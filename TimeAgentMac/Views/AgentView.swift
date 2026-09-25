import SwiftUI
import AppKit

/// Agent window for one User Story or Task/Bug: setup (repo + branch), live
/// transcript, question answering, task / plan approval, and push / MR.
struct AgentView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var run: AgentRun
    @State private var reply = ""
    @State private var clock = "00:00:00"
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if run.phase == .setup { setup } else {
                HSplitView {
                    transcript.frame(minWidth: 420)
                    Group { if run.isStory { taskPanel } else { planPanel } }
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
                Divider()
                bottomBar
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onReceive(tick) { _ in clock = Self.hms(run.elapsed) }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Button("\(run.kindLabel) #\(run.id)") { store.openInTP(run.id) }
                .buttonStyle(.link).font(.callout.monospacedDigit())
            Text(run.name).font(.headline).lineLimit(1)
            Spacer()
            if run.busy { ProgressView().controlSize(.small) }
            phaseBadge
            if run.startedAt != nil {
                Label(clock, systemImage: "timer").font(.callout.monospacedDigit()).foregroundStyle(.red)
            }
        }
        .padding(12)
    }

    private var phaseBadge: some View {
        let (label, color): (String, Color) = {
            switch run.phase {
            case .setup: return ("Setup", .secondary)
            case .understanding: return ("Understanding", .blue)
            case .needsAnswer: return ("Waiting for your answer", .orange)
            case .reviewTasks: return ("Review tasks", .orange)
            case .reviewPlan: return ("Review plan", .orange)
            case .creatingTasks: return ("Creating tasks", .blue)
            case .coding: return ("Coding", .purple)
            case .needsInput: return ("Waiting for you", .orange)
            case .readyToFinish: return ("Ready for MR", .green)
            case .finishing: return ("Pushing", .blue)
            case .done: return ("Done", .green)
            case .stopped: return ("Stopped", .secondary)
            case .failed: return ("Failed", .red)
            }
        }()
        return Text(label).font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }

    // MARK: setup

    private var setup: some View {
        Form {
            Section("Repository") {
                HStack {
                    TextField("Folder", text: $run.repoPath, prompt: Text("~/code/my-project"))
                    Button("Choose…") { chooseFolder() }
                }
                TextField("Base branch", text: $run.baseBranch, prompt: Text("master"))
            }
            Section("Branch") {
                if !run.isStory && run.usId != 0 {
                    Picker("Work on", selection: $run.branchMode) {
                        Text("US branch (\(run.usBranch))").tag(AgentRun.BranchMode.usBranch)
                        Text("New branch from the US branch").tag(AgentRun.BranchMode.newFromUS)
                    }
                    .pickerStyle(.radioGroup)
                }
                if !run.isStory && (run.usId == 0 || run.branchMode == .newFromUS) {
                    TextField("New branch", text: $run.newBranch)
                }
                Text(branchSummary).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(run.isStory
                     ? "The agent reads the US, asks questions if needed and proposes tasks. Nothing is coded until you approve the tasks. Time is logged split across the created tasks."
                     : "The agent reads the \(run.kindLabel.lowercased()) (and its US), asks questions if needed and proposes a plan. Nothing is coded until you approve the plan. All time is logged to this \(run.kindLabel.lowercased()).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button { Task { await run.start() } } label: {
                    Label("Start agent", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(run.repoPath.isEmpty || run.baseBranch.isEmpty || run.workBranch.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    /// e.g. "Commits on feature/TP-42, cut from feature/US-7 (created from master if missing). MR → feature/US-7."
    private var branchSummary: String {
        var s = "Commits on \(run.workBranch), cut from \(run.parentBranch)"
        if run.parentBranch == run.usBranch { s += " (created from \(run.baseBranch) if missing)" }
        else if run.workBranch == run.usBranch { s = "Commits on \(run.usBranch) (created from \(run.baseBranch) if missing)" }
        return s + ". MR → \(run.parentBranch)."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Use this repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run.repoPath = url.path
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(run.log) { line in logLine(line).id(line.id) }
                }
                .padding(12)
            }
            .onChange(of: run.log.count) { _ in
                if let last = run.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private func logLine(_ line: AgentLogLine) -> some View {
        switch line.kind {
        case .agent:
            Text(LocalizedStringKey(line.text)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .user:
            Text(line.text).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        case .tool:
            Label(line.text, systemImage: "wrench.and.screwdriver")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        case .info:
            Label(line.text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(line.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    // MARK: tasks

    private var taskPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TASKS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if run.tasks.isEmpty {
                Text("The agent will propose tasks once it understands the story.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    if run.phase == .reviewTasks { editableTasks } else { readonlyTasks }
                }
            }
            if run.phase == .reviewTasks {
                Button { run.tasks.append(AgentTask(name: "", description: "")) } label: {
                    Label("Add task", systemImage: "plus")
                }
                Button { Task { await run.approveTasks() } } label: {
                    Label("Create tasks & start coding", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Or reply below to ask for a different breakdown.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// Item runs: what's being worked on + the plan approval gate.
    private var planPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKING ON").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(run.name).font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Button("#\(run.id)") { store.openInTP(run.id) }.buttonStyle(.link)
                if run.usId != 0 {
                    Button("US #\(run.usId)") { store.openInTP(run.usId) }.buttonStyle(.link)
                }
            }
            .font(.caption.monospacedDigit())
            Label(run.workBranch, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if run.phase == .reviewPlan {
                Button { run.approvePlan() } label: {
                    Label("Approve plan & start coding", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Or reply below to change the plan.").font(.caption).foregroundStyle(.secondary)
            } else if [.understanding, .needsAnswer].contains(run.phase) {
                Text("Coding starts only after you approve the plan.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var editableTasks: some View {
        ForEach($run.tasks) { $t in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Task title", text: $t.name).textFieldStyle(.roundedBorder)
                    Button(role: .destructive) { run.tasks.removeAll { $0.id == t.id } } label: {
                        Image(systemName: "minus.circle.fill")
                    }.buttonStyle(.borderless).foregroundStyle(.red)
                }
                TextField("Description", text: $t.description, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.caption).lineLimit(1...4)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var readonlyTasks: some View {
        ForEach(Array(run.tasks.enumerated()), id: \.element.id) { i, t in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: run.currentTask == i ? "arrowtriangle.right.fill"
                      : (run.currentTask ?? -1) > i ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(run.currentTask == i ? .purple : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.callout.weight(run.currentTask == i ? .semibold : .regular))
                    if t.tpId != 0 {
                        Button("#\(t.tpId)") { store.openInTP(t.tpId) }
                            .buttonStyle(.link).font(.caption.monospacedDigit())
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            TextField(run.phase == .needsAnswer ? "Answer the agent's questions…" : "Message the agent…",
                      text: $reply, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...5)
                .onSubmit(send)
                .disabled(!run.canReply)
            Button("Send", action: send).disabled(!run.canReply || reply.isEmpty)

            if let wt = run.worktree {
                Button { NSWorkspace.shared.open(wt) } label: { Image(systemName: "folder") }
                    .help("Open worktree")
            }
            if let url = run.mrURL.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open MR", systemImage: "arrow.up.right.square") }
            }
            if run.canFinish {
                Button { Task { await run.finish() } } label: {
                    Label("Push & open MR", systemImage: "arrow.triangle.pull")
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
            if case .failed = run.phase, run.worktree == nil {
                Button("Back to setup") { run.phase = .setup }
            }
            if !run.isFinished && run.startedAt != nil {
                Button(role: .destructive) { Task { await run.stop() } } label: {
                    Label("Stop & log", systemImage: "stop.fill")
                }
                .tint(.red)
            }
        }
        .padding(10)
    }

    private func send() {
        guard run.canReply else { return }
        run.reply(reply); reply = ""
    }

    private static func hms(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
