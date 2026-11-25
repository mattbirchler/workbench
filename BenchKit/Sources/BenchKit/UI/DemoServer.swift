import Foundation

/// Stands in for Bench on a Mac so the phone app can be tried without one.
/// It answers the same messages a Mac would, from sample projects, and moves
/// one session along on a timer so the list looks alive.
@MainActor
final class DemoServer {
    var output: (ServerMessage) -> Void = { _ in }

    private var projects: [CompanionProject] = []
    private var transcripts: [UUID: [TranscriptMessage]] = [:]
    /// A project's changes once a Commit, Push or Open PR has moved them
    /// on from the samples.
    private var git: [UUID: ChangesSnapshot] = [:]
    private var watching: Set<UUID> = []
    private var timer: Task<Void, Never>?
    private var step = 0
    private var nextID = 0

    // Fixed ids so the demo looks the same every time.
    private let recipes = UUID(uuidString: "D3E00000-0000-4000-8000-000000000001")!
    private let shoppingAgent = UUID(uuidString: "D3E00000-0000-4000-8000-000000000002")!
    private let website = UUID(uuidString: "D3E00000-0000-4000-8000-000000000003")!
    private let notes = UUID(uuidString: "D3E00000-0000-4000-8000-000000000004")!
    private let recipesSession = UUID(uuidString: "D3E00000-0000-4000-8000-000000000011")!
    private let agentSession = UUID(uuidString: "D3E00000-0000-4000-8000-000000000012")!
    private let websiteSession = UUID(uuidString: "D3E00000-0000-4000-8000-000000000013")!
    private let notesSession = UUID(uuidString: "D3E00000-0000-4000-8000-000000000014")!
    private let blog = UUID(uuidString: "D3E00000-0000-4000-8000-000000000005")!

