import BenchKit
import SwiftUI

/// The Files sidebar for a project on another Mac.
struct RemoteFilesPanel: View {
    @Environment(RemoteMacs.self) private var macs
    let host: String
    let projectID: UUID

    private var client: CompanionClient? { macs.client(for: host) }
    private var key: String { RemoteMacs.key(host: host, projectID: projectID) }

    private var selectedPath: String? {
        if case .file(let path) = macs.openTabs[key] { return path }
        return nil
    }

    var body: some View {
        Group {
            if let client, client.status == .connected, !client.canBrowseFiles {
                ContentUnavailableView("Update Workbench There", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("Workbench on \(macs.name(for: host)) is too old to share its files. Update it and relaunch it."))
            } else {
                FileTreeList(
                    tree: client?.fileTrees[projectID],
                    expanded: Binding(
                        get: { macs.expandedFolders[key] ?? [] },
                        set: { macs.expandedFolders[key] = $0 }
                    ),
                    truncated: client?.truncatedFiles.contains(projectID) ?? false,
                    kinds: kinds,
                    selectedPath: selectedPath,
                    root: client?.snapshot?.projects.first { $0.id == projectID }?.path,
                    open: { macs.openFile(host: host, projectID: projectID, path: $0) }
                )
                .id(key)
            }
        }
        // The client asks again by itself after reconnecting.
        .task(id: key) {
            guard let client else { return }
            client.watchFiles(projectID: projectID)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            client.unwatchFiles(projectID: projectID)
        }
    }

    /// Changed files, when the changes list has been loaded.
    private var kinds: [String: ChangeKind] {
        guard let changes = client?.changes[projectID] else { return [:] }
        var kinds: [String: ChangeKind] = [:]
        for change in changes.againstBase + changes.staged + changes.unstaged { kinds[change.path] = change.kind }
        return kinds
    }
}

/// One file from the other Mac, reloading as it changes there.
struct RemoteFileView: View {
    @Environment(RemoteMacs.self) private var macs
    let host: String
    let projectID: UUID
    let path: String

    private var client: CompanionClient? { macs.client(for: host) }
    private var content: FileContent? { client?.fileContents["\(projectID):\(path)"] }

    private var drafts: RemoteFileDrafts { .shared }
    private var file: RemoteFileDrafts.File { .init(host: host, projectID: projectID, path: path) }
    private var draft: FileDraft? { drafts.draft(for: file) }
    private var isEdited: Bool { draft?.isEdited ?? false }

    /// What the tab shows: the text being edited, over what the other Mac
    /// last sent.
    private var shown: FileContent? {
        guard let draft else { return content }
        if case .text = content { return .text(draft.text) }
        // Unsaved edits to a file that has since gone stay on screen.
        return draft.isEdited ? .text(draft.text) : content
    }

    var body: some View {
        VStack(spacing: 0) {
            FileHeader(path: path, content: shown, badge: isEdited ? "Edited" : nil) {
                if isEdited {
                    Button("Save") { drafts.save(file) }
                        .controlSize(.small)
                        .help("Save your changes to \(macs.name(for: host)) (⌘S)")
                }
            } actions: {
                EmptyView()
            }
            Divider()
            if let conflict = draft?.conflict {
                FileConflictBanner(conflict: conflict, reload: { drafts.reload(file) }, discard: discardEdits,
                                   keepMine: { drafts.keepMine(file) })
                Divider()
            }
            // An older Workbench there can't save, so its files stay read only.
            FileContentView(content: shown, path: path,
                            editor: client?.canEditFiles == true ? FileEditor(edit: edit) : nil)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear { drafts.release(file) }
        .task(id: content) {
            // Nothing sent yet isn't the same as the file being gone.
            guard let content else { return }
            drafts.fileRead(Self.text(of: content), for: file)
        }
        .task {
            guard let client else { return }
            client.watchFiles(projectID: projectID)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            client.unwatchFiles(projectID: projectID)
        }
        .task(id: Revision(connected: client?.status == .connected, revision: client?.fileRevisions[projectID])) {
            guard client?.status == .connected else { return }
            client?.requestFile(projectID: projectID, path: path)
        }
    }

    private static func text(of content: FileContent?) -> String? {
        if case .text(let text) = content { return text }
        return nil
    }

    private func edit(_ text: String) {
        // The draft is let go of when the tab is switched away from.
        if draft == nil { drafts.fileRead(Self.text(of: content) ?? "", for: file) }
        drafts.edit(text, for: file)
    }

    /// Drops the edits and shows the file as it is on the other Mac.
    private func discardEdits() {
        drafts.discard(file)
        drafts.fileRead(Self.text(of: content), for: file)
    }

    private struct Revision: Equatable {
        var connected: Bool
        var revision: Int?
    }
}
