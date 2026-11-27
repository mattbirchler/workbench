import BenchKit
import SwiftUI

/// A project, tapped from the list: its Claude session as a conversation.
/// With several Claude tabs open, picks between them first.
struct ProjectScreen: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    /// A session to show instead of the list, when there are several.
    var sessionID: UUID?

    private var project: CompanionProject? {
        client.snapshot?.projects.first { $0.id == projectID }
    }

    var body: some View {
        if let project {
            if client.isShowingSaved {
                // The Mac is out of reach: queue prompts for when it's back.
                OfflineProjectView(projectID: projectID)
            } else if let sessionID, project.sessions.contains(where: { $0.id == sessionID }) {
                SessionView(projectID: projectID, sessionID: sessionID)
            } else if project.sessions.count == 1, let session = project.sessions.first {
                SessionView(projectID: projectID, sessionID: session.id)
            } else if project.sessions.isEmpty {
                ProjectStartView(project: project)
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ProjectMenu(projectID: projectID) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(project.sessions) { session in
                            NavigationLink(value: SessionRoute(projectID: projectID, sessionID: session.id)) {
                                HStack(spacing: 12) {
                                    ActivityMark(activity: session.activity, size: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title).font(.system(.body, design: .rounded, weight: .semibold)).foregroundStyle(PhoneTheme.ink)
                                        Text(session.actionText ?? session.question ?? session.summary ?? PhoneTheme.label(for: session.activity))
                                            .font(.subheadline).foregroundStyle(PhoneTheme.inkMuted).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(PhoneTheme.inkMuted)
                                }
                                .padding(14)
                                .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
                            }
                            .buttonStyle(.cardPress)
                        }
                    }
                    .padding(16)
                }
                .background(PhoneTheme.canvas)
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ProjectMenu(projectID: projectID) }
            }
        } else if client.snapshot == nil {
            // Nothing from the Mac yet (a cold launch straight into this
            // project, or a new Mac): the project isn't closed, it's unknown.
            LoadingState(text: client.status == .connected ? "Loading your projects" : "Connecting to your Mac")
                .background(PhoneTheme.canvas)
        } else {
            ContentUnavailableView("Project closed", systemImage: "folder",
                                   description: Text("It's no longer in Workbench's sidebar."))
        }
    }
}

struct SessionRoute: Hashable {
    var projectID: UUID
    var sessionID: UUID
}

