import BenchKit
import SwiftUI
import WidgetKit

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
    /// False in a widget, which may be showing an old picture: a timer
    /// still counting there would look current.
    var ticks = true

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
        } else if let since = row.since, ticks {
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
    /// How wide the segments are together, or nil to fill the space.
    var width: CGFloat? = 34

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
            .frame(width: width, height: 4)
            .frame(maxWidth: width == nil ? .infinity : nil)
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

// MARK: - Widgets

extension DashboardLook {
    /// A widget's colors: the app's theme when it has one, else plain
    /// light or dark with Workbench's state colors.
    static func widget(_ snapshot: WidgetSnapshot?, scheme: ColorScheme) -> DashboardLook {
        if let colors = scheme == .dark ? snapshot?.dark : snapshot?.light {
            var look = DashboardLook(colors)
            // Solid: there's no wallpaper showing through a widget.
            look.background = look.background.opacity(1)
            return look
        }
        var look = DashboardLook.standard
        if scheme == .dark {
            look.background = Color(red: 0.11, green: 0.11, blue: 0.12)
        } else {
            look.background = .white
            look.ink = Color(red: 0.1, green: 0.1, blue: 0.11)
            look.waitingInk = Color(red: 0.48, green: 0.34, blue: 0.0)
        }
        return look
    }
}

/// The one thing to know, in the app's own words: how many sessions need
/// you, else how many are working, else that all is quiet.
struct StatusHeadline {
    var count: Int?
    var words: String
    var activity: String

    init(_ state: DashboardAttributes.ContentState) {
        if state.waiting > 0 {
            count = state.waiting
            words = state.waiting == 1 ? "needs you" : "need you"
            activity = "waiting"
        } else if state.working > 0 {
            count = state.working
            words = "working"
            activity = "working"
        } else if state.done > 0 {
            count = state.done
            words = "done"
            activity = "done"
        } else {
            count = nil
            words = "All quiet"
            activity = "idle"
        }
    }

    /// "2 need you", for VoiceOver and the one-line widgets.
    var sentence: String { count.map { "\($0) \(words)" } ?? words }
}

/// "as of 3:42 PM", once what's showing has gone a while without the app.
struct StatusAge: View {
    @Environment(\.dashboardLook) private var look
    let snapshot: WidgetSnapshot

    var body: some View {
        Text("as of \(snapshot.savedAt.formatted(date: .omitted, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(look.muted)
            .lineLimit(1)
    }
}

/// With nothing saved yet: the app hasn't been opened since pairing.
struct StatusEmpty: View {
    @Environment(\.dashboardLook) private var look
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Workbench")
                .font(.subheadline.weight(.semibold))
            Text(compact ? "Open the app to see your sessions." : "Open Workbench and pair with your Mac to see your sessions here.")
                .font(.caption)
                .foregroundStyle(look.muted)
        }
        .foregroundStyle(look.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The small Home Screen widget: the count that matters, large, with the
/// rest under it and the checklist of whatever is working.
struct StatusSmall: View {
    @Environment(\.dashboardLook) private var look
    let snapshot: WidgetSnapshot
    let isStale: Bool

    var body: some View {
        let state = snapshot.state
        let headline = StatusHeadline(state)
        let tint = look.color(for: headline.activity)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                DashboardGlyph(activity: headline.activity == "idle" ? "done" : headline.activity, size: 13)
                Text(snapshot.macName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(look.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let count = headline.count {
                Text("\(count)")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(headline.activity == "waiting" ? look.waitingInk : tint)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
            }
            Text(headline.words)
                .font(.system(headline.count == nil ? .title3 : .headline, design: .rounded, weight: .semibold))
                .foregroundStyle(look.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isStale {
                StatusAge(snapshot: snapshot)
            } else if headline.activity == "working", let row = state.rows.first(where: { $0.stepsTotal != nil }),
                      let done = row.stepsDone, let total = row.stepsTotal {
                // Only under "working": under "need you" it would read as
                // progress on the thing that's waiting.
                DashboardSteps(done: done, total: total, tint: look.color(for: row.activity), width: nil)
            } else if let rest = rest(state, besides: headline.activity) {
                Text(rest)
                    .font(.caption2)
                    .foregroundStyle(look.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(isStale ? 0.75 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.macName): \(headline.sentence)")
    }

    /// The states the headline didn't name: "1 working, 2 done".
    private func rest(_ state: DashboardAttributes.ContentState, besides shown: String) -> String? {
        var parts: [String] = []
        if shown != "working", state.working > 0 { parts.append("\(state.working) working") }
        if shown != "done", state.done > 0 { parts.append("\(state.done) done") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The medium Home Screen widget: the Lock Screen dashboard's rows.
struct StatusMedium: View {
    @Environment(\.dashboardLook) private var look
    let snapshot: WidgetSnapshot
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.macName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isStale { StatusAge(snapshot: snapshot) } else { DashboardSummary(state: snapshot.state, isStale: false) }
            }
            if snapshot.state.rows.isEmpty {
                DashboardNothing()
            } else {
                ForEach(Array(snapshot.state.rows.prefix(3).enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(look.ink.opacity(0.12)) }
                    DashboardRowView(row: row, showsText: true, ticks: false)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(look.ink)
        .opacity(isStale ? 0.75 : 1)
    }
}

/// The Lock Screen's round widget: a mark and a count.
struct StatusCircular: View {
    let state: DashboardAttributes.ContentState?

    var body: some View {
        let headline = state.map(StatusHeadline.init)
        VStack(spacing: 0) {
            Image(systemName: symbol(headline?.activity))
                .font(.system(size: 13, weight: .semibold))
            if let count = headline?.count {
                Text("\(count)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workbench: \(headline?.sentence ?? "Open the app")")
    }

    private func symbol(_ activity: String?) -> String {
        switch activity {
        case "waiting": "hand.raised.fill"
        case "working": "asterisk"
        case "done": "checkmark.circle.fill"
        case "idle": "checkmark"
        default: "macbook.and.iphone"
        }
    }
}

/// The Lock Screen's wide widget: the headline and the session behind it.
struct StatusRectangular: View {
    let snapshot: WidgetSnapshot?
    let isStale: Bool

    var body: some View {
        if let snapshot {
            let headline = StatusHeadline(snapshot.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline.sentence)
                    .font(.headline)
                    .widgetAccentable()
                if let row = snapshot.state.rows.first {
                    Text(row.project).font(.subheadline.weight(.medium))
                    Text(isStale ? "as of \(snapshot.savedAt.formatted(date: .omitted, time: .shortened))" : row.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(snapshot.macName).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Open Workbench to see your sessions.")
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
