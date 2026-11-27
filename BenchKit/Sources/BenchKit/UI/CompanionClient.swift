import Foundation
import Observation

/// One end of the WebSocket to Bench on a Mac: the phone's, or another
/// Mac's. Reconnects on its own with a growing delay, and keeps the last
/// snapshot so the list doesn't blank out while it does.
@MainActor
@Observable
public final class CompanionClient {
    /// Called with each message sent to a real Mac (not the demo), so the
    /// phone app can count replies and answers.
    @ObservationIgnored public var onSend: ((ClientMessage) -> Void)?

    public enum Status: Equatable, Sendable {
        case disconnected, connecting, connected
    }

    public private(set) var status: Status = .disconnected
    public private(set) var snapshot: ProjectsSnapshot?
    /// Sidebar icons as PNG data, by project.
    public private(set) var icons: [UUID: Data] = [:]
    public private(set) var macName: String?
    /// Why the last attempt failed, in plain words.
    public private(set) var problem: String?
    /// Set when the Mac speaks an older or newer version of the protocol.
    public private(set) var versionProblem: String?
    public private(set) var lastUpdate: Date?
    /// Each watched session's conversation, once the Mac has sent it.
    public private(set) var transcripts: [UUID: [TranscriptMessage]] = [:]
    /// Why the last reply or answer to a session didn't go through.
    public private(set) var sendProblems: [UUID: String] = [:]
    /// Each watched session's `/btw` side question, while one is showing.
    public private(set) var sideQuestions: [UUID: SideQuestion] = [:]
    @ObservationIgnored private var dismissedSideQuestions: Set<UUID> = []
    /// Whether each watched conversation goes back further than what's
    /// here, and whether the page before is on its way.
    public private(set) var earlierPages: [UUID: EarlierPages] = [:]
    public enum EarlierPages: Equatable, Sendable { case none, available, loading }
    /// Whole pictures that came back for `requestImage`, by id. A handful
    /// at a time: these are the big ones.
    public private(set) var fullImages: [String: TranscriptImage] = [:]
    @ObservationIgnored private var fullImageOrder: [String] = []
    @ObservationIgnored private var requestedImages: Set<String> = []
    @ObservationIgnored private var watched: Set<UUID> = []
    /// Which of those this connection has been asked for.
    @ObservationIgnored private var sentWatches: Set<UUID> = []
    /// Each watched project's git state.
    public private(set) var changes: [UUID: ChangesSnapshot] = [:]
    /// Diffs that came back, by "project:change". The last few dozen
    /// stay; a long session of tapping through changes used to keep them all.
    public private(set) var diffs: [String: [DiffLine]] = [:]
    @ObservationIgnored private var diffOrder: [String] = []
    @ObservationIgnored private var fileOrder: [String] = []
    @ObservationIgnored private var commitReviewOrder: [String] = []
    @ObservationIgnored private var watchedChanges: Set<UUID> = []
    /// The protocol version the Mac speaks, once it has said.
    public private(set) var serverVersion: Int?
    /// What the Mac offers beyond its protocol version.
    public private(set) var macFeatures: Set<String> = []
    /// Where the last project list from each Mac is kept, so it still
    /// shows after a cold launch while the Mac sleeps. Nil keeps nothing.
    @ObservationIgnored public var snapshotCache: SnapshotCache?
    /// When the projects showing were last heard from the Mac: read from
    /// the cache, or the time of the last live list.
    ///
    /// There are two ways to be showing an old list. After a cold launch
    /// the snapshot comes from disk, with no tabs, and counts as saved
    /// until the Mac answers. Partway through a run the snapshot in memory
    /// stays as it was, tabs and all, and counts as saved once a try to
    /// reach the Mac has failed. Coming back from the background tries
    /// again first, so the tabs don't vanish for the second that takes.
    /// The next live list replaces either.
    public private(set) var savedAt: Date?
    /// The snapshot showing came from disk, not from the Mac this run.
    private var isFromDisk = false
    /// A try to reach the Mac failed since it last answered. Until then
    /// an old list is shown as "connecting", not "asleep".
    public private(set) var hasFailedToReach = false
    /// The Mac turned down this pairing code, so it has a new one. Queuing
    /// is pointless until the phone pairs again: the Mac reads another
    /// mailbox now. Cleared by a welcome or a new pairing.
    public private(set) var needsRepair = false
    /// The features from the last time this Mac was connected, kept with
    /// the saved list.
    @ObservationIgnored private var cachedFeatures: Set<String> = []
    /// When the cache was last written, to skip writing the same list
    /// again with every update.
    @ObservationIgnored private var lastSaved: (saved: SavedMac, at: Date)?

    /// True when the projects showing are from before: the Mac is out of
    /// reach and there is a list from it to show.
    public var isShowingSaved: Bool {
        demo == nil && snapshot != nil && savedAt != nil && status != .connected && (isFromDisk || hasFailedToReach)
    }