struct SessionView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(Navigator.self) private var navigator
    let projectID: UUID
    let sessionID: UUID
    @State private var draft: String
    @State private var attachments: [PendingAttachment]
    @State private var problem: String?
    /// The model being switched to, until the Mac reports it. Shared by
    /// the header, which does the switching, and the message box, which
    /// shows the model.
    @State private var switchingModel: ModelChoice?
    /// True once an `@` has been typed here, when the project's files are
    /// asked for so they can be suggested.
    @State private var watchesFiles = false
    /// Counts answers to Claude's questions, for the tap that goes with each.
    @State private var answersSent = 0
    /// The messages as turns, with what you just sent merged in. Grouped
    /// once per change, not once per draw.
    @State private var conversation = Conversation(tracksChanges: true)
    /// Ends the watch when the screen is popped. `onDisappear` fired on a
    /// push too, so coming back from a file read the whole conversation again.
    @State private var lease = SessionLease()
    @FocusState private var composing: Bool
    /// On an iPhone Duo, closed or open and turned sideways, the bar runs
    /// down the side: the header's buttons go there and the header keeps
    /// only the name and status.
    @Environment(\.hasVerticalBar) private var hasVerticalBar
    @Environment(\.toggleSidebar) private var toggleSidebar
    /// What was just sent and when. Dictation that's still running when
    /// you send puts its text back in the field a moment later.
    @State private var lastSent: (text: String, at: Date)?
    /// What the `/model` list asked for, waiting on the switch.
    @State private var modelRequest: ModelRequest?
    /// True while that list shows, opened from the header's model or by
    /// sending `/model`.
    @State private var showsModels = false

    init(projectID: UUID, sessionID: UUID) {
        self.projectID = projectID
        self.sessionID = sessionID
        _draft = State(initialValue: Drafts.load("\(sessionID).text") ?? "")
        #if DEBUG
        // For screenshots of the command suggestions.
        if let seeded = ProcessInfo.processInfo.environment["BENCH_CHAT_DRAFT"] { _draft = State(initialValue: seeded) }
        #endif
        _attachments = State(initialValue: Drafts.load("\(sessionID).attachments") ?? [])
    }

    /// How wide the conversation gets on an iPad, so lines stay readable.
    static let column: CGFloat = 760

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var session: CompanionSession? { project?.sessions.first { $0.id == sessionID } }
    private var messages: [TranscriptMessage]? { client.transcripts[sessionID] }
    /// Claude is on a turn, so its last step is under way.
    private var isWorking: Bool { session.map { [.working, .remoteWorking].contains($0.activity) } ?? false }
    /// Claude is on a turn or waiting on you, so queued messages are still
    /// waiting on something. A queue left behind when Claude quit isn't.
    private var isBusy: Bool { session.map { [.working, .remoteWorking, .waiting].contains($0.activity) } ?? false }

    /// Who this is and what it's doing: across the top, or in the bar's
    /// title row on an iPhone Duo with its bar down the side.
    /// Beside the iPad-style project list (an open iPhone Duo turned
    /// sideways), the bar keeps a row across the top for the list's button,
    /// and the name goes in it. With no list there's no such row, and the
    /// header stays where it is, full width.
    private var headerInBar: Bool { hasVerticalBar && toggleSidebar != nil }

    @ViewBuilder private var header: some View {
        if let project, let session {
            SessionHeader(project: project, session: session, icon: client.icons[project.parentID ?? project.id],
                          buttonsInBar: hasVerticalBar, inTitleRow: headerInBar, request: $modelRequest,
                          switching: $switchingModel,
                          switchModel: { client.reply(sessionID: sessionID, text: $0.command, attachments: []) },
                          setEffort: { client.reply(sessionID: sessionID, text: $0.command, attachments: []) })
        } else {
            // The tab is gone from the Mac (or hasn't been heard of yet,
            // while connecting): keep a way back.
            ClosedSessionHeader(project: project, icon: project.flatMap { client.icons[$0.parentID ?? $0.id] },
                                buttonsInBar: hasVerticalBar, inTitleRow: headerInBar, isLoading: client.snapshot == nil)
        }
    }

    var body: some View {
        conversationView
            .modifier(SessionHaptics(answersSent: answersSent, activity: session?.activity, model: session?.model))
            // The bar lives in the scroll view's safe area, so the scroll
            // view knows where its visible bottom is: the last message
            // lands above the bar, not under it, and the bar's height can
            // change (a growing draft, a permission card) without guessing.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    // One thing above the message box: a question or a
                    // permission first, else the checklist (with the agents
                    // counted on it), else the agents, else a note.
                    if let session, let questions = session.questions {
                        QuestionCard(questions: questions, plan: PlanText.forApproval(questions, in: messages), agentName: session.agentTitle) { answers in
                            answersSent += 1
                            client.answerQuestions(sessionID: sessionID, answers: answers)
                        }
                        .id(questions)
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                        .transition(ChatMotion.card)
                    } else if let session, session.isAllowOrDeny {
                        PermissionCard(session: session, reply: { composing = true }) { allow in
                            client.answer(sessionID: sessionID, allow: allow)
                        }
                        .transition(ChatMotion.card)
                    } else if let session, let items = session.checklist, !items.isEmpty {
                        ChecklistBar(items: items, session: session, agents: session.pinnedAgents)
                            .transition(ChatMotion.card)
                    } else if let session, let agents = session.pinnedAgents {
                        AgentsBar(agents: agents)
                            .transition(ChatMotion.card)
                    } else if let session, session.isCompacting {
                        CompactingBanner()
                            .transition(ChatMotion.card)
                    }
                    // Asked for just now, so it shows alongside whatever else is up.
                    if let question = client.sideQuestions[sessionID] {
                        SideQuestionCard(question: question, maxHeight: 220) { client.dismissSideQuestion(sessionID: sessionID) }
                            .id(question.id)
                            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                            .transition(ChatMotion.card)
                    }
                    if let session { composeBar(session) }
                }
                .frame(maxWidth: Self.column)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background {
                    // Text scrolls under the glass; fade it so the note
                    // above the field stays readable.
                    LinearGradient(colors: [PhoneTheme.canvas.opacity(0), PhoneTheme.canvas], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
                        .ignoresSafeArea(edges: .bottom)
                }
                .animation(ChatMotion.dock, value: session?.isAllowOrDeny)
                .animation(ChatMotion.dock, value: session?.questions)
                .animation(ChatMotion.dock, value: session?.isCompacting)
                .animation(ChatMotion.dock, value: session?.checklist?.isEmpty ?? true)
                .animation(ChatMotion.dock, value: session?.pinnedAgents == nil)
                .animation(ChatMotion.dock, value: client.sideQuestions[sessionID]?.id)
            }
            .background(PhoneTheme.canvas)
            .imageDrop(enabled: session?.canReply ?? false) { attachments += $0 }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !headerInBar { header }
        }
        .toolbar(hasVerticalBar ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if hasVerticalBar {
                // The name and status sit in the bar's own title row, as
                // other screens' titles do.
                if headerInBar { ToolbarItem(placement: .principal) { header } }
                if let project, let session {
                    ToolbarItem(placement: .topBarTrailing) { ChangesButton(project: project, inBar: true) }
                    ToolbarItem(placement: .topBarTrailing) { ProjectMenuButton(projectID: project.id, session: session, inBar: true) }
                }
            }
        }
        // The header draws its own background. The bar's title row needs
        // the bar's, or the conversation shows through the name.
        .toolbarBackground(PhoneTheme.canvas, for: .navigationBar)
        .toolbarBackground(headerInBar ? .visible : .hidden, for: .navigationBar)
        .keepsSwipeBack()
        .task(id: client.status) {
            lease.end = { [client] in client.unwatch(sessionID: sessionID) }
            if client.status == .connected {
                client.watch(sessionID: sessionID)
                client.loadSlashCommands(projectID: projectID)
                #if DEBUG
                // For testing from a script: sends the seeded draft once
                // the conversation is in.
                if ProcessInfo.processInfo.environment["BENCH_CHAT_SEND"] != nil, !draft.isEmpty {
                    try? await Task.sleep(for: .seconds(3))
                    send()
                }
                #endif
            }
        }
        .onChange(of: client.sendProblems[sessionID]) { _, new in
            problem = new
            // It didn't go: take the bubble back and give you your words.
            if new != nil, let unsent = conversation.dropLastSent(), draft.isEmpty { draft = unsent.text }
        }
        .onChange(of: messages, initial: true) { _, new in conversation.update(new) }
        .onChange(of: draft) { _, new in Drafts.save(new.isEmpty ? nil : new, for: "\(sessionID).text") }
        .onChange(of: attachments) { _, new in Drafts.save(new.isEmpty ? nil : new, for: "\(sessionID).attachments") }
        .alert("Couldn't send", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil; client.clearProblem(sessionID: sessionID) } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder
    private var conversationView: some View {
        if !conversation.isLoaded, session == nil, client.snapshot != nil {
            // No transcript came and none will: the Mac doesn't have this tab.
            VStack(spacing: 8) {
                Spacer()
                Text("✻\u{FE0E}").font(.system(size: 34, weight: .semibold)).foregroundStyle(PhoneTheme.inkMuted)
                Text(project == nil ? "This project was closed on the Mac" : "This tab was closed on the Mac")
                    .font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(PhoneTheme.ink)
                    .multilineTextAlignment(.center)
                if project != nil {
                    Text("Its conversation is in Past Sessions.").font(.subheadline).foregroundStyle(PhoneTheme.inkMuted)
                    NavigationLink(value: PastSessionsRoute(projectID: projectID)) { Text("Past Sessions") }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PhoneTheme.accent)
                        .padding(.top, 4)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        } else if !conversation.isLoaded {
            LoadingState(text: "Loading the conversation")
        } else if conversation.turns.isEmpty {
            EmptyStateScaffold(title: "Ready when you are",
                               message: "Tell \(session?.agentTitle ?? "your agent") what to work on. Type `/` to see its commands.") {
                ConversationEmptyIllustration(appeared: $0)
            }
        } else {
            // Equatable, so the Mac's once-a-second snapshot (which redraws
            // this screen for the header and bars) leaves the list alone
            // unless something it shows has changed.
            ConversationList(sessionID: sessionID, conversation: conversation, isWorking: isWorking, isBusy: isBusy,
                             agentStatuses: session?.agentsByCall ?? [:], queueActions: queueActions,
                             earlier: client.earlierPages[sessionID] ?? .none,
                             loadEarlier: { client.requestEarlier(sessionID: sessionID) })
                .equatable()
                // A finished turn lists the files it changed. Tapping one
                // goes to the project's changes, where its diff is.
                .environment(\.turnReview, turnReview)
        }
    }

    /// The message box, apart from the screen's body, which is already as
    /// much as the compiler will type-check.
    private func composeBar(_ session: CompanionSession) -> some View {
        let setMode: ((PermissionMode) -> Void)? = session.permissionMode == nil ? nil
            : { client.setPermissionMode(sessionID: sessionID, mode: $0) }
        let stop: (() -> Void)? = client.canInterrupt ? { client.interrupt(sessionID: sessionID) } : nil
        let commands = (client.slashCommands[projectID] ?? []).filter { !$0.opensInTerminal }
        return ComposeBar(session: session, draft: $draft, attachments: $attachments, focused: $composing,
                          modelRequest: $modelRequest, showsModels: $showsModels,
                          switchingModel: switchingModel, setMode: setMode, files: mentionFiles,
                          commands: commands, stop: stop) { send() }
            .onChange(of: draft) { old, text in
                clearDictationEcho(text, was: old)
                continueList(text, was: old)
            }
            .modifier(MentionFiles(projectID: projectID, draft: draft, isWatching: $watchesFiles))
    }

    /// The project's files, once an `@` has asked for them.
    private var mentionFiles: [String] {
        watchesFiles ? (client.filePaths[projectID] ?? []) : []
    }

    private var turnReview: TurnReviewActions? {
        guard let project, project.isGit != false, !client.isShowingSaved else { return nil }
        let navigator = navigator, projectID = projectID
        return TurnReviewActions(root: project.path) { _, _ in
            navigator.push(ChangesRoute(projectID: projectID))
        } reviewAll: { _ in
            navigator.push(ChangesRoute(projectID: projectID))
        }
    }

    private var queueActions: QueueActions? {
        guard client.canEditQueue, session?.activity == .working else { return nil }
        let queued = conversation.turns.filter(\.isQueued)
        guard !queued.isEmpty else { return nil }
        let id = sessionID
        return .forQueue(queued, takeBack: { client.takeBackQueue(sessionID: id, queued: $0, keep: $1) },
                         sendNow: client.canSendNow ? { client.sendQueueNow(sessionID: id) } : nil) { text in
            draft = draft.isEmpty ? text : draft + "\n" + text
            composing = true
        }
    }

    private func send() {
        // A `!` with no command after it isn't a message.
        let text = ShellDraft.isEmptyCommand(draft) ? "" : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // Claude Code answers /btw in a pop-up only its terminal shows, so
        // the Mac asks it separately, and pictures stay for the next message.
        if let question = SideQuestion.question(in: text) {
            if !client.canAskSideQuestions {
                problem = "Side questions need a newer Workbench on your Mac."
            } else if question.isEmpty {
                problem = "Type a question after /btw."
            } else {
                client.askSideQuestion(sessionID: sessionID, question: question)
                draft = ""
                composing = false
            }
            return
        }
        conversation.send(text: text, images: attachments.map(\.companion.data), queued: isBusy)
        client.reply(sessionID: sessionID, text: text, attachments: attachments.map(\.companion))
        Task {
            try? await Task.sleep(for: .seconds(31))
            // Still not in the transcript, and the line is down: it didn't
            // go. Say so, which also gives you your words back.
            if client.status != .connected, conversation.hasPendingSent {
                client.noteSendProblem(sessionID: sessionID, "The Mac went away before that was sent.")
            } else {
                conversation.settle()
            }
        }
        lastSent = (text, .now)
        draft = ""
        attachments = []
        // Usually it's one message, then reading the reply: give the
        // conversation the whole screen.
        composing = false
    }

    /// A new line typed at the end of a list item brings the next item's
    /// marker with it; one on an empty item ends the list. Only at the
    /// end, where the cursor goes when the text is set from here.
    private func continueList(_ text: String, was old: String) {
        guard text.hasSuffix("\n"), text.dropLast() == old else { return }
        let edit = ListShorthand.newline(in: old, replacing: old.endIndex..<old.endIndex)
        let continued = ListShorthand.apply(edit, to: old).text
        if continued != text { draft = continued }
    }

    /// Clears the field again when dictation puts back what you just sent.
    /// It lands all at once in the empty field, unlike typing.
    private func clearDictationEcho(_ text: String, was old: String) {
        guard let sent = lastSent, Date.now.timeIntervalSince(sent.at) < 3, old.isEmpty else { return }
        let echo = Self.letters(text), original = Self.letters(sent.text)
        guard echo.count >= 2, echo.count * 2 >= original.count,
              original.hasPrefix(echo) || echo.hasPrefix(original) else { return }
        lastSent = nil
        DispatchQueue.main.async { draft = "" }
    }

    /// Text without spacing, punctuation or case, since dictation's final
    /// pass can tidy those.
    private static func letters(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}

/// The messages, newest at the bottom. Takes only what it shows, and
/// compares equal when none of it changed, so the screen around it can
/// redraw as often as it likes.
private struct ConversationList: View, Equatable {
    let sessionID: UUID
    let conversation: Conversation
    let isWorking: Bool
    let isBusy: Bool
    let agentStatuses: [String: AgentStatus]
    let queueActions: QueueActions?
    /// Whether the conversation goes back further than what's here.
    let earlier: CompanionClient.EarlierPages
    let loadEarlier: () -> Void

    static func == (a: ConversationList, b: ConversationList) -> Bool {
        a.conversation === b.conversation && a.isWorking == b.isWorking && a.isBusy == b.isBusy
            && a.agentStatuses == b.agentStatuses && a.queueActions == b.queueActions && a.earlier == b.earlier
    }

    var body: some View {
        let all = conversation.turns
        // Queued messages last, and only while Claude is busy.
        let shown = all.filter { !$0.isQueued }
        let turns = isBusy ? all : shown
        // The newest turns in a plain stack, the history above them drawn
        // a chunk at a time as you scroll near it (see ChatHistory): a lazy
        // stack guesses the heights of rows it hasn't drawn, and the bottom
        // of a guess can be over nothing at all.
        let recentStart = ChatTail.start(count: turns.count)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if earlier != .none {
                    EarlierButton(isLoading: earlier == .loading, action: loadEarlier)
                }
                ChatHistory(turns[..<recentStart], spacing: 14) { row($0, lastShown: shown.last?.id) }
                ForEach(turns[recentStart...]) { row($0, lastShown: shown.last?.id) }
            }
            .environment(\.queueActions, queueActions)
            // Edits fold to their counts until tapped, to keep
            // the conversation readable on a phone.
            .environment(\.collapsesDiffs, true)
            .animatesArrivals(turns.map(\.id))
            .environment(\.agentStatuses, agentStatuses)
            .frame(maxWidth: SessionView.column)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .sticksToBottom(sentKey: turns.lastSentID)
        // Timing notes go to the system log under the session.
        .environment(\.chatTimingID, sessionID)
    }

    @Environment(\.turnReview) private var turnReview

    /// A turn's row, with the files its turn changed under it when it's
    /// the last row of a finished turn that changed some.
    private func row(_ turn: TranscriptTurn, lastShown: String?) -> some View {
        let changes = turnReview == nil ? nil : conversation.changes[turn.id].flatMap { $0.isLatest && isBusy ? nil : $0 }
        return VStack(alignment: .leading, spacing: 14) {
            TranscriptTurnView(turn: turn, isLive: isWorking && turn.id == lastShown)
                .equatable()
            if let changes {
                TurnChangesCard(changes: changes)
                    .transition(.opacity)
            }
        }
        .id(turn.id)
        .transition(ChatMotion.row(for: turn))
    }
}

