import Foundation

// What Bench on the Mac and the companion on iPhone say to each other, over
// one WebSocket. Every message is one JSON frame, sent as binary. The phone speaks
// first with `hello`; until the token checks out, nothing else is answered.

/// Bumped when a message changes shape, so an old phone build can say so.
public let companionProtocolVersion = 9

/// Things a Mac can do beyond its protocol version. It lists the ones it
/// has in its welcome, and a client asks for the ones it wants with
/// `features`, so neither side sends the other something it can't read.
public enum CompanionFeature {
    /// Tool results in transcripts: what commands printed, what failed.
    public static let results = "results"
    /// Stopping Claude, as Escape does in its terminal.
    public static let interrupt = "interrupt"
    /// The Mac's terminal colors, to theme the app with.
    public static let theme = "theme"
    /// Messages you sent while Claude was busy, shown as queued until
    /// Claude takes them in.
    public static let queue = "queue"
    /// Taking queued messages back out, to edit or drop them.
    public static let editQueue = "editQueue"
    /// Subagents: what each is doing in the session, and notes in the
    /// conversation when background agents and commands stop.
    public static let agents = "agents"
    /// Sending queued messages right away, as Ctrl+Return does.
    public static let sendNow = "sendNow"
    /// Active and Inactive projects: which is which, which are pinned,
    /// and moving them between the two.
    public static let placement = "placement"
    /// How much of the Claude plan's limits are used, for the rings.
    public static let planUsage = "planUsage"
    /// The pages Claude published for a project, to list and open.
    public static let artifacts = "artifacts"
    /// The slash commands a project's Claude Code offers, to suggest while typing.
    public static let slashCommands = "slashCommands"
    /// Pictures in transcripts as small copies, with the whole picture
    /// on request (`ClientMessage.image`), so a conversation with many
    /// screenshots opens in a frame of kilobytes rather than megabytes.
    public static let imagePreviews = "imagePreviews"
    /// Conversations a page at a time: a short opening frame that says
    /// whether there's more, and `ClientMessage.earlierTranscript` for
    /// the page before it.
    public static let paging = "paging"
    /// Reviewing code: diffs come with the whole file around their changes
    /// (for the phone to fold) and with their code colored, open files
    /// get `ServerMessage.fileCode` after them, and
    /// `ClientMessage.reviewCommit` shows a commit's changes on one page.
    public static let codeReview = "codeReview"
    /// The client pings when the line goes quiet and expects a pong back,
    /// so a Mac that went to sleep or a tunnel that dropped is noticed in
    /// under a minute instead of whenever the OS gives up on the socket.
    /// The Mac, in turn, drops a client that stays silent for a minute.
    public static let keepalive = "keepalive"
    /// A note in the conversation after each long stretch of work: how
    /// long Claude worked and when it finished.
    public static let turnTimes = "turnTimes"
    /// The phone can reach the Mac over the home network, found with
    /// Bonjour and checked against the certificate pinned in the pairing.
    public static let localNetwork = "localNetwork"
    /// Everything in a project's right-click menu on the Mac, for another
    /// Mac's sidebar: renaming, icons, hidden worktrees, removing, phone
    /// notifications, and which Claude account it uses.
    public static let projectMenu = "projectMenu"
    /// Saving a text file another Mac edited (`ClientMessage.writeFile`).
    public static let editFiles = "editFiles"
    /// Adding a folder on the Mac as a project from another Mac, with a
    /// look through its folders to pick one (`ClientMessage.browseFolder`
    /// and `addProject`).
    public static let addProject = "addProject"
}

/// A terminal theme's two main colors, which the rest of a theme is built
/// from.
public struct TerminalColors: Codable, Sendable, Hashable {
    public struct RGB: Codable, Sendable, Hashable {
        public var r: Double, g: Double, b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

        /// How far from gray: 0 for black, white and grays.
        var chroma: Double { max(r, g, b) - min(r, g, b) }

        /// The hue in degrees: 0 red, 60 yellow, 120 green, 240 blue.
        var hue: Double {
            let high = max(r, g, b), spread = chroma
            guard spread > 0 else { return 0 }
            let raw: Double = switch high {
            case r: (g - b) / spread
            case g: 2 + (b - r) / spread
            default: 4 + (r - g) / spread
            }
            let degrees = raw * 60
            return degrees < 0 ? degrees + 360 : degrees
        }

        /// WCAG relative luminance, for contrast.
        var relativeLuminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// True when white text reads on this color. White is preferred, so
        /// it only gives way on light colors like mint or amber.
        public var prefersWhiteText: Bool {
            (1.05 / (relativeLuminance + 0.05)) >= 2.6
        }

        /// Part way from this color to another.
        public func mixed(_ fraction: Double, with other: RGB) -> RGB {
            RGB(r: r + (other.r - r) * fraction, g: g + (other.g - g) * fraction, b: b + (other.b - b) * fraction)
        }

