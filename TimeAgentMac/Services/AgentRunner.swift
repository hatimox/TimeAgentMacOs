import Foundation
import AppKit

/// Runs a Claude Code agent against a User Story or a single Task/Bug:
/// understand → (questions) → tasks / plan for approval → code in a git
/// worktree → push + GitLab MR. The whole run is timed and logged to TP.

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

/// What a run works on: a whole User Story (the agent breaks it into tasks)
/// or a single existing Task/Bug (the agent plans, you approve, it codes).
enum AgentTarget {
    case story(id: Int, name: String, projectName: String)
    case item(WorkItem)

    var id: Int {
        switch self { case .story(let id, _, _): return id; case .item(let it): return it.id }
    }
}

@MainActor
final class AgentRun: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case setup, understanding, needsAnswer, reviewTasks, reviewPlan, creatingTasks
        case coding, needsInput, readyToFinish, finishing, done, stopped
        case failed(String)
    }

    /// Item runs: work directly on the US branch, or on a new branch cut from it.
    enum BranchMode: String, CaseIterable, Identifiable {
        case usBranch, newFromUS
        var id: String { rawValue }
    }

    let target: AgentTarget
    let id: Int                  // TP id of the target
    let usId: Int                // parent US (== id for story runs, 0 if a task has none)
    let projectName: String
    let kindLabel: String        // "US" | "Task" | "Bug"
    @Published var name: String
    @Published var usName: String
    @Published var phase: Phase = .setup
    @Published var log: [AgentLogLine] = []
    @Published var tasks: [AgentTask] = []
    @Published var repoPath: String
    @Published var baseBranch: String
    @Published var branchMode: BranchMode = .newFromUS
    @Published var newBranch: String
    @Published var mrURL: String?
    @Published private(set) var busy = false          // an agent turn is in progress
    @Published private(set) var currentTask: Int?      // index into tasks
    @Published private(set) var startedAt: Date?

    unowned let store: AppStore
    private var story: TPClient.UserStoryInfo?
    private var itemDetail: TPClient.ItemDetail?
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

    var isStory: Bool { if case .story = target { return true }; return false }
    var usBranch: String { "feature/US-\(usId)" }
    /// The branch the agent commits on.
    var workBranch: String {
        if isStory { return usBranch }
        if usId == 0 || branchMode == .newFromUS { return newBranch.trimmingCharacters(in: .whitespaces) }
        return usBranch
    }
    /// The branch `workBranch` is cut from, and the MR target.
    var parentBranch: String {
        (isStory || usId == 0 || branchMode == .usBranch) ? baseBranch : usBranch
    }
    var isFinished: Bool { phase == .done || phase == .stopped }
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var canReply: Bool { !busy && [.needsAnswer, .reviewTasks, .reviewPlan, .needsInput, .readyToFinish].contains(phase) }
    var canFinish: Bool { !busy && [.needsInput, .readyToFinish].contains(phase) }

    init(store: AppStore, target: AgentTarget) {
        self.store = store; self.target = target; self.id = target.id
        switch target {
        case .story(let id, let name, let project):
            usId = id; self.name = name; usName = name; projectName = project; kindLabel = "US"
        case .item(let it):
            usId = it.usId; name = it.name; usName = it.usName; projectName = it.projectName
            kindLabel = it.displayType
        }
        newBranch = "feature/TP-\(target.id)"
        let saved = store.settings.agentRepos[projectName] ?? [:]
        repoPath = saved["path"] ?? ""
        baseBranch = saved["branch"] ?? "master"
    }

    private var settings: Settings { store.settings }
    private var claudePath: String? {
        let p = settings.agentClaudePath.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? Shell.which("claude") : p
    }
    private var processId: Int {
        if case .item(let it) = target { return it.processId }
        return story?.processId ?? 0
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
        guard !workBranch.isEmpty else { return fail("Enter a branch name") }
        settings.agentRepos[projectName] = ["path": repoPath, "branch": baseBranch]
        settings.save()

        phase = .understanding; busy = true
        startedAt = Date(); bucketSince = startedAt!
        info("Loading \(kindLabel) #\(id)…")
        do {
            switch target {
            case .story:
                story = try await client.fetchUserStory(id: id)
                if let n = story?.name, !n.isEmpty { name = n; usName = n }
            case .item(let it):
                itemDetail = try await client.fetchItemDetail(entityType: it.entityType, id: it.id)
            }
        } catch { return fail("Could not load \(kindLabel): \((error as? TPError)?.message ?? error.localizedDescription)") }

        guard let wt = await prepareWorktree(repo) else { return }
        worktree = wt
        await moveTargetState(matching: "progress")
        launch(claude, extra: planArgs, prompt: isStory ? storyPrompt : itemPrompt)
    }

    /// User answer / follow-up. Relaunches (resuming the session) if the agent exited.
    func reply(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, canReply else { return }
        append(.user, t)
        let coding = ![.needsAnswer, .reviewTasks, .reviewPlan].contains(phase)
        phase = coding ? .coding : .understanding
        busy = true
        if let proc { proc.send(t) }
        else if let claude = claudePath { launch(claude, extra: coding ? codingArgs : planArgs, prompt: t) }
    }

    /// Story runs: create the reviewed tasks in TP, then start coding.
    func approveTasks() async {
        guard let client = store.client, let story else { return }
        tasks.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !tasks.isEmpty else { return }
        phase = .creatingTasks
        for i in tasks.indices where tasks[i].tpId == 0 {
            do {
                tasks[i].tpId = try await client.createTask(usId: id, projectId: story.projectId,
                                                            name: tasks[i].name, description: tasks[i].description)
                info("Created task #\(tasks[i].tpId) — \(tasks[i].name)")
            } catch {
                append(.error, "Creating “\(tasks[i].name)” failed: \((error as? TPError)?.message ?? error.localizedDescription)")
                phase = .reviewTasks; return
            }
        }
        Task { await store.refresh() }
        startCoding(prompt: storyCodingPrompt)
    }

    /// Item runs: the plan was approved — start coding.
    func approvePlan() {
        guard phase == .reviewPlan else { return }
        append(.user, "Plan approved — start coding.")
        startCoding(prompt: itemCodingPrompt)
    }

    /// Restart the agent (same conversation) with edit permissions.
    private func startCoding(prompt: String) {
        phase = .coding; busy = true
        guard let claude = claudePath else { return }
        let start = { [weak self] in guard let self else { return }; self.launch(claude, extra: self.codingArgs, prompt: prompt) }
        if let proc { afterExit = start; proc.closeInput() } else { start() }
    }

    /// Commit leftovers, push the work branch, open the GitLab MR, log time.
    func finish() async {
        guard let wt = worktree else { return }
        phase = .finishing
        proc?.closeInput()
        if !(await Shell.run(["git", "status", "--porcelain"], cwd: wt)).out
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = await Shell.run(["git", "add", "-A"], cwd: wt)
            _ = await Shell.run(["git", "commit", "-m", "\(isStory ? "US" : "TP")#\(id): \(name)"], cwd: wt)
        }
        // A task branch cut from a local-only US branch needs that target on the remote.
        if parentBranch != baseBranch,
           await Shell.run(["git", "ls-remote", "--exit-code", "--heads", "origin", parentBranch], cwd: wt).code != 0 {
            info("Pushing \(parentBranch)…")
            _ = await Shell.run(["git", "push", "origin", parentBranch], cwd: wt)
        }
        info("Pushing \(workBranch)…")
        let push = await Shell.run(["git", "push", "-u", "origin", workBranch], cwd: wt)
        guard push.code == 0 else {
            append(.error, "git push failed:\n\(push.out)"); phase = .readyToFinish; return
        }
        if Shell.which("glab") != nil {
            var args = ["glab", "mr", "create", "--source-branch", workBranch, "--target-branch", parentBranch,
                        "--title", mrTitle, "--description", mrDescription, "--remove-source-branch", "--yes"]
            for r in settings.mrReviewers.split(separator: ",") {
                let n = r.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { args += ["--reviewer", n] }
            }
            let mr = await Shell.run(args, cwd: wt)
            if mr.code == 0 { mrURL = Self.firstURL(in: mr.out); info("Merge request created → \(parentBranch)") }
            else { append(.error, "glab mr create failed:\n\(mr.out)"); mrURL = Self.firstURL(in: push.out) }
        } else {
            mrURL = Self.firstURL(in: push.out)
            info("glab not installed — branch pushed; open the merge request from the link.")
        }
        await logTime()
        await moveTargetState(matching: "review")
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

    private func moveTargetState(matching: String) async {
        switch target {
        case .story:
            await store.moveState(entityType: "UserStories", stateKey: "UserStory", id: id,
                                  processId: processId, matching: matching)
        case .item(let it):
            await store.moveState(entityType: it.entityType, stateKey: it.entityType == "Bugs" ? "Bug" : "Task",
                                  id: it.id, processId: it.processId, matching: matching)
        }
    }

    // MARK: process plumbing

    /// Never add AI co-author / attribution trailers to commits or MRs.
    private static let noAttribution = #"{"includeCoAuthoredBy":false,"attribution":{"commit":"","pr":""}}"#

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
                    "--verbose", "--model", settings.agentModel.isEmpty ? "sonnet" : settings.agentModel,
                    "--settings", Self.noAttribution]
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
                    if name == "ExitPlanMode", let plan = input["plan"] as? String {
                        turnText += plan + "\n"
                        append(.agent, plan)
                    }
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
            if isStory, let ts = Self.parseTasks(text), !ts.isEmpty { tasks = ts; phase = .reviewTasks }
            else if !isStory, text.contains("@@PLAN_READY@@") { phase = .reviewPlan }
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

    /// Story runs: `@@TASK n@@` switches the time bucket and moves that TP task to In Progress.
    private func scanMarkers(_ t: String) {
        guard isStory, let re = try? NSRegularExpression(pattern: "@@TASK (\\d+)@@") else { return }
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range(at: 1), in: t), let n = Int(t[r]), tasks.indices.contains(n - 1) else { continue }
            switchBucket(n - 1)
            currentTask = n - 1
            let tpId = tasks[n - 1].tpId
            if tpId != 0 {
                Task { await store.moveState(entityType: "Tasks", stateKey: "Task", id: tpId,
                                             processId: processId, matching: "progress") }
            }
        }
    }

    // MARK: time

    private func switchBucket(_ n: Int) {
        let now = Date()
        buckets[bucket, default: 0] += now.timeIntervalSince(bucketSince)
        bucket = n; bucketSince = now
    }

    /// Log the full run time. Item runs: all on the item. Story runs: each task
    /// gets its coding time plus an even share of the pre-coding time; no tasks
    /// → on the US.
    private func logTime() async {
        guard startedAt != nil, let client = store.client else { return }
        startedAt = nil
        switchBucket(bucket)
        let total = buckets.values.reduce(0, +)
        let created = tasks.indices.filter { tasks[$0].tpId != 0 }
        var perEntity: [Int: TimeInterval] = [:]
        if !isStory || created.isEmpty {
            perEntity[id] = total
        } else {
            let shared = buckets.filter { !created.contains($0.key) }.values.reduce(0, +)
            for i in created { perEntity[tasks[i].tpId] = (buckets[i] ?? 0) + shared / Double(created.count) }
        }
        for (entity, secs) in perEntity {
            let h = (secs / 3600 * 100).rounded() / 100
            guard h > 0 else { continue }
            do {
                _ = try await client.logTime(entityId: entity, hours: h, description: "AI agent session — \(kindLabel)#\(id)",
                                             date: Date(), tzOffsetMinutes: settings.tzOffsetMinutes)
                info("Logged \(store.fmt(h)) to #\(entity)")
            } catch { append(.error, "Logging time to #\(entity) failed: \((error as? TPError)?.message ?? error.localizedDescription)") }
        }
        await store.refresh()
    }

    // MARK: git

    /// Make sure the work branch exists (creating the US branch from the base
    /// and/or the task branch from the US branch as needed), then return a
    /// worktree checked out on it — reusing any existing checkout of it.
    private func prepareWorktree(_ repo: URL) async -> URL? {
        info("Fetching origin…")
        _ = await Shell.run(["git", "fetch", "origin"], cwd: repo)
        if parentBranch == usBranch {
            guard await ensureBranch(usBranch, from: baseBranch, repo) else { return nil }
        }
        guard await ensureBranch(workBranch, from: parentBranch, repo) else { return nil }

        if let existing = await worktreePath(for: workBranch, repo) {
            info("Reusing \(existing.path) (on \(workBranch))")
            return existing
        }
        let wt = repo.deletingLastPathComponent().appendingPathComponent(
            "\(repo.lastPathComponent)-\(workBranch.replacingOccurrences(of: "/", with: "-"))")
        let r = await Shell.run(["git", "worktree", "add", wt.path, workBranch], cwd: repo)
        guard r.code == 0 else { fail("git worktree failed: \(r.out)"); return nil }
        info("Created worktree \(wt.path) on \(workBranch)")
        return wt
    }

    /// Create `branch` if missing: from its remote copy if someone pushed it,
    /// else from `parent` (remote first, then local).
    private func ensureBranch(_ branch: String, from parent: String, _ repo: URL) async -> Bool {
        func exists(_ ref: String) async -> Bool {
            await Shell.run(["git", "rev-parse", "--verify", "--quiet", ref], cwd: repo).code == 0
        }
        if await exists("refs/heads/\(branch)") { return true }
        let start: String
        if await exists("refs/remotes/origin/\(branch)") { start = "origin/\(branch)" }
        else if await exists("refs/heads/\(parent)") && parent == usBranch { start = parent }   // local US branch may be ahead
        else if await exists("refs/remotes/origin/\(parent)") { start = "origin/\(parent)" }
        else if await exists("refs/heads/\(parent)") { start = parent }
        else { fail("Branch “\(parent)” not found locally or on origin"); return false }
        let r = await Shell.run(["git", "branch", "--no-track", branch, start], cwd: repo)
        guard r.code == 0 else { fail("Creating \(branch) failed: \(r.out)"); return false }
        info("Created branch \(branch) from \(start)")
        return true
    }

    private func worktreePath(for branch: String, _ repo: URL) async -> URL? {
        var path: String?
        for line in await Shell.run(["git", "worktree", "list", "--porcelain"], cwd: repo).out.split(separator: "\n") {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            else if line == "branch refs/heads/\(branch)", let path { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: prompts

    private static let commitRules = """
        - Never push.
        - Never add `Co-Authored-By` or any AI / Claude attribution to commit messages.
        - Stay inside this directory. Build / run the tests if the project has them.
        - If you are blocked or need a decision, ask and stop.
        - When everything is done, print `@@DONE@@` followed by a short summary of the changes.
        """

    private var workspaceSection: String {
        "## Workspace\nThe current directory is a git worktree of the project on branch `\(workBranch)` (from `\(parentBranch)`)."
    }

    private var storyPrompt: String {
        let desc = story?.description ?? ""
        return """
        You are a software engineer working on TargetProcess User Story #\(id): “\(name)”.

        ## User Story
        \(desc.isEmpty ? "(no description)" : desc)

        \(workspaceSection)

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

    private var itemPrompt: String {
        let d = itemDetail
        let usPart = usId != 0 ? " (part of User Story #\(usId): “\(usName)”)" : ""
        let usSection = usId != 0
            ? "\n## Parent User Story (context)\n\((d?.usDescription.isEmpty ?? true) ? "(no description)" : d!.usDescription)\n"
            : ""
        return """
        You are a software engineer working on TargetProcess \(kindLabel) #\(id): “\(name)”\(usPart).

        ## \(kindLabel)
        \((d?.description.isEmpty ?? true) ? "(no description)" : d!.description)
        \(usSection)
        \(workspaceSection)

        ## Step 1 — understand & plan (read-only)
        Explore the code relevant to this \(kindLabel.lowercased()). Do not modify any files yet.
        Then end your reply in exactly ONE of these two ways:
        - If anything important is unclear, ask concise numbered questions and end with the line @@QUESTIONS@@.
        - Otherwise, present a concise implementation plan (files, approach, tests) and end with the line @@PLAN_READY@@.
        Do not start coding — wait for approval.
        \(settings.agentInstructions)
        """
    }

    private var storyCodingPrompt: String {
        let list = tasks.enumerated().map { "\($0.offset + 1). TP#\($0.element.tpId) — \($0.element.name): \($0.element.description)" }
            .joined(separator: "\n")
        return """
        The tasks were approved and created in TargetProcess. Implement them in order:
        \(list)

        Rules:
        - Before starting task n, print the line `@@TASK n@@` on its own.
        - Commit after each task with `git commit -m "TP#<task id>: <title>"`.
        \(Self.commitRules)
        """
    }

    private var itemCodingPrompt: String {
        """
        The plan is approved. Implement it now.

        Rules:
        - Commit with `git commit -m "TP#\(id): <summary>"` (one or more commits).
        \(Self.commitRules)
        """
    }

    private var mrTitle: String {
        isStory ? "US#\(id): \(name)" : "TP#\(id): \(name)"
    }

    private var mrDescription: String {
        var parts = [isStory ? "User Story: TP#\(id) — \(name)" : "\(kindLabel): TP#\(id) — \(name)"]
        if !isStory && usId != 0 { parts.append("User Story: TP#\(usId) — \(usName)") }
        let list = tasks.filter { $0.tpId != 0 }.map { "- TP#\($0.tpId) \($0.name)" }.joined(separator: "\n")
        if !list.isEmpty { parts.append("## Tasks\n\(list)") }
        if !summary.isEmpty { parts.append("## Summary\n\(summary)") }
        return parts.joined(separator: "\n\n")
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
