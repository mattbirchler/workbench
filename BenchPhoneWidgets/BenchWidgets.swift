import ActivityKit
import BenchKit
import SwiftUI
import WidgetKit

@main
struct BenchWidgets: WidgetBundle {
    var body: some Widget {
        DashboardActivityWidget()
    }
}

/// Every session on a Mac, on the lock screen and in the Dynamic Island.
struct DashboardActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DashboardAttributes.self) { context in
            LockScreen(context: context)
        } dynamicIsland: { context in
            let state = context.state
            // The island is always black, so the theme's dark colors.
            let look = DashboardLook.island(context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.macName)
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
                        ForEach(state.rows.prefix(3)) { row in
                            DashboardRowView(row: row, showsText: false)
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
                    } else {
                        DashboardCount(activity: "working", count: state.working)
                    }
                }
                .environment(\.dashboardLook, look)
            } compactTrailing: {
                Group {
                    if state.waiting > 0, state.working > 0 {
                        DashboardCount(activity: "working", count: state.working)
                    } else if state.waiting == 0, state.done > 0 {
                        DashboardCount(activity: "done", count: state.done)
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

/// The dashboard on the Lock Screen, in the app's theme for the phone's
/// light or dark when it was given one.
private struct LockScreen: View {
    let context: ActivityViewContext<DashboardAttributes>
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = DashboardLook.lockScreen(context.attributes, scheme: scheme)
        DashboardRoster(macName: context.attributes.macName, state: context.state, isStale: context.isStale)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .environment(\.dashboardLook, look)
            .activityBackgroundTint(look.background)
            .activitySystemActionForegroundColor(look.ink)
    }
}