    /// What the Mac offers: live when connected, and what it offered last
    /// time when it isn't. Tells the offline screens what to show.
    public var savedFeatures: Set<String> {
        status == .connected ? macFeatures : cachedFeatures
    }
    /// The Mac's terminal colors, when this client asked for them and the
    /// Mac is matching a theme. Kept while reconnecting, so the look holds.
    public private(set) var theme: TerminalColors?
    /// The Claude plan's limits, from Macs with the planUsage feature.
    public private(set) var planUsage: PlanUsage?
    /// Token use and API-price costs, from Macs with the usage feature.
    public private(set) var usage: CompanionUsage?
    /// The version of Workbench on the Mac, when it says.
    public private(set) var macAppVersion: String?
    /// Kinds of notifications this phone doesn't want. Kept on the phone
    /// and sent to each Mac it connects to.
    public var mutedNotifications: Set<CompanionNotificationKind> {
        get {
            access(keyPath: \.mutedNotifications)
            let raw = UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? []
            return Set(raw.compactMap(CompanionNotificationKind.init(rawValue:)))
        }
        set {
            withMutation(keyPath: \.mutedNotifications) {
                UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: Self.mutedKey)
            }
            sendNotificationPrefs()
        }
    }
    private static let mutedKey = "notifications.muted"
    /// The features this client uses, asked for when a Mac offers them.
    @ObservationIgnored private let wantedFeatures: Set<String>
    /// Each watched project's files, as folders.
    public private(set) var fileTrees: [UUID: FileTree] = [:]
    /// The same files as a flat list, for `@` suggestions in the chat.
    public private(set) var filePaths: [UUID: [String]] = [:]
    /// Projects with more files than the Mac lists.
    public private(set) var truncatedFiles: Set<UUID> = []
    /// Goes up when a watched project's files change.
    public private(set) var fileRevisions: [UUID: Int] = [:]
    /// Files that came back, by "project:path".
    public private(set) var fileContents: [String: FileContent] = [:]
    /// What to color in those files, by the same key, from a Mac with the
    /// codeReview feature.
    public private(set) var fileCode: [String: [CodeRun]] = [:]
    /// Commits asked for with `requestCommitReview`, by "project:hash".
    /// A missing key is loading; `.failed` means the Mac couldn't read it.
    public private(set) var commitReviews: [String: CommitReviewState] = [:]
    /// How many views are showing each project's files.
    @ObservationIgnored private var fileWatchers: [UUID: Int] = [:]
    /// Each project's past conversations, once asked for.
    public private(set) var pastSessions: [UUID: [PastSessionSummary]] = [:]
    /// Each project's published pages, once asked for.
    public private(set) var artifacts: [UUID: [ArtifactLink]] = [:]
    /// The Mac's day of agent work, by how many days back it is.
    public private(set) var days: [Int: CompanionDay] = [:]
    /// Each project's slash commands, once asked for.
    public private(set) var slashCommands: [UUID: [SlashCommand]] = [:]
    /// A tab the Mac just opened for us. The app navigates to it.
    public private(set) var started: (projectID: UUID, sessionID: UUID)?
    /// The last thing the Mac couldn't do for us.
    public private(set) var lastProblem: String?
    /// The Mac's answer to the last `splitTasks`, until the next one.
    public private(set) var taskSplit: TaskSplitResult?
    /// The Mac's answer to the last `startTasks`: which tasks didn't
    /// start, by id. Empty means all of them did.
    public private(set) var taskStartFailures: [UUID: String]?
    /// Why notifications aren't set up on this device, if they aren't.
    public private(set) var pushProblem: String?
    @ObservationIgnored private var pushToken: String?
    /// True in an app with a notification extension that opens sealed
    /// notifications, so the Mac seals them (see NotificationSeal).
    @ObservationIgnored public var opensSealedNotifications = false
    @ObservationIgnored private var dashboardToken: String?

    @ObservationIgnored private var task: (any CompanionSocket)?
    /// How this connection reached the Mac: set on the welcome, nil while
    /// there isn't one.
    public private(set) var path: ConnectionPath?
    /// True when the Mac has Tailscale too, so the phone can reach it away
    /// from home. False for a Mac paired without it.
    public private(set) var macHasTailscale = false
    /// The path of `task`, until its welcome sets `path`.
    @ObservationIgnored private var taskPath: ConnectionPath?
    /// Tailscale and the home network trying at once, until one wins.
    @ObservationIgnored private var attempt: PathAttempt?
    /// What was sent while the race had no socket yet. It goes out on the
    /// winner, after its hello.
    @ObservationIgnored private var outbox = RaceOutbox()
    /// This device said no to the local network. Not asked again until
    /// the next `connect`, which the phone does coming to the foreground.
    @ObservationIgnored private var localDenied = false
    /// Tailscale answered a quiet check, so the next connection goes
    /// straight to it.
    @ObservationIgnored private var tailscaleNext = false
    /// The quiet Tailscale check in flight, and the one-minute timer that
    /// runs it while on the home network.
    @ObservationIgnored private var tailscaleProbe: Task<Void, Never>?
    @ObservationIgnored private var tailscaleChecks: Task<Void, Never>?
    /// One session per pin, so each home-network attempt doesn't make
    /// another.
    @ObservationIgnored private var pinnedSession: (pin: String, session: URLSession, mismatches: PinMismatches)?
    @ObservationIgnored private var pairing: PairingInfo?
    /// The Mac said where its room on the relay is, or that it has none
    /// now. The app saves it with the pairing, by host.
    @ObservationIgnored public var onRelayChange: ((_ host: String, _ relay: RelayEndpoint?) -> Void)?
    @ObservationIgnored private var reconnect: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var wantsConnection = false
    /// Pings when nothing has come from the Mac for a while, and gives up
    /// on the connection when nothing comes back either.
    @ObservationIgnored private var keepalive: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = ContinuousClock.now
    /// Quiet for this long: ask. Quiet for three times as long: gone.
    static let quietBeforePing: Duration = .seconds(15)
    /// What this device calls itself in Bench's settings on the Mac.
    @ObservationIgnored private let deviceName: String
    /// Set while showing the demo: messages go to it instead of a Mac.
    @ObservationIgnored private var demo: DemoServer?
    public var isDemo: Bool { demo != nil }

    public init(deviceName: String, features: Set<String> = []) {
        self.deviceName = deviceName
        self.wantedFeatures = features
    }

    /// True when the Mac can stop Claude for us.
    public var canInterrupt: Bool { macFeatures.contains(CompanionFeature.interrupt) }

    /// Stops what Claude is doing in a session, as Escape does.
    public func interrupt(sessionID: UUID) {
        sendProblems[sessionID] = nil
        send(.interrupt(sessionID: sessionID))
    }

    /// True when the Mac can take queued messages back for us.
    public var canEditQueue: Bool { macFeatures.contains(CompanionFeature.editQueue) }

    /// Takes a session's queued messages back and queues `keep` again.
    public func takeBackQueue(sessionID: UUID, queued: [String], keep: [String]) {
        sendProblems[sessionID] = nil
        send(.takeBackQueue(sessionID: sessionID, queued: queued, keep: keep))
    }

    /// Switches a session's permission mode. Only for a session that
    /// reports one.
    public func setPermissionMode(sessionID: UUID, mode: PermissionMode) {
        sendProblems[sessionID] = nil
        send(.setPermissionMode(sessionID: sessionID, mode: mode.rawValue))
    }

    /// True when the Mac can send queued messages right away.
    public var canSendNow: Bool { macFeatures.contains(CompanionFeature.sendNow) }
    public var canPlaceProjects: Bool { macFeatures.contains(CompanionFeature.placement) }
    /// True when the Mac can skip kinds of notifications for this phone.
    public var canMuteNotifications: Bool { macFeatures.contains(CompanionFeature.notificationPrefs) }

    /// True when the Mac answers `/btw` side questions for us.
    public var canAskSideQuestions: Bool {
        macFeatures.contains(CompanionFeature.sideQuestions) && wantedFeatures.contains(CompanionFeature.sideQuestions)
    }

    /// Asks a side question about a session's conversation. It shows as
    /// asked right away; the Mac's answer replaces it as it comes in.
    public func askSideQuestion(sessionID: UUID, question: String) {
        guard canAskSideQuestions else { return }
        let asked = SideQuestion(question: question)
        sideQuestions[sessionID] = asked
        send(.askSideQuestion(sessionID: sessionID, id: asked.id, question: question))
    }

    /// Closes a session's side question, here and on the Mac.
    public func dismissSideQuestion(sessionID: UUID) {
        guard let question = sideQuestions.removeValue(forKey: sessionID) else { return }
        // Updates already on their way would bring it back.
        dismissedSideQuestions.insert(question.id)
        send(.dismissSideQuestion(sessionID: sessionID, id: question.id))
    }

    /// Sends a session's queued messages now, as Ctrl+Return does.
    public func sendQueueNow(sessionID: UUID) {
        sendProblems[sessionID] = nil
        send(.sendQueueNow(sessionID: sessionID))
    }

    /// The Mac this client is talking to, or trying to.
    public var host: String? { pairing?.host }

    public func connect(_ pairing: PairingInfo) {
        endDemo()
        let switching = self.pairing != nil && self.pairing?.host != pairing.host
        // The same Mac with a new code or certificate: whatever is open or
        // on its way uses the old ones, and on the home network an old
        // code's hello counts toward the Mac's guess limit.
        let repaired = !switching && self.pairing != nil
            && (self.pairing?.token != pairing.token || self.pairing?.local != pairing.local)
        if self.pairing != pairing {
            attempts = 0
            needsRepair = false
        }
        self.pairing = pairing
        wantsConnection = true
        localDenied = false
        if switching {
            // Everything we know is about the other Mac.
            forgetMac()
        }
        if switching || repaired {
            reconnect?.cancel()
            reconnect = nil
            cancelAttempt()
            endLocalChecks()
            tailscaleNext = false
            task?.close()
            task = nil
            path = nil
        }
        if snapshot == nil { loadSaved(host: pairing.host) }
        guard task == nil else {
            tryTailscaleQuietly()
            return
        }
        guard attempt == nil else { return }
        open()
    }

    /// Shows the list saved from this Mac, if there is one, until it answers.
    private func loadSaved(host: String) {
        guard demo == nil, let saved = snapshotCache?.load(host: host) else { return }
        snapshot = saved.snapshot
        savedAt = saved.savedAt
        isFromDisk = true
        cachedFeatures = saved.features
        if macName == nil { macName = saved.macName }
        lastSaved = (saved, saved.savedAt)
    }

    /// Writes what's showing to the cache, with the time its projects were
    /// heard. The same list is written again only once a minute, so its
    /// time stays close without a write per update.
    private func saveSnapshot(heardAt: Date) {
        guard demo == nil, let snapshotCache, let host = pairing?.host, let snapshot else { return }
        let now = Date.now
        let saved = SavedMac(snapshot: snapshot.withoutSessions, features: macFeatures, macName: macName, savedAt: heardAt)
        if let last = lastSaved, last.saved.snapshot == saved.snapshot, last.saved.features == saved.features,
           last.saved.macName == saved.macName, now.timeIntervalSince(last.at) < 60 { return }
        snapshotCache.save(saved, host: host)
        lastSaved = (saved, now)
    }

    /// Clears what's in memory. The saved list on disk stays: unpairing
    /// removes that.
    private func forgetMac() {
        snapshot = nil
        savedAt = nil
        isFromDisk = false
        hasFailedToReach = false
        cachedFeatures = []
        lastSaved = nil
        icons = [:]
        macName = nil
        problem = nil
        versionProblem = nil
        lastUpdate = nil
        transcripts = [:]
        earlierPages = [:]
        sendProblems = [:]
        sideQuestions = [:]
        fullImages = [:]
        fullImageOrder = []
        requestedImages = []
        watched = []
        changes = [:]
        diffs = [:]
        watchedChanges = []
        serverVersion = nil
        macFeatures = []
        macHasTailscale = false
        theme = nil
        planUsage = nil
        usage = nil
        macAppVersion = nil
        fileTrees = [:]
        filePaths = [:]
        truncatedFiles = []
        fileRevisions = [:]
        fileContents = [:]
        fileWatchers = [:]
        pastSessions = [:]
        artifacts = [:]
        days = [:]
        slashCommands = [:]
        started = nil
        lastProblem = nil
        taskSplit = nil
        taskStartFailures = nil
    }

    /// Shows sample projects from `DemoServer` instead of a real Mac.
    public func startDemo() {
        disconnect()
        forgetMac()
        pairing = nil
        let server = DemoServer()
        demo = server
        server.output = { [weak self] message in self?.apply(message) }
        server.start()
    }

    private func endDemo() {
        guard let demo else { return }
        demo.stop()
        self.demo = nil
        forgetMac()
        status = .disconnected
    }

    public func disconnect() {
        endDemo()
        wantsConnection = false
        reconnect?.cancel()
        reconnect = nil
        cancelAttempt()
        endLocalChecks()
        task?.close()
        task = nil
        path = nil
        sentWatches = []
        status = .disconnected
    }

    /// Tries again right now, for pull to refresh. A connection that's up
    /// is left alone: tearing it down lost the open conversations for a
    /// moment and had the Mac send them all again.
    public func retry() {
        guard demo == nil else { return }
        guard status != .connected else {
            tryTailscaleQuietly()
            return
        }
        reconnect?.cancel()
        reconnect = nil
        attempts = 0
        // Asking again by hand: the setting may have changed since.
        localDenied = false
        cancelAttempt()
        task?.close()
        task = nil
        if wantsConnection { open() }
    }

    private func open() {
        guard let pairing, attempt == nil else { return }
        let tailscale = pairing.socketURL
        let local = localDenied ? nil : pairing.local
        let relay = relayRoom(of: pairing)
        // With only Tailscale to try, or once Tailscale has just answered,
        // this is the plain Tailscale connection it always was.
        if let tailscale, (local == nil && relay == nil) || tailscaleNext {
            tailscaleNext = false
            status = .connecting
            let task = URLSession.shared.webSocketTask(with: tailscale)
            self.task = task
            taskPath = .tailscale
            task.start()
            send(.hello(token: pairing.token, device: deviceName))
            Task { await receive(on: task) }
            return
        }
        if local == nil, relay == nil {
            // Nowhere to go, as before.
            guard pairing.local != nil else { return }
            // A home-network-only Mac, and this device said no to looking.
            // Trying again can't help until the setting changes, so don't.
            status = .disconnected
            hasFailedToReach = true
            problem = Self.plain(LocalResolver.Failure.denied)
            return
        }
        race(tailscale: tailscale, local: local, relay: relay, token: pairing.token)
    }

    // MARK: Sessions

    public func watch(sessionID: UUID) {
        watched.insert(sessionID)
        // The screen asks when it connects, and the welcome asks for every
        // watched session too: the Mac sent each opening twice.
        guard status == .connected, !sentWatches.contains(sessionID) else { return }
        sentWatches.insert(sessionID)
        send(.watchTranscript(sessionID: sessionID))
    }

    public func unwatch(sessionID: UUID) {
        watched.remove(sessionID)
        sentWatches.remove(sessionID)
        transcripts[sessionID] = nil
        earlierPages[sessionID] = nil
        guard status == .connected else { return }
        send(.unwatchTranscript(sessionID: sessionID))
    }

    public func reply(sessionID: UUID, text: String, attachments: [CompanionAttachment] = []) {
        sendProblems[sessionID] = nil
        if attachments.isEmpty {
            send(.reply(sessionID: sessionID, text: text))
        } else {
            send(.replyWithAttachments(sessionID: sessionID, text: text, attachments: attachments))
        }
    }

    public func answer(sessionID: UUID, allow: Bool) {
        sendProblems[sessionID] = nil
        send(.answer(sessionID: sessionID, allow: allow))
    }

    /// Answers Claude's multiple-choice questions, one answer per question.
    public func answerQuestions(sessionID: UUID, answers: [CompanionAnswer]) {
        sendProblems[sessionID] = nil
        send(.answerQuestions(sessionID: sessionID, answers: answers))
    }

    public func clearProblem(sessionID: UUID) {
        sendProblems[sessionID] = nil
    }

    /// Asks the Mac for the page of a conversation before what's here.
    /// It lands at the front of `transcripts`. Nothing happens while a
    /// page is on its way or when there's nothing earlier.
    public func requestEarlier(sessionID: UUID) {
        guard earlierPages[sessionID] == .available, let first = transcripts[sessionID]?.first,
              status == .connected, macFeatures.contains(CompanionFeature.paging) else { return }
        earlierPages[sessionID] = .loading
        send(.earlierTranscript(sessionID: sessionID, before: first.id))
    }

    /// Asks the Mac for the whole of a picture that came as a preview. It
    /// lands in `fullImages`. Asking again while one is on its way does nothing.
    public func requestImage(_ image: TranscriptImage) {
        guard image.isPreview, fullImages[image.id] == nil, !requestedImages.contains(image.id) else { return }
        guard status == .connected, macFeatures.contains(CompanionFeature.imagePreviews) else { return }
        requestedImages.insert(image.id)
        send(.image(imageID: image.id))
    }

    // MARK: Changes

    public func watchChanges(projectID: UUID) {
        watchedChanges.insert(projectID)
        guard status == .connected else { return }
        send(.watchChanges(projectID: projectID))
    }

    /// Whether something already asked for this project's changes, so a
    /// view that only borrows them knows not to stop them when it closes.
    public func isWatchingChanges(_ projectID: UUID) -> Bool { watchedChanges.contains(projectID) }

    /// The branches a new agent can start from, once the Mac has sent them.
    /// Nil from a Mac too old to send them.
    public func agentBases(projectID: UUID) -> [String]? {
        changes[projectID]?.branches
    }

    /// True when the Mac takes refreshes and base changes from the Changes panel.
    public var canControlBranches: Bool { macFeatures.contains(CompanionFeature.branchControls) }

    public func setBaseRef(projectID: UUID, ref: String?) {
        guard status == .connected, canControlBranches else { return }
        send(.setBaseRef(projectID: projectID, ref: ref))
    }

    public func refreshChanges(projectID: UUID) {
        guard status == .connected, canControlBranches else { return }
        send(.refreshChanges(projectID: projectID))
    }

    public func unwatchChanges(projectID: UUID) {
        watchedChanges.remove(projectID)
        changes[projectID] = nil
        // Diffs stay: opening one hides the changes list, and clearing them
        // here would throw away the diff that screen just asked for.
        guard status == .connected else { return }
        send(.unwatchChanges(projectID: projectID))
    }

    public func requestDiff(projectID: UUID, change: FileChange) {
        diffs["\(projectID):\(change.id)"] = nil
        send(.diff(projectID: projectID, change: change))
    }

    // MARK: Files

    /// True once the Mac is new enough to share its files.
    public var canBrowseFiles: Bool { (serverVersion ?? 0) >= 8 }

    /// Call when a view starts showing a project's files, and
    /// `unwatchFiles` when it stops. Several views can watch at once.
    public func watchFiles(projectID: UUID) {
        fileWatchers[projectID, default: 0] += 1
        guard fileWatchers[projectID] == 1, status == .connected, canBrowseFiles else { return }
        send(.watchFiles(projectID: projectID))
    }

    public func unwatchFiles(projectID: UUID) {
        guard let count = fileWatchers[projectID] else { return }
        if count > 1 {
            fileWatchers[projectID] = count - 1
            return
        }
        fileWatchers[projectID] = nil
        fileTrees[projectID] = nil
        filePaths[projectID] = nil
        truncatedFiles.remove(projectID)
        fileRevisions[projectID] = nil
        fileContents = fileContents.filter { !$0.key.hasPrefix("\(projectID):") }
        fileCode = fileCode.filter { !$0.key.hasPrefix("\(projectID):") }
        guard status == .connected, canBrowseFiles else { return }
        send(.unwatchFiles(projectID: projectID))
    }

    public func requestFile(projectID: UUID, path: String) {
        guard canBrowseFiles else { return }
        send(.readFile(projectID: projectID, path: path))
    }

    // MARK: Adding projects

    /// True once the Mac can add a folder as a project for us.
    public var canAddProjects: Bool { macFeatures.contains(CompanionFeature.addProject) }
    /// True when the other end is a Workbench host with no screen, like a
    /// Linux server, rather than a Mac running the app.
    public var isHeadless: Bool { macFeatures.contains(CompanionFeature.headless) }

    /// The folder last asked for with `browseFolder`.
    public private(set) var folder: FolderListing?
    /// The Mac's answer to `addProject`.
    public private(set) var addedProject: (path: String, projectID: UUID?, problem: String?)?

    /// Asks for the folders inside a folder on the Mac; nil is its home folder.
    public func browseFolder(_ path: String?) {
        guard canAddProjects else { return }
        send(.browseFolder(path: path))
    }

    /// Asks the Mac to add a folder as a project.
    public func addProject(path: String) {
        guard canAddProjects else { return }
        addedProject = nil
        send(.addProject(path: path))
    }

    /// Forgets the last folder and answer, when the picker closes.
    public func clearAddProject() {
        folder = nil
        addedProject = nil
    }

    // MARK: Editing files

    /// True once the Mac can save a file we edited.
    public var canEditFiles: Bool { macFeatures.contains(CompanionFeature.editFiles) }

    /// The Mac's answer to `saveFile`: the project, the path, and why it
    /// couldn't, or nil once it's on disk.
    @ObservationIgnored public var onFileSaved: ((UUID, String, String?) -> Void)?

    /// Asks the Mac to replace a text file with `text`. False when it
    /// can't be asked right now.
    @discardableResult
    public func saveFile(projectID: UUID, path: String, text: String) -> Bool {
        guard canEditFiles, status == .connected else { return false }
        send(.writeFile(projectID: projectID, path: path, text: text))
        return true
    }

    // MARK: Reviewing code

    /// True once the Mac colors code, sends diffs with the whole file
    /// around their changes, and shows a commit on one page.
    public var canReviewCode: Bool {
        macFeatures.contains(CompanionFeature.codeReview) && wantedFeatures.contains(CompanionFeature.codeReview)
    }

    public func requestCommitReview(projectID: UUID, hash: String) {
        guard canReviewCode else { return }
        commitReviews["\(projectID):\(hash)"] = nil
        send(.reviewCommit(projectID: projectID, hash: hash))
    }

    // MARK: Starting things

    public var canListCommands: Bool { macFeatures.contains(CompanionFeature.slashCommands) }

    public func loadSlashCommands(projectID: UUID) {
        guard canListCommands else { return }
        send(.slashCommands(projectID: projectID))
    }

    public var canShowDay: Bool { macFeatures.contains(CompanionFeature.day) }

    public func loadDay(daysBack: Int) {
        guard canShowDay else { return }
        send(.day(daysBack: daysBack))
    }

    public var canListArtifacts: Bool { macFeatures.contains(CompanionFeature.artifacts) }

    public func loadArtifacts(projectID: UUID) {
        guard canListArtifacts else { return }
        send(.artifacts(projectID: projectID))
    }

    public func loadPastSessions(projectID: UUID) {
        send(.pastSessions(projectID: projectID))
    }

    public func resume(projectID: UUID, sessionID: String) {
        lastProblem = nil
        send(.resumeSession(projectID: projectID, sessionID: sessionID))
    }

    public func newClaudeTab(projectID: UUID, prompt: String?) {
        lastProblem = nil
        send(.newClaudeTab(projectID: projectID, prompt: prompt))
    }

    public func reorderProjects(ids: [UUID]) {
        send(.reorderProjects(ids: ids))
    }

    public func pinProject(_ id: UUID, pinned: Bool) {
        send(.pinProject(projectID: id, pinned: pinned))
    }

    public func setProjectActive(_ id: UUID, active: Bool) {
        send(.setProjectActive(projectID: id, active: active))
    }

    /// True when the Mac takes every command in its projects' right-click menu.
    public var canEditProjects: Bool { macFeatures.contains(CompanionFeature.projectMenu) }

    /// An empty name goes back to the folder's.
    public func renameProject(_ id: UUID, to name: String) {
        guard canEditProjects else { return }
        send(.renameProject(projectID: id, name: name))
    }

    /// Nil goes back to the automatic icon.
    public func setProjectIcon(_ id: UUID, image: Data?, fileExtension: String?) {
        guard canEditProjects else { return }
        lastProblem = nil
        send(.setProjectIcon(projectID: id, image: image, fileExtension: fileExtension))
    }

    public func showHiddenWorktrees(of id: UUID) {
        guard canEditProjects else { return }
        send(.showHiddenWorktrees(projectID: id))
    }

    public func removeProject(_ id: UUID) {
        guard canEditProjects else { return }
        send(.removeProject(projectID: id))
    }

    public func hideExternalWorktree(_ id: UUID) {
        guard canEditProjects else { return }
        send(.hideExternalWorktree(projectID: id))
    }

    public func setNotifiesPhone(_ id: UUID, isOn: Bool) {
        guard canEditProjects else { return }
        send(.setNotifiesPhone(projectID: id, isOn: isOn))
    }

    public func setClaudeAccount(_ accountID: UUID, for id: UUID) {
        guard canEditProjects else { return }
        send(.setClaudeAccount(projectID: id, accountID: accountID))
    }

    /// True when the Mac can close Claude tabs and clean up agents for us.
    public var canManageAgents: Bool { macFeatures.contains(CompanionFeature.agentLifecycle) }
    public var canRunShortcuts: Bool { macFeatures.contains(CompanionFeature.shortcuts) }

    public func runShortcut(projectID: UUID, shortcutID: String) {
        guard status == .connected, canRunShortcuts else { return }
        lastProblem = nil
        send(.runShortcut(projectID: projectID, shortcutID: shortcutID))
    }

    public func stopShortcut(projectID: UUID, shortcutID: String) {
        guard status == .connected, canRunShortcuts else { return }
        lastProblem = nil
        send(.stopShortcut(projectID: projectID, shortcutID: shortcutID))
    }

    /// Closes a Claude tab on the Mac, ending Claude in it.
    public func closeSession(projectID: UUID, sessionID: UUID) {
        guard status == .connected, canManageAgents else { return }
        send(.closeSession(projectID: projectID, sessionID: sessionID))
    }

    /// Cleans up (after a merge) or discards an agent's worktree on the
    /// Mac: the folder is removed and the local branch is deleted.
    public func removeAgent(projectID: UUID, discard: Bool) {
        guard status == .connected, canManageAgents else { return }
        lastProblem = nil
        send(.removeAgent(projectID: projectID, discard: discard))
    }

    /// A nil `base` lets the Mac pick, as its own New Agent sheet would.
    public func newAgent(parentID: UUID, prompt: String, branch: String, base: String? = nil) {
        lastProblem = nil
        send(.newAgent(parentID: parentID, prompt: prompt, branch: branch, base: base))
    }

    public func clearStarted() {
        started = nil
    }

    /// True when the Mac can split a message into tasks and start them.
    public var canSendTasks: Bool { macFeatures.contains(CompanionFeature.sendTasks) }

    /// Asks the Mac to split one message into tasks. The answer lands in
    /// `taskSplit`, or in `lastProblem` if the Mac couldn't.
    public func splitTasks(message: String) {
        lastProblem = nil
        taskSplit = nil
        send(.splitTasks(message: message))
    }

    /// Asks the Mac to start an agent for each task. The answer lands in
    /// `taskStartFailures`.
    public func startTasks(_ tasks: [DraftTask]) {
        lastProblem = nil
        taskStartFailures = nil
        send(.startTasks(tasks))
    }

    /// Forgets the last split and start, when the screen closes.
    public func clearTaskSplit() {
        taskSplit = nil
        taskStartFailures = nil
    }

    public func clearLastProblem() {
        lastProblem = nil
    }

    // MARK: Notifications

    public func setPushToken(_ token: String) {
        pushToken = token
        pushProblem = nil
        if status == .connected {
            send(.registerPush(token: token, sealed: opensSealedNotifications ? true : nil))
            sendNotificationPrefs()
        }
    }

    private func sendNotificationPrefs() {
        guard let pushToken, status == .connected, canMuteNotifications else { return }
        send(.notificationPrefs(token: pushToken, muted: mutedNotifications.sorted { $0.rawValue < $1.rawValue }))
    }

    public func notePushProblem(_ text: String) {
        pushProblem = text
    }

    /// True when this Mac keeps a lock screen dashboard up to date.
    public var canShowDashboard: Bool { macFeatures.contains(CompanionFeature.dashboard) }

    /// Hands the Mac the dashboard's push token, or tells it the dashboard
    /// with that token ended.
    public func registerDashboard(token: String, ended: Bool = false) {
        dashboardToken = ended ? nil : token
        if status == .connected, canShowDashboard { send(.registerDashboard(token: token, ended: ended)) }
    }

    private func send(_ message: ClientMessage) {
        if let demo {
            demo.receive(message)
            return
        }
        if task == nil, attempt != nil {
            // Before the race picks a socket. Today's single socket queued
            // these behind the hello; this does the same.
            outbox.append(message)
            onSend?(message)
            return
        }
        if sendQueued(message) { onSend?(message) }
    }

    /// Puts a message on the socket, without counting it. False when
    /// there's no socket to put it on.
    @discardableResult
    private func sendQueued(_ message: ClientMessage) -> Bool {
        guard let task, let data = try? CompanionCoding.encoder.encode(message) else { return false }
        let sessionID = message.sessionIDIfReply
        task.sendData(data) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.task === task else { return }
                // What you were sending is gone with the connection; say
                // so where it was typed, then reconnect.
                if let sessionID { self.sendProblems[sessionID] = "Couldn't reach the Mac, so that wasn't sent." }
                self.failed(error)
            }
        }
        return true
    }

    /// Something the screen found out on its own about a reply, like a
    /// sent message the Mac never showed while the line was down.
    public func noteSendProblem(sessionID: UUID, _ text: String) {
        sendProblems[sessionID] = text
    }

    /// Every ten seconds while this task is the connection: a ping once
    /// the Mac has been quiet for a while, and the connection called
    /// failed once it's been quiet for far longer than a pong takes.
    private func startKeepalive(for task: any CompanionSocket) {
        keepalive?.cancel()
        lastHeard = .now
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.task === task else { return }
                let quiet = ContinuousClock.now - self.lastHeard
                if quiet > Self.quietBeforePing * 3 {
                    self.failed(KeepaliveLapse())
                    return
                }
                if quiet > Self.quietBeforePing { self.send(.ping) }
            }
        }
    }

    struct KeepaliveLapse: Error {}

    private func receive(on task: any CompanionSocket) async {
        while self.task === task {
            do {
                let data = try await task.receiveData()
                // Decoded off the main actor: a conversation's opening frame
                // can run to megabytes, and the screen shouldn't stall for it.
                // One frame at a time, so messages still apply in order.
                guard let data, let decoded = await Self.decode(data) else { continue }
                guard self.task === task else { return }
                apply(decoded)
            } catch {
                guard self.task === task else { return }
                failed(error)
                return
            }
        }
    }

    private nonisolated static func decode(_ data: Data) async -> ServerMessage? {
        await Task.detached(priority: .userInitiated) {
            Perf.measure("decode") { try? CompanionCoding.decoder.decode(ServerMessage.self, from: data) }
        }.value
    }

    func apply(_ message: ServerMessage) {
        lastHeard = .now
        switch message {
        case .welcome(let macName, let version, let features, let appVersion):
            if let task { startKeepalive(for: task) }
            self.macName = macName
            macAppVersion = appVersion
            serverVersion = version
            macFeatures = Set(features ?? [])
            path = demo == nil ? (taskPath ?? .tailscale) : nil
            // Macs from before the home network all used Tailscale. Newer
            // ones have it unless they were paired without.
            macHasTailscale = demo == nil && !(pairing?.isLocalOnly ?? false)
            // Off Tailscale: keep checking whether it answers, to move to it.
            if path == .local || path == .relay { startLocalChecks() } else { endLocalChecks() }
            if !macFeatures.contains(CompanionFeature.theme) { theme = nil }
            // Before asking for transcripts, so they come with results.
            let asked = wantedFeatures.intersection(macFeatures)
            if !asked.isEmpty { send(.features(asked.sorted())) }
            status = .connected
            attempts = 0
            problem = nil
            needsRepair = false
            versionProblem = version == companionProtocolVersion ? nil
                : version < companionProtocolVersion
                    ? "Workbench on that Mac is an older version. Relaunch Workbench there so it picks up the update."
                    : "This app is older than Workbench on that Mac. Install the new build here."
            // Pick the open conversations back up after a reconnect.
            for sessionID in watched { send(.watchTranscript(sessionID: sessionID)) }
            sentWatches = watched
            for projectID in watchedChanges { send(.watchChanges(projectID: projectID)) }
            if canBrowseFiles {
                for projectID in fileWatchers.keys { send(.watchFiles(projectID: projectID)) }
            }
            if let pushToken { send(.registerPush(token: pushToken, sealed: opensSealedNotifications ? true : nil)) }
            sendNotificationPrefs()
            if let dashboardToken, canShowDashboard { send(.registerDashboard(token: dashboardToken, ended: false)) }
            hasFailedToReach = false
            cachedFeatures = macFeatures
            // The projects aren't new yet: they come next. This keeps the
            // Mac's name and features, with the list's own time.
            saveSnapshot(heardAt: savedAt ?? .now)
        case .projects(let snapshot):
            self.snapshot = snapshot
            lastUpdate = .now
            savedAt = lastUpdate
            isFromDisk = false
            saveSnapshot(heardAt: lastUpdate ?? .now)
        case .icons(let data):
            icons = data
        case .relay(let endpoint):
            // Where to find this Mac through the relay from now on. The
            // connection that's open carries on as it is.
            guard var pairing, endpoint == nil || endpoint?.relayURL != nil, pairing.relay != endpoint else { break }
            pairing.relay = endpoint
            self.pairing = pairing
            onRelayChange?(pairing.host, endpoint)
        case .error(let text):
            problem = text
            if text == PairingInfo.rejectedMessage { needsRepair = true }
        case .pong:
            break
        case .transcript(let sessionID, let messages, let replaces, let hasMore):
            guard watched.contains(sessionID) else { return }
            if replaces {
                Perf.mark("transcriptOpened")
                transcripts[sessionID] = messages
                earlierPages[sessionID] = hasMore == true ? .available : .none
            } else {
                transcripts[sessionID, default: []].append(contentsOf: messages)
            }
        case .earlierTranscript(let sessionID, let messages, let hasMore):
            guard watched.contains(sessionID) else { return }
            transcripts[sessionID] = messages + (transcripts[sessionID] ?? [])
            earlierPages[sessionID] = hasMore ? .available : .none
        case .sent(let sessionID, let ok, let problem):
            if !ok { sendProblems[sessionID] = problem ?? "Workbench couldn't send that." }
        case .changes(let projectID, let snapshot):
            guard watchedChanges.contains(projectID) else { return }
            changes[projectID] = snapshot
        case .diff(let projectID, let changeID, let lines):
            diffs["\(projectID):\(changeID)"] = lines
            Self.cap(&diffs, order: &diffOrder, key: "\(projectID):\(changeID)", limit: 40)
        case .files(let projectID, let listing):
            guard fileWatchers[projectID] != nil else { return }
            fileTrees[projectID] = FileTree(paths: listing.paths)
            filePaths[projectID] = listing.paths
            if listing.truncated { truncatedFiles.insert(projectID) } else { truncatedFiles.remove(projectID) }
        case .fileRevision(let projectID, let revision):
            guard fileWatchers[projectID] != nil else { return }
            fileRevisions[projectID] = revision
        case .file(let projectID, let path, let content):
            guard fileWatchers[projectID] != nil else { return }
            fileContents["\(projectID):\(path)"] = content
            // Colors for the text before this one would land in the wrong places.
            fileCode["\(projectID):\(path)"] = nil
            Self.cap(&fileContents, order: &fileOrder, key: "\(projectID):\(path)", limit: 30)
            fileCode = fileCode.filter { fileContents[$0.key] != nil }
        case .fileCode(let projectID, let path, let runs):
            guard fileWatchers[projectID] != nil else { return }
            fileCode["\(projectID):\(path)"] = runs
        case .commitReview(let projectID, let hash, let review):
            commitReviews["\(projectID):\(hash)"] = review.map(CommitReviewState.loaded) ?? .failed
            Self.cap(&commitReviews, order: &commitReviewOrder, key: "\(projectID):\(hash)", limit: 20)
        case .pastSessions(let projectID, let sessions):
            pastSessions[projectID] = sessions
        case .slashCommands(let projectID, let commands):
            if slashCommands[projectID] != commands { slashCommands[projectID] = commands }
        case .sideQuestion(let sessionID, let question):
            if let question, dismissedSideQuestions.contains(question.id) { break }
            if sideQuestions[sessionID] != question { sideQuestions[sessionID] = question }
        case .day(let day):
            if days[day.daysBack] != day { days[day.daysBack] = day }
        case .artifacts(let projectID, let links):
            if artifacts[projectID] != links { artifacts[projectID] = links }
        case .started(let projectID, let sessionID):
            started = (projectID, sessionID)
        case .folder(let listing):
            folder = listing
        case .projectAdded(let path, let projectID, let problem):
            addedProject = (path, projectID, problem)
        case .fileSaved(let projectID, let path, let problem):
            onFileSaved?(projectID, path, problem)
        case .problem(let text):
            lastProblem = text
        case .theme(let colors):
            theme = colors
        case .planUsage(let usage):
            planUsage = usage
        case .usage(let usage):
            self.usage = usage
        case .morningSummary:
            break  // the feature is gone; older Macs may still send it
        case .taskSplit(let result):
            taskSplit = result
        case .tasksStarted(let failures):
            taskStartFailures = failures
        case .image(let image):
            requestedImages.remove(image.id)
            fullImages[image.id] = image
            fullImageOrder.removeAll { $0 == image.id }
            fullImageOrder.append(image.id)
            while fullImageOrder.count > 6, let oldest = fullImageOrder.first {
                fullImageOrder.removeFirst()
                fullImages[oldest] = nil
            }
        }
    }

    /// Keeps a cache of things asked for one at a time from growing
    /// without end: the oldest go once there are more than `limit`.
    private static func cap<Value>(_ cache: inout [String: Value], order: inout [String], key: String, limit: Int) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
    }

    func failed(_ error: Error) {
        keepalive?.cancel()
        keepalive = nil
        task = nil
        path = nil
        taskPath = nil
        endLocalChecks()
        sentWatches = []
        status = .disconnected
        hasFailedToReach = true
        // A Mac without Tailscale is only ever out of reach at home; the
        // Tailscale wording would send you looking in the wrong place.
        let error = pairing?.isLocalOnly == true && !(error is LocalResolver.Failure) && !(error is PinnedSession.Mismatch)
            && !(error is RelayError)
            ? LocalResolver.Failure.notFound : error
        if error is PinnedSession.Mismatch || (error as? RelayError) == .wrongPairing {
            needsRepair = true
            problem = Self.plain(error)
        } else if !needsRepair, problem == nil || attempts == 0 {
            // While the code needs replacing, that stays the reason shown.
            problem = Self.plain(error)
        }
        // A code the Mac turned down fails the same way next time, and on
        // the home network each try counts toward its guess limit. Wait
        // for a new pairing, or a retry by hand.
        guard wantsConnection, !needsRepair else { return }
        attempts += 1
        let delay = min(15, pow(2, Double(attempts - 1)))
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsConnection, self.task == nil else { return }
            self.open()
        }
    }

    /// For tests: a reconnect is waiting to run.
    var isReconnectScheduled: Bool { reconnect != nil }
    /// For tests: the socket in use or being opened, outside a race.
    var currentSocket: (any CompanionSocket)? { task }

    /// The home network Mac answered with a certificate other than the paired one.
    static let certificateChanged = "This Mac's code has changed. Scan it again."

    /// What a Mac without Tailscale looks like from away from home.
    static let localOnlyUnreachable = "Your Mac isn't on this network. It's asleep, or you're away from home."

    /// Turns URLSession's wording into something useful.
    static func plain(_ error: Error) -> String {
        switch error as? LocalResolver.Failure {
        case .denied:
            return "Workbench isn't allowed to look on your home network. Turn on Local Network for Workbench in Settings, under Privacy & Security."
        case .notFound:
            return localOnlyUnreachable
        case nil:
            break
        }
        if error is PinnedSession.Mismatch { return certificateChanged }
        switch error as? RelayError {
        case .hostOffline:
            return "Your Mac isn't connected. It's asleep, off, or offline."
        case .wrongPairing:
            return PairingInfo.rejectedMessage
        case .overLimit:
            return "This Mac has used today's allowance on the Workbench relay. It works again tomorrow, and on your home network until then."
        case .roomFull:
            return "Too many devices are connected to this Mac through the Workbench relay. Close Workbench on one of them."
        case .hostGone, .replaced, .relayRestarting, .tooLarge, .closed:
            return "Couldn't reach your Mac through the Workbench relay. Check that this device is online."
        case nil:
            break
        }
        if error is KeepaliveLapse {
            return "The Mac stopped answering. Is it awake, with Tailscale connected?"
        }
        if SecureConnection.isFailure(error) {
            return "Couldn't make a secure connection to the Mac. Check that HTTPS Certificates is on in your Tailscale admin console, then look at Tailscale in Workbench's settings on that Mac."
        }
        let reason = error.localizedDescription
        let lower = reason.lowercased()
        if lower.contains("hostname could not be found") || lower.contains("server with the specified hostname") {
            return "Can't find the Mac. Is Tailscale connected on this device?"
        }
        if lower.contains("could not connect") || lower.contains("connection refused") || lower.contains("bad gateway") {
            return "Found the Mac, but Workbench isn't answering. Is Workbench open there with the companion turned on?"
        }
        if (error as? URLError)?.code == .timedOut || lower.contains("timed out") {
            return "The Mac didn't answer in time. Check that it's awake, and that HTTPS Certificates is on in your Tailscale admin console."
        }
        if lower.contains("offline") || lower.contains("internet connection") {
            return "This device is offline."
        }
        return reason
    }
}

