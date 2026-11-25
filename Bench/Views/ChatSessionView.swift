import AppKit
import BenchKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a chat view gets its Claude session: a tab on another Mac over
/// the network, or one of this Mac's own tabs.
@MainActor protocol ChatSource {
    var session: CompanionSession? { get }
    /// The conversation, or nil while it loads.
    var messages: [TranscriptMessage]? { get }
    /// Why the last thing sent didn't go through.
    var sendProblem: String? { get }
    /// Changes when the conversation should be asked for again, like
    /// after reconnecting.
    var openKey: String { get }
    /// Names this conversation in the chat timing log.
    var timingID: UUID { get }
    /// Names this conversation's unsent draft.
    var draftKey: String { get }
    /// Shows the raw terminal instead, where there is one to show.
    var showTerminal: (() -> Void)? { get }
    /// Interrupts Claude the way Escape does, where that's possible.
    var interrupt: (() -> Void)? { get }
    /// Opens a file Claude touched, by its full path, where that's possible.
    var openFile: ((String) -> Void)? { get }
    /// Shows a file named in a reply in the Finder, where there is one, and
    /// says whether the text named a file at all.
    var revealFile: ((String) -> Bool)? { get }
    /// Reads a picture whole, where the conversation holds previews and
    /// there's no Mac at the other end to ask.
    var fullImage: (@Sendable (TranscriptImage) async -> TranscriptImage?)? { get }
    /// Takes the queued messages back and queues `keep` again, where that's possible.
    var takeBackQueue: ((_ queued: [String], _ keep: [String]) -> Void)? { get }
    /// Sends the queued messages now, as Ctrl+Return does, where that's possible.
    var sendQueueNow: (() -> Void)? { get }
    /// Switches Claude Code's permission mode, where that's possible.
    var setPermissionMode: ((PermissionMode) -> Void)? { get }
    /// The slash commands to suggest while typing. Ones that open in the
    /// terminal are only offered where there's a terminal to show.
    var slashCommands: [SlashCommand] { get }
    /// The project's files, for `@` suggestions, or nil while they load
    /// or where they can't be listed.
    var projectFiles: [String]? { get }
    /// The folder `@` paths like `../` count from, on this Mac. Nil where
    /// the session is on another Mac, whose folders can't be read from here.
    var folderRoot: String? { get }
    /// The `/btw` side question showing above the message box, if any.
    var sideQuestion: SideQuestion? { get }
    /// Asks a side question about the conversation, where that's
    /// possible. Returns why it can't be asked.
    var askSideQuestion: ((String) -> String?)? { get }
    /// What `/status` shows: the session's model, account and setup. Nil
    /// where that isn't known, as for a tab on another Mac.
    var statusRows: [ChatStatusRow]? { get }

    func open()
    /// Keeps the project's files listed for as long as the calling task runs.
    func holdFiles() async
    func close()
    func reply(_ text: String, attachments: [CompanionAttachment])
    func answer(allow: Bool)
    func answer(_ answers: [CompanionAnswer])
    func clearProblem()
    func dismissSideQuestion()
}

/// A tab on another Mac, through its connection.
struct RemoteChatSource: ChatSource {
    let client: CompanionClient?
    let projectID: UUID
    let sessionID: UUID

    var session: CompanionSession? {
        client?.snapshot?.projects.first { $0.id == projectID }?.sessions.first { $0.id == sessionID }
    }
    var messages: [TranscriptMessage]? { client?.transcripts[sessionID] }
    var sendProblem: String? { client?.sendProblems[sessionID] }
    var openKey: String { client.map { "\($0.status)" } ?? "none" }
    var timingID: UUID { sessionID }
    var draftKey: String { "remote-\(sessionID)" }
    var showTerminal: (() -> Void)? { nil }
    var interrupt: (() -> Void)? {
        guard let client, client.canInterrupt else { return nil }
        let id = sessionID
        return { client.interrupt(sessionID: id) }
    }
    var openFile: ((String) -> Void)? { nil }
    var revealFile: ((String) -> Bool)? { nil }
    // The Mac at the other end sends whole pictures when asked.
    var fullImage: (@Sendable (TranscriptImage) async -> TranscriptImage?)? { nil }
    var slashCommands: [SlashCommand] {
        let all = client?.slashCommands[projectID] ?? (client?.canListCommands == true ? [] : SlashCommand.builtIn)
        return all.filter { !$0.opensInTerminal }
    }
    var projectFiles: [String]? { client?.filePaths[projectID] }
    var folderRoot: String? { nil }
    var sendQueueNow: (() -> Void)? {
        guard let client, client.canSendNow else { return nil }
        let id = sessionID
        return { client.sendQueueNow(sessionID: id) }
    }
    var setPermissionMode: ((PermissionMode) -> Void)? {
        // Only Macs that report the mode know how to change it.
        guard let client, session?.permissionMode != nil else { return nil }
        let id = sessionID
        return { client.setPermissionMode(sessionID: id, mode: $0) }
    }
    var takeBackQueue: ((_ queued: [String], _ keep: [String]) -> Void)? {
        guard let client, client.canEditQueue else { return nil }
        let id = sessionID
        return { client.takeBackQueue(sessionID: id, queued: $0, keep: $1) }
    }

    func open() {
        guard client?.status == .connected else { return }
        client?.watch(sessionID: sessionID)
        client?.loadSlashCommands(projectID: projectID)
    }
    func close() { client?.unwatch(sessionID: sessionID) }
    func holdFiles() async {
        guard let client else { return }
        // The client asks again by itself after reconnecting.
        client.watchFiles(projectID: projectID)
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        client.unwatchFiles(projectID: projectID)
    }
    func reply(_ text: String, attachments: [CompanionAttachment]) {
        client?.reply(sessionID: sessionID, text: text, attachments: attachments)
    }
    func answer(allow: Bool) { client?.answer(sessionID: sessionID, allow: allow) }
    func answer(_ answers: [CompanionAnswer]) { client?.answerQuestions(sessionID: sessionID, answers: answers) }
    func clearProblem() { client?.clearProblem(sessionID: sessionID) }
    var sideQuestion: SideQuestion? { client?.sideQuestions[sessionID] }
    var askSideQuestion: ((String) -> String?)? {
        guard let client, client.canAskSideQuestions else { return nil }
        let id = sessionID
        return { question in
            client.askSideQuestion(sessionID: id, question: question)
            return nil
        }
    }
    func dismissSideQuestion() { client?.dismissSideQuestion(sessionID: sessionID) }
    var statusRows: [ChatStatusRow]? { nil }
}

/// A Claude session as a conversation: read along, send the next message,
/// answer its questions, allow or deny a tool. Drawn in the terminal
/// theme's colors, so it sits in Bench like the terminal does.
struct ChatSessionView: View {
    let source: any ChatSource
    @State private var draft: String
    @State private var attachments: [RemoteAttachment]
    @State private var problem: String?
    /// The messages as turns, grouped once per change rather than on
    /// every pass through the body, with what you just sent merged in.
    @State private var conversation = Conversation(tracksChanges: true)

    init(source: any ChatSource) {
        self.source = source
        _draft = State(initialValue: Drafts.load(source.draftKey + ".text") ?? "")
        #if DEBUG
        // For screenshots of the command suggestions.
        if let seeded = ProcessInfo.processInfo.environment["BENCH_CHAT_DRAFT"] { _draft = State(initialValue: seeded) }
        #endif
        _attachments = State(initialValue: Drafts.load(source.draftKey + ".attachments") ?? [])
    }

    var body: some View {
        let palette = TerminalTheme.shared.chatPalette
        ChatBody(source: source, turns: conversation, draft: $draft, attachments: $attachments, send: send, sendRightAway: sendRightAway)
            .environment(\.companionPalette, palette)
            .environment(\.openStepFile, source.openFile)
            .environment(\.revealStepFile, source.revealFile)
            .environment(\.loadFullImage, source.fullImage)
            .environment(\.stepFonts, ChatStyle.steps)
            .environment(\.markdownFonts, ChatStyle.markdown)
            .environment(\.chatTurnStyle, ChatStyle.turns)
            .environment(\.dockCardStyle, ChatTypography.shared.dockCards)
            // Lets ⌘+, ⌘− and ⌘0 size the chat while it's on screen.
            .focusedSceneValue(\.showsChat, true)
            .background(palette.canvas)
            .task(id: source.openKey) { source.open() }
            .task { await source.holdFiles() }
            .onDisappear { source.close() }
            .onChange(of: source.sendProblem) { _, new in
                problem = new
                // It didn't go: take the bubble back and give you your words.
                if new != nil, let unsent = conversation.dropLastSent(), draft.isEmpty { draft = unsent.text }
            }
            .onChange(of: source.messages, initial: true) { _, new in conversation.update(new) }
            .onChange(of: draft) { _, new in Drafts.save(new.isEmpty ? nil : new, for: source.draftKey + ".text") }
            .onChange(of: attachments) { _, new in Drafts.save(new.isEmpty ? nil : new, for: source.draftKey + ".attachments") }
            .onChange(of: source.draftKey) { _, key in
                // A fresh conversation for the new tab, filled right away:
                // the messages may have changed in this same update, and
                // that onChange can run before this one, so waiting for
                // the next change would leave the chat blank.
                let fresh = Conversation(tracksChanges: true)
                fresh.update(source.messages)
                conversation = fresh
                draft = Drafts.load(key + ".text") ?? ""
                attachments = Drafts.load(key + ".attachments") ?? []
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .loadTestSend)) { note in
                guard let text = note.object as? String else { return }
                draft = text
                send()
            }
            #endif
            .alert("Couldn't Send", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil; source.clearProblem() } })) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
    }

    /// Sends, and if Claude is busy, has it read the message now rather
    /// than after its current step, like Ctrl+Return in its terminal.
    private func sendRightAway() {
        let busy = source.session?.activity == .working
        send()
        guard busy, let sendNow = source.sendQueueNow else { return }
        Task {
            // Long enough for the message to land in Claude Code's queue.
            try? await Task.sleep(for: .milliseconds(900))
            sendNow()
        }
    }

    private func send() {
        // A `!` with no command after it isn't a message.
        let text = ShellDraft.isEmptyCommand(draft) ? "" : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // Claude Code answers /btw in a pop-up only its terminal shows, so
        // it's asked here instead, and pictures stay for the next message.
        if let question = SideQuestion.question(in: text) {
            guard let ask = source.askSideQuestion else {
                problem = "Side questions need a newer Workbench on the Mac this tab is on."
                return
            }
            guard !question.isEmpty else {
                problem = "Type a question after /btw."
                return
            }
            if let reason = ask(question) {
                problem = reason
                return
            }
            draft = ""
            return
        }
        let busy = source.session.map { [.working, .remoteWorking, .waiting].contains($0.activity) } ?? false
        conversation.send(text: text, images: attachments.map(\.data), queued: busy)
        source.reply(text, attachments: attachments.map { CompanionAttachment(name: $0.name, data: $0.data) })
        Task { [conversation] in
            try? await Task.sleep(for: .seconds(31))
            conversation.settle()
        }
        draft = ""
        attachments = []
    }
}

/// What a chat shows while its conversation loads. Most load in well under
/// a blink, so the spinner holds back a moment: a quick load shows nothing,
/// rather than a spinner that flashes and is gone.
private struct LoadingConversation: View {
    @Environment(\.companionPalette) private var palette
    @State private var shows = false

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("Loading the conversation").font(ChatStyle.small).foregroundStyle(palette.inkMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .opacity(shows ? 1 : 0)
        .animation(Theme.Motion.hover, value: shows)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { shows = true }
        }
    }
}

private struct ChatBody: View {
    @Environment(\.companionPalette) private var palette
    @Environment(AppStore.self) private var store
    /// Set where a turn's changes can be shown, as for this Mac's own tabs.
    @Environment(\.turnReview) private var turnReview
    let source: any ChatSource
    /// The messages as turns, grouped once per change.
    let turns: Conversation
    @Binding var draft: String
    @Binding var attachments: [RemoteAttachment]
    let send: () -> Void
    let sendRightAway: () -> Void

    private var session: CompanionSession? { source.session }

    private struct StartingKey: Equatable {
        var session: UUID?
        var isStarting: Bool
    }

    /// How long Claude gets to start before the chat points at its terminal.
    /// Starting takes a second or two, longer when resuming a long session.
    private static let startingGrace: Double = 8

    /// An image is being dragged over the chat.
    @State private var dropTargeted = false
    /// A card a command put above the message box, if one is showing.
    @State private var commandCard: CommandCard?

    private enum CommandCard { case status, help }
    /// Claude has been starting for long enough that it may be stuck on a
    /// question only its terminal can show.
    @State private var startsSlowly = false

    /// Which screen the chat is showing, for the timing log. These look
    /// alike at a glance, so the log tells them apart.
    private var screenForTiming: String {
        let composer = session == nil ? "no" : "yes"
        guard let messages = source.messages, turns.isLoaded else { return "screen=loading composer=\(composer)" }
        if messages.isEmpty, !turns.hasPendingSent { return "screen=nothing-yet composer=\(composer)" }
        return "screen=list composer=\(composer)"
    }

