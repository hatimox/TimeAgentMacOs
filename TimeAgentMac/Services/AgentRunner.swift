import Foundation
import AppKit

/// Runs a Claude Code agent against a User Story: understand → (questions) →
/// propose tasks → create them in TP → code in a git worktree → push + GitLab
/// MR. The whole run is timed and logged split across the created tasks.

struct AgentLogLine: Identifiable {
    enum Kind { case agent, tool, user, info, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

struct AgentTask: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var description: String
    var tpId: Int = 0
}

// MARK: - shell helpers

enum Shell {
    /// GUI apps get a minimal PATH; add the usual CLI install locations.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
    }()

    static func which(_ name: String) -> String? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Run a command to completion off the main thread → (status, stdout+stderr).
    static func run(_ args: [String], cwd: URL? = nil) async -> (code: Int32, out: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                p.environment = environment
                if let cwd { p.currentDirectoryURL = cwd }
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}

// MARK: - headless claude process

/// A `claude -p` process speaking stream-json on stdin/stdout. Stays alive
/// between turns so follow-up messages (answers) continue the conversation.
final class ClaudeProcess {
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()
    private let proc = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    var onEvent: (@MainActor ([String: Any]) -> Void)?
    var onExit: (@MainActor (Int32, String) -> Void)?

    init(executable: String, args: [String], cwd: URL) {
        _ = Self.ignoreSigpipe   // writing to a dead agent must not kill the app
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        proc.environment = Shell.environment
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr
    }

    /// Set `onEvent` / `onExit` before calling. Events arrive in order, then exit.
    func start() throws {
        try proc.run()
        let out = stdout.fileHandleForReading, err = stderr.fileHandleForReading, proc = self.proc
        let onEvent = self.onEvent, onExit = self.onExit
        Task.detached {
            async let errText: String = withCheckedContinuation { c in
                DispatchQueue.global().async {
                    c.resume(returning: String(data: err.readDataToEndOfFile(), encoding: .utf8) ?? "")
                }
            }
            do {
                for try await line in out.bytes.lines {
                    guard let d = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    await MainActor.run { onEvent?(obj) }
                }
            } catch {}
            let e = await errText
            proc.waitUntilExit()
            let code = proc.terminationStatus
            await MainActor.run { onExit?(code, e) }
        }
    }

    func send(_ text: String) {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard var d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        d.append(0x0A)
        try? stdin.fileHandleForWriting.write(contentsOf: d)
    }

