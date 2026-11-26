import BenchKit
import SwiftUI

/// The continue buttons' fill and the color of their labels: the
/// palette's accent and the text that reads on it, so the buttons change
/// with the dots and checkmarks when you pick a theme.
@MainActor
private var continueButton: (fill: Color, ink: Color) {
    let palette = TerminalTheme.shared.chatPalette
    return (palette.accent, palette.onAccent)
}

/// The agent new tabs run, for the pages that name one.
@MainActor private var agentName: String { Agents.standard.name }

/// The welcome a new user sees, filling the window: what Bench is, a check
/// of the tools it uses, how you like to see Claude, your theme, your first
/// projects, and your iPhone. Ends on your first project's start page.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, setup, style, theme, projects, iPhone, done
    }

    @Environment(AppStore.self) private var store
    @Environment(Companion.self) private var companion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Called with the project to open, if any were added.
    let finish: () -> Void

    @State private var step: Step = Self.firstStep
    @State private var forward = true
    /// Folders picked on the Projects step.
    @State private var picked: [String] = []
    /// Shown when Continue is pressed with something required missing.
    @State private var warnsAboutSetup = false

    private var palette: CompanionPalette { TerminalTheme.shared.chatPalette }

    var body: some View {
        ZStack {
            palette.canvas
            ClaudeGlow(color: palette.accent, center: UnitPoint(x: 0.5, y: step == .welcome ? 0.38 : 0.0),
                       reach: step == .welcome ? 0.5 : 0.65)
                .animation(.smooth(duration: 0.8), value: step)
            VStack(spacing: 0) {
                ZStack {
                    page
                        .id(step)
                        // With keyboard navigation on, AppKit drew a focus
                        // ring where a control sat before its page slid in,
                        // so it floated over the wrong thing. Return and
                        // Escape still work through the footer's shortcuts.
                        .focusEffectDisabled()
                        .transition(pageTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if step != .welcome && step != .done {
                    footer
                        .transition(.opacity)
                }
            }
        }
        .foregroundStyle(palette.ink)
        .onAppear {
            logStep()
        }
        .onChange(of: step) { logStep() }
        .alert(setupWarning.title, isPresented: $warnsAboutSetup) {
            Button("Fix It First", role: .cancel) {}
            Button("Continue Anyway") {
                Analytics.capture(.onboardingContinuedAnyway, ["missing": missingTools])
                advance()
            }
        } message: {
            Text(setupWarning.message)
        }
    }

    /// What's missing, in words, for the Continue warning.
    private var setupWarning: (title: String, message: String) {
        let check = SetupCheck.shared
        let later = "You can finish setting it up later in Settings > Setup."
        let gitMissing = check.toolItems.contains { item in item.id == "git" && { if case .missing = item.status { true } else { false } }() }
        let noAgent = check.readyAgents.isEmpty
        if noAgent, gitMissing {
            return ("Workbench isn't ready yet",
                    "It needs Claude Code and git. Agent tabs, changes, and branches won't work until they're set up. \(later)")
        }
        if noAgent {
            let signedOut = check.agents.filter { $0.state == .signedOut }
            if let agent = signedOut.first {
                return ("\(agent.product) isn't signed in",
                        "Agent tabs won't be able to start until you sign in. \(later)")
            }
            return ("Claude Code isn't installed",
                    "Workbench runs Claude Code in its agent tabs (or Codex, in beta), so they won't work until one is installed. \(later)")
        }
        return ("git isn't installed",
                "Workbench uses git to show changes, branches, and agents. Those won't work until Apple's command line tools are installed. \(later)")
    }

    /// BENCH_WELCOME_STEP=<n> opens on a later step, for checking layouts.
    private static var firstStep: Step {
        #if DEBUG
        if let n = ProcessInfo.processInfo.environment["BENCH_WELCOME_STEP"].flatMap(Int.init), let step = Step(rawValue: n) { return step }
        #endif
        return .welcome
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
            removal: .opacity.combined(with: .offset(x: forward ? -40 : 40)))
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: WelcomeStep(palette: palette) { go(to: .setup) }
        case .setup: SetupStep(palette: palette)
        case .style: StyleStep(palette: palette)
        case .theme: ThemeStep()
        case .projects: ProjectsStep(palette: palette, picked: $picked)
        case .iPhone: PhoneStep(palette: palette)
        case .done: DoneStep(palette: palette, projectName: firstProjectName, finish: complete)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { go(to: Step(rawValue: step.rawValue - 1) ?? .welcome) }
                .buttonStyle(.pressable)
                .foregroundStyle(palette.inkMuted)
                .keyboardShortcut(.cancelAction)
            Spacer()
            dots
            Spacer()
            Button(action: next) {
                Text(continueTitle)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundStyle(continueButton.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background(Capsule().fill(continueButton.fill))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .font(.ui(size: 13, weight: .medium))
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    /// One dot per step between the welcome and the end.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.dropFirst().dropLast(), id: \.self) { item in
                Capsule()
                    .fill(item == step ? palette.accent : palette.ink.opacity(item.rawValue < step.rawValue ? 0.35 : 0.12))
                    .frame(width: item == step ? 22 : 7, height: 7)
            }
        }
        .animation(.snappy(duration: 0.3), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue) of \(Step.allCases.count - 2)")
    }

    private var continueTitle: String {
        switch step {
        case .projects: picked.isEmpty ? "Skip for Now" : (picked.count == 1 ? "Add Project" : "Add \(picked.count) Projects")
        case .iPhone: "Continue"
        default: "Continue"
        }
    }

    private func next() {
        if step == .setup, SetupCheck.shared.needsAttention {
            warnsAboutSetup = true
            return
        }
        advance()
    }

    private func advance() {
        if step == .projects, !picked.isEmpty {
            store.addProjects(picked.map { URL(fileURLWithPath: $0) }, opensClaude: false, source: .welcome)
        }
        go(to: Step(rawValue: step.rawValue + 1) ?? .done)
    }

    private func go(to target: Step) {
        forward = target.rawValue > step.rawValue
        withAnimation(.smooth(duration: 0.45)) { step = target }
    }

    private var firstProjectName: String? {
        guard !picked.isEmpty else { return nil }
        return store.selectedProject?.name
    }

    private func complete() {
        Analytics.capture(.onboardingCompleted, [
            "projects_added": picked.count,
            "chat_view": AppStore.newClaudeTabsShowChat,
            "theme_matches": TerminalTheme.shared.matches,
            "theme_source": TerminalTheme.shared.source.rawValue,
            "iphone_enabled": companion.isEnabled,
            "relay_enabled": companion.isEnabled && companion.relay.isOn,
            "missing": missingTools,
            "replay": seenBefore,
        ])
        UserDefaults.standard.set(true, forKey: SetupCheck.seenKey)
        finish()
    }

    /// Whether the welcome had been finished before, so a replay from the
    /// Help menu doesn't count as a new user.
    @State private var seenBefore = UserDefaults.standard.bool(forKey: SetupCheck.seenKey)

    private func logStep() {
        Analytics.capture(.onboardingStepViewed, ["step": "\(step)", "index": step.rawValue, "replay": seenBefore])
    }

    /// What the check found missing, like "claude_signed_out,git", or "none".
    private var missingTools: String {
        let check = SetupCheck.shared
        var names = check.agents.compactMap { agent -> String? in
            switch agent.state {
            case .signedOut: "\(agent.id.rawValue)_signed_out"
            case .notInstalled: "\(agent.id.rawValue)_not_installed"
            default: nil
            }
        }
        names += check.toolItems.compactMap { item in if case .missing = item.status { item.id } else { nil } }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

// MARK: - Shared pieces

/// A step's big title and the line under it.
private struct StepHeader: View {
    let title: String
    let detail: String
    let palette: CompanionPalette

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.ui(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.ui(size: 14))
                .foregroundStyle(palette.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A rounded panel that sits on the canvas.
private struct Panel<Content: View>: View {
    let palette: CompanionPalette
    var selected = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surface.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? palette.accent : palette.hairline, lineWidth: selected ? 2 : 1))
    }
}

/// Fades and lifts views in one after another as a page appears. The
/// first and last pages take their time over it. The pages in between are
/// for getting something done, so theirs is quick: the page is all there
/// by the time it has slid in, and going Back doesn't replay a slow reveal.
private struct Staggered: ViewModifier {
    let index: Int
    var unhurried = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : (unhurried ? 12 : 8))
            .onAppear {
                let animation: Animation = unhurried
                    ? .smooth(duration: 0.5).delay(0.12 + Double(index) * 0.07)
                    : .smooth(duration: 0.3).delay(Double(index) * 0.04)
                withAnimation(animation) { shown = true }
            }
    }
}

