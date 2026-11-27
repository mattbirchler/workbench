import AppKit
import BenchKit
import GhosttyKit
import Observation
import UniformTypeIdentifiers

/// Live state for one tab's terminal. Lives as long as the tab does, whether
/// or not it's on screen, so background shells keep running.
@Observable
final class TerminalSession: TerminalSurfaceDelegate {
    let tabID: UUID
    let projectID: UUID
    let isAgent: Bool
    /// The agent the tab runs. Nil for a shell.
    let agent: (any AgentProvider)?
    let view: TerminalSurfaceView
    /// Runs in the session keeper, so it carries on through a restart.
    let isKept: Bool
    /// The keeper it started with, to tell if that one goes away.
    let keeperInstance: String?
    /// When `claude` was typed into this tab's new shell, which takes a
    /// moment to get to it. nil for a session joined while already running.
    @ObservationIgnored private(set) var launchedClaudeAt: Date?

    /// Title set by the running program (e.g. Claude's task summary),
    /// without the spinner Claude Code puts in front while it works. The
    /// spinner turns ten times a second; publishing every frame of it had
    /// each tab chip and Overview card laying out again that often.
    var terminalTitle: String?
    /// Prompt, current action, and so on from Claude's hooks, for the Overview.
    var details: AgentDetails?
    /// How full Claude's context is, from its transcript.
    var usage: ContextUsage?
    /// The model's name, like "Opus 5.5": from the transcript, or else
    /// what the session started with. Each new one is counted
    /// (`claude_model_used`), so we know which models people run.
    var model: String? {
        didSet {
            guard let model, model != oldValue else { return }
            Analytics.capture(.claudeModelUsed, ModelAnalytics.properties(model: model))
        }
    }
    /// How hard Claude thinks, like "high": the last /effort since the
    /// model was picked, or else what Claude Code saved for the model.
    var effort: String?
    /// An effort level just sent from the chat, and when, shown until the
    /// transcript or settings catch up.
    @ObservationIgnored var sentEffort: (level: String, at: Date)?
    /// Claude's checklist, from its transcript, and when it last changed.
    var checklist: [ChecklistItem] = []
    var checklistUpdatedAt: Date?
    /// Claude's latest tool calls, newest first, from its transcript.
    var trail: [ToolAction] = []
    /// What Claude last said along the way, and when.
    var note: String?
    var noteAt: Date?
    /// Its subagents, from their own transcripts.
    var agents: [AgentStatus] = []
    /// Every file Claude has edited in this session, with when, from its
    /// transcript. Some can be in other projects.
    var editedFiles: [String: Date] = [:] {
        didSet { editsElsewhereCache = nil }
    }
    /// Those files sorted into the other projects they're in, kept until
    /// the files or the project folders change. The sidebar asks for this
    /// for every row on every redraw, so it can't be worked out each time.
    @ObservationIgnored private var editsElsewhereCache: (roots: [CrossProjectEdits.Root<UUID>], byProject: [UUID: [String: Date]])?

    /// The files Claude edited here that are in other projects, by project.
    func editsElsewhere(_ index: CrossProjectEdits.Index<UUID>) -> [UUID: [String: Date]] {
        let files = editedFiles
        if let cache = editsElsewhereCache, cache.roots == index.roots { return cache.byProject }
        let byProject = files.isEmpty ? [:] : index.byProject(files, home: projectID)
        editsElsewhereCache = (index.roots, byProject)
        return byProject
    }
    /// The machine this tab is logged in to over ssh, if any.
    var remoteHost: String?
    /// An interactive Claude Code is the terminal's foreground program,
    /// even one started by hand, which Bench's hooks don't report on.
    var claudeInFront = false
    /// What Claude's hooks last reported. nil in shell tabs, and until Claude
    /// reports something.
    private(set) var claudeState: AgentState?
    /// Set when the bell rings or a notification arrives while the tab is hidden.
    var needsAttention = false
    /// True while the program (usually Claude) is busy.
    private(set) var isWorking = false {
        didSet { if isWorking != oldValue { workingSince = isWorking ? Date() : nil } }
    }
    /// When the terminal last started looking busy.
    @ObservationIgnored private var workingSince: Date?
    /// Set when work finishes while the tab isn't in front of the user.
    /// Cleared once they look at it.
    var finishedUnseen = false {
        didSet { if !finishedUnseen, markedUnread { markedUnread = false } }
    }
    /// Set by Mark as Unread in the sidebar: a done mark you put back
    /// yourself. Unlike one Workbench sets, coming back to the app doesn't
    /// clear it, only opening the tab or a new turn starting. Saved, so it
    /// lasts through a relaunch.
    var markedUnread = false {
        didSet { if markedUnread != oldValue { manager?.noteMarkedUnread(self) } }
    }
    var isVisible = false {
        didSet {
            view.setOccluded(!isVisible)
            if isVisible {
                // Opening the tab is the visit a manual mark waits for.
                if oldValue == false, markedUnread { markedUnread = false }
                markSeen()
                if isAgent { manager?.lastClaudeTab[projectID] = tabID }
            }
        }
    }

    // Raw busy signals. Claude Code reports progress (OSC 9;4) and also
    // animates its title with a spinner while it works.
    @ObservationIgnored private var progressActive = false
    @ObservationIgnored private var titleSpinning = false
    @ObservationIgnored private var finishWork: DispatchWorkItem?

    @ObservationIgnored weak var manager: TerminalManager?
    /// For a session outside the manager (a shell into another Mac): called
    /// when its program exits.
    @ObservationIgnored var onClose: (() -> Void)?

    init(tab: TabRecord, project: Project) {
        tabID = tab.id
        projectID = project.id
        isAgent = tab.kind == .agent
        agent = isAgent ? tab.provider ?? Agents.standard : nil
        var launch = TerminalSurfaceView.Launch(workingDirectory: project.path)
        let account = ClaudeAccounts.shared.profile(tab.claudeAccountID ?? project.claudeAccountID)
        let codexAccount = CodexAccounts.shared.profile(tab.codexAccountID ?? project.codexAccountID)
        // Local Claude tabs go through the keeper, when it's on, so they
        // keep running while Workbench restarts.
        // The keeper ends itself once it has nothing to keep, so make sure
        // one is running (and note which) before relying on it.
        keeperInstance = tab.kind == .agent && SessionKeeper.isEnabled ? SessionKeeper.currentInstance() : nil
        isKept = keeperInstance != nil
        if tab.kind == .agent {
            if isKept, SessionKeeper.takeRunning(tab.id) {
                // Claude is still running in the keeper from before the
                // restart. Join it as it is: launching would clear the
                // state its hooks have been keeping.
            } else {
                let claude = AgentSessions.launch(tabID: tab.id, folder: project.path, prompt: tab.initialPrompt,
                                                   resuming: tab.resumeSessionID, account: account,
                                                   agentAccount: codexAccount.id,
                                                   provider: agent ?? Agents.standard)
                launch.environment = claude.environment
                // The keeper types it in only when it starts the session,
                // never into one a relay joins again.
                if isKept { launch.environment[SessionKeeper.inputVariable] = claude.input } else { launch.initialInput = claude.input }
                launchedClaudeAt = Date()
            }
        } else if tab.runsCommandOnStart, let command = tab.command {
            launch.initialInput = command + "\n"
        }
        // `claude` typed into any of the project's tabs uses its account too.
        if let folder = account.folder, tab.isTerminal {
            launch.environment["CLAUDE_CONFIG_DIR"] = folder
        }
        // And `codex` its Codex account.
        if let folder = codexAccount.folder, tab.isTerminal {
            launch.environment["CODEX_HOME"] = folder
        }
        // Lets PortScanner tell which tab a server was started from.
        launch.environment[PortScanner.environmentKey] = tab.id.uuidString
        // The `bench` tool, so the shell (and Claude) can add projects.
        if let tools = ProjectRequests.toolFolder {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            launch.environment["PATH"] = "\(tools):\(path)"
            launch.environment["BENCH_CLI"] = tools + "/bench"
            // Where this copy of Workbench listens, which differs for a test copy.
            launch.environment["BENCH_REQUESTS"] = ProjectRequests.folder.path
        }
        // Marks this tab's login process so RemoteSessionScanner can find its
        // terminal device. Ghostty runs this as `exec -l <command>`, so the
        // shell ignores the comment but it shows up in the process list.
        let shell = RemoteSessionScanner.shellCommand(for: tab.id)
        launch.command = isKept ? SessionKeeper.relayCommand(tabID: tab.id, shell: shell) : shell
        view = TerminalSurfaceView(launch: launch)
        view.delegate = self
    }

