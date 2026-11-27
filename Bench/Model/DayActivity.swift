import BenchKit
import Foundation
import Observation

/// A day of agent work across every project, for the Overview's timeline.
///
/// Rebuilt from the session files the agents keep, so it covers days before
/// this was written and sessions Workbench wasn't open for. What those files
/// can't say, Workbench adds: what's running right now, and when an agent
/// sat on a permission prompt (`WaitLog`).
@Observable
final class DayActivity {
    static let shared = DayActivity()

    /// The day on show, by project. Projects with nothing that day are left out.
    private(set) var projects: [UUID: ProjectDay] = [:]
    /// The start of the day `projects` is for, and when it was last read.
    private(set) var day: Date?
    private(set) var readAt: Date?
    private(set) var isReading = false

    @ObservationIgnored private let reader = DayReader()

    struct Source: Sendable {
        var id: UUID
        var path: String
    }

    /// Reads whatever the session files have gained since last time.
    /// `live` is what each open session is doing now, by its file.
    func refresh(day: Date, sources: [Source], live: [String: SessionLiveState]) async {
        let from = Calendar.current.startOfDay(for: day)
        let to = Calendar.current.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86400)
        let now = Date()
        isReading = true
        let result = await load(day: day, sources: sources, live: live, now: now)
        isReading = false
        if projects != result { projects = result }
        self.day = from
        readAt = now
    }

    /// A day by project, without putting it on show: for a phone that asks.
    func load(day: Date, sources: [Source], live: [String: SessionLiveState], now: Date = .now) async -> [UUID: ProjectDay] {
        let from = Calendar.current.startOfDay(for: day)
        let to = Calendar.current.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86400)
        let logged = WaitLog.shared.spans(from: from, to: min(to, now))
        return await reader.read(sources: sources, from: from, to: min(to, now), now: now, live: live, logged: logged)
    }

    /// What each open agent session is doing now, by its session file.
    static func live(store: AppStore, terminals: TerminalManager) -> [String: SessionLiveState] {
        var result: [String: SessionLiveState] = [:]
        for item in OverviewView.items(store: store, terminals: terminals) {
            guard let session = item.session,
                  let path = session.details?.transcriptPath ?? AgentSessions.transcriptPath(tabID: item.tab.id) else { continue }
            switch item.activity {
            case .working:
                result[path] = .working
            case .waiting:
                let details = session.details
                result[path] = .waiting(since: details?.questionAt ?? .now, question: details?.plainAction ?? details?.action ?? details?.question)
            default:
                break
            }
        }
        return result
    }

    /// The day as a phone draws it.
    func companionDay(daysBack: Int, store: AppStore, terminals: TerminalManager) async -> CompanionDay {
        let today = Calendar.current.startOfDay(for: .now)
        let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: today) ?? today
        let now = Date()
        let items = OverviewView.items(store: store, terminals: terminals)
        let days = await load(day: start, sources: store.projects.map { Source(id: $0.id, path: $0.path) },
                              live: daysBack == 0 ? Self.live(store: store, terminals: terminals) : [:], now: now)
        let rows = store.projects.compactMap { project -> CompanionDay.Row? in
            guard let day = days[project.id] else { return nil }
            return CompanionDay.Row(name: OverviewDay.label(project), day: day,
                                    isWorking: daysBack == 0 && items.contains { $0.project.id == project.id && $0.activity == .working },
                                    isWaiting: daysBack == 0 && items.contains { $0.project.id == project.id && $0.activity == .waiting })
        }
        let cost = daysBack == 0 ? UsageLedger.shared.cost(since: start) : 0
        return CompanionDay(daysBack: daysBack, start: start, readAt: now, rows: rows, cost: cost >= 0.01 ? cost : nil)
    }

    var workingTime: TimeInterval { projects.values.reduce(0) { $0 + $1.workingTime } }
    var waitingTime: TimeInterval { projects.values.reduce(0) { $0 + $1.waitingTime } }
    var promptCount: Int { projects.values.reduce(0) { $0 + $1.prompts.count } }
    var linesAdded: Int { projects.values.reduce(0) { $0 + $1.linesAdded } }
    var linesRemoved: Int { projects.values.reduce(0) { $0 + $1.linesRemoved } }
}

