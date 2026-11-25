import BenchKit
import SwiftUI

/// The first screen on a phone: what needs you, then what Claude is doing,
/// then what it finished, as rows you can open in one tap. Projects with
/// nothing going on fold below, one line each.
///
/// Rows above the fold are sessions, not projects, since a project with
/// two Claude tabs can have one asking you a question while the other
/// works. On a wide iPad window this same list is the sidebar.
struct ProjectsView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(PairingStore.self) private var pairing
    @Environment(Navigator.self) private var navigator
    @Environment(ActivityManager.self) private var activities
    @Environment(QueueStore.self) private var queue
    @State private var showsSettings = false
    @State private var showsUsage = false
    @State private var pendingAgentAction: AgentAction?
    /// When the morning summary you put away was written.
    @State private var reachability = MacReachability()
    /// The order just dragged into, shown until the Mac's next snapshot
    /// agrees, so the rows don't snap back for a second.
    @State private var pendingOrder: [UUID]?
    /// Where you just put a project (pinned, inactive), shown until the
    /// Mac's next list agrees, so the row moves when you ask, not when
    /// the Mac answers.
    @State private var pendingPlacement: [UUID: CompanionSection] = [:]
    /// Counts pins and moves, for the tap that goes with each.
    @State private var placementTaps = 0
    /// The list as it was when your finger came down. Shown until you let
    /// go, so rows don't re-sort under a scroll.
    @State private var heldSnapshot: ProjectsSnapshot?
    /// True once the Mac has been out of reach long enough to say so.
    @State private var connectionBannerDue = false
    @AppStorage("inactiveCollapsed") private var inactiveCollapsed = false
    /// The custom groups folded away on this phone, by id, plus
    /// "ungrouped" for Ungrouped. Comma-separated.
    @AppStorage("collapsedGroups") private var collapsedGroups = ""
    @State private var query = ""
    /// False until the first list has been drawn and had a moment to
    /// settle, so its arrival isn't animated.
    @State private var hasSettled = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = ProjectsView.debugShowsInspector ? NavigationSplitViewVisibility.detailOnly : .all
    /// The window's width, to tell when the sidebar has to cover the chat
    /// and when the inspector fits beside both.
    @State private var width: CGFloat = 0

    /// The inspector beside the chat on a window wide enough for all
    /// three panes. Remembered between launches.
    @AppStorage("iPadInspectorShown") private var wideInspector = true
    /// The inspector on a narrower iPad window, where it takes the
    /// sidebar's place. Starts hidden (BENCH_SHOW_INSPECTOR=1 opens it, for screenshots).
    @State private var narrowInspector = ProjectsView.debugShowsInspector

    private static var debugShowsInspector: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BENCH_SHOW_INSPECTOR"] != nil
        #else
        false
        #endif
    }

    /// A wide iPad window: projects in a sidebar, like Bench on the Mac.
    private var isSplit: Bool { sizeClass == .regular }
    /// Room for projects, the chat and the inspector side by side.
    private var fitsThreePanes: Bool { width >= 1180 }

    /// The project the inspector shows, when there's one to show. A Mac
    /// that's out of reach has no changes or files to send.
    private var inspectorProject: UUID? {
        guard let id = navigator.selected, !client.isShowingSaved,
              client.snapshot?.projects.contains(where: { $0.id == id }) == true else { return nil }
        return id
    }

    private var showsInspector: Bool {
        inspectorProject != nil && (fitsThreePanes ? wideInspector : narrowInspector)
    }

    /// The sidebar and the inspector open and close on one curve, so the
    /// chat between them is pushed the same way from either side.
    private static let paneMotion = Animation.snappy(duration: 0.3)

    private func setInspector(_ shown: Bool) {
        withAnimation(Self.paneMotion) {
            if fitsThreePanes {
                wideInspector = shown
            } else {
                narrowInspector = shown
                if shown { columns = .detailOnly }
            }
        }
    }

    var body: some View {
        @Bindable var navigator = navigator
        Group {
            if isSplit {
                // The inspector sits beside the split view, not in its detail
                // column: a pushed screen covers that whole column, and the
                // system's .inspector broke pushes or the upright sidebar.
                HStack(spacing: 0) {
                    NavigationSplitView(columnVisibility: $columns) {
                        projectList
                            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
                    } detail: {
                        NavigationStack(path: $navigator.detailPath) {
                            detailRoot
                                .environment(\.toggleSidebar) {
                                    withAnimation(Self.paneMotion) { columns = columns == .detailOnly ? .all : .detailOnly }
                                }
                                .projectRoutes()
                        }
                        .environment(\.inspector, inspectorProject == nil ? nil
                                     : InspectorToggle(isShown: showsInspector) { setInspector(!showsInspector) })
                    }
                    .navigationSplitViewStyle(.balanced)
                    // Bringing the sidebar back where all three don't fit puts
                    // the inspector away, so the chat keeps its room.
                    .onChange(of: columns) { _, new in
                        if !fitsThreePanes, new != .detailOnly, narrowInspector { withAnimation(Self.paneMotion) { narrowInspector = false } }
                    }
                    // Too narrow for both side by side (an iPad mini upright),
                    // the sidebar covers the chat. Picking a project puts it
                    // away; the sidebar button brings it back.
                    .onChange(of: navigator.selected, initial: true) { _, selected in
                        if selected != nil, width > 0, width < 1000 { tuckSidebar() }
                    }
                    .onChange(of: width) { old, new in
                        if old == 0, new < 1000, navigator.selected != nil { tuckSidebar() }
                    }
                    // A column of its own, as on the Mac. Where all three don't
                    // fit, it takes the sidebar's place.
                    if showsInspector, let id = inspectorProject {
                        Divider().ignoresSafeArea()
                        InspectorPane(projectID: id)
                            .id(id)
                            .frame(width: 300)
                            .background(PhoneTheme.canvas)
                            .transition(.move(edge: .trailing))
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            } else {
                NavigationStack(path: $navigator.path) {
                    projectList.projectRoutes()
                }
            }
        }
        .tint(PhoneTheme.ink)
    }

    /// Hides the sidebar covering the chat. Done a beat later: right after
    /// a change of project, the split view puts the sidebar back itself.
    private func tuckSidebar() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(Self.paneMotion) { columns = .detailOnly }
        }
    }

    /// The selected project, or a nudge to pick one.
    @ViewBuilder
    private var detailRoot: some View {
        if let id = navigator.selected, client.snapshot?.projects.contains(where: { $0.id == id }) == true {
            ProjectScreen(projectID: id, sessionID: navigator.selectedSession)
                .id(id)
        } else {
            EmptyStateScaffold(title: "Pick a project", message: "Choose a project to see what your agent is up to.") {
                ProjectsEmptyIllustration(appeared: $0)
            }
                .background(PhoneTheme.canvas)
        }
    }

    // MARK: The list

    private var projectList: some View {
        @Bindable var navigator = navigator
        // An old list's tabs are stale, so every project sorts into the
        // quiet sections.
        let saved = client.isShowingSaved
        let board = (heldSnapshot ?? client.snapshot).map {
            Board(snapshot: saved ? $0.withoutSessions : $0.placing(pendingPlacement), order: pendingOrder, query: query)
        }
        return List {
            if pairing.macs.count > 1 {
                MacChips(reachability: reachability)
                    .plainRow()
            }
            if saved, let savedAt = client.savedAt {
                OfflineNote(savedAt: savedAt)
                    .plainRow()
            } else if client.versionProblem != nil || (client.status != .connected && connectionBannerDue) {
                ConnectionBanner()
                    .plainRow()
            }
            if let board {
                if let usage = client.planUsage, query.isEmpty {
                    // Tap for each limit by name, its pace and when it resets.
                    Button { showsUsage = true } label: { PlanUsageStrip(usage: usage) }
                        .buttonStyle(.cardPress)
                        .accessibilityHint("Shows each limit and when it resets")
                        .plainRow()
                }
                if board.isEmpty {
                    if board.hasProjects {
                        ContentUnavailableView.search(text: query)
                            .plainRow()
                    } else {
                        ContentUnavailableView("No projects yet", systemImage: "folder",
                                               description: Text("Add a project in Workbench on your Mac and it shows up here."))
                            .padding(.top, 40)
                            .plainRow()
                    }
                }
                if !saved {
                    sessionSection("Needs you", color: PhoneTheme.waiting, rows: board.needsYou, tinted: true)
                    sessionSection("Working", color: PhoneTheme.palette.working, rows: board.working)
                    sessionSection("Done", color: PhoneTheme.palette.done, rows: board.done)
                }
                quietSection(board)
            } else if client.status == .connecting {
                LoadingState()
                    .frame(height: 160)
                    .plainRow()
            }
        }
        .listStyle(.insetGrouped)
        // Lets Recent and Inactive rows be shorter than the default 44.
        .environment(\.defaultMinListRowHeight, 34)
        .listSectionSpacing(14)
        .scrollContentBackground(.hidden)
        .background(PhoneTheme.canvas)
        .reorderContainer(for: CompanionProject.self) { difference in
            guard let snapshot = client.snapshot else { return }
            // Only pinned projects have an order to change.
            var ids = Board(snapshot: snapshot, order: pendingOrder, query: "").pinned.map(\.id)
            let moving = Set(difference.sources)
            let moved = ids.filter { moving.contains($0) }
            ids.removeAll { moving.contains($0) }
            switch difference.destination.position {
            case .before(let id): ids.insert(contentsOf: moved, at: ids.firstIndex(of: id) ?? ids.endIndex)
            case .end: ids.append(contentsOf: moved)
            }
            let rest = snapshot.topLevel.map(\.id).filter { !ids.contains($0) }
            pendingOrder = ids + rest
            client.reorderProjects(ids: ids)
        }
        // The Mac's answer to a drag is the next change in order.
        .onChange(of: client.snapshot?.topLevel.map(\.id)) { pendingOrder = nil }
        // And its answer to a pin or a move is the next change in placement.
        .onChange(of: client.snapshot?.topLevel.map(\.placement)) { pendingPlacement = [:] }
        // If the Mac never answers, the row goes back where it was.
        .task(id: pendingPlacement) {
            guard !pendingPlacement.isEmpty else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { pendingPlacement = [:] }
        }
        // While you're dragging the list it stays as it was. What changed
        // meanwhile lands when you let go.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting {
                if heldSnapshot == nil { heldSnapshot = client.snapshot }
            } else if heldSnapshot != nil {
                heldSnapshot = nil
            }
        }
        // The first list isn't animated in. The row animations below also
        // caught the list's own first layout, so it grew open from nothing,
        // and one taller than the screen came to rest scrolled, with the
        // top card under the title.
        .transaction { if !hasSettled { $0.animation = nil } }
        .task(id: board != nil) {
            guard board != nil, !hasSettled else { return }
            try? await Task.sleep(for: .milliseconds(700))
            hasSettled = true
        }
        .animation(.snappy(duration: 0.25), value: heldSnapshot == nil)
        .animation(.snappy(duration: 0.25), value: pendingPlacement)
        .sensoryFeedback(.impact(weight: .light), trigger: placementTaps)
        .animation(.snappy(duration: 0.25), value: client.snapshot?.projects.map { "\($0.id)\(String(describing: $0.placement))\($0.sessions.map { "\($0.id)\($0.activity)" })" })
        .animation(.snappy(duration: 0.25), value: inactiveCollapsed)
        .animation(.snappy(duration: 0.25), value: collapsedGroups)
        .animation(.snappy(duration: 0.25), value: connectionBannerDue)
        // Coming back to the app reconnects, usually in well under a
        // second. The banner waits that out, so the list doesn't jolt
        // down and back up every time you open the app.
        .task(id: client.status == .connected) {
            connectionBannerDue = false
            guard client.status != .connected else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { connectionBannerDue = true }
        }
        // A light tap when something new needs you while you're looking.
        // Counted from the Mac's live list, not the rows on screen, so
        // clearing a search or reconnecting doesn't set it off.
        .sensoryFeedback(.impact(weight: .light), trigger: needingYou) { old, new in
            guard let old, let new else { return false }
            return !new.isSubset(of: old)
        }
        // And a firmer one when a session finishes while you're looking.
        .sensoryFeedback(.success, trigger: finished) { old, new in
            guard let old, let new else { return false }
            return !new.isSubset(of: old)
        }
        .refreshable { client.retry(); checkOtherMacs() }
        .task(id: pairing.macs.map(\.host)) { checkOtherMacs() }
        // So the queued counts are current while the Mac is away.
        .task(id: client.isShowingSaved) { if client.isShowingSaved { await queue.refresh() } }
        .modifier(SearchWhenMany(query: $query, enabled: (client.snapshot?.projects.count ?? 0) > 8))
        // The title is the news: what needs you, in the largest type on
        // the screen. The Mac's name and the rest sit under it.
        .navigationTitle(headline.title)
        .navigationSubtitle(headline.detail)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // New work starts at your thumb, not in a corner of the toolbar.
            if client.canSendTasks, !saved {
                NewWorkBar { navigator.showsSendTasks = true }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .agentActionConfirmation($pendingAgentAction)
        .toolbar {
            if activities.isAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(activities.isShowing ? "Remove from Lock Screen" : "Show on Lock Screen", systemImage: "platter.filled.bottom.iphone") {
                        if activities.isShowing { activities.hideDashboard() } else { activities.showDashboard() }
                    }
                    .tint(activities.isShowing ? PhoneTheme.working : nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) {
            PhoneSettings()
        }
        .sheet(isPresented: $navigator.showsSendTasks) {
            SendTasksView()
        }
        .sheet(isPresented: $showsUsage) {
            if let usage = client.planUsage {
                PlanUsageSheet(usage: usage)
                    .presentationDetents([.medium, .large])
            }
        }
        #if DEBUG
        // For screenshots: BENCH_OPEN_SETTINGS=1 opens Settings,
        // BENCH_OPEN_SEND_TASKS=1 opens Send Tasks, and
        // BENCH_SHOW_DASHBOARD=1 starts the Lock Screen dashboard, and
        // BENCH_APP_ICON=<name> switches to that app icon.
        .task {
            let env = ProcessInfo.processInfo.environment
            if let icon = env["BENCH_APP_ICON"] {
                try? await Task.sleep(for: .seconds(1))
                do {
                    try await UIApplication.shared.setAlternateIconName(AppIconChoice(alternateIconName: icon).alternateIconName)
                } catch {
                    print("BENCH_APP_ICON failed: \(error)")
                }
            }
            if env["BENCH_SHOW_DASHBOARD"] != nil {
                try? await Task.sleep(for: .seconds(1.5))
                activities.showDashboard()
            }
            guard env["BENCH_OPEN_SETTINGS"] != nil || env["BENCH_OPEN_SEND_TASKS"] != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if env["BENCH_OPEN_SETTINGS"] != nil { showsSettings = true } else { navigator.showsSendTasks = true }
        }
        #endif
    }

    /// The tabs waiting on you right now, or nil while the list is an old
    /// one or hasn't arrived.
    private var needingYou: Set<UUID>? {
        guard !client.isShowingSaved, client.status == .connected, let snapshot = client.snapshot else { return nil }
        return Set(snapshot.projects.flatMap(\.sessions)
            .filter { $0.activity == .waiting || $0.activity == .attention }.map(\.id))
    }

    /// The tabs that have finished, or nil while the list is an old one
    /// or hasn't arrived.
    private var finished: Set<UUID>? {
        guard !client.isShowingSaved, client.status == .connected, let snapshot = client.snapshot else { return nil }
        return Set(snapshot.projects.flatMap(\.sessions).filter { $0.activity == .done }.map(\.id))
    }

    /// Pins or unpins, moving the row right away.
    private func pin(_ project: CompanionProject, _ pinned: Bool) {
        placementTaps += 1
        pendingPlacement[project.id] = pinned ? .pinned : (project.isActive == false ? .inactive : .active)
        client.pinProject(project.id, pinned: pinned)
    }

    /// Moves to Active or Inactive, moving the row right away.
    private func setActive(_ project: CompanionProject, _ active: Bool) {
        placementTaps += 1
        pendingPlacement[project.id] = active ? .active : .inactive
        client.setProjectActive(project.id, active: active)
    }

    /// Knocks on every Mac we're not connected to, for the dots in the chips.
    private func checkOtherMacs() {
        reachability.check(pairing.macs.filter { $0.host != pairing.info?.host })
    }

    // MARK: Sections

    @ViewBuilder
    private func sessionSection(_ title: String, color: Color, rows: [SessionItem], tinted: Bool = false) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { item in
                    sessionLink(item) {
                        SessionRowView(project: item.project, session: item.session,
                                       icon: client.icons[item.project.parentID ?? item.project.id],
                                       parentName: item.project.parentID.flatMap { id in client.snapshot?.projects.first { $0.id == id }?.name },
                                       selected: isSelected(item.project.id, session: item.session.id),
                                       answer: canAnswer(item.session) ? { client.answer(sessionID: item.session.id, allow: $0) } : nil,
                                       pick: canAnswer(item.session) ? { client.answerQuestions(sessionID: item.session.id, answers: [CompanionAnswer(selected: [$0])]) } : nil)
                    }
                    .listRowBackground(rowBackground(tint: tinted ? color : nil, selected: isSelected(item.project.id, session: item.session.id),
                                                     breathes: tinted, finishedAt: item.session.activity == .done ? item.session.stoppedAt : nil))
                    .swipeActions(edge: .leading) { placementButtons(item.project, leading: true) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { placementButtons(item.project, leading: false) }
                    .contextMenu { placementMenu(item.project, session: item.session) }
                }
            } header: {
                SectionHeader(title: title, color: color, count: rows.count)
            }
        }
    }

    /// Whether a row can answer for its session: the Mac is there to hear
    /// it. (`canReply` is about messages, and is off while a question is up.)
    private func canAnswer(_ session: CompanionSession) -> Bool {
        !client.isShowingSaved && client.status == .connected
    }

    /// Projects with nothing going on, in the Mac's sections: Pinned in
    /// your order, Active, Recent, and Inactive folded away. A Mac that
    /// doesn't sort projects gets one Projects section.
    @ViewBuilder
    private func quietSection(_ board: Board) -> some View {
        if let groups = board.groups {
            customGroups(groups, ungrouped: board.ungrouped)
        } else {
            activitySections(board)
        }
    }

    /// The Mac's own groups, each folding away on its own, then Ungrouped.
    @ViewBuilder
    private func customGroups(_ groups: [(group: CompanionGroup, projects: [CompanionProject])],
                              ungrouped: [CompanionProject]) -> some View {
        ForEach(groups, id: \.group.id) { entry in
            if !entry.projects.isEmpty {
                let key = entry.group.id.uuidString
                Section {
                    if !isFolded(key) {
                        ForEach(entry.projects) { project in projectRow(project, in: entry.projects) }
                    }
                } header: {
                    FoldingHeader(title: entry.group.name, count: entry.projects.count,
                                  collapsed: foldBinding(key))
                }
            }
        }
        if !ungrouped.isEmpty {
            Section {
                if !isFolded("ungrouped") {
                    ForEach(ungrouped) { project in projectRow(project, in: ungrouped, compact: true) }
                }
            } header: {
                FoldingHeader(title: "Ungrouped", count: ungrouped.count, collapsed: foldBinding("ungrouped"))
            }
        }
    }

    private func isFolded(_ key: String) -> Bool {
        collapsedGroups.split(separator: ",").contains { $0 == key }
    }

    private func foldBinding(_ key: String) -> Binding<Bool> {
        Binding {
            isFolded(key)
        } set: { folded in
            var keys = collapsedGroups.split(separator: ",").map(String.init).filter { $0 != key }
            if folded { keys.append(key) }
            collapsedGroups = keys.joined(separator: ",")
        }
    }

    /// Pinned in your order, Active, Recent, and Inactive folded away.
    @ViewBuilder
    private func activitySections(_ board: Board) -> some View {
        if !board.pinned.isEmpty {
            Section {
                ForEach(board.pinned) { project in projectRow(project, in: board.pinned) }
                    .reorderable()
                    // Reordering draws its own row background; put the card back.
                    .listRowBackground(PhoneTheme.surface)
            } header: {
                SectionHeader(title: CompanionSection.pinned.title, color: nil, count: nil, symbol: "pin.fill")
            }
        }
        // Recent gets compact rows on a lighter card, so its older work
        // reads as a step down from what you're working on.
        ForEach([(title: CompanionSection.active.title, projects: board.active, compact: false),
                 (title: CompanionSection.recent.title, projects: board.recent, compact: true),
                 (title: "Projects", projects: board.unsorted, compact: false)], id: \.title) { group in
            if !group.projects.isEmpty {
                Section {
                    ForEach(group.projects) { project in projectRow(project, in: group.projects, compact: group.compact) }
                } header: {
                    SectionHeader(title: group.title, color: nil, count: nil,
                                  hint: group.compact ? board.recentHint : nil)
                }
            }
        }
        if !board.inactive.isEmpty {
            Section {
                if !inactiveCollapsed {
                    ForEach(board.inactive) { project in projectRow(project, in: board.inactive, compact: true, dimmed: true) }
                }
            } header: {
                FoldingHeader(title: "Inactive", count: board.inactive.count, collapsed: $inactiveCollapsed)
            }
        }
    }

    /// While offline, a row says how many prompts wait for the Mac.
    /// `siblings` are the rows of its section: a worktree whose project is
    /// among them hangs off it.
    private func projectRow(_ project: CompanionProject, in siblings: [CompanionProject], compact: Bool = false, dimmed: Bool = false) -> some View {
        let selected = isSelected(project.id, session: nil)
        let nested = project.isWorktree && siblings.contains { $0.id == project.parentID }
        let queued = client.isShowingSaved ? queue.items(projectID: project.id).filter { $0.status != .expired }.count : 0
        return projectLink(project.id) {
            ProjectRowView(project: project, icon: client.icons[project.parentID ?? project.id],
                           selected: selected, compact: compact, nested: nested, queued: queued)
                .opacity(dimmed && !selected ? 0.6 : 1)
        }
        .listRowBackground(rowBackground(tint: nil, selected: selected, light: compact))
        .listRowInsets(compact ? EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 16) : nil)
        .swipeActions(edge: .leading) { placementButtons(project, leading: true) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { placementButtons(project, leading: false) }
        .contextMenu { placementMenu(project) }
    }

    /// Opens a session: pushed on a phone, shown in the iPad's detail area.
    @ViewBuilder
    private func sessionLink(_ item: SessionItem, @ViewBuilder row: () -> some View) -> some View {
        if isSplit {
            Button { navigator.open(projectID: item.project.id, sessionID: item.session.id) } label: { row() }
                .buttonStyle(.plain)
        } else {
            // No chevron: the card is the button, and the row keeps the width.
            NavigationLink(value: SessionRoute(projectID: item.project.id, sessionID: item.session.id)) { row() }
                .navigationLinkIndicatorVisibility(.hidden)
        }
    }

    /// Opens a project: pushed on a phone, picked in the iPad's sidebar.
    @ViewBuilder
    private func projectLink(_ id: UUID, @ViewBuilder row: () -> some View) -> some View {
        if isSplit {
            Button { navigator.select(id) } label: { row() }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: id) { row() }
                .navigationLinkIndicatorVisibility(.hidden)
        }
    }

    private func isSelected(_ id: UUID, session: UUID?) -> Bool {
        isSplit && navigator.selected == id && (session == nil || navigator.selectedSession == session)
    }

    /// `light` is for Recent and Inactive: a fainter card than the ones
    /// above it.
    /// A row waiting on you breathes, and one that just finished takes a
    /// sweep of light, as the Mac's rows do.
    private func rowBackground(tint: Color?, selected: Bool, light: Bool = false,
                               breathes: Bool = false, finishedAt: Date? = nil) -> some View {
        ZStack {
            PhoneTheme.surface.opacity(light ? 0.45 : 1)
            if let tint {
                if breathes { BreathingTint(color: tint) } else { tint.opacity(0.1) }
            }
            if let finishedAt { FinishSweep(finishedAt: finishedAt) }
            if selected { PhoneTheme.ink.opacity(0.08) }
        }
    }

    /// Pin and Inactive, for swiping a row. Only top-level projects have
    /// a place in the list to change. A swipe has room for a word, so
    /// each shows a short name and reads out the menu's full one.
    @ViewBuilder
    private func placementButtons(_ project: CompanionProject, leading: Bool) -> some View {
        if client.canPlaceProjects, !usesGroups, !project.isWorktree, let isActive = project.isActive {
            if leading {
                if project.isPinned == true {
                    Button("Unpin", systemImage: "pin.slash") { pin(project, false) }
                        .tint(PhoneTheme.remote)
                } else {
                    Button("Pin", systemImage: "pin") { pin(project, true) }
                        .tint(PhoneTheme.remote)
                        .accessibilityLabel("Pin to Top")
                }
            } else if isActive {
                Button("Inactive", systemImage: "moon") { setActive(project, false) }
                    .tint(.gray)
                    .accessibilityLabel("Move to Inactive")
            } else {
                Button("Active", systemImage: "sun.max") { setActive(project, true) }
                    .tint(PhoneTheme.accent)
                    .accessibilityLabel("Make Active")
            }
        }
    }

    /// A row's menu, with the Mac's names for things. A session's row can
    /// also close its tab.
    @ViewBuilder
    private func placementMenu(_ project: CompanionProject, session: CompanionSession? = nil) -> some View {
        if client.canPlaceProjects, !usesGroups, !project.isWorktree, let isActive = project.isActive {
            if project.isPinned == true {
                Button("Unpin", systemImage: "pin.slash") { pin(project, false) }
            } else {
                Button("Pin to Top", systemImage: "pin") { pin(project, true) }
            }
            if isActive {
                Button("Move to Inactive", systemImage: "moon") { setActive(project, false) }
            } else {
                Button("Make Active", systemImage: "sun.max") { setActive(project, true) }
            }
        }
        Divider()
        Button("New Agent Tab", systemImage: "plus.square") { client.newClaudeTab(projectID: project.id, prompt: nil) }
        Button("New Agent on a Branch…", systemImage: "arrow.triangle.branch") {
            navigator.push(NewAgentRoute(projectID: project.id))
        }
        if let session, client.canManageAgents {
            Divider()
            Button("Close Tab", systemImage: "xmark.square", role: .destructive) {
                pendingAgentAction = .closeSession(projectID: project.id, session: session)
            }
        }
        AgentRemovalButtons(project: project, pending: $pendingAgentAction)
    }

    /// Whether the Mac sorts projects into its own groups. Pinning and
    /// Inactive don't apply then.
    private var usesGroups: Bool { client.snapshot?.groups != nil }

    /// The screen's title and the line under it: "2 need you" over
    /// "Matt's MacBook Pro · 1 working, 1 done". The most pressing count
    /// leads, and the app's name stands in when there's nothing to count.
    private var headline: (title: String, detail: String) {
        func detail(_ words: String?) -> String { [client.macName, words].compactMap { $0 }.joined(separator: "  ·  ") }
        guard let snapshot = client.snapshot else { return ("Workbench", client.macName ?? "") }
        // What its tabs were doing is old news.
        if client.isShowingSaved { return ("Workbench", detail("Offline")) }
        let sessions = snapshot.projects.flatMap(\.sessions)
        let waiting = sessions.filter { $0.activity == .waiting || $0.activity == .attention }.count
        let working = sessions.filter { $0.activity == .working || $0.activity == .remoteWorking }.count
        let done = sessions.filter { $0.activity == .done }.count
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        if working > 0 { parts.append("\(working) working") }
        if done > 0 { parts.append("\(done) done") }
        guard let first = parts.first else { return ("All quiet", detail(nil)) }
        let rest = parts.dropFirst().joined(separator: ", ")
        return (first, detail(rest.isEmpty ? nil : rest))
    }
}

