import AppKit
import BenchKit

/// Builds what the phone sees from what Bench already knows: the store's
/// projects, each terminal's activity and Claude details, the PR status,
/// and the branch from the repo monitor.
struct CompanionSnapshots {
    let store: AppStore
    let terminals: TerminalManager
    let pullRequests: PullRequests
    let deployments: Deployments
    let monitors: RepoMonitors
    let files: FileListMonitors
    let icons: ProjectIcons
    let cleaner: WorktreeCleaner
    let shortcuts: TabShortcuts
    let ports: PortScanner
    /// Each project's dev command, read from disk at most every 10 seconds
    /// rather than on every snapshot.
    private let devCommands = DevCommandCache()
    /// Which projects were working at the last snapshot, to read a repo
    /// again when its agent stops.
    private let finishes = FinishTracker()

    func build() -> ProjectsSnapshot {
        let projects = store.projects.map { project -> CompanionProject in
            let monitor = monitors.monitor(for: project)
            if monitor.snapshot == nil, !monitor.isRefreshing { monitor.refresh() }
            let sessions = project.tabs.filter { $0.kind == .agent }.compactMap { Self.session(for: $0, terminals: terminals) }
            // Only the selected project's repo is watched, so what a row
            // says is uncommitted would be from before the agent's work.
            // One read as it stops, not a timer.
            if finishes.stoppedWorking(project.id, isWorking: sessions.contains { $0.activity == .working }) {
                monitor.refreshSoon()
            }
            let uncommitted = monitor.snapshot.map { $0.staged + $0.unstaged }
            return CompanionProject(
                id: project.id,
                name: project.name,
                repoName: project.repoName,
                path: project.path,
                branch: monitor.snapshot?.branch ?? project.branch,
                parentID: project.parentID,
                isExternalWorktree: project.isExternalWorktree ? true : nil,
                activity: sessions.contains { $0.activity == .waiting } ? .waiting : Self.kind(terminals.activity(for: project)),
                pullRequest: pullRequests.info[project.id].map(Self.pullRequest),
                sessions: sessions,
                isActive: project.isWorktree ? nil : store.isActive(project.id),
                isPinned: project.isWorktree ? nil : store.isPinned(project.id),
                section: project.isWorktree ? nil : Self.section(store.section(of: project.id)),
                deploy: deployments.info[project.id].map(Self.deploy),
                defaultBranch: monitor.snapshot?.baseRef.flatMap { $0.split(separator: "/").last.map(String.init) },
                cleanup: project.isWorktree ? cleaner.companionCleanup(project.id) : nil,
                shortcuts: companionShortcuts(for: project),
                isGit: monitor.snapshot?.isRepository,
                hasCustomName: project.isWorktree ? nil : project.customName != nil,
                hasCustomIcon: project.isWorktree ? nil : icons.hasCustomIcon(project),
                hasHiddenWorktrees: project.isWorktree ? nil : project.hiddenWorktrees?.isEmpty == false,
                notifiesPhone: store.notifiesPhone(project.id),
                claudeAccountID: store.claudeAccountID(for: project.id),
                uncommittedAdditions: uncommitted?.reduce(0) { $0 + $1.additions },
                uncommittedDeletions: uncommitted?.reduce(0) { $0 + $1.deletions })
        }
        return ProjectsSnapshot(projects: projects, selectedProjectID: store.selectedProjectID, groups: groups,
                                claudeAccounts: claudeAccounts, inactiveAfter: store.sidebarTimes.inactiveAfter)
    }

    /// Remembers which projects had an agent working, between snapshots.
    private final class FinishTracker {
        private var working: Set<UUID> = []

        /// True the first time a project that was working no longer is.
        func stoppedWorking(_ id: UUID, isWorking: Bool) -> Bool {
            if isWorking {
                working.insert(id)
                return false
            }
            return working.remove(id) != nil
        }
    }

