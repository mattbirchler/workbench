import BenchKit
import SwiftUI
import WidgetKit

/// Keeps the widgets' picture of the Mac current while the app is open.
/// Widgets can't reach the Mac themselves, so this is all they know.
@MainActor
enum WidgetFeed {
    private static var saved: WidgetSnapshot?

    /// Saves what the app is showing, if the widgets would look different.
    /// `force` saves anyway, so the widgets count their age from now: for
    /// when the app is leaving the screen.
    static func update(from client: CompanionClient, force: Bool = false) {
        // Sample sessions aren't yours, and a list from before isn't news.
        guard !client.isDemo, !client.isShowingSaved, let projects = client.snapshot?.projects, let macName = client.macName else { return }
        let snapshot = WidgetSnapshot(macName: macName, state: DashboardActivity.state(for: projects),
                                      light: DashboardColors(PhoneTheme.themePalette, scheme: .light),
                                      dark: DashboardColors(PhoneTheme.themePalette, scheme: .dark))
        if !force, let saved {
            if saved.shows(sameAs: snapshot) { return }
            // What a busy session is doing changes every few seconds. The
            // counts and who's asking are worth a reload at once; the
            // rest can wait a little.
            let sameShape = saved.state.rows.map(\.id) == snapshot.state.rows.map(\.id)
                && saved.state.rows.map(\.activity) == snapshot.state.rows.map(\.activity)
                && (saved.state.waiting, saved.state.working, saved.state.done) == (snapshot.state.waiting, snapshot.state.working, snapshot.state.done)
            if sameShape, snapshot.savedAt.timeIntervalSince(saved.savedAt) < 30 { return }
        }
        saved = snapshot
        WidgetSnapshot.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Empties the widgets, for when the phone has no Mac any more.
    static func clear() {
        saved = nil
        WidgetSnapshot.save(nil)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
