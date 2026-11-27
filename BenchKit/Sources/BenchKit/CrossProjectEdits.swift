import Foundation

/// Edits a Claude session made outside its own project's folder, matched
/// to the other projects Workbench knows. Asking Claude in one project to
/// make the same change in a sibling repo is common, and those edits
/// otherwise never show up where you're looking.
public enum CrossProjectEdits {
    /// A project's folder, for matching paths to it.
    public struct Root<ID: Hashable & Sendable>: Sendable, Equatable {
        public var id: ID
        public var path: String

        public init(id: ID, path: String) {
            self.id = id
            self.path = path
        }
    }

    /// Project folders made ready for matching many files against them.
    /// Matching happens while views draw, so it has to stay cheap however
    /// many projects there are: each folder is turned into bytes once, and
    /// a file is then compared with plain byte prefixes.
    public struct Index<ID: Hashable & Sendable>: Sendable {
        /// Each folder as UTF-8 ending in one slash, deepest first, so the
        /// first one that starts a file is the deepest that holds it.
        private let folders: [(id: ID, prefix: [UInt8])]
        /// The folders it was made from, to tell when it's out of date.
        public let roots: [Root<ID>]

        public init(_ roots: [Root<ID>]) {
            self.roots = roots
            folders = roots.map { root in
                var prefix = Array(root.path.precomposedStringWithCanonicalMapping.utf8)
                if prefix.last != UInt8(ascii: "/") { prefix.append(UInt8(ascii: "/")) }
                return (root.id, prefix)
            }
            .sorted { $0.prefix.count > $1.prefix.count }
        }

        /// The project a file lies in: the deepest folder that holds it, so
        /// a worktree kept inside its repo's folder wins over the repo. A
        /// folder whose name only starts the same way, like `Bench` and
        /// `Bench.worktrees`, doesn't hold it.
        public func owner(of file: String) -> ID? {
            // Paths are nearly always ASCII, which needs no normalizing.
            // Others are composed the same way the folders were, so an
            // accented name matches however it was typed.
            var file = file
            let isASCII = file.withUTF8 { $0.allSatisfy { $0 < 0x80 } }
            if !isASCII { file = file.precomposedStringWithCanonicalMapping }
            return file.withUTF8 { bytes in
                folders.first { folder in
                    bytes.count > folder.prefix.count && folder.prefix.withUnsafeBytes {
                        // An empty prefix has no address, and matches anything.
                        guard let prefix = $0.baseAddress, let path = bytes.baseAddress else { return $0.isEmpty }
                        return memcmp(prefix, path, $0.count) == 0
                    }
                }?.id
            }
        }

        /// The edited files that belong to other projects, by project, for
        /// a session whose own project is `home`. Files in no known
        /// project, or in the session's own project, are left out.
        public func byProject(_ files: [String: Date], home: ID) -> [ID: [String: Date]] {
            var result: [ID: [String: Date]] = [:]
            for (file, at) in files {
                guard let owner = owner(of: file), owner != home else { continue }
                result[owner, default: [:]][file] = at
            }
            return result
        }
    }

    /// The project a file lies in. For more than a file or two, make an
    /// `Index` once and ask it.
    public static func owner<ID>(of file: String, among roots: [Root<ID>]) -> ID? {
        Index(roots).owner(of: file)
    }

    /// The edited files that belong to other projects, by project.
    public static func byProject<ID>(_ files: [String: Date], home: ID, roots: [Root<ID>]) -> [ID: [String: Date]] {
        Index(roots).byProject(files, home: home)
    }

    /// The tools that change a file, and the input that names it.
    static let editTools: [String: String] = ["Edit": "file_path", "MultiEdit": "file_path", "Write": "file_path",
                                              "NotebookEdit": "notebook_path"]

    /// The files a transcript line's tool calls edit, with absolute paths.
    public static func editedFiles(in entry: [String: Any]) -> [String] {
        guard entry["type"] as? String == "assistant",
              let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String,
                  let key = editTools[name], let path = (block["input"] as? [String: Any])?[key] as? String,
                  path.hasPrefix("/") else { return nil }
            // A native string: one bridged from NSString is slow to compare.
            var standard = (path as NSString).standardizingPath
            standard.makeContiguousUTF8()
            return standard
        }
    }
}