        /// The WCAG contrast ratio against another color, from 1 to 21.
        public func contrast(on other: RGB) -> Double {
            let (a, b) = (relativeLuminance, other.relativeLuminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// This color with at least `contrast` against a background: text
        /// needs 4.5, a line 3. Light themes' greens and yellows often
        /// fall short, so this deepens the color (or lightens it on a dark
        /// background) just enough, keeping its hue.
        public func readable(on background: RGB, contrast wanted: Double) -> RGB {
            guard contrast(on: background) < wanted else { return self }
            let toward: RGB = background.luminance < 0.5 ? .init(r: 1, g: 1, b: 1) : .init(r: 0, g: 0, b: 0)
            for step in 1...7 {
                let mixed = mixed(Double(step) / 10, with: toward)
                if mixed.contrast(on: background) >= wanted { return mixed }
            }
            return mixed(0.7, with: toward)
        }
    }

    public var background: RGB
    public var foreground: RGB
    /// The color for `inline code` in the chat: the theme's blue, made
    /// readable on its background. nil from a Mac that predates it.
    public var code: RGB?
    /// The theme's one bright color, for buttons and your chat bubbles.
    /// nil when the theme has none (or from a Mac that predates it), and
    /// the app keeps its orange.
    public var accent: RGB?
    /// The theme's green, for finished checklist steps and progress bars.
    /// nil on a theme with no green (a monochrome one), or from a Mac that
    /// predates it, and the app keeps its own green.
    public var done: RGB?
    /// The color for Claude at work: a working row's tint and sparkles,
    /// the step under way, the timer. See `workingColor`. nil from a Mac
    /// that predates it, or on a theme with neither an accent nor an
    /// orange, and the app keeps its orange.
    public var working: RGB?

    public init(background: RGB, foreground: RGB, code: RGB? = nil, accent: RGB? = nil,
                done: RGB? = nil, working: RGB? = nil) {
        self.background = background
        self.foreground = foreground
        self.code = code
        self.accent = accent
        self.done = done
        self.working = working
    }

    /// A theme's accent, taken from its cursor color. Some themes use their
    /// text color or plain white for the cursor; those have no accent.
    public static func accent(fromCursor cursor: RGB?) -> RGB? {
        guard let cursor, cursor.chroma >= 0.12 else { return nil }
        return cursor
    }

    /// The done and working colors for a theme, each deepened or lightened
    /// until it reads as text on the background.
    ///
    /// Done is the theme's green from its 16 ANSI colors (black, red,
    /// green, yellow, blue, magenta, cyan, white, then their bright
    /// versions): the bright one on a dark theme, the normal one on a light
    /// theme. One that isn't really green (a monochrome theme's gray, an
    /// amber theme's "green") is left out, so done keeps its meaning in the
    /// app's own green. Working is `workingColor`.
    public static func statusColors(palette: [RGB], background: RGB, foreground: RGB,
                                    accent: RGB?) -> (done: RGB?, working: RGB?) {
        var done: RGB?, orange: RGB?
        if palette.count >= 16 {
            let bright = background.luminance < 0.5
            func pick(_ index: Int) -> RGB { palette[bright ? index + 8 : index] }
            func colored(_ color: RGB, hue: ClosedRange<Double>) -> RGB? {
                guard color.chroma >= 0.12, hue.contains(color.hue) else { return nil }
                return color.readable(on: background, contrast: 4.5)
            }
            done = colored(pick(2), hue: 60...170)
            // Red and yellow half and half: an orange in the theme's own key.
            orange = colored(pick(1).mixed(0.5, with: pick(3)), hue: 5...55)
        }
        return (done, workingColor(accent: accent, orange: orange, background: background, foreground: foreground))
    }

    /// The color for Claude at work. Working is the state you see most and
    /// the one that asks nothing of you, so it wears the theme's accent.
    ///
    /// The other states own their colors: green for done, amber for
    /// waiting on you, blue for a notification or work on another machine.
    /// An accent in any of those (anything from amber round through green
    /// and teal to blue, `clashingHues`) would read as that state, so the
    /// row takes the theme's orange instead. It used to go gray, but a gray
    /// working row looked just like the sidebar's gray selection ring. A
    /// theme with no accent (a gray cursor) keeps its orange too. An orange
    /// that leans amber is left out, and the app keeps its own (nil).
    public static func workingColor(accent: RGB?, orange: RGB?, background: RGB, foreground: RGB) -> RGB? {
        guard let accent else { return orange }
        guard clashingHues.contains(accent.hue) else { return accent.readable(on: background, contrast: 4.5) }
        guard let orange, !clashingHues.contains(orange.hue) else { return nil }
        return orange
    }

    /// Hues an accent can't take for working without looking like another
    /// state: from amber (waiting, about 40°) through green (done) to blue
    /// (notifications, other machines). Reds, oranges, pinks and purples
    /// are free.
    public static let clashingHues: Range<Double> = 28..<250

    public var isDark: Bool { background.luminance < 0.5 }
}


/// What a project is up to. Mirrors Bench's sidebar colors.
public enum ActivityKind: String, Codable, Sendable, Hashable {
    case idle, working, remoteWorking, waiting, done, attention
}

/// A project's pull request and its checks, as Bench shows them.
public struct CompanionPullRequest: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case open, draft, merged, closed }
    public enum Checks: String, Codable, Sendable { case none, pending, passing, failing }