    func closeInput() { try? stdin.fileHandleForWriting.close() }
    func terminate() { if proc.isRunning { proc.terminate() } }
}

// MARK: - one agent run

@MainActor
final class AgentRun: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case setup, understanding, needsAnswer, reviewTasks, creatingTasks
        case coding, needsInput, readyToFinish, finishing, done, stopped
        case failed(String)
    }

    let usId: Int
    let projectName: String
    @Published var usName: String
    @Published var phase: Phase = .setup
    @Published var log: [AgentLogLine] = []
    @Published var tasks: [AgentTask] = []
    @Published var repoPath: String
    @Published var baseBranch: String
    @Published var mrURL: String?
    @Published private(set) var busy = false          // an agent turn is in progress
    @Published private(set) var currentTask: Int?      // index into tasks
    @Published private(set) var startedAt: Date?

    unowned let store: AppStore
    private var story: TPClient.UserStoryInfo?
    private var proc: ClaudeProcess?
    private var afterExit: (() -> Void)?
    private var sessionId: String?
    private(set) var worktree: URL?
    private var turnText = ""
    private var summary = ""
    // Time accounting: seconds per task index; -1 = before any task started.
    private var buckets: [Int: TimeInterval] = [:]
    private var bucket = -1
    private var bucketSince = Date()

    var branch: String { "feature/US-\(usId)" }
    var isFinished: Bool { phase == .done || phase == .stopped }
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var canReply: Bool { !busy && [.needsAnswer, .needsInput, .readyToFinish].contains(phase) }
    var canFinish: Bool { !busy && [.needsInput, .readyToFinish].contains(phase) }

    init(store: AppStore, usId: Int, usName: String, projectName: String) {
        self.store = store; self.usId = usId; self.usName = usName; self.projectName = projectName
        let saved = store.settings.agentRepos[projectName] ?? [:]
        repoPath = saved["path"] ?? ""
        baseBranch = saved["branch"] ?? "main"
    }

    private var settings: Settings { store.settings }
    private var claudePath: String? {
        let p = settings.agentClaudePath.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? Shell.which("claude") : p
    }

    // MARK: lifecycle

    func start() async {
        guard let client = store.client else { return fail("TargetProcess is not configured") }
        guard let claude = claudePath, FileManager.default.isExecutableFile(atPath: claude) else {
            return fail("Claude Code CLI not found — install it or set its path in Settings → Agent")
        }
        let repo = URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) else {
            return fail("Not a git repository: \(repo.path)")
        }
        settings.agentRepos[projectName] = ["path": repoPath, "branch": baseBranch]
        settings.save()

        phase = .understanding; busy = true
        startedAt = Date(); bucketSince = startedAt!
        info("Loading US #\(usId)…")
        do { story = try await client.fetchUserStory(id: usId) }
        catch { return fail("Could not load US: \((error as? TPError)?.message ?? error.localizedDescription)") }
        if let story, !story.name.isEmpty { usName = story.name }

        guard let wt = await makeWorktree(repo) else { return }
        worktree = wt
        await store.moveState(entityType: "UserStories", stateKey: "UserStory", id: usId,
                              processId: story?.processId ?? 0, matching: "progress")
        launch(claude, extra: ["--permission-mode", "plan",
                               "--allowedTools", "Read,Glob,Grep,Bash(git log:*),Bash(git diff:*),Bash(ls:*)"],
               prompt: understandPrompt)
    }

    /// User answer / follow-up. Relaunches (resuming the session) if the agent exited.
    func reply(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, canReply else { return }
        append(.user, t)
        let coding = phase != .needsAnswer
        phase = coding ? .coding : .understanding
        busy = true
        if let proc { proc.send(t) }
        else if let claude = claudePath { launch(claude, extra: coding ? codingArgs : planArgs, prompt: t) }
    }

    /// Create the reviewed tasks in TP, then restart the agent in edit mode.
    func approveTasks() async {
        guard let client = store.client, let story else { return }
        tasks.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !tasks.isEmpty else { return }
        phase = .creatingTasks
        for i in tasks.indices where tasks[i].tpId == 0 {
            do {
                tasks[i].tpId = try await client.createTask(usId: usId, projectId: story.projectId,
                                                            name: tasks[i].name, description: tasks[i].description)
                info("Created task #\(tasks[i].tpId) — \(tasks[i].name)")
            } catch {
                append(.error, "Creating “\(tasks[i].name)” failed: \((error as? TPError)?.message ?? error.localizedDescription)")
                phase = .reviewTasks; return
            }
        }
        Task { await store.refresh() }
        phase = .coding; busy = true
        guard let claude = claudePath else { return }
        let prompt = codingPrompt
        let start = { [weak self] in guard let self else { return }; self.launch(claude, extra: self.codingArgs, prompt: prompt) }
        if let proc { afterExit = start; proc.closeInput() } else { start() }
    }

    /// Commit leftovers, push the feature branch, open the GitLab MR, log time.
    func finish() async {
        guard let wt = worktree else { return }
        phase = .finishing
        proc?.closeInput()
        if !(await Shell.run(["git", "status", "--porcelain"], cwd: wt)).out
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = await Shell.run(["git", "add", "-A"], cwd: wt)
            _ = await Shell.run(["git", "commit", "-m", "US#\(usId): \(usName) (agent)"], cwd: wt)
        }
        info("Pushing \(branch)…")
        let push = await Shell.run(["git", "push", "-u", "origin", branch], cwd: wt)
        guard push.code == 0 else {
            append(.error, "git push failed:\n\(push.out)"); phase = .readyToFinish; return
        }
        if Shell.which("glab") != nil {
            var args = ["glab", "mr", "create", "--source-branch", branch, "--target-branch", baseBranch,
                        "--title", "US#\(usId): \(usName)", "--description", mrDescription,
                        "--remove-source-branch", "--yes"]
            for r in settings.mrReviewers.split(separator: ",") {
                let name = r.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { args += ["--reviewer", name] }
            }
            let mr = await Shell.run(args, cwd: wt)
            if mr.code == 0 { mrURL = Self.firstURL(in: mr.out); info("Merge request created") }
            else { append(.error, "glab mr create failed:\n\(mr.out)"); mrURL = Self.firstURL(in: push.out) }
        } else {
            mrURL = Self.firstURL(in: push.out)
            info("glab not installed — branch pushed; open the merge request from the link.")
        }
        await logTime()
        await store.moveState(entityType: "UserStories", stateKey: "UserStory", id: usId,
                              processId: story?.processId ?? 0, matching: "review")
        phase = .done
    }

    /// Kill the agent and log the time spent so far.
    func stop() async {
        afterExit = nil
        proc?.terminate(); proc = nil
        busy = false
        await logTime()
        phase = .stopped
    }

    // MARK: process plumbing

    private var planArgs: [String] {
        ["--permission-mode", "plan", "--allowedTools", "Read,Glob,Grep,Bash(git log:*),Bash(git diff:*),Bash(ls:*)"]
    }

    private var codingArgs: [String] {
        var tools = ["Read", "Edit", "MultiEdit", "Write", "Glob", "Grep", "TodoWrite",
                     "Bash(git add:*)", "Bash(git commit:*)", "Bash(git status:*)",
                     "Bash(git diff:*)", "Bash(git log:*)", "Bash(ls:*)"]
        tools += settings.agentExtraTools.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ["--permission-mode", "acceptEdits", "--allowedTools", tools.joined(separator: ","),
                "--disallowedTools", "Bash(git push:*)"]
    }

    private func launch(_ claude: String, extra: [String], prompt: String) {
        guard let wt = worktree else { return }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--model", settings.agentModel.isEmpty ? "sonnet" : settings.agentModel]
        if let sessionId { args += ["--resume", sessionId] }
        args += extra
        let p = ClaudeProcess(executable: claude, args: args, cwd: wt)
        p.onEvent = { [weak self] in self?.handle($0) }
        p.onExit = { [weak self] code, err in self?.exited(code, err) }
        do { try p.start() } catch { return fail("Could not start claude: \(error.localizedDescription)") }
        proc = p
        busy = true; turnText = ""
        p.send(prompt)
    }

    private func exited(_ code: Int32, _ err: String) {
        proc = nil
        if let next = afterExit { afterExit = nil; next(); return }
        guard busy, !isFinished, phase != .finishing else { return }
        busy = false
        if code != 0 {
            append(.error, "Agent exited (\(code)). \(err.suffix(600))")
            if phase == .understanding { phase = .needsAnswer } else if phase == .coding { phase = .needsInput }
        }
    }

    private func handle(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "system":
            if ev["subtype"] as? String == "init", let s = ev["session_id"] as? String { sessionId = s }
        case "assistant":
            let content = (ev["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for c in content {
                switch c["type"] as? String {
                case "text":
                    let t = c["text"] as? String ?? ""
                    turnText += t + "\n"
                    scanMarkers(t)
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { append(.agent, t) }
                case "tool_use":
                    let name = c["name"] as? String ?? "tool"
                    let input = c["input"] as? [String: Any] ?? [:]
                    if name == "ExitPlanMode", let plan = input["plan"] as? String { turnText += plan + "\n" }
                    append(.tool, toolSummary(name, input))
                default: break
                }
            }
        case "result":
            if let s = ev["session_id"] as? String { sessionId = s }
            let text = ev["result"] as? String ?? ""
            if ev["is_error"] as? Bool == true { append(.error, text.isEmpty ? "Agent reported an error" : text) }
            turnFinished(turnText + "\n" + text)
            turnText = ""
        default: break
        }
    }

    private func turnFinished(_ text: String) {
        busy = false
        switch phase {
        case .understanding:
            if let ts = Self.parseTasks(text), !ts.isEmpty { tasks = ts; phase = .reviewTasks }
            else { phase = .needsAnswer }
        case .coding:
            if text.contains("@@DONE@@") {
                summary = text.components(separatedBy: "@@DONE@@").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                phase = .readyToFinish
            } else { phase = .needsInput }
        default: break
        }
    }

    /// `@@TASK n@@` switches the time bucket and moves the TP task to In Progress.
    private func scanMarkers(_ t: String) {
        guard let re = try? NSRegularExpression(pattern: "@@TASK (\\d+)@@") else { return }
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range(at: 1), in: t), let n = Int(t[r]), tasks.indices.contains(n - 1) else { continue }
            switchBucket(n - 1)
            currentTask = n - 1
            let tpId = tasks[n - 1].tpId
            if tpId != 0 {
                Task { await store.moveState(entityType: "Tasks", stateKey: "Task", id: tpId,
                                             processId: story?.processId ?? 0, matching: "progress") }
            }
        }
    }

    // MARK: time

    private func switchBucket(_ n: Int) {
        let now = Date()
        buckets[bucket, default: 0] += now.timeIntervalSince(bucketSince)
        bucket = n; bucketSince = now
    }

    /// Log the full run time: each task gets its own coding time plus an even
    /// share of the time before coding started. No tasks → log on the US.
    private func logTime() async {
        guard startedAt != nil, let client = store.client else { return }
        startedAt = nil
        switchBucket(bucket)
        let created = tasks.indices.filter { tasks[$0].tpId != 0 }
        var perEntity: [Int: TimeInterval] = [:]
        if created.isEmpty {
            perEntity[usId] = buckets.values.reduce(0, +)
        } else {
            let shared = buckets.filter { !created.contains($0.key) }.values.reduce(0, +)
            for i in created { perEntity[tasks[i].tpId] = (buckets[i] ?? 0) + shared / Double(created.count) }
        }
        for (id, secs) in perEntity {
            let h = (secs / 3600 * 100).rounded() / 100
            guard h > 0 else { continue }
            do {
                _ = try await client.logTime(entityId: id, hours: h, description: "AI agent session — US#\(usId)",
                                             date: Date(), tzOffsetMinutes: settings.tzOffsetMinutes)
                info("Logged \(store.fmt(h)) to #\(id)")
            } catch { append(.error, "Logging time to #\(id) failed: \((error as? TPError)?.message ?? error.localizedDescription)") }
        }
        await store.refresh()
    }

    // MARK: git

    private func makeWorktree(_ repo: URL) async -> URL? {
        let wt = repo.deletingLastPathComponent().appendingPathComponent("\(repo.lastPathComponent)-US-\(usId)")
        if FileManager.default.fileExists(atPath: wt.path) { info("Reusing worktree \(wt.path)"); return wt }
        info("Creating worktree \(wt.path) on \(branch)…")
        _ = await Shell.run(["git", "fetch", "origin", baseBranch], cwd: repo)
        var args = ["git", "worktree", "add"]
        if await Shell.run(["git", "rev-parse", "--verify", "--quiet", branch], cwd: repo).code == 0 {
            args += [wt.path, branch]
        } else {
            let hasRemote = await Shell.run(["git", "rev-parse", "--verify", "--quiet", "origin/\(baseBranch)"], cwd: repo).code == 0
            args += ["--no-track", "-b", branch, wt.path, hasRemote ? "origin/\(baseBranch)" : baseBranch]
        }
        let r = await Shell.run(args, cwd: repo)
        guard r.code == 0 else { fail("git worktree failed: \(r.out)"); return nil }
        return wt
    }

    /// Default branch of the repo at `path` (origin/HEAD, else current branch).
    static func defaultBranch(of path: String) async -> String? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let head = await Shell.run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: url)
        if head.code == 0 {
            return head.out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "origin/", with: "")
        }
        let cur = await Shell.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: url)
        return cur.code == 0 ? cur.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // MARK: prompts

    private var understandPrompt: String {
        let desc = story?.description ?? ""
        return """
        You are a software engineer working on TargetProcess User Story #\(usId): “\(usName)”.

        ## User Story
        \(desc.isEmpty ? "(no description)" : desc)

        ## Workspace
        The current directory is a git worktree of the project on branch `\(branch)` (based on `\(baseBranch)`).

        ## Step 1 — understand (read-only)
        Explore the code relevant to this story. Do not modify any files yet.
        Then end your reply in exactly ONE of these two ways:
        - If anything important is unclear, ask concise numbered questions and end with the line @@QUESTIONS@@. You will get answers and can continue.
        - Otherwise, propose 1–8 implementation tasks as a fenced block tagged `tasks` holding a JSON array:
        ```tasks
        [{"name": "Short imperative title", "description": "What to change and where"}]
        ```
        \(settings.agentInstructions)
        """
    }

    private var codingPrompt: String {
        let list = tasks.enumerated().map { "\($0.offset + 1). TP#\($0.element.tpId) — \($0.element.name): \($0.element.description)" }
            .joined(separator: "\n")
        return """
        The tasks were approved and created in TargetProcess. Implement them in order:
        \(list)

        Rules:
        - Before starting task n, print the line `@@TASK n@@` on its own.
        - Commit after each task with `git commit -m "TP#<task id>: <title>"`. Never push.
        - Stay inside this directory. Build / run the tests if the project has them.
        - If you are blocked or need a decision, ask and stop.
        - When all tasks are done, print `@@DONE@@` followed by a short summary of the changes.
        """
    }

    private var mrDescription: String {
        let list = tasks.filter { $0.tpId != 0 }.map { "- TP#\($0.tpId) \($0.name)" }.joined(separator: "\n")
        return "User Story: TP#\(usId) — \(usName)\n\n## Tasks\n\(list)\n\n## Summary\n\(summary)\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"
    }

    // MARK: helpers

    static func parseTasks(_ text: String) -> [AgentTask]? {
        guard let re = try? NSRegularExpression(pattern: "```tasks\\s*\\n(.*?)```", options: .dotMatchesLineSeparators),
              let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let r = Range(m.range(at: 1), in: text),
              let data = text[r].data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return AgentTask(name: name, description: $0["description"] as? String ?? "")
        }
    }

    private static func firstURL(in s: String) -> String? {
        guard let r = s.range(of: "https?://\\S+", options: .regularExpression) else { return nil }
        return String(s[r])
    }

    private func toolSummary(_ name: String, _ input: [String: Any]) -> String {
        var arg = ["file_path", "command", "pattern", "path", "url"].lazy.compactMap { input[$0] as? String }.first ?? ""
        if let wt = worktree?.path { arg = arg.replacingOccurrences(of: wt + "/", with: "") }
        return "\(name) \(arg)".prefix(200).description
    }

    private func append(_ kind: AgentLogLine.Kind, _ text: String) { log.append(.init(kind: kind, text: text)) }
    private func info(_ text: String) { append(.info, text) }
    private func fail(_ message: String) { append(.error, message); busy = false; phase = .failed(message) }
}
