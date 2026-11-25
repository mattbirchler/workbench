import ActivityKit
import BenchKit
import Foundation
import Observation
import SwiftUI

/// The lock screen dashboard: one Live Activity listing what every session
/// on the Mac is up to. It only starts when you ask for it. The Mac pushes
/// its updates, so this just hands it the token.
@Observable
final class ActivityManager {
    @ObservationIgnored weak var client: CompanionClient?
    @ObservationIgnored private var watchers: [String: Task<Void, Never>] = [:]
    /// The Macs whose dashboards are on the lock screen, by name.
    private(set) var showing: Set<String> = []

    /// Notifications from the Mac. The dashboard depends on the same
    /// setup on the Mac, so it's off when they are.
    private(set) var notificationsOn = PhoneNotifications.isOn

    var isAvailable: Bool {
        guard let client else { return false }
        #if DEBUG
        // BENCH_SHOW_DASHBOARD=1 starts it from demo data, for screenshots.
        if ProcessInfo.processInfo.environment["BENCH_SHOW_DASHBOARD"] != nil { return true }
        #endif
        return notificationsOn && !client.isDemo && client.canShowDashboard && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// True when the connected Mac's dashboard is on the lock screen.
    var isShowing: Bool { client?.macName.map(showing.contains) ?? false }

    /// Turns notifications on or off from the menu.
    func setNotifications(_ on: Bool) async {
        if on {
            notificationsOn = await PhoneNotifications.turnOn()
        } else {
            PhoneNotifications.turnOff()
            notificationsOn = false
            for activity in Activity<DashboardAttributes>.activities { end(activity) }
        }
    }

    /// Call once the client is connected: picks up a dashboard that's
    /// already running, and clears away the one-session activities older
    /// builds started.
    func start() {
        Task {
            await PhoneNotifications.settle()
            notificationsOn = PhoneNotifications.isOn
            for activity in Activity<BenchActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            for activity in Activity<DashboardAttributes>.activities { track(activity) }
        }
    }

    /// Puts the connected Mac's dashboard on the lock screen.
    func showDashboard() {
        guard isAvailable, !isShowing, let client, let macName = client.macName ?? (client.isDemo ? "Mac Studio" : nil) else { return }
        let state = DashboardActivity.state(for: client.snapshot?.projects ?? [])
        do {
            // The theme as it is now. A dashboard keeps the colors it
            // started with, so a change of theme shows on the next one.
            let attributes = DashboardAttributes(macName: macName, light: DashboardColors(PhoneTheme.themePalette, scheme: .light),
                                                 dark: DashboardColors(PhoneTheme.themePalette, scheme: .dark))
            let activity = try Activity.request(attributes: attributes,
                                                content: .init(state: state, staleDate: .now.addingTimeInterval(DashboardActivity.staleAfter)),
                                                pushType: .token)
            track(activity)
        } catch {
            client.notePushProblem("Couldn't start the Lock Screen dashboard: \(error.localizedDescription)")
        }
    }

    func hideDashboard() {
        guard let macName = client?.macName else { return }
        for activity in Activity<DashboardAttributes>.activities where activity.attributes.macName == macName { end(activity) }
    }

    private func end(_ activity: Activity<DashboardAttributes>) {
        showing.remove(activity.attributes.macName)
        if let token = activity.pushToken, activity.attributes.macName == client?.macName {
            client?.registerDashboard(token: Self.hex(token), ended: true)
        }
        let id = activity.id
        Task {
            for activity in Activity<DashboardAttributes>.activities where activity.id == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func track(_ activity: Activity<DashboardAttributes>) {
        let macName = activity.attributes.macName
        showing.insert(macName)
        watchers[activity.id]?.cancel()
        watchers[activity.id] = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                await MainActor.run {
                    guard self?.client?.macName == macName else { return }
                    self?.client?.registerDashboard(token: Self.hex(data))
                }
            }
        }
        Task { [weak self] in
            // iOS ends it after 8 hours, or you swipe it away.
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                await MainActor.run {
                    self?.showing.remove(macName)
                    self?.watchers[activity.id]?.cancel()
                    self?.watchers[activity.id] = nil
                    if let token = activity.pushToken, self?.client?.macName == macName {
                        self?.client?.registerDashboard(token: Self.hex(token), ended: true)
                    }
                }
            }
        }
    }

    /// Re-sends the token after a reconnect, since the Mac may have
    /// restarted and forgotten it.
    func resendTokens() {
        for activity in Activity<DashboardAttributes>.activities where activity.attributes.macName == client?.macName {
            showing.insert(activity.attributes.macName)
            if let token = activity.pushToken { client?.registerDashboard(token: Self.hex(token)) }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

extension DashboardColors {
    /// A theme's colors as the phone shows them in light or in dark. Nil
    /// with no theme picked, when the dashboard keeps its own look.
    init?(_ palette: CompanionPalette?, scheme: ColorScheme) {
        guard let palette else { return nil }
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        func hex(_ color: Color) -> String {
            let resolved = color.resolve(in: environment)
            func byte(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", byte(resolved.red), byte(resolved.green), byte(resolved.blue))
        }
        self.init(background: hex(palette.surface), ink: hex(palette.ink), working: hex(palette.working),
                  remote: hex(palette.remote), waiting: hex(palette.waiting), done: hex(palette.done),
                  waitingInk: hex(palette.waitingInk))
    }
}
