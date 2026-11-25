import BenchKit
import SwiftUI

/// The changes panel for a project on another Mac. It's the same list as
/// a project on this Mac, fed by what the other Mac sends.
struct RemoteChangesPanel: View {
    @Environment(RemoteMacs.self) private var macs
    @Environment(ClaudeActions.self) private var actions
    let host: String
    let projectID: UUID

    private var client: CompanionClient? { macs.client(for: host) }
    private var project: CompanionProject? { client?.snapshot?.projects.first { $0.id == projectID } }
    private var changes: ChangesSnapshot? { client?.changes[projectID] }
    /// An older Mac can't take refreshes or base changes.
    private var canControl: Bool { client?.canControlBranches == true }

    var body: some View {
        Group {
            if let changes {
                if !changes.isRepository {
                    VStack(spacing: 0) {
                        NotRepositoryBar()
                        Divider()
                        RemoteFilesPanel(host: host, projectID: projectID)
                    }
                } else {
                    ChangesList(
                        snapshot: changes,
                        selectedDiffID: selectedDiffID,
                        openDiff: { macs.openDiff(host: host, projectID: projectID, change: $0) },
                        refresh: canControl ? { client?.refreshChanges(projectID: projectID) } : nil,
                        chooseBase: canControl ? { client?.setBaseRef(projectID: projectID, ref: $0) } : nil,
                        // This Mac's buttons, sent to an agent on that one.
                        actions: actions.all,
                        pullRequest: project?.pullRequest.map(PullRequestInfo.init)
                    ) { file in
                        Button("Show Changes") { macs.openDiff(host: host, projectID: projectID, change: file) }
                        if file.kind != .deleted {
                            Button("Open") { macs.openFile(host: host, projectID: projectID, path: file.path) }
                        }
                        Divider()
                        CopyPathButtons(path: file.path, root: nil)
                    } openFile: { file in
                        macs.openFile(host: host, projectID: projectID, path: file.path)
                    } runAction: { prompt in
                        run(prompt)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: client?.status) {
            if client?.status == .connected { client?.watchChanges(projectID: projectID) }
        }
        .onDisappear { client?.unwatchChanges(projectID: projectID) }
    }

    /// Sends an action's prompt to an agent in this project on the other
    /// Mac: the one whose tab is open here, or else its newest, or a new
    /// tab when it has none. Returns why it couldn't.
    private func run(_ prompt: String) -> String? {
        guard let client, client.status == .connected else { return "Not connected to \(macs.name(for: host))." }
        let key = RemoteMacs.key(host: host, projectID: projectID)
        let sessions = project?.sessions ?? []
        var open: UUID?
        if case .session(let id) = macs.openTabs[key] { open = id }
        guard let target = sessions.first(where: { $0.id == open }) ?? sessions.last else {
            client.newClaudeTab(projectID: projectID, prompt: prompt)
            return nil
        }
        guard target.canReply else {
            return target.replyProblem ?? "\(target.agentTitle) can't take a message right now."
        }
        macs.openTabs[key] = .session(target.id)
        client.reply(sessionID: target.id, text: prompt)
        return nil
    }

    /// The diff tab showing in this project, if one is.
    private var selectedDiffID: String? {
        if case .diff(let change) = macs.openTabs[RemoteMacs.key(host: host, projectID: projectID)] { return change.id }
        return nil
    }
}

/// One file's diff from the other Mac.
struct RemoteDiffView: View {
    @Environment(RemoteMacs.self) private var macs
    let host: String
    let projectID: UUID
    let change: FileChange

    private var client: CompanionClient? { macs.client(for: host) }
    private var lines: [DiffLine]? { client?.diffs["\(projectID):\(change.id)"] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(change.fileName).fontWeight(.semibold)
                Text(change.directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                if !change.isBinary {
                    Text("+\(change.additions)").foregroundStyle(Theme.Status.done).font(.callout.monospacedDigit())
                    Text("−\(change.deletions)").foregroundStyle(Theme.Status.failed).font(.callout.monospacedDigit())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let lines {
                if lines.isEmpty {
                    ContentUnavailableView("No Diff", systemImage: "doc",
                                           description: Text(change.isBinary ? "This is a binary file." : "Git had nothing to show for this file."))
                } else {
                    GeometryReader { geometry in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lines) { line in
                                    DiffLineRow(line: line, minWidth: geometry.size.width)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .font(.ui(size: 12, design: .monospaced))
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: client?.status) {
            if client?.status == .connected { client?.requestDiff(projectID: projectID, change: change) }
        }
    }
}