// MARK: - What goes where

private extension ProjectsSnapshot {
    /// The same list with these projects where you just put them.
    func placing(_ placements: [UUID: CompanionSection]) -> ProjectsSnapshot {
        guard !placements.isEmpty else { return self }
        var copy = self
        for index in copy.projects.indices {
            guard let section = placements[copy.projects[index].id] else { continue }
            copy.projects[index].section = section
            copy.projects[index].isPinned = section == .pinned
            if section != .pinned { copy.projects[index].isActive = section != .inactive }
        }
        return copy
    }
}

/// One Claude tab, with the project it's in.
private struct SessionItem: Identifiable {
    let project: CompanionProject
    let session: CompanionSession
    var id: String { "\(project.id)/\(session.id)" }
}

/// The snapshot sorted into the list's sections.
private struct Board {
    var needsYou: [SessionItem] = []
    var working: [SessionItem] = []
    var done: [SessionItem] = []
    /// Projects with nothing going on, by section, each project's
    /// worktrees after it.
    var pinned: [CompanionProject] = []
    var active: [CompanionProject] = []
    var recent: [CompanionProject] = []
    var inactive: [CompanionProject] = []
    /// From a Mac that doesn't sort projects into sections.
    var unsorted: [CompanionProject] = []
    /// With the Mac's custom groups: each group's projects, then the rest.
    /// Nil when the Mac sorts by activity.
    var groups: [(group: CompanionGroup, projects: [CompanionProject])]?
    var ungrouped: [CompanionProject] = []
    var hasProjects = false
    /// How far back Recent reaches on the Mac, like "Last day".
    var recentHint = SidebarTimes.standard.recentHint