    var body: some View {
        // The conversation runs on under the message box, which floats on
        // it as glass, with the system's soft edge where the two meet.
        // A conversation that had to load fades in. One that was ready
        // when its tab opened is just there. The stack gives the fade a
        // parent that stays put while what's in it changes.
        ZStack { conversation }
            .animation(Theme.Motion.hover, value: source.messages == nil || !turns.isLoaded)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .bottom, spacing: 0) { dock }
        .environment(\.chatTimingID, source.timingID)
        .onChange(of: screenForTiming, initial: true) { _, screen in
            ChatTiming.note("chat showing", tab: source.timingID, details: "\(screen) messages=\(source.messages?.count ?? 0)")
        }
        .overlay {
            ImageDropCatcher(canDrop: session?.canReply ?? false, targeted: { dropTargeted = $0 }) { pasteboard in
                attachments += RemoteAttachment.pasted(from: pasteboard, numberedFrom: attachments.count + 1)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        Label("Drop to attach", systemImage: "photo.badge.plus")
                            .font(.ui(size: 14, weight: .semibold))
                            .foregroundStyle(palette.accent)
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }

    @ViewBuilder
    private var conversation: some View {
        // Waits for the turns too, which are grouped just after the messages
        // arrive. A list that first lays out empty and then gets a whole
        // conversation at once can draw none of it until you scroll a long way.
        if source.messages == nil || !turns.isLoaded {
            LoadingConversation()
                // Gone at once, so the conversation never fades in over it.
                .transition(.identity)
        } else if let messages = source.messages, messages.isEmpty, !turns.hasPendingSent {
            EmptyStateScaffold(title: "Ready when you are",
                               message: "Tell \(session?.agentTitle ?? "your agent") what to work on. Type `/` for commands, or `@` to point it at a file.") {
                ConversationEmptyIllustration(appeared: $0)
            } accessory: {
                if let session { LiveRow(session: session).padding(.top, 14) }
            }
            .transition(.opacity)
        } else {
            let turns = turns.turns
            let working = session.map { [.working, .remoteWorking].contains($0.activity) } ?? false
            let shown = turns.filter { !$0.isQueued }
            // Only while Claude is busy: a queue left behind when Claude quit isn't waiting on anything.
            let busy = session.map { [.working, .remoteWorking, .waiting].contains($0.activity) } ?? false
            let queued = busy ? turns.filter(\.isQueued) : []
            // What each finished turn changed, by the row it goes under.
            // The newest turn gets its list once Claude is done with it.
            let changes = turnReview == nil ? [:] : self.turns.changes.filter { !($0.value.isLatest && busy) }
            // The newest turns sit in a plain stack, and the history above
            // them is drawn a chunk at a time as you scroll near it (see
            // ChatHistory). A lazy stack would guess the heights of rows it
            // hasn't drawn, and with turns this uneven the guess can leave
            // the bottom of the conversation over nothing at all. These
            // heights are real, so the bottom always has its rows, while the
            // history still costs nothing until you scroll to it.
            let recentStart = ChatTail.start(count: shown.count)
            // An overlay, so nothing above asks the scroll view how big it
            // would like to be: the window does on every change, to work out
            // its smallest size, and the answer means measuring every turn.
            Color.clear.overlay {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 18) {
                        ChatHistory(shown[..<recentStart], spacing: 18) { row($0, isLive: false, of: shown.count, changes: changes[$0.id]) }
                        ForEach(shown[recentStart...]) { turn in
                            row(turn, isLive: working && turn.id == shown.last?.id, of: shown.count, changes: changes[turn.id])
                        }
                        ForEach(queued) { turn in
                            TranscriptTurnView(turn: turn).id(turn.id)
                                .transition(ChatMotion.row(for: turn))
                        }
                        .environment(\.queueActions, queueActions(queued))
                    }
                    .animatesArrivals(turns.map(\.id))
                    .environment(\.agentStatuses, session?.agentsByCall ?? [:])
                        // Under the turns, with its own space above it
                        // (see LiveRow). Queued messages only show while
                        // Claude is busy, and this only once it's done,
                        // so the two never meet.
                        if let session {
                            LiveRow(session: session, spacing: 18)
                                .id("live")
                        }
                    }
                    .frame(maxWidth: ChatLayout.column)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                }
                .sticksToBottom(sentKey: turns.lastSentID)
                // Text fades as it slides under the message box, and under
                // the tab bar at the top.
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .softTopEdge(surface: palette.canvas)
            }
            .transition(.opacity)
        }
    }

    /// A turn's row, with the files its turn changed under it when it's
    /// the last row of a finished turn that changed some.
    private func row(_ turn: TranscriptTurn, isLive: Bool, of count: Int, changes: TurnChanges?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TranscriptTurnView(turn: turn, isLive: isLive)
                .equatable()
            if let changes {
                TurnChangesCard(changes: changes)
                    .transition(.opacity)
            }
        }
            .id(turn.id)
            .transition(ChatMotion.row(for: turn))
            .onAppear { ChatTiming.note("first row drawn", tab: source.timingID, details: "turns=\(count)", once: true) }
    }

    private func queueActions(_ queued: [TranscriptTurn]) -> QueueActions? {
        guard let takeBack = source.takeBackQueue, session?.activity == .working else { return nil }
        return .forQueue(queued, takeBack: takeBack, sendNow: source.sendQueueNow) { text in
            draft = draft.isEmpty ? text : draft + "\n" + text
        }
    }

    /// Does what one of Claude Code's commands asks for here in Workbench,
    /// rather than in a picker only its terminal can show.
    private func run(_ command: ChatCommand) {
        switch command {
        case .prints:
            break  // Sent like any message.
        case .resume:
            store.showsOverview = false
            store.showsUsage = false
            store.showsHistory = true
        case .usage:
            store.showsUsage = true
        case .status:
            commandCard = .status
        case .help:
            commandCard = .help
        case .export:
            exportConversation()
        }
    }

    /// Asks where to save the conversation, then has Claude Code write it
    /// there: `/export` with a file named skips the dialog its terminal
    /// would show. Claude Code's line saying where it went shows in the chat.
    private func exportConversation() {
        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.prompt = "Export"
        panel.nameFieldStringValue = ExportName.suggested(title: session?.title, on: .now)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let source = source
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            source.reply("/export " + url.path, attachments: [])
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }

    private var dock: some View {
        // One container for the glass pieces, so they render together.
        GlassEffectContainer(spacing: 4) {
        VStack(spacing: 10) {
            if let session {
                if session.isCompacting {
                    CompactingBanner()
                        .transition(ChatMotion.card)
                }
                if let questions = session.questions {
                    QuestionCard(questions: questions, plan: PlanText.forApproval(questions, in: source.messages), agentName: session.agentTitle) { answers in source.answer(answers) }
                        .id(questions)
                        .transition(ChatMotion.card)
                }
                if session.isAllowOrDeny {
                    PermissionDock(session: session) { allow in source.answer(allow: allow) }
                        .transition(ChatMotion.card)
                }
                // While Claude starts, the message box shows it. This only
                // comes up if starting goes on long enough to look stuck.
                if !session.canReply, let reason = session.replyProblem, !session.isAllowOrDeny, session.questions == nil,
                   !session.isStarting || startsSlowly {
                    GlassEffectContainer {
                    HStack(spacing: 6) {
                        Text(session.isStarting && source.showTerminal != nil
                             ? "\(session.agentTitle) is taking a while to start. It may be waiting on a question in its terminal."
                             : reason)
                        if let showTerminal = source.showTerminal {
                            Button("Show Terminal", action: showTerminal)
                                .buttonStyle(.pressable)
                                .foregroundStyle(ChatStyle.link)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(ChatStyle.small)
                    .foregroundStyle(palette.inkMuted)
                    // It floats over the conversation, so it gets glass to sit on.
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(ChatMotion.glassCard)
                }
                // The right panel shows these too, so only while it's hidden.
                if !store.showsChanges {
                    if let items = session.checklist, !items.isEmpty {
                        GlassEffectContainer {
                            ChatChecklistBar(items: items, session: session, agents: session.pinnedAgents)
                        }
                        .transition(ChatMotion.glassCard)
                    } else if let agents = session.pinnedAgents {
                        GlassEffectContainer {
                            ChatAgentsBar(agents: agents)
                        }
                        .transition(ChatMotion.glassCard)
                    }
                }
                if let question = source.sideQuestion {
                    SideQuestionCard(question: question) { source.dismissSideQuestion() }
                        .id(question.id)
                        .transition(ChatMotion.card)
                }
                if commandCard == .status, let rows = source.statusRows {
                    ChatStatusCard(rows: rows) { commandCard = nil }
                        .transition(ChatMotion.card)
                }
                if commandCard == .help {
                    ChatHelpCard(commands: source.slashCommands.map(\.inLocalChat)) { command in
                        commandCard = nil
                        draft = command.completion
                    } close: {
                        commandCard = nil
                    }
                    .transition(ChatMotion.card)
                }
                Composer(session: session, draft: $draft, attachments: $attachments, send: send, sendRightAway: sendRightAway,
                         interrupt: source.interrupt,
                         switchModel: { source.reply($0.command, attachments: []) },
                         setEffort: { source.reply($0.command, attachments: []) },
                         runCommand: { source.reply($0.command, attachments: []) },
                         commands: source.showTerminal == nil ? source.slashCommands.filter { !$0.opensInTerminal } : source.slashCommands.map(\.inLocalChat),
                         files: source.projectFiles ?? [],
                         folderRoot: source.folderRoot,
                         runInTerminal: source.showTerminal.map { show in
                             { text in source.reply(text, attachments: []); show() }
                         },
                         runChatCommand: source.showTerminal == nil ? nil : { run($0) },
                         sentMessages: turns.sentTexts,
                         setPermissionMode: source.setPermissionMode,
                         showsStartingBeam: !startsSlowly)
            }
        }
        }
        // When the window works out how small it can get, it measures this
        // at almost no width. Cards that wrap their text (compacting, a
        // question) then report a height of thousands of points, and the
        // whole chat overflows the window. A floor on the width keeps that
        // measurement sane. The outer frame then asks the window for no
        // minimum at all: with the sidebar and inspector open the column
        // can be narrower than the floor, and a pane that insists on more
        // than its column sends AppKit's split view into a layout loop.
        .frame(minWidth: 260)
        .frame(maxWidth: ChatLayout.column + 24)
        .frame(minWidth: 0, maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .animation(ChatMotion.dock, value: session?.isAllowOrDeny)
        .animation(ChatMotion.dock, value: session?.questions)
        .animation(ChatMotion.dock, value: session?.isCompacting)
        .animation(ChatMotion.dock, value: session?.checklist?.isEmpty ?? true)
        .animation(ChatMotion.dock, value: session?.pinnedAgents == nil)
        .animation(ChatMotion.dock, value: store.showsChanges)
        .animation(ChatMotion.dock, value: source.sideQuestion?.id)
        .animation(ChatMotion.dock, value: commandCard)
        .animation(ChatMotion.dock, value: startsSlowly)
        .onChange(of: source.draftKey) { _, _ in commandCard = nil }
        .task(id: StartingKey(session: session?.id, isStarting: session?.isStarting ?? false)) {
            startsSlowly = false
            guard session?.isStarting == true else { return }
            try? await Task.sleep(for: .seconds(ChatBody.startingGrace))
            if !Task.isCancelled { startsSlowly = true }
        }
    }
}

/// The file name `/export` suggests: the tab's title and the day.
enum ExportName {
    static func suggested(title: String?, on date: Date) -> String {
        // Slashes and colons can't be in a file name.
        // A tab's title can start with Claude Code's mark or spinner ("✳ Fix sidebar").
        let words = (title ?? "").drop { !$0.isLetter && !$0.isNumber }
        let cleaned = words.map { "/:".contains($0) ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        let day = date.formatted(.iso8601.year().month().day())
        return "\(name.isEmpty ? "Conversation" : name) \(day).txt"
    }
}

/// Claude's checklist above the message box, while the right panel is
/// hidden. Folded, it's one line: how long the turn has run, the current
/// step, and steps done over a progress bar. Click to open the list.
struct ChatChecklistBar: View {
    @Environment(\.companionPalette) private var palette
    let items: [ChecklistItem]
    let session: CompanionSession
    /// Subagents at work, counted on the folded line since this bar takes
    /// the agents bar's place.
    var agents: [AgentStatus]?
    @AppStorage("chatChecklistExpanded") private var expanded = false

    var body: some View {
        let type = ChatTypography.shared
        VStack(spacing: 0) {
            if expanded {
                ChecklistRows(items: items, textSize: 13 * type.scale, spacing: 6, wraps: true, usesPalette: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    // Just a fade: the bar growing is what reveals them. Sliding
                    // up from below carried them across the line under them.
                    .transition(.opacity)
                Divider().overlay(palette.hairline)
            }
            Button {
                withAnimation(ChatMotion.dock) { expanded.toggle() }
            } label: {
                VStack(spacing: 7) {
                    HStack(spacing: 8) {
                        ActivityMark(activity: session.activity, size: 12)
                        if let since = session.since {
                            ActiveTimer(since: since, activity: session.activity)
                        }
                        Text(items.current?.label ?? "Every step done")
                            .foregroundStyle(palette.ink.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let running = agents?.filter(\.isRunning).count, running > 0 {
                            Label("\(running)", systemImage: "person.2")
                                .font(type.text(11, weight: .medium))
                                .foregroundStyle(palette.inkMuted)
                                .help(running == 1 ? "1 agent working" : "\(running) agents working")
                        }
                        Text("\(items.doneCount)/\(items.count)")
                            .monospacedDigit()
                            .foregroundStyle(palette.inkMuted)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10 * type.scale, weight: .semibold))
                            .foregroundStyle(palette.inkMuted)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(ChatStyle.small)
                    ChecklistProgressBar(progress: items.progress, track: palette.hairline)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help(expanded ? "Hide the checklist" : "Show every step")
            .accessibilityLabel("Checklist, \(items.doneCount) of \(items.count) steps done")
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ChatTypography.dockRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ChatTypography.dockRadius, style: .continuous))
    }
}

/// Claude's subagents above the message box, while the right panel is
/// hidden. Folded, it's one line: how many are working and what one is
/// doing. Click to see each.
struct ChatAgentsBar: View {
    @Environment(\.companionPalette) private var palette
    let agents: [AgentStatus]
    @AppStorage("chatAgentsExpanded") private var expanded = false

    var body: some View {
        let running = agents.filter(\.isRunning)
        let type = ChatTypography.shared
        VStack(spacing: 0) {
            if expanded {
                AgentStatusRows(agents: agents, textSize: 13 * type.scale, spacing: 8, usesPalette: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    // Just a fade: the bar growing is what reveals them. Sliding
                    // up from below carried them across the line under them.
                    .transition(.opacity)
                Divider().overlay(palette.hairline)
            }
            Button {
                withAnimation(ChatMotion.dock) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if running.isEmpty {
                        Image(systemName: "checkmark").font(.system(size: 11 * type.scale, weight: .semibold)).foregroundStyle(StepColors.added)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(running.isEmpty ? (agents.count == 1 ? "Agent done" : "\(agents.count) agents done")
                         : running.count == 1 ? "1 agent" : "\(running.count) agents")
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.ink)
                        .fixedSize()
                    if let action = running.first?.action {
                        Text(action)
                            .foregroundStyle(palette.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10 * type.scale, weight: .semibold))
                        .foregroundStyle(palette.inkMuted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(ChatStyle.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help(expanded ? "Hide the agents" : "Show each agent")
            .accessibilityLabel(running.isEmpty ? "Agents done" : "\(running.count) agents working")
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ChatTypography.dockRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ChatTypography.dockRadius, style: .continuous))
        .animation(.snappy(duration: 0.25), value: agents)
    }
}

/// When Claude last finished, at the end of the conversation. What it's
/// doing right now is in the message box (see `ComposerStatus`).
///
/// Always in the conversation, at no height while there's nothing to
/// say, so it opens and closes a frame at a time as Claude finishes and
/// starts. Put in and taken out with `if`, the conversation changed
/// height all at once, and the message box under it jumped.
private struct LiveRow: View {
    @Environment(\.companionPalette) private var palette
    let session: CompanionSession
    /// The space to leave above it, between it and the last turn.
    var spacing: CGFloat = 0
    /// What it last said, to keep saying as it closes.
    @State private var lastLabel = ""

    private var isDone: Bool { session.activity == .done }
    private var label: String {
        "Finished" + (session.stoppedAt.map { " " + $0.formatted(.relative(presentation: .named)) } ?? "")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.done)
            Text(isDone ? label : lastLabel)
                .foregroundStyle(palette.inkMuted)
        }
        .font(ChatStyle.small)
        .padding(.leading, 4)
        // The space above it opens and closes with it, so closed it
        // leaves no gap. That's why it sits outside the spaced stack of
        // turns: a stack's own spacing stays even around nothing.
        .padding(.top, 2 + spacing)
        .revealed(isDone ? 1 : 0)
        .animation(ChatMotion.dock, value: isDone)
        .onChange(of: isDone, initial: true) { _, done in
            if done { lastLabel = label }
        }
        .onChange(of: session.stoppedAt) { _, _ in
            if isDone { lastLabel = label }
        }
    }
}

/// What Claude is doing right now, along the top of the message box:
/// working on something or waiting on you, for how long, and how to stop
/// it. It's part of the box, so the status, the typing and the stopping
/// are one object.
private struct ComposerStatus: View {
    @Environment(\.companionPalette) private var palette
    let session: CompanionSession
    let interrupt: (() -> Void)?
    /// With something typed, Escape belongs to the message, so the
    /// control says Stop instead of naming the key.
    let hasDraft: Bool

    /// True while there's something to say.
    static func shows(for session: CompanionSession) -> Bool {
        [.working, .remoteWorking, .waiting].contains(session.activity)
    }

    var body: some View {
        let tint = palette.color(for: session.activity) ?? palette.inkMuted
        HStack(spacing: 10) {
            PulsingDot(color: tint)
                .padding(.leading, 4)
            Text(text)
                .foregroundStyle(palette.ink(for: session.activity))
                .lineLimit(1)
                .help(text)
            if let since = session.since {
                ActiveTimer(since: since, activity: session.activity)
                    .fontWeight(.regular)
                    .opacity(0.75)
            }
            Spacer(minLength: 8)
            if let interrupt, session.activity == .working {
                Button(action: interrupt) {
                    Group {
                        if hasDraft {
                            Label("Stop", systemImage: "stop.fill")
                        } else {
                            Text("esc")
                        }
                    }
                    .font(ChatTypography.shared.text(10.5, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.inkMuted.opacity(0.45)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .foregroundStyle(palette.inkMuted)
                .help(hasDraft ? "Stop \(session.agentTitle)" : "Stop \(session.agentTitle) (Escape), like pressing Escape in the terminal")
                .accessibilityLabel("Stop \(session.agentTitle)")
            }
        }
        .font(ChatStyle.small)
    }

    private var text: String {
        switch session.activity {
        case .waiting:
            if session.isAllowOrDeny || session.questions != nil { return "Waiting for you" }
            return session.question ?? "Waiting for you"
        case .remoteWorking:
            return (session.actionText ?? "Working") + (session.remoteHost.map { " on \($0)" } ?? "")
        default:
            return session.actionText ?? "Working"
        }
    }
}

/// A status dot with a soft ring that breathes, so a live row reads as
/// live without anything moving around.
private struct PulsingDot: View {
    let color: Color
    @Environment(\.motionLevel) private var motionLevel
    private var reduceMotion: Bool { motionLevel == .still }

    var body: some View {
        if reduceMotion {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .background(Circle().fill(color.opacity(0.2)).frame(width: 16, height: 16))
        } else {
            // Core Animation plays it, so it costs nothing per frame.
            LayerMotion(kind: .pulse(NSColor(color), dot: 8, ring: 16, ringTo: 16,
                                     opacity: 0.28, opacityTo: 0.12, period: 2.2))
                // Laid out as the dot alone; the ring spills past it.
                .frame(width: 8, height: 8)
                .allowsHitTesting(false)
        }
    }
}

/// Claude is asking to run a tool. Return allows it once, Escape denies,
/// the same keys as in the terminal.
private struct PermissionDock: View {
    @Environment(\.companionPalette) private var palette
    /// The radius, border and title the question and side-question cards use.
    @Environment(\.dockCardStyle) private var style
    let session: CompanionSession
    let answer: (Bool) -> Void
    /// How tall the command is when laid out at the card's width.
    @State private var commandTextHeight: CGFloat = 0

    /// "git push" out of "Running git push", so the command reads as one.
    private var command: String? {
        // The whole command when the Mac has it. `action` is only the
        // start of its first line.
        if let whole = session.command, !whole.isEmpty { return whole }
        guard let action = session.action else { return nil }
        return action.hasPrefix("Running ") ? String(action.dropFirst("Running ".count)) : action
    }

    private var title: String {
        session.action?.hasPrefix("Running ") == true ? "\(session.agentTitle) wants to run a command" : (session.question ?? "\(session.agentTitle) needs your permission")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radius ?? ChatTypography.dockRadius, style: .continuous)
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 17 * ChatTypography.shared.scale))
                .foregroundStyle(palette.waiting)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(style.title)
                    .foregroundStyle(palette.ink)
                if let command {
                    // All of it, before you allow it: a long command
                    // scrolls rather than hiding its later lines.
                    // Sized from the text's own height. A frame with only a
                    // most-height takes all it's offered, which left a
                    // one-line command in a seven-line box.
                    let scrolls = commandTextHeight > Self.commandHeight
                    ScrollView {
                        commandText(command)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { commandTextHeight = $0 }
                    }
                    .scrollIndicators(scrolls ? .visible : .hidden)
                    .scrollDisabled(!scrolls)
                    .frame(height: min(max(commandTextHeight, Self.lineHeight), Self.commandHeight))
                }
            }
            Spacer(minLength: 8)
            // Allow first, then Deny: the same order as the sidebar, the
            // Overview and the iPhone.
            Button { answer(true) } label: {
                KeyedLabel(title: "Allow", key: "↩")
            }
            .buttonStyle(DockButtonStyle(fill: palette.waiting, ink: .black.opacity(0.85), font: style.action, bold: true))
            .keyboardShortcut(.defaultAction)
            .help("Answer Yes, once.")
            Button { answer(false) } label: {
                KeyedLabel(title: "Deny", key: "esc")
            }
            .buttonStyle(DockButtonStyle(fill: palette.raised, ink: palette.ink, font: style.action))
            .keyboardShortcut(.cancelAction)
            .help("Answer No. \(session.agentTitle) stops and waits for you to say what to do instead.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.waiting.opacity(0.1), in: shape)
        .background(palette.surface, in: shape)
        .overlay(shape.strokeBorder(palette.waiting.opacity(0.5), lineWidth: style.borderWidth ?? 1))
    }
}

private extension PermissionDock {
    /// About seven lines of a command before it scrolls.
    static var commandHeight: CGFloat { 120 }
    /// One line, for the moment before the text has been measured.
    static var lineHeight: CGFloat { 16 * ChatTypography.shared.scale }

    func commandText(_ command: String) -> some View {
        Text(command)
            .font(ChatStyle.mono)
            .foregroundStyle(palette.ink.opacity(0.85))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KeyedLabel: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
            Text(key).font(.system(size: 10.5 * ChatTypography.shared.scale)).opacity(0.6)
        }
    }
}

private struct DockButtonStyle: ButtonStyle {
    let fill: Color
    let ink: Color
    /// The cards' button font, so it grows with the chat's text.
    let font: Font
    var bold = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font.weight(bold ? .semibold : .regular))
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// An image waiting to go with the next message.
struct RemoteAttachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var data: Data
    /// A small copy for the message box, made once so a big screenshot
    /// isn't decoded on every redraw.
    let thumbnail: NSImage?

    init(name: String, data: Data) {
        self.name = name
        self.data = data
        thumbnail = Self.thumbnail(of: data, maxPixels: 240)
    }

    private static func thumbnail(of data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    /// The pictures on a pasteboard: image files copied in Finder, or an
    /// image itself, like a screenshot or one copied from a web page.
    /// Empty when there's no picture, so text pastes as text.
    static func pasted(from pasteboard: NSPasteboard, numberedFrom first: Int) -> [RemoteAttachment] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
        if !files.isEmpty {
            return files.compactMap { url in
                (try? Data(contentsOf: url)).map { RemoteAttachment(name: url.lastPathComponent, data: $0) }
            }
        }
        let name = first == 1 ? "Pasted image.png" : "Pasted image \(first).png"
        if let png = pasteboard.data(forType: .png) { return [RemoteAttachment(name: name, data: png)] }
        // Other image types (TIFF, JPEG, HEIC from Photos) become PNG. Text
        // copied from some apps carries a PDF picture of itself, so with
        // text on the clipboard, only a bitmap counts.
        let bitmaps: [NSPasteboard.PasteboardType] = [.tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]
        let hasText = pasteboard.types?.contains(.string) == true
        guard !hasText || pasteboard.availableType(from: bitmaps) != nil,
              pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        return [RemoteAttachment(name: name, data: png)]
    }

    /// Whether a pasteboard holds a picture `pasted(from:)` can read,
    /// checked without loading it.
    static func hasPicture(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) || pasteboard.availableType(from: [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]) != nil
    }
}

/// Takes pictures dropped anywhere on the chat and attaches them to the
/// next message, the same as pasting them. Other files are turned away.
/// It's an AppKit view so it sits above the message box: otherwise the
/// box would take a dropped file and type its path. Clicks pass through.
struct ImageDropCatcher: NSViewRepresentable {
    let canDrop: Bool
    let targeted: (Bool) -> Void
    let drop: (NSPasteboard) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.canDrop = canDrop
        view.targeted = targeted
        view.drop = drop
    }

    final class CatcherView: NSView {
        var canDrop = false
        var targeted: (Bool) -> Void = { _ in }
        var drop: (NSPasteboard) -> Void = { _ in }

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL, .png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)])
        }

        required init?(coder: NSCoder) { fatalError("Not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
            canDrop && RemoteAttachment.hasPicture(info.draggingPasteboard) ? .copy : []
        }

        override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
            let operation = operation(info)
            targeted(!operation.isEmpty)
            return operation
        }

        override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { operation(info) }
        override func draggingExited(_ info: NSDraggingInfo?) { targeted(false) }
        override func draggingEnded(_ info: NSDraggingInfo) { targeted(false) }

        override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
            guard !operation(info).isEmpty else { return false }
            drop(info.draggingPasteboard)
            return true
        }
    }
}

