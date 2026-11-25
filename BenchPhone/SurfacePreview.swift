#if DEBUG
import BenchKit
import SwiftUI

/// What the app shows outside itself, drawn inside it: the simulator
/// can't be locked from a script, so BENCH_SURFACE_SAMPLE=dashboard draws
/// the Lock Screen dashboard here, from the demo's sessions.
struct SurfacePreview: View {
    @Environment(CompanionClient.self) private var client
    let kind: String

    private var state: DashboardAttributes.ContentState {
        DashboardActivity.state(for: client.snapshot?.projects ?? [])
    }

    @Environment(\.colorScheme) private var scheme

    private var snapshot: WidgetSnapshot {
        WidgetSnapshot(macName: "Mac Studio", state: state, savedAt: .now.addingTimeInterval(-40 * 60),
                       light: DashboardColors(PhoneTheme.themePalette, scheme: .light),
                       dark: DashboardColors(PhoneTheme.themePalette, scheme: .dark))
    }

    /// BENCH_SURFACE_SAMPLE=widgets: the Home Screen widgets at their
    /// sizes on an iPhone, fresh and gone stale, then the Lock Screen ones.
    @ViewBuilder private var widgets: some View {
        let look = DashboardLook.widget(snapshot, scheme: scheme)
        var quiet: WidgetSnapshot { var copy = snapshot; copy.state = .init(rows: [], more: 0, working: 0, waiting: 0, done: 0); return copy }
        var busy: WidgetSnapshot {
            var copy = snapshot
            copy.state.rows.removeAll { $0.kind == .waiting }
            copy.state.waiting = 0
            return copy
        }
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                tile(look, width: 170) { StatusSmall(snapshot: snapshot, isStale: false) }
                tile(look, width: 170) { StatusSmall(snapshot: busy, isStale: false) }
            }
            HStack(spacing: 14) {
                tile(look, width: 170) { StatusSmall(snapshot: quiet, isStale: false) }
                tile(look, width: 170) { StatusSmall(snapshot: snapshot, isStale: true) }
            }
            tile(look, width: 354) { StatusMedium(snapshot: snapshot, isStale: false) }
            HStack(spacing: 14) {
                tile(look, width: 170) { StatusEmpty(compact: true) }
                VStack(spacing: 10) {
                    StatusCircular(state: snapshot.state)
                        .frame(width: 66, height: 66)
                        .background(.white.opacity(0.18), in: Circle())
                    StatusRectangular(snapshot: snapshot, isStale: false)
                        .frame(width: 160, height: 66)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private func tile(_ look: DashboardLook, width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(16)
            .frame(width: width, height: 170)
            .environment(\.dashboardLook, look)
            .background(look.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    var body: some View {
        ScrollView {
            if kind == "widgets" { widgets.padding(.vertical, 12) } else { dashboards }
        }
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.55, green: 0.32, blue: 0.5)],
                                   startPoint: .top, endPoint: .bottom))
        .task { if client.snapshot == nil { client.startDemo() } }
    }

    private var dashboards: some View {
            VStack(spacing: 18) {
                dashboard("Own colors", .standard)
                if let light = DashboardColors(PhoneTheme.themePalette, scheme: .light) { dashboard("Theme, light", DashboardLook(light)) }
                if let dark = DashboardColors(PhoneTheme.themePalette, scheme: .dark) { dashboard("Theme, dark", DashboardLook(dark)) }
            }
            .padding(12)
    }

    private func dashboard(_ title: String, _ look: DashboardLook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.8))
            DashboardRoster(macName: "Mac Studio", state: state, isStale: false)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .environment(\.dashboardLook, look)
                .background(look.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}
#endif
