import BenchKit
import Observation
import SwiftUI

/// Bench on the phone: graphite surfaces, cream ink, and the Mac's state
/// colors doing the talking. Light mode is a cool paper rather than a
/// warm one, so the state colors stand out.
///
/// When the Mac shares its terminal theme, the surfaces and text come from
/// that instead, and the app goes light or dark to match it.
enum PhoneTheme {
    static let working = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let remote = Color(red: 0.34, green: 0.55, blue: 0.82)
    static let waiting = Color(red: 0.95, green: 0.68, blue: 0.15)
    static let done = Color(red: 0.2, green: 0.75, blue: 0.4)
    static let attention = Color.blue
    /// Something went wrong or will be lost: a failed check, a deleted
    /// file, why a request didn't go through. Readable as text on both
    /// the light and dark surfaces.
    static let error = Color(light: Color(red: 0.80, green: 0.20, blue: 0.17), dark: Color(red: 0.96, green: 0.42, blue: 0.38))
    /// A merged pull request, in the purple GitHub uses for it.
    static let merged = Color(light: Color(red: 0.51, green: 0.31, blue: 0.87), dark: Color(red: 0.64, green: 0.48, blue: 0.95))

    /// Corner radii, so the same kind of thing is rounded the same.
    enum Radius {
        /// Small things inside a card: a thumbnail, an icon tile, the
        /// ring around a project icon.
        static let control: CGFloat = 12
        /// Cards, banners and panels.
        static let card: CGFloat = 18
        /// The message box.
        static let field: CGFloat = 22
    }

    /// The screen behind everything.
    static var canvas: Color { palette.canvas }
    /// Cards and panels.
    static var surface: Color { palette.surface }
    /// A step up from a surface: code, tool steps, the compose field.
    static var raised: Color { palette.raised }
    /// The theme's accent: buttons like Send, checkmarks, highlights.
    static var accent: Color { palette.accent }
    /// Text and icons drawn on the accent, like Send's arrow.
    static var onAccent: Color { palette.onAccent }
    static var ink: Color { palette.ink }
    static var inkMuted: Color { palette.inkMuted }
    static var hairline: Color { palette.hairline }

    /// An activity's color in the palette in use, so working and done
    /// follow the theme (working takes its accent, or its orange when the
    /// accent would look like another state).
    static func color(for activity: ActivityKind) -> Color? {
        palette.color(for: activity)
    }

    static func label(for activity: ActivityKind) -> String {
        CompanionPalette.label(for: activity)
    }

    /// The phone's own colors.
    static let standard = CompanionPalette(
        accent: CompanionPalette.ownAccent, onAccent: CompanionPalette.onOwnAccent, working: working, remote: remote, waiting: waiting, done: done, attention: attention,
        canvas: Color(light: Color(red: 0.945, green: 0.949, blue: 0.957), dark: Color(red: 0.082, green: 0.090, blue: 0.106)),
        surface: Color(light: .white, dark: Color(red: 0.118, green: 0.129, blue: 0.153)),
        raised: Color(light: Color(red: 0.965, green: 0.967, blue: 0.972), dark: Color(red: 0.149, green: 0.161, blue: 0.188)),
        ink: Color(light: Color(red: 0.106, green: 0.102, blue: 0.094), dark: Color(red: 0.925, green: 0.914, blue: 0.890)),
        inkMuted: Color(light: Color(red: 0.43, green: 0.42, blue: 0.40), dark: Color(red: 0.60, green: 0.59, blue: 0.56)),
        hairline: Color(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.08)))

    /// The colors in use: the Mac's terminal theme when it's on, the
    /// phone's own otherwise. Read in a view's body, so views follow
    /// theme changes.
    static var palette: CompanionPalette { MacTheme.shared.palette ?? standard }
    /// The theme you picked, or nil when the app is in its own colors.
    static var themePalette: CompanionPalette? { MacTheme.shared.palette }
}