/// The message box, floating at the bottom: what you type, pictures to
/// send with it, how full Claude's context is, and send.
private struct Composer: View {
    @Environment(\.companionPalette) private var palette

    /// The permission mode, beside the model, when Claude reports one.
    @ViewBuilder private var modePill: some View {
        if let raw = session.permissionMode, let mode = PermissionMode(rawValue: raw), let setPermissionMode {
            ModePill(mode: mode, set: setPermissionMode)
        }
    }

    let session: CompanionSession
    @Binding var draft: String
    @Binding var attachments: [RemoteAttachment]
    let send: () -> Void
    /// Control-Return: send, and if Claude is busy, have it read the
    /// message now instead of after its current step.
    let sendRightAway: () -> Void
    /// Stops Claude, where that's possible.
    var interrupt: (() -> Void)?
    let switchModel: (ModelChoice) -> Void
    let setEffort: (EffortLevel) -> Void
    let runCommand: (QuickCommand) -> Void
    /// Slash commands to suggest as you type one.
    var commands: [SlashCommand] = []
    /// The project's files, suggested after an `@`.
    var files: [String] = []
    /// Where `@../` and the like count from, for listing folders outside
    /// the project. Nil where they can't be listed.
    var folderRoot: String?
    /// Types a command that opens a picker into the terminal, and shows it.
    var runInTerminal: ((String) -> Void)?
    /// Runs a command the chat handles itself, in this Mac's own chats.
    var runChatCommand: ((ChatCommand) -> Void)?
    /// The messages sent in this conversation, oldest first, for the up
    /// arrow to bring back.
    var sentMessages: [String] = []
    /// Switches Claude Code's permission mode, where that's possible.
    var setPermissionMode: ((PermissionMode) -> Void)?
    /// False once Claude has been starting for a while, when the light
    /// around the box stops and the chat points at the terminal instead.
    var showsStartingBeam = true
    @Environment(\.motionLevel) private var motionLevel
    /// Claude Code is starting in the tab, so there's nothing to type to yet.
    private var isStarting: Bool { session.isStarting && !session.canReply }
    @FocusState private var focused: Bool
    /// Steps through `sentMessages` with the arrows. State so the key
    /// monitor sees where you are.
    @State private var history = ComposerHistory()
    @Environment(\.tabHasKeys) private var tabHasKeys
    /// Edges of the message box with text scrolled past them.
    @State private var hiddenEdges: Edge.Set = []
    /// Kept as state so the key monitor sees the latest.
    @State private var commandList: [SlashCommand] = []
    /// The files and folders `@` can name, worked out once per listing.
    @State private var mentionList: [FileMention] = []
    /// Reads the folders `@~/`, `@../` and the like point into.
    @State private var folders = MentionFolders()
    /// Where the cursor is in the draft (a UTF-16 offset), -1 while text
    /// is selected, or nil when it isn't known and taken to be at the end.
    @State private var caret: Int?
    @State private var highlighted = 0
    /// The draft the suggestions were dismissed for with Escape.
    @State private var dismissedFor: String?
    /// The highlighted row of the model list `/model` opens over the box,
    /// or nil while it's closed.
    @State private var modelPicker: Int?
    /// A model chosen in that list. Checked against the session before it
    /// goes on to `modelRequest`.
    @State private var chosenModel: ModelChoice?
    /// The effort level shown in that list, and whether you changed it.
    @State private var pickerEffort: EffortLevel?
    @State private var effortChanged = false
    /// What the list asked for, waiting on the switch.
    @State private var modelRequest: ModelRequest?
    /// How far open the status line is, from 0 to 1.
    @State private var statusProgress: CGFloat = 0
    /// Whether the line's views exist: while it's open or still closing.
    /// Closed, they'd keep a timer ticking for nothing.
    @State private var statusMounted = false
    /// The last session with something to say, and whether dictation had
    /// the line last, so the line keeps its words as it closes.
    @State private var lastStatus: CompanionSession?
    @State private var lastWasDictation = false
    /// What Escape in an empty box does while Claude works: stops it.
    /// State, so the key monitor sees the latest.
    @State private var stopper: (() -> Void)?

