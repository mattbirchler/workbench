import AppKit
import BenchKit
import SwiftUI

/// A Markdown file drawn the way the chat draws Claude's replies, a size
/// up, in a centered column narrow enough to read comfortably.
struct MarkdownFileView: View {
    let text: String
    /// The file's folder, which relative links are resolved against.
    let folder: URL
    /// Opens a linked file that's on disk in a tab.
    let openFile: (URL) -> Void

    /// About 75 characters of the 15pt body text, wider as ⌘+ grows it.
    static let column: CGFloat = 660

    /// Markdown files are rendered up to this size, and show as text past it.
    static let renderLimit = 512 << 10

    /// A section grows past this many characters only until its next blank
    /// line, so a long stretch without headings still comes in pieces.
    static let sectionLength = 2_000

    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    static func isMarkdown(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The file cut into sections, kept until the text changes.
    @State private var split = Split()

    private final class Split {
        var text: String?
        var sections: [String] = []
    }

    private var sections: [String] {
        if split.text != text {
            split.sections = Self.sections(of: text)
            split.text = text
        }
        return split.sections
    }

    /// The scroll view's width, which the column is sized from.
    @State private var available: CGFloat = 0

    /// The column's width in a scroll view this wide: the cap, or less in
    /// a narrow pane. Set outright rather than as a maximum, since a run of
    /// prose keeps the height it measured at its first width when the pane
    /// narrows.
    private static func columnWidth(in available: CGFloat, scale: CGFloat) -> CGFloat {
        max(120, min(column * scale, available - 2 * margin))
    }

    static let margin: CGFloat = 32

    var body: some View {
        let typography = ChatTypography.shared
        let palette = TerminalTheme.shared.chatPalette
        ScrollView {
            // Each section is drawn only as it scrolls into view: the chat's
            // Markdown view lays out everything it's given at once, which
            // stalls on a long file.
            LazyVStack(alignment: .leading, spacing: 8) {
                let width = Self.columnWidth(in: available, scale: typography.scale).rounded()
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    // The extra space a heading gets inside a run of prose.
                    MarkdownText(text: section)
                        .padding(.top, index > 0 && section.hasPrefix("#") ? 4 : 0)
                        // Drawn afresh when the column's width changes, since a
                        // run of prose doesn't measure itself again for that.
                        .id("\(index) \(width)")
                }
            }
            .foregroundStyle(palette.ink)
            .frame(width: Self.columnWidth(in: available, scale: typography.scale), alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 48)
            // Nothing until the width is known, rather than a column that
            // asks the window for more room than it has.
            .opacity(available > 0 ? 1 : 0)
        }
        // The column's width comes from the pane, never the other way round.
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .environment(\.companionPalette, palette)
        .environment(\.markdownFonts, typography.readingMarkdown)
        .environment(\.openURL, OpenURLAction { open($0) })
    }

    /// Splits Markdown into pieces that draw the same on their own: before
    /// each heading, and at a blank line once a piece is long. Never inside
    /// a code fence.
    static func sections(of text: String) -> [String] {
        var sections: [String] = []
        var current: [Substring] = []
        var length = 0
        var inFence = false
        func flush() {
            let section = current.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !section.isEmpty { sections.append(section) }
            current = []
            length = 0
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") {
                inFence.toggle()
            } else if !inFence {
                if trimmed.isEmpty, length >= sectionLength {
                    flush()
                    continue
                }
                if line.hasPrefix("#"), !current.isEmpty { flush() }
            }
            current.append(line)
            length += line.utf8.count + 1
        }
        flush()
        return sections
    }

    /// Links to other files open in Workbench; anything else goes to the
    /// app that handles it.
    private func open(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == nil || url.isFileURL {
            // A link to a heading in this file has nowhere to go yet.
            let path = url.isFileURL ? url.path : url.path(percentEncoded: false)
            guard !path.isEmpty else { return .discarded }
            let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appending(path: path)
            guard FileManager.default.fileExists(atPath: target.path) else { return .discarded }
            openFile(target.standardizedFileURL)
            return .handled
        }
        return .systemAction
    }
}

/// Which way a Markdown file shows: rendered, or as its text.
struct MarkdownModeSwitch: View {
    @Binding var showsSource: Bool

    var body: some View {
        Picker("Markdown", selection: $showsSource) {
            Text("Preview").tag(false)
            Text("Source").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Show the file rendered, or as Markdown you can edit")
    }
}