/// "Earlier messages", at the top of a conversation that goes back
/// further than what's loaded. A spinner while the page is on its way.
private struct EarlierButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up").font(.caption.weight(.semibold))
                }
                Text(isLoading ? "Loading earlier messages" : "Earlier messages")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PhoneTheme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(PhoneTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(PhoneTheme.hairline))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// A spinner, with a line under it if there's something to say, filling
/// the screen while something loads. It waits a moment before showing:
/// most things arrive from the Mac in a fraction of a second, and a
/// spinner that flashes for that long reads as a flicker.
struct LoadingState: View {
    var text: String?
    @State private var shown = false

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            ActivityMark(activity: .working, size: 22)
            if let text {
                Text(text).font(.footnote).foregroundStyle(PhoneTheme.inkMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { shown = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text ?? "Loading")
    }
}

// MARK: - Header

/// Beside the ⋯ menu: one tap to a project's changes on a phone, or the
/// inspector's toggle on an iPad that has one, as on the Mac.
struct ChangesButton: View {
    @Environment(\.inspector) private var inspector
    @Environment(CompanionClient.self) private var client
    let project: CompanionProject
    /// In the system's bar, which draws the button itself from a symbol
    /// and a title. It only puts those in a bar down the side.
    var inBar = false

    var body: some View {
        if let inspector {
            if inBar {
                Button(inspector.isShown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right", action: inspector.toggle)
            } else {
                Button(action: inspector.toggle) {
                    circle("sidebar.right", on: inspector.isShown)
                }
                .accessibilityLabel(inspector.isShown ? "Hide Inspector" : "Show Inspector")
            }
        } else if project.isGit != false, !client.isHeadless {
            NavigationLink(value: ChangesRoute(projectID: project.id)) {
                if inBar {
                    Label("Changes", systemImage: "plus.forwardslash.minus")
                } else {
                    circle("plus.forwardslash.minus", on: false)
                }
            }
            .accessibilityLabel("Changes")
        }
    }

    private func circle(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(on ? PhoneTheme.accent : PhoneTheme.ink)
            .frame(width: 36, height: 36)
            .glassEffect(.regular.interactive(), in: .circle)
            .touchArea(horizontal: 4, vertical: 4)
    }
}

/// Back, or the iPad's sidebar toggle where there's nothing to go back to.
/// The same button on every header this screen draws.
private struct SessionBackButton: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.toggleSidebar) private var toggleSidebar

    var body: some View {
        Button { if let toggleSidebar { toggleSidebar() } else { dismiss() } } label: {
            Image(systemName: toggleSidebar == nil ? "chevron.left" : "sidebar.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(PhoneTheme.ink)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
                .touchArea(horizontal: 4, vertical: 4)
        }
        .accessibilityLabel(toggleSidebar == nil ? "Back" : "Show or Hide Projects")
    }
}

private extension View {
    /// The header's own background and rule. In the system's bar it has
    /// neither: the bar is the background.
    @ViewBuilder func headerChrome(inBar: Bool, leading: CGFloat, rule: Color) -> some View {
        if inBar {
            self
        } else {
            padding(.leading, leading)
                .padding(.trailing, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .background(PhoneTheme.canvas.opacity(0.96))
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(rule).frame(height: 1)
                }
        }
    }
}

/// The header for a session the Mac no longer has: just the way back and
/// a word on why. While the phone is still connecting it says so instead,
/// since the tab may well turn up with the first snapshot.
private struct ClosedSessionHeader: View {
    let project: CompanionProject?
    let icon: Data?
    var buttonsInBar = false
    var inTitleRow = false
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !buttonsInBar { SessionBackButton() }
            if let project {
                CompanionProjectIcon(project: project, icon: icon, size: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(project.map { $0.isWorktree ? ($0.branch ?? $0.name) : $0.name } ?? "Session")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(PhoneTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if isLoading {
                        ActivityMark(activity: .working, size: 11)
                    } else {
                        Image(systemName: "xmark.square")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PhoneTheme.inkMuted)
                    }
                    Text(isLoading ? "Connecting to your Mac" : "Closed on the Mac")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
        }
        .headerChrome(inBar: inTitleRow, leading: buttonsInBar ? 16 : 12, rule: PhoneTheme.inkMuted.opacity(0.15))
    }
}

/// The instrument panel: who this is, what it's doing, how full it is.
private struct SessionHeader: View {
    let project: CompanionProject
    let session: CompanionSession
    let icon: Data?
    /// The system's bar has Back, Changes and the menu, down the side.
    var buttonsInBar = false
    /// The header itself is in the bar's title row, which is its background.
    var inTitleRow = false
    /// Set by the `/model` list to switch, after asking first if the
    /// conversation is long.
    @Binding var request: ModelRequest?
    /// The model being switched to. The message box shows it.
    @Binding var switching: ModelChoice?
    let switchModel: (ModelChoice) -> Void
    let setEffort: (EffortLevel) -> Void

