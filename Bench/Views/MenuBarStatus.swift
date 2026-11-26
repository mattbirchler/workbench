import AppKit
import BenchKit
import SwiftUI

/// The menu bar icon: what your Claude sessions are doing while Bench is in
/// the background. An exclamation and a count when any are waiting for you,
/// a sparkle and a count while any are working. Clicking it opens the panel.
///
/// A status item of our own rather than SwiftUI's `MenuBarExtra`. That one
/// redrew its icon whenever the store changed, sometimes from inside the
/// main window's layout pass, and on some Macs AppKit throws when a status
/// button's image is set mid-layout: Workbench quit a second after launch.
/// Here the icon is only ever set from its own turn of the run loop, and
/// only when what it shows has changed.
@MainActor
final class MenuBarItem: NSObject, NSPopoverDelegate {
    /// What the icon shows.
    struct Status: Equatable {
        var waiting = 0
        var working = 0

        init(_ items: [OverviewItem] = []) {
            waiting = items.filter { $0.activity == .waiting }.count
            working = items.filter { $0.activity == .working || $0.activity == .remoteWorking }.count
        }

        var symbol: String { waiting > 0 ? "exclamationmark.bubble.fill" : "sparkle" }
        /// The count beside the symbol, or nothing while all is quiet.
        var title: String { waiting > 0 ? "\(waiting)" : working > 0 ? "\(working)" : "" }
        var spoken: String {
            if waiting > 0 { return "Workbench, \(waiting) waiting for you" }
            if working > 0 { return "Workbench, \(working) working" }
            return "Workbench"
        }
    }

    private let store: AppStore
    private let terminals: TerminalManager
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var shown: Status?
    /// True from a change until the icon catches up, so a burst of changes
    /// costs one update.
    private var refreshQueued = false

    init(store: AppStore, terminals: TerminalManager) {
        self.store = store
        self.terminals = terminals
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.imagePosition = .imageLeading
        popover.behavior = .transient
        popover.delegate = self
        refresh()
    }

    /// Reads the sessions, shows them, and asks to be told when they change.
    private func refresh() {
        refreshQueued = false
        let status = withObservationTracking {
            Status(OverviewView.items(store: store, terminals: terminals))
        } onChange: { [weak self] in
            // The change may come mid-layout. The icon waits for its own
            // turn of the run loop.
            DispatchQueue.main.async { self?.queueRefresh() }
        }
        guard status != shown, let button = item.button else { return }
        shown = status
        button.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)
        button.title = status.title
        button.setAccessibilityLabel(status.spoken)
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        let panel = MenuBarPanel(close: { [weak self] in self?.popover.performClose(nil) })
            .environment(store)
            .environment(terminals)
            .followsMotionSetting()
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Lets go of the panel, so it isn't kept up to date while closed.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}

/// Reopens the main window from places with no SwiftUI scene around them,
/// like the menu bar panel. The app's commands fill this in, since they
/// have the `openWindow` action and outlive the window.
@MainActor
enum MainWindow {
    static var open: (() -> Void)?
}

/// The panel that opens from the menu bar icon: every session that isn't
/// idle, needs-you first. Clicking one brings Bench forward on that tab.
struct MenuBarPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(TerminalManager.self) private var terminals
    /// Closes the panel, after a pick.
    var close: () -> Void = {}

    var body: some View {
        let items = OverviewView.items(store: store, terminals: terminals).filter { $0.activity != .idle }
        VStack(alignment: .leading, spacing: 0) {
            Text("Agent Sessions")
                .font(.ui(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if items.isEmpty {
                Text("Nothing is working or waiting right now.")
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            MenuBarRow(item: item) { show(item) }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 6)
            HStack {
                Button("Open Overview") {
                    bringForward()
                    store.showOverview(from: .menuBar)
                }
                Spacer()
                Button("Quit Workbench") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.ui(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private func show(_ item: OverviewItem) {
        bringForward()
        store.selectedProjectID = item.project.id
        store.selectTab(item.tab.id, in: item.project.id)
    }

    /// Activates Bench, reopening its window if it was closed.
    private func bringForward() {
        close()
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            MainWindow.open?()
        }
    }
}

private struct MenuBarRow: View {
    let item: OverviewItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ActivityIndicator(activity: item.activity, size: 11)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.project.name)
                            .font(.ui(size: 12, weight: .semibold))
                        if let label = item.label {
                            Text("· \(label)")
                                .font(.ui(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            if let text = item.elapsed(now: context.date) {
                                Text(text)
                                    .font(.ui(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let task = item.task {
                        Text(task)
                            .font(.ui(size: 12))
                            .lineLimit(1)
                    }
                    if let line = detailLine {
                        Text(line)
                            .font(.ui(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
    }

    /// The question it's waiting on, what it's doing, or how it finished.
    private var detailLine: String? {
        let details = item.details
        switch item.activity {
        case .waiting: return details?.question
        case .working: return (details?.plainAction ?? details?.action).map { "› \($0)" }
        case .remoteWorking: return "On \(item.session?.remoteHost ?? "another machine")"
        case .done: return details?.summary
        default: return nil
        }
    }
}
