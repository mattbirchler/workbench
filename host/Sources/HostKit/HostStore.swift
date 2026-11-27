import Foundation

/// One agent session's place in a project. The session itself is the
/// terminal the host keeps for it (`HostSessions`).
public struct HostTab: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    /// A first message, until the session has started with it.
    public var prompt: String?
    /// A past conversation to pick back up when this tab first starts.
    public var resuming: String?

    public init(id: UUID = UUID(), title: String = "Claude", createdAt: Date = Date(), prompt: String? = nil, resuming: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.prompt = prompt
        self.resuming = resuming
    }
}

/// A folder on this machine that agents work in.
public struct HostProject: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: String
    /// A name you gave it. Nil shows its folder's name.
    public var customName: String?
    public var tabs: [HostTab]
    public var isPinned: Bool
    /// When a session here last started or was sent something.
    public var lastUsed: Date?
    /// Moved to Inactive by hand, until it's used again.
    public var setAside: Bool

    public init(id: UUID = UUID(), path: String, customName: String? = nil, tabs: [HostTab] = [],
                isPinned: Bool = false, lastUsed: Date? = nil, setAside: Bool = false) {
        self.id = id
        self.path = path
        self.customName = customName
        self.tabs = tabs
        self.isPinned = isPinned
        self.lastUsed = lastUsed
        self.setAside = setAside
    }

    public var folderName: String { URL(fileURLWithPath: path).lastPathComponent }
    public var name: String { customName ?? folderName }
}

/// The host's projects and their tabs, saved whenever they change.
///
/// Only touched on the main queue.
public final class HostStore {
    private struct Saved: Codable {
        var projects: [HostProject] = []
    }

    public private(set) var projects: [HostProject] = []
    private let file: URL

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let saved = try? decoder.decode(Saved.self, from: data) {
                projects = saved.projects
            } else {
                // Keep what couldn't be read rather than write over it.
                try? FileManager.default.copyItem(at: file, to: file.appendingPathExtension("unreadable"))
                hostLog("couldn't read \(file.path); starting with no projects (a copy is beside it)")
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Saved(projects: projects)) else { return }
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            hostLog("couldn't save projects: \(error.localizedDescription)")
        }
    }

    public func project(_ id: UUID) -> HostProject? { projects.first { $0.id == id } }

    public func project(holding tab: UUID) -> HostProject? {
        projects.first { $0.tabs.contains { $0.id == tab } }
    }

    public var allTabs: [HostTab] { projects.flatMap(\.tabs) }

    public enum AddResult: Equatable {
        case added(HostProject), alreadyHere(HostProject), notAFolder
    }

    @discardableResult
    public func addProject(path: String) -> AddResult {
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isFolder), isFolder.boolValue else { return .notAFolder }
        if let existing = projects.first(where: { $0.path == full }) { return .alreadyHere(existing) }
        let project = HostProject(path: full, lastUsed: Date())
        projects.append(project)
        save()
        return .added(project)
    }

    private func update(_ id: UUID, _ change: (inout HostProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[index])
        save()
    }

    public func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.customName = trimmed.isEmpty ? nil : trimmed }
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        update(id) { $0.isPinned = pinned }
    }

    public func setActive(_ id: UUID, _ active: Bool) {
        update(id) {
            $0.setAside = !active
            if active { $0.lastUsed = Date() }
        }
    }

    public func noteUsed(_ id: UUID) {
        update(id) {
            $0.lastUsed = Date()
            $0.setAside = false
        }
    }

    /// Puts the projects in this order. Ones not named keep their order
    /// after the ones that are.
    public func reorder(_ ids: [UUID]) {
        let named = ids.compactMap { id in projects.first { $0.id == id } }
        let rest = projects.filter { !ids.contains($0.id) }
        projects = named + rest
        save()
    }

    @discardableResult
    public func addTab(to projectID: UUID, title: String = "Claude", prompt: String? = nil, resuming: String? = nil) -> HostTab? {
        guard projects.contains(where: { $0.id == projectID }) else { return nil }
        let tab = HostTab(title: title, prompt: prompt, resuming: resuming)
        update(projectID) {
            $0.tabs.append(tab)
            $0.lastUsed = Date()
            $0.setAside = false
        }
        return tab
    }

    public func closeTab(_ tabID: UUID) {
        guard let project = project(holding: tabID) else { return }
        update(project.id) { $0.tabs.removeAll { $0.id == tabID } }
    }

    /// Once a tab has started, its first message and the conversation it
    /// was to resume are spent: from then on its own record says.
    public func markStarted(_ tabID: UUID) {
        guard let project = project(holding: tabID) else { return }
        update(project.id) {
            guard let index = $0.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            $0.tabs[index].prompt = nil
            $0.tabs[index].resuming = nil
        }
    }
}