    public var number: Int
    public var title: String
    public var url: URL
    public var state: State
    public var checks: Checks
    public var passedCount: Int
    public var totalCount: Int
    public var failingNames: [String]

    public init(number: Int, title: String, url: URL, state: State, checks: Checks,
                passedCount: Int, totalCount: Int, failingNames: [String]) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.checks = checks
        self.passedCount = passedCount
        self.totalCount = totalCount
        self.failingNames = failingNames
    }
}

/// One Claude tab in a project.
public struct CompanionSession: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var activity: ActivityKind
    /// Your latest prompt.
    public var prompt: String?
    /// What it's doing right now, in words ("Editing Theme.swift").
    public var action: String?
    /// The whole shell command it's running or asking to run, every line
    /// of it. `action` only has room for the start of the first line,
    /// which isn't enough to say yes to. Nil for other tools, and from
    /// older Macs.
    public var command: String?
    /// Its question, while it waits for you.
    public var question: String?
    /// True when Return means Allow and Escape means Deny.
    public var isAllowOrDeny: Bool
    /// The start of its last message, once it stopped.
    public var summary: String?
    public var stoppedAt: Date?
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// The model it's using, like "Opus 5.5". nil before Claude's first
    /// reply, and from Macs that predate it.
    public var model: String?
    /// How hard Claude thinks, as `/effort` takes it, like "high". nil when
    /// the Mac doesn't know, and from Macs that predate it.
    public var effort: String?
    /// The machine it's logged in to over ssh, if any.
    public var remoteHost: String?
    /// True when a message from the phone would reach Claude. When false,
    /// `replyProblem` says why.
    public var canReply = false
    public var replyProblem: String?
    /// True while Claude Code is starting in the tab and hasn't reported in
    /// yet. `replyProblem` says so too, for apps that predate this.
    public var isStarting = false
    /// When its current stretch of work or waiting began, for a timer.
    /// nil while idle or done, and from Macs that predate it.
    public var since: Date?
    /// Claude's checklist for the work in progress, when it keeps one.
    public var checklist: [ChecklistItem]?
    /// The multiple-choice questions on screen, while Claude asks them.
    /// Answer with `ClientMessage.answerQuestions`.
    public var questions: [CompanionQuestion]?
    /// True while Claude Code summarizes the conversation to make room.
    public var isCompacting = false
    /// Its subagents, newest last, while it has any.
    public var agents: [AgentStatus]?
    /// The next message Claude Code suggests you send, while it shows one.
    public var suggestion: String?
    /// Its last few tool calls in the main conversation, newest first.
    /// nil from Macs that predate it.
    public var trail: [ToolAction]?
    /// What Claude last said in words, and when.
    public var note: String?
    public var noteAt: Date?
    /// When you sent your latest prompt.
    public var promptAt: Date?
    /// Claude Code's permission mode, as a `PermissionMode` raw value, read
    /// from its terminal. nil when it isn't on screen, and from Macs that
    /// predate it, which also can't switch it.
    public var permissionMode: String?
    /// Which agent the session runs, what to call it, and what it offers.
    /// All nil for Claude, and from Macs that predate other agents.
    public var agent: AgentID?
    public var agentName: String?
    public var catalog: AgentCatalog?

    public init(id: UUID, title: String, activity: ActivityKind, prompt: String? = nil, action: String? = nil,
                question: String? = nil, isAllowOrDeny: Bool = false, summary: String? = nil, stoppedAt: Date? = nil,
                contextTokens: Int? = nil, contextWindow: Int? = nil, model: String? = nil, remoteHost: String? = nil,
                canReply: Bool = false, replyProblem: String? = nil, since: Date? = nil,
                checklist: [ChecklistItem]? = nil, questions: [CompanionQuestion]? = nil, isCompacting: Bool = false,
                agents: [AgentStatus]? = nil, suggestion: String? = nil, trail: [ToolAction]? = nil,
                note: String? = nil, noteAt: Date? = nil, promptAt: Date? = nil, effort: String? = nil,
                command: String? = nil, permissionMode: String? = nil, isStarting: Bool = false) {
        self.permissionMode = permissionMode
        self.isStarting = isStarting
        self.effort = effort
        self.command = command
        self.id = id
        self.title = title
        self.activity = activity
        self.prompt = prompt
        self.action = action
        self.question = question
        self.isAllowOrDeny = isAllowOrDeny
        self.summary = summary
        self.stoppedAt = stoppedAt
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.model = model
        self.remoteHost = remoteHost
        self.canReply = canReply
        self.replyProblem = replyProblem
        self.since = since
        self.checklist = checklist
        self.questions = questions
        self.isCompacting = isCompacting
        self.agents = agents
        self.suggestion = suggestion
        self.trail = trail
        self.note = note
        self.noteAt = noteAt
        self.promptAt = promptAt
    }

    // Fields added after version 1 are optional when reading, so an older
    // Mac's messages still decode.
    private enum CodingKeys: String, CodingKey {
        case id, title, activity, prompt, action, question, isAllowOrDeny, summary, stoppedAt
        case contextTokens, contextWindow, model, remoteHost, canReply, replyProblem, since, checklist
        case questions, isCompacting, agents, suggestion, trail, note, noteAt, promptAt, effort, command
        case permissionMode, isStarting, agent, agentName, catalog
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        agent = try c.decodeIfPresent(AgentID.self, forKey: .agent)
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        catalog = try? c.decodeIfPresent(AgentCatalog.self, forKey: .catalog)
        title = try c.decode(String.self, forKey: .title)
        activity = try c.decode(ActivityKind.self, forKey: .activity)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        isAllowOrDeny = try c.decodeIfPresent(Bool.self, forKey: .isAllowOrDeny) ?? false
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        stoppedAt = try c.decodeIfPresent(Date.self, forKey: .stoppedAt)
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try? c.decodeIfPresent(String.self, forKey: .effort)
        command = try? c.decodeIfPresent(String.self, forKey: .command)
        remoteHost = try c.decodeIfPresent(String.self, forKey: .remoteHost)
        canReply = try c.decodeIfPresent(Bool.self, forKey: .canReply) ?? false
        replyProblem = try c.decodeIfPresent(String.self, forKey: .replyProblem)
        since = try c.decodeIfPresent(Date.self, forKey: .since)
        checklist = try c.decodeIfPresent([ChecklistItem].self, forKey: .checklist)
        questions = try c.decodeIfPresent([CompanionQuestion].self, forKey: .questions)
        isCompacting = try c.decodeIfPresent(Bool.self, forKey: .isCompacting) ?? false
        agents = try? c.decodeIfPresent([AgentStatus].self, forKey: .agents)
        suggestion = try? c.decodeIfPresent(String.self, forKey: .suggestion)
        trail = try? c.decodeIfPresent([ToolAction].self, forKey: .trail)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        noteAt = try? c.decodeIfPresent(Date.self, forKey: .noteAt)
        promptAt = try? c.decodeIfPresent(Date.self, forKey: .promptAt)
        permissionMode = try? c.decodeIfPresent(String.self, forKey: .permissionMode)
        isStarting = (try? c.decodeIfPresent(Bool.self, forKey: .isStarting)) ?? false
    }
}

