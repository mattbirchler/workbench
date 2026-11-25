import BenchKit
import SwiftUI

/// One Claude session (or remote tab) shown in the Overview.
struct OverviewItem: Identifiable {
    let project: Project
    let tab: TabRecord
    let session: TerminalSession?
    /// "Claude 2" when a project has more than one Claude tab.
    let label: String?

    var id: UUID { tab.id }
    var activity: TabActivity { session?.activity ?? .idle }
    var details: AgentDetails? { session?.details }

    /// Needs you first, then work in progress, then finished, then idle.
    var rank: Int {
        switch activity {
        case .waiting: 0
        case .working: 1
        case .remoteWorking: 2
        case .attention: 3
        case .done: 4
        case .idle: 5
        }
    }

    /// How long it's been working or waiting ("6m"), or since it finished ("12m ago").
    func elapsed(now: Date) -> String? {
        let details = self.details
        let since: Date?
        var suffix = ""
        switch activity {
        case .waiting: since = details?.questionAt ?? details?.promptAt
        case .working, .remoteWorking: since = details?.promptAt
        case .done:
            since = details?.stoppedAt
            suffix = " ago"
        default: since = nil
        }
        guard let since else { return nil }
        let seconds = max(0, now.timeIntervalSince(since))
        let text = switch seconds {
        case ..<60: "<1m"
        case ..<3600: "\(Int(seconds / 60))m"
        case ..<86400: "\(Int(seconds / 3600))h"
        default: "\(Int(seconds / 86400))d"
        }
        return text + suffix
    }

    /// What it's working on: Claude's tab title without its spinner, or
    /// your prompt when the title says nothing useful.
    var task: String? {
        let title = (session?.terminalTitle ?? "").drop { !$0.isLetter && !$0.isNumber }
        let cleaned = String(title).trimmingCharacters(in: .whitespaces)
        if !cleaned.isEmpty, cleaned != "Claude Code", cleaned.lowercased() != "claude" { return cleaned }
        return details?.prompt
    }
}

/// Every Claude session across all projects as a grid of cards, sorted so
/// the ones that need you come first. Clicking a card opens its tab.
struct OverviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(RepoMonitors.self) private var monitors
    @Environment(OfflineQueue.self) private var offlineQueue

    static func items(store: AppStore, terminals: TerminalManager) -> [OverviewItem] {
        var items: [OverviewItem] = []
        for project in store.projects {
            let claudeTabs = project.tabs.filter { $0.kind == .agent }
            for tab in project.tabs {
                let session = terminals.existingSession(tab.id)
                let isRemote = session?.remoteHost != nil
                guard tab.kind == .agent || isRemote else { continue }
                let index = claudeTabs.firstIndex { $0.id == tab.id }
                let label = claudeTabs.count > 1 ? index.map { "\(tab.provider?.name ?? Agents.standard.name) \($0 + 1)" } : nil
                items.append(OverviewItem(project: project, tab: tab, session: session, label: label))
            }
        }
        // Stable within a rank: keep sidebar order.
        return items.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
    }

    var body: some View {
        let items = Self.items(store: store, terminals: terminals)
        VStack(alignment: .leading, spacing: 0) {
            header(items)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 16)
            if items.isEmpty {
                EmptyStateScaffold(title: "No Agent Sessions",
                                   message: "Open an agent tab in any project and it shows up here, or use Brain Dump to start work in several projects at once.",
                                   actionTitle: "Brain Dump…", action: { store.startSendTasks() }) {
                    SessionsEmptyIllustration(appeared: $0)
                }
                .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
            } else {
                ScrollView {
                    // Cards start at the top of their row, not centered in it.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(items) { item in
                            OverviewCard(item: item, monitor: monitors.monitor(for: item.project)) {
                                store.selectedProjectID = item.project.id
                                store.selectTab(item.tab.id, in: item.project.id)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TerminalTheme.shared.canvas)
        .navigationTitle("Overview")
        .task {
            // Line counts for projects that aren't selected, which aren't watched live.
            for project in Set(items.map(\.project)) { monitors.monitor(for: project).refresh() }
        }
    }

    private func header(_ items: [OverviewItem]) -> some View {
        let count = { (states: [TabActivity]) in items.filter { states.contains($0.activity) }.count }
        return HStack(spacing: 10) {
            Text("Overview")
                .font(.ui(size: 22, weight: .semibold))
            CountChip(count: count([.waiting]), label: "needs you", color: ActivityBackground.waiting, text: Theme.Status.waiting)
            CountChip(count: count([.working, .remoteWorking]), label: "working", color: ActivityBackground.working, text: Theme.Status.working)
            CountChip(count: count([.done]), label: "done", color: ActivityBackground.done, text: Theme.Status.done)
            CountChip(count: count([.idle, .attention]), label: "idle", color: .secondary, text: .secondary)
            Spacer()
            if !offlineQueue.failed.isEmpty {
                let n = offlineQueue.failed.count
                Button(n == 1 ? "1 queued prompt couldn't start" : "\(n) queued prompts couldn't start") {
                    offlineQueue.showsFailedPrompts = true
                }
                .controlSize(.small)
            }
        }
    }
}

private struct CountChip: View {
    let count: Int
    let label: String
    let color: Color
    let text: Color

    var body: some View {
        if count > 0 {
            Text("\(count) \(label)")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(text)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.16)))
        }
    }
}

