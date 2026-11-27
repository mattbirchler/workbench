import Foundation
import Testing
@testable import Bench

/// Which look Workbench starts in, before Ghostty has loaded. The first
/// built-in theme drawn comes from this, so it has to match the one Ghostty
/// picks a moment later.
@MainActor
struct AppAppearanceTests {
    /// Whether a Mac in `mac` ("Dark" or "Light") with `mode` saved starts dark.
    private func startsDark(mode: String?, mac: String) -> Bool {
        let saved = [AppAppearance.key: mode, "AppleInterfaceStyle": mac]
        return AppAppearance.startsDark { saved[$0] ?? nil }
    }

    @Test func darkChoiceWinsOverALightMac() {
        #expect(startsDark(mode: "dark", mac: "Light"))
    }

    @Test func lightChoiceWinsOverADarkMac() {
        #expect(!startsDark(mode: "light", mac: "Dark"))
    }

    @Test func matchMacFollowsTheMac() {
        #expect(startsDark(mode: "system", mac: "Dark"))
        #expect(!startsDark(mode: "system", mac: "Light"))
    }

    @Test func missingOrUnknownChoiceFollowsTheMac() {
        #expect(startsDark(mode: nil, mac: "Dark"))
        #expect(!startsDark(mode: "sepia", mac: "Light"))
    }
}