private extension View {
    func staggered(_ index: Int, unhurried: Bool = false) -> some View {
        modifier(Staggered(index: index, unhurried: unhurried))
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let palette: CompanionPalette
    let start: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 148, height: 148)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                .offset(y: floating ? -5 : 5)
                .staggered(0, unhurried: true)
            Text("Welcome to Workbench")
                .font(.ui(size: 44, weight: .bold))
                .padding(.top, 26)
                .staggered(1, unhurried: true)
            Text("A home for your coding agents. Run them in real terminals or a chat view, with your git changes beside them and your iPhone within reach.")
                .font(.ui(size: 16))
                .foregroundStyle(palette.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.top, 12)
                .staggered(2, unhurried: true)
            // The agents it works with, the one it's built for first.
            HStack(spacing: 10) {
                Text("Works with")
                    .font(.ui(size: 12, weight: .medium))
                    .foregroundStyle(palette.inkMuted)
                ForEach(AgentSetup.all) { agent in
                    Feature(symbol: agent.symbol, text: agent.product, tag: agent.isBeta ? "Beta" : nil, palette: palette)
                }
            }
            .accessibilityElement(children: .combine)
            .padding(.top, 30)
            .staggered(3, unhurried: true)
            Button(action: start) {
                Text("Get Started")
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundStyle(continueButton.ink)
                    .padding(.horizontal, 30)
                    .frame(height: 44)
                    .background(Capsule().fill(continueButton.fill).shadow(color: palette.accent.opacity(0.4), radius: 16, y: 6))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, 38)
            .staggered(4, unhurried: true)
        }
        .padding(40)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { floating = true }
        }
    }

    private struct Feature: View {
        let symbol: String
        let text: String
        /// A small label after the name, like "Beta".
        var tag: String?
        let palette: CompanionPalette

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(text)
                    .font(.ui(size: 12, weight: .medium))
                    .foregroundStyle(palette.ink.opacity(0.85))
                if let tag {
                    Text(tag)
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundStyle(palette.inkMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(palette.ink.opacity(0.08)))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, tag == nil ? 12 : 7)
            .frame(height: 30)
            .background(Capsule().fill(palette.ink.opacity(0.06)))
            .overlay(Capsule().strokeBorder(palette.hairline))
        }
    }
}

