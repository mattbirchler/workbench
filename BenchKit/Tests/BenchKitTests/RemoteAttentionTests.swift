import Foundation
import Testing
@testable import BenchKit

struct RemoteAttentionTests {
    private let projectID = UUID()
    private let sessionID = UUID()

    private func snapshot(_ activity: ActivityKind, question: String? = nil) -> ProjectsSnapshot {
        var session = CompanionSession(id: sessionID, title: "Claude", activity: activity)
        session.question = question
        let project = CompanionProject(id: projectID, name: "Recipes", repoName: "recipes", path: "/tmp/recipes",
                                       activity: activity, sessions: [session])
        return ProjectsSnapshot(projects: [project])
    }

    @Test func alreadyWaitingAtFirstSightIsNotNews() {
        var attention = RemoteAttention()
        let change = attention.update(snapshot(.waiting))
        #expect(change.started.isEmpty)
        #expect(change.ended.isEmpty)
    }

    @Test func startingToWaitAlertsOnce() {
        var attention = RemoteAttention()
        _ = attention.update(snapshot(.working))
        let change = attention.update(snapshot(.waiting, question: "Run npm test?"))
        #expect(change.started.map(\.sessionID) == [sessionID])
        #expect(change.started.first?.projectID == projectID)
        #expect(change.started.first?.project == "Recipes")
        #expect(change.started.first?.question == "Run npm test?")
        #expect(attention.update(snapshot(.waiting)).started.isEmpty)
    }

    @Test func answeringEndsIt() {
        var attention = RemoteAttention()
        _ = attention.update(snapshot(.working))
        _ = attention.update(snapshot(.waiting))
        let change = attention.update(snapshot(.working))
        #expect(change.started.isEmpty)
        #expect(change.ended == [sessionID])
    }

    @Test func aClosedSessionEndsToo() {
        var attention = RemoteAttention()
        _ = attention.update(snapshot(.working))
        _ = attention.update(snapshot(.waiting))
        #expect(attention.update(ProjectsSnapshot(projects: [])).ended == [sessionID])
    }
}
