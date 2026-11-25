import BenchKit
import SwiftUI

/// Picks a folder on another Mac to add as a project there. This Mac's
/// folder picker can't see that Mac's disk, so Workbench on that Mac lists
/// its folders one at a time.
struct AddRemoteProjectSheet: View {
    @Environment(RemoteMacs.self) private var macs
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let host: String
    /// The path in the field, which follows the folder showing until it's typed in.
    @State private var path = ""
    @State private var isAdding = false

    private var client: CompanionClient? { macs.client(for: host) }
    private var listing: FolderListing? { client?.folder }
    private var name: String { macs.name(for: host) }
    private var isConnected: Bool { client?.status == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Project on \(name)")
                    .font(.ui(size: 15, weight: .semibold))
                Text("Pick a folder on \(name), or type its path.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button {
                    if let parent = listing?.parent { open(parent) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(listing?.parent == nil)
                .help("Go to the folder above")
                .accessibilityLabel("Go to the folder above")
                TextField("~/Code/project", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(size: 12, design: .monospaced))
                    .onSubmit { open(path) }
            }
            folders
                .frame(height: 260)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            if let problem {
                Text(problem)
                    .font(.ui(size: 12))
                    .foregroundStyle(Theme.Status.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                if isAdding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add This Folder", action: add)
                    .buttonStyle(.prominent)
                    .disabled(!canAdd)
                    .help(listing.map { "Add \($0.path) as a project on \(name)" } ?? "")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            client?.clearAddProject()
            client?.browseFolder(nil)
        }
        .onDisappear { client?.clearAddProject() }
        .onChange(of: listing?.path) { _, new in
            if let new { path = new }
        }
        .onChange(of: client?.addedProject?.projectID) { _, id in
            // It's in that Mac's list now: show it.
            guard let id else { return }
            store.selectedRemote = RemoteSelection(host: host, projectID: id)
            dismiss()
        }
        .onChange(of: client?.addedProject?.problem) { _, problem in
            if problem != nil { isAdding = false }
        }
    }

    @ViewBuilder
    private var folders: some View {
        if let listing {
            if listing.folders.isEmpty {
                Text(listing.problem == nil ? "No folders in here." : "")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(listing.folders, id: \.self) { folder in
                            Button {
                                open((listing.path as NSString).appendingPathComponent(folder))
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(folder)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.ui(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .font(.ui(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .id(listing.path)
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Why the folder can't be shown or added, if it can't.
    private var problem: String? {
        if !isConnected { return "Not connected to \(name)." }
        return client?.addedProject?.problem ?? listing?.problem
    }

    private var canAdd: Bool {
        guard isConnected, !isAdding, let listing else { return false }
        return listing.problem == nil
    }

    private func open(_ folder: String) {
        client?.browseFolder(folder)
    }

    private func add() {
        guard let listing else { return }
        isAdding = true
        client?.addProject(path: listing.path)
    }
}
