import AppKit
import BenchKit
import GhosttyKit
import Observation
import SwiftUI

/// The terminal theme's colors, from the user's Ghostty config or one of the
/// built-in themes layered on top of it, so the rest of the window can match
/// the terminal tabs. Follows Ghostty's own light and dark theme switching,
/// since libghostty reports each change.
@MainActor
@Observable
final class TerminalTheme {
    static let shared = TerminalTheme()
    static let matchKey = "matchTerminalTheme"

    private(set) var background: NSColor?
    private(set) var foreground: NSColor?
    /// The 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan,
    /// white, then their bright versions.
    private(set) var ansi: [NSColor] = []
    /// The theme's cursor color, when it sets one.
    private(set) var cursor: NSColor?

    /// Where the window's colors come from. Settings > General.
    enum Source: String, CaseIterable, Identifiable {
        /// The user's Ghostty theme.
        case ghostty
        /// One of Workbench's own themes, for both the terminal tabs and
        /// the window around them.
        case builtIn
        /// The Mac's usual colors around the terminal, which keeps the
        /// Ghostty theme.
        case system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ghostty: "Ghostty Theme"
            case .builtIn: "Workbench Themes"
            case .system: "System"
            }
        }
    }

    static let sourceKey = "themeSource"
    static let lightThemeKey = "builtInLightTheme"
    static let darkThemeKey = "builtInDarkTheme"

    var source: Source {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            if source == .builtIn || oldValue == .builtIn { GhosttyRuntime.shared.reloadConfig() }
        }
    }

    /// The built-in theme for light mode, and the one for dark mode. The
    /// window follows the Mac's appearance between them.
    var lightThemeID: String {
        didSet {
            UserDefaults.standard.set(lightThemeID, forKey: Self.lightThemeKey)
            if source == .builtIn, lightThemeID != oldValue { GhosttyRuntime.shared.reloadConfig() }
        }
    }

    var darkThemeID: String {
        didSet {
            UserDefaults.standard.set(darkThemeID, forKey: Self.darkThemeKey)
            if source == .builtIn, darkThemeID != oldValue { GhosttyRuntime.shared.reloadConfig() }
        }
    }

    var lightTheme: BuiltInTheme { BuiltInTheme.named(lightThemeID) ?? .defaultLight }
    var darkTheme: BuiltInTheme { BuiltInTheme.named(darkThemeID) ?? .defaultDark }

    /// The built-in theme in use right now, or nil when following Ghostty
    /// or the system.
    func activeBuiltInTheme(dark: Bool) -> BuiltInTheme? {
        source == .builtIn ? (dark ? darkTheme : lightTheme) : nil
    }

    /// True when the window takes its colors from a terminal theme, either
    /// Ghostty's or a built-in one.
    var matches: Bool { source != .system }

    private init() {
        let defaults = UserDefaults.standard
        source = Self.initialSource(defaults)
        lightThemeID = defaults.string(forKey: Self.lightThemeKey) ?? BuiltInTheme.defaultLightID
        darkThemeID = defaults.string(forKey: Self.darkThemeKey) ?? BuiltInTheme.defaultDarkID
        // A built-in theme's colors are known without asking Ghostty, so
        // the first thing drawn (the welcome, for a new user) is already
        // in the theme and not the plain look until a terminal loads. It
        // goes by Workbench's own Light or Dark choice, as Ghostty does
        // once it loads: starting in the Mac's look and then switching
        // left parts of the window in the old one.
        if source == .builtIn {
            let dark = AppAppearance.startsDark { defaults.string(forKey: $0) }
            let theme = dark ? darkTheme : lightTheme
            func color(_ rgb: TerminalColors.RGB) -> NSColor { NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
            background = color(theme.background)
            foreground = color(theme.foreground)
            cursor = color(theme.cursor)
            ansi = theme.palette.map(color)
        }
    }

    /// The saved choice. Before there was one, a switch turned matching
    /// Ghostty on or off; that carries over. Someone who never touched it
    /// follows Ghostty if they've picked a Ghostty theme, and gets a
    /// built-in theme if not, rather than the plain default colors.
    private static func initialSource(_ defaults: UserDefaults) -> Source {
        if let saved = defaults.string(forKey: sourceKey).flatMap(Source.init(rawValue:)) { return saved }
        if defaults.object(forKey: matchKey) != nil {
            return defaults.bool(forKey: matchKey) ? .ghostty : .system
        }
        return GhosttyConfigFiles.setsColors ? .ghostty : .builtIn
    }

    /// Reads the colors from a config libghostty handed us. The config is
    /// only valid during the call, so the colors are copied out.
    func update(from config: ghostty_config_t) {
        if let bg = Self.color(config, "background"), bg != background { background = bg }
        if let fg = Self.color(config, "foreground"), fg != foreground { foreground = fg }
        let cursorColor = Self.color(config, "cursor-color")
        if cursorColor != cursor { cursor = cursorColor }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        if ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) {
            let colors = withUnsafeBytes(of: palette.colors) { raw in
                raw.bindMemory(to: ghostty_config_color_s.self).prefix(16).map {
                    NSColor(srgbRed: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1)
                }
            }
            if colors != ansi { ansi = colors }
        }
    }

    /// One of the theme's ANSI colors (1 red, 2 green, 3 yellow, 4 blue,
    /// 5 magenta), or nil when not matching the terminal.
    func ansiColor(_ index: Int) -> Color? {
        guard isActive, ansi.count > index else { return nil }
        return Color(nsColor: ansi[index])
    }

    #if DEBUG
    /// Stands in for a Ghostty config, for rendering pages in tests.
    func setForTesting(background: NSColor, foreground: NSColor, ansi: [NSColor], cursor: NSColor? = nil) {
        self.background = background
        self.foreground = foreground
        self.ansi = ansi
        self.cursor = cursor
    }
    #endif

    private static func color(_ config: ghostty_config_t, _ key: String) -> NSColor? {
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(value.r) / 255, green: CGFloat(value.g) / 255, blue: CGFloat(value.b) / 255, alpha: 1)
    }

    private var isActive: Bool { matches && background != nil }

    private var isDark: Bool {
        guard let rgb = background?.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }

    /// Light or dark to match the terminal, or nil to follow the system.
    var colorScheme: ColorScheme? {
        isActive ? (isDark ? .dark : .light) : nil
    }

    /// Behind content that sits next to the terminal: diffs, files, Overview.
    var nsCanvas: NSColor {
        isActive ? background! : .textBackgroundColor
    }

    var canvas: Color { Color(nsColor: nsCanvas) }

    /// The selected row in a sidebar, standing out from `panel`: the page
    /// color in light themes, a step lighter in dark ones. nil to keep the
    /// system's look.
    var selectedRow: Color? {
        guard isActive, let background else { return nil }
        guard isDark else { return canvas }
        let step = foreground ?? .white
        return Color(nsColor: background.blended(withFraction: 0.13, of: step) ?? background)
    }

    /// The sidebars: the terminal background, a step toward its text color,
    /// or nil to keep the system's sidebar look.
    var panel: Color? {
        guard isActive, let background else { return nil }
        let step = foreground ?? (isDark ? .white : .black)
        return Color(nsColor: background.blended(withFraction: isDark ? 0.045 : 0.035, of: step) ?? background)
    }
}

