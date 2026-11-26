import BenchKit
import Foundation
import Network
import Observation

/// The WebSocket server the iPhone app talks to. Listens on localhost,
/// which Tailscale Serve puts on the tailnet, and, given a `LocalIdentity`,
/// on the home network too, over TLS with the Mac's own certificate. Every
/// second while a phone is connected it rebuilds the sidebar snapshot and
/// sends it if anything changed.
@Observable
final class CompanionServer {
    /// Set only for a second copy of Bench (a test run with
    /// BENCH_TEST_COMPANION_PORT, or an installed copy whose bundle id has
    /// a suffix), which then leaves Tailscale alone so it can't take over
    /// the real one's address.
    nonisolated static let testPort: UInt16? = {
        if let port = ProcessInfo.processInfo.environment["BENCH_TEST_COMPANION_PORT"].flatMap(UInt16.init) { return port }
        return BenchPaths.isSecondaryInstance ? 48801 : nil
    }()
    nonisolated static let port: UInt16 = testPort ?? 48800

    private(set) var isRunning = false
    private(set) var connectedDevices: [String] = []
    private(set) var lastError: String?
    /// Where the home network listener ended up, once it's ready.
    private(set) var localPort: UInt16?
    /// Why the home network listener last failed. It tries again by itself.
    private(set) var localError: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var localListener: NWListener?
    @ObservationIgnored private var identity: LocalIdentity?
    @ObservationIgnored private let advertises: Bool
    /// Between start() and stop(): while it's set, a failed home network
    /// listener is started again.
    @ObservationIgnored private var wantsLocal = false
    /// Between start() and stop(), so an identity that arrives late knows
    /// whether to start the home network listener.
    @ObservationIgnored private var isStarted = false
    /// Bad hellos on the home network listener, by address, against
    /// `throttledToken`. A new code starts the count over.
    @ObservationIgnored private var throttle = HelloThrottle()
    @ObservationIgnored private var throttledToken: String?
    /// The code before this one. A phone still using it isn't guessing.
    @ObservationIgnored private var previousToken: String?
    @ObservationIgnored private var clients: [ObjectIdentifier: Client] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastSnapshot: ProjectsSnapshot?
    /// What connected devices were last sent, at most a second old, or
    /// nil while nothing is connected.
    var latestSnapshot: ProjectsSnapshot? { lastSnapshot }
    @ObservationIgnored private var lastIcons: [UUID: Data] = [:]
    @ObservationIgnored private let snapshots: CompanionSnapshots
    @ObservationIgnored private let token: () -> String
    // Results are kept, and only go to clients that asked for them.
    @ObservationIgnored private let transcripts = TranscriptStreamer(options: .init(keepsResults: true, keepsQueue: true, keepsNotices: true, keepsTurnTimes: true))
    @ObservationIgnored private var lastTheme: TerminalColors?
    @ObservationIgnored private var lastPlanUsage: PlanUsage?
    @ObservationIgnored private var lastChanges: [UUID: ChangesSnapshot] = [:]
    /// What each client was last sent about a project's files.
    @ObservationIgnored private var sentFiles: [ObjectIdentifier: [UUID: FileListing]] = [:]
    @ObservationIgnored private var sentRevisions: [ObjectIdentifier: [UUID: Int]] = [:]
    /// Set by the companion, which keeps the push tokens.
    @ObservationIgnored var onRegisterPush: ((_ token: String, _ device: String, _ sealed: Bool) -> Void)?
    @ObservationIgnored var onRegisterDashboard: ((_ token: String, _ ended: Bool) -> Void)?
    /// This Mac's room on the relay, or nil when the relay is off. Set by
    /// the companion.
    @ObservationIgnored var relayEndpoint: (() -> RelayEndpoint?)?
    /// Counts of what went through the relay, for the daily usage total.
    @ObservationIgnored var onRelayUsage: ((RelayUsage) -> Void)?
    @ObservationIgnored var onNotificationPrefs: ((_ token: String, _ muted: [CompanionNotificationKind]) -> Void)?
    /// The usage and summary last sent, and when usage was last re-read.
    @ObservationIgnored private var lastUsage: CompanionUsage?
    @ObservationIgnored private var usageRefreshed = Date.distantPast
    /// Tabs whose side question changed and will be sent shortly.
    @ObservationIgnored private var pendingSideQuestions: Set<UUID> = []

    private final class Client {
        /// The socket, for a client that connected straight to this Mac.
        let connection: NWConnection?
        /// The sealed connection, for one that came through the relay.
        let relay: RelayHostConnection?
        /// Messages on their way out through the relay, in order.
        private var relayOutgoing: AsyncStream<Data>.Continuation?
        /// Came in on the home network listener rather than through Tailscale.
        let isLocal: Bool
        /// The remote host, which the throttle goes by.
        let address: String
        var device: String?
        var isAuthorized: Bool { device != nil }
        /// Claude tabs whose conversations this phone is showing.
        var watching: Set<UUID> = []
        /// Projects whose Changes screen this phone is showing.
        var watchingChanges: Set<UUID> = []
        /// File monitors this client is holding, by project.
        var watchingFiles: [UUID: FileListMonitor] = [:]
        /// The features it asked for, from the ones the welcome listed.
        var features: Set<String> = []
        /// When it last sent anything. A client that pings keeps this
        /// fresh; one that goes quiet for a minute has gone away.
        var lastHeard = Date.now
        var keepsAlive: Bool { features.contains(CompanionFeature.keepalive) }
        /// Transcript frames in flight, in order. Making previews of a
        /// frame's pictures takes a moment, and a frame with none mustn't
        /// overtake one with some.
        private var transcriptChain: Task<Void, Never>?
        init(relay: RelayHostConnection, sent: @escaping @Sendable (Int) -> Void) {
            connection = nil
            self.relay = relay
            isLocal = false
            address = "relay"
            // One task sends everything, so messages keep their order.
            let (stream, outgoing) = AsyncStream<Data>.makeStream()
            relayOutgoing = outgoing
            Task {
                for await data in stream {
                    if (try? await relay.send(data)) != nil { sent(data.count) }
                }
            }
        }