/// One of the questions in Claude's multiple-choice picker.
public struct CompanionQuestion: Codable, Sendable, Hashable {
    /// What a plan approval asks. The phone matches on it to offer the plan.
    public static let planApprovalText = "Claude wants you to approve its plan."

    public struct Option: Codable, Sendable, Hashable {
        public var label: String
        public var description: String?
        /// A mock-up, code or diagram Claude drew for this option, as
        /// plain monospaced text. Nil when it has none, and from older Macs.
        public var preview: String?

        public init(label: String, description: String? = nil, preview: String? = nil) {
            self.label = label
            self.description = description
            self.preview = preview
        }
    }

    public var question: String
    /// A short tag for it, like "Auth method".
    public var header: String?
    public var options: [Option]
    /// True when you can pick more than one.
    public var multiSelect: Bool
    /// False when only the options will do, like Claude Code asking
    /// whether to trust a folder. Missing means your own words are fine.
    public var allowsOther: Bool?

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false, allowsOther: Bool? = nil) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
        self.allowsOther = allowsOther
    }

    /// True when Claude drew a preview for its options. Claude Code then
    /// shows them side by side and takes notes on the picked option
    /// instead of your own answer. It only does that for single choice.
    public var hasPreviews: Bool {
        !multiSelect && options.contains { !($0.preview ?? "").isEmpty }
    }
}

/// Your answer to one question: the options you picked, by index, or your
/// own words instead (single-choice questions only).
public struct CompanionAnswer: Codable, Sendable, Hashable {
    public var selected: [Int]
    public var other: String?
    /// Notes on the picked option, for a question with previews, where
    /// Claude Code takes notes rather than your own answer. Nil otherwise.
    public var note: String?

    public init(selected: [Int], other: String? = nil, note: String? = nil) {
        self.selected = selected
        self.other = other
        self.note = note
    }
}

