import BenchKit
import Foundation
import SwiftUI
import Observation

/// The app's saved state: projects, their tabs, and what is selected.
@Observable
final class AppStore {
    private(set) var projects: [Project] = []
    var selectedProjectID: UUID? {
        didSet {
            // Both the project you left and the one you opened are seen as of now.
            for id in [oldValue, selectedProjectID].compactMap({ $0 }) { seenAt[id] = .now }
            save()
            // A project left sitting in Inactive closes its tabs once you leave it.
            if let oldValue, oldValue != selectedProjectID { closeInactiveTabs() }
            // Picking a project (click, ⌘1–9, a notification) leaves the Overview.
            showsOverview = false
            settingsSection = nil
            selectedRemote = nil
            sidebarHost = nil
        }
    }

    /// When you last had each project open, this run. Edits Claude made to
    /// a project from another one since then get a note in the sidebar.
    private(set) var seenAt: [UUID: Date] = [:]
    @ObservationIgnored private let launchedAt = Date()

    func lastSeen(_ projectID: UUID) -> Date { seenAt[projectID] ?? launchedAt }

    /// The Mac whose projects the sidebar lists: nil for this one, or the
    /// host of a paired Mac. Picking a project anywhere follows it there.
    var sidebarHost: String?

    /// A project on another Mac, shown in place of the local selection.
    /// Not saved: the other Mac's list may differ by the next launch.
    var selectedRemote: RemoteSelection? {
        didSet {
            if selectedRemote != nil {
                showsOverview = false
                settingsSection = nil
            }
        }
    }

    /// Something a menu item or shortcut asked of the remote project on
    /// screen. Its view does it and clears this.
    enum RemoteAction: Equatable { case claudeTab, shell, newAgent }
    var pendingRemoteAction: RemoteAction?

    /// True when the main area shows a project, here or on another Mac, so
    /// New Claude Tab and friends have somewhere to go.
    var hasProjectOnScreen: Bool { selectedRemote != nil || selectedProjectID != nil }

    var showsChanges = true {
        // The split view writes the same value back now and then; only a
        // real change counts as you choosing.
        didSet { if !isFittingWindow, showsChanges != oldValue { fitHidChanges = false } }
    }
    /// Whether the sidebar is showing. The window draws its own sidebar
    /// button, so it keeps this rather than the split view alone. When
    /// it's hidden, a rail of project icons stands in for it.
    var sidebarVisibility: NavigationSplitViewVisibility = .all {
        didSet { if !isFittingWindow, sidebarVisibility != oldValue { fitCollapsedSidebar = false } }
    }

    // MARK: Fitting a narrow window

    /// Below this window width the right panel tucks away.
    static let hidesChangesBelow: CGFloat = 1000
    /// Below this the sidebar collapses to its icons.
    static let collapsesSidebarBelow: CGFloat = 720

    /// True when the window got too narrow and hid the right panel
    /// itself, so it comes back when the window widens. Showing or hiding
    /// it yourself clears this, and then it stays how you left it.
    @ObservationIgnored private var fitHidChanges = false
    @ObservationIgnored private var fitCollapsedSidebar = false
    @ObservationIgnored private var isFittingWindow = false
    @ObservationIgnored private var lastWindowWidth: CGFloat?

    /// Hides the right panel, then collapses the sidebar, as the window
    /// narrows past each breakpoint, and brings back whatever it hid as
    /// the window widens again. It only acts when the width crosses a
    /// breakpoint, so a panel you open in a narrow window stays open.
    func fitWindow(width: CGFloat) {
        let old = lastWindowWidth ?? .infinity
        lastWindowWidth = width
        isFittingWindow = true
        defer { isFittingWindow = false }
        withAnimation(Theme.Motion.layout) {
            if old >= Self.hidesChangesBelow, width < Self.hidesChangesBelow, showsChanges {
                showsChanges = false
                fitHidChanges = true
            } else if old < Self.hidesChangesBelow, width >= Self.hidesChangesBelow, fitHidChanges {
                showsChanges = true
                fitHidChanges = false
            }
            if old >= Self.collapsesSidebarBelow, width < Self.collapsesSidebarBelow, sidebarVisibility != .detailOnly {
                sidebarVisibility = .detailOnly
                fitCollapsedSidebar = true
            } else if old < Self.collapsesSidebarBelow, width >= Self.collapsesSidebarBelow, fitCollapsedSidebar {
                sidebarVisibility = .all
                fitCollapsedSidebar = false
            }
        }
    }
    /// True while the Overview of every Claude session fills the main area.
    var showsOverview = false {
        didSet { if showsOverview { settingsSection = nil } }
    }
    /// Where the Overview was opened from, for analytics.
    enum OverviewSource: String {
        case sidebar, rail, menu, commandBar = "command_bar", menuBar = "menu_bar", notification
    }
    /// Opens the Overview. Asking again while it's showing isn't counted.
    func showOverview(from source: OverviewSource) {
        if !showsOverview { Analytics.capture(.overviewOpened, ["from": source.rawValue]) }
        showsOverview = true
    }
    /// The Settings page's section while Settings fills the main area and
    /// its sections take over the sidebar. nil when it's closed.
    var settingsSection: SettingsSection? = AppStore.openingSection {
        didSet { if settingsSection != nil { showsOverview = false } }
    }
    /// BENCH_OPEN_SETTINGS=<section> opens on a page of Settings, for
    /// checking layouts.
    private static var openingSection: SettingsSection? {
        #if DEBUG
        ProcessInfo.processInfo.environment["BENCH_OPEN_SETTINGS"].flatMap(SettingsSection.init(rawValue:))
        #else
        nil
        #endif
    }
    /// True while Settings is open on Usage, with token use and API-price
    /// estimates.
    var showsUsage: Bool {
        get { settingsSection == .usage }
        set { settingsSection = newValue ? .usage : (settingsSection == .usage ? nil : settingsSection) }
    }
    /// True while a page that isn't a project (Overview or Settings) is showing.
    var showsPage: Bool { showsOverview || settingsSection != nil }
    /// True while the selected project's Past Sessions popover is open.
    var showsHistory = false
    /// The file a review tab was last asked to scroll to. Not saved.
    var reviewReveal: ReviewReveal?
    /// True while the ⌘K command bar floats over the window.
    var showsCommandBar = false
    /// True while the welcome fills the window: on first launch, or from
    /// Help > Welcome to Bench.
    var showsWelcome = !UserDefaults.standard.bool(forKey: SetupCheck.seenKey)
        || ProcessInfo.processInfo.environment["BENCH_WELCOME_STEP"] != nil
    /// The project whose New Agent sheet is open.
    var newAgentParentID: UUID?
    /// True while the Send Tasks sheet is open.
    var showsSendTasks = false
    /// Asks Settings > Claude Accounts to open its Add Account sheet.
    var addsClaudeAccount = false
    /// The other Mac the open Send Tasks sheet sends to, if any.
    var sendTasksHost: String?
    /// The project whose sidebar name is being edited.
    var renamingProjectID: UUID?
    /// The tab whose name is being edited in the tab bar.
    var renamingTabID: UUID?
    /// Projects showing the New Tab page from the + button, with their tabs
    /// as they were when it opened. Any change to the tabs closes it.
    private var startPages: [UUID: StartPageMark] = [:]
    private struct StartPageMark: Equatable {
        var selected: UUID?
        var tabs: [UUID]
    }

    /// Opens the New Agent sheet for a project, or for the project a
    /// worktree came from.
    func startNewAgent(from projectID: UUID? = nil) {
        if projectID == nil, selectedRemote != nil {
            pendingRemoteAction = .newAgent
            return
        }
        guard let id = projectID ?? selectedProjectID else { return }
        newAgentParentID = rootID(of: id)
    }