// MARK: Choosing a path

extension CompanionClient {
    /// The Mac's room on the relay, when the pairing has one and this app
    /// uses the relay.
    private func relayRoom(of pairing: PairingInfo) -> (url: URL, room: String)? {
        guard wantedFeatures.contains(CompanionFeature.relay), let relay = pairing.relay, let url = relay.relayURL else { return nil }
        return (url, relay.room)
    }

    /// How long the relay gets to answer once it has started.
    static let relayTimeout: TimeInterval = 12

    /// Starts Tailscale, gives it a head start, then starts the home
    /// network too, and the relay as the fallback. The first to answer its
    /// hello wins, with Tailscale ahead of the home network and both ahead
    /// of the relay when they answer close together; the others are
    /// closed. The winner then runs through the same receive loop as ever.
    private func race(tailscale: URL?, local: PairingInfo.LocalEndpoint?, relay: (url: URL, room: String)?, token: String) {
        status = .connecting
        let attempt = PathAttempt(race: ConnectionRace(hasTailscale: tailscale != nil, hasLocal: local != nil, hasRelay: relay != nil))
        self.attempt = attempt
        let hello = ClientMessage.hello(token: token, device: deviceName)
        if let tailscale {
            attempt.start(.tailscale, client: self, hello: hello) {
                URLSession.shared.webSocketTask(with: tailscale)
            }
        }
        let pinned = local.map { pinnedSession(for: $0.fingerprint) }
        // Only what this attempt's home network try runs into counts.
        _ = pinned?.1.take()
        attempt.driver = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.attempt === attempt else { return }
                let elapsed = attempt.elapsed
                if let local, let session = pinned?.0, !attempt.startedLocal, attempt.race.startsLocal(at: elapsed) {
                    attempt.startedLocal = true
                    attempt.start(.local, client: self, hello: hello) {
                        let url = try await LocalResolver.resolve(mac: local.mac, timeout: ConnectionRace.localTimeout - 1)
                        return session.webSocketTask(with: url)
                    }
                }
                if attempt.startedLocal, attempt.isOpen(.local), attempt.race.localTimedOut(at: elapsed) {
                    self.attemptFailed(.local, LocalResolver.Failure.notFound, in: attempt)
                    if self.attempt !== attempt { return }
                }
                if let relay, attempt.relayStartedAt == nil, attempt.race.startsRelay(at: elapsed) {
                    attempt.relayStartedAt = elapsed
                    attempt.start(.relay, client: self, hello: hello) {
                        RelayCompanionSocket(relay: relay.url, room: relay.room, token: token)
                    }
                }
                if let started = attempt.relayStartedAt, attempt.isOpen(.relay), elapsed - started >= Self.relayTimeout {
                    self.attemptFailed(.relay, URLError(.timedOut), in: attempt)
                    if self.attempt !== attempt { return }
                }
                if let winner = attempt.race.tick(at: elapsed) {
                    self.finish(attempt, winner: winner)
                    return
                }
                // The home network is out, and only Tailscale's own answer
                // or failure can end this now. Its worker reports either.
                guard attempt.race.waitsOnClock else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func pinnedSession(for pin: String) -> (URLSession, PinMismatches) {
        if let pinnedSession, pinnedSession.pin == pin { return (pinnedSession.session, pinnedSession.mismatches) }
        pinnedSession?.session.finishTasksAndInvalidate()
        let mismatches = PinMismatches()
        let session = PinnedSession.make(pin: pin, onMismatch: { mismatches.note() })
        pinnedSession = (pin, session, mismatches)
        return (session, mismatches)
    }

    fileprivate func attemptAnswered(_ path: ConnectionPath, _ message: ServerMessage, in attempt: PathAttempt) {
        guard self.attempt === attempt, attempt.isOpen(path) else { return }
        attempt.answers[path] = message
        if let winner = attempt.race.welcomed(path, at: attempt.elapsed) { finish(attempt, winner: winner) }
    }

    fileprivate func attemptFailed(_ path: ConnectionPath, _ error: Error, in attempt: PathAttempt) {
        guard self.attempt === attempt, attempt.isOpen(path) else { return }
        // Turned away by the pin: say that, not that the Mac wasn't found.
        var error = error
        if path == .local, pinnedSession?.mismatches.take() == true { error = PinnedSession.Mismatch() }
        if (error as? LocalResolver.Failure) == .denied { localDenied = true }
        attempt.errors[path] = error
        attempt.close(path)
        guard attempt.race.failed(path) else {
            // Tailscale failing early lets an answer from home win now.
            if let winner = attempt.race.tick(at: attempt.elapsed) { finish(attempt, winner: winner) }
            return
        }
        cancelAttempt()
        // All are out. When the relay itself said why (the Mac isn't
        // connected, the code is wrong), that's the answer. Otherwise say
        // what went wrong with Tailscale, as before, or with the home
        // network for a Mac that only has that.
        let relaySaid: Error? = switch attempt.errors[.relay] as? RelayError {
        case .hostOffline, .wrongPairing, .overLimit, .roomFull: attempt.errors[.relay]
        default: nil
        }
        // A certificate that changed is a reason to scan again, and wins
        // over anything vaguer. With a relay in the pairing, a device
        // that reached nothing is most likely offline, and the Tailscale
        // wording would send someone who doesn't use it looking for it.
        let pinChanged: Error? = attempt.errors[.local] is PinnedSession.Mismatch ? attempt.errors[.local] : nil
        let usual = pairing?.isLocalOnly == true ? attempt.errors[.local] : attempt.errors[.tailscale]
        let shown = relaySaid ?? pinChanged ?? attempt.errors[.relay] ?? usual
        failed(shown ?? error)
    }

    /// Hands the winner to the receive loop, with the answer it already had.
    private func finish(_ attempt: PathAttempt, winner: ConnectionPath) {
        guard self.attempt === attempt, let task = attempt.tasks[winner], let first = attempt.answers[winner] else { return }
        attempt.tasks[winner] = nil
        let queued = outbox.drain()
        cancelAttempt()
        self.task = task
        taskPath = winner
        // The winner's hello is already out, so these follow it as before.
        for message in queued { sendQueued(message) }
        apply(first)
        Task { await receive(on: task) }
    }

    func cancelAttempt() {
        attempt?.cancel()
        attempt = nil
        // Nothing will carry these now. Say so where they were typed.
        for sessionID in outbox.drain().compactMap(\.sessionIDIfReply) {
            sendProblems[sessionID] = "Couldn't reach the Mac, so that wasn't sent."
        }
    }

    // MARK: Back to Tailscale

    /// While on the home network, checks whether Tailscale answers. If it
    /// does, the client moves to it now when nothing's mid-reply, and on
    /// the next reconnect otherwise. Runs on `retry`, when the app comes
    /// back, and every minute.
    public func tryTailscaleQuietly() {
        // Once Tailscale has answered, the next connection uses it anyway.
        guard demo == nil, path == .local || path == .relay, tailscaleProbe == nil, !tailscaleNext,
              let pairing, let url = pairing.socketURL else { return }
        let hello = ClientMessage.hello(token: pairing.token, device: deviceName)
        tailscaleProbe = Task { [weak self] in
            let task = URLSession.shared.webSocketTask(with: url)
            task.start()
            let welcome = try? await Self.handshake(task, hello: hello, within: .seconds(10))
            // Whoever cancelled this has already let it go.
            guard let self, !Task.isCancelled else {
                task.close()
                return
            }
            self.tailscaleProbe = nil
            guard let welcome, case .welcome = welcome,
                  self.path == .local || self.path == .relay, self.pairing == pairing else {
                task.close()
                return
            }
            if self.isMidReply {
                task.close()
                self.tailscaleNext = true
                return
            }
            // Quiet: this check becomes the connection.
            let old = self.task
            self.task = task
            self.taskPath = .tailscale
            self.sentWatches = []
            old?.close()
            self.apply(welcome)
            Task { await self.receive(on: task) }
        }
    }

    /// True when a session you're looking at has Claude working, so
    /// changing connections now could drop part of its reply.
    private var isMidReply: Bool {
        guard let snapshot else { return false }
        return snapshot.projects.contains { project in
            project.sessions.contains { watched.contains($0.id) && ($0.activity == .working || $0.activity == .remoteWorking) }
        }
    }

    private func startLocalChecks() {
        guard tailscaleChecks == nil, pairing?.socketURL != nil else { return }
        tailscaleChecks = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                self.tryTailscaleQuietly()
            }
        }
    }

    private func endLocalChecks() {
        tailscaleChecks?.cancel()
        tailscaleChecks = nil
        tailscaleProbe?.cancel()
        tailscaleProbe = nil
    }

    /// Sends the hello and waits for the first answer. Nil if the
    /// connection fails or nothing comes in time.
    fileprivate nonisolated static func handshake(
        _ task: any CompanionSocket, hello: ClientMessage, within limit: Duration? = nil
    ) async throws -> ServerMessage {
        let exchange: @Sendable () async throws -> ServerMessage = {
            let data = try CompanionCoding.encoder.encode(hello)
            try await task.sendData(data)
            guard let bytes = try await task.receiveData(), let message = await decode(bytes) else {
                throw URLError(.cannotParseResponse)
            }
            return message
        }
        guard let limit else { return try await exchange() }
        let answer = await Deadline.first(within: limit) { try? await exchange() } onTimeout: { task.close() }
        guard let answer else { throw URLError(.timedOut) }
        return answer
    }
}