    var hasActivity: Bool { !needsYou.isEmpty || !working.isEmpty || !done.isEmpty }
    var isEmpty: Bool {
        !hasActivity && pinned.isEmpty && active.isEmpty && recent.isEmpty && inactive.isEmpty && unsorted.isEmpty
            && ungrouped.isEmpty && (groups ?? []).allSatisfy(\.projects.isEmpty)
    }

    init(snapshot: ProjectsSnapshot, order: [UUID]?, query: String) {
        hasProjects = !snapshot.projects.isEmpty
        recentHint = snapshot.recentHint
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ project: CompanionProject, _ session: CompanionSession?) -> Bool {
            guard !words.isEmpty else { return true }
            var haystack = [project.name, project.repoName, project.branch ?? "", project.pullRequest?.title ?? ""]
            if let session { haystack += [session.title, session.action ?? "", session.question ?? ""] }
            return haystack.contains { $0.lowercased().contains(words) }
        }
        var top = snapshot.topLevel
        var groupOf: [UUID: Int]?
        if let macGroups = snapshot.groups {
            groups = macGroups.map { (group: $0, projects: []) }
            var index: [UUID: Int] = [:]
            var position: [UUID: Int] = [:]
            for (i, group) in macGroups.enumerated() {
                for (j, id) in group.projectIDs.enumerated() where index[id] == nil {
                    index[id] = i
                    position[id] = j
                }
            }
            groupOf = index
            // In each group's order; the rest (Ungrouped) by name.
            top.sort { a, b in
                switch (position[a.id], position[b.id]) {
                case let (x?, y?): x < y
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
        }
        if let order, groupOf == nil {
            top.sort { a, b in (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max) }
        }
        // Each section keeps the Mac's order, except Inactive, by name.
        let inactiveTop = top.filter { $0.placement == .inactive }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ordered = groupOf == nil ? top.filter { $0.placement != .inactive } + inactiveTop : top
        for project in ordered {
            for each in [project] + snapshot.worktrees(of: project.id) {
                var busy = false
                for session in each.sessions where matches(each, session) {
                    let item = SessionItem(project: each, session: session)
                    switch session.activity {
                    case .waiting, .attention: needsYou.append(item); busy = true
                    case .working, .remoteWorking: working.append(item); busy = true
                    case .done: done.append(item); busy = true
                    case .idle: break
                    }
                }
                guard !busy, matches(each, nil) else { continue }
                if let groupOf {
                    if let index = groupOf[project.id] { groups?[index].projects.append(each) } else { ungrouped.append(each) }
                    continue
                }
                switch project.placement {
                case .pinned: pinned.append(each)
                case .active: active.append(each)
                case .recent: recent.append(each)
                case .inactive: inactive.append(each)
                case nil: unsorted.append(each)
                }
            }
        }
        needsYou.sort { ($0.session.since ?? .distantPast) < ($1.session.since ?? .distantPast) }
        working.sort { ($0.session.since ?? .distantFuture) < ($1.session.since ?? .distantFuture) }
        done.sort { ($0.session.stoppedAt ?? .distantPast) > ($1.session.stoppedAt ?? .distantPast) }
    }
}

// MARK: - Rows

/// "Needs you", with its color and how many.
private struct SectionHeader: View {
    let title: String
    let color: Color?
    let count: Int?
    var symbol: String?
    /// Quiet words on the right, like "Last day".
    var hint: String?