    func terminal(_ view: TerminalSurfaceView, didSetTitle title: String) {
        titleSpinning = title.unicodeScalars.first.map(titleDriver.isWorkingMark) ?? false
        let text = titleSpinning ? String(String.UnicodeScalarView(title.unicodeScalars.dropFirst())).trimmingCharacters(in: .whitespaces) : title
        // Observers hear about every assignment, not just changes.
        if text != terminalTitle { terminalTitle = text }
        updateWorking()
        if remoteHost == nil, !titleShowsClaude { markTurnOver(reason: "the terminal's title is \"\(title)\"") }
    }

    func terminal(_ view: TerminalSurfaceView, didReportProgress active: Bool) {
        progressActive = active
        updateWorking()
    }

    /// Clears the done and attention marks if the user can see this tab.
    /// A tab you marked unread keeps its mark until you open it again.
    func markSeen() {
        guard isVisible, NSApp.isActive, !markedUnread else { return }
        needsAttention = false
        finishedUnseen = false
    }

    /// Puts the done mark back on a turn you've already looked at, so it
    /// isn't forgotten.
    func markUnread() {
        finishedUnseen = true
        markedUnread = true
    }

    /// How long a turn has to run before finishing in front of you makes a sound.
    private static let chimeAfter: TimeInterval = 20

    private var userCanSee: Bool {
        isVisible && NSApp.isActive && (view.window?.isKeyWindow ?? false)
    }

