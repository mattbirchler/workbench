import BenchKit
import SwiftUI

struct ChangesRoute: Hashable {
    var projectID: UUID
}

struct DiffRoute: Hashable {
    var projectID: UUID
    var change: FileChange
}

/// How many Changes lists are on screen for each project.
@MainActor
private enum ChangesLists {
    static var open: [UUID: Int] = [:]
}

/// The Changes panel, on a phone: what's staged, what isn't, what this
/// branch adds over its base, and the commits on it.
struct ChangesView: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var changes: ChangesSnapshot? { client.changes[projectID] }

    var body: some View {
        Group {
            if let changes {
                if !changes.isRepository {
                    EmptyStateScaffold(title: "Not a Git repository", message: project?.name ?? "", symbol: "folder")
                } else if changes.fileCount == 0, changes.commits.isEmpty {
                    EmptyStateScaffold(title: "No changes",
                                       message: changes.baseRef.map { "Nothing differs from \($0)." } ?? "The working copy is clean.") {
                        ChangesEmptyIllustration(appeared: $0, branch: changes.branch)
                    }
                } else {
                    List {
                        if let error = changes.error {
                            Text(error).font(.footnote).foregroundStyle(PhoneTheme.error)
                                .listRowBackground(PhoneTheme.surface)
                        }
                        if let summary = branchSummary(changes) {
                            Text(summary).font(.footnote).foregroundStyle(PhoneTheme.inkMuted)
                                .listRowBackground(PhoneTheme.surface)
                        }
                        fileSection("Staged", files: changes.staged)
                        fileSection("Unstaged", files: changes.unstaged)
                        fileSection(changes.baseRef.map { "Against \($0)" } ?? "Against base", files: changes.againstBase)
                        if !changes.commits.isEmpty {
                            Section("Commits on \(changes.branch ?? "this branch")") {
                                ForEach(changes.commits) { commit in
                                    // A Mac that can show a commit on one page makes it tappable.
                                    if client.canReviewCode {
                                        OpenLink(item: .commit(CommitRoute(projectID: projectID, hash: commit.hash, shortHash: commit.shortHash))) {
                                            CommitRow(commit: commit)
                                        }
                                    } else {
                                        CommitRow(commit: commit)
                                    }
                                }
                            }
                            .listRowBackground(PhoneTheme.surface)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            } else {
                LoadingState(text: "Reading the repository")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneTheme.canvas)
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Where the list has a navigation bar. The iPad's right pane
            // has none, and shows the same two controls under its tabs.
            ToolbarItemGroup(placement: .topBarTrailing) {
                ChangesControls(projectID: projectID)
            }
        }
        .task(id: client.status) {
            if client.status == .connected { client.watchChanges(projectID: projectID) }
        }
        .onAppear { ChangesLists.open[projectID, default: 0] += 1 }
        // The iPad can show this list twice, in the inspector and pushed
        // over the chat. Closing one mustn't stop the other's changes.
        .onDisappear {
            let left = (ChangesLists.open[projectID] ?? 1) - 1
            ChangesLists.open[projectID] = left > 0 ? left : nil
            if left <= 0 { client.unwatchChanges(projectID: projectID) }
        }
    }

    /// "3 ahead of origin/main, 1 behind", from the Mac's header numbers.
    private func branchSummary(_ changes: ChangesSnapshot) -> String? {
        guard let base = changes.baseRef, let ahead = changes.aheadOfBase, let behind = changes.behindBase else { return nil }
        if ahead == 0, behind == 0 { return "Even with \(base)" }
        var parts = ["\(ahead) ahead of \(base)"]
        if behind > 0 { parts.append("\(behind) behind") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func fileSection(_ title: String, files: [FileChange]) -> some View {
        if !files.isEmpty {
            Section {
                ForEach(files) { file in
                    OpenLink(item: .diff(DiffRoute(projectID: projectID, change: file))) {
                        FileRow(file: file)
                    }
                }
                .listRowBackground(PhoneTheme.surface)
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    LineCounts(additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
                        .textCase(nil)
                }
            }
        }
    }
}

private struct CommitRow: View {
    let commit: Commit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.subject).font(.subheadline).foregroundStyle(PhoneTheme.ink).lineLimit(2)
            HStack(spacing: 8) {
                Text(commit.shortHash).font(.caption.monospaced())
                Text(commit.date, format: .relative(presentation: .named))
                Spacer()
                LineCounts(additions: commit.additions, deletions: commit.deletions)
            }
            .font(.caption)
            .foregroundStyle(PhoneTheme.inkMuted)
        }
        .padding(.vertical, 2)
    }
}

private struct FileRow: View {
    let file: FileChange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: FileIcon.symbol(for: file.fileName))
                .font(.subheadline)
                .foregroundStyle(PhoneTheme.inkMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName).font(.subheadline.weight(.medium)).foregroundStyle(PhoneTheme.ink).lineLimit(1)
                if !file.directory.isEmpty {
                    Text(file.directory).font(.caption).foregroundStyle(PhoneTheme.inkMuted).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if file.isBinary {
                Text("binary").font(.caption).foregroundStyle(PhoneTheme.inkMuted)
            } else {
                LineCounts(additions: file.additions, deletions: file.deletions)
            }
            // What happened to it, as on the Mac: a letter in its color.
            Text(letter)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(color.opacity(0.6)))
        }
    }

    private var letter: String {
        switch file.kind {
        case .untracked: "U"
        case .typeChanged: "T"
        default: file.kind.rawValue
        }
    }

    private var color: Color {
        switch file.kind {
        case .added, .untracked: PhoneTheme.done
        case .deleted: PhoneTheme.error
        case .renamed, .copied: PhoneTheme.remote
        case .conflicted: PhoneTheme.working
        case .modified, .typeChanged: PhoneTheme.waiting
        }
    }
}

