import BenchKit
import Foundation
import Testing
@testable import Bench

/// The Mac app's readers of a Codex session, run on recorded sessions and
/// compared with saved copies, the same way Claude's are.
@MainActor
struct CodexReadersGoldenTests {
    nonisolated private static let sessions = ["tools", "simple"]
    private func file(_ session: String) -> URL { Golden.fixture("codex/rollout-\(session).jsonl") }
    private func path(_ session: String) -> String { file(session).path }

    @Test func aCodexSessionFileGetsCodexsReader() {
        #expect(Agents.transcripts(for: path("tools")).agent == .codex)
        #expect(Agents.transcripts(for: CodexTranscripts.sessionsFolders[0].appendingPathComponent("2026/11/24/rollout-x.jsonl").path).agent == .codex)
        #expect(Agents.transcripts(for: Golden.fixture("claude/tools.jsonl").path).agent == .claude)
    }

    @Test(arguments: sessions)
    func theLastThingCodexSaid(session: String) throws {
        let whole = AgentStateWatcher.lastAssistantMessage(transcript: path(session)) ?? "(none)"
        let start = AgentStateWatcher.lastAssistantText(transcript: path(session)) ?? "(none)"
        try Golden.check("start: \(start)\n\nwhole:\n\(whole)\n", "codex/\(session).last-message.txt")
    }

    @Test(arguments: sessions)
    func theTurnARecapIsWrittenFrom(session: String) throws {
        let text = Recaps.turn(transcript: path(session)).map { "used tools: \($0.usedTools)\n\n\($0.text)\n" } ?? "(no turn)\n"
        try Golden.check(text, "codex/\(session).recap-turn.txt")
    }

    @Test(arguments: sessions)
    func theSpendLedgersTotals(session: String) throws {
        let rows = CodexTranscripts().ledgerEntries(in: file(session))
            .sorted { $0.bucket.model < $1.bucket.model }
            .map { entry -> String in
                let tally = entry.tally
                return "\(entry.bucket.model) in \(entry.bucket.folder): \(tally.requests) requests, in \(tally.input), "
                    + "cache write \(tally.cacheWrite), cache read \(tally.cacheRead), out \(tally.output), "
                    + String(format: "cost %.6f", tally.cost)
            }
        try Golden.check(rows.joined(separator: "\n") + "\n", "codex/\(session).ledger.txt")
    }

    @Test(arguments: sessions)
    func thePastSessionsRow(session: String) throws {
        let size = try #require(try file(session).resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let past = try #require(CodexTranscripts().pastSession(in: file(session), modified: Date(timeIntervalSince1970: 0), size: size))
        let text = """
            id: \(past.id)
            agent: \(past.agent.rawValue)
            first prompt: \(past.firstPrompt ?? "(none)")
            last prompt: \(past.lastPrompt ?? "(none)")

            """
        try Golden.check(text, "codex/\(session).past-session.txt")
    }

    @Test(arguments: sessions)
    func whatTheMetersRead(session: String) async throws {
        let reader = TranscriptUsageReader()
        let transcript = path(session)
        let info = await withCheckedContinuation { done in reader.update(path: transcript) { done.resume(returning: $0) } }
        var lines = [
            "model: \(info.model ?? "(none)")",
            "model id: \(info.usage?.model ?? "(none)")",
            "context tokens: \(info.usage?.contextTokens ?? -1)",
            "window: \(info.usage?.window ?? -1)",
            "output tokens: \(info.usage?.outputTokens ?? -1)",
            "effort: \(info.effort ?? "(none)")",
            "interrupted: \(info.interruptedAt != nil)",
            "note: \(info.note ?? "(none)")",
            "trail:",
        ]
        lines += info.trail.map { "  \($0.text)" }
        lines.append("edited files:")
        lines += info.editedFiles.keys.sorted().map { "  \($0)" }
        try Golden.check(lines.joined(separator: "\n") + "\n", "codex/\(session).usage.txt")
    }

    @Test func theChatStreamsACodexSession() async throws {
        let streamer = TranscriptStreamer(options: .init(keepsResults: true), format: { Agents.transcripts(for: $0).format })
        let transcript = path("tools")
        let opened = await withCheckedContinuation { done in
            streamer.opening(tabID: UUID(), path: transcript) { messages, _ in done.resume(returning: messages) }
        }
        #expect(opened.first?.role == .user)
        #expect(opened.contains { $0.tool == .write && $0.edit?.isNewFile == true })
        #expect(opened.contains { $0.tool == .shell && $0.detail == "ls nope-missing" })
        #expect(opened.contains { $0.resultOf != nil && $0.isError == true })
    }

    @Test func findsASessionsFolderAndId() throws {
        #expect(CodexSessionIndex.folder(of: file("tools")) == "/Users/matt/Apps/Bench/build/codex-fixtures/cproj")
        let real = URL(fileURLWithPath: "/x/rollout-2026-11-24T11-27-16-01a20e98-fa65-7263-992e-0b7ac97271fa.jsonl")
        #expect(CodexTranscripts.sessionID(of: real) == "01a20e98-fa65-7263-992e-0b7ac97271fa")
    }

    @Test func namesCodexsModels() {
        #expect(CodexModels.name("gpt-6.2-sol") == "GPT-6.2 Sol")
        #expect(CodexModels.name("gpt-6-luna") == "GPT-6 Luna")
        #expect(CodexModels.name("o9") == "O9")
    }
}
