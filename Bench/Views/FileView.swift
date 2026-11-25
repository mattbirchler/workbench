import AppKit
import BenchKit
import SwiftUI

/// A project file in its own tab, reloading as it changes. Text can be
/// edited and saved with ⌘S; unsaved edits are kept in `FileDrafts`, and
/// survive the file changing on disk. A full path is a file outside the
/// project, like one of Claude's plans.
struct FileView: View {
    @Environment(AppStore.self) private var store
    @Environment(RepoMonitors.self) private var repos
    let project: Project
    let path: String
    let monitor: FileListMonitor
    /// The tab it's in, so the Changes switch can turn it into the diff.
    var tabID: UUID?
    /// Whether this tab has the keys, for the next-change shortcuts.
    var isFocused = true

    @State private var content: FileContent?
    @State private var marks: [Int: ChangeMark] = [:]
    @State private var jump = ChangeJump()

    private var url: URL { project.fileURL(forPath: path) }

    private var drafts: FileDrafts { .shared }
    private var draft: FileDraft? { drafts.draft(for: url) }
    private var isEdited: Bool { draft?.isEdited ?? false }

    /// What the tab shows: the text being edited, over what's on disk.
    private var shown: FileContent? {
        guard let draft else { return content }
        if case .text = content { return .text(draft.text) }
        // Unsaved edits to a file that has since gone stay on screen.
        return draft.isEdited ? .text(draft.text) : content
    }

    /// A page a browser tab can show as it looks, not as its source.
    private var isWebPage: Bool {
        ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
    }

    /// This file's entry in the changes panel, if it has changed.
    private var change: FileChange? {
        guard let snapshot = repos.monitor(for: project).snapshot else { return nil }
        return (snapshot.unstaged + snapshot.staged + snapshot.againstBase).first { $0.path == path }
    }

    var body: some View {
        VStack(spacing: 0) {
            FileHeader(path: path, content: shown, badge: isEdited ? "Edited" : nil) {
                if isEdited {
                    Button("Save") { drafts.saveOrExplain(url) }
                        .controlSize(.small)
                        .help("Save your changes (⌘S)")
                }
                if let change {
                    if !marks.isEmpty {
                        ChangeStepButtons(hasKeys: isFocused) { forward in
                            jump = ChangeJump(id: jump.id + 1, forward: forward)
                        }
                    }
                    ChangesFileSwitch(mode: .file) { _ in
                        if let tabID {
                            store.showChanges(change, inTab: tabID, of: project.id)
                        } else {
                            store.openDiff(change, in: project.id)
                        }
                    }
                }
            } actions: {
                if isWebPage {
                    Button {
                        store.openPreview(url.standardizedFileURL, in: project.id)
                    } label: {
                        Image(systemName: "globe")
                    }
                    .buttonStyle(.borderless)
                    .help("Open in a browser tab")
                    .accessibilityLabel("Open in a browser tab")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open in default app")
            }
            Divider()
            if let conflict = draft?.conflict {
                FileConflictBanner(conflict: conflict, reload: { drafts.reload(url) }, discard: discardEdits,
                                   keepMine: { drafts.keepMine(url) })
                Divider()
            }
            // The marks are for the file on disk, so they'd sit on the
            // wrong lines beside unsaved edits.
            FileContentView(content: shown, path: path, marks: isEdited ? [:] : marks, jump: jump, onRunOut: runOut,
                            editor: FileEditor(edit: edit))
        }
        .background(TerminalTheme.shared.canvas)
        .onDisappear { drafts.release(url) }
        // Keep the folder watched while the tab is open, so edits show up
        // even when the sidebar is on Changes.
        .task { await monitor.hold() }
        .task(id: monitor.revision) { await load() }
        // The project's watcher doesn't see files outside it, so check
        // those now and then: a plan changes as Claude revises it.
        .task(id: path) {
            guard path.hasPrefix("/") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
        }
        .task(id: MarksKey(change: change, content: content)) { await loadMarks() }
    }

    private struct MarksKey: Equatable {
        var change: FileChange?
        var content: FileContent?
    }

    private func load() async {
        let url = url
        let next = await Task.detached(priority: .userInitiated) { FileReader.read(url) }.value
        if next != content { content = next }
        drafts.diskRead(Self.text(of: next), for: url)
    }

    private static func text(of content: FileContent?) -> String? {
        if case .text(let text) = content { return text }
        return nil
    }

    private func edit(_ text: String) {
        // The draft is let go of when another tab on this file closes.
        if draft == nil { drafts.diskRead(Self.text(of: content) ?? "", for: url) }
        drafts.edit(text, for: url)
    }

    /// Drops the edits and shows the file as it is on disk.
    private func discardEdits() {
        drafts.discard(url)
        drafts.diskRead(Self.text(of: content), for: url)
    }

    /// Marks what changed: against the branch's base for a file that only
    /// differs there, against the last commit otherwise.
    private func loadMarks() async {
        guard let change else {
            if !marks.isEmpty { marks = [:] }
            return
        }
        let next: [Int: ChangeMark]
        if change.kind == .untracked || change.kind == .added, case .text(let text) = content {
            // All new: every line is added.
            let count = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0))
            next = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, ChangeMark.added) })
        } else {
            let git = repos.monitor(for: project)
            let base = change.section == .againstBase ? git.snapshot?.baseRef : nil
            let diff = await git.client.changedLines(path, baseRef: base)
            next = ChangeMark.marks(fromZeroContextDiff: diff)
        }
        if next != marks { marks = next }
    }

    /// Past the last change, on to the next changed file (or back to the
    /// previous one), in this same tab.
    private func runOut(_ forward: Bool) {
        guard !isEdited, let tabID, let snapshot = repos.monitor(for: project).snapshot else { return }
        let files = snapshot.filesInOrder(section: nil)
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        let next = forward ? index + 1 : index - 1
        guard files.indices.contains(next) else { return }
        store.showFile(files[next].path, inTab: tabID, of: project.id)
    }
}

