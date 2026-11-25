import BenchKit
import Charts
import SwiftUI

/// Settings, from the gear on the project list: your Macs, which
/// notifications you get, what Claude has cost, and how the app looks.
struct PhoneSettings: View {
    @Environment(CompanionClient.self) private var client
    @Environment(PairingStore.self) private var pairing
    @Environment(ActivityManager.self) private var activities
    @Environment(\.dismiss) private var dismiss
    @State private var showsAddMac = false
    @State private var reachability = MacReachability()
    @State private var path = NavigationPath()
    @AppStorage(Analytics.optedOutKey) private var analyticsOptedOut = false
    @State private var appIcon = AppIconChoice(alternateIconName: UIApplication.shared.alternateIconName)

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if pairing.isDemo { demoSection }
                if !pairing.macs.isEmpty { macsSection }
                notificationsSection
                if let usage = client.usage { usageSection(usage) }
                appearanceSection
                privacySection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(PhoneTheme.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: MacRoute.self) { MacScreen(host: $0.host, reachability: reachability) }
            .navigationDestination(for: UsageRoute.self) { _ in PhoneUsageScreen() }
            .task(id: pairing.macs.map(\.host)) {
                reachability.check(pairing.macs.filter { $0.host != pairing.info?.host })
            }
            .sheet(isPresented: $showsAddMac) { PairView(isSheet: true) }
            #if DEBUG
            // For screenshots: BENCH_OPEN_SETTINGS=usage goes on to Usage.
            .task {
                guard ProcessInfo.processInfo.environment["BENCH_OPEN_SETTINGS"] == "usage" else { return }
                try? await Task.sleep(for: .seconds(1))
                path.append(UsageRoute())
            }
            #endif
        }
        .tint(PhoneTheme.ink)
    }

    // MARK: Sections

    private var demoSection: some View {
        Section {
            Button("Pair with Your Mac", systemImage: "qrcode.viewfinder") { showsAddMac = true }
            Button("Exit Demo", systemImage: "xmark") {
                pairing.isDemo = false
                dismiss()
            }
        } header: {
            Text("Demo")
        } footer: {
            Text("You're looking at sample projects. Pair with Workbench on your Mac to see your own.")
        }
        .listRowBackground(PhoneTheme.surface)
    }

    private var macsSection: some View {
        Section("Your Macs") {
            ForEach(pairing.macs, id: \.host) { mac in
                NavigationLink(value: MacRoute(host: mac.host)) {
                    MacRow(host: mac.host, reachability: reachability)
                }
            }
            // Touch and hold a row, then drag it. The chips above the
            // project list follow this order.
            .onMove { pairing.move(fromOffsets: $0, toOffset: $1) }
            Button("Add a Mac", systemImage: "plus") { showsAddMac = true }
        }
        .listRowBackground(PhoneTheme.surface)
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Notifications", isOn: Binding(
                get: { activities.notificationsOn },
                set: { on in Task { await activities.setNotifications(on) } }
            ))
            if activities.notificationsOn {
                if client.canMuteNotifications {
                    ForEach(CompanionNotificationKind.choices) { kind in
                        Toggle(isOn: Binding(
                            get: { !client.mutedNotifications.contains(kind) },
                            set: { on in
                                if on { client.mutedNotifications.remove(kind) } else { client.mutedNotifications.insert(kind) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                Text(kind.detail)
                                    .font(.footnote)
                                    .foregroundStyle(PhoneTheme.inkMuted)
                            }
                        }
                    }
                }
                if let problem = client.pushProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(PhoneTheme.waiting)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(notificationsFooter)
        }
        .listRowBackground(PhoneTheme.surface)
    }

    private var notificationsFooter: String {
        if !activities.notificationsOn {
            return "Your Mac sends these when an agent needs you or finishes. The Lock Screen dashboard needs them too."
        }
        if !client.canMuteNotifications, client.status == .connected {
            return "Update Workbench on your Mac to choose which of these you get."
        }
        return "These choices go to each Mac you pair. To see every session at a glance, tap the Lock Screen button at the top of Projects."
    }

    private func usageSection(_ usage: CompanionUsage) -> some View {
        Section {
            NavigationLink(value: UsageRoute()) {
                HStack {
                    Label("Usage and Costs", systemImage: "chart.bar.xaxis")
                    Spacer()
                    Text(UsageText.money(usage.cost(lastDays: 30)))
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .monospacedDigit()
                }
            }
        } footer: {
            Text("What the last 30 days of Claude Code would cost at API prices.")
        }
        .listRowBackground(PhoneTheme.surface)
    }

    private var appearanceSection: some View {
        @Bindable var theme = MacTheme.shared
        return Section {
            Picker("Colors", selection: $theme.source) {
                ForEach(MacTheme.Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: theme.source)
            .sensoryFeedback(.selection, trigger: theme.lightThemeID + theme.darkThemeID)
            .sensoryFeedback(.selection, trigger: appIcon)
            if theme.source == .builtIn {
                themeRow("Light Mode", BuiltInTheme.light, $theme.lightThemeID)
                themeRow("Dark Mode", BuiltInTheme.dark, $theme.darkThemeID)
            }
            appIconRow
        } header: {
            Text("Appearance")
        } footer: {
            Text(appearanceFooter)
        }
        .listRowBackground(PhoneTheme.surface)
    }

    private func themeRow(_ title: String, _ themes: [BuiltInTheme], _ selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PhoneTheme.inkMuted)
            ThemeSwatchRow(themes: themes, selection: selection, width: 116)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 0))
    }

    private var appIconRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("App Icon")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PhoneTheme.inkMuted)
            AppIconPicker(selection: appIcon) { choice in
                guard choice != appIcon, UIApplication.shared.supportsAlternateIcons else { return }
                let previous = appIcon
                appIcon = choice
                UIApplication.shared.setAlternateIconName(choice.alternateIconName) { error in
                    if error != nil { Task { @MainActor in appIcon = previous } }
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
    }

    private var appearanceFooter: String {
        switch MacTheme.shared.source {
        case .mac:
            MacTheme.shared.colors == nil
                ? "Uses the colors from Workbench on your Mac once it shares a theme."
                : "Uses the same colors as Workbench on your Mac."
        case .builtIn: "One theme for light mode and one for dark. The app switches with your \(Device.name)'s appearance."
        case .standard: "Workbench's own colors, light or dark with your \(Device.name)."
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("Share Anonymous Usage Data", isOn: Binding(
                get: { !analyticsOptedOut },
                set: { Analytics.isOptedOut = !$0 }
            ))
        } header: {
            Text("Privacy")
        } footer: {
            Text("Counts of what you use, like replies sent or commands allowed, and a report when the app crashes, with a random ID that isn't linked to you. Never your messages, code, project names, or location.")
        }
        .listRowBackground(PhoneTheme.surface)
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.appVersion)
            Link(destination: URL(string: "https://workbenchapp.dev/support")!) {
                Label("Help and Support", systemImage: "questionmark.circle")
            }
            Link(destination: URL(string: "https://workbenchapp.dev/privacy")!) {
                Label("Privacy", systemImage: "hand.raised")
            }
            if !pairing.isDemo {
                Button("Try the Demo", systemImage: "sparkles") {
                    pairing.isDemo = true
                    dismiss()
                }
            }
        } header: {
            Text("About")
        }
        .listRowBackground(PhoneTheme.surface)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private struct MacRoute: Hashable { var host: String }
