import BenchKit
import Foundation
import Testing
@testable import Bench

/// A project with several Claude tabs gives each tab a line on its sidebar
/// card: what the tab is about and what it's up to.
struct TabLineTests {
    @Test func aNameYouGaveTheTabComesFirst() {
        #expect(TabLine.describe(customTitle: "Release notes", terminalTitle: "✳ Fix the build", prompt: "Hi") == "Release notes")
    }

    @Test func claudesTitleForTheTaskComesNextWithoutItsSpinner() {
        #expect(TabLine.describe(customTitle: nil, terminalTitle: "✳ Fix the build", prompt: "Hi") == "Fix the build")
    }

    @Test func aGenericTitleFallsBackToThePromptsFirstLine() {
        #expect(TabLine.describe(customTitle: nil, terminalTitle: "✳ Claude Code", prompt: "Get started on ATL-350.\nThen test it") == "Get started on ATL-350.")
        #expect(TabLine.describe(customTitle: nil, terminalTitle: "Claude", prompt: nil) == nil)
        #expect(TabLine.describe(customTitle: " ", terminalTitle: nil, prompt: "  ") == nil)
    }

    @Test func aTabJustStartedWithAPromptIsLabelledByIt() {
        let line = TabLine(id: UUID(), activity: .idle, customTitle: nil, terminalTitle: nil, details: nil,
                           initialPrompt: "Get started on ATL-350.", fallbackTitle: "Claude")
        #expect(line.label == "Get started on ATL-350.")
        #expect(line.state == "Starting")
    }

    @Test func statesSayWhatEachTabIsUpTo() {
        func state(_ activity: TabActivity, _ details: AgentDetails? = nil) -> String {
            TabLine(id: UUID(), activity: activity, customTitle: nil, terminalTitle: nil, details: details,
                    initialPrompt: nil, fallbackTitle: "Claude").state
        }
        #expect(state(.working) == "Working")
        #expect(state(.waiting) == "Waiting on you")
        #expect(state(.done) == "Finished")
        #expect(state(.idle) == "Ready")
        #expect(state(.idle, AgentDetails(prompt: "x", stoppedAt: Date())) == "Done")
    }

    @Test func theTooltipCarriesWhatItsRunningOrItsRecap() {
        let working = TabLine(id: UUID(), activity: .working, customTitle: nil, terminalTitle: nil,
                              details: AgentDetails(prompt: "x", action: "Edit Theme.swift", plainAction: "Editing Theme.swift"),
                              initialPrompt: nil, fallbackTitle: "Claude")
        #expect(working.detail == "Editing Theme.swift")
        let finished = TabLine(id: UUID(), activity: .done, customTitle: nil, terminalTitle: nil,
                               details: AgentDetails(prompt: "x", summary: "Fixed it."),
                               initialPrompt: nil, fallbackTitle: "Claude")
        #expect(finished.detail == "Fixed it.")
        #expect(finished.label == "x")
    }
}
