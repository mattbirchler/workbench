import Foundation
import PostHog

/// Usage analytics for Workbench on the Mac and the iPhone, sent to the
/// shared "Birchtree Apps" PostHog project. `import PostHog` stays in this
/// file, which both apps compile.
///
/// What's sent: the events below, with counts, yes/no values, and values
/// from fixed lists. Never code, prompts, file names, paths, project or
/// branch names, or anything else typed or read from disk.
///
/// Crashes are reported too: when the app crashes, PostHog's crash
/// reporter saves the stack trace (which functions were running, and the
/// app and system versions), and the next launch sends it as an
/// `$exception` event. Folder paths in it have the home folder replaced
/// with `~`, so they don't carry the Mac's account name. Opting out turns
/// this off along with everything else.
///
/// Each install keeps one random anonymous ID, so active users and
/// retention can be counted. There are no person profiles. Time zone,
/// locale, and device name are stripped here; the IP address is discarded
/// by the PostHog project's "Discard client IP data" setting.
enum Analytics {
    /// The PostHog project token. Public by design: it ships in every
    /// client and only allows sending events to this project.
    private static let projectToken = "phc_rBkGD8e38uUJjekGXqxFiBGNaJnDQf8A5TADoNRehTAc"
    private static let host = "https://us.i.posthog.com"

    /// The `app` property on every event, which tells the apps sharing the
    /// project apart. Debug builds that send (see `isDisabled`) say so here,
    /// so the dashboard leaves them out.
    nonisolated static var appName: String {
        #if os(macOS)
        let name = "Workbench"
        #else
        let name = "Workbench iPhone"
        #endif
        #if DEBUG
        return name + " (Debug)"
        #else
        return name
        #endif
    }

    /// Set when the user turns analytics off in Settings.
    static let optedOutKey = "analyticsOptedOut"

    /// Event names. Renaming one breaks the dashboard built on it.
    enum Event: String, CaseIterable {
        // Both apps.
        case appLaunched = "app_launched"
        case updateInstalled = "update_installed"

        // Mac: the welcome.
        case onboardingStepViewed = "onboarding_step_viewed"
        case onboardingContinuedAnyway = "onboarding_continued_anyway"
        case onboardingCompleted = "onboarding_completed"
        case claudeSignInStarted = "claude_sign_in_started"
        case claudeSignInCompleted = "claude_sign_in_completed"
        case agentSetupStarted = "agent_setup_started"
        case agentSetupCompleted = "agent_setup_completed"

        // Mac: everyday use.
        case projectAdded = "project_added"
        case claudeTabOpened = "claude_tab_opened"
        case claudeAccountsFound = "claude_accounts_found"
        case claudeAccountAdded = "claude_account_added"
        case claudeAccountChosen = "claude_account_chosen"
        case tabViewSwitched = "tab_view_switched"
        case tabsSplit = "tabs_split"
        /// The Overview page was opened (property `from`: sidebar, rail,
        /// menu, command_bar, menu_bar or notification).
        case overviewOpened = "overview_opened"
        case artifactOpened = "artifact_opened"
        case artifactTargetChosen = "artifact_target_chosen"
        case agentStarted = "agent_started"
        case agentRemoved = "agent_removed"
        case diffCommentAdded = "diff_comment_added"
        case iphoneEnabled = "iphone_enabled"
        case iphonePaired = "iphone_paired"
        case remoteMacAdded = "remote_mac_added"
        /// The Workbench relay was turned on or off (property `on`).
        case relayToggled = "relay_toggled"
        /// Once a day on a Mac with the relay on: how much went through it
        /// (connections, messages and bytes each way). Counts only.
        case relayUsage = "relay_usage"
        /// At most once a day for each way a client reached a Mac
        /// (property `path`: tailscale, local or relay).
        case connectionPath = "connection_path"
        case feedbackSent = "feedback_sent"
        case claudeModelUsed = "claude_model_used"
        case modelSwitched = "model_switched"
        case effortSet = "effort_set"
        case sideQuestionAsked = "side_question_asked"
        case dictationEnabled = "dictation_enabled"
        case dictationUsed = "dictation_used"

        // iPhone.
        case pairingCompleted = "pairing_completed"
        case replySent = "reply_sent"
        case toolAnswered = "tool_answered"
        case questionAnswered = "question_answered"
        case notificationOpened = "notification_opened"
        case notificationAnswered = "notification_answered"
    }

    private static var started = false