/// Messages sent while there's no socket yet, in order.
struct RaceOutbox {
    private(set) var messages: [ClientMessage] = []

    mutating func append(_ message: ClientMessage) { messages.append(message) }

    /// Everything waiting, oldest first, leaving it empty.
    mutating func drain() -> [ClientMessage] {
        defer { messages = [] }
        return messages
    }
}

/// One `open()`: the race, and each path's socket and answer so far.
@MainActor
private final class PathAttempt {
    var race: ConnectionRace
    let started = ContinuousClock.now
    var startedLocal = false
    /// When the relay started, in seconds since the attempt did.
    var relayStartedAt: TimeInterval?
    var tasks: [ConnectionPath: any CompanionSocket] = [:]
    var answers: [ConnectionPath: ServerMessage] = [:]
    var errors: [ConnectionPath: Error] = [:]
    private var workers: [ConnectionPath: Task<Void, Never>] = [:]
    var driver: Task<Void, Never>?

    init(race: ConnectionRace) { self.race = race }

    var elapsed: TimeInterval {
        let gone = ContinuousClock.now - started
        return Double(gone.components.seconds) + Double(gone.components.attoseconds) / 1e18
    }

    /// Still trying: hasn't answered or failed.
    func isOpen(_ path: ConnectionPath) -> Bool { answers[path] == nil && errors[path] == nil }

