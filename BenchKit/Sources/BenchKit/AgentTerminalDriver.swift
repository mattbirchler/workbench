import Foundation

/// How Workbench works an agent's terminal: which keys do what, and how to
/// read its screen and its window title. Each agent's command-line tool
/// draws its own interface, so everything that depends on what one looks
/// like is here. `TerminalManager` decides when to act (is the tab waiting,
/// is it on this Mac) and does the timing; the driver says which keys and
/// what the screen means.
///
/// A nil key, or a false capability, means the agent has no such thing,
/// and the app leaves that control out.
public protocol AgentTerminalDriver: Sendable {
    typealias Key = AgentKey

    // MARK: Keys

    /// Says yes to an allow-or-deny question.
    var allowKey: Key { get }
    /// Says no to one.
    var denyKey: Key { get }
    /// Stops what the agent is doing.
    var interruptKey: Key { get }
    /// Sends queued messages now instead of after the current step.
    var sendQueueNowKey: Key? { get }
    /// Moves to the next permission mode.
    var nextModeKey: Key? { get }
    /// True when queued messages can be taken back out by pressing Up in
    /// an empty message box.
    var takesBackQueue: Bool { get }

    // MARK: The window title

    /// True when a title starts with the mark the agent shows while it works.
    func isWorkingMark(_ scalar: Unicode.Scalar) -> Bool
    /// True while the title is the agent's own, so it's in front in the
    /// terminal. `title` has any working mark taken off.
    func titleIsAgents(_ title: String?) -> Bool
    /// True when the title is what the shell shows while the agent's
    /// program is starting up.
    func titleIsStarting(_ title: String?) -> Bool

    // MARK: The screen

    /// What's in the message box. Nil when it isn't on screen.
    func messageBox(in screen: String?) -> String?
    /// True when the message box holds the agent's own hint, not words
    /// someone typed.
    func isHint(_ box: String) -> Bool
    /// True when the hint says queued messages can be taken back.
    func isQueueHint(_ box: String) -> Bool
    /// The permission mode on screen.
    func permissionMode(in screen: String?) -> PermissionMode?
    /// A question the agent asks in its terminal before a session starts,
    /// like whether to trust the folder. It comes before any hook runs,
    /// so the screen is the only place to find it.
    func startupPrompt(in screen: String) -> StartupPrompt?
    /// True when the agent's message box is at the bottom of the screen,
    /// for an agent whose hooks say nothing until the first message.
    func showsMessageBox(in screen: String?) -> Bool
    /// A message as this agent takes it, for a command the chat words
    /// Claude's way, like `/effort high`.
    func typed(_ message: String) -> String
    /// How long to wait after typing a message before pressing Return,
    /// in milliseconds.
    var returnDelay: Int { get }
    /// The choices in the agent's plan approval picker.
    func planApproval(in screen: String?) -> CompanionQuestion?
    /// The keys that answer the agent's multiple-choice picker.
    func answerSteps(questions: [CompanionQuestion], answers: [CompanionAnswer]) -> Result<[AnswerStep], AnswerProblem>
}

/// One thing to do in an agent's picker: press a key, or type text.
public enum AnswerStep: Equatable, Sendable {
    case key(AgentKey)
    case text(String)
}

public struct AnswerProblem: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) { self.message = message }
}

/// A question an agent asks in its terminal before a session starts, as
/// a card you can answer from the chat or another device.
public struct StartupPrompt: Sendable {
    /// How to pick one of the question's options.
    public struct Answer: Sendable {
        /// Keys that move to the option, when the cursor doesn't start on it.
        public var moves: [AgentKey]
        /// Words on the option's line, checked to be on the cursor's line
        /// after the moves and before confirming.
        public var picked: String?
        public var confirm: AgentKey

        public init(moves: [AgentKey] = [], picked: String? = nil, confirm: AgentKey = .returnKey) {
            self.moves = moves
            self.picked = picked
            self.confirm = confirm
        }
    }

    public var question: CompanionQuestion
    /// Why a message can't be sent yet, after the agent's name: "is
    /// asking whether to trust this folder".
    public var blocker: String
    /// One per option of the question, in order.
    public var answers: [Answer]

    public init(question: CompanionQuestion, blocker: String, answers: [Answer]) {
        self.question = question
        self.blocker = blocker
        self.answers = answers
    }

    /// True when a screen shows the cursor on the line with these words.
    public static func cursorIsOn(_ words: String, in screen: String?) -> Bool {
        screen?.components(separatedBy: "\n").contains { line in
            (line.contains("❯") || line.contains("›")) && line.contains(words)
        } ?? false
    }
}

public extension AgentTerminalDriver {
    func typed(_ message: String) -> String { message }
    var returnDelay: Int { 200 }
}