    /// The Claude accounts set up here, main first.
    private var claudeAccounts: [CompanionClaudeAccount] {
        let accounts = ClaudeAccounts.shared
        return accounts.profiles.map {
            CompanionClaudeAccount(id: $0.id, name: $0.name, email: accounts.account(for: $0.id).status?.email)
        }
    }

    /// The custom groups, with this Mac's projects only, when the sidebar uses them.
    private var groups: [CompanionGroup]? {
        guard store.grouping == .custom else { return nil }
        return store.groups.map { group in
            CompanionGroup(id: group.id, name: group.name,
                           projectIDs: group.entries.filter { $0.host == nil }.map(\.projectID))
        }
    }

    static func section(_ section: AppStore.Section) -> CompanionSection {
        switch section {
        case .pinned: .pinned
        case .active: .active
        case .recent: .recent
        case .inactive: .inactive
        }
    }

    /// One Claude tab as remote devices see it, or nil before its terminal
    /// starts. `here` words its problems for the chat view on this Mac.
    static func session(for tab: TabRecord, terminals: TerminalManager, here: Bool = false) -> CompanionSession? {
        guard let session = terminals.existingSession(tab.id) else { return nil }
        let suggestion = terminals.promptSuggestion(tabID: tab.id)
        let details = session.details
        let problem = terminals.companionReplyProblem(tabID: tab.id, here: here)
        let trust = terminals.startupPrompt(tabID: tab.id)?.question
        let plan = trust == nil && details?.questions == nil ? terminals.planApproval(tabID: tab.id) : nil
        var snapshot = CompanionSession(
            id: tab.id,
            title: tab.customTitle ?? session.terminalTitle ?? tab.title,
            activity: trust == nil ? Self.kind(session.activity) : .waiting,
            prompt: details?.prompt,
            action: details?.action,
            question: trust?.question ?? details?.question,
            isAllowOrDeny: details?.isAllowOrDeny ?? false,
            summary: details?.summary,
            stoppedAt: details?.stoppedAt,
            contextTokens: session.usage?.contextTokens,
            contextWindow: session.usage?.window,
            model: session.model,
            remoteHost: session.remoteHost,
            canReply: problem == nil,
            replyProblem: problem,
            since: session.activeSince,
            checklist: session.visibleChecklist,
            questions: trust.map { [$0] } ?? plan.map { [$0] } ?? details?.questions,
            isCompacting: details?.isCompacting ?? false,
            agents: session.agents.isEmpty ? nil : session.agents,
            suggestion: suggestion,
            trail: session.trail.isEmpty ? nil : session.trail,
            note: session.note,
            noteAt: session.noteAt,
            promptAt: details?.promptAt,
            effort: session.effort,
            command: details?.command,
            permissionMode: terminals.permissionMode(tabID: tab.id)?.rawValue,
            isStarting: terminals.isStartingClaude(tabID: tab.id))
        // Claude's sessions say nothing, as they always have, so phones
        // and Macs that predate other agents read them the same.
        if let agent = session.agent, agent.id != AgentID.standard {
            snapshot.agent = agent.id
            snapshot.agentName = agent.name
            snapshot.catalog = agent.catalog
        }
        return snapshot
    }

    static func deploy(_ info: DeployInfo) -> CompanionDeploy {
        let state: CompanionDeploy.State = switch info.state {
        case .deploying: .deploying
        case .succeeded: .succeeded
        case .failed: .failed
        }
        return CompanionDeploy(state: state, prNumber: info.prNumber,
                               place: (info.state == .failed ? info.failing : info.environments).first, url: info.url)
    }

    /// The transcript behind a Claude tab: what its hooks reported last,
    /// or its session record before any hook has run.
    func transcriptPath(tabID: UUID) -> String? {
        Self.transcriptPath(tabID: tabID, terminals: terminals)
    }

    static func transcriptPath(tabID: UUID, terminals: TerminalManager) -> String? {
        terminals.existingSession(tabID)?.details?.transcriptPath ?? AgentSessions.transcriptPath(tabID: tabID)
    }

