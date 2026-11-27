import BenchKit
import Dispatch
import Foundation

/// The pairing code devices connect with, and this host's room on the
/// Workbench relay. Made once and kept, so devices stay paired.
public struct HostPairing: Codable, Sendable {
    public var token: String
    /// The relay room's key. Nil until the relay is turned on.
    public var relayKey: String?
    /// The relay's address, when it's on.
    public var relayAddress: String?
    /// A made-up name for this host, for a pairing that has no tailnet
    /// name to go by. Devices only use it to tell hosts apart.
    public var id: String?

    public static func load(_ file: URL) -> HostPairing {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(HostPairing.self, from: data) {
            return saved
        }
        let made = HostPairing(token: PairingInfo.makeToken(), id: UUID().uuidString.lowercased())
        made.save(file)
        return made
    }

    public func save(_ file: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Turns the relay on, making this host's room the first time.
    public mutating func useRelay(address: String) {
        if relayKey == nil { relayKey = RelayRoom.make().key }
        relayAddress = address
    }

    public var relayRoom: RelayRoom? { relayKey.map(RelayRoom.init(key:)) }

    public var relayEndpoint: RelayEndpoint? {
        guard let relayKey, let relayAddress else { return nil }
        let endpoint = RelayEndpoint(url: relayAddress, room: RelayRoom(key: relayKey).id)
        return endpoint.relayURL == nil ? nil : endpoint
    }
}

/// One connected Mac or iPhone, however it got here.
public final class HostClient {
    let send: (Data) -> Void
    let close: () -> Void
    var isAuthorized = false
    var device: String?
    var features: Set<String> = []
    var watching: Set<UUID> = []
    var lastHeard = Date()
    var keepsAlive: Bool { features.contains(CompanionFeature.keepalive) }

    public init(send: @escaping (Data) -> Void, close: @escaping () -> Void) {
        self.send = send
        self.close = close
    }
}

/// Answers the Mac and iPhone apps: the same messages the Mac's own server
/// answers, from a machine with no window.
///
/// How a device connected (a WebSocket, the relay) is someone else's job.
/// They hand this a `HostClient` and the frames that arrive on it.
///
/// Only touched on the main queue.
public final class HostServer {
    /// What this host does beyond the protocol version. A device asks for
    /// the ones it wants.
    public static let features: [String] = [
        CompanionFeature.results, CompanionFeature.interrupt, CompanionFeature.queue, CompanionFeature.sendNow,
        CompanionFeature.placement, CompanionFeature.paging, CompanionFeature.keepalive, CompanionFeature.turnTimes,
        CompanionFeature.relay, CompanionFeature.addProject, CompanionFeature.agentLifecycle,
        CompanionFeature.headless,
    ]

    /// How many messages open a conversation, and each earlier page.
    static let pageSize = 150
    /// The most a frame may be, under the 32 MB the apps accept.
    static let frameBudget = 24 << 20

    public let store: HostStore
    public let sessions: HostSessions
    public let name: String
    public let version: String
    public var pairing: HostPairing
    /// Set by whoever owns push tokens.
    public var onRegisterPush: ((_ token: String, _ device: String, _ sealed: Bool) -> Void)?

    private var clients: [ObjectIdentifier: HostClient] = [:]
    private var lastSnapshot: ProjectsSnapshot?
    private var timer: DispatchSourceTimer?
    private let transcripts = TranscriptStreamer(options: .init(keepsResults: true, keepsQueue: true, keepsNotices: true, keepsTurnTimes: true))
    private let claudeProjects: URL

    public init(store: HostStore, sessions: HostSessions, pairing: HostPairing, name: String, version: String) {
        self.store = store
        self.sessions = sessions
        self.pairing = pairing
        self.name = name
        self.version = version
        let environment = ProcessInfo.processInfo.environment
        let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        claudeProjects = config.appendingPathComponent("projects", isDirectory: true)
        sessions.onChange = { [weak self] in self?.sendSnapshotIfChanged() }
    }

    /// Starts the once-a-second look at what the sessions are doing.
    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    public var connectedDevices: [String] { clients.values.filter(\.isAuthorized).compactMap(\.device).sorted() }

    // MARK: Connections

    public func connected(_ client: HostClient) {
        clients[ObjectIdentifier(client)] = client
        // A connection that never says hello isn't kept.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak client] in
            guard let self, let client, !client.isAuthorized else { return }
            self.drop(client)
        }
    }