private struct UsageRoute: Hashable {}

// MARK: Macs

/// A Mac's name and whether it's there, for the list of Macs.
private struct MacRow: View {
    @Environment(CompanionClient.self) private var client
    @Environment(PairingStore.self) private var pairing
    let host: String
    let reachability: MacReachability

    var body: some View {
        let current = host == pairing.info?.host
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(PhoneTheme.inkMuted)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(pairing.name(for: host))
                    .fontWeight(current ? .semibold : .regular)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.text)
                }
                .font(.footnote)
                .foregroundStyle(PhoneTheme.inkMuted)
                if current, client.status == .connected, let path = client.path {
                    Text(Self.describe(path))
                        .font(.footnote)
                        .foregroundStyle(PhoneTheme.inkMuted)
                }
            }
            Spacer()
            if current, pairing.macs.count > 1 {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(PhoneTheme.accent)
            }
        }
    }

    private var status: MacStatus {
        MacStatus(host: host, client: client, pairing: pairing, reachability: reachability)
    }

    private static func describe(_ path: ConnectionPath) -> String {
        switch path {
        case .tailscale: "Connected over Tailscale"
        case .local: "Connected over your home network"
        }
    }
}

/// How a Mac is doing, in a dot and a few words.
private struct MacStatus {
    var color: Color
    var text: String

