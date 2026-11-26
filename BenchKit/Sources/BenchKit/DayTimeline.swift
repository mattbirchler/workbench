import Foundation

/// A stretch of an agent session's day: time it spent working, or time it
/// spent stopped on a question for you.
public struct DaySpan: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case working, waiting }

    public var kind: Kind
    public var start: Date
    public var end: Date
    /// What you asked for (working), or what it asked you (waiting).
    public var text: String?

    public init(kind: Kind, start: Date, end: Date, text: String? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// The part of the span inside a range, if any of it is.
    public func clipped(from: Date, to: Date) -> DaySpan? {
        let start = max(start, from), end = min(end, to)
        guard end >= start, self.end >= from, self.start <= to else { return nil }
        return DaySpan(kind: kind, start: start, end: end, text: text)
    }
}

/// The moment an agent finished a stretch of work, and how it summed it up.
public struct DayFinish: Sendable, Hashable {
    public var at: Date
    /// What you'd asked for.
    public var prompt: String?
    /// The start of its last message.
    public var summary: String?

    public init(at: Date, prompt: String? = nil, summary: String? = nil) {
        self.at = at
        self.prompt = prompt
        self.summary = summary
    }
}

/// What one session did between two times.
public struct SessionDay: Sendable, Hashable {
    /// Stretches of work, oldest first. Time spent waiting on you inside
    /// one is in `waits` as well, and drawn over it.
    public var work: [DaySpan] = []
    public var waits: [DaySpan] = []
    public var finishes: [DayFinish] = []
    /// When you sent each prompt, with its first line.
    public var prompts: [DayFinish] = []
    public var linesAdded = 0
    public var linesRemoved = 0

    public init() {}

    public var isEmpty: Bool { work.isEmpty && waits.isEmpty && prompts.isEmpty }
    public var waitingTime: TimeInterval { waits.reduce(0) { $0 + $1.duration } }

    /// Time spent working: the stretches of work, less the waits in them.
    public var workingTime: TimeInterval {
        var total = work.reduce(0) { $0 + $1.duration }
        for wait in waits {
            for span in work {
                if let overlap = wait.clipped(from: span.start, to: span.end) { total -= overlap.duration }
            }
        }
        return max(0, total)
    }
}

/// What a session is doing right now, as far as Workbench can see. The
/// session file can't say: a long command and a quit look the same in it.
public enum SessionLiveState: Sendable, Hashable {
    /// Not running, or not one Workbench can see.
    case unknown
    case working
    /// Stopped on a question since then.
    case waiting(since: Date, question: String?)
}

/// Builds a session's timeline from its messages, taken in file order. It
/// keeps its place, so a session still being written can be read a few
/// lines at a time.
public struct SessionTimeline: Sendable {
    /// With nothing running, the agent isn't quiet this long in the middle
    /// of a turn: it was stopped, and picked up again later.
    public static let quietLimit: TimeInterval = 20 * 60
    /// A new prompt this long after the last activity came after the work
    /// was done, not on top of it.
    public static let finishedGap: TimeInterval = 45

    private var work: [DaySpan] = []
    private var waits: [DaySpan] = []
    private var finishes: [DayFinish] = []
    private var prompts: [DayFinish] = []
    private var edits: [(at: Date, added: Int, removed: Int)] = []

    private var open: (start: Date, text: String?)?
    private var lastAt: Date?
    private var lastText: String?
    /// Tool calls still running.
    private var pending: Set<String> = []
    /// A question it's asked and you haven't answered.
    private var ask: (at: Date, text: String?)?

    public init() {}

    public var lastActivity: Date? { lastAt }