        func sendThroughRelay(_ data: Data) { relayOutgoing?.yield(data) }

        func close() {
            connection?.cancel()
            relayOutgoing?.finish()
            if let relay { Task { await relay.close() } }
        }

        init(connection: NWConnection, isLocal: Bool) {
            self.connection = connection
            relay = nil
            self.isLocal = isLocal
            if case .hostPort(let host, _) = connection.endpoint {
                address = "\(host)"
            } else {
                address = "\(connection.endpoint)"
            }
        }

        /// Runs `work` after everything enqueued before it has finished.
        func enqueueTranscript(_ work: @escaping @MainActor () async -> Void) {
            let previous = transcriptChain
            transcriptChain = Task { @MainActor in
                await previous?.value
                await work()
            }
        }

        /// Transcript messages as this client can take them: results and
        /// queued messages only if it asked for them.
        func fitted(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
            let results = features.contains(CompanionFeature.results), queue = features.contains(CompanionFeature.queue)
            let agents = features.contains(CompanionFeature.agents), turnTimes = features.contains(CompanionFeature.turnTimes)
            if results, queue, agents, turnTimes { return messages }
            return messages.filter {
                (results || $0.resultOf == nil) && (queue || $0.queue == nil) && (agents || $0.notice == nil) && (turnTimes || $0.worked == nil)
            }
        }
    }

    /// What this Mac offers beyond the protocol version.
    static let features = [CompanionFeature.turnTimes, CompanionFeature.results, CompanionFeature.interrupt, CompanionFeature.theme, CompanionFeature.queue, CompanionFeature.editQueue, CompanionFeature.agents, CompanionFeature.sendNow, CompanionFeature.placement, CompanionFeature.projectMenu, CompanionFeature.planUsage, CompanionFeature.artifacts, CompanionFeature.slashCommands,
                           CompanionFeature.notificationPrefs, CompanionFeature.usage,
                           CompanionFeature.imagePreviews, CompanionFeature.paging, CompanionFeature.sendTasks,
                           CompanionFeature.branchControls, CompanionFeature.agentLifecycle, CompanionFeature.shortcuts, CompanionFeature.dashboard,
                           CompanionFeature.codeReview, CompanionFeature.keepalive, CompanionFeature.offlineQueue,
                           CompanionFeature.localNetwork, CompanionFeature.sideQuestions, CompanionFeature.editFiles, CompanionFeature.addProject,
                           CompanionFeature.relay]

    /// The port this server listens on: the app's, unless a test picks
    /// a free one of its own.
    let listeningPort: UInt16

    /// `identity` turns on the home network listener; `advertises` puts it
    /// on Bonjour, which tests leave off.
    init(snapshots: CompanionSnapshots, token: @escaping () -> String, port: UInt16 = CompanionServer.port,
         identity: LocalIdentity? = nil, advertises: Bool = true) {
        self.snapshots = snapshots
        self.token = token
        self.listeningPort = port
        self.identity = identity
        self.advertises = advertises
    }

    private static func webSocketOptions() -> NWProtocolWebSocket.Options {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 32 << 20  // room for a few attached photos
        return webSocket
    }

    /// Hands over an identity that finished loading after init, as the
    /// app's does: it loads off the main actor. Starts the home network
    /// listener if the server is already running. Only the first one counts.
    func useIdentity(_ identity: LocalIdentity) {
        guard self.identity == nil else { return }
        self.identity = identity
        if isStarted {
            wantsLocal = true
            startLocal()
        }
    }

    /// The identity couldn't be loaded, so there's no home network listener.
    /// Shown where the listener's own failures are.
    func identityFailed(_ message: String) {
        localError = message
    }

    func start() {
        isStarted = true
        noteToken()
        if identity != nil {
            wantsLocal = true
            startLocal()
        }
        guard listener == nil else { return }
        SideQuestions.shared.onChange = { [weak self] tabID in self?.sideQuestionChanged(tabID) }
        lastError = nil
        let parameters = NWParameters.tcp
        // Only Tailscale's local proxy should be able to connect directly.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listeningPort)!)
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(Self.webSocketOptions(), at: 0)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    // A listener this server has since let go of.
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.isRunning = true
                    case .failed(let error):
                        // Only this listener. The home network one, and any
                        // phone on it, carry on: a clash on this port
                        // mustn't take the home path down too.
                        self.lastError = error.localizedDescription
                        listener.cancel()
                        self.listener = nil
                        self.isRunning = false
                    case .cancelled: self.isRunning = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The home network listener: every interface, a port the system
    /// picks, TLS with this Mac's certificate, and the same hello as the
    /// localhost one.
    private func startLocal() {
        guard let identity, wantsLocal, localListener == nil else { return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity.identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: .init())
        parameters.defaultProtocolStack.applicationProtocols.insert(Self.webSocketOptions(), at: 0)
        do {
            let listener = try NWListener(using: parameters, on: .any)
            if advertises {
                listener.service = NWListener.Service(name: identity.macID, type: "_workbench._tcp")
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    // A listener this server has since let go of.
                    guard let self, let listener, self.localListener === listener else { return }
                    switch state {
                    case .ready:
                        self.localPort = listener.port?.rawValue
                        self.localError = nil
                    case .waiting(let error):
                        // Often the Local Network permission turned off. It
                        // carries on by itself once it can; until then, say
                        // why instead of "Starting…".
                        self.localError = error.localizedDescription
                    case .failed(let error):
                        // Often a network change. Start over in a moment.
                        self.localError = error.localizedDescription
                        self.dropLocalListener()
                        self.retryLocal()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection, isLocal: true) }
            }
            listener.start(queue: .main)
            localListener = listener
        } catch {
            localError = error.localizedDescription
            retryLocal()
        }
    }

