import Foundation
import Testing
@testable import Bench

/// A Markdown file is drawn in sections, so only what's on screen is laid
/// out. Each section has to draw the same as it would in the whole file.
@MainActor
struct MarkdownFileTests {
    @Test func splitsBeforeEachHeading() {
        let text = "# Title\n\nIntro.\n\n## Usage\n\nRun it.\n"
        #expect(MarkdownFileView.sections(of: text) == ["# Title\n\nIntro.", "## Usage\n\nRun it."])
    }

    @Test func neverSplitsInsideACodeFence() {
        let text = "Before.\n\n```sh\n# not a heading\n\n" + String(repeating: "x", count: 3_000) + "\n```\nAfter."
        let sections = MarkdownFileView.sections(of: text)
        #expect(sections.count == 1)
        #expect(sections[0].hasSuffix("```\nAfter."))
    }

    @Test func breaksALongStretchAtABlankLine() {
        let paragraph = String(repeating: "word ", count: 120)
        let text = Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        let sections = MarkdownFileView.sections(of: text)
        #expect(sections.count > 1)
        // Nothing lost or added but the blank lines between sections.
        #expect(sections.joined(separator: "\n\n") == text.trimmingCharacters(in: .newlines))
    }

    @Test func keepsATableWhole() {
        let rows = (0..<200).map { "| row \($0) | some text in a cell |" }.joined(separator: "\n")
        let text = "| A | B |\n|---|---|\n" + rows
        #expect(MarkdownFileView.sections(of: text).count == 1)
    }

    @Test func knowsMarkdownByExtension() {
        #expect(MarkdownFileView.isMarkdown("README.md"))
        #expect(MarkdownFileView.isMarkdown("docs/Guide.MARKDOWN"))
        #expect(!MarkdownFileView.isMarkdown("main.swift"))
        #expect(!MarkdownFileView.isMarkdown("Makefile"))
    }
}