    /// True while the top of the box has a line to show: Claude's status,
    /// or dictation's while you talk.
    private var showsStatus: Bool {
        dictation.activeTarget == session.id || ComposerStatus.shows(for: session)
    }

    /// True while the send button is a stop button: Claude is working and
    /// there's nothing to send. Type, and it's an arrow again that queues.
    private var showsStop: Bool {
        interrupt != nil && session.activity == .working && draft.isEmpty && attachments.isEmpty
    }

    private struct FocusKey: Equatable {
        var session: UUID
        var canReply: Bool
        var hasKeys: Bool
    }

    /// Asks for the cursor until the box has it. One request right as the
    /// view appears can be lost: the window may still be settling a click
    /// in the sidebar, or the view may still be fading in. Gives up after a
    /// second, so it never fights a click somewhere else.
    private func takeFocus() async {
        guard session.canReply, tabHasKeys else { return }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled || focused { break }
            focused = true
        }
        #if DEBUG
        // A seeded draft starts selected; screenshots want the cursor after it.
        if ProcessInfo.processInfo.environment["BENCH_CHAT_DRAFT"] != nil {
            try? await Task.sleep(for: .milliseconds(300))
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        }
        #endif
    }

    private var suggestions: Suggestions? {
        guard dismissedFor != draft else { return nil }
        return Suggestions.find(draft: draft, caret: draftCaret, commands: commandList, files: mentionList, folders: folders)
    }

    /// True once the draft starts with `!`, even before the command. The
    /// box is then in shell mode: the `!` shows as a chip beside the
    /// field, and the field holds only the command.
    private var isShellCommand: Bool { ShellDraft.isShell(draft) }

    /// True once the draft starts with `/btw`. As with `!`, a chip stands
    /// for it and the field holds only the question.
    private var isSideQuestion: Bool { ComposerDraft.mode(of: draft) == .sideQuestion }

    /// What the field holds: the draft, without the `!` that the chip
    /// stands for. Its own state, kept in step with the draft both ways,
    /// because a field only takes a change made from here once what you
    /// typed has landed in what it's bound to. Bound to the draft through
    /// a mapping, it kept showing the `!` beside the chip.
    @State private var field = ""

    /// Works the draft out from what was typed, then takes the `!` (and a
    /// space typed after it out of habit) back out of the field.
    private func fieldChanged(to text: String) {
        let edited = ComposerDraft.draft(afterEditing: text, in: ComposerDraft.mode(of: draft))
        if text != ComposerDraft.fieldText(for: draft), edited != draft { draft = edited }
        // On the next pass: set in the same one as the typing, the field
        // keeps what was typed.
        DispatchQueue.main.async {
            let shown = ComposerDraft.fieldText(for: draft)
            if shown != field { field = shown }
        }
    }

    /// The draft changed from outside the field: sent, recalled, restored.
    private func draftChanged(to draft: String) {
        let shown = ComposerDraft.fieldText(for: draft)
        if shown != field { field = shown }
    }

    /// The cursor's place in the draft, which is past the hidden `!`.
    private var draftCaret: Int? {
        caret.map { $0 < 0 ? $0 : $0 + ComposerDraft.hiddenPrefixLength(in: draft) }
    }

    /// The shell's color: the one the chat gives inline code.
    private var shellTint: Color { palette.code }
    /// Dictation, when it's turned on in Settings.
    private var dictation: Dictation { .shared }

    /// This message box, as somewhere dictation can type. With the cursor
    /// here, the words go in where it is, typed into the editor so Undo
    /// takes them back. If the cursor has moved on by the time they're
    /// ready, they're added to the end of the draft instead.
    private var dictationTarget: Dictation.Target {
        let draft = $draft
        let focused = $focused
        return Dictation.Target(id: session.id) { text in
            if focused.wrappedValue, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
               editor.string == ComposerDraft.fieldText(for: draft.wrappedValue) {
                let range = editor.selectedRange()
                let before = (editor.string as NSString).substring(to: range.location)
                editor.insertText(Self.spaced(text, after: before), replacementRange: range)
            } else {
                draft.wrappedValue += Self.spaced(text, after: draft.wrappedValue)
            }
        }
    }

    /// The dictated text, with a space in front when it follows a word.
    private static func spaced(_ text: String, after preceding: String) -> String {
        SmartSpacing.needsLeadingSpace(preceding: SmartSpacing.lastVisibleCharacter(in: preceding), text: text) ? " " + text : text
    }

    /// The line along the top of the box, and the rule under it.
    private var statusStrip: some View {
        VStack(spacing: 8) {
            if dictation.activeTarget == session.id || (!ComposerStatus.shows(for: session) && lastWasDictation) {
                // Dictation's line takes the place of Claude's while it
                // has something to say.
                DictationStatusLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ComposerStatus(session: ComposerStatus.shows(for: session) ? session : lastStatus ?? session,
                               interrupt: interrupt, hasDraft: !draft.isEmpty)
            }
            // Edge to edge, past the box's padding.
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)
                .padding(.leading, -14)
                .padding(.trailing, -10)
        }
    }

    /// Opens or closes the status line. Closing, its views stay until
    /// it's shut.
    private func showStatus(_ shows: Bool, animated: Bool) {
        guard animated else {
            statusProgress = shows ? 1 : 0
            statusMounted = shows
            return
        }
        if shows {
            statusMounted = true
            withAnimation(ChatMotion.dock) { statusProgress = 1 }
        } else {
            withAnimation(ChatMotion.dock) {
                statusProgress = 0
            } completion: {
                if statusProgress == 0 { statusMounted = false }
            }
        }
    }

    /// One button for sending and stopping.
    private var sendButton: some View {
        let symbol = showsStop ? "stop.fill" : isShellCommand ? "return" : "arrow.up"
        let ink: Color = showsStop ? palette.canvas : canSend ? (isShellCommand ? palette.canvas : palette.onAccent) : palette.inkMuted
        let fill: Color = showsStop ? palette.ink : canSend ? (isShellCommand ? shellTint : palette.accent) : palette.raised
        let help = showsStop
            ? "Stop \(session.agentTitle) (Escape)"
            : isShellCommand
            ? "Run in the shell (Return). Delete at the start of the line, or Escape, goes back to a message."
            : isSideQuestion
            ? "Ask on the side (Return). Delete at the start of the line, or Escape, goes back to a message."
            : "Send to \(session.agentTitle) (Return). Shift-Return adds a line. Control-Return sends now, even while \(session.agentTitle) is busy."
        // An arrow that sends, and a square that stops while Claude works
        // and there's nothing to send.
        return Button(action: { if showsStop { interrupt?() } else { submit() } }) {
            Image(systemName: symbol)
                .font(.ui(size: showsStop ? 10 : 12, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(ink)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: showsStop ? 8 : 13, style: .continuous).fill(fill))
        }
        .buttonStyle(.pressable)
        .disabled(!canSend && !showsStop)
        .help(help)
        .accessibilityLabel(showsStop ? "Stop \(session.agentTitle)" : isShellCommand ? "Run" : isSideQuestion ? "Ask" : "Send")
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.snappy(duration: 0.22), value: showsStop)
    }

    /// Catches Command-V while you're typing here, for pictures.
    @State private var pasteMonitor: Any?
    /// Claude Code's suggested next message, kept here so the key monitor
    /// sees the latest one.
    @State private var suggestion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always here, at no height while there's nothing to say. It
            // opens upward a frame at a time, so the box grows from its
            // top edge and the field and buttons under it never move.
            // The space under it opens with it, which is why it sits
            // outside the spaced stack below: a stack's own spacing stays
            // even around nothing.
            Group { if statusMounted { statusStrip.padding(.bottom, 8) } }
                .revealed(statusProgress)
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentThumbnail(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    // Room for the remove buttons, which sit over the corners.
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                .scrollClipDisabled()
                .transition(.opacity)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isShellCommand {
                    // Stands for the `!` you typed, so there's no space to
                    // think about after it.
                    Text("!")
                        .font(ChatStyle.inputCommand.weight(.bold))
                        .foregroundStyle(shellTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(shellTint.opacity(0.2)))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .accessibilityLabel("Shell command")
                } else if isSideQuestion {
                    // Stands for the `/btw` you typed.
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.ui(size: 11, weight: .semibold))
                        Text("btw")
                            .font(ChatStyle.input.weight(.semibold))
                    }
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.accent.opacity(0.18)))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .accessibilityLabel("Side question")
                }
                TextField(isShellCommand ? "Command to run" : isSideQuestion ? "Ask a side question" : suggestion.map { "\($0)   →" } ?? placeholder, text: $field, axis: .vertical)
                    // Tall enough for a pasted paragraph or two of feedback
                    // before it scrolls.
                    .lineLimit(1...18)
                    .textFieldStyle(.plain)
                    .font(isShellCommand ? ChatStyle.inputCommand : ChatStyle.input)
                    .foregroundStyle(palette.ink)
                    .focused($focused)
                    .disabled(!session.canReply)
                    .onSubmit(submit)
                    // Opening a conversation puts the cursor here, ready to
                    // type, and so do the box becoming usable again and its
                    // side of a split getting the keys.
                    .task(id: FocusKey(session: session.id, canReply: session.canReply, hasKeys: tabHasKeys)) {
                        await takeFocus()
                    }
                    // Past eight lines the box scrolls. Fade whichever edge has
                    // more text past it, so it's clear there's more.
                    .background(ScrollEdgesWatcher(text: draft, isFocused: focused, caret: NSColor(isShellCommand ? shellTint : palette.ink), report: { edges in
                        if edges != hiddenEdges { hiddenEdges = edges }
                    }, reportCaret: { offset in
                        if offset != caret { caret = offset }
                    }))
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: hiddenEdges.contains(.top) ? 18 : 0)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: hiddenEdges.contains(.bottom) ? 18 : 0)
                        }
                        .animation(Theme.Motion.hover, value: hiddenEdges)
                    }
                    // While Claude starts, the box says so where you'll type,
                    // and hands over to the field once it's ready: the label
                    // clears first, so the two never show through each other.
                    .opacity(isStarting ? 0 : 1)
                    .animation(.easeOut(duration: 0.18).delay(isStarting ? 0 : 0.12), value: isStarting)
                    .overlay(alignment: .leading) {
                        if isStarting {
                            HStack(spacing: 7) {
                                // Claude's turning mark in the theme's accent,
                                // like the light around the box. Not the
                                // working color: nothing is at work yet.
                                if motionLevel == .still {
                                    Text("✻\u{FE0E}")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(palette.accent)
                                        .frame(width: 12, height: 12)
                                } else {
                                    LayerMotion(kind: .glyphs(NSColor(palette.accent), size: 12))
                                        .frame(width: 12, height: 12)
                                        .allowsHitTesting(false)
                                }
                                Text("Starting \(session.agentTitle)")
                                    .font(ChatStyle.input)
                                    .foregroundStyle(palette.inkMuted)
                            }
                            .accessibilityElement(children: .combine)
                            .transition(.opacity.animation(.easeOut(duration: 0.12)))
                        }
                    }
            }
            HStack(spacing: 8) {
                Button(action: attach) {
                    Image(systemName: "paperclip")
                        .font(.ui(size: 13))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .foregroundStyle(palette.inkMuted)
                .disabled(!session.canReply)
                .help("Attach an image")
                QuickCommandMenu(session: session, run: runCommand)
                if dictation.isEnabled {
                    DictationMicButton(target: session.id, isEnabled: session.canReply) {
                        focused = true
                        dictation.toggle(dictationTarget)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if isShellCommand {
                    // As in Claude Code's own prompt: `! make test` runs
                    // in the shell, and Claude sees what it printed.
                    Label("Runs in the shell. \(session.agentTitle) sees what it prints.", systemImage: "terminal")
                        .font(.ui(size: 11))
                        .foregroundStyle(shellTint)
                        .lineLimit(1)
                        .padding(.leading, 4)
                        .transition(.opacity)
                } else if isSideQuestion {
                    Label("\(session.agentTitle) answers on the side. It isn't added to the conversation.", systemImage: "arrow.turn.down.right")
                        .font(.ui(size: 11))
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                        .padding(.leading, 4)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
                modePill
                if session.model != nil || session.canRunCommand {
                    ModelPill(session: session, request: $modelRequest, switchModel: switchModel, setEffort: setEffort) {
                        if modelPicker == nil { openModelPicker() } else { modelPicker = nil }
                        focused = true
                    }
                }
                if let tokens = session.contextTokens, let window = session.contextWindow {
                    ChatContextMeter(tokens: tokens, window: window)
                }
                sendButton
            }
        }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        // The shadow goes on the box's shape only. On the whole stack it
        // would fall under each line of text, picture and selection too.
        // Glass, so the conversation shows through as it scrolls under.
        // The border is part of what the glass holds: drawn after the
        // glass, the shell color never showed.
        .overlay {
            if isShellCommand {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(shellTint.opacity(0.55))
            } else if isSideQuestion {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.accent.opacity(0.55))
            } else if focused {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.ink.opacity(0.18))
            }
        }
        // Light runs around the box while Claude starts. It's a thin line
        // that stops within seconds, so it plays at the Calm setting too,
        // which is about areas that would otherwise move for as long as
        // Claude works.
        .overlay {
            if isStarting, showsStartingBeam, motionLevel != .still {
                LayerMotion(kind: .beam(NSColor(palette.accent)), cornerRadius: 18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: isStarting)
        .animation(.easeOut(duration: 0.5), value: showsStartingBeam)
        .overlay(alignment: .top) {
            // Shown whenever it's open, not only while the box has focus:
            // focus arrives a beat after a click on the model pill, too
            // late for the animation. Losing focus closes it (below).
            if let row = modelPicker {
                // Its own glass group, so the panel and what's in it grow
                // as one piece.
                GlassEffectContainer {
                    ModelPicker(catalog: session.agentCatalog, current: session.model, highlighted: row, canSwitch: session.canRunCommand,
                                effort: pickerEffort, pick: { chosenModel = $0 },
                                pickEffort: { pickerEffort = $0; effortChanged = true },
                                highlight: { modelPicker = $0 })
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(Self.listTransition(from: .bottomTrailing))
                .frame(height: 0, alignment: .bottom)
                .offset(y: -8)
            } else if focused, let suggestions {
                GlassEffectContainer {
                    switch suggestions.list {
                    case .commands(let commands):
                        CommandSuggestions(commands: commands, highlighted: min(highlighted, commands.count - 1),
                                           runs: suggestions.token.isWholeMessage, highlight: { highlighted = $0 }) { command in
                            accept(command, for: suggestions.token, sending: false)
                        }
                    case .files(let mentions):
                        FileSuggestions(mentions: mentions, highlighted: min(highlighted, mentions.count - 1),
                                        highlight: { highlighted = $0 }) { mention in
                            fill(suggestions.token, with: mention.insertion)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(Self.listTransition(from: .bottomLeading))
                // A zero-height frame at the box's top edge, with the list
                // hanging up out of it, so it floats above the box.
                .frame(height: 0, alignment: .bottom)
                .offset(y: -8)
            }
        }
        // Pictures fade in and the box grows to hold them, rather than
        // jumping taller.
        .animation(.easeOut(duration: 0.15), value: attachments.map(\.id))
        .animation(.easeOut(duration: 0.12), value: suggestions == nil)
        // Opening takes a moment longer than closing, which gets out of the way.
        .animation(.easeOut(duration: modelPicker == nil ? 0.11 : 0.18), value: modelPicker == nil)
        .onChange(of: focused) { _, isFocused in
            if !isFocused { modelPicker = nil }
        }
        // The dictation key works on whichever message box has the cursor.
        .onChange(of: focused, initial: true) { _, isFocused in
            if isFocused { dictation.focus(dictationTarget) } else { dictation.blur(session.id) }
        }
        .onDisappear { dictation.blur(session.id) }
        .animation(.easeOut(duration: 0.15), value: dictation.isEnabled)
        .onChange(of: showsStatus, initial: true) { was, shows in
            showStatus(shows, animated: was != shows)
        }
        .onChange(of: session, initial: true) { _, session in
            guard ComposerStatus.shows(for: session) else { return }
            lastStatus = session
            if dictation.activeTarget != session.id { lastWasDictation = false }
        }
        .onChange(of: dictation.activeTarget == session.id, initial: true) { _, dictating in
            lastWasDictation = dictating || (lastWasDictation && !ComposerStatus.shows(for: session))
        }
        .animation(.easeOut(duration: 0.15), value: dictation.activeTarget == session.id)
        .onChange(of: showsStop, initial: true) { _, stops in
            stopper = stops ? interrupt : nil
        }
        .onChange(of: chosenModel) { _, choice in
            guard let choice else { return }
            chosenModel = nil
            guard session.canRunCommand else { return }
            modelPicker = nil
            let newModel = choice.matches(session.model) ? nil : choice
            let effort = effortChanged && (newModel != nil || pickerEffort != session.effortLevel) ? pickerEffort : nil
            if newModel != nil || effort != nil { modelRequest = ModelRequest(model: newModel, effort: effort) }
        }
        .animation(.easeOut(duration: 0.12), value: ComposerDraft.mode(of: draft))
        .onChange(of: draft) { _, new in
            highlighted = 0
            if new != dismissedFor { dismissedFor = nil }
            history.draftChanged(to: new)
        }
        .onChange(of: field) { _, text in fieldChanged(to: text) }
        .onChange(of: draft, initial: true) { _, new in draftChanged(to: new) }
        .onChange(of: sentMessages, initial: true) { _, new in history.update(entries: new) }
        .onAppear { commandList = commands }
        .onChange(of: commands) { _, new in commandList = new }
        .onAppear { mentionList = FileMention.all(from: files) }
        .onChange(of: files) { _, new in mentionList = FileMention.all(from: new) }
        .onChange(of: folderRoot, initial: true) { _, new in folders.root = new }
        .onAppear(perform: watchPastes)
        .onAppear { suggestion = session.canReply ? session.suggestion : nil }
        .onChange(of: session.suggestion) { _, new in suggestion = session.canReply ? new : nil }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    /// The text field pastes text only, so a picture on the clipboard is
    /// caught first and attached. Anything else pastes as usual. Also
    /// catches Shift-Return, which would otherwise send.
    private func watchPastes() {
        guard pasteMonitor == nil else { return }
        let attachments = $attachments
        let draft = $draft
        let suggestion = $suggestion
        let sendRightAway = sendRightAway
        let commandList = $commandList
        let mentionList = $mentionList
        let folders = folders
        let highlighted = $highlighted
        let dismissedFor = $dismissedFor
        let modelPicker = $modelPicker
        let chosenModel = $chosenModel
        let pickerEffort = $pickerEffort
        let effortChanged = $effortChanged
        let history = $history
        let accept: (SlashCommand, ComposerToken, Bool) -> Void = { accept($0, for: $1, sending: $2) }
        let fill = fill
        let stopper = $stopper
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [focused = $focused] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // While dictating: Space (with the key held) goes hands-free,
            // and Escape throws the recording away.
            if focused.wrappedValue, Dictation.shared.keyDown(event) { return nil }
            // While the model list shows: up and down move, left and right
            // change the effort, Return or a number switches, Escape closes
            // it. Any other key closes it and types.
            if focused.wrappedValue, let row = modelPicker.wrappedValue {
                let models = session.agentCatalog.models
                let plain = modifiers.subtracting([.numericPad, .function]).isEmpty
                switch event.keyCode {
                case 125 where plain: modelPicker.wrappedValue = (row + 1) % models.count; return nil
                case 126 where plain: modelPicker.wrappedValue = (row + models.count - 1) % models.count; return nil
                case 123 where plain, 124 where plain:
                    let step = event.keyCode == 124 ? 1 : -1
                    pickerEffort.wrappedValue = pickerEffort.wrappedValue?.stepped(step) ?? .high
                    effortChanged.wrappedValue = true
                    return nil
                case 36 where plain, 76 where plain: chosenModel.wrappedValue = models[row]; return nil
                case 53: modelPicker.wrappedValue = nil; return nil
                default:
                    if plain, let digit = event.characters.flatMap(Int.init), (1...models.count).contains(digit) {
                        modelPicker.wrappedValue = digit - 1
                        chosenModel.wrappedValue = models[digit - 1]
                        return nil
                    }
                    modelPicker.wrappedValue = nil
                }
            }
            // While suggestions show: arrows move, Tab fills the pick in,
            // Return runs a command that's the whole message (or fills it
            // in if it takes something after) and fills in anything else,
            // Escape hides them.
            if focused.wrappedValue, dismissedFor.wrappedValue != draft.wrappedValue,
               modifiers.subtracting([.numericPad, .function]).isEmpty,
               let found = Suggestions.find(draft: draft.wrappedValue,
                                            caret: Self.caret(in: event.window).map { $0 < 0 ? $0 : $0 + ComposerDraft.hiddenPrefixLength(in: draft.wrappedValue) },
                                            commands: commandList.wrappedValue, files: mentionList.wrappedValue, folders: folders) {
                let index = min(highlighted.wrappedValue, found.count - 1)
                var sending: Bool?
                switch event.keyCode {
                case 125: highlighted.wrappedValue = (index + 1) % found.count; return nil
                case 126: highlighted.wrappedValue = (index + found.count - 1) % found.count; return nil
                case 48: sending = false
                case 36, 76: sending = true
                case 53: dismissedFor.wrappedValue = draft.wrappedValue; return nil
                default: break
                }
                if let sending {
                    switch found.list {
                    case .commands(let commands): accept(commands[index], found.token, sending)
                    case .files(let mentions): fill(found.token, mentions[index].insertion)
                    }
                    return nil
                }
            }
            // Shell mode. `!` typed at the very start of the box becomes
            // the chip, so what you type next is the command, space or no
            // space. `/btw` becomes a chip the same way once it's typed
            // (see fieldChanged). Delete back there, or Escape, makes it a
            // message again and keeps what you typed.
            if focused.wrappedValue, modifiers.isDisjoint(with: [.command, .control]),
               let editor = event.window?.firstResponder as? NSTextView, !editor.hasMarkedText() {
                let inMode = ComposerDraft.mode(of: draft.wrappedValue) != .message
                let atStart = editor.selectedRange() == NSRange(location: 0, length: 0)
                if !inMode, atStart, event.characters == "!" {
                    draft.wrappedValue = ShellDraft.draft(forCommand: draft.wrappedValue)
                    return nil
                }
                if inMode, atStart, event.characters == " " { return nil }
                if inMode, (atStart && event.keyCode == 51) || event.keyCode == 53 {
                    draft.wrappedValue = ComposerDraft.leaving(draft.wrappedValue)
                    return nil
                }
            }
            if focused.wrappedValue, event.keyCode == 36 || event.keyCode == 76, modifiers == .control {
                sendRightAway()
                return nil
            }
            // Up on the first line brings back the last message you sent,
            // and earlier ones after it, the way a shell recalls commands.
            // Down on the last line comes forward again, ending with what
            // you had typed. Inside a longer message, including one that
            // wraps onto several lines, the arrows just move.
            if focused.wrappedValue, event.keyCode == 126 || event.keyCode == 125,
               modifiers.subtracting([.numericPad, .function]).isEmpty,
               let editor = event.window?.firstResponder as? NSTextView {
                let up = event.keyCode == 126
                let recalled: String?
                if up, ComposerLines.caretIsOnFirstLine(of: editor) {
                    recalled = history.wrappedValue.up(from: draft.wrappedValue)
                } else if !up, history.wrappedValue.isBrowsing, ComposerLines.caretIsOnLastLine(of: editor) {
                    recalled = history.wrappedValue.down()
                } else {
                    recalled = nil
                }
                if let recalled {
                    draft.wrappedValue = recalled
                    DispatchQueue.main.async {
                        (event.window?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
                    }
                    return nil
                }
            }
            // Right arrow or Tab in the empty box takes Claude Code's
            // suggestion, the way they do in its terminal.
            if focused.wrappedValue, event.keyCode == 124 || event.keyCode == 48,
               modifiers.subtracting([.numericPad, .function]).isEmpty,
               draft.wrappedValue.isEmpty, let text = suggestion.wrappedValue {
                draft.wrappedValue = text
                DispatchQueue.main.async {
                    (event.window?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
                }
                return nil
            }
            // Shift-Return (or Option-Return) starts a new line where the
            // cursor is, instead of sending.
            if focused.wrappedValue, event.keyCode == 36 || event.keyCode == 76,
               !modifiers.intersection([.shift, .option]).isEmpty, modifiers.isDisjoint(with: [.command, .control]),
               let editor = event.window?.firstResponder as? NSTextView {
                Self.insertNewline(in: editor)
                return nil
            }
            // Escape in an empty box stops Claude, as it does in the
            // terminal. Everything above that uses Escape (the lists,
            // shell mode, dictation) has had its turn by now.
            if focused.wrappedValue, event.keyCode == 53, modifiers.isEmpty, let stop = stopper.wrappedValue {
                stop()
                return nil
            }
            guard modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  focused.wrappedValue else { return event }
            let pasted = RemoteAttachment.pasted(from: .general, numberedFrom: attachments.wrappedValue.count + 1)
            guard !pasted.isEmpty else { return event }
            attachments.wrappedValue += pasted
            return nil
        }
    }

    /// A new line where the cursor is. On a list item, the next item's
    /// marker comes with it: the same bullet, or the next number. On an
    /// item with nothing in it, the marker goes instead, ending the list.
    private static func insertNewline(in editor: NSTextView) {
        let text = editor.string
        guard let selection = Range(editor.selectedRange(), in: text) else {
            editor.insertNewlineIgnoringFieldEditor(nil)
            return
        }
        let edit = ListShorthand.newline(in: text, replacing: selection)
        editor.insertText(edit.replacement, replacementRange: NSRange(edit.range, in: text))
    }

    /// The cursor in the message box, if it has the keys: -1 with text
    /// selected, as suggestions only show for a plain cursor.
    private static func caret(in window: NSWindow?) -> Int? {
        guard let editor = window?.firstResponder as? NSTextView else { return nil }
        let selection = editor.selectedRange()
        return selection.length == 0 ? selection.location : -1
    }

    /// Puts a picked command in the box. One that's the whole message
    /// fills the box; one mid-message replaces just its word.
    private func accept(_ command: SlashCommand, for token: ComposerToken, sending: Bool) {
        if token.isWholeMessage {
            accept(command, sending: sending)
        } else {
            fill(token, with: "/" + command.name + " ")
        }
    }

    /// Replaces the word being typed with a pick, leaving the cursor after
    /// it. Typed into the editor, so Undo takes it back.
    private func fill(_ token: ComposerToken, with text: String) {
        highlighted = 0
        // The editor holds the draft without the `!` or `/btw` the chip stands for.
        let hidden = ComposerDraft.hiddenPrefixLength(in: draft)
        var range = NSRange(token.range, in: draft)
        range.location -= hidden
        if range.location >= 0, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
           editor.string == ComposerDraft.fieldText(for: draft) {
            editor.insertText(text, replacementRange: range)
            return
        }
        guard token.range.upperBound <= draft.endIndex else { return }
        draft.replaceSubrange(token.range, with: text)
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        }
    }

    /// Puts a picked command in the box. With `sending`, one that takes
    /// nothing after its name is sent right away, as in the terminal. One
    /// that opens a picker goes to the terminal, where the picker shows,
    /// unless the chat has its own way to do what it does.
    private func accept(_ command: SlashCommand, sending: Bool) {
        if sending, command.name == "model" {
            openModelPicker(clearingDraft: true)
            return
        }
        if let runChatCommand, let chat = command.chatCommand, chat.runsInChat {
            draft = ""
            runChatCommand(chat)
            return
        }
        if command.opensInTerminal, let runInTerminal {
            draft = ""
            runInTerminal("/" + command.name)
            return
        }
        draft = command.completion
        if sending, command.argumentHint == nil {
            DispatchQueue.main.async { submit() }
        } else {
            DispatchQueue.main.async {
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
            }
        }
    }

    /// Sends, unless the message is just `/model`: that opens the list of
    /// models instead, as it does in Claude Code's terminal. Other commands
    /// the chat handles itself, like `/resume`, are run here too.
    private func submit() {
        if ModelChoice.opensPicker(draft), attachments.isEmpty {
            openModelPicker(clearingDraft: true)
        } else if attachments.isEmpty, let runChatCommand, let chat = ChatCommand(draft: draft), chat.runsInChat {
            draft = ""
            runChatCommand(chat)
        } else {
            send()
        }
    }

    /// Opens the model list. Typing `/model` clears that command out of the
    /// box. Opening it from the model pill leaves your message as it is.
    private func openModelPicker(clearingDraft: Bool = false) {
        if clearingDraft { draft = "" }
        pickerEffort = session.effortLevel
        effortChanged = false
        modelPicker = session.agentCatalog.models.firstIndex { $0.matches(session.model) } ?? 0
    }

    /// How the lists above the box arrive: growing a little out of the
    /// corner they belong to. Never a fade. Glass can't cross-fade, so
    /// fading one in shows the conversation through it until it lands.
    private static func listTransition(from corner: UnitPoint) -> AnyTransition {
        ChatMotion.glassList(from: corner)
    }

    private var placeholder: String {
        guard session.canReply else { return isStarting ? "Starting \(session.agentTitle)" : "Can't send right now" }
        return session.activity == .working ? "Queue a message for when \(session.agentTitle) finishes this step" : "Message \(session.agentTitle)"
    }

    private var canSend: Bool {
        // A side question is just the question: pictures wait for the next message.
        if isSideQuestion { return session.canReply && !ComposerDraft.isEmpty(draft) }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ShellDraft.isEmptyCommand(draft)
        return session.canReply && (hasText || !attachments.isEmpty)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let data = try? Data(contentsOf: url) {
                attachments.append(RemoteAttachment(name: url.lastPathComponent, data: data))
            }
        }
    }
}

/// A picture waiting to be sent: a small preview, with a button on its
/// corner to take it off. Hover for its name.
private struct AttachmentThumbnail: View {
    @Environment(\.companionPalette) private var palette
    let attachment: RemoteAttachment
    let remove: () -> Void
    @State private var hovering = false

    private let side: CGFloat = 56

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let thumbnail = attachment.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.ui(size: 18))
                    .foregroundStyle(palette.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.raised)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.hairline))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.ui(size: 8, weight: .bold))
                    .foregroundStyle(palette.ink)
                    .frame(width: 18, height: 18)
                    .background(palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(palette.hairline))
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .offset(x: 6, y: -6)
            .opacity(hovering ? 1 : 0.85)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .onHover { hovering = $0 }
        .help(attachment.name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.name)
    }
}

