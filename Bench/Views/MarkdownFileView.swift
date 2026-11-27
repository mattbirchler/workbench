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

    /// Markdown files are rendered up to this size. Past it the whole file
    /// is laid out at once too slowly, so it shows as text.
    static let renderLimit = 512 << 10

    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    static func isMarkdown(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The scroll view's width, so the column can be given an exact one.
    @State private var available: CGFloat = 0

    /// The column's width: the cap, or less in a narrow pane. Set
    /// outright rather than as a maximum, since a run of prose keeps the
    /// height it measured at its first width when the pane narrows.
    private func columnWidth(scale: CGFloat) -> CGFloat {
        let cap = Self.column * scale
        guard available > 0 else { return cap }
        return max(120, min(cap, available - 2 * Self.margin))
    }

    static let margin: CGFloat = 32

    var body: some View {
        let typography = ChatTypography.shared
        let palette = TerminalTheme.shared.chatPalette
        ScrollView {
            MarkdownText(text: text)
                .foregroundStyle(palette.ink)
                .frame(width: columnWidth(scale: typography.scale), alignment: .leading)
                .padding(.horizontal, Self.margin)
                .padding(.top, 28)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .environment(\.companionPalette, palette)
        .environment(\.markdownFonts, typography.readingMarkdown)
        .environment(\.openURL, OpenURLAction { open($0) })
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
