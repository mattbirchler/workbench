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
                    if inspector == nil {
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
    @State private var search = ""

    private var sessions: [PastSessionSummary]? { client.pastSessions[projectID] }

    var body: some View {
        Group {
            if let sessions {
                if sessions.isEmpty {
                    EmptyStateScaffold(title: "No past sessions",
                                       message: "Conversations in this project show up here once there are some.",
                                       symbol: "clock.arrow.circlepath")
                } else {
                    List(filtered(sessions)) { session in
                        Button {
                            client.resume(projectID: projectID, sessionID: session.id)
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title ?? session.firstPrompt ?? "Untitled")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(PhoneTheme.ink)
                                        .lineLimit(1)
                                    if session.title != nil, let prompt = session.firstPrompt {
                                        Text(prompt).font(.footnote).foregroundStyle(PhoneTheme.inkMuted).lineLimit(2)
                                    }
                                    HStack(spacing: 8) {
                                        Text(session.modified, format: .relative(presentation: .named))
                                        if let branch = session.branch {
                                            Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(PhoneTheme.inkMuted.opacity(0.7))
                                }
                                Spacer()
                                Text(session.openTabID == nil ? "Resume" : "Open")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(session.openTabID == nil ? PhoneTheme.accent : PhoneTheme.inkMuted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(PhoneTheme.surface)
                    }
                    .searchable(text: $search, prompt: "Titles and prompts")
                }
            } else {
                LoadingState()
            }
        }
        .scrollContentBackground(.hidden)
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

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var bases: [String]? { client.agentBases(projectID: projectID) }
    private var trimmedBranch: String { branch.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section("What should it do?") {
                TextField("Describe the task", text: $prompt, axis: .vertical)
                    .lineLimit(4...10)
                    .foregroundStyle(PhoneTheme.ink)
            }
            .listRowBackground(PhoneTheme.surface)
            Section {
                // The label stays on screen: the placeholder alone didn't
                // say this is the branch.
                LabeledContent("Branch") {
                    TextField("Branch", text: $branch, prompt: Text("Suggested from the task"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .foregroundStyle(PhoneTheme.ink)
                Picker("Start From", selection: $base) {
                    Text("Default Branch").tag(String?.none)
                    ForEach(bases ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .foregroundStyle(PhoneTheme.ink)
                .tint(PhoneTheme.inkMuted)
                .disabled(bases == nil)
            } footer: {
                if !trimmedBranch.isEmpty, bases?.contains(trimmedBranch) == true {
                    Text("\(trimmedBranch) already exists, so the agent picks it up where it left off instead of starting fresh.")
                } else {
                    Text("A new worktree for \(project?.repoName ?? "the repo") on your Mac. The setup files and command saved for the project are used, or its .env files if none are saved.")
                }
            }
            .listRowBackground(PhoneTheme.surface)
            if let problem = client.lastProblem {
                Section { Text(problem).foregroundStyle(PhoneTheme.error) }
                    .listRowBackground(PhoneTheme.surface)
            }
            // The main button, on the page instead of in a row, where it
            // read as a line of text.
            Section {
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
                .buttonStyle(.phonePrimary)
                .sensoryFeedback(.impact(weight: .medium), trigger: isStarting) { _, new in new }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneTheme.canvas)
        .navigationTitle("New Agent")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: client.lastProblem) { _, problem in if problem != nil { isStarting = false } }
        // A dropped connection never answers, so don't wait on it.
        .onChange(of: client.status) { _, status in if status != .connected { isStarting = false } }
        .onAppear {
            client.clearLastProblem()
            if !client.isWatchingChanges(projectID) {
                startedWatching = true
                client.watchChanges(projectID: projectID)
            }
        }
        .onDisappear { if startedWatching { client.unwatchChanges(projectID: projectID) } }
    }
}