    func start() {
        build()
        output(.welcome(macName: "Demo Mac", protocolVersion: companionProtocolVersion,
                        features: [CompanionFeature.results, CompanionFeature.interrupt, CompanionFeature.placement,
                                   CompanionFeature.planUsage, CompanionFeature.artifacts,
                                   CompanionFeature.slashCommands, CompanionFeature.notificationPrefs,
                                   CompanionFeature.usage, CompanionFeature.codeReview, CompanionFeature.sideQuestions],
                        appVersion: "0.7.3"))
        sendProjects()
        let now = Date()
        output(.planUsage(PlanUsage(limits: [
            PlanLimit(id: "five_hour", name: "5 hours", shortName: "5h", percent: 34,
                      resetsAt: now.addingTimeInterval(2 * 3600 + 900), window: PlanLimit.fiveHours),
            PlanLimit(id: "seven_day", name: "This week", shortName: "Week", percent: 58,
                      resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600), window: PlanLimit.week),
            PlanLimit(id: "model:fable", name: "Fable", shortName: "Fable", percent: 41,
                      resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600), window: PlanLimit.week, isPerModel: true),
        ], updated: now)))
        output(.usage(Self.sampleUsage(now: now)))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.advance()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func receive(_ message: ClientMessage) {
        switch message {
        case .watchTranscript(let id):
            watching.insert(id)
            output(.transcript(sessionID: id, messages: transcripts[id] ?? [], replaces: true))
        case .unwatchTranscript(let id):
            watching.remove(id)
        case .reply(let id, let text), .replyWithAttachments(let id, let text, _):
            reply(to: id, text: text)
        case .answer(let id, let allow):
            answer(id, allow: allow)
        case .answerQuestions(let id, let answers):
            answerQuestions(id, answers: answers)
        case .watchChanges(let id):
            output(.changes(projectID: id, snapshot: changes(for: id)))
        case .diff(let id, let change):
            let text = Self.wholeFileDiffs[change.path] ?? Self.diffs[change.path] ?? ""
            output(.diff(projectID: id, changeID: change.id, lines: Self.colored(DiffParser.parse(text))))
        case .watchFiles(let id):
            output(.files(projectID: id, listing: FileListing(paths: files(for: id), truncated: false)))
            output(.fileRevision(projectID: id, revision: 1))
        case .readFile(let id, let path):
            let text = Self.fileTexts[path]
            output(.file(projectID: id, path: path, content: text.map { .text($0) } ?? .missing))
            if let text, path.hasSuffix(".swift") {
                output(.fileCode(projectID: id, path: path, runs: DemoCode.runs(text)))
            }
        case .reviewCommit(let id, let hash):
            output(.commitReview(projectID: id, hash: hash, review: commitReview(hash)))
        case .pastSessions(let id):
            output(.pastSessions(projectID: id, sessions: pastSessions(for: id)))
        case .slashCommands(let id):
            output(.slashCommands(projectID: id, commands: SlashCommand.builtIn + [
                SlashCommand(name: "release", description: "Bump the version and publish a build", source: .project),
            ]))
        case .artifacts(let id):
            output(.artifacts(projectID: id, links: id == recipes ? [
                ArtifactLink(url: "https://claude.ai/artifact/demo-shopping", title: "Shopping list mockup",
                             updated: .now.addingTimeInterval(-600), version: 3, icon: "list", sessionTitle: "Add a shopping list"),
                ArtifactLink(url: "https://claude.ai/artifact/demo-colors", title: "Dark mode color audit",
                             updated: .now.addingTimeInterval(-90_000), icon: "palette", sessionTitle: "Support dark mode"),
            ] : []))
        case .resumeSession, .newClaudeTab, .newAgent, .splitTasks, .startTasks:
            output(.problem("This is a demo, so it can't start sessions. Pair with Workbench on your Mac to do that for real."))
        case .reorderProjects(let ids):
            projects.sort { (ids.firstIndex(of: $0.id) ?? .max) < (ids.firstIndex(of: $1.id) ?? .max) }
            sendProjects()
        case .interrupt(let id):
            interrupt(id)
        case .setPermissionMode(let id, let mode):
            update(id) { $0.permissionMode = mode }
        case .askSideQuestion(let id, let questionID, let question):
            var asked = SideQuestion(id: questionID, question: question)
            output(.sideQuestion(sessionID: id, question: asked))
            later(1.5) { [self] in
                asked.answer = "This is the demo, so there's no Claude to ask. With Workbench on your Mac, Claude answers from what it knows "
                    + "in this conversation, and the answer shows here without being added to it."
                asked.state = .answered
                output(.sideQuestion(sessionID: id, question: asked))
            }
        case .pinProject(let id, let pinned):
            place(id) { $0.section = pinned ? .pinned : .active }
        case .setProjectActive(let id, let active):
            place(id) { $0.section = active ? .active : .inactive }
        case .hello, .ping, .unwatchChanges, .unwatchFiles, .registerPush, .notificationPrefs, .registerActivity, .registerActivityStart, .registerDashboard, .features, .takeBackQueue, .sendQueueNow, .image, .earlierTranscript, .setBaseRef, .refreshChanges, .closeSession, .removeAgent, .runShortcut, .stopShortcut, .dismissSideQuestion,
             .renameProject, .setProjectIcon, .showHiddenWorktrees, .removeProject, .hideExternalWorktree, .setNotifiesPhone,
             .setClaudeAccount, .setPermissionMode, .writeFile, .browseFolder, .addProject:
            break
        }
    }

    // MARK: Behavior

    private func reply(to id: UUID, text: String) {
        output(.sent(sessionID: id, ok: true, problem: nil))
        append(id, .user, text)
        if let action = ChangesAction.matching(prompt: text) { return act(action, in: id) }
        update(id) {
            $0.activity = .working
            $0.suggestion = nil
            $0.prompt = text
            $0.action = "Thinking"
            $0.question = nil
            $0.isAllowOrDeny = false
            $0.since = .now
        }
        later(2) { [self] in
            append(id, .assistant, "This is the demo, so nothing actually runs. With Workbench on your Mac, Claude Code would get your message right away, and you'd watch it work from here.")
            update(id) {
                $0.activity = .done
                $0.action = nil
                $0.summary = "Replied in the demo."
                $0.stoppedAt = .now
            }
        }
    }

    private func answer(_ id: UUID, allow: Bool) {
        output(.sent(sessionID: id, ok: true, problem: nil))
        update(id) {
            $0.question = nil
            $0.isAllowOrDeny = false
            $0.activity = .working
            $0.action = allow ? "Running npm run build" : "Thinking"
            $0.since = .now
        }
        if allow {
            append(id, .tool, "Running npm run build", toolName: "Bash", detail: "npm run build", toolUseID: "demo-build")
        } else {
            append(id, .user, "No, don't run that.")
        }
        later(3) { [self] in
            if allow {
                append(id, .tool, "vite v6.2.0 building for production...\n✓ 48 modules transformed.\n✓ built in 1.24s",
                       resultOf: "demo-build")
            }
            append(id, .assistant, allow
                   ? "The build passed. The new pricing page is in `dist/pricing/index.html` and the nav links to it."
                   : "Okay, I won't build it. The pricing page changes are ready whenever you want to check them.")
            update(id) {
                $0.activity = .done
                $0.action = nil
                $0.summary = allow ? "Added the pricing page; the build passes." : "Pricing page ready; build skipped."
                $0.stoppedAt = .now
            }
        }
    }

    /// Stop works on anything that's working; the recipes session picks
    /// up again on its next step, the way the demo loops.
    private func interrupt(_ id: UUID) {
        guard projects.flatMap(\.sessions).first(where: { $0.id == id })?.activity == .working else {
            output(.sent(sessionID: id, ok: false, problem: "Claude isn't working on anything right now."))
            return
        }
        output(.sent(sessionID: id, ok: true, problem: nil))
        update(id) {
            $0.activity = .done
            $0.action = nil
            $0.summary = "Stopped. Tell Claude what to do instead."
            $0.stoppedAt = .now
        }
    }

    private func answerQuestions(_ id: UUID, answers: [CompanionAnswer]) {
        output(.sent(sessionID: id, ok: true, problem: nil))
        let question = projects.flatMap(\.sessions).first { $0.id == id }?.questions?.first
        let choice = answers.first.flatMap { answer in
            answer.other ?? answer.selected.first.flatMap { question?.options.indices.contains($0) == true ? question?.options[$0].label : nil }
        } ?? "that"
        update(id) {
            $0.questions = nil
            $0.question = nil
            $0.activity = .working
            $0.action = "Editing Exporter.swift"
            $0.since = .now
        }
        append(id, .tool, "Editing Exporter.swift", toolName: "Edit", detail: "Sources/Export/Exporter.swift",
               edit: .between("        let first = pages.first!\n", "        guard let first = pages.first else {\n            return emptyExport(for: notebook)\n        }\n"))
        later(3) { [self] in
            append(id, .assistant, "Done: an empty notebook now exports with “\(choice)”, and there's a test that exports one.")
            update(id) {
                $0.activity = .done
                $0.action = nil
                $0.summary = "Empty notebooks export without crashing."
                $0.stoppedAt = .now
            }
        }
    }

    /// Moves the recipes session through its checklist, then starts over.
    private func advance() {
        step += 1
        let actions = ["Editing ShoppingList.swift", "Reading RecipeStore.swift", "Running the tests",
                       "Editing ShoppingListView.swift", "Building the app"]
        update(recipesSession) { session in
            let done = min(step / 2 % 6, 5)
            session.action = actions[step % actions.count]
            session.activity = done == 5 ? .done : .working
            session.checklist = Self.checklist(done: done)
            session.contextTokens = 48_000 + (step % 12) * 3_500
            if var agent = session.agents?.first {
                agent.action = ["Reading CloudSync.swift", "Searching for iCloud", "Reading RecipeStore.swift"][step % 3]
                agent.steps = 6 + step % 9
                session.agents = [agent]
            }
            if done == 5 {
                session.summary = "Shopping lists work: add from any recipe, check off items, and they sync."
                session.stoppedAt = .now
                session.action = nil
            } else {
                session.summary = nil
                session.stoppedAt = nil
            }
        }
        if step % 2 == 0 {
            append(recipesSession, .tool, actions[step % actions.count], toolName: "Edit")
        }
    }

    // MARK: Plumbing

    private func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    private func update(_ sessionID: UUID, _ change: (inout CompanionSession) -> Void) {
        for p in projects.indices {
            for s in projects[p].sessions.indices where projects[p].sessions[s].id == sessionID {
                change(&projects[p].sessions[s])
                projects[p].activity = projects[p].sessions.map(\.activity).max { rank($0) < rank($1) } ?? .idle
            }
        }
        sendProjects()
    }

    private func rank(_ kind: ActivityKind) -> Int {
        switch kind {
        case .idle: 0
        case .done: 1
        case .working, .remoteWorking: 2
        case .waiting, .attention: 3
        }
    }

    private func append(_ sessionID: UUID, _ role: TranscriptMessage.Role, _ text: String,
                        toolName: String? = nil, detail: String? = nil, edit: ToolEdit? = nil,
                        toolUseID: String? = nil, resultOf: String? = nil) {
        nextID += 1
        let message = TranscriptMessage(id: "demo-live-\(nextID)", role: role, text: text, detail: detail,
                                        toolName: toolName, at: .now, edit: edit, toolUseID: toolUseID, resultOf: resultOf,
                                        isError: resultOf == nil ? nil : false)
        transcripts[sessionID, default: []].append(message)
        if watching.contains(sessionID) {
            output(.transcript(sessionID: sessionID, messages: [message], replaces: false))
        }
    }

    private func place(_ id: UUID, _ change: (inout CompanionProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[index])
        projects[index].isPinned = projects[index].section == .pinned
        projects[index].isActive = projects[index].section != .inactive
        // In section order, each project followed by its worktrees.
        let rank = { (p: CompanionProject) in CompanionSection.allCases.firstIndex(of: p.section ?? .active) ?? 0 }
        let top = projects.filter { !$0.isWorktree }.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        projects = top.flatMap { parent in [parent] + projects.filter { $0.parentID == parent.id } }
        sendProjects()
    }

    private func sendProjects() {
        output(.projects(ProjectsSnapshot(projects: projects)))
    }

    // MARK: Sample data

    private static func checklist(done: Int) -> [ChecklistItem] {
        let titles = [("Add a ShoppingList model", "Adding a ShoppingList model"),
                      ("Save lists with the recipes", "Saving lists with the recipes"),
                      ("Add items from a recipe", "Adding items from a recipe"),
                      ("Check off items", "Adding check-off"),
                      ("Write tests", "Writing tests")]
        return titles.enumerated().map { index, title in
            ItemStatus(index: index, done: done).item(id: "\(index)", title: title.0, active: title.1)
        }
    }

    private struct ItemStatus {
        let index: Int
        let done: Int
        func item(id: String, title: String, active: String) -> ChecklistItem {
            let status: ChecklistItem.Status = index < done ? .completed : index == done ? .inProgress : .pending
            return ChecklistItem(id: id, title: title, activeTitle: active, status: status,
                                 startedAt: status == .inProgress ? .now : nil)
        }
    }

    private func build() {
        let minute: TimeInterval = 60
        projects = [
            CompanionProject(
                id: recipes, name: "Recipes", repoName: "recipes", path: "~/Code/recipes", branch: "main",
                activity: .working,
                sessions: [CompanionSession(
                    id: recipesSession, title: "Add a shopping list", activity: .working,
                    prompt: "Add a shopping list. I want to add ingredients from any recipe and check them off at the store.",
                    action: "Editing ShoppingList.swift", contextTokens: 48_000, contextWindow: 200_000, model: "Opus 5.5",
                    canReply: true, since: .now.addingTimeInterval(-6 * minute), checklist: Self.checklist(done: 2),
                    agents: [AgentStatus(toolUseID: "r7t", description: "Find where recipes are saved and synced", type: "Explore",
                                         isFinished: false, isRunning: true, action: "Reading CloudSync.swift", steps: 6,
                                         startedAt: .now.addingTimeInterval(-50))],
                    permissionMode: PermissionMode.acceptEdits.rawValue)],
                uncommittedAdditions: 30, uncommittedDeletions: 1),
            CompanionProject(
                id: shoppingAgent, name: "dark-mode", repoName: "recipes", path: "~/Code/recipes-agents/dark-mode",
                branch: "agent/dark-mode", parentID: recipes, activity: .done,
                pullRequest: CompanionPullRequest(
                    number: 42, title: "Support dark mode", url: URL(string: "https://github.com")!,
                    state: .open, checks: .passing, passedCount: 3, totalCount: 3, failingNames: []),
                sessions: [CompanionSession(
                    id: agentSession, title: "Support dark mode", activity: .done,
                    prompt: "Make every screen work in dark mode, and open a PR when it looks right.",
                    summary: "Opened PR #42. Every screen uses semantic colors now, and the recipe photos get a subtle border in dark mode.",
                    stoppedAt: .now.addingTimeInterval(-25 * minute), canReply: true,
                    agents: [AgentStatus(toolUseID: "a2at", description: "List every hard-coded color", type: "Explore",
                                         isFinished: true, isRunning: false, steps: 14,
                                         startedAt: .now.addingTimeInterval(-39 * minute), finishedAt: .now.addingTimeInterval(-38 * minute - 12)),
                             AgentStatus(toolUseID: "a2bt", description: "Check images and icons for dark variants", type: "Explore",
                                         isFinished: true, isRunning: false, steps: 9,
                                         startedAt: .now.addingTimeInterval(-39 * minute), finishedAt: .now.addingTimeInterval(-38 * minute - 40))],
                    suggestion: "merge the PR")],
                uncommittedAdditions: 124, uncommittedDeletions: 18),
            CompanionProject(
                id: website, name: "Website", repoName: "website", path: "~/Code/website", branch: "pricing-page",
                activity: .waiting,
                sessions: [CompanionSession(
                    id: websiteSession, title: "Pricing page", activity: .waiting,
                    prompt: "Add a pricing page with the three plans, and link it from the nav.",
                    question: "Claude wants to run: npm run build", isAllowOrDeny: true, canReply: true,
                    since: .now.addingTimeInterval(-2 * minute), command: "npm run build")],
                uncommittedAdditions: 1, uncommittedDeletions: 0),
            CompanionProject(
                id: notes, name: "Field Notes", repoName: "field-notes", path: "~/Code/field-notes", branch: "main",
                activity: .waiting,
                sessions: [CompanionSession(
                    id: notesSession, title: "Fix the export crash", activity: .waiting,
                    prompt: "Exporting a notebook with no pages crashes. Find out why and fix it.",
                    question: "What should an empty notebook export as?", canReply: false,
                    replyProblem: "Claude is asking you a question. Answer it first.",
                    since: .now.addingTimeInterval(-4 * minute),
                    questions: [CompanionQuestion(
                        question: "What should an empty notebook export as?", header: "Empty export",
                        options: [.init(label: "A title page", description: "One page with the notebook's name and date."),
                                  .init(label: "Nothing, with a message", description: "Skip the file and say the notebook is empty.")])])],
                uncommittedAdditions: 3, uncommittedDeletions: 1),
            CompanionProject(
                id: blog, name: "Blog", repoName: "blog", path: "~/Code/blog", branch: "main", activity: .idle,
                deploy: CompanionDeploy(state: .deploying, prNumber: 18, place: "blog / production", url: nil),
                defaultBranch: "main", uncommittedAdditions: 9, uncommittedDeletions: 2),
        ]

        for index in projects.indices where !projects[index].isWorktree {
            let id = projects[index].id
            let section: CompanionSection = id == recipes ? .pinned : id == notes ? .inactive : id == blog ? .recent : .active
            projects[index].section = section
            projects[index].isActive = section != .inactive
            projects[index].isPinned = section == .pinned
        }

        let ago = { (m: Double) in Date.now.addingTimeInterval(-m * minute) }
        transcripts = [
            recipesSession: [
                .init(id: "r1", role: .user, text: "Add a shopping list. I want to add ingredients from any recipe and check them off at the store.", at: ago(6)),
                .init(id: "r2", role: .assistant, text: "I'll start with a `ShoppingList` model saved next to the recipes, then add a button on each recipe and a list screen with check-off.", at: ago(6)),
                .init(id: "r3", role: .tool, text: "Reading RecipeStore.swift", detail: "Sources/RecipeStore.swift", toolName: "Read", at: ago(5)),
                .init(id: "r4", role: .tool, text: "Writing ShoppingList.swift", detail: "Sources/ShoppingList.swift", toolName: "Write", at: ago(4),
                      edit: .written("struct ShoppingList: Codable {\n    var items: [Item] = []\n\n    struct Item: Codable, Identifiable {\n        var id = UUID()\n        var name: String\n        var recipeID: Recipe.ID?\n        var isChecked = false\n    }\n}\n")),
                .init(id: "r5", role: .assistant, text: "The model is in. Each item remembers which recipe it came from, so removing a recipe can offer to clear its items too.", at: ago(3)),
                .init(id: "r6", role: .tool, text: "Editing RecipeStore.swift", detail: "Sources/RecipeStore.swift", toolName: "Edit", at: ago(2),
                      edit: .between("    var recipes: [Recipe] = []\n", "    var recipes: [Recipe] = []\n    var shoppingList = ShoppingList()\n")),
                .init(id: "r7", role: .tool, text: "Running a subagent: Find where recipes are saved and synced", toolName: "Agent", at: ago(1),
                      toolUseID: "r7t", agent: AgentCall(description: "Find where recipes are saved and synced", type: "Explore", background: true)),
            ],
            agentSession: [
                .init(id: "a1", role: .user, text: "Make every screen work in dark mode, and open a PR when it looks right.", at: ago(40)),
                .init(id: "a2", role: .tool, text: "Finding **/*.swift", detail: "**/*.swift", toolName: "Glob", at: ago(39)),
                .init(id: "a2a", role: .tool, text: "Running a subagent: List every hard-coded color", toolName: "Agent", at: ago(39),
                      toolUseID: "a2at", agent: AgentCall(description: "List every hard-coded color", type: "Explore")),
                .init(id: "a2b", role: .tool, text: "Running a subagent: Check images and icons for dark variants", toolName: "Agent", at: ago(39),
                      toolUseID: "a2bt", agent: AgentCall(description: "Check images and icons for dark variants", type: "Explore")),
                .init(id: "a2ar", role: .tool, text: "Found 31 fixed colors in 12 files.", at: ago(38), resultOf: "a2at"),
                .init(id: "a2br", role: .tool, text: "Two images need dark variants.", at: ago(38), resultOf: "a2bt"),
                .init(id: "a3", role: .assistant, text: "Most screens used fixed colors. I'm switching them to semantic colors from the asset catalog.", at: ago(38)),
                .init(id: "a4", role: .tool, text: "Running gh pr create", detail: "gh pr create --fill", toolName: "Bash", at: ago(26), toolUseID: "a4t"),
                .init(id: "a4r", role: .tool, text: "https://github.com/you/recipes/pull/42", at: ago(26), resultOf: "a4t", isError: false),
                .init(id: "a5", role: .assistant, text: "Opened **PR #42**.\n\n- Every screen uses semantic colors\n- Recipe photos get a subtle border in dark mode\n- Checked both appearances in the simulator", at: ago(25)),
            ],
            websiteSession: [
                .init(id: "w1", role: .user, text: "Add a pricing page with the three plans, and link it from the nav.", at: ago(8)),
                .init(id: "w2", role: .tool, text: "Writing src/pages/pricing.astro", detail: "src/pages/pricing.astro", toolName: "Write", at: ago(6),
                      edit: .written("---\nimport Layout from '../layouts/Layout.astro'\nimport Plan from '../components/Plan.astro'\n---\n<Layout title=\"Pricing\">\n  <h1>Pick a plan</h1>\n  <div class=\"plans\">\n    <Plan name=\"Starter\" price=\"$0\" />\n    <Plan name=\"Pro\" price=\"$12\" />\n    <Plan name=\"Team\" price=\"$40\" />\n  </div>\n</Layout>\n")),
                .init(id: "w3", role: .tool, text: "Editing src/components/Nav.astro", detail: "src/components/Nav.astro", toolName: "Edit", at: ago(4),
                      edit: .between("  <a href=\"/blog\">Blog</a>\n", "  <a href=\"/blog\">Blog</a>\n  <a href=\"/pricing\">Pricing</a>\n")),
                .init(id: "w4", role: .assistant, text: "The page and nav link are done. I'd like to run the build to make sure nothing broke.", at: ago(2)),
            ],
            notesSession: [
                .init(id: "n1", role: .user, text: "Exporting a notebook with no pages crashes. Find out why and fix it.", at: ago(8)),
                .init(id: "n2", role: .tool, text: "Searching for “pages.first!”", detail: "pages.first!", toolName: "Grep", at: ago(6)),
                .init(id: "n3", role: .assistant, text: "Found it: `Exporter` force-unwraps `pages.first`, so a notebook with no pages crashes.", at: ago(5)),
                .init(id: "n4", role: .tool, text: "Asking you a question", toolName: "AskUserQuestion", at: ago(4)),
            ],
        ]
    }

    private func changes(for id: UUID) -> ChangesSnapshot {
        if let moved = git[id] { return moved }
        return switch id {
        case recipes:
            ChangesSnapshot(branch: "main", baseRef: "origin/main", unstaged: [
                FileChange(path: "Recipes/Models/ShoppingList.swift", kind: .untracked, additions: 24, deletions: 0, section: .unstaged),
                FileChange(path: "Recipes/Models/RecipeStore.swift", kind: .modified, additions: 6, deletions: 1, section: .unstaged),
            ], upstream: "origin/main", unpushed: 0, branches: ["main"])
        case shoppingAgent:
            // Work since the pull request went up, not committed yet.
            ChangesSnapshot(branch: "agent/dark-mode", baseRef: "origin/main", unstaged: [
                FileChange(path: "Recipes/Views/ShoppingListView.swift", kind: .modified, additions: 96, deletions: 14, section: .unstaged),
                FileChange(path: "Recipes/Models/RecipeStore.swift", kind: .modified, additions: 28, deletions: 4, section: .unstaged),
            ], againstBase: [
                FileChange(path: "Recipes/Views/RecipeCard.swift", kind: .modified, additions: 4, deletions: 3, section: .againstBase),
            ], commits: [Commit(hash: "4f1c2a9e", shortHash: "4f1c2a9", subject: "Support dark mode", body: "",
                                author: "Claude", date: .now.addingTimeInterval(-1600), additions: 4, deletions: 3)],
                            upstream: "origin/agent/dark-mode", unpushed: 0, branches: ["main"])
        case website:
            ChangesSnapshot(branch: "pricing-page", baseRef: "origin/main", unstaged: [
                FileChange(path: "src/components/Nav.astro", kind: .modified, additions: 1, deletions: 0, section: .unstaged),
            ], branches: ["main"])
        case notes:
            ChangesSnapshot(branch: "main", baseRef: "origin/main", unstaged: [
                FileChange(path: "FieldNotes/Exporter.swift", kind: .modified, additions: 3, deletions: 1, section: .unstaged),
            ], upstream: "origin/main", unpushed: 0, branches: ["main"])
        case blog:
            ChangesSnapshot(branch: "main", baseRef: "origin/main", unstaged: [
                FileChange(path: "posts/shopping-lists.md", kind: .modified, additions: 9, deletions: 2, section: .unstaged),
            ], upstream: "origin/main", unpushed: 0, branches: ["main"])
        default:
            ChangesSnapshot(branch: "main", baseRef: "origin/main", upstream: "origin/main", unpushed: 0, branches: ["main"])
        }
    }

    /// Acts out a Commit, Push or Open PR from the Changes screen: the
    /// session works for a moment, then the project's changes, counts and
    /// pull request move on as they would on a Mac.
    private func act(_ action: ChangesAction, in sessionID: UUID) {
        guard let id = projects.first(where: { $0.sessions.contains { $0.id == sessionID } })?.id else { return }
        let command = switch action {
        case .commit: "git commit"
        case .push: "git push"
        case .pullRequest: "gh pr create"
        }
        update(sessionID) {
            $0.activity = .working
            $0.action = "Running \(command)"
            $0.question = nil
            $0.questions = nil
            $0.isAllowOrDeny = false
            $0.since = .now
        }
        later(3) { [self] in
            var state = changes(for: id)
            let branch = state.branch ?? "main"
            var said = ""
            // Open PR commits what's uncommitted and pushes first.
            if action != .push, !(state.staged + state.unstaged).isEmpty {
                let files = state.staged + state.unstaged
                let subject = id == website ? "Link the pricing page from the nav" : "Polish the shopping list in dark mode"
                state.commits.insert(Commit(hash: "9b3e7d1\(nextID)", shortHash: "9b3e7d1", subject: subject, body: "", author: "Claude",
                                            date: .now, additions: files.reduce(0) { $0 + $1.additions },
                                            deletions: files.reduce(0) { $0 + $1.deletions }), at: 0)
                state.againstBase += files.filter { file in !state.againstBase.contains { $0.path == file.path } }.map {
                    FileChange(path: $0.path, kind: $0.kind == .untracked ? .added : $0.kind,
                               additions: $0.additions, deletions: $0.deletions, section: .againstBase)
                }
                state.staged = []
                state.unstaged = []
                state.unpushed = (state.unpushed ?? 0) + 1
                said = "Committed as 9b3e7d1: \(subject). Nothing is pushed yet."
            }
            if action != .commit {
                state.upstream = "origin/\(branch)"
                state.unpushed = 0
                said = "Pushed \(branch) to origin."
            }
            git[id] = state
            output(.changes(projectID: id, snapshot: state))
            if let index = projects.firstIndex(where: { $0.id == id }) {
                projects[index].uncommittedAdditions = 0
                projects[index].uncommittedDeletions = 0
                if action == .pullRequest {
                    let title = state.commits.first?.subject ?? branch
                    projects[index].pullRequest = CompanionPullRequest(
                        number: 43, title: title, url: URL(string: "https://github.com")!, state: .open, checks: .pending,
                        passedCount: 0, totalCount: 3, failingNames: [])
                    said = "Opened pull request #43, \(title). Its checks are running."
                }
            }
            append(sessionID, .assistant, said)
            update(sessionID) {
                $0.activity = .done
                $0.action = nil
                $0.summary = said
                $0.stoppedAt = .now
            }
        }
    }

    private func commitReview(_ hash: String) -> CommitReview? {
        guard let commit = changes(for: shoppingAgent).commits.first(where: { $0.hash == hash }) else { return nil }
        let path = "Recipes/Views/RecipeCard.swift"
        var diff = ReviewDiff(parsing: "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n" + (Self.diffs[path] ?? ""))
        diff.lines = Self.colored(diff.lines)
        var full = commit
        full.body = "Cards used fixed black and white, so they disappeared in dark mode. They now use the system's label colors and a card background from the asset catalog."
        return CommitReview(commit: full, diff: diff, truncated: false)
    }

    /// Demo diffs are all Swift or close enough, so color each line alone.
    private static func colored(_ lines: [DiffLine]) -> [DiffLine] {
        lines.map { line in
            var line = line
            if line.kind == .context || line.kind == .added || line.kind == .removed {
                let runs = DemoCode.runs(line.text)
                if !runs.isEmpty { line.code = runs }
            }
            return line
        }
    }

    private func files(for id: UUID) -> [String] {
        switch id {
        case website: ["README.md", "package.json", "src/components/Nav.astro", "src/pages/index.astro", "src/pages/pricing.astro"]
        case notes: ["README.md", "FieldNotes/Exporter.swift", "FieldNotes/Notebook.swift", "FieldNotesTests/ExporterTests.swift"]
        default: ["README.md", "Recipes/Models/RecipeStore.swift", "Recipes/Models/ShoppingList.swift",
                  "Recipes/Views/RecipeCard.swift", "Recipes/Views/ShoppingListView.swift"]
        }
    }

    private func pastSessions(for id: UUID) -> [PastSessionSummary] {
        [PastSessionSummary(id: "demo-past-1", title: "Speed up search", firstPrompt: "Search feels slow with a lot of recipes.",
                            branch: "main", modified: .now.addingTimeInterval(-86_400 * 2)),
         PastSessionSummary(id: "demo-past-2", title: "Add recipe photos", firstPrompt: "Let me attach a photo to each recipe.",
                            branch: "main", modified: .now.addingTimeInterval(-86_400 * 5))]
    }

    /// What a Mac with the codeReview feature sends: the whole file.
    private static let wholeFileDiffs: [String: String] = [
        "Recipes/Views/RecipeCard.swift": """
        @@ -1,34 +1,35 @@
         import SwiftUI
         
         /// A recipe in the list: its photo, title and summary.
         struct RecipeCard: View {
             let recipe: Recipe
             var isFavorite = false
         
             var body: some View {
                 HStack(spacing: 12) {
                     RecipePhoto(recipe: recipe)
                         .frame(width: 64, height: 64)
                         .clipShape(RoundedRectangle(cornerRadius: 8))
                     VStack(alignment: .leading) {
                         Text(recipe.title)
        -                    .foregroundStyle(.black)
        +                    .foregroundStyle(.primary)
                         Text(recipe.summary)
        -                    .foregroundStyle(Color(white: 0.4))
        +                    .foregroundStyle(.secondary)
                     }
        -            .background(.white)
        +            .background(Color("CardBackground"))
        +            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                     Spacer()
                     if isFavorite {
                         Image(systemName: "heart.fill")
                             .foregroundStyle(.pink)
                     }
                 }
                 .padding(.vertical, 6)
                 .accessibilityElement(children: .combine)
             }
         }
         
         #Preview {
             RecipeCard(recipe: .sample, isFavorite: true)
                 .padding()
         }
        """,
    ]

    private static let diffs: [String: String] = [
        "Recipes/Models/ShoppingList.swift": """
        @@ -0,0 +1,24 @@
        +import Foundation
        +
        +/// Ingredients to buy, each remembering the recipe it came from.
        +struct ShoppingList: Codable {
        +    struct Item: Codable, Identifiable {
        +        var id = UUID()
        +        var name: String
        +        var recipeID: UUID?
        +        var isChecked = false
        +    }
        +
        +    var items: [Item] = []
        +
        +    mutating func add(_ recipe: Recipe) {
        +        for ingredient in recipe.ingredients where !items.contains(where: { $0.name == ingredient.name }) {
        +            items.append(Item(name: ingredient.name, recipeID: recipe.id))
        +        }
        +    }
        +
        +    mutating func toggle(_ item: Item) {
        +        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        +        items[index].isChecked.toggle()
        +    }
        +}
        """,
        "Recipes/Models/RecipeStore.swift": """
        @@ -8,7 +8,12 @@ final class RecipeStore {
             var recipes: [Recipe] = []
        -    var favorites: Set<UUID> = []
        +    var favorites: Set<UUID> = []
        +    var shoppingList = ShoppingList()
        +
        +    func addToShoppingList(_ recipe: Recipe) {
        +        shoppingList.add(recipe)
        +        save()
        +    }

             func save() {
                 let data = try? JSONEncoder().encode(recipes)
        """,
        "Recipes/Views/RecipeCard.swift": """
        @@ -12,9 +12,10 @@ struct RecipeCard: View {
                 VStack(alignment: .leading) {
                     Text(recipe.title)
        -                .foregroundStyle(.black)
        +                .foregroundStyle(.primary)
                     Text(recipe.summary)
        -                .foregroundStyle(Color(white: 0.4))
        +                .foregroundStyle(.secondary)
                 }
        -        .background(.white)
        +        .background(Color("CardBackground"))
        +        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        """,
        "src/components/Nav.astro": """
        @@ -3,6 +3,7 @@
           <a href="/">Home</a>
           <a href="/blog">Blog</a>
        +  <a href="/pricing">Pricing</a>
           <a href="/about">About</a>
         </nav>
        """,
    ]

    private static let fileTexts: [String: String] = [
        "FieldNotes/Exporter.swift": """
        @@ -12,3 +12,5 @@
             func export(_ notebook: Notebook) -> Data {
        -        let first = notebook.pages.first!
        +        guard let first = notebook.pages.first else {
        +            return emptyExport(for: notebook)
        +        }
                 return render(first, in: notebook)
        """,
        "posts/shopping-lists.md": """
        @@ -1,6 +1,13 @@
         # Shopping lists are here

        -Recipes can now make a list for you.
        -More soon.
        +Recipes can now make a shopping list for you.
        +
        +- Add ingredients from any recipe
        +- Check them off at the store
        +- Lists sync between your devices
        +
        +Dark mode is next. It's in review now,
        +and should be out this week.
        +
         Thanks for reading.
        """,
        "README.md": "# Demo project\n\nThis is sample content from Workbench's demo. Pair with Workbench on your Mac to see your own projects here.\n",
        "Recipes/Views/ShoppingListView.swift": """
        import SwiftUI

        struct ShoppingListView: View {
            @Environment(RecipeStore.self) private var store

            var body: some View {
                List(store.shoppingList.items) { item in
                    Label(item.name, systemImage: item.isChecked ? "checkmark.circle.fill" : "circle")
                }
                .navigationTitle("Shopping List")
            }
        }
        """,
    ]
}

