import Foundation
import Testing
@testable import BenchKit

private let sessionID = UUID()
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func project(_ activity: ActivityKind, summary: String? = nil, pullRequest: CompanionPullRequest? = nil) -> CompanionProject {
    CompanionProject(id: UUID(uuidString: "D3E00000-0000-4000-8000-000000000001")!, name: "Recipes", repoName: "recipes",
                     path: "~/Code/recipes", activity: activity, pullRequest: pullRequest,
                     sessions: [CompanionSession(id: sessionID, title: "Claude", activity: activity, summary: summary, canReply: true)])
}

private func dirty(unpushed: Int = 0, upstream: String? = "origin/feat/x") -> ChangesSnapshot {
    ChangesSnapshot(branch: "feat/x", baseRef: "origin/main",
                    unstaged: [FileChange(path: "a.swift", kind: .modified, additions: 3, deletions: 1, section: .unstaged)],
                    upstream: upstream, unpushed: unpushed, branches: ["main"])
}

private func committed(unpushed: Int = 1, upstream: String? = "origin/feat/x") -> ChangesSnapshot {
    ChangesSnapshot(branch: "feat/x", baseRef: "origin/main",
                    commits: [Commit(hash: "abc123", shortHash: "abc", subject: "Fix the export", body: "", author: "Claude", date: start)],
                    upstream: upstream, unpushed: unpushed, branches: ["main"])
}

private let pullRequest = CompanionPullRequest(number: 43, title: "Fix the export", url: URL(string: "https://github.com/a/b/pull/43")!,
                                               state: .open, checks: .pending, passedCount: 0, totalCount: 2, failingNames: [])

@Test func offersTheNextStepFirst() {
    #expect(ChangesAction.available(in: dirty(), pullRequest: nil) == [.commit, .pullRequest])
    #expect(ChangesAction.available(in: committed(), pullRequest: nil) == [.push, .pullRequest])
    #expect(ChangesAction.available(in: committed(unpushed: 0), pullRequest: pullRequest).isEmpty)
    // A branch that was never pushed has commits to push.
    #expect(ChangesAction.available(in: committed(unpushed: 0, upstream: nil), pullRequest: nil) == [.push, .pullRequest])
    // No pull request from the default branch to itself.
    let main = ChangesSnapshot(branch: "main", baseRef: "origin/main", unstaged: dirty().unstaged, upstream: "origin/main", unpushed: 0)
    #expect(ChangesAction.available(in: main, pullRequest: nil) == [.commit])
    #expect(ChangesAction.available(in: ChangesSnapshot(isRepository: false), pullRequest: nil).isEmpty)
}

@Test func promptsNameTheBranchesAndAreRecognized() {
    let prompt = ChangesAction.pullRequest.filledPrompt(for: dirty())
    #expect(prompt.contains("for feat/x against main"))
    #expect(!prompt.contains("{"))
    for action in ChangesAction.allCases {
        #expect(ChangesAction.matching(prompt: action.filledPrompt(for: dirty())) == action)
    }
    #expect(ChangesAction.matching(prompt: "Commit when you're done") == nil)
}

@Test func aCommitShowsUpAsCommitted() {
    var run = ChangesActionRun(action: .commit, sessionID: sessionID, project: project(.done), changes: dirty(), now: start)
    // The Mac's list is a beat behind: still done from before.
    run.update(project: project(.done), changes: dirty(), now: start.addingTimeInterval(1))
    #expect(run.phase == .running)
    #expect(!run.isSettling)
    run.update(project: project(.working), changes: dirty(), now: start.addingTimeInterval(2))
    #expect(run.phase == .running)
    run.update(project: project(.working), changes: committed(), now: start.addingTimeInterval(5))
    #expect(run.phase == .succeeded(.committed(subject: "Fix the export")))
    #expect(run.nextCheck == nil)
}

@Test func stoppingWithoutCommittingFailsOnceTheRepoHasBeenRead() {
    var run = ChangesActionRun(action: .commit, sessionID: sessionID, project: project(.done), changes: dirty(), now: start)
    run.update(project: project(.working), changes: dirty(), now: start.addingTimeInterval(2))
    let stopped = project(.done, summary: "A pre-commit hook failed: lint found 2 errors.\nI left the changes as they were.")
    run.update(project: stopped, changes: dirty(), now: start.addingTimeInterval(6))
    #expect(run.phase == .running)
    #expect(run.isSettling)
    run.update(project: stopped, changes: dirty(), now: start.addingTimeInterval(17))
    #expect(run.phase == .failed("Claude stopped without committing. It said: A pre-commit hook failed: lint found 2 errors."))
}