    func reply(_ text: String, tabID: UUID) -> String? {
        terminals.companionReply(text, tabID: tabID)
    }

    /// A message with pictures: they go in as files, the way you'd drop
    /// one on the terminal, so Claude sees them as images.
    func reply(_ text: String, attachments: [CompanionAttachment], tabID: UUID) -> String? {
        terminals.companionReply(text, images: attachments.map(\.data), tabID: tabID)
    }

    func answer(_ answers: [CompanionAnswer], tabID: UUID) -> String? {
        terminals.answerQuestions(answers, tabID: tabID)
    }

    /// Stops Claude in a tab, or says why it couldn't.
    func setPermissionMode(_ mode: PermissionMode, tabID: UUID) async -> String? {
        await terminals.setPermissionMode(mode, tabID: tabID)
    }

    func takeBackQueue(queued: [String], keep: [String], tabID: UUID) async -> String? {
        await terminals.takeBackQueue(queued: queued, keep: keep, tabID: tabID)
    }

    func sendQueueNow(tabID: UUID) -> String? {
        terminals.sendQueueNow(tabID: tabID)
    }

    /// Asks a `/btw` side question from another device, or says why it can't.
    func askSideQuestion(_ question: String, id: UUID, tabID: UUID) -> String? {
        SideQuestions.shared.ask(question, id: id, tabID: tabID, terminals: terminals, fromPhone: true)
    }

    private func agentName(_ tabID: UUID) -> String {
        store.projects.lazy.flatMap(\.tabs).first { $0.id == tabID }?.provider?.name ?? Agents.standard.name
    }

    func interrupt(tabID: UUID) -> String? {
        terminals.interrupt(tabID: tabID) ? nil : "\(agentName(tabID)) isn't working on anything right now."
    }

    /// The terminal theme's colors, for clients that theme themselves to it.
    func themeColors() -> TerminalColors? {
        TerminalTheme.shared.companionColors
    }

    func answer(allow: Bool, tabID: UUID) -> String? {
        terminals.answerPermission(allow: allow, tabID: tabID) ? nil : "\(agentName(tabID)) isn't asking for permission right now."
    }

    // MARK: Starting things

    func projectPath(_ projectID: UUID) -> String? { store.project(projectID)?.path }

    func pastSessions(projectID: UUID) async -> [PastSessionSummary] {
        guard let project = store.project(projectID) else { return [] }
        let open = AgentSessions.openSessions()
        let tabs = Set(project.tabs.map(\.id))
        return await SessionHistory.load(projectPath: project.path).map { past in
            PastSessionSummary(id: past.id, title: past.title, firstPrompt: past.firstPrompt, lastPrompt: past.lastPrompt,
                               branch: past.branch, modified: past.modified,
                               openTabID: open[past.id].flatMap { tabs.contains($0) ? $0 : nil })
        }
    }

    /// Picks a past conversation back up, or finds the tab it's open in.
    /// Returns the tab to show.
    func resume(projectID: UUID, sessionID: String) -> UUID? {
        guard let project = store.project(projectID) else { return nil }
        if let tab = AgentSessions.openSessions()[sessionID], project.tabs.contains(where: { $0.id == tab }) {
            store.selectTab(tab, in: projectID)
            return tab
        }
        let title = SessionHistory.title(of: sessionID, projectPath: project.path)
        return newClaudeTab(projectID: projectID, prompt: nil, resuming: sessionID, title: title)
    }

    /// Opens a Claude tab and starts it right away, since nobody is going
    /// to click it on the Mac.
    func newClaudeTab(projectID: UUID, prompt: String?, resuming sessionID: String? = nil, title: String? = nil) -> UUID? {
        guard let tab = store.addTab(.agent, to: projectID, prompt: prompt?.nilIfEmpty, resuming: sessionID, title: title, fromPhone: true),
              let project = store.project(projectID) else { return nil }
        _ = terminals.session(for: tab, in: project)
        return tab.id
    }

