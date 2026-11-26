import AppKit
import BenchKit
import SwiftUI

/// The ⌘K command bar: a search field floating over the window that goes to
/// any project, worktree, or paired Mac's project, and runs the menu's
/// actions. Projects folded away under Inactive are as easy to reach as
/// the ones at the top of the sidebar.
struct CommandBarOverlay: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack(alignment: .top) {
            // Click anywhere outside the bar to put it away.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.showsCommandBar = false }
            CommandBarView()
                .frame(width: 560)
                .padding(.top, 72)
        }
        .transition(.opacity)
    }
}

/// One row: a project on this Mac, a project on a paired Mac, or an action.
private enum CommandBarItem: Identifiable {
    case project(Project)
    case remote(ActiveEntry)
    case action(CommandBarAction)

    var id: String {
        switch self {
        case .project(let project): "project:\(project.id.uuidString)"
        case .remote(let entry): "remote:\(entry.id)"
        case .action(let action): "action:\(action.id)"
        }
    }
}

private struct CommandBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(ProjectIcons.self) private var icons
    @Environment(RemoteMacs.self) private var macs
    @Environment(RepoMonitors.self) private var monitors
    @Environment(PullRequests.self) private var pullRequests
    #if DEBUG
    @State private var query = ProcessInfo.processInfo.environment["BENCH_SNAPSHOT_COMMAND_BAR"] ?? ""
    #else
    @State private var query = ""
    #endif
    @State private var selectedID: String?

    /// About twelve rows show before the list scrolls.
    private static let rowHeight: CGFloat = 38
    private static let maxVisibleRows = 12

    var body: some View {
        let items = rankedItems
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.ui(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                CommandBarField(text: $query, placeholder: "Go to a project or run an action",
                                onMove: { move($0, in: items) },
                                onSubmit: { pick(selected(in: items)) },
                                onCancel: { store.showsCommandBar = false })
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    // A 20pt target that takes the mark's own room in the row.
                    .padding(-2)
                    .help("Clear")
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            Divider()
            if items.isEmpty {
                Text("Nothing matches \u{201C}\(query)\u{201D}")
                    .font(.ui(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                row(item, isSelected: item.id == selected(in: items)?.id)
                                    .id(item.id)
                                    .onTapGesture { pick(item) }
                                    .onHover { if $0 { selectedID = item.id } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: CGFloat(min(items.count, Self.maxVisibleRows)) * (Self.rowHeight + 2) + 12)
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        // Glass, like Spotlight, frosted toward the window's color so the
        // results stay easy to read over busy text.
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.55)),
                     in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onChange(of: query) { _, _ in selectedID = nil }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ item: CommandBarItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            switch item {
            case .project(let project):
                if project.isWorktree {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.ui(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                } else {
                    ProjectIcon(project: project, image: icons.image(for: project), size: 22)
                        .task { icons.reload(project) }
                }
                Text(name(of: project))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name(of: project))
                Spacer(minLength: 8)
                if !store.isActive(project.id) {
                    tag("Inactive")
                }
                ActivityIndicator(activity: terminals.activity(for: project), size: 11)
            case .remote(let entry):
                // The sidebar's icon and activity mark once that Mac has
                // answered; a plain computer until then.
                let client = macs.client(for: entry.host ?? "")
                let project = client?.snapshot?.projects.first { $0.id == entry.projectID }
                if let project {
                    CompanionProjectIcon(project: project, icon: client?.icons[project.parentID ?? project.id], size: 22)
                } else {
                    Image(systemName: "desktopcomputer")
                        .font(.ui(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                Text(project?.name ?? entry.name ?? "Project")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project?.name ?? entry.name ?? "Project")
                Spacer(minLength: 8)
                tag(macs.name(for: entry.host ?? ""))
                if let project {
                    ActivityIndicator(activity: project.activity.tabActivity, size: 11)
                }
            case .action(let action):
                Image(systemName: action.symbol)
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                Text(action.title)
                    .lineLimit(1)
                    .help(action.title)
                Spacer(minLength: 8)
                if let shortcut = action.shortcut {
                    Text(shortcut)
                        .font(.ui(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.ui(size: 13, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.16) : .clear)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The name the sidebar gives it: a worktree goes by its branch.
    private func name(of project: Project) -> String {
        guard project.isWorktree else { return project.name }
        return monitors.monitor(for: project).snapshot?.branch ?? project.branch ?? project.name
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.ui(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    // MARK: Ranking

    /// Projects in the sidebar's order (Active, then Inactive by recent use)
    /// with worktrees under their parent and the current project last,
    /// paired Macs' Active projects, then the actions. Typing re-ranks them
    /// all by how well they match.
    private var rankedItems: [CommandBarItem] {
        var items: [CommandBarItem] = []
        var listed = Set<UUID>()
        var projects: [Project] = []
        let activeLocal = store.listedEntries.filter { $0.host == nil }.compactMap { store.project($0.projectID) }
        let inactive = store.inactiveProjects.sorted {
            (store.lastUsed[$0.id] ?? .distantPast) > (store.lastUsed[$1.id] ?? .distantPast)
        }
        for project in activeLocal + inactive where !listed.contains(project.id) {
            listed.insert(project.id)
            projects.append(project)
            projects.append(contentsOf: store.worktrees(of: project.id))
        }
        // The project you're already in goes last while the field is empty.
        if query.isEmpty, !store.showsPage, store.selectedRemote == nil,
           let current = store.selectedProjectID, let index = projects.firstIndex(where: { $0.id == current }) {
            projects.append(projects.remove(at: index))
        }
        items.append(contentsOf: projects.map(CommandBarItem.project))
        items.append(contentsOf: store.listedEntries.filter { $0.host != nil }.map(CommandBarItem.remote))
        items.append(contentsOf: AppActions(store: store, terminals: terminals)
            .commandBarActions(pullRequests: pullRequests, macs: macs).map(CommandBarItem.action))

        let candidates = items.map { item -> CommandBarMatcher.Candidate<String> in
            switch item {
            case .project(let project):
                var keywords = [project.repoName, project.folderName]
                if let branch = project.branch { keywords.append(branch) }
                return .init(id: item.id, keywords: keywords, recency: store.lastUsed[store.rootID(of: project.id)], isProject: true)
            case .remote(let entry):
                return .init(id: item.id, keywords: [entry.name ?? "", macs.name(for: entry.host ?? "")], isProject: true)
            case .action(let action):
                return .init(id: item.id, keywords: [action.title] + action.keywords)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return CommandBarMatcher.rank(candidates, query: query).compactMap { byID[$0] }
    }

    // MARK: Selection

    private func selected(in items: [CommandBarItem]) -> CommandBarItem? {
        items.first { $0.id == selectedID } ?? items.first
    }

    private func move(_ offset: Int, in items: [CommandBarItem]) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selected(in: items)?.id } ?? 0
        selectedID = items[(current + offset + items.count) % items.count].id
    }

    private func pick(_ item: CommandBarItem?) {
        guard let item else { return }
        store.showsCommandBar = false
        switch item {
        case .project(let project):
            store.openFromCommandBar(project.id)
        case .remote(let entry):
            if let host = entry.host {
                store.selectedRemote = RemoteSelection(host: host, projectID: entry.projectID)
            }
        case .action(let action):
            action.run()
        }
    }
}

/// The bar's text field. An AppKit field so it can take focus away from a
/// terminal the moment the bar opens, hand it back when the bar closes, and
/// turn the arrow keys, return, and escape into moves, a pick, and a close.
private struct CommandBarField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ field: FocusingTextField, coordinator: Coordinator) {
        field.giveFocusBack()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandBarField
        init(parent: CommandBarField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }

    /// Takes focus as soon as it's in a window and remembers who had it.
    final class FocusingTextField: NSTextField {
        private weak var previousResponder: NSResponder?
        private weak var previousWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            previousWindow = window
            // The field editor stands in for whatever view was typing.
            let responder = window.firstResponder
            previousResponder = (responder as? NSTextView)?.delegate as? NSResponder ?? responder
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                window.makeFirstResponder(self)
            }
        }

        func giveFocusBack() {
            guard let window = previousWindow, let previousResponder, previousResponder !== self else { return }
            window.makeFirstResponder(previousResponder)
        }
    }
}