extension TerminalTheme {
    /// The chat view's colors: built from the terminal's background and
    /// text, so a Claude tab looks the same as a chat or a terminal. The
    /// usual Mac colors when not matching.
    var chatPalette: CompanionPalette {
        companionColors.map { CompanionPalette.mac.themed(with: $0) } ?? .mac
    }

    /// The background and text colors, for the chat here and for the
    /// phone, or nil when not matching the terminal.
    var companionColors: TerminalColors? {
        guard isActive, let background else { return nil }
        let text = foreground ?? (isDark ? .white : .black)
        func rgb(_ color: NSColor) -> TerminalColors.RGB {
            let c = color.usingColorSpace(.sRGB) ?? color
            return TerminalColors.RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        }
        // The theme's blue for `inline code`, as Claude Code colors it in
        // the terminal. Only once the palette has been read.
        let code = ansi.count >= 16 ? rgb(readableThemeColor(.blue, contrast: 4.5)) : nil
        // The accent comes from the cursor color. Ghostty doesn't always
        // hand that back, so a built-in theme's own value comes first.
        let accent = activeBuiltInTheme(dark: isDark).map { TerminalColors.accent(fromCursor: $0.cursor) }
            ?? TerminalColors.accent(fromCursor: cursor.map(rgb))
        // The checklist's green from the theme's palette, once it has been
        // read, and the working color from the accent.
        let status = TerminalColors.statusColors(palette: ansi.map(rgb), background: rgb(background),
                                                 foreground: rgb(text), accent: accent)
        return TerminalColors(background: rgb(background), foreground: rgb(text), code: code, accent: accent,
                              done: status.done, working: status.working)
    }
}