    /// Closes a Claude tab for another device. Nil when it's gone already.
    func closeSession(projectID: UUID, sessionID: UUID) -> Bool {
        guard store.project(projectID)?.tabs.contains(where: { $0.id == sessionID }) == true else { return false }
        store.closeTab(sessionID, in: projectID)
        return true
    }

    /// The shortcuts this project's + menu offers, as on the Mac: the dev
    /// server first, then your own.
    func companionShortcuts(for project: Project) -> [CompanionShortcut] {
        var found: [(id: String, name: String, symbol: String, command: String, inTabBar: Bool)] = []
        if shortcuts.showsDevButton, let dev = devCommands.command(in: project.url) {
            found.append(("dev", dev, "play.fill", dev, true))
        }
        for shortcut in shortcuts.shortcuts(for: project) {
            found.append((shortcut.id.uuidString, shortcut.name, shortcut.symbol, shortcut.command, shortcut.showsInTabBar))
        }
        return found.map { item in
            let running = runningTabs(item.command, in: project)
            let ports = Set(running.flatMap { ports.ports(forTab: $0).map(\.port) })
            return CompanionShortcut(id: item.id, name: item.name, symbol: item.symbol, command: item.command,
                                     isRunning: !running.isEmpty, ports: ports.sorted(), showsInTabBar: item.inTabBar)
        }
    }

    private func runningTabs(_ command: String, in project: Project) -> [UUID] {
        project.tabs.filter { $0.command == command && terminals.isRunning($0.id) }.map(\.id)
    }

    /// The command for a shortcut id from `companionShortcuts`, and whether
    /// it reuses a running tab.
    private func shortcut(_ id: String, in project: Project) -> (command: String, reuses: Bool)? {
        if id == "dev" {
            return shortcuts.showsDevButton ? PackageManager.devCommand(in: project.url).map { ($0, true) } : nil
        }
        return shortcuts.shortcuts(for: project).first { $0.id.uuidString == id }.map { ($0.command, $0.reusesRunningTab) }
    }

    /// Runs a shortcut in a new tab for another device, started right away
    /// since nobody will click it here. False when there's no such
    /// shortcut, or it's already running and reuses its tab.
    func runShortcut(projectID: UUID, shortcutID: String) -> Bool {
        guard let project = store.project(projectID), let found = shortcut(shortcutID, in: project) else { return false }
        if found.reuses, !runningTabs(found.command, in: project).isEmpty { return false }
        guard let tab = store.addTab(.shell, to: projectID, command: found.command),
              let updated = store.project(projectID) else { return false }
        _ = terminals.session(for: tab, in: updated)
        return true
    }

    /// Closes every tab running a shortcut, for another device.
    func stopShortcut(projectID: UUID, shortcutID: String) {
        guard let project = store.project(projectID), let found = shortcut(shortcutID, in: project) else { return }
        for tab in project.tabs where tab.command == found.command { store.closeTab(tab.id, in: projectID) }
    }

    /// Cleans up or discards an agent's worktree for another device.
    func removeAgent(projectID: UUID) async throws -> Bool {
        guard let worktree = store.project(projectID), worktree.isWorktree else { return false }
        try await cleaner.removeForRemote(worktree)
        return true
    }

    func reorder(ids: [UUID]) {
        store.setTopLevelOrder(ids)
    }

    /// Starts an agent on a branch for another device, the way the New
    /// Agent sheet here would: from the branch it would pick (usually
    /// main) unless one was chosen, with the project's saved setup or the
    /// files the sheet would suggest. This Mac's window stays where it is.
    func newAgent(parentID: UUID, prompt: String, branch: String, base: String?) async throws -> (project: UUID, tab: UUID)? {
        guard let started = try await startAgent(parentID: parentID, prompt: prompt, branch: branch, base: base),
              let tab = started.tab else { return nil }
        return (started.project, tab)
    }