/// A project as the sidebar shows it. A worktree carries its parent's id.
public struct CompanionProject: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var repoName: String
    public var path: String
    public var branch: String?
    public var parentID: UUID?
    /// A worktree made outside Workbench, which can't be discarded from
    /// here. Nil otherwise, and from older Macs.
    public var isExternalWorktree: Bool?
    public var activity: ActivityKind
    public var pullRequest: CompanionPullRequest?
    public var sessions: [CompanionSession]
    /// Whether it's under Active on the Mac, and pinned to the top there.
    /// Nil from a Mac that doesn't sort projects that way.
    public var isActive: Bool?
    public var isPinned: Bool?
    /// Which sidebar section it's in on the Mac. Nil for worktrees, and
    /// from older Macs, which only send `isActive` and `isPinned`.
    public var section: CompanionSection?
    /// How the last merged pull request's deploy went. Nil from older Macs.
    public var deploy: CompanionDeploy?
    /// The branch pull requests merge into, like "main". Nil from older Macs.
    public var defaultBranch: String?
    /// For an agent whose pull request merged: whether it's waiting to be
    /// cleaned up, and what would be lost. Nil otherwise, and from older Macs.
    public var cleanup: CompanionCleanup?
    /// The project's tab shortcuts. Nil from older Macs.
    public var shortcuts: [CompanionShortcut]?
    /// Whether the folder is a git repository. Nil from older Macs: assume git.
    public var isGit: Bool?
    /// Whether it has a name you gave it, rather than its folder's.
    /// Nil from Macs without the projectMenu feature, as are the rest.
    public var hasCustomName: Bool?
    /// Whether its icon is one you picked, in its `.bench` folder.
    public var hasCustomIcon: Bool?
    /// Whether some of its worktrees are hidden from the sidebar.
    public var hasHiddenWorktrees: Bool?
    /// Whether the Mac sends its notifications to the paired iPhone.
    public var notifiesPhone: Bool?
    /// The Claude account its new tabs use, from `ProjectsSnapshot.claudeAccounts`.
    public var claudeAccountID: UUID?

    public var isWorktree: Bool { parentID != nil }

    public init(id: UUID, name: String, repoName: String, path: String, branch: String? = nil, parentID: UUID? = nil,
                isExternalWorktree: Bool? = nil,
                activity: ActivityKind, pullRequest: CompanionPullRequest? = nil, sessions: [CompanionSession] = [],
                isActive: Bool? = nil, isPinned: Bool? = nil, section: CompanionSection? = nil,
                deploy: CompanionDeploy? = nil, defaultBranch: String? = nil, cleanup: CompanionCleanup? = nil,
                shortcuts: [CompanionShortcut]? = nil, isGit: Bool? = nil,
                hasCustomName: Bool? = nil, hasCustomIcon: Bool? = nil, hasHiddenWorktrees: Bool? = nil,
                notifiesPhone: Bool? = nil, claudeAccountID: UUID? = nil) {
        self.isGit = isGit
        self.hasCustomName = hasCustomName
        self.hasCustomIcon = hasCustomIcon
        self.hasHiddenWorktrees = hasHiddenWorktrees
        self.notifiesPhone = notifiesPhone
        self.claudeAccountID = claudeAccountID
        self.cleanup = cleanup
        self.shortcuts = shortcuts
        self.section = section
        self.deploy = deploy
        self.defaultBranch = defaultBranch
        self.id = id
        self.name = name
        self.repoName = repoName
        self.path = path
        self.branch = branch
        self.parentID = parentID
        self.isExternalWorktree = isExternalWorktree
        self.activity = activity
        self.pullRequest = pullRequest
        self.sessions = sessions
        self.isActive = isActive
        self.isPinned = isPinned
    }
}

/// The Mac sidebar's sections, top to bottom.
public enum CompanionSection: String, Codable, Sendable, Hashable, CaseIterable {
    /// Pinned to the top, in your order.
    case pinned
    /// Claude is busy there, or you used it lately (6 hours unless
    /// changed in Settings).
    case active
    /// Used a while ago, but not long enough to be Inactive.
    case recent
    /// Not used for a day (unless changed in Settings), or moved there by
    /// hand.
    case inactive

    public var title: String {
        switch self {
        case .pinned: "Pinned"
        case .active: "Active"
        case .recent: "Recent"
        case .inactive: "Inactive"
        }
    }
}

extension CompanionProject {
    /// Its section, worked out from `isActive` and `isPinned` for a Mac
    /// that doesn't send one. Nil when that Mac doesn't sort projects.
    public var placement: CompanionSection? {
        if let section { return section }
        if isPinned == true { return .pinned }
        guard let isActive else { return nil }
        return isActive ? .active : .inactive
    }
}

/// Everything on the sidebar, in sidebar order.
public struct ProjectsSnapshot: Codable, Sendable, Hashable {
    public var projects: [CompanionProject]
    public var selectedProjectID: UUID?
    /// The Mac's own named groups, in order, when its sidebar groups
    /// projects that way instead of by activity. Nil otherwise, and from
    /// older Macs.
    public var groups: [CompanionGroup]?
    /// The Claude accounts set up on the Mac, main first. Nil from Macs
    /// without the projectMenu feature.
    public var claudeAccounts: [CompanionClaudeAccount]?
    /// How long until an unused project on the Mac moves to Inactive, in
    /// seconds, which is how far back Recent reaches. Nil from older Macs,
    /// which always use a day.
    public var inactiveAfter: TimeInterval?

