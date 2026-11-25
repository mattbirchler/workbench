import BenchKit
import SwiftUI

/// Pills across the top of the sidebar: this Mac, then every Mac it's
/// paired with. The sidebar lists the projects on whichever is picked.
struct DevicePills: View {
    @Environment(RemoteMacs.self) private var macs
    @Environment(AppStore.self) private var store
    @State private var showsAddMac = false
    @State private var forgetting: String?
    /// The Mac whose pill is being dragged to a new place in the row.
    @State private var dragging: String?

    var body: some View {
        TitleAreaScrollView {
            HStack(spacing: 6) {
                pill(title: "This Mac", dot: nil, selected: store.sidebarHost == nil) { show(nil) }
                    .help("Projects on this Mac")
                ForEach(macs.macs) { mac in
                    pill(title: macs.name(for: mac.host), dot: dotColor(mac.host), selected: store.sidebarHost == mac.host) {
                        show(mac.host)
                    }
                    .help(helpText(mac.host))
                    .onDrag {
                        dragging = mac.host
                        return NSItemProvider(object: mac.host as NSString)
                    }
                    .onDrop(of: [.text], delegate: MacReorderDelegate(target: mac.host, dragging: $dragging, macs: macs))
                    .contextMenu {
                        Button("Reconnect") { macs.reconnect(host: mac.host) }
                        if macs.macs.count > 1 {
                            Divider()
                            Button("Move Left") { macs.move(host: mac.host, by: -1) }
                                .disabled(mac.host == macs.macs.first?.host)
                            Button("Move Right") { macs.move(host: mac.host, by: 1) }
                                .disabled(mac.host == macs.macs.last?.host)
                        }
                        Divider()
                        Button("Forget \(macs.name(for: mac.host))…", role: .destructive) { forgetting = mac.host }
                    }
                }
                Button {
                    showsAddMac = true
                } label: {
                    Image(systemName: "plus")
                        .font(.ui(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05), in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .foregroundStyle(.secondary)
                .help("Add a Mac running Workbench")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
        .onChange(of: store.selectedRemote) { _, selection in
            if let selection { macs.lastProject[selection.host] = selection.projectID }
        }
        .sheet(isPresented: $showsAddMac) { AddMacSheet() }
        .confirmationDialog("Forget \(forgetting.map { macs.name(for: $0) } ?? "this Mac")?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) {
                guard let host = forgetting else { return }
                if store.sidebarHost == host || store.selectedRemote?.host == host { show(nil) }
                store.removeFromActive(host: host)
                macs.forget(host: host)
            }
        } message: {
            Text("To see its projects again, paste its pairing link again.")
        }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["BENCH_SHOW_ADD_MAC"] != nil { showsAddMac = true } }
        // BENCH_SHOW_FIRST_MAC=1 switches the sidebar to the first other
        // Mac a few seconds after launch, for screenshots.
        .task {
            guard ProcessInfo.processInfo.environment["BENCH_SHOW_FIRST_MAC"] != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            show(macs.macs.first?.host)
        }
        #endif
    }

    private func pill(title: String, dot: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                // Every pill keeps the width of its bold title, so picking
                // one never changes the row's layout. An animated layout
                // change in this sideways scroll view, which reaches under
                // the title bar, made the pills jump up and slide back down.
                ZStack {
                    Text(title).font(.ui(size: 12, weight: .semibold)).hidden()
                    Text(title).font(.ui(size: 12, weight: selected ? .semibold : .medium))
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 24)
            // Only the colors animate, never where the pills sit.
            .animation(.snappy(duration: 0.2)) { content in
                content
                    .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.85))
                    .background(selected ? Color.primary.opacity(0.85) : Color.primary.opacity(0.05), in: Capsule())
                    .overlay(Capsule().strokeBorder(selected ? .clear : Color.primary.opacity(0.1)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Switches the sidebar to a Mac, and the main area to the project you
    /// last had open there (or its first one).
    private func show(_ host: String?) {
        guard let host else {
            store.selectedRemote = nil
            store.sidebarHost = nil
            return
        }
        guard host != store.sidebarHost else { return }
        let projects = macs.client(for: host)?.snapshot?.projects ?? []
        if let id = macs.lastProject[host].flatMap({ id in projects.first { $0.id == id }?.id })
            ?? macs.client(for: host)?.snapshot?.topLevel.first?.id {
            store.selectedRemote = RemoteSelection(host: host, projectID: id)
        }
        store.sidebarHost = host
    }

    private func dotColor(_ host: String) -> Color {
        switch macs.client(for: host)?.status {
        case .connected: ActivityBackground.done
        case .connecting: ActivityBackground.waiting
        default: Color.secondary.opacity(0.5)
        }
    }

    private func helpText(_ host: String) -> String {
        let client = macs.client(for: host)
        switch client?.status {
        case .connected: return "Projects on \(macs.name(for: host))"
        default: return macs.problem(for: host) ?? (client?.status == .connecting ? "Connecting to \(host)" : "Not connected to \(host)")
        }
    }
}

/// The sidebar's list when another Mac is picked: its projects in the
/// same sections as this Mac's. Pinned and Active on the raised tray,
/// Recent in compact rows, and Inactive, dimmed, folding away. Pinned
/// rows drag to change their order on that Mac.
struct RemoteProjectList: View {
    @Environment(RemoteMacs.self) private var macs
    @Environment(AppStore.self) private var store
    let host: String
    /// The ⌘1 to ⌘9 hints, while Command is held.
    var shortcuts: [SidebarShortcuts.Target: Int] = [:]
    @AppStorage("inactiveCollapsed") private var inactiveCollapsed = false
    @State private var dragging: UUID?
    /// The order just dragged into, shown until that Mac's next snapshot
    /// agrees, so rows don't snap back for a second.
    @State private var pendingOrder: [UUID]?
    @State private var showsAddProject = false

    private var client: CompanionClient? { macs.client(for: host) }
    /// Whether that Mac can add a folder as a project for us.
    private var canAdd: Bool { client?.canAddProjects == true && client?.status == .connected }
    private var addHelp: String { "Add a Project on \(macs.name(for: host))" }

    var body: some View {
        ScrollView {
            if let client, let snapshot = client.snapshot {
                let list = ordered(snapshot.topLevel)
                let current = currentSections(list)
                let recent = list.filter { $0.placement == .recent }
                let inactive = list.filter { $0.placement == .inactive }
                // Not lazy, like this Mac's list (see SidebarView): a lazy
                // stack lays the window out again on every scroll step.
                VStack(spacing: 0) {
                    if !current.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(Array(current.enumerated()), id: \.element.title) { index, section in
                                SectionTitle(title: section.title, symbol: section.title == "Pinned" ? "pin.fill" : nil,
                                             addsProject: index == 0 && canAdd, isLoading: index == 0 && isConnecting,
                                             add: { showsAddProject = true }, addHelp: addHelp)
                                rows(section.projects, compact: false, client: client, snapshot: snapshot)
                            }
                        }
                        .sidebarTray()
                    }
                    if !recent.isEmpty {
                        // Inset to line up with the tray's titles and icons above.
                        SectionTitle(title: "Recent", hint: snapshot.recentHint, addsProject: current.isEmpty && canAdd,
                                     isLoading: current.isEmpty && isConnecting,
                                     add: { showsAddProject = true }, addHelp: addHelp)
                            .padding(.horizontal, 10)
                        VStack(spacing: 1) {
                            rows(recent, compact: true, client: client, snapshot: snapshot)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                    }
                    if current.isEmpty && recent.isEmpty {
                        SectionTitle(title: "Projects", addsProject: canAdd, isLoading: isConnecting,
                                     add: { showsAddProject = true }, addHelp: addHelp)
                            .padding(.horizontal, 6)
                        Text(snapshot.projects.isEmpty
                             ? "No projects in Workbench on \(macs.name(for: host))"
                             : "Projects used on \(macs.name(for: host)) in the last day show up here.")
                            .font(.ui(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                    if !inactive.isEmpty {
                        InactiveHeader(count: inactive.count, busiest: busiest(inactive, snapshot: snapshot),
                                       collapsed: $inactiveCollapsed)
                        Fold(isOpen: !inactiveCollapsed) {
                            VStack(spacing: 1) {
                                ForEach(inactive) { project in
                                    block(project, compact: true, client: client, snapshot: snapshot)
                                        // The back catalog: quieter until you pick one.
                                        .opacity(isPicked(project, snapshot: snapshot) ? 1 : 0.6)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 12)
                        }
                    }
                }
                // As on this Mac's list: a row changing state takes its neighbours along.
                .animation(SidebarMotion.rowChange, value: snapshot.projects.map(\.activity))
                .animation(.snappy(duration: 0.2), value: list.map(\.id))
                .animation(.snappy(duration: 0.2), value: list.map(\.placement))
                .animation(.snappy(duration: 0.2), value: inactiveCollapsed)
                .animation(.easeOut(duration: 0.15), value: store.selectedRemote)
            } else {
                status
            }
        }
        .onChange(of: client?.snapshot?.topLevel.map(\.id)) {
            // That Mac's answer to a drag is the next change in order.
            pendingOrder = nil
            selectFirstIfNeeded()
        }
        .onAppear(perform: selectFirstIfNeeded)
        .sheet(isPresented: $showsAddProject) {
            AddRemoteProjectSheet(host: host)
        }
    }

    private var isConnecting: Bool { client?.status == .connecting }

    /// Pinned and Active, for the tray, leaving out empty ones. A Mac too
    /// old to sort its projects sends them all as one list.
    private func currentSections(_ list: [CompanionProject]) -> [(title: String, projects: [CompanionProject])] {
        let all: [(title: String, projects: [CompanionProject])] = [
            ("Pinned", list.filter { $0.placement == .pinned }),
            ("Active", list.filter { $0.placement == .active }),
            ("Projects", list.filter { $0.placement == nil }),
        ]
        return all.filter { !$0.projects.isEmpty }
    }

    /// One section's rows. Only pinned ones (or all of them, on a Mac that
    /// doesn't sort its projects) drag to reorder.
    @ViewBuilder
    private func rows(_ projects: [CompanionProject], compact: Bool, client: CompanionClient,
                      snapshot: ProjectsSnapshot) -> some View {
        ForEach(projects) { project in
            block(project, compact: compact, client: client, snapshot: snapshot)
        }
    }

    /// A project with its agents' worktrees indented under it.
    @ViewBuilder
    private func block(_ project: CompanionProject, compact: Bool, client: CompanionClient,
                       snapshot: ProjectsSnapshot) -> some View {
        let reorders = project.placement == nil || project.placement == .pinned
        RemoteProjectRow(host: host, project: project, icon: client.icons[project.id], indented: false,
                         shortcut: shortcuts[.remote(host: host, projectID: project.id)], compact: compact)
            .onDrag {
                guard reorders else { return NSItemProvider() }
                dragging = project.id
                return NSItemProvider(object: project.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: RemoteReorderDelegate(
                target: project.id, dragging: $dragging,
                order: {
                    ordered(client.snapshot?.topLevel ?? [])
                        .filter { $0.placement == nil || $0.placement == .pinned }.map(\.id)
                },
                move: { ids in
                    let rest = ordered(client.snapshot?.topLevel ?? []).map(\.id).filter { !ids.contains($0) }
                    pendingOrder = ids + rest
                    client.reorderProjects(ids: ids)
                }))
        ForEach(snapshot.worktrees(of: project.id)) { worktree in
            RemoteProjectRow(host: host, project: worktree, icon: client.icons[project.id], indented: true,
                             shortcut: shortcuts[.remote(host: host, projectID: worktree.id)], compact: compact)
                .padding(.leading, compact ? 14 : 18)
        }
    }

    /// Whether the open project is this one or one of its worktrees.
    private func isPicked(_ project: CompanionProject, snapshot: ProjectsSnapshot) -> Bool {
        guard let selected = store.selectedRemote, selected.host == host else { return false }
        return selected.projectID == project.id || snapshot.worktrees(of: project.id).contains { $0.id == selected.projectID }
    }

    /// Waiting first, then working, among folded projects and their worktrees.
    private func busiest(_ projects: [CompanionProject], snapshot: ProjectsSnapshot) -> TabActivity? {
        TabActivity.busiest(projects.flatMap { [$0] + snapshot.worktrees(of: $0.id) }.map(\.activity.tabActivity))
    }

    /// Top-level projects in that Mac's order, or the order just dragged into.
    private func ordered(_ projects: [CompanionProject]) -> [CompanionProject] {
        guard let pendingOrder else { return projects }
        return projects.sorted { a, b in
            (pendingOrder.firstIndex(of: a.id) ?? .max) < (pendingOrder.firstIndex(of: b.id) ?? .max)
        }
    }

    /// Switching to a Mac before its projects arrived leaves the main area
    /// on a local project. Open one of this Mac's once they're here.
    private func selectFirstIfNeeded() {
        guard store.sidebarHost == host, store.selectedRemote?.host != host,
              let first = client?.snapshot?.topLevel.first else { return }
        store.selectedRemote = RemoteSelection(host: host, projectID: first.id)
    }

    /// Shown until the first snapshot arrives.
    private var status: some View {
        VStack(spacing: 8) {
            let problem = macs.problem(for: host)
            if client?.status == .connecting {
                Text("Connecting to \(macs.name(for: host))…")
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            } else {
                Text(problem ?? "Not connected to \(macs.name(for: host)).")
                    .textSelection(.enabled)
                Button("Reconnect") { macs.reconnect(host: host) }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 24)
        .padding(.horizontal, 16)
    }
}

/// A project from another Mac in this Mac's Active section, with its
/// agents' worktrees under it. While that Mac is away, a stand-in row
/// keeps its place and says why.
struct PinnedRemoteRows: View {
    @Environment(AppStore.self) private var store
    @Environment(RemoteMacs.self) private var macs
    let entry: ActiveEntry
    let host: String
    /// The ⌘1 to ⌘9 hints, while Command is held.
    var shortcuts: [SidebarShortcuts.Target: Int] = [:]
    /// Smaller rows, to match this Mac's projects in the same section.
    var compact = false

    private var client: CompanionClient? { macs.client(for: host) }
    private var project: CompanionProject? { client?.snapshot?.projects.first { $0.id == entry.projectID } }

    var body: some View {
        Group {
            if let project, let client, let snapshot = client.snapshot {
                RemoteProjectRow(host: host, project: project, icon: client.icons[project.id], indented: false,
                                 pinned: true, shortcut: shortcuts[.remote(host: host, projectID: project.id)], compact: compact)
                ForEach(snapshot.worktrees(of: project.id)) { worktree in
                    RemoteProjectRow(host: host, project: worktree, icon: client.icons[project.id], indented: true, pinned: true,
                                     shortcut: shortcuts[.remote(host: host, projectID: worktree.id)], compact: compact)
                        .padding(.leading, compact ? 14 : 18)
                }
            } else {
                away
            }
        }
        .onChange(of: project?.name) { _, name in
            if let name { store.rememberName(name, host: host, projectID: entry.projectID) }
        }
    }

    /// Shown until the Mac answers, or if the project left Bench there.
    private var away: some View {
        HStack(spacing: compact ? 8 : 10) {
            Image(systemName: "cloud")
                .font(.ui(size: compact ? 10 : 13))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 18 : 28, height: compact ? 18 : 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: compact ? 5 : 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name ?? "Project")
                    .font(.ui(size: compact ? 12 : 13, weight: compact ? .regular : .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(reason)
                    .font(.ui(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 6)
        .contentShape(Rectangle())
        .help(reason)
        .contextMenu {
            Button("Reconnect") { macs.reconnect(host: host) }
            if store.grouping == .custom {
                GroupMenu(entry: entry)
                Button("Remove from This Mac's List") { store.removeFromActive(host: host, projectID: entry.projectID) }
            } else {
                Button("Remove from Active") { store.removeFromActive(host: host, projectID: entry.projectID) }
            }
        }
    }

    private var reason: String {
        guard client?.snapshot != nil, client?.status == .connected else {
            return client?.status == .connecting ? "Connecting to \(macs.name(for: host))…" : "\(macs.name(for: host)) isn't connected"
        }
        return "No longer in Workbench on \(macs.name(for: host))"
    }
}

/// Reorders the paired Macs as a dragged pill passes over the others.
/// The pills change places at once: this row never animates its layout.
private struct MacReorderDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let macs: RemoteMacs

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        macs.move(host: dragging, onto: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Reorders another Mac's projects live as a dragged row passes over the
/// others, and tells that Mac each new order.
private struct RemoteReorderDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let order: () -> [UUID]
    let move: ([UUID]) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        var ids = order()
        guard let dragging, dragging != target,
              let from = ids.firstIndex(of: dragging),
              let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        move(ids)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

#if DEBUG
/// For screenshots: BENCH_OPEN_REMOTE=<project name> opens that project on
/// the first Mac that has it; BENCH_OPEN_REMOTE_TAB=shell, =diff or =claude
/// opens a shell there, its first changed file, or a new Claude tab;
/// BENCH_REMOTE_SAY=<text> then sends that to the project's first session
/// once it can take a message. BENCH_SHOW_ADD_MAC=1 opens the pairing sheet.
struct RemoteScreenshotHooks: View {
    @Environment(RemoteMacs.self) private var macs
    @Environment(AppStore.self) private var store

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: snapshotIDs, initial: true) { _, _ in openForScreenshot() }
    }

    private var snapshotIDs: [UUID] {
        macs.macs.flatMap { macs.client(for: $0.host)?.snapshot?.projects.map(\.id) ?? [] }
    }

    private func openForScreenshot() {
        guard store.selectedRemote == nil, let name = ProcessInfo.processInfo.environment["BENCH_OPEN_REMOTE"] else { return }
        for mac in macs.macs {
            guard let client = macs.client(for: mac.host),
                  let project = client.snapshot?.projects.first(where: { $0.name == name }) else { continue }
            store.selectedRemote = RemoteSelection(host: mac.host, projectID: project.id)
            store.sidebarHost = mac.host
            switch ProcessInfo.processInfo.environment["BENCH_OPEN_REMOTE_TAB"] {
            case "shell":
                _ = macs.shell(host: mac.host, project: project)
            case "claude":
                client.newClaudeTab(projectID: project.id, prompt: nil)
            case "diff":
                client.watchChanges(projectID: project.id)
                Task {
                    for _ in 0..<40 {
                        try? await Task.sleep(for: .milliseconds(250))
                        if let changes = client.changes[project.id],
                           let change = (changes.unstaged + changes.staged + changes.againstBase).first {
                            macs.openDiff(host: mac.host, projectID: project.id, change: change)
                            return
                        }
                    }
                }
            default: break
            }
            if let text = ProcessInfo.processInfo.environment["BENCH_REMOTE_SAY"] {
                Task {
                    for _ in 0..<120 {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let session = client.snapshot?.projects.first(where: { $0.id == project.id })?.sessions.first else { continue }
                        macs.openTabs[RemoteMacs.key(host: mac.host, projectID: project.id)] = .session(session.id)
                        guard session.canReply, session.activity != .working else { continue }
                        client.reply(sessionID: session.id, text: text)
                        return
                    }
                }
            }
            return
        }
    }
}
#endif

/// A project on another Mac, drawn like a local one.
struct RemoteProjectRow: View {
    @Environment(AppStore.self) private var store
    @Environment(RemoteMacs.self) private var macs
    let host: String
    let project: CompanionProject
    let icon: Data?
    let indented: Bool
    /// True in this Mac's Active section, where a cloud marks it as remote.
    var pinned = false
    var shortcut: Int?
    /// Recent and Inactive: a smaller icon, a lighter name, no status line.
    var compact = false
    @State private var isHovering = false
    /// What a request sent from here (Clean Up, Discard, a new icon) was,
    /// while it waits on that Mac, so this row shows the problem if it fails.
    @State private var pendingFailure: String?

    private var isSelected: Bool {
        !store.showsPage && store.selectedRemote == RemoteSelection(host: host, projectID: project.id)
    }

    var body: some View {
        let client = macs.client(for: host)
        SidebarRowBody(model: model(client: client), isSelected: isSelected, compact: compact, actions: actions(client: client))
            .modifier(SidebarRowChrome(activity: project.activity.tabActivity, isSelected: isSelected, isHovering: isHovering))
            .onTapGesture { store.selectedRemote = RemoteSelection(host: host, projectID: project.id) }
            .onHover { isHovering = $0 }
            // The same button and selected traits as this Mac's rows.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(project.name) on \(macs.name(for: host))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { store.selectedRemote = RemoteSelection(host: host, projectID: project.id) }
            .contextMenu { menu }
            .onChange(of: macs.client(for: host)?.lastProblem) { _, problem in
            guard let failure = pendingFailure, let problem else { return }
            pendingFailure = nil
            let alert = NSAlert()
            alert.messageText = failure
            alert.informativeText = problem
            alert.runModal()
        }
    }

    // MARK: Right-click menu

    /// The same commands as a local project's menu, run on that Mac, plus
    /// keeping an eye on it from this Mac's own list. Show in Finder is
    /// left out: it would open a window on a Mac you're not in front of.
    @ViewBuilder
    private var menu: some View {
        if let client = macs.client(for: host) {
            if indented {
                worktreeMenu(client)
            } else {
                projectMenu(client)
            }
        }
    }

    @ViewBuilder
    private func projectMenu(_ client: CompanionClient) -> some View {
        let place = macs.name(for: host)
        // Shown in this Mac's own list, the Mac's name says which list
        // each command changes.
        let there = pinned ? " on \(place)" : ""
        localListItems
        Divider()
        if client.canPlaceProjects, let isActive = project.isActive {
            if project.isPinned == true {
                Button("Unpin" + there) { client.pinProject(project.id, pinned: false) }
            } else {
                Button("Pin to Top" + there) { client.pinProject(project.id, pinned: true) }
            }
            if isActive {
                Button("Move to Inactive" + there) { client.setProjectActive(project.id, active: false) }
            } else {
                Button("Make Active" + there) { client.setProjectActive(project.id, active: true) }
            }
        }
        phoneToggle(client)
        Divider()
        Button("New Agent Tab") { client.newClaudeTab(projectID: project.id, prompt: nil) }
        Button("Open Shell on \(place)") { openShell() }
        Button("New Agent on a Branch…") { newAgent() }
        accountMenu(client)
        if client.canEditProjects {
            Divider()
            Button("Rename…") {
                GroupNamePrompt.ask(title: "Rename \(project.name)", confirm: "Rename", initial: project.name,
                                    placeholder: "Project name") { client.renameProject(project.id, to: $0) }
            }
            if project.hasCustomName == true {
                Button("Use Folder Name") { client.renameProject(project.id, to: "") }
            }
            Button("Ask an Agent to Set Icon") {
                store.selectedRemote = RemoteSelection(host: host, projectID: project.id)
                client.newClaudeTab(projectID: project.id, prompt: ProjectIcons.claudePrompt)
            }
            Button("Choose Icon…") { chooseIcon(client) }
            if project.hasCustomIcon == true {
                Button("Reset Icon") { client.setProjectIcon(project.id, image: nil, fileExtension: nil) }
            }
            if project.hasHiddenWorktrees == true {
                Divider()
                Button("Show Hidden Worktrees") { client.showHiddenWorktrees(of: project.id) }
            }
            Divider()
            Button("Remove from Workbench on \(place)…", role: .destructive) { confirmRemoveProject(client) }
        }
    }

    @ViewBuilder
    private func worktreeMenu(_ client: CompanionClient) -> some View {
        if let pr = project.pullRequest {
            Button("Open Pull Request #\(pr.number)") { NSWorkspace.shared.open(pr.url) }
        }
        Button("New Agent Tab") { client.newClaudeTab(projectID: project.id, prompt: nil) }
        Button("Open Shell on \(macs.name(for: host))") { openShell() }
        Button("New Agent on a Branch…") { newAgent() }
        accountMenu(client)
        // Before the group that removes things, so Discard Agent is last.
        phoneToggle(client)
        if project.isExternalWorktree == true {
            if client.canEditProjects {
                Divider()
                Button("Remove from Sidebar", role: .destructive) { client.hideExternalWorktree(project.id) }
            }
        } else if client.canManageAgents {
            Divider()
            if let cleanup = project.cleanup {
                Button("Clean Up…") { confirmRemove(client, discard: false, cleanup: cleanup) }
            }
            Button("Discard Agent…", role: .destructive) { confirmRemove(client, discard: true, cleanup: project.cleanup) }
        }
    }

    /// Adding it to this Mac's own list, or taking it off, to keep an eye
    /// on it from here.
    @ViewBuilder
    private var localListItems: some View {
        if store.isActive(host: host, projectID: project.id), store.grouping == .custom {
            GroupMenu(entry: ActiveEntry(projectID: project.id, host: host, name: project.name))
            Button("Remove from This Mac's List") { store.removeFromActive(host: host, projectID: project.id) }
        } else if store.isActive(host: host, projectID: project.id) {
            Button("Remove from Active on This Mac") { store.removeFromActive(host: host, projectID: project.id) }
        } else if store.grouping == .custom {
            Button("Add to This Mac's List") { store.addToActive(host: host, projectID: project.id, name: project.name) }
        } else {
            Button("Add to Active on This Mac") { store.addToActive(host: host, projectID: project.id, name: project.name) }
        }
    }

    @ViewBuilder
    private func phoneToggle(_ client: CompanionClient) -> some View {
        if client.canEditProjects, let isOn = project.notifiesPhone {
            Divider()
            Toggle("Send Notifications to iPhone", isOn: Binding(
                get: { isOn },
                set: { client.setNotifiesPhone(project.id, isOn: $0) }))
        }
    }

    /// Which of that Mac's Claude accounts new tabs use, once it has more than one.
    @ViewBuilder
    private func accountMenu(_ client: CompanionClient) -> some View {
        if client.canEditProjects, let accounts = client.snapshot?.claudeAccounts, accounts.count > 1 {
            Menu("Claude Account") {
                ForEach(accounts) { account in
                    Toggle(isOn: Binding(get: { project.claudeAccountID == account.id },
                                         set: { if $0 { client.setClaudeAccount(account.id, for: project.id) } })) {
                        Text(account.email.map { "\(account.name) (\($0))" } ?? account.name)
                    }
                }
            }
        }
    }

    private func newAgent() {
        store.selectedRemote = RemoteSelection(host: host, projectID: project.id)
        store.pendingRemoteAction = .newAgent
    }

    private func openShell() {
        _ = macs.shell(host: host, project: project)
        store.selectedRemote = RemoteSelection(host: host, projectID: project.id)
    }

    /// Picks an image here and sends it to that Mac as the project's icon.
    private func chooseIcon(_ client: CompanionClient) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.message = "Choose an icon for \(project.name) on \(macs.name(for: host))"
            panel.prompt = "Use as Icon"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            guard ProjectIcons.extensions.contains(ext), let data = try? Data(contentsOf: url) else {
                let alert = NSAlert()
                alert.messageText = "Workbench can't use that file as an icon"
                alert.informativeText = "Pick a PNG, JPEG, HEIC, WebP, TIFF, GIF, ICNS, SVG, or PDF."
                alert.runModal()
                return
            }
            guard data.count <= 8 << 20 else {
                let alert = NSAlert()
                alert.messageText = "That image is too big"
                alert.informativeText = "Pick an image under 8 MB."
                alert.runModal()
                return
            }
            pendingFailure = "Couldn't change the icon for \(project.name)"
            client.setProjectIcon(project.id, image: data, fileExtension: ext)
        }
    }

    /// Asks first: the project and its tabs leave Workbench on that Mac,
    /// where nobody may be watching.
    private func confirmRemoveProject(_ client: CompanionClient) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            let place = macs.name(for: host)
            alert.messageText = "Remove \(project.name) from Workbench on \(place)?"
            alert.informativeText = "Its tabs on \(place) close. The folder stays where it is, and you can add it again later."
            alert.addButton(withTitle: "Remove").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if store.selectedRemote?.host == host,
               store.selectedRemote?.projectID == project.id
                || client.snapshot?.worktrees(of: project.id).contains(where: { $0.id == store.selectedRemote?.projectID }) == true {
                store.selectedRemote = client.snapshot?.topLevel.first { $0.id != project.id }
                    .map { RemoteSelection(host: host, projectID: $0.id) }
            }
            if pinned { store.removeFromActive(host: host, projectID: project.id) }
            client.removeProject(project.id)
        }
    }

    /// Asks with the same warnings as that Mac's own Clean Up and Discard,
    /// then sends the request.
    private func confirmRemove(_ client: CompanionClient, discard: Bool, cleanup: CompanionCleanup?) {
        let alert = NSAlert()
        let name = project.branch ?? project.name
        let place = macs.name(for: host)
        let risk: String = switch cleanup {
        case .uncommitted?: " It has uncommitted changes, which will be lost."
        case .unpushed?: " It has commits that were never pushed. Its branch will be deleted, so they'll only be recoverable from git's reflog."
        case .unknown?: " Workbench couldn't check it for uncommitted changes or unpushed commits."
        case .ready?: ""
        case nil: " Any uncommitted changes will be lost."
        }
        if discard {
            alert.messageText = "Discard \(name) on \(place)?"
            alert.informativeText = "The agent's worktree folder is removed from \(place) and its local branch is deleted. Anything already pushed stays on GitHub." + risk
        } else {
            alert.messageText = "Clean up \(name) on \(place)?"
            alert.informativeText = "Its pull request is merged. The folder is removed from \(place) and its local branch is deleted." + risk
        }
        alert.alertStyle = discard || (cleanup != .ready && cleanup != nil) ? .critical : .warning
        alert.addButton(withTitle: discard ? "Discard" : "Clean Up").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pendingFailure = "Couldn't remove \(project.branch ?? project.name)"
        client.removeAgent(projectID: project.id, discard: discard)
        if store.selectedRemote == RemoteSelection(host: host, projectID: project.id) {
            store.selectedRemote = project.parentID.map { RemoteSelection(host: host, projectID: $0) }
        }
    }

    /// What the row says, from the Mac's latest snapshot. Its activity is
    /// drawn like a local project's; the Mac name pill is what marks it
    /// as remote.
    private func model(client: CompanionClient?) -> SidebarRowModel {
        var model = SidebarRowModel(name: indented ? (project.branch ?? project.name) : project.name,
                                    isWorktree: indented, icon: .remote(project, icon), activity: project.activity.tabActivity)
        model.shortcut = shortcut
        if pinned && !indented { model.macName = macs.name(for: host) }
        if let active = project.activeSince {
            model.timer = ActiveTimerModel(since: active.since, action: active.action)
            model.task = project.sessions.first { $0.activity == project.activity }
                .map(\.title).flatMap { $0.isEmpty || $0 == "Claude" ? nil : $0 }
            model.checklist = project.checklist
            if let session = waitingSession, session.question != nil || session.isAllowOrDeny {
                model.waiting = WaitingPrompt(question: session.question, action: session.isAllowOrDeny ? session.action : nil,
                                              canAnswer: session.isAllowOrDeny && session.canReply && client != nil)
            }
        }
        if let finish = project.lastFinish {
            model.finished = FinishedSummary(recap: finish.summary, at: finish.at,
                                             changes: client?.changes[project.id].map { $0.staged + $0.unstaged } ?? [])
            model.lastFinish = FinishedSummary(recap: finish.summary, at: finish.at)
        }
        model.status = status
        return model
    }

    /// The session asking, while the project waits on you.
    private var waitingSession: CompanionSession? {
        project.activity == .waiting ? project.sessions.first { $0.activity == .waiting } : nil
    }

    /// A quiet row's second line, picked the same way as a local row's.
    private var status: RowStatus? {
        RowStatus.pick(pr: project.pullRequest.map(PullRequestInfo.init), deploy: project.deploy.map(DeployInfo.init),
                       branch: project.branch, baseRef: project.defaultBranch, isWorktree: indented)
    }

    private func actions(client: CompanionClient?) -> SidebarRowActions {
        SidebarRowActions(allow: { answer(allow: true, client: client) },
                          deny: { answer(allow: false, client: client) })
    }

    /// Answers the allow-or-deny question on that Mac.
    private func answer(allow: Bool, client: CompanionClient?) {
        guard let client, let session = waitingSession else { return }
        client.answer(sessionID: session.id, allow: allow)
    }
}

nonisolated extension PullRequestInfo {
    /// A pull request as another Mac reported it, in this Mac's terms.
    init(_ pr: CompanionPullRequest) {
        let state: State = switch pr.state {
        case .open: .open
        case .draft: .draft
        case .merged: .merged
        case .closed: .closed
        }
        let checks: Checks = switch pr.checks {
        case .none: .none
        case .pending: .pending
        case .passing: .passing
        case .failing: .failing
        }
        self.init(number: pr.number, title: pr.title, url: pr.url, state: state, checks: checks,
                  passedCount: pr.passedCount, totalCount: pr.totalCount, failingNames: pr.failingNames)
    }
}

nonisolated extension DeployInfo {
    /// A deploy as another Mac reported it, in this Mac's terms: the one
    /// place it names is where it went, or where it failed.
    init(_ deploy: CompanionDeploy) {
        let state: State = switch deploy.state {
        case .deploying: .deploying
        case .succeeded: .succeeded
        case .failed: .failed
        }
        let places = deploy.place.map { [$0] } ?? []
        self.init(state: state, prNumber: deploy.prNumber, prTitle: "", environments: places,
                  failing: deploy.state == .failed ? places : [], url: deploy.url)
    }
}

extension CompanionProject {
    /// The latest finished turn, seen or not: its recap and when.
    var lastFinish: (summary: String, at: Date)? {
        sessions.compactMap { session -> (summary: String, at: Date)? in
            guard let summary = session.summary, let at = session.stoppedAt,
                  at >= (session.promptAt ?? .distantPast) else { return nil }
            return (summary, at)
        }
        .max { $0.at < $1.at }
    }
}

/// The name of the Mac a project is on, with a cloud, in a small blue pill.
struct MacNamePill: View {
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "cloud.fill").font(.ui(size: 8.5))
            Text(name).lineLimit(1).truncationMode(.tail)
        }
        .font(.ui(size: Theme.TypeScale.meta, weight: .semibold))
        .foregroundStyle(ActiveTimer.ink(for: .remoteWorking))
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 1.5)
        .background(ActivityBackground.remote.opacity(0.16), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("On \(name)")
        .help("On \(name)")
    }
}

#if DEBUG
/// Rows and chat bars for projects on another Mac, drawn to
/// PNGs in light and dark from a saved snapshot, for checking them.
/// BENCH_RENDER_REMOTE=<folder> BENCH_RENDER_REMOTE_SNAPSHOT=<file>.
enum RemoteRowsPreview {
    static func render(to folder: URL, snapshotFile: URL) {
        _ = NSApplication.shared
        guard let data = try? Data(contentsOf: snapshotFile),
              let snapshot = try? CompanionCoding.decoder.decode(ProjectsSnapshot.self, from: data) else {
            print("Couldn't read the snapshot"); return
        }
        let store = AppStore()
        let macs = RemoteMacs()
        for layout in [SidebarLayout.standard, .compact] {
            // Its own settings, so the real app's layout is left alone.
            let defaults = UserDefaults(suiteName: "RemoteRowsPreview-\(layout.rawValue)")!
            defaults.set(layout.rawValue, forKey: SidebarLayout.key)
            draw(VStack(spacing: 2) {
                ForEach(snapshot.projects) { project in
                    RemoteProjectRow(host: "studio.example", project: project, icon: nil, indented: false)
                }
            }
            .padding(8).frame(width: 280)
            .environment(store).environment(macs).defaultAppStorage(defaults), name: "rows-\(layout.rawValue)", folder: folder)
        }
        if let session = snapshot.projects.first?.sessions.first {
            let bars = VStack(spacing: 10) {
                if let items = session.checklist {
                    ChatChecklistBar(items: items, session: session, agents: session.pinnedAgents)
                }
                if let agents = session.agents {
                    ChatAgentsBar(agents: agents)
                }
            }
            .padding(16).frame(width: 520)
            .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
            draw(bars, name: "chat-bars", folder: folder)
        }
    }

    private static func draw(_ view: some View, name: String, folder: URL) {
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-\(mode).png"))
        }
    }
}
#endif
