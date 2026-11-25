import BenchKit
import SwiftUI

// The dashboard's drawing, apart from the Live Activity that shows it, so
// the app can draw the same thing (a debug build does, to look it over).

/// The lock screen view: a header, then one row per session.
struct DashboardRoster: View {
    @Environment(\.dashboardLook) private var look
    let macName: String
    let state: DashboardAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(macName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                DashboardSummary(state: state, isStale: isStale)
            }
            if state.rows.isEmpty {
                DashboardNothing()
            } else {
                ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(look.ink.opacity(0.12)) }
                    DashboardRowView(row: row, showsText: true)
                }
            }
        }
        .foregroundStyle(look.ink)
    }
}

/// "2 working · 1 needs you", or a warning when the Mac's gone quiet.
struct DashboardSummary: View {
    @Environment(\.dashboardLook) private var look
    let state: DashboardAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Group {
            if isStale {
                Text("Mac not updating")
                    .foregroundStyle(look.muted)
            } else {
                let parts = parts
                if let first = parts.first {
                    parts.dropFirst().reduce(first) { $0 + Text(" · ").foregroundStyle(look.muted) + $1 }
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private var parts: [Text] {
        var parts: [Text] = []
        if state.working > 0 { parts.append(Text("\(state.working) working").foregroundStyle(look.muted)) }
        if state.waiting > 0 { parts.append(Text("\(state.waiting) need\(state.waiting == 1 ? "s" : "") you").foregroundStyle(look.waitingInk)) }
        if parts.isEmpty, state.done > 0 { parts.append(Text("\(state.done) done").foregroundStyle(look.muted)) }
        if state.more > 0 { parts.append(Text("+\(state.more) more").foregroundStyle(look.muted)) }
        return parts
    }
}

struct DashboardRowView: View {
    @Environment(\.dashboardLook) private var look
    let row: DashboardRow
    /// False in the Dynamic Island, where there's room for less.
    let showsText: Bool

    private var needsYou: Bool { [.waiting, .attention].contains(row.kind) }

    var body: some View {
        HStack(spacing: 8) {
            DashboardGlyph(activity: row.activity, size: 15)
            HStack(spacing: 6) {
                Text(row.project)
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                if showsText {
                    Text(row.text)
                        .foregroundStyle(needsYou ? look.waitingInk : look.muted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let done = row.stepsDone, let total = row.stepsTotal, total > 0, !needsYou {
                DashboardSteps(done: done, total: total, tint: look.color(for: row.activity))
            }
            trailing
                .font(.caption)
                .foregroundStyle(look.muted)
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var trailing: some View {
        if row.kind == .done {
            switch row.checks {
            case "passing": Text("PR ✓").foregroundStyle(look.color(for: "done"))
            case "failing": Text("PR ✗").foregroundStyle(.red)
            case "pending": Text("PR …")
            default: Text("Done")
            }
        } else if let since = row.since {
            Text(timerInterval: since...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 52, alignment: .trailing)
        }
    }
}

/// The checklist as the app draws it on a row: a segment per step, the
/// done ones filled and the current one half lit, then "2/5". Lists too
/// long for segments this small become one bar.
struct DashboardSteps: View {
    @Environment(\.dashboardLook) private var look
    let done: Int
    let total: Int
    let tint: Color

    private static let segmentLimit = 8

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if total <= Self.segmentLimit {
                    HStack(spacing: 1.5) {
                        ForEach(0..<total, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(index < done ? tint : index == done ? tint.opacity(0.45) : look.ink.opacity(0.16))
                        }
                    }
                } else {
                    Capsule().fill(look.ink.opacity(0.16))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint)
                                .scaleEffect(x: min(1, Double(done) / Double(total)), y: 1, anchor: .leading)
                        }
                }
            }
            .frame(width: 34, height: 4)
            Text("\(done)/\(total)")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .fixedSize()
        }
        .accessibilityElement()
        .accessibilityLabel("\(done) of \(total) steps done")
    }
}

struct DashboardNothing: View {
    @Environment(\.dashboardLook) private var look

    var body: some View {
        Text("DashboardNothing running right now")
            .font(.footnote)
            .foregroundStyle(look.muted)
    }
}

/// A state's glyph and how many sessions are in it, for the compact island.
struct DashboardCount: View {
    @Environment(\.dashboardLook) private var look
    let activity: String
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            DashboardGlyph(activity: activity, size: 13)
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(look.color(for: activity))
        }
    }
}

/// Claude's symbol for working, a raised hand for waiting, a check for done.
struct DashboardGlyph: View {
    @Environment(\.dashboardLook) private var look
    let activity: String
    let size: CGFloat

    var body: some View {
        let color = look.color(for: activity)
        switch activity {
        case "waiting", "attention":
            Image(systemName: "hand.raised.fill")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size * 0.95, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        default:
            Text("✻\u{FE0E}")
                .font(.system(size: size * 1.05, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }
}

/// The colors the dashboard draws with: its own, or the app's theme.
struct DashboardLook {
    var background: Color
    var ink: Color
    var working: Color
    var remote: Color
    var waiting: Color
    var done: Color
    /// `waiting` for words rather than marks.
    var waitingInk: Color

    var muted: Color { ink.opacity(0.6) }

    /// White on dark glass, with Workbench's own state colors.
    static let standard = DashboardLook(background: Color.black.opacity(0.55), ink: .white,
                               working: Color(red: 0.85, green: 0.47, blue: 0.34),
                               remote: Color(red: 0.42, green: 0.45, blue: 0.95),
                               waiting: Color(red: 0.95, green: 0.68, blue: 0.15),
                               done: Color(red: 0.2, green: 0.75, blue: 0.4))

    init(background: Color, ink: Color, working: Color, remote: Color, waiting: Color, done: Color) {
        self.background = background
        self.ink = ink
        self.working = working
        self.remote = remote
        self.waiting = waiting
        self.done = done
        self.waitingInk = waiting
    }

    init(_ colors: DashboardColors) {
        // A little see-through, like the dashboard's own background, so
        // the wallpaper still shows.
        self.init(background: Self.color(colors.background).opacity(0.88), ink: Self.color(colors.ink),
                  working: Self.color(colors.working), remote: Self.color(colors.remote),
                  waiting: Self.color(colors.waiting), done: Self.color(colors.done))
        if let ink = colors.waitingInk { waitingInk = Self.color(ink) }
    }

    static func lockScreen(_ attributes: DashboardAttributes, scheme: ColorScheme) -> DashboardLook {
        (scheme == .dark ? attributes.dark : attributes.light).map(DashboardLook.init) ?? .standard
    }

    /// In the Dynamic Island: the theme's state colors, on the island's
    /// own black with white text.
    static func island(_ attributes: DashboardAttributes) -> DashboardLook {
        guard let colors = attributes.dark else { return .standard }
        var look = DashboardLook(colors)
        look.background = .black
        look.ink = .white
        look.waitingInk = look.waiting
        return look
    }

    func color(for activity: String) -> Color {
        switch activity {
        case "working": working
        case "remoteWorking": remote
        case "waiting", "attention": waiting
        case "done": done
        default: muted
        }
    }

    private static func color(_ hex: String) -> Color {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    @Entry var dashboardLook: DashboardLook = .standard
}