// MARK: - Setup check

private struct SetupStep: View {
    let palette: CompanionPalette
    var check = SetupCheck.shared
    @AppStorage(Agents.defaultAgentKey) private var defaultAgent = AgentID.claude.rawValue

    /// What the page says, once it knows which agents are here. Workbench
    /// is built for Claude Code; Codex works too, and is in beta.
    private var detail: String {
        guard check.hasChecked else { return "Workbench runs the tools you already have. Looking for them now." }
        let ready = check.readyAgents
        guard let first = ready.first else {
            return "Workbench is built for Claude Code, and you can install it right here. It also works with Codex, which is in beta."
        }
        if ready.count > 1 {
            return "Claude Code and Codex are both set up. Workbench is built for Claude Code, and Codex support is in beta. Use either, tab by tab."
        }
        return first.isBeta
            ? "\(first.product) is set up, so you're ready to go. \(first.product) support is in beta. Workbench is built for Claude Code, which you can add here any time."
            : "\(first.product) is already set up, so you're ready to go. Workbench also works with Codex, in beta, if you ever want to add it."
    }

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: "Let's check your Mac", detail: detail, palette: palette)
                .staggered(0)
                .animation(Theme.Motion.state, value: check.hasChecked)
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(check.agentItems.enumerated()), id: \.element.id) { index, item in
                        ToolCard(item: item, palette: palette)
                            .staggered(index + 1)
                    }
                }
                if check.readyAgents.count > 1 {
                    Panel(palette: palette) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New tabs start with").font(.ui(size: 13, weight: .semibold))
                                Text("You can open a tab with the other one any time, and change this in Settings.")
                                    .font(.ui(size: 11))
                                    .foregroundStyle(palette.inkMuted)
                            }
                            Spacer(minLength: 8)
                            Picker("New tabs start with", selection: $defaultAgent) {
                                ForEach(check.readyAgents) { Text($0.name).tag($0.id.rawValue) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .transition(.opacity)
                }
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(check.toolItems.enumerated()), id: \.element.id) { index, item in
                        ToolCard(item: item, palette: palette, compact: true)
                            .staggered(index + 3)
                    }
                }
            }
            .frame(maxWidth: 700)
            .animation(Theme.Motion.state, value: check.readyAgents.count)
            Button("Check Again") { Task { await check.run(rescan: true) } }
                .buttonStyle(.pressable)
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(palette.inkMuted)
                .disabled(check.isChecking)
                .staggered(6)
        }
        .padding(40)
        .task { await check.run() }
        // Picks up a tool installed or signed in to while Workbench was in the back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await check.run(rescan: true) }
        }
    }

    private struct ToolCard: View {
        let item: SetupCheck.Item
        let palette: CompanionPalette
        /// A smaller card, for the tools under the agents.
        var compact = false

        /// An install command needs the card's whole width to fit on a line.
        private var showsFixBelow: Bool { if case .installAgent = item.fix { true } else { false } }

        var body: some View {
            Panel(palette: palette) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: compact ? 10 : 14) {
                        Image(systemName: symbol)
                            .font(.ui(size: compact ? 14 : 17, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: compact ? 30 : 40, height: compact ? 30 : 40)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.name).font(.ui(size: 14, weight: .semibold))
                                if item.isBeta {
                                    Text("Beta")
                                        .font(.ui(size: 10, weight: .semibold))
                                        .foregroundStyle(palette.inkMuted)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(palette.ink.opacity(0.07)))
                                }
                                Spacer(minLength: 4)
                                badge
                            }
                            Text(item.purpose.replacingOccurrences(of: "Optional. ", with: ""))
                                .font(.ui(size: 12))
                                .foregroundStyle(palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            if !showsFixBelow { fix }
                        }
                    }
                    if showsFixBelow { fix }
                }
                .padding(compact ? 13 : 16)
                .frame(maxWidth: .infinity, minHeight: compact ? 104 : 112, alignment: .topLeading)
            }
        }

        private var symbol: String {
            switch item.id {
            case "claude": "sparkle"
            case "codex": "hexagon"
            case "git": "arrow.triangle.branch"
            case "gh": "arrow.triangle.pull"
            default: "network"
            }
        }

        private var tint: Color {
            switch item.id {
            case "claude", "codex": palette.accent
            case "git": .orange
            case "gh": .purple
            default: .blue
            }
        }

        @ViewBuilder private var badge: some View {
            switch item.status {
            case .checking:
                ProgressView().controlSize(.small)
            case .ok:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Status.done)
                    .transition(.scale.combined(with: .opacity))
            case .missing:
                Label("Needed", systemImage: "exclamationmark.circle.fill")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Status.failed)
            case .skipped:
                Text("Optional")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(palette.inkMuted)
            }
        }

        @ViewBuilder private var fix: some View {
            switch item.fix {
            case .link(let title, let url):
                Link(destination: url) {
                    Text(title + " ›").font(.ui(size: 12, weight: .semibold))
                }
                .foregroundStyle(palette.accent)
                .padding(.top, 2)
            case .installCommandLineTools:
                Button("Install Command Line Tools") {
                    Task.detached { _ = Tools.run("/usr/bin/xcode-select", ["--install"]) }
                }
                .buttonStyle(.pressable)
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.top, 2)
            case .installAgent(let agent):
                VStack(alignment: .leading, spacing: 6) {
                    CopyableCommand(command: agent.installCommand)
                    if let needs = agent.installNeeds {
                        Text(needs).font(.ui(size: 11)).foregroundStyle(palette.inkMuted)
                    }
                    HStack(spacing: 12) {
                        AgentSetupButton(agent: agent, action: .install, title: "Install Here ›")
                            .buttonStyle(.pressable)
                            .font(.ui(size: 12, weight: .semibold))
                            .foregroundStyle(palette.accent)
                        Link(destination: agent.page) {
                            Text("Learn More").font(.ui(size: 12, weight: .medium))
                        }
                        .foregroundStyle(palette.inkMuted)
                    }
                }
            case .signInToAgent(let agent):
                AgentSetupButton(agent: agent, action: .signIn, title: "Sign In to \(agent.product) ›")
                    .buttonStyle(.pressable)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.top, 2)
            case .note(let text):
                Text(text)
                    .font(.ui(size: 11))
                    .foregroundStyle(palette.inkMuted)
                    .padding(.top, 2)
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - Terminal or chat