/// Claude Code commands, like compacting, without typing them.
private struct QuickCommandMenu: View {
    @Environment(\.companionPalette) private var palette
    let session: CompanionSession
    let run: (QuickCommand) -> Void
    @State private var confirming: QuickCommand?

    var body: some View {
        Menu {
            ForEach(session.agentCatalog.quickCommands) { command in
                Button(command.title, systemImage: command.symbol) {
                    if command.confirmation != nil { confirming = command } else { run(command) }
                }
                .help(command.help)
            }
        } label: {
            Image(systemName: "slash.circle")
                .font(.ui(size: 13))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(palette.inkMuted)
        .disabled(!session.canRunCommand)
        .help(session.canRunCommand ? "Commands" : "Commands work once \(session.agentTitle) finishes")
        .accessibilityLabel("Commands")
        .confirmationDialog(confirming?.confirmation?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let command = confirming, let confirmation = command.confirmation {
                Button(confirmation.button, role: .destructive) { run(command) }
            }
        } message: {
            Text(confirming?.confirmation?.message ?? "")
        }
    }
}

/// The model Claude is using. Click it for the same list `/model` opens.
/// Shows the model picked right away, with a spinner until Claude confirms.
private struct ModelPill: View {
    @Environment(\.companionPalette) private var palette
    let session: CompanionSession
    /// Set by the list to switch, after asking first if the conversation is long.
    @Binding var request: ModelRequest?
    let switchModel: (ModelChoice) -> Void
    let setEffort: (EffortLevel) -> Void
    let open: () -> Void
    @State private var hovering = false
    @State private var switching: ModelChoice?