    private func dropLocalListener() {
        localListener?.cancel()
        localListener = nil
        localPort = nil
    }

    private func retryLocal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.startLocal() }
        }
    }

    func stop() {
        isStarted = false
        listener?.cancel()
        listener = nil
        wantsLocal = false
        dropLocalListener()
        // Each client the long way, so the file monitors it held are let go
        // of: cancelling the sockets alone left their FSEvents streams and
        // relists running for the rest of the process.
        for client in Array(clients.values) { remove(client) }
        clients.removeAll()
        connectedDevices = []
        isRunning = false
        stopTimer()
    }

    /// Sends the latest snapshot right away, for changes worth not waiting on.
    func sendNow() { tick() }

    // MARK: Connections

    /// Starts the guess count over when the code has changed since it was
    /// last looked at: after "Make a New Code", a phone that locked itself
    /// out with the old one has to get in with the new one.
    private func noteToken() {
        let current = token()
        guard current != throttledToken else { return }
        if let throttledToken { previousToken = throttledToken }
        throttledToken = current
        throttle = HelloThrottle()
    }

    private func accept(_ connection: NWConnection, isLocal: Bool = false) {
        let client = Client(connection: connection, isLocal: isLocal)
        if isLocal { noteToken() }
        if isLocal, throttle.isBlocked(client.address, at: .now) {
            connection.cancel()
            return
        }
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            MainActor.assumeIsolated {
                guard let self, let client else { return }
                switch state {
                case .failed, .cancelled: self.remove(client)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(client)
        // A connection that never says hello was kept for as long as the
        // socket lived. Fifteen seconds is plenty to send one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak client] in
            MainActor.assumeIsolated {
                guard let self, let client, !client.isAuthorized else { return }
                self.remove(client)
            }
        }
    }

    /// Takes a device that came through the relay. Its pairing code was
    /// already checked by the relay handshake, and its hello is checked
    /// again like anyone's.
    func accept(relay connection: RelayHostConnection) {
        let client = Client(relay: connection, sent: { [weak self] bytes in
            Task { @MainActor in self?.onRelayUsage?(.init(messagesOut: 1, bytesOut: bytes)) }
        })
        clients[ObjectIdentifier(client)] = client
        onRelayUsage?(.init(connections: 1))
        Task { [weak self, weak client] in
            do {
                for try await data in connection.messages {
                    guard let self, let client else { return }
                    self.onRelayUsage?(.init(messagesIn: 1, bytesIn: data.count))
                    self.handle(data, from: client)
                }
            } catch {}
            if let self, let client { self.remove(client) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak client] in
            MainActor.assumeIsolated {
                guard let self, let client, !client.isAuthorized else { return }
                self.remove(client)
            }
        }
    }

    /// Tells every client that asked where this Mac's room on the relay
    /// is now, or that it has none.
    func relayChanged() {
        let endpoint = relayEndpoint?()
        for client in clients.values where client.isAuthorized && client.features.contains(CompanionFeature.relay) {
            send(.relay(endpoint), to: client)
        }
    }

    /// True when a device is connected through the relay right now.
    var hasRelayClients: Bool { clients.values.contains { $0.relay != nil } }

    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.close()
        for monitor in client.watchingFiles.values { monitor.release() }
        client.watchingFiles = [:]
        sentFiles[ObjectIdentifier(client)] = nil
        sentRevisions[ObjectIdentifier(client)] = nil
        updateDevices()
        transcripts.forget(except: watchedTabs)
    }

    private func updateDevices() {
        connectedDevices = clients.values.compactMap(\.device).sorted()
        if connectedDevices.isEmpty { stopTimer() } else { startTimer() }
    }

    private func receive(_ client: Client) {
        client.connection?.receiveMessage { [weak self, weak client] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, let client else { return }
                if error != nil {
                    self.remove(client)
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                switch metadata?.opcode {
                case .close:
                    self.remove(client)
                    return
                case .text, .binary:
                    if let data { self.handle(data, from: client) }
                default: break
                }
                self.receive(client)
            }
        }
    }

    private func handle(_ data: Data, from client: Client) {
        client.lastHeard = .now
        guard let message = try? CompanionCoding.decoder.decode(ClientMessage.self, from: data) else {
            send(.error("Couldn't read that message."), to: client)
            return
        }
        // Nothing but hello before the pairing code has been checked. The
        // cases below check too, but this way a new message can't forget.
        if !client.isAuthorized {
            guard case .hello = message else { return }
        }
        switch message {
        case .hello(let token, let device):
            if client.isLocal { noteToken() }
            // Guessed too often from there: no answer at all, right or wrong.
            if client.isLocal, throttle.isBlocked(client.address, at: .now) {
                remove(client)
                return
            }
            guard token == self.token() else {
                // The code from before is a phone that hasn't scanned the
                // new one yet, not a guess.
                if client.isLocal, token != previousToken { throttle.failed(from: client.address, at: .now) }
                send(.error(PairingInfo.rejectedMessage), to: client)
                // Give the error time to go out before closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak client] in
                    MainActor.assumeIsolated { if let client { self?.remove(client) } }
                }
                return
            }
            client.device = device.isEmpty ? "iPhone" : device
            updateDevices()
            if !UserDefaults.standard.bool(forKey: "analyticsPhonePaired") {
                UserDefaults.standard.set(true, forKey: "analyticsPhonePaired")
                Analytics.capture(.iphonePaired)
            }
            send(.welcome(macName: Host.current().localizedName ?? "Mac", protocolVersion: companionProtocolVersion,
                          features: Self.features,
                          appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String), to: client)
            let icons = snapshots.iconData()
            lastIcons = icons
            send(.icons(icons), to: client)
            let snapshot = snapshots.build()
            lastSnapshot = snapshot
            send(.projects(snapshot), to: client)
        case .ping:
            guard client.isAuthorized else { return }
            send(.pong, to: client)
        case .watchTranscript(let tabID):
            guard client.isAuthorized else { return }
            client.watching.insert(tabID)
            if client.features.contains(CompanionFeature.sideQuestions), let question = SideQuestions.shared.byTab[tabID] {
                send(.sideQuestion(sessionID: tabID, question: question), to: client)
            }
            guard let path = snapshots.transcriptPath(tabID: tabID) else {
                ChatTiming.note("remote asked, no transcript yet", tab: tabID)
                send(.transcript(sessionID: tabID, messages: [], replaces: true), to: client)
                return
            }
            let readStarted = ContinuousClock.now
            ChatTiming.note("remote asked for chat", tab: tabID)
            transcripts.opening(tabID: tabID, path: path) { [weak self, weak client] messages, hasMore in
                ChatTiming.note("remote chat read", tab: tabID,
                                details: "took=\((ContinuousClock.now - readStarted).milliseconds)ms messages=\(messages.count) hasMore=\(hasMore)")
                guard let self, let client else { return }
                sendTranscript(sessionID: tabID, messages: messages, replaces: true, hasMore: hasMore, to: client)
            }
        case .earlierTranscript(let tabID, let before):
            guard client.isAuthorized, client.watching.contains(tabID),
                  let path = snapshots.transcriptPath(tabID: tabID) else { return }
            transcripts.earlier(tabID: tabID, path: path, before: before, count: Self.pageSize) { [weak self, weak client] messages, hasMore in
                guard let self, let client else { return }
                sendTranscript(sessionID: tabID, messages: messages, earlier: true, hasMore: hasMore, to: client)
            }
        case .unwatchTranscript(let tabID):
            client.watching.remove(tabID)
            transcripts.forget(except: watchedTabs)
        case .reply(let tabID, let text):
            guard client.isAuthorized else { return }
            let problem = snapshots.reply(text, tabID: tabID)
            send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
        case .replyWithAttachments(let tabID, let text, let attachments):
            guard client.isAuthorized else { return }
            let problem = snapshots.reply(text, attachments: attachments, tabID: tabID)
            send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
        case .answer(let tabID, let allow):
            guard client.isAuthorized else { return }
            let problem = snapshots.answer(allow: allow, tabID: tabID)
            send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
            // The sidebar changes a moment later; don't make the phone wait a whole tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.tick() }
            }
        case .features(let wanted):
            guard client.isAuthorized else { return }
            client.features = Set(wanted).intersection(Self.features)
            if client.features.contains(CompanionFeature.relay) {
                send(.relay(relayEndpoint?()), to: client)
            }
            if client.features.contains(CompanionFeature.theme) {
                send(.theme(snapshots.themeColors()), to: client)
            }
            if client.features.contains(CompanionFeature.planUsage) {
                send(.planUsage(PlanUsageMonitor.shared.usage), to: client)
            }
            if client.features.contains(CompanionFeature.usage) {
                send(.usage(UsageLedger.shared.companionUsage()), to: client)
                refreshUsage(force: true)
            }
        case .interrupt(let tabID):
            guard client.isAuthorized else { return }
            let problem = snapshots.interrupt(tabID: tabID)
            send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.tick() }
            }
        case .askSideQuestion(let tabID, let id, let question):
            guard client.isAuthorized, client.features.contains(CompanionFeature.sideQuestions) else { return }
            if let problem = snapshots.askSideQuestion(question, id: id, tabID: tabID) {
                send(.sideQuestion(sessionID: tabID, question: SideQuestion(id: id, question: question, state: .failed, problem: problem)),
                     to: client)
            }
        case .dismissSideQuestion(let tabID, let id):
            guard client.isAuthorized, client.features.contains(CompanionFeature.sideQuestions) else { return }
            SideQuestions.shared.dismiss(tabID: tabID, id: id)
        case .sendQueueNow(let tabID):
            guard client.isAuthorized else { return }
            let problem = snapshots.sendQueueNow(tabID: tabID)
            send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.tick() }
            }
        case .setPermissionMode(let tabID, let raw):
            guard client.isAuthorized, let mode = PermissionMode(rawValue: raw) else { return }
            Task { [weak self, weak client] in
                guard let self, let client else { return }
                let problem = await snapshots.setPermissionMode(mode, tabID: tabID)
                send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
                tick()
            }
        case .takeBackQueue(let tabID, let queued, let keep):
            guard client.isAuthorized else { return }
            Task { [weak self, weak client] in
                guard let self, let client else { return }
                let problem = await snapshots.takeBackQueue(queued: queued, keep: keep, tabID: tabID)
                send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
            }
        case .answerQuestions(let tabID, let answers):
            guard client.isAuthorized else { return }
            let problem = snapshots.answer(answers, tabID: tabID)
            send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.tick() }
            }
        case .watchChanges(let projectID):
            guard client.isAuthorized else { return }
            client.watchingChanges.insert(projectID)
            snapshots.refreshChanges(projectID: projectID, olderThan: 2)
            snapshots.loadBranches(projectID: projectID)
            if let changes = snapshots.changes(projectID: projectID) {
                lastChanges[projectID] = changes
                send(.changes(projectID: projectID, snapshot: changes), to: client)
            }
        case .unwatchChanges(let projectID):
            client.watchingChanges.remove(projectID)
            if !watchedProjects.contains(projectID) { lastChanges[projectID] = nil }
        case .diff(let projectID, let change):
            guard client.isAuthorized else { return }
            Task { [weak self, weak client] in
                guard let self else { return }
                let lines = await snapshots.diff(projectID: projectID, change: change,
                                                 forReview: client?.features.contains(CompanionFeature.codeReview) == true)
                guard let client else { return }
                send(.diff(projectID: projectID, changeID: change.id, lines: lines), to: client)
            }
        case .reviewCommit(let projectID, let hash):
            guard client.isAuthorized, client.features.contains(CompanionFeature.codeReview), Self.isCommitHash(hash) else { return }
            Task { [weak self, weak client] in
                guard let self else { return }
                let review = await snapshots.commitReview(projectID: projectID, hash: hash)
                guard let client else { return }
                send(.commitReview(projectID: projectID, hash: hash, review: review), to: client)
            }
        case .watchFiles(let projectID):
            guard client.isAuthorized, client.watchingFiles[projectID] == nil,
                  let monitor = snapshots.fileMonitor(projectID: projectID) else { return }
            monitor.retain()
            client.watchingFiles[projectID] = monitor
            sendFiles(to: client)
        case .unwatchFiles(let projectID):
            client.watchingFiles.removeValue(forKey: projectID)?.release()
            sentFiles[ObjectIdentifier(client)]?[projectID] = nil
            sentRevisions[ObjectIdentifier(client)]?[projectID] = nil
        case .readFile(let projectID, let path):
            guard client.isAuthorized, let monitor = snapshots.fileMonitor(projectID: projectID) else { return }
            Task { [weak self, weak client] in
                // Only files the list offers: nothing ignored, nothing in
                // .git, nothing outside the project folder. If the list
                // isn't ready yet, wait for it rather than guess.
                let allowed = await Self.isListed(path, in: monitor)
                let url = monitor.root.appendingPathComponent(path)
                let content: FileContent = allowed
                    // Leave room under the 32 MB message limit for the encoding.
                    ? await Task.detached(priority: .userInitiated) { FileReader.read(url, imageLimit: 12 << 20) }.value
                    : .missing
                guard let self, let client else { return }
                send(.file(projectID: projectID, path: path, content: content), to: client)
                // The colors follow, so the text shows right away.
                if client.features.contains(CompanionFeature.codeReview), case .text(let text) = content,
                   let runs = await SyntaxColors.runs(in: text, path: path) {
                    send(.fileCode(projectID: projectID, path: path, runs: runs), to: client)
                }
            }
        case .writeFile(let projectID, let path, let text):
            guard client.isAuthorized, let monitor = snapshots.fileMonitor(projectID: projectID) else { return }
            Task { [weak self, weak client] in
                // The same files reading offers, and nothing a link in the
                // project points to outside it.
                var problem: String?
                if await Self.isListed(path, in: monitor) {
                    let root = monitor.root
                    problem = await Task.detached(priority: .userInitiated) {
                        Self.write(text, toPath: path, in: root)
                    }.value
                } else {
                    problem = "It's no longer in the project."
                }
                guard let self, let client else { return }
                send(.fileSaved(projectID: projectID, path: path, problem: problem), to: client)
            }
        case .image(let imageID):
            guard client.isAuthorized else { return }
            let paths = client.watching.compactMap { snapshots.transcriptPath(tabID: $0) }
            Task { [weak self, weak client] in
                guard let image = await ImagePreviews.shared.full(id: imageID, transcriptPaths: paths),
                      let self, let client else { return }
                send(.image(image), to: client)
            }
        case .registerPush(let token, let sealed):
            guard client.isAuthorized else { return }
            onRegisterPush?(token, client.device ?? "iPhone", sealed == true)
        case .notificationPrefs(let token, let muted):
            guard client.isAuthorized else { return }
            onNotificationPrefs?(token, muted)
        case .registerActivity, .registerActivityStart:
            // From phones that predate the dashboard. The Mac no longer
            // starts or follows a Live Activity per session.
            break
        case .registerDashboard(let token, let ended):
            guard client.isAuthorized, client.features.contains(CompanionFeature.dashboard) else { return }
            onRegisterDashboard?(token, ended)
        case .pastSessions(let projectID):
            guard client.isAuthorized else { return }
            Task { [weak self, weak client] in
                guard let self else { return }
                let sessions = await snapshots.pastSessions(projectID: projectID)
                guard let client else { return }
                send(.pastSessions(projectID: projectID, sessions: sessions), to: client)
            }
        case .slashCommands(let projectID):
            guard client.isAuthorized, let path = snapshots.projectPath(projectID) else { return }
            Task { [weak self, weak client] in
                let commands = await SlashCommandLibrary.shared.load(path: path)
                guard let self, let client else { return }
                send(.slashCommands(projectID: projectID, commands: commands), to: client)
            }
        case .artifacts(let projectID):
            guard client.isAuthorized, let path = snapshots.projectPath(projectID) else { return }
            Task { [weak self, weak client] in
                let links = await ArtifactLibrary.shared.load(path: path)
                guard let self, let client else { return }
                send(.artifacts(projectID: projectID, links: links), to: client)
            }
        case .resumeSession(let projectID, let sessionID):
            guard client.isAuthorized else { return }
            if let tab = snapshots.resume(projectID: projectID, sessionID: sessionID) {
                send(.started(projectID: projectID, sessionID: tab), to: client)
                tick()
            } else {
                send(.problem("Couldn't open that session. Is the project still in Workbench?"), to: client)
            }
        case .newClaudeTab(let projectID, let prompt):
            guard client.isAuthorized else { return }
            if let tab = snapshots.newClaudeTab(projectID: projectID, prompt: prompt) {
                send(.started(projectID: projectID, sessionID: tab), to: client)
                tick()
            } else {
                send(.problem("Couldn't open a tab. Is the project still in Workbench?"), to: client)
            }
        case .reorderProjects(let ids):
            guard client.isAuthorized else { return }
            snapshots.reorder(ids: ids)
            tick()
        case .pinProject(let id, let pinned):
            guard client.isAuthorized else { return }
            snapshots.store.setPinned(id, pinned)
            tick()
        case .setProjectActive(let id, let active):
            guard client.isAuthorized else { return }
            snapshots.store.setActive(id, active)
            tick()
        case .renameProject(let id, let name):
            guard client.isAuthorized else { return }
            snapshots.store.renameProject(id, to: name)
            tick()
        case .setProjectIcon(let id, let image, let fileExtension):
            guard client.isAuthorized, let project = snapshots.store.project(id) else { return }
            do {
                if let image {
                    try snapshots.icons.setIcon(data: image, fileExtension: fileExtension, for: project)
                } else {
                    try snapshots.icons.resetIcon(for: project)
                }
            } catch {
                send(.problem("Couldn't change the icon: \(error.localizedDescription)"), to: client)
            }
            tick()
        case .showHiddenWorktrees(let id):
            guard client.isAuthorized else { return }
            snapshots.store.showHiddenWorktrees(of: id)
            tick()
        case .browseFolder(let path):
            guard client.isAuthorized else { return }
            Task { [weak self, weak client] in
                let listing = await Task.detached(priority: .userInitiated) {
                    FolderListing.read(path, home: NSHomeDirectory())
                }.value
                guard let self, let client else { return }
                send(.folder(listing), to: client)
            }
        case .addProject(let path):
            guard client.isAuthorized else { return }
            let full = FolderListing.expand(path, home: NSHomeDirectory())
            // On its start page, as a project added there by hand would be
            // without the agent tab: nothing starts until it's asked for.
            switch snapshots.store.addProject(path: full, opensClaude: false, source: .otherMac) {
            case .added(let project), .alreadyHere(let project):
                tick()
                send(.projectAdded(path: full, projectID: project.id, problem: nil), to: client)
            case .notAFolder:
                send(.projectAdded(path: full, projectID: nil, problem: "There's no folder at \(full) on this Mac."), to: client)
            }
        case .removeProject(let id):
            guard client.isAuthorized, snapshots.store.project(id)?.isWorktree == false else { return }
            snapshots.store.removeProject(id)
            tick()
        case .hideExternalWorktree(let id):
            guard client.isAuthorized else { return }
            snapshots.store.hideExternalWorktree(id)
            tick()
        case .setNotifiesPhone(let id, let isOn):
            guard client.isAuthorized else { return }
            snapshots.store.setNotifiesPhone(id, isOn)
            tick()
        case .setClaudeAccount(let id, let accountID):
            guard client.isAuthorized, ClaudeAccounts.shared.profiles.contains(where: { $0.id == accountID }) else { return }
            snapshots.store.setClaudeAccount(accountID, for: id)
            tick()
        case .newAgent(let parentID, let prompt, let branch, let base):
            guard client.isAuthorized else { return }
            Task { [weak self, weak client] in
                guard let self else { return }
                do {
                    guard let started = try await snapshots.newAgent(parentID: parentID, prompt: prompt, branch: branch, base: base) else {
                        if let client { send(.problem("Couldn't start the agent. Is the project still in Workbench?"), to: client) }
                        return
                    }
                    if let client { send(.started(projectID: started.project, sessionID: started.tab), to: client) }
                    tick()
                } catch {
                    if let client { send(.problem(error.localizedDescription), to: client) }
                }
            }
        case .splitTasks(let message):
            guard client.isAuthorized, client.features.contains(CompanionFeature.sendTasks) else { return }
            let projects = TaskSplitter.projects(in: snapshots.store)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let repos = TaskSplitter.repos(in: snapshots.store)
            Task { [weak self, weak client] in
                var result = TaskSplitResult(message: message, tasks: [], projects: projects, existingBranches: [:])
                // From the phone there's no selected project to go by.
                switch await TaskSplitter.split(message, projects: projects, repos: repos, profile: .main()) {
                case .success(let tasks):
                    result.tasks = tasks
                    // Every project's branches, so a task moved to another
                    // project on the phone can be checked there too.
                    for project in projects {
                        if let repo = repos[project.id] {
                            result.existingBranches[project.id] = Array(await TaskSplitter.existingBranches(repo: repo))
                        }
                    }
                case .failure(let failure):
                    result.problem = failure.message
                }
                guard let self, let client else { return }
                send(.taskSplit(result), to: client)
            }
        case .setBaseRef(let projectID, let ref):
            guard client.isAuthorized, client.features.contains(CompanionFeature.branchControls),
                  ref.map(Self.isRefName) ?? true else { return }
            snapshots.setBaseRef(ref, projectID: projectID)
        case .closeSession(let projectID, let sessionID):
            guard client.isAuthorized, client.features.contains(CompanionFeature.agentLifecycle) else { return }
            if snapshots.closeSession(projectID: projectID, sessionID: sessionID) { tick() }
        case .removeAgent(let projectID, let discard):
            guard client.isAuthorized, client.features.contains(CompanionFeature.agentLifecycle) else { return }
            Task { [weak self, weak client] in
                guard let self else { return }
                do {
                    if try await snapshots.removeAgent(projectID: projectID) {
                        Analytics.capture(.agentRemoved, ["kind": discard ? "discard" : "clean_up", "from_phone": true])
                    }
                    tick()
                } catch {
                    if let client { send(.problem(error.localizedDescription), to: client) }
                }
            }
        case .runShortcut(let projectID, let shortcutID):
            guard client.isAuthorized, client.features.contains(CompanionFeature.shortcuts) else { return }
            _ = snapshots.runShortcut(projectID: projectID, shortcutID: shortcutID)
            tick()
        case .stopShortcut(let projectID, let shortcutID):
            guard client.isAuthorized, client.features.contains(CompanionFeature.shortcuts) else { return }
            snapshots.stopShortcut(projectID: projectID, shortcutID: shortcutID)
            tick()
        case .refreshChanges(let projectID):
            guard client.isAuthorized, client.features.contains(CompanionFeature.branchControls) else { return }
            snapshots.refreshNow(projectID: projectID)
        case .startTasks(let tasks):
            guard client.isAuthorized, client.features.contains(CompanionFeature.sendTasks) else { return }
            Task { [weak self, weak client] in
                guard let self else { return }
                let failures = await AgentLauncher.startAll(tasks, store: snapshots.store, terminals: snapshots.terminals)
                Analytics.capture(.agentStarted, ["kind": "send_tasks", "count": tasks.count - failures.count, "from_phone": true])
                if let client { send(.tasksStarted(failures: failures), to: client) }
                tick()
            }
        }
    }

    /// Replaces a project's text file for another Mac. Returns why it
    /// couldn't, or nil once it's written.
    nonisolated static func write(_ text: String, toPath path: String, in root: URL) -> String? {
        let target = root.appendingPathComponent(path).resolvingSymlinksInPath()
        let folder = root.resolvingSymlinksInPath().path
        guard target.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") else {
            return "It's a link to a file outside the project."
        }
        do {
            try FileDrafts.write(text, to: target)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// True when `path` is in the project's file list. Holds the monitor
    /// while waiting up to ten seconds for a list that hasn't loaded.
    static func isListed(_ path: String, in monitor: FileListMonitor) async -> Bool {
        let parts = path.split(separator: "/")
        guard !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".git") else { return false }
        if monitor.listing == nil {
            monitor.retain()
            defer { monitor.release() }
            for _ in 0..<100 where monitor.listing == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return monitor.listing?.paths.contains(path) ?? false
    }

    /// Sends a client whatever's new about the files it's watching.
    private func sendFiles(to client: Client) {
        let key = ObjectIdentifier(client)
        for (projectID, monitor) in client.watchingFiles {
            if let listing = monitor.listing, sentFiles[key]?[projectID] != listing {
                sentFiles[key, default: [:]][projectID] = listing
                send(.files(projectID: projectID, listing: listing), to: client)
            }
            if sentRevisions[key]?[projectID] != monitor.revision {
                sentRevisions[key, default: [:]][projectID] = monitor.revision
                send(.fileRevision(projectID: projectID, revision: monitor.revision), to: client)
            }
        }
    }

    /// How much of a conversation goes to a phone at a time, when it
    /// takes pages: about twenty turns with their steps and results.
    static let pageSize = 240

    /// Sends a client part of a conversation, as it can take it: results
    /// and queued messages only if it asked, pictures as previews if it
    /// asked for those, a page at a time if it asked for that. Frames go
    /// out in the order they were given.
    ///
    /// `replaces` is the opening (or a rewritten file), `earlier` a page
    /// before what the client has, neither an addition at the end.
    /// `hasMore` says whether the conversation goes back further than
    /// the first message sent.
    private func sendTranscript(sessionID: UUID, messages: [TranscriptMessage], replaces: Bool = false, earlier: Bool = false,
                                hasMore: Bool? = nil, to client: Client) {
        var fitted = client.fitted(messages)
        var hasMore = hasMore
        if replaces {
            if client.features.contains(CompanionFeature.paging) {
                if fitted.count > Self.pageSize {
                    fitted = Array(fitted.suffix(Self.pageSize))
                    hasMore = true
                }
            } else if hasMore == true {
                // No pages: a note stands in for what isn't there.
                fitted.insert(TranscriptMessage(id: "opening-note", role: .system, text: "Showing the most recent messages."), at: 0)
            }
        }
        guard replaces || earlier || !fitted.isEmpty else { return }
        func message(_ messages: [TranscriptMessage], hasMore: Bool?) -> ServerMessage {
            earlier ? .earlierTranscript(sessionID: sessionID, messages: messages, hasMore: hasMore ?? false)
                : .transcript(sessionID: sessionID, messages: messages, replaces: replaces, hasMore: replaces ? hasMore : nil)
        }
        // A frame past the client's limit (32 MB) ends the connection, and
        // the reconnect asks for the same frame again, forever. Keep the
        // newest messages that fit instead, and say there's more.
        func sendFitting(_ messages: [TranscriptMessage]) {
            var kept = messages, more = hasMore
            while true {
                guard let data = try? CompanionCoding.encoder.encode(message(kept, hasMore: more)) else { return }
                if data.count <= Self.frameBudget || kept.count <= 1 {
                    send(data: data, to: client)
                    return
                }
                NSLog("Bench: a \(data.count / 1_000_000) MB transcript frame is over budget; sending the newer half of its \(kept.count) messages")
                kept.removeFirst(kept.count / 2)
                more = true
                if replaces, !client.features.contains(CompanionFeature.paging), kept.first?.id != "opening-note" {
                    kept.insert(TranscriptMessage(id: "opening-note", role: .system, text: "Showing the most recent messages."), at: 0)
                }
            }
        }
        guard client.features.contains(CompanionFeature.imagePreviews) else {
            sendFitting(fitted)
            return
        }
        client.enqueueTranscript { [weak self, weak client] in
            let shrinkStarted = ContinuousClock.now
            let shrunk = await ImagePreviews.shared.shrink(fitted)
            guard let self, let client, client.watching.contains(sessionID) else { return }
            sendFitting(shrunk)
            if replaces {
                ChatTiming.note("remote chat sent", tab: sessionID,
                                details: "previews=\((ContinuousClock.now - shrinkStarted).milliseconds)ms messages=\(shrunk.count)")
            }
        }
    }

    /// A commit as the phone names one: hex, as git prints it. Anything
    /// else could be read by git as an option.
    nonisolated static func isCommitHash(_ hash: String) -> Bool {
        (4...64).contains(hash.count) && hash.allSatisfy { $0.isHexDigit }
    }

    /// A branch or remote name as git allows them, and never something git
    /// would take for an option.
    nonisolated static func isRefName(_ ref: String) -> Bool {
        !ref.isEmpty && !ref.hasPrefix("-") && !ref.contains("..") && ref.count <= 256
            && ref.allSatisfy { !$0.isWhitespace && !$0.isNewline && $0.asciiValue.map { $0 >= 32 && $0 != 127 } ?? true }
            && !ref.contains { ["~", "^", ":", "?", "*", "[", "\\"].contains(String($0)) }
    }

    private var watchedProjects: Set<UUID> {
        clients.values.reduce(into: Set<UUID>()) { $0.formUnion($1.watchingChanges) }
    }

    private var watchedTabs: Set<UUID> {
        clients.values.reduce(into: Set<UUID>()) { $0.formUnion($1.watching) }
    }

    /// The most a frame may be, under the 32 MB the clients accept.
    static let frameBudget = 24 << 20

    private func send(_ message: ServerMessage, to client: Client) {
        guard let data = try? CompanionCoding.encoder.encode(message) else { return }
        send(data: data, to: client)
    }

    private func send(data: Data, to client: Client) {
        // Binary, so neither end makes a UTF-8 string of a frame that can
        // run to megabytes. Clients have always taken both.
        guard let connection = client.connection else {
            client.sendThroughRelay(data)
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Passes a tab's side question on to the clients watching it. While
    /// the answer streams in, at most five times a second.
    private func sideQuestionChanged(_ tabID: UUID) {
        let question = SideQuestions.shared.byTab[tabID]
        if question?.state == .asking, !question!.answer.isEmpty {
            guard pendingSideQuestions.insert(tabID).inserted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pendingSideQuestions.remove(tabID) != nil else { return }
                    self.sendSideQuestion(tabID)
                }
            }
            return
        }
        pendingSideQuestions.remove(tabID)
        sendSideQuestion(tabID)
    }

    private func sendSideQuestion(_ tabID: UUID) {
        let message = ServerMessage.sideQuestion(sessionID: tabID, question: SideQuestions.shared.byTab[tabID])
        for client in clients.values where client.watching.contains(tabID) && client.features.contains(CompanionFeature.sideQuestions) {
            send(message, to: client)
        }
    }

    private func broadcast(_ message: ServerMessage) {
        for client in clients.values where client.isAuthorized { send(message, to: client) }
    }

    // MARK: Updates

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // In the common modes, so the phone keeps hearing from the Mac
        // through a long scroll or window resize.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        lastSnapshot = nil
        lastIcons = [:]
    }

    private func tick() {
        guard !connectedDevices.isEmpty else { return }
        // A phone off Wi-Fi or a Mac asleep never says goodbye; its socket
        // just stops. Clients that ping are expected every fifteen
        // seconds or so, so a minute of silence means it's gone.
        for client in clients.values where client.keepsAlive && Date.now.timeIntervalSince(client.lastHeard) > 60 {
            NSLog("Bench: dropping \(client.device ?? "a device") after a minute of silence")
            remove(client)
        }
        for client in clients.values where !client.watchingFiles.isEmpty { sendFiles(to: client) }
        let snapshot = snapshots.build()
        if snapshot != lastSnapshot {
            lastSnapshot = snapshot
            broadcast(.projects(snapshot))
        }
        let icons = snapshots.iconData()
        if icons != lastIcons {
            lastIcons = icons
            broadcast(.icons(icons))
        }
        let theme = snapshots.themeColors()
        if theme != lastTheme {
            lastTheme = theme
            for client in clients.values where client.features.contains(CompanionFeature.theme) {
                send(.theme(theme), to: client)
            }
        }
        let usage = PlanUsageMonitor.shared.usage
        if usage != lastPlanUsage {
            lastPlanUsage = usage
            for client in clients.values where client.features.contains(CompanionFeature.planUsage) {
                send(.planUsage(usage), to: client)
            }
        }
        if clients.values.contains(where: { $0.features.contains(CompanionFeature.usage) }) {
            refreshUsage(force: false)
            let usage = UsageLedger.shared.companionUsage()
            if usage != lastUsage {
                lastUsage = usage
                for client in clients.values where client.features.contains(CompanionFeature.usage) {
                    send(.usage(usage), to: client)
                }
            }
        }
        for projectID in watchedProjects {
            snapshots.refreshChanges(projectID: projectID, olderThan: 3)
            guard let changes = snapshots.changes(projectID: projectID), changes != lastChanges[projectID] else { continue }
            lastChanges[projectID] = changes
            for client in clients.values where client.watchingChanges.contains(projectID) {
                send(.changes(projectID: projectID, snapshot: changes), to: client)
            }
        }
        for tabID in watchedTabs {
            guard let path = snapshots.transcriptPath(tabID: tabID) else { continue }
            transcripts.poll(tabID: tabID, path: path) { [weak self] messages, replaces in
                guard let self else { return }
                for client in clients.values where client.watching.contains(tabID) {
                    sendTranscript(sessionID: tabID, messages: messages, replaces: replaces, to: client)
                }
            }
        }
    }

    /// Reads new session logs for a phone showing usage: right away when
    /// it asks, then every ten minutes while it stays connected.
    private func refreshUsage(force: Bool) {
        guard force || Date().timeIntervalSince(usageRefreshed) > 600 else { return }
        usageRefreshed = .now
        UsageLedger.shared.refresh()
    }
}