    /// Opens a path's socket, sends the hello and reports the first answer.
    func start(
        _ path: ConnectionPath, client: CompanionClient, hello: ClientMessage,
        makeTask: @escaping @MainActor () async throws -> any CompanionSocket
    ) {
        workers[path] = Task { [weak client] in
            do {
                let task = try await makeTask()
                // Timed out or lost the race while it was finding the Mac.
                guard !Task.isCancelled, self.isOpen(path) else { task.close(); throw CancellationError() }
                self.tasks[path] = task
                task.start()
                // The socket's own error, so the wording is what it always was.
                let answer = try await CompanionClient.handshake(task, hello: hello)
                client?.attemptAnswered(path, answer, in: self)
            } catch {
                client?.attemptFailed(path, error, in: self)
            }
        }
    }

    func close(_ path: ConnectionPath) {
        workers[path]?.cancel()
        tasks[path]?.close()
        tasks[path] = nil
    }

    func cancel() {
        driver?.cancel()
        workers.values.forEach { $0.cancel() }
        for task in tasks.values { task.close() }
        tasks = [:]
    }
}

/// A commit review the client asked for.
public enum CommitReviewState: Equatable, Sendable {
    case loaded(CommitReview)
    case failed
}

extension ClientMessage {
    /// The session a message is an answer or reply to, when it's one you
    /// typed and would want to know didn't go.
    var sessionIDIfReply: UUID? {
        switch self {
        case .reply(let sessionID, _), .replyWithAttachments(let sessionID, _, _),
             .answer(let sessionID, _), .answerQuestions(let sessionID, _):
            sessionID
        default:
            nil
        }
    }
}

/// Work with a time limit.
enum Deadline {
    /// What `work` comes back with, or nil once `limit` has passed, when
    /// `onTimeout` runs to stop it. `onTimeout` runs only if the time
    /// really ran out: the wait is cancelled when the work finishes first,
    /// and a cancelled wait that went on to stop the work would undo what
    /// just succeeded (it closed the socket that had just answered).
    nonisolated static func first<T: Sendable>(
        within limit: Duration, _ work: @escaping @Sendable () async -> T?, onTimeout: @escaping @Sendable () -> Void
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                do { try await Task.sleep(for: limit) } catch { return nil }
                onTimeout()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