/// Where the app's colors come from: the Mac's terminal theme (kept so the
/// app opens in it before it has reconnected), one of the built-in themes,
/// or the phone's own colors.
@MainActor
@Observable
final class MacTheme {
    enum Source: String, CaseIterable, Identifiable {
        case mac, builtIn, standard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mac: "Match Mac"
            case .builtIn: "Themes"
            case .standard: "Standard"
            }
        }
    }

    static let shared = MacTheme()
    private static let colorsKey = "macTerminalColors"
    private static let enabledKey = "matchesMacTheme"
    private static let sourceKey = "themeSource"
    private static let lightKey = "builtInLightTheme"
    private static let darkKey = "builtInDarkTheme"

    /// The latest colors from the Mac, or nil when it isn't sharing any.
    private(set) var colors: TerminalColors?
    /// Settings' choice. Matches the Mac unless changed.
    var source: Source {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            rebuild()
        }
    }
    var lightThemeID: String {
        didSet {
            UserDefaults.standard.set(lightThemeID, forKey: Self.lightKey)
            rebuild()
        }
    }
    var darkThemeID: String {
        didSet {
            UserDefaults.standard.set(darkThemeID, forKey: Self.darkKey)
            rebuild()
        }
    }
    private(set) var palette: CompanionPalette?
    /// True when a screenshot run set the colors, so the Mac (or the demo)
    /// doesn't replace them.
    @ObservationIgnored private var isPinned = false

    /// Light or dark to match the Mac's theme, or nil to follow the phone.
    /// Built-in themes have a version for each, so they follow the phone.
    var colorScheme: ColorScheme? {
        guard source == .mac, let colors else { return nil }
        return colors.isDark ? .dark : .light
    }

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Self.sourceKey).flatMap(Source.init(rawValue:)) {
            source = saved
        } else {
            // Before the choice, a switch turned matching the Mac off.
            source = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey) ? .mac : .standard
        }
        lightThemeID = defaults.string(forKey: Self.lightKey) ?? BuiltInTheme.defaultLightID
        darkThemeID = defaults.string(forKey: Self.darkKey) ?? BuiltInTheme.defaultDarkID
        colors = defaults.data(forKey: Self.colorsKey).flatMap { try? JSONDecoder().decode(TerminalColors.self, from: $0) }
        #if DEBUG
        // Screenshots: "1f2026,dedfe4" (and optionally a third color for
        // inline code) themes the app without a Mac.
        if let sample = ProcessInfo.processInfo.environment["BENCH_PHONE_THEME"] {
            colors = Self.parse(sample)
            source = .mac
            isPinned = true
        }
        #endif
        rebuild()
    }

    func update(_ colors: TerminalColors?) {
        guard colors != self.colors, !isPinned else { return }
        self.colors = colors
        UserDefaults.standard.set(colors.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.colorsKey)
        rebuild()
    }

    private func rebuild() {
        switch source {
        case .mac:
            palette = colors.map { PhoneTheme.standard.themed(with: $0) }
        case .builtIn:
            let light = BuiltInTheme.named(lightThemeID) ?? .defaultLight
            let dark = BuiltInTheme.named(darkThemeID) ?? .defaultDark
            palette = .appearance(light: PhoneTheme.standard.themed(with: light.terminalColors),
                                  dark: PhoneTheme.standard.themed(with: dark.terminalColors))
        case .standard:
            palette = nil
        }
    }

    #if DEBUG
    private static func parse(_ text: String) -> TerminalColors? {
        let parts = text.split(separator: ",").map { String($0) }
        guard parts.count >= 2, let bg = rgb(parts[0]), let fg = rgb(parts[1]) else { return nil }
        return TerminalColors(background: bg, foreground: fg, code: parts.count > 2 ? rgb(parts[2]) : nil)
    }

    private static func rgb(_ hex: String) -> TerminalColors.RGB? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return TerminalColors.RGB(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }
    #endif
}

extension View {
    /// Widens what answers a touch, without moving or resizing anything:
    /// a 36-point button with 4 points each way takes a touch across 44.
    /// Put it on a button's label.
    func touchArea(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }
}

/// What to call the device the app is running on, so an iPad isn't told
/// about "your iPhone".
@MainActor
enum Device {
    /// "iPhone" or "iPad".
    static var name: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    /// "This iPhone" or "This iPad", to start a sentence.
    static var thisName: String { "This \(name)" }
}

/// The picture for an empty state with no drawing of its own: an SF Symbol
/// in a soft circle of the accent. It settles into place as the state
/// arrives, unless motion is reduced.
struct EmptyStateSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String
    let appeared: Bool

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(PhoneTheme.accent)
            .frame(width: 84, height: 84)
            .background(PhoneTheme.accent.opacity(0.14), in: Circle())
            .overlay(Circle().strokeBorder(PhoneTheme.accent.opacity(0.22), lineWidth: 1))
            .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
            .animation(.spring(duration: 0.4, bounce: 0.25), value: appeared)
    }
}

extension EmptyStateScaffold where Illustration == EmptyStateSymbol, Accessory == EmptyView {
    /// The app's empty state with a symbol for its picture, so screens
    /// without an illustration still share the type and spacing of the
    /// ones that have one.
    init(title: String, message: String = "", symbol: String, size: Size = .regular) {
        self.init(title: title, message: message, size: size) { EmptyStateSymbol(name: symbol, appeared: $0) }
    }
}

/// The main button on a screen: a capsule in the accent, about 50 points
/// tall and as wide as it's allowed, dimmed while it can't be used.
/// `fullWidth: false` is the same button at the size of its label, for
/// the end of a row.
struct PhonePrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    /// Draws the button it can't use yet as a plain outline with muted
    /// text, for a screen where it sits in view the whole time and a
    /// dimmed accent would be a big pale slab.
    var quietWhenDisabled = false
    @Environment(\.isEnabled) private var isEnabled

    private var isQuiet: Bool { quietWhenDisabled && !isEnabled }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(fullWidth ? .headline : .subheadline.weight(.semibold))
            .foregroundStyle(isQuiet ? PhoneTheme.inkMuted : PhoneTheme.onAccent)
            .tint(isQuiet ? PhoneTheme.inkMuted : PhoneTheme.onAccent)
            .padding(.horizontal, fullWidth ? 0 : 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 50 : 36)
            .background {
                if isQuiet {
                    Capsule().fill(PhoneTheme.surface)
                    Capsule().strokeBorder(PhoneTheme.hairline)
                } else {
                    Capsule().fill(PhoneTheme.accent.gradient)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : (isQuiet ? 1 : 0.4))
            // Gives a little under the finger, as Start Claude always did.
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PhonePrimaryButtonStyle {
    /// The main button on a screen.
    static var phonePrimary: PhonePrimaryButtonStyle { PhonePrimaryButtonStyle() }
    /// The main button, at the size of its label.
    static var phonePrimaryCompact: PhonePrimaryButtonStyle { PhonePrimaryButtonStyle(fullWidth: false) }
}
