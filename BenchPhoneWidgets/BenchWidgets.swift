import ActivityKit
import BenchKit
import SwiftUI
import WidgetKit

@main
struct BenchWidgets: WidgetBundle {
    var body: some Widget {
        DashboardActivityWidget()
        StatusWidget()
    }
}

/// What your Mac's sessions are up to, on the Home Screen and the Lock
/// Screen, for when no dashboard is running. It shows what the app last
/// saw, and says so once that's a while ago.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "me.birchtree.BenchPhone.status", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Sessions")
        .description("What needs you on your Mac, and what's working.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct StatusEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var isStale: Bool
}

struct StatusProvider: TimelineProvider {
    private static let sample = WidgetSnapshot(macName: "Mac Studio", state: .init(rows: [
        DashboardRow(id: UUID(), project: "Website", activity: "waiting", text: "Allow npm run build?"),
        DashboardRow(id: UUID(), project: "Recipes", activity: "working", text: "Adding a shopping list", stepsDone: 2, stepsTotal: 5),
    ], more: 0, working: 1, waiting: 1, done: 0))

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snapshot: Self.sample, isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        let saved = context.isPreview ? nil : WidgetSnapshot.load()
        completion(StatusEntry(date: .now, snapshot: saved ?? Self.sample, isStale: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date.now
        guard let saved = WidgetSnapshot.load() else {
            return completion(Timeline(entries: [StatusEntry(date: now, snapshot: nil, isStale: false)], policy: .never))
        }
        // As saved, then once more when it's old enough to say so. The
        // app reloads the widgets whenever it saves something new.
        var entries = [StatusEntry(date: now, snapshot: saved, isStale: saved.isStale(at: now))]
        let turnsStale = saved.savedAt.addingTimeInterval(WidgetSnapshot.staleAfter + 1)
        if turnsStale > now { entries.append(StatusEntry(date: turnsStale, snapshot: saved, isStale: true)) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

private struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: StatusEntry

    var body: some View {
        let look = DashboardLook.widget(entry.snapshot, scheme: scheme)
        switch family {
        case .accessoryCircular:
            StatusCircular(state: entry.snapshot?.state)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular:
            StatusRectangular(snapshot: entry.snapshot, isStale: entry.isStale)
                .containerBackground(for: .widget) { Color.clear }
        default:
            Group {
                if let snapshot = entry.snapshot {
                    if family == .systemMedium {
                        StatusMedium(snapshot: snapshot, isStale: entry.isStale)
                    } else {
                        StatusSmall(snapshot: snapshot, isStale: entry.isStale)
                    }
                } else {
                    StatusEmpty(compact: family == .systemSmall)
                }
            }
            .environment(\.dashboardLook, look)
            .containerBackground(for: .widget) { look.background }
        }
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
