import BenchKit
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(RemoteMacs.self) private var macs
    @Environment(OfflineQueue.self) private var offlineQueue
    @Environment(\.openWindow) private var openWindow
    @State private var isNarrow = false
    #if DEBUG
    @Environment(RepoMonitors.self) private var repos
    #endif

    var body: some View {
        splitView
            // Sidebars tuck away as the window narrows, and come back as it widens.
            .environment(\.isNarrowWindow, isNarrow)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                store.fitWindow(width: width)
                isNarrow = width < WindowChrome.narrowWindowWidth
            }
            .terminalColorScheme()
            .background(ControlTabCycler { offset in
                // A project on this Mac, with its tabs on screen. The
                // Overview, Settings and other Macs' projects keep the keys.
                guard !store.showsPage, store.selectedRemote == nil, store.selectedProject != nil else { return false }
                store.cycleTab(by: offset)
                return true
            })
            .task {
                // The project list couldn't be read at launch. Say so once
                // the window is up, and point at where the file went.
                guard let file = store.brokenStateFile else { return }
                try? await Task.sleep(for: .seconds(1))
                let alert = NSAlert()
                alert.messageText = "Workbench couldn't read its project list"
                alert.informativeText = "The saved list was kept at \(file.path) instead of being replaced. Workbench starts with an empty list; add your projects again, or send that file along with a Feedback report."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show in Finder")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            }
                #if DEBUG
            // BENCH_SNAPSHOT=<path.png> saves the window's contents a few
            // seconds after launch, for checking layouts without screen recording.
            // BENCH_SETTINGS_TOUR=<folder> opens each Settings section and
            // saves the window as settings-<section>.png there, then quits.
            // BENCH_OPEN_LINK=<url> clicks a link a few seconds after launch,
            // the way the chat or a terminal would.
            .task {
                guard let link = ProcessInfo.processInfo.environment["BENCH_OPEN_LINK"].flatMap(URL.init(string:)) else { return }
                try? await Task.sleep(for: .seconds(4))
                ArtifactLinks.open(link)
            }
            .task {
                guard let folder = ProcessInfo.processInfo.environment["BENCH_SETTINGS_TOUR"] else { return }
                try? await Task.sleep(for: .seconds(2))
                for section in SettingsSection.allCases {
                    store.settingsSection = section
                    try? await Task.sleep(for: .seconds(section == .usage ? 25 : 1.5))
                    guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: folder).appendingPathComponent("settings-\(section.rawValue).png"))
                }
                exit(0)
            }
            .task {
                guard let path = ProcessInfo.processInfo.environment["BENCH_SNAPSHOT"] else { return }
                if ProcessInfo.processInfo.environment["BENCH_SNAPSHOT_START_PAGE"] != nil, let id = store.selectedProjectID {
                    try? await Task.sleep(for: .seconds(1))
                    store.openStartPage(id)
                }
                // BENCH_SNAPSHOT_OVERVIEW opens the Overview before the snapshot.
                if ProcessInfo.processInfo.environment["BENCH_SNAPSHOT_OVERVIEW"] != nil {
                    try? await Task.sleep(for: .seconds(1))
                    store.showsOverview = true
                }
                // BENCH_SNAPSHOT_DIFF=1 opens the selected project's first
                // changed file as a diff before the snapshot.
                if ProcessInfo.processInfo.environment["BENCH_SNAPSHOT_DIFF"] != nil, let project = store.selectedProject {
                    let monitor = repos.monitor(for: project)
                    var waited = 0
                    while monitor.snapshot == nil, waited < 20 {
                        try? await Task.sleep(for: .milliseconds(250))
                        waited += 1
                    }
                    if let snapshot = monitor.snapshot,
                       let change = (snapshot.unstaged + snapshot.staged + snapshot.againstBase).first {
                        store.openDiff(change, in: project.id)
                    }
                }
                // BENCH_SNAPSHOT_COMMAND_BAR=<query> opens the command bar
                // with that typed before the snapshot.
                if ProcessInfo.processInfo.environment["BENCH_SNAPSHOT_COMMAND_BAR"] != nil {
                    try? await Task.sleep(for: .seconds(1))
                    store.showsCommandBar = true
                }
                let delay = ProcessInfo.processInfo.environment["BENCH_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 4
                try? await Task.sleep(for: .seconds(delay))
                guard let view = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil })?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    NSLog("Bench: no window to snapshot")
                    return
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                do {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    NSLog("Bench: snapshot written to %@", path)
                } catch {
                    NSLog("Bench: snapshot failed: %@", error.localizedDescription)
                }
            }
            .task { await FrameMeter.runSidebarBench(store: store) }
            .task { await LoadTestHooks.start(store: store) }
            // A test copy (BENCH_SUPPORT_DIR) shares the real app's
            // defaults, so its window's size and place would be saved over
            // the real window's. Turn that off before anything moves it.
            .task {
                guard ProcessInfo.processInfo.environment["BENCH_SUPPORT_DIR"] != nil else { return }
                for _ in 0..<50 {
                    let windows = NSApp.windows.filter { !($0 is NSPanel) && !$0.frameAutosaveName.isEmpty }
                    for window in windows {
                        window.setFrameAutosaveName("")
                        window.isRestorable = false
                    }
                    if !windows.isEmpty { return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            // BENCH_RESIZE=<width>x<height> resizes the window a little at a
            // time, like a drag, starting two seconds after launch. For
            // layout problems that only show at some sizes.
            // BENCH_HIDE_PANEL=1 closes the right panel first.
            // BENCH_CYCLE_TABS=<seconds> moves to the selected project's
            // next tab every so many seconds, for timing how a chat opens
            // when you come back to it.
            .task {
                guard let seconds = ProcessInfo.processInfo.environment["BENCH_CYCLE_TABS"].flatMap(Double.init) else { return }
                try? await Task.sleep(for: .seconds(seconds))
                while !Task.isCancelled {
                    store.cycleTab(by: 1)
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
            .task {
                guard let spec = ProcessInfo.processInfo.environment["BENCH_RESIZE"] else { return }
                let parts = spec.split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2 else { return }
                try? await Task.sleep(for: .seconds(2))
                if ProcessInfo.processInfo.environment["BENCH_HIDE_PANEL"] != nil { store.showsChanges = false }
                guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
                // BENCH_RESIZE_DARK=1 forces the dark appearance first, and
                // BENCH_RESIZE_CORNER=1 moves the window to the screen's corner.
                if ProcessInfo.processInfo.environment["BENCH_RESIZE_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
                var frame = window.frame
                if ProcessInfo.processInfo.environment["BENCH_RESIZE_CORNER"] != nil { frame.origin = NSPoint(x: 40, y: 40) }
                // BENCH_RESIZE_THEN=<width>x<height> resizes again to that
                // afterwards, to see what comes back as the window widens.
                let then = ProcessInfo.processInfo.environment["BENCH_RESIZE_THEN"]?.split(separator: "x").compactMap { Double($0) }
                var targets = [NSSize(width: parts[0], height: parts[1])]
                if let then, then.count == 2 { targets.append(NSSize(width: then[0], height: then[1])) }
                // BENCH_RESIZE_STEP=<points> per step; a big one is a single jump.
                let step = ProcessInfo.processInfo.environment["BENCH_RESIZE_STEP"].flatMap(Double.init) ?? 20
                for target in targets {
                    NSLog("Bench: resizing from %.0fx%.0f", frame.width, frame.height)
                    while abs(frame.width - target.width) > 0.5 || abs(frame.height - target.height) > 0.5 {
                        frame.size.width += max(-step, min(step, target.width - frame.width))
                        frame.size.height += max(-step, min(step, target.height - frame.height))
                        window.setFrame(frame, display: true)
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    NSLog("Bench: resized to %.0fx%.0f, window is %.0fx%.0f", frame.width, frame.height,
                          window.frame.width, window.frame.height)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            #endif
            .overlay {
                // The fade belongs to the bar alone. On the whole window,
                // picking something from the bar (which closes it and
                // changes the selection in one go) animated the sidebar
                // and the project too.
                ZStack {
                    if store.showsCommandBar {
                        CommandBarOverlay()
                    }
                }
                .animation(.easeOut(duration: 0.12), value: store.showsCommandBar)
            }
            // The welcome covers the whole window, title bar included.
            .overlay {
                if store.showsWelcome {
                    OnboardingView { withAnimation(.smooth(duration: 0.5)) { store.showsWelcome = false } }
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .background(TrafficLightsPlacement(shift: trafficLightsOnCard ? CardBand.trafficLightsShift : 0))
            .onAppear {
                #if DEBUG
                // BENCH_STAY_BACK=1 hands focus straight back to whatever app
                // had it, so a test copy doesn't catch what you're typing.
                // BENCH_HIDE_SIDEBAR=1 and BENCH_HIDE_PANEL=1 start with them hidden.
                if ProcessInfo.processInfo.environment["BENCH_HIDE_SIDEBAR"] != nil { store.sidebarVisibility = .detailOnly }
                if ProcessInfo.processInfo.environment["BENCH_HIDE_PANEL"] != nil { store.showsChanges = false }
                // Its windows float on top and ignore the mouse, so they still
                // draw for screenshots (a window behind others doesn't).
                if ProcessInfo.processInfo.environment["BENCH_STAY_BACK"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        for window in NSApp.windows {
                            window.level = .floating
                            window.ignoresMouseEvents = true
                        }
                        NSApp.deactivate()
                    }
                }
                // BENCH_FEEDBACK_OPEN=1 opens Send Feedback at launch, for screenshots.
                if ProcessInfo.processInfo.environment["BENCH_FEEDBACK_OPEN"] != nil {
                    openWindow(id: "feedback")
                }
                // BENCH_OPEN_SECTION=usage (or any Settings section) opens it at launch.
                if let section = ProcessInfo.processInfo.environment["BENCH_OPEN_SECTION"].flatMap(SettingsSection.init(rawValue:)) {
                    store.settingsSection = section
                }
                #endif
            }
    }

    /// A project's card fills the main area and the sidebar is collapsed
    /// to its icons, so the traffic lights sit on the card's tab row.
    private var trafficLightsOnCard: Bool {
        guard store.sidebarVisibility == .detailOnly, !store.showsOverview, store.settingsSection == nil else { return false }
        if let remote = store.selectedRemote { return macs.client(for: remote.host) != nil }
        return store.selectedProject != nil
    }

    @ViewBuilder private var splitView: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $store.sidebarVisibility) {
            VStack(spacing: 0) {
                SidebarBand()
                SidebarView()
            }
            .environment(\.companionPalette, TerminalTheme.shared.sidebarPalette)
            .ignoresSafeArea(.container, edges: .top)
            .terminalPanelBackground()
            .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(spacing: 0) {
                // A collapsed sidebar leaves its project icons behind.
                if store.sidebarVisibility == .detailOnly {
                    ProjectRail()
                        .environment(\.companionPalette, TerminalTheme.shared.sidebarPalette)
                        .terminalChromeBackground()
                        .ignoresSafeArea(.container, edges: .top)
                        .modifier(FadeInOnAppear())
                }
                detail
            }
            // The split view already animates the sidebar in and out. If
            // SwiftUI animated the rail's arrival as well, it would animate
            // the layout of everything in the main area (terminal, chat,
            // tabs) on every frame, and the animation stuttered. So the
            // rail takes its place at once and only fades in.
            .animation(nil, value: store.sidebarVisibility)
        }
        .sheet(isPresented: Binding(
            get: { store.newAgentParentID != nil },
            set: { if !$0 { store.newAgentParentID = nil } }
        )) {
            if let id = store.newAgentParentID, let parent = store.project(id) {
                NewAgentSheet(parent: parent)
            }
        }
        .sheet(isPresented: Binding(
            get: { offlineQueue.showsFailedPrompts },
            set: { offlineQueue.showsFailedPrompts = $0 }
        )) {
            QueuedPromptsSheet()
        }
        .sheet(isPresented: Binding(
            get: { store.showsSendTasks },
            set: { store.showsSendTasks = $0 }
        )) {
            if let host = store.sendTasksHost, let client = macs.client(for: host), client.canSendTasks {
                SendTasksSheet(model: SendTasksModel(remote: client))
            } else {
                SendTasksSheet()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        @Bindable var store = store
        Group {
            if store.showsOverview {
                VStack(spacing: 0) {
                    PlainMainBand()
                    OverviewView()
                }
                // Behind the band too, so the top of the page takes the
                // theme instead of the plain window color.
                .background(TerminalTheme.shared.canvas)
                .ignoresSafeArea(.container, edges: .top)
            } else if let section = store.settingsSection {
                VStack(spacing: 0) {
                    PlainMainBand()
                    SettingsPage(section: section)
                }
                // Behind the band too, so the top of the page takes the
                // theme instead of the plain window color.
                .background(TerminalTheme.shared.canvas)
                .ignoresSafeArea(.container, edges: .top)
            } else if let remote = store.selectedRemote, macs.client(for: remote.host) != nil {
                RemoteProjectView(host: remote.host, projectID: remote.projectID)
                    .id(remote)
                    .terminalCanvasBackground()
                    .inspector(isPresented: $store.showsChanges) {
                        Group {
                            if macs.client(for: remote.host)?.isHeadless == true {
                                // A server sends sessions and chat. Its
                                // changes and files come later.
                                Text("Changes and files aren't shown for a server yet.")
                                    .font(.ui(size: 12))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(20)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                RemoteInspector(host: remote.host, projectID: remote.projectID)
                            }
                        }
                            .id(remote)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 600)
                    }
            } else if let project = store.selectedProject {
                ProjectDetailView(project: project)
                    .terminalChromeBackground()
                    .inspector(isPresented: $store.showsChanges) {
                        LocalInspector(project: project)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 600)
                    }
            } else {
                VStack(spacing: 0) {
                    PlainMainBand()
                    EmptyStateView()
                        .frame(maxHeight: .infinity)
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }
}

private struct EmptyStateView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        EmptyStateScaffold(title: "No Project Selected",
                           message: "Pick one in the sidebar. To bring in a new one, add its folder or drag it into the sidebar.",
                           actionTitle: "Add Project…", action: { ProjectPicker.present(store: store) }) {
            ProjectsEmptyIllustration(appeared: $0)
        }
        .environment(\.companionPalette, TerminalTheme.shared.chatPalette)
    }
}

enum ProjectPicker {
    static func present(store: AppStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more project folders"
        if panel.runModal() == .OK {
            store.addProjects(panel.urls, source: .folderPicker)
        }
    }
}

/// Fades a view in when it appears, without animating where it sits.
/// Opacity is cheap to animate; layout isn't.
private struct FadeInOnAppear: ViewModifier {
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { isShown = true }
            }
    }
}
