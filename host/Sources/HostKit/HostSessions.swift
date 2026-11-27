import BenchKit
import Dispatch
import Foundation

/// The agent sessions this host is running, each in a terminal nobody
/// sees: starting them, knowing what each is doing, and typing into them
/// for the Mac or iPhone that asked.
///
/// It's the host's version of what the Mac's terminal manager does for
/// agent tabs, with the same hooks and the same driver, so a session here
/// looks to the apps like one on a remote Mac.
///
/// Only touched on the main queue.
public final class HostSessions {
    /// One session's terminal and what the host remembers about it.
    final class Runtime {
        let tabID: UUID
        let projectID: UUID
        let terminal: HeadlessTerminal
        let launchedAt = Date()
        /// When its current stretch of working or waiting began.
        var since: Date?
        var lastState: AgentState?
        /// Finishes up to here have been looked at on some device.
        var seenStopAt: Date?
        /// When a question was last answered from a device. Until the hooks
        /// catch up, the session counts as working again.
        var answeredAt: Date?
        var sentEffort: String?
        /// True once its hooks recorded a session, even if it has ended since.
        var cameUp = false
        /// Why it isn't running, for a session that ended before it started.
        var failure: String?

        init(tabID: UUID, projectID: UUID, terminal: HeadlessTerminal) {
            self.tabID = tabID
            self.projectID = projectID
            self.terminal = terminal
        }
    }

    /// Something worth telling a phone about.
    public enum Event: Equatable {
        case waiting(tabID: UUID, projectID: UUID, question: String?, allowOrDeny: Bool)
        case finished(tabID: UUID, projectID: UUID, summary: String?)
    }

    public let paths: HostPaths
    public let store: HostStore
    /// What a new session runs: `claude`, or your own command or wrapper.
    public var claudeCommand: String
    /// Called when sessions change in a way the tick wouldn't notice soon.
    public var onChange: (() -> Void)?
    public var onEvent: ((Event) -> Void)?

    private var runtimes: [UUID: Runtime] = [:]
    private var details: [UUID: AgentDetails] = [:]
    private var files = AgentStateFiles()
    private let driver = ClaudeTerminalDriver()
    private var isShuttingDown = false
    private let wording = (name: "Claude", product: "Claude Code")

    public init(paths: HostPaths, store: HostStore, claudeCommand: String? = nil) {
        self.paths = paths
        self.store = store
        let custom = claudeCommand ?? ProcessInfo.processInfo.environment["WORKBENCH_CLAUDE_COMMAND"] ?? ""
        self.claudeCommand = custom.trimmingCharacters(in: .whitespaces).isEmpty ? "claude" : custom
    }

    // MARK: Starting and ending

    /// Starts every tab the store has, picking each conversation back up.
    /// For when the host starts: its sessions ended with the last run.
    public func resumeAll() {
        for project in store.projects {
            for tab in project.tabs { start(tab, in: project) }
        }
    }

