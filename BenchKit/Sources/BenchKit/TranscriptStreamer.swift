import Foundation

/// Follows the transcripts the phone is watching. Each file is read from
/// where it was last left, off the main thread, and turned into messages.
///
/// A long conversation is read from its end: enough to open with, and
/// then further back a page at a time as the phone asks for earlier
/// messages. `parsedFrom` is how far back the reading has gone.
public final class TranscriptStreamer: @unchecked Sendable {
    /// How much of a long conversation is read to start with.
    public static let openingLimit = 300

    private struct State {
        var path: String
        /// Where the next read of new lines starts.
        var offset: UInt64 = 0
        var partial = Data()
        /// Everything parsed so far, oldest first.
        var messages: [TranscriptMessage] = []
        /// The plan file Claude last wrote, for filling in plan approvals.
        var planFile: String?
        /// The byte where the oldest parsed line starts. Zero once the
        /// whole file has been read.
        var parsedFrom: UInt64 = 0
        /// True when old messages were dropped to save memory, so the
        /// start of the conversation isn't here even if parsedFrom is zero.
        var trimmed = false
        /// Where each message's line starts in the file (for messages read
        /// backward a chunk at a time, where the chunk starts), so a page
        /// before messages that have been let go of can be read again.
        var lineStarts: [String: UInt64] = [:]

        /// True when the start of the conversation isn't in `messages`.
        var isPartial: Bool { parsedFrom > 0 || trimmed }
    }

    private let queue = DispatchQueue(label: "Bench.TranscriptStreamer", qos: .userInitiated)
    private var states: [UUID: State] = [:]  // only touched on `queue`
    private let options: TranscriptParser.Options
    /// Makes the pictures in freshly read messages small, where the
    /// platform can. Read with the messages, off the main thread.
    public typealias Shrink = @Sendable (inout [TranscriptMessage]) -> Void
    private let shrink: Shrink
    /// Which agent's session file a path is, so it's read the right way.
    private let format: @Sendable (_ path: String) -> any TranscriptFormat

    public init(options: TranscriptParser.Options = .init(),
                format: @escaping @Sendable (_ path: String) -> any TranscriptFormat = { _ in ClaudeTranscriptFormat() },
                shrink: @escaping Shrink = { _ in }) {
        self.options = options
        self.format = format
        self.shrink = shrink
    }