    public init(projects: [CompanionProject], selectedProjectID: UUID? = nil, groups: [CompanionGroup]? = nil,
                claudeAccounts: [CompanionClaudeAccount]? = nil, inactiveAfter: TimeInterval? = nil) {
        self.projects = projects
        self.selectedProjectID = selectedProjectID
        self.groups = groups
        self.claudeAccounts = claudeAccounts
        self.inactiveAfter = inactiveAfter
    }

    /// The words beside the Recent header, like "Last day" or "Last week".
    public var recentHint: String {
        SidebarTimes.recentHint(inactiveAfter: inactiveAfter ?? SidebarTimes.standard.inactiveAfter)
    }

    /// Projects that aren't worktrees, in order.
    public var topLevel: [CompanionProject] { projects.filter { !$0.isWorktree } }
    public func worktrees(of id: UUID) -> [CompanionProject] { projects.filter { $0.parentID == id } }
}

/// A Claude account on the Mac: its name, and the email it's signed in
/// with if known.
public struct CompanionClaudeAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var email: String?

    public init(id: UUID, name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }
}

/// One of the Mac sidebar's custom groups: its name and its projects, in
/// order. Projects in no group go under Ungrouped.
public struct CompanionGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var projectIDs: [UUID]

    public init(id: UUID, name: String, projectIDs: [UUID]) {
        self.id = id
        self.name = name
        self.projectIDs = projectIDs
    }
}

