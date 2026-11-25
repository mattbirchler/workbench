import BenchKit
import SwiftUI

struct FilesRoute: Hashable {
    var projectID: UUID
    /// The folder to list, relative to the project. "" is the project itself.
    var folder = ""
}

struct FileRoute: Hashable {
    var projectID: UUID
    var path: String
}

/// A project's files on the Mac, one folder at a time, with a search
/// across all of them.
struct FilesView: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    let folder: String
    /// Opens a folder in place, for the iPad's inspector.
    var openFolder: ((String) -> Void)?
    @State private var search = Self.sampleSearch

    /// For screenshots: BENCH_SEARCH starts the screen with a search typed.
    private static var sampleSearch: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["BENCH_SEARCH"] ?? ""
        #else
        ""
        #endif
    }

    /// The most search results shown, so a short query in a big project
    /// doesn't build thousands of rows.
    private static let resultLimit = 200

    private var project: CompanionProject? { client.snapshot?.projects.first { $0.id == projectID } }
    private var tree: FileTree? { client.fileTrees[projectID] }
    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Group {
            if !client.canBrowseFiles {
                EmptyStateScaffold(title: "Update Workbench on your Mac",
                                   message: "This Mac's version of Workbench can't share its files yet.", symbol: "folder")
            } else if let tree {
                if !query.isEmpty {
                    results(tree.rows(matching: query, limit: Self.resultLimit))
                } else if let entries = tree.children[folder], !entries.isEmpty {
                    listing(entries, in: tree)
                } else {
                    EmptyStateScaffold(title: "No files", symbol: "folder")
                }
            } else {
                LoadingState()
            }
        }
        .scrollContentBackground(.hidden)
        .background(PhoneTheme.canvas)
        .navigationTitle(folder.isEmpty ? (project?.name ?? "Files") : String(folder.split(separator: "/").last ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        // The Mac sends the whole list of files, so the search covers the
        // project from any folder, not just the one that's open.
        .searchable(text: $search, prompt: "Search all files")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .watchingFiles(of: projectID)
    }

    /// The open folder: where it is, then its folders and files.
    private func listing(_ entries: [FileTree.Entry], in tree: FileTree) -> some View {
        List {
            Section {
                if folder.isEmpty, client.truncatedFiles.contains(projectID) {
                    Text("This project has more files than Workbench lists. Some are left out.")
                        .font(.footnote)
                        .foregroundStyle(PhoneTheme.inkMuted)
                }
                ForEach(entries, id: \.path) { entry in
                    if entry.isDirectory, let openFolder {
                        // In the iPad's inspector, which has no stack of its own.
                        Button { openFolder(entry.path) } label: {
                            HStack {
                                FileRow(entry: entry, count: tree.children[entry.path]?.count)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(PhoneTheme.inkMuted.opacity(0.7))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else if entry.isDirectory {
                        NavigationLink(value: FilesRoute(projectID: projectID, folder: entry.path)) {
                            FileRow(entry: entry, count: tree.children[entry.path]?.count)
                        }
                    } else {
                        OpenLink(item: .file(FileRoute(projectID: projectID, path: entry.path))) {
                            FileRow(entry: entry)
                        }
                    }
                }
            } header: {
                Breadcrumb(root: project?.name ?? "Project", folder: folder, count: entries.count)
            }
            .listRowBackground(PhoneTheme.surface)
        }
        .listStyle(.insetGrouped)
    }

    /// Files anywhere in the project whose path has the search in it.
    @ViewBuilder
    private func results(_ rows: [FileTree.Row]) -> some View {
        if rows.isEmpty {
            EmptyStateScaffold(title: "No matches",
                               message: "No file in \(project?.name ?? "this project") has \u{201C}\(query)\u{201D} in its name or path.",
                               symbol: "magnifyingglass")
        } else {
            List {
                Section {
                    ForEach(rows) { row in
                        OpenLink(item: .file(FileRoute(projectID: projectID, path: row.entry.path))) {
                            FileRow(entry: row.entry, showsFolder: true)
                        }
                    }
                } header: {
                    Text(rows.count == Self.resultLimit ? "First \(rows.count) matches" : rows.count == 1 ? "1 match" : "\(rows.count) matches")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .textCase(nil)
                }
                .listRowBackground(PhoneTheme.surface)
            }
            .listStyle(.insetGrouped)
        }
    }
}

/// Where the open folder is: the project, then each folder down to this
/// one, with how many things are in it at the far end.
private struct Breadcrumb: View {
    let root: String
    let folder: String
    let count: Int

    private var parts: [String] { folder.split(separator: "/").map(String.init) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            path
                .lineLimit(1)
                // A deep path keeps its end, which is where you are.
                .truncationMode(.head)
                .accessibilityLabel("In \(([root] + parts).joined(separator: ", "))")
            Spacer(minLength: 0)
            Text(count == 1 ? "1 item" : "\(count) items")
                .foregroundStyle(PhoneTheme.inkMuted)
                .fixedSize()
        }
        .font(.system(.caption, design: .monospaced))
        .textCase(nil)
    }

    /// The folders in muted ink and the open one in full, so the eye
    /// lands on the end.
    private var path: Text {
        let names = [root] + parts
        var text = Text("")
        for (index, name) in names.enumerated() {
            let isLast = index == names.count - 1
            text = text + Text(name).foregroundColor(isLast ? PhoneTheme.ink : PhoneTheme.inkMuted)
            if !isLast { text = text + Text(" / ").foregroundColor(PhoneTheme.inkMuted.opacity(0.6)) }
        }
        return text
    }
}

/// One folder or file: a tile tinted by what kind of thing it is, and its
/// name in the code face, since it's a name from the disk.
private struct FileRow: View {
    let entry: FileTree.Entry
    /// How many things a folder holds.
    var count: Int?
    /// Adds the folder the file is in, for search results from all over.
    var showsFolder = false
    @ScaledMetric(relativeTo: .subheadline) private var tile: CGFloat = 30

    private var symbol: String { entry.isDirectory ? "folder.fill" : FileIcon.symbol(for: entry.name) }

    /// Folders in the accent, then a color for each kind of file the
    /// icons already tell apart.
    private var tint: Color {
        if entry.isDirectory { return PhoneTheme.accent }
        switch symbol {
        case "chevron.left.forwardslash.chevron.right": return PhoneTheme.remote
        case "curlybraces": return PhoneTheme.waiting
        case "photo": return PhoneTheme.merged
        default: return PhoneTheme.inkMuted
        }
    }

    private var parent: String {
        let parts = entry.path.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : parts.joined(separator: "/")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: tile, height: tile)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(PhoneTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsFolder {
                    Text(parent)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if let count {
                Text("\(count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .accessibilityLabel(count == 1 ? "1 item" : "\(count) items")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One file from the Mac, reloading when it changes there.
struct FileScreen: View {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID
    let path: String

    private var content: FileContent? { client.fileContents["\(projectID):\(path)"] }
    /// The text with its colors, made once per change of the file or its
    /// colors. Making it in the body ran on every draw.
    @State private var colored: AttributedString?

    var body: some View {
        Group {
            switch content {
            case .text(let text)?:
                ScrollView([.vertical, .horizontal]) {
                    Text(colored ?? AttributedString(text))
                        // Follows the system text size, like the bars around it.
                        .font(.caption.monospaced())
                        .foregroundStyle(PhoneTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case .image(let data)?:
                if let image = UIImage(data: data) {
                    ScrollView([.vertical, .horizontal]) {
                        Image(uiImage: image).resizable().scaledToFit().padding(12)
                    }
                } else {
                    EmptyStateScaffold(title: "Can't show this image", symbol: "photo")
                }
            case .binary(let size)?:
                EmptyStateScaffold(title: "Not a text file",
                                   message: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), symbol: "doc")
            case .tooLarge(let size)?:
                EmptyStateScaffold(title: "Too large to show",
                                   message: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), symbol: "doc")
            case .missing?:
                EmptyStateScaffold(title: "File not found", message: "It may have been moved or deleted on your Mac.",
                                   symbol: "questionmark.folder")
            case nil:
                LoadingState()
            }
        }
        .background(PhoneTheme.canvas)
        .navigationTitle(String(path.split(separator: "/").last ?? Substring(path)))
        .navigationBarTitleDisplayMode(.inline)
        .watchingFiles(of: projectID)
        .task(id: Revision(connected: client.status == .connected, revision: client.fileRevisions[projectID])) {
            guard client.status == .connected else { return }
            client.requestFile(projectID: projectID, path: path)
        }
        .onChange(of: Coloring(content: content, runs: client.fileCode["\(projectID):\(path)"]), initial: true) { _, now in
            colored = now.text.map { color($0, runs: now.runs) }
        }
    }

    /// The text with its code colored, once the Mac has sent the colors.
    /// Very long files stay plain, since one huge styled text is slow.
    private func color(_ text: String, runs: [CodeRun]?) -> AttributedString {
        guard let runs, text.utf16.count <= 300_000 else { return AttributedString(text) }
        return codeText(text, runs: runs)
    }

    /// What the colored text is made from.
    private struct Coloring: Equatable {
        var content: FileContent?
        var runs: [CodeRun]?
        var text: String? { if case .text(let text)? = content { text } else { nil } }
    }

    private struct Revision: Equatable {
        var connected: Bool
        var revision: Int?
    }
}

private extension View {
    /// Keeps the Mac sending this project's file list while the view shows.
    func watchingFiles(of projectID: UUID) -> some View {
        modifier(WatchingFiles(projectID: projectID))
    }
}

private struct WatchingFiles: ViewModifier {
    @Environment(CompanionClient.self) private var client
    let projectID: UUID

    func body(content: Content) -> some View {
        content.task {
            client.watchFiles(projectID: projectID)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            client.unwatchFiles(projectID: projectID)
        }
    }
}
