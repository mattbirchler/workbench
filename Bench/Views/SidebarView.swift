import BenchKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Environment(RemoteMacs.self) private var macs
    @Environment(TerminalManager.self) private var terminals
    @State private var dragging: String?
    /// Ties a project's row in one section to its row in another, so a
    /// project that changes section travels there instead of fading out
    /// in one place and in at the other.
    @Namespace private var rowSpace
    @AppStorage("inactiveCollapsed") private var inactiveCollapsed = false
    @State private var showsShortcuts = false
    @State private var keyMonitor: Any?
    /// Waits out a short hold before the ⌘ hints show.
    @State private var pendingShortcuts: Task<Void, Never>?

    var body: some View {
        // The projects stay in place under Settings rather than being
        // rebuilt when you come back, so the list is where you left it.
        ZStack {
            let inSettings = store.settingsSection != nil
            projectsSidebar
                .opacity(inSettings ? 0 : 1)
                .allowsHitTesting(!inSettings)
                .accessibilityHidden(inSettings)
            if inSettings {
                SettingsSidebar()
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.addProjects(urls, source: .drop)
            return true
        }
        .animation(.easeOut(duration: 0.12), value: showsShortcuts)
        .animation(.easeOut(duration: 0.15), value: store.settingsSection == nil)
        .onAppear(perform: watchCommandKey)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            hideShortcuts()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hideShortcuts()
        }
    }

    /// The Macs, the Overview, and the projects.
    @ViewBuilder private var projectsSidebar: some View {
        VStack(spacing: 0) {
            DevicePills()
                .padding(.bottom, 10)
            // This Mac's list stays in place under another Mac's, so it
            // keeps its scroll position when you come back to it.
            ZStack {
                let host = store.sidebarHost
                localList
                    .opacity(host == nil ? 1 : 0)
                    .allowsHitTesting(host == nil)
                    .accessibilityHidden(host != nil)
                if let host {
                    RemoteProjectList(host: host, shortcuts: shortcuts)
                        .id(host)
                }
            }
            .frame(maxHeight: .infinity)
            // Rows fade as they slide under the meters.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            // The list runs on under the cards and meters at the bottom,
            // which float on it as glass.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    #if DEBUG
                    RemoteScreenshotHooks()
                    #endif
                    UpdatedCard()
                    IPhoneAppCard()
                    UpdateReadyButton()
                    SidebarMeters()
                    VersionFooter()
                }
            }
        }
    }

    /// This Mac's Overview, then three levels that each look quieter than
    /// the one above: Pinned and Active together on a raised tray (what
    /// you're working on), Recent in compact rows (the last day), and
    /// everything else, dimmed, under Inactive, which folds away.
    private var localList: some View {
        let groups = listedGroups
        let shortcuts = shortcuts
        let current = groups.filter { $0.title != "Recent" }
        let recent = groups.first { $0.title == "Recent" }
        return VStack(spacing: 0) {
            OverviewRow()
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            // Plain stacks, not lazy ones: a lazy stack works out which rows
            // are on screen at every step of a scroll, and that lays out the
            // whole window again, so scrolling dropped to about 30 fps. A
            // sidebar's worth of rows is cheap to build once.
            ScrollView {
                VStack(spacing: 0) {
                    if store.grouping == .custom {
                        customGroups(shortcuts: shortcuts)
                    } else {
                        currentTray(current, shortcuts: shortcuts)
                        recentSection(recent, isFirst: current.isEmpty, shortcuts: shortcuts)
                        if groups.isEmpty { emptyListed }
                        inactiveSection
                    }
                    if store.projects.isEmpty {
                        Text("Drop a project folder here")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 24)
                    }
                }
            }
            // A row growing or shrinking as its agent starts, asks or
            // finishes takes the rows under it along, on the same clock as
            // its tint (ActivityBackground). Without this the row's
            // contents and its neighbours jumped while the tint eased.
            .animation(SidebarMotion.rowChange, value: store.projects.map { terminals.activity(for: $0) })
            .animation(.snappy(duration: 0.2), value: inactiveCollapsed)
            .animation(.snappy(duration: 0.2), value: store.inactiveProjects.map(\.id))
            .animation(.snappy(duration: 0.2), value: store.listedEntries.map(\.id))
            // Also when the only change is which section a project is in.
            .animation(.snappy(duration: 0.2), value: store.activeProjects.map(\.id))
            .animation(.snappy(duration: 0.2), value: store.groups)
            .animation(.snappy(duration: 0.2), value: store.ungroupedCollapsed)
            .animation(.easeOut(duration: 0.15), value: store.selectedProjectID)
        }
    }

    /// Pinned and Active together on a raised tray: what you're working on.
    @ViewBuilder
    private func currentTray(_ current: [(title: String, entries: [ActiveEntry])],
                             shortcuts: [SidebarShortcuts.Target: Int]) -> some View {
        if !current.isEmpty {
            VStack(spacing: 2) {
                ForEach(Array(current.enumerated()), id: \.element.title) { index, group in
                    SectionTitle(title: group.title, symbol: group.title == "Pinned" ? "pin.fill" : nil,
                                 addsProject: index == 0)
                    rows(group.entries, compact: false, shortcuts: shortcuts)
                }
            }
            .sidebarTray()
        }
    }

    /// With custom groups: your groups on the raised tray, each folding
    /// away, then everything else in compact rows under Ungrouped.
    @ViewBuilder
    private func customGroups(shortcuts: [SidebarShortcuts.Target: Int]) -> some View {
        let groups = store.groups
        if groups.isEmpty {
            SectionTitle(title: "Groups", addsProject: true)
                .padding(.horizontal, 6)
            if !store.projects.isEmpty {
                Text("Make a group, then right-click a project and choose Move to Group, or drag it in.")
                    .font(.ui(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            NewGroupButton()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    GroupHeader(title: group.name, entries: group.entries, collapsed: group.isCollapsed,
                                groupID: group.id, addsProject: index == 0, dragging: $dragging) {
                        store.setGroupCollapsed(group.id, !group.isCollapsed)
                    }
                    Fold(isOpen: !group.isCollapsed) {
                        VStack(spacing: 2) {
                            if group.entries.isEmpty {
                                Text("Drag projects here")
                                    .font(.ui(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .onDrop(of: [.text], delegate: GroupDropDelegate(groupID: group.id, dragging: $dragging,
                                                                                     store: store))
                            }
                            rows(group.entries, compact: false, shortcuts: shortcuts)
                        }
                    }
                }
                NewGroupButton()
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
            }
            .sidebarTray()
        }
        let ungrouped = store.ungroupedEntries
        if !ungrouped.isEmpty {
            GroupHeader(title: "Ungrouped", entries: ungrouped, collapsed: store.ungroupedCollapsed,
                        groupID: nil, addsProject: false, dragging: $dragging) {
                store.ungroupedCollapsed.toggle()
            }
            // With the header's own 6pt, 16pt in all: the left edge of the
            // group headers on the tray above and of Inactive.
            .padding(.horizontal, 10)
            Fold(isOpen: !store.ungroupedCollapsed) {
                VStack(spacing: 1) {
                    rows(ungrouped, compact: true, shortcuts: shortcuts)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }

    /// Recent's projects (the last day, unless changed in Settings) in
    /// compact rows.
    @ViewBuilder
    private func recentSection(_ recent: (title: String, entries: [ActiveEntry])?, isFirst: Bool,
                               shortcuts: [SidebarShortcuts.Target: Int]) -> some View {
        if let recent {
            // Inset to line up with the tray's titles and icons above.
            SectionTitle(title: "Recent", hint: store.sidebarTimes.recentHint, addsProject: isFirst)
                .padding(.horizontal, 10)
            VStack(spacing: 1) {
                rows(recent.entries, compact: true, shortcuts: shortcuts)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    /// Before anything's been used in the last day.
    @ViewBuilder
    private var emptyListed: some View {
        SectionTitle(title: "Projects", addsProject: true)
            .padding(.horizontal, 6)
        if !store.projects.isEmpty {
            Text("Projects you've used in the last day show up here. Right-click one and choose Pin to Top to keep it here.")
                .font(.ui(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    /// Everything else, dimmed and folded away.
    @ViewBuilder
    private var inactiveSection: some View {
        let inactive = store.inactiveProjects
        if !inactive.isEmpty {
            InactiveHeader(count: inactive.count, busiest: busiestActivity(of: inactive), collapsed: $inactiveCollapsed)
            Fold(isOpen: !inactiveCollapsed) {
                VStack(spacing: 1) {
                    ForEach(inactive) { project in
                        projectBlock(project, shortcuts: [:], dragID: nil, compact: true)
                            // The back catalog: quieter until you pick one.
                            .opacity(store.selectedProjectID.map { store.rootID(of: $0) } == project.id ? 1 : 0.6)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }

    /// Waiting first, then working, among the folded projects and their worktrees.
    private func busiestActivity(of projects: [Project]) -> TabActivity? {
        TabActivity.busiest(projects.flatMap { [$0] + store.worktrees(of: $0.id) }.map { terminals.activity(for: $0) })
    }

    /// One section's rows, with their ⌘1 to ⌘9 hints while Command is held.
    @ViewBuilder
    private func rows(_ entries: [ActiveEntry], compact: Bool, shortcuts: [SidebarShortcuts.Target: Int]) -> some View {
        ForEach(entries) { entry in
            if let host = entry.host {
                PinnedRemoteRows(entry: entry, host: host, shortcuts: shortcuts, compact: compact)
                    .modifier(ActiveDrag(entryID: entry.id, dragging: $dragging, store: store))
            } else if let project = store.project(entry.projectID) {
                projectBlock(project, shortcuts: shortcuts,
                             dragID: store.grouping == .custom || store.isPinned(entryID: entry.id) ? entry.id : nil,
                             compact: compact)
            }
        }
    }

    /// The number each row's ⌘ hint shows, while Command is held.
    private var shortcuts: [SidebarShortcuts.Target: Int] {
        showsShortcuts ? SidebarShortcuts.numbers(store: store, macs: macs) : [:]
    }

    /// A project and its agents' worktrees indented under it. The one
    /// you're in gets a New Agent button in its row. Only pinned rows drag.
    /// Compact rows are smaller and leave out the status line.
    @ViewBuilder
    private func projectBlock(_ project: Project, shortcuts: [SidebarShortcuts.Target: Int], dragID: String?,
                              compact: Bool = false) -> some View {
        let shortcut = shortcuts[.local(project.id)]
        let newAgent: (() -> Void)? = showsNewAgentRow(for: project) ? { store.startNewAgent(from: project.id) } : nil
        Group {
            if let dragID {
                ProjectRow(project: project, isSelected: isSelected(project), shortcut: shortcut, compact: compact,
                           newAgent: newAgent)
                    .modifier(ActiveDrag(entryID: dragID, dragging: $dragging, store: store))
            } else {
                ProjectRow(project: project, isSelected: isSelected(project), shortcut: shortcut, compact: compact,
                           newAgent: newAgent)
            }
        }
        .matchedGeometryEffect(id: project.id, in: rowSpace)
        let worktrees = store.sidebarWorktrees(of: project.id)
        let merged = Set(worktrees.merged.map(\.id))
        ForEach(worktrees.listed.filter { !merged.contains($0.id) }) { worktree in
            worktreeRow(worktree, shortcuts: shortcuts, compact: compact)
        }
        if !worktrees.merged.isEmpty {
            MergedWorktreesLine(projectID: project.id, worktrees: worktrees.merged, isFolded: worktrees.isFolded,
                                compact: compact)
                .padding(.leading, compact ? 14 : 18)
            if !worktrees.isFolded {
                ForEach(worktrees.merged) { worktree in
                    worktreeRow(worktree, shortcuts: shortcuts, compact: compact)
                }
            }
        }
    }

    private func worktreeRow(_ worktree: Project, shortcuts: [SidebarShortcuts.Target: Int], compact: Bool) -> some View {
        ProjectRow(project: worktree, isSelected: isSelected(worktree), shortcut: shortcuts[.local(worktree.id)],
                   compact: compact)
            .padding(.leading, compact ? 14 : 18)
    }

    private func isSelected(_ project: Project) -> Bool {
        !store.showsPage && store.selectedRemote == nil && project.id == store.selectedProjectID
    }

    /// The New Agent button shows in the selected project's row, or the
    /// row of the project whose worktree is selected, so it's there when
    /// you need it without repeating in every row.
    private func showsNewAgentRow(for project: Project) -> Bool {
        guard !store.showsPage, store.selectedRemote == nil, let selected = store.selectedProjectID else { return false }
        return store.rootID(of: selected) == project.id
    }

    /// Shows the ⌘1 to ⌘9 hints once Command has been held on its own for
    /// a moment. Without the wait they'd flash on every ⌘T, ⌘W, and so on.
    /// They stay up through ⌘1 to ⌘9 themselves, so you can go to 4, then
    /// 7, then back to 4 without letting go to read the numbers again.
    private func watchCommandKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type == .flagsChanged && mods == .command {
                if !showsShortcuts && pendingShortcuts == nil {
                    pendingShortcuts = Task { @MainActor in
                        try? await Task.sleep(for: Self.shortcutHintDelay)
                        guard !Task.isCancelled else { return }
                        pendingShortcuts = nil
                        showsShortcuts = true
                    }
                }
            } else if event.type == .keyDown,
                      SidebarShortcuts.keepsHints(characters: event.charactersIgnoringModifiers, modifiers: mods) {
                // One of the shortcuts the hints are for: leave them (or
                // the wait for them) alone while Command stays down.
            } else {
                hideShortcuts()
            }
            return event
        }
    }

    /// How long Command is held before the hints show.
    static let shortcutHintDelay = Duration.milliseconds(100)

    private func hideShortcuts() {
        pendingShortcuts?.cancel()
        pendingShortcuts = nil
        showsShortcuts = false
    }

    /// Pinned, Active, and Recent, leaving out empty ones.
    private var listedGroups: [(title: String, entries: [ActiveEntry])] {
        let all: [(title: String, entries: [ActiveEntry])] = [
            ("Pinned", store.pins),
            ("Active", store.activeProjects.map { ActiveEntry(projectID: $0.id) }),
            ("Recent", store.recentProjects.map { ActiveEntry(projectID: $0.id) }),
        ]
        return all.filter { !$0.entries.isEmpty }
    }

}

/// Timings the sidebar's rows share with their backgrounds.
enum SidebarMotion {
    /// A row changing with its agent's state: its lines, its height, its
    /// tint, and the rows below making room.
    static let rowChange = Animation.snappy(duration: 0.25)
}

/// How much the Pinned and Active rows show. Standard has room for what
/// each agent is doing and just did; Compact fits many projects at once.
/// Recent and Inactive rows are compact either way.
enum SidebarLayout: String {
    case standard, compact

    static let key = "sidebarLayout"

    /// New installs start on Standard. A Mac that already has projects
    /// keeps the layout it's been using, which is Compact.
    static func registerDefault(hasProjects: Bool) {
        guard UserDefaults.standard.string(forKey: key) == nil else { return }
        UserDefaults.standard.set((hasProjects ? compact : standard).rawValue, forKey: key)
    }
}

/// Two or more merged worktrees with nothing going on, as one line under
/// their project: "4 merged", which shows or hides them, and Clean Up for
/// all of them at once.
private struct MergedWorktreesLine: View {
    @Environment(AppStore.self) private var store
    @Environment(WorktreeCleaner.self) private var cleaner
    let projectID: UUID
    let worktrees: [Project]
    let isFolded: Bool
    let compact: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.ui(size: 11, weight: .medium))
                .foregroundStyle(.purple)
                .frame(width: 20, height: compact ? 16 : 18)
            HStack(spacing: 4) {
                Text("\(worktrees.count) merged")
                Image(systemName: "chevron.right")
                    .font(.ui(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Clean Up") { cleaner.cleanUp(worktrees) }
                .buttonStyle(.link)
                .help("Remove these worktrees and delete their local branches")
        }
        .font(.ui(size: compact ? 11 : 12))
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 3 : 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(isHovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { isHovering = $0 }
        .help(worktrees.map { $0.branch ?? $0.name }.joined(separator: "\n"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(worktrees.count) merged worktrees")
        .accessibilityAction(named: isFolded ? "Show" : "Hide") { toggle() }
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) {
            if isFolded { store.expandedMerged.insert(projectID) } else { store.expandedMerged.remove(projectID) }
        }
    }
}

/// A section's name, with an optional symbol, a hint on the right, and
/// the Add Project button on whichever section comes first. Another Mac's
/// list shows a spinner there while it connects.
struct SectionTitle: View {
    @Environment(AppStore.self) private var store
    let title: String
    var symbol: String?
    var hint: String?
    var addsProject = false
    var isLoading = false
    /// What the Add Project button does in place of this Mac's folder
    /// picker, and what its tooltip says, for another Mac's list.
    var add: (() -> Void)?
    var addHelp = "Add Project (⌘O)"

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.ui(size: 8.5, weight: .semibold))
                    .rotationEffect(.degrees(symbol == "pin.fill" ? 45 : 0))
            }
            Text(title)
                .font(.ui(size: 11, weight: .semibold))
            Spacer(minLength: 4)
            if let hint {
                Text(hint)
                    .font(.ui(size: Theme.TypeScale.meta))
                    .foregroundStyle(.tertiary)
            }
            if isLoading {
                ProgressView().controlSize(.mini)
                    .frame(width: 20, height: 20)
            }
            if addsProject {
                Button {
                    if let add { add() } else { ProjectPicker.present(store: store) }
                } label: {
                    Image(systemName: "plus")
                        .font(.ui(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(addHelp)
                .accessibilityLabel("Add Project")
            }
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 20)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// Lets a pinned row be dragged, reordering live as it passes others.
struct ActiveDrag: ViewModifier {
    let entryID: String
    @Binding var dragging: String?
    let store: AppStore

    func body(content: Content) -> some View {
        content
            .onDrag {
                dragging = entryID
                return NSItemProvider(object: entryID as NSString)
            }
            .onDrop(of: [.text], delegate: ActiveReorderDelegate(target: entryID, dragging: $dragging, store: store))
    }
}

private struct ActiveReorderDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let store: AppStore

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        if store.grouping == .custom {
            store.moveGrouped(dragging, over: target)
        } else {
            store.moveActive(dragging, over: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// "Inactive" with a count, folding the projects under it away. A dot
/// shows when one of them is busy or waiting, so folding hides nothing urgent.
struct InactiveHeader: View {
    let count: Int
    /// The busiest of the folded projects, for the dot.
    let busiest: TabActivity?
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            collapsed.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.ui(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 10)
                Text("Inactive")
                    .font(.ui(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.ui(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if collapsed, let busiest {
                    ActivityIndicator(activity: busiest, size: 9)
                        .help("An inactive project is busy or waiting on you")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(collapsed ? "Show inactive projects" : "Hide inactive projects")
    }
}

extension TabActivity {
    /// Waiting first, then working: what a folded section's dot shows.
    static func busiest(_ all: [TabActivity]) -> TabActivity? {
        if all.contains(.waiting) { return .waiting }
        if all.contains(.working) { return .working }
        if all.contains(.remoteWorking) { return .remoteWorking }
        return nil
    }
}

extension View {
    /// The raised tray Pinned and Active (or your groups) sit on.
    func sidebarTray() -> some View {
        padding(4)
            .padding(.bottom, 2)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07)))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
    }
}

/// A custom group's name, or Ungrouped, with a count, folding the rows
/// under it away. A dot shows when a folded project is busy or waiting.
/// Rows dropped on it join the group.
private struct GroupHeader: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    let title: String
    let entries: [ActiveEntry]
    let collapsed: Bool
    /// nil for Ungrouped.
    let groupID: UUID?
    let addsProject: Bool
    @Binding var dragging: String?
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.ui(size: 8, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .font(.ui(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text("\(entries.count)")
                        .font(.ui(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if collapsed, let busiest = busiestActivity {
                        ActivityIndicator(activity: busiest, size: 9)
                            .help("A project in \(title) is busy or waiting on you")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help(collapsed ? "Show \(title)" : "Hide \(title)")
            if addsProject {
                Button {
                    ProjectPicker.present(store: store)
                } label: {
                    Image(systemName: "plus")
                        .font(.ui(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Add Project (⌘O)")
            }
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 20)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .onDrop(of: [.text], delegate: GroupDropDelegate(groupID: groupID, dragging: $dragging, store: store))
        .contextMenu {
            if let groupID {
                Button("Rename Group…") {
                    GroupNamePrompt.ask(title: "Rename Group", confirm: "Rename", initial: title) {
                        store.renameGroup(groupID, to: $0)
                    }
                }
                let index = store.groups.firstIndex { $0.id == groupID }
                Button("Move Up") { store.moveGroup(groupID, by: -1) }
                    .disabled(index == 0)
                Button("Move Down") { store.moveGroup(groupID, by: 1) }
                    .disabled(index == store.groups.count - 1)
                Divider()
                Button("Delete Group", role: .destructive) { store.deleteGroup(groupID) }
            } else {
                Button("New Group…") {
                    GroupNamePrompt.ask(title: "New Group", confirm: "Create") { store.createGroup(named: $0) }
                }
            }
        }
    }

    /// Waiting first, then working, among this Mac's projects here and their worktrees.
    private var busiestActivity: TabActivity? {
        let projects = entries.filter { $0.host == nil }.compactMap { store.project($0.projectID) }
        let all = projects.flatMap { [$0] + store.worktrees(of: $0.id) }.map { terminals.activity(for: $0) }
        if all.contains(.waiting) { return .waiting }
        if all.contains(.working) { return .working }
        if all.contains(.remoteWorking) { return .remoteWorking }
        return nil
    }
}

/// A row dropped on a group's header (or its empty space) joins the group.
/// On Ungrouped, it leaves its group.
private struct GroupDropDelegate: DropDelegate {
    let groupID: UUID?
    @Binding var dragging: String?
    let store: AppStore

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil }
        guard let id = dragging, let entry = store.listedEntries.first(where: { $0.id == id }) else { return false }
        store.move(entry, toGroup: groupID)
        return true
    }
}

/// Makes a new, empty group.
private struct NewGroupButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            GroupNamePrompt.ask(title: "New Group", confirm: "Create") { store.createGroup(named: $0) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.ui(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text("New Group")
                    .font(.ui(size: 11))
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// "Move to Group", for a row's right-click menu with custom groups.
struct GroupMenu: View {
    @Environment(AppStore.self) private var store
    let entry: ActiveEntry

    var body: some View {
        let current = store.groupID(of: entry.id)
        Menu("Move to Group") {
            ForEach(store.groups) { group in
                Button(group.name) { store.move(entry, toGroup: group.id) }
                    .disabled(group.id == current)
            }
            if !store.groups.isEmpty { Divider() }
            Button("New Group…") {
                GroupNamePrompt.ask(title: "New Group", confirm: "Create") { store.createGroup(named: $0, with: entry) }
            }
            if current != nil {
                Divider()
                Button("Remove from Group") { store.move(entry, toGroup: nil) }
            }
        }
    }
}

/// Asks for a group's name in a small alert.
enum GroupNamePrompt {
    /// Calls `done` with the name, unless it's empty or you cancel. Waits
    /// a turn first, so a right-click menu can close before the alert opens.
    @MainActor
    static func ask(title: String, confirm: String, initial: String = "", placeholder: String = "Group name",
                    done: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: initial)
            field.placeholderString = placeholder
            field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { done(name) }
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    @Environment(RepoMonitors.self) private var monitors
    @Environment(ProjectIcons.self) private var icons
    @Environment(PullRequests.self) private var pullRequests
    @Environment(Deployments.self) private var deployments
    @Environment(WorktreeCleaner.self) private var cleaner
    @Environment(Companion.self) private var companion
    let project: Project
    let isSelected: Bool
    var shortcut: Int?
    /// Recent and Inactive: a smaller icon, a lighter name, no status line.
    var compact = false
    /// Starts an agent from this project, when it's the one you're in.
    var newAgent: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        let monitor = monitors.monitor(for: project)
        let activity = terminals.activity(for: project)
        SidebarRowBody(model: model(activity: activity, monitor: monitor), isSelected: isSelected, compact: compact,
                       actions: actions, isHovering: isHovering)
            .modifier(SidebarRowChrome(activity: activity, isSelected: isSelected, isHovering: isHovering))
            // The whole row opens the project. Only the Allow, Deny, and
            // Clean Up buttons go elsewhere.
            .onTapGesture { store.selectedProjectID = project.id }
            .onHover { isHovering = $0 }
            // To VoiceOver the row is a button that opens the project and
            // says when it's the one open. Its own buttons stay reachable.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title(branch: monitor.snapshot?.branch))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { store.selectedProjectID = project.id }
        .task(id: monitor.lastRefresh) {
            if monitor.snapshot == nil { monitor.refresh() }
            icons.reload(project)
            pullRequests.track(project, branch: monitor.snapshot?.branch, baseRef: monitor.snapshot?.baseRef)
        }
        .contextMenu { menu }
    }

    /// What the row says, from the terminals, the repo and the stores.
    private func model(activity: TabActivity, monitor: RepoMonitor) -> SidebarRowModel {
        var model = SidebarRowModel(name: title(branch: monitor.snapshot?.branch), isWorktree: project.isWorktree,
                                    icon: .local(project, icons.image(for: project)), activity: activity)
        model.shortcut = shortcut
        model.notifiesPhone = notifiesPhone
        if store.renamingProjectID == project.id {
            model.rename = .init(placeholder: project.folderName, name: project.name)
        }
        let lastFinish = terminals.lastFinish(for: project)
        if let active = terminals.activeSince(for: project) {
            model.timer = ActiveTimerModel(since: active.since, action: active.action, tabID: active.tabID)
            // From the tab behind the timer, so they don't mix two tabs' work.
            let lead = terminals.existingSession(active.tabID)
            model.checklist = lead?.visibleChecklist ?? terminals.checklist(for: project)
            if activity == .waiting { model.waiting = waitingPrompt }
        }
        if let unseen = terminals.unseenSummary(for: project) {
            let at = terminals.existingSession(unseen.tabID)?.details?.stoppedAt ?? lastFinish?.at
            model.finished = FinishedSummary(recap: unseen.summary, at: at,
                                             changes: monitor.snapshot.map { $0.staged + $0.unstaged } ?? [],
                                             tabID: unseen.tabID)
        }
        model.tabs = terminals.tabLines(for: project)
        if let timer = model.timer {
            model.task = model.tabs.first { $0.id == timer.tabID }?.task
        }
        if project.tabs.contains(where: { tab in
            RestartRecovery.shared.stopped(tabID: tab.id, lastPrompt: terminals.existingSession(tab.id)?.details?.promptAt) != nil
        }) {
            model.notice = .stoppedByRestart
        } else if project.isWorktree, let leftovers = cleaner.waiting[project.id] {
            model.notice = .leftovers(leftovers.summary)
        }
        model.lastFinish = lastFinish.map { FinishedSummary(recap: $0.summary, at: $0.at, tabID: $0.tabID) }
        model.editedFrom = editedFrom
        model.status = RowStatus.pick(pr: pullRequests.info[project.id], deploy: deployments.info[project.id],
                                      branch: monitor.snapshot?.branch, baseRef: monitor.snapshot?.baseRef,
                                      isWorktree: project.isWorktree)
        return model
    }

    /// Claude in another project editing this one: said while it's at it,
    /// and afterward until you open this project.
    private var editedFrom: SidebarRowModel.EditedFrom? {
        guard let edit = terminals.editsFromOtherProjects(into: project).first,
              let source = store.project(edit.session.projectID) else { return nil }
        let session = edit.session
        if [.working, .waiting].contains(session.activity), edit.lastEdit >= (session.details?.promptAt ?? .distantPast) {
            return .init(name: source.name, isLive: true)
        }
        guard !isSelected, edit.lastEdit > store.lastSeen(project.id) else { return nil }
        return .init(name: source.name, isLive: false)
    }

    /// What Claude is asking: its permission question, else the question
    /// of whichever tab is waiting.
    private var waitingPrompt: WaitingPrompt? {
        let permission = terminals.permissionWaiting(in: project)
        let details = permission?.details ?? project.tabs.lazy.compactMap { terminals.existingSession($0.id)?.details }
            .first { $0.state == .waiting }
        guard let details else { return nil }
        return WaitingPrompt(question: details.question, action: permission != nil ? details.action : nil,
                             canAnswer: permission != nil)
    }

    private var actions: SidebarRowActions {
        SidebarRowActions(
            allow: { answerPermission(allow: true) },
            deny: { answerPermission(allow: false) },
            cleanUp: { cleaner.cleanUp(project) },
            rename: { name in finishRenaming(name) },
            newAgent: newAgent)
    }

    /// Answers the permission question the way Return and Escape do in the
    /// terminal, in whichever tab is asking.
    private func answerPermission(allow: Bool) {
        guard let permission = terminals.permissionWaiting(in: project) else { return }
        terminals.answerPermission(allow: allow, tabID: permission.tabID)
    }

    /// Saves the name typed in the row's field, or with nil keeps the old
    /// one. An empty name goes back to the folder's.
    private func finishRenaming(_ name: String?) {
        guard store.renamingProjectID == project.id else { return }
        if let name { store.renameProject(project.id, to: name) }
        store.renamingProjectID = nil
    }

    /// A worktree is named by its branch: the one it's on now, which is
    /// the one it was made with unless Claude switched.
    private func title(branch: String?) -> String {
        project.isWorktree ? (branch ?? project.branch ?? project.name) : project.name
    }

    /// Shown only while the iPhone companion is on, since there's no phone
    /// to notify otherwise.
    private var notifiesPhone: Bool {
        companion.isEnabled && store.notifiesPhone(project.id)
    }

    /// Turns phone notifications on for the project and its worktrees,
    /// for when you step away while Claude works.
    @ViewBuilder
    private var phoneToggle: some View {
        if companion.isEnabled {
            Divider()
            Toggle("Send Notifications to iPhone", isOn: Binding(
                get: { store.notifiesPhone(project.id) },
                set: { store.setNotifiesPhone(project.id, $0) }
            ))
        }
    }

    @ViewBuilder
    private var menu: some View {
        markUnreadItem
        if project.isWorktree {
            worktreeMenu
        } else {
            projectMenu
        }
    }

    /// Puts the done mark back on a reply you've looked at but not dealt
    /// with. First, as in Mail, and only on a row with nothing showing yet.
    @ViewBuilder
    private var markUnreadItem: some View {
        if terminals.unreadTarget(for: project) != nil {
            Button("Mark as Unread") { terminals.markUnread(project) }
            Divider()
        }
    }

    @ViewBuilder
    private var worktreeMenu: some View {
        if let pr = pullRequests.info[project.id] {
            Button("Open Pull Request #\(pr.number)") { NSWorkspace.shared.open(pr.url) }
        }
        // The same groups, in the same order, as a project's menu: new
        // work, Show in Finder, then what removes things last.
        Button("New Agent on a Branch…") { store.startNewAgent(from: project.id) }
        if ProjectAccountMenuItems.hasChoice {
            Menu(ProjectAccountMenuItems.title) { ProjectAccountMenuItems(projectID: project.id) }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }
        Button(Editors.menuTitle) { Editors.open(project.url) }
        phoneToggle
        Divider()
        if project.isExternalWorktree {
            Button("Remove from Sidebar", role: .destructive) { store.hideExternalWorktree(project.id) }
        } else {
            if cleaner.waiting[project.id] != nil {
                Button("Clean Up…") { cleaner.cleanUp(project) }
            }
            Button("Discard Agent…", role: .destructive) { cleaner.discard(project) }
        }
    }

    @ViewBuilder
    private var projectMenu: some View {
        if store.grouping == .custom {
            GroupMenu(entry: store.entry(for: project.id))
        } else {
            if store.isPinned(project.id) {
                Button("Unpin") { store.setPinned(project.id, false) }
            } else {
                Button("Pin to Top") { store.setPinned(project.id, true) }
            }
            if store.isActive(project.id) {
                Button("Move to Inactive") { store.setActive(project.id, false) }
            } else {
                Button("Make Active") { store.setActive(project.id, true) }
            }
        }
        phoneToggle
        Divider()
        Button("New Agent on a Branch…") { store.startNewAgent(from: project.id) }
        Menu(ProjectAccountMenuItems.title) { ProjectAccountMenuItems(projectID: project.id) }
        Divider()
        Button("Rename…") { store.renamingProjectID = project.id }
        if project.customName != nil {
            Button("Use Folder Name") { store.renameProject(project.id, to: "") }
        }
        Button("Ask \(Agents.standard.name) to Set Icon") {
            store.selectedProjectID = project.id
            store.addTab(.agent, to: project.id, prompt: ProjectIcons.claudePrompt)
        }
        Button("Choose Icon…") { ProjectIcons.presentPicker(for: project, icons: icons) }
        if icons.hasCustomIcon(project) {
            Button("Reset Icon") {
                do { try icons.resetIcon(for: project) } catch { NSAlert(error: error).runModal() }
            }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }
        Button(Editors.menuTitle) { Editors.open(project.url) }
        if project.hiddenWorktrees?.isEmpty == false {
            Button("Show Hidden Worktrees") { store.showHiddenWorktrees(of: project.id) }
        }
        Divider()
        Button("Remove from Workbench…", role: .destructive) {
            confirmRemove(project)
        }
    }

    /// Asks first, in the words used for a project on another Mac: the
    /// project, its tabs and its agents all leave the list at once.
    private func confirmRemove(_ project: Project) {
        // After the menu has closed, so the alert isn't under it.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Remove \(project.name) from Workbench?"
            alert.informativeText = "Its tabs close. The folder stays where it is, and you can add it again later."
            alert.addButton(withTitle: "Remove").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.removeProject(project.id)
        }
    }
}

/// The project's own icon if it has one, otherwise a colored initial derived
/// from its name so it stays stable.
struct ProjectIcon: View {
    let project: Project
    var image: NSImage?
    var size: CGFloat = 20
    /// A hairline edge, which helps small icons on a dark sidebar.
    var outlined = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                let hue = IconTint.tileHue(for: project.repoName)
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.5, brightness: 0.85),
                        Color(hue: (hue + 0.04).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.6),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay {
                    Text(project.repoName.prefix(1).uppercased())
                        .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(outlined ? 0.12 : 0), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
}

/// The one thing a quiet row's second line says, most useful first:
/// trouble, then a deploy in flight, then the pull request, then a branch
/// that isn't the default. Nothing at all for a project on its default
/// branch with nothing going on.
enum RowStatus: Equatable {
    case checksFailing(PullRequestInfo)
    case deployFailed(DeployInfo)
    case deploying(DeployInfo)
    case pullRequest(PullRequestInfo)
    case branch(String)

    static func pick(pr: PullRequestInfo?, deploy: DeployInfo?, branch: String?, baseRef: String?, isWorktree: Bool) -> RowStatus? {
        let openPR = pr.flatMap { $0.state == .open || $0.state == .draft ? $0 : nil }
        if let openPR, openPR.checks == .failing { return .checksFailing(openPR) }
        if let deploy, deploy.state == .failed { return .deployFailed(deploy) }
        if let deploy, deploy.state == .deploying { return .deploying(deploy) }
        if let openPR { return .pullRequest(openPR) }
        // A worktree is named by its branch, so its finished PR says more.
        if isWorktree, let pr { return .pullRequest(pr) }
        if !isWorktree, let branch, !isDefault(branch, baseRef: baseRef) { return .branch(branch) }
        return nil
    }

    private static func isDefault(_ branch: String, baseRef: String?) -> Bool {
        if let baseRef, let last = baseRef.split(separator: "/").last { return branch == last }
        return branch == "main" || branch == "master"
    }
}

/// A quiet row's second line: an icon and a few words.
struct RowStatusLine: View {
    let status: RowStatus
    /// Standard rows let a long pull request title wrap onto a second line.
    var lines = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol {
                Image(systemName: symbol.name)
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundStyle(symbol.color)
            }
            Text(text)
                .lineLimit(lines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                // A pull request's title rarely fits.
                .help(text)
        }
        .font(.ui(size: 11))
        .foregroundStyle(isTrouble ? AnyShapeStyle(Theme.Status.failed) : AnyShapeStyle(.secondary))
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
        case .deploying(let deploy): deploy.environments.first.map { "Deploying to \($0)" } ?? "Deploying #\(deploy.prNumber)"
        case .pullRequest(let pr):
            switch pr.state {
            case .merged: "Merged #\(pr.number) \(pr.title)"
            case .closed: "Closed #\(pr.number) \(pr.title)"
            default: "#\(pr.number) \(pr.title)"
            }
        case .branch(let name): name
        }
    }

    private var symbol: (name: String, color: Color)? {
        switch status {
        case .checksFailing, .deployFailed: ("xmark.circle.fill", Theme.Status.failed)
        case .deploying: ("arrow.up.circle.fill", Theme.Status.waiting)
        case .pullRequest(let pr):
            switch pr.state {
            case .merged: ("checkmark.circle.fill", .purple)
            case .closed: ("xmark.circle", .secondary)
            default: PullRequestDisplay.checksSymbol(pr.checks) ?? ("arrow.triangle.pull", Theme.Status.done)
            }
        case .branch: ("arrow.triangle.branch", .secondary)
        }
    }
}

enum PullRequestDisplay {
    static func checksSymbol(_ checks: PullRequestInfo.Checks) -> (name: String, color: Color)? {
        switch checks {
        case .none: nil
        case .pending: ("clock.fill", Theme.Status.waiting)
        case .passing: ("checkmark.circle.fill", Theme.Status.done)
        case .failing: ("xmark.circle.fill", Theme.Status.failed)
        }
    }

    static func checksText(_ pr: PullRequestInfo) -> String? {
        switch pr.checks {
        case .none: return nil
        case .pending: return pr.totalCount > 0 ? "Checks running, \(pr.passedCount) of \(pr.totalCount) passed" : "Checks running"
        case .passing: return "Checks passed"
        case .failing:
            return pr.failingNames.isEmpty ? "Checks failing" : "Failing: " + pr.failingNames.prefix(3).joined(separator: ", ")
        }
    }
}

/// A busy row's second line: how long it's been at it, then what it's
/// doing right now, wrapping onto a second line where the row has room.
struct ActiveTimerLine: View {
    let since: Date
    let action: String?
    let activity: ActivityKind
    var lines = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            ActiveTimer(since: since, activity: activity)
            Text(action ?? fallback)
                .lineLimit(lines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.ui(size: 11))
        .foregroundStyle(.secondary)
    }

    private var fallback: String {
        switch activity {
        case .waiting: "Waiting on you"
        case .remoteWorking: "Working over ssh"
        default: "Working"
        }
    }
}

/// Under a waiting Standard row: what Claude is asking, and for a plain
/// allow-or-deny question, buttons that answer it the way Return and
/// Escape do in the terminal.
struct WaitingDetail: View {
    let prompt: WaitingPrompt
    let allow: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let question = prompt.question {
                Text(question)
                    .lineLimit(2)
            }
            if let action = prompt.action {
                Text(action)
                    .font(.ui(size: Theme.TypeScale.meta, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
            if prompt.canAnswer {
                HStack(spacing: 6) {
                    Button("Allow", action: allow)
                        .buttonStyle(AnswerButtonStyle(prominent: true))
                        .help("Allow it, like pressing Return in the terminal")
                    Button("Deny", action: deny)
                        .buttonStyle(AnswerButtonStyle(prominent: false))
                        .help("Say no, like pressing Escape in the terminal")
                }
            }
        }
        .font(.ui(size: 11))
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.top, 5)
    }
}

/// Allow and Deny, wherever Workbench asks outside the chat: Allow first,
/// in the waiting amber, then Deny. `large` is for the Overview's cards.
struct AnswerButtonStyle: ButtonStyle {
    let prominent: Bool
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(size: large ? 12 : 11, weight: .medium))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.primary)
            .padding(.horizontal, large ? 12 : 9)
            .padding(.vertical, large ? 4 : 2.5)
            .background(prominent ? AnyShapeStyle(ActivityBackground.waiting) : AnyShapeStyle(Color.primary.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: large ? 6 : 5, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Under a finished Standard row: when it finished, the recap, and what's
/// left uncommitted.
struct FinishedDetail: View {
    let recap: String
    let at: Date?
    let changes: [FileChange]
    let lines: Int
    @Environment(\.motionLevel) private var motionLevel
    /// How much of each total is showing, from 0 to 1.
    @State private var counted = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let at {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Finished " + Self.ago(at, now: context.date))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(recap)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .help(recap)
            if !changes.isEmpty {
                changeCounts
                    .padding(.top, 3)
            }
        }
        .font(.ui(size: 11))
    }

    /// "5 files +212 −38", uncommitted.
    private var changeCounts: some View {
        let files = Set(changes.map(\.path)).count
        let added = changes.reduce(0) { $0 + $1.additions }
        let removed = changes.reduce(0) { $0 + $1.deletions }
        return HStack(spacing: 4) {
            Text(files == 1 ? "1 file" : "\(files) files")
                .foregroundStyle(.secondary)
            if added > 0 { CountingText(prefix: "+", value: Double(added) * counted).foregroundStyle(Theme.Status.done) }
            if removed > 0 { CountingText(prefix: "−", value: Double(removed) * counted).foregroundStyle(Theme.Status.failed) }
        }
        .font(.ui(size: 10, weight: .medium).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help("Uncommitted changes")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(files == 1 ? "1 file" : "\(files) files"), \(added) added, \(removed) removed, uncommitted")
        .onAppear {
            // The totals of a turn that finished a moment ago count up from
            // nothing. Older ones are just there.
            guard motionLevel != .still, let at, Date().timeIntervalSince(at) < Self.freshFor else { return }
            counted = 0
            withAnimation(.easeOut(duration: 0.7).delay(0.25)) { counted = 1 }
        }
    }

    /// How long after a turn ends its totals still count up when they appear.
    private static let freshFor: TimeInterval = 8

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// A whole number that can count its way to a new value: it animates
/// through the numbers in between, where plain text would jump.
struct CountingText: View, Animatable {
    let prefix: String
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(prefix + String(Int(value.rounded())))
    }
}

#if DEBUG
/// This Mac's project rows, quiet, drawn to PNGs in light and dark at each
/// layout, for checking the row itself: its icon, name, selection card and
/// shortcut. BENCH_RENDER_ROWS=<folder>, with BENCH_SUPPORT_DIR pointed at
/// a scratch folder, since the row's environment reads the support folder.
enum LocalRowsPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalRowsPreview-\(UUID().uuidString)")
        let bench = Project(path: root.appendingPathComponent("Bench").path)
        var worktree = Project(path: root.appendingPathComponent("Bench-worktrees/feat-ui-foundations").path)
        worktree.parentID = bench.id
        worktree.parentName = "Bench"
        worktree.branch = "feat/ui-foundations"
        let recipes = Project(path: root.appendingPathComponent("Recipes").path)
        var website = Project(path: root.appendingPathComponent("website").path)
        website.customName = "Website (Astro)"
        let projects = [bench, worktree, recipes, website]
        for project in projects {
            try? FileManager.default.createDirectory(at: project.url, withIntermediateDirectories: true)
        }
        struct Fixture: Encodable { var projects: [Project] }
        let stateFile = root.appendingPathComponent("state.json")
        try? JSONEncoder().encode(Fixture(projects: projects)).write(to: stateFile)
        let store = AppStore(fileURL: stateFile)
        let terminals = TerminalManager(store: store)
        let pullRequests = PullRequests()
        let deployments = Deployments()
        let cleaner = WorktreeCleaner(store: store, terminals: terminals, pullRequests: pullRequests)
        let monitors = RepoMonitors()
        let icons = ProjectIcons()
        let ports = PortScanner()
        let companion = Companion(snapshots: CompanionSnapshots(
            store: store, terminals: terminals, pullRequests: pullRequests, deployments: deployments, monitors: monitors,
            files: FileListMonitors(), icons: icons, cleaner: cleaner, shortcuts: TabShortcuts(), ports: ports))
        // Standard and Compact layouts, then the smaller rows of Recent and Inactive.
        for (name, layout, compact) in [("standard", SidebarLayout.standard, false), ("compact", .compact, false), ("small", .standard, true)] {
            // Its own settings, so the real app's layout is left alone.
            let defaults = UserDefaults(suiteName: "LocalRowsPreview-\(name)")!
            defaults.set(layout.rawValue, forKey: SidebarLayout.key)
            let view = VStack(spacing: 2) {
                ProjectRow(project: bench, isSelected: true, compact: compact)
                ProjectRow(project: worktree, isSelected: false, compact: compact)
                    .padding(.leading, compact ? 14 : 18)
                ProjectRow(project: recipes, isSelected: false, shortcut: 2, compact: compact)
                ProjectRow(project: website, isSelected: false, compact: compact)
            }
            .padding(8).frame(width: 280)
            .environment(store).environment(terminals).environment(monitors).environment(icons).environment(ports)
            .environment(pullRequests).environment(deployments).environment(cleaner).environment(companion)
            .defaultAppStorage(defaults)
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("rows-\(name)-\(mode).png"))
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Busy sidebar rows with sample checklists, drawn to PNGs in light and
/// dark, for checking the steps bar. BENCH_RENDER_STEPS=<folder>.
enum StepsBarPreview {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        func steps(_ done: Int, _ total: Int, current: Bool = true) -> [ChecklistItem] {
            (0..<total).map { i in
                ChecklistItem(id: "\(i)", title: "Step \(i)",
                              status: i < done ? .completed : (i == done && current ? .inProgress : .pending))
            }
        }
        let rows: [(String, String, TabActivity, [ChecklistItem], Color)] = [
            ("Bench", "Editing SidebarView.swift", .working, steps(3, 7), .orange),
            ("Recipes", "Waiting on you", .waiting, steps(5, 6), .green),
            ("Website", "Running the build", .working, steps(1, 4), .purple),
            ("Podcast Tools", "Writing tests", .working, steps(11, 18), .teal),
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = VStack(spacing: 4) {
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 7).fill(row.4.gradient).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.0).font(.ui(size: 13, weight: .medium))
                            ActiveTimerLine(since: Date().addingTimeInterval(-252), action: row.1,
                                            activity: CompanionSnapshots.kind(row.2))
                            ChecklistStepsBar(items: row.3, activity: CompanionSnapshots.kind(row.2))
                                .padding(.top, 4).padding(.bottom, 1)
                        }
                        Spacer(minLength: 0)
                        ActivityIndicator(activity: row.2, size: 11)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background { ActivityBackground(activity: row.2, showsOutline: false) }
                }
            }
            .padding(10)
            .frame(width: 260)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.companionPalette, TerminalTheme.shared.sidebarPalette)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("steps-\(name).png"))
        }
        renderStandard(to: folder)
    }

    /// Standard rows: a busy one with its checklist, and a finished one.
    private static func renderStandard(to folder: URL) {
        let now = Date()
        let steps = (0..<7).map { i in
            ChecklistItem(id: "\(i)", title: "Step \(i)", activeTitle: "Building the standard row",
                          status: i < 3 ? .completed : i == 3 ? .inProgress : .pending)
        }
        let changes = [FileChange(path: "a.swift", kind: .modified, additions: 180, deletions: 30, section: .unstaged),
                       FileChange(path: "b.swift", kind: .modified, additions: 32, deletions: 8, section: .unstaged)]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = VStack(spacing: 4) {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 7).fill(Color.orange.gradient).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Bench").font(.ui(size: 13, weight: .medium))
                        ActiveTimerLine(since: now.addingTimeInterval(-252), action: "Building the standard row",
                                        activity: CompanionSnapshots.kind(.working))
                        ChecklistStepsBar(items: steps, activity: CompanionSnapshots.kind(.working))
                            .padding(.top, 4).padding(.bottom, 1)
                    }
                    Spacer(minLength: 0)
                    ActivityIndicator(activity: .working, size: 11).padding(.top, 3)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background { ActivityBackground(activity: .working, showsOutline: false) }
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 7).fill(Color.purple.gradient).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Nonogame").font(.ui(size: 13, weight: .medium))
                        FinishedDetail(recap: "Added the Rolling dice reveal and put it in the reveal picker. Dice settle on the solved image, and the unit tests pass.",
                                       at: now.addingTimeInterval(-360), changes: changes, lines: 3)
                    }
                    Spacer(minLength: 0)
                    ActivityIndicator(activity: .done, size: 11).padding(.top, 3)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background { ActivityBackground(activity: .done, showsOutline: false) }
                // Three Claude tabs: one finished, described in full, and a line for each of the others.
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 7).fill(Color.pink.gradient).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("newspring-atlas").font(.ui(size: 13, weight: .medium))
                        FinishedDetail(recap: "Started ATL-351 on a new branch off origin/main; reviewed divisions.yaml and the lakehouse writer.",
                                       at: now.addingTimeInterval(-240), changes: [], lines: 3)
                        OtherTabsList(lines: [
                            TabLine(id: UUID(), activity: .working, customTitle: nil, terminalTitle: "✳ Get started on ATL-350",
                                    details: AgentDetails(prompt: "Get started on ATL-350.", plainAction: "Reading divisions.yaml"),
                                    initialPrompt: nil, fallbackTitle: "Claude"),
                            TabLine(id: UUID(), activity: .idle, customTitle: "Release notes", terminalTitle: nil,
                                    details: AgentDetails(prompt: "Draft the notes", stoppedAt: now),
                                    initialPrompt: nil, fallbackTitle: "Claude"),
                        ])
                        .padding(.top, 4)
                        RowStatusLine(status: .branch("generalize-division-naming-atl-351")).padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    ActivityIndicator(activity: .done, size: 11).padding(.top, 3)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background { ActivityBackground(activity: .done, showsOutline: false) }
            }
            .padding(10)
            .frame(width: 280)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.companionPalette, TerminalTheme.shared.sidebarPalette)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("standard-\(name).png"))
        }
    }
}
#endif