    private var current: String? { switching?.name ?? session.model }
    /// Fable gets an amber capsule all the time, so it's never missed.
    private var costly: Bool { ModelChoice.usesLimitsFaster(model: session.model, switching: switching) }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                if costly {
                    Image(systemName: "flame.fill")
                        .font(.ui(size: 9, weight: .semibold))
                        .transition(.opacity)
                }
                Text(ModelChoice.label(model: session.model, switching: switching))
                    .font(.ui(size: 11, weight: .medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if switching != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.ui(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(costly ? ModelChoice.costlyColor : hovering ? palette.ink : palette.inkMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .overlay { if costly { Capsule().strokeBorder(ModelChoice.costlyColor.opacity(0.35), lineWidth: 0.5) } }
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: current)
        }
        .buttonStyle(.pressable)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("Model \(current ?? "unknown")")
        .accessibilityValue(costly ? ModelChoice.usesLimitsFasterNote : "")
        .modelSwitching($request, switching: $switching, model: session.model,
                        switchModel: switchModel, setEffort: setEffort)
    }

    private var background: Color {
        if costly { return ModelChoice.costlyColor.opacity(hovering ? 0.24 : 0.14) }
        return hovering ? palette.raised : .clear
    }

    private var help: String {
        if let switching { return "Switching to \(switching.name)…" }
        let change = "Change the model or effort (/model)"
        return costly ? "\(ModelChoice.usesLimitsFasterHelp) \(change)" : change
    }
}

/// Claude Code's permission mode, beside the model: how much Claude does
/// before asking. A menu switches it, the way Shift-Tab does in its
/// terminal. The pill shows the mode it's switching to until the Mac
/// reports it.
private struct ModePill: View {
    @Environment(\.companionPalette) private var palette
    let mode: PermissionMode
    let set: (PermissionMode) -> Void
    @State private var hovering = false
    @State private var switching: PermissionMode?

