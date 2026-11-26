import Foundation
import Testing
@testable import Bench

/// ⇧⌘G and the ⌘K bar's "Open Pull Request" come from the same lookups in
/// AppActions, so they agree: the URL comes from the project on screen
/// (or its Mac when it's on another one), and the command bar lists the
/// action only when there's a pull request to open.
@MainActor
struct OpenPullRequestTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-open-pr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pr(_ number: Int) -> PullRequestInfo {
        PullRequestInfo(number: number, title: "Thing", url: URL(string: "https://github.com/o/r/pull/\(number)")!,
                        state: .open, checks: .none)
    }

    @Test func showsNothingWithoutAPullRequest() throws {
        let store = AppStore(fileURL: try folder().appendingPathComponent("state.json"))
        guard case .added(let project) = store.addProject(path: try folder().path, source: .folderPicker) else {
            Issue.record("project wasn't added"); return
        }
        store.selectedProjectID = project.id

        let actions = AppActions(store: store, terminals: TerminalManager(store: store))
        let pullRequests = PullRequests()

        #expect(actions.pullRequestURL(in: pullRequests, macs: RemoteMacs()) == nil)
        #expect(actions.pullRequestTitle(in: pullRequests, macs: RemoteMacs()) == "Open Pull Request")
        #expect(!actions.commandBarActions(pullRequests: pullRequests, macs: RemoteMacs())
            .contains { $0.id == "open-pull-request" })
    }

    @Test func showsTheProjectOnScreenPullRequest() throws {
        let store = AppStore(fileURL: try folder().appendingPathComponent("state.json"))
        guard case .added(let project) = store.addProject(path: try folder().path, source: .folderPicker) else {
            Issue.record("project wasn't added"); return
        }
        store.selectedProjectID = project.id

        let actions = AppActions(store: store, terminals: TerminalManager(store: store))
        let pullRequests = PullRequests()
        pullRequests.setInfoForTesting(pr(11), for: project.id)

        #expect(actions.pullRequestURL(in: pullRequests, macs: RemoteMacs())?.absoluteString
            == "https://github.com/o/r/pull/11")
        #expect(actions.pullRequestTitle(in: pullRequests, macs: RemoteMacs()) == "Open Pull Request #11")

        let entry = try #require(actions.commandBarActions(pullRequests: pullRequests, macs: RemoteMacs())
            .first { $0.id == "open-pull-request" })
        #expect(entry.title == "Open Pull Request #11")
        #expect(entry.shortcut == "⇧⌘G")
        #expect(entry.keywords == ["pr", "github", "browser", "review"])
    }

    @Test func anotherProjectPullRequestDoesntShow() throws {
        let store = AppStore(fileURL: try folder().appendingPathComponent("state.json"))
        guard case .added(let first) = store.addProject(path: try folder().path, source: .folderPicker),
              case .added(let second) = store.addProject(path: try folder().path, source: .folderPicker) else {
            Issue.record("projects weren't added"); return
        }
        store.selectedProjectID = first.id

        let actions = AppActions(store: store, terminals: TerminalManager(store: store))
        let pullRequests = PullRequests()
        pullRequests.setInfoForTesting(pr(11), for: second.id)

        #expect(actions.pullRequestURL(in: pullRequests, macs: RemoteMacs()) == nil)
        #expect(!actions.commandBarActions(pullRequests: pullRequests, macs: RemoteMacs())
            .contains { $0.id == "open-pull-request" })
    }
}