    /// Starts a tab's session if it isn't running. False if it couldn't.
    @discardableResult
    public func start(_ tab: HostTab, in project: HostProject) -> Bool {
        if runtimes[tab.id] != nil { return true }
        let stateFile = paths.stateFile(tab.id), sessionFile = paths.sessionFile(tab.id)
        // State and events left over from the last run no longer apply.
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: paths.stateFolder, includingPropertiesForKeys: nil)) ?? []
        for file in leftovers where file.lastPathComponent.hasPrefix(tab.id.uuidString) {
            try? FileManager.default.removeItem(at: file)
        }
        var environment = ["BENCH_SESSION_FILE": sessionFile.path, "BENCH_STATE_FILE": stateFile.path]
        var command = claudeCommand
        if let settings = writeHooks() { command += " --settings \(shellQuote(settings))" }
        if let session = tab.resuming ?? Self.resumableSession(at: sessionFile) {
            command += " --resume \(shellQuote(session))"
        } else if let prompt = tab.prompt, !prompt.isEmpty {
            // In the environment, not on the command line, so nothing in
            // it is read by the shell.
            environment["BENCH_PROMPT"] = prompt
            command += #" "$BENCH_PROMPT""#
        }
        // The record is rewritten when the session starts. Until then it
        // would say the last run's session is still going.
        try? FileManager.default.removeItem(at: sessionFile)
        guard let terminal = HeadlessTerminal(command: command, folder: project.path, environment: environment) else {
            hostLog("couldn't start a terminal for \(project.path)")
            return false
        }
        let runtime = Runtime(tabID: tab.id, projectID: project.id, terminal: terminal)
        runtimes[tab.id] = runtime
        terminal.onExit = { [weak self, weak runtime] status in
            guard let self, let runtime else { return }
            self.ended(runtime, status: status)
        }
        store.markStarted(tab.id)
        hostLog("started a session in \(project.path)")
        return true
    }

    /// Claude Code's settings for a session: Workbench's hooks.
    private func writeHooks() -> String? {
        do {
            let data = try JSONSerialization.data(withJSONObject: ClaudeHooks.hooks, options: [.prettyPrinted, .sortedKeys])
            if (try? Data(contentsOf: paths.hooksFile)) != data { try data.write(to: paths.hooksFile, options: .atomic) }
            return paths.hooksFile.path
        } catch {
            hostLog("couldn't write the hooks file: \(error.localizedDescription)")
            return nil
        }
    }

    /// The session recorded for a tab, if its conversation is still on disk.
    static func resumableSession(at file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = info["session_id"] as? String, !id.isEmpty else { return nil }
        if let transcript = info["transcript_path"] as? String,
           !FileManager.default.fileExists(atPath: transcript) { return nil }
        return id
    }

    private func ended(_ runtime: Runtime, status: Int32) {
        guard !isShuttingDown, runtimes[runtime.tabID] === runtime else { return }
        if runtime.cameUp {
            // Claude was quit, or its conversation ended. The tab goes,
            // and the conversation stays under past sessions.
            hostLog("session \(runtime.tabID) ended (\(status))")
            forget(runtime.tabID)
            store.closeTab(runtime.tabID)
        } else {
            // It never got going. Keep the tab so the reason can be read.
            let screen = runtime.terminal.screen ?? ""
            let notFound = status == 127 || screen.contains("command not found") || screen.contains("not found")
            runtime.failure = notFound
                ? "Workbench couldn't find Claude Code on this machine. Install it there (https://claude.com/product/claude-code), then start a new session."
                : "Claude Code stopped before it started. On that machine, run claude in this folder to see why."
            hostLog("session \(runtime.tabID) didn't start (\(status)): \(screen.suffix(300))")
        }
        onChange?()
    }

    private func forget(_ tabID: UUID) {
        runtimes[tabID] = nil
        details[tabID] = nil
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.stateFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(tabID.uuidString) {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: paths.sessionFile(tabID))
    }

    /// Closes a tab, ending Claude in it.
    public func close(_ tabID: UUID) {
        runtimes[tabID]?.terminal.hangUp()
        forget(tabID)
        store.closeTab(tabID)
        onChange?()
    }

    /// Ends every session and leaves the tabs for the next run to resume.
    public func shutDown() {
        isShuttingDown = true
        for runtime in runtimes.values { runtime.terminal.hangUp() }
    }

    public var isAnythingRunning: Bool { runtimes.values.contains { $0.terminal.isRunning } }

    // MARK: What each session is doing

    /// Reads what the hooks have reported since last time.
    public func refresh() {
        details = files.read(folder: paths.stateFolder, summary: { Self.lastAssistantText(transcript: $0) })
        for runtime in runtimes.values {
            if !runtime.cameUp, isRecorded(runtime.tabID) { runtime.cameUp = true }
            let state = effectiveState(runtime)
            guard state != runtime.lastState else { continue }
            let before = runtime.lastState
            runtime.lastState = state
            let detail = details[runtime.tabID]
            switch state {
            case .working:
                // Answering a question carries on the same stretch of work.
                if before != .waiting || runtime.since == nil { runtime.since = detail?.promptAt ?? Date() }
            case .waiting:
                runtime.since = detail?.questionAt ?? detail?.toolAt ?? Date()
                onEvent?(.waiting(tabID: runtime.tabID, projectID: runtime.projectID, question: detail?.question,
                                  allowOrDeny: detail?.isAllowOrDeny ?? false))
            case .done:
                runtime.since = nil
                if before == .working || before == .waiting {
                    onEvent?(.finished(tabID: runtime.tabID, projectID: runtime.projectID, summary: detail?.summary))
                }
            case nil:
                runtime.since = nil
            }
        }
    }

    /// The hooks' word for a session, except that one just answered from a
    /// device is working again until the hooks say what happened next.
    private func effectiveState(_ runtime: Runtime) -> AgentState? {
        guard runtime.terminal.isRunning, let detail = details[runtime.tabID] else { return nil }
        if detail.state == .waiting, let answered = runtime.answeredAt {
            let asked = [detail.questionAt, detail.toolAt].compactMap { $0 }.max() ?? .distantPast
            if answered > asked, Date().timeIntervalSince(answered) < 600 { return .working }
        }
        return detail.state
    }

    /// True while Claude is up in the tab: its start hook wrote the record
    /// and its end hook hasn't removed it.
    private func isRecorded(_ tabID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: paths.sessionFile(tabID).path)
    }

    private func isUp(_ runtime: Runtime) -> Bool {
        runtime.terminal.isRunning && isRecorded(runtime.tabID)
    }

    /// A question Claude Code asks in its terminal before a session starts,
    /// like whether to trust the folder. No hook has run yet, so the screen
    /// is the only place to find it.
    func startupPrompt(_ runtime: Runtime) -> StartupPrompt? {
        guard runtime.terminal.isRunning, !isRecorded(runtime.tabID), let screen = runtime.terminal.screen else { return nil }
        return driver.startupPrompt(in: screen)
    }

    func planApproval(_ runtime: Runtime) -> CompanionQuestion? {
        guard effectiveState(runtime) == .waiting, details[runtime.tabID]?.tool == .planApproval else { return nil }
        return driver.planApproval(in: runtime.terminal.screen)
    }

    private func isStarting(_ runtime: Runtime) -> Bool {
        runtime.terminal.isRunning && !isRecorded(runtime.tabID) && startupPrompt(runtime) == nil
            && !needsSignIn(runtime) && Date().timeIntervalSince(runtime.launchedAt) < 20
    }

    /// True while Claude Code shows its first run: pick a theme, then sign in.
    private func needsSignIn(_ runtime: Runtime) -> Bool {
        guard let screen = runtime.terminal.screen else { return false }
        return screen.contains("Let's get started") || screen.contains("Select login method")
    }

    /// Why a message can't be typed into a session right now, or nil when
    /// it can. Claude Code queues what's typed while it works, so busy is fine.
    private func replyProblem(_ runtime: Runtime) -> String? {
        if let failure = runtime.failure { return failure }
        guard runtime.terminal.isRunning else { return "\(wording.name) isn't running in this session any more." }
        if let prompt = startupPrompt(runtime) {
            return "\(wording.product) \(prompt.blocker). Answer that first."
        }
        guard isRecorded(runtime.tabID) else {
            if isStarting(runtime) { return "\(wording.name) is starting." }
            if needsSignIn(runtime) {
                return "\(wording.product) isn't signed in on that machine yet. Run claude there once and sign in, then start a new session."
            }
            return "\(wording.product) is waiting on something in its terminal that Workbench can't answer from here. On that machine, run claude in this folder once to get past it."
        }
        if effectiveState(runtime) == .waiting {
            let detail = details[runtime.tabID]
            if detail?.isAllowOrDeny == true { return "\(wording.name) is asking for permission. Allow or deny it first." }
            if detail?.questions != nil || planApproval(runtime) != nil { return "\(wording.name) is asking you a question. Answer it first." }
            return "\(wording.name) is asking something Workbench can't answer from here. On that machine, run claude --resume in this folder to answer it."
        }
        return nil
    }

    /// A tab as the Mac and iPhone apps show a session, or nil if it has
    /// no terminal.
    public func session(for tab: HostTab) -> CompanionSession? {
        guard let runtime = runtimes[tab.id] else { return nil }
        let detail = details[tab.id]
        let state = effectiveState(runtime)
        let trust = startupPrompt(runtime)?.question
        let plan = trust == nil && detail?.questions == nil ? planApproval(runtime) : nil
        let problem = replyProblem(runtime)
        let activity: ActivityKind
        if trust != nil {
            activity = .waiting
        } else if runtime.failure != nil {
            activity = .attention
        } else {
            switch state {
            case .working: activity = .working
            case .waiting: activity = .waiting
            case .done: activity = (detail?.stoppedAt ?? .distantPast) > (runtime.seenStopAt ?? .distantPast) ? .done : .idle
            case nil: activity = .idle
            }
        }
        let isWaiting = state == .waiting
        return CompanionSession(
            id: tab.id,
            title: runtime.terminal.title.flatMap(Self.cleanTitle) ?? tab.title,
            activity: activity,
            prompt: detail?.prompt,
            action: detail?.action,
            question: trust?.question ?? (isWaiting ? detail?.question : nil),
            isAllowOrDeny: isWaiting && (detail?.isAllowOrDeny ?? false),
            summary: detail?.summary,
            stoppedAt: detail?.stoppedAt,
            model: Self.modelName(detail?.switchedModel ?? detail?.startModel),
            canReply: problem == nil,
            replyProblem: problem,
            since: runtime.since,
            questions: trust.map { [$0] } ?? plan.map { [$0] } ?? (isWaiting ? detail?.questions : nil),
            isCompacting: detail?.isCompacting ?? false,
            promptAt: detail?.promptAt,
            effort: runtime.sentEffort,
            command: detail?.command,
            permissionMode: isUp(runtime) ? driver.permissionMode(in: runtime.terminal.screen)?.rawValue : nil,
            isStarting: isStarting(runtime))
    }

    /// The window title without the mark Claude Code puts in front of it,
    /// and nil when it's only Claude Code's own name.
    static func cleanTitle(_ title: String) -> String? {
        let text = title.drop { !($0.isLetter || $0.isNumber) }
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned == "Claude Code" || cleaned.lowercased() == "claude" ? nil : cleaned
    }

    /// "claude-opus-5-5" as "Opus 5.5". Nil for anything not shaped like that.
    static func modelName(_ id: String?) -> String? {
        guard let id, id.hasPrefix("claude-") else { return id }
        var parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // A date on the end isn't part of the name.
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first, family.first?.isLetter == true else { return id }
        let version = parts.dropFirst().filter { Int($0) != nil }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    public func activity(for project: HostProject) -> ActivityKind {
        let kinds = project.tabs.compactMap { session(for: $0)?.activity }
        for kind in [ActivityKind.waiting, .working, .attention, .done] where kinds.contains(kind) { return kind }
        return .idle
    }

    /// The conversation behind a tab: what its hooks reported last, or its
    /// session record before any event.
    public func transcriptPath(_ tabID: UUID) -> String? {
        if let path = details[tabID]?.transcriptPath { return path }
        guard let data = try? Data(contentsOf: paths.sessionFile(tabID)),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return info["transcript_path"] as? String
    }

    /// Which tab each open Claude session is in, by session id.
    public func openSessions() -> [String: UUID] {
        var result: [String: UUID] = [:]
        for tab in runtimes.keys {
            guard let data = try? Data(contentsOf: paths.sessionFile(tab)),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = info["session_id"] as? String else { continue }
            result[id] = tab
        }
        return result
    }

    /// A device is looking at a session, so its finish has been seen.
    public func markSeen(_ tabID: UUID) {
        guard let runtime = runtimes[tabID], let stopped = details[tabID]?.stoppedAt else { return }
        if stopped > (runtime.seenStopAt ?? .distantPast) {
            runtime.seenStopAt = stopped
            onChange?()
        }
    }

    // MARK: Typing for a device

    private func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
            self?.onChange?()
        }
    }

    /// Types a message into a session and sends it. Returns the problem
    /// if it can't.
    public func reply(_ text: String, images: [Data] = [], tabID: UUID) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runtime = runtimes[tabID] else { return "That session is gone." }
        let pictures = savePictures(images)
        guard !text.isEmpty || !pictures.isEmpty else { return "Nothing to send." }
        if let problem = replyProblem(runtime) { return problem }
        // Claude's "Switch model?" question would only show in its terminal.
        if text.hasPrefix("/model ") {
            try? Data().write(to: paths.stateFolder.appendingPathComponent("\(tabID.uuidString).model-ok"), options: .atomic)
        }
        // No hook fires for /effort, so show it right away.
        if let level = EffortLevel(command: text) { runtime.sentEffort = level.rawValue }
        store.noteUsed(runtime.projectID)
        let terminal = runtime.terminal
        let typed = ComposerToken.readyToSend(driver.typed(text))
        let pause = driver.returnDelay
        if pictures.isEmpty {
            terminal.sendText(typed)
            // Let Claude take in the pasted text before pressing Return.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(pause)) { terminal.press(.returnKey) }
        } else {
            // Claude Code attaches a picture when its file's path is pasted
            // in, so the paths go in ahead of the words.
            if let paths = TerminalDrop.text(forPaths: pictures) { terminal.sendText(paths + " ") }
            let afterPictures = 400 + 150 * pictures.count
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(afterPictures)) {
                if !text.isEmpty { terminal.sendText(typed) }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(250, pause))) { terminal.press(.returnKey) }
            }
        }
        checkSoon()
        return nil
    }

    /// Saves pictures sent with a message where Claude Code can read them.
    private func savePictures(_ images: [Data]) -> [String] {
        guard !images.isEmpty else { return [] }
        // Yesterday's have been read by now.
        let old = (try? FileManager.default.contentsOfDirectory(at: paths.attachments, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in old {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 86_400 { try? FileManager.default.removeItem(at: file) }
        }
        return images.compactMap { data in
            let file = paths.attachments.appendingPathComponent("\(UUID().uuidString).\(Self.pictureExtension(data))")
            return (try? data.write(to: file, options: .atomic)) == nil ? nil : file.path
        }
    }

    static func pictureExtension(_ data: Data) -> String {
        let start = [UInt8](data.prefix(12))
        if start.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if start.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if start.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if start.count >= 12, start[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return "webp" }
        return "png"
    }

    /// Return picks "Yes" and Escape picks "No". Only while the session is
    /// still asking an allow-or-deny question.
    public func answer(allow: Bool, tabID: UUID) -> String? {
        guard let runtime = runtimes[tabID], effectiveState(runtime) == .waiting, details[tabID]?.isAllowOrDeny == true else {
            return "\(wording.name) isn't asking for permission right now."
        }
        runtime.terminal.press(allow ? driver.allowKey : driver.denyKey)
        runtime.answeredAt = Date()
        checkSoon()
        return nil
    }

    /// Stops what Claude is doing, as Escape does in its terminal.
    public func interrupt(tabID: UUID) -> String? {
        guard let runtime = runtimes[tabID], effectiveState(runtime) == .working else {
            return "\(wording.name) isn't working on anything right now."
        }
        runtime.terminal.press(driver.interruptKey)
        checkSoon()
        return nil
    }

    /// Sends queued messages now instead of after the step Claude is on.
    public func sendQueueNow(tabID: UUID) -> String? {
        guard let runtime = runtimes[tabID], isUp(runtime), let key = driver.sendQueueNowKey else {
            return "Queued messages can't be sent now for this session."
        }
        runtime.terminal.press(key)
        return nil
    }

    /// Answers Claude's pickers by pressing the keys you would.
    public func answer(_ answers: [CompanionAnswer], tabID: UUID) -> String? {
        guard let runtime = runtimes[tabID] else { return "That session is gone." }
        let terminal = runtime.terminal
        if let prompt = startupPrompt(runtime) {
            guard answers.count == 1, answers[0].selected.count == 1, let choice = answers[0].selected.first,
                  answers[0].other == nil, prompt.answers.indices.contains(choice) else { return "Pick one of the choices." }
            let answer = prompt.answers[choice]
            // Move to the option, check the cursor got there, then confirm.
            var delay = 0
            for key in answer.moves {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { terminal.press(key) }
                delay += 300
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                if !answer.moves.isEmpty, let picked = answer.picked {
                    guard StartupPrompt.cursorIsOn(picked, in: terminal.screen) else { return }
                }
                terminal.press(answer.confirm)
                self?.checkSoon()
            }
            return nil
        }
        if let plan = planApproval(runtime) {
            guard answers.count == 1 else { return "Pick one choice for the plan." }
            let answer = answers[0]
            if let other = answer.other?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
                guard plan.allowsOther == true else { return "Pick one of the choices for the plan." }
                run([.key(.digit(plan.options.count + 1)), .text(other), .key(.returnKey)], in: terminal)
            } else {
                guard answer.selected.count == 1, let choice = answer.selected.first, plan.options.indices.contains(choice) else {
                    return "Pick one choice for the plan."
                }
                terminal.press(.digit(choice + 1))
            }
            runtime.answeredAt = Date()
            checkSoon()
            return nil
        }
        guard effectiveState(runtime) == .waiting, let questions = details[tabID]?.questions else {
            return "\(wording.name) isn't asking a question right now."
        }
        switch driver.answerSteps(questions: questions, answers: answers) {
        case .success(let steps):
            run(steps, in: terminal)
            runtime.answeredAt = Date()
            checkSoon()
            return nil
        case .failure(let problem):
            return problem.message
        }
    }

    /// Keys go in one at a time, with a pause for the picker to redraw.
    private func run(_ steps: [AnswerStep], in terminal: HeadlessTerminal) {
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250 * index)) {
                switch step {
                case .key(let key): terminal.press(key)
                case .text(let text): terminal.sendText(text)
                }
            }
        }
    }

    /// Switches Claude Code's permission mode the way Shift-Tab does, one
    /// press at a time, reading the mode line after each, so it stops on
    /// the right one whatever order this version uses.
    public func setPermissionMode(_ target: PermissionMode, tabID: UUID, completion: @escaping (String?) -> Void) {
        guard let runtime = runtimes[tabID], isUp(runtime), let key = driver.nextModeKey,
              let start = driver.permissionMode(in: runtime.terminal.screen) else {
            completion("Couldn't find \(wording.product)'s mode in its terminal.")
            return
        }
        if start == target { return completion(nil) }
        guard effectiveState(runtime) != .waiting else { return completion("\(wording.name) is asking you something. Answer it first.") }
        let terminal = runtime.terminal
        let driver = driver
        let wording = wording
        func step(current: PermissionMode, presses: Int) {
            // Bypass, auto, and the usual three: no cycle is longer than 6.
            guard presses < 7 else { return completion("Couldn't switch to \(target.name).") }
            terminal.press(key)
            func look(_ tries: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let next = driver.permissionMode(in: terminal.screen)
                    if let next, next != current {
                        if next == target { return completion(nil) }
                        if next == start {
                            return completion(target == .bypass
                                ? "Bypass permissions is only available when \(wording.name) starts with it, like claude --dangerously-skip-permissions."
                                : "\(target.name) isn't available in this \(wording.name) session.")
                        }
                        return step(current: next, presses: presses + 1)
                    }
                    if tries >= 10 { return completion("\(wording.product) didn't change its mode.") }
                    look(tries + 1)
                }
            }
            look(0)
        }
        step(current: start, presses: 0)
    }

    // MARK: Reading a conversation's end

    /// The first lines of Claude's final message, from the end of its transcript.
    static func lastAssistantText(transcript path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // The last 256 KB is plenty to reach the final message.
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
            guard !text.isEmpty else { continue }
            let line = AgentStateFiles.oneLine(text)
            return line.count > 220 ? String(line.prefix(219)) + "…" : line
        }
        return nil
    }
}