private struct StyleStep: View {
    let palette: CompanionPalette
    @AppStorage(AppStore.newTabsShowChatKey) private var showsChat = false

    var body: some View {
        VStack(spacing: 30) {
            StepHeader(title: "How do you like to see \(agentName)?",
                       detail: "Your agent always runs in a real terminal. You can watch it there, or read the same session as a conversation. Pick what new agent tabs show.",
                       palette: palette)
                .staggered(0)
            HStack(spacing: 18) {
                option(chat: false, title: "Terminal", detail: "Your agent exactly as it looks in your terminal.") {
                    TerminalPreview()
                }
                .staggered(1)
                option(chat: true, title: "Chat", detail: "The same session as a conversation, with cards for edits and questions.") {
                    ChatPreview(palette: palette)
                }
                .staggered(2)
            }
            .frame(maxWidth: 640)
            Text("Switch any tab between the two with ⌥⌘T.")
                .font(.ui(size: 12))
                .foregroundStyle(palette.inkMuted)
                .staggered(3)
        }
        .padding(40)
    }

    private func option(chat: Bool, title: String, detail: String, @ViewBuilder preview: () -> some View) -> some View {
        let selected = showsChat == chat
        return Button {
            withAnimation(.snappy(duration: 0.25)) { showsChat = chat }
        } label: {
            Panel(palette: palette, selected: selected) {
                VStack(alignment: .leading, spacing: 12) {
                    preview()
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.ui(size: 15, weight: .semibold))
                        if !chat {
                            Chip("Default", tint: palette.inkMuted)
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.ui(size: 17))
                            .foregroundStyle(selected ? palette.accent : palette.inkMuted.opacity(0.5))
                    }
                    Text(detail)
                        .font(.ui(size: 12))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
            .scaleEffect(selected ? 1 : 0.98)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A small drawing of Claude Code in a terminal.
private struct TerminalPreview: View {
    var body: some View {
        let mono = Font.ui(size: 10, design: .monospaced)
        VStack(alignment: .leading, spacing: 5) {
            Text("> add a shopping list").foregroundStyle(.white.opacity(0.9))
            Text("⏺ Update(ShoppingList.swift)").foregroundStyle(.white.opacity(0.8))
            Text("  ⎿  Added 24 lines").foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 0) {
                Text("+ ").foregroundStyle(.green.opacity(0.9))
                Text("struct ShoppingList {").foregroundStyle(.green.opacity(0.75))
            }
            Text("✻ Editing RecipeStore.swift… (48s)").foregroundStyle(Color(red: 0.94, green: 0.55, blue: 0.33))
            Spacer(minLength: 0)
            Text("╭──────────────────────────╮").foregroundStyle(.white.opacity(0.25))
            Text("│ >                        │").foregroundStyle(.white.opacity(0.25))
        }
        .font(mono)
        .lineLimit(1)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }
}

/// A small drawing of the same session as a chat.
private struct ChatPreview: View {
    let palette: CompanionPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Spacer(minLength: 30)
                Text("Add a shopping list")
                    .font(.ui(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.accent))
            }
            Text("I'll add a ShoppingList model and a button on each recipe.")
                .font(.ui(size: 10))
                .foregroundStyle(palette.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "pencil").font(.ui(size: 8, weight: .bold))
                Text("ShoppingList.swift").font(.ui(size: 9, weight: .medium, design: .monospaced))
                Text("+24").font(.ui(size: 9, weight: .semibold)).foregroundStyle(StepColors.added)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.raised))
            Spacer(minLength: 0)
            HStack {
                Text("Message \(agentName)").font(.ui(size: 9)).foregroundStyle(palette.inkMuted)
                Spacer()
                Image(systemName: "arrow.up.circle.fill").font(.ui(size: 12)).foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(palette.raised))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.canvas)
    }
}