    /// Opens the Send Tasks sheet, which works with or without a project
    /// selected.
    /// With another Mac's project on screen, the tasks go to that Mac.
    func startSendTasks(remoteHost: String? = nil) {
        sendTasksHost = remoteHost
        showsSendTasks = true
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    /// Projects shown at the top level of the sidebar (not worktrees).
    var topLevelProjects: [Project] {
        projects.filter { $0.parentID == nil }
    }

    // MARK: Phone notifications

    /// Projects that send notifications to your iPhone, by their own id (a
    /// worktree follows its project). Off by default, so the phone stays
    /// quiet while you work at the Mac. Turn a project on as you leave.
    private(set) var phoneNotifying: Set<UUID> = Set(
        (UserDefaults.standard.stringArray(forKey: AppStore.phoneNotifyingKey) ?? []).compactMap(UUID.init(uuidString:)))
    private static let phoneNotifyingKey = "companion.notifyingProjects"

    func notifiesPhone(_ projectID: UUID) -> Bool {
        phoneNotifying.contains(rootID(of: projectID))
    }

    func setNotifiesPhone(_ projectID: UUID, _ isOn: Bool) {
        let id = rootID(of: projectID)
        guard phoneNotifying.contains(id) != isOn else { return }
        if isOn { phoneNotifying.insert(id) } else { phoneNotifying.remove(id) }
        UserDefaults.standard.set(phoneNotifying.map(\.uuidString), forKey: Self.phoneNotifyingKey)
    }

    // MARK: Active and inactive

    /// Projects you've pinned to the top of Active, in your order: this
    /// Mac's, and projects on paired Macs you've added here.
    private(set) var pins: [ActiveEntry] = []
    /// When you last used each of this Mac's projects: sent Claude a
    /// prompt, opened a tab, or (from Claude Code's history) worked there.
    private(set) var lastUsed: [UUID: Date] = [:]
    /// When you moved a project to Inactive. It stays there until you use
    /// it again.
    private(set) var dismissed: [UUID: Date] = [:]
    /// When each project last came into Active. Active sorts by this, so
    /// a project keeps its place while you work in it instead of jumping
    /// to the top with every message.
    private(set) var activeSince: [UUID: Date] = [:]
    /// Your own named groups, in order, for when the sidebar groups
    /// projects your way instead of by when you used them.
    private(set) var groups: [ProjectGroup] = []
    /// How the sidebar sorts projects: by when you used them, or into
    /// your own groups.
    var grouping = SidebarGrouping(rawValue: UserDefaults.standard.string(forKey: SidebarGrouping.key) ?? "") ?? .activity {
        didSet {
            guard grouping != oldValue else { return }
            UserDefaults.standard.set(grouping.rawValue, forKey: SidebarGrouping.key)
            syncProjectOrder()
            save()
        }
    }
    /// Whether Ungrouped is folded away, with custom groups.
    var ungroupedCollapsed = UserDefaults.standard.bool(forKey: "ungroupedCollapsed") {
        didSet { UserDefaults.standard.set(ungroupedCollapsed, forKey: "ungroupedCollapsed") }
    }
    /// The time the sections are worked out for, moved on every few
    /// minutes so projects move along when their time is up.
    /// Tests move it forward to age projects.
    var now = Date()
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var closesInactiveAtLaunch = true
    /// Whether Claude is working or waiting on you in a project or one of
    /// its worktrees. Set by the terminals, which own that state.
    @ObservationIgnored var isBusy: (UUID) -> Bool = { _ in false }
    /// Whether closing a tab would cut off work: Claude mid-task or
    /// waiting on you, or a program running in a shell. Set by the terminals.
    @ObservationIgnored var tabIsWorking: (UUID) -> Bool = { _ in false }

    /// How long a project stays in Active after you use it, and when it
    /// moves on to Inactive. Recent is in between. Settings › General.
    var sidebarTimes = SidebarTimes.saved() {
        didSet {
            // Inactive always comes after Active. With @Observable, setting
            // it here runs didSet again, which then saves the fitted times.
            if sidebarTimes.fitted != sidebarTimes { sidebarTimes = sidebarTimes.fitted; return }
            guard sidebarTimes != oldValue else { return }
            sidebarTimes.save()
            syncProjectOrder()
            closeInactiveTabs()
        }
    }
    /// Whether a project's tabs close when it goes Inactive, so coming back
    /// to it starts fresh. Off keeps them however long it's been.
    var closesInactiveTabs = UserDefaults.standard.object(forKey: AppStore.closesInactiveTabsKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(closesInactiveTabs, forKey: Self.closesInactiveTabsKey)
            if closesInactiveTabs { closeInactiveTabs() }
        }
    }
    static let closesInactiveTabsKey = "closesInactiveTabs"

    enum Section {
        case pinned, active, recent, inactive
    }

    /// Where a project (or the project a worktree came from) goes in the
    /// sidebar. Pinned always wins. Claude working or waiting counts as
    /// Active, however long ago you last sent anything. Moving a project
    /// to Inactive keeps it there until you use it again.
    func section(of projectID: UUID) -> Section {
        let id = rootID(of: projectID)
        if isPinned(id) { return .pinned }
        let used = lastUsed[id]
        if let gone = dismissed[id], gone >= (used ?? .distantPast) { return .inactive }
        if isBusy(id) { return .active }
        guard let used else { return .inactive }
        let age = now.timeIntervalSince(used)
        if age < sidebarTimes.active { return .active }
        if age < sidebarTimes.inactiveAfter { return .recent }
        return .inactive
    }

    /// Projects in Active: ones with open tabs first, then ones with none
    /// (say, after you close the last tab), each newest arrival first.
    /// Ones already there keep their order.
    var activeProjects: [Project] {
        topLevelProjects.filter { section(of: $0.id) == .active }
            .sorted {
                let (open0, open1) = (hasTabs($0.id), hasTabs($1.id))
                if open0 != open1 { return open0 }
                return arrival($0.id) > arrival($1.id)
            }
    }

    /// Whether a project or any of its worktrees has a tab open.
    func hasTabs(_ id: UUID) -> Bool {
        projects.contains { ($0.id == id || $0.parentID == id) && !$0.tabs.isEmpty }
    }

    /// Projects used a while ago but not long enough to be Inactive (by
    /// default 6 to 24 hours), most recent first. Nothing happens
    /// in them (using one moves it to Active), so this order holds still.
    var recentProjects: [Project] {
        topLevelProjects.filter { section(of: $0.id) == .recent }
            .sorted { (lastUsed[$0.id] ?? .distantPast) > (lastUsed[$1.id] ?? .distantPast) }
    }

    private func arrival(_ id: UUID) -> Date {
        activeSince[id] ?? lastUsed[id] ?? .distantPast
    }

    /// Pinned, then Active, then Recent: the projects the sidebar lists
    /// above Inactive. With custom groups, every group's projects and then
    /// Ungrouped, which leaves nothing under Inactive.
    var listedEntries: [ActiveEntry] {
        switch grouping {
        case .activity: pins + (activeProjects + recentProjects).map { ActiveEntry(projectID: $0.id) }
        case .custom: groups.flatMap(\.entries) + ungroupedEntries
        }
    }

    /// The rows ⌘1 to ⌘9 count through (with their worktrees): the listed
    /// ones, leaving out folded groups.
    var numberedEntries: [ActiveEntry] {
        switch grouping {
        case .activity: listedEntries
        case .custom:
            groups.filter { !$0.isCollapsed }.flatMap(\.entries) + (ungroupedCollapsed ? [] : ungroupedEntries)
        }
    }

    /// Anywhere above Inactive.
    func isActive(_ projectID: UUID) -> Bool {
        section(of: projectID) != .inactive
    }

    /// Notes when a project comes into Active from outside it, so it takes
    /// its place there once and then stays put.
    private func noteArrival(_ id: UUID, at date: Date) {
        let wasActive: Bool = {
            guard let used = lastUsed[id], Date.now.timeIntervalSince(used) < sidebarTimes.active else { return false }
            if let gone = dismissed[id], gone >= used { return false }
            return true
        }()
        if !wasActive || activeSince[id] == nil { activeSince[id] = date }
    }

    func isActive(host: String, projectID: UUID) -> Bool {
        pins.contains { $0.host == host && $0.projectID == projectID }
    }

    func isPinned(_ projectID: UUID) -> Bool {
        pins.contains { $0.host == nil && $0.projectID == rootID(of: projectID) }
    }

