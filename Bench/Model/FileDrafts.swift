import AppKit
import BenchKit
import Foundation
import Observation

/// The files open for editing in file tabs, by file rather than by tab, so
/// unsaved edits survive switching tabs or flipping a tab to its diff and
/// back. Nothing is written until you save.
@MainActor
@Observable
final class FileDrafts {
    static let shared = FileDrafts()

    private(set) var drafts: [String: FileDraft] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func draft(for url: URL) -> FileDraft? { drafts[Self.key(url)] }

    func isEdited(_ url: URL) -> Bool { drafts[Self.key(url)]?.isEdited ?? false }

    /// The files with unsaved edits, by name.
    var edited: [URL] {
        drafts.filter(\.value.isEdited).keys.sorted().map { URL(fileURLWithPath: $0) }
    }

    /// The file was read from disk again; nil when it isn't text any more
    /// (gone, or no longer readable as text).
    func diskRead(_ text: String?, for url: URL) {
        let key = Self.key(url)
        guard var draft = drafts[key] else {
            if let text { drafts[key] = FileDraft(text) }
            return
        }
        draft.diskRead(text)
        if text == nil, !draft.isEdited {
            drafts[key] = nil
        } else if draft != drafts[key] {
            drafts[key] = draft
        }
    }

    func edit(_ text: String, for url: URL) {
        change(url) { $0.edit(text) }
    }

    func reload(_ url: URL) {
        change(url) { $0.reload() }
    }

    func keepMine(_ url: URL) {
        change(url) { $0.keepMine() }
    }

    /// Throws the edits away. The tab reads the file again.
    func discard(_ url: URL) {
        drafts[Self.key(url)] = nil
    }

    /// Lets go of a file no tab is showing, unless it has unsaved edits.
    func release(_ url: URL) {
        if !isEdited(url) { drafts[Self.key(url)] = nil }
    }

    private func change(_ url: URL, _ body: (inout FileDraft) -> Void) {
        let key = Self.key(url)
        guard var draft = drafts[key] else { return }
        body(&draft)
        if draft != drafts[key] { drafts[key] = draft }
    }

    /// Writes the edits to disk. The write goes to a temporary file that
    /// then takes the file's place, so nothing reading it (a build, Claude)
    /// sees half of it; the file keeps its permissions, and a symlink
    /// stays a symlink.
    func save(_ url: URL) throws {
        let key = Self.key(url)
        guard let draft = drafts[key], draft.isEdited else { return }
        try Self.write(draft.text, to: url)
        change(url) { $0.didSave() }
    }

    /// Writes text to a file, as `save` describes.
    nonisolated static func write(_ text: String, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .atomic)
        if let permissions {
            try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    /// Saves, and says why in an alert if it couldn't. False if it failed.
    @discardableResult
    func saveOrExplain(_ url: URL) -> Bool {
        do {
            try save(url)
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    /// Asks what to do with unsaved edits before their tabs close or the
    /// app quits. False means stop: it was cancelled, or a save failed.
    func confirmLosing(_ urls: [URL]) -> Bool {
        let unsaved = urls.filter(isEdited)
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        if unsaved.count == 1 {
            alert.messageText = "Save your changes to \(unsaved[0].lastPathComponent)?"
            alert.informativeText = "Your changes will be lost if you don't save them."
        } else {
            alert.messageText = "Save your changes to \(unsaved.count) files?"
            alert.informativeText = "Your changes to " + unsaved.map(\.lastPathComponent).formatted(.list(type: .and))
                + " will be lost if you don't save them."
        }
        alert.addButton(withTitle: unsaved.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for url in unsaved where !saveOrExplain(url) { return false }
            return true
        case .alertThirdButtonReturn:
            unsaved.forEach(discard)
            return true
        default:
            return false
        }
    }
}

extension Project {
    /// Where a tab's file is, if it's a file tab: a path inside the
    /// project, or a full path for a file outside it.
    func fileURL(of tab: TabRecord) -> URL? {
        guard tab.kind == .file, let path = tab.filePath else { return nil }
        return fileURL(forPath: path)
    }

    func fileURL(forPath path: String) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)).standardizedFileURL
    }
}