/// The name, folder, and size above a file, with room for buttons. The
/// buttons keep the order the diff's header uses (`DiffView.header`), so
/// nothing moves when a tab flips between File and Changes: `leading`
/// (stepping through changes, the File and Changes switch), then the
/// count, the wrap toggle, the copy button, and `actions` (Show in Finder,
/// open).
struct FileHeader<Leading: View, Actions: View>: View {
    let path: String
    let content: FileContent?
    /// A word beside the name, like "Edited".
    var badge: String?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let actions: () -> Actions
    @AppStorage("fileViewWraps") private var wraps = false

    init(path: String, content: FileContent?, badge: String? = nil, @ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.path = path
        self.content = content
        self.badge = badge
        self.leading = leading
        self.actions = actions
    }

    var body: some View {
        PaneHeader(title: (path as NSString).lastPathComponent,
                   subtitle: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                   badge: badge) {
            leading()
            if case .text(let text) = content {
                Text(Self.lineCount(text))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Toggle(isOn: $wraps) {
                    Image(systemName: "text.word.spacing")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(wraps ? "Stop wrapping long lines" : "Wrap long lines")
                CopyFileButton { text }
            }
            actions()
        }
    }

    private static func lineCount(_ text: String) -> String {
        var count = text.isEmpty ? 0 : 1
        for byte in text.utf8 where byte == 10 { count += 1 }
        if text.hasSuffix("\n") { count -= 1 }
        return count == 1 ? "1 line" : "\(count.formatted()) lines"
    }
}

/// Copies a file's whole text, and shows a checkmark for a moment after.
/// `text` is asked for on the click, so the diff's header can read the file
/// then; nil is a file that can't be copied as text.
struct CopyFileButton: View {
    let text: () -> String?
    @State private var copied = false
    @State private var failed = false

