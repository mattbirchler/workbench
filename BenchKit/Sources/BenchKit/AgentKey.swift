import Foundation

/// A key Workbench presses in an agent's terminal for you: the handful
/// that answer a question, stop the agent or move through a picker.
///
/// The Mac presses them in its on-screen terminal. A host with no screen
/// (Workbench on a Linux box) encodes them for the terminal it keeps in
/// memory. Either way an agent's driver only says which key.
public enum AgentKey: Equatable, Sendable {
    case returnKey, escape
    case rightArrow, downArrow, upArrow, backspace
    /// Ctrl+Return: Claude Code's "send now" for queued messages.
    case controlReturn
    /// 1 through 9 on the top row: picks an option in Claude Code's pickers.
    case digit(Int)
    /// Shift+Tab: steps Claude Code to its next permission mode.
    case backTab
    /// N: opens the notes on the picked option, when Claude Code shows
    /// a question's previews side by side.
    case notes
}
