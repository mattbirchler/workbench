import BenchKit
import Foundation
import Observation
import SwiftUI

/// A one-click message to Claude, shown as a button in the Changes panel:
/// "Commit", "Push", "Open PR", "Merge", or one you wrote. Claude does the git work
/// itself, so whichever host a repo lives on, the button is the same.
struct ClaudeAction: Codable, Identifiable, Hashable {
    /// Which part of the branch's state the button follows: Commit greys
    /// out on a clean tree, Push when everything's pushed, Open PR turns
    /// into a link once a pull request exists, and Merge follows the pull
    /// request's checks. Your own actions are always available.
    enum Role: String, Codable {
        case commit, push, pullRequest, merge, custom
    }

    var id = UUID()
    /// The button's label.
    var name: String
    /// What's sent to Claude. `{branch}`, `{base}`, and `{pr}` are filled in.
    var prompt: String
    /// An SF Symbol for the button.
    var symbol = "sparkles"
    var role: Role = .custom

    init(id: UUID = UUID(), name: String, prompt: String, symbol: String = "sparkles", role: Role = .custom) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.symbol = symbol
        self.role = role
    }

    // Each field but the name and prompt may be missing from a file an
    // older or newer build wrote, and gets its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "sparkles"
        role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .custom
    }

    /// The prompt with the branch names and pull request number put in.
    /// Without a branch (a detached checkout), a base, or a pull request,
    /// the words say so instead.
    func filledPrompt(branch: String?, base: String?, pullRequest: Int? = nil) -> String {
        prompt
            .replacingOccurrences(of: "{branch}", with: branch ?? "the current branch")
            .replacingOccurrences(of: "{base}", with: base ?? "the default branch")
            .replacingOccurrences(of: "{pr}", with: pullRequest.map { "#\($0)" } ?? "the pull request for this branch")
    }

    /// What the Merge button sends instead while a pull request's checks
    /// are failing.
    static func fixChecksPrompt(pullRequest: Int, failing: [String]) -> String {
        let names = failing.isEmpty ? "" : " (failing: \(failing.joined(separator: ", ")))"
        return """
        The checks on pull request #\(pullRequest) failed\(names). Look at why, using gh run view --log-failed or \
        the host's equivalent, then fix the problem, commit, and push. Don't merge.
        """
    }

    /// Symbols offered in the editor.
    static let symbols = ["sparkles", "checkmark.circle", "arrow.up.circle", "arrow.triangle.pull",
                          "arrow.triangle.merge", "arrow.clockwise", "wand.and.stars", "text.badge.checkmark",
                          "list.bullet.clipboard", "tag", "trash", "doc.text"]

    static let defaults: [ClaudeAction] = [
        // The words are BenchKit's, so the phone's buttons send the same.
        ClaudeAction(name: ChangesAction.commit.name, prompt: ChangesAction.commit.prompt,
                     symbol: ChangesAction.commit.symbol, role: .commit),
        ClaudeAction(name: ChangesAction.push.name, prompt: ChangesAction.push.prompt,
                     symbol: ChangesAction.push.symbol, role: .push),
        ClaudeAction(name: ChangesAction.pullRequest.name, prompt: ChangesAction.pullRequest.prompt,
                     symbol: ChangesAction.pullRequest.symbol, role: .pullRequest),
        merge,
    ]

    static let merge = ClaudeAction(
        name: "Merge",
        prompt: """
        Merge pull request {pr} into {base}. First look at its checks once with gh pr checks (don't wait or \
        watch): if any are still running or have failed, stop and tell me. Use a merge method this repo allows, \
        going by its settings and recent merges, and delete the remote branch if the repo usually does. \
        Then switch this checkout to {base} and pull. If the merge is blocked (a required review, a conflict, \
        a new failing check), stop and tell me why instead of working around it.
        """,
        symbol: "arrow.triangle.merge", role: .merge)
}

/// Your Claude actions, saved in Workbench's folder. Starts with Commit,
/// Push, Open PR, and Merge, which you can reword, reorder, or delete.
@Observable
final class ClaudeActions {
    private(set) var all: [ClaudeAction]

    private static let defaultFile = BenchPaths.support.appendingPathComponent("claude-actions.json")
    /// Set once Merge has been added to a list saved before it existed, so
    /// deleting it later sticks.
    static let offeredMergeKey = "claudeActions.offeredMerge"
    private let file: URL

    init(file: URL = ClaudeActions.defaultFile, defaults: UserDefaults = .standard) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            if let saved = try? JSONDecoder().decode(LossyArray<ClaudeAction>.self, from: data) {
                all = saved.wrappedValue
                if !defaults.bool(forKey: Self.offeredMergeKey), let added = Self.addingMerge(to: all) {
                    all = added
                    write()
                }
            } else {
                BenchPaths.setAside(file)
                all = ClaudeAction.defaults
            }
        } else {
            all = ClaudeAction.defaults
        }
        // Every list from here on has had its chance at Merge.
        defaults.set(true, forKey: Self.offeredMergeKey)
    }

    /// True while the list is the one Workbench ships with.
    var isDefault: Bool {
        let defaults = ClaudeAction.defaults
        return all.count == defaults.count && zip(all, defaults).allSatisfy { mine, theirs in
            mine.name == theirs.name && mine.prompt == theirs.prompt && mine.symbol == theirs.symbol && mine.role == theirs.role
        }
    }

    /// A list saved before Merge existed, with it added after Open PR (or
    /// at the end). nil when it already has one.
    static func addingMerge(to list: [ClaudeAction]) -> [ClaudeAction]? {
        guard !list.contains(where: { $0.role == .merge }) else { return nil }
        var list = list
        let index = list.firstIndex { $0.role == .pullRequest }.map { $0 + 1 } ?? list.endIndex
        list.insert(ClaudeAction.merge, at: index)
        return list
    }

    func save(_ action: ClaudeAction) {
        if let index = all.firstIndex(where: { $0.id == action.id }) {
            all[index] = action
        } else {
            all.append(action)
        }
        write()
    }

    func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
        write()
    }

    func move(from source: IndexSet, to destination: Int) {
        all.move(fromOffsets: source, toOffset: destination)
        write()
    }

    func restoreDefaults() {
        all = ClaudeAction.defaults
        write()
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: file, options: .atomic)
        } catch {
            NSLog("Bench: couldn't save Claude actions: \(error)")
        }
    }
}