    var body: some View {
        Button {
            guard let text = text() else {
                failed = true
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            failed = false
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : failed ? "This file can't be copied as text" : "Copy file contents")
        .accessibilityLabel("Copy file contents")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

extension FileHeader where Leading == EmptyView {
    /// A header with nothing ahead of the count.
    init(path: String, content: FileContent?, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(path: path, content: content, leading: { EmptyView() }, actions: actions)
    }
}

/// What a file tab does with typing. Without one, the text is read only.
struct FileEditor {
    /// Called with the whole text after each edit.
    let edit: (String) -> Void
}

/// The note above a file whose disk copy changed under unsaved edits.
/// Nothing is lost either way until a button is pressed.
struct FileConflictBanner: View {
    let conflict: FileDraft.Conflict
    let reload: () -> Void
    let discard: () -> Void
    let keepMine: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.ui(size: 13))
                .foregroundStyle(.yellow)
            Text(conflict == .gone
                 ? "This file was moved or deleted while you were editing. Saving puts it back."
                 : "This file changed on disk while you were editing. Saving replaces those changes with yours.")
                .font(Theme.TypeScale.font(Theme.TypeScale.bodySmall))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if conflict == .gone {
                Button("Discard My Edits", action: discard)
            } else {
                Button("Reload", action: reload)
                    .help("Show the file as it is on disk and drop your edits")
            }
            Button("Keep Mine", action: keepMine)
                .help("Carry on editing. Nothing is written until you save.")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // A floor on the width, then no minimum asked of the window: when
        // the window works out how small it can get it measures this at
        // almost no width, where the wrapping text is thousands of points
        // tall, and that pushed the whole window's contents up out of it
        // (see InfoBanner).
        .frame(minWidth: 360)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.10))
        .clipped()
    }
}

/// Text with line numbers, an image, or why neither can be shown.
struct FileContentView: View {
    let content: FileContent?
    /// The file's path, so its code can be colored for its language.
    var path: String?
    var marks: [Int: ChangeMark] = [:]
    var jump = ChangeJump()
    var onRunOut: (Bool) -> Void = { _ in }
    /// Set to let the text be edited.
    var editor: FileEditor?
    @AppStorage("fileViewWraps") private var wraps = false

    var body: some View {
        switch content {
        case nil:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text):
            CodeTextView(text: text, wraps: wraps, path: path, marks: marks, jump: jump, onRunOut: onRunOut, onEdit: editor?.edit)
        case .image(let data):
            if let image = NSImage(data: data) {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Can't Show This Image", systemImage: "photo")
            }
        case .binary(let size):
            ContentUnavailableView("Binary File", systemImage: "doc",
                                   description: Text(size > 0 ? "\(FileContent.size(size)) of data that isn't text." : "This isn't a text file."))
        case .tooLarge(let size):
            ContentUnavailableView("File Too Large", systemImage: "doc",
                                   description: Text("At \(FileContent.size(size)), it's too big to show here."))
        case .missing:
            ContentUnavailableView("File Not Found", systemImage: "questionmark.folder",
                                   description: Text("It may have been moved or deleted."))
        }
    }
}

// MARK: - Text with line numbers

/// Monospaced text with line numbers that keeps its scroll position and
/// selection when the file changes underneath it. Read only unless
/// `onEdit` is set.
struct CodeTextView: NSViewRepresentable {
    let text: String
    let wraps: Bool
    var path: String?
    /// Changed lines to mark in the gutter.
    var marks: [Int: ChangeMark] = [:]
    /// The latest request to move to the next or previous mark.
    var jump = ChangeJump()
    /// Called when a jump finds no more marks that way.
    var onRunOut: (Bool) -> Void = { _ in }
    /// Called with the whole text after each edit. Nil is read only.
    var onEdit: ((String) -> Void)?

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The text last sent off to be colored.
        var colored: String?
        var jump = 0
        var onEdit: ((String) -> Void)?
        weak var container: CodeTextContainer?
        /// The coloring on its way, dropped when more is typed.
        var coloring: Task<Void, Never>?

        func textDidChange(_ notification: Notification) {
            guard let container else { return }
            container.textEdited()
            onEdit?(container.textView.string)
        }

        /// Return keeps the line's indentation.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let text = textView.string as NSString
            let caret = textView.selectedRange().location
            let line = text.lineRange(for: NSRange(location: caret, length: 0))
            var end = line.location
            while end < caret, [32, 9].contains(text.character(at: end)) { end += 1 }
            let indent = text.substring(with: NSRange(location: line.location, length: end - line.location))
            textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CodeTextContainer {
        let view = CodeTextContainer(source: LineNumberSource())
        view.setText(text)
        view.setWraps(wraps)
        context.coordinator.container = view
        return view
    }

