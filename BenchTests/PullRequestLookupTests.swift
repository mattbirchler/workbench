import Foundation
import Testing
@testable import Bench

/// The pull request lookup asks `gh pr list --head <branch>` so it also
/// finds pull requests opened from forks, and picks the branch's current
/// one out of the list.
struct PullRequestLookupTests {
    private func entry(_ number: Int, state: String, isDraft: Bool = false) -> [String: Any] {
        ["number": number, "title": "Thing", "url": "https://github.com/o/r/pull/\(number)",
         "state": state, "isDraft": isDraft]
    }

    @Test func picksTheOpenPullRequest() throws {
        let pr = try #require(PullRequests.pick(from: [entry(8, state: "CLOSED"), entry(9, state: "OPEN")]))
        #expect(pr.number == 9)
        #expect(pr.state == .open)
    }

    @Test func fallsBackToTheLatestOfAnyState() throws {
        // A merged branch's last pull request is what merge detection needs.
        let pr = try #require(PullRequests.pick(from: [entry(8, state: "MERGED"), entry(7, state: "CLOSED")]))
        #expect(pr.number == 8)
        #expect(pr.state == .merged)
    }

    @Test func nothingToPick() {
        #expect(PullRequests.pick(from: []) == nil)
        #expect(PullRequests.pick(from: [["nope": 1]]) == nil)
    }

    @Test func parsesForkPullRequestFields() throws {
        let json: [String: Any] = [
            "number": 11, "title": "Shortcut", "url": "https://github.com/mattbirchler/workbench/pull/11",
            "state": "OPEN", "isDraft": true, "headRefOid": "abc123",
            "mergeCommit": ["oid": "def456"], "mergedAt": "2026-11-25T12:00:00Z",
            "statusCheckRollup": [["name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"]],
        ]
        let pr = try #require(PullRequests.parse(from: json))
        #expect(pr.state == .draft)
        #expect(pr.headCommit == "abc123")
        #expect(pr.mergeCommit == "def456")
        #expect(pr.mergedAt != nil)
        #expect(pr.checks == .passing)
        #expect(pr.totalCount == 1)
    }
}
