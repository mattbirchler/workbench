import AppKit
import UniformTypeIdentifiers

/// The app File > Open in Editor opens a project's folder with, the way
/// `code <folder>` does from a shell, but without needing the editor's
/// shell command installed. You pick it in Settings > General; until
/// then it's the first editor in `known` that's on this Mac.
@MainActor
enum Editors {
    /// The bundle identifier of the editor you picked. Unset until you pick one.
    static let chosenKey = "editorBundleID"

    struct Editor: Identifiable, Equatable {
        let bundleID: String
        let url: URL
        var id: String { bundleID }
        /// The app's name as the Applications folder shows it.
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    /// Editors offered when they're installed, the likeliest first. Any
    /// other app can be picked with Other App… in Settings.
    static let known = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.vscodium",
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.barebones.bbedit",
    ]

    /// The app with this bundle identifier, if it's on this Mac.
    static func editor(_ bundleID: String) -> Editor? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { Editor(bundleID: bundleID, url: $0) }
    }

    /// The editor to open with: the one you picked while it's still
    /// installed, or else the first known one that is.
    static var current: Editor? {
        if let chosen = UserDefaults.standard.string(forKey: chosenKey).flatMap(editor) { return chosen }
        return known.lazy.compactMap(editor).first
    }

    /// What Settings lists: the known editors on this Mac, and the one
    /// you picked when it's some other app.
    static var choices: [Editor] {
        var list = known.compactMap(editor)
        if let current, !list.contains(where: { $0.bundleID == current.bundleID }) { list.append(current) }
        return list
    }

    /// "Open in Visual Studio Code", or "Open in Editor…" while there's
    /// none yet and choosing it asks for one.
    static var menuTitle: String {
        current.map { "Open in \($0.name)" } ?? "Open in Editor…"
    }

    /// Opens a folder in the editor, asking which app to use first when
    /// there's none on this Mac.
    static func open(_ folder: URL) {
        if let current {
            open(folder, in: current)
            return
        }
        // After the menu this came from has closed, so the panel isn't under it.
        DispatchQueue.main.async {
            if let editor = chooseApp() { open(folder, in: editor) }
        }
    }

    private static func open(_ folder: URL, in editor: Editor) {
        let name = editor.name
        NSWorkspace.shared.open([folder], withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Couldn't open \(folder.lastPathComponent) in \(name)"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }

    /// Asks for an app, from the Applications folder, and remembers it as
    /// the editor. Nil if you cancel.
    @discardableResult
    static func chooseApp() -> Editor? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the app to open projects in"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        UserDefaults.standard.set(bundleID, forKey: chosenKey)
        return Editor(bundleID: bundleID, url: url)
    }
}
