import AppKit
import BenchKit
import SwiftUI

/// The switch for the menu bar Live Activity, for the places that flip it:
/// Settings, the View menu, the command bar and the Overview.
enum LiveActivitySetting {
    static let key = "showsLiveActivity"

    /// False before macOS 27.3, where there's nothing to switch.
    static var isAvailable: Bool {
        #if compiler(>=6.4.4)
        if #available(macOS 27.3, *) { return true }
        #endif
        return false
    }

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// Live Activities came to the Mac with macOS 27.3, whose SDK ships with
// Swift 6.4.4. Older toolchains build Workbench without this.
#if compiler(>=6.4.4)
import ActivityKit

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
    static var isShown: Bool { LiveActivitySetting.isOn }

    private let store: AppStore
    private let terminals: TerminalManager
    private let icons: ProjectIcons?
    private let rosterIcons = RosterIcons()
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
    private var activation: NSObjectProtocol?

    init(store: AppStore, terminals: TerminalManager, icons: ProjectIcons?) {
        self.store = store
        self.terminals = terminals
        self.icons = icons
        // One left behind by a copy of the app that quit or crashed.
        let leftovers = Activity<DashboardAttributes>.activities.map(Handle.init)
        enqueue {
            for old in leftovers { await old.end() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRefresh() }
        }
        // The system only lets an app start an activity while it's in
        // front. One refused in the background gets another go here.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRefresh() }
        }
        #if DEBUG
        if Self.demo != nil {
            Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.queueRefresh() }
            }
        }
        #endif
        refresh()
    }

    /// Ends the activity, for when the setting is turned off.
    func remove() {
        removed = true
        timer?.invalidate()
        if let activation { NotificationCenter.default.removeObserver(activation) }
        end()
    }

    /// Ends it as the app quits, waiting a moment for the system to hear:
    /// an activity outlives the app that started it otherwise.
    func endForQuit() {
        removed = true
        let handles = Activity<DashboardAttributes>.activities.map(Handle.init)
        guard !handles.isEmpty else { return }
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            for handle in handles { await handle.end() }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 1)
    }

    private func refresh() {
        refreshQueued = false
        guard !removed else { return }
        let state = withObservationTracking {
            demoWithIcons ?? Self.state(OverviewView.items(store: store, terminals: terminals)) { [icons, rosterIcons] project in
                rosterIcons.name(for: project, image: icons?.image(for: project))
            }
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

    /// BENCH_LIVE_ACTIVITY_DEMO=1 shows made-up sessions, to look it over
    /// in a test copy. Set to "waiting", one of them starts out needing you.
    private static var demo: DashboardAttributes.ContentState? {
        #if DEBUG
        guard let mode = ProcessInfo.processInfo.environment["BENCH_LIVE_ACTIVITY_DEMO"] else { return nil }
        var rows = [
            DashboardRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, project: "Recipes", activity: "working",
                         text: "Adding a shopping list", since: demoStart, stepsDone: 2, stepsTotal: 5),
            DashboardRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, project: "Weather", activity: "working",
                         text: "Reading the forecast module, its fixtures and tests", since: demoStart.addingTimeInterval(-340)),
            DashboardRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, project: "Quick Notes", activity: "done",
                         text: "Fixed the sync crash", checks: "passing"),
        ]
        // A quarter of a minute in, one starts waiting.
        let asks = mode == "waiting" || Date.now.timeIntervalSince(demoStart) > 12
        if asks {
            rows.insert(DashboardRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, project: "Website", activity: "waiting",
                                     text: "Allow npm run build?", since: demoStart), at: 0)
        }
        return .init(rows: rows, more: 0, working: 2, waiting: asks ? 1 : 0, done: 1)
        #else
        return nil
        #endif
    }
    #if DEBUG
    private static let demoStart = Date.now
    #endif

    /// The demo, with your first few projects' icons on its rows, to see
    /// those too.
    private var demoWithIcons: DashboardAttributes.ContentState? {
        guard var state = Self.demo else { return nil }
        for (index, project) in store.projects.prefix(state.rows.count).enumerated() {
            state.rows[index].icon = rosterIcons.name(for: project, image: icons?.image(for: project))
        }
        return state
    }

    private static var macName: String { Host.current().localizedName ?? "Mac" }

    /// The dashboard for the sessions as the overview lists them: what
    /// needs you first, then what's working, then what just finished.
    /// `icon` names a project's icon file for the roster.
    static func state(_ items: [OverviewItem], now: Date = .now,
                      icon: (Project) -> String? = { _ in nil }) -> DashboardAttributes.ContentState {
        var rows: [(row: DashboardRow, project: Project)] = []
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
                rows.append((row(details?.question ?? "Waiting for you", since: details?.questionAt ?? details?.promptAt), item.project))
            case .attention:
                waiting += 1
                rows.append((row("Needs attention"), item.project))
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
                rows.append((row, item.project))
            case .done:
                guard let stopped = details?.stoppedAt, now.timeIntervalSince(stopped) < DashboardActivity.doneFor else { continue }
                done += 1
                rows.append((row(details?.summary ?? "Finished"), item.project))
            case .idle:
                continue
            }
        }
        // The items come ranked, needs-you first.
        let shown = rows.prefix(DashboardActivity.maxRows).map { entry in
            var row = entry.row
            row.icon = icon(entry.project)
            return row
        }
        return .init(rows: shown, more: rows.count - shown.count, working: working, waiting: waiting, done: done)
    }
}

/// Project icons as small files in the folder the app shares with its
/// widget extension, which is sandboxed and can't read a project's own.
/// A file is named for its project and its picture, so a changed icon is a
/// changed row, and the roster redraws.
@MainActor
private final class RosterIcons {
    private var known: [UUID: (image: NSImage?, repoName: String, name: String?)] = [:]
    private let folder = DashboardIcons.folder

    init() {
        // Ones nothing has asked for in a while. Any still wanted are
        // written again the first time they're asked for.
        guard let folder else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified.timeIntervalSinceNow < -7 * 24 * 3600 { try? FileManager.default.removeItem(at: file) }
        }
    }

    func name(for project: Project, image: NSImage?) -> String? {
        guard let folder else { return nil }
        if let entry = known[project.id], entry.image === image, entry.repoName == project.repoName { return entry.name }
        let name = write(project, image: image, to: folder)
        known[project.id] = (image, project.repoName, name)
        return name
    }

    private func write(_ project: Project, image: NSImage?, to folder: URL) -> String? {
        // The icon as the sidebar draws it, lettered tile and all.
        let renderer = ImageRenderer(content: ProjectIcon(project: project, image: image, size: 64, outlined: false))
        renderer.scale = 1
        guard let drawn = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: drawn).representation(using: .png, properties: [:]) else { return nil }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in png { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let prefix = project.id.uuidString
        let name = "\(prefix)-\(String(hash, radix: 16)).png"
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for old in try FileManager.default.contentsOfDirectory(atPath: folder.path) where old.hasPrefix(prefix) && old != name {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
            }
            if !FileManager.default.fileExists(atPath: file.path) { try png.write(to: file, options: .atomic) }
            return name
        } catch {
            NSLog("MenuBarActivity: couldn't save an icon: %@", String(describing: error))
            return nil
        }
    }
}
#endif
