import AppKit
import BenchKit
import SwiftUI

/// The chat's fonts and text size, as chosen in Settings and with ⌘+ / ⌘−.
/// Nil families mean the system's fonts.
@MainActor
@Observable
final class ChatTypography {
    static let shared = ChatTypography()

    static let textFontKey = "chatTextFont"
    static let codeFontKey = "chatCodeFont"
    static let scaleKey = "chatTextScale"

    /// The sizes ⌘+ and ⌘− step through.
    static let scales: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6]

    /// The chosen family for words, or nil for the system font.
    var textFamily: String? {
        didSet { UserDefaults.standard.set(textFamily, forKey: Self.textFontKey) }
    }

    /// The chosen family for code, or nil for the system's monospaced font.
    var codeFamily: String? {
        didSet { UserDefaults.standard.set(codeFamily, forKey: Self.codeFontKey) }
    }

    /// 1 is the usual size.
    var scale: Double {
        didSet { UserDefaults.standard.set(scale, forKey: Self.scaleKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        textFamily = defaults.string(forKey: Self.textFontKey)
        codeFamily = defaults.string(forKey: Self.codeFontKey)
        let saved = defaults.double(forKey: Self.scaleKey)
        scale = Self.scales.contains(saved) ? saved : 1
    }

    // MARK: Size

    var canZoomIn: Bool { scale < Self.scales.last! }
    var canZoomOut: Bool { scale > Self.scales.first! }
    var isDefaultSize: Bool { scale == 1 }

    func zoomIn() {
        if let next = Self.scales.first(where: { $0 > scale + 0.001 }) { scale = next }
    }

    func zoomOut() {
        if let next = Self.scales.last(where: { $0 < scale - 0.001 }) { scale = next }
    }

    func resetSize() { scale = 1 }

    // MARK: Fonts

    /// A font for words, at a size given for 100%.
    func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let size = size * scale
        if let family = Self.installed(textFamily) {
            return Font.custom(family, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    /// A font for code, at a size given for 100%.
    func code(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let size = size * scale
        if let family = Self.installed(codeFamily) {
            return Font.custom(family, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    var steps: StepFonts {
        StepFonts(text: text(12.5), mono: code(12), monoSmall: code(11.5), caption: text(11), scale: scale)
    }

    /// The cards above the message box (a question, a permission, a side
    /// question, compacting): one corner radius, one border and one title
    /// for all of them, in the chat's fonts so they grow with ⌘+. The
    /// radius is the message box's, which they sit on top of.
    var dockCards: DockCardStyle {
        DockCardStyle(radius: Self.dockRadius, borderWidth: 1,
                      title: text(13, weight: .semibold), heading: text(13.5), body: text(12.5), caption: text(11),
                      action: text(12.5), compactActions: true)
    }

    /// The corner radius of everything floating at the foot of the chat.
    static let dockRadius: CGFloat = 18

    /// Headings step up from the 13.5pt body (17, 15, then the body's size
    /// in semibold), and code blocks and tables sit just under it, close
    /// to the 12.5pt inline code.
    var markdown: MarkdownFonts {
        let customized = Self.installed(textFamily) != nil || Self.installed(codeFamily) != nil
        var fonts = MarkdownFonts(
            heading1: text(17, weight: .bold),
            heading2: text(15, weight: .bold),
            heading3: text(13.5, weight: .semibold),
            code: code(12),
            tableHeader: text(12, weight: .semibold),
            table: text(12),
            // Left to SwiftUI unless a font is chosen, since it can't find a
            // monospaced version of most families.
            inlineCode: customized ? code(12.5) : nil)
        // Replies' prose, as one text view so it selects across lines.
        // Sizes match ChatStyle.body and the headings above.
        fonts.prose = ProseFonts(textFamily: Self.installed(textFamily), codeFamily: Self.installed(codeFamily),
                                 bodySize: 13.5, codeSize: 12.5, heading1Size: 17, heading2Size: 15,
                                 heading3Size: 13.5, lineSpacing: 2, scale: scale)
        return fonts
    }

    /// The same Markdown a step up in size, for reading a whole Markdown
    /// file in its tab: a 15pt body with headings stepping up to 24.
    var readingMarkdown: MarkdownFonts {
        let customized = Self.installed(textFamily) != nil || Self.installed(codeFamily) != nil
        var fonts = MarkdownFonts(
            heading1: text(24, weight: .bold),
            heading2: text(19, weight: .bold),
            heading3: text(16, weight: .semibold),
            code: code(13),
            tableHeader: text(13.5, weight: .semibold),
            table: text(13.5),
            inlineCode: customized ? code(14) : nil)
        fonts.prose = ProseFonts(textFamily: Self.installed(textFamily), codeFamily: Self.installed(codeFamily),
                                 bodySize: 15, codeSize: 14, heading1Size: 24, heading2Size: 19,
                                 heading3Size: 16, lineSpacing: 4, scale: scale)
        return fonts
    }

    // MARK: Families

    /// The family, if it's still installed. One that's been removed falls
    /// back to the system font without forgetting the choice.
    private static func installed(_ family: String?) -> String? {
        guard let family, availableFamilies.contains(family) else { return nil }
        return family
    }

    /// Looked up once, and again whenever the menus are built, so a font
    /// installed while Workbench is open can still be picked.
    private static var availableFamilies = Set(NSFontManager.shared.availableFontFamilies)

    /// Every family on this Mac, for the text font menu.
    static func allFamilies() -> [String] {
        let families = NSFontManager.shared.availableFontFamilies
        availableFamilies = Set(families)
        return families
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The families whose letters are all the same width, for the code font menu.
    static func monospacedFamilies() -> [String] {
        allFamilies().filter { family in
            guard let member = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first,
                  let name = member.first as? String,
                  let font = NSFont(name: name, size: 12) else { return false }
            return font.isFixedPitch
        }
    }
}