    /// This Mac's projects under Inactive, by name. None with custom
    /// groups, where every project is in a group or Ungrouped.
    var inactiveProjects: [Project] {
        guard grouping == .activity else { return [] }
        return topLevelProjects.filter { section(of: $0.id) == .inactive }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Notes that you used a project (or one of its worktrees) at a time,
    /// which brings it into Active, or to the top of it.
    func noteUse(_ projectID: UUID, at date: Date = .now) {
        let id = rootID(of: projectID)
        guard project(id) != nil, date > (lastUsed[id] ?? .distantPast) else { return }
        noteArrival(id, at: min(date, .now))
        lastUsed[id] = min(date, .now)
        syncProjectOrder()
        save()
    }

    /// Takes in when you last worked in each project, from Claude Code's
    /// history, without moving anything you've used since.
    func noteHistory(_ dates: [UUID: Date]) {
        var changed = false
        for (projectID, date) in dates {
            let id = rootID(of: projectID)
            guard project(id) != nil, date > (lastUsed[id] ?? .distantPast) else { continue }
            noteArrival(id, at: min(date, .now))
            lastUsed[id] = min(date, .now)
            changed = true
        }
        guard changed else { return }
        syncProjectOrder()
        save()
    }

    /// Make Active brings a project back as if you'd just used it; Move to
    /// Inactive puts it away (unpinning it) until you use it again.
    func setActive(_ projectID: UUID, _ isOn: Bool) {
        let id = rootID(of: projectID)
        if isOn {
            dismissed[id] = nil
            lastUsed[id] = .now
            activeSince[id] = .now
        } else {
            pins.removeAll { $0.host == nil && $0.projectID == id }
            dismissed[id] = .now
        }
        syncProjectOrder()
        save()
        if !isOn { closeInactiveTabs(includingSelected: true) }
    }

    /// Closes the tabs of projects in Inactive, and of their worktrees, so
    /// coming back to one shows the New Tab page and its recent sessions
    /// instead of tabs from days ago. Tabs where closing would cut off work
    /// stay. So does the project on screen, unless `includingSelected`.
    /// Nothing closes when that's turned off in Settings.
    func closeInactiveTabs(includingSelected: Bool = false) {
        guard closesInactiveTabs else { return }
        let onScreen = includingSelected ? nil : selectedProjectID.map(rootID(of:))
        var changed = false
        for index in projects.indices where !projects[index].tabs.isEmpty {
            let project = projects[index]
            let root = rootID(of: project.id)
            guard root != onScreen, section(of: root) == .inactive else { continue }
            // A project you've put in a group stays as you left it.
            if grouping == .custom, groupID(of: ActiveEntry(projectID: root).id) != nil { continue }
            let kept = project.tabs.filter { tabIsWorking($0.id) }
            guard kept.count < project.tabs.count else { continue }
            projects[index].tabs = kept
            projects[index].pruneSplits()
            if !kept.contains(where: { $0.id == project.selectedTabID }) {
                projects[index].selectedTabID = kept.first?.id
            }
            startPages[project.id] = nil
            changed = true
        }
        if changed { save() }
    }

    /// Names a project in the sidebar. An empty name, or the folder's own,
    /// goes back to showing the folder name. Its worktrees follow along.
    func renameProject(_ projectID: UUID, to newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }), !projects[index].isWorktree else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = trimmed.isEmpty || trimmed == projects[index].folderName ? nil : trimmed
        guard projects[index].customName != custom else { return }
        projects[index].customName = custom
        let name = projects[index].name
        for i in projects.indices where projects[i].parentID == projectID {
            projects[i].parentName = name
        }
        save()
    }

    /// Pins a project to the top of Active, or unpins it (it stays in
    /// Active while you've used it lately).
    func setPinned(_ projectID: UUID, _ isOn: Bool) {
        let id = rootID(of: projectID)
        if isOn {
            guard !isPinned(id) else { return }
            dismissed[id] = nil
            pins.append(ActiveEntry(projectID: id))
        } else {
            pins.removeAll { $0.host == nil && $0.projectID == id }
        }
        syncProjectOrder()
        save()
    }

    /// Adds a project on a paired Mac to Active here, pinned.
    func addToActive(host: String, projectID: UUID, name: String) {
        guard !isActive(host: host, projectID: projectID) else { return }
        pins.append(ActiveEntry(projectID: projectID, host: host, name: name))
        save()
    }

    func removeFromActive(host: String, projectID: UUID) {
        pins.removeAll { $0.host == host && $0.projectID == projectID }
        removeFromGroups(ActiveEntry(projectID: projectID, host: host).id)
        if selectedRemote == RemoteSelection(host: host, projectID: projectID), sidebarHost == nil {
            selectedRemote = nil
        }
        save()
    }

    /// Forgets every pinned project from a Mac that's no longer paired.
    func removeFromActive(host: String) {
        let inGroups = groups.contains { $0.entries.contains { $0.host == host } }
        guard inGroups || pins.contains(where: { $0.host == host }) else { return }
        pins.removeAll { $0.host == host }
        for index in groups.indices { groups[index].entries.removeAll { $0.host == host } }
        save()
    }

    /// Keeps a pinned project's name current, for when its Mac is away.
    func rememberName(_ name: String, host: String, projectID: UUID) {
        guard let index = pins.firstIndex(where: { $0.host == host && $0.projectID == projectID }),
              pins[index].name != name else { return }
        pins[index].name = name
        save()
    }

    func isPinned(entryID: String) -> Bool {
        pins.contains { $0.id == entryID }
    }

    /// Moves a pinned entry to where another pinned one is, as a dragged
    /// row passes over it. The rest of Active orders itself.
    func moveActive(_ entryID: String, over targetID: String) {
        guard entryID != targetID,
              let from = pins.firstIndex(where: { $0.id == entryID }),
              let to = pins.firstIndex(where: { $0.id == targetID }) else { return }
        pins.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        syncProjectOrder()
        save()
    }

    // MARK: Custom groups

    /// This Mac's projects that aren't in a group, by name, then other
    /// Macs' projects you've added here that aren't in one either.
    var ungroupedEntries: [ActiveEntry] {
        let grouped = Set(groups.flatMap(\.entries).map(\.id))
        let local = topLevelProjects
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { ActiveEntry(projectID: $0.id) }
        let remote = pins.filter { $0.host != nil }
        return (local + remote).filter { !grouped.contains($0.id) }
    }

    /// The group a row is in, by its entry id.
    func groupID(of entryID: String) -> UUID? {
        groups.first { $0.entries.contains { $0.id == entryID } }?.id
    }

    /// The entry for one of this Mac's projects, or a worktree's project.
    func entry(for projectID: UUID) -> ActiveEntry {
        ActiveEntry(projectID: rootID(of: projectID))
    }

    /// Makes a group, optionally starting it with a project, and returns it.
    @discardableResult
    func createGroup(named name: String, with entry: ActiveEntry? = nil) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = ProjectGroup(name: trimmed.isEmpty ? "New Group" : trimmed)
        groups.append(group)
        if let entry { move(entry, toGroup: group.id) } else { save() }
        return group.id
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }),
              groups[index].name != trimmed else { return }
        groups[index].name = trimmed
        save()
    }

    /// Deletes a group. Its projects go back to Ungrouped.
    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        syncProjectOrder()
        save()
    }

    func setGroupCollapsed(_ id: UUID, _ isCollapsed: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }),
              groups[index].isCollapsed != isCollapsed else { return }
        groups[index].isCollapsed = isCollapsed
        save()
    }

    /// Moves a group one place up (-1) or down (1).
    func moveGroup(_ id: UUID, by offset: Int) {
        guard let from = groups.firstIndex(where: { $0.id == id }),
              groups.indices.contains(from + offset) else { return }
        groups.swapAt(from, from + offset)
        syncProjectOrder()
        save()
    }

    /// Puts a row at the end of a group, or back in Ungrouped with nil.
    func move(_ entry: ActiveEntry, toGroup groupID: UUID?) {
        removeFromGroups(entry.id, saving: false)
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].entries.append(entry)
            groups[index].isCollapsed = false
        }
        syncProjectOrder()
        save()
    }

    /// Moves a dragged row to where another row is, as it passes over it.
    /// Over an ungrouped row, it leaves its group.
    func moveGrouped(_ entryID: String, over targetID: String) {
        guard entryID != targetID, let entry = listedEntries.first(where: { $0.id == entryID }) else { return }
        guard let target = groupID(of: targetID) else {
            if groupID(of: entryID) != nil { move(entry, toGroup: nil) }
            return
        }
        removeFromGroups(entryID, saving: false)
        guard let index = groups.firstIndex(where: { $0.id == target }) else { return }
        let at = groups[index].entries.firstIndex { $0.id == targetID } ?? groups[index].entries.endIndex
        groups[index].entries.insert(entry, at: at)
        syncProjectOrder()
        save()
    }

    private func removeFromGroups(_ entryID: String, saving: Bool = true) {
        guard groupID(of: entryID) != nil else { return }
        for index in groups.indices { groups[index].entries.removeAll { $0.id == entryID } }
        if saving { save() }
    }

    /// Keeps the saved project order (the one the phone shows) in step with
    /// the sidebar: Active, then the rest by name.
    private func syncProjectOrder() {
        let order = listedEntries.filter { $0.host == nil }.map(\.projectID) + inactiveProjects.map(\.id)
        reorderTopLevel(order)
    }

    /// Reads when you last worked in each project from Claude Code's own
    /// history, so work outside Bench (or before it) counts too. Then does
    /// it again every few minutes, which also lets projects leave Active
    /// when their time is up while Bench sits open.
    func startClock() {
        guard clock == nil else { return }
        // Before any terminal starts, so a project that went inactive while
        // Workbench was closed doesn't resume its old Claude sessions.
        if closesInactiveAtLaunch { closeInactiveTabs(includingSelected: true) }
        readHistory()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = .now
                self.syncProjectOrder()
                self.readHistory()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func readHistory() {
        let paths = projects.map { ($0.id, $0.path) }
        Task.detached(priority: .utility) { [weak self] in
            var newest: [UUID: Date] = [:]
            for (id, path) in paths {
                let files = SessionHistory.files(forProject: path).map(\.file)
                // A file's modified date isn't enough: resuming a session
                // (as every Claude tab does when Workbench opens) writes to
                // it without anyone doing anything. So look inside the few
                // most recently changed for the last real message.
                let recent = files
                    .compactMap { url in
                        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) }
                    }
                    .sorted { $0.1 > $1.1 }
                    .prefix(3)
                if let date = recent.compactMap({ TranscriptTimes.lastMessage(in: $0.0, modified: $0.1) }).max() {
                    newest[id] = date
                }
            }
            await MainActor.run {
                self?.noteHistory(newest)
                self?.closeInactiveTabs()
            }
        }
    }

    /// Where the command bar goes for a project on this Mac: into the
    /// session it already has, or a new Claude tab when it has none. Either
    /// way it counts as using the project, which brings an inactive one back
    /// into Active.
    func openFromCommandBar(_ projectID: UUID) {
        guard let project = project(projectID) else { return }
        showsHistory = false
        selectedProjectID = projectID
        if let tab = project.selectedTab {
            selectTab(tab.id, in: projectID)
            noteUse(projectID)
        } else {
            addTab(.agent, to: projectID)
        }
    }

    /// The agent worktrees branched from a project, oldest first.
    func worktrees(of projectID: UUID) -> [Project] {
        projects.filter { $0.parentID == projectID }
    }

    /// Whether a worktree's pull request is merged and it's waiting to be
    /// cleaned up, with Claude not busy there. Set by the cleaner.
    @ObservationIgnored var isMergedAndIdle: (UUID) -> Bool = { _ in false }
    /// Projects whose merged worktrees are shown in full instead of folded
    /// into one line. Only for as long as Workbench is open.
    var expandedMerged: Set<UUID> = []

    /// A project's worktrees as the sidebar lists them. Two or more merged
    /// ones with nothing going on fold into a single "N merged" line, so
    /// finished agents don't crowd out the ones still working. The
    /// worktree on screen is never folded away.
    struct SidebarWorktrees {
        /// Rows in order, above the merged line and (when expanded) below it.
        var listed: [Project]
        /// The merged worktrees the line stands for. Empty when there's no line.
        var merged: [Project]
        var isFolded: Bool
    }

    func sidebarWorktrees(of projectID: UUID) -> SidebarWorktrees {
        let all = worktrees(of: projectID)
        let merged = all.filter { isMergedAndIdle($0.id) && $0.id != selectedProjectID }
        guard merged.count >= 2 else { return SidebarWorktrees(listed: all, merged: [], isFolded: false) }
        let others = all.filter { worktree in !merged.contains { $0.id == worktree.id } }
        let folded = !expandedMerged.contains(projectID)
        return SidebarWorktrees(listed: folded ? others : others + merged, merged: merged, isFolded: folded)
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// The name of a project, or for an agent's worktree, its project's.
    func rootName(of project: Project) -> String {
        project.parentID.flatMap { self.project($0) }?.name ?? project.parentName ?? project.name
    }

    /// The top-level project for a project or one of its worktrees.
    func rootID(of projectID: UUID) -> UUID {
        project(projectID)?.parentID ?? projectID
    }

    var allTabIDs: Set<UUID> {
        Set(projects.flatMap { $0.tabs.map(\.id) })
    }

    private let fileURL: URL

    /// Called when a project's worktrees are worth looking up right away.
    @ObservationIgnored var onWorktreeLookNeeded: (() -> Void)?

    init(fileURL: URL = AppStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultFileURL: URL {
        BenchPaths.support.appendingPathComponent("state.json")
    }

    // MARK: Projects

    /// Adds folders as projects and selects the last one.
    /// Adds folders as projects and selects the last one. `opensClaude`
    /// starts each new project with a Claude tab; without it, a project
    /// opens on its start page.
    func addProjects(_ urls: [URL], opensClaude: Bool = true, source: ProjectSource) {
        var lastAdded: UUID?
        for url in urls {
            switch addProject(path: url.path, opensClaude: opensClaude, source: source) {
            case .added(let project), .alreadyHere(let project): lastAdded = project.id
            case .notAFolder: break
            }
        }
        if let lastAdded { selectedProjectID = lastAdded }
    }

    /// How a project was added, for analytics.
    enum ProjectSource: String {
        case welcome, drop, folderPicker = "folder_picker", benchCommand = "bench_command", otherMac = "other_mac"
    }

    enum AddOutcome {
        case added(Project)
        case alreadyHere(Project)
        case notAFolder
    }

    /// Adds one folder as a project, with a Claude tab, without changing
    /// what's selected.
    @discardableResult
    func addProject(path: String, opensClaude: Bool = true, source: ProjectSource) -> AddOutcome {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return .notAFolder }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == standardized }) { return .alreadyHere(existing) }
        var project = Project(path: standardized)
        if opensClaude {
            let tab = Self.claudeTab()
            project.tabs = [tab]
            project.selectedTabID = tab.id
        }
        projects.append(project)
        lastUsed[project.id] = .now
        activeSince[project.id] = .now
        syncProjectOrder()
        save()
        Analytics.capture(.projectAdded, ["source": source.rawValue])
        onWorktreeLookNeeded?()
        return .added(project)
    }

    /// Removes a project from Bench, along with its worktrees. Nothing on
    /// disk changes.
    func removeProject(_ id: UUID) {
        let parentID = project(id)?.parentID
        projects.removeAll { $0.id == id || $0.parentID == id }
        pins.removeAll { $0.host == nil && $0.projectID == id }
        removeFromGroups(ActiveEntry(projectID: id).id)
        if parentID == nil { setNotifiesPhone(id, false) }
        lastUsed[id] = nil
        dismissed[id] = nil
        activeSince[id] = nil
        if let selectedProjectID, project(selectedProjectID) == nil {
            self.selectedProjectID = parentID ?? listedEntries.first { $0.host == nil }?.projectID ?? topLevelProjects.first?.id
        }
        save()
    }

    // MARK: Worktrees

    /// Adds an agent's worktree under its project, with a Claude tab that
    /// starts on `prompt`, and selects it unless `select` is false. A setup
    /// command gets its own shell tab so you can watch it run.
    @discardableResult
    func addWorktree(parent: Project, path: String, branch: String, base: String?, prompt: String?, setupCommand: String?,
                     select: Bool = true, agent: AgentID? = nil) -> UUID {
        // A look through git can land while the new worktree is being
        // made, and would have listed it as someone else's.
        let resolvedPath = WorktreeList.resolved(path)
        if let early = projects.first(where: { $0.isExternalWorktree && WorktreeList.resolved($0.path) == resolvedPath }) {
            removeProject(early.id)
        }
        var worktree = Project(path: path)
        worktree.parentID = parent.id
        worktree.parentName = parent.name
        worktree.branch = branch
        worktree.baseRef = base
        var claude = Self.claudeTab(prompt: prompt, agent: agent)
        let account = claudeAccountID(for: parent.id)
        claude.claudeAccountID = account
        let codexAccount = codexAccountID(for: parent.id)
        claude.codexAccountID = codexAccount
        worktree.tabs = [claude]
        if let setupCommand, !setupCommand.isEmpty {
            var setup = TabRecord(kind: .shell, command: setupCommand)
            setup.claudeAccountID = account
            setup.codexAccountID = codexAccount
            worktree.tabs.append(setup)
        }
        worktree.selectedTabID = claude.id
        insert(worktree, under: parent.id)
        if select { selectedProjectID = worktree.id }
        save()
        noteUse(parent.id)
        return worktree.id
    }

    /// Keeps a project's worktrees together, right after it.
    private func insert(_ worktree: Project, under parentID: UUID) {
        let after = projects.lastIndex { $0.id == parentID || $0.parentID == parentID } ?? projects.endIndex - 1
        projects.insert(worktree, at: after + 1)
    }

    /// Brings a project's worktrees in line with what git lists. Ones you
    /// made yourself are added with no tabs, so nothing starts until you
    /// open them. Ones that have since gone away are dropped, unless they
    /// still have tabs open.
    func syncWorktrees(of parentID: UUID, listed: [WorktreeList.Entry]) {
        guard let parentIndex = projects.firstIndex(where: { $0.id == parentID && !$0.isWorktree }),
              WorktreeList.isMainWorktree(projects[parentIndex].path, of: listed) else { return }
        let fileManager = FileManager.default
        let byPath = Dictionary(listed.map { (WorktreeList.resolved($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false

        // Forget hidden worktrees that are gone, so one made later in the
        // same place shows up.
        let hidden = projects[parentIndex].hiddenWorktrees ?? []
        let stillThere = hidden.filter { byPath[WorktreeList.resolved($0)] != nil }
        if stillThere != hidden {
            projects[parentIndex].hiddenWorktrees = stillThere.isEmpty ? nil : stillThere
            changed = true
        }

        for worktree in worktrees(of: parentID) where worktree.isExternalWorktree {
            let entry = byPath[WorktreeList.resolved(worktree.path)]
            if entry == nil || !fileManager.fileExists(atPath: worktree.path) {
                if worktree.tabs.isEmpty { removeProject(worktree.id) }
            } else if entry?.branch != worktree.branch, let index = projects.firstIndex(where: { $0.id == worktree.id }) {
                projects[index].branch = entry?.branch
                changed = true
            }
        }

        guard let parent = project(parentID) else { return }
        let found = WorktreeList.importable(listed, known: Set(projects.map(\.path)), hidden: Set(parent.hiddenWorktrees ?? []))
        for entry in found where fileManager.fileExists(atPath: entry.path) {
            var worktree = Project(path: entry.path)
            worktree.parentID = parent.id
            worktree.parentName = parent.name
            worktree.branch = entry.branch
            worktree.madeOutsideWorkbench = true
            insert(worktree, under: parent.id)
            changed = true
        }
        if changed { save() }
    }

    /// Takes a worktree made outside Workbench out of the sidebar and keeps
    /// it out. Its folder and branch stay as they are.
    func hideExternalWorktree(_ id: UUID) {
        guard let worktree = project(id), worktree.isExternalWorktree, let parentID = worktree.parentID,
              let index = projects.firstIndex(where: { $0.id == parentID }) else { return }
        projects[index].hiddenWorktrees = (projects[index].hiddenWorktrees ?? []) + [worktree.path]
        removeProject(id)
    }

    /// Lets the worktrees hidden from a project come back on the next look.
    func showHiddenWorktrees(of projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].hiddenWorktrees = nil
        save()
        onWorktreeLookNeeded?()
    }

    func setWorktreeSetup(files: [String], command: String?, for projectID: UUID) {
        update(projectID) {
            $0.setupFiles = files
            $0.setupCommand = command
        }
    }

    /// Puts the top-level projects in this order, each followed by its
    /// worktrees. Anything not named keeps its place at the end.
    func setTopLevelOrder(_ ids: [UUID]) {
        // An older phone drags projects into order. Only pinned projects
        // keep an order of their own, so that's the part it can change.
        let slots = pins.indices.filter { pins[$0].host == nil }
        let reordered = ids.filter { isPinned($0) }
        if reordered.count == slots.count {
            for (slot, id) in zip(slots, reordered) { pins[slot] = ActiveEntry(projectID: id) }
        }
        syncProjectOrder()
        save()
    }

    /// Puts the top-level projects in this order, each followed by its
    /// worktrees. Anything not named keeps its place at the end.
    private func reorderTopLevel(_ ids: [UUID]) {
        var ordered: [Project] = []
        for id in ids {
            guard let project = projects.first(where: { $0.id == id && !$0.isWorktree }) else { continue }
            ordered.append(project)
            ordered.append(contentsOf: projects.filter { $0.parentID == id })
        }
        let placed = Set(ordered.map(\.id))
        ordered.append(contentsOf: projects.filter { !placed.contains($0.id) })
        guard ordered.map(\.id) != projects.map(\.id) else { return }
        projects = ordered
    }

    func setBaseRef(_ ref: String?, for projectID: UUID) {
        update(projectID) { $0.baseRef = ref }
    }

    // MARK: Claude accounts

    /// The account new Claude tabs in a project use: its own choice, then
    /// its parent project's for a worktree, then the main account.
    func claudeAccountID(for projectID: UUID) -> UUID {
        let accounts = ClaudeAccounts.shared
        guard let project = project(projectID) else { return ClaudeProfile.mainID }
        let chosen = project.claudeAccountID ?? project.parentID.flatMap { self.project($0)?.claudeAccountID }
        return accounts.profile(chosen).id
    }

    /// Picks the account a project's new Claude tabs use. Tabs already open
    /// keep theirs. A worktree set to its project's account goes back to
    /// following it.
    func setClaudeAccount(_ accountID: UUID, for projectID: UUID) {
        guard let project = project(projectID) else { return }
        let inherited = project.parentID.map { claudeAccountID(for: $0) } ?? ClaudeProfile.mainID
        let value: UUID? = accountID == inherited ? nil : accountID
        guard project.claudeAccountID != value else { return }
        update(projectID) { $0.claudeAccountID = value }
        Analytics.capture(.claudeAccountChosen, ["main": accountID == ClaudeProfile.mainID])
    }

    /// Projects (not worktrees) that use an account.
    func projects(using accountID: UUID) -> [Project] {
        topLevelProjects.filter { claudeAccountID(for: $0.id) == accountID }
    }

    // MARK: Codex accounts

    /// The account new Codex tabs in a project use, chosen the same way as
    /// its Claude account.
    func codexAccountID(for projectID: UUID) -> UUID {
        let accounts = CodexAccounts.shared
        guard let project = project(projectID) else { return CodexProfile.mainID }
        let chosen = project.codexAccountID ?? project.parentID.flatMap { self.project($0)?.codexAccountID }
        return accounts.profile(chosen).id
    }

    /// Picks the account a project's new Codex tabs use. Tabs already open
    /// keep theirs.
    func setCodexAccount(_ accountID: UUID, for projectID: UUID) {
        guard let project = project(projectID) else { return }
        let inherited = project.parentID.map { codexAccountID(for: $0) } ?? CodexProfile.mainID
        let value: UUID? = accountID == inherited ? nil : accountID
        guard project.codexAccountID != value else { return }
        update(projectID) { $0.codexAccountID = value }
    }

    /// Projects (not worktrees) whose Codex tabs use an account.
    func projects(usingCodexAccount accountID: UUID) -> [Project] {
        topLevelProjects.filter { codexAccountID(for: $0.id) == accountID }
    }

    // MARK: Tabs

    @discardableResult
    func addTab(_ kind: TabKind, to projectID: UUID, prompt: String? = nil, command: String? = nil, resuming sessionID: String? = nil, title: String? = nil,
                account: UUID? = nil, agent: AgentID? = nil, fromPhone: Bool = false) -> TabRecord? {
        startPages[projectID] = nil
        // A past session picks up with the agent it was with.
        let past = sessionID.flatMap { id in project(projectID).flatMap { SessionHistory.agent(ofSession: id, projectPath: $0.path) } }
        var tab = TabRecord(kind: kind, agent: agent ?? past, initialPrompt: prompt, command: command)
        tab.resumeSessionID = sessionID
        if tab.isTerminal {
            // A past session resumes with the account it ran under.
            let owner = sessionID.flatMap { id in project(projectID).flatMap { SessionHistory.account(ofSession: id, projectPath: $0.path) } }
            tab.claudeAccountID = account ?? owner ?? claudeAccountID(for: projectID)
            let codexOwner = sessionID.flatMap { id in project(projectID).flatMap { SessionHistory.codexAccount(ofSession: id, projectPath: $0.path) } }
            tab.codexAccountID = codexOwner ?? codexAccountID(for: projectID)
        }
        if kind == .agent { tab.showsChat = Self.newClaudeTabsShowChat ? true : nil }
        if let title { tab.title = title }
        update(projectID) {
            $0.tabs.append(tab)
            $0.selectedTabID = tab.id
        }
        noteUse(projectID)
        if kind == .agent {
            Analytics.capture(.claudeTabOpened, [
                "agent": (tab.agent ?? .claude).rawValue,
                "view": tab.showsChat == true ? "chat" : "terminal",
                "resumed": sessionID != nil,
                "has_prompt": prompt?.isEmpty == false,
                "from_phone": fromPhone,
            ])
        }
        return tab
    }

    /// Shows a changed file in a tab: the one already showing it, or a new
    /// tab right after the current one.
    /// Shows a changed file's diff: in the tab already showing it, or else
    /// in the project's preview tab, which the next diff replaces. `keep`
    /// makes it a tab of its own that stays.
    func openDiff(_ change: FileChange, in projectID: UUID, keep: Bool = false) {
        update(projectID) { project in
            if let index = project.tabs.firstIndex(where: { $0.diff?.id == change.id }) {
                if keep { project.tabs[index].isPreview = false }
                project.selectedTabID = project.tabs[index].id
                return
            }
            var tab = TabRecord(diff: change)
            tab.isPreview = !keep
            // Reuse the preview tab, unless it's half of a split.
            if !keep, let index = project.tabs.firstIndex(where: { $0.isPreview && project.split(of: $0.id) == nil }) {
                project.tabs[index] = tab
                project.selectedTabID = tab.id
                return
            }
            let current = project.tabs.firstIndex { $0.id == project.selectedTab?.id }
            project.tabs.insert(tab, at: current.map { $0 + 1 } ?? project.tabs.endIndex)
            project.selectedTabID = tab.id
        }
    }

    /// Turns a preview tab into one that stays.
    func keepTab(_ tabID: UUID, in projectID: UUID) {
        update(projectID) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            project.tabs[index].isPreview = false
        }
    }

    /// Keeps the preview tab showing this change, if it's the preview.
    func keepDiff(_ changeID: String, in projectID: UUID) {
        guard let tab = project(projectID)?.tabs.first(where: { $0.diff?.id == changeID && $0.isPreview }) else { return }
        keepTab(tab.id, in: projectID)
    }

    /// Shows a commit, or the branch's whole change set, in a review tab:
    /// the one already showing it, or a new tab right after the current one.
    func openReview(_ target: ReviewTarget, in projectID: UUID) {
        update(projectID) { project in
            if let existing = project.tabs.first(where: { $0.review?.commit == target.commit && $0.review?.turn == target.turn && $0.kind == .review }) {
                project.selectedTabID = existing.id
                return
            }
            let tab = TabRecord(review: target)
            let current = project.tabs.firstIndex { $0.id == project.selectedTab?.id }
            project.tabs.insert(tab, at: current.map { $0 + 1 } ?? project.tabs.endIndex)
            project.selectedTabID = tab.id
        }
    }

    /// Shows what a turn changed in a review tab, scrolled to `file`
    /// (its full path) when one is given.
    func openTurnReview(_ target: ReviewTarget, file: String? = nil, in projectID: UUID) {
        openReview(target, in: projectID)
        guard let file, let tab = project(projectID)?.selectedTab, tab.kind == .review else { return }
        reviewReveal = ReviewReveal(tabID: tab.id, path: file, id: (reviewReveal?.id ?? 0) + 1)
    }

    /// Points a review tab at something else, in place: the switch between
    /// the latest turn and the whole branch.
    func showReview(_ target: ReviewTarget, inTab tabID: UUID, of projectID: UUID) {
        update(projectID) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID && $0.kind == .review }) else { return }
            project.tabs[index].review = target
            project.tabs[index].title = target.title
        }
    }

    /// Turns a tab into the diff of `change`, in place: the Changes side
    /// of a file tab's switch, or the next file when stepping through changes.
    func showChanges(_ change: FileChange, inTab tabID: UUID, of projectID: UUID) {
        update(projectID) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            project.tabs[index].kind = .diff
            project.tabs[index].diff = change
            project.tabs[index].filePath = nil
            project.tabs[index].title = change.fileName
        }
    }

    /// Turns a tab into a file's view, in place: the File side of a diff
    /// tab's switch.
    func showFile(_ path: String, inTab tabID: UUID, of projectID: UUID) {
        update(projectID) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            project.tabs[index].kind = .file
            project.tabs[index].filePath = path
            project.tabs[index].diff = nil
            project.tabs[index].title = (path as NSString).lastPathComponent
        }
    }

    /// Shows a project file in a tab: the one already showing it, or a new
    /// tab right after the current one.
    func openFile(_ path: String, in projectID: UUID) {
        update(projectID) { project in
            if let existing = project.tabs.first(where: { $0.kind == .file && $0.filePath == path }) {
                project.selectedTabID = existing.id
                return
            }
            let tab = TabRecord(filePath: path)
            let current = project.tabs.firstIndex { $0.id == project.selectedTab?.id }
            project.tabs.insert(tab, at: current.map { $0 + 1 } ?? project.tabs.endIndex)
            project.selectedTabID = tab.id
        }
    }

    /// Shows a web page in a browser tab, right after the current one. A
    /// local server already open in a tab comes forward instead, whatever
    /// page of it that tab is on; any other address needs an exact match.
    func openPreview(_ url: URL, in projectID: UUID) {
        update(projectID) { project in
            let isServer = url.host().map(BrowserAddress.isLocal) ?? false
            let existing = project.tabs.first { tab in
                guard tab.kind == .preview, let open = tab.pageURL ?? tab.previewURL else { return false }
                return isServer ? open.port == url.port && open.host() == url.host() : open == url
            }
            if let existing {
                project.selectedTabID = existing.id
                return
            }
            let tab = TabRecord(previewURL: url)
            let current = project.tabs.firstIndex { $0.id == project.selectedTab?.id }
            project.tabs.insert(tab, at: current.map { $0 + 1 } ?? project.tabs.endIndex)
            project.selectedTabID = tab.id
        }
        selectedProjectID = projectID
    }

    /// A new browser tab: empty, ready for an address, or on a page a
    /// link asked to open on its own. It goes after `tabID` (the tab the
    /// link was in), or after the current tab.
    @discardableResult
    func openBrowserTab(_ url: URL? = nil, in projectID: UUID, after tabID: UUID? = nil) -> UUID? {
        guard let project = project(projectID) else { return nil }
        startPages[projectID] = nil
        let tab = TabRecord(browsing: url)
        update(projectID) { project in
            // After the tab, or after its pair so the pair stays together.
            let anchor = (tabID ?? project.selectedTab?.id).map { project.split(of: $0)?.second ?? $0 }
            let index = project.tabs.firstIndex { $0.id == anchor }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(tab, at: index)
            project.selectedTabID = tab.id
        }
        noteUse(project.id)
        return tab.id
    }

    /// The project a tab is in.
    func projectID(ofTab tabID: UUID) -> UUID? {
        projects.first { $0.tabs.contains { $0.id == tabID } }?.id
    }

    /// Keeps a browser tab's record in step with its page: where it is
    /// now, and what it's called.
    func notePage(url: URL?, title: String?, tab tabID: UUID, in projectID: UUID) {
        guard let tab = project(projectID)?.tabs.first(where: { $0.id == tabID }), tab.kind == .preview else { return }
        let title = title.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        guard tab.pageURL != url || tab.title != title else { return }
        update(projectID) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            project.tabs[index].pageURL = url
            project.tabs[index].title = title
        }
    }

    /// Shows one of Claude's published pages in a tab of its own, right
    /// after the current one, or brings it forward if it's already open.
    /// Split it beside the chat from the tab's menu to read both at once.
    func openArtifact(_ url: URL, title: String?, in projectID: UUID) {
        guard let project = project(projectID) else { return }
        startPages[projectID] = nil
        selectedProjectID = projectID
        if let existing = project.tabs.first(where: { $0.kind == .preview && ($0.pageURL ?? $0.previewURL) == url }) {
            selectTab(existing.id, in: projectID)
            return
        }
        var page = TabRecord(previewURL: url)
        if let title, !title.isEmpty { page.title = title } else { page.title = "Artifact" }
        update(projectID) { project in
            // After the current tab, or after its pair so the pair stays together.
            let anchor = project.selectedTab.map { project.split(of: $0.id)?.second ?? $0.id }
            let index = project.tabs.firstIndex { $0.id == anchor }.map { $0 + 1 } ?? project.tabs.endIndex
            project.tabs.insert(page, at: index)
            project.selectedTabID = page.id
        }
        noteUse(projectID)
    }

    /// The file shown by the selected project's current tab, if it's a diff.
    var selectedDiff: FileChange? { selectedProject?.selectedTab?.diff }

    func closeTab(_ tabID: UUID, in projectID: UUID) {
        update(projectID) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            // Closing one side of a split leaves the other side in front.
            let partner = project.partner(of: tabID)
            project.tabs.remove(at: index)
            if project.selectedTabID == tabID || project.selectedTabID == nil {
                if let partner {
                    project.selectedTabID = partner
                } else {
                    let next = min(index, project.tabs.count - 1)
                    project.selectedTabID = next >= 0 ? project.tabs[next].id : nil
                }
            }
        }
    }

    func selectTab(_ tabID: UUID, in projectID: UUID) {
        startPages[projectID] = nil
        update(projectID) { $0.selectedTabID = tabID }
    }

    /// Moves a tab (or a split pair) to where another one is in the tab
    /// bar, as a drag passes over it.
    func moveTab(_ tabID: UUID, over targetID: UUID, in projectID: UUID) {
        guard tabID != targetID else { return }
        update(projectID) { $0.moveStop(tabID, over: targetID) }
    }

    // MARK: Splits

    /// Whether the selected project's current tab can get a new shell
    /// beside it: a terminal tab that isn't split already.
    var canSplitSelectedTab: Bool {
        guard let project = selectedProject, !showsStartPage(project), let tab = project.selectedTab else { return false }
        return tab.isTerminal && project.split(of: tab.id) == nil
    }

    /// Opens a new shell beside a terminal tab and switches to it.
    @discardableResult
    func splitTab(_ tabID: UUID, in projectID: UUID, axis: TabSplit.Axis) -> TabRecord? {
        guard let project = project(projectID), let tab = project.tabs.first(where: { $0.id == tabID }),
              tab.isTerminal, project.split(of: tabID) == nil else { return nil }
        startPages[projectID] = nil
        var shell = TabRecord(kind: .shell)
        shell.claudeAccountID = tab.claudeAccountID ?? claudeAccountID(for: projectID)
        shell.codexAccountID = tab.codexAccountID ?? codexAccountID(for: projectID)
        update(projectID) { project in
            let index = project.tabs.firstIndex { $0.id == tabID } ?? project.tabs.endIndex - 1
            project.tabs.insert(shell, at: index + 1)
            project.splits = (project.splits ?? []) + [TabSplit(first: tabID, second: shell.id, axis: axis)]
            project.selectedTabID = shell.id
        }
        noteUse(projectID)
        Analytics.capture(.tabsSplit, ["axis": axis.rawValue, "with": "new_shell"])
        return shell
    }

    /// Shows `other` beside `tabID`, taking either out of a pair it was in.
    func pairTabs(_ tabID: UUID, with other: UUID, in projectID: UUID, axis: TabSplit.Axis = .sideBySide) {
        guard tabID != other, let project = project(projectID),
              project.tabs.contains(where: { $0.id == tabID && $0.canSplit }),
              project.tabs.contains(where: { $0.id == other && $0.canSplit }) else { return }
        startPages[projectID] = nil
        update(projectID) { project in
            project.splits?.removeAll { [$0.first, $0.second].contains(tabID) || [$0.first, $0.second].contains(other) }
            // Keeps the pair together in the tab order.
            if let from = project.tabs.firstIndex(where: { $0.id == other }) {
                let moved = project.tabs.remove(at: from)
                let to = project.tabs.firstIndex { $0.id == tabID }.map { $0 + 1 } ?? project.tabs.endIndex
                project.tabs.insert(moved, at: to)
            }
            project.splits = (project.splits ?? []) + [TabSplit(first: tabID, second: other, axis: axis)]
            project.selectedTabID = other
        }
        Analytics.capture(.tabsSplit, ["axis": axis.rawValue, "with": "existing_tab"])
    }

    /// Puts both tabs of a tab's pair back on their own.
    func unsplit(_ tabID: UUID, in projectID: UUID) {
        update(projectID) { project in
            project.splits?.removeAll { $0.first == tabID || $0.second == tabID }
        }
    }

    /// Changes a pair's layout, side by side or stacked.
    func setSplitAxis(_ axis: TabSplit.Axis, of tabID: UUID, in projectID: UUID) {
        changeSplit(of: tabID, in: projectID) { $0.axis = axis }
    }

    /// Swaps the two sides of a tab's pair.
    func swapSplit(of tabID: UUID, in projectID: UUID) {
        changeSplit(of: tabID, in: projectID) { split in
            (split.first, split.second) = (split.second, split.first)
            split.fraction = 1 - split.fraction
        }
        update(projectID) { project in
            // The tab order follows, so the pair's button stays put.
            guard let split = project.split(of: tabID),
                  let a = project.tabs.firstIndex(where: { $0.id == split.first }),
                  let b = project.tabs.firstIndex(where: { $0.id == split.second }), a > b else { return }
            project.tabs.swapAt(a, b)
        }
    }

    /// Where the divider sits: the share of space the pair's first tab gets.
    func setSplitFraction(_ fraction: Double, of tabID: UUID, in projectID: UUID) {
        let clamped = min(max(fraction, TabSplit.fractionRange.lowerBound), TabSplit.fractionRange.upperBound)
        changeSplit(of: tabID, in: projectID) { $0.fraction = clamped }
    }

    /// Moves typing to the other side of the current tab's pair.
    func switchPane() {
        guard let project = selectedProject, let tab = project.selectedTab,
              let partner = project.partner(of: tab.id) else { return }
        selectTab(partner, in: project.id)
    }

    /// Called when a pane's terminal takes the keyboard, like when it's
    /// clicked: that side becomes the current tab.
    func focusPane(_ tabID: UUID, in projectID: UUID) {
        guard let project = project(projectID), project.selectedTabID != tabID,
              let selected = project.selectedTab, project.partner(of: selected.id) == tabID else { return }
        update(projectID) { $0.selectedTabID = tabID }
    }

    private func changeSplit(of tabID: UUID, in projectID: UUID, _ change: (inout TabSplit) -> Void) {
        update(projectID) { project in
            guard let index = project.splits?.firstIndex(where: { $0.first == tabID || $0.second == tabID }) else { return }
            change(&project.splits![index])
        }
    }

    // MARK: New Tab page

    /// Shows the start page: always when there are no tabs, and in place of
    /// the selected tab after the + button until a tab is picked or opened.
    func showsStartPage(_ project: Project) -> Bool {
        project.tabs.isEmpty || startPages[project.id] == StartPageMark(selected: project.selectedTab?.id, tabs: project.tabs.map(\.id))
    }

    func openStartPage(_ projectID: UUID) {
        guard let project = project(projectID) else { return }
        startPages[projectID] = StartPageMark(selected: project.selectedTab?.id, tabs: project.tabs.map(\.id))
    }

    func closeStartPage(_ projectID: UUID) {
        startPages[projectID] = nil
    }

    /// Where the setting for showing new Claude tabs as a chat lives.
    static let newTabsShowChatKey = "newClaudeTabsShowChat"
    /// Settings > General: whether new Claude tabs open as a chat.
    static var newClaudeTabsShowChat: Bool { UserDefaults.standard.bool(forKey: newTabsShowChatKey) }

    /// A new Claude tab, shown as a terminal or a chat as Settings says.
    static func claudeTab(prompt: String? = nil, agent: AgentID? = nil) -> TabRecord {
        var tab = TabRecord(kind: .agent, agent: agent, initialPrompt: prompt)
        if newClaudeTabsShowChat { tab.showsChat = true }
        return tab
    }

    /// Shows a Claude tab as a conversation, or as its raw terminal.
    /// Forgets a tab's first prompt and the session it was resuming, once
    /// Claude has started with them, so a relaunch doesn't use them again.
    func clearPendingLaunch(tabID: UUID) {
        guard let project = projects.first(where: { $0.tabs.contains { $0.id == tabID } }),
              let tab = project.tabs.first(where: { $0.id == tabID }),
              tab.initialPrompt != nil || tab.resumeSessionID != nil else { return }
        update(project.id) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            project.tabs[index].initialPrompt = nil
            project.tabs[index].resumeSessionID = nil
        }
    }

    /// `byUser` is false when Bench switches on its own, like falling back
    /// to the terminal when a chat can't be read.
    func setShowsChat(_ showsChat: Bool, tab tabID: UUID, in projectID: UUID, byUser: Bool = true) {
        if byUser { Analytics.capture(.tabViewSwitched, ["to": showsChat ? "chat" : "terminal"]) }
        update(projectID) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            project.tabs[index].showsChat = showsChat ? true : nil
        }
    }

    /// Gives a tab a name of your own. An empty name, or nil, goes back to
    /// the tab's own.
    func renameTab(_ tabID: UUID, in projectID: UUID, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        update(projectID) { project in
            guard let index = project.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let custom = trimmed.isEmpty || trimmed == project.tabs[index].title ? nil : trimmed
            guard project.tabs[index].customTitle != custom else { return }
            project.tabs[index].customTitle = custom
        }
    }


    /// Moves the tab selection by `offset`, wrapping around.
    /// A split counts as one stop.
    func cycleTab(by offset: Int) {
        guard let project = selectedProject else { return }
        let stops = project.tabStops
        guard !stops.isEmpty else { return }
        let current = project.selectedTab.map { project.split(of: $0.id)?.first ?? $0.id }
        let index = stops.firstIndex { $0.id == current } ?? 0
        let next = (index + offset + stops.count) % stops.count
        selectTab(stops[next].id, in: project.id)
    }

    // MARK: Persistence

    private func update(_ projectID: UUID, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let hadTabs = !projects[index].tabs.isEmpty
        change(&projects[index])
        projects[index].pruneSplits()
        // Closing the last tab, or opening the first, moves it within Active.
        if hadTabs == projects[index].tabs.isEmpty { syncProjectOrder() }
        save()
    }

    private struct Saved: Codable {
        var projects: [Project]
        var selectedProjectID: UUID?
        /// The Active list from before Active filled itself from recent
        /// use. Only read, to keep other Macs' projects you'd added.
        var active: [ActiveEntry]?
        var pins: [ActiveEntry]?
        var lastUsed: [UUID: Date]?
        var dismissed: [UUID: Date]?
        var activeSince: [UUID: Date]?
        var groups: [ProjectGroup]?
    }

    /// Where the saved state went when it couldn't be read at launch, so
    /// the window can say so. Nil when the file was fine or didn't exist.
    private(set) var brokenStateFile: URL?

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let saved: Saved
        do {
            saved = try JSONDecoder().decode(Saved.self, from: data)
        } catch {
            // Starting empty is bad enough; writing that emptiness over the
            // real list on the next save would be worse. Keep the file.
            NSLog("Bench: couldn't read saved state: \(error)")
            brokenStateFile = BenchPaths.setAside(fileURL) ?? fileURL
            return
        }
        // Setting the selection saves, and a save before everything is
        // read back would write an empty Active list over the real one.
        isLoading = true
        defer { isLoading = false }
        projects = saved.projects
        for index in projects.indices { projects[index].pruneSplits() }
        let topLevel = Set(topLevelProjects.map(\.id))
        // Coming from the hand-kept Active list, other Macs' projects stay
        // pinned; this Mac's fill in from when you last used them.
        pins = (saved.pins ?? (saved.active ?? []).filter { $0.host != nil })
            .filter { $0.host != nil || topLevel.contains($0.projectID) }
        lastUsed = saved.lastUsed ?? [:]
        dismissed = saved.dismissed ?? [:]
        activeSince = saved.activeSince ?? [:]
        groups = (saved.groups ?? []).map { group in
            var group = group
            group.entries = group.entries.filter { $0.host != nil || topLevel.contains($0.projectID) }
            return group
        }
        if saved.activeSince == nil {
            // Before sections, a relaunch resuming every Claude tab counted
            // as using each project. Forget the last day of that; Claude
            // Code's history fills it back in correctly.
            let dayAgo = Date.now.addingTimeInterval(-24 * 3600)
            lastUsed = lastUsed.filter { $0.value < dayAgo }
            // Which projects are inactive isn't known until then either.
            closesInactiveAtLaunch = false
        }
        selectedProjectID = saved.selectedProjectID ?? projects.first?.id
    }

    @ObservationIgnored private var isLoading = false

    private func save() {
        guard !isLoading else { return }
        let saved = Saved(projects: projects, selectedProjectID: selectedProjectID, pins: pins,
                          lastUsed: lastUsed, dismissed: dismissed, activeSince: activeSince, groups: groups)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Bench: failed to save state: \(error)")
        }
    }
}

