import BenchKit
import SwiftUI
import WidgetKit

// Live Activities reached the Mac in the macOS 27.3 SDK (Xcode 27.3, Swift
// 6.4.4). An older Xcode still has to build this target, since the app
// embeds it, so there it builds an extension with nothing in it.
#if compiler(>=6.4.4)
import ActivityKit

@main
struct BenchMacWidgets: WidgetBundle {
    var body: some Widget {
        if #available(macOS 27.3, *) {
            MacDashboardActivityWidget()
        }
    }
}

/// Every session on this Mac as a Live Activity: counts in the menu bar
/// (or the Dynamic Island on a MacBook that has one), and the roster when
/// it's opened. The drawing is the phone dashboard's (DashboardViews).
@available(macOS 27.3, *)
struct MacDashboardActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DashboardAttributes.self) { context in
            MacRoster(context: context)
        } dynamicIsland: { context in
            let state = context.state
            let look = DashboardLook.island(context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Workbench")
                        .font(MacRosterMetrics.title)
                        .lineLimit(1)
                        .padding(.leading, 10)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DashboardSummary(state: state, isStale: context.isStale, font: MacRosterMetrics.summary)
                        .padding(.trailing, 10)
                        .padding(.top, 4)
                        .environment(\.dashboardLook, look)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MacRosterRows(state: state)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .environment(\.dashboardLook, look)
                }
            } compactLeading: {
                Group {
                    if state.waiting > 0 {
                        DashboardCount(activity: "waiting", count: state.waiting)
                    } else if state.working > 0 {
                        DashboardCount(activity: "working", count: state.working)
                    } else {
                        DashboardCount(activity: "done", count: state.done)
                    }
                }
                .environment(\.dashboardLook, look)
            } compactTrailing: {
                Group {
                    if state.waiting > 0, state.working > 0 {
                        DashboardCount(activity: "working", count: state.working)
                    }
                }
                .environment(\.dashboardLook, look)
            } minimal: {
                DashboardGlyph(activity: state.waiting > 0 ? "waiting" : state.working > 0 ? "working" : "done", size: 14)
                    .environment(\.dashboardLook, look)
            }
        }
    }
}

/// The roster, opened from the menu bar.
@available(macOS 27.3, *)
private struct MacRoster: View {
    let context: ActivityViewContext<DashboardAttributes>
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = DashboardLook.lockScreen(context.attributes, scheme: scheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workbench")
                    .font(MacRosterMetrics.title)
                    .lineLimit(1)
                Spacer(minLength: 12)
                DashboardSummary(state: context.state, isStale: context.isStale, font: MacRosterMetrics.summary)
            }
            MacRosterRows(state: context.state)
        }
        .foregroundStyle(look.ink)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .environment(\.dashboardLook, look)
        .activityBackgroundTint(look.background)
        .activitySystemActionForegroundColor(look.ink)
    }
}

/// The Mac's text styles are small ones (a footnote is 10 points), fine in
/// a window and too small up here. The roster sets its own sizes.
private enum MacRosterMetrics {
    static let title = Font.system(size: 15, weight: .semibold)
    static let summary = Font.system(size: 12.5)
    static let row = Font.system(size: 13.5)
    static let trailing = Font.system(size: 12.5)
    static let icon: CGFloat = 24
}

/// A row per session: its project's icon and name, what it's doing, and
/// how it stands.
private struct MacRosterRows: View {
    let state: DashboardAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(state.rows) { row in
                MacRosterRow(row: row)
            }
            if state.rows.isEmpty {
                DashboardNothing().font(MacRosterMetrics.row)
            }
        }
    }
}

private struct MacRosterRow: View {
    @Environment(\.dashboardLook) private var look
    let row: DashboardRow

    private var needsYou: Bool { [.waiting, .attention].contains(row.kind) }

    var body: some View {
        HStack(spacing: 10) {
            MacProjectIcon(row: row, size: MacRosterMetrics.icon)
            HStack(spacing: 7) {
                Text(row.project)
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                Text(row.text)
                    .foregroundStyle(needsYou ? look.waitingInk : look.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let done = row.stepsDone, let total = row.stepsTotal, total > 0, !needsYou {
                DashboardSteps(done: done, total: total, tint: look.color(for: row.activity), width: 34, height: 5, textSize: 12)
            }
            HStack(spacing: 5) {
                DashboardGlyph(activity: row.activity, size: 15)
                trailing
                    .font(MacRosterMetrics.trailing)
                    .foregroundStyle(look.muted)
            }
        }
        .font(MacRosterMetrics.row)
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
                // Room for an hour and more: "1:02:33".
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// The project's icon, from the file the app left for it (DashboardIcons),
/// or a lettered tile when there's none to read.
private struct MacProjectIcon: View {
    let row: DashboardRow
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                let hue = IconTint.tileHue(for: row.project)
                LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.85),
                                        Color(hue: (hue + 0.04).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Text(row.project.prefix(1).uppercased())
                            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        guard let name = row.icon, let folder = DashboardIcons.folder else { return nil }
        return NSImage(contentsOf: folder.appendingPathComponent(name))
    }
}

#else

@main
struct BenchMacWidgets: WidgetBundle {
    var body: some Widget {
        NoWidget()
    }
}

struct NoWidget: Widget {
    var body: some WidgetConfiguration {
        EmptyWidgetConfiguration()
    }
}

#endif
