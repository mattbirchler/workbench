import AppKit
import BenchKit
import Foundation

/// What ⌘1 to ⌘9 open: the sidebar's rows, top to bottom, the way they're
/// shown right now. That's this Mac's Pinned, Active, and Recent projects
/// (or, with another Mac's pill picked, that Mac's list), each followed by
/// its agents' worktrees. Inactive projects, and merged worktrees folded
/// into one line, don't get a number.
enum SidebarShortcuts {
    enum Target: Hashable {
        case local(UUID)
        case remote(host: String, projectID: UUID)
    }

    /// Every numbered row in order. Only the first nine have a shortcut.
    static func targets(store: AppStore, macs: RemoteMacs) -> [Target] {
        if let host = store.sidebarHost {
            return remoteTargets(host: host, macs: macs)
        }
        var targets: [Target] = []
        for entry in store.numberedEntries {
            if let host = entry.host {
                targets.append(.remote(host: host, projectID: entry.projectID))
                let worktrees = macs.client(for: host)?.snapshot?.worktrees(of: entry.projectID) ?? []
                targets += worktrees.map { .remote(host: host, projectID: $0.id) }
            } else {
                targets.append(.local(entry.projectID))
                // Folded merged worktrees aren't on screen, so they get no number.
                targets += store.sidebarWorktrees(of: entry.projectID).listed.map { .local($0.id) }
            }
        }
        return targets
    }

    /// Another Mac's list, leaving out its Inactive section like this Mac's.
    private static func remoteTargets(host: String, macs: RemoteMacs) -> [Target] {
        guard let snapshot = macs.client(for: host)?.snapshot else { return [] }
        return snapshot.topLevel
            .filter { $0.placement != .inactive }
            .flatMap { [$0] + snapshot.worktrees(of: $0.id) }
            .map { .remote(host: host, projectID: $0.id) }
    }

    /// Each of the first nine rows and its number, for the hints shown
    /// while Command is held.
    static func numbers(store: AppStore, macs: RemoteMacs) -> [Target: Int] {
        var numbers: [Target: Int] = [:]
        for (index, target) in targets(store: store, macs: macs).prefix(9).enumerated() {
            numbers[target] = index + 1
        }
        return numbers
    }

    /// Whether a key press leaves the hints showing: ⌘1 to ⌘9 and nothing
    /// else, so the numbers are still there for the next one. The number
    /// pad's digits count too.
    static func keepsHints(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.subtracting(.numericPad) == .command,
              let characters, characters.count == 1, let digit = Int(characters) else { return false }
        return (1...9).contains(digit)
    }

    /// Opens the row at `index` (0 for ⌘1).
    static func select(at index: Int, store: AppStore, macs: RemoteMacs) {
        let all = targets(store: store, macs: macs)
        guard all.indices.contains(index) else { return }
        switch all[index] {
        case .local(let id):
            store.selectedProjectID = id
        case .remote(let host, let id):
            store.selectedRemote = RemoteSelection(host: host, projectID: id)
        }
    }

    /// The row's name for its menu item: a worktree goes by its branch.
    static func title(of target: Target, store: AppStore, macs: RemoteMacs) -> String {
        switch target {
        case .local(let id):
            guard let project = store.project(id) else { return "Project" }
            return project.isWorktree ? (project.branch ?? project.name) : project.name
        case .remote(let host, let id):
            if let project = macs.client(for: host)?.snapshot?.projects.first(where: { $0.id == id }) {
                return project.isWorktree ? (project.branch ?? project.name) : project.name
            }
            return store.pins.first { $0.host == host && $0.projectID == id }?.name ?? "Project"
        }
    }
}