    /// The same, telling apart a project that's gone (nil) from an agent
    /// that started but has no Claude tab to point at (a nil `tab`).
    /// `fromQueue` is for prompts queued while this Mac was asleep.
    func startAgent(parentID: UUID, prompt: String, branch: String, base: String?,
                    fromQueue: Bool = false) async throws -> (project: UUID, tab: UUID?)? {
        guard let parent = store.project(store.rootID(of: parentID)) else { return nil }
        let branch = branch.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Worktrees.suggestBranch(from: prompt)
        var start = base?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if start == nil { start = await AgentLauncher.preferredBase(repo: parent.url) }
        let id = try await AgentLauncher.start(parent: parent, branch: branch, base: start, prompt: prompt,
                                               files: parent.setupFiles ?? Worktrees.suggestedSetupFiles(repo: parent.url),
                                               command: parent.setupCommand, select: false, savesSetup: false,
                                               store: store, terminals: terminals)
        if fromQueue {
            Analytics.capture(.agentStarted, ["kind": "single", "count": 1, "from_queue": true])
        } else {
            Analytics.capture(.agentStarted, ["kind": "single", "count": 1, "from_phone": true])
        }
        return (id, store.project(id)?.tabs.first(where: { $0.kind == .agent })?.id)
    }

    // MARK: Changes

    /// What the Changes panel would show for a project, if its repo has
    /// been read yet.
    func changes(projectID: UUID) -> ChangesSnapshot? {
        guard let project = store.project(projectID) else { return nil }
        let monitor = monitors.monitor(for: project)
        return monitor.snapshot?.changesSnapshot(branches: monitor.branches, chosenBase: project.baseRef)
    }

    /// Compares a project's changes against another branch, as the base
    /// picker in its Changes panel does.
    func setBaseRef(_ ref: String?, projectID: UUID) {
        guard let project = store.project(projectID) else { return }
        store.setBaseRef(ref, for: projectID)
        monitors.monitor(for: project).baseOverride = ref
    }

    /// Re-reads a project's repo and branches now, as the Changes panel's
    /// refresh button does.
    func refreshNow(projectID: UUID) {
        guard let project = store.project(projectID) else { return }
        let monitor = monitors.monitor(for: project)
        monitor.refresh()
        monitor.loadBranches()
    }

    /// Reads a project's branches, for picking a base on another device.
    func loadBranches(projectID: UUID) {
        guard let project = store.project(projectID) else { return }
        monitors.monitor(for: project).loadBranches()
    }

    /// Re-reads a project's repo unless it was read very recently. Only the
    /// selected project's repo is watched for changes on the Mac, so a
    /// phone looking at another one asks for refreshes itself.
    func refreshChanges(projectID: UUID, olderThan seconds: TimeInterval) {
        guard let project = store.project(projectID) else { return }
        let monitor = monitors.monitor(for: project)
        guard !monitor.isRefreshing else { return }
        if let last = monitor.lastRefresh, Date().timeIntervalSince(last) < seconds { return }
        monitor.refresh()
    }

    /// One file's diff, parsed off the main thread. `forReview`, for
    /// clients with the codeReview feature, sends the whole file around
    /// the changes for them to fold, with what to color in each line.
    func diff(projectID: UUID, change: FileChange, forReview: Bool = false) async -> [DiffLine] {
        guard let project = store.project(projectID) else { return [] }
        let monitor = monitors.monitor(for: project)
        let client = monitor.client
        let baseRef = monitor.snapshot?.baseRef
        let lines = await Task.detached(priority: .userInitiated) {
            let text = await client.diff(for: change, baseRef: baseRef, wholeFile: forReview)
            let lines = DiffParser.parse(text)
            // A huge file goes back to just the changes, to keep the message small.
            guard forReview, lines.count > 30_000 else { return lines }
            return DiffParser.parse(await client.diff(for: change, baseRef: baseRef))
        }.value
        return forReview ? await SyntaxColors.colored(lines, path: change.path) : lines
    }