    func updateNSView(_ view: CodeTextContainer, context: Context) {
        view.setBackground(TerminalTheme.shared.nsCanvas)
        view.setWraps(wraps)
        let editable = onEdit != nil
        context.coordinator.onEdit = onEdit
        view.setEditable(editable)
        view.textView.delegate = editable ? context.coordinator : nil
        view.setText(text)
        if let numbers = view.source as? LineNumberSource, numbers.marks != marks {
            numbers.marks = marks
            view.refreshDecorations()
        }
        if jump.id != context.coordinator.jump {
            context.coordinator.jump = jump.id
            let starts = marks.keys.sorted().filter { marks[$0 - 1] == nil || marks[$0 - 1] == .removedAbove }
            if !view.jump(to: starts, forward: jump.forward) {
                let forward = jump.forward
                DispatchQueue.main.async { onRunOut(forward) }
            }
        }
        guard let path, context.coordinator.colored != text else { return }
        // While typing, wait for a pause rather than coloring every key.
        let waits = editable && context.coordinator.colored != nil
        context.coordinator.colored = text
        let text = text
        context.coordinator.coloring?.cancel()
        context.coordinator.coloring = Task {
            if waits {
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { return }
            }
            guard let spans = await SyntaxColors.spans(in: text, path: path), !Task.isCancelled else { return }
            // Edited text carries the colors of what was there before.
            view.applySyntax(spans, to: text, resetting: editable)
        }
    }
}

/// What a gutter knows about the text beside it: where its lines start,
/// how wide the gutter needs to be, and what to draw for each line. The
/// file view numbers lines; the diff view numbers them twice and tints them.
protocol GutterSource: AnyObject {
    /// Where each line starts, in UTF-16 offsets into the text, from 0 up.
    var lineStarts: [Int] { get }
    /// How wide the gutter should be for the current text.
    var width: CGFloat { get }
    /// The text changed. Recount lines and work out the width.
    func textChanged(_ text: String)
    /// Draws the cell for one line. `row` spans the gutter's width and the
    /// line's whole height, wrapped fragments included; `firstLine` is the
    /// first fragment's rect inside it, for centering a label.
    func drawCell(line: Int, in row: NSRect, firstLine: NSRect)
    /// A fill behind the whole line in the text view, edge to edge.
    func lineBackground(_ line: Int) -> NSColor?
    /// Whether the user can leave a comment on this line.
    func canComment(_ line: Int) -> Bool
    /// Whether the line is a folded stretch that opens when clicked.
    func isFold(_ line: Int) -> Bool
}

extension GutterSource {
    func lineBackground(_ line: Int) -> NSColor? { nil }
    func canComment(_ line: Int) -> Bool { false }
    func isFold(_ line: Int) -> Bool { false }
}

/// A gutter beside a scrolling text view. The gutter is its own view so it
/// never covers the text, and so selecting text never picks up its numbers.
final class CodeTextContainer: NSView {
    private let scrollView = NSScrollView()
    /// Internal so colored code can be applied from SyntaxColors.swift.
    let textView: BandedTextView
    private let gutter: GutterView
    let source: GutterSource

    /// Called with a fold row's index when it's clicked.
    var onFold: ((Int) -> Void)? {
        get { textView.onFold }
        set { textView.onFold = newValue }
    }

    /// The last line moved to with `jump`, and where the view was scrolled
    /// then, so the next jump goes on from it unless the user has scrolled.
    private var lastJump: (line: Int, origin: NSPoint)?