/// An image sent along with a message. The Mac saves it and puts the
/// path in the prompt, which Claude Code reads as an image.
public struct CompanionAttachment: Codable, Sendable, Hashable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Phone to Mac.
public enum ClientMessage: Codable, Sendable {
    /// The pairing token and the phone's name, as the first message.
    case hello(token: String, device: String)
    case ping
    /// Start or stop getting a session's conversation. The Mac answers with
    /// the whole thing, then sends new messages as they're written.
    case watchTranscript(sessionID: UUID)
    case unwatchTranscript(sessionID: UUID)
    /// Your next message to a session, typed into its terminal and sent.
    case reply(sessionID: UUID, text: String)
    /// A message with images. The text may be empty.
    case replyWithAttachments(sessionID: UUID, text: String, attachments: [CompanionAttachment])
    /// Allow or deny the tool Claude is asking about.
    case answer(sessionID: UUID, allow: Bool)
    /// Answers to Claude's multiple-choice questions, one per question, in order.
    case answerQuestions(sessionID: UUID, answers: [CompanionAnswer])
    /// Start or stop getting a project's git changes as they happen.
    case watchChanges(projectID: UUID)
    case unwatchChanges(projectID: UUID)
    /// One file's diff.
    case diff(projectID: UUID, change: FileChange)
    /// Start or stop getting a project's file list as it changes.
    case watchFiles(projectID: UUID)
    case unwatchFiles(projectID: UUID)
    /// One file's contents, by its path in the project.
    case readFile(projectID: UUID, path: String)
    /// The phone's push token, so the Mac can notify it.
    /// `sealed` is true when the phone can open sealed notifications
    /// (see NotificationSeal); older phones leave it out.
    case registerPush(token: String, sealed: Bool? = nil)
    /// From phones before the dashboard: a Live Activity's push token for
    /// one session, and the token to start one. Macs now ignore both.
    case registerActivity(sessionID: UUID, token: String?)
    case registerActivityStart(token: String)
    /// The lock screen dashboard's push token, and again with `ended`
    /// once it's gone. Only to a Mac that offers `CompanionFeature.dashboard`.
    case registerDashboard(token: String, ended: Bool)
    /// A project's past Claude conversations.
    case pastSessions(projectID: UUID)
    /// Pick a past conversation back up in a Claude tab (or switch to the
    /// tab it's already open in).
    case resumeSession(projectID: UUID, sessionID: String)
    /// Open a new Claude tab, optionally with a first prompt.
    case newClaudeTab(projectID: UUID, prompt: String?)
    /// Start an agent on its own branch and worktree. An empty branch name
    /// means suggest one from the prompt; an empty base means the branch
    /// the Mac's own New Agent sheet would pick (usually main).
    case newAgent(parentID: UUID, prompt: String, branch: String, base: String?)
    /// Put the top-level projects in this order; worktrees stay under their project.
    case reorderProjects(ids: [UUID])
    /// The features from the Mac's welcome that this client uses. Only
    /// sent to a Mac that listed some.
    case features([String])
    /// Stop what Claude is doing in a session, as Escape does.
    case interrupt(sessionID: UUID)
    /// Take every queued message back out of Claude Code, then queue the
    /// ones in `keep` again. `queued` is what this client sees queued, in
    /// order, so the Mac can check it's taking back the right thing.
    case takeBackQueue(sessionID: UUID, queued: [String], keep: [String])
    /// Send the queued messages now instead of after the step Claude is
    /// on, as Ctrl+Return does in its terminal.
    case sendQueueNow(sessionID: UUID)
    /// Pin a project to the top of Active, or unpin it.
    case pinProject(projectID: UUID, pinned: Bool)
    /// Move a project to Active as if just used, or to Inactive until
    /// it's used again.
    case setProjectActive(projectID: UUID, active: Bool)
    /// The pages Claude published for a project. Needs the artifacts feature.
    case artifacts(projectID: UUID)
    /// The slash commands Claude Code offers in a project. Needs the slashCommands feature.
    case slashCommands(projectID: UUID)
    /// The kinds of notifications this phone doesn't want, by its push
    /// token. Needs the notificationPrefs feature.
    case notificationPrefs(token: String, muted: [CompanionNotificationKind])
    /// The whole of a picture that came as a preview, by its id. The Mac
    /// looks in the conversations this client is watching. Needs the
    /// imagePreviews feature.
    case image(imageID: String)
    /// The page of a watched conversation before the message with this
    /// id. Needs the paging feature.
    case earlierTranscript(sessionID: UUID, before: String)
    /// Split one message into tasks across the Mac's projects, without
    /// starting anything. Needs the sendTasks feature.
    case splitTasks(message: String)
    /// Start an agent for each task, as checked on the phone. Needs the
    /// sendTasks feature.
    case startTasks([DraftTask])
    /// Compare a project's changes against this branch, or nil for the
    /// default branch. Needs the branchControls feature.
    case setBaseRef(projectID: UUID, ref: String?)
    /// Read a project's changes and branches again now. Needs the
    /// branchControls feature.
    case refreshChanges(projectID: UUID)
    /// Close a Claude tab, ending Claude in it. Needs the agentLifecycle
    /// feature.
    case closeSession(projectID: UUID, sessionID: UUID)
    /// Remove an agent's worktree: its folder is removed and its
    /// local branch is deleted. `discard` is false for Clean Up after a
    /// merge. Needs the agentLifecycle feature.
    case removeAgent(projectID: UUID, discard: Bool)
    /// Run one of the project's shortcuts in a new tab on the Mac, unless
    /// it's a dev server or a shortcut that reuses its tab and is already
    /// running. Needs the shortcuts feature.
    case runShortcut(projectID: UUID, shortcutID: String)
    /// Close the tabs running a shortcut, which stops it. Needs the
    /// shortcuts feature.
    case stopShortcut(projectID: UUID, shortcutID: String)
    /// One commit's message and every file's diff. Needs the codeReview feature.
    case reviewCommit(projectID: UUID, hash: String)
    /// Ask a `/btw` side question about a session's conversation, without
    /// adding it. The answer comes back as `ServerMessage.sideQuestion`
    /// to every client watching the session, with this id. Needs the
    /// sideQuestions feature.
    case askSideQuestion(sessionID: UUID, id: UUID, question: String)
    /// Close a session's side question, stopping it if it's still being
    /// answered, if it's still this one. Needs the sideQuestions feature.
    case dismissSideQuestion(sessionID: UUID, id: UUID)
    /// Rename a project. An empty name goes back to its folder's. Needs
    /// the projectMenu feature, as do the rest.
    case renameProject(projectID: UUID, name: String)
    /// Use this image as the project's icon, or go back to the automatic
    /// one when nil. `fileExtension` is the image's, like "png".
    case setProjectIcon(projectID: UUID, image: Data?, fileExtension: String?)
    /// Show the worktrees hidden from under a project again.
    case showHiddenWorktrees(projectID: UUID)
    /// Take a project out of Workbench. Its folder stays where it is.
    case removeProject(projectID: UUID)
    /// Take a worktree made outside Workbench off the sidebar.
    case hideExternalWorktree(projectID: UUID)
    /// Whether the project's notifications go to the paired iPhone.
    case setNotifiesPhone(projectID: UUID, isOn: Bool)
    /// Which Claude account the project's new tabs use.
    case setClaudeAccount(projectID: UUID, accountID: UUID)
    /// Switch Claude Code's permission mode, a `PermissionMode` raw value.
    /// Only to a Mac whose sessions report `permissionMode`.
    case setPermissionMode(sessionID: UUID, mode: String)
    /// Replace a text file in the project with this, from another Mac's
    /// file tab. Only for a file the list offers. Answered with `fileSaved`.
    case writeFile(projectID: UUID, path: String, text: String)
    /// The folders inside a folder on the Mac, to pick a project from. Nil
    /// is the home folder, and a leading `~` means it too. Answered with
    /// `folder`.
    case browseFolder(path: String?)
    /// Add this folder on the Mac as a project. Answered with `projectAdded`.
    case addProject(path: String)
}