    /// Sets up PostHog and its crash reporter. Call it first thing at
    /// launch, before anything that could crash: a crash that happens
    /// before this runs is never reported. Setup also queues the report of
    /// the last crash, if there was one, and sends it straight away, so it
    /// gets out even if this launch crashes again a moment later.
    static func start() {
        guard !started, !isDisabled else { return }
        started = true
        PostHogSDK.shared.setup(makeConfig())
        PostHogSDK.shared.register(superProperties)
        if isOptedOut { PostHogSDK.shared.optOut() }
        PostHogSDK.shared.flush()
    }

    /// Sends `app_launched` (and `update_installed` after an update). Call
    /// once launch has what the properties need.
    static func launched(_ properties: [String: Any] = [:]) {
        guard started else { return }
        noteVersion()
        capture(.appLaunched, properties)
    }

    /// Notes how a client reached a Mac ("tailscale", "local" or "relay"),
    /// at most once a day for each way.
    static func connectionPath(_ name: String) {
        let key = "analytics.connectionPath.\(name)", today = Int(Date.now.timeIntervalSince1970 / 86_400)
        guard UserDefaults.standard.integer(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        capture(.connectionPath, ["path": name])
    }

    static func capture(_ event: Event, _ properties: [String: Any] = [:]) {
        guard started else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties.isEmpty ? nil : properties)
    }

    static var isOptedOut: Bool {
        get { UserDefaults.standard.bool(forKey: optedOutKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: optedOutKey)
            guard started else { return }
            if newValue { PostHogSDK.shared.optOut() } else { PostHogSDK.shared.optIn() }
        }
    }

    /// Nothing is sent from tests, demo and screenshot runs, test copies of
    /// the Mac app, Debug builds, or copies someone else built from the
    /// source (see OfficialBuild). BENCH_ANALYTICS=1 lets a Debug build
    /// send, as "(Debug)", to check events arrive.
    private static var isDisabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if NSClassFromString("XCTestCase") != nil || env["XCTestConfigurationFilePath"] != nil { return true }
        if env["BENCH_DEMO"] != nil { return true }
        if !OfficialBuild.isOfficial { return true }
        #if DEBUG
        return env["BENCH_ANALYTICS"] != "1"
        #else
        return env["BENCH_SUPPORT_DIR"] != nil
        #endif
    }

    /// `$geoip_disable` stops PostHog looking up a location. The null `$ip`
    /// matches the other Birchtree apps, but PostHog fills the address in
    /// from the request anyway; the project setting is what drops it.
    private static var superProperties: [String: Any] {
        ["app": appName, "$geoip_disable": true, "$ip": NSNull()]
    }

    private static func makeConfig() -> PostHogConfig {
        let config = PostHogConfig(projectToken: projectToken, host: host)
        // Only the events above. PostHog's own "Application Opened" fires on
        // every return to the app, so app_launched is sent instead.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        #if os(iOS)
        config.captureElementInteractions = false
        config.rageClickConfig.enabled = false
        config.surveys = false
        #endif
        // Crash reports. The project's "exception autocapture" setting in
        // PostHog must stay on too, or the SDK turns this back off. Not
        // installed at all when the user has opted out.
        config.errorTrackingConfig.autoCapture = !isOptedOut
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        config.preloadFeatureFlags = false
        // The time zone and locale PostHog adds to every event would show
        // roughly where someone is, and the device name can be a person's
        // name ("Sam's iPhone"). The IP address can't be removed here:
        // PostHog reads it from the request, so the project is set to
        // discard it.
        config.setBeforeSend { event in
            for key in ["$timezone", "$locale", "$device_name"] {
                event.properties.removeValue(forKey: key)
            }
            // Crash reports list every loaded file by its full path, and an
            // app run from Downloads would put the account name in them.
            if event.event == "$exception" {
                event.properties = event.properties.mapValues(withoutHomeFolder)
            }
            return event
        }
        #if DEBUG
        config.debug = true
        #endif
        return config
    }

    private nonisolated static let userFolder = try! NSRegularExpression(pattern: "/Users/[^/]+")

    /// The value with any `/Users/<name>` in its text replaced by `~`, at
    /// any depth.
    nonisolated static func withoutHomeFolder(_ value: Any) -> Any {
        switch value {
        case let text as String:
            return userFolder.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
        case let list as [Any]:
            return list.map(withoutHomeFolder)
        case let dictionary as [String: Any]:
            return dictionary.mapValues(withoutHomeFolder)
        default:
            return value
        }
    }

    /// Sends `update_installed` when this launch is a newer version than the
    /// last one.
    private static func noteVersion() {
        let key = "analyticsLastVersion"
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let last = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(version, forKey: key)
        if let last, last != version {
            capture(.updateInstalled, ["from_version": last])
        }
    }
}