// MARK: - Theme

private struct ThemeStep: View {
    var body: some View {
        @Bindable var theme = TerminalTheme.shared
        let palette = theme.chatPalette
        VStack(spacing: 22) {
            StepHeader(title: "Make it yours",
                       detail: "Use your Ghostty theme, so the sidebars, chat, and diffs look like part of your terminal, or pick one of Workbench's own themes for a light and a dark look.",
                       palette: palette)
                .staggered(0)
            WindowPreview(palette: palette, panel: theme.panel)
                .frame(width: 460, height: 210)
                .staggered(1)
                .animation(.smooth(duration: 0.5), value: theme.source)
                .animation(.smooth(duration: 0.5), value: theme.lightThemeID)
                .animation(.smooth(duration: 0.5), value: theme.darkThemeID)
            Picker("Colors", selection: $theme.source) {
                ForEach(TerminalTheme.Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .staggered(2)
            Group {
                if theme.source == .builtIn {
                    VStack(alignment: .leading, spacing: 10) {
                        swatches("Light Mode", BuiltInTheme.light, $theme.lightThemeID, palette)
                        swatches("Dark Mode", BuiltInTheme.dark, $theme.darkThemeID, palette)
                    }
                    .frame(maxWidth: 720)
                } else {
                    Text(theme.source == .ghostty
                         ? "Change themes in your Ghostty config and Workbench follows."
                         : "Terminal tabs keep your Ghostty theme. The rest follows your Mac's light or dark appearance.")
                        .font(.ui(size: 12))
                        .foregroundStyle(palette.inkMuted)
                }
            }
            .staggered(3)
        }
        .padding(40)
    }

    private func swatches(_ title: String, _ themes: [BuiltInTheme], _ selection: Binding<String>,
                          _ palette: CompanionPalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(palette.inkMuted)
                .padding(.leading, 4)
            ThemeSwatchRow(themes: themes, selection: selection, width: 112)
        }
    }
}

/// A miniature Bench window in the current colors.
private struct WindowPreview: View {
    let palette: CompanionPalette
    let panel: Color?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 8, height: 8) }
                }
                .padding(.bottom, 8)
                ForEach(0..<5) { row in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(rowColor(row)).frame(width: 16, height: 16)
                        RoundedRectangle(cornerRadius: 2).fill(palette.ink.opacity(row == 1 ? 0.7 : 0.3)).frame(width: CGFloat(54 - row * 6), height: 5)
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(row == 1 ? palette.ink.opacity(0.1) : .clear))
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 130)
            .frame(maxHeight: .infinity)
            .background(panel ?? Color(nsColor: .windowBackgroundColor))
            ChatPreview(palette: palette)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(8)
                .background(panel ?? Color(nsColor: .windowBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.hairline))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
    }

    private func rowColor(_ row: Int) -> Color {
        [Color.orange, palette.accent, .purple, .blue, .green][row].opacity(0.85)
    }
}

