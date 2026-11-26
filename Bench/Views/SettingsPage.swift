import BenchKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The parts of Settings, in the order the sidebar lists them.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, claude, accounts, usage, shortcuts, dictation, iphone, setup, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .claude: "Agents"
        case .accounts: "Accounts"
        case .usage: "Usage"
        case .shortcuts: "Shortcuts"
        case .dictation: "Dictation"
        case .iphone: "Remote Access"
        case .setup: "Setup"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .claude: "sparkle"
        case .accounts: "person.2"
        case .usage: "chart.bar"
        case .shortcuts: "bolt"
        case .dictation: "mic"
        case .iphone: "dot.radiowaves.left.and.right"
        case .setup: "checklist"
        case .updates: "arrow.down.circle"
        }
    }

    /// The line under the page's title.
    var subtitle: String {
        switch self {
        case .general: "How Workbench keeps your projects and agents tidy, and your work going."
        case .appearance: "Colors, fonts, and text size. The preview shows your choices as you make them."
        case .claude: "Claude Code and Codex: which you use, how their tabs open, and what they write for you in the background."
        case .accounts: "The accounts your agents sign in with. Give a project its own, like a work account for work projects."
        case .usage: ""
        case .shortcuts: "One-click tabs for commands you run often, and one-click messages to your agent."
        case .dictation: "Talk instead of typing in a chat's message box. What you say never leaves this Mac."
        case .iphone: "See your sessions and answer your agents from your iPhone, iPad, or another Mac."
        case .setup: "The tools Workbench uses, and whether this Mac has them."
        case .updates: "Which version you have, and how updates arrive."
        }
    }
}

// MARK: - Sidebar