    private var tint: Color { PhoneTheme.color(for: session.activity) ?? PhoneTheme.inkMuted }

    var body: some View {
        header
            .modelSwitching($request, switching: $switching, model: session.model,
                            switchModel: switchModel, setEffort: setEffort)
    }

    /// Who this is on one row, what it's doing on the next. The status
    /// has the row to itself: sharing one with the name, the model and the
    /// buttons, it was cut down to a word or two.
    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if !buttonsInBar { SessionBackButton() }
                CompanionProjectIcon(project: project, icon: icon, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.isWorktree ? (project.branch ?? project.name) : project.name)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(PhoneTheme.ink)
                        .lineLimit(1)
                    if inTitleRow {
                        // No second row in the bar's title row: the status
                        // stays under the name there.
                        status
                    } else if let place {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption2.weight(.semibold))
                            Text(place)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(PhoneTheme.inkMuted)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if !buttonsInBar {
                    ChangesButton(project: project)
                    ProjectMenuButton(projectID: project.id, session: session)
                }
            }
            if !inTitleRow {
                status
                    .padding(.leading, buttonsInBar ? 0 : 4)
            }
        }
        .headerChrome(inBar: inTitleRow, leading: buttonsInBar ? 16 : 12, rule: tint.opacity(session.activity == .idle ? 0.15 : 0.45))
        .animation(.easeInOut(duration: 0.3), value: session.activity)
    }

    /// The mark, what's going on in words, and how full the context is.
    private var status: some View {
        HStack(spacing: 6) {
            ActivityMark(activity: session.activity, size: 11)
            Text(statusText)
                .font(inTitleRow ? .caption.weight(.medium) : .footnote.weight(.medium))
                .foregroundStyle(session.activity == .idle ? PhoneTheme.inkMuted : PhoneTheme.ink.opacity(0.85))
                .lineLimit(1)
                .contentTransition(.opacity)
            if !inTitleRow { Spacer(minLength: 6) }
            // Kept whole: the status beside it gives way first.
            if let tokens = session.contextTokens, let window = session.contextWindow {
                if !inTitleRow {
                    Text("\(shortTokens(tokens)) of \(shortTokens(window))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                ContextRing(tokens: tokens, window: window)
                    .padding(.leading, inTitleRow ? 2 : 0)
            }
        }
    }

    /// Where the session is working: its branch, or for a worktree (whose
    /// name is its branch) the repo and its pull request.
    private var place: String? {
        if project.isWorktree {
            return [project.repoName, project.pullRequest.map { "#\($0.number)" }].compactMap { $0 }.joined(separator: " · ")
        }
        return project.branch
    }

    private var statusText: String {
        switch session.activity {
        case .working: session.actionText ?? "Working"
        case .remoteWorking: (session.actionText ?? "Working") + (session.remoteHost.map { " on \($0)" } ?? "")
        case .waiting: session.question ?? "Waiting for you"
        case .done: "Finished" + (session.stoppedAt.map { " " + $0.formatted(.relative(presentation: .named)) } ?? "")
        case .attention: "Needs attention"
        case .idle: "Idle"
        }
    }
}

/// Claude's subagents, pinned above the message box while any are running
/// or finished during this turn. Folded, it's one line: how many are
/// working and what one of them is doing. Tap to see each.
struct AgentsBar: View {
    let agents: [AgentStatus]
    @AppStorage("agentsExpanded") private var expanded = false

    var body: some View {
        let running = agents.filter(\.isRunning)
        VStack(spacing: 0) {
            if expanded {
                AgentStatusRows(agents: agents, textSize: 15, spacing: 10, usesPalette: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    // Just a fade: the bar growing is what reveals them.
                    .transition(.opacity)
                Divider().overlay(PhoneTheme.hairline)
            }
            Button {
                withAnimation(ChatMotion.dock) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if running.isEmpty {
                        Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(StepColors.added)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(running.isEmpty ? (agents.count == 1 ? "Agent done" : "\(agents.count) agents done")
                         : running.count == 1 ? "1 agent" : "\(running.count) agents")
                        .fontWeight(.semibold)
                        .foregroundStyle(PhoneTheme.ink)
                        .fixedSize()
                    if let action = running.first?.action {
                        Text(action)
                            .foregroundStyle(PhoneTheme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(running.isEmpty ? "Agents done" : "\(running.count) agents working")
            .accessibilityHint(expanded ? "Hides the agents" : "Shows each agent")
        }
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .animation(.snappy(duration: 0.25), value: agents)
    }
}

/// The taps a session gives while you watch it: an answer sent, the turn
/// ending, the model changing. Apart from the screen's body, which is
/// already as much as the compiler will type-check.
private struct SessionHaptics: ViewModifier {
    let answersSent: Int
    let activity: ActivityKind?
    let model: String?

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.success, trigger: answersSent)
            .sensoryFeedback(.success, trigger: activity) { (old: ActivityKind?, new: ActivityKind?) -> Bool in
                guard let old, let new else { return false }
                return new == ActivityKind.done && (old == ActivityKind.working || old == ActivityKind.remoteWorking)
            }
            .sensoryFeedback(.selection, trigger: model) { (old: String?, new: String?) -> Bool in
                old != nil && new != nil
            }
    }
}

/// Asks the Mac for the project's files the first time an `@` is typed,
/// so they can be suggested, and stops when the message box goes away.
private struct MentionFiles: ViewModifier {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    let draft: String
    @Binding var isWatching: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: draft, initial: true) { _, text in
                guard !isWatching, client.canBrowseFiles, FileMention.token(in: text) != nil else { return }
                isWatching = true
                client.watchFiles(projectID: projectID)
            }
            .onDisappear {
                guard isWatching else { return }
                isWatching = false
                client.unwatchFiles(projectID: projectID)
            }
    }
}

extension FileMention {
    /// The `@` word at the end of what's typed. The phone's field doesn't
    /// say where its cursor is, so it's taken to be at the end, where you
    /// are while typing.
    static func token(in text: String) -> ComposerToken? {
        guard let token = ComposerToken.at(text.utf16.count, in: text), token.kind == .file else { return nil }
        return token
    }
}

/// Files and folders that finish the `@` word being typed. Tap one to
/// put it in the message.
private struct FileSuggestions: View {
    let mentions: [FileMention]
    let pick: (FileMention) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mentions.enumerated()), id: \.element.id) { index, mention in
                if index > 0 { Divider().padding(.leading, 14) }
                Button { pick(mention) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: mention.isDirectory ? "folder" : "doc")
                            .font(.footnote)
                            .foregroundStyle(PhoneTheme.inkMuted)
                            .frame(width: 18)
                        Text(mention.isDirectory ? mention.name + "/" : mention.name)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .foregroundStyle(PhoneTheme.ink)
                            .lineLimit(1)
                        if !mention.folder.isEmpty {
                            Text(mention.folder)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(PhoneTheme.inkMuted)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mention.path)
                .accessibilityHint(mention.isDirectory ? "Puts this folder in the message" : "Puts this file in the message")
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private extension View {
    /// A small capsule in the message box: the model, the permission mode.
    /// `shrinks` lets its words be cut short when there's no room for them.
    func composerPill(fill: Color, stroke: Color? = nil, shrinks: Bool = false) -> some View {
        font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: !shrinks, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(fill, in: Capsule())
            .overlay { if let stroke { Capsule().strokeBorder(stroke, lineWidth: 0.5) } }
            .touchArea(horizontal: 2, vertical: 10)
    }
}

/// How much the agent does before asking, as a pill that opens the list
/// of modes. Shows the one you picked at once: the Mac reports the change
/// a moment later, when Claude Code's screen says so.
private struct ModePill: View {
    let mode: PermissionMode
    let set: (PermissionMode) -> Void
    /// Only its symbol, where there's no room for its name.
    var compact = false
    @State private var switching: PermissionMode?

    private var shown: PermissionMode { switching ?? mode }

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
            HStack(spacing: 4) {
                Image(systemName: shown.symbol)
                    .imageScale(.small)
                if !compact {
                    Text(shown.name)
                        .contentTransition(.opacity)
                }
                if switching != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
            }
            .foregroundStyle(shown == .bypass ? PhoneTheme.error : PhoneTheme.inkMuted)
            .composerPill(fill: shown == .bypass ? PhoneTheme.error.opacity(0.14) : PhoneTheme.ink.opacity(0.07))
            .animation(.easeInOut(duration: 0.15), value: shown)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: shown)
        .onChange(of: mode) { switching = nil }
        .accessibilityLabel("Permission mode, \(shown.name)")
        .accessibilityHint("Chooses how much the agent does before asking")
    }

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
}