// MARK: - Projects

private struct ProjectsStep: View {
    let palette: CompanionPalette
    @Binding var picked: [String]
    @Environment(AppStore.self) private var store
    @State private var suggestions: [ProjectSuggestion]?
    /// Folders chosen by hand, shown with the suggestions.
    @State private var chosen: [ProjectSuggestion] = []
    @State private var isTargeted = false
    @State private var didPreselect = false

    private var rows: [ProjectSuggestion] { chosen + (suggestions ?? []).filter { s in !chosen.contains { $0.path == s.path } } }

    var body: some View {
        VStack(spacing: 26) {
            StepHeader(title: "Add your projects",
                       detail: suggestions?.isEmpty == false
                           ? "These are folders you've already used a coding agent in, newest first. Pick the ones you want in your sidebar."
                           : "Choose the folders you work in. Each one gets its own agent tabs, terminals, and changes.",
                       palette: palette)
                .staggered(0)
            if let suggestions {
                if !rows.isEmpty {
                    Panel(palette: palette) {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { Rectangle().fill(palette.hairline).frame(height: 1).padding(.leading, 58) }
                                    SuggestionRow(suggestion: row, palette: palette, isOn: picked.contains(row.path)) {
                                        toggle(row.path)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 560)
                    .staggered(1)
                    .onAppear { preselect(suggestions) }
                }
                dropZone
                    .frame(maxWidth: 560)
                    .staggered(2)
            } else {
                ProgressView().controlSize(.small).padding(30)
            }
        }
        .padding(40)
        .task {
            guard suggestions == nil else { return }
            suggestions = await ProjectSuggestions.load(excluding: Set(store.projects.map(\.path)))
        }
    }

    private var dropZone: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.ui(size: 16, weight: .medium))
                    .foregroundStyle(palette.accent)
                Text(isTargeted ? "Drop to add" : "Drop folders here, or choose them…")
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundStyle(palette.ink.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? palette.accent.opacity(0.12) : palette.ink.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? palette.accent : palette.ink.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.pressable)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more project folders"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            if !rows.contains(where: { $0.path == path }) {
                chosen.insert(ProjectSuggestion(path: path, lastUsed: .now, icon: ProjectIcons.findIcon(in: url)), at: 0)
            }
            if !picked.contains(path) { picked.append(path) }
        }
    }

    private func toggle(_ path: String) {
        if let index = picked.firstIndex(of: path) { picked.remove(at: index) } else { picked.append(path) }
    }

    /// Starts with the three most recent picked, once.
    private func preselect(_ suggestions: [ProjectSuggestion]) {
        guard !didPreselect else { return }
        didPreselect = true
        if picked.isEmpty { picked = suggestions.prefix(3).map(\.path) }
    }
}

