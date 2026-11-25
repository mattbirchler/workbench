import Foundation

/// One folder on a Mac and the folders inside it, for picking a project
/// from another Mac.
public struct FolderListing: Codable, Sendable, Hashable {
    /// The folder's full path.
    public var path: String
    /// The folder above it, or nil at the top.
    public var parent: String?
    /// The names of the folders inside, in the order Finder lists them.
    public var folders: [String]
    /// Why it couldn't be read, when it couldn't.
    public var problem: String?

    public init(path: String, parent: String?, folders: [String], problem: String? = nil) {
        self.path = path
        self.parent = parent
        self.folders = folders
        self.problem = problem
    }

    /// The most folders sent for one listing.
    public static let limit = 2000

    /// `path` as a full path: nil and `~` are the home folder.
    public static func expand(_ path: String?, home: String) -> String {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + trimmed.dropFirst(1) }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    /// Reads a folder. Hidden folders and bundles like apps are left out:
    /// neither is somewhere a project lives.
    public static func read(_ path: String?, home: String) -> FolderListing {
        let full = URL(fileURLWithPath: expand(path, home: home)).standardizedFileURL
        let parent = full.path == "/" ? nil : full.deletingLastPathComponent().path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full.path, isDirectory: &isFolder), isFolder.boolValue else {
            return FolderListing(path: full.path, parent: parent, folders: [], problem: "There's no folder at that path.")
        }
        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: full, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])
            let names = items.filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return FolderListing(path: full.path, parent: parent, folders: Array(names.prefix(limit)))
        } catch {
            return FolderListing(path: full.path, parent: parent, folders: [], problem: error.localizedDescription)
        }
    }
}
