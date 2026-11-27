import BenchKit
import Foundation

/// One coding agent Workbench can run in a tab, and everything about it
/// that differs from another: how it's started, how it's asked to report
/// what it's doing, where it keeps its conversations.
///
/// The rest of the app works with tabs, sessions and transcripts and asks
/// a provider for the parts only that agent's own command-line tool
/// knows. Code outside `Bench/Agents` shouldn't check which agent a tab
/// runs: it calls the tab's provider, so a feature written once works for
/// every agent.
protocol AgentProvider {
    var id: AgentID { get }
    /// What the agent is called in the app: "Claude".
    var name: String { get }
    /// The command-line tool people install: "Claude Code".
    var productName: String { get }
    /// The SF Symbol for its tabs.
    var symbol: String { get }
    /// The program a tab runs when you haven't set your own command: "claude".
    var program: String { get }
    /// The saved setting that holds your own command, when you have one.
    var commandKey: String { get }
    /// Printed in the tab when `program` isn't installed.
    var missingProgramNote: String { get }
    /// What to type before the program to start it signed in to a tab's
    /// account: each account is a folder of its own, named by a variable.
    /// `claude` is the tab's Claude account, and `agentAccount` its account
    /// for any other agent. Empty for the main account.
    func accountPrefix(claude: ClaudeProfile, agentAccount: UUID?) -> String

    /// Works the agent's terminal: its keys, title and screen.
    nonisolated var driver: any AgentTerminalDriver { get }
    /// Its models, effort levels and commands, and which of the chat's
    /// features it has.
    var catalog: AgentCatalog { get }
    /// The effort level the agent has saved for a model, which a session
    /// uses until you change it. Nil when it has none.
    nonisolated func savedEffort(forModel model: String?) -> String?
    /// Runs the agent out of sight, and knows its account and prices.
    nonisolated var background: any AgentBackground { get }
    /// Reads the agent's session files.
    nonisolated var transcripts: any AgentTranscripts { get }

    /// What follows the command in a new tab: the flags that make the
    /// agent report to Workbench, take in the note about `bench`, and
    /// start, continue or pick up a conversation. Called once per launch,
    /// and free to write whatever files those flags point at. May add to
    /// `environment`, which the tab's shell starts with.
    func launchArguments(for launch: AgentLaunch, environment: inout [String: String]) -> String
}

/// What to call an agent in a sentence.
struct AgentWording {
    /// "Claude": who you're talking to.
    var name: String
    /// "Claude Code": the program that runs in the terminal.
    var product: String
}

extension AgentProvider {
    var wording: AgentWording { AgentWording(name: name, product: productName) }

    /// The start of the command a tab types: yours, or the plain program.
    /// The provider's own flags go after it, so a wrapper has to pass its
    /// arguments on. Line breaks become spaces, since a newline would run
    /// the command early.
    func command(_ defaults: UserDefaults = .standard) -> String {
        let typed = (defaults.string(forKey: commandKey) ?? "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? program : typed
    }
}

/// What a provider is told about the tab it's starting in.
struct AgentLaunch {
    /// How the conversation begins.
    enum Start: Equatable {
        case fresh
        /// With a first message, which is in the tab's environment under
        /// this name. It isn't typed out: the command is typed before the
        /// shell is ready, and macOS drops typed-ahead input past 1,024
        /// bytes, which cut long prompts off before the Return.
        case prompt(variable: String)
        /// Picking a past conversation back up, by the agent's own id for it.
        case resume(session: String)
    }

    var tabID: UUID
    /// The project folder the tab opens in.
    var folder: String
    var start: Start
    var account: ClaudeProfile
    /// The environment variable holding what the agent is told about
    /// `bench` (`BenchCommand.note`), for the same reason as the prompt.
    var noteVariable: String
}

/// The agents this copy of Workbench can run.
enum Agents {
    static let claude = ClaudeProvider()
    static let codex = CodexProvider()
    /// Every agent this version knows how to run. A saved tab keeps
    /// working whether or not its agent is still offered.
    static let all: [any AgentProvider] = [claude, codex]

    /// The agents you can start a new tab with.
    static var offered: [any AgentProvider] { all.filter { isOffered($0.id) } }

    /// Where your choice of agent for new tabs is kept.
    nonisolated static let defaultAgentKey = "defaultAgent"

    /// The agent you chose for new tabs, while it's still offered.
    nonisolated static func standardID(defaults: UserDefaults = .standard,
                                       installed: (String) -> Bool = AgentPrograms.isInstalled) -> AgentID {
        let codexOffered = isOffered(.codex, defaults: defaults, installed: installed)
        guard let saved = defaults.string(forKey: defaultAgentKey) else {
            // Nothing chosen: Claude, unless Codex is the only one here.
            return codexOffered && installed("codex") && !installed("claude") ? .codex : .claude
        }
        let id = AgentID(rawValue: saved)
        return id == .codex && codexOffered ? id : .claude
    }

    /// The agent a new tab runs when nothing says otherwise.
    static var standard: any AgentProvider { provider(standardID()) ?? claude }

    /// The agent a name means, as typed: "codex", "Claude", "claude code".
    static func offered(named name: String) -> (any AgentProvider)? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return offered.first { $0.id.rawValue == wanted || $0.name.lowercased() == wanted || $0.wording.product.lowercased() == wanted }
    }

    /// Turns Codex on or off by hand. Left alone, Codex is offered on a
    /// Mac that has it installed.
    nonisolated static let codexEnabledKey = "codexEnabled"

    /// Where the switch for an agent you can turn off is kept.
    nonisolated static func switchKey(for id: AgentID) -> String { "\(id.rawValue)Enabled" }

    /// The agents with a switch: every one but Claude.
    static var optional: [any AgentProvider] { all.filter { $0.id != AgentID.standard } }

    nonisolated static func isOffered(_ id: AgentID, defaults: UserDefaults = .standard,
                                      installed: (String) -> Bool = AgentPrograms.isInstalled) -> Bool {
        guard id == .codex else { return true }
        if defaults.object(forKey: codexEnabledKey) != nil { return defaults.bool(forKey: codexEnabledKey) }
        return installed("codex")
    }

    /// Nil for an agent this version doesn't have.
    static func provider(_ id: AgentID) -> (any AgentProvider)? {
        all.first { $0.id == id }
    }
}

/// A string as TOML writes one: in double quotes, with what would end it
/// or break the line escaped.
nonisolated func tomlQuote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7F {
                out += String(format: "\\u%04X", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

/// Whether an agent's program is on this Mac. Asked on every menu and
/// list, so the answer is kept for a little while.
nonisolated enum AgentPrograms {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: (found: Bool, at: Date)] = [:]

    /// Looks again next time, after something was installed.
    static func forget() {
        lock.lock()
        known = [:]
        lock.unlock()
    }

    static func isInstalled(_ program: String) -> Bool {
        lock.lock()
        if let hit = known[program], Date().timeIntervalSince(hit.at) < 30 { lock.unlock(); return hit.found }
        lock.unlock()
        let found = Tools.path(program) != nil
        lock.lock()
        known[program] = (found, Date())
        lock.unlock()
        return found
    }
}