@Test func aQuestionMidwayNeedsYouThenCarriesOn() {
    var run = ChangesActionRun(action: .push, sessionID: sessionID, project: project(.done), changes: committed(), now: start)
    run.update(project: project(.waiting), changes: committed(), now: start.addingTimeInterval(3))
    #expect(run.phase == .needsYou)
    run.update(project: project(.working), changes: committed(), now: start.addingTimeInterval(9))
    #expect(run.phase == .running)
    run.update(project: project(.done), changes: committed(unpushed: 0), now: start.addingTimeInterval(12))
    #expect(run.phase == .succeeded(.pushed(upstream: "origin/feat/x")))
}

@Test func anOlderMacCantSayWhetherThePushWentThrough() {
    let old = ChangesSnapshot(branch: "feat/x", baseRef: "origin/main", commits: committed().commits)
    var run = ChangesActionRun(action: .push, sessionID: sessionID, project: project(.done), changes: old, now: start)
    run.update(project: project(.working), changes: old, now: start.addingTimeInterval(2))
    run.update(project: project(.done, summary: "Pushed feat/x."), changes: old, now: start.addingTimeInterval(4))
    run.update(project: project(.done, summary: "Pushed feat/x."), changes: old, now: start.addingTimeInterval(15))
    #expect(run.phase == .succeeded(.finished(summary: "Pushed feat/x.")))
}

@Test func aPullRequestComesFromTheMacOrFromWhatTheAgentSaid() {
    var run = ChangesActionRun(action: .pullRequest, sessionID: sessionID, project: project(.done), changes: committed(), now: start)
    run.update(project: project(.working), changes: committed(), now: start.addingTimeInterval(2))
    run.update(project: project(.working, pullRequest: pullRequest), changes: committed(unpushed: 0), now: start.addingTimeInterval(20))
    #expect(run.phase == .succeeded(.pullRequest(number: 43, title: "Fix the export", url: pullRequest.url)))

    // The Mac looks for pull requests once a minute; the agent's link is sooner.
    var early = ChangesActionRun(action: .pullRequest, sessionID: sessionID, project: project(.done), changes: committed(), now: start)
    early.update(project: project(.working), changes: committed(), now: start.addingTimeInterval(2))
    early.update(project: project(.done, summary: "It's up: https://github.com/a/b/pull/57."), changes: committed(unpushed: 0),
                 now: start.addingTimeInterval(20))
    #expect(early.phase == .succeeded(.pullRequest(number: 57, title: nil, url: URL(string: "https://github.com/a/b/pull/57")!)))

    // One that was there already isn't this run's doing.
    var again = ChangesActionRun(action: .pullRequest, sessionID: sessionID, project: project(.done, pullRequest: pullRequest),
                                 changes: committed(), now: start)
    again.update(project: project(.working, pullRequest: pullRequest), changes: committed(), now: start.addingTimeInterval(2))
    #expect(again.phase == .running)
}

@Test func sendAndStartProblemsFailStraightAway() {
    var run = ChangesActionRun(action: .commit, sessionID: sessionID, project: project(.done), changes: dirty(), now: start)
    run.update(project: project(.done), changes: dirty(), sendProblem: "Claude isn't running in that tab.", now: start.addingTimeInterval(1))
    #expect(run.phase == .failed("Claude isn't running in that tab."))

    // No session yet: a new tab was asked for.
    let empty = CompanionProject(id: UUID(), name: "Blog", repoName: "blog", path: "~/blog", activity: .idle)
    var fresh = ChangesActionRun(action: .commit, sessionID: nil, project: empty, changes: dirty(), now: start)
    fresh.update(project: empty, changes: dirty(), now: start.addingTimeInterval(1))
    #expect(fresh.phase == .running)
    var opened = empty
    opened.sessions = [CompanionSession(id: sessionID, title: "Claude", activity: .working, canReply: true)]
    fresh.update(project: opened, changes: dirty(), now: start.addingTimeInterval(3))
    #expect(fresh.sessionID == sessionID)

    var refused = ChangesActionRun(action: .commit, sessionID: nil, project: empty, changes: dirty(), now: start)
    refused.update(project: empty, changes: dirty(), startProblem: "Couldn't open a tab.", now: start.addingTimeInterval(1))
    #expect(refused.phase == .failed("Couldn't open a tab."))
}

/// A Mac from before the counts leaves them out; a phone from before
/// them skips the extra keys.
@Test func uncommittedCountsAreOptionalOnTheWire() throws {
    let sent = CompanionProject(id: UUID(), name: "Blog", repoName: "blog", path: "~/blog", activity: .idle,
                                uncommittedAdditions: 124, uncommittedDeletions: 18)
    let data = try CompanionCoding.encoder.encode(sent)
    #expect(try CompanionCoding.decoder.decode(CompanionProject.self, from: data) == sent)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["uncommittedAdditions"] = nil
    object["uncommittedDeletions"] = nil
    let old = try CompanionCoding.decoder.decode(CompanionProject.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.uncommittedAdditions == nil)
    #expect(old.uncommittedDeletions == nil)
}