/// Claude's checklist, pinned above the message box like the terminal's.
/// Folded, it's one line: how long the turn has run, the current step, and
/// steps done over a progress bar. Tap to open the whole list above it.
struct ChecklistBar: View {
    let items: [ChecklistItem]
    let session: CompanionSession
    /// Subagents at work, counted on the folded line since the bar takes
    /// the agents bar's place.
    var agents: [AgentStatus]? = nil
    @AppStorage("checklistExpanded") private var expanded = false

    private var tint: Color { PhoneTheme.color(for: session.activity) ?? PhoneTheme.hairline }

    var body: some View {
        // A soft tick as each step is checked off.
        card.sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: items.doneCount) { old, new in new > old }
    }

    private var card: some View {
        VStack(spacing: 0) {
            if expanded {
                ChecklistRows(items: items, textSize: 15, spacing: 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    // Just a fade: the bar growing is what reveals them.
                    .transition(.opacity)
                Divider().overlay(PhoneTheme.hairline)
            }
            Button {
                withAnimation(ChatMotion.dock) { expanded.toggle() }
            } label: {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ActivityMark(activity: session.activity, size: 13)
                        if let since = session.since {
                            ActiveTimer(since: since, activity: session.activity)
                        }
                        Text(items.current?.label ?? "Every step done")
                            .foregroundStyle(PhoneTheme.ink.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let running = agents?.filter(\.isRunning).count, running > 0 {
                            Label("\(running)", systemImage: "person.2")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PhoneTheme.inkMuted)
                                .accessibilityLabel("\(running) agents working")
                        }
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PhoneTheme.inkMuted)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.subheadline)
                    // The same segments as the project list and the Mac, with
                    // the count at the end.
                    ChecklistStepsBar(items: items, activity: session.activity)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Checklist, \(items.doneCount) of \(items.count) steps done")
            .accessibilityHint(expanded ? "Hides the list" : "Shows every step")
        }
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(tint.opacity(0.45)))
        .clipShape(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
    }
}

/// The ⋯ menu as a glass button, for the custom header.
private struct ProjectMenuButton: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    let session: CompanionSession
    var inBar = false
    @State private var confirming: QuickCommand?
    @State private var pendingAgentAction: AgentAction?
    /// BENCH_SHOW_ARTIFACTS=1 opens the list, for screenshots.
    @State private var showsArtifacts = ProcessInfo.processInfo.environment["BENCH_SHOW_ARTIFACTS"] != nil && Self.isDebug
    private static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var artifacts: [ArtifactLink]? { client.artifacts[projectID] }

    /// "main · #127", for the menu's git section.
    private var branchLine: String? {
        guard let project else { return nil }
        var parts: [String] = []
        if let branch = project.branch { parts.append(branch) }
        if let pr = project.pullRequest { parts.append("#\(pr.number)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Only what the menu shows. The session changes every few seconds
    /// while Claude works, and rebuilding an open menu snaps its scroll
    /// back to the top, so the menu redraws only when this changes.
    private var menuModel: ProjectMenuModel {
        ProjectMenuModel(
            canRunCommand: session.canRunCommand,
            agentName: session.agentTitle,
            quickCommands: session.agentCatalog.quickCommands,
            canListArtifacts: client.canListArtifacts,
            artifactCount: artifacts?.count,
            branchLine: branchLine,
            shortcuts: client.canRunShortcuts ? (project?.shortcuts ?? []) : [],
            canManageAgents: client.canManageAgents,
            isRemovableAgent: project?.isWorktree == true && project?.isExternalWorktree != true,
            hasCleanup: project?.cleanup != nil,
            showsChanges: !client.isHeadless
        )
    }

    var body: some View {
        ProjectMenuList(projectID: projectID, model: menuModel, inBar: inBar, perform: perform)
            .equatable()
            .confirmationDialog(confirming?.confirmation?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible) {
                if let command = confirming, let confirmation = command.confirmation {
                    Button(confirmation.button, role: .destructive) { run(command) }
                }
            } message: {
                Text(confirming?.confirmation?.message ?? "")
            }
            .agentActionConfirmation($pendingAgentAction)
            .sheet(isPresented: $showsArtifacts) {
                ArtifactsSheet(links: artifacts)
                    .presentationDetents([.medium, .large])
            }
            // Keeps the count current; new pages turn up as Claude publishes them.
            .task(id: "\(projectID)-\(client.status == .connected)") {
                while !Task.isCancelled {
                    client.loadArtifacts(projectID: projectID)
                    try? await Task.sleep(for: .seconds(showsArtifacts ? 5 : 20))
                }
            }
    }

    private func run(_ command: QuickCommand) {
        client.reply(sessionID: session.id, text: command.command, attachments: [])
    }

    /// Looks the project and session up fresh, since the menu keeps the
    /// closure from whenever it last redrew.
    private func perform(_ request: ProjectMenuRequest) {
        let project = client.snapshot?.projects.first { $0.id == projectID }
        switch request {
        case .command(let command):
            if command.confirmation != nil { confirming = command } else { run(command) }
        case .artifacts:
            showsArtifacts = true
        case .runShortcut(let id):
            client.runShortcut(projectID: projectID, shortcutID: id)
        case .stopShortcut(let id):
            client.stopShortcut(projectID: projectID, shortcutID: id)
        case .newTab:
            client.newClaudeTab(projectID: projectID, prompt: nil)
        case .closeTab:
            let current = project?.sessions.first { $0.id == session.id } ?? session
            pendingAgentAction = .closeSession(projectID: projectID, session: current)
        case .cleanUp:
            if let project { pendingAgentAction = .cleanUp(project) }
        case .discard:
            if let project { pendingAgentAction = .discard(project) }
        }
    }
}

private struct ProjectMenuModel: Equatable {
    var canRunCommand: Bool
    /// What to call the session's agent, and its quick commands.
    var agentName: String
    var quickCommands: [QuickCommand]
    var canListArtifacts: Bool
    var artifactCount: Int?
    var branchLine: String?
    var shortcuts: [CompanionShortcut]
    var canManageAgents: Bool
    var isRemovableAgent: Bool
    var hasCleanup: Bool
    /// False for a server, which doesn't send changes yet.
    var showsChanges = true
}

private enum ProjectMenuRequest {
    case command(QuickCommand)
    case artifacts
    case runShortcut(String)
    case stopShortcut(String)
    case newTab
    case closeTab
    case cleanUp
    case discard
}

/// The ⋯ menu itself. It reads nothing from the client, so it redraws
/// only when its model does.
private struct ProjectMenuList: View, Equatable {
    let projectID: UUID
    let model: ProjectMenuModel
    var inBar = false
    let perform: (ProjectMenuRequest) -> Void
    /// On an iPad with the inspector, Changes and Artifacts live there.
    @Environment(\.inspector) private var inspector

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectID == rhs.projectID && lhs.model == rhs.model && lhs.inBar == rhs.inBar
    }

    var body: some View {
        Menu {
            Section(model.canRunCommand ? model.agentName : "\(model.agentName) (once it finishes)") {
                ForEach(model.quickCommands) { command in
                    Button(command.title, systemImage: command.symbol) { perform(.command(command)) }
                        .disabled(!model.canRunCommand)
                }
            }
            if model.canListArtifacts, inspector == nil {
                Button { perform(.artifacts) } label: {
                    Label("Artifacts", systemImage: "doc.richtext")
                    if let count = model.artifactCount, count > 0 { Text(count == 1 ? "1 page" : "\(count) pages") }
                }
            }
            Section(model.branchLine ?? "") {
                if inspector == nil, model.showsChanges {
                    NavigationLink(value: ChangesRoute(projectID: projectID)) {
                        Label("Changes", systemImage: "plus.forwardslash.minus")
                    }
                }
                NavigationLink(value: PastSessionsRoute(projectID: projectID)) {
                    Label("Past Sessions", systemImage: "clock.arrow.circlepath")
                }
            }
            if !model.shortcuts.isEmpty {
                Section("Shortcuts on Your Mac") {
                    ForEach(model.shortcuts) { shortcut in
                        if shortcut.isRunning {
                            Button(role: .destructive) { perform(.stopShortcut(shortcut.id)) } label: {
                                Label("Stop \(shortcut.name)", systemImage: "stop.fill")
                                Text(shortcut.ports.isEmpty ? "Running" : "Running on port " + shortcut.ports.map { String($0) }.joined(separator: ", "))
                            }
                        } else {
                            Button(shortcut.name, systemImage: shortcut.symbol) { perform(.runShortcut(shortcut.id)) }
                        }
                    }
                }
            }
            Divider()
            Button("New Agent Tab", systemImage: "plus.square") { perform(.newTab) }
            NavigationLink(value: NewAgentRoute(projectID: projectID)) {
                Label("New Agent on a Branch…", systemImage: "arrow.triangle.branch")
            }
            if model.canManageAgents {
                Divider()
                Button("Close Tab", systemImage: "xmark.square", role: .destructive) { perform(.closeTab) }
                if model.isRemovableAgent {
                    if model.hasCleanup {
                        Button("Clean Up", systemImage: "checkmark.circle") { perform(.cleanUp) }
                    }
                    Button("Discard Agent", systemImage: "trash", role: .destructive) { perform(.discard) }
                }
            }
        } label: {
            if inBar {
                Label("More", systemImage: "ellipsis")
            } else {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PhoneTheme.ink)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .touchArea(horizontal: 4, vertical: 4)
            }
        }
    }
}