/// Mac to phone.
public enum ServerMessage: Codable, Sendable {
    /// The token was accepted.
    case welcome(macName: String, protocolVersion: Int, features: [String]? = nil, appVersion: String? = nil)
    /// The whole sidebar, sent on hello and whenever anything changes.
    case projects(ProjectsSnapshot)
    /// Sidebar icons as PNG data, sent on hello and when they change.
    case icons([UUID: Data])
    case error(String)
    case pong
    /// Messages for a watched session. `replaces` means start over with
    /// these; otherwise add them to the end. With the paging feature,
    /// `hasMore` says whether the conversation goes back further than
    /// the first of these.
    case transcript(sessionID: UUID, messages: [TranscriptMessage], replaces: Bool, hasMore: Bool? = nil)
    /// The page asked for with `ClientMessage.earlierTranscript`, to go
    /// before what the client has. `hasMore` is true when there are
    /// earlier pages still.
    case earlierTranscript(sessionID: UUID, messages: [TranscriptMessage], hasMore: Bool)
    /// Whether a reply or answer went through, and why not if it didn't.
    case sent(sessionID: UUID, ok: Bool, problem: String?)
    /// A watched project's git state, sent when watching starts and on change.
    case changes(projectID: UUID, snapshot: ChangesSnapshot)
    /// The diff that was asked for, parsed and word-highlighted.
    case diff(projectID: UUID, changeID: String, lines: [DiffLine])
    /// A watched project's files, sent when watching starts and when files
    /// come or go.
    case files(projectID: UUID, listing: FileListing)
    /// Goes up when anything in a watched project changes, so open files
    /// can ask again.
    case fileRevision(projectID: UUID, revision: Int)
    /// The file that was asked for.
    case file(projectID: UUID, path: String, content: FileContent)
    /// What to color in a text file that was just sent, for clients with
    /// the codeReview feature. Not sent for languages the Mac can't read.
    case fileCode(projectID: UUID, path: String, runs: [CodeRun])
    /// The commit asked for with `ClientMessage.reviewCommit`, or nil
    /// review when the Mac couldn't read it.
    case commitReview(projectID: UUID, hash: String, review: CommitReview?)
    case pastSessions(projectID: UUID, sessions: [PastSessionSummary])
    /// A tab the phone asked for is open. The phone shows it.
    case started(projectID: UUID, sessionID: UUID)
    /// Something the phone asked for didn't work.
    case problem(String)
    /// The Mac's terminal colors, or nil when it isn't matching a theme.
    /// Sent to clients that asked for the theme feature, and on change.
    case theme(TerminalColors?)
    /// The plan's limits, or nil when there are none to show. Sent to
    /// clients that asked for the planUsage feature, and on change.
    case planUsage(PlanUsage?)
    /// A project's published pages, newest update first.
    case artifacts(projectID: UUID, links: [ArtifactLink])
    /// A project's slash commands.
    case slashCommands(projectID: UUID, commands: [SlashCommand])
    /// The Usage page's numbers, or nil when there's nothing yet. Sent to
    /// clients that asked for the usage feature, and on change.
    case usage(CompanionUsage?)
    /// Today's morning summary, from older Macs. Ignored now.
    case morningSummary(CompanionMorningSummary?)
    /// The whole picture that was asked for with `ClientMessage.image`.
    case image(TranscriptImage)
    /// The tasks a message split into, for `ClientMessage.splitTasks`.
    case taskSplit(TaskSplitResult)
    /// Which of the tasks sent with `ClientMessage.startTasks` didn't
    /// start, by task id, and why. Empty means every agent started.
    case tasksStarted(failures: [UUID: String])
    /// A watched session's side question as it's answered, or nil once
    /// it's closed. Sent to clients with the sideQuestions feature.
    case sideQuestion(sessionID: UUID, question: SideQuestion?)
    /// The answer to `writeFile`: it's on disk, or `problem` says why not.
    case fileSaved(projectID: UUID, path: String, problem: String?)
    /// The answer to `browseFolder`.
    case folder(FolderListing)
    /// The answer to `addProject`: the project, new or already there, or
    /// `problem` says why not.
    case projectAdded(path: String, projectID: UUID?, problem: String?)
}

/// A past conversation, as Bench's Past Sessions popover lists it.
public struct PastSessionSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String?
    public var firstPrompt: String?
    public var lastPrompt: String?
    public var branch: String?
    public var modified: Date
    /// The tab it's open in right now, if any.
    public var openTabID: UUID?

    public init(id: String, title: String? = nil, firstPrompt: String? = nil, lastPrompt: String? = nil,
                branch: String? = nil, modified: Date, openTabID: UUID? = nil) {
        self.id = id
        self.title = title
        self.firstPrompt = firstPrompt
        self.lastPrompt = lastPrompt
        self.branch = branch
        self.modified = modified
        self.openTabID = openTabID
    }
}

public enum CompanionCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
