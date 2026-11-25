import Foundation

/// A text file open for editing: what's on disk, what's been typed, and
/// what to do when the two part ways. Claude edits the same files, so the
/// disk can change under unsaved edits; those edits are never thrown away
/// without being asked about.
public struct FileDraft: Equatable, Sendable {
    /// The disk changed while there were unsaved edits.
    public enum Conflict: Equatable, Sendable {
        /// The file has new contents, which Reload would take.
        case changed(String)
        /// The file was moved or deleted.
        case gone
    }

    /// The file as last read from or written to disk.
    public private(set) var saved: String
    /// The text in the editor.
    public private(set) var text: String
    public private(set) var conflict: Conflict?
    /// The file is gone and the edits were kept, so saving puts it back.
    private var keptAfterGone = false

    public init(_ disk: String) {
        saved = disk
        text = disk
    }

    /// Whether there's anything Save would write.
    public var isEdited: Bool { text != saved || keptAfterGone || conflict == .gone }

    /// The editor's text changed.
    public mutating func edit(_ new: String) {
        text = new
        // Undone back to where it started: nothing of yours is left to
        // keep, so the newer file on disk wins.
        if text == saved, case .changed(let disk) = conflict {
            saved = disk
            text = disk
            conflict = nil
        }
    }

    /// The file was read again; nil means it's no longer there. With no
    /// unsaved edits the editor follows the disk. With some, the edits
    /// stay and the difference becomes a conflict to settle.
    public mutating func diskRead(_ disk: String?) {
        guard let disk else {
            if isEdited, !keptAfterGone { conflict = .gone }
            return
        }
        keptAfterGone = false
        if conflict == .gone { conflict = nil }
        if disk == saved {
            // Back to what the edits were made against.
            conflict = nil
        } else if text == saved || disk == text {
            saved = disk
            text = disk
            conflict = nil
        } else {
            conflict = .changed(disk)
        }
    }

    /// Settles a conflict by taking the file on disk and dropping the edits.
    public mutating func reload() {
        guard case .changed(let disk) = conflict else { return }
        saved = disk
        text = disk
        conflict = nil
    }

    /// Settles a conflict by keeping the edits. They stay unsaved, and
    /// saving replaces what's on disk.
    public mutating func keepMine() {
        switch conflict {
        case .changed(let disk): saved = disk
        case .gone: keptAfterGone = true
        case nil: break
        }
        conflict = nil
    }

    /// The editor's text was written to disk.
    public mutating func didSave() {
        didSave(text)
    }

    /// `written` reached the disk a moment ago, as when another Mac saves
    /// it for us. Anything typed since is still unsaved.
    public mutating func didSave(_ written: String) {
        saved = written
        conflict = nil
        keptAfterGone = false
    }
}
