import BenchKit
import Foundation

/// Claude Code.
///
/// A Claude tab starts Claude with a small settings file whose hooks
/// record the tab's session and report what Claude is doing (see
/// `AgentSessions`). The same file sets a status line that passes the
/// plan's usage on to `PlanUsageMonitor`.
struct ClaudeProvider: AgentProvider {
    let id = AgentID.claude
    let name = "Claude"
    let productName = "Claude Code"
    let symbol = "sparkle"
    let program = "claude"
    /// Settings > Claude: what new Claude tabs run in place of plain `claude`,
    /// like `claude --permission-mode acceptEdits` or a wrapper script.
    let commandKey = "claudeCommand"
    let missingProgramNote = "Workbench could not find Claude Code. Install it from https://claude.com/product/claude-code then open a new Claude tab."

    func accountPrefix(claude: ClaudeProfile, agentAccount: UUID?) -> String { claude.shellPrefix }

    nonisolated var driver: any AgentTerminalDriver { ClaudeTerminalDriver() }
    var catalog: AgentCatalog { .claude }
    nonisolated func savedEffort(forModel model: String?) -> String? { ClaudeEffort.saved(forModel: model) }
    nonisolated var background: any AgentBackground { ClaudeBackground() }
    nonisolated var transcripts: any AgentTranscripts { ClaudeTranscripts() }

    /// The hooks every Claude tab starts with. They live in the shared kit,
    /// where a host with no screen uses the same ones.
    static var hooks: [String: Any] { ClaudeHooks.hooks }

    private static let hooksFile = BenchPaths.support.appendingPathComponent("claude-hooks.json")

    func launchArguments(for launch: AgentLaunch, environment: inout [String: String]) -> String {
        var arguments = ""
        let userStatusLine = Self.userStatusLine(in: launch.folder, account: launch.account)
        do {
            let data = try JSONSerialization.data(withJSONObject: ClaudeHooks.settings(userStatusLine: userStatusLine), options: [.prettyPrinted, .sortedKeys])
            if (try? Data(contentsOf: Self.hooksFile)) != data { try data.write(to: Self.hooksFile, options: .atomic) }
            arguments += " --settings \(shellQuote(Self.hooksFile.path))"
        } catch {
            NSLog("Bench: couldn't set up Claude session tracking: \(error)")
        }
        arguments += #" --append-system-prompt "$\#(launch.noteVariable)""#
        switch launch.start {
        case .fresh: break
        case .prompt(let variable): arguments += #" "$\#(variable)""#
        case .resume(let session): arguments += " --resume \(shellQuote(session))"
        }
        environment["BENCH_STATUS_FILE"] = launch.account.statusFile.path
        if let own = userStatusLine?["command"] as? String, !own.isEmpty {
            environment["BENCH_USER_STATUS_LINE"] = own
        }
        return arguments
    }

    /// The status line Claude would use in `folder` without Bench: the
    /// project's local settings, then the project's, then the account's.
    static func userStatusLine(in folder: String, account: ClaudeProfile) -> [String: Any]? {
        let home = account.isMain
            ? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? account.configURL
            : account.configURL
        let project = URL(fileURLWithPath: folder).appendingPathComponent(".claude")
        let files = [project.appendingPathComponent("settings.local.json"),
                     project.appendingPathComponent("settings.json"),
                     home.appendingPathComponent("settings.json")]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let statusLine = json["statusLine"] as? [String: Any] else { continue }
            return statusLine
        }
        return nil
    }
}
