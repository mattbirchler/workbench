// Live Activities came to the Mac with macOS 27.3, whose SDK ships with
// Swift 6.4.4. Older toolchains build Workbench without this.
#if compiler(>=6.4.4)
import ActivityKit
import AppKit
import BenchKit
import SwiftUI

/// The sessions dashboard as a Live Activity: counts in the menu bar (or
/// the Dynamic Island on a MacBook with one), and the roster when you open
/// it. The same thing the phone puts on its Lock Screen, but started and
/// updated right here, with no push involved. The BenchWidgets extension
/// draws it.
///
/// It's there while anything is working, waiting, or recently finished,
/// and goes away once all is quiet. Off until you turn it on in Settings.
@available(macOS 27.3, *)
@MainActor
final class MenuBarActivity {
    /// The setting that shows it. Off unless you turn it on.
    static let shownKey = "showsLiveActivity"
    static var isShown: Bool { UserDefaults.standard.bool(forKey: shownKey) }

    private let store: AppStore
    private let terminals: TerminalManager
    private var activity: Handle?
    private var shown: DashboardAttributes.ContentState?
    /// True from a change until the activity catches up, so a burst of
    /// changes costs one update.
    private var refreshQueued = false
    private var removed = false
    /// Starts, updates and ends happen one at a time, in order.
    private var work: Task<Void, Never>?
    /// Finished sessions drop off the dashboard after a while, with no
    /// change in the store to say so.
    private var timer: Timer?

    init(store: AppStore, terminals: TerminalManager) {
        self.store = store
        self.terminals = terminals
        // One left behind by a copy of the app that quit or crashed.
        let leftovers = Activity<DashboardAttributes>.activities.map(Handle.init)
        enqueue {
            for old in leftovers { await old.end() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRefresh() }
        }
        refresh()
    }

    /// Ends the activity, for when the setting is turned off or the app quits.
    func remove() {
        removed = true
        timer?.invalidate()
        end()
    }

    private func refresh() {
        refreshQueued = false
        guard !removed else { return }
        let state = withObservationTracking {
            Self.state(OverviewView.items(store: store, terminals: terminals))
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.queueRefresh() }
        }
        guard state != shown else { return }
        let before = shown
        shown = state
        guard state.working + state.waiting + state.done > 0 else { return end() }

        // Opens the roster by itself when another session starts waiting.
        var alert: AlertConfiguration?
        if state.waiting > (before?.waiting ?? 0), let row = state.rows.first {
            alert = AlertConfiguration(title: "\(row.project) needs you", body: "\(row.text)", sound: .default)
        }
        let content = ActivityContent(state: state, staleDate: nil)
        enqueue { [weak self] in
            guard let self else { return }
            if let activity = self.activity, activity.activity.activityState == .active {
                await activity.update(content, alert: alert)
            } else {
                do {
                    let started = try Activity.request(attributes: DashboardAttributes(macName: Self.macName),
                                                       content: content, pushType: nil)
                    NSLog("MenuBarActivity: started %@", started.id)
                    self.activity = Handle(activity: started)
                } catch {
                    NSLog("MenuBarActivity: couldn't start: %@", String(describing: error))
                    // Try again on the next change.
                    self.shown = nil
                }
            }
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        enqueue { await activity.end() }
    }

    private func queueRefresh() {
        guard !refreshQueued, !removed else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let earlier = work
        work = Task {
            await earlier?.value
            await step()
        }
    }

    /// An activity, to hand to its own calls off the main actor. `Activity`
    /// isn't marked Sendable, though its calls are made to be used this way.
    private nonisolated struct Handle: @unchecked Sendable {
        let activity: Activity<DashboardAttributes>

        @concurrent
        func update(_ content: ActivityContent<DashboardAttributes.ContentState>, alert: AlertConfiguration?) async {
            await activity.update(content, alertConfiguration: alert)
        }

        @concurrent
        func end() async {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static var macName: String { Host.current().localizedName ?? "Mac" }

    /// The dashboard for the sessions as the overview lists them: what
    /// needs you first, then what's working, then what just finished.
    static func state(_ items: [OverviewItem], now: Date = .now) -> DashboardAttributes.ContentState {
        var rows: [DashboardRow] = []
        var working = 0, waiting = 0, done = 0
        for item in items {
            let details = item.details
            let kind = CompanionSnapshots.kind(item.activity).rawValue
            func row(_ text: String, since: Date? = nil) -> DashboardRow {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                return DashboardRow(id: item.id, project: item.project.name, activity: kind,
                                    text: line.count > 80 ? String(line.prefix(79)) + "…" : line, since: since)
            }
            switch item.activity {
            case .waiting:
                waiting += 1
                rows.append(row(details?.question ?? "Waiting for you", since: details?.questionAt ?? details?.promptAt))
            case .attention:
                waiting += 1
                rows.append(row("Needs attention"))
            case .working, .remoteWorking:
                working += 1
                let steps = item.session?.visibleChecklist
                let step = steps?.first { $0.status == .inProgress }?.label
                let text = details?.plainAction ?? details?.action ?? step
                    ?? item.session?.remoteHost.map { "Working on \($0)" } ?? "Working"
                var row = row(text, since: item.session?.activeSince ?? details?.promptAt)
                if let steps, !steps.isEmpty {
                    row.stepsDone = steps.doneCount
                    row.stepsTotal = steps.count
                }
                rows.append(row)
            case .done:
                guard let stopped = details?.stoppedAt, now.timeIntervalSince(stopped) < DashboardActivity.doneFor else { continue }
                done += 1
                rows.append(row(details?.summary ?? "Finished"))
            case .idle:
                continue
            }
        }
        // The items come ranked, needs-you first.
        let shown = Array(rows.prefix(DashboardActivity.maxRows))
        return .init(rows: shown, more: rows.count - shown.count, working: working, waiting: waiting, done: done)
    }
}
#endif
