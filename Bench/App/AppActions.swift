import AppKit
import BenchKit
import SwiftUI

/// What the menu bar and the ⌘K command bar both do, kept in one place so
/// the two can't drift apart.
@MainActor
struct AppActions {
    let store: AppStore
    let terminals: TerminalManager

    func newTab(_ kind: TabKind) {
        // A project on another Mac: its view starts the tab there.
        if store.selectedRemote != nil {
            store.pendingRemoteAction = kind == .shell ? .shell : .claudeTab
            return
        }
        guard let id = store.selectedProjectID else { return }
        store.addTab(kind, to: id)
    }

    /// ⌘T and the + button: the New Tab page, where every kind of tab is
    /// a click away. From that page it starts Claude, so ⌘T twice is
    /// still a new Claude tab. Another Mac's project has no such page,
    /// and starts Claude there as before.
    func newTab() {
        guard store.selectedRemote == nil, let project = store.selectedProject else {
            newTab(.agent)
            return
        }
        if store.showsStartPage(project) {
            store.addTab(.agent, to: project.id)
        } else {
            store.openStartPage(project.id)
        }
    }

    /// Closes the current tab. Asks first if something (like Claude) is
    /// still running in it.
    func closeTab() {
        // Holding ⌘W a moment too long closes one tab, not a row of them.
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        // What's in front closes first: Settings or the Overview, then the
        // New Tab page. The tab underneath isn't the one you're looking at.
        if store.settingsSection != nil {
            store.settingsSection = nil
            return
        }
        if store.showsOverview {
            store.showsOverview = false
            return
        }
        guard store.selectedRemote == nil, let project = store.selectedProject else { return }
        if store.showsStartPage(project) {
            store.closeStartPage(project.id)
            return
        }
        guard let tab = project.selectedTab else { return }
        guard FileDrafts.shared.confirmLosing([project.fileURL(of: tab)].compactMap { $0 }) else { return }
        guard terminals.confirmClose(tab) else { return }
        store.closeTab(tab.id, in: project.id)
    }

    /// The file in the current tab, if it's a file tab in front.
    private var currentFile: URL? {
        guard store.settingsSection == nil, !store.showsOverview, store.selectedRemote == nil,
              let project = store.selectedProject, !store.showsStartPage(project),
              let tab = project.selectedTab else { return nil }
        return project.fileURL(of: tab)
    }

    /// The file tab in front in a project on another Mac, if that's
    /// what's showing.
    private var currentRemoteFile: RemoteFileDrafts.File? {
        guard !store.showsPage, let remote = store.selectedRemote, let macs = RemoteFileDrafts.shared.macs,
              case .file(let path) = macs.openTabs[RemoteMacs.key(host: remote.host, projectID: remote.projectID)]
        else { return nil }
        return .init(host: remote.host, projectID: remote.projectID, path: path)
    }

    /// Whether ⌘S has anything to write.
    var canSaveFile: Bool {
        if let currentRemoteFile { return RemoteFileDrafts.shared.isEdited(currentRemoteFile) }
        return currentFile.map(FileDrafts.shared.isEdited) ?? false
    }

    /// Saves the edits in the current file tab.
    func saveFile() {
        if let currentRemoteFile {
            RemoteFileDrafts.shared.save(currentRemoteFile)
            return
        }
        guard let currentFile else { return }
        FileDrafts.shared.saveOrExplain(currentFile)
    }

