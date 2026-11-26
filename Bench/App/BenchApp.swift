import BenchKit
import SwiftUI

@main
enum BenchMain {
    static func main() {
        // See TestHost: the test host must not act like the app.
        if TestHost.isRunning { TestHostApp.main() } else { BenchApp.main() }
    }
}

struct BenchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store: AppStore
    @State private var terminals: TerminalManager
    @State private var monitors: RepoMonitors
    @State private var files: FileListMonitors
    @State private var updater: Updater
    @State private var shortcuts: TabShortcuts
    @State private var claudeActions = ClaudeActions()
    @State private var icons: ProjectIcons
    @State private var ports: PortScanner
    @State private var reviewComments = ReviewComments()
    @State private var previews = PreviewPages()
    @State private var pullRequests: PullRequests
    @State private var deployments: Deployments
    @State private var cleaner: WorktreeCleaner
    @State private var worktreeScanner: WorktreeScanner
    @State private var companion: Companion
    @State private var requests: ProjectRequests
    @State private var feedbackAgent: FeedbackAgent
    @State private var offlineQueue: OfflineQueue
    @State private var remoteMacs: RemoteMacs
    @State private var whatsNew = WhatsNew()

    init() {
        // Before anything reads its files or settings: an import staged in
        // Settings > General, put in place now so the running app couldn't
        // save over it.
        SettingsTransfer.applyPending()
        // First, so a crash anywhere in launch is reported next time.
        Analytics.start()
        // Before any window or terminal exists, so they start in the right look.
        AppAppearance.shared.apply()
        #if DEBUG
        // Crashes here, to check crash reports reach PostHog: launch with
        // BENCH_CRASH=1 BENCH_ANALYTICS=1, then again without BENCH_CRASH.
        if ProcessInfo.processInfo.environment["BENCH_CRASH"] != nil {
            fatalError("BENCH_CRASH test crash")
        }
        #endif
        let info = Bundle.main.infoDictionary
        ChatTiming.start(file: BenchPaths.support.appendingPathComponent("chat-timing.log"),
                         version: "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        #if DEBUG
        // Writes every part of the setup to a settings file, then quits.
        if let path = ProcessInfo.processInfo.environment["BENCH_EXPORT_SETTINGS"] {
            let data = try? SettingsTransfer.export(Set(SettingsTransfer.Section.allCases))
            try? data?.write(to: URL(fileURLWithPath: path))
            exit(data == nil ? 1 : 0)
        }
        // Prints the recap for a transcript's latest turn, then quits.
        if let path = ProcessInfo.processInfo.environment["BENCH_RECAP"] {
            let turn = Recaps.turn(transcript: path)
            print(turn?.text ?? "No turn found")
            print("\nUsed tools: \(turn?.usedTools ?? false)\nRecap: \(turn.flatMap { Recaps.write($0.text, profile: .main()) } ?? "none")")
            exit(0)
        }
        // Prints what Usage counts by model, then quits.
        if ProcessInfo.processInfo.environment["BENCH_USAGE_REPORT"] != nil {
            UsageLedger.printReport()
            exit(0)
        }
        // Draws the Usage page to PNGs in this folder, light and dark, then quits.
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_USAGE"] {
            UsageView.renderForTesting(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_EMPTY_STATES"] {
            EmptyStatesPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_SENDTASKS_SHEET"] {
            SendTasksSheetPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_REMOTE"],
           let file = ProcessInfo.processInfo.environment["BENCH_RENDER_REMOTE_SNAPSHOT"] {
            RemoteRowsPreview.render(to: URL(fileURLWithPath: folder), snapshotFile: URL(fileURLWithPath: file))
            exit(0)
        }
        // BENCH_DARK=1 starts a test copy in dark mode, for screenshots.
        if ProcessInfo.processInfo.environment["BENCH_DARK"] != nil {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_CHANGES"] {
            ChangesListPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_CODE"],
           let file = ProcessInfo.processInfo.environment["BENCH_RENDER_CODE_FILE"] {
            SyntaxColorsPreview.render(to: URL(fileURLWithPath: folder), file: URL(fileURLWithPath: file))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_REVIEW"],
           let repo = ProcessInfo.processInfo.environment["BENCH_RENDER_REVIEW_REPO"] {
            ReviewPreview.render(to: URL(fileURLWithPath: folder), repo: repo)
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_TABS"] {
            TabStripPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_DICTATION"] {
            DictationPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_COMPOSER"] {
            ComposerPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let seconds = ProcessInfo.processInfo.environment["BENCH_COMPOSER_RIG"].flatMap(Double.init) {
            ComposerRig.run(every: seconds)
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_WORKLOG"] {
            WorkLogPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_STEPS"] {
            StepsBarPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_ROWS"] {
            LocalRowsPreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_THEME"] {
            ThemePreview.render(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        if let folder = ProcessInfo.processInfo.environment["BENCH_RENDER_ACTIVITY_THEMES"] {
            ThemePreview.renderActivity(to: URL(fileURLWithPath: folder))
            exit(0)
        }
        #endif
        Task.detached(priority: .userInitiated) { Tools.resolveIfNeeded() }
        let store = AppStore()
        ArtifactLinks.store = store
        Analytics.launched([
            "projects": store.projects.filter { $0.parentID == nil }.count,
            "agents": store.projects.filter { $0.isWorktree && !$0.isExternalWorktree }.count,
            "welcome_seen": !store.showsWelcome,
            "chat_view_default": AppStore.newClaudeTabsShowChat,
        ])
        SidebarLayout.registerDefault(hasProjects: !store.projects.isEmpty)
        store.startClock()
        ClaudeAccounts.shared.start()
        // Read the Codex account list before anything reads Codex's
        // sessions. Its sign-ins are checked only once Codex is offered.
        if Agents.isOffered(.codex) { CodexAccounts.shared.start() } else { _ = CodexAccounts.shared }
        let terminals = TerminalManager(store: store)
        store.isBusy = { [weak terminals] id in terminals?.isClaudeBusy(inProject: id) ?? false }
        store.tabIsWorking = { [weak terminals] id in terminals?.tabIsWorking(id) ?? false }
        _store = State(initialValue: store)
        _terminals = State(initialValue: terminals)
        let macs = RemoteMacs()
        _remoteMacs = State(initialValue: macs)
        // An agent on another Mac needs you: the same tone and banner as
        // one on this Mac, by the same rules (see `setClaudeState`).
        macs.onWaiting = { [weak store, weak terminals, weak macs] host, alert in
            guard let store, let terminals, let macs else { return }
            let key = RemoteMacs.key(host: host, projectID: alert.projectID)
            let open = macs.openTabs[key]
            let isLooking = NSApp.isActive && !store.showsPage
                && store.selectedRemote == RemoteSelection(host: host, projectID: alert.projectID)
                && (open == nil || open == .session(alert.sessionID))
            if !isLooking { Chime.play(.needsYou) }
            if !NSApp.isActive {
                terminals.notifier.notifyRemoteWaiting(mac: macs.name(for: host), host: host, alert: alert)
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
        macs.onWaitingEnded = { [weak terminals] sessionID in terminals?.notifier.clear(tabID: sessionID) }
        terminals.notifier.openRemote = { [weak store, weak macs] host, projectID, sessionID in
            guard let store, let macs, macs.client(for: host) != nil else { return }
            macs.openTabs[RemoteMacs.key(host: host, projectID: projectID)] = .session(sessionID)
            store.selectedRemote = RemoteSelection(host: host, projectID: projectID)
            NSApp.activate()
        }
        let pullRequests = PullRequests()
        pullRequests.onChecksFinished = { [weak terminals] projectID, project, pr, waiting in
            terminals?.notifier.notifyChecks(project: project, projectID: projectID, pr: pr, waitingToMerge: waiting)
        }
        pullRequests.onReadyToMerge = { [weak terminals, weak store] projectID, prompt in
            guard let project = store?.project(projectID) else { return }
            _ = terminals?.sendToClaude(prompt, in: project, send: true)
        }
        let deployments = Deployments()
        pullRequests.onMerged = { [weak deployments] projectID, name, pr in
            deployments?.watch(projectID: projectID, name: name, pr: pr)
        }
        deployments.onFinished = { [weak terminals] projectID, project, deploy in
            terminals?.notifier.notifyDeploy(project: project, projectID: projectID, deploy: deploy)
        }
        _pullRequests = State(initialValue: pullRequests)
        _deployments = State(initialValue: deployments)
        let cleaner = WorktreeCleaner(store: store, terminals: terminals, pullRequests: pullRequests)
        _cleaner = State(initialValue: cleaner)
        store.isMergedAndIdle = { [weak cleaner, weak store, weak terminals] id in
            guard cleaner?.waiting[id] != nil, let project = store?.project(id), let terminals else { return false }
            return ![.working, .remoteWorking, .waiting].contains(terminals.activity(for: project))
        }
        _worktreeScanner = State(initialValue: WorktreeScanner(store: store))
        let monitors = RepoMonitors()
        let files = FileListMonitors()
        _files = State(initialValue: files)
        let icons = ProjectIcons()
        _monitors = State(initialValue: monitors)
        _icons = State(initialValue: icons)
        let shortcuts = TabShortcuts()
        let ports = PortScanner()
        _shortcuts = State(initialValue: shortcuts)
        _ports = State(initialValue: ports)
        let snapshots = CompanionSnapshots(
            store: store, terminals: terminals, pullRequests: pullRequests, deployments: deployments, monitors: monitors, files: files, icons: icons,
            cleaner: cleaner, shortcuts: shortcuts, ports: ports)
        let companion = Companion(snapshots: snapshots)
        // Another device sees ports too, while this Mac is in the background.
        ports.scansInBackground = { [weak companion] in !(companion?.server.connectedDevices.isEmpty ?? true) }
        _companion = State(initialValue: companion)
        let feedbackAgent = FeedbackAgent(store: store, terminals: terminals, cleaner: cleaner)
        feedbackAgent.notifyPhone = { [weak companion] title, body, projectID, tabID in
            guard companion?.isEnabled == true else { return }
            companion?.push.notify(title: title, body: body, projectID: projectID, sessionID: tabID)
        }
        _feedbackAgent = State(initialValue: feedbackAgent)
        // Prompts the phone queued while this Mac was asleep.
        let offlineQueue = OfflineQueue(
            token: { [weak companion] in companion?.token },
            isEnabled: { [weak companion] in companion?.isEnabled == true },
            relayURL: QueueRelay.urlForBuild(),
            start: { [weak store] prompt in
                guard let store, let parent = store.project(store.rootID(of: prompt.projectID)) else { return nil }
                guard OfflineQueue.isGitFolder(parent.url) else { throw OfflineQueue.NotGit() }
                return try await snapshots.startAgent(parentID: prompt.projectID, prompt: prompt.prompt, branch: "", base: nil, fromQueue: true)
            },
            folder: BenchPaths.support.appendingPathComponent("OfflineQueue", isDirectory: true))
        offlineQueue.notifyPhone = { [weak companion] title, body, projectID, tabID in
            guard companion?.isEnabled == true else { return }
            companion?.push.notify(title: title, body: body, projectID: projectID, sessionID: tabID)
        }
        companion.onTokenWillChange = { [weak offlineQueue] old in
            Task { await offlineQueue?.drain(oldToken: old) }
        }
        companion.onTurnedOn = { [weak offlineQueue] in
            Task { await offlineQueue?.check() }
        }
        offlineQueue.onFailure = { [weak terminals] failures in
            guard let first = failures.first else { return }
            terminals?.notifier.notifyQueuedFailures(count: failures.count, firstReason: first.reason)
        }
        terminals.notifier.openQueuedPrompts = { [weak offlineQueue] in
            offlineQueue?.showsFailedPrompts = true
            NSApp.activate()
        }
        offlineQueue.start()
        _offlineQueue = State(initialValue: offlineQueue)
        let runner = BenchCommandRunner(store: store, terminals: terminals, snapshots: snapshots)
        runner.discardFeedback = { [weak feedbackAgent] folder in
            feedbackAgent?.discard(folder: folder) ?? (false, "Workbench isn't ready.")
        }
        runner.notify = { [weak store, weak terminals, weak companion] request in
            guard let store, let terminals, let companion else { return (false, "Workbench isn't ready.") }
            return Self.notify(request, store: store, terminals: terminals, companion: companion)
        }
        runner.phones = { [weak companion] in
            guard let companion, companion.isEnabled else { return nil }
            return companion.push.devices.map(\.name)
        }
        let requests = ProjectRequests(runner: runner)
        _requests = State(initialValue: requests)
        AppDelegate.terminals = terminals
        AppDelegate.store = store
        _updater = State(initialValue: Updater(terminals: terminals))
        // Before any tab starts, so kept tabs know whether to join a session.
        SessionKeeper.prepare()
        // Bring every Claude conversation back, once the window is up.
        _ = RestartRecovery.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak terminals] in terminals?.resumeClaudeTabs() }
        #if DEBUG
        // For testing restarts: BENCH_QUIT_AFTER=<seconds> quits the normal
        // way, as an update does, without asking.
        // For testing tab closing: BENCH_CLOSE_TAB_AFTER=<seconds> closes
        // the selected project's current tab, as its close button does.
        if let seconds = ProcessInfo.processInfo.environment["BENCH_CLOSE_TAB_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak store] in
                guard let store, let project = store.projects.first(where: { $0.id == store.selectedProjectID }),
                      let tabID = project.selectedTabID else { return }
                store.closeTab(tabID, in: project.id)
            }
        }
        if let seconds = ProcessInfo.processInfo.environment["BENCH_QUIT_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                AppDelegate.skipsQuitConfirmation = true
                NSApp.terminate(nil)
            }
        }
        #endif
    }

    /// `bench notify`: a banner on this Mac, a push to paired phones, or
    /// both. The project the command ran in gives the title and where a
    /// tap goes. Asking for the phone outright skips the per-project
    /// "notify my phone" switch, since this is an explicit request.
    static func notify(_ request: NotifyRequest, store: AppStore, terminals: TerminalManager, companion: Companion) -> (ok: Bool, message: String) {
        let project = request.tabID.flatMap { tabID in store.projects.first { $0.tabs.contains { $0.id == tabID } } }
        let title = request.title ?? project?.name ?? "Workbench"
        let wantsMac = request.target != .phone
        let wantsPhone = request.target != .mac
        let phones = companion.isEnabled ? companion.push.devices : []
        if request.target == .phone, phones.isEmpty {
            return (false, companion.isEnabled
                    ? "No iPhone is paired with Workbench, so there's nowhere to send it."
                    : "The iPhone companion is off in Workbench's settings, so there's nowhere to send it.")
        }
        var done: [String] = []
        if wantsMac {
            terminals.notifier.notifyMessage(title: title, body: request.message, tabID: request.tabID, projectID: project?.id)
            done.append("shown on this Mac")
        }
        if wantsPhone, !phones.isEmpty {
            companion.push.notify(title: title, body: request.message, projectID: project?.id, sessionID: request.tabID, kind: .messages)
            done.append("sent to " + phones.map(\.name).formatted(.list(type: .and)))
        }
        var message = "Notification " + done.formatted(.list(type: .and)) + "."
        if wantsPhone, phones.isEmpty, request.target == .both {
            message += " No iPhone is paired with Workbench, so nothing went there."
        }
        return (true, message)
    }

    var body: some Scene {
        Window("Workbench", id: "main") {
            ContentView()
                .showsPicturesOverWindow()
                .showsToasts()
                .tint(Theme.accent)
                .environment(store)
                .environment(terminals)
                .environment(monitors)
                .environment(files)
                .environment(icons)
                .environment(ports)
                .environment(reviewComments)
                .environment(previews)
                // A link that asks for a new window gets a tab beside its own.
                .onAppear {
                    previews.openInNewTab = { [store] url, tabID in
                        guard let projectID = store.projectID(ofTab: tabID) else { return }
                        store.openBrowserTab(url, in: projectID, after: tabID)
                    }
                }
                .environment(pullRequests)
                .environment(deployments)
                .environment(cleaner)
                .environment(remoteMacs)
                .environment(updater)
                .environment(whatsNew)
                .environment(shortcuts)
                .environment(claudeActions)
                .environment(companion)
                .environment(feedbackAgent)
                .environment(offlineQueue)
                .environment(\.companionPalette, .mac)
                // Claude's published pages open the way you chose.
                .environment(\.openURL, OpenURLAction { ArtifactLinks.handle($0) ? .handled : .systemAction })
                .followsMotionSetting()
                // A merged PR is the cue to clean up its agent's worktree.
                .onChange(of: pullRequests.info) { cleaner.sweep() }
                .onChange(of: store.projects.map(\.id)) { _, ids in
                    monitors.prune(keeping: Set(ids))
                    files.prune(keeping: Set(ids))
                    pullRequests.forget(keeping: Set(ids))
                }
                .frame(minWidth: WindowChrome.minWindowWidth, minHeight: 500)
                .onChange(of: store.allTabIDs) { _, ids in
                    terminals.prune(keeping: ids)
                    previews.prune(keeping: ids)
                }
        }
        .defaultSize(width: 1440, height: 900)
        // No toolbar: the columns draw the top band themselves (WindowChrome).
        .windowStyle(.hiddenTitleBar)
        .commands {
            BenchCommands(store: store, terminals: terminals, macs: remoteMacs, previews: previews, pullRequests: pullRequests)
            UpdateCommands(updater: updater)
        }

        Window("What's New", id: "whats-new") {
            WhatsNewView()
                .tint(Theme.accent)
                .environment(whatsNew)
        }
        .defaultSize(width: 560, height: 680)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Window("Send Feedback", id: "feedback") {
            FeedbackView()
                .tint(Theme.accent)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var terminals: TerminalManager?
    static weak var store: AppStore?
    private var menuBarItem: MenuBarItem?
    /// Set once you've already agreed to a restart, so quitting doesn't ask again.
    static var skipsQuitConfirmation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconManager.shared.applyAtLaunch()
        HangWatchdog.shared.start()
        Dictation.shared.start()
        syncMenuBarItem()
        // The setting can change from Settings or from an imported settings
        // file, so the icon follows the preference itself.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMenuBarItem() }
        }
    }

    /// Shows or hides the menu bar icon to match its setting.
    @MainActor
    private func syncMenuBarItem() {
        let wanted = MenuBarItem.isShown
        if wanted, menuBarItem == nil, let store = Self.store, let terminals = Self.terminals {
            menuBarItem = MenuBarItem(store: store, terminals: terminals)
        } else if !wanted, let item = menuBarItem {
            item.remove()
            menuBarItem = nil
        }
    }

    /// Closing the window leaves Workbench running, as Mac apps do. Its
    /// terminals belong to TerminalManager, not the window, so they keep
    /// going; the Dock icon (or the menu bar icon, if it's on) brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved edits in file tabs are asked about however the quit
        // came, an update's relaunch included: they'd be gone for good.
        let drafts = FileDrafts.shared
        guard drafts.confirmLosing(drafts.edited) else { return .terminateCancel }
        let remoteDrafts = RemoteFileDrafts.shared
        guard remoteDrafts.confirmLosing(remoteDrafts.edited, quitting: true) else { return .terminateCancel }
        guard !Self.skipsQuitConfirmation, let terminals = Self.terminals else { return .terminateNow }
        let kept = terminals.tabsKeptThroughQuit()
        guard terminals.quitInterruptsWork(keeping: kept) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Workbench?"
        alert.informativeText = Self.interruptionText(terminals.busyTabNames(skipping: kept), action: "Quitting")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Quits and ends kept Claude tabs too, for when Keep Working is on but
    /// you want everything stopped. Asks first if that interrupts work.
    static func quitCompletely() {
        SessionKeeper.endsSessionsAtQuit = true
        NSApp.terminate(nil)
        // Still running, so the quit was cancelled.
        SessionKeeper.endsSessionsAtQuit = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let terminals = Self.terminals { RestartRecovery.shared.recordQuit(terminals: terminals) }
        // Keep Working was turned off while some tabs were kept.
        SessionKeeper.endForQuit()
    }

    /// What a quit or restart would stop, by name, and what happens after.
    static func interruptionText(_ busy: (claude: [String], programs: [String]), action: String) -> String {
        var parts: [String] = []
        if !busy.claude.isEmpty {
            parts.append(busy.claude.count == 1
                ? "An agent is busy in \(list(busy.claude)). \(action) stops it there, and when Workbench opens again that tab offers to continue where it left off."
                : "Agents are busy in \(list(busy.claude)). \(action) stops them there, and when Workbench opens again those tabs offer to continue where they left off.")
        }
        if !busy.programs.isEmpty {
            parts.append("A program is running in \(list(busy.programs)), and \(action.lowercased()) stops it.")
        }
        parts.append("Your conversations, drafts, and queued messages are kept.")
        return parts.joined(separator: "\n\n")
    }

    private static func list(_ names: [String]) -> String {
        let shown = names.count > 4 ? Array(names.prefix(3)) + ["\(names.count - 3) more"] : names
        guard shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + shown.last!
    }
}

struct BenchCommands: Commands {
    let store: AppStore
    let terminals: TerminalManager
    let macs: RemoteMacs
    let previews: PreviewPages
    let pullRequests: PullRequests
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarLayout.key) private var sidebarLayout = SidebarLayout.standard
    @AppStorage(SessionKeeper.enabledKey) private var keepsWorking = false
    /// True while a chat is on screen. Otherwise the text size items stay
    /// off, so the terminal gets ⌘+, ⌘− and ⌘0 for its own font.
    @FocusedValue(\.showsChat) private var showsChat

    private var actions: AppActions { AppActions(store: store, terminals: terminals) }

    var body: some Commands {
        // The menu bar panel has no scene of its own to open windows from.
        let _ = MainWindow.open = { [openWindow] in openWindow(id: "main") }
        // Settings is a page in the main window rather than its own window.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "main")
                actions.openSettings()
                NSApp.activate()
            }
            .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            // The New Tab page; from there, ⌘T again starts Claude.
            Button("New Tab") { actions.newTab() }
                .keyboardShortcut("t")
            Button("New \(Agents.standard.name) Tab") { actions.newTab(.agent) }
            Button("New Shell Tab") { actions.newTab(.shell) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Browser Tab") { actions.newBrowserTab() }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(!actions.canOpenBrowserTab)
            // The address field of the browser tab on screen, or a new one.
            Button("Open Location…") { actions.openLocation(in: previews) }
                .keyboardShortcut("l")
                .disabled(!actions.canOpenBrowserTab)
            Button("Split Right") { actions.split(.sideBySide) }
                .keyboardShortcut("d")
                .disabled(!actions.canSplit)
            Button("Split Down") { actions.split(.stacked) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!actions.canSplit)
            Button("New Agent on a Branch…") { store.startNewAgent() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!store.hasProjectOnScreen)
            Button("Brain Dump…") { actions.startSendTasks() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Add Project…") { ProjectPicker.present(store: store) }
                .keyboardShortcut("o")
            Button {
                actions.openInEditor()
            } label: {
                EditorMenuTitle()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!actions.canOpenInEditor)
        }
        // With Keep Working on, a plain quit leaves Claude tabs running.
        CommandGroup(after: .appTermination) {
            if keepsWorking {
                Button("Quit Workbench Completely") { AppDelegate.quitCompletely() }
            }
        }
        CommandGroup(before: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "keyboard-shortcuts") }
                .keyboardShortcut("/")
            Button("Send Feedback…") { openWindow(id: "feedback") }
            Button("Welcome to Workbench") { store.showsWelcome = true }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { actions.saveFile() }
                .keyboardShortcut("s")
                .disabled(!actions.canSaveFile)
            Button("Close Tab") { actions.closeTab() }
                .keyboardShortcut("w")
        }
        CommandGroup(after: .sidebar) {
            Button("Go to Project or Action…") {
                guard !store.showsWelcome else { return }
                store.showsCommandBar.toggle()
            }
            .keyboardShortcut("k")
            Divider()
            Picker("Project List", selection: $sidebarLayout) {
                Text("Standard").tag(SidebarLayout.standard)
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Text("Compact").tag(SidebarLayout.compact)
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
            .pickerStyle(.inline)
            Picker("Group Projects", selection: Binding(get: { store.grouping }, set: { store.grouping = $0 })) {
                ForEach(SidebarGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Button(store.showsChanges ? "Hide Changes" : "Show Changes") { store.showsChanges.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button(actions.pullRequestTitle(in: pullRequests, macs: macs)) { actions.openPullRequest(in: pullRequests, macs: macs) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions.pullRequestURL(in: pullRequests, macs: macs) == nil)
            Button {
                actions.toggleChat()
            } label: {
                ChatMenuTitle(store: store)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(!actions.canToggleChat)
            // Works with a message typed, where Escape belongs to the
            // message box.
            Button("Stop Agent") { actions.stopClaude() }
                .keyboardShortcut(".")
                .disabled(!actions.canStopClaude)
            Button("Copy Page Address") { actions.copyPreviewURL(from: previews) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!actions.canCopyPreviewURL)
            Divider()
            SizeCommands(showsChat: showsChat == true, store: store, terminals: terminals, previews: previews)
            Divider()
            Button("Next Tab") { store.cycleTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store.cycleTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            PaneCommands(store: store, terminals: terminals, previews: previews)
            Button("Unsplit") { actions.unsplit() }
                .disabled(!actions.isSplit)
            Divider()
            Button("Overview") { actions.showOverview(from: .menu) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Usage and Costs") { actions.showUsage() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Next Session Needing You") { actions.jumpToNextNeedingYou() }
                .keyboardShortcut("j")
            Button("Past Sessions") { actions.showPastSessions() }
                .keyboardShortcut("y")
                .disabled(store.selectedProject == nil)
            // Always nine items: SwiftUI doesn't add menu items to Commands
            // when the list grows later, so ones built from the sidebar's
            // rows went missing if it was empty at launch.
            ForEach(0..<9, id: \.self) { index in
                Button {
                    SidebarShortcuts.select(at: index, store: store, macs: macs)
                } label: {
                    SidebarRowTitle(store: store, macs: macs, index: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}

/// "Show as Chat" or "Show Terminal", for the current tab. Its own view so
/// it follows the tab; menu items in Commands don't update otherwise.
extension FocusedValues {
    /// Set by the chat view while it's on screen.
    @Entry var showsChat: Bool?
}

/// Bigger, smaller, and actual size: for the page in the browser tab
/// you're on, or else for the chat's text. A view of its own so the menu
/// follows the tab and the size as they change. Always the same three
/// items, since menus built in Commands don't swap items later.
private struct SizeCommands: View {
    let showsChat: Bool
    let store: AppStore
    let terminals: TerminalManager
    let previews: PreviewPages
    private var typography: ChatTypography { .shared }

    var body: some View {
        let page = AppActions(store: store, terminals: terminals).browserTab?.id
        Button(page != nil ? "Zoom In" : "Make Text Bigger") {
            if let page { previews.zoom(page, by: 1) } else { typography.zoomIn() }
        }
        .keyboardShortcut("=")
        .disabled(page.map { !previews.canZoom($0, by: 1) } ?? (!showsChat || !typography.canZoomIn))
        Button(page != nil ? "Zoom Out" : "Make Text Smaller") {
            if let page { previews.zoom(page, by: -1) } else { typography.zoomOut() }
        }
        .keyboardShortcut("-")
        .disabled(page.map { !previews.canZoom($0, by: -1) } ?? (!showsChat || !typography.canZoomOut))
        Button("Actual Size") {
            if let page { previews.resetZoom(page) } else { typography.resetSize() }
        }
        .keyboardShortcut("0")
        .disabled(page.map { previews.zoom(of: $0) == 1 } ?? (!showsChat || typography.isDefaultSize))
    }
}

/// Back and Forward for the browser tab you're on, and Switch Pane for a
/// split. ⌘] is Forward, as in any browser, except in a split, where it
/// has always switched panes. A view of its own so the menu follows the tab.
private struct PaneCommands: View {
    let store: AppStore
    let terminals: TerminalManager
    let previews: PreviewPages

    var body: some View {
        let actions = AppActions(store: store, terminals: terminals)
        let tab = actions.browserTab?.id
        Button("Back") { tab.flatMap(previews.existing)?.goBack() }
            .keyboardShortcut("[")
            .disabled(tab == nil)
        Button("Forward") { tab.flatMap(previews.existing)?.goForward() }
            .keyboardShortcut(actions.isSplit ? nil : KeyboardShortcut("]"))
            .disabled(tab == nil)
        Button("Switch Pane") { actions.switchPane() }
            .keyboardShortcut(actions.isSplit ? KeyboardShortcut("]") : nil)
            .disabled(!actions.isSplit)
    }
}

private struct ChatMenuTitle: View {
    let store: AppStore

    var body: some View {
        Text(store.selectedProject?.selectedTab?.showsChat == true ? "Show Terminal" : "Show as Chat")
    }
}

/// "Open in Visual Studio Code", or whichever editor Settings has. A view
/// of its own so the name follows the setting.
private struct EditorMenuTitle: View {
    @AppStorage(Editors.chosenKey) private var chosen = ""

    var body: some View {
        let _ = chosen
        Text(Editors.menuTitle)
    }
}

/// The name of the Nth numbered sidebar row, for its ⌘N menu item. A view
/// of its own so the name follows the sidebar; the menu around it doesn't.
private struct SidebarRowTitle: View {
    let store: AppStore
    let macs: RemoteMacs
    let index: Int

    var body: some View {
        let targets = SidebarShortcuts.targets(store: store, macs: macs)
        if targets.indices.contains(index) {
            Text(SidebarShortcuts.title(of: targets[index], store: store, macs: macs))
        } else {
            Text("Project \(index + 1)")
        }
    }
}

extension EnvironmentValues {
    /// Whether the tab this view is in has the keys: false for the other
    /// side of a split, so its chat box doesn't take the cursor.
    @Entry var tabHasKeys = true
}