private struct SuggestionRow: View {
    let suggestion: ProjectSuggestion
    let palette: CompanionPalette
    let isOn: Bool
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name)
                        .font(.ui(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(suggestion.shortPath)
                        .font(.ui(size: 11))
                        .foregroundStyle(palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(suggestion.lastUsed, format: .relative(presentation: .named))
                    .font(.ui(size: 11))
                    .foregroundStyle(palette.inkMuted)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.ui(size: 18))
                    .foregroundStyle(isOn ? palette.accent : palette.inkMuted.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.ink.opacity(isHovering ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder private var icon: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let url = suggestion.icon, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                .frame(width: 32, height: 32).clipShape(shape)
        } else {
            let hue = Double(abs(suggestion.name.lowercased().hashValueStable) % 360) / 360
            shape.fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.85),
                                               Color(hue: hue, saturation: 0.65, brightness: 0.6)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 32, height: 32)
                .overlay {
                    Text(suggestion.name.prefix(1).uppercased())
                        .font(.ui(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
        }
    }
}

// MARK: - iPhone

private struct PhoneStep: View {
    let palette: CompanionPalette
    @Environment(Companion.self) private var companion

    var body: some View {
        @Bindable var companion = companion
        HStack(spacing: 48) {
            PhoneDrawing(palette: palette)
                .staggered(1)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Take \(agentName) with you")
                        .font(.ui(size: 30, weight: .bold))
                    Text("Workbench for iPhone shows every session as a chat. Answer your agent's questions, allow a command, or send a follow-up from the couch, and get a notification when it needs you.")
                        .font(.ui(size: 14))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: Companion.appStoreURL) {
                        Label("Get the iPhone app on the App Store", systemImage: "arrow.up.right.square")
                            .font(.ui(size: 13, weight: .medium))
                    }
                    .tint(palette.accent)
                }
                .staggered(0)
                Toggle("Let my iPhone connect to Workbench", isOn: $companion.isEnabled)
                    .toggleStyle(.benchSwitch)
                    .font(.ui(size: 13, weight: .medium))
                    .staggered(2)
                pairing
                    .staggered(3)
            }
            .frame(width: 340)
        }
        .padding(40)
        .task { if companion.isEnabled { await companion.publish() } }
        .task(id: companion.needsHTTPS) {
            while companion.needsHTTPS, companion.isEnabled, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await companion.publish()
            }
        }
    }

    @ViewBuilder private var pairing: some View {
        if !companion.isEnabled {
            Text("At home it connects over your Wi-Fi, and away from home over Tailscale. Both are just your own devices talking to each other. If you'd rather not set up Tailscale, the optional Workbench relay reaches your Mac from anywhere, encrypted so the relay can't read it. You can do this later in Settings > Remote Access.")
                .font(.ui(size: 12))
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else if let url = companion.pairing?.url, let image = PairingCode.qrCode(for: url.absoluteString) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .padding(7)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .transition(.scale.combined(with: .opacity))
                    Text("Open Workbench on your iPhone and scan this code. Keep it to yourself: it lets a device see your sessions.")
                        .font(.ui(size: 12))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                paths
                if let error = companion.tailscaleError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.ui(size: 12))
                            .foregroundStyle(palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if companion.needsHTTPS {
                            Link("Open Tailscale DNS Settings", destination: Tailscale.httpsSettingsURL)
                                .font(.ui(size: 12))
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting the pairing code ready…")
                    .font(.ui(size: 12))
                    .foregroundStyle(palette.inkMuted)
            }
        }
    }

    /// The ways a device reaches this Mac, in the order they're tried:
    /// the two direct ones, then the relay you can choose to add.
    private var paths: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("How your iPhone reaches this Mac")
                .font(.ui(size: 12, weight: .semibold))
            path("wifi", "Home Wi-Fi", "Direct, device to device.")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                path("point.3.connected.trianglepath.dotted", "Tailscale",
                     companion.hasTailscale ? "Direct, from anywhere." : "Direct, from anywhere. Not set up.")
                if !companion.hasTailscale {
                    Link("Set Up", destination: Tailscale.downloadURL)
                        .font(.ui(size: 12))
                }
            }
            Toggle(isOn: Binding(get: { companion.relay.isOn }, set: { companion.relay.setOn($0) })) {
                path("arrow.triangle.swap", "Workbench relay", "Optional fallback.")
            }
            .toggleStyle(.benchSwitch)
            Text(companion.hasTailscale
                 ? "The first two are only your devices talking to each other, and always come first. The relay steps in when neither connects. It passes messages through a relay server, encrypted so the relay can't read them."
                 : "Without Tailscale, your iPhone only connects on your home Wi-Fi. Set up Tailscale to keep it between your devices, or turn on the relay: it passes messages through a relay server, encrypted so the relay can't read them.")
                .font(.ui(size: 11))
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func path(_ symbol: String, _ name: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(palette.inkMuted)
                .frame(width: 16)
            Text(name).font(.ui(size: 12, weight: .medium))
            Text(note).font(.ui(size: 12)).foregroundStyle(palette.inkMuted)
        }
    }
}