    /// Scrolls to the next (or previous) of `lines`, counting from the
    /// last one moved to, or from the top of the view after a scroll.
    /// False when there's none that way.
    @discardableResult
    func jump(to lines: [Int], forward: Bool) -> Bool {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return false }
        let clip = scrollView.contentView
        let current: Int
        if let lastJump, lastJump.origin == clip.bounds.origin {
            current = lastJump.line
        } else {
            let top = textView.lineRows(in: clip.bounds, lineStarts: source.lineStarts).first?.index ?? 0
            // From the top line, so a change sitting at the top counts as next.
            current = forward ? top - 1 : top
        }
        guard let target = forward ? lines.first(where: { $0 > current }) : lines.last(where: { $0 < current }),
              target < source.lineStarts.count else { return false }
        scroll(toLine: target, linesAbove: 3)
        return true
    }

    /// Scrolls so `line` is near the top, with `linesAbove` lines of what's
    /// above it still showing.
    func scroll(toLine target: Int, linesAbove: CGFloat = 0) {
        guard target < source.lineStarts.count, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let clip = scrollView.contentView
        layoutManager.ensureLayout(for: container)
        let glyph = layoutManager.glyphIndexForCharacter(at: source.lineStarts[target])
        let rect = glyph < layoutManager.numberOfGlyphs
            ? layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            : layoutManager.extraLineFragmentRect
        let y = rect.minY + textView.textContainerOrigin.y - rect.height * linesAbove
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
        lastJump = (target, clip.bounds.origin)
    }

    /// Called with the line at the top of the view as it scrolls.
    var onTopLine: ((Int) -> Void)?

    /// Called with a line's index when the user asks to comment on it, from
    /// the gutter's "+" or the text's context menu. Nil hides both.
    var onComment: ((Int) -> Void)? {
        didSet {
            gutter.onComment = onComment
            textView.onComment = onComment
        }
    }

    func setBackground(_ color: NSColor) {
        guard textView.backgroundColor != color else { return }
        textView.backgroundColor = color
        scrollView.backgroundColor = color
        gutter.background = color
        gutter.needsDisplay = true
    }

    init(source: GutterSource) {
        self.source = source
        textView = BandedTextView(source: source)
        gutter = GutterView(source: source)
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        gutter.textView = textView
        addSubview(gutter)
        addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(redrawGutter),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(redrawGutter),
                                               name: NSView.frameDidChangeNotification, object: textView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func redrawGutter() {
        gutter.needsDisplay = true
        if let onTopLine {
            // A line a little way down, so a header just scrolled under
            // the top edge still counts as current.
            let probe = scrollView.contentView.bounds
            if let top = textView.lineRows(in: NSRect(x: probe.minX, y: probe.minY + 12, width: probe.width, height: 1),
                                           lineStarts: source.lineStarts).first?.index {
                onTopLine(top)
            }
        }
    }

    /// Redraws the gutter and the line bands, for when what they show
    /// changed but the text didn't (a comment was added, say).
    func refreshDecorations() {
        if abs(gutter.frame.width - source.width) > 0.5 { needsLayout = true }
        gutter.needsDisplay = true
        textView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = source.width
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        if !scrollView.hasHorizontalScroller {
            textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        }
    }

    func setText(_ text: String) {
        guard textView.string != text else { return }
        replaceText(length: (text as NSString).length) { textView.string = text }
        // The file was read again: undo can't reach back past that.
        if textView.isEditable { textView.undoManager?.removeAllActions() }
    }

    /// Lets the text be typed in, as code: nothing is corrected, curled
    /// or replaced.
    func setEditable(_ editable: Bool) {
        guard textView.isEditable != editable else { return }
        textView.isEditable = editable
        textView.allowsUndo = editable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
    }

    /// The text was typed in: count its lines again for the gutter.
    func textEdited() {
        let width = source.width
        source.textChanged(textView.string)
        if abs(width - source.width) > 0.5 { needsLayout = true }
        gutter.needsDisplay = true
    }

    func setAttributedText(_ text: NSAttributedString) {
        replaceText(length: text.length) { textView.textStorage?.setAttributedString(text) }
    }

    /// Swaps the text in while keeping the selection and scroll position.
    private func replaceText(length: Int, _ apply: () -> Void) {
        let first = textView.string.isEmpty
        let selection = textView.selectedRanges
        let origin = scrollView.contentView.bounds.origin
        apply()
        if !first {
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                let start = min(range.location, length)
                return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
            }
            if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let width = source.width
        source.textChanged(textView.string)
        if abs(width - source.width) > 0.5 { needsLayout = true }
        gutter.needsDisplay = true
    }

    func setWraps(_ wraps: Bool) {
        // A horizontal scroller is the sign of not wrapping.
        guard scrollView.hasHorizontalScroller == wraps, let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        if wraps {
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        needsLayout = true
        gutter.needsDisplay = true
    }
}

/// One line's place in a text view: the row it fills (every wrapped
/// fragment) and its first fragment, both in text container coordinates.
struct LineRow {
    let index: Int
    let rect: NSRect
    let firstLine: NSRect
}

extension NSTextView {
    /// The lines laid out inside `rect` (in the view's coordinates), given
    /// where each line starts. Only touches the lines showing, so a long
    /// file costs the same as a short one.
    func lineRows(in rect: NSRect, lineStarts: [Int]) -> [LineRow] {
        guard let layoutManager, let container = textContainer, !lineStarts.isEmpty else { return [] }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (string as NSString).length

        func fragment(startingAt character: Int) -> NSRect {
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            guard glyph < layoutManager.numberOfGlyphs else { return layoutManager.extraLineFragmentRect }
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }

        // The first line that starts at or before the top of the rect.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= characters.location { low = mid } else { high = mid - 1 }
        }
        var rows: [LineRow] = []
        var line = low
        // A file's text ends in a newline, so a line starting at the very
        // end is nothing. A diff's doesn't, so there an empty last line is
        // still a line.
        let endsWithNewline = length > 0 && string.hasSuffix("\n")
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters),
              lineStarts[line] < max(length, 1) || (!endsWithNewline && lineStarts[line] == length && line > 0) {
            let first = fragment(startingAt: lineStarts[line])
            let bottom: CGFloat
            if line + 1 < lineStarts.count, lineStarts[line + 1] < length {
                bottom = fragment(startingAt: lineStarts[line + 1]).minY
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: lineStarts[line])
                let rest = NSRange(location: glyph, length: max(0, layoutManager.numberOfGlyphs - glyph))
                bottom = rest.length == 0 ? first.maxY : layoutManager.boundingRect(forGlyphRange: rest, in: container).maxY
            }
            rows.append(LineRow(index: line, rect: NSRect(x: 0, y: first.minY, width: 0, height: max(bottom, first.maxY) - first.minY),
                                firstLine: first))
            line += 1
        }
        return rows
    }
}

