import AppKit
import BenchKit
import Foundation
import Observation
import SwiftUI

/// Which part of a remote project is showing in the main area.
enum RemoteTab: Hashable {
    case session(UUID)
    case shell
    case diff(FileChange)
    case file(String)
}

/// The other Macs this Mac is paired with, each with its own connection to
/// Bench there. Saved next to the companion token, readable by you only.
@Observable
final class RemoteMacs {
    struct Mac: Codable, Identifiable {
        var host: String
        var token: String
        /// What the Mac called itself the last time we connected.
        var name: String?
        /// Its home-network side, from the pairing code. Nil for codes
        /// made before that existed.
        var local: PairingInfo.LocalEndpoint?
        var id: String { host }
        var info: PairingInfo { PairingInfo(host: host, token: token, local: local) }
    }

    private(set) var macs: [Mac] = []
    @ObservationIgnored private var clients: [String: CompanionClient] = [:]
    /// Which tab is open in each remote project, by `key(host:projectID:)`.
    var openTabs: [String: RemoteTab] = [:]
    /// Diff tabs open in each remote project.
    var diffTabs: [String: [FileChange]] = [:]
    /// File tabs open in each remote project, by path.
    var fileTabs: [String: [String]] = [:]
    /// Folders open in each remote project's Files sidebar.
    var expandedFolders: [String: Set<String>] = [:]
    /// Shells logged in to remote projects, kept while you look elsewhere.
    private(set) var shells: [String: TerminalSession] = [:]
    /// The project last picked on each Mac, to come back to when you
    /// switch to that Mac again.
    var lastProject: [String: UUID] = [:]
    @ObservationIgnored private var nameTimer: Timer?
    /// Why Tailscale on this Mac says a paired Mac's link won't work, by
    /// host. Only shown while that Mac isn't connected.
    private var tailnetProblems: [String: String] = [:]
    @ObservationIgnored private var lastTailnetCheck = Date.distantPast
    /// Which sessions on each Mac are waiting on you, by host, to notice
    /// when one starts.
    @ObservationIgnored private var attention: [String: RemoteAttention] = [:]
    /// A session on another Mac has started waiting on you. Set by the app,
    /// which notifies or chimes as it does for this Mac's tabs.
    @ObservationIgnored var onWaiting: ((_ host: String, _ alert: RemoteAttention.Alert) -> Void)?
    /// It stopped waiting, so a notification about it is out of date.
    @ObservationIgnored var onWaitingEnded: ((_ sessionID: UUID) -> Void)?

