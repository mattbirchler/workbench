import Foundation
import Testing
@testable import BenchKit

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

private func user(_ text: String, _ minutes: Double) -> TranscriptMessage {
    TranscriptMessage(id: UUID().uuidString, role: .user, text: text, at: at(minutes))
}

private func says(_ text: String, _ minutes: Double) -> TranscriptMessage {
    TranscriptMessage(id: UUID().uuidString, role: .assistant, text: text, at: at(minutes))
}

private func tool(_ name: String, id: String, _ minutes: Double, detail: String? = nil, edit: ToolEdit? = nil) -> TranscriptMessage {
    TranscriptMessage(id: UUID().uuidString, role: .tool, text: name, detail: detail, toolName: name, at: at(minutes), edit: edit, toolUseID: id)
}

private func result(of id: String, _ minutes: Double) -> TranscriptMessage {
    TranscriptMessage(id: UUID().uuidString, role: .tool, text: "", at: at(minutes), resultOf: id)
}

private func worked(_ minutes: Double) -> TranscriptMessage {
    TranscriptMessage(id: UUID().uuidString, role: .system, text: "", at: at(minutes), worked: 60)
}

private func timeline(_ messages: [TranscriptMessage]) -> SessionTimeline {
    var timeline = SessionTimeline()
    for message in messages { timeline.take(message) }
    return timeline
}

@Test func aTurnRunsFromThePromptToTheLastThingTheAgentDid() {
    let day = timeline([
        user("Add an RSS feed\nwith full text", 0),
        tool("Edit", id: "a", 20, edit: ToolEdit(removed: [], added: [], removedCount: 3, addedCount: 96, isNewFile: false)),
        result(of: "a", 20.1),
        says("The feed is at /feed.xml.\nMore detail.", 29),
        worked(29),
    ]).day(from: at(-60), to: at(600), now: at(120))
    #expect(day.work == [DaySpan(kind: .working, start: at(0), end: at(29), text: "Add an RSS feed")])
    #expect(day.finishes == [DayFinish(at: at(29), prompt: "Add an RSS feed", summary: "The feed is at /feed.xml.")])
    #expect(day.prompts.count == 1)
    #expect((day.linesAdded, day.linesRemoved) == (96, 3))
    #expect(day.workingTime == 29 * 60)
}

@Test func aQuestionIsTimeSpentWaitingOnYou() {
    let day = timeline([
        user("Build the pricing page", 0),
        tool("AskUserQuestion", id: "q", 5, detail: "Which layout?"),
        result(of: "q", 80),
        says("Three columns it is.", 90),
        worked(90),
    ]).day(from: at(-60), to: at(600), now: at(120))
    #expect(day.waits == [DaySpan(kind: .waiting, start: at(5), end: at(80), text: "Which layout?")])
    #expect(day.waitingTime == 75 * 60)
    // The wait is inside the turn, and doesn't count as work.
    #expect(day.workingTime == 15 * 60)
}

@Test func aSessionStillRunningWorksUntilNow() {
    let reader = timeline([user("Speed up shell startup", 0), tool("Bash", id: "b", 1)])
    let working = reader.day(from: at(-60), to: at(600), now: at(40), live: .working)
    #expect(working.work.last?.end == at(40))
    #expect(working.finishes.isEmpty)

    let waiting = reader.day(from: at(-60), to: at(600), now: at(40), live: .waiting(since: at(30), question: "Run zprof?"))
    #expect(waiting.waits == [DaySpan(kind: .waiting, start: at(30), end: at(40), text: "Run zprof?")])
    #expect(waiting.workingTime == 30 * 60)

    // Nothing running it anymore: it ended where its file does.
    let gone = reader.day(from: at(-60), to: at(600), now: at(40))
    #expect(gone.work.last?.end == at(1))
}

@Test func aLongQuietStretchWithNothingRunningSplitsTheWork() {
    let day = timeline([
        user("Tidy the tests", 0),
        says("Starting.", 1),
        says("Back at it.", 120),
        worked(125),
    ]).day(from: at(-60), to: at(600), now: at(300))
    #expect(day.work.map(\.start) == [at(0), at(120)])
    #expect(day.work.map(\.end) == [at(1), at(120)])
    // A command that takes an hour is still one stretch.
    let long = timeline([user("Run the benchmarks", 0), tool("Bash", id: "b", 1), result(of: "b", 61), worked(62)])
        .day(from: at(-60), to: at(600), now: at(300))
    #expect(long.work.count == 1)
}

@Test func spansAreCutToTheDay() {
    let day = timeline([user("Overnight job", -120), tool("Bash", id: "b", -119), result(of: "b", 30), worked(30)])
        .day(from: at(0), to: at(600), now: at(300))
    #expect(day.work == [DaySpan(kind: .working, start: at(0), end: at(30), text: "Overnight job")])
    #expect(day.prompts.isEmpty)
}

@Test func durationsReadShort() {
    #expect(DayText.duration(119 * 60) == "1h 59m")
    #expect(DayText.duration(64 * 60) == "1h 04m")
    #expect(DayText.duration(120 * 60) == "2h")
    #expect(DayText.duration(44 * 60) == "44m")
    #expect(DayText.duration(20) == "<1m")
    let merged = DayText.merged([DaySpan(kind: .working, start: at(10), end: at(30)), DaySpan(kind: .working, start: at(0), end: at(15)),
                                 DaySpan(kind: .working, start: at(40), end: at(50))])
    #expect(merged.map(\.start) == [at(0), at(40)])
    #expect(merged.map(\.end) == [at(30), at(50)])
}

@Test func aDayReachesThePhoneWhole() throws {
    var project = ProjectDay(id: UUID())
    project.work = [DaySpan(kind: .working, start: at(0), end: at(30), text: "Add an RSS feed")]
    project.waits = [DaySpan(kind: .waiting, start: at(5), end: at(10), text: "Run the tests")]
    project.finishes = [DayFinish(at: at(30), summary: "Done.")]
    let day = CompanionDay(daysBack: 0, start: at(-60), readAt: at(45), rows: [CompanionDay.Row(name: "Blog", day: project, isWorking: true)], cost: 4.2)
    let sent = try CompanionCoding.encoder.encode(ServerMessage.day(day))
    guard case .day(let received) = try CompanionCoding.decoder.decode(ServerMessage.self, from: sent) else {
        Issue.record("Not a day")
        return
    }
    #expect(received == day)
    #expect(received.workingTime == 25 * 60)
    // A finish with work soon after it isn't a stop worth marking.
    project.work.append(DaySpan(kind: .working, start: at(32), end: at(40)))
    #expect(project.stops.isEmpty)
    // Six hours at least, ending an hour past now.
    let hours = day.hours(calendar: Calendar(identifier: .gregorian))
    #expect(hours.end.timeIntervalSince(hours.start) >= 6 * 3600)
}