    init(host: String, client: CompanionClient, pairing: PairingStore, reachability: MacReachability) {
        if host == pairing.info?.host {
            switch client.status {
            case .connected:
                color = PhoneTheme.done
                text = client.macAppVersion.map { "Connected, Workbench \($0)" } ?? "Connected"
            case .connecting:
                color = PhoneTheme.waiting
                text = "Connecting"
            default:
                color = PhoneTheme.inkMuted
                text = "Not connected"
            }
            return
        }
        switch reachability.states[host] {
        case .bench: color = PhoneTheme.done; text = "Ready"
        case .macOnly: color = PhoneTheme.waiting; text = "Workbench isn't open"
        case .offline: color = PhoneTheme.inkMuted; text = "Can't reach it"
        case .checking, nil: color = PhoneTheme.inkMuted.opacity(0.5); text = "Checking"
        }
    }
}

/// One Mac: switch to it, reconnect, or unpair.
private struct MacScreen: View {
    @Environment(CompanionClient.self) private var client
    @Environment(PairingStore.self) private var pairing
    @Environment(\.dismiss) private var dismiss
    let host: String
    let reachability: MacReachability
    @State private var confirmsUnpair = false

    var body: some View {
        let current = host == pairing.info?.host
        let status = MacStatus(host: host, client: client, pairing: pairing, reachability: reachability)
        List {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(status.color).frame(width: 8, height: 8)
                        Text(current && client.status == .connected ? "Connected" : status.text)
                    }
                }
                if current, let version = client.macAppVersion {
                    LabeledContent("Workbench", value: version)
                }
                LabeledContent("Address", value: host)
                    .textSelection(.enabled)
            }
            .listRowBackground(PhoneTheme.surface)

            Section {
                if current {
                    Button("Reconnect", systemImage: "arrow.clockwise") { client.retry() }
                } else {
                    Button("Switch to This Mac", systemImage: "arrow.left.arrow.right") {
                        pairing.select(host: host)
                        dismiss()
                    }
                }
            }
            .listRowBackground(PhoneTheme.surface)

            Section {
                Button("Unpair", systemImage: "iphone.slash", role: .destructive) { confirmsUnpair = true }
            } footer: {
                Text("To pair again, scan the code in Workbench's settings on that Mac.")
            }
            .listRowBackground(PhoneTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(PhoneTheme.canvas)
        .navigationTitle(pairing.name(for: host))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Unpair from \(pairing.name(for: host))?", isPresented: $confirmsUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                pairing.unpair(host: host)
                dismiss()
            }
        } message: {
            Text(current && pairing.macs.count > 1
                 ? "\(Device.thisName) will switch to your other Mac."
                 : "\(Device.thisName) stops getting updates and notifications from it.")
        }
    }
}

// MARK: Usage