    /// The conversation so far, for a phone that just started watching.
    /// Long files are read from the end, just far enough to fill it.
    /// `hasMore` is true when the conversation goes back further.
    public func opening(tabID: UUID, path: String, completion: @escaping @MainActor (_ messages: [TranscriptMessage], _ hasMore: Bool) -> Void) {
        queue.async { [self] in
            var state = states[tabID] ?? State(path: path)
            if state.path != path { state = State(path: path) }
            Self.readNew(into: &state, options: options, format: format, shrink: shrink)
            states[tabID] = state
            var messages = state.messages
            // Results ride along with their steps, so they get room of their own.
            let limit = Self.keptLimit(options)
            let hasMore = messages.count > limit || state.isPartial
            if messages.count > limit { messages = Array(messages.suffix(limit)) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(messages, hasMore) } }
        }
    }

    /// Up to `count` messages before the one with `id`, reading further
    /// back in the file as needed. `hasMore` is true when there are
    /// earlier ones still. Nothing when `id` isn't known any more.
    public func earlier(tabID: UUID, path: String, before id: String, count: Int,
                 completion: @escaping @MainActor (_ messages: [TranscriptMessage], _ hasMore: Bool) -> Void) {
        queue.async { [self] in
            guard var state = states[tabID], state.path == path else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion([], false) } }
                return
            }
            guard var index = state.messages.firstIndex(where: { $0.id == id }) else {
                // Let go of to save memory, but its line is known: read the
                // page before it straight from the file, and keep nothing.
                guard let at = state.lineStarts[id], at > 0, let handle = FileHandle(forReadingAtPath: path) else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion([], false) } }
                    return
                }
                var read = Self.readBackward(handle, end: at, want: count, format: format(path), options: options, shrink: shrink)
                try? handle.close()
                shrink(&read.messages)
                for message in read.messages { state.lineStarts[message.id] = read.parsedFrom }
                states[tabID] = state
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(read.messages, read.parsedFrom > 0) } }
                return
            }
            // What's kept may not reach back far enough: before what was
            // parsed, or before what was let go of. Read on from there.
            if index < count, let from = Self.unreadStart(state), let handle = FileHandle(forReadingAtPath: path) {
                var read = Self.readBackward(handle, end: from, want: count - index, format: format(path), options: options, shrink: shrink)
                try? handle.close()
                shrink(&read.messages)
                for message in read.messages { state.lineStarts[message.id] = read.parsedFrom }
                state.messages.insert(contentsOf: read.messages, at: 0)
                if state.parsedFrom > 0 { state.parsedFrom = read.parsedFrom }
                index += read.messages.count
                states[tabID] = state
            }
            let from = max(0, index - count)
            let page = Array(state.messages[from..<index])
            let hasMore = from > 0 || Self.unreadStart(state) != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(page, hasMore) } }
        }
    }

    /// Where the file's unread part ends: the oldest parsed line, or, once
    /// old messages have been let go of, the oldest kept message's line.
    /// Nil when the conversation's start is in hand.
    private static func unreadStart(_ state: State) -> UInt64? {
        if state.parsedFrom > 0 { return state.parsedFrom }
        guard state.trimmed, let first = state.messages.first, let at = state.lineStarts[first.id], at > 0 else { return nil }
        return at
    }

    /// New messages since last time. `replaces` is true when the session
    /// moved to a new transcript (after /clear) or the file was rewritten,
    /// in which case `messages` is the new conversation from the start.
    /// With `always`, it calls back even when there's nothing new.
    public func poll(tabID: UUID, path: String, always: Bool = false, completion: @escaping @MainActor ([TranscriptMessage], _ replaces: Bool) -> Void) {
        queue.async { [self] in
            var state = states[tabID] ?? State(path: path)
            var replaces = state.path != path
            if replaces { state = State(path: path) }
            let before = state.messages.count
            let rewritten = Self.readNew(into: &state, options: options, format: format, shrink: shrink)
            if rewritten {
                replaces = true
                state = State(path: path)
                _ = Self.readNew(into: &state, options: options, format: format, shrink: shrink)
            }
            states[tabID] = state
            let fresh = replaces ? state.messages : Array(state.messages[before...])
            // A long live session keeps growing; keep a few pages of it
            // and let the rest go. Earlier pages read again from the file.
            let keep = Self.keptLimit(options) * 4
            if state.messages.count > keep * 2 {
                state.messages.removeFirst(state.messages.count - keep)
                state.trimmed = true
                states[tabID] = state
            }
            guard always || replaces || !fresh.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(fresh, replaces) } }
        }
    }

    public func forget(except tabIDs: Set<UUID>) {
        queue.async { [self] in
            for id in states.keys where !tabIDs.contains(id) { states[id] = nil }
        }
    }

    /// Reads and parses whatever was appended. Returns true if the file got
    /// shorter, which means it was rewritten and should be read again.
    @discardableResult
    private static func readNew(into state: inout State, options: TranscriptParser.Options,
                                format lookup: (String) -> any TranscriptFormat, shrink: Shrink) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: state.path) else { return false }
        defer { try? handle.close() }
        let format = lookup(state.path)
        let end = (try? handle.seekToEnd()) ?? 0
        if end < state.offset { return true }
        guard end > state.offset else { return false }
        if state.offset == 0, end > tailChunk {
            readTail(of: handle, end: end, into: &state, options: options, format: lookup, shrink: shrink)
            return false
        }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd() else { return false }
        // Where the first whole line of this read starts.
        var lineStart = state.offset - UInt64(state.partial.count)
        state.offset += UInt64(data.count)
        var chunk = state.partial + data
        if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
            state.partial = Data(chunk[chunk.index(after: lastNewline)...])
            chunk = Data(chunk[..<lastNewline])
        } else {
            state.partial = chunk
            return false
        }
        var fresh: [TranscriptMessage] = []
        for line in chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let parsed = format.messages(in: Data(line), options: options)
            for message in parsed { state.lineStarts[message.id] = lineStart }
            fresh.append(contentsOf: parsed)
            lineStart += UInt64(line.count) + 1
        }
        // Previews from here on: a screenshot is a megabyte or two, and a
        // conversation kept for hours held every one of them whole.
        shrink(&fresh)
        PlanText.fill(&fresh, lastFile: &state.planFile)
        state.messages.append(contentsOf: fresh)
        return false
    }

    /// Where reading from the end starts: the last 4 MB, doubling until
    /// there are enough messages to show.
    private static let tailChunk: UInt64 = 4 << 20

    private static func keptLimit(_ options: TranscriptParser.Options) -> Int {
        options.keepsResults ? openingLimit * 2 : openingLimit
    }

    /// Long conversations run to hundreds of megabytes, almost all of it
    /// old tool output. Parse only enough of the end to fill the opening,
    /// so a big transcript opens about as fast as a small one.
    private static func readTail(of handle: FileHandle, end: UInt64, into state: inout State, options: TranscriptParser.Options,
                                 format lookup: (String) -> any TranscriptFormat, shrink: Shrink) {
        // The last line may still be being written: find where whole
        // lines end, and keep the rest for the next read.
        let peek = min(end, tailChunk)
        try? handle.seek(toOffset: end - peek)
        guard let tail = try? handle.read(upToCount: Int(peek)) else { return }
        var lineEnd = end
        var partial = Data()
        if let lastNewline = tail.lastIndex(of: UInt8(ascii: "\n")) {
            partial = Data(tail[tail.index(after: lastNewline)...])
            lineEnd = end - UInt64(partial.count)
        }
        let read = readBackward(handle, end: lineEnd, want: keptLimit(options), format: lookup(state.path), options: options, shrink: shrink)
        state.messages = read.messages
        for message in read.messages { state.lineStarts[message.id] = read.parsedFrom }
        PlanText.fill(&state.messages, lastFile: &state.planFile)
        state.parsedFrom = read.parsedFrom
        state.partial = partial
        state.offset = end
    }

    /// Parses whole lines backward from `end` (a line boundary) until
    /// there are `want` messages or the file's start. Returns them, oldest
    /// first, and the byte where the oldest parsed line starts.
    private static func readBackward(_ handle: FileHandle, end: UInt64, want: Int, format: any TranscriptFormat,
                                     options: TranscriptParser.Options, shrink: Shrink) -> (messages: [TranscriptMessage], parsedFrom: UInt64) {
        var messages: [TranscriptMessage] = []
        var parsedFrom = end
        var size = tailChunk
        while parsedFrom > 0, messages.count < want {
            let start = parsedFrom > size ? parsedFrom - size : 0
            try? handle.seek(toOffset: start)
            guard var data = try? handle.read(upToCount: Int(parsedFrom - start)) else { break }
            var lineStart = start
            if start > 0 {
                // The first line is probably cut off partway; the next round reads it whole.
                guard let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) else { size *= 2; continue }
                let skip = data.distance(from: data.startIndex, to: data.index(after: firstNewline))
                lineStart = start + UInt64(skip)
                data = Data(data.dropFirst(skip))
            }
            var earlier: [TranscriptMessage] = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                earlier.append(contentsOf: format.messages(in: Data(line), options: options))
            }
            shrink(&earlier)
            var planFile: String?
            PlanText.fill(&earlier, lastFile: &planFile)
            messages = earlier + messages
            parsedFrom = lineStart
            size *= 2
        }
        return (messages, parsedFrom)
    }
}
