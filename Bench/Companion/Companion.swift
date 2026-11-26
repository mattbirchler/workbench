import BenchKit
import Foundation
import Observation

/// Turns the iPhone companion on and off: starts the server, points
/// Tailscale Serve at it, and keeps the pairing token.
@Observable
final class Companion {
    /// Saved, so the companion comes back on when Bench relaunches.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
            if isEnabled, !oldValue {
                Analytics.capture(.iphoneEnabled)
                onTurnedOn?()
            }
        }
    }
    private(set) var token: String
    /// The Mac's tailnet name, once Tailscale has told us.
    private(set) var hostName: String?
    /// Only when Tailscale is installed but isn't working. Not having it
    /// isn't an error: the home network works without it.
    private(set) var tailscaleError: String?
    /// Tailscale is installed and gave this Mac an address.
    private(set) var hasTailscale = false
    /// This Mac's home network id and certificate, once loaded. Nil until
    /// the companion first starts, and if loading failed (see
    /// `server.localError`).
    private(set) var localIdentity: LocalIdentity?
    /// The host the pairing code carries, which phones know this Mac by
    /// (see `PairingIdentity`). Saved, so it stays put while Tailscale is
    /// down. Nil only before anything is known: no tailnet address and no
    /// local identity.
    private(set) var identityHost: String? {
        didSet {
            guard identityHost != oldValue else { return }
            UserDefaults.standard.set(identityHost, forKey: Self.identityHostKey)
        }
    }
    private(set) var isServing = false
    /// Set when the problem is HTTPS Certificates being off for the
    /// tailnet, so the settings can link to the switch and check again.
    private(set) var needsHTTPS = false
    /// "" when Bench owns the tailnet root, "/bench" when something else does.
    private(set) var servePath = ""
    /// Serve has said which path Bench is on, this run. Until then
    /// `servePath` is a guess, and a remembered identity keeps its path.
    @ObservationIgnored private var servePathKnown = false
    let server: CompanionServer
    /// This Mac's room on the Workbench relay, for reaching it from away
    /// without Tailscale. Off unless turned on.
    let relay: CompanionRelay
    @ObservationIgnored private let relayToken: TokenBox
    let push = CompanionPush()
    @ObservationIgnored private let sleepGuard = SleepGuard()
    @ObservationIgnored private let snapshots: CompanionSnapshots
    @ObservationIgnored private var activityTimer: Timer?
    @ObservationIgnored private var isLoadingIdentity = false

    private static let enabledKey = "companion.enabled"
    /// Debug builds share the release app's defaults, so they keep theirs
    /// apart, as they do their identity (see `identityPlace`).
    #if DEBUG
    private static let identityHostKey = "companion.identityHost.debug"
    #else
    private static let identityHostKey = "companion.identityHost"
    #endif
    /// The iPhone app on the App Store.
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/workbench-manage-your-agents/id6827762868")!
    private static let tokenFile = BenchPaths.support.appendingPathComponent("companion-token")

    init(snapshots: CompanionSnapshots) {
        self.snapshots = snapshots
        let token = Self.loadOrMakeToken()
        self.token = token
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        // The server reads the token each time, so a regenerated one takes
        // effect without a restart.
        var current = token
        server = CompanionServer(snapshots: snapshots, token: { current })
        tokenReader = { current = $0 }
        let server = server
        // The relay reads the token from a place it can reach off the main
        // actor, kept in step with the one above.
        let shared = TokenBox(token)
        relayToken = shared
        relay = CompanionRelay(support: BenchPaths.support, token: { shared.value }, accept: { server.accept(relay: $0) })
        server.relayEndpoint = { [weak self] in self?.relay.endpoint }
        server.onRelayUsage = { [weak self] in self?.relay.note($0) }
        relay.onChange = { [weak self] in self?.server.relayChanged() }
        identityHost = UserDefaults.standard.string(forKey: Self.identityHostKey)
        server.onRegisterPush = { [weak self] token, device, sealed in self?.push.register(token: token, device: device, sealed: sealed) }
        push.pairingToken = token
        server.onRegisterDashboard = { [weak self] token, ended in self?.push.registerDashboard(token: token, ended: ended) }
        server.onNotificationPrefs = { [weak self] token, muted in self?.push.setMuted(muted, token: token) }
        snapshots.terminals.notifier.remote = { [weak self] event in self?.handle(event) }
        // As saved, until Tailscale and the identity have been checked.
        push.hostName = identityHost
        if isEnabled { start() }
    }

    /// Where the local identity lives, and its keychain label. Only the
    /// release app uses the real ones. Keychain items trust the app that
    /// made them, and dev builds are signed differently, so a debug build
    /// sharing the label would get the release app a "wants to use key"
    /// prompt, and sharing the files (with a key that doesn't match them)
    /// would have the two remaking the certificate in turn. A copy with a
    /// bundle id suffix already has its own folder. Debug builds get a
    /// folder of their own inside the support folder, and a label naming
    /// that support folder, so two debug copies with their own
    /// BENCH_SUPPORT_DIR stay apart too. Each folder has its own id, so no
    /// copy ever advertises under the real Mac's.
    nonisolated static func identityPlace(support: URL, suffix: String?, isDebug: Bool) -> (folder: URL, label: String) {
        var label = "Workbench local network"
        var folder = support
        if let suffix { label += " (\(suffix))" }
        if isDebug {
            label += " (debug \(support.path))"
            folder = support.appendingPathComponent("debug-local-network")
        }
        return (folder, label)
    }

    /// Loads the local identity off the main actor, the first time the
    /// companion starts, then hands it to the server.
    private func loadIdentity() {
        guard localIdentity == nil, !isLoadingIdentity else { return }
        isLoadingIdentity = true
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let place = Self.identityPlace(support: BenchPaths.support, suffix: BenchPaths.instanceSuffix, isDebug: isDebug)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LocalIdentity.loadOrMake(folder: place.folder, keychainLabel: place.label) }
            }.value
            isLoadingIdentity = false
            switch result {
            case .success(let identity):
                localIdentity = identity
                server.useIdentity(identity)
                updateIdentityHost()
            case .failure(let error):
                NSLog("Bench: couldn't load the home network identity: \(error.localizedDescription)")
                server.identityFailed("Couldn't set up the home network connection: \(error.localizedDescription)")
            }
        }
    }

    /// Works out `identityHost` from what's known now, and tells push.
    private func updateIdentityHost() {
        // Test copies leave Tailscale alone, so what they remember of it
        // doesn't count.
        let installed = CompanionServer.testPort == nil && Tailscale.isInstalled
        if let mac = localIdentity?.macID {
            identityHost = PairingIdentity.host(tailnetAddress: address, remembered: identityHost,
                                                isTailscaleInstalled: installed, mac: mac, servePathKnown: servePathKnown)
        } else {
            // No id to make a local-only name from: only the tailnet's.
            let host = PairingIdentity.host(tailnetAddress: address, remembered: identityHost,
                                            isTailscaleInstalled: installed, mac: "", servePathKnown: servePathKnown)
            identityHost = PairingInfo(host: host, token: "").isLocalOnly ? nil : host
        }
        push.hostName = identityHost
    }

    /// The moments the Mac notifies about, sent on to the phone as well.
    /// Only for projects you've asked to hear about (see
    /// `AppStore.notifiesPhone`), so the phone stays quiet while you're at
    /// the Mac.
    private func agentName(_ tabID: UUID, in projectID: UUID) -> String {
        snapshots.store.project(projectID)?.tabs.first { $0.id == tabID }?.provider?.name ?? Agents.standard.name
    }

    private func handle(_ event: RemoteEvent) {
        guard isEnabled, snapshots.store.notifiesPhone(event.projectID) else { return }
        switch event {
        case .waiting(let project, let tabID, let projectID, let question, let allowOrDeny):
            push.notify(title: "\(agentName(tabID, in: projectID)) needs you", body: question ?? "Waiting for your permission in \(project).",
                        projectID: projectID, sessionID: tabID, collapseID: tabID.uuidString, kind: .needsYou,
                        category: allowOrDeny ? NotificationActions.permissionCategory : NotificationActions.replyCategory)
        case .finished(let project, let tabID, let projectID, let summary):
            push.notify(title: "\(project): finished", body: summary ?? "\(agentName(tabID, in: projectID)) is done and waiting for your next message.",
                        projectID: projectID, sessionID: tabID, collapseID: tabID.uuidString, kind: .finished,
                        category: NotificationActions.replyCategory)
        case .checks(let project, _, let pr):
            let title = pr.checks == .passing ? "Checks passed" : "Checks failed"
            let body = pr.checks == .passing ? "PR #\(pr.number) in \(project): \(pr.title)"
                : "PR #\(pr.number) in \(project). Failing: " + pr.failingNames.joined(separator: ", ")
            push.notify(title: title, body: body, projectID: nil, sessionID: nil, url: pr.url, collapseID: pr.url.absoluteString, kind: .checks)
        case .deploy(let project, _, let deploy):
            let text = AgentNotifier.deployText(project: project, deploy: deploy)
            push.notify(title: text.title, body: text.body, projectID: nil, sessionID: nil, url: deploy.url,
                        collapseID: "deploy-\(project)-\(deploy.prNumber)", kind: .deploys)
        }
    }

    /// Every couple of seconds: keep the Mac awake while agents work, and
    /// push changes to any Live Activities.
    private func sweep() {
        // Straight from the terminals: building the phone's whole snapshot
        // every two seconds, phone or no phone, was most of what the app
        // did while it sat idle.
        sleepGuard.set(snapshots.terminals.anyWorking)
        guard push.isReady, push.hasDashboards else { return }
        let snapshot = server.latestSnapshot ?? snapshots.build()
        push.updateDashboards(DashboardActivity.state(for: snapshot.projects))
    }

    @ObservationIgnored private var tokenReader: (String) -> Void = { _ in }
    /// Gets the old token just before it's replaced, so prompts still
    /// queued under it can be taken. Set by the app.
    @ObservationIgnored var onTokenWillChange: ((String) -> Void)?
    /// Called when the companion is switched on, so queued prompts are
    /// checked right away. Set by the app.
    @ObservationIgnored var onTurnedOn: (() -> Void)?

    /// The host plus any path, as the phone connects to it.
    var address: String? { hostName.map { $0 + servePath } }

    /// What the QR code holds. With the local identity, always there, with
    /// the home network part. Without it (it failed to load), only when
    /// Tailscale has an address, as before.
    var pairing: PairingInfo? {
        if let localIdentity, let identityHost {
            return PairingInfo(host: identityHost, token: token,
                               local: .init(mac: localIdentity.macID, fingerprint: localIdentity.fingerprint),
                               relay: relay.endpoint)
        }
        return address.map { PairingInfo(host: $0, token: token, relay: relay.endpoint) }
    }

    /// Makes a new token. Paired phones have to scan the new code.
    func regenerateToken() {
        onTokenWillChange?(token)
        token = PairingInfo.makeToken()
        tokenReader(token)
        relayToken.value = token
        // A new code means a new room, so the old code can't find this
        // Mac on the relay either.
        relay.newRoom()
        push.pairingToken = token
        try? Data(token.utf8).write(to: Self.tokenFile, options: .atomic)
        // Readable by you only, as it is when first made.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.tokenFile.path)
        server.stop()
        if isEnabled { server.start() }
    }

    private func start() {
        server.start()
        relay.start()
        loadIdentity()
        Task { await publish() }
        activityTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        // In the common modes, so a long scroll or resize doesn't pause it.
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
    }

    private func stop() {
        relay.stop()
        server.stop()
        isServing = false
        hasTailscale = false
        activityTimer?.invalidate()
        activityTimer = nil
        sleepGuard.set(false)
        if CompanionServer.testPort == nil { Task { try? await Tailscale.stopServing(port: CompanionServer.port) } }
    }

    /// Reads the tailnet name and points Serve at the server. Without
    /// Tailscale, or while it's down, the pairing code still shows: the
    /// home network carries it.
    func publish() async {
        guard CompanionServer.testPort == nil else {
            updateIdentityHost()
            return
        }
        guard Tailscale.isInstalled else {
            hostName = nil
            hasTailscale = false
            isServing = false
            needsHTTPS = false
            tailscaleError = nil
            updateIdentityHost()
            return
        }
        let status = await Tailscale.status()
        hostName = status?.hostName
        hasTailscale = hostName != nil
        updateIdentityHost()
        guard let status, let hostName else {
            isServing = false
            needsHTTPS = false
            tailscaleError = "Tailscale isn't running or signed in."
            return
        }
        // Known right away, where Serve would wait or fail its handshake.
        guard status.hasHTTPS else {
            isServing = false
            needsHTTPS = true
            tailscaleError = Tailscale.httpsOff
            return
        }
        do {
            servePath = try await Tailscale.serve(host: hostName, port: CompanionServer.port)
            servePathKnown = true
            updateIdentityHost()
            guard let address else { return }
            let problem = await Tailscale.httpsProblem(address: address)
            // Turned off while that was finding out.
            guard isEnabled else { return }
            isServing = problem == nil
            needsHTTPS = problem != nil
            tailscaleError = problem
        } catch {
            isServing = false
            needsHTTPS = (error as? Tailscale.Failure)?.needsHTTPS == true
            tailscaleError = error.localizedDescription
        }
    }

    private static func loadOrMakeToken() -> String {
        if let data = try? Data(contentsOf: tokenFile) {
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        let token = PairingInfo.makeToken()
        try? FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(token.utf8).write(to: tokenFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return token
    }
}

/// The pairing token, readable from the relay's own task.
nonisolated final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String

    init(_ token: String) { self.token = token }

    var value: String {
        get { lock.withLock { token } }
        set { lock.withLock { token = newValue } }
    }
}