    private func updateWorking() {
        if progressActive || titleSpinning {
            finishWork?.cancel()
            finishWork = nil
            // Both are observed, and this runs on every spinner frame.
            if !isWorking { isWorking = true }
            if finishedUnseen { finishedUnseen = false }
            return
        }
        guard isWorking, finishWork == nil else { return }
        // Wait a moment before calling it done, so short gaps between
        // steps don't flash the indicator.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            finishWork = nil
            // A turn you watched go by in a few seconds needs no sound. One
            // that took a while, or finished in a tab you weren't looking
            // at, gets the tone. Not when it only stopped to ask you
            // something: that has its own.
            let ranLong = workingSince.map { Date().timeIntervalSince($0) >= Self.chimeAfter } ?? false
            isWorking = false
            if !userCanSee { finishedUnseen = true }
            if isAgent, claudeState != .waiting, ranLong || !userCanSee { Chime.play(.finished) }
            if isAgent, !NSApp.isActive, let manager, let name = manager.store?.projects.first(where: { $0.id == projectID })?.name {
                let tabID = tabID, projectID = projectID
                Task { [weak self] in
                    let summary = await self?.finishedSummary()
                    manager.notifier.notifyFinished(project: name, tabID: tabID, projectID: projectID, summary: summary)
                }
            }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// What to say about a turn that just finished: its recap, if one
    /// comes within a few seconds, or else how Claude's reply began.
    private func finishedSummary() async -> String? {
        // The Stop hook can land a moment after the terminal goes quiet.
        for _ in 0..<12 {
            if let stopped = details?.stoppedAt, stopped >= (details?.promptAt ?? .distantPast) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let path = details?.transcriptPath, let stopped = details?.stoppedAt,
              stopped >= (details?.promptAt ?? .distantPast) else { return details?.summary }
        return await Recaps.shared.waitForRecap(transcript: path, stoppedAt: stopped) ?? details?.summary
    }

    /// What the hooks last said when you answered Claude from Bench. Until
    /// they say something new, the tab shows the answer taking effect, so
    /// cards on other devices go away now instead of at Claude's next step.
    var answeredDetails: AgentDetails?

    /// Claude has your answer: it carries on, or after a deny, waits for
    /// what to do instead.
    func markAnswered(continuing: Bool) {
        guard details?.state == .waiting else { return }
        answeredDetails = details
        details?.state = continuing ? .working : .done
        setClaudeState(details?.state)
    }

    /// The hooks said working or waiting, but the turn ended without them
    /// hearing: you pressed Esc (the transcript notes it, no hook runs), or
    /// Claude left the terminal. Until the hooks say something new, the
    /// tab is done, so it stops asking you to allow or deny and the phone
    /// can send to it again.
    func markTurnOver(reason: String) {
        guard isAgent, let state = details?.state, state == .waiting || state == .working else { return }
        NSLog("Bench: tab \(tabID) was \(state.rawValue), but \(reason); calling it done")
        answeredDetails = details
        details?.state = .done
        setClaudeState(.done)
    }

    /// Esc after the turn's prompt, so this interrupt hasn't been seen.
    func noteInterrupt(at interruptedAt: Date?) {
        guard let interruptedAt, interruptedAt > (details?.promptAt ?? .distantPast),
              interruptedAt > (details?.stoppedAt ?? .distantPast) else { return }
        markTurnOver(reason: "the transcript says you interrupted it")
    }

    /// Reads this tab's title. A plain terminal is read the way the
    /// standard agent's is, in case that's what was started in it by hand.
    private var titleDriver: any AgentTerminalDriver { agent?.driver ?? Agents.standard.driver }

    /// The agent keeps the title while it's in front. When the shell's own
    /// title is back, it isn't anymore.
    private var titleShowsClaude: Bool {
        titleSpinning || titleDriver.titleIsAgents(terminalTitle)
    }

    func setClaudeState(_ state: AgentState?) {
        guard state != claudeState else { return }
        let wasWaiting = claudeState == .waiting
        claudeState = state
        if state == .waiting {
            // In front but looking elsewhere: a tone. Looking right at
            // it, the question appearing is enough.
            if !userCanSee { Chime.play(.needsYou) }
            if !NSApp.isActive {
                let name = manager?.store?.projects.first { $0.id == projectID }?.name ?? "Workbench"
                manager?.notifier.notifyWaiting(project: name, tabID: tabID, projectID: projectID, agent: (agent ?? Agents.standard).name, question: details?.question,
                                                  allowOrDeny: details?.isAllowOrDeny == true)
                NSApp.requestUserAttention(.informationalRequest)
            }
        } else if wasWaiting {
            manager?.notifier.clear(tabID: tabID)
        }
    }

    func terminal(_ view: TerminalSurfaceView, didChangeDirectory path: String) {}

    func terminal(_ view: TerminalSurfaceView, didNotify title: String, body: String) {
        markAttention()
    }

    func terminalDidRingBell(_ view: TerminalSurfaceView) {
        markAttention()
    }

    private func markAttention() {
        if !userCanSee { needsAttention = true }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    func terminalRequestedNewTab(_ view: TerminalSurfaceView) {
        manager?.store?.addTab(.shell, to: projectID)
    }

    func terminal(_ view: TerminalSurfaceView, requestedGoToTab tab: ghostty_action_goto_tab_e) -> Bool {
        manager?.goToTab(tab, in: projectID) ?? false
    }

    func terminalWasClicked(_ view: TerminalSurfaceView) {
        manager?.store?.focusPane(tabID, in: projectID)
    }

    func terminalRequestedOtherPane(_ view: TerminalSurfaceView) -> Bool {
        guard let store = manager?.store, let project = store.project(projectID),
              let partner = project.partner(of: tabID) else { return false }
        store.selectTab(partner, in: projectID)
        return true
    }

    /// A kept tab's relay ends with an error when its keeper goes away.
    /// Start the tab again rather than leave it at "Process exited".
    func terminalChildExited(_ view: TerminalSurfaceView) -> Bool {
        guard isKept, let manager, SessionKeeper.currentInstance() != keeperInstance else { return false }
        // Not from inside Ghostty's callback: this replaces the terminal.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = manager.restartIfKeeperLost(self)
        }
        return true
    }

    func terminalDidClose(_ view: TerminalSurfaceView) {
        if let manager {
            if isKept, manager.restartIfKeeperLost(self) { return }
            manager.store?.closeTab(tabID, in: projectID)
        } else {
            onClose?()
        }
    }
}

enum TabActivity {
    /// `remoteWorking` is work in a tab that's logged in to another machine
    /// over ssh, shown differently so it's clear the work is happening elsewhere.
    case idle, working, remoteWorking, waiting, done, attention
}

extension TerminalSession {
    /// An idle Claude chat is fine to close: it picks up where it left off
    /// next time. One that's mid-task, or waiting on a permission answer,
    /// is not. Shell tabs ask whenever a program is running.
    var closingInterruptsWork: Bool {
        guard view.needsConfirmQuit else { return false }
        if isAgent { return isWorking || claudeState == .waiting }
        return true
    }

    /// When the tab's current stretch of work or waiting began: your last
    /// message to Claude for a turn in progress, its question while it
    /// waits on you. nil while it's idle or done.
    var activeSince: Date? {
        switch activity {
        case .waiting:
            return details?.questionAt ?? workingSince
        case .working, .remoteWorking:
            if let prompt = details?.promptAt, prompt > (details?.stoppedAt ?? .distantPast) { return prompt }
            return workingSince
        default:
            return nil
        }
    }

    /// The checklist worth showing: one with steps left, or one finished
    /// during the turn still under way. An old, finished list is hidden.
    var visibleChecklist: [ChecklistItem]? {
        guard !checklist.isEmpty else { return nil }
        if checklist.contains(where: { $0.status != .completed }) { return checklist }
        guard activeSince != nil, let updated = checklistUpdatedAt, let prompt = details?.promptAt, updated >= prompt else { return nil }
        return checklist
    }

    var activity: TabActivity {
        if claudeState == .waiting { return .waiting }
        if isWorking { return remoteHost == nil ? .working : .remoteWorking }
        if finishedUnseen { return .done }
        if needsAttention { return .attention }
        return .idle
    }
}

/// Creates and keeps terminal sessions for every tab in the store.
@Observable
final class TerminalManager {
    private var sessions: [UUID: TerminalSession] = [:]
    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var cachedProjectIndex: CrossProjectEdits.Index<UUID>?
    @ObservationIgnored let notifier = AgentNotifier()
    @ObservationIgnored private var stateWatcher: AgentStateWatcher?
    @ObservationIgnored private var remoteScanner: RemoteSessionScanner?
    @ObservationIgnored private let usageReader = TranscriptUsageReader()
    /// One per agent that has subagents, made the first time it's needed.
    @ObservationIgnored private var subagentReaders: [AgentID: any SubagentReading] = [:]

    private func subagentReader(for session: TerminalSession) -> (any SubagentReading)? {
        guard let agent = session.agent else { return nil }
        if let reader = subagentReaders[agent.id] { return reader }
        let reader = agent.transcripts.makeSubagentReader()
        subagentReaders[agent.id] = reader
        return reader
    }
    /// The Claude tab you looked at most recently in each project.
    @ObservationIgnored var lastClaudeTab: [UUID: UUID] = [:]

    init(store: AppStore) {
        self.store = store
        notifier.openTab = { [weak self] tabID, projectID in
            self?.store?.selectedProjectID = projectID
            self?.store?.selectTab(tabID, in: projectID)
            NSApp.activate()
        }
        notifier.openOverview = { [weak self] in
            self?.store?.showOverview(from: .notification)
            NSApp.activate()
        }
        stateWatcher = AgentStateWatcher { [weak self] all in
            guard let self else { return }
            for (id, session) in sessions {
                // Claude has started: its first prompt is in the conversation now.
                if all[id] != nil, AgentSessions.isRunning(tabID: id) { store.clearPendingLaunch(tabID: id) }
                if let answered = session.answeredDetails, all[id] == answered {
                    // Nothing new from the hooks since you answered.
                } else {
                    session.answeredDetails = nil
                    // A new prompt in any tab counts as using its project.
                    if let prompt = all[id]?.promptAt, prompt != session.details?.promptAt {
                        store.noteUse(session.projectID, at: prompt)
                    }
                    session.setClaudeState(all[id]?.state)
                    if session.details != all[id] { session.details = all[id] }
                }
                // For the Overview's timeline: how long it sits on a permission prompt.
                if session.isAgent { WaitLog.shared.note(tab: id, project: session.projectID, details: session.claudeState == .waiting ? session.details : nil) }
                // Hooks fire on every prompt and tool call, which is a good
                // pace to re-read the transcript's token counts.
                // Before any hook but SessionStart, as after resuming, the
                // tab's session record knows the transcript.
                let startModel = (all[id]?.startModel ?? AgentSessions.startModel(tabID: id)).map(ContextUsage.modelName)
                // A switch the hook just reported beats the transcript, which
                // only names the new model once Claude replies on it.
                let switchedModel = all[id]?.switchedModel.map(ContextUsage.modelName)
                if let switchedModel, session.model != switchedModel { session.model = switchedModel }
                if let path = all[id]?.transcriptPath ?? AgentSessions.transcriptPath(tabID: id) {
                    usageReader.update(path: path) { [weak self, weak session] info in
                        guard let session else { return }
                        if session.usage != info.usage { session.usage = info.usage }
                        let model = switchedModel ?? info.model ?? startModel
                        if session.model != model {
                            session.model = model
                            session.sentEffort = nil
                        }
                        let effort = Self.effort(sent: session.sentEffort, transcript: info, saved: session.agent?.savedEffort(forModel: model))
                        if session.effort != effort { session.effort = effort }
                        if session.checklist != info.checklist { session.checklist = info.checklist }
                        if session.checklistUpdatedAt != info.checklistUpdatedAt { session.checklistUpdatedAt = info.checklistUpdatedAt }
                        if session.trail != info.trail { session.trail = info.trail }
                        if session.editedFiles != info.editedFiles {
                            let before = session.editedFiles
                            session.editedFiles = info.editedFiles
                            self?.noteEditsElsewhere(by: session, before: before)
                        }
                        if session.note != info.note { session.note = info.note }
                        if session.noteAt != info.noteAt { session.noteAt = info.noteAt }
                        session.noteInterrupt(at: info.interruptedAt)
                    }
                    subagentReader(for: session)?.update(transcript: path, since: all[id]?.startedAt) { [weak session] agents in
                        guard let session, session.agents != agents else { return }
                        session.agents = agents
                    }
                }
            }
            usageReader.keep(paths: Set(sessions.keys.compactMap { all[$0]?.transcriptPath ?? AgentSessions.transcriptPath(tabID: $0) }))
        }
        remoteScanner = RemoteSessionScanner(hasTabs: { [weak self] in !(self?.sessions.isEmpty ?? true) }) { [weak self] hosts, claudeTabs in
            guard let self else { return }
            for (id, session) in sessions {
                if session.remoteHost != hosts[id] { session.remoteHost = hosts[id] }
                let inFront = claudeTabs.contains(id)
                if session.claudeInFront != inFront { session.claudeInFront = inFront }
            }
        }
        // Coming back to the app counts as seeing the tab that's on screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.values.forEach { $0.markSeen() } }
        }
        // Esc on Claude writes to the transcript but runs no hook, so while
        // a tab says working or waiting, look at its transcript's new lines
        // now and then. Only the bytes added since last time are read.
        let interruptCheck = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForInterrupts() }
        }
        RunLoop.main.add(interruptCheck, forMode: .common)
    }

    private func checkForInterrupts() {
        for (id, session) in sessions where session.isAgent && session.remoteHost == nil {
            guard let state = session.details?.state, state == .waiting || state == .working,
                  let path = session.details?.transcriptPath ?? AgentSessions.transcriptPath(tabID: id) else { continue }
            usageReader.update(path: path) { [weak session] info in
                session?.noteInterrupt(at: info.interruptedAt)
            }
        }
    }

    var startupError: String? { GhosttyRuntime.shared.startupError }

    func session(for tab: TabRecord, in project: Project) -> TerminalSession {
        if let existing = sessions[tab.id] { return existing }
        let session = TerminalSession(tab: tab, project: project)
        session.manager = self
        sessions[tab.id] = session
        if markedUnreadTabs.contains(tab.id) { session.markUnread() }
        return session
    }

    // MARK: Mark as Unread

    static let markedUnreadKey = "markedUnreadTabs"
    /// The tabs you marked unread, kept until you open them. Saved, so a
    /// tab started again after a relaunch gets its mark back.
    @ObservationIgnored private lazy var markedUnreadTabs: Set<UUID> =
        Set((UserDefaults.standard.stringArray(forKey: Self.markedUnreadKey) ?? []).compactMap(UUID.init))

    func noteMarkedUnread(_ session: TerminalSession) {
        let before = markedUnreadTabs
        if session.markedUnread { markedUnreadTabs.insert(session.tabID) } else { markedUnreadTabs.remove(session.tabID) }
        if markedUnreadTabs != before { saveMarkedUnread() }
    }

    private func saveMarkedUnread() {
        UserDefaults.standard.set(markedUnreadTabs.map(\.uuidString).sorted(), forKey: Self.markedUnreadKey)
    }

    /// The tab Mark as Unread puts the mark on: the one whose reply the
    /// row shows. Nil when there's nothing to mark, or the row already
    /// says something needs you (unread, working, or asking).
    func unreadTarget(for project: Project) -> TerminalSession? {
        guard activity(for: project) == .idle, let last = lastFinish(for: project) else { return nil }
        return sessions[last.tabID]
    }

    func markUnread(_ project: Project) {
        unreadTarget(for: project)?.markUnread()
    }

    func existingSession(_ tabID: UUID) -> TerminalSession? { sessions[tabID] }

    /// The folder of the project a tab belongs to.
    func projectPath(forTab tabID: UUID) -> String? {
        guard let projectID = sessions[tabID]?.projectID else { return nil }
        return store?.projects.first { $0.id == projectID }?.path
    }

    /// Every project's folder, for telling which project a file is in.
    /// Made again only when the projects or their folders change.
    var projectIndex: CrossProjectEdits.Index<UUID> {
        let roots: [CrossProjectEdits.Root<UUID>] = (store?.projects ?? []).map { .init(id: $0.id, path: $0.path) }
        if let cached = cachedProjectIndex, cached.roots == roots { return cached }
        let index = CrossProjectEdits.Index(roots)
        cachedProjectIndex = index
        return index
    }

    /// The project a file is in, if it's in one.
    func project(holding path: String) -> UUID? { projectIndex.owner(of: path) }

    /// The files a project's Claude tabs edited in other projects, by
    /// project, with when each was last edited.
    func editsInOtherProjects(from project: Project) -> [UUID: [String: Date]] {
        let index = projectIndex
        var result: [UUID: [String: Date]] = [:]
        for session in project.tabs.compactMap({ sessions[$0.id] }) where !session.editedFiles.isEmpty {
            for (other, files) in session.editsElsewhere(index) {
                result[other, default: [:]].merge(files) { max($0, $1) }
            }
        }
        return result
    }

    /// Claude editing another project counts as using it, which brings that
    /// project into Active, where its row can say where the edits came from.
    private func noteEditsElsewhere(by session: TerminalSession, before: [String: Date]) {
        let fresh = session.editedFiles.filter { before[$0.key] != $0.value }
        guard let store, !fresh.isEmpty else { return }
        for (other, files) in projectIndex.byProject(fresh, home: session.projectID) {
            if let last = files.values.max() { store.noteUse(other, at: last) }
        }
    }

    /// A Claude tab in another project that edited this one: the tab, its
    /// project, and its latest edit here.
    struct EditFromElsewhere {
        let session: TerminalSession
        let lastEdit: Date
    }

    /// The other projects' Claude tabs that edited this project, newest
    /// edit first.
    func editsFromOtherProjects(into project: Project) -> [EditFromElsewhere] {
        let index = projectIndex
        return sessions.values.compactMap { session -> EditFromElsewhere? in
            guard session.projectID != project.id, !session.editedFiles.isEmpty,
                  let files = session.editsElsewhere(index)[project.id],
                  let last = files.values.max() else { return nil }
            return EditFromElsewhere(session: session, lastEdit: last)
        }
        .sorted { $0.lastEdit > $1.lastEdit }
    }

    /// The most important activity across a project's tabs, for the sidebar.
    /// Whether Claude is busy in any tab, here or on another machine.
    var anyWorking: Bool {
        sessions.values.contains { [.working, .remoteWorking].contains($0.activity) }
    }

    func activity(for project: Project) -> TabActivity {
        let live = project.tabs.compactMap { sessions[$0.id] }
        if live.contains(where: { $0.claudeState == .waiting }) { return .waiting }
        if live.contains(where: { $0.isWorking && $0.remoteHost == nil }) { return .working }
        if live.contains(where: \.isWorking) { return .remoteWorking }
        if live.contains(where: \.finishedUnseen) { return .done }
        if live.contains(where: \.needsAttention) { return .attention }
        return .idle
    }

    /// The recap (or start of Claude's reply) for a turn that finished
    /// while you weren't looking, until you open the project, and the tab
    /// it came from, so the card can say what the others are doing.
    func unseenSummary(for project: Project) -> (tabID: UUID, summary: String)? {
        let latest = project.tabs.compactMap { sessions[$0.id] }
            .filter { $0.finishedUnseen }
            .max { ($0.details?.stoppedAt ?? .distantPast) < ($1.details?.stoppedAt ?? .distantPast) }
        guard let latest, let summary = latest.details?.summary else { return nil }
        return (latest.tabID, summary)
    }

    /// The latest finished turn in a project, seen or not: its tab, recap and when.
    func lastFinish(for project: Project) -> (tabID: UUID, summary: String, at: Date)? {
        project.tabs.compactMap { sessions[$0.id] }
            .compactMap { session -> (UUID, String, Date)? in
                guard let details = session.details, let summary = details.summary, let at = details.stoppedAt,
                      at >= (details.promptAt ?? .distantPast) else { return nil }
                return (session.tabID, summary, at)
            }
            .max { $0.2 < $1.2 }
            .map { (tabID: $0.0, summary: $0.1, at: $0.2) }
    }

    /// One line per Claude tab, in tab order, for a project with several.
    func tabLines(for project: Project) -> [TabLine] {
        project.tabs.filter { $0.kind == .agent }.compactMap { tab in
            guard let session = sessions[tab.id] else { return nil }
            return TabLine(id: tab.id, activity: session.activity, customTitle: tab.customTitle,
                           terminalTitle: session.terminalTitle, details: session.details,
                           initialPrompt: tab.initialPrompt, fallbackTitle: tab.title)
        }
    }

    /// For the sidebar's timer: when the tab behind the project's activity
    /// started, and what it's doing in words. The longest-running one wins
    /// when several tabs share that activity. Its tab comes too, for the
    /// trail and checklist that go with the timer.
    func activeSince(for project: Project) -> (tabID: UUID, since: Date, action: String?)? {
        let activity = activity(for: project)
        let matching = project.tabs.compactMap { sessions[$0.id] }.filter { session in
            switch activity {
            case .working: session.activity == .working
            case .remoteWorking: session.activity == .remoteWorking
            case .waiting: session.activity == .waiting
            default: false
            }
        }
        guard let first = matching.compactMap({ s in s.activeSince.map { (s, $0) } }).min(by: { $0.1 < $1.1 }) else { return nil }
        return (first.0.tabID, first.1, first.0.details.flatMap { $0.plainAction ?? $0.action })
    }

    /// The tab waiting on an allow-or-deny question in a project, and its details.
    func permissionWaiting(in project: Project) -> (tabID: UUID, details: AgentDetails)? {
        for tab in project.tabs {
            if let session = sessions[tab.id], let details = session.details, details.isAllowOrDeny { return (tab.id, details) }
        }
        return nil
    }

    /// The agents to pin for a project: the selected tab's, else those of
    /// any tab that has some running.
    func agents(for project: Project) -> [AgentStatus]? {
        let pinned = { (session: TerminalSession) in session.agents.pinned(activeSince: session.activeSince) }
        if let selected = project.selectedTabID, let session = sessions[selected], !pinned(session).isEmpty { return pinned(session) }
        let all = project.tabs.compactMap { sessions[$0.id] }.flatMap(pinned)
        return all.isEmpty ? nil : all
    }

    /// The checklist to show for a project: the selected tab's, else the
    /// one from the tab behind the project's activity, else the most
    /// recently changed.
    func checklist(for project: Project) -> [ChecklistItem]? {
        if let selected = project.selectedTabID, let list = sessions[selected]?.visibleChecklist { return list }
        let withList = project.tabs.compactMap { sessions[$0.id] }.filter { $0.visibleChecklist != nil }
        let activity = activity(for: project)
        let pick = withList.first { $0.activity == activity }
            ?? withList.max { ($0.checklistUpdatedAt ?? .distantPast) < ($1.checklistUpdatedAt ?? .distantPast) }
        return pick?.visibleChecklist
    }

    /// Types a message into the project's Claude tab (the one you used most
    /// recently) and switches to it, leaving you to press Return. Opens a new
    /// Claude tab with the message if there isn't one running.
    ///
    /// With `send`, presses Return too, the way the phone does. If Claude
    /// can't take a message right now (it's asking for permission, say),
    /// the text is typed and left for you, and the reason is returned.
    @discardableResult
    func sendToClaude(_ text: String, in project: Project, send: Bool = false) -> String? {
        guard let store else { return nil }
        let running = project.tabs.filter { $0.kind == .agent && sessions[$0.id] != nil }
        let target = running.first { $0.id == lastClaudeTab[project.id] } ?? running.last
        guard let target, let session = sessions[target.id] else {
            store.addTab(.agent, to: project.id, prompt: text)
            return nil
        }
        store.selectTab(target.id, in: project.id)
        if send, companionReply(text, tabID: target.id, here: true) == nil { return nil }
        session.view.sendText(text)
        return send ? companionReplyProblem(tabID: target.id, here: true) : nil
    }

    /// What to call the agent `sendToClaude` would reach in a project.
    func agentName(in project: Project) -> String {
        let running = project.tabs.filter { $0.kind == .agent && sessions[$0.id] != nil }
        let target = running.first { $0.id == lastClaudeTab[project.id] } ?? running.last
        return (target?.provider ?? Agents.standard).name
    }

    /// Answers Claude's permission question in a tab: Return picks "Yes",
    /// Escape picks "No". Does nothing unless that tab is still waiting on an
    /// allow-or-deny question, in case it was answered in the meantime.
    @discardableResult
    func answerPermission(allow: Bool, tabID: UUID) -> Bool {
        guard let session = sessions[tabID], session.details?.isAllowOrDeny == true, let driver = session.agent?.driver else { return false }
        session.view.press(allow ? driver.allowKey : driver.denyKey)
        session.markAnswered(continuing: allow)
        return true
    }

    /// Stops what Claude is doing, as pressing Escape in its terminal does.
    @discardableResult
    func interrupt(tabID: UUID) -> Bool {
        guard let session = sessions[tabID], let driver = session.agent?.driver, session.claudeState == .working else { return false }
        session.view.press(driver.interruptKey)
        return true
    }

    /// What to call a tab's agent in a message.
    private func words(_ tabID: UUID) -> AgentWording {
        (sessions[tabID]?.agent ?? Agents.standard).wording
    }

    /// Sends Claude's queued messages right away instead of after the step
    /// it's on, the way Ctrl+Return does in its terminal: Claude stops what
    /// it's doing and reads them.
    func sendQueueNow(tabID: UUID) -> String? {
        guard let session = sessions[tabID], session.isAgent, session.remoteHost == nil else {
            return "Queued messages can only be sent now for \(words(tabID).name) on this Mac."
        }
        guard let key = session.agent?.driver.sendQueueNowKey else { return "Queued messages can't be sent early here." }
        guard session.claudeState == .working else { return "\(words(tabID).name) already read those messages." }
        session.view.press(key)
        return nil
    }

    /// Takes every queued message back out of Claude Code, the way pressing
    /// Up in its empty message box does, clears the box, and queues the
    /// ones in `keep` again. Claude Code only gives the whole queue back at
    /// once, so dropping one means sending the rest again. Each step checks
    /// the screen, so nothing is deleted that isn't the queue.
    func takeBackQueue(queued: [String], keep: [String], tabID: UUID) async -> String? {
        guard let session = sessions[tabID], session.isAgent, session.remoteHost == nil else {
            return "Queued messages can only be changed for \(words(tabID).name) on this Mac."
        }
        guard let driver = session.agent?.driver, driver.takesBackQueue else { return "Queued messages can't be changed here." }
        guard session.claudeState == .working, !queued.isEmpty else {
            return "\(words(tabID).name) already read those messages."
        }
        guard let box = driver.messageBox(in: session.view.visibleText()) else {
            return "Couldn't find \(words(tabID).name)'s message box. Show the terminal to change the queue there."
        }
        guard box.isEmpty || driver.isQueueHint(box) else {
            return "There's text in \(words(tabID).name)'s message box in the terminal. Clear it first."
        }
        session.view.press(.upArrow)
        try? await Task.sleep(for: .milliseconds(400))
        let taken = driver.messageBox(in: session.view.visibleText()) ?? ""
        let first = queued[0].split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let expected = Self.squeezed(taken).hasPrefix(Self.squeezed(String(first.prefix(40))))
        guard !taken.isEmpty, !driver.isHint(taken) else {
            // Up did something else, like picking a message in a newer
            // Claude Code. Down puts it back.
            session.view.press(.downArrow)
            return "Couldn't take the queue back. Show the terminal and press Up there."
        }
        // Clear the box. Too many deletes do nothing once it's empty.
        let count = max(taken.count, queued.joined(separator: "\n").count) + 8
        for index in 0..<count {
            session.view.press(.backspace)
            if index % 40 == 39 { try? await Task.sleep(for: .milliseconds(15)) }
        }
        try? await Task.sleep(for: .milliseconds(300))
        if let left = driver.messageBox(in: session.view.visibleText()), !left.isEmpty, !driver.isHint(left) {
            return "\(words(tabID).name)'s message box didn't clear. Check the terminal."
        }
        // The turn ended first and Up brought back an older message
        // instead: the queue was already read, so don't send it twice.
        guard expected else { return "\(words(tabID).name) already read those messages." }
        for text in keep where !text.isEmpty {
            session.view.sendText(ComposerToken.readyToSend(text))
            try? await Task.sleep(for: .milliseconds(session.agent?.driver.returnDelay ?? 200))
            session.view.press(.returnKey)
            try? await Task.sleep(for: .milliseconds(400))
        }
        return nil
    }

    /// The next message Claude Code suggests, which it shows faintly in its
    /// empty message box after a turn. It only lives on screen, so Bench
    /// reads it there: text in the box with the cursor still at its start,
    /// unlike text you typed, which leaves the cursor after it.
    func promptSuggestion(tabID: UUID) -> String? {
        guard let session = sessions[tabID], session.isAgent, session.remoteHost == nil,
              session.claudeState != .working, session.claudeState != .waiting,
              agentIsUp(session, tabID: tabID), let driver = session.agent?.driver,
              let box = driver.messageBox(in: session.view.visibleText()), !box.isEmpty,
              !driver.isHint(box), !box.contains("\n"),
              let column = session.view.cursorColumn(), column <= 3 else { return nil }
        return box
    }

    /// Claude Code's permission mode, from the line under its message box.
    /// nil when it isn't Claude on this Mac, or the line isn't showing.
    func permissionMode(tabID: UUID) -> PermissionMode? {
        guard let session = sessions[tabID], session.isAgent, session.remoteHost == nil,
              agentIsUp(session, tabID: tabID) else { return nil }
        return session.agent?.driver.permissionMode(in: session.view.visibleText())
    }

    /// Switches Claude Code to `target` the way Shift-Tab does in its
    /// terminal, one press at a time, reading the mode line after each, so
    /// it stops on the right one whatever order this version uses. If the
    /// mode never comes up, it goes back to where it started. Returns the
    /// problem, if any.
    func setPermissionMode(_ target: PermissionMode, tabID: UUID) async -> String? {
        guard let session = sessions[tabID], session.isAgent, session.remoteHost == nil else {
            return "Modes can only be changed for \(words(tabID).name) on this Mac."
        }
        guard let key = session.agent?.driver.nextModeKey, let start = permissionMode(tabID: tabID) else {
            return "Couldn't find \(words(tabID).product)'s mode in its terminal. Show the terminal to change it there."
        }
        if start == target { return nil }
        guard session.claudeState != .waiting else {
            return "\(words(tabID).name) is asking you something. Answer it first."
        }
        var current = start
        var presses = 0
        // Bypass, auto, and the usual three: no cycle is longer than 6.
        while presses < 7 {
            session.view.press(key)
            presses += 1
            var next: PermissionMode?
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                next = permissionMode(tabID: tabID)
                if let next, next != current { break }
            }
            guard let next, next != current else {
                return "\(words(tabID).product) didn't change its mode. Show the terminal to change it there."
            }
            current = next
            if current == target { return nil }
            if current == start {
                return target == .bypass
                    ? "Bypass permissions is only available when \(words(tabID).name) starts with it, like claude --dangerously-skip-permissions."
                    : "\(target.name) isn't available in this \(words(tabID).name) session."
            }
        }
        return "Couldn't switch to \(target.name). Show the terminal to change it there."
    }

    /// Text without any spacing, to compare what's on screen (which wraps)
    /// with what was sent.
    nonisolated private static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// Answers Claude's multiple-choice picker by pressing the keys you
    /// would. See `answerSteps` for which.
    func answerQuestions(_ answers: [CompanionAnswer], tabID: UUID) -> String? {
        if let prompt = startupPrompt(tabID: tabID) { return answerStartup(answers, prompt: prompt, tabID: tabID) }
        if let plan = planApproval(tabID: tabID) { return answerPlan(answers, plan: plan, tabID: tabID) }
        guard let session = sessions[tabID], let questions = session.details?.questions else {
            return "\(words(tabID).name) isn't asking a question right now."
        }
        let steps: [AnswerStep]
        switch (session.agent?.driver ?? Agents.standard.driver).answerSteps(questions: questions, answers: answers) {
        case .success(let found): steps = found
        case .failure(let problem): return problem.message
        }
        session.markAnswered(continuing: true)
        // Keys go in one at a time, with a pause for the picker to redraw.
        Task { [weak session] in
            for step in steps {
                switch step {
                case .key(let key): session?.view.press(key)
                case .text(let text): session?.view.sendText(text)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return nil
    }

    /// A question the agent is asking in its terminal before its session
    /// starts, like whether to trust the folder. It asks before any hook
    /// runs, so Bench reads the screen to find out.
    func startupPrompt(tabID: UUID) -> StartupPrompt? {
        guard let session = sessions[tabID], session.isAgent, session.remoteHost == nil,
              !AgentSessions.isRunning(tabID: tabID),
              let driver = session.agent?.driver, let text = session.view.visibleText() else { return nil }
        return driver.startupPrompt(in: text)
    }

    /// Picks an answer to that question: moves to the option, checks on
    /// screen that the cursor got there, then confirms.
    private func answerStartup(_ answers: [CompanionAnswer], prompt: StartupPrompt, tabID: UUID) -> String? {
        guard let session = sessions[tabID], answers.count == 1, let choice = answers[0].selected.first,
              answers[0].selected.count == 1, answers[0].other == nil, prompt.answers.indices.contains(choice) else {
            return "Pick one of the choices."
        }
        let answer = prompt.answers[choice]
        Task { [weak session] in
            guard let session else { return }
            for key in answer.moves {
                session.view.press(key)
                try? await Task.sleep(for: .milliseconds(300))
            }
            if !answer.moves.isEmpty, let picked = answer.picked {
                guard StartupPrompt.cursorIsOn(picked, in: session.view.visibleText()) else { return }
            }
            session.view.press(answer.confirm)
        }
        return nil
    }

    /// True once the agent is up in a tab: its hooks have recorded a
    /// session, or (for an agent whose hooks wait for the first message)
    /// its message box is on screen.
    private func agentIsUp(_ session: TerminalSession, tabID: UUID) -> Bool {
        AgentSessions.isRunning(tabID: tabID) || session.agent?.driver.showsMessageBox(in: session.view.visibleText()) == true
    }

    /// Claude Code's "Would you like to proceed?" picker after it shows a
    /// plan, as a question you can answer from another device. Its hooks
    /// only say a plan is waiting, not what the choices are (they change
    /// between Claude Code versions), so Bench reads them off the screen.
    func planApproval(tabID: UUID) -> CompanionQuestion? {
        guard let session = sessions[tabID], session.isAgent, session.remoteHost == nil,
              session.claudeState == .waiting, session.details?.tool == .planApproval else { return nil }
        return session.agent?.driver.planApproval(in: session.view.visibleText())
    }

    /// Picks a choice in the plan picker by its number, or picks "Type
    /// here" and types your words, the way AskUserQuestion's own words go in.
    private func answerPlan(_ answers: [CompanionAnswer], plan: CompanionQuestion, tabID: UUID) -> String? {
        guard let session = sessions[tabID], answers.count == 1 else { return "Pick one choice for the plan." }
        let answer = answers[0]
        if let other = answer.other?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
            guard plan.allowsOther == true else { return "Pick one of the choices for the plan." }
            session.markAnswered(continuing: true)
            Task { [weak session] in
                session?.view.press(.digit(plan.options.count + 1))
                try? await Task.sleep(for: .milliseconds(250))
                session?.view.sendText(other)
                try? await Task.sleep(for: .milliseconds(250))
                session?.view.press(.returnKey)
            }
            return nil
        }
        guard answer.selected.count == 1, let choice = answer.selected.first, plan.options.indices.contains(choice) else {
            return "Pick one choice for the plan."
        }
        session.view.press(.digit(choice + 1))
        session.markAnswered(continuing: true)
        return nil
    }

    /// A session's effort level: the newer of one just sent from the chat
    /// and one set with /effort in the transcript, or else what the agent
    /// has saved for the model.
    nonisolated static func effort(sent: (level: String, at: Date)?, transcript: TranscriptInfo, saved: String?) -> String? {
        if let sent, sent.at > (transcript.effortAt ?? .distantPast) { return sent.level }
        return transcript.effort ?? saved
    }

    /// Sends your next prompt to a Claude tab that has finished, as if you'd
    /// typed it and pressed Return. Only when its hooks say Claude stopped,
    /// so the text can't land in a plain shell.
    @discardableResult
    func reply(_ text: String, tabID: UUID) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session = sessions[tabID], session.claudeState == .done else { return false }
        let driver = session.agent?.driver
        session.view.sendText(ComposerToken.readyToSend(driver?.typed(text) ?? text))
        // Let Claude take in the pasted text before pressing Return.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(driver?.returnDelay ?? 200)) { [weak session] in
            session?.view.press(.returnKey)
        }
        return true
    }

    /// True while a tab's shell is running `claude` but its hooks haven't
    /// reported in: it's still starting, or stuck on a question only its own
    /// terminal can answer. The chat shows it starting, and only brings up
    /// the terminal if that goes on.
    func isStartingClaude(tabID: UUID) -> Bool {
        guard let session = sessions[tabID], session.isAgent, session.remoteHost == nil,
              startupPrompt(tabID: tabID) == nil, !agentIsUp(session, tabID: tabID) else { return false }
        if session.agent?.driver.titleIsStarting(session.terminalTitle) == true { return true }
        // Before that, the new shell is still loading and hasn't run the
        // command typed into it.
        return session.launchedClaudeAt.map { Date().timeIntervalSince($0) < 10 } ?? false
    }

    /// Why a message from the phone can't be typed into a tab right now,
    /// or nil when it can. Text only goes where Claude is running and at
    /// its prompt (or busy: Claude Code queues what you type while it works).
    /// `here` words it for the chat view on this Mac, where the terminal
    /// is a click away.
    func companionReplyProblem(tabID: UUID, here: Bool = false) -> String? {
        guard let session = sessions[tabID], session.isAgent else { return "That isn't a \(words(tabID).name) tab." }
        guard session.remoteHost == nil else { return "This tab is logged in to \(session.remoteHost!). Messages can only be sent to \(words(tabID).name) on this Mac." }
        if let prompt = startupPrompt(tabID: tabID) {
            return "\(words(tabID).product) \(prompt.blocker). Answer that first."
        }
        // Claude restarted by hand in this tab (`claude --continue`) has no
        // hooks, but its message box on screen says typing is safe.
        guard agentIsUp(session, tabID: tabID)
                || Self.canTypeWithoutHooks(claudeInFront: session.claudeInFront, screen: session.view.visibleText(),
                                         driver: session.agent?.driver) else {
            // The shell is running `claude`, but its hooks haven't reported
            // in: it's still starting, or stuck on a question only its own
            // terminal can answer, like trusting a new folder.
            if isStartingClaude(tabID: tabID) || session.claudeInFront {
                return here
                    ? "\(words(tabID).name) is starting, or waiting on a question in its terminal. Show the terminal to answer it."
                    : "\(words(tabID).name) is starting, or waiting on a question in its terminal (like whether to trust a new folder). Open the tab on that Mac to answer it."
            }
            return here ? "\(words(tabID).name) isn't running in this tab. Show the terminal to start it." : "\(words(tabID).name) isn't running in this tab. Start it on the Mac first."
        }
        if session.claudeState == .waiting {
            return session.details?.isAllowOrDeny == true
                ? "\(words(tabID).name) is asking for permission. Allow or deny it first."
                : session.details?.questions != nil
                    ? "\(words(tabID).name) is asking you a question. Answer it first."
                    : here ? "\(words(tabID).name) is asking you something in the terminal. Show the terminal to answer it."
                    : "\(words(tabID).name) is asking you a question on the Mac. Answer it there first."
        }
        return nil
    }

    /// Whether a Claude with no hooks can take a message. Nothing reports
    /// its questions, and Return on one would answer it, so this needs
    /// its message box on screen and not a numbered choice.
    nonisolated static func canTypeWithoutHooks(claudeInFront: Bool, screen: String?, driver: (any AgentTerminalDriver)?) -> Bool {
        guard claudeInFront, let box = driver?.messageBox(in: screen) else { return false }
        return box.range(of: #"^\d+\.\s"#, options: .regularExpression) == nil
    }

    /// Types a message from the phone into a Claude tab and sends it.
    /// Returns the problem if it can't.
    @discardableResult
    func companionReply(_ text: String, images: [Data] = [], tabID: UUID, here: Bool = false) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pictures = AttachedPictures.save(images)
        guard !text.isEmpty || !pictures.isEmpty else { return "Nothing to send." }
        if let problem = companionReplyProblem(tabID: tabID, here: here) { return problem }
        guard let session = sessions[tabID] else { return "That tab is gone." }
        // Claude's "Switch model?" question would only show in the terminal.
        if text.hasPrefix("/model ") {
            AgentSessions.allowModelSwitch(tabID: tabID)
            Analytics.capture(.modelSwitched, ModelAnalytics.switchProperties(
                from: session.model, to: String(text.dropFirst("/model ".count)), fromPhone: !here))
        }
        // No hook fires for /effort, so show it right away.
        if let level = EffortLevel(command: text) {
            Analytics.capture(.effortSet, ["level": level.rawValue, "from_phone": !here])
            session.sentEffort = (level.rawValue, .now)
            session.effort = level.rawValue
        }
        // Return has to reach the message box, not a file picker left open.
        let driver = session.agent?.driver
        let pause = driver?.returnDelay ?? 200
        let typed = ComposerToken.readyToSend(driver?.typed(text) ?? text)
        if pictures.isEmpty {
            session.view.sendText(typed)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(pause)) { [weak session] in
                session?.view.press(.returnKey)
            }
            return nil
        }
        // Claude Code attaches a picture when its file's path is pasted
        // in, the same as dropping the file on a terminal, and shows it as
        // "[Image #1]". So each picture is saved to a temporary file and
        // the paths go in ahead of the words. The clipboard is left alone:
        // going through it set off anything watching for copied pictures.
        Task { [weak session] in
            if let paths = TerminalDrop.text(forPaths: pictures.map(\.path)) {
                session?.view.sendText(paths + " ")
            }
            // Give Claude Code time to read the files in before the words
            // and Return follow.
            try? await Task.sleep(for: .milliseconds(400 + 150 * pictures.count))
            if !text.isEmpty { session?.view.sendText(typed) }
            try? await Task.sleep(for: .milliseconds(max(250, pause)))
            session?.view.press(.returnKey)
        }
        return nil
    }

    /// When a kept tab's relay ends because its keeper went away, starts
    /// the tab again in place, instead of closing it as when Claude and the
    /// shell exit. Claude resumes its conversation. False if the keeper
    /// is still the same one, so the session really ended.
    func restartIfKeeperLost(_ session: TerminalSession) -> Bool {
        guard SessionKeeper.currentInstance() != session.keeperInstance,
              let project = store?.project(session.projectID),
              let tab = project.tabs.first(where: { $0.id == session.tabID }) else { return false }
        RestartRecovery.shared.noteStopped(tab.id)
        sessions[tab.id] = nil
        session.view.removeFromSuperview()
        session.view.close()
        _ = self.session(for: tab, in: project)
        return true
    }

    /// Frees sessions whose tabs no longer exist.
    func prune(keeping tabIDs: Set<UUID>) {
        for (id, session) in sessions where !tabIDs.contains(id) {
            // Closing the window only lets go of the relay.
            if session.isKept { SessionKeeper.end(id) }
            session.view.removeFromSuperview()
            session.view.close()
            sessions[id] = nil
        }
        let marked = markedUnreadTabs.intersection(tabIDs)
        if marked != markedUnreadTabs {
            markedUnreadTabs = marked
            saveMarkedUnread()
        }
        AgentSessions.prune(keeping: tabIDs)
        LocalChatSource.forget(except: tabIDs)
        SideQuestions.shared.forget(except: tabIDs)
    }

    func goToTab(_ tab: ghostty_action_goto_tab_e, in projectID: UUID) -> Bool {
        guard let store, let project = store.projects.first(where: { $0.id == projectID }) else { return false }
        // A split is one stop, like its one button in the tab bar.
        let stops = project.tabStops
        guard !stops.isEmpty else { return false }
        let selected = project.selectedTab.map { project.split(of: $0.id)?.first ?? $0.id }
        let current = stops.firstIndex { $0.id == selected } ?? 0
        let index: Int
        switch tab {
        case GHOSTTY_GOTO_TAB_PREVIOUS: index = (current - 1 + stops.count) % stops.count
        case GHOSTTY_GOTO_TAB_NEXT: index = (current + 1) % stops.count
        case GHOSTTY_GOTO_TAB_LAST: index = stops.count - 1
        default:
            let n = Int(tab.rawValue) - 1
            guard n >= 0, n < stops.count else { return false }
            index = n
        }
        store.selectTab(stops[index].id, in: projectID)
        return true
    }

    /// Asks before closing a tab where that would cut off work in progress.
    func confirmClose(_ tab: TabRecord) -> Bool {
        guard let session = sessions[tab.id], session.closingInterruptsWork else { return true }
        let alert = NSAlert()
        alert.messageText = "Close \(tab.title)?"
        alert.informativeText = session.isAgent
            ? "\(words(tab.id).name) is in the middle of something. Closing the tab will stop it."
            : "Something is still running in this tab. Closing it will stop it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks once before closing several tabs, if any of them is busy.
    func confirmClose(_ tabs: [TabRecord]) -> Bool {
        let busy = tabs.filter { sessions[$0.id]?.closingInterruptsWork == true }
        guard !busy.isEmpty else { return true }
        if tabs.count == 1 { return confirmClose(tabs[0]) }
        let alert = NSAlert()
        alert.messageText = "Close \(tabs.count) tabs?"
        alert.informativeText = busy.count == 1
            ? "\(busy[0].displayTitle) is still working. Closing it will stop it."
            : "\(busy.count) of them are still working. Closing them will stop them."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// True if the tab's terminal is running something besides an idle shell.
    func isRunning(_ tabID: UUID) -> Bool {
        sessions[tabID]?.view.needsConfirmQuit ?? false
    }

    /// True if closing any tab right now would cut off work in progress.
    var anyClosingInterruptsWork: Bool {
        sessions.values.contains(where: \.closingInterruptsWork)
    }

    /// True while Claude is working or waiting on you in any tab. Unlike
    /// `anyClosingInterruptsWork`, a dev server in a shell doesn't count.
    /// Whether Claude is working or waiting on you in a project or any of
    /// its worktrees. Keeps a project under Active however long a run goes.
    func isClaudeBusy(inProject rootID: UUID) -> Bool {
        sessions.values.contains { session in
            session.isAgent && (session.isWorking || session.claudeState == .waiting)
                && store?.rootID(of: session.projectID) == rootID
        }
    }

    /// True if closing this tab would cut off work in progress.
    func tabIsWorking(_ tabID: UUID) -> Bool {
        sessions[tabID]?.closingInterruptsWork ?? false
    }

    var anyClaudeBusy: Bool {
        sessions.values.contains { $0.isAgent && $0.closingInterruptsWork }
    }

    /// "Recipes (Claude)" for each tab that quitting would cut off, Claude
    /// tabs first. Leaves out tabs in `skipping`.
    func busyTabNames(skipping: Set<UUID> = []) -> (claude: [String], programs: [String]) {
        var claude: [String] = []
        var programs: [String] = []
        for project in store?.projects ?? [] {
            for tab in project.tabs where !skipping.contains(tab.id) {
                guard let session = sessions[tab.id], session.closingInterruptsWork else { continue }
                let name = project.tabs.filter { $0.isTerminal }.count > 1 ? "\(project.name) (\(tab.displayTitle))" : project.name
                if session.isAgent { claude.append(name) } else { programs.append(name) }
            }
        }
        return (claude, programs)
    }

    // MARK: Quitting

    /// Tabs that a quit leaves running: kept tabs whose sessions the keeper
    /// says are alive. Asks the keeper, so call it once per decision.
    /// None once Keep Working is turned off, or for Quit Workbench
    /// Completely, so they stop as usual.
    func tabsKeptThroughQuit() -> Set<UUID> {
        guard SessionKeeper.isEnabled, !SessionKeeper.endsSessionsAtQuit, let live = SessionKeeper.liveTabs() else { return [] }
        return Set(sessions.filter { $0.value.isKept && live.contains($0.key) }.keys)
    }

    /// Like `anyClosingInterruptsWork`, for quitting: kept tabs carry on.
    func quitInterruptsWork(keeping kept: Set<UUID>) -> Bool {
        sessions.contains { !kept.contains($0.key) && $0.value.closingInterruptsWork }
    }

    /// Like `anyClaudeBusy`, for quitting: kept tabs carry on.
    var anyClaudeBusyForQuit: Bool {
        let kept = tabsKeptThroughQuit()
        return sessions.contains { !kept.contains($0.key) && $0.value.isAgent && $0.value.closingInterruptsWork }
    }

    /// Every running session, for noting what a quit interrupts.
    func claudeSessionsForQuit() -> [(UUID, TerminalSession)] {
        sessions.map { ($0.key, $0.value) }
    }

    /// Starts every Claude tab with a conversation to pick back up, so
    /// after a relaunch they all come back at once: for the Overview, the
    /// phone, and notifications, not just the tab you're looking at.
    /// A few at a time, so a dozen Claude Codes don't start in one go.
    func resumeClaudeTabs() {
        guard let store else { return }
        SessionKeeper.endLeftovers(keeping: store.allTabIDs)
        let resumes = UserDefaults.standard.object(forKey: Self.resumesAtLaunchKey) as? Bool ?? true
        var delay = 0.0
        for project in store.projects where FileManager.default.fileExists(atPath: project.path) {
            for tab in project.tabs where tab.kind == .agent && sessions[tab.id] == nil {
                // A tab still running in the keeper joins it whatever the
                // setting: Claude never stopped.
                if !SessionKeeper.wasRunningAtLaunch(tab.id) {
                    guard resumes, AgentSessions.hasResumableSession(tabID: tab.id) || RestartRecovery.shared.stopped[tab.id] != nil
                          || tab.initialPrompt != nil || tab.resumeSessionID != nil else { continue }
                }
                delay += 0.4
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let project = self.store?.project(project.id),
                          let tab = project.tabs.first(where: { $0.id == tab.id }) else { return }
                    _ = self.session(for: tab, in: project)
                }
            }
        }
    }

    static let resumesAtLaunchKey = "resumesClaudeTabsAtLaunch"
}


