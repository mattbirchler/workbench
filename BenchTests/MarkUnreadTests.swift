import Foundation
import Testing
@testable import Bench

/// Mark as Unread (BIR-589): the done mark you put back stays until you
/// open the tab, and is saved so it comes back after a relaunch.
@MainActor
@Suite(.serialized)
struct MarkUnreadTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-unread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The test host shares the real app's defaults, so put the key back.
    private func withSavedKey(_ body: () throws -> Void) rethrows {
        let key = TerminalManager.markedUnreadKey
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        try body()
    }

    private var savedIDs: [String] {
        UserDefaults.standard.stringArray(forKey: TerminalManager.markedUnreadKey) ?? []
    }

    @Test func markStaysUntilTheTabIsOpenedAgain() throws {
        try withSavedKey {
            let store = AppStore(fileURL: try folder().appendingPathComponent("state.json"))
            guard case .added(let project) = store.addProject(path: try folder().path, source: .folderPicker) else {
                Issue.record("project wasn't added"); return
            }
            let tab = TabRecord(kind: .shell)
            let terminals = TerminalManager(store: store)
            let session = terminals.session(for: tab, in: project)
            defer { session.view.close() }

            session.markUnread()
            #expect(session.finishedUnseen)
            #expect(session.activity == .done)
            #expect(savedIDs == [tab.id.uuidString])

            // Coming back to the app doesn't count as opening it.
            session.markSeen()
            #expect(session.finishedUnseen)

            // A relaunch: a new manager making the tab's session again.
            let relaunched = TerminalManager(store: store)
            let again = relaunched.session(for: tab, in: project)
            defer { again.view.close() }
            #expect(again.markedUnread)
            #expect(again.activity == .done)

            // Opening the tab is the visit that clears the saved mark.
            again.isVisible = true
            #expect(!again.markedUnread)
            #expect(savedIDs.isEmpty)
        }
    }

    @Test func closingTheTabForgetsTheMark() throws {
        try withSavedKey {
            let store = AppStore(fileURL: try folder().appendingPathComponent("state.json"))
            guard case .added(let project) = store.addProject(path: try folder().path, source: .folderPicker) else {
                Issue.record("project wasn't added"); return
            }
            let tab = TabRecord(kind: .shell)
            let terminals = TerminalManager(store: store)
            terminals.session(for: tab, in: project).markUnread()
            #expect(savedIDs == [tab.id.uuidString])

            terminals.prune(keeping: [])
            #expect(savedIDs.isEmpty)
        }
    }
}