/// A project in the sidebar's Active section: one on this Mac, or one on a
/// paired Mac that you've added here.
struct ActiveEntry: Codable, Hashable, Identifiable {
    var projectID: UUID
    /// The paired Mac it's on, or nil for this Mac.
    var host: String?
    /// For another Mac's project: its name, shown while that Mac is away.
    var name: String?

    var id: String { "\(host ?? "")|\(projectID.uuidString)" }
}

/// One of your own named groups of projects in the sidebar.
struct ProjectGroup: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var entries: [ActiveEntry] = []
    var isCollapsed = false
}

/// How the sidebar sorts projects.
enum SidebarGrouping: String, CaseIterable {
    /// Pinned, Active, Recent, and Inactive, from when you used them.
    case activity
    /// Your own named groups, then Ungrouped.
    case custom

    static let key = "sidebarGrouping"

    var title: String {
        switch self {
        case .activity: "By Activity"
        case .custom: "Custom Groups"
        }
    }
}

/// When the last message in a session file was written, from the
/// timestamps on its entries. Remembered per file and modified date, so
/// each file is read again only after it changes.
nonisolated enum TranscriptTimes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [URL: (modified: Date, last: Date?)] = [:]

    static func lastMessage(in url: URL, modified: Date) -> Date? {
        lock.lock()
        if let hit = cache[url], hit.modified == modified { lock.unlock(); return hit.last }
        lock.unlock()
        let last = Agents.transcripts(for: url.path).lastActivity(in: url)
        lock.lock()
        cache[url] = (modified, last)
        lock.unlock()
        return last
    }

}

/// A request for a review tab to scroll to a file, by its full path. A new
/// id each time, so asking for the same file twice scrolls twice.
struct ReviewReveal: Equatable {
    var tabID: UUID
    var path: String
    var id: Int
}
