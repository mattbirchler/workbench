import Foundation

/// Settings > General > Move to Another Mac: your Workbench setup as one
/// file, in parts you pick, to bring to another Mac.
///
/// An import isn't applied while Workbench runs, since the running app
/// would save what it has in memory over it. It's staged as
/// `pending-import.json`, Workbench restarts, and `applyPending` puts it in
/// place at launch before anything is read. What it replaces is backed up
/// first, to `Backups/before-import-<date>`.
nonisolated enum SettingsTransfer {
    static let format = "workbench-settings"
    static let version = 1
    static let pendingName = "pending-import.json"

    /// The parts of a setup you can choose to bring along.
    enum Section: String, CaseIterable, Identifiable, Codable {
        case projects, shortcuts, appearance, settings, accounts, pairedMacs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: "Projects and sidebar"
            case .shortcuts: "Shortcuts"
            case .appearance: "Appearance"
            case .settings: "Other settings"
            case .accounts: "Claude accounts"
            case .pairedMacs: "Paired Macs"
            }
        }

        var detail: String {
            switch self {
            case .projects: "Your projects, groups, pins, and open tabs. Each project's folder has to be at the same place on the new Mac."
            case .shortcuts: "Tab shortcuts and one-click messages to your agent."
            case .appearance: "Themes, light or dark, the app icon, focus ring, motion, and chat fonts."
            case .settings: "Everything else in Settings, like how agent tabs open, the agent commands, Keep Working, worktrees, dictation, and the sidebar meters."
            case .accounts: "Your Claude Code and Codex accounts and which projects use them. You sign in to each one again on the new Mac."
            case .pairedMacs: "The other Macs this one shows projects from. The file then holds the keys to reach them, so keep it private."
            }
        }

        /// Files in Workbench's Application Support folder.
        var files: [String] {
            switch self {
            case .projects: ["state.json"]
            case .shortcuts: ["shortcuts.json", "claude-actions.json"]
            case .appearance, .settings: []
            case .accounts: ["claude-accounts.json", "codex-accounts.json"]
            case .pairedMacs: ["remote-macs.json"]
            }
        }

        /// Workbench's own preferences. Window sizes, caches, and anything
        /// tied to this Mac (like the iPhone's pairing) stay behind.
        var preferenceKeys: [String] {
            switch self {
            case .projects: ["sidebarGrouping", "sidebarLayout", "inactiveCollapsed", "ungroupedCollapsed"]
            case .shortcuts: ["showsDevButton"]
            case .appearance: ["appearanceMode", "appIcon", "focusRingColor", "motionLevel", "playsSounds", "sound.finished",
                               "sound.needsYou", "themeSource",
                               "builtInLightTheme", "builtInDarkTheme", "matchTerminalTheme",
                               "chatTextFont", "chatCodeFont", "chatTextScale", "interfaceTextScale"]
            case .settings: ["newClaudeTabsShowChat", "claudeCommand", "recaps.enabled", "keepsClaudeSessionsAlive",
                             "resumesClaudeTabsAtLaunch", "autoCleanMergedWorktrees", "worktreesFolder",
                             "trashRemovedWorktrees", "editorBundleID",
                             "installsUpdatesWhenIdle", "monthlyBudget", "planUsageShown", "planUsagePace",
                             "showsMacActivity", "showsSimulators", "showsMenuBarIcon", "showsLiveActivity", "analyticsOptedOut", "fileViewWraps", "inspectorMode",
                             "inspectorShowsFiles", "usage.days", "usage.showsTokens",
                             "dictation.enabled", "dictation.key", "dictation.fixesTerms"]
            case .accounts, .pairedMacs: []
            }
        }

        /// Paired Macs carry keys, so they're left out unless you ask.
        var isOnByDefault: Bool { self != .pairedMacs }
    }

    /// One preference's value. Only the plain kinds Workbench's settings use.
    enum Value: Codable, Equatable {
        case bool(Bool), int(Int), double(Double), string(String)

        init?(_ any: Any) {
            if let number = any as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
                else if CFNumberIsFloatType(number) { self = .double(number.doubleValue) }
                else { self = .int(number.intValue) }
            } else if let string = any as? String {
                self = .string(string)
            } else {
                return nil
            }
        }

        var object: Any {
            switch self {
            case .bool(let v): v
            case .int(let v): v
            case .double(let v): v
            case .string(let v): v
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int.self) { self = .int(v) }
            else if let v = try? c.decode(Double.self) { self = .double(v) }
            else { self = .string(try c.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            }
        }
    }

    /// One section's contents. A file or setting that's missing was never
    /// set, so importing it goes back to the default.
    struct Part: Codable, Equatable {
        var files: [String: String] = [:]
        var preferences: [String: Value] = [:]
    }

    /// The exported file.
    struct Archive: Codable {
        var format = SettingsTransfer.format
        var version = SettingsTransfer.version
        var exportedAt: Date
        var appVersion: String
        var fromMac: String
        /// The home folder it came from, so paths can follow a new user name.
        var home: String
        var sections: [Section: Part]

        enum CodingKeys: String, CodingKey { case format, version, exportedAt, appVersion, fromMac, home, sections }

        init(exportedAt: Date, appVersion: String, fromMac: String, home: String, sections: [Section: Part]) {
            self.exportedAt = exportedAt
            self.appVersion = appVersion
            self.fromMac = fromMac
            self.home = home
            self.sections = sections
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decode(String.self, forKey: .format)
            version = try c.decode(Int.self, forKey: .version)
            exportedAt = try c.decode(Date.self, forKey: .exportedAt)
            appVersion = try c.decode(String.self, forKey: .appVersion)
            fromMac = try c.decode(String.self, forKey: .fromMac)
            home = try c.decode(String.self, forKey: .home)
            // Sections this version doesn't know are skipped.
            let raw = try c.decode([String: Part].self, forKey: .sections)
            sections = Dictionary(uniqueKeysWithValues: raw.compactMap { key, part in Section(rawValue: key).map { ($0, part) } })
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(format, forKey: .format)
            try c.encode(version, forKey: .version)
            try c.encode(exportedAt, forKey: .exportedAt)
            try c.encode(appVersion, forKey: .appVersion)
            try c.encode(fromMac, forKey: .fromMac)
            try c.encode(home, forKey: .home)
            try c.encode(Dictionary(uniqueKeysWithValues: sections.map { ($0.key.rawValue, $0.value) }), forKey: .sections)
        }
    }

    enum TransferError: LocalizedError {
        case notASettingsFile, newerVersion

        var errorDescription: String? {
            switch self {
            case .notASettingsFile: "This isn't a Workbench settings file."
            case .newerVersion: "This file came from a newer version of Workbench. Update Workbench, then try again."
            }
        }
    }

    // MARK: - Export

    static func export(_ sections: Set<Section>, support: URL = BenchPaths.support, defaults: UserDefaults = .standard,
                       home: String = NSHomeDirectory(), fromMac: String = Host.current().localizedName ?? "Mac",
                       appVersion: String = appVersion, now: Date = .now) throws -> Data {
        var parts: [Section: Part] = [:]
        for section in sections {
            var part = Part()
            for name in section.files {
                if let text = try? String(contentsOf: support.appendingPathComponent(name), encoding: .utf8) {
                    part.files[name] = text
                }
            }
            for key in section.preferenceKeys {
                if let value = defaults.object(forKey: key).flatMap(Value.init) { part.preferences[key] = value }
            }
            parts[section] = part
        }
        let archive = Archive(exportedAt: now, appVersion: appVersion, fromMac: fromMac, home: home, sections: parts)
        return try encoder.encode(archive)
    }

    // MARK: - Import

    static func read(_ data: Data) throws -> Archive {
        guard let archive = try? decoder.decode(Archive.self, from: data), archive.format == format else {
            throw TransferError.notASettingsFile
        }
        guard archive.version <= version else { throw TransferError.newerVersion }
        return archive
    }

    /// How many of the file's projects have no folder at that place here.
    static func missingProjectFolders(in archive: Archive, home: String = NSHomeDirectory(),
                                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (missing: Int, total: Int) {
        guard let text = archive.sections[.projects]?.files["state.json"],
              let data = rewriteHome(text, from: archive.home, to: home).data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = state["projects"] as? [[String: Any]] else { return (0, 0) }
        let paths = projects.compactMap { $0["path"] as? String }
        return (paths.filter { !exists($0) }.count, paths.count)
    }

    /// Saves the chosen sections for the next launch to put in place.
    static func stage(_ archive: Archive, sections: Set<Section>, support: URL = BenchPaths.support) throws {
        var chosen = archive
        chosen.sections = archive.sections.filter { sections.contains($0.key) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try encoder.encode(chosen).write(to: support.appendingPathComponent(pendingName), options: .atomic)
    }

    static func hasPending(support: URL = BenchPaths.support) -> Bool {
        FileManager.default.fileExists(atPath: support.appendingPathComponent(pendingName).path)
    }

    /// At launch, before anything reads its files or settings: puts a
    /// staged import in place. Returns the sections it applied, or nil when
    /// nothing was waiting.
    @discardableResult
    static func applyPending(support: URL = BenchPaths.support, defaults: UserDefaults = .standard,
                             home: String = NSHomeDirectory(), now: Date = .now) -> [Section]? {
        let pending = support.appendingPathComponent(pendingName)
        guard let data = try? Data(contentsOf: pending) else { return nil }
        // Whatever happens, don't try this one again at every launch.
        defer { try? FileManager.default.removeItem(at: pending) }
        guard let archive = try? read(data) else {
            NSLog("Bench: couldn't read the staged settings import")
            return nil
        }
        let fm = FileManager.default
        let sections = Section.allCases.filter { archive.sections[$0] != nil }

        // Keep what's about to be replaced.
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let backup = support.appendingPathComponent("Backups/before-import-\(stamp)")
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var oldPreferences: [String: Any] = [:]
        for section in sections {
            for name in section.files {
                let file = support.appendingPathComponent(name)
                if fm.fileExists(atPath: file.path) { try? fm.copyItem(at: file, to: backup.appendingPathComponent(name)) }
            }
            for key in section.preferenceKeys {
                if let value = defaults.object(forKey: key) { oldPreferences[key] = value }
            }
        }
        if let plist = try? PropertyListSerialization.data(fromPropertyList: oldPreferences, format: .xml, options: 0) {
            try? plist.write(to: backup.appendingPathComponent("preferences.plist"))
        }

        for section in sections {
            guard let part = archive.sections[section] else { continue }
            for name in section.files {
                guard let text = part.files[name] else { continue }
                do {
                    try rewriteHome(text, from: archive.home, to: home)
                        .write(to: support.appendingPathComponent(name), atomically: true, encoding: .utf8)
                } catch {
                    NSLog("Bench: couldn't import \(name): \(error)")
                }
            }
            for key in section.preferenceKeys {
                switch part.preferences[key] {
                case .string(let text)?: defaults.set(rewriteHome(text, from: archive.home, to: home), forKey: key)
                case let value?: defaults.set(value.object, forKey: key)
                case nil: defaults.removeObject(forKey: key)
                }
            }
        }
        NSLog("Bench: imported settings (\(sections.map(\.rawValue).joined(separator: ", "))), backup in \(backup.path)")
        return sections
    }

    /// Moves paths under the old home folder to the new one, written plainly
    /// or with JSON's escaped slashes.
    static func rewriteHome(_ text: String, from old: String, to new: String) -> String {
        guard !old.isEmpty, old != new else { return text }
        if text == old { return new }
        func escaped(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\/") }
        return text
            .replacingOccurrences(of: old + "/", with: new + "/")
            .replacingOccurrences(of: escaped(old + "/"), with: escaped(new + "/"))
            .replacingOccurrences(of: "\"\(old)\"", with: "\"\(new)\"")
            .replacingOccurrences(of: "\"\(escaped(old))\"", with: "\"\(escaped(new))\"")
    }

    static var appVersion: String {
        let info = Foundation.Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