extension DemoServer {
    /// A month of made-up usage that rises and falls like real work.
    static func sampleUsage(now: Date) -> CompanionUsage {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let days = (0..<30).reversed().map { back -> CompanionUsage.Day in
            let date = calendar.date(byAdding: .day, value: -back, to: today)!
            let weekend = calendar.isDateInWeekend(date)
            let wave = 1 + 0.6 * sin(Double(back) / 2.3)
            let opus = weekend ? 4.0 * wave : 38.0 * wave
            let fable = weekend ? 1.5 * wave : 12.0 * wave * (back % 3 == 0 ? 1.8 : 1)
            let haiku = 0.4 * wave
            let cost = ["Opus": opus, "Fable": fable, "Haiku": haiku]
            return CompanionUsage.Day(day: formatter.string(from: date), cost: cost, tokens: Int((opus + fable + haiku) * 210_000))
        }
        let total = days.reduce(0) { $0 + $1.total }
        let opus = days.reduce(0) { $0 + ($1.cost["Opus"] ?? 0) }
        let fable = days.reduce(0) { $0 + ($1.cost["Fable"] ?? 0) }
        return CompanionUsage(days: days, models: [
            .init(name: "Opus 5.5", family: "Opus", cost: opus, tokens: Int(opus * 210_000)),
            .init(name: "Fable 5.1", family: "Fable", cost: fable, tokens: Int(fable * 190_000)),
            .init(name: "Haiku 5.5", family: "Haiku", cost: total - opus - fable, tokens: Int((total - opus - fable) * 900_000)),
        ], cacheSavings: total * 2.4, updated: now.addingTimeInterval(-240))
    }
}