/// Settings' sections in the sidebar, in place of the projects while
/// Settings is open, with Back at the top.
struct SettingsSidebar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarNavRow(title: "Back", symbol: "chevron.left", isSelected: false) {
                store.settingsSection = nil
            }
            .keyboardShortcut(.cancelAction)
            Text("Settings")
                .font(.ui(size: 20, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)
            ForEach(SettingsSection.allCases) { section in
                SidebarNavRow(title: section.title, symbol: section.symbol, isSelected: store.settingsSection == section) {
                    store.settingsSection = section
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

private struct SidebarNavRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.ui(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                Text(title)
                    .font(.ui(size: 13, weight: isSelected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? TerminalTheme.shared.selectedRow ?? Color(nsColor: .controlBackgroundColor)
                                     : Color.primary.opacity(isHovering ? 0.05 : 0))
                    .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 3, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Page

/// Settings in the main area: the chosen section's title, then its groups.
struct SettingsPage: View {
    let section: SettingsSection

    var body: some View {
        if section == .usage {
            UsageView()
        } else if section == .appearance {
            AppearanceSettingsPage(section: section)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.ui(size: 22, weight: .semibold))
                        Text(section.subtitle)
                            .font(.ui(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    content
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(TerminalTheme.shared.canvas)
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .general: GeneralSettings()
        case .appearance: EmptyView()
        case .claude: ClaudeSettings()
        case .accounts: ClaudeAccountsSettings()
        case .usage: EmptyView()
        case .shortcuts: ShortcutsSettings()
        case .dictation: DictationSettings()
        case .iphone: CompanionSettings()
        case .setup: SetupSettings()
        case .updates: UpdateSettings()
        }
    }
}

// MARK: - Building blocks

/// A titled panel of rows, with an optional note under it.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().opacity(0.6) }
                        row
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UsagePanel.fill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            if let footer {
                Text(footer)
                    .font(.ui(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A row with a title, an optional explanation under it, and a control on
/// the right.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    /// The longer explanation, behind an info button after the title, so
    /// the row itself stays one line of description.
    var more: String?
    @ViewBuilder var accessory: Accessory
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.ui(size: 13))
                    if let more {
                        SettingsInfoButton(title: title, text: more)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Only the words dim here. The control dims itself when it's
            // disabled, so fading the whole row faded it twice.
            .opacity(isEnabled ? 1 : 0.5)
            Spacer(minLength: 12)
            // The explanation is read after the control's name, the way a
            // hint is, so VoiceOver users hear what the setting does.
            accessory
                .accessibilityHint(more ?? detail ?? "")
        }
        // One row per VoiceOver stop, with the title and control inside it.
        .accessibilityElement(children: .contain)
    }
}

/// The small ⓘ after a setting's name. A click shows the rest of what
/// there is to say about it, which the pointer's tooltip shows too.
private struct SettingsInfoButton: View {
    let title: String
    let text: String
    @State private var isShown = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.ui(size: Theme.TypeScale.meta, weight: .medium))
                .foregroundStyle(isHovering || isShown ? Color.primary : Color.secondary.opacity(0.75))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressableChip)
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.hover, value: isHovering)
        .help(text)
        .accessibilityLabel("More about \(title)")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.ui(size: Theme.TypeScale.bodySmall))
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

extension SettingsRow where Accessory == AnyView {
    /// A row whose control is a switch.
    init(_ title: String, detail: String? = nil, more: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.more = more
        // The row shows the title, so the switch hides its own. A custom
        // style's button doesn't inherit the hidden title as its spoken
        // name, so it's set as the label too.
        accessory = AnyView(Toggle(title, isOn: isOn)
            .toggleStyle(.benchSwitch)
            .labelsHidden()
            .accessibilityLabel(title))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    @AppStorage(WorktreeCleaner.autoCleanKey) private var autoClean = false
    @AppStorage(Worktrees.chosenFolderKey) private var worktreesFolder = ""
    @AppStorage(Worktrees.trashKey) private var trashesWorktrees = false
    @AppStorage(PlanUsageMonitor.shownKey) private var showsPlanUsage = true
    @AppStorage(MacActivity.shownKey) private var showsMacActivity = true
    @AppStorage(SimulatorWatch.shownKey) private var showsSimulators = true
    @AppStorage(PlanUsageMonitor.paceKey) private var showsPace = true
    @AppStorage(Analytics.optedOutKey) private var analyticsOptedOut = false

    var body: some View {
        KeepWorkingSettings()
        SettingsGroup(title: "Sidebar") {
            SettingsRow(title: "Group projects",
                        detail: "Sort projects by when you last used them, or into groups you name.",
                        more: "By Activity sorts the sidebar into Pinned, Active, Recent, and Inactive from when you last used each project. Custom Groups lets you make your own named groups, like a backend and its app together. Your iPhone shows the same groups.") {
                Picker("Group projects", selection: Binding(get: { store.grouping }, set: { store.grouping = $0 })) {
                    Text("By Activity").tag(SidebarGrouping.activity)
                    Text("Custom Groups").tag(SidebarGrouping.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if store.grouping == .activity {
                SidebarTimesRows()
            }
        }
        SettingsGroup(title: "Agents") {
            SettingsRow("Clean up merged agents automatically",
                        detail: "Deletes a merged agent's worktree and branch when nothing would be lost.",
                        more: "When an agent's pull request merges, its worktree and its local branch are deleted, but only when nothing would be lost. Otherwise the agent shows a Clean Up button.",
                        isOn: $autoClean)
            SettingsRow("Move removed worktrees to the Trash",
                        detail: "Keeps a removed agent's folder in the Trash until you empty it.",
                        more: "Cleaning up or discarding an agent deletes its worktree folder right away, which frees the space. Turn this on to send the folder to the Trash instead, where it stays (and takes up room) until you empty it.",
                        isOn: $trashesWorktrees)
            SettingsRow(title: "Where new worktrees go", detail: worktreesFolderDetail) {
                HStack(spacing: 8) {
                    if !worktreesFolder.isEmpty {
                        Button("Use Default") { worktreesFolder = "" }
                    }
                    Button("Choose…") { chooseWorktreesFolder() }
                }
                .fixedSize()
            }
        }
        SettingsGroup(title: "Mac Activity") {
            SettingsRow("Show CPU and memory in the sidebar",
                        detail: "Two rings at the foot of the sidebar that light up when your Mac is under load.",
                        more: "They stay grey until your Mac is under load. Rest the pointer on them for the numbers and which projects are responsible. Checking costs almost nothing, and stops while Workbench is hidden.",
                        isOn: $showsMacActivity)
            SettingsRow("Show running simulators in the sidebar",
                        detail: "A count beside the rings whenever Xcode simulators are running.",
                        more: "Simulators are easy to forget: close the Simulator window, or let Xcode start one for a preview or a test run, and it keeps running out of sight. The count is green for the first hour, yellow after one, orange after two, and red after a day. Rest the pointer on it to see each simulator, how long it has been on, how much memory it holds, and to shut it down. Nothing shows while none are running, and checking stops while Workbench is hidden.",
                        isOn: $showsSimulators)
        }
        SettingsGroup(title: "Plan Usage") {
            SettingsRow("Show plan usage in the sidebar",
                        detail: "Rings at the foot of the sidebar for your Claude plan's limits.",
                        more: "They show your plan's 5-hour, weekly, and per-model limits, and stay grey until a limit is half used. Rest the pointer on them for percentages and reset times. Accounts without plan limits, like API keys, get one ring for this month's estimated spending instead.",
                        isOn: $showsPlanUsage)
            SettingsRow("Mark how far into each window you are",
                        detail: "A tick on each ring: an arc past its tick is going faster than the window.",
                        isOn: $showsPace)
                .disabled(!showsPlanUsage)
        }
        SettingsGroup(title: "Privacy") {
            SettingsRow("Share anonymous usage data",
                        detail: "Counts of what you use and crash reports. Never your code or prompts.",
                        more: "Counts of what you use, like agent tabs opened or agents started, and a report when the app crashes, with a random ID that isn't linked to you. Never your code, prompts, file or project names, or location.",
                        isOn: Binding(get: { !analyticsOptedOut }, set: { Analytics.isOptedOut = !$0 }))
        }
        MoveSettingsGroup()
    }

    private var worktreesFolderDetail: String {
        let existing = "Worktrees you already have stay where they are."
        return worktreesFolder.isEmpty
            ? "Next to each repo, in a folder like Bench.worktrees. \(existing)"
            : "\(worktreesFolder.abbreviatingWithTilde), with a folder inside it for each repo. \(existing)"
    }

    private func chooseWorktreesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = worktreesFolder.isEmpty ? URL(fileURLWithPath: NSHomeDirectory()) : URL(fileURLWithPath: worktreesFolder)
        panel.message = "Choose where new worktrees go"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        worktreesFolder = url.path
    }
}

/// How long projects stay in Active and Recent, and whether their tabs
/// close when they go Inactive. Only with the sidebar sorted by activity.
private struct SidebarTimesRows: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SettingsRow(title: "Keep projects in Active for",
                    detail: "After you last use a project. Projects where an agent is working or waiting on you stay in Active either way.") {
            Picker("Keep projects in Active for", selection: Binding(
                get: { store.sidebarTimes.active },
                set: { store.sidebarTimes = SidebarTimes(active: $0, inactiveAfter: store.sidebarTimes.inactiveAfter) })) {
                ForEach(SidebarTimes.activeChoices, id: \.self) { Text(SidebarTimes.name($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        SettingsRow(title: "Move to Inactive after",
                    detail: "Projects you haven't used for this long move to Inactive. Until then, they wait under Recent.") {
            Picker("Move to Inactive after", selection: Binding(
                get: { store.sidebarTimes.inactiveAfter },
                set: { store.sidebarTimes = SidebarTimes(active: store.sidebarTimes.active, inactiveAfter: $0) })) {
                ForEach(SidebarTimes.inactiveChoices(after: store.sidebarTimes.active), id: \.self) {
                    Text(SidebarTimes.name($0)).tag($0)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        SettingsRow("Close tabs when a project goes Inactive",
                    detail: "Coming back to it shows the New Tab page and its recent sessions, instead of tabs from days ago. Tabs where an agent is still working stay open.",
                    isOn: Binding(get: { store.closesInactiveTabs }, set: { store.closesInactiveTabs = $0 }))
    }
}

/// Keep Working: Claude tabs run in the session keeper, so quitting or
/// updating Workbench doesn't stop them.
private struct KeepWorkingSettings: View {
    @State private var isOn = SessionKeeper.isEnabled
    @State private var couldNotStart = false

    var body: some View {
        SettingsGroup(title: "Keep Working",
                      footer: footer) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow("Keep agents working while Workbench restarts",
                            detail: "Agent tabs carry on in the background when Workbench quits or updates.",
                            more: "Agent tabs carry on in the background when Workbench quits or restarts to update, then pick up right where they are when it opens again. Nothing stops halfway, nothing needs resuming, and updates can install while an agent is busy.",
                            isOn: Binding(get: { isOn }, set: { on in
                                isOn = on
                                couldNotStart = !SessionKeeper.setEnabled(on)
                            }))
                HStack(alignment: .top, spacing: 18) {
                    KeepWorkingStep(symbol: "sparkle", title: "Your agent is working", detail: "You quit, or an update installs.")
                    KeepWorkingStep(symbol: "arrow.clockwise", title: "Workbench restarts", detail: "It keeps going in the background.")
                    KeepWorkingStep(symbol: "checkmark.circle", title: "You're back", detail: "The tab shows what it did meanwhile.")
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var footer: String {
        if couldNotStart {
            return "Workbench couldn't start the helper that keeps tabs running, so agent tabs run the usual way for now. It tries again the next time Workbench opens."
        }
        return isOn
            ? "Works for agent tabs on this Mac. Agent tabs you open from now on are kept, and the rest join them the next time Workbench opens."
            : "Works for agent tabs on this Mac. Off: quitting stops your agents, and their tabs offer to continue when Workbench opens again."
    }
}

private struct KeepWorkingStep: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(TerminalTheme.shared.working)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ui(size: 12, weight: .medium))
                Text(detail)
                    .font(.ui(size: Theme.TypeScale.bodySmall))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Claude

/// Turns an agent on or off.
private struct AgentSwitchRow: View {
    let name: String
    let key: String
    let changed: () -> Void
    @State private var isOn: Bool

    init(name: String, isOn: Bool, key: String, changed: @escaping () -> Void) {
        self.name = name
        self.key = key
        self.changed = changed
        _isOn = State(initialValue: isOn)
    }

    var body: some View {
        SettingsRow(title: "Use \(name)",
                    detail: "Shows \(name) in the New Tab menu and wherever you pick an agent.",
                    more: "\(name) runs in the same tabs, with the same chat, cards and shortcuts. Workbench passes its hooks when it starts \(name) and never changes \(name)'s own settings. The first time, \(name) asks you to trust those hooks.") {
            Toggle("Use \(name)", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: isOn) { _, on in
                    UserDefaults.standard.set(on, forKey: key)
                    changed()
                }
        }
    }
}

/// The command an agent's new tabs run.
private struct AgentCommandRow: View {
    let name: String
    let program: String
    @AppStorage private var command: String

    init(name: String, program: String, key: String) {
        self.name = name
        self.program = program
        _command = AppStorage(wrappedValue: "", key)
    }

    var body: some View {
        SettingsRow(title: "\(name) command",
                    detail: "What new \(name) tabs run. Leave it empty for plain \(program).",
                    more: "For example, your own wrapper script, or \(program) with options you always want. Workbench adds its own options after it. It never changes \(name)'s own settings.") {
            VStack(alignment: .trailing, spacing: 6) {
                TextField("", text: $command, prompt: Text(program))
                    .accessibilityLabel("\(name) command")
                    .font(.ui(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(width: 320)
                Button("Use Default") { command = "" }
                    .controlSize(.small)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Goes back to plain \(program).")
            }
        }
    }
}

/// Which agent new tabs run, shown once there's more than one to choose.
private struct AgentChoiceSettings: View {
    @AppStorage(Agents.defaultAgentKey) private var defaultAgent = AgentID.claude.rawValue
    /// Bumped when a switch changes, so the rows under it redraw.
    @State private var refresh = 0
    var check = SetupCheck.shared

    var body: some View {
        let _ = refresh
        SettingsGroup(title: "Coding Agents",
                      footer: "Workbench is built for Claude Code. Codex support is in beta: the everyday work is there, and a few things, like its own questions and plans, still happen in its terminal. Installing an agent here runs its own installer in a small terminal.") {
            ForEach(check.agents) { agent in
                AgentStatusRow(agent: agent)
            }
            // A switch for an agent that's here but you'd rather not see.
            ForEach(Agents.optional.filter { AgentPrograms.isInstalled($0.program) }, id: \.id) { agent in
                AgentSwitchRow(name: agent.name, isOn: Agents.isOffered(agent.id), key: Agents.switchKey(for: agent.id)) { refresh += 1 }
            }
            if Agents.offered.count > 1 {
                SettingsRow(title: "New tabs run",
                            detail: "The agent a new tab, a new agent on a branch, and Workbench's own recaps use.",
                            more: "You can still open a tab with the other one from the New Tab menu. Tabs you already have keep the agent they started with.") {
                    Picker("New tabs run", selection: $defaultAgent) {
                        ForEach(Agents.offered, id: \.id) { agent in
                            Text(agent.name).tag(agent.id.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                // Claude's command is with its tabs' settings, below.
                ForEach(Agents.offered.filter { $0.id != AgentID.standard }, id: \.id) { agent in
                    AgentCommandRow(name: agent.name, program: agent.program, key: agent.commandKey)
                }
            }
        }
        .task { await check.run() }
    }
}

/// One agent: whether it's ready, and a way to install it or sign in.
private struct AgentStatusRow: View {
    let agent: AgentSetup

    private var detail: String {
        switch agent.state {
        case .checking: agent.maker
        case .ready(let version): agent.maker + (version.map { " Version \($0)." } ?? "")
        case .signedOut: agent.maker + " Installed, but not signed in."
        case .notInstalled: agent.maker + " Not installed: " + agent.installCommand
        }
    }

    var body: some View {
        SettingsRow(title: agent.title, detail: detail) {
            switch agent.state {
            case .checking:
                ProgressView().controlSize(.small)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Status.done)
                    .font(.ui(size: 12, weight: .medium))
            case .signedOut:
                AgentSetupButton(agent: agent, action: .signIn)
            case .notInstalled:
                AgentSetupButton(agent: agent, action: .install)
            }
        }
    }
}

private struct ClaudeSettings: View {
    @Environment(AppStore.self) private var store
    @AppStorage(AppStore.newTabsShowChatKey) private var newTabsShowChat = false
    @AppStorage(Recaps.enabledKey) private var writesRecaps = true
    @AppStorage(Agents.claude.commandKey) private var claudeCommand = ""
    /// Empty until the first artifact click asks.
    @AppStorage(ArtifactLinks.targetKey) private var artifactTarget = ""

    var body: some View {
        AgentChoiceSettings()
        SettingsGroup(title: "Agent Tabs") {
            SettingsRow(title: "Show new agent tabs as",
                        detail: "Chat shows the conversation with cards for questions and permissions.",
                        more: "Chat shows the conversation the way your phone does. Switch any tab with View > Show as Chat (⌥⌘T). The agent runs in the terminal either way.") {
                Picker("Show new agent tabs as", selection: $newTabsShowChat) {
                    Text("Terminal").tag(false)
                    Text("Chat").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Open artifacts",
                        detail: "Where links to pages Claude publishes go.",
                        more: "A Workbench tab opens next to the one you're in. To read it beside the chat, right-click the tab and choose Split With. The first time you sign in to claude.ai there, Workbench remembers it.") {
                Picker("Open artifacts", selection: $artifactTarget) {
                    Text("Ask Next Time").tag("")
                    Text("In a Workbench Tab").tag(ArtifactLinkTarget.workbench.rawValue)
                    Text("In Your Browser").tag(ArtifactLinkTarget.browser.rawValue)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Claude command",
                        detail: "What new Claude tabs run. Leave it empty for plain claude.",
                        more: "For example, claude --permission-mode acceptEdits or your own wrapper script. Workbench adds its own options after it, so a wrapper needs to pass them on to claude.") {
                VStack(alignment: .trailing, spacing: 6) {
                    TextField("", text: $claudeCommand, prompt: Text("claude"))
                        .accessibilityLabel("Command")
                        .font(.ui(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 320)
                    Button("Use Default") { claudeCommand = "" }
                        .controlSize(.small)
                        .disabled(claudeCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityHint("Goes back to plain claude.")
                }
            }
            let warnings = ClaudeCommandCheck.warnings(for: claudeCommand)
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings, id: \.self) { warning in
                        Label {
                            Text(warning)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.Status.waiting)
                        }
                        .font(.ui(size: 12))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        SettingsGroup(title: "Written by Your Agent",
                      footer: "These run the agent you chose for new tabs in the background, with no tools and nothing saved to your past sessions. They use a small, fast model and count toward Usage.") {
            SettingsRow("Recaps when an agent finishes",
                        detail: "A sentence about what got done after each turn where the agent did some work, in the Overview, the sidebar, and on your iPhone.",
                        isOn: $writesRecaps)
        }
        if FeedbackAgent.isAvailable {
            FeedbackAgentSettings()
        }
    }
}

/// Only on the developer's own Macs: see `FeedbackAgent.availableKey`.
private struct FeedbackAgentSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(FeedbackAgent.self) private var agent

    var body: some View {
        @Bindable var agent = agent
        SettingsGroup(title: "Feedback Agent",
                      footer: "Feedback is still emailed as usual. Agents treat it as a report, not instructions, and never push or open a pull request. The agent asks before anything risky, the way it does in any tab. At most \(FeedbackAgent.dailyLimit) start in a day. The rest wait on the relay for up to two weeks.") {
            SettingsRow("Look into new feedback",
                        detail: "Starts an agent to look into each piece of feedback you send.",
                        more: "Every minute, Workbench picks up feedback sent from Send Feedback and starts an agent in its own worktree to investigate and try a fix. Feedback that's only praise is thrown away.",
                        isOn: $agent.isEnabled)
            SettingsRow(title: "Project", detail: "Where the agents work.") {
                Picker("Project", selection: $agent.projectID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(store.topLevelProjects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(title: "Queue key", detail: "The relay's FEEDBACK_QUEUE_SECRET.") {
                SecureField("", text: $agent.secret)
                    .accessibilityLabel("Queue key")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            SettingsRow(title: "Status") {
                HStack(spacing: 10) {
                    Text(statusText)
                        .foregroundStyle(agent.isProblem ? Theme.Status.failed : Color.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                    Button("Check Now") { agent.check() }
                        .disabled(!agent.isEnabled || !agent.isReady || agent.isChecking)
                }
            }
        }
    }

    private var statusText: String {
        if !agent.isEnabled { return "Off" }
        if !agent.isReady { return "Choose a project and paste the queue key." }
        if agent.isChecking { return "Checking…" }
        return agent.status ?? "Waiting for the first check."
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    @Environment(TabShortcuts.self) private var shortcuts
    @State private var editing: TabShortcut?

    var body: some View {
        @Bindable var shortcuts = shortcuts
        SettingsGroup(title: "Tab Shortcuts",
                      footer: "Each shortcut opens a terminal tab that runs its command in the project's folder. Find them on the New Tab page and in the menu on the + button's arrow. A project's shortcuts also show in its worktrees, so each runs in that worktree's own checkout. Drag to reorder.") {
            if shortcuts.all.isEmpty {
                Text("No shortcuts yet. Add one for a command you run often, like `npm test`, `make watch` or `ssh my-server`.")
                    .font(.ui(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(shortcuts.all) { shortcut in
                        ShortcutRow(shortcut: shortcut) { editing = shortcut }
                            .listRowBackground(Color.clear)
                    }
                    .onMove { shortcuts.move(from: $0, to: $1) }
                }
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(shortcuts.all.count) * 40 + 4)
            }
            HStack {
                Spacer()
                Button("Add Shortcut…") { editing = TabShortcut(name: "", command: "") }
            }
        }
        SettingsGroup(title: "Dev Server") {
            SettingsRow("Show a dev server button in JavaScript projects",
                        detail: "Shows when package.json has a dev script, and runs it.",
                        more: "It runs the script with the project's package manager. Clicking it again switches to the server if it's still running.",
                        isOn: $shortcuts.showsDevButton)
        }
        .sheet(item: $editing) { shortcut in
            ShortcutEditor(shortcut: shortcut, isNew: !shortcuts.all.contains { $0.id == shortcut.id })
        }
        ClaudeActionsSettings()
    }
}

/// The buttons under the branch in the Changes panel, each a message to
/// Claude. Commit, Push, and Open PR come built in.
private struct ClaudeActionsSettings: View {
    @Environment(ClaudeActions.self) private var actions
    @State private var editing: ClaudeAction?

    var body: some View {
        SettingsGroup(title: "Agent Actions",
                      footer: "Each action is a button in the Changes panel that sends its message to the project's agent tab, or opens one. The agent does the git work itself, so the same buttons work on GitHub, GitLab, or anywhere else. Write {branch} and {base} in a message to put in the branch names. Drag to reorder.") {
            if actions.all.isEmpty {
                Text("No actions. Add one, or restore Commit, Push, and Open PR.")
                    .font(.ui(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(actions.all) { action in
                        ClaudeActionRow(action: action) { editing = action }
                            .listRowBackground(Color.clear)
                    }
                    .onMove { actions.move(from: $0, to: $1) }
                }
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(actions.all.count) * 40 + 4)
            }
            HStack {
                if !actions.isDefault {
                    Button("Restore Defaults…") { confirmRestoreDefaults() }
                }
                Spacer()
                Button("Add Action…") { editing = ClaudeAction(name: "", prompt: "") }
            }
        }
        .sheet(item: $editing) { action in
            ClaudeActionEditor(action: action, isNew: !actions.all.contains { $0.id == action.id })
        }
    }

    /// Asks first: restoring throws away every action you wrote or changed.
    private func confirmRestoreDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore the default actions?"
        alert.informativeText = "Commit, Push, and Open PR come back as they were. Actions you added or changed are deleted."
        alert.addButton(withTitle: "Restore Defaults").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        actions.restoreDefaults()
    }
}

// MARK: - iPhone

/// The relay's address, saved when you press Return or click away, so a
/// half-typed address never gets used.
private struct RelayAddressField: View {
    let relay: CompanionRelay
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(CompanionRelay.defaultAddress))
            .accessibilityLabel("Relay address")
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)
            .focused($isFocused)
            .onAppear { text = relay.customAddress }
            .onSubmit { relay.setCustomAddress(text) }
            .onChange(of: isFocused) { _, focused in
                if !focused { relay.setCustomAddress(text) }
            }
    }
}

private struct CompanionSettings: View {
    @Environment(Companion.self) private var companion

    var body: some View {
        @Bindable var companion = companion
        SettingsGroup {
            SettingsRow("Let my iPhone and other Macs connect",
                        detail: "Shows your projects and agent sessions on your own devices.",
                        more: "The Workbench app on your iPhone, or Workbench on another Mac, shows your projects and what each agent session is doing. It connects over your home network, Tailscale, or the Workbench relay if you turn it on, and only devices you've paired can reach it.",
                        isOn: $companion.isEnabled)
            SettingsRow(title: "Get Workbench for iPhone",
                        detail: "Workbench for iPhone is free on the App Store.") {
                Link("Open App Store", destination: Companion.appStoreURL)
            }
        }
        if companion.isEnabled {
            SettingsGroup(title: "Pair Your iPhone or Another Mac") {
                pairing
            }
            SettingsGroup(title: "Away from Home") {
                SettingsRow("Use the Workbench relay",
                            detail: "Reach this Mac from anywhere, with no account and nothing else to install.",
                            more: "Your Mac and your paired devices both connect out to the relay, which passes messages between them when they can't reach each other directly. Everything is sealed on your devices with keys from the pairing code, so the relay can't read it, and it keeps none of it. Your home network and Tailscale are still used first when they answer.",
                            isOn: Binding(get: { companion.relay.isOn }, set: { companion.relay.setOn($0) }))
                if companion.relay.isOn {
                    SettingsRow(title: "Relay address",
                                detail: "Leave empty to use Workbench's. Fill in to use one you host.") {
                        RelayAddressField(relay: companion.relay)
                    }
                }
            }
            SettingsGroup(title: "Status") {
                SettingsRow(title: "Server") {
                    Text(companion.server.isRunning ? "Running" : (companion.server.lastError ?? "Starting…"))
                        .foregroundStyle(.secondary)
                }
                SettingsRow(title: "Home network") {
                    Text(companion.server.localPort != nil ? "On this network" : (companion.server.localError ?? "Starting…"))
                        .foregroundStyle(.secondary)
                }
                SettingsRow(title: "Tailscale") {
                    Group {
                        if !Tailscale.isInstalled {
                            Text("Not set up").foregroundStyle(.secondary)
                        } else if let error = companion.tailscaleError {
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(error).foregroundStyle(Theme.Status.failed)
                                if companion.needsHTTPS {
                                    Link("Open Tailscale DNS Settings", destination: Tailscale.httpsSettingsURL)
                                }
                            }
                        } else if let host = companion.address {
                            Text(companion.isServing ? "https://\(host)" : host).foregroundStyle(.secondary)
                        } else {
                            Text("Checking…").foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
                SettingsRow(title: "Relay") {
                    Text(companion.relay.statusText)
                        .foregroundStyle(companion.relay.isProblem ? AnyShapeStyle(Theme.Status.failed) : AnyShapeStyle(.secondary))
                }
                SettingsRow(title: "Connected") {
                    let devices = companion.server.connectedDevices
                    Text(devices.isEmpty ? "No phones right now" : devices.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            notifications
        }
        Color.clear
            .frame(height: 0)
            .task { if companion.isEnabled { await companion.publish() } }
            // Notices HTTPS being turned on while this page is open.
            .task(id: companion.needsHTTPS) {
                while companion.needsHTTPS, companion.isEnabled, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    await companion.publish()
                }
            }
    }

    /// Asks first: a new code cuts off every device that paired with the
    /// old one.
    private func confirmNewCode() {
        let alert = NSAlert()
        alert.messageText = "Make a new pairing code?"
        alert.informativeText = "Every paired iPhone, iPad and Mac stops connecting until it pairs again with the new code."
        alert.addButton(withTitle: "Make New Code").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        companion.regenerateToken()
    }

    /// Asks first: this deletes Workbench's copy of the key, and Apple only
    /// lets a key be downloaded once.
    private func confirmRemoveKey() {
        let alert = NSAlert()
        alert.messageText = "Remove the key file?"
        alert.informativeText = "Workbench deletes its copy of your APNs key and sends notifications through its own push service instead. To use the key again you'll need the .p8 file you downloaded from Apple."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        companion.push.removeKey()
    }

    @ViewBuilder private var pairing: some View {
        if let url = companion.pairing?.url, let image = PairingCode.qrCode(for: url.absoluteString) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 168, height: 168)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Open Workbench on your iPhone and scan this code.")
                        .font(.ui(size: 13, weight: .medium))
                    Text("The code holds how to reach this Mac and a secret. Anyone who scans it can see your sessions, so keep it to yourself.")
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                    Text("For another Mac running Workbench, choose Copy Pairing Link. On that Mac, click + next to This Mac at the top of the sidebar, and paste the link.")
                        .font(.ui(size: 12))
                        .foregroundStyle(.secondary)
                    if !companion.hasTailscale, !companion.relay.isOn {
                        HStack(spacing: 4) {
                            Text("Works on your home Wi-Fi. To use it anywhere, turn on the Workbench relay below, or set up Tailscale.")
                                .font(.ui(size: 12))
                                .foregroundStyle(.secondary)
                            Link("Set Up Tailscale", destination: Tailscale.downloadURL)
                                .font(.ui(size: 12))
                        }
                    }
                    HStack {
                        Button("Copy Pairing Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                        Button("Make a New Code…") { confirmNewCode() }
                            .help("Paired iPhones, iPads and Macs will need the new code.")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Getting the pairing code ready…")
                .font(.ui(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var notifications: some View {
        @Bindable var push = companion.push
        // Your own key only works for a phone app built by your developer
        // team, so its fields stay out of the way unless you've set one up.
        let showsKey = push.hasKeyFile || UserDefaults.standard.bool(forKey: "showsPushSetup")
        return SettingsGroup(title: "Notifications",
                             footer: push.usesRelay
                                ? "Workbench tells your phone when an agent needs you, when it finishes, and when checks and deploys finish, for the projects you choose. Before you step away, right-click a project in the sidebar and choose Send Notifications to iPhone. Notifications go through Workbench's push service on their way to Apple. Nothing is stored."
                                : "Workbench only notifies your phone about projects you choose: right-click one in the sidebar and choose Send Notifications to iPhone. Notifications go straight from this Mac to Apple, signed with your APNs key. To make one: Certificates, Identifiers & Profiles › Keys › add a key with Apple Push Notifications service, then download the .p8 file.") {
            SettingsRow(title: "Status", detail: push.lastResult) {
                HStack {
                    Group {
                        if let problem = push.setupProblem {
                            Text(problem)
                        } else if push.devices.isEmpty {
                            Text("Turn on notifications in Workbench on your phone.")
                        } else {
                            Text("Ready for " + push.devices.map(\.name).joined(separator: ", "))
                        }
                    }
                    .foregroundStyle(.secondary)
                    if push.isReady, !push.devices.isEmpty {
                        Button("Send a Test") { push.sendTest() }
                    }
                }
            }
            if showsKey {
                SettingsRow(title: "Key file", detail: push.hasKeyFile ? "apns-key.p8 in Application Support › Bench" : "None. Using Workbench's push service.") {
                    HStack {
                        if push.hasKeyFile {
                            Button("Remove…", role: .destructive) { confirmRemoveKey() }
                                .help("Send through Workbench's push service instead")
                        }
                        Button(push.hasKeyFile ? "Replace…" : "Choose…") { push.presentKeyPicker() }
                    }
                }
                if push.hasKeyFile {
                    SettingsRow(title: "Key ID") {
                        // The names go on as labels rather than titles, since a
                        // titled field would show its title as placeholder text.
                        TextField("", text: $push.keyID, prompt: Text("ABC123DEFG"))
                            .accessibilityLabel("Key ID")
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                    SettingsRow(title: "Team ID") {
                        TextField("", text: $push.teamID)
                            .accessibilityLabel("Team ID")
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                }
            }
        }
    }
}

// MARK: - Setup

private struct SetupSettings: View {
    var check = SetupCheck.shared

    var body: some View {
        SettingsGroup(title: "What Workbench Uses",
                      footer: "Workbench looks for these tools the same way your shell does.") {
            ForEach(Array(check.items.enumerated()), id: \.element.id) { index, item in
                SetupRow(item: item, order: index)
            }
            HStack {
                Spacer()
                if check.isChecking { ProgressView().controlSize(.small) }
                Button("Check Again") { Task { await check.run(rescan: true) } }
                    .disabled(check.isChecking)
            }
        }
        .task { await check.run() }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow
    @State private var automaticallyChecks = false
    @AppStorage(Updater.installsWhenIdleKey) private var installsWhenIdle = Updater.installsWhenIdleByDefault

    private var version: String { AppVersion.current.long }

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Workbench \(version)") {
                HStack {
                    Button("What's New") { openWindow(id: "whats-new") }
                    Button("Acknowledgements") { openWindow(id: "acknowledgements") }
                }
            }
        }
        if updater.isEnabled {
            SettingsGroup(title: "Updates",
                          footer: installsWhenIdle
                          ? "Updates download in the background and install when you quit Workbench or choose Restart to Update. They also install after 30 minutes with no input and nothing running, which restarts Workbench."
                          : "Updates download in the background and install when you quit Workbench or choose Restart to Update.") {
                SettingsRow("Check for updates automatically", isOn: $automaticallyChecks)
                    .onChange(of: automaticallyChecks) { _, on in updater.automaticallyChecks = on }
                SettingsRow("Install updates when this Mac is idle", isOn: $installsWhenIdle)
                SettingsRow(title: "Check now") {
                    Button("Check for Updates") { updater.checkForUpdates() }
                }
            }
            .onAppear { automaticallyChecks = updater.automaticallyChecks }
        } else {
            SettingsGroup {
                Text("This is a development build, so it doesn't update itself.")
                    .font(.ui(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