extension TerminalTheme {
    /// The color for Claude at work: the sidebar's working rows and
    /// spinners, and the checklist's step under way. Claude orange when not
    /// matching, or when the theme has neither an accent nor an orange.
    var working: Color {
        companionColors?.working?.color ?? ActivityBackground.claudeOrange
    }
}

extension TerminalTheme {
    /// The sidebar's palette: the app's own, with Claude at work in the
    /// theme's working color, so a busy row's timer and checklist bar
    /// match its tint instead of staying orange.
    var sidebarPalette: CompanionPalette {
        var palette = CompanionPalette.mac
        if let working = companionColors?.working?.color {
            palette.working = working
            palette.workingInk = working
        }
        return palette
    }
}

extension TerminalTheme {
    /// Behind a sheet: the theme's page color, or the usual sheet color
    /// when not matching.
    var sheetBackground: Color {
        colorScheme == nil ? Color(nsColor: .windowBackgroundColor) : canvas
    }

    /// Behind a text field in a sheet: a step up from the sheet in the
    /// theme, like the chat's compose field, or the usual field color.
    var sheetField: Color {
        colorScheme == nil ? Color(nsColor: .textBackgroundColor) : chatPalette.raised
    }
}

extension View {
    /// A sheet in the terminal theme's colors, light or dark to match, so
    /// it doesn't sit plain in front of a themed window. The usual sheet
    /// when not matching.
    func terminalSheet() -> some View {
        modifier(TerminalSheet())
    }

    /// Fills in the sidebar color when matching the terminal theme.
    func terminalPanelBackground() -> some View {
        modifier(TerminalPanelBackground())
    }

    /// Fills in the terminal background behind a project's tabs when
    /// matching the terminal theme, so the tab bar blends into it.
    func terminalCanvasBackground() -> some View {
        modifier(TerminalCanvasBackground())
    }

    /// Behind a project's tab bar and around its terminal card: the
    /// sidebars' color when matching the terminal theme, the window's
    /// otherwise.
    func terminalChromeBackground() -> some View {
        background(TerminalTheme.shared.panel ?? Color(nsColor: .windowBackgroundColor))
    }
}

// These keep one view structure whether matching is on or off, so turning
// it on or off doesn't rebuild the terminal views inside them.

private struct TerminalCanvasBackground: ViewModifier {
    func body(content: Content) -> some View {
        let theme = TerminalTheme.shared
        content.background(theme.colorScheme == nil ? Color.clear : theme.canvas)
    }
}

private struct TerminalSheet: ViewModifier {
    func body(content: Content) -> some View {
        content
            .presentationBackground(TerminalTheme.shared.sheetBackground)
            .terminalColorScheme()
    }
}

private struct TerminalPanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(TerminalTheme.shared.panel ?? .clear)
    }
}

/// Sets the appearance of the window it's in, and only that window. Unlike
/// preferredColorScheme, this leaves the app's own appearance alone (the
/// Mac's, or the one picked in Settings), which is what tells Ghostty to
/// switch light and dark themes.
struct WindowAppearance: NSViewRepresentable {
    let scheme: ColorScheme?

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.appearanceName = scheme.map { $0 == .dark ? .darkAqua : .aqua }
    }

    final class Probe: NSView {
        var appearanceName: NSAppearance.Name? {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            let wanted = appearanceName.flatMap(NSAppearance.init(named:))
            if window.appearance?.name != wanted?.name { window.appearance = wanted }
        }
    }
}

private struct TerminalColorScheme: ViewModifier {
    @Environment(\.colorScheme) private var system

    func body(content: Content) -> some View {
        let scheme = TerminalTheme.shared.colorScheme
        content
            .environment(\.colorScheme, scheme ?? system)
            .background(WindowAppearance(scheme: scheme))
    }
}

extension View {
    /// Goes light or dark with the terminal theme, for both SwiftUI and the
    /// AppKit views (sidebar, toolbar) in this window.
    func terminalColorScheme() -> some View { modifier(TerminalColorScheme()) }
}

/// The user's own Ghostty config files, checked for a theme or colors.
enum GhosttyConfigFiles {
    static var paths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let appSupport = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [xdg.appendingPathComponent("ghostty/config"), xdg.appendingPathComponent("ghostty/config.ghostty"),
                appSupport.appendingPathComponent("config"), appSupport.appendingPathComponent("config.ghostty")]
    }

    /// True when a config picks a theme or sets its own background, so
    /// following Ghostty shows colors the user chose.
    static var setsColors: Bool {
        paths.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.split(whereSeparator: \.isNewline).contains { line in
                let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
                return key == "theme" || key == "background"
            }
        }
    }
}