/// Reads session files off the main thread, keeping its place in each so a
/// session being written is only read where it has grown.
actor DayReader {
    private struct FileState {
        var offset = 0
        var timeline = SessionTimeline()
    }

    private var files: [String: FileState] = [:]

    func read(sources: [DayActivity.Source], from: Date, to: Date, now: Date,
              live: [String: SessionLiveState], logged: [UUID: [DaySpan]]) -> [UUID: ProjectDay] {
        var result: [UUID: ProjectDay] = [:]
        var seen = Set<String>()
        for source in sources {
            var work: [DaySpan] = []
            var waits = logged[source.id] ?? []
            var day = ProjectDay(id: source.id)
            for (_, transcripts, file) in SessionHistory.files(forProject: source.path) {
                // A session with anything in the day was written to since it began.
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified >= from else { continue }
                seen.insert(file.path)
                let timeline = update(file, format: transcripts.format)
                let session = timeline.day(from: from, to: to, now: now, live: live[file.path] ?? .unknown)
                work += session.work
                waits += session.waits
                day.finishes += session.finishes
                day.prompts += session.prompts
                day.linesAdded += session.linesAdded
                day.linesRemoved += session.linesRemoved
            }
            day.work = DayText.merged(work)
            day.waits = DayText.merged(waits.compactMap { $0.clipped(from: from, to: to) })
            day.finishes.sort { $0.at < $1.at }
            day.prompts.sort { $0.at < $1.at }
            if !day.isEmpty { result[source.id] = day }
        }
        // Today and yesterday are both asked for, by this Mac and by phones,
        // so files are kept until there are a great many.
        if files.count > 600 { files = files.filter { seen.contains($0.key) } }
        return result
    }

    /// Takes in the whole lines a file has gained.
    private func update(_ file: URL, format: any TranscriptFormat) -> SessionTimeline {
        var state = files[file.path] ?? FileState()
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return state.timeline }
        // Rewritten from the top: start over.
        if data.count < state.offset { state = FileState() }
        let options = TranscriptParser.Options(keepsResults: true, keepsTurnTimes: true)
        var lines: [Data] = []
        var consumed = state.offset
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = state.offset
            while offset < raw.count {
                let start = base + offset
                guard let end = memchr(start, Int32(UInt8(ascii: "\n")), raw.count - offset) else { break }
                let length = UnsafeRawPointer(end) - start
                if length > 0 { lines.append(Data(bytes: start, count: length)) }
                offset += length + 1
                consumed = offset
            }
        }
        for line in lines {
            for message in format.messages(in: line, options: options) { state.timeline.take(message) }
        }
        state.offset = consumed
        files[file.path] = state
        return state.timeline
    }
}

/// When agents sat waiting on a permission prompt. Session files don't
/// record that (a command waiting to be allowed looks like one running), so
/// Workbench notes it as it happens and keeps a week of it.
final class WaitLog {
    static let shared = WaitLog()

    nonisolated struct Entry: Codable, Sendable {
        var project: UUID
        var start: Date
        var end: Date
        var text: String?
    }

    private var entries: [Entry] = []
    private var open: [UUID: Entry] = [:]
    private var loaded = false
    private static let file = BenchPaths.support.appendingPathComponent("wait-log.json")
    private static let kept: TimeInterval = 8 * 86400

    /// Called with each report from a tab's hooks.
    func note(tab: UUID, project: UUID, details: AgentDetails?, now: Date = .now) {
        if let details, details.state == .waiting, details.isAllowOrDeny {
            guard open[tab] == nil else { return }
            let start = min(details.questionAt ?? now, now)
            open[tab] = Entry(project: project, start: start, end: start, text: details.plainAction ?? details.action ?? details.question)
        } else if var entry = open.removeValue(forKey: tab) {
            entry.end = max(entry.start, now)
            // Answered at once: nothing was held up.
            guard entry.end.timeIntervalSince(entry.start) >= 5 else { return }
            load()
            entries.append(entry)
            entries.removeAll { now.timeIntervalSince($0.end) > Self.kept }
            save()
        }
    }

    /// The waits that ended in a range, by project. Ones still going come
    /// from the sessions themselves.
    func spans(from: Date, to: Date) -> [UUID: [DaySpan]] {
        load()
        var result: [UUID: [DaySpan]] = [:]
        for entry in entries {
            guard let span = DaySpan(kind: .waiting, start: entry.start, end: entry.end, text: entry.text).clipped(from: from, to: to) else { continue }
            result[entry.project, default: []].append(span)
        }
        return result
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        entries = (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
