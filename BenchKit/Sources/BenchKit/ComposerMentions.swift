import Foundation

/// The word at the cursor that suggestions can finish: a slash command
/// (`/unslop`) or a file (`@Sources/App.swift`), anywhere in the message.
public struct ComposerToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case command, file }

    public var kind: Kind
    /// The whole word, from its `/` or `@` to the next space, so picking
    /// a suggestion with the cursor mid-word replaces all of it.
    public var range: Range<String.Index>
    /// What's typed between the `/` or `@` and the cursor.
    public var query: String
    /// True when the word is the whole message, the only place Claude Code
    /// runs a command itself rather than reading it as part of the message.
    public var isWholeMessage: Bool

    /// The word being typed at `caret` (a UTF-16 offset, as AppKit counts),
    /// or nil when it isn't a command or file. The `/` or `@` has to start
    /// a word, so an email address or a path like `src/app` doesn't count.
    public static func at(_ caret: Int, in text: String) -> ComposerToken? {
        let utf16 = text.utf16
        guard caret >= 0, caret <= utf16.count,
              let cursor = utf16.index(utf16.startIndex, offsetBy: caret, limitedBy: utf16.endIndex)?
                  .samePosition(in: text) else { return nil }
        var start = cursor
        while start > text.startIndex {
            let before = text.index(before: start)
            if text[before].isWhitespace { break }
            start = before
        }
        guard start < cursor else { return nil }
        let kind: Kind
        switch text[start] {
        case "/": kind = .command
        case "@": kind = .file
        default: return nil
        }
        let query = String(text[text.index(after: start)..<cursor])
        if kind == .command, query.contains("/") { return nil }
        var end = cursor
        while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
        let isWhole = start == text.startIndex && end == text.endIndex
        return ComposerToken(kind: kind, range: start..<end, query: query, isWholeMessage: isWhole)
    }
}

extension SlashCommand {
    /// Claude Code's own commands that do something to the session, like
    /// `/clear`, only work as the whole message. These read like a request
    /// to Claude, so they still mean something in the middle of one.
    private static let worksInASentence: Set<String> = ["code-review", "init", "loop", "schedule", "security-review", "simplify"]

    /// True for a command that still makes sense named mid-message, like a
    /// skill: "use /unslop on this".
    public var worksMidMessage: Bool {
        !opensInTerminal && (source != .builtIn || Self.worksInASentence.contains(name))
    }

    /// The commands matching `query`, what's typed after the slash. Names
    /// that start with it come first, then names with a word starting with
    /// it, then names that contain it.
    public static func matches(query: String, in commands: [SlashCommand], limit: Int = 8) -> [SlashCommand] {
        let query = query.lowercased()
        let sorted = commands.sorted { $0.name < $1.name }
        if query.isEmpty { return Array(sorted.prefix(limit)) }
        func words(_ name: String) -> [Substring] { name.lowercased().split(whereSeparator: { "-:_".contains($0) }) }
        let starts = sorted.filter { $0.name.lowercased().hasPrefix(query) }
        let wordStarts = sorted.filter { command in
            !starts.contains(command) && words(command.name).contains { $0.hasPrefix(query) }
        }
        let contains = sorted.filter { command in
            !starts.contains(command) && !wordStarts.contains(command) && command.name.lowercased().contains(query)
        }
        let found = starts + wordStarts + contains
        // An exact match on its own adds nothing to what's typed.
        if found.count == 1, found[0].name.lowercased() == query { return [] }
        return Array(found.prefix(limit))
    }
}

/// A file or folder you can name with `@`, as in Claude Code's prompt.
public struct FileMention: Hashable, Sendable, Identifiable {
    /// Its place in the project, like "Sources/App.swift" or "Sources".
    public var path: String
    public var isDirectory: Bool

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// The folder it's in, or "" at the top of the project.
    public var folder: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    /// What replaces the `@` word when it's picked. A folder ends in a
    /// slash and keeps suggesting what's inside it, and a file ends in a
    /// space so you can keep typing. A path with a space in it is quoted,
    /// the way Claude Code writes one.
    public var insertion: String {
        let shown = isDirectory ? path + "/" : path
        let quoted = shown.contains(" ") ? "\"\(shown)\"" : shown
        return "@" + quoted + (isDirectory ? "" : " ")
    }

    /// Every file in a listing, plus the folders they're in.
    public static func all(from paths: [String]) -> [FileMention] {
        var folders = Set<String>()
        for path in paths {
            var slash = path.firstIndex(of: "/")
            while let found = slash {
                folders.insert(String(path[..<found]))
                slash = path[path.index(after: found)...].firstIndex(of: "/")
            }
        }
        return folders.map { FileMention(path: $0, isDirectory: true) } + paths.map { FileMention(path: $0, isDirectory: false) }
    }