/// A drawn iPhone showing a question from Claude.
private struct PhoneDrawing: View {
    let palette: CompanionPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Capsule().fill(.black).frame(width: 52, height: 15).frame(maxWidth: .infinity).padding(.top, 8)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5).fill(palette.accent.gradient).frame(width: 20, height: 20)
                    .overlay(Image(systemName: "sparkle").font(.ui(size: 9, weight: .bold)).foregroundStyle(.white))
                Text("Recipes").font(.ui(size: 11, weight: .semibold))
            }
            .padding(.top, 6)
            HStack {
                Spacer(minLength: 24)
                Text("Add a shopping list")
                    .font(.ui(size: 9.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.accent))
            }
            Text("Done. Every recipe has an Add to List button now.")
                .font(.ui(size: 9.5))
                .foregroundStyle(palette.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("\(agentName) wants to run", systemImage: "hand.raised.fill")
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundStyle(palette.waitingInk)
                Text("swift test").font(.ui(size: 9, design: .monospaced))
                HStack(spacing: 5) {
                    Text("Allow").frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(Capsule().fill(palette.done)).foregroundStyle(.white)
                    Text("Deny").frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(Capsule().fill(palette.ink.opacity(0.12)))
                }
                .font(.ui(size: 9, weight: .semibold))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.waiting.opacity(0.5)))
            Spacer(minLength: 0)
            HStack {
                Text("Message \(agentName)").font(.ui(size: 9)).foregroundStyle(palette.inkMuted)
                Spacer()
                Image(systemName: "arrow.up.circle.fill").font(.ui(size: 13)).foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(palette.raised))
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 12)
        .frame(width: 188, height: 380)
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(palette.canvas).shadow(color: .black.opacity(0.35), radius: 30, y: 16))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(Color(white: 0.16), lineWidth: 7))
        .offset(y: tilted ? -6 : 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { tilted = true }
        }
    }
}

// MARK: - Done

private struct DoneStep: View {
    let palette: CompanionPalette
    let projectName: String?
    let finish: () -> Void
    @State private var checked = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(palette.accent.opacity(0.15)).frame(width: 96, height: 96)
                    .scaleEffect(checked ? 1 : 0.6)
                Image(systemName: "checkmark")
                    .font(.ui(size: 40, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .symbolEffect(.bounce, value: checked)
                    .scaleEffect(checked ? 1 : 0.3)
                    .opacity(checked ? 1 : 0)
            }
            Text("You're all set")
                .font(.ui(size: 38, weight: .bold))
                .padding(.top, 24)
                .staggered(1, unhurried: true)
            Text("A few keys worth knowing:")
                .font(.ui(size: 14))
                .foregroundStyle(palette.inkMuted)
                .padding(.top, 8)
                .staggered(2, unhurried: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                tip("⌘T", "New tab. Press it again to start \(agentName)")
                tip("⌥⌘T", "Switch a tab between terminal and chat")
                tip("⇧⌘N", "Start an agent on its own branch")
                tip("⌘1 – ⌘9", "Jump to an Active project")
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surface.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.hairline))
            .padding(.top, 22)
            .staggered(3, unhurried: true)
            Text("Workbench shares anonymous counts of what you use to help improve it. Never your code, prompts, or project names. You can turn this off in Settings > General.")
                .font(.ui(size: 11))
                .foregroundStyle(palette.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .staggered(4, unhurried: true)
            Button(action: finish) {
                Text(projectName.map { "Open \($0)" } ?? "Start Using Workbench")
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundStyle(continueButton.ink)
                    .padding(.horizontal, 30)
                    .frame(height: 44)
                    .background(Capsule().fill(continueButton.fill).shadow(color: palette.accent.opacity(0.4), radius: 16, y: 6))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, 32)
            .staggered(5, unhurried: true)
        }
        .padding(40)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) { checked = true }
        }
    }

    private func tip(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .font(.ui(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.ink.opacity(0.08)))
                .gridColumnAlignment(.trailing)
            Text(text)
                .font(.ui(size: 13))
                .foregroundStyle(palette.ink.opacity(0.85))
        }
    }
}