    public func disconnected(_ client: HostClient) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        transcripts.forget(except: watchedTabs)
        if let device = client.device { hostLog("\(device) disconnected") }
    }

    private func drop(_ client: HostClient) {
        client.close()
        disconnected(client)
    }

    private var watchedTabs: Set<UUID> {
        clients.values.reduce(into: Set<UUID>()) { $0.formUnion($1.watching) }
    }

    // MARK: Messages

    public func received(_ data: Data, from client: HostClient) {
        client.lastHeard = Date()
        guard let message = try? CompanionCoding.decoder.decode(ClientMessage.self, from: data) else {
            if client.isAuthorized { send(.error("Couldn't read that message."), to: client) }
            return
        }
        // Nothing but hello before the pairing code has been checked.
        if !client.isAuthorized {
            guard case .hello(let token, let device) = message else { return }
            guard token == pairing.token else {
                send(.error(PairingInfo.rejectedMessage), to: client)
                // Give the error time to go out before closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak client] in
                    if let client { self?.drop(client) }
                }
                return
            }
            client.isAuthorized = true
            client.device = device.isEmpty ? "A device" : device
            hostLog("\(client.device ?? "A device") connected")
            send(.welcome(macName: name, protocolVersion: companionProtocolVersion, features: Self.features, appVersion: version), to: client)
            send(.icons([:]), to: client)
            sessions.refresh()
            let snapshot = buildSnapshot()
            lastSnapshot = snapshot
            send(.projects(snapshot), to: client)
            return
        }
        handle(message, from: client)
    }

    private func handle(_ message: ClientMessage, from client: HostClient) {
        switch message {
        case .hello:
            break
        case .ping:
            send(.pong, to: client)
        case .features(let wanted):
            client.features = Set(wanted).intersection(Self.features)
            if client.features.contains(CompanionFeature.relay) { send(.relay(pairing.relayEndpoint), to: client) }
        case .watchTranscript(let tabID):
            client.watching.insert(tabID)
            sessions.markSeen(tabID)
            guard let path = sessions.transcriptPath(tabID) else {
                send(.transcript(sessionID: tabID, messages: [], replaces: true), to: client)
                return
            }
            transcripts.opening(tabID: tabID, path: path) { [weak self, weak client] messages, hasMore in
                guard let self, let client else { return }
                self.sendTranscript(sessionID: tabID, messages: messages, replaces: true, hasMore: hasMore, to: client)
            }
        case .earlierTranscript(let tabID, let before):
            guard client.watching.contains(tabID), let path = sessions.transcriptPath(tabID) else { return }
            transcripts.earlier(tabID: tabID, path: path, before: before, count: Self.pageSize) { [weak self, weak client] messages, hasMore in
                guard let self, let client else { return }
                self.sendTranscript(sessionID: tabID, messages: messages, earlier: true, hasMore: hasMore, to: client)
            }
        case .unwatchTranscript(let tabID):
            client.watching.remove(tabID)
            transcripts.forget(except: watchedTabs)
        case .reply(let tabID, let text):
            sent(sessions.reply(text, tabID: tabID), tabID, to: client)
        case .replyWithAttachments(let tabID, let text, let attachments):
            sent(sessions.reply(text, images: attachments.map(\.data), tabID: tabID), tabID, to: client)
        case .answer(let tabID, let allow):
            sent(sessions.answer(allow: allow, tabID: tabID), tabID, to: client)
        case .answerQuestions(let tabID, let answers):
            sent(sessions.answer(answers, tabID: tabID), tabID, to: client)
        case .interrupt(let tabID):
            sent(sessions.interrupt(tabID: tabID), tabID, to: client)
        case .sendQueueNow(let tabID):
            sent(sessions.sendQueueNow(tabID: tabID), tabID, to: client)
        case .setPermissionMode(let tabID, let raw):
            guard let mode = PermissionMode(rawValue: raw) else { return }
            sessions.setPermissionMode(mode, tabID: tabID) { [weak self, weak client] problem in
                guard let self, let client else { return }
                self.sent(problem, tabID, to: client)
            }
        case .takeBackQueue(let tabID, _, _):
            send(.sent(sessionID: tabID, ok: false, problem: "Queued messages can't be taken back on a Workbench server yet."), to: client)
        case .pastSessions(let projectID):
            guard let project = store.project(projectID) else { return }
            let open = sessions.openSessions()
            let folder = ClaudeSessionFiles.folder(forProject: project.path, projects: claudeProjects)
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak client] in
                let found = Self.pastSessions(in: folder, open: open)
                DispatchQueue.main.async {
                    guard let self, let client else { return }
                    self.send(.pastSessions(projectID: projectID, sessions: found), to: client)
                }
            }
        case .resumeSession(let projectID, let sessionID):
            if let tab = sessions.openSessions()[sessionID], store.project(projectID)?.tabs.contains(where: { $0.id == tab }) == true {
                send(.started(projectID: projectID, sessionID: tab), to: client)
            } else {
                startTab(in: projectID, prompt: nil, resuming: sessionID, for: client)
            }
        case .newClaudeTab(let projectID, let prompt):
            startTab(in: projectID, prompt: prompt, resuming: nil, for: client)
        case .closeSession(_, let sessionID):
            sessions.close(sessionID)
        case .reorderProjects(let ids):
            store.reorder(ids)
            sendSnapshotIfChanged()
        case .pinProject(let id, let pinned):
            store.setPinned(id, pinned)
            sendSnapshotIfChanged()
        case .setProjectActive(let id, let active):
            store.setActive(id, active)
            sendSnapshotIfChanged()
        case .renameProject(let id, let name):
            store.rename(id, to: name)
            sendSnapshotIfChanged()
        case .removeProject(let id):
            for tab in store.project(id)?.tabs ?? [] { sessions.close(tab.id) }
            store.removeProject(id)
            sendSnapshotIfChanged()
        case .browseFolder(let path):
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak client] in
                let listing = FolderListing.read(path, home: NSHomeDirectory())
                DispatchQueue.main.async {
                    guard let self, let client else { return }
                    self.send(.folder(listing), to: client)
                }
            }
        case .addProject(let path):
            let full = FolderListing.expand(path, home: NSHomeDirectory())
            switch store.addProject(path: full) {
            case .added(let project), .alreadyHere(let project):
                sendSnapshotIfChanged()
                send(.projectAdded(path: full, projectID: project.id, problem: nil), to: client)
            case .notAFolder:
                send(.projectAdded(path: full, projectID: nil, problem: "There's no folder at \(full) on \(name)."), to: client)
            }
        case .registerPush(let token, let sealed):
            onRegisterPush?(token, client.device ?? "A device", sealed ?? false)
        case .watchChanges(let projectID):
            // Nothing reads git here yet. Say so once, so the panel isn't
            // left waiting.
            send(.changes(projectID: projectID, snapshot: Self.noChanges), to: client)
        case .watchFiles(let projectID):
            send(.files(projectID: projectID, listing: FileListing(paths: [], truncated: false)), to: client)
        case .newAgent, .splitTasks, .startTasks, .runShortcut, .removeAgent:
            send(.problem("That isn't available on a Workbench server yet."), to: client)
        case .writeFile(let projectID, let path, _):
            send(.fileSaved(projectID: projectID, path: path, problem: "Files can't be saved on a Workbench server yet."), to: client)
        default:
            // Asked by an app newer than this host, or for something a
            // server has no answer to. Nothing waits on these.
            break
        }
    }

    /// What a server says about a project's changes until it reads git.
    static let noChanges = ChangesSnapshot(branch: nil, baseRef: nil, staged: [], unstaged: [], againstBase: [], commits: [],
                                           isRepository: false, error: "Changes aren't shown for a Workbench server yet.")

    private func sent(_ problem: String?, _ tabID: UUID, to client: HostClient) {
        send(.sent(sessionID: tabID, ok: problem == nil, problem: problem), to: client)
        // The sidebar changes a moment later; don't make the device wait a whole tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.tick() }
    }

    private func startTab(in projectID: UUID, prompt: String?, resuming: String?, for client: HostClient) {
        let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab = store.addTab(to: projectID, prompt: prompt?.isEmpty == false ? prompt : nil, resuming: resuming),
              let project = store.project(projectID) else {
            send(.problem("Couldn't start a session. Is the project still on \(name)?"), to: client)
            return
        }
        guard sessions.start(tab, in: project) else {
            store.closeTab(tab.id)
            send(.problem("Couldn't start a terminal for that session on \(name)."), to: client)
            return
        }
        send(.started(projectID: projectID, sessionID: tab.id), to: client)
        sendSnapshotIfChanged()
    }

    static func pastSessions(in folder: URL, open: [String: UUID]) -> [PastSessionSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var found: [PastSessionSummary] = []
        for file in files where file.pathExtension == "jsonl" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let summary = ClaudeSessionFiles.summary(of: file, size: values?.fileSize ?? 0) else { continue }
            found.append(PastSessionSummary(id: summary.id, title: summary.title, firstPrompt: summary.firstPrompt,
                                            lastPrompt: summary.lastPrompt, branch: summary.branch,
                                            modified: values?.contentModificationDate ?? .distantPast,
                                            openTabID: open[summary.id]))
        }
        return found.sorted { $0.modified > $1.modified }
    }

    // MARK: The sidebar

    func buildSnapshot(now: Date = Date()) -> ProjectsSnapshot {
        let times = SidebarTimes.standard
        let projects = store.projects.map { project -> CompanionProject in
            let sessions = project.tabs.compactMap { self.sessions.session(for: $0) }
            let activity = self.sessions.activity(for: project)
            let section: CompanionSection
            let quiet = now.timeIntervalSince(project.lastUsed ?? .distantPast)
            if project.isPinned {
                section = .pinned
            } else if activity == .working || activity == .waiting {
                section = .active
            } else if project.setAside {
                section = .inactive
            } else if quiet < times.active {
                section = .active
            } else {
                section = quiet < times.inactiveAfter ? .recent : .inactive
            }
            let git = Self.gitBranch(in: project.path)
            return CompanionProject(
                id: project.id, name: project.name, repoName: project.folderName, path: project.path,
                branch: git.branch, activity: activity, sessions: sessions,
                isActive: section != .inactive, isPinned: project.isPinned, section: section,
                isGit: git.isRepository, hasCustomName: project.customName != nil, hasCustomIcon: false,
                hasHiddenWorktrees: false)
        }
        return ProjectsSnapshot(projects: projects, inactiveAfter: times.inactiveAfter)
    }

    /// The branch a folder is on, from its `.git/HEAD`. Cheap enough to
    /// read each second, and needs no `git`.
    static func gitBranch(in path: String) -> (isRepository: Bool, branch: String?) {
        var git = URL(fileURLWithPath: path).appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isFolder) else { return (false, nil) }
        if !isFolder.boolValue {
            // A worktree: the file says where its git folder is.
            guard let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") else { return (true, nil) }
            let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            git = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: path, isDirectory: true))
        }
        guard let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8) else { return (true, nil) }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        return (true, line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil)
    }

    private func sendSnapshotIfChanged() {
        guard clients.values.contains(where: \.isAuthorized) else { return }
        let snapshot = buildSnapshot()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        broadcast(.projects(snapshot))
    }

    private func tick() {
        // Read whether or not anyone is connected: a phone that isn't
        // still wants to hear when an agent needs it.
        sessions.refresh()
        guard !clients.isEmpty else {
            lastSnapshot = nil
            return
        }
        // A phone off Wi-Fi never says goodbye; its socket just stops.
        // Clients that ping are heard from every fifteen seconds or so.
        for client in clients.values where client.keepsAlive && Date().timeIntervalSince(client.lastHeard) > 60 {
            hostLog("dropping \(client.device ?? "a device") after a minute of silence")
            drop(client)
        }
        sendSnapshotIfChanged()
        for tabID in watchedTabs {
            guard let path = sessions.transcriptPath(tabID) else { continue }
            transcripts.poll(tabID: tabID, path: path) { [weak self] messages, replaces in
                guard let self else { return }
                for client in self.clients.values where client.watching.contains(tabID) {
                    self.sendTranscript(sessionID: tabID, messages: messages, replaces: replaces, to: client)
                }
                // Someone is reading along, so what just finished was seen.
                self.sessions.markSeen(tabID)
            }
        }
    }

    // MARK: Sending

    /// Sends messages for a watched conversation. `replaces` starts the
    /// client over with these, and `earlier` is a page to go before what
    /// it has. `hasMore` says whether the conversation goes back further.
    private func sendTranscript(sessionID: UUID, messages: [TranscriptMessage], replaces: Bool = false, earlier: Bool = false,
                                hasMore: Bool? = nil, to client: HostClient) {
        var fitted = messages
        var hasMore = hasMore
        // Results only go to clients that asked for them.
        if !client.features.contains(CompanionFeature.results) { fitted.removeAll { $0.resultOf != nil } }
        if replaces {
            if client.features.contains(CompanionFeature.paging) {
                if fitted.count > Self.pageSize {
                    fitted = Array(fitted.suffix(Self.pageSize))
                    hasMore = true
                }
            } else if hasMore == true {
                fitted.insert(TranscriptMessage(id: "opening-note", role: .system, text: "Showing the most recent messages."), at: 0)
            }
        }
        guard replaces || earlier || !fitted.isEmpty else { return }
        // A frame past the client's limit ends the connection, and the
        // reconnect asks for the same frame again. Keep the newest that fit.
        var kept = fitted, more = hasMore
        while true {
            let message: ServerMessage = earlier
                ? .earlierTranscript(sessionID: sessionID, messages: kept, hasMore: more ?? false)
                : .transcript(sessionID: sessionID, messages: kept, replaces: replaces, hasMore: replaces ? more : nil)
            guard let data = try? CompanionCoding.encoder.encode(message) else { return }
            if data.count <= Self.frameBudget || kept.count <= 1 {
                client.send(data)
                return
            }
            kept.removeFirst(kept.count / 2)
            more = true
        }
    }

    private func send(_ message: ServerMessage, to client: HostClient) {
        guard let data = try? CompanionCoding.encoder.encode(message) else { return }
        client.send(data)
    }

    private func broadcast(_ message: ServerMessage) {
        guard let data = try? CompanionCoding.encoder.encode(message) else { return }
        for client in clients.values where client.isAuthorized { client.send(data) }
    }
}
