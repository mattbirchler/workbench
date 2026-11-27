import BenchKit
import Foundation

/// One of this Mac's Claude tabs, for the chat view. It reads what the
/// phone would get, straight from Bench: the tab's state twice a second
/// and the transcript as it grows. Messages and answers go into the
/// terminal the same way they do from the phone.
@Observable
final class LocalChatSource: ChatSource {
    let tab: TabRecord
    @ObservationIgnored private let terminals: TerminalManager
    @ObservationIgnored private let onShowTerminal: () -> Void
    @ObservationIgnored private let onOpenFile: (String) -> Void
    @ObservationIgnored private let onRevealFile: (String) -> Bool
    /// The project's files, for `@` suggestions.
    @ObservationIgnored private let files: FileListMonitor?

    private(set) var session: CompanionSession?
    private(set) var messages: [TranscriptMessage]?
    private(set) var sendProblem: String?

    /// One streamer for every chat, kept by tab, so coming back to a tab
    /// reads what was added since rather than the whole file again.
    @ObservationIgnored private static let streamer = TranscriptStreamer(options: .init(keepsResults: true, keepsQueue: true, keepsNotices: true, keepsTurnTimes: true, keepsCommands: true, keepsPatches: true), format: { Agents.transcripts(for: $0).format },
                                                                  shrink: { ImagePreviews.shared.shrinkNow(&$0) })
    private var streamer: TranscriptStreamer { Self.streamer }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var path: String?
    /// True while a read is under way, so a slow one isn't started twice.
    @ObservationIgnored private var isReading = false
    /// For the timing log: when the last refresh ran, and what was last
    /// said about finding the transcript.
    @ObservationIgnored private var lastRefresh: SuspendingClock.Instant?
    @ObservationIgnored private var saidNoTranscript = false

    init(tab: TabRecord, terminals: TerminalManager, files: FileListMonitor? = nil, showTerminal: @escaping () -> Void, openFile: @escaping (String) -> Void, revealFile: @escaping (String) -> Bool) {
        self.tab = tab
        self.terminals = terminals
        self.onShowTerminal = showTerminal
        self.onOpenFile = openFile
        self.onRevealFile = revealFile
        self.files = files
        refreshSession()
    }

    var openKey: String { tab.id.uuidString }
    var timingID: UUID { tab.id }
    var showTerminal: (() -> Void)? { onShowTerminal }
    var openFile: ((String) -> Void)? { onOpenFile }
    var revealFile: ((String) -> Bool)? { onRevealFile }
    var fullImage: (@Sendable (TranscriptImage) async -> TranscriptImage?)? {
        let path = self.path
        return { image in await ImagePreviews.shared.full(id: image.id, transcriptPaths: [path].compactMap { $0 }) }
    }
    var draftKey: String { "local-\(tab.id)" }
    var slashCommands: [SlashCommand] {
        guard let path = terminals.projectPath(forTab: tab.id) else { return SlashCommand.builtIn }
        return SlashCommandLibrary.shared.commands(forProject: path)
    }
    var projectFiles: [String]? { files?.listing?.paths }
    var folderRoot: String? { terminals.projectPath(forTab: tab.id) }
    func holdFiles() async { await files?.hold() }
    var takeBackQueue: ((_ queued: [String], _ keep: [String]) -> Void)? {
        { [weak self] queued, keep in
            guard let self else { return }
            Task { @MainActor in
                if let problem = await self.terminals.takeBackQueue(queued: queued, keep: keep, tabID: self.tab.id) {
                    self.sendProblem = problem
                }
            }
        }
    }
    var sendQueueNow: (() -> Void)? {
        { [weak self] in
            guard let self else { return }
            if let problem = terminals.sendQueueNow(tabID: tab.id) { sendProblem = problem }
        }
    }
    var setPermissionMode: ((PermissionMode) -> Void)? {
        { [weak self] mode in
            guard let self else { return }
            Task { @MainActor in
                self.sendProblem = await self.terminals.setPermissionMode(mode, tabID: self.tab.id)
            }
        }
    }
    var interrupt: (() -> Void)? { { [weak self] in self.map { $0.terminals.interrupt(tabID: $0.tab.id) } } }

    func open() {
        guard timer == nil else { return }
        ChatTiming.begin(tab: tab.id, details: "session=\(session == nil ? "no" : "yes")")
        lastRefresh = nil
        refresh()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
    }

    func reply(_ text: String, attachments: [CompanionAttachment]) {
        sendProblem = terminals.companionReply(text, images: attachments.map(\.data), tabID: tab.id, here: true)
        refreshSession()
    }

    func answer(allow: Bool) {
        sendProblem = terminals.answerPermission(allow: allow, tabID: tab.id) ? nil : "\((tab.provider ?? Agents.standard).name) isn't asking for permission right now."
        refreshSession()
    }

    func answer(_ answers: [CompanionAnswer]) {
        sendProblem = terminals.answerQuestions(answers, tabID: tab.id)
        refreshSession()
    }

    func clearProblem() { sendProblem = nil }