/// A text view that paints its source's line backgrounds from edge to
/// edge behind the text, so an added or removed line reads as one band
/// even where it's empty or wraps.
final class BandedTextView: NSTextView {
    private weak var source: GutterSource?
    var onComment: ((Int) -> Void)?
    var onFold: ((Int) -> Void)?

    /// A click on a fold row opens it, rather than placing the caret.
    override func mouseDown(with event: NSEvent) {
        if let onFold, let source, event.clickCount == 1 {
            let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if let line = source.lineStarts.lastIndex(where: { $0 <= offset }), source.isFold(line) {
                onFold(line)
                return
            }
        }
        super.mouseDown(with: event)
    }

    init(source: GutterSource) {
        self.source = source
        // TextKit 1, built by hand: the convenience initializer that picks
        // it can't be called from a subclass.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let source else { return }
        let origin = textContainerOrigin
        let right = max(bounds.width, enclosingScrollView?.contentView.bounds.maxX ?? 0)
        for row in lineRows(in: rect, lineStarts: source.lineStarts) {
            guard let fill = source.lineBackground(row.index) else { continue }
            fill.setFill()
            NSRect(x: 0, y: row.rect.minY + origin.y, width: right, height: row.rect.height).fill()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onComment != nil, let source else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        guard let line = source.lineStarts.lastIndex(where: { $0 <= offset }), source.canComment(line) else { return menu }
        let item = NSMenuItem(title: "Comment on this line", action: #selector(commentOnLine(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = line
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func commentOnLine(_ sender: NSMenuItem) {
        guard let line = sender.representedObject as? Int else { return }
        onComment?(line)
    }
}

/// Numbers the lines of a file, as a gutter source.
final class LineNumberSource: GutterSource {
    private(set) var lineStarts: [Int] = [0]
    private(set) var width: CGFloat = 35
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    /// Changed lines, marked with a bar at the gutter's edge.
    var marks: [Int: ChangeMark] = [:]

    func textChanged(_ text: String) {
        var starts = [0]
        var offset = 0
        let units = text.utf16
        let count = units.count
        for unit in units {
            offset += 1
            if unit == 10, offset < count { starts.append(offset) }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        width = CGFloat(digits) * 7 + 16
    }

    func drawCell(line: Int, in row: NSRect, firstLine: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let label = "\(line + 1)" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: row.maxX - size.width - 9, y: firstLine.minY + (firstLine.height - size.height) / 2),
                   withAttributes: attributes)
        guard let mark = marks[line] else { return }
        mark.color.setFill()
        switch mark {
        case .added, .changed:
            NSRect(x: row.maxX - 5, y: row.minY, width: 3, height: row.height).fill()
        case .removedAbove:
            // A small wedge on the line's top edge, where the lines were.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: row.maxX - 8, y: row.minY))
            path.line(to: NSPoint(x: row.maxX - 2, y: row.minY))
            path.line(to: NSPoint(x: row.maxX - 2, y: row.minY + 5))
            path.close()
            path.fill()
        }
    }
}

/// The gutter itself: fills its background, asks the source to draw each
/// line showing, and ends in a hairline. When comments are allowed, the
/// line under the pointer gets a "+" to start one.
final class GutterView: NSView {
    var background: NSColor = .textBackgroundColor
    weak var textView: NSTextView?
    private let source: GutterSource
    var onComment: ((Int) -> Void)? {
        didSet { if onComment == nil { hoveredLine = nil } }
    }
    private var hoveredLine: Int? {
        didSet { if hoveredLine != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    init(source: GutterSource) {
        self.source = source
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private static let chipSize: CGFloat = 15
    private static let chipInset: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        guard let textView, let clip = textView.enclosingScrollView?.contentView else { return }
        let top = textView.textContainerOrigin.y - clip.bounds.minY
        for row in rows() {
            let rect = NSRect(x: 0, y: top + row.rect.minY, width: bounds.width, height: row.rect.height)
            let first = NSRect(x: 0, y: top + row.firstLine.minY, width: bounds.width, height: row.firstLine.height)
            source.drawCell(line: row.index, in: rect, firstLine: first)
            if row.index == hoveredLine, onComment != nil, source.canComment(row.index) {
                drawChip(in: chipRect(firstLine: first))
            }
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    /// The lines showing, in the text view's container coordinates.
    private func rows() -> [LineRow] {
        guard let textView, let clip = textView.enclosingScrollView?.contentView else { return [] }
        return textView.lineRows(in: clip.bounds, lineStarts: source.lineStarts)
    }

    private func chipRect(firstLine: NSRect) -> NSRect {
        NSRect(x: Self.chipInset, y: firstLine.midY - Self.chipSize / 2, width: Self.chipSize, height: Self.chipSize)
    }

    private func drawChip(in rect: NSRect) {
        NSColor(Theme.accent).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.chip, yRadius: Theme.Radius.chip).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(Theme.onAccent),
        ]
        let plus = "+" as NSString
        let size = plus.size(withAttributes: attributes)
        plus.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    // MARK: Hover and clicks

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard onComment != nil else { return }
        hoveredLine = line(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredLine = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let onComment, let textView, let clip = textView.enclosingScrollView?.contentView else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let top = textView.textContainerOrigin.y - clip.bounds.minY
        for row in rows() where source.canComment(row.index) {
            let first = NSRect(x: 0, y: top + row.firstLine.minY, width: bounds.width, height: row.firstLine.height)
            if chipRect(firstLine: first).insetBy(dx: -2, dy: -2).contains(point) {
                onComment(row.index)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func line(at point: NSPoint) -> Int? {
        guard let textView, let clip = textView.enclosingScrollView?.contentView else { return nil }
        let top = textView.textContainerOrigin.y - clip.bounds.minY
        return rows().first { row in
            let rect = NSRect(x: 0, y: top + row.rect.minY, width: bounds.width, height: row.rect.height)
            return rect.contains(point)
        }?.index
    }
}
