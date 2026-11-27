import Foundation
// On the Mac, Live Activities came with macOS 27.3, whose SDK ships with
// Swift 6.4.4. Older toolchains build the Mac side without them.
#if os(iOS) || (os(macOS) && compiler(>=6.4.4))
import ActivityKit
#endif

/// The lock screen dashboard: every session that's busy, waiting or just
/// finished on one Mac, as a short roster. The phone starts it when you
/// ask; the Mac pushes the updates.
public struct DashboardAttributes: Codable, Sendable, Hashable {
    public struct ContentState: Codable, Sendable, Hashable {
        /// The rows shown, what needs you first. At most `DashboardActivity.maxRows`.
        public var rows: [DashboardRow]
        /// Sessions left off the end.
        public var more: Int
        public var working: Int
        public var waiting: Int
        public var done: Int

        public init(rows: [DashboardRow], more: Int, working: Int, waiting: Int, done: Int) {
            self.rows = rows
            self.more = more
            self.working = working
            self.waiting = waiting
            self.done = done
        }

        public static let empty = ContentState(rows: [], more: 0, working: 0, waiting: 0, done: 0)
    }

    /// The Mac it's about, like "Mac Studio".
    public var macName: String
    /// The app's theme when the dashboard started, for the phone in light
    /// and in dark. Nil for the dashboard's own colors.
    public var light: DashboardColors?
    public var dark: DashboardColors?

    public init(macName: String, light: DashboardColors? = nil, dark: DashboardColors? = nil) {
        self.macName = macName
        self.light = light
        self.dark = dark
    }
}

/// The few colors the dashboard draws with, as "#rrggbb". The widget
/// can't read the app's settings, so the app hands them over at the start.
public struct DashboardColors: Codable, Sendable, Hashable {
    public var background: String
    public var ink: String
    public var working: String
    public var remote: String
    public var waiting: String
    public var done: String
    /// `waiting` as text, dark enough to read on a light background.
    public var waitingInk: String?

    public init(background: String, ink: String, working: String, remote: String, waiting: String, done: String, waitingInk: String? = nil) {
        self.waitingInk = waitingInk
        self.background = background
        self.ink = ink
        self.working = working
        self.remote = remote
        self.waiting = waiting
        self.done = done
    }
}

#if os(iOS) || (os(macOS) && compiler(>=6.4.4))
@available(macOS 27.3, *)
extension DashboardAttributes: ActivityAttributes {}
#endif

/// One session on the dashboard.
public struct DashboardRow: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var project: String
    /// `ActivityKind`'s raw value.
    public var activity: String
    /// What it's doing, asking, or said last.
    public var text: String
    /// When its current stretch of work or waiting began, for a timer.
    public var since: Date?
    /// For a finished session with an open pull request: its checks, as
    /// `CompanionPullRequest.Checks`' raw value.
    public var checks: String?
    /// For a session working through a checklist: how many steps are
    /// done, and how many there are.
    public var stepsDone: Int?
    public var stepsTotal: Int?
    /// On the Mac: the project's icon, as the name of a file in
    /// `DashboardIcons.folder`.
    public var icon: String?

    public init(id: UUID, project: String, activity: String, text: String, since: Date? = nil, checks: String? = nil,
                stepsDone: Int? = nil, stepsTotal: Int? = nil, icon: String? = nil) {
        self.icon = icon
        self.id = id
        self.project = project
        self.activity = activity
        self.text = text
        self.since = since
        self.checks = checks
        self.stepsDone = stepsDone
        self.stepsTotal = stepsTotal
    }

    public var kind: ActivityKind { ActivityKind(rawValue: activity) ?? .idle }
}

/// Where the Mac app leaves project icons for the widget extension that
/// draws its Live Activity. The extension is sandboxed and can't read the
/// projects' own folders, so the two share an app group, named in each
/// one's Info.plist as BenchAppGroup.
public enum DashboardIcons {
    public static var folder: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BenchAppGroup") as? String, !group.hasPrefix("."),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent("ProjectIcons", isDirectory: true)
    }
}

public enum DashboardActivity {
    public static let maxRows = 4
    /// How long a finished session stays on the dashboard.
    public static let doneFor: TimeInterval = 30 * 60
    /// The Mac pushes at least this often, so the dashboard can tell when
    /// it's gone quiet.
    public static let heartbeat: TimeInterval = 15 * 60
    public static let staleAfter: TimeInterval = 20 * 60
    private static let maxText = 80

    /// The dashboard for a set of projects.
    public static func state(for projects: [CompanionProject], now: Date = .now) -> DashboardAttributes.ContentState {
        var rows: [(rank: Int, sort: Double, row: DashboardRow)] = []
        var working = 0, waiting = 0, done = 0
        for project in projects {
            for session in project.sessions {
                let since = session.since
                switch session.activity {
                case .waiting, .attention:
                    waiting += 1
                    let text = session.activity == .attention ? "Needs attention" : (session.question ?? "Waiting for you")
                    rows.append((0, since?.timeIntervalSinceReferenceDate ?? 0, row(project, session, text, since: since)))
                case .working, .remoteWorking:
                    working += 1
                    let step = session.checklist?.first { $0.status == .inProgress }?.label
                    let text = session.action ?? step ?? (session.remoteHost.map { "Working on \($0)" } ?? "Working")
                    var row = row(project, session, text, since: since)
                    if let steps = session.checklist, !steps.isEmpty {
                        row.stepsDone = steps.doneCount
                        row.stepsTotal = steps.count
                    }
                    rows.append((1, since?.timeIntervalSinceReferenceDate ?? 0, row))
                case .done:
                    guard let stopped = session.stoppedAt, now.timeIntervalSince(stopped) < doneFor else { continue }
                    done += 1
                    let pr = project.pullRequest
                    let checks = pr.flatMap { [.open, .draft].contains($0.state) && $0.checks != .none ? $0.checks.rawValue : nil }
                    rows.append((2, -stopped.timeIntervalSinceReferenceDate,
                                 row(project, session, session.summary ?? "Finished", since: nil, checks: checks)))
                case .idle:
                    continue
                }
            }
        }
        rows.sort { ($0.rank, $0.sort, $0.row.id.uuidString) < ($1.rank, $1.sort, $1.row.id.uuidString) }
        let shown = rows.prefix(maxRows).map(\.row)
        return .init(rows: Array(shown), more: rows.count - shown.count, working: working, waiting: waiting, done: done)
    }

    private static func row(_ project: CompanionProject, _ session: CompanionSession, _ text: String,
                            since: Date?, checks: String? = nil) -> DashboardRow {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let short = line.count > maxText ? String(line.prefix(maxText - 1)) + "…" : line
        return DashboardRow(id: session.id, project: project.name, activity: session.activity.rawValue,
                            text: short, since: since, checks: checks)
    }
}

/// Push payloads for the dashboard, in the shape APNs wants.
public enum DashboardPayload {
    public static func update(_ state: DashboardAttributes.ContentState, alert: (title: String, body: String)?,
                              now: Date = .now) throws -> [String: Any] {
        var aps: [String: Any] = [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": "update",
            "content-state": try contentState(state),
            "stale-date": Int(now.addingTimeInterval(DashboardActivity.staleAfter).timeIntervalSince1970),
        ]
        if let alert { aps["alert"] = ["title": alert.title, "body": alert.body] }
        return ["aps": aps]
    }

    /// The content state as ActivityKit decodes it: JSONEncoder's defaults,
    /// so dates are seconds since 2001.
    static func contentState(_ state: DashboardAttributes.ContentState) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
    }
}