    var sideQuestion: SideQuestion? { SideQuestions.shared.byTab[tab.id] }
    var askSideQuestion: ((String) -> String?)? {
        { [weak self] question in
            guard let self else { return nil }
            return SideQuestions.shared.ask(question, tabID: tab.id, terminals: terminals)
        }
    }
    func dismissSideQuestion() { SideQuestions.shared.dismiss(tabID: tab.id) }

    var statusRows: [ChatStatusRow]? {
        var rows: [ChatStatusRow] = []
        if let session {
            if let model = session.model {
                rows.append(ChatStatusRow(label: "Model", value: model + (session.effortLevel.map { ", \($0.name.lowercased()) effort" } ?? "")))
            }
            if let mode = session.permissionMode.flatMap(PermissionMode.init(rawValue:)) {
                rows.append(ChatStatusRow(label: "Permissions", value: mode.name))
            }
            if let tokens = session.contextTokens, let window = session.contextWindow, window > 0 {
                rows.append(ChatStatusRow(label: "Context", value: "\(ContextUsage.short(tokens)) of \(ContextUsage.short(window)) tokens (\(tokens * 100 / window)%)"))
            }
        }
        let accounts = ClaudeAccounts.shared
        if let status = accounts.account(for: tab.claudeAccountID).status {
            var parts = [status.summary]
            if let email = status.email, !email.isEmpty { parts.append(email) }
            if accounts.hasSeveral { parts.insert(accounts.profile(tab.claudeAccountID).name, at: 0) }
            rows.append(ChatStatusRow(label: "Account", value: parts.joined(separator: " · ")))
        }
        if let folder = terminals.projectPath(forTab: tab.id) {
            rows.append(ChatStatusRow(label: "Folder", value: (folder as NSString).abbreviatingWithTildeInPath))
        }
        if let path {
            rows.append(ChatStatusRow(label: "Session", value: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent))
        }
        if let version = ClaudeCodeVersion.shared.current() {
            rows.append(ChatStatusRow(label: "Claude Code", value: version))
        }
        rows.append(ChatStatusRow(label: "Workbench", value: AppVersion.current.long))
        return rows
    }

    /// Lets go of what was read for tabs that are gone.
    static func forget(except tabIDs: Set<UUID>) { streamer.forget(except: tabIDs) }

    private func refresh() {
        // The timer is every half second, so a long gap means the main
        // thread was held up, which would freeze the whole window. The
        // suspending clock stops with the Mac, so sleep isn't a gap.
        let now = SuspendingClock.now
        if let lastRefresh, (now - lastRefresh).seconds > 1.5 {
            ChatTiming.note("main thread held up", tab: tab.id, details: "gap=\((now - lastRefresh).milliseconds)ms")
        }
        lastRefresh = now
        refreshSession()
        refreshTranscript()
    }

    private func refreshSession() {
        let fresh = CompanionSnapshots.session(for: tab, terminals: terminals, here: true)
        if (fresh == nil) != (session == nil) {
            ChatTiming.note(fresh == nil ? "session gone" : "session ready", tab: tab.id)
        }
        if fresh != session { session = fresh }
    }

    /// The whole conversation the first time, then what's new. A new
    /// transcript (after /clear) starts over.
    private func refreshTranscript() {
        guard let current = CompanionSnapshots.transcriptPath(tabID: tab.id, terminals: terminals) else {
            if !saidNoTranscript {
                saidNoTranscript = true
                ChatTiming.note("no transcript yet", tab: tab.id)
            }
            if messages == nil { messages = [] }
            return
        }
        saidNoTranscript = false
        guard !isReading else { return }
        isReading = true
        if current != path || messages == nil {
            let size = (try? FileManager.default.attributesOfItem(atPath: current))?[.size] as? UInt64
            ChatTiming.note("reading transcript", tab: tab.id,
                            details: "new=\(current != path) size=\(size.map { "\($0 / 1_000_000)MB" } ?? "missing")")
            let readStarted = ContinuousClock.now
            path = current
            streamer.opening(tabID: tab.id, path: current) { [weak self] opening, hasMore in
                guard let self else { return }
                self.isReading = false
                ChatTiming.note("transcript read", tab: self.tab.id,
                                details: "took=\((ContinuousClock.now - readStarted).milliseconds)ms messages=\(opening.count) hasMore=\(hasMore)")
                guard self.path == current else { return }
                var messages = opening
                if hasMore {
                    messages.insert(TranscriptMessage(id: "opening-note", role: .system, text: "Showing the most recent messages."), at: 0)
                }
                self.messages = messages
            }
            return
        }
        streamer.poll(tabID: tab.id, path: current, always: true) { [weak self] fresh, replaces in
            guard let self else { return }
            self.isReading = false
            guard self.path == current else { return }
            if replaces {
                ChatTiming.note("transcript replaced", tab: self.tab.id, details: "messages=\(fresh.count)")
                self.messages = fresh
            } else if !fresh.isEmpty {
                var all = (self.messages ?? []) + fresh
                // A chat left open for hours keeps the recent end only.
                if all.count > 2_000 { all.removeFirst(all.count - 1_200) }
                self.messages = all
            }
        }
    }
}
