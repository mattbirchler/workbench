import BenchKit
import SwiftUI

struct CommitRoute: Hashable {
    var projectID: UUID
    var hash: String
    var shortHash: String
}

/// One commit on one page: what it says, the files it touched, and every
/// file's diff in one scroll. Tap a file to jump to it.
struct CommitScreen: View {
    @Environment(CompanionClient.self) private var client
    let route: CommitRoute

    private var state: CommitReviewState? { client.commitReviews["\(route.projectID):\(route.hash)"] }

    var body: some View {
        Group {
            switch state {
            case .loaded(let review)?:
                content(review)
            case .failed?:
                EmptyStateScaffold(title: "Can't show this commit", message: "Workbench couldn't read it on your Mac.",
                                   symbol: "exclamationmark.triangle")
            case nil:
                LoadingState()
            }
        }
        .background(PhoneTheme.canvas)
        .navigationTitle(route.shortHash)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: client.status) {
            if client.status == .connected, state == nil { client.requestCommitReview(projectID: route.projectID, hash: route.hash) }
        }
    }

    private func content(_ review: CommitReview) -> some View {
        // Rows fill this view's width, not the screen's, which is wrong in
        // Split View on an iPad.
        GeometryReader { geometry in content(review, width: geometry.size.width) }
    }

    private func content(_ review: CommitReview, width: CGFloat) -> some View {
        let headers = Dictionary(uniqueKeysWithValues: review.diff.files.map { ($0.headerLine, $0) })
        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(review.commit)
                        .frame(width: width, alignment: .leading)
                    fileList(review.diff.files) { file in
                        withAnimation { proxy.scrollTo(review.diff.lines[file.headerLine].id, anchor: .top) }
                    }
                    .frame(width: width, alignment: .leading)
                    ForEach(Array(review.diff.lines.enumerated()), id: \.element.id) { index, line in
                        if let file = headers[index] {
                            FileHeaderRow(file: file, minWidth: width)
                        } else {
                            DiffLineRow(line: line, minWidth: width)
                        }
                    }
                    .diffFont()
                    if review.truncated {
                        Text("This commit is too big to show all of it here. Open it on your Mac to see the rest.")
                            .font(.footnote)
                            .foregroundStyle(PhoneTheme.inkMuted)
                            .padding(16)
                            .frame(width: width, alignment: .leading)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func header(_ commit: Commit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.subject)
                .font(.headline)
                .foregroundStyle(PhoneTheme.ink)
                .textSelection(.enabled)
            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(.subheadline)
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(commit.author)
                Text(commit.date, format: .relative(presentation: .named))
                Spacer()
                LineCounts(additions: commit.additions, deletions: commit.deletions)
            }
            .font(.caption)
            .foregroundStyle(PhoneTheme.inkMuted)
        }
        .padding(16)
    }

    private func fileList(_ files: [ReviewFile], open: @escaping (ReviewFile) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files) { file in
                Button { open(file) } label: {
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
                        LineCounts(additions: file.additions, deletions: file.deletions)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Jumps to its changes")
            }
        }
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

/// Where one file's changes start in a commit review.
private struct FileHeaderRow: View {
    let file: ReviewFile
    let minWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: FileIcon.symbol(for: file.fileName))
                .foregroundStyle(PhoneTheme.inkMuted)
            Text(file.path)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PhoneTheme.ink)
            LineCounts(additions: file.additions, deletions: file.deletions)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(PhoneTheme.ink.opacity(0.08))
    }
}