    /// Flips the current Claude tab between its terminal and the chat.
    func toggleChat() {
        guard let project = store.selectedProject, let tab = project.selectedTab, tab.kind == .agent,
              terminals.existingSession(tab.id)?.remoteHost == nil else { return }
        // From the keyboard, so it changes at once: no fade to wait out.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            store.setShowsChat(tab.showsChat != true, tab: tab.id, in: project.id)
        }
    }

    var canToggleChat: Bool { store.selectedProject?.selectedTab?.kind == .agent }

    /// The Claude tab on screen that's working: the current tab, or the
    /// other half of its split.
    private var workingClaudeTab: UUID? {
        guard store.selectedRemote == nil, !store.showsPage, let project = store.selectedProject,
              let tab = project.selectedTab else { return nil }
        return [tab.id, project.partner(of: tab.id)].compactMap { $0 }.first { id in
            terminals.existingSession(id).map { $0.isAgent && $0.claudeState == .working } ?? false
        }
    }

    /// Stops Claude in the tab on screen, the way Escape does in its terminal.
    func stopClaude() {
        guard let tab = workingClaudeTab else { return }
        _ = terminals.interrupt(tabID: tab)
    }

    var canStopClaude: Bool { workingClaudeTab != nil }

    /// The browser tab you're looking at: the current tab, which is the
    /// focused side when it's split.
    var browserTab: TabRecord? {
        guard store.selectedRemote == nil, !store.showsPage, let project = store.selectedProject,
              !store.showsStartPage(project), let tab = project.selectedTab, tab.kind == .preview else { return nil }
        return tab
    }

    /// A browser tab on screen: the current tab, or the other half of
    /// its split.
    private var browserTabOnScreen: TabRecord? {
        if let tab = browserTab { return tab }
        guard store.selectedRemote == nil, !store.showsPage, let project = store.selectedProject,
              !store.showsStartPage(project), let tab = project.selectedTab,
              let partner = project.partner(of: tab.id) else { return nil }
        return project.tabs.first { $0.id == partner && $0.kind == .preview }
    }

    /// Browser tabs are for projects on this Mac.
    var canOpenBrowserTab: Bool { store.selectedRemote == nil && store.selectedProjectID != nil }

    /// An empty browser tab, with the cursor in its address field.
    func newBrowserTab() {
        guard canOpenBrowserTab, let id = store.selectedProjectID else { return }
        store.openBrowserTab(in: id)
    }

    /// Puts the cursor in the address field of the browser tab on screen.
    /// With none on screen, opens a new one.
    func openLocation(in previews: PreviewPages) {
        guard let tab = browserTabOnScreen, let project = store.selectedProject else {
            newBrowserTab()
            return
        }
        if project.selectedTab?.id != tab.id { store.selectTab(tab.id, in: project.id) }
        previews.focusAddress(of: tab.id)
    }

    var canCopyPreviewURL: Bool { browserTab != nil }

    /// Copies the address of the page on screen, where it is now rather
    /// than where the tab started.
    func copyPreviewURL(from previews: PreviewPages) {
        guard let tab = browserTab, let url = previews.currentURL(for: tab.id) ?? tab.pageURL ?? tab.previewURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toasts.shared.show("Address Copied", symbol: "link")
    }

    /// The pull request for the project on screen, here or on another Mac.
    func pullRequestURL(in pullRequests: PullRequests, macs: RemoteMacs) -> URL? {
        if let remote = store.selectedRemote {
            return macs.client(for: remote.host)?.snapshot?.projects.first { $0.id == remote.projectID }?.pullRequest?.url
        }
        return store.selectedProjectID.flatMap { pullRequests.info[$0]?.url }
    }

    /// The menu and ⌘K title, with the number like the right-click menu's.
    func pullRequestTitle(in pullRequests: PullRequests, macs: RemoteMacs) -> String {
        let number: Int?
        if let remote = store.selectedRemote {
            number = macs.client(for: remote.host)?.snapshot?.projects.first { $0.id == remote.projectID }?.pullRequest?.number
        } else {
            number = store.selectedProjectID.flatMap { pullRequests.info[$0]?.number }
        }
        return number.map { "Open Pull Request #\($0)" } ?? "Open Pull Request"
    }

    /// Opens the project's pull request in the browser, like the sidebar's
    /// Open Pull Request.
    func openPullRequest(in pullRequests: PullRequests, macs: RemoteMacs) {
        guard let url = pullRequestURL(in: pullRequests, macs: macs) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens a new shell beside the current tab.
    func split(_ axis: TabSplit.Axis) {
        guard canSplit, let project = store.selectedProject, let tab = project.selectedTab else { return }
        store.splitTab(tab.id, in: project.id, axis: axis)
    }

    var canSplit: Bool { store.selectedRemote == nil && !store.showsPage && store.canSplitSelectedTab }

    /// The current tab's split, if it has one and it's on screen.
    private var currentSplit: (project: Project, tab: TabRecord)? {
        guard store.selectedRemote == nil, !store.showsPage, let project = store.selectedProject,
              !store.showsStartPage(project), let tab = project.selectedTab, project.split(of: tab.id) != nil else { return nil }
        return (project, tab)
    }

    var isSplit: Bool { currentSplit != nil }

    func unsplit() {
        guard let current = currentSplit else { return }
        store.unsplit(current.tab.id, in: current.project.id)
    }

    func switchPane() {
        guard isSplit else { return }
        store.switchPane()
    }

    func openSettings() {
        store.settingsSection = store.settingsSection ?? .general
    }

    /// With another Mac's project on screen, the tasks go to that Mac.
    func startSendTasks() { store.startSendTasks(remoteHost: store.selectedRemote?.host) }

    func showOverview() { store.showsOverview = true }

    func showUsage() { store.showsUsage = true }

    func showPastSessions() {
        store.showsOverview = false
        store.showsUsage = false
        store.showsHistory = true
    }

    /// Goes to the next Claude session that's waiting for you, then ones that
    /// finished or rang while you were away. Repeating it walks the queue.
    func jumpToNextNeedingYou() {
        let queue = OverviewView.items(store: store, terminals: terminals)
            .filter { [.waiting, .attention, .done].contains($0.activity) }  // already waiting-first
        guard !queue.isEmpty else {
            NSSound.beep()
            return
        }
        let current = store.showsPage ? nil : store.selectedProject?.selectedTab?.id
        let next = queue.firstIndex { $0.tab.id == current }.map { queue[($0 + 1) % queue.count] } ?? queue[0]
        store.selectedProjectID = next.project.id
        store.selectTab(next.tab.id, in: next.project.id)
    }

    /// The actions the command bar lists, in menu order. Ones the menu
    /// would disable right now (nothing selected) are left out.
    func commandBarActions(pullRequests: PullRequests, macs: RemoteMacs) -> [CommandBarAction] {
        let hasProject = store.hasProjectOnScreen
        var actions: [CommandBarAction] = []
        if hasProject {
            actions.append(CommandBarAction(id: "new-tab", title: "New Tab", symbol: "plus.square",
                                            shortcut: "⌘T", keywords: ["page", "start", "recent"]) { newTab() })
            actions.append(CommandBarAction(id: "new-claude-tab", title: "New \(Agents.standard.name) Tab", symbol: "sparkle",
                                            keywords: ["session", "start"]) { newTab(.agent) })
            actions.append(CommandBarAction(id: "new-shell-tab", title: "New Shell Tab", symbol: "terminal",
                                            shortcut: "⇧⌘T", keywords: ["terminal"]) { newTab(.shell) })
            if canOpenBrowserTab {
                actions.append(CommandBarAction(id: "new-browser-tab", title: "New Browser Tab", symbol: "globe",
                                                shortcut: "⌃⌘T", keywords: ["web", "page", "site", "address", "url", "search"]) { newBrowserTab() })
            }
            if canSplit {
                actions.append(CommandBarAction(id: "split-right", title: "Split Right", symbol: "rectangle.split.2x1",
                                                shortcut: "⌘D", keywords: ["pane", "side by side", "shell"]) { split(.sideBySide) })
                actions.append(CommandBarAction(id: "split-down", title: "Split Down", symbol: "rectangle.split.1x2",
                                                shortcut: "⇧⌘D", keywords: ["pane", "stacked", "below", "shell"]) { split(.stacked) })
            }
            if isSplit {
                actions.append(CommandBarAction(id: "unsplit", title: "Unsplit", symbol: "rectangle",
                                                keywords: ["pane", "split", "join"]) { unsplit() })
            }
            actions.append(CommandBarAction(id: "new-agent", title: "New Agent on a Branch…", symbol: "arrow.triangle.branch",
                                            shortcut: "⇧⌘N", keywords: ["worktree", "branch"]) { store.startNewAgent() })
            if let url = pullRequestURL(in: pullRequests, macs: macs) {
                actions.append(CommandBarAction(id: "open-pull-request", title: pullRequestTitle(in: pullRequests, macs: macs), symbol: "arrow.triangle.pull",
                                                shortcut: "⇧⌘G", keywords: ["pr", "github", "browser", "review"]) { NSWorkspace.shared.open(url) })
            }
        }
        actions.append(CommandBarAction(id: "send-tasks", title: "Brain Dump…",
                                        symbol: "brain", shortcut: "⌥⌘N",
                                        keywords: ["send tasks", "agents", "worktree", "split", "several projects"]) { startSendTasks() })
        actions.append(CommandBarAction(id: "add-project", title: "Add Project…", symbol: "folder.badge.plus",
                                        shortcut: "⌘O", keywords: ["open", "folder"]) { ProjectPicker.present(store: store) })
        actions.append(CommandBarAction(id: "overview", title: "Overview", symbol: "square.grid.2x2",
                                        keywords: ["sessions", "dashboard"]) { showOverview() })
        actions.append(CommandBarAction(id: "next-needing-you", title: "Next Session Needing You", symbol: "bell",
                                        shortcut: "⌘J", keywords: ["waiting", "attention"]) { jumpToNextNeedingYou() })
        if store.selectedProjectID != nil {
            actions.append(CommandBarAction(id: "past-sessions", title: "Past Sessions", symbol: "clock.arrow.circlepath",
                                            shortcut: "⌘Y", keywords: ["history", "resume"]) { showPastSessions() })
        }
        actions.append(CommandBarAction(id: "changes", title: store.showsChanges ? "Hide Changes" : "Show Changes",
                                        symbol: "sidebar.right", shortcut: "⌥⌘0", keywords: ["diff", "panel"]) { store.showsChanges.toggle() })
        actions.append(CommandBarAction(id: "usage", title: "Usage and Costs", symbol: "chart.bar",
                                        shortcut: "⇧⌘U", keywords: ["tokens", "spend"]) { showUsage() })
        actions.append(CommandBarAction(id: "settings", title: "Settings…", symbol: "gearshape",
                                        shortcut: "⌘,", keywords: ["preferences"]) { openSettings() })
        return actions
    }
}

/// One action row in the command bar.
struct CommandBarAction: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var shortcut: String?
    /// Other words it should match on, besides its title.
    var keywords: [String] = []
    var run: @MainActor () -> Void
}