    public mutating func take(_ message: TranscriptMessage) {
        guard let at = message.at, message.queue == nil else { return }
        if message.role == .system {
            // The agent's own note that a stretch of work is over.
            if message.worked != nil { close(at: lastAt ?? at, finished: true) }
            return
        }
        if let ask {
            waits.append(DaySpan(kind: .waiting, start: ask.at, end: max(ask.at, at), text: ask.text))
            self.ask = nil
        }
        if message.role == .user {
            guard message.shell == nil, message.command == nil else { return }
            if message.text.hasPrefix("[Request interrupted") {
                close(at: lastAt ?? at, finished: false)
                return
            }
            if let lastAt { close(at: lastAt, finished: at.timeIntervalSince(lastAt) > Self.finishedGap) }
            let text = Self.firstLine(message.text)
            open = (at, text)
            prompts.append(DayFinish(at: at, prompt: text))
            pending = []
            lastAt = at
            lastText = nil
            return
        }

        if let lastAt, open != nil, pending.isEmpty, at.timeIntervalSince(lastAt) > Self.quietLimit {
            let text = open?.text
            close(at: lastAt, finished: false)
            open = (at, text)
        } else if open == nil {
            open = (at, nil)
        }
        if let call = message.resultOf {
            pending.remove(call)
        } else if message.role == .tool {
            if let id = message.toolUseID { pending.insert(id) }
            if let kind = ToolKind(name: message.toolName), kind == .question || kind == .planApproval {
                ask = (at, kind == .planApproval ? "Approve its plan" : Self.firstLine(message.detail ?? message.text))
            }
            if let edit = message.edit { edits.append((at, edit.addedCount, edit.removedCount)) }
        } else if message.role == .assistant {
            lastText = message.text
        }
        lastAt = max(lastAt ?? at, at)
    }

    private mutating func close(at: Date, finished: Bool) {
        guard let open else { return }
        work.append(DaySpan(kind: .working, start: open.start, end: max(open.start, at), text: open.text))
        if finished { finishes.append(DayFinish(at: max(open.start, at), prompt: open.text, summary: lastText.map(Self.firstLine))) }
        self.open = nil
        lastText = nil
        pending = []
    }

    /// What the session did between two times. `live` says what it's doing
    /// at `now`, which ends its last stretch of work.
    public func day(from: Date, to: Date, now: Date, live: SessionLiveState = .unknown) -> SessionDay {
        var all = self
        switch live {
        case .working:
            if all.open == nil, let lastAt = all.lastAt, now.timeIntervalSince(lastAt) < Self.quietLimit {
                // Started again since the last line was written.
                all.open = (lastAt, all.work.last?.text)
            }
            if let open = all.open {
                all.work.append(DaySpan(kind: .working, start: open.start, end: max(open.start, now), text: open.text))
            }
            if let ask = all.ask { all.waits.append(DaySpan(kind: .waiting, start: ask.at, end: max(ask.at, now), text: ask.text)) }
        case .waiting(let since, let question):
            if let open = all.open {
                all.work.append(DaySpan(kind: .working, start: open.start, end: max(open.start, now), text: open.text))
            }
            let start = all.ask?.at ?? since
            all.waits.append(DaySpan(kind: .waiting, start: start, end: max(start, now), text: all.ask?.text ?? question))
        case .unknown:
            if let lastAt = all.lastAt {
                // A question nobody answered ends when the session went quiet.
                if let ask = all.ask { all.waits.append(DaySpan(kind: .waiting, start: ask.at, end: max(ask.at, lastAt), text: ask.text)) }
                all.close(at: lastAt, finished: all.ask == nil && now.timeIntervalSince(lastAt) > Self.finishedGap)
            }
        }
        var day = SessionDay()
        day.work = all.work.compactMap { $0.clipped(from: from, to: to) }
        day.waits = all.waits.compactMap { $0.clipped(from: from, to: to) }
        day.finishes = all.finishes.filter { $0.at >= from && $0.at <= to }
        day.prompts = all.prompts.filter { $0.at >= from && $0.at <= to }
        for edit in all.edits where edit.at >= from && edit.at <= to {
            day.linesAdded += edit.added
            day.linesRemoved += edit.removed
        }
        return day
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 200 ? String(trimmed.prefix(199)) + "…" : trimmed
    }
}

/// Wording and arithmetic the day view shares.
public enum DayText {
    /// "2h 48m", "44m", "under a minute".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return seconds > 0 ? "<1m" : "0m" }
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(String(format: "%02d", rest))m"
    }

    /// Spans joined where they touch or overlap, for drawing several
    /// sessions in one row.
    public static func merged(_ spans: [DaySpan]) -> [DaySpan] {
        var result: [DaySpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end {
                if span.end > last.end { result[result.count - 1].end = span.end }
            } else {
                result.append(span)
            }
        }
        return result
    }
}
