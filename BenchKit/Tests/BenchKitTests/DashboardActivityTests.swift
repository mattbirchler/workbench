import Foundation
import Testing
@testable import BenchKit

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func session(_ activity: ActivityKind, since: TimeInterval? = nil, stopped: TimeInterval? = nil,
                     action: String? = nil, question: String? = nil) -> CompanionSession {
    CompanionSession(id: UUID(), title: "Claude", activity: activity, action: action, question: question,
                     stoppedAt: stopped.map { now.addingTimeInterval(-$0) }, since: since.map { now.addingTimeInterval(-$0) })
}

private func project(_ name: String, _ sessions: [CompanionSession], pr: CompanionPullRequest? = nil) -> CompanionProject {
    CompanionProject(id: UUID(), name: name, repoName: name, path: "/tmp/\(name)", activity: .idle, pullRequest: pr, sessions: sessions)
}

@Test func dashboardPutsWhatNeedsYouFirst() {
    let projects = [
        project("Bench", [session(.working, since: 250, action: "Editing BenchWidgets.swift")]),
        project("birchfeed", [session(.waiting, since: 70, question: "Allow npm run db:migrate?")]),
        project("pace-api", [session(.remoteWorking, since: 730)]),
        project("notes", [session(.idle)]),
    ]
    let state = DashboardActivity.state(for: projects, now: now)
    #expect(state.rows.map(\.project) == ["birchfeed", "pace-api", "Bench"])
    #expect(state.rows.first?.text == "Allow npm run db:migrate?")
    #expect((state.working, state.waiting, state.done, state.more) == (2, 1, 0, 0))
}

@Test func dashboardCountsStepsOnWorkingRows() throws {
    var busy = session(.working, since: 30, action: "Editing")
    busy.checklist = [ChecklistItem(id: "1", title: "One", status: .completed), ChecklistItem(id: "2", title: "Two", status: .inProgress),
                      ChecklistItem(id: "3", title: "Three", status: .pending)]
    let state = DashboardActivity.state(for: [project("Bench", [busy]), project("notes", [session(.working, since: 5)])], now: now)
    #expect(state.rows.map(\.stepsDone) == [1, nil])
    #expect(state.rows.map(\.stepsTotal) == [3, nil])
    // An older phone build decodes the same state without the counts.
    struct OldRow: Decodable { var id: UUID; var project: String; var activity: String; var text: String }
    struct OldState: Decodable { var rows: [OldRow] }
    let old = try JSONDecoder().decode(OldState.self, from: JSONEncoder().encode(state))
    #expect(old.rows.count == 2)
}

@Test func dashboardDropsOldFinishedSessionsAndCapsRows() {
    let pr = CompanionPullRequest(number: 42, title: "Lap chart", url: URL(string: "https://example.com")!, state: .open,
                                  checks: .passing, passedCount: 8, totalCount: 8, failingNames: [])
    let projects = [
        project("Pace", [session(.done, stopped: 60)], pr: pr),
        project("old", [session(.done, stopped: 3 * 60 * 60)]),
        project("a", [session(.working, since: 1)]),
        project("b", [session(.working, since: 2)]),
        project("c", [session(.working, since: 3)]),
        project("d", [session(.working, since: 4)]),
    ]
    let state = DashboardActivity.state(for: projects, now: now)
    #expect(state.rows.count == DashboardActivity.maxRows)
    #expect(state.more == 1)
    #expect(state.done == 1)
    #expect(!state.rows.contains { $0.project == "old" })
}

@Test func dashboardPayloadDecodesAsActivityKitWould() throws {
    let state = DashboardActivity.state(for: [project("Bench", [session(.working, since: 5, action: "Building")])], now: now)
    let payload = try DashboardPayload.update(state, alert: nil, now: now)
    let aps = try #require(payload["aps"] as? [String: Any])
    let data = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
    #expect(try JSONDecoder().decode(DashboardAttributes.ContentState.self, from: data) == state)
}

@Test func widgetSnapshotKnowsWhenItLooksTheSameAndWhenItIsOld() {
    let state = DashboardActivity.state(for: [project("Bench", [session(.working, since: 5, action: "Building")])], now: now)
    let first = WidgetSnapshot(macName: "Mac Studio", state: state, savedAt: now)
    var later = first
    later.savedAt = now.addingTimeInterval(90)
    #expect(first.shows(sameAs: later))
    later.state.waiting = 1
    #expect(!first.shows(sameAs: later))
    #expect(!first.isStale(at: now.addingTimeInterval(60)))
    #expect(first.isStale(at: now.addingTimeInterval(WidgetSnapshot.staleAfter + 60)))
}
