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

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                dashboard("Own colors", .standard)
                if let light = DashboardColors(PhoneTheme.themePalette, scheme: .light) { dashboard("Theme, light", DashboardLook(light)) }
                if let dark = DashboardColors(PhoneTheme.themePalette, scheme: .dark) { dashboard("Theme, dark", DashboardLook(dark)) }
            }
            .padding(12)
        }
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.55, green: 0.32, blue: 0.5)],
                                   startPoint: .top, endPoint: .bottom))
        .task { if client.snapshot == nil { client.startDemo() } }
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