/// How full the context is: a small ring that fills clockwise, warming up
/// to orange and then red as it nears the limit. Matches the Mac's message
/// box. VoiceOver reads the numbers.
private struct ContextRing: View {
    let tokens: Int
    let window: Int
    /// Grows with the status text beside it.
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12

    private var fraction: Double { min(1, Double(tokens) / Double(max(1, window))) }
    private var color: Color { fraction >= 0.85 ? PhoneTheme.error : fraction >= 0.7 ? PhoneTheme.waiting : PhoneTheme.inkMuted }

    var body: some View {
        let line = max(2, size * 0.2)
        ZStack {
            Circle()
                .stroke(PhoneTheme.inkMuted.opacity(0.25), lineWidth: line)
            Circle()
                // A sliver even when nearly empty, so the ring reads as a meter.
                .trim(from: 0, to: max(0.03, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.3), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full, \(shortTokens(tokens)) of \(shortTokens(window)) tokens")
    }
}

// MARK: - Bottom

/// Claude is asking to run a tool. Return on the Mac means Allow, Escape
/// means Deny; these do the same.
private struct PermissionCard: View {
    let session: CompanionSession
    /// Puts the cursor in the message box, to say something else instead.
    var reply: (() -> Void)?
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(PhoneTheme.waiting)
                Text(session.permissionTitle)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(PhoneTheme.ink)
                Spacer(minLength: 6)
                if let since = session.since {
                    ActiveTimer(since: since, activity: session.activity)
                        .font(.footnote)
                }
            }
            if let command = session.command, !command.isEmpty {
                CommandBlock(command: command)
            } else if let action = session.action {
                // An older Mac only sends the start of the first line.
                Text(action).font(.system(.footnote, design: .monospaced)).foregroundStyle(PhoneTheme.inkMuted).lineLimit(3)
            }
            PermissionButtons(session: session, answer: answer)
            if let reply, session.canReply {
                Button("Reply instead", action: reply)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .touchArea(vertical: 8)
                    .buttonStyle(.plain)
                    .accessibilityHint("Puts the cursor in the message box")
            }
        }
        .padding(14)
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.waiting.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

private struct ComposeBar: View {
    let session: CompanionSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var draft: String
    @Binding var attachments: [PendingAttachment]
    var focused: FocusState<Bool>.Binding
    /// Set to switch models or effort, from the list `/model` opens.
    @Binding var modelRequest: ModelRequest?
    /// True while the list of models `/model` opens is showing.
    @Binding var showsModels: Bool
    /// The model being switched to, until the Mac reports it.
    var switchingModel: ModelChoice?
    /// Switches the permission mode. Nil when the session reports none.
    var setMode: ((PermissionMode) -> Void)?
    /// The project's files, suggested after an `@`. Empty until one is typed.
    var files: [String] = []
    /// The files and folders `@` can name, worked out once per listing.
    @State private var mentionList: [FileMention] = []
    /// Slash commands to suggest while you type one.
    var commands: [SlashCommand] = []
    /// Stops Claude, when the Mac can.
    let stop: (() -> Void)?
    let send: () -> Void
    /// The effort level shown in the list, and whether you changed it.
    @State private var pickerEffort: EffortLevel?
    @State private var effortChanged = false
    /// Counts sends and stops, for the tap that goes with each.
    @State private var sends = 0
    @State private var stops = 0