    private var shown: PermissionMode { switching ?? mode }

    private func choose(_ option: PermissionMode) {
        guard option != mode else { switching = nil; return }
        switching = option
        set(option)
        // Give up on showing it if the Mac never reports it.
        Task {
            try? await Task.sleep(for: .seconds(4))
            if switching == option { switching = nil }
        }
    }

    var body: some View {
        Menu {
            Picker("Mode", selection: Binding(get: { shown }, set: choose)) {
                ForEach(PermissionMode.offered, id: \.self) { option in
                    // Two lines of text: the name, and what it does under it.
                    Label {
                        Text(option.name)
                        Text(option.detail)
                    } icon: {
                        Image(systemName: option.symbol)
                    }
                    .tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: shown.symbol)
                    .font(.ui(size: 9, weight: .semibold))
                Text(shown.name)
                    .font(.ui(size: 11, weight: .medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if switching != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.ui(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(hovering ? palette.raised : .clear, in: Capsule())
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: shown)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .onChange(of: mode) { _, new in
            if new == switching { switching = nil }
        }
        .help("\(shown.name): \(shown.detail). Change the mode (Shift-Tab in the terminal)")
        .accessibilityLabel("Mode \(shown.name)")
    }

    /// The same color as the model beside it, whatever the mode.
    private var tint: Color { hovering ? palette.ink : palette.inkMuted }
}

/// A row in one of the lists above the message box, dimmed while the
/// mouse is down on it. The highlight is the hover state.
private struct ListRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The models to switch to, floating above the message box after you type
/// `/model`, like the list Claude Code shows in its terminal.
private struct ModelPicker: View {
    /// What the session's agent offers.
    let catalog: AgentCatalog
    @Environment(\.companionPalette) private var palette
    /// The session's model, like "Opus 5.5".
    let current: String?
    let highlighted: Int
    let canSwitch: Bool
    /// The effort level shown, or nil when the Mac doesn't know it.
    let effort: EffortLevel?
    let pick: (ModelChoice) -> Void
    let pickEffort: (EffortLevel) -> Void
    /// The pointer moved onto a row, which takes the highlight.
    let highlight: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Switch Model")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 4)
            ForEach(Array(catalog.models.enumerated()), id: \.element.id) { index, choice in
                let isCurrent = choice.matches(current)
                Button { pick(choice) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.ui(size: 12).monospacedDigit())
                            .foregroundStyle(palette.inkMuted)
                        HStack(spacing: 4) {
                            Text(isCurrent ? current ?? choice.name : choice.name)
                                .font(.ui(size: 13, weight: .semibold))
                                .foregroundStyle(palette.ink)
                            if choice.isEconomy {
                                Image(systemName: "leaf.fill")
                                    .font(.ui(size: 10, weight: .semibold))
                                    .foregroundStyle(palette.done)
                                    .accessibilityHidden(true)
                            }
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .font(.ui(size: 10, weight: .bold))
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .frame(minWidth: 96, alignment: .leading)
                        Text(choice.summary)
                            .font(.ui(size: 12))
                            .foregroundStyle(palette.inkMuted)
                            .lineLimit(1)
                        if choice.usesLimitsFaster {
                            Label(ModelChoice.usesLimitsFasterNote, systemImage: "flame.fill")
                                .font(.ui(size: 11, weight: .medium))
                                .foregroundStyle(ModelChoice.costlyColor)
                                .lineLimit(1)
                                .help(ModelChoice.usesLimitsFasterHelp)
                        }
                        Spacer(minLength: 6)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == highlighted ? palette.accent.opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ListRowPress())
                .onHover { if $0, canSwitch { highlight(index) } }
                .disabled(!canSwitch)
                .opacity(canSwitch ? 1 : 0.6)
                .accessibilityLabel(isCurrent ? "\(choice.name), current model" : choice.name)
            }
            effortRow
            Text(canSwitch ? "↑↓ model · ←→ effort · Return to switch · Esc to cancel"
                 : "You can change the model once the agent finishes · Esc to close")
                .font(.ui(size: Theme.TypeScale.meta))
                .foregroundStyle(palette.inkMuted.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Effort, as five steps to click, like the dots in Claude Code's list.
    private var effortRow: some View {
        HStack(spacing: 4) {
            Text("Effort")
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(palette.inkMuted)
                .frame(width: 44, alignment: .leading)
            ForEach(catalog.efforts) { level in
                let isOn = level == effort
                Button { pickEffort(level) } label: {
                    Text(level.name)
                        .font(.ui(size: Theme.TypeScale.bodySmall, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? palette.ink : palette.inkMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isOn ? palette.accent.opacity(0.2) : palette.ink.opacity(0.05), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(ListRowPress())
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            if effort == nil {
                Text("Default")
                    .font(.ui(size: Theme.TypeScale.bodySmall))
                    .foregroundStyle(palette.inkMuted)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .disabled(!canSwitch)
        .opacity(canSwitch ? 1 : 0.6)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// How full Claude's context is: a small ring that fills clockwise, warming
/// up to orange and then red as it nears the limit. Hovering (or clicking)
/// opens a card that says what the ring is and gives the exact numbers.
private struct ChatContextMeter: View {
    @Environment(\.companionPalette) private var palette
    let tokens: Int
    let window: Int

    @State private var hovering = false
    @State private var showsCard = false

    private var fraction: Double { min(1, Double(tokens) / Double(max(1, window))) }
    private var color: Color { fraction >= 0.85 ? Theme.Status.failed : fraction >= 0.7 ? palette.waitingInk : palette.inkMuted }
    private var percent: Int { Int((fraction * 100).rounded()) }

    var body: some View {
        Button { showsCard.toggle() } label: {
            ZStack {
                Circle()
                    .stroke(palette.inkMuted.opacity(0.2), lineWidth: 2.5)
                Circle()
                    // A sliver even when nearly empty, so the ring reads as a meter.
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            .padding(5)
            .background(Circle().fill(hovering || showsCard ? palette.raised : .clear))
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.3), value: fraction)
        }
        .buttonStyle(.pressable)
        .onHover { over in
            hovering = over
            hoverChanged()
        }
        .popover(isPresented: $showsCard, arrowEdge: .top) {
            ContextCard(tokens: tokens, window: window, fraction: fraction, percent: percent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent) percent full")
        .accessibilityHint("How much of the agent's working memory this conversation has used")
    }

    /// Opens after a beat, so the card doesn't flash when the pointer only
    /// passes over on its way to Send, and closes soon after it leaves.
    private func hoverChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + (hovering ? 0.25 : 0.15)) {
            if showsCard != hovering { showsCard = hovering }
        }
    }
}

/// What the context ring means, in a sentence, with the numbers behind it.
private struct ContextCard: View {
    let tokens: Int
    let window: Int
    let fraction: Double
    let percent: Int

    /// System colors, not the chat theme's: the popover follows the Mac's
    /// appearance, whatever the chat is themed as.
    private var color: Color { fraction >= 0.85 ? Theme.Status.failed : fraction >= 0.7 ? .orange : .secondary }

    private var advice: String? {
        if fraction >= 0.85 { return "Nearly full. Run /compact to summarize now, or start a new chat." }
        if fraction >= 0.7 { return "Getting full. /compact or a new chat will keep the agent sharp." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context")
                    .font(.ui(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                Text("\(percent)% full")
                    .font(.ui(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(fraction >= 0.7 ? color : .primary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: 4)
            Text("\(shortTokens(tokens)) of \(shortTokens(window)) tokens")
                .font(.ui(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Text("How much of the agent's working memory this conversation has used. When it fills up, the agent summarizes the earlier parts to make room, and some detail gets lost.")
                .font(.ui(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let advice {
                Text(advice)
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}

/// What to suggest for the word at the cursor: commands after a `/`,
/// files and folders after an `@`.
private struct Suggestions: Equatable {
    enum List: Equatable {
        case commands([SlashCommand])
        case files([FileMention])
    }

    var token: ComposerToken
    var list: List

    var count: Int {
        switch list {
        case .commands(let commands): commands.count
        case .files(let mentions): mentions.count
        }
    }

    /// Nil when there's nothing to suggest. With no `caret`, the cursor is
    /// taken to be at the end.
    static func find(draft: String, caret: Int?, commands: [SlashCommand], files: [FileMention], folders: MentionFolders) -> Suggestions? {
        guard let token = ComposerToken.at(caret ?? draft.utf16.count, in: draft) else { return nil }
        switch token.kind {
        case .command:
            // Mid-message, only commands that mean something there, like skills.
            let offered = token.isWholeMessage ? commands : commands.filter(\.worksMidMessage)
            let found = SlashCommand.matches(query: token.query, in: offered)
            return found.isEmpty ? nil : Suggestions(token: token, list: .commands(found))
        case .file:
            let query = token.query.hasPrefix("\"") ? String(token.query.dropFirst()) : token.query
            // A path outside the project, like `~/` or `../`, isn't in its
            // listing, so what's in that folder on disk is suggested.
            let found = MentionFolder(query: query).map { $0.matches(in: folders.entries(in: $0)) }
                ?? FileMention.matches(query: query, in: files)
            return found.isEmpty ? nil : Suggestions(token: token, list: .files(found))
        }
    }
}

/// Reads the folders that `@` paths outside the project point into, like
/// `~/` or `../app/`, as Claude Code's own picker does. The suggestions are
/// worked out a few times a key, so the last folder read is kept a moment.
private final class MentionFolders {
    /// The folder relative paths count from, or nil to read nothing, for
    /// a session on another Mac.
    var root: String?
    private var last: (path: String, read: Date, entries: [FileMention])?

    /// What's in `folder`, each named on its own.
    func entries(in folder: MentionFolder) -> [FileMention] {
        guard let root, let path = folder.path(root: root) else { return [] }
        if let last, last.path == path, Date().timeIntervalSince(last.read) < 2 { return last.entries }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let entries = names.map { name in
            // Follows links, so a link to a folder opens like one.
            var isFolder: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isFolder)
            return FileMention(path: name, isDirectory: isFolder.boolValue)
        }
        last = (path, Date(), entries)
        return entries
    }
}

/// The files and folders matching what's typed after an `@`,
/// floating above the message box.
private struct FileSuggestions: View {
    @Environment(\.companionPalette) private var palette
    let mentions: [FileMention]
    let highlighted: Int
    /// The pointer moved onto a row, which takes the highlight.
    let highlight: (Int) -> Void
    let pick: (FileMention) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(mentions.enumerated()), id: \.element.id) { index, mention in
                Button { pick(mention) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: mention.isDirectory ? "folder" : FileIcon.symbol(for: mention.name))
                            .font(.ui(size: 12))
                            .foregroundStyle(palette.inkMuted)
                            .frame(width: 16)
                        Text(mention.name + (mention.isDirectory ? "/" : ""))
                            .font(.ui(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(mention.folder)
                            .font(.ui(size: 12))
                            .foregroundStyle(palette.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 6)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == highlighted ? palette.accent.opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ListRowPress())
                .onHover { if $0 { highlight(index) } }
                .help(mention.path)
            }
            Text("↑↓ to choose · Tab or Return to fill in · Esc to hide")
                .font(.ui(size: Theme.TypeScale.meta))
                .foregroundStyle(palette.inkMuted.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The slash commands matching what's typed, floating above the message box.
private struct CommandSuggestions: View {
    @Environment(\.companionPalette) private var palette
    let commands: [SlashCommand]
    let highlighted: Int
    /// True when Return runs the pick. Mid-message it only fills it in.
    var runs = true
    /// The pointer moved onto a row, which takes the highlight.
    let highlight: (Int) -> Void
    let pick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button { pick(command) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/" + command.name)
                            .font(.ui(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let hint = command.argumentHint {
                            Text(hint)
                                .font(.ui(size: 12, design: .monospaced))
                                .foregroundStyle(palette.inkMuted.opacity(0.8))
                                .lineLimit(1)
                        }
                        Text(command.description)
                            .font(.ui(size: 12))
                            .foregroundStyle(palette.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        if let label = tag(command) {
                            Text(label)
                                .font(.ui(size: Theme.TypeScale.meta, weight: .medium))
                                .foregroundStyle(palette.inkMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(palette.ink.opacity(0.07), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == highlighted ? palette.accent.opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ListRowPress())
                .onHover { if $0 { highlight(index) } }
                .help(command.description)
            }
            Text(runs ? "↑↓ to choose · Tab to fill in · Return to run · Esc to hide"
                      : "↑↓ to choose · Tab or Return to fill in · Esc to hide")
                .font(.ui(size: Theme.TypeScale.meta))
                .foregroundStyle(palette.inkMuted.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tag(_ command: SlashCommand) -> String? {
        if command.opensInTerminal { return "Terminal" }
        switch command.source {
        case .project: return "Project"
        case .plugin: return command.name.split(separator: ":").first.map(String.init) ?? "Plugin"
        case .user: return nil
        case .builtIn: return nil
        }
    }
}

/// Reports which edges of a SwiftUI text field have text scrolled out of
/// sight past them. Put it behind the field: it finds the AppKit field
/// there and, while typing, the clip view the editor scrolls in.
private struct ScrollEdgesWatcher: NSViewRepresentable {
    /// Passed so a change in the text or focus checks again.
    let text: String
    let isFocused: Bool
    /// The cursor's color. Over glass in dark mode the system's own came
    /// out dark on dark, so it's set to the text's color.
    let caret: NSColor
    let report: (Edge.Set) -> Void
    /// Where the cursor is while typing (a UTF-16 offset), -1 with text
    /// selected, nil while the field isn't being typed in.
    var reportCaret: ((Int?) -> Void)?

    func makeNSView(context: Context) -> WatcherView { WatcherView() }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.report = report
        view.reportCaret = reportCaret
        view.caret = caret
        // After AppKit has laid out the new text.
        DispatchQueue.main.async { view.check() }
    }

    final class WatcherView: NSView {
        var report: ((Edge.Set) -> Void)?
        var reportCaret: ((Int?) -> Void)?
        var caret: NSColor?
        private weak var observedClip: NSClipView?
        private weak var observedEditor: NSTextView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.check() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            DispatchQueue.main.async { self.check() }
        }

        /// The text field drawn over this view.
        private var field: NSTextField? {
            guard let root = window?.contentView else { return nil }
            let frame = convert(bounds, to: nil)
            func search(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable,
                   field.convert(field.bounds, to: nil).intersects(frame.insetBy(dx: 2, dy: 2)) { return field }
                for child in view.subviews {
                    if let found = search(child) { return found }
                }
                return nil
            }
            return search(root)
        }

        func check() {
            guard let field else { return }
            var edges: Edge.Set = []
            if let editor = field.currentEditor() as? NSTextView {
                // The window shares one editor among its fields, so each
                // selection change checks that it's still this field's.
                if observedEditor !== editor {
                    if let observedEditor {
                        NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: observedEditor)
                    }
                    observedEditor = editor
                    NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                                           name: NSTextView.didChangeSelectionNotification, object: editor)
                }
                let selection = editor.selectedRange()
                reportCaret?(selection.length == 0 ? selection.location : -1)
            } else {
                reportCaret?(nil)
            }
            if let editor = field.currentEditor() as? NSTextView, let caret, editor.insertionPointColor != caret {
                editor.insertionPointColor = caret
            }
            if let editor = field.currentEditor() as? NSTextView, let clip = editor.superview as? NSClipView {
                if observedClip !== clip {
                    observedClip = clip
                    clip.postsBoundsChangedNotifications = true
                    NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                                           name: NSView.boundsDidChangeNotification, object: clip)
                }
                if clip.bounds.minY > 1 { edges.insert(.top) }
                if clip.bounds.maxY < editor.frame.height - 1 { edges.insert(.bottom) }
            } else {
                // Not typing: the field shows its first lines. The cell
                // measures only up to its line limit, so measure the text.
                let needed = field.attributedStringValue.boundingRect(
                    with: NSSize(width: field.bounds.width - 4, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                if needed > field.bounds.height + 1 { edges.insert(.bottom) }
            }
            report?(edges)
        }

        @objc private func scrolled() { check() }
        @objc private func selectionChanged() { check() }
    }
}


/// Fades scrolled text out under the top of its card, where the system's
/// soft edge has no bar to work from. It only shows once something has
/// scrolled up there, so the first lines of a conversation stay whole.
private struct SoftTopEdge: ViewModifier {
    let surface: Color
    @State private var isScrolled = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 4 } action: { _, scrolled in
                isScrolled = scrolled
            }
            .overlay(alignment: .top) {
                LinearGradient(stops: [.init(color: surface, location: 0),
                                       .init(color: surface.opacity(0.75), location: 0.35),
                                       .init(color: surface.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                    .opacity(isScrolled ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isScrolled)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    /// Fades this scroll view's content out at its top edge, into `surface`.
    func softTopEdge(surface: Color) -> some View { modifier(SoftTopEdge(surface: surface)) }
}

#if DEBUG
/// A stretch of Claude's work as the chat draws it, to PNGs in light and
/// dark: reads, edits (one open, as the newest is while Claude works),
/// commands that passed, failed and are still running, and a reply either
/// side. BENCH_RENDER_WORKLOG=<folder>.
enum WorkLogPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        let now = Date()
        func tool(_ id: String, _ name: String, _ text: String, _ detail: String?, edit: ToolEdit? = nil, ago: TimeInterval = 60) -> TranscriptMessage {
            TranscriptMessage(id: id, role: .tool, text: text, detail: detail, toolName: name, at: now.addingTimeInterval(-ago),
                              edit: edit, toolUseID: id)
        }
        func result(_ id: String, _ text: String, error: Bool = false) -> TranscriptMessage {
            TranscriptMessage(id: "r" + id, role: .tool, text: text, at: now.addingTimeInterval(-30), resultOf: id, isError: error)
        }
        let finished: [TranscriptMessage] = [
            tool("1", "Read", "Reading RecipeStore.swift", "/p/Recipes/RecipeStore.swift"),
            tool("2", "Grep", "Searching", "shoppingList in Recipes"),
            tool("3", "Write", "Writing ShoppingList.swift", "/p/Recipes/ShoppingList.swift",
                 edit: ToolEdit(removed: [], added: ["import Foundation", "", "struct ShoppingList {"], removedCount: 0, addedCount: 31, isNewFile: true)),
            tool("4", "Edit", "Editing RecipeStore.swift", "/p/Recipes/RecipeStore.swift",
                 edit: ToolEdit(removed: [], added: ["    let shoppingList = ShoppingList()"], removedCount: 0, addedCount: 1, isNewFile: false)),
            tool("5", "Edit", "Editing RecipeStore.swift", "/p/Recipes/RecipeStore.swift",
                 edit: ToolEdit(removed: ["        recipes.remove(recipe)"],
                                added: ["        recipes.remove(recipe)", "        shoppingList.removeItems(from: recipe)"],
                                removedCount: 1, addedCount: 2, isNewFile: false)),
            tool("6", "Bash", "Running the tests", "cd /p/Recipes && swift test --filter ShoppingListTests"),
            tool("7", "Bash", "Checking the style", "swiftlint"),
        ]
        let finishedResults = [
            "6": result("6", "Test Suite 'ShoppingListTests' passed.\n\t Executed 6 tests, with 0 failures in 0.412 seconds"),
            "7": result("7", "RecipeStore.swift:41:9: error: Line Length Violation\nDone linting! Found 1 violation, 1 serious in 14 files.", error: true),
        ]
        let live: [TranscriptMessage] = [
            tool("8", "Edit", "Editing RecipeDetailView.swift", "/p/Recipes/RecipeDetailView.swift",
                 edit: ToolEdit(removed: ["            Spacer()"],
                                added: ["            Spacer()", "            Button(\"Add to List\") { store.shoppingList.add(recipe) }",
                                        "                .buttonStyle(.borderedProminent)"],
                                removedCount: 1, addedCount: 5, isNewFile: false)),
        ]
        let running: [TranscriptMessage] = live + [
            tool("9", "Bash", "Building the app", "cd /p/Recipes && xcodebuild -scheme Recipes build", ago: 570),
        ]
        let palette = TerminalTheme.shared.chatPalette
        func reply(_ text: String) -> some View {
            Text(text).font(ChatStyle.body).foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
        }
        let view = VStack(alignment: .leading, spacing: 18) {
            reply("I'll add a shopping list model first, then the button on each recipe.")
            StepRunView(steps: finished, results: finishedResults)
            reply("The model is in. Now the button on each recipe.")
            StepRunView(steps: live, results: [:], isLive: true)
            reply("And once the next step has arrived:")
            StepRunView(steps: running, results: [:], isLive: true)
        }
        .padding(28)
        .frame(width: 640, alignment: .leading)
        .background(palette.canvas)
        .environment(\.companionPalette, palette)
        .environment(\.stepFonts, ChatStyle.steps)
        .environment(\.markdownFonts, ChatStyle.markdown)
        .environment(\.openStepFile, { _ in })
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("worklog-\(name).png"))
        }
    }
}

/// The message box in each of its states, to PNGs in light and dark:
/// idle, working with nothing typed (the send button is Stop), working
/// with a draft, waiting, and working on another Mac.
/// BENCH_RENDER_COMPOSER=<folder>.
enum ComposerPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        let palette = TerminalTheme.shared.chatPalette
        func session(_ activity: ActivityKind, action: String? = nil, question: String? = nil, host: String? = nil, ago: TimeInterval = 0) -> CompanionSession {
            CompanionSession(id: UUID(), title: "Recipes", activity: activity, action: action, question: question,
                             contextTokens: 84_000, contextWindow: 200_000, model: "Opus 5.5", remoteHost: host,
                             canReply: true, since: activity == .idle ? nil : Date().addingTimeInterval(-ago))
        }
        let states: [(String, CompanionSession, String)] = [
            ("Idle", session(.idle), ""),
            ("Working, nothing typed", session(.working, action: "Running the tests", ago: 194), ""),
            ("Working, with a draft", session(.working, action: "Editing RecipeDetailView.swift", ago: 12), "Also add it to the iPad layout"),
            ("Waiting on you", session(.waiting, question: "Should the share button go in the toolbar?", ago: 47), ""),
            ("Working on another Mac", session(.remoteWorking, action: "Building the app", host: "studio", ago: 3_720), ""),
        ]
        let view = VStack(alignment: .leading, spacing: 18) {
            ForEach(states, id: \.0) { state in
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.0).font(.ui(size: 11, weight: .semibold)).foregroundStyle(palette.inkMuted)
                    Composer(session: state.1, draft: .constant(state.2), attachments: .constant([]), send: {}, sendRightAway: {},
                             interrupt: {}, switchModel: { _ in }, setEffort: { _ in }, runCommand: { _ in })
                }
            }
        }
        .padding(24)
        .frame(width: 640, alignment: .leading)
        .background(palette.canvas)
        .environment(\.companionPalette, palette)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("composer-\(name).png"))
        }
    }
}

/// The foot of a chat in a window of its own, with Claude starting and
/// finishing work on a timer, for watching the message box's status line
/// come and go. Laid out like `ChatBody`: a conversation with the message
/// box floating over its bottom edge. BENCH_COMPOSER_RIG=<seconds between
/// changes>. Prints the window's number, for `screencapture -l`.
/// With BENCH_COMPOSER_RIG_STARTING set, it goes between Claude starting
/// and ready instead.
enum ComposerRig {
    static func run(every seconds: Double) {
        let app = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 620, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Composer rig"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: RigView(seconds: seconds))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        print("window \(window.windowNumber)")
        fflush(stdout)
        app.run()
    }

    private struct RigView: View {
        let seconds: Double
        @State private var working = false
        @State private var draft = ""
        @State private var attachments: [RemoteAttachment] = []
        private let id = UUID()

        private let starts = ProcessInfo.processInfo.environment["BENCH_COMPOSER_RIG_STARTING"] != nil

        private var session: CompanionSession {
            if starts {
                return CompanionSession(id: id, title: "Recipes", activity: .idle, model: "Opus 5.5",
                                        canReply: working, isStarting: !working)
            }
            return CompanionSession(id: id, title: "Recipes", activity: working ? .working : .done,
                             action: "Running the tests", stoppedAt: Date().addingTimeInterval(-90),
                             contextTokens: 84_000, contextWindow: 200_000, model: "Opus 5.5",
                             canReply: true, since: working ? Date().addingTimeInterval(-12) : nil)
        }

        var body: some View {
            let palette = TerminalTheme.shared.chatPalette
            Color.clear.overlay {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(0..<14, id: \.self) { line in
                                Text("Line \(line + 1) of the conversation, so there is something to scroll under the box.")
                                    .font(ChatStyle.body).foregroundStyle(palette.ink)
                            }
                        }
                        LiveRow(session: session, spacing: 18).id("live")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                }
                .sticksToBottom(sentKey: 0)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                GlassEffectContainer(spacing: 4) {
                    VStack(spacing: 10) {
                        Composer(session: session, draft: $draft, attachments: $attachments, send: {}, sendRightAway: {},
                                 interrupt: {}, switchModel: { _ in }, setEffort: { _ in }, runCommand: { _ in })
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .background(palette.canvas)
            .environment(\.companionPalette, palette)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(seconds))
                    working.toggle()
                }
            }
        }
    }
}
#endif
