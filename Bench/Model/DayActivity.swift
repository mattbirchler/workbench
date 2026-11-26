import BenchKit
import Foundation
import Observation

/// What a project's agents did in a day: every session in it, as one row.
nonisolated struct ProjectDay: Identifiable, Sendable, Equatable {
    var id: UUID
    /// Stretches of work and of waiting on you, joined where sessions overlap.
    var work: [DaySpan] = []
    var waits: [DaySpan] = []
    var finishes: [DayFinish] = []
    var prompts: [DayFinish] = []
    var linesAdded = 0
    var linesRemoved = 0

    var isEmpty: Bool { work.isEmpty && waits.isEmpty }
    var waitingTime: TimeInterval { waits.reduce(0) { $0 + $1.duration } }

    /// Time with an agent working: the work, less the waits inside it.
    var workingTime: TimeInterval {
        var total = work.reduce(0) { $0 + $1.duration }
        for wait in waits {
            for span in work {
                if let overlap = wait.clipped(from: span.start, to: span.end) { total -= overlap.duration }
            }
        }
        return max(0, total)
    }

    var lastActivity: Date? { (work.map(\.end) + waits.map(\.end)).max() }
}

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
        let logged = WaitLog.shared.spans(from: from, to: min(to, now))
        isReading = true
        let result = await reader.read(sources: sources, from: from, to: min(to, now), now: now, live: live, logged: logged)
        isReading = false
        if projects != result { projects = result }
        self.day = from
        readAt = now
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
        // Files from a day no longer on show.
        files = files.filter { seen.contains($0.key) }
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