    /// One commit on one page, for a client with the codeReview feature:
    /// its message and every file's diff with the code colored. A huge
    /// commit is cut off after `lineLimit` lines.
    func commitReview(projectID: UUID, hash: String, lineLimit: Int = 20_000) async -> CommitReview? {
        guard let project = store.project(projectID) else { return nil }
        let git = monitors.monitor(for: project).client
        guard var commit = await git.commit(hash) else { return nil }
        let text = await git.reviewDiff(commit: hash, baseRef: nil)
        var diff = await Task.detached(priority: .userInitiated) { ReviewDiff(parsing: text) }.value
        var truncated = false
        if diff.lines.count > lineLimit {
            truncated = true
            // Keep whole files only, so none ends partway through.
            let kept = diff.files.filter { $0.headerLine < lineLimit }
            let end = diff.files.first { $0.headerLine >= lineLimit }?.headerLine ?? diff.lines.count
            diff.files = kept
            diff.lines = Array(diff.lines[..<end])
        }
        for (index, file) in diff.files.enumerated() {
            let range = diff.lineRange(ofFileAt: index)
            guard !range.isEmpty else { continue }
            let colored = await SyntaxColors.colored(Array(diff.lines[range]), path: file.path)
            diff.lines.replaceSubrange(range, with: colored)
        }
        commit.additions = diff.files.reduce(0) { $0 + $1.additions }
        commit.deletions = diff.files.reduce(0) { $0 + $1.deletions }
        return CommitReview(commit: commit, diff: diff, truncated: truncated)
    }

    /// Each project's sidebar icon as a small PNG. Encoded once per image.
    /// The file monitor for a project, for a phone or Mac browsing it.
    func fileMonitor(projectID: UUID) -> FileListMonitor? {
        store.project(projectID).map { files.monitor(for: $0) }
    }

    func iconData() -> [UUID: Data] {
        var result: [UUID: Data] = [:]
        for project in store.projects {
            guard let image = icons.image(for: project) else { continue }
            if let data = Self.png(image, for: project.id) { result[project.id] = data }
        }
        return result
    }

    static func kind(_ activity: TabActivity) -> ActivityKind {
        switch activity {
        case .idle: .idle
        case .working: .working
        case .remoteWorking: .remoteWorking
        case .waiting: .waiting
        case .done: .done
        case .attention: .attention
        }
    }

    private static func pullRequest(_ pr: PullRequestInfo) -> CompanionPullRequest {
        let state: CompanionPullRequest.State = switch pr.state {
        case .open: .open
        case .draft: .draft
        case .merged: .merged
        case .closed: .closed
        }
        let checks: CompanionPullRequest.Checks = switch pr.checks {
        case .none: .none
        case .pending: .pending
        case .passing: .passing
        case .failing: .failing
        }
        return CompanionPullRequest(number: pr.number, title: pr.title, url: pr.url, state: state, checks: checks,
                                    passedCount: pr.passedCount, totalCount: pr.totalCount, failingNames: pr.failingNames)
    }

    // MARK: Icons

    private static var pngCache: [UUID: (image: ObjectIdentifier, data: Data)] = [:]

    /// A 128px PNG of the icon, cached until the project gets a new image.
    private static func png(_ image: NSImage, for id: UUID) -> Data? {
        if let cached = pngCache[id], cached.image == ObjectIdentifier(image) { return cached.data }
        let side = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        pngCache[id] = (ObjectIdentifier(image), data)
        return data
    }
}

/// `PackageManager.devCommand`, remembered for a few seconds per folder.
private final class DevCommandCache {
    private var cache: [URL: (read: Date, command: String?)] = [:]

    func command(in folder: URL) -> String? {
        if let hit = cache[folder], Date().timeIntervalSince(hit.read) < 10 { return hit.command }
        let command = PackageManager.devCommand(in: folder)
        cache[folder] = (Date(), command)
        return command
    }
}
