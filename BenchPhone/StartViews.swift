import BenchKit
import SwiftUI

struct PastSessionsRoute: Hashable {
    var projectID: UUID
}

struct NewAgentRoute: Hashable {
    var projectID: UUID
}

/// The toolbar menu on a project: open or start things on the Mac. All of
/// it needs the Mac, so it's gone while the Mac is out of reach.
struct ProjectMenu: ToolbarContent {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    var session: CompanionSession?
    @Environment(\.inspector) private var inspector

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }

    var body: some ToolbarContent {
        if !client.isShowingSaved {
            if let inspector {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(inspector.isShown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right", action: inspector.toggle)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if inspector == nil, !client.isHeadless {
                        NavigationLink(value: ChangesRoute(projectID: projectID)) {
                            Label("Changes", systemImage: "plus.forwardslash.minus")
                        }
                    }
                    if client.canBrowseFiles, inspector == nil {
                        NavigationLink(value: FilesRoute(projectID: projectID)) {
                            Label("Files", systemImage: "folder")
                        }
                    }
                    NavigationLink(value: PastSessionsRoute(projectID: projectID)) {
                        Label("Past Sessions", systemImage: "clock.arrow.circlepath")
                    }
                    Divider()
                    Button("New Agent Tab", systemImage: "plus.square") { client.newClaudeTab(projectID: projectID, prompt: nil) }
                    NavigationLink(value: NewAgentRoute(projectID: projectID)) {
                        Label("New Agent on a Branch…", systemImage: "arrow.triangle.branch")
                    }
                } label: {
                    // A plain ⋯, like the chat's: the bar draws the circle.
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }
}

/// A project's past conversations, newest first. Tap one to pick it up in
/// a new Claude tab on the Mac.
struct PastSessionsView: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    @State private var search = Self.sampleSearch

    private var sessions: [PastSessionSummary]? { client.pastSessions[projectID] }

    /// For screenshots: BENCH_SEARCH starts the screen with a search typed.
    private static var sampleSearch: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["BENCH_SEARCH"] ?? ""
        #else
        ""
        #endif
    }

    var body: some View {
        Group {
            if let sessions {
                if sessions.isEmpty {
                    EmptyStateScaffold(title: "No past sessions",
                                       message: "Conversations in this project show up here once there are some.",
                                       symbol: "clock.arrow.circlepath")
                } else {
                    let shown = filtered(sessions)
                    Group {
                        if shown.isEmpty {
                            EmptyStateScaffold(title: "No matches", message: "No past session mentions that in its title, prompts or branch.",
                                               symbol: "magnifyingglass")
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 10) {
                                    ForEach(shown) { session in
                                        Button {
                                            client.resume(projectID: projectID, sessionID: session.id)
                                        } label: {
                                            PastSessionCard(session: session)
                                        }
                                        .buttonStyle(.cardPress)
                                    }
                                }
                                // On an iPad it stays a comfortable column instead of stretching.
                                .frame(maxWidth: 640)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "Titles and prompts")
                }
            } else {
                LoadingState()
            }
        }
        .background(PhoneTheme.canvas)
        .navigationTitle("Past Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: client.status) {
            if client.status == .connected { client.loadPastSessions(projectID: projectID) }
        }
    }

    private func filtered(_ sessions: [PastSessionSummary]) -> [PastSessionSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            [session.title, session.firstPrompt, session.lastPrompt, session.branch]
                .contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }
    }
}

/// One past conversation: when it was last touched, what was first asked,
/// and what else the Mac knows about it.
private struct PastSessionCard: View {
    let session: PastSessionSummary

    /// What was first asked is what people remember a conversation by, so
    /// it leads, with the title Claude gave it as the line under it.
    private var headline: String { session.firstPrompt ?? session.title ?? "Untitled" }
    private var subtitle: String? { session.firstPrompt == nil ? nil : session.title }
    /// Where a long conversation ended up, when that isn't where it began.
    private var lastPrompt: String? {
        guard let last = session.lastPrompt, last != session.firstPrompt else { return nil }
        return last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                (Text(session.modified, format: .relative(presentation: .named))
                    + Text("  \u{00B7}  ")
                    + Text(session.modified, format: .dateTime.month(.abbreviated).day()))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if session.openTabID != nil {
                    // Already in a tab on the Mac, so tapping goes to it
                    // instead of starting it again.
                    HStack(spacing: 5) {
                        Circle().fill(PhoneTheme.done).frame(width: 6, height: 6)
                        Text("Open on Mac")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PhoneTheme.inkMuted)
                }
            }
            Text(headline)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(PhoneTheme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, 6)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            if let lastPrompt {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(lastPrompt).lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(PhoneTheme.inkMuted)
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Last message: \(lastPrompt)")
            }
            HStack(spacing: 8) {
                if let branch = session.branch {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                        Text(branch)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PhoneTheme.raised, in: Capsule())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Branch \(branch)")
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(session.openTabID == nil ? "Resume" : "Open")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PhoneTheme.accent)
            }
            .padding(.top, 12)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
    }
}