/// Pictures on their way to Claude Code, saved as files so their paths
/// can be pasted into its terminal.
enum AttachedPictures {
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Attached images", isDirectory: true)
    }

    /// Writes each picture to a temporary file and returns the files, in
    /// order. Data that isn't a picture is left out.
    static func save(_ pictures: [Data]) -> [URL] {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        clearOld()
        return pictures.compactMap { data in
            guard let (data, ext) = readable(data) else { return nil }
            let file = folder.appendingPathComponent("Attached image \(UUID().uuidString.prefix(8)).\(ext)")
            do { try data.write(to: file) } catch { return nil }
            return file
        }
    }

    /// The picture in a form Claude Code takes, with its file extension.
    /// PNG, JPEG, GIF and WebP go as they are, and anything else (HEIC,
    /// TIFF) becomes PNG.
    private static func readable(_ data: Data) -> (Data, String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else { return nil }
        for (kind, ext) in [(UTType.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.webP, "webp")] where type.conforms(to: kind) {
            return (data, ext)
        }
        guard let tiff = NSImage(data: data)?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }

    /// Claude Code reads a picture in when its path is pasted, so files
    /// from earlier messages aren't needed. A day's grace covers a message
    /// still queued.
    private static func clearOld() {
        let files = FileManager.default
        let old = Date().addingTimeInterval(-24 * 60 * 60)
        for file in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < old {
                try? files.removeItem(at: file)
            }
        }
    }
}
