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
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DashboardSummary(state: state, isStale: context.isStale)
                        .padding(.trailing, 6)
                        .environment(\.dashboardLook, look)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ForEach(state.rows) { row in
                            DashboardRowView(row: row, showsText: true)
                        }
                        if state.rows.isEmpty { DashboardNothing() }
                    }
                    .padding(.horizontal, 6)
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
        DashboardRoster(macName: "Workbench", state: context.state, isStale: context.isStale)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .environment(\.dashboardLook, look)
            .activityBackgroundTint(look.background)
            .activitySystemActionForegroundColor(look.ink)
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
