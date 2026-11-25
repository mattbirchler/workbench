import BenchKit
import SwiftUI

@main
struct BenchPhoneApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var pairing: PairingStore
    @State private var client: CompanionClient
    @State private var navigator = Navigator()
    @State private var activities = ActivityManager()
    @State private var queue = QueueStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // First, so a crash anywhere in launch is reported next time.
        Analytics.start()
        let client = CompanionClient(deviceName: UIDevice.current.name,
                                     features: [CompanionFeature.turnTimes, CompanionFeature.results, CompanionFeature.interrupt, CompanionFeature.theme, CompanionFeature.queue, CompanionFeature.editQueue, CompanionFeature.agents, CompanionFeature.sendNow, CompanionFeature.placement, CompanionFeature.planUsage, CompanionFeature.artifacts, CompanionFeature.slashCommands, CompanionFeature.notificationPrefs, CompanionFeature.usage, CompanionFeature.imagePreviews, CompanionFeature.paging, CompanionFeature.sendTasks, CompanionFeature.agentLifecycle, CompanionFeature.shortcuts, CompanionFeature.branchControls, CompanionFeature.dashboard, CompanionFeature.codeReview, CompanionFeature.keepalive, CompanionFeature.sideQuestions])
        // The notification extension opens sealed notifications.
        client.opensSealedNotifications = true
        // Keeps each Mac's last project list, for when it's asleep.
        client.snapshotCache = .standard
        let pairing = PairingStore()
        _pairing = State(initialValue: pairing)
        Analytics.launched(["paired_macs": pairing.macs.count])
        client.onSend = { PhoneAnalytics.log($0) }
        _client = State(initialValue: client)
        AppDelegate.client = client
        // Here rather than when the first screen appears: a button on a
        // notification can start the app with no screen at all.
        AppDelegate.pairing = pairing
        #if DEBUG
        // The chat timing log to a file too, where a simulator's can be read.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            ChatTiming.start(file: documents.appendingPathComponent("chat-timing.log"),
                             version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let path = ProcessInfo.processInfo.environment["BENCH_TRANSCRIPT_SAMPLE"] {
                    // Screenshots: render a transcript file straight from disk.
                    TranscriptPreview(path: path)
                } else if let mode = ProcessInfo.processInfo.environment["BENCH_CHECKLIST_SAMPLE"] {
                    // Screenshots: the checklist bar, folded or ("open") open.
                    ChecklistPreview(expanded: mode == "open")
                } else if ProcessInfo.processInfo.environment["BENCH_MARKDOWN_SAMPLE"] != nil {
                    // Screenshots: render the Markdown sample on its own.
                    ScrollView { MarkdownText(text: MarkdownText.sample).padding(16) }.background(PhoneTheme.canvas)
                } else if pairing.info != nil || pairing.isDemo {
                    ProjectsView()
                } else {
                    PairView()
                }
                #else
                if pairing.info != nil || pairing.isDemo {
                    ProjectsView()
                } else {
                    PairView()
                }
                #endif
            }
            // Pairing took: the list is about to take the pair screen's place.
            .sensoryFeedback(.success, trigger: pairing.info != nil) { old, new in !old && new }
            .environment(pairing)
            .environment(client)
            .environment(navigator)
            .environment(activities)
            .environment(queue)
            .tint(PhoneTheme.accent)
            .environment(\.companionPalette, PhoneTheme.palette)
            .preferredColorScheme(MacTheme.shared.colorScheme)
            // The Mac's terminal colors, when it shares them. A Mac that
            // doesn't (older, or not matching a theme) puts the phone's own
            // colors back.
            .onChange(of: client.theme) { _, theme in
                if client.macFeatures.contains(CompanionFeature.theme) { MacTheme.shared.update(theme) }
            }
            .onChange(of: client.macFeatures) { _, features in
                if client.status == .connected, !features.contains(CompanionFeature.theme) { MacTheme.shared.update(nil) }
            }
            .onAppear {
                AppDelegate.navigator = navigator
                AppDelegate.pairing = pairing
                activities.client = client
                activities.start()
            }
            .onChange(of: client.status) { _, status in
                if status == .connected { activities.resendTokens() }
            }
            .onChange(of: client.started?.sessionID) { _, _ in
                if let started = client.started {
                    navigator.open(projectID: started.projectID, sessionID: started.sessionID)
                    client.clearStarted()
                }
            }
            #if DEBUG
            // Turned in code, the safe area at the top doesn't update and the
            // status bar overlaps the bars, so screenshots go without it.
            .statusBarHidden(ProcessInfo.processInfo.environment["BENCH_LANDSCAPE"] != nil)
            .onAppear {
                // For screenshots: BENCH_LANDSCAPE=1 turns the app sideways,
                // since the simulator can't be rotated from the command line.
                // iPadOS only allows it in a build with UIRequiresFullScreen.
                guard ProcessInfo.processInfo.environment["BENCH_LANDSCAPE"] != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                    scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { print("BENCH_LANDSCAPE: \($0)") }
                }
            }
            .onChange(of: client.snapshot?.projects.count) { _, _ in
                #if DEBUG
                // For screenshots: BENCH_SEND_TASKS_SAMPLE opens Brain Dump with samples.
                if ProcessInfo.processInfo.environment["BENCH_SEND_TASKS_SAMPLE"] != nil { navigator.showsSendTasks = true }
                #endif
                // For screenshots: BENCH_OPEN_PROJECT=<name> opens that project's session.
                guard navigator.path.isEmpty, let name = ProcessInfo.processInfo.environment["BENCH_OPEN_PROJECT"],
                      let project = client.snapshot?.projects.first(where: { $0.name == name }) else { return }
                navigator.open(projectID: project.id, sessionID: project.sessions.first?.id)
                // BENCH_OPEN_SCREEN=changes|diff|commit|agent|files|past goes one screen
                // further, files:<folder> opens that folder, and file:<path>
                // opens that file.
                let screen = ProcessInfo.processInfo.environment["BENCH_OPEN_SCREEN"] ?? ""
                switch screen {
                case "changes", "diff", "commit": navigator.push(ChangesRoute(projectID: project.id))
                case "agent": navigator.push(NewAgentRoute(projectID: project.id))
                case "files": navigator.push(FilesRoute(projectID: project.id))
                case "past": navigator.push(PastSessionsRoute(projectID: project.id))
                case _ where screen.hasPrefix("files:"):
                    navigator.push(FilesRoute(projectID: project.id, folder: String(screen.dropFirst(6))))
                case _ where screen.hasPrefix("file:"):
                    navigator.push(FileRoute(projectID: project.id, path: String(screen.dropFirst(5))))
                default: break
                }
            }
            .onChange(of: "\(client.changes.count) \(navigator.path.count)") { _, _ in
                // With BENCH_OPEN_SCREEN=diff, opens a changed file once the list loads
                // and Changes is open (the demo has its list before then),
                // preferring one with removed lines.
                // BENCH_OPEN_SCREEN=commit opens the first commit the same way.
                if ProcessInfo.processInfo.environment["BENCH_OPEN_SCREEN"] == "commit",
                   navigator.path.count == 2, let name = ProcessInfo.processInfo.environment["BENCH_OPEN_PROJECT"],
                   let project = client.snapshot?.projects.first(where: { $0.name == name }),
                   let commit = client.changes[project.id]?.commits.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        navigator.push(CommitRoute(projectID: project.id, hash: commit.hash, shortHash: commit.shortHash))
                    }
                    return
                }
                // BENCH_OPEN_SCREEN=inspector-diff opens a changed file as
                // the iPad's inspector does, in the middle pane.
                if ProcessInfo.processInfo.environment["BENCH_OPEN_SCREEN"] == "inspector-diff",
                   let name = ProcessInfo.processInfo.environment["BENCH_OPEN_PROJECT"],
                   let project = client.snapshot?.projects.first(where: { $0.name == name }),
                   navigator.selected == project.id, navigator.detailPath.isEmpty,
                   let changes = client.changes[project.id],
                   let file = (changes.staged + changes.unstaged + changes.againstBase).first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { navigator.show(.diff(DiffRoute(projectID: project.id, change: file))) }
                    return
                }
                guard ProcessInfo.processInfo.environment["BENCH_OPEN_SCREEN"] == "diff",
                      navigator.path.count == 2, let name = ProcessInfo.processInfo.environment["BENCH_OPEN_PROJECT"],
                      let project = client.snapshot?.projects.first(where: { $0.name == name }),
                      let changes = client.changes[project.id],
                      case let files = changes.staged + changes.unstaged + changes.againstBase,
                      let file = files.first(where: { $0.deletions > 0 }) ?? files.first else { return }
                // A beat after Changes opens: the iPad's stack drops a second
                // screen pushed while the first is still sliding in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    navigator.push(DiffRoute(projectID: project.id, change: file))
                }
            }
            #endif
            .onChange(of: navigator.pendingURL) { _, url in
                if let url {
                    UIApplication.shared.open(url)
                    navigator.pendingURL = nil
                }
            }
            .onChange(of: pairing.info, initial: true) { _, info in
                queue.use(info)
                if let info { client.connect(info) } else if !pairing.isDemo { client.disconnect() }
            }
            .onChange(of: pairing.isDemo, initial: true) { _, demo in
                if demo {
                    navigator.reset()
                    client.startDemo()
                } else if let info = pairing.info {
                    client.connect(info)
                } else {
                    client.disconnect()
                }
            }
            .onChange(of: client.macName) { _, name in
                // So the switcher can call each Mac by its name.
                if let name, let host = client.host { pairing.remember(name: name, for: host) }
            }
            .onChange(of: scenePhase) { _, phase in
                // iOS drops the socket in the background anyway; reconnect
                // cleanly when we're back.
                switch phase {
                case .active:
                    if let info = pairing.info { client.connect(info) }
                    // Sends prompts that didn't go out, and checks on the rest.
                    Task { await queue.refresh() }
                case .background: if !pairing.isDemo { client.disconnect() }
                default: break
                }
            }
        }
        .commands { PhoneCommands(client: client, navigator: navigator) }
    }
}