/// Start an agent on its own branch, from the phone. The Mac makes the
/// worktree with the project's saved setup and starts Claude with the
/// prompt.
struct NewAgentView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var prompt = ""
    @State private var branch = ""
    /// Nil starts from the branch the Mac would pick, usually main.
    @State private var base: String?
    @State private var isStarting = false
    /// Whether this view asked for the project's changes (for the branch
    /// list), so it stops them when it closes.
    @State private var startedWatching = false
    @FocusState private var typing: Bool

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var bases: [String]? { client.agentBases(projectID: projectID) }
    private var trimmedBranch: String { branch.trimmingCharacters(in: .whitespaces) }

    private var canStart: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStarting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("What should it do?")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(PhoneTheme.ink)
                    .padding(.horizontal, 4)
                TextField("Describe the task", text: $prompt, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($typing)
                    .font(.body)
                    .foregroundStyle(PhoneTheme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous)
                        .strokeBorder(typing ? PhoneTheme.accent.opacity(0.6) : PhoneTheme.hairline))
                    .animation(.easeOut(duration: 0.15), value: typing)
                    .padding(.top, 10)
                options
                    .padding(.top, 14)
                Group {
                    if !trimmedBranch.isEmpty, bases?.contains(trimmedBranch) == true {
                        Text("\(trimmedBranch) already exists, so the agent picks it up where it left off instead of starting fresh.")
                    } else {
                        Text("A new worktree for \(project?.repoName ?? "the repo") on your Mac. The setup files and command saved for the project are used, or its .env files if none are saved.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(PhoneTheme.inkMuted)
                .padding(.horizontal, 4)
                .padding(.top, 10)
                if let problem = client.lastProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(PhoneTheme.error)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PhoneTheme.error.opacity(0.1), in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
                        .padding(.top, 16)
                }
            }
            // On an iPad it stays a comfortable column instead of stretching.
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        // The main button stays in reach above the keyboard, instead of
        // somewhere down the page.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                isStarting = true
                client.newAgent(parentID: projectID, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                branch: trimmedBranch, base: base)
            } label: {
                HStack(spacing: 8) {
                    if isStarting { ProgressView() }
                    Text("Start Agent")
                }
            }
            // Quiet until there's a task to start. While it's starting it
            // keeps the accent, dimmed, so it still reads as the thing
            // that was pressed.
            .buttonStyle(PhonePrimaryButtonStyle(quietWhenDisabled: !isStarting))
            .sensoryFeedback(.impact(weight: .medium), trigger: isStarting) { _, new in new }
            .disabled(!canStart)
            .animation(.easeOut(duration: 0.15), value: canStart)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(PhoneTheme.canvas)
        }
        .background(PhoneTheme.canvas)
        .navigationTitle("New Agent")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: client.lastProblem) { _, problem in if problem != nil { isStarting = false } }
        // A dropped connection never answers, so don't wait on it.
        .onChange(of: client.status) { _, status in if status != .connected { isStarting = false } }
        .onAppear {
            // Straight to typing: the task is the one thing the screen needs.
            typing = true
            client.clearLastProblem()
            if !client.isWatchingChanges(projectID) {
                startedWatching = true
                client.watchChanges(projectID: projectID)
            }
        }
        .onDisappear { if startedWatching { client.unwatchChanges(projectID: projectID) } }
    }

    /// The branch and where it starts from, as two rows of one card.
    private var options: some View {
        VStack(spacing: 0) {
            // The label stays on screen: the placeholder alone didn't
            // say this is the branch.
            HStack(spacing: 12) {
                optionLabel("Branch", symbol: "arrow.triangle.branch")
                TextField("Branch", text: $branch, prompt: Text("Suggested from the task").font(.subheadline))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(PhoneTheme.ink)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            Rectangle().fill(PhoneTheme.hairline).frame(height: 1).padding(.leading, 14)
            HStack(spacing: 12) {
                optionLabel("Start From", symbol: "arrow.turn.down.right")
                Spacer(minLength: 8)
                Menu {
                    Picker("Start From", selection: $base) {
                        Text("Default Branch").tag(String?.none)
                        ForEach(bases ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let base {
                            Text(base).font(.system(.subheadline, design: .monospaced))
                        } else {
                            Text("Default Branch").font(.subheadline)
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .touchArea(vertical: 12)
                }
                .disabled(bases == nil)
                .accessibilityLabel("Start From")
                .accessibilityValue(base ?? "Default Branch")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
        }
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
    }

    private func optionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PhoneTheme.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(PhoneTheme.ink)
        }
        .fixedSize()
    }
}