    /// The files and folders matching `query`, what's typed after the `@`.
    /// With nothing typed, what's at the top of the project. With a slash,
    /// paths that start with it, nearest first. Otherwise names that start
    /// with it, then names that contain it, then paths that contain it.
    /// Shorter paths win a tie, since they're usually the one you mean.
    public static func matches(query: String, in mentions: [FileMention], limit: Int = 8) -> [FileMention] {
        let query = query.lowercased()
        func order(_ a: FileMention, _ b: FileMention) -> Bool {
            let depthA = a.path.count(where: { $0 == "/" }), depthB = b.path.count(where: { $0 == "/" })
            if depthA != depthB { return depthA < depthB }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        if query.isEmpty {
            return Array(mentions.filter { !$0.path.contains("/") }.sorted(by: order).prefix(limit))
        }
        var tiers: [[FileMention]] = [[], [], []]
        for mention in mentions {
            let path = mention.path.lowercased()
            if query.contains("/") {
                let shown = mention.isDirectory ? path + "/" : path
                if shown.hasPrefix(query) {
                    // Typing "Sources/" shouldn't offer "Sources/" itself.
                    if shown != query { tiers[0].append(mention) }
                } else if path.contains(query) {
                    tiers[2].append(mention)
                }
                continue
            }
            let name = mention.name.lowercased()
            if name.hasPrefix(query) { tiers[0].append(mention) }
            else if name.contains(query) { tiers[1].append(mention) }
            else if path.contains(query) { tiers[2].append(mention) }
        }
        var found: [FileMention] = []
        for tier in tiers {
            found += tier.sorted(by: order).prefix(limit - found.count)
            if found.count >= limit { break }
        }
        return found
    }
}

/// The folder an `@` path outside the project points into, like `~/Notes/`
/// or `../app/`. The project's listing doesn't hold these, so Claude Code's
/// picker, and this one, list the folder itself. It's any path starting
/// `~/`, `../`, `./` or `/`.
public struct MentionFolder: Equatable, Sendable {
    /// The folder as typed, up to its last slash: "~/", "../app/", "/tmp/".
    public var typed: String
    /// What's typed after it: the start of a name in the folder.
    public var name: String

    /// Nil for a path in the project, like "Sources/Ap".
    public init?(query: String) {
        guard ["~/", "../", "./", "/"].contains(where: query.hasPrefix),
              let slash = query.lastIndex(of: "/") else { return nil }
        typed = String(query[...slash])
        name = String(query[query.index(after: slash)...])
    }

    /// The folder's full path. One starting with `.` counts from `root`,
    /// the folder Claude Code runs in.
    public func path(root: String?, home: String = NSHomeDirectory()) -> String? {
        if typed.hasPrefix("/") { return typed }
        if typed.hasPrefix("~/") { return home + typed.dropFirst() }
        guard let root else { return nil }
        return (root.hasSuffix("/") ? root : root + "/") + typed
    }

    /// The things in the folder matching the name typed, as mentions to
    /// fill in. `entries` is what's in it, each named on its own. Names
    /// that start with what's typed come first, then names that contain
    /// it. Hidden ones show once the name typed starts with a dot.
    public func matches(in entries: [FileMention], limit: Int = 8) -> [FileMention] {
        let name = name.lowercased()
        var starts: [FileMention] = [], contains: [FileMention] = []
        for entry in entries where name.hasPrefix(".") || !entry.path.hasPrefix(".") {
            let entryName = entry.path.lowercased()
            // Typing all of "README.md" shouldn't offer "README.md" itself.
            if entryName == name, !entry.isDirectory { continue }
            if entryName.hasPrefix(name) { starts.append(entry) }
            else if entryName.contains(name) { contains.append(entry) }
        }
        let order: (FileMention, FileMention) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (starts.sorted(by: order) + contains.sorted(by: order))
            .prefix(limit)
            .map { FileMention(path: typed + $0.path, isDirectory: $0.isDirectory) }
    }
}

extension ComposerToken {
    /// The message as it should be typed into Claude Code before pressing
    /// Return. A message that ends on a file mention (`@~/Work/app/`)
    /// leaves Claude Code's file picker open, so Return goes to the picker
    /// and the message never sends. A space after the mention closes the
    /// picker; Claude Code trims it off when it sends.
    public static func readyToSend(_ text: String) -> String {
        guard at(text.utf16.count, in: text)?.kind == .file else { return text }
        return text + " "
    }
}