private struct OverviewCard: View {
    @Environment(ProjectIcons.self) private var icons
    @Environment(PullRequests.self) private var pullRequests
    @Environment(Deployments.self) private var deployments
    @Environment(PortScanner.self) private var ports
    @Environment(TerminalManager.self) private var terminals
    let item: OverviewItem
    let monitor: RepoMonitor
    let open: () -> Void
    @State private var isHovering = false
    @State private var reply = ""

    private var agentName: String { item.tab.provider?.name ?? Agents.standard.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Clicking the top of the card opens the tab. The rest holds
            // buttons and a text field that need their own clicks.
            VStack(alignment: .leading, spacing: 8) {
                headerRow
                Text(item.task ?? (item.session == nil ? "Not running" : "Waiting for a prompt"))
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundStyle(item.task == nil ? .secondary : .primary)
                    .lineLimit(2)
                    // The whole task where it's cut off; "Open this tab" otherwise.
                    .help(item.task ?? "Open this tab")
                if let prompt = item.details?.prompt, prompt != item.task {
                    Text("You: “\(prompt)”")
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(prompt)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .help("Open this tab")
            // One button to VoiceOver, reading the project and its task.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens this tab")
            activityBox
            // Cards in a row share its height; the footer sits at the bottom
            // so the context meters line up across the row. (A Spacer here
            // would add the stack's spacing to every card.)
            footer
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(isHovering ? 0.12 : 0.05), radius: isHovering ? 6 : 2, y: 1)
                ActivityBackground(activity: item.activity, cornerRadius: 12)
                if item.activity == .idle {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovering ? 0.2 : 0.1))
                }
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Tab", open)
    }

    // MARK: Pieces

    private var headerRow: some View {
        HStack(spacing: 8) {
            ProjectIcon(project: item.project, image: icons.image(for: item.project), size: 20)
            Text(item.project.repoName)
                .font(.ui(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(subtitle)
            Spacer(minLength: 4)
            stateLabel
            TimelineView(.periodic(from: .now, by: 15)) { context in
                if let text = item.elapsed(now: context.date) {
                    Text(text)
                        .font(.ui(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Claude 2 · camera-picker · PR #41"
    private var subtitle: String {
        var parts: [String] = []
        if let label = item.label { parts.append(label) }
        if let branch = monitor.snapshot?.branch { parts.append(branch) }
        if let pr = pullRequests.info[item.project.id] {
            let checks = switch pr.checks {
            case .passing: " ✓"
            case .failing: " ✕"
            case .pending: " …"
            case .none: ""
            }
            parts.append("PR #\(pr.number)\(checks)")
        }
        if let deploy = deployments.info[item.project.id] {
            let label = switch deploy.state {
            case .deploying: "Deploying…"
            case .succeeded: "Deployed ✓"
            case .failed: "Deploy failed ✕"
            }
            parts.append(label)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch item.activity {
        case .waiting:
            StateLabel(symbol: "exclamationmark.circle", text: "NEEDS YOU", color: Theme.Status.waiting)
        case .working:
            StateLabel(symbol: "sparkle", text: "WORKING", color: Theme.Status.working)
        case .remoteWorking:
            StateLabel(symbol: "network", text: "ON \((item.session?.remoteHost ?? "REMOTE").uppercased())", color: Theme.Status.remote)
        case .done:
            StateLabel(symbol: "checkmark.circle", text: "DONE", color: Theme.Status.done)
        case .attention:
            StateLabel(symbol: "bell", text: "ATTENTION", color: ActivityBackground.attention)
        case .idle:
            StateLabel(symbol: nil, text: "IDLE", color: .secondary)
        }
    }

    @ViewBuilder
    private var activityBox: some View {
        let details = item.details
        switch item.activity {
        case .waiting:
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(details?.question ?? "\(agentName) is waiting for you")
                        .font(.ui(size: 12))
                    if let action = details?.action {
                        Text(action)
                            .font(.ui(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(action)
                    }
                }
                Spacer(minLength: 0)
                if details?.isAllowOrDeny == true {
                    // Return and Escape in that tab: the same as choosing
                    // "Yes" or "No" in Claude's prompt. Allow first, in
                    // amber, as in the sidebar and the chat.
                    Button("Allow") {
                        if !terminals.answerPermission(allow: true, tabID: item.tab.id) { NSSound.beep() }
                    }
                    .buttonStyle(AnswerButtonStyle(prominent: true, large: true))
                    .help("Answer Yes, once. \(agentName) keeps asking next time.")
                    Button("Deny") {
                        if !terminals.answerPermission(allow: false, tabID: item.tab.id) { NSSound.beep() }
                    }
                    .buttonStyle(AnswerButtonStyle(prominent: false, large: true))
                    .help("Answer No. \(agentName) stops and waits for you to say what to do instead.")
                } else {
                    Button("Open Tab", action: open)
                        .buttonStyle(.prominent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        case .working:
            if let action = details?.plainAction ?? details?.action {
                monospacedBox("› \(action)")
            }
        case .remoteWorking:
            Text("Working on \(item.session?.remoteHost ?? "another machine"). Workbench sees its progress, not its prompts.")
                .font(.ui(size: 12))
                .foregroundStyle(.secondary)
        case .done:
            if let summary = details?.summary {
                Text(summary)
                    .font(.ui(size: 12))
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            }
            if item.session?.claudeState == .done {
                replyField
            }
        case .attention, .idle:
            if item.session == nil {
                Text("Open it to pick the conversation back up.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Send the next prompt without leaving the Overview.
    private var replyField: some View {
        HStack(spacing: 6) {
            TextField("Reply to \(agentName)…", text: $reply)
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 12))
                .onSubmit(sendReply)
            Button(action: sendReply) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderless)
            .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Send to \(agentName) (Return)")
        }
    }

    private func sendReply() {
        if terminals.reply(reply, tabID: item.tab.id) {
            reply = ""
        } else {
            NSSound.beep()
        }
    }

    private func monospacedBox(_ text: String) -> some View {
        Text(text)
            .font(.ui(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .help(text)
    }

    @ViewBuilder
    private var footer: some View {
        let files = (monitor.snapshot?.staged ?? []) + (monitor.snapshot?.unstaged ?? [])
        let added = files.reduce(0) { $0 + $1.additions }
        let removed = files.reduce(0) { $0 + $1.deletions }
        let projectPorts = ports.ports(forTab: item.tab.id)
        let usage = item.session?.usage
        if added + removed > 0 || !projectPorts.isEmpty || usage != nil {
            HStack(spacing: 10) {
                if added > 0 { Text("+\(added)").foregroundStyle(Theme.Status.done) }
                if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.Status.failed) }
                ForEach(projectPorts) { port in
                    Text(verbatim: "localhost:\(port.port)").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let usage { ContextMeter(usage: usage) }
            }
            .font(.ui(size: 12, design: .monospaced))
        }
    }
}

/// A small bar for how full a session's context window is, like
/// "▰▰▱▱ 84k / 200k". Turns orange, then red, as it nears the limit,
/// when a /compact or a fresh session will keep Claude sharp.
struct ContextMeter: View {
    let usage: ContextUsage

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(3, 48 * usage.fraction))
            }
            .frame(width: 48, height: 5)
            Text("\(ContextUsage.short(usage.contextTokens)) / \(ContextUsage.short(usage.window))")
                .font(.ui(size: 11).monospacedDigit())
                .foregroundStyle(usage.fraction >= 0.7 ? color : .secondary)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(Int(usage.fraction * 100)) percent full")
    }

    private var color: Color {
        switch usage.fraction {
        case 0.85...: Theme.Status.failed
        case 0.7...: Theme.Status.waiting
        default: .secondary
        }
    }

    private var help: String {
        var lines = ["Context: \(usage.contextTokens.formatted()) of \(usage.window.formatted()) tokens (\(Int(usage.fraction * 100))%)"]
        lines.append("\(usage.outputTokens.formatted()) tokens written this session")
        if let model = usage.modelName { lines.append(model) }
        if usage.fraction >= 0.7 { lines.append("Getting full: /compact or a new session will help") }
        return lines.joined(separator: "\n")
    }
}

private struct StateLabel: View {
    let symbol: String?
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.ui(size: 10, weight: .bold))
            }
            Text(text)
                .font(.ui(size: 11, weight: .bold))
                .kerning(0.4)
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

/// The "Overview" row at the top of the sidebar.
struct OverviewRow: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @State private var isHovering = false

    var body: some View {
        let items = OverviewView.items(store: store, terminals: terminals)
        let waiting = items.filter { $0.activity == .waiting }.count
        let working = items.filter { $0.activity == .working || $0.activity == .remoteWorking }.count
        let selected = store.showsOverview
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.ui(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
            Text("Overview")
                .font(.ui(size: 13, weight: selected ? .semibold : .medium))
            Spacer(minLength: 0)
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.ui(size: 11, weight: .bold).monospacedDigit())
                    // The waiting color is a dark amber in light mode and a
                    // light one in dark mode, so the count flips with it.
                    .foregroundStyle(Color(light: .white, dark: .black))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.Status.waiting))
                    .help("\(waiting) waiting for you")
            } else if working > 0 {
                Text("\(working)")
                    .font(.ui(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("\(working) working")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(isHovering ? 0.05 : 0))
                .shadow(color: .black.opacity(selected ? 0.14 : 0), radius: 3, y: 1)
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.showsOverview = true }
        .onHover { isHovering = $0 }
        .help("Every agent session at a glance")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