    var body: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }
            if let note {
                HStack(spacing: 6) {
                    if session.activity == .working { ActivityMark(activity: .working, size: 11) }
                    Text(note)
                    Spacer(minLength: 8)
                    // With nothing typed the send button is Stop (below).
                    // With a draft it's Send again, so Stop comes up here.
                    if let stop, session.activity == .working, !showsStop {
                        Button { stops += 1; stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PhoneTheme.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.interactive(), in: .capsule)
                                .touchArea(horizontal: 4, vertical: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Interrupts \(session.agentTitle), like pressing Escape in its terminal")
                    }
                }
                .font(.caption)
                .foregroundStyle(PhoneTheme.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .transition(.opacity)
            }
            if let suggestion = session.suggestion, session.canReply, draft.isEmpty {
                // Claude Code's guess at what you'll say next: tap to use it.
                Button {
                    draft = suggestion
                    focused.wrappedValue = true
                } label: {
                    Label(suggestion, systemImage: "arrow.turn.down.right")
                        .font(.subheadline)
                        .foregroundStyle(PhoneTheme.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint("Puts \(session.agentTitle)'s suggested message in the message box")
                .glassList(from: .bottomLeading)
            }
            if isShellCommand {
                // As in Claude Code's own prompt: `! make test` runs in the
                // shell on the Mac, and Claude sees what it printed.
                Label("Runs in the shell on the Mac. \(session.agentTitle) sees what it prints.", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(shellTint)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isSideQuestion {
                Label("\(session.agentTitle) answers on the side. It isn't added to the conversation.", systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(PhoneTheme.accent)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsModels {
                ModelPicker(catalog: session.agentCatalog, agentName: session.agentTitle, current: session.model, canSwitch: session.canRunCommand, effort: pickerEffort) { choice in
                    showsModels = false
                    guard !choice.matches(session.model) else { return }
                    // A new model brings its own effort level, so one you
                    // just picked goes in again after the switch.
                    modelRequest = ModelRequest(model: choice, effort: effortChanged ? pickerEffort : nil)
                } pickEffort: { level in
                    pickerEffort = level
                    effortChanged = true
                    modelRequest = ModelRequest(effort: level)
                } close: {
                    showsModels = false
                }
                .glassList()
            } else if session.canReply, let matches = SlashCommand.matches(for: draft, in: commands, limit: 5), !matches.isEmpty {
                CommandSuggestions(commands: matches) { command in
                    if command.name == "model" {
                        openModels()
                        return
                    }
                    draft = command.completion
                    focused.wrappedValue = true
                }
                .glassList()
            } else if session.canReply, let token = mentionToken,
                      case let matches = FileMention.matches(query: token.query, in: mentionList, limit: 5), !matches.isEmpty {
                FileSuggestions(mentions: matches) { mention in
                    draft.replaceSubrange(token.range, with: mention.insertion)
                    focused.wrappedValue = true
                }
                .glassList()
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    AttachmentControls(attachments: $attachments)
                        .disabled(!session.canReply)
                    VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 8) {
                        if isShellCommand {
                            // Stands for the `!` you typed, so there's no
                            // space to think about after it. Tap it to go
                            // back to a message, keeping what you typed.
                            Button {
                                draft = ShellDraft.leaving(draft)
                            } label: {
                                Text("!")
                                    .font(.body.monospaced().weight(.bold))
                                    .foregroundStyle(shellTint)
                                    .padding(.horizontal, 9)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(shellTint.opacity(0.2)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Shell command")
                            .accessibilityHint("Goes back to a message for \(session.agentTitle), keeping what you typed")
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        } else if isSideQuestion {
                            // Stands for the `/btw` you typed. Tap it to go
                            // back to a message, keeping what you typed.
                            Button {
                                draft = ComposerDraft.leaving(draft)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "bubble.left.and.text.bubble.right")
                                        .font(.footnote.weight(.semibold))
                                    Text("btw")
                                        .font(.body.weight(.semibold))
                                }
                                .foregroundStyle(PhoneTheme.accent)
                                .padding(.horizontal, 9)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PhoneTheme.accent.opacity(0.18)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Side question")
                            .accessibilityHint("Goes back to a message for \(session.agentTitle), keeping what you typed")
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                        TextField(isShellCommand ? "Command to run" : isSideQuestion ? "Ask a side question" : !session.canReply ? "Can't send right now" : session.activity == .working ? "Queue a message for \(session.agentTitle)" : "Message \(session.agentTitle)",
                                  text: $field, axis: .vertical)
                            // An iPad has room for a pasted paragraph or two;
                            // an iPhone keeps it short, above the keyboard.
                            .lineLimit(1...(horizontalSizeClass == .regular ? 14 : 6))
                            .textFieldStyle(.plain)
                            .font(isShellCommand ? .body.monospaced() : .body)
                            .foregroundStyle(PhoneTheme.ink)
                            .tint(isShellCommand ? shellTint : nil)
                            // A command is typed as it is: no capital
                            // letter to start it, no corrected words.
                            .textInputAutocapitalization(isShellCommand ? .never : .sentences)
                            .autocorrectionDisabled(isShellCommand)
                            .focused(focused)
                            .disabled(!session.canReply)
                            // With a hardware keyboard (an iPad's, usually),
                            // Return sends and Shift-Return starts a new line,
                            // as on the Mac. The on-screen keyboard is unchanged.
                            .onKeyPress(.return, phases: .down) { press in
                                guard !press.modifiers.contains(.shift), !press.modifiers.contains(.option) else { return .ignored }
                                if canSend { submit() }
                                return .handled
                            }
                            // Also with a hardware keyboard: Escape, or
                            // Delete in the empty box, leaves shell mode.
                            .onKeyPress(keys: [.escape, .delete], phases: .down) { press in
                                guard ComposerDraft.mode(of: draft) != .message,
                                      press.key == .escape || ComposerDraft.isEmpty(draft) else { return .ignored }
                                draft = ComposerDraft.leaving(draft)
                                return .handled
                            }
                    }
                    if showsPills { pills }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    // Inside the glass: drawn after it, a border doesn't show.
                    .overlay {
                        if isShellCommand {
                            RoundedRectangle(cornerRadius: PhoneTheme.Radius.field, style: .continuous).strokeBorder(shellTint.opacity(0.55))
                        } else if isSideQuestion {
                            RoundedRectangle(cornerRadius: PhoneTheme.Radius.field, style: .continuous).strokeBorder(PhoneTheme.accent.opacity(0.55))
                        }
                    }
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.field, style: .continuous))
                    sendButton
                }
            }
        }
        // The note and Stop come and go with each turn. Unanimated, the
        // bar and the conversation above it jumped every time.
        .animation(ChatMotion.dock, value: note)
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
        .sensoryFeedback(.impact(weight: .medium), trigger: stops)
        .animation(.snappy, value: attachments.map(\.id))
        .animation(.snappy, value: session.suggestion)
        .animation(.snappy, value: draft.isEmpty)
        .animation(.snappy, value: ComposerDraft.mode(of: draft))
        .animation(.snappy, value: SlashCommand.matches(for: draft, in: commands, limit: 5)?.isEmpty ?? true)
        .animation(.snappy, value: showsModels)
        .animation(.snappy, value: mentionToken?.query)
        .onChange(of: files, initial: true) { _, paths in mentionList = FileMention.all(from: paths) }
        .onChange(of: showsModels) { _, shows in
            guard shows else { return }
            pickerEffort = session.effortLevel
            effortChanged = false
            focused.wrappedValue = false
        }
        // Typing again puts the list away.
        .onChange(of: draft) { _, text in
            if showsModels, !text.isEmpty { showsModels = false }
        }
        .onChange(of: field) { _, text in fieldChanged(to: text) }
        .onChange(of: draft, initial: true) { _, new in draftChanged(to: new) }
    }

    /// The `@` word being typed at the end of a message, which the
    /// project's files can finish. Not in a shell command or a side
    /// question, where an `@` is just an `@`.
    private var mentionToken: ComposerToken? {
        guard !isShellCommand, !isSideQuestion, !mentionList.isEmpty else { return nil }
        return FileMention.token(in: draft)
    }

    /// The model and the permission mode sit in the box, under what you
    /// type, as in Claude Code's terminal. They step aside for a shell
    /// command or a side question, which neither applies to.
    private var showsPills: Bool {
        guard !isShellCommand, !isSideQuestion else { return false }
        return session.model != nil || session.canRunCommand || mode != nil
    }

    private var mode: PermissionMode? {
        guard setMode != nil else { return nil }
        return session.permissionMode.flatMap(PermissionMode.init(rawValue:))
    }

    /// Both pills in full where they fit. On a narrow screen (an iPhone
    /// Duo's outer display, with its bar of buttons down the side) the
    /// mode gives up its name first, and then the model's name is cut
    /// short: pills that insisted on their width pushed the whole screen
    /// off its left edge.
    private var pills: some View {
        ViewThatFits(in: .horizontal) {
            pillRow(compactMode: false, shrinks: false)
            pillRow(compactMode: true, shrinks: false)
            pillRow(compactMode: true, shrinks: true)
        }
    }

    private func pillRow(compactMode: Bool, shrinks: Bool) -> some View {
        HStack(spacing: 6) {
            if session.model != nil || session.canRunCommand {
                modelPill(shrinks: shrinks)
            }
            if let mode, let setMode {
                ModePill(mode: mode, set: setMode, compact: compactMode)
            }
            Spacer(minLength: 0)
        }
    }

    /// The model. Tap for the same list `/model` opens.
    private func modelPill(shrinks: Bool) -> some View {
        let costly = ModelChoice.usesLimitsFaster(model: session.model, switching: switchingModel)
        let current = switchingModel?.name ?? session.model
        return Button {
            if showsModels { showsModels = false } else { openModels() }
        } label: {
            HStack(spacing: 4) {
                if costly {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(ModelChoice.costlyColor)
                }
                Text(ModelChoice.label(model: session.model, switching: switchingModel))
                    .foregroundStyle(costly ? ModelChoice.costlyColor : PhoneTheme.inkMuted)
                    .contentTransition(.opacity)
                if switchingModel != nil {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(PhoneTheme.inkMuted)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: current)
            .composerPill(fill: costly ? ModelChoice.costlyColor.opacity(0.16) : PhoneTheme.ink.opacity(0.07),
                          stroke: costly ? ModelChoice.costlyColor.opacity(0.35) : nil, shrinks: shrinks)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model \(current ?? "unknown")")
        .accessibilityValue(costly ? ModelChoice.usesLimitsFasterNote : "")
        .accessibilityHint("Shows the models and effort levels")
    }

    /// True while the send button is a stop button: Claude is working and
    /// there's nothing to send. Type, and it's an arrow again that queues.
    private var showsStop: Bool {
        stop != nil && session.activity == .working && draft.isEmpty && attachments.isEmpty
    }

    /// One button for sending and stopping: an arrow that sends, and a
    /// square that stops while Claude works and there's nothing to send.
    private var sendButton: some View {
        let symbol = showsStop ? "stop.fill" : isShellCommand ? "return" : "arrow.up"
        let ink: Color = showsStop ? PhoneTheme.ink : canSend ? (isShellCommand ? PhoneTheme.canvas : PhoneTheme.onAccent) : PhoneTheme.inkMuted
        let glass: Glass = showsStop ? .regular.interactive()
            : canSend ? .regular.tint(isShellCommand ? shellTint : PhoneTheme.accent).interactive() : .regular
        return Button {
            if showsStop { stops += 1; stop?() } else { submit() }
        } label: {
            Image(systemName: symbol)
                .font(showsStop ? .footnote.weight(.bold) : .body.weight(.bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(ink)
                .frame(width: 42, height: 42)
                .glassEffect(glass, in: .circle)
        }
        .accessibilityLabel(showsStop ? "Stop \(session.agentTitle)" : isShellCommand ? "Run" : isSideQuestion ? "Ask" : "Send")
        .accessibilityHint(showsStop ? "Interrupts \(session.agentTitle), like pressing Escape in its terminal" : "")
        .disabled(!canSend && !showsStop)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.snappy(duration: 0.22), value: showsStop)
    }

    /// Sends, unless the message is just `/model`: that opens the list of
    /// models instead, as it does in Claude Code's terminal.
    private func submit() {
        if ModelChoice.opensPicker(draft), attachments.isEmpty {
            openModels()
        } else {
            sends += 1
            send()
        }
    }

    private func openModels() {
        draft = ""
        showsModels = true
    }

    private var note: String? {
        if !session.canReply { return session.replyProblem }
        // With nothing typed, the box itself says a message will wait and
        // its button is Stop. Once you type, this line says it, and
        // carries Stop.
        if session.activity == .working, !showsStop { return "Working. Your message waits for the current step to finish." }
        return nil
    }

    private var canSend: Bool {
        // A side question is just the question: pictures wait for the next message.
        if isSideQuestion { return session.canReply && !ComposerDraft.isEmpty(draft) }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ShellDraft.isEmptyCommand(draft)
        return session.canReply && (hasText || !attachments.isEmpty)
    }

    /// True once the draft starts with `!`. The box is then in shell
    /// mode: the `!` shows as a chip beside the field, and the field
    /// holds only the command.
    private var isShellCommand: Bool { ShellDraft.isShell(draft) }

    /// True once the draft starts with `/btw`: a chip stands for it, as
    /// for `!`, and the field holds only the question.
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

    /// The shell's color: the one the chat gives inline code.
    private var shellTint: Color { PhoneTheme.palette.code }
}

/// The models to switch to, above the message box after you send `/model`,
/// like the list Claude Code shows in its terminal. Tap one to switch.
private struct ModelPicker: View {
    /// What the session's agent offers.
    let catalog: AgentCatalog
    var agentName: String = "Claude"
    /// The session's model, like "Opus 5.5".
    let current: String?
    let canSwitch: Bool
    /// The effort level shown, or nil when the Mac doesn't know it.
    let effort: EffortLevel?
    let pick: (ModelChoice) -> Void
    let pickEffort: (EffortLevel) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Switch Model")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(PhoneTheme.ink)
                    if !canSwitch {
                        Text("You can change the model once \(agentName) finishes")
                            .font(.caption)
                            .foregroundStyle(PhoneTheme.inkMuted)
                    }
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .frame(width: 28, height: 28)
                        .touchArea(horizontal: 8, vertical: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)
            ForEach(catalog.models) { choice in
                let isCurrent = choice.matches(current)
                Divider().padding(.leading, 14)
                Button { pick(choice) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(isCurrent ? current ?? choice.name : choice.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PhoneTheme.ink)
                                if choice.isEconomy {
                                    Image(systemName: "leaf.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PhoneTheme.done)
                                        .accessibilityHidden(true)
                                }
                            }
                            Text(choice.summary)
                                .font(.caption)
                                .foregroundStyle(PhoneTheme.inkMuted)
                                .lineLimit(1)
                            if choice.usesLimitsFaster {
                                Label(ModelChoice.usesLimitsFasterNote, systemImage: "flame.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(ModelChoice.costlyColor)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PhoneTheme.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSwitch)
                .opacity(canSwitch ? 1 : 0.6)
                .accessibilityLabel(isCurrent ? "\(choice.name), current model" : choice.name)
            }
            Divider().padding(.leading, 14)
            effortRow
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Effort, as five steps to tap. A tap sets it right away.
    private var effortRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(effort == nil ? "Effort (default)" : "Effort")
                .font(.caption.weight(.medium))
                .foregroundStyle(PhoneTheme.inkMuted)
            HStack(spacing: 4) {
                ForEach(catalog.efforts) { level in
                    let isOn = level == effort
                    Button { pickEffort(level) } label: {
                        Text(level.shortName)
                            .font(.caption.weight(isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? PhoneTheme.ink : PhoneTheme.inkMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(isOn ? PhoneTheme.accent.opacity(0.2) : PhoneTheme.ink.opacity(0.06), in: Capsule())
                            .touchArea(horizontal: 2, vertical: 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(level.name) effort")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .disabled(!canSwitch)
        .opacity(canSwitch ? 1 : 0.6)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private extension View {
    /// A glass list above the message box coming and going. Glass can't
    /// fade (the conversation shows through it until the fade lands), so
    /// the list grows a little out of the box, in a glass group of its own
    /// so the glass and what's on it move as one piece.
    func glassList(from corner: UnitPoint = .bottom) -> some View {
        GlassEffectContainer { self }
            .transition(ChatMotion.glassList(from: corner))
    }
}

/// Slash commands matching what's typed, above the message box. Tap one
/// to put it in the box.
private struct CommandSuggestions: View {
    let commands: [SlashCommand]
    let pick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                if index > 0 { Divider().padding(.leading, 14) }
                Button { pick(command) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("/" + command.name)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .foregroundStyle(PhoneTheme.ink)
                                .lineLimit(1)
                            if let hint = command.argumentHint {
                                Text(hint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(PhoneTheme.inkMuted)
                                    .lineLimit(1)
                            }
                        }
                        if !command.description.isEmpty {
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(PhoneTheme.inkMuted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Puts this command in the message box")
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

#if DEBUG
/// The checklist bar over a bare canvas, for screenshots in the simulator.
struct ChecklistPreview: View {
    var expanded: Bool

    var body: some View {
        let titles = [("Read how race data reaches the race screen", "Reading how race data reaches the race screen"),
                      ("Add a lap time chart view", "Adding a lap time chart view"),
                      ("Wire the chart to live timing", "Wiring the chart to live timing"),
                      ("Handle sessions with no laps yet", "Handling sessions with no laps yet"),
                      ("Add tests for lap parsing", "Adding tests for lap parsing"),
                      ("Run the test suite and fix failures", "Running the test suite and fixing failures"),
                      ("Commit each step", "Committing each step")]
        let items = titles.enumerated().map { index, title in
            ChecklistItem(id: "\(index + 1)", title: title.0, activeTitle: title.1,
                          status: index < 3 ? .completed : index == 3 ? .inProgress : .pending,
                          startedAt: index == 3 ? Date(timeIntervalSinceNow: -131) : nil)
        }
        let session = CompanionSession(id: UUID(), title: "Lap time chart", activity: .working,
                                       since: Date(timeIntervalSinceNow: -1094), checklist: items)
        VStack {
            Spacer()
            ChecklistBar(items: items, session: session)
                .padding(.horizontal, 12)
                .onAppear { UserDefaults.standard.set(expanded, forKey: "checklistExpanded") }
        }
        .background(PhoneTheme.canvas)
    }
}

/// The last turns of a transcript file, for screenshots in the simulator.
struct TranscriptPreview: View {
    let path: String

    var body: some View {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        let messages = data.split(separator: UInt8(ascii: "\n")).flatMap { TranscriptParser.messages(in: Data($0)) }
        let turns = TranscriptTurn.group(messages).suffix(40)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(turns)) { turn in TranscriptTurnView(turn: turn) }
            }
            .padding(16)
        }
        .background(PhoneTheme.canvas)
        .defaultScrollAnchor(.bottom)
    }
}
#endif

/// Runs `end` when the screen's state is let go of, which SwiftUI does
/// when the screen leaves the navigation stack and not while another
/// screen sits on top of it.
nonisolated private final class SessionLease: @unchecked Sendable {
    nonisolated(unsafe) var end: (@MainActor @Sendable () -> Void)?

    deinit {
        guard let end else { return }
        Task { @MainActor in end() }
    }
}
