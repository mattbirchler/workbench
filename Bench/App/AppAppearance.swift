import AppKit
import Observation

/// Whether Workbench follows the Mac's light or dark appearance, or always
/// stays one of them. Settings › Appearance. Setting the app's appearance
/// carries through to everything else: the terminal tabs and built-in themes
/// watch it, and Ghostty's own light and dark themes switch with it.
@MainActor @Observable
final class AppAppearance {
    static let shared = AppAppearance()
    static let key = "appearanceMode"

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "Match Mac"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        mode = UserDefaults.standard.string(forKey: Self.key).flatMap(Mode.init(rawValue:)) ?? .system
    }

    func apply() {
        NSApplication.shared.appearance = mode.appearance
    }

    /// Whether Workbench is dark at launch: the choice in Settings, or the
    /// Mac's own appearance when following it. Read from the settings
    /// rather than NSApp, which may not have settled this early. `setting`
    /// reads a saved value by key.
    static func startsDark(_ setting: (String) -> String? = { UserDefaults.standard.string(forKey: $0) }) -> Bool {
        switch setting(key).flatMap(Mode.init(rawValue:)) ?? .system {
        case .dark: true
        case .light: false
        case .system: setting("AppleInterfaceStyle") == "Dark"
        }
    }
}