/// One file's diff: green and red lines, with the changed words marked.
struct DiffScreen: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    let change: FileChange

    /// Stretches of unchanged lines opened so far.
    @State private var expanded: Set<Int> = []

    private var lines: [DiffLine]? { client.diffs["\(projectID):\(change.id)"] }

    /// A Mac with the codeReview feature sends the whole file in one hunk,
    /// so long unchanged stretches fold into "Show N lines" rows. Anything
    /// else, like an older Mac's diff with several hunks, shows as it came.
    private func folded(_ lines: [DiffLine]) -> DiffFolding.Result {
        guard client.canReviewCode, lines.count(where: { $0.kind == .hunk }) <= 1 else { return DiffFolding.Result(lines: lines) }
        return DiffFolding.fold(lines, expanded: expanded)
    }

    var body: some View {
        Group {
            if let lines {
                if lines.isEmpty {
                    EmptyStateScaffold(title: "No diff", message: change.isBinary ? "This is a binary file." : "Git had nothing to show for this file.", symbol: "doc")
                } else {
                    let shown = folded(lines)
                    // The rows fill this view's width, not the screen's,
                    // which is wrong in Split View on an iPad. They also
                    // run on under a bar down the side (an iPhone Duo), as
                    // long lines of code already do, so a changed line's
                    // color doesn't stop short of its text.
                    GeometryReader { proxy in
                    let rowWidth = proxy.size.width + proxy.safeAreaInsets.trailing
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shown.lines.enumerated()), id: \.element.id) { index, line in
                                if let key = shown.folds[index] {
                                    DiffFoldRow(text: line.text, minWidth: rowWidth) {
                                        withAnimation(.snappy) { _ = expanded.insert(key) }
                                    }
                                } else {
                                    DiffLineRow(line: line, minWidth: rowWidth)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .diffFont()
                    }
                }
            } else {
                LoadingState()
            }
        }
        .background(PhoneTheme.canvas)
        .navigationTitle(change.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: client.status) {
            if client.status == .connected { client.requestDiff(projectID: projectID, change: change) }
        }
    }
}

extension View {
    /// A diff's font: small and monospaced, growing with the system text
    /// size. It stops at one size up, since the line-number columns are a
    /// fixed width and a bigger number would wrap.
    func diffFont() -> some View {
        font(.caption.monospaced())
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// What Changes compares against, and Refresh. In the navigation bar on a
/// phone; in the iPad's right pane, a row under the tabs (`showsBase`),
/// where there's room to say which branch it is.
struct ChangesControls: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    var showsBase = false

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var changes: ChangesSnapshot? { client.changes[projectID] }

    /// "Default Branch (main)"
    private var defaultLabel: String {
        project?.defaultBranch.map { "Default Branch (\($0))" } ?? "Default Branch"
    }

    /// Whether there's anything to show: an older Mac can't change the
    /// base, and a folder without git has none.
    static func isAvailable(_ client: CompanionClient, projectID: UUID) -> Bool {
        client.canControlBranches && client.changes[projectID]?.isRepository == true
    }

    var body: some View {
        if Self.isAvailable(client, projectID: projectID), let changes {
            Menu {
                Section("Compare Against") {
                    Button { client.setBaseRef(projectID: projectID, ref: nil) } label: {
                        if changes.chosenBase == nil { Label(defaultLabel, systemImage: "checkmark") } else { Text(defaultLabel) }
                    }
                    ForEach((changes.branches ?? []).filter { $0 != changes.branch }, id: \.self) { branch in
                        Button { client.setBaseRef(projectID: projectID, ref: branch) } label: {
                            if changes.chosenBase == branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                        }
                    }
                }
            } label: {
                if showsBase {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text("vs \(changes.chosenBase ?? changes.baseRef ?? project?.defaultBranch ?? "default")")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PhoneTheme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(PhoneTheme.surface, in: Capsule())
                    .touchArea(vertical: 7)
                } else {
                    Label("Compare Against", systemImage: "arrow.triangle.branch")
                }
            }
            .accessibilityLabel("Compare Against")
            if showsBase { Spacer(minLength: 8) }
            Button { client.refreshChanges(projectID: projectID) } label: {
                if showsBase {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PhoneTheme.ink)
                        .frame(width: 30, height: 30)
                        .background(PhoneTheme.surface, in: Circle())
                        .touchArea(horizontal: 7, vertical: 7)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .accessibilityLabel("Refresh")
        }
    }
}