/// The Mac's Usage page, on the phone: a month of costs at API prices.
struct PhoneUsageScreen: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        ScrollView {
            if let usage = client.usage {
                VStack(spacing: 14) {
                    if usage.paysPerToken == true, let spend = client.planUsage?.limits.first(where: \.isSpend) {
                        MonthSpendPanel(limit: spend)
                    }
                    HStack(spacing: 10) {
                        UsageTile(title: "Today", cost: usage.cost(lastDays: 1), tokens: usage.tokens(lastDays: 1))
                        UsageTile(title: "7 days", cost: usage.cost(lastDays: 7), tokens: usage.tokens(lastDays: 7))
                        UsageTile(title: "30 days", cost: usage.cost(lastDays: 30), tokens: usage.tokens(lastDays: 30))
                    }
                    UsageChart(usage: usage)
                    models(usage)
                    if usage.cacheSavings > 0 {
                        UsagePanel {
                            HStack(alignment: .firstTextBaseline) {
                                Label("Prompt caching saved", systemImage: "bolt")
                                Spacer()
                                Text(UsageText.money(usage.cacheSavings))
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                    Text(footnote(usage))
                        .font(.footnote)
                        .foregroundStyle(PhoneTheme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            } else {
                ContentUnavailableView("No usage yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Workbench on your Mac is still reading Claude Code's logs."))
                    .padding(.top, 80)
            }
        }
        .background(PhoneTheme.canvas)
        .navigationTitle("Usage and Costs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func footnote(_ usage: CompanionUsage) -> String {
        let updated = usage.updated.formatted(.relative(presentation: .named))
        if usage.paysPerToken == true {
            let source = usage.provider ?? "an API key"
            return "Your Mac's Claude Code uses \(source), which bills by the token, so these are close to what you paid. Worked out at API prices from Claude Code's logs on your Mac. Updated \(updated)."
        }
        return "Estimates at API prices, from Claude Code's logs on your Mac. A Claude plan costs a flat monthly price instead. Updated \(updated)."
    }

    private func models(_ usage: CompanionUsage) -> some View {
        UsagePanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("By model")
                    .font(.subheadline.weight(.semibold))
                ForEach(usage.models, id: \.name) { model in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(UsageText.color(family: model.family))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.name)
                            Text("\(UsageText.tokens(model.tokens)) tokens")
                                .font(.caption)
                                .foregroundStyle(PhoneTheme.inkMuted)
                        }
                        Spacer()
                        Text(UsageText.money(model.cost))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}

/// A stacked bar per day, colored by model family.
private struct UsageChart: View {
    let usage: CompanionUsage

    private struct Bar: Identifiable {
        var id: String { day + family }
        var day: String
        var date: Date
        var family: String
        var cost: Double
    }

    private var bars: [Bar] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return usage.days.flatMap { day in
            day.cost.filter { $0.value > 0 }.compactMap { family, cost in
                formatter.date(from: day.day).map { Bar(day: day.day, date: $0, family: family, cost: cost) }
            }
        }
    }

    private var families: [String] {
        let totals = usage.days.reduce(into: [String: Double]()) { result, day in
            for (family, cost) in day.cost { result[family, default: 0] += cost }
        }
        return totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
    }

    var body: some View {
        UsagePanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Last 30 days")
                    .font(.subheadline.weight(.semibold))
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.date, unit: .day), y: .value("Cost", bar.cost))
                        .foregroundStyle(by: .value("Model", bar.family))
                }
                .chartForegroundStyleScale(domain: families, range: families.map(UsageText.color(family:)))
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(PhoneTheme.hairline)
                        AxisValueLabel {
                            if let cost = value.as(Double.self) { Text(UsageText.money(cost, cents: false)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 190)
            }
        }
    }
}

private struct UsageTile: View {
    let title: String
    let cost: Double
    let tokens: Int

    var body: some View {
        UsagePanel {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(PhoneTheme.inkMuted)
                Text(UsageText.money(cost))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(UsageText.tokens(tokens))
                    .font(.caption2)
                    .foregroundStyle(PhoneTheme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UsagePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PhoneTheme.Radius.card, style: .continuous).strokeBorder(PhoneTheme.hairline))
    }
}

enum UsageText {
    static func money(_ value: Double, cents: Bool = true) -> String {
        let digits = cents && value < 1000 ? 2 : 0
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }

    /// "1.2M", "340K".
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(2)))
    }

    /// The same colors as the Mac's Usage page, checked for color blindness.
    static func color(family: String) -> Color {
        switch family {
        case "Fable": dynamic(light: 0x2A78D6, dark: 0x3987E5)
        case "Opus": dynamic(light: 0xEB6834, dark: 0xD95926)
        case "Sonnet": dynamic(light: 0x1BAF7A, dark: 0x199E70)
        case "Haiku": dynamic(light: 0xEDA100, dark: 0xC98500)
        default: dynamic(light: 0xE87BA4, dark: 0xD55181)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }
}

/// This month's spending for an API key account, against the budget set
/// on the Mac when there is one.
private struct MonthSpendPanel: View {
    let limit: PlanLimit

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let spent = limit.resetsAt.map { $0 <= now } == true ? 0 : limit.dollars ?? 0
            let percent = limit.percent(at: now)
            UsagePanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This month")
                        .font(.subheadline.weight(.semibold))
                    HStack(alignment: .firstTextBaseline) {
                        Text(PlanLimit.dollarText(spent))
                            .font(.title2.weight(.semibold).monospacedDigit())
                        Text(limit.budget.map { "of \(PlanLimit.dollarText($0))" } ?? "so far")
                            .foregroundStyle(PhoneTheme.inkMuted)
                        Spacer()
                        if limit.budget != nil {
                            Text("\(Int(percent.rounded()))%")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(UsageColor.color(for: percent))
                        }
                    }
                    if limit.budget != nil {
                        ProgressView(value: percent, total: 100)
                            .tint(UsageColor.color(for: percent))
                    }
                    if let reset = limit.resetsAt, reset > now {
                        Text("Starts over \(reset.formatted(.dateTime.month(.wide).day())).\(limit.budget == nil ? " Set a monthly budget in Usage on your Mac." : "")")
                            .font(.caption)
                            .foregroundStyle(PhoneTheme.inkMuted)
                    }
                }
            }
        }
    }
}
