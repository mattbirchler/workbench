import AppKit
import BenchKit
import Foundation
import Observation

/// Text files on other Macs open for editing here. Like `FileDrafts`, but
/// the disk is the other Mac's: what it sends is the file as it stands
/// there, and saving asks Workbench on that Mac to write it. Nothing is
/// sent until you save.
@MainActor
@Observable
final class RemoteFileDrafts {
    static let shared = RemoteFileDrafts()

    /// One file on one Mac.
    struct File: Hashable {
        var host: String
        var projectID: UUID
        var path: String
        var name: String { (path as NSString).lastPathComponent }
    }

    private(set) var drafts: [File: FileDraft] = [:]
    /// The text sent to be saved and not yet answered, by file.
    @ObservationIgnored private var sent: [File: String] = [:]
    /// Where the connections are. Set by `RemoteMacs`.
    @ObservationIgnored weak var macs: RemoteMacs?

    func draft(for file: File) -> FileDraft? { drafts[file] }

    func isEdited(_ file: File) -> Bool { drafts[file]?.isEdited ?? false }

    /// The files with unsaved edits.
    var edited: [File] { drafts.filter(\.value.isEdited).keys.sorted { $0.path < $1.path } }

    /// The other Mac sent the file again; nil when it isn't text any more.
    func fileRead(_ text: String?, for file: File) {
        guard var draft = drafts[file] else {
            if let text { drafts[file] = FileDraft(text) }
            return
        }
        draft.diskRead(text)
        if text == nil, !draft.isEdited {
            drafts[file] = nil
        } else if draft != drafts[file] {
            drafts[file] = draft
        }
    }

    func edit(_ text: String, for file: File) { change(file) { $0.edit(text) } }
    func reload(_ file: File) { change(file) { $0.reload() } }
    func keepMine(_ file: File) { change(file) { $0.keepMine() } }

    /// Throws the edits away.
    func discard(_ file: File) {
        drafts[file] = nil
        sent[file] = nil
    }

    /// Lets go of a file no tab is showing, unless it has unsaved edits.
    func release(_ file: File) {
        if !isEdited(file) { discard(file) }
    }

    /// Lets go of everything from a Mac that was forgotten.
    func forget(host: String) {
        for file in drafts.keys where file.host == host { discard(file) }
    }

    private func change(_ file: File, _ body: (inout FileDraft) -> Void) {
        guard var draft = drafts[file] else { return }
        body(&draft)
        if draft != drafts[file] { drafts[file] = draft }
    }

    /// Sends the edits to the other Mac to write. The file stays "Edited"
    /// until that Mac says it's done.
    func save(_ file: File) {
        guard let draft = drafts[file], draft.isEdited else { return }
        let name = macs?.name(for: file.host) ?? "the other Mac"
        guard let client = macs?.client(for: file.host),
              client.saveFile(projectID: file.projectID, path: file.path, text: draft.text) else {
            explain(file, problem: "Not connected to \(name). Your changes are still here; save again once it's back.")
            return
        }
        sent[file] = draft.text
    }

    /// The other Mac answered a save.
    func saved(_ file: File, problem: String?) {
        guard let text = sent.removeValue(forKey: file) else { return }
        if let problem {
            explain(file, problem: problem)
        } else {
            change(file) { $0.didSave(text) }
        }
    }

    private func explain(_ file: File, problem: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't save \(file.name)"
        alert.informativeText = problem
        alert.runModal()
    }

    /// Asks before unsaved edits are thrown away, when their tab closes or
    /// the app quits. A save here takes a moment to come back, so the
    /// choice is to go back and save, or to lose them. False means stop.
    func confirmLosing(_ files: [File], quitting: Bool = false) -> Bool {
        let unsaved = files.filter(isEdited)
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let place = macs?.name(for: unsaved[0].host) ?? "another Mac"
        if unsaved.count == 1 {
            alert.messageText = "Discard your changes to \(unsaved[0].name)?"
            alert.informativeText = "They haven't been saved to \(place)."
        } else {
            alert.messageText = "Discard your changes to \(unsaved.count) files on other Macs?"
            alert.informativeText = "Your changes to " + unsaved.map(\.name).formatted(.list(type: .and))
                + " haven't been saved."
        }
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.addButton(withTitle: quitting ? "Don't Quit" : "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        unsaved.forEach(discard)
        return true
    }
}
