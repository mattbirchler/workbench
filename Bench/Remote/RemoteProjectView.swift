import BenchKit
import SwiftUI

/// The center pane for a project on another Mac: its Claude sessions as
/// tabs, a shell logged in over ssh, and diffs from its changes panel.
struct RemoteProjectView: View {
    @Environment(AppStore.self) private var store
    @Environment(RemoteMacs.self) private var macs
    let host: String
    let projectID: UUID
    @State private var showsHistory = false
    @State private var showsNewAgent = false

    private var client: CompanionClient? { macs.client(for: host) }
    private var project: CompanionProject? { client?.snapshot?.projects.first { $0.id == projectID } }
    private var key: String { RemoteMacs.key(host: host, projectID: projectID) }

    private var tabs: [RemoteTab] {
        var tabs = (project?.sessions ?? []).map { RemoteTab.session($0.id) }
        if macs.shells[key] != nil { tabs.append(.shell) }
        tabs += (macs.diffTabs[key] ?? []).map { .diff($0) }
        tabs += (macs.fileTabs[key] ?? []).map { .file($0) }
        return tabs
    }

    private var selected: RemoteTab? {
        if let open = macs.openTabs[key], tabs.contains(open) { return open }
        return tabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let client, client.status != .connected {
                ConnectionStrip(client: client, name: macs.name(for: host), problem: macs.problem(for: host))
                    .padding(.bottom, TerminalCard.margin)
            }
            // Set into the window as a rounded card, like this Mac's tabs.
            VStack(spacing: 0) {
                tabRow
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .canvasCard()
            .padding([.horizontal, .bottom], TerminalCard.margin)
        }
        // The card runs up to the top of the window, its tab row in line
        // with the traffic lights, so there's no band over it.
        .padding(.top, CardBand.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("\(project?.name ?? "Project") on \(macs.name(for: host))")
        .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
            RemotePastSessionsPopover(host: host, projectID: projectID) { showsHistory = false }
        }
        .sheet(isPresented: $showsNewAgent) {
            RemoteNewAgentSheet(host: host, projectID: projectID)
        }
        // A menu item or shortcut, possibly sent before this view existed.
        .onAppear(perform: runPendingAction)
        .onChange(of: store.pendingRemoteAction) { runPendingAction() }
        .onChange(of: client?.started?.sessionID) { _, _ in
            // A tab we asked for is open: show it, even in a new worktree.
            guard let client, let started = client.started else { return }
            macs.openTabs[RemoteMacs.key(host: host, projectID: started.projectID)] = .session(started.sessionID)
            if started.projectID != projectID {
                store.selectedRemote = RemoteSelection(host: host, projectID: started.projectID)
            }
            client.clearStarted()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let project {
            switch selected {
            case .session(let sessionID):
                ChatSessionView(source: RemoteChatSource(client: macs.client(for: host), projectID: projectID, sessionID: sessionID))
                    .id(sessionID)
            case .shell:
                if let shell = macs.shells[key] {
                    TerminalHost(session: shell)
                }
            case .diff(let change):
                RemoteDiffView(host: host, projectID: projectID, change: change)
                    .id(change)
            case .file(let path):
                RemoteFileView(host: host, projectID: projectID, path: path)
                    .id(path)
            case nil:
                start(project)
            }
        } else {
            ContentUnavailableView("Project Closed", systemImage: "folder",
                                   description: Text("It's no longer in Workbench's sidebar on \(macs.name(for: host))."))
        }
    }

    /// No tabs yet: start Claude there, or pick a past conversation back up.
    private func start(_ project: CompanionProject) -> some View {
        typealias Start = ProjectStartView<CompanionProjectIcon>
        let recents = client?.pastSessions[projectID].map { sessions in
            sessions.prefix(4).map { session in
                Start.Recent(id: session.id, title: session.title ?? session.firstPrompt ?? "Untitled",
                             detail: session.title == nil ? nil : (session.lastPrompt ?? session.firstPrompt),
                             modified: session.modified, isOpen: session.openTabID != nil)
            }
        }
        return Start(
            icon: CompanionProjectIcon(project: project, icon: client?.icons[project.parentID ?? project.id], size: 76, outlined: false),
            name: project.name,
            branch: project.branch,
            place: "on \(macs.name(for: host))",
            start: { client?.newClaudeTab(projectID: projectID, prompt: nil) },
            actions: [
                .init(title: "Open Shell on \(macs.name(for: host))", symbol: "network") { _ = macs.shell(host: host, project: project) },
                .init(title: "New Agent on a Branch…", symbol: "arrow.triangle.branch") { showsNewAgent = true },
            ],
            recents: recents,
            resume: { client?.resume(projectID: projectID, sessionID: $0.id) },
            tint: client?.icons[project.parentID ?? project.id].map(IconTint.color(ofIcon:))
                ?? IconTint.tileColor(for: project.repoName))
        .id(projectID)
        .task(id: projectID) {
            if client?.status == .connected { client?.loadPastSessions(projectID: projectID) }
        }
    }

    /// The tabs, at the top of the card.
    private var tabRow: some View {
        TabRow {
            CardBandLeading()
        } tabs: {
            ForEach(tabs, id: \.self) { tab in
                RemoteTabButton(tab: tab, session: session(for: tab), isSelected: tab == selected,
                                closesSessions: client?.canManageAgents == true, isEdited: isEdited(tab)) {
                    macs.openTabs[key] = tab
                } close: {
                    close(tab)
                }
                .transition(TabTransition())
            }
        } trailing: {
            remoteMenu
        } end: {
            if let running = runningShortcuts.first {
                // A running shortcut keeps a way to its ports and Stop.
                RemoteShortcutButton(shortcut: running, host: host, macName: macs.name(for: host)) {
                    client?.runShortcut(projectID: projectID, shortcutID: running.id)
                } stop: {
                    client?.stopShortcut(projectID: projectID, shortcutID: running.id)
                }
            }
            CardBandTrailing()
        }
        .animation(Theme.Motion.tab, value: tabs)
    }

    private var runningShortcuts: [CompanionShortcut] {
        guard client?.canRunShortcuts == true else { return [] }
        return (project?.shortcuts ?? []).filter(\.isRunning)
    }

    /// ＋ for a project on another Mac. A click opens a new Claude tab there;
    /// the arrow lists a shell, an agent on a branch, its shortcuts and past
    /// sessions. It looks like this Mac's ＋ and lists the same items in the
    /// same order (`NewTabMenu`).
    private var remoteMenu: some View {
        Menu {
            Button("New Agent Tab") { client?.newClaudeTab(projectID: projectID, prompt: nil) }
            Button("Open Shell on \(macs.name(for: host))") {
                if let project { _ = macs.shell(host: host, project: project) }
            }
            Button("New Agent on a Branch…") { showsNewAgent = true }
            if client?.canRunShortcuts == true, let shortcuts = project?.shortcuts, !shortcuts.isEmpty {
                Section("Shortcuts on \(macs.name(for: host))") {
                    ForEach(shortcuts) { shortcut in
                        if shortcut.isRunning {
                            Button {
                                client?.stopShortcut(projectID: projectID, shortcutID: shortcut.id)
                            } label: {
                                Label("Stop \(shortcut.name)", systemImage: "stop.fill")
                            }
                        } else {
                            Button {
                                client?.runShortcut(projectID: projectID, shortcutID: shortcut.id)
                            } label: {
                                Label(shortcut.name, systemImage: shortcut.symbol)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Past Sessions…") { showsHistory = true }
        } label: {
            Image(systemName: "plus")
                .font(.ui(size: 12, weight: .medium))
        } primaryAction: {
            client?.newClaudeTab(projectID: projectID, prompt: nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .frame(height: BarButtonMetrics.height)
        .accessibilityLabel("New Agent Tab")
        .help("New Agent Tab on \(macs.name(for: host)). Use the arrow for a shell, an agent on a branch, shortcuts and past sessions")
    }

    private func runPendingAction() {
        guard let action = store.pendingRemoteAction else { return }
        store.pendingRemoteAction = nil
        switch action {
        case .claudeTab: client?.newClaudeTab(projectID: projectID, prompt: nil)
        case .shell: if let project { _ = macs.shell(host: host, project: project) }
        case .newAgent: showsNewAgent = true
        }
    }

    /// Whether a file tab has changes that haven't been saved to the other Mac.
    private func isEdited(_ tab: RemoteTab) -> Bool {
        guard case .file(let path) = tab else { return false }
        return RemoteFileDrafts.shared.isEdited(.init(host: host, projectID: projectID, path: path))
    }

    private func session(for tab: RemoteTab) -> CompanionSession? {
        guard case .session(let id) = tab else { return nil }
        return project?.sessions.first { $0.id == id }
    }

    private func close(_ tab: RemoteTab) {
        switch tab {
        case .shell: macs.closeShell(host: host, projectID: projectID)
        case .diff(let change): macs.closeDiff(host: host, projectID: projectID, change: change)
        case .file(let path):
            guard RemoteFileDrafts.shared.confirmLosing([.init(host: host, projectID: projectID, path: path)]) else { return }
            macs.closeFile(host: host, projectID: projectID, path: path)
        case .session(let id):
            // Same rule as this Mac's tabs: ask only when Claude is busy.
            if let session = session(for: tab), session.activity != .idle {
                let alert = NSAlert()
                alert.messageText = "Close this \(session.agentTitle) tab on \(macs.name(for: host))?"
                alert.informativeText = "\(session.agentTitle) is still running in it there. Closing the tab ends that session; you can resume it later from Past Sessions."
                alert.addButton(withTitle: "Close Tab").hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            client?.closeSession(projectID: projectID, sessionID: id)
        }
    }
}

/// Why the remote Mac isn't answering, above the tabs.
private struct ConnectionStrip: View {
    let client: CompanionClient
    let name: String
    /// From `RemoteMacs.problem(for:)`.
    let problem: String?

    var body: some View {
        HStack(spacing: 8) {
            if client.status == .connecting {
                ProgressView().controlSize(.small)
                Text(problem.map { "Trying again. \($0)" } ?? "Connecting to \(name)…")
                    .lineLimit(2)
                    .help(problem ?? "")
            } else {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
                Text(problem ?? "Not connected to \(name).")
                    .lineLimit(2)
                    .help(problem ?? "")
                Button("Reconnect") { client.retry() }
                    .buttonStyle(.link)
            }
            Spacer()
            if let last = client.lastUpdate {
                Text("Showing what Workbench reported \(last, format: .relative(presentation: .named)).")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.ui(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ActivityBackground.waiting.opacity(0.1))
    }
}

private struct RemoteTabButton: View {
    let tab: RemoteTab
    let session: CompanionSession?
    let isSelected: Bool
    /// Whether that Mac lets us close its Claude tabs.
    var closesSessions = false
    var isEdited = false
    let select: () -> Void
    let close: () -> Void

    private var canClose: Bool {
        if case .session = tab { return closesSessions }
        return true
    }

    var body: some View {
        // Remote tabs don't split, so nothing keeps the close button showing.
        TabChip(symbol: symbol, tint: tint, title: title, isSelected: isSelected,
                showsClose: false, canClose: canClose, activity: session?.activity.tabActivity ?? .idle,
                select: select, close: close) {
            if isEdited {
                Circle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
        }
    }

    private var symbol: String {
        switch tab {
        case .session: "sparkle"
        case .shell: "network"
        case .diff(let change): change.isImage ? "photo" : "plus.forwardslash.minus"
        case .file: "doc.text"
        }
    }

    private var tint: Color {
        switch tab {
        case .session: .orange
        case .shell: ActivityBackground.remote
        case .diff: .blue
        case .file: .indigo
        }
    }

    private var title: String {
        switch tab {
        case .session: session?.title ?? "Agent"
        case .shell: "ssh"
        case .diff(let change): change.fileName
        case .file(let path): (path as NSString).lastPathComponent
        }
    }
}

/// A shortcut on the other Mac, like its dev server. Runs it there; once
/// it's running, a menu opens its ports or stops it.
private struct RemoteShortcutButton: View {
    let shortcut: CompanionShortcut
    let host: String
    let macName: String
    let run: () -> Void
    let stop: () -> Void

    var body: some View {
        let isDev = shortcut.id == "dev"
        let tint: Color = isDev ? .green : shortcut.command.hasPrefix("ssh ") ? ActivityBackground.remote : .secondary
        if shortcut.isRunning {
            Menu {
                ForEach(shortcut.ports, id: \.self) { port in
                    Button("Open \(host):\(String(port))") {
                        if let url = URL(string: "http://\(host):\(port)") { NSWorkspace.shared.open(url) }
                    }
                }
                if !shortcut.ports.isEmpty { Divider() }
                Button("Stop") { stop() }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Theme.Status.done).frame(width: 6, height: 6)
                    Text(shortcut.name)
                        .font(.ui(size: 11, weight: .medium, design: isDev ? .monospaced : .default))
                    if let port = shortcut.ports.first {
                        Text(":\(String(port))")
                            .font(.ui(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.Status.fill(Theme.Status.done)))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Running on \(macName)")
        } else {
            BarButton(symbol: shortcut.symbol, title: shortcut.name, tint: tint, monospaced: isDev, action: run)
                .help("Run \(shortcut.command) on \(macName)")
        }
    }
}