    private static let file = BenchPaths.support.appendingPathComponent("remote-macs.json")

    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([Mac].self, from: data) {
            macs = saved
        }
        RemoteFileDrafts.shared.macs = self
        for mac in macs { connect(mac) }
        // Keep each Mac's name once it has introduced itself, and look into
        // the ones that aren't answering.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rememberNames()
                self?.checkTailnetIfStuck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        nameTimer = timer
    }

    static func key(host: String, projectID: UUID) -> String { "\(host)|\(projectID.uuidString)" }

    // MARK: Pairing

    /// Adds a Mac, or refreshes its token if it's already here. A Mac
    /// already here under another host (it gained or changed its tailnet
    /// name) is replaced, keeping its name.
    func add(_ info: PairingInfo) {
        let old = info.local.flatMap { local in
            macs.first { $0.local?.mac == local.mac && $0.host != info.host }?.host
        }
        let name = macs.first { $0.host == info.host }?.name ?? old.flatMap { old in macs.first { $0.host == old }?.name }
        let isNew = old == nil && !macs.contains { $0.host == info.host }
        if let old { forget(host: old) }
        macs.removeAll { $0.host == info.host }
        let mac = Mac(host: info.host, token: info.token, name: name, local: info.local)
        macs.append(mac)
        clients[info.host]?.disconnect()
        clients[info.host] = nil
        connect(mac)
        save()
        if isNew { Analytics.capture(.remoteMacAdded) }
    }

    func forget(host: String) {
        macs.removeAll { $0.host == host }
        clients[host]?.disconnect()
        clients[host] = nil
        attention[host] = nil
        RemoteFileDrafts.shared.forget(host: host)
        for key in shells.keys where key.hasPrefix(host + "|") { closeShell(key: key) }
        openTabs = openTabs.filter { !$0.key.hasPrefix(host + "|") }
        diffTabs = diffTabs.filter { !$0.key.hasPrefix(host + "|") }
        fileTabs = fileTabs.filter { !$0.key.hasPrefix(host + "|") }
        expandedFolders = expandedFolders.filter { !$0.key.hasPrefix(host + "|") }
        lastProject[host] = nil
        save()
    }

    /// Puts one Mac where another one sits in the row; the order is saved.
    func move(host: String, onto target: String) {
        guard host != target,
              let from = macs.firstIndex(where: { $0.host == host }),
              let to = macs.firstIndex(where: { $0.host == target }) else { return }
        macs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    /// Moves one Mac a place left (-1) or right (1) in the row.
    func move(host: String, by step: Int) {
        guard let from = macs.firstIndex(where: { $0.host == host }),
              macs.indices.contains(from + step) else { return }
        macs.swapAt(from, from + step)
        save()
    }

    func client(for host: String) -> CompanionClient? { clients[host] }

    func reconnect(host: String) {
        clients[host]?.retry()
        checkTailnet()
    }

    /// Why a Mac isn't connected, in plain words, or nil if it is or
    /// nothing has gone wrong yet. Kept while it tries again, so the reason
    /// doesn't vanish behind "Connecting".
    func problem(for host: String) -> String? {
        guard let client = clients[host], client.status != .connected else { return nil }
        return tailnetProblems[host] ?? client.problem
    }

    /// Every 30 seconds while some Mac isn't connected: does Tailscale
    /// still list it?
    private func checkTailnetIfStuck() {
        guard Date.now.timeIntervalSince(lastTailnetCheck) >= 30,
              macs.contains(where: { clients[$0.host]?.status != .connected }) else { return }
        checkTailnet()
    }

    private func checkTailnet() {
        lastTailnetCheck = .now
        let hosts = macs.map(\.host)
        Task {
            guard let status = await Tailscale.status() else { return }
            var problems: [String: String] = [:]
            for host in hosts {
                if let problem = status.pairingProblem(host: host) { problems[host] = problem.message }
            }
            if problems != tailnetProblems { tailnetProblems = problems }
        }
    }

    /// "Matt's Mac mini", or the first label of the host until it has
    /// introduced itself.
    func name(for host: String) -> String {
        if let name = clients[host]?.macName { return name }
        if let name = macs.first(where: { $0.host == host })?.name { return name }
        return String(host.split(separator: ".").first ?? Substring(host))
    }

    private func connect(_ mac: Mac) {
        let client = CompanionClient(deviceName: Host.current().localizedName ?? "Mac",
                                     features: [CompanionFeature.turnTimes, CompanionFeature.results, CompanionFeature.interrupt, CompanionFeature.queue, CompanionFeature.editQueue, CompanionFeature.agents, CompanionFeature.sendNow, CompanionFeature.placement, CompanionFeature.branchControls, CompanionFeature.agentLifecycle, CompanionFeature.sendTasks, CompanionFeature.shortcuts,
                                                CompanionFeature.imagePreviews, CompanionFeature.keepalive, CompanionFeature.sideQuestions])
        clients[mac.host] = client
        let host = mac.host
        client.onFileSaved = { projectID, path, problem in
            RemoteFileDrafts.shared.saved(.init(host: host, projectID: projectID, path: path), problem: problem)
        }
        client.connect(mac.info)
        watchSessions(of: client, host: mac.host)
    }

    /// Looks at a Mac's sessions each time its list changes, until the Mac
    /// is forgotten or paired again (which makes a new client).
    private func watchSessions(of client: CompanionClient, host: String) {
        withObservationTracking {
            _ = client.snapshot
        } onChange: { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client, self.clients[host] === client else { return }
                self.sessionsChanged(on: host, client: client)
                self.watchSessions(of: client, host: host)
            }
        }
    }

    private func sessionsChanged(on host: String, client: CompanionClient) {
        // A list saved from last time isn't what's happening now.
        guard client.status == .connected, let snapshot = client.snapshot else { return }
        let change = attention[host, default: RemoteAttention()].update(snapshot)
        for alert in change.started { onWaiting?(host, alert) }
        for sessionID in change.ended { onWaitingEnded?(sessionID) }
    }

    private func rememberNames() {
        var changed = false
        for index in macs.indices {
            if let name = clients[macs[index].host]?.macName, name != macs[index].name {
                macs[index].name = name
                changed = true
            }
        }
        if changed { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if macs.isEmpty {
                try? FileManager.default.removeItem(at: Self.file)
            } else {
                let data = try JSONEncoder().encode(macs)
                try data.write(to: Self.file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
            }
        } catch {
            NSLog("Bench: couldn't save remote Macs: \(error)")
        }
    }

    // MARK: Tabs

    func openDiff(host: String, projectID: UUID, change: FileChange) {
        let key = Self.key(host: host, projectID: projectID)
        var open = diffTabs[key] ?? []
        if !open.contains(change) { open.append(change) }
        diffTabs[key] = open
        openTabs[key] = .diff(change)
    }

    func closeDiff(host: String, projectID: UUID, change: FileChange) {
        let key = Self.key(host: host, projectID: projectID)
        diffTabs[key]?.removeAll { $0 == change }
        if openTabs[key] == .diff(change) { openTabs[key] = nil }
    }

    func openFile(host: String, projectID: UUID, path: String) {
        let key = Self.key(host: host, projectID: projectID)
        var open = fileTabs[key] ?? []
        if !open.contains(path) { open.append(path) }
        fileTabs[key] = open
        openTabs[key] = .file(path)
    }

    func closeFile(host: String, projectID: UUID, path: String) {
        let key = Self.key(host: host, projectID: projectID)
        fileTabs[key]?.removeAll { $0 == path }
        if openTabs[key] == .file(path) { openTabs[key] = nil }
        RemoteFileDrafts.shared.discard(.init(host: host, projectID: projectID, path: path))
    }

    // MARK: Shells

    /// A terminal logged in to the project's folder on that Mac over ssh,
    /// opened on first use and kept until you close it.
    func shell(host: String, project: CompanionProject) -> TerminalSession {
        let key = Self.key(host: host, projectID: project.id)
        if let existing = shells[key] { return existing }
        let quotedPath = project.path.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "ssh -t \(host) 'cd \"\(quotedPath)\" && exec \"$SHELL\" -l'"
        let tab = TabRecord(kind: .shell, command: command)
        let session = TerminalSession(tab: tab, project: Project(path: NSHomeDirectory()))
        session.onClose = { [weak self] in self?.closeShell(key: key) }
        shells[key] = session
        openTabs[key] = .shell
        return session
    }

    func closeShell(host: String, projectID: UUID) {
        closeShell(key: Self.key(host: host, projectID: projectID))
    }

    private func closeShell(key: String) {
        // Free the surface, which also ends the ssh session. Dropping the
        // session alone left both running with nothing pointing at them.
        shells[key]?.view.close()
        shells[key] = nil
        if openTabs[key] == .shell { openTabs[key] = nil }
    }
}

/// A project on another Mac, selected in the sidebar.
struct RemoteSelection: Hashable {
    var host: String
    var projectID: UUID
}

extension CompanionPalette {
    /// The shared views in the Mac's own colors.
    static let mac = CompanionPalette(
        accent: CompanionPalette.ownAccent, onAccent: CompanionPalette.onOwnAccent,
        working: ActivityBackground.claudeOrange, remote: ActivityBackground.remote,
        waiting: ActivityBackground.waiting, done: ActivityBackground.done, attention: ActivityBackground.attention,
        canvas: Color(nsColor: .textBackgroundColor), surface: Color(nsColor: .controlBackgroundColor),
        raised: Color.primary.opacity(0.05), ink: .primary, inkMuted: .secondary, hairline: Color.primary.opacity(0.1))
}

extension ActivityKind {
    /// The sidebar's own activity, for its indicators and backgrounds.
    var tabActivity: TabActivity {
        switch self {
        case .idle: .idle
        case .working: .working
        case .remoteWorking: .remoteWorking
        case .waiting: .waiting
        case .done: .done
        case .attention: .attention
        }
    }
}