    var body: some View {
        HStack(spacing: 7) {
            if let color {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(PhoneTheme.inkMuted)
            }
            Text(title).sectionEyebrow()
            SectionHairline()
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PhoneTheme.inkMuted)
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(PhoneTheme.inkMuted)
            }
        }
        .textCase(nil)
        .padding(.leading, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The line a section's name runs into, out to its count.
private struct SectionHairline: View {
    var body: some View {
        Rectangle()
            .fill(PhoneTheme.hairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

private extension Text {
    /// A section's name: small, spaced capitals.
    func sectionEyebrow() -> some View {
        font(.caption2.weight(.semibold))
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(PhoneTheme.ink.opacity(0.75))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A session that's working, waiting on you, or done: the project, which
/// tab if the project has several, and what's going on in one line.
private struct SessionRowView: View {
    let project: CompanionProject
    let session: CompanionSession
    let icon: Data?
    /// The project a worktree belongs to, by name.
    var parentName: String?
    var selected = false
    /// Answers an allow or deny from the row. Nil when it can't be sent
    /// from here (the Mac is out of reach, or the session can't take it).
    var answer: ((Bool) -> Void)?
    /// Answers a question by the number of the option picked.
    var pick: ((Int) -> Void)?

    private var tint: Color? { PhoneTheme.color(for: session.activity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? .isSelected : [])
            // Answer from here, as on the Mac's sidebar: an allow or deny
            // with its command, or a question with a few plain options.
            if session.isAllowOrDeny, let answer {
                if let command = session.command, !command.isEmpty {
                    CommandBlock(command: command, lineLimit: 2)
                }
                PermissionButtons(session: session, compact: true, answer: answer)
            } else if let question = session.quickQuestion, let pick {
                QuickAnswers(session: session, question: question, pick: pick)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            ZStack {
                if let tint {
                    RoundedRectangle(cornerRadius: PhoneTheme.Radius.control, style: .continuous)
                        .strokeBorder(tint, lineWidth: 2)
                        .frame(width: 40, height: 40)
                }
                CompanionProjectIcon(project: project, icon: icon, size: 32)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                // The name, what tells this session from its neighbors, then
                // the clock and the mark at the end, where digits line up
                // down the list.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if project.isWorktree {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PhoneTheme.inkMuted)
                    }
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(PhoneTheme.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let detail {
                        Text(detail.text)
                            .font(detail.isBranch ? .caption.monospaced() : .subheadline)
                            .foregroundStyle(PhoneTheme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let since = session.since, [.working, .remoteWorking, .waiting].contains(session.activity) {
                        ActiveTimer(since: since, activity: session.activity)
                            .font(.footnote)
                    } else if session.activity == .done, let stopped = session.stoppedAt {
                        Age(date: stopped)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(PhoneTheme.inkMuted)
                    }
                    ActivityMark(activity: session.activity, size: 13)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
                // What Claude is doing changes by the second, so one
                // line; a question or a summary is worth two.
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(session.activity == .done ? PhoneTheme.inkMuted : PhoneTheme.ink.opacity(0.8))
                    .lineLimit([.working, .remoteWorking].contains(session.activity) ? 1 : 2)
                // The Mac's step bar: a segment per step, the current one glowing.
                if let items = session.checklist, !items.isEmpty,
                   [.working, .remoteWorking, .waiting].contains(session.activity) {
                    ChecklistStepsBar(items: items, activity: session.activity)
                        .padding(.top, 4)
                }
                if let pr = project.pullRequest {
                    PullRequestChip(pr: pr)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var title: String {
        project.isWorktree ? (project.branch ?? project.name) : project.name
    }

    /// Which tab, when the project has more than one and the tab has a
    /// name of its own.
    private var tabLabel: String? {
        guard project.sessions.count > 1, session.title != "Claude", !session.title.isEmpty else { return nil }
        return session.title
    }

    /// Beside the name: the tab when the project has several, else the
    /// branch (a worktree's name is its branch already, so it gets the
    /// project it belongs to).
    private var detail: (text: String, isBranch: Bool)? {
        if let tab = tabLabel { return (tab, false) }
        if project.isWorktree { return parentName.map { ($0, false) } }
        return project.branch.map { ($0, true) }
    }

    private var line: String {
        switch session.activity {
        case .working, .remoteWorking:
            var text = session.checklist?.current?.label ?? session.actionText ?? "Working"
            if let host = session.remoteHost { text += " on \(host)" }
            return text
        case .waiting:
            // The command has a block of its own under the row.
            if session.isAllowOrDeny, answer != nil { return session.permissionTitle }
            return session.question ?? "Waiting for you"
        case .done:
            return session.summary?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Finished"
        case .attention:
            return "Needs attention"
        case .idle:
            return ""
        }
    }
}

/// A project with nothing going on: its name and the most useful thing
/// about it, the branch or pull request.
private struct ProjectRowView: View {
    let project: CompanionProject
    let icon: Data?
    var selected = false
    /// Recent and Inactive: a smaller icon and name, no status line.
    var compact = false
    /// A worktree shown right under its project, tied to it by an elbow.
    var nested = false
    /// Prompts waiting for the Mac, shown while it's offline.
    var queued = 0

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            if nested {
                // An agent's row hangs off the project above it.
                WorktreeConnector()
                    .frame(width: compact ? 14 : 20, height: compact ? 28 : 40)
            }
            CompanionProjectIcon(project: project, icon: icon, size: compact ? 22 : 32)
                .frame(width: compact ? 28 : 40, height: compact ? 28 : 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if project.isWorktree, !nested {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PhoneTheme.inkMuted)
                    }
                    Text(project.isWorktree ? (project.branch ?? project.name) : project.name)
                        .font(compact ? .system(.subheadline, design: .rounded, weight: .medium)
                                      : .system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(compact ? PhoneTheme.ink.opacity(0.85) : PhoneTheme.ink)
                        .lineLimit(1)
                }
                if !compact, let status = project.status, !(project.isWorktree && isJustBranch(status)) {
                    ProjectStatusLine(status: status, isWorktree: project.isWorktree)
                }
            }
            Spacer(minLength: 8)
            if queued > 0 {
                Text("\(queued) queued")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PhoneTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(PhoneTheme.accent.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, compact ? 0 : 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A worktree's title is its branch already.
    private func isJustBranch(_ status: CompanionProjectStatus) -> Bool {
        if case .branch = status { true } else { false }
    }
}

/// The elbow that ties a worktree's row to its project: down from the row
/// above, then across to the icon.
private struct WorktreeConnector: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let x = proxy.size.width * 0.3, mid = proxy.size.height / 2, radius: CGFloat = 5
                path.move(to: CGPoint(x: x, y: -10))
                path.addLine(to: CGPoint(x: x, y: mid - radius))
                path.addQuadCurve(to: CGPoint(x: x + radius, y: mid), control: CGPoint(x: x, y: mid))
                path.addLine(to: CGPoint(x: proxy.size.width + 4, y: mid))
            }
            .stroke(PhoneTheme.inkMuted.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

/// "Inactive" with a count, folding the projects under it away. A dot
/// shows when one of them needs you, so folding hides nothing urgent.
/// A section's name and count, folding its rows away when tapped:
/// Inactive, or one of the Mac's custom groups.
private struct FoldingHeader: View {
    let title: String
    let count: Int
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            collapsed.toggle()
        } label: {
            HStack(spacing: 7) {
                Text(title).sectionEyebrow()
                SectionHairline()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PhoneTheme.inkMuted)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(PhoneTheme.inkMuted)
            }
            .foregroundStyle(PhoneTheme.ink)
            .textCase(nil)
            .padding(.leading, 2)
            .touchArea(vertical: 13)
        }
        .buttonStyle(.plain)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }
}

private struct ConnectionBanner: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        HStack(spacing: 12) {
            if client.status == .connecting {
                ProgressView().controlSize(.small)
            } else if client.status == .connected {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(PhoneTheme.waiting)
            } else {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(PhoneTheme.inkMuted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PhoneTheme.ink)
                if client.status == .connected, let version = client.versionProblem {
                    Text(version).font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                // Kept while it tries again, so the reason doesn't vanish
                // behind "Connecting".
                } else if let problem = client.problem {
                    Text(problem).font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                } else if let last = client.lastUpdate {
                    Text("Showing what Workbench reported \(last, format: .relative(presentation: .named)).")
                        .font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
    }

    private var title: String {
        switch client.status {
        case .connecting: client.problem == nil ? "Connecting to your Mac…" : "Trying again…"
        case .connected: "Update needed"
        case .disconnected: "Not connected"
        }
    }
}

/// Takes the banner's place while the list showing is the one the Mac
/// sent last, and heads a project opened then. Says "connecting" until a
/// try has failed, so an awake Mac isn't called asleep, and keeps the
/// reason a try failed.
struct OfflineNote: View {
    @Environment(CompanionClient.self) private var client
    /// When the list showing was saved. Nil inside a project, where the
    /// note says what queuing does instead of how old the list is.
    var savedAt: Date?

    var body: some View {
        HStack(spacing: 12) {
            if client.needsRepair {
                Image(systemName: "key").foregroundStyle(PhoneTheme.inkMuted)
            } else if client.status == .connecting && !client.hasFailedToReach {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "moon.zzz").foregroundStyle(PhoneTheme.inkMuted)
            }
            VStack(alignment: .leading, spacing: 2) {
                if client.needsRepair {
                    Text("Your Mac has a new pairing code. Pair again to queue prompts.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneTheme.ink)
                    if let savedAt {
                        Text("These are your projects from \(savedAt, format: .relative(presentation: .named)).")
                            .font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                    }
                } else if client.hasFailedToReach {
                    Text("Your Mac is asleep or offline.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneTheme.ink)
                    if let savedAt {
                        Text("These are your projects from \(savedAt, format: .relative(presentation: .named)). You can queue prompts for when it wakes.")
                            .font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                        if let problem = client.problem {
                            Text(problem).font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                        }
                    } else {
                        Text("Prompts you queue start as new agents when it's back online.")
                            .font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                    }
                } else {
                    Text("Connecting to your Mac…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneTheme.ink)
                    if let savedAt {
                        Text("Showing your projects from \(savedAt, format: .relative(presentation: .named)).")
                            .font(.caption).foregroundStyle(PhoneTheme.inkMuted)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
    }
}

/// A quiet row's line under its name: an icon and a few words, red when
/// something broke.
private struct ProjectStatusLine: View {
    let status: CompanionProjectStatus
    let isWorktree: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(symbol.color)
            Text(text)
                .lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(isTrouble ? PhoneTheme.error : PhoneTheme.inkMuted)
    }

    private var isTrouble: Bool {
        switch status {
        case .checksFailing, .deployFailed: true
        default: false
        }
    }

    private var text: String {
        switch status {
        case .checksFailing(let pr): "Checks failing on #\(pr.number)"
        case .deployFailed(let deploy): "Deploy of #\(deploy.prNumber) failed"
        case .deploying(let deploy): deploy.place.map { "Deploying to \($0)" } ?? "Deploying #\(deploy.prNumber)"
        case .pullRequest(let pr):
            switch pr.state {
            case .merged: "Merged #\(pr.number) \(pr.title)"
            case .closed: "Closed #\(pr.number) \(pr.title)"
            default: "#\(pr.number) \(pr.title)"
            }
        case .branch(let name): name
        }
    }

    private var symbol: (name: String, color: Color) {
        switch status {
        case .checksFailing, .deployFailed: ("xmark.circle.fill", PhoneTheme.error)
        case .deploying: ("arrow.up.circle.fill", PhoneTheme.waiting)
        case .pullRequest(let pr):
            switch pr.state {
            case .merged: ("checkmark.circle.fill", PhoneTheme.merged)
            case .closed: ("xmark.circle", PhoneTheme.inkMuted)
            case .draft: ("pencil.circle", PhoneTheme.inkMuted)
            case .open:
                switch pr.checks {
                case .passing: ("checkmark.circle.fill", PhoneTheme.done)
                case .pending: ("clock.fill", PhoneTheme.waiting)
                case .failing: ("xmark.circle.fill", PhoneTheme.error)
                case .none: ("arrow.triangle.pull", PhoneTheme.done)
                }
            }
        case .branch: ("arrow.triangle.branch", PhoneTheme.inkMuted)
        }
    }
}

/// A session's pull request in a small capsule: its number and how its
/// checks stand, like "#42 · 7/7 checks".
private struct PullRequestChip: View {
    let pr: CompanionPullRequest

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            // The state colors are too light to read as small text on a
            // light card, so the words stay in ink and the tint says it.
            Text(text)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(PhoneTheme.ink.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var text: String {
        switch pr.state {
        case .merged: return "#\(pr.number) merged"
        case .closed: return "#\(pr.number) closed"
        case .draft: return "#\(pr.number) draft"
        case .open:
            switch pr.checks {
            case .failing:
                let failing = pr.failingNames.count
                return failing > 0 ? "#\(pr.number) · \(failing) failing" : "#\(pr.number) · checks failing"
            case .passing, .pending:
                return pr.totalCount > 0 ? "#\(pr.number) · \(pr.passedCount)/\(pr.totalCount) checks" : "#\(pr.number)"
            case .none:
                return "#\(pr.number)"
            }
        }
    }

    private var spoken: String {
        switch pr.state {
        case .merged: return "Pull request \(pr.number), merged"
        case .closed: return "Pull request \(pr.number), closed"
        case .draft: return "Pull request \(pr.number), draft"
        case .open:
            switch pr.checks {
            case .failing: return "Pull request \(pr.number), checks failing"
            case .passing, .pending:
                return pr.totalCount > 0 ? "Pull request \(pr.number), \(pr.passedCount) of \(pr.totalCount) checks passed" : "Pull request \(pr.number)"
            case .none: return "Pull request \(pr.number)"
            }
        }
    }

    private var symbol: String {
        switch pr.state {
        case .merged: "checkmark.circle.fill"
        case .closed: "xmark.circle"
        case .draft: "pencil.circle"
        case .open:
            switch pr.checks {
            case .passing: "checkmark.circle.fill"
            case .pending: "clock.fill"
            case .failing: "xmark.circle.fill"
            case .none: "arrow.triangle.pull"
            }
        }
    }

    private var color: Color {
        switch pr.state {
        case .merged: PhoneTheme.merged
        case .closed, .draft: PhoneTheme.inkMuted
        case .open:
            switch pr.checks {
            case .passing, .none: PhoneTheme.palette.done
            case .pending: PhoneTheme.waiting
            case .failing: PhoneTheme.error
            }
        }
    }
}

/// The wash behind a row that's waiting on you, slowly rising and falling
/// so it reads as asking. Still with Reduce Motion on.
private struct BreathingTint: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            color.opacity(0.1)
        } else {
            // Drawn from the clock, like ActivityMark, so no animation that
            // never ends sits inside a list row.
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.6) / 3.6
                color.opacity(0.07 + 0.08 * (0.5 - 0.5 * cos(phase * 2 * .pi)))
            }
        }
    }
}

/// One band of light across a row whose session just finished. Rows that
/// finished a while ago, and Reduce Motion, get nothing.
private struct FinishSweep: View {
    let finishedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGFloat = -1
    @State private var isSweeping = false

    var body: some View {
        GeometryReader { proxy in
            if isSweeping {
                LinearGradient(colors: [.clear, PhoneTheme.palette.done.opacity(0.28), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: position * proxy.size.width)
                    .animation(.easeOut(duration: 1.1), value: position)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: finishedAt) {
            guard !reduceMotion, Date.now.timeIntervalSince(finishedAt) < 6 else { return }
            position = -0.6
            isSweeping = true
            // A beat, so the band is drawn at the start before it moves.
            try? await Task.sleep(for: .milliseconds(50))
            position = 1
            try? await Task.sleep(for: .seconds(1.2))
            isSweeping = false
        }
    }
}

/// A card that presses in slightly, instead of the plain highlight.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CardPressStyle {
    static var cardPress: CardPressStyle { CardPressStyle() }
}

// MARK: - Above the rows

/// The Claude plan's limits as one slim line: a small ring for each, the
/// fullest one's time to reset.
private struct PlanUsageStrip: View {
    let usage: PlanUsage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let soonest = usage.limits.compactMap { $0.timeLeft(at: context.date) }.first
            HStack(spacing: 8) {
                if usage.limits.contains(where: \.isSpend) {
                    // Money reads as a sentence ("$142 of $500"), and
                    // there's one of it, so it keeps the room.
                    Text("Spent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PhoneTheme.ink)
                    ForEach(usage.limits) { limit in
                        HStack(spacing: 5) {
                            UsageRing(limit: limit, now: context.date, size: 18, lineWidth: 3, showsPercent: false, showsPace: false)
                            Text(limit.summary(at: context.date))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(PhoneTheme.inkMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let soonest {
                        Text(soonest)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PhoneTheme.inkMuted)
                    }
                } else {
                    // The number first, its name under it: side by side,
                    // three of them were cut off before the number.
                    ForEach(usage.limits) { limit in
                        HStack(spacing: 6) {
                            UsageRing(limit: limit, now: context.date, size: 18, lineWidth: 3, showsPercent: false, showsPace: false)
                            stacked("\(Int(limit.percent(at: context.date).rounded()))%", limit.shortName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let soonest {
                        stacked(soonest, "to reset", alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel { values in
            Text("Plan usage")
            values
        }
    }

    private func stacked(_ value: String, _ name: String, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(value)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(PhoneTheme.ink)
            Text(name)
                .font(.caption2)
                .foregroundStyle(PhoneTheme.inkMuted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Where new work starts: a glass bar at the foot of the list that opens
/// Brain Dump, with the question it will ask as its placeholder.
private struct NewWorkBar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "brain")
                    .font(.body.weight(.medium))
                    .foregroundStyle(PhoneTheme.inkMuted)
                Text("Tell your agents what to do")
                    .font(.body)
                    .foregroundStyle(PhoneTheme.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(PhoneTheme.onAccent)
                    .frame(width: 30, height: 30)
                    .background(PhoneTheme.accent, in: Circle())
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 48)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Brain Dump")
        .accessibilityHint("Say what you want done across your projects")
    }
}

/// Every plan limit by name: how much is used, how that compares with
/// the time gone (the tick on the ring), and when it resets.
private struct PlanUsageSheet: View {
    let usage: PlanUsage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(usage.limits) { limit in
                            HStack(spacing: 14) {
                                UsageRing(limit: limit, now: context.date, size: 46, lineWidth: 5, showsPercent: true, showsPace: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(limit.name)
                                        .font(.system(.body, design: .rounded, weight: .semibold))
                                        .foregroundStyle(PhoneTheme.ink)
                                    Text(limit.isSpend ? limit.summary(at: context.date) : "\(Int(limit.percent(at: context.date).rounded()))% used")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(PhoneTheme.inkMuted)
                                }
                                Spacer(minLength: 8)
                                if let left = limit.timeLeft(at: context.date) {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(left)
                                            .font(.subheadline.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(PhoneTheme.ink)
                                        Text("to reset")
                                            .font(.caption)
                                            .foregroundStyle(PhoneTheme.inkMuted)
                                    }
                                }
                            }
                            .padding(14)
                            .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
                            .accessibilityElement(children: .combine)
                        }
                        Text("The tick on each ring is how far through its window you are. Ahead of the tick, you're using it faster than it refills.")
                            .font(.footnote)
                            .foregroundStyle(PhoneTheme.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                    }
                    .padding(16)
                }
            }
            .background(PhoneTheme.canvas)
            .navigationTitle("Plan Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// "now", "4m", "2h", "3d": how long ago, in the least room.
private struct Age: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.text(context.date.timeIntervalSince(date)))
        }
    }

    static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}

/// Search, once there are enough projects to lose one.
private struct SearchWhenMany: ViewModifier {
    @Binding var query: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, prompt: "Projects, branches, sessions")
        } else {
            content
        }
    }
}

private extension View {
    /// A card or banner in the list, drawn by itself rather than as a row.
    func plainRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
    }
}

extension View {
    /// The screens a project leads to, for whichever stack shows them.
    func projectRoutes() -> some View {
        navigationDestination(for: UUID.self) { ProjectScreen(projectID: $0) }
            .navigationDestination(for: SessionRoute.self) { SessionView(projectID: $0.projectID, sessionID: $0.sessionID) }
            .navigationDestination(for: ChangesRoute.self) { ChangesView(projectID: $0.projectID) }
            .navigationDestination(for: DiffRoute.self) { DiffScreen(projectID: $0.projectID, change: $0.change) }
            .navigationDestination(for: CommitRoute.self) { CommitScreen(route: $0) }
            .navigationDestination(for: FilesRoute.self) { FilesView(projectID: $0.projectID, folder: $0.folder) }
            .navigationDestination(for: FileRoute.self) { FileScreen(projectID: $0.projectID, path: $0.path) }
            .navigationDestination(for: PastSessionsRoute.self) { PastSessionsView(projectID: $0.projectID) }
            .navigationDestination(for: NewAgentRoute.self) { NewAgentView(projectID: $0.projectID) }
    }
}
