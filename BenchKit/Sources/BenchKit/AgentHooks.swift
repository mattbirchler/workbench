import Foundation

/// The shell commands Workbench's hooks are made of. Every agent that
/// supports hooks runs them the same way (a command, with the event's
/// JSON on its input), so a provider only decides which of its events
/// run which of these.
public enum AgentHookCommands {
    public static func command(_ script: String) -> [String: Any] { ["type": "command", "command": script] }

    /// Records the tab's state. Written via a temp file and a rename so
    /// Workbench never reads a half-written file.
    public static func writeState(_ state: AgentState) -> [String: Any] {
        command(#"if [ -n "$BENCH_STATE_FILE" ]; then printf '\#(state.rawValue)' > "$BENCH_STATE_FILE.tmp" && mv -f "$BENCH_STATE_FILE.tmp" "$BENCH_STATE_FILE"; fi"#)
    }

    /// Back to working once a tool finishes, unless the tab is waiting on
    /// permission for a different command. An agent that runs several
    /// commands at once finishes the ones that need no permission while
    /// one is still asking, and that one has to stay on screen. The
    /// command being asked about is in the saved permission event; a
    /// finished tool whose event has the same command is the one allowed.
    public static var workingAfterTool: [String: Any] { command(#"if [ -n "$BENCH_STATE_FILE" ]; then e=$(cat); q="$BENCH_STATE_FILE.question.json"; if [ "$(cat "$BENCH_STATE_FILE" 2>/dev/null)" = waiting ] && [ -f "$q" ]; then c=$(sed -nE 's/.*"tool_input":\{"command":("([^"\\]|\\.)*").*/\1/p' "$q" | head -n 1); case "$e" in *"\"command\":$c"*) ;; *) exit 0 ;; esac; fi; printf 'working' > "$BENCH_STATE_FILE.tmp" && mv -f "$BENCH_STATE_FILE.tmp" "$BENCH_STATE_FILE"; fi"#) }

    /// Saves the event's JSON as `<tab id>.<event>.json`, via a temp file
    /// and a rename like `writeState`.
    public static func saveEvent(_ event: String) -> [String: Any] {
        command(#"if [ -n "$BENCH_STATE_FILE" ]; then cat > "$BENCH_STATE_FILE.\#(event).tmp" && mv -f "$BENCH_STATE_FILE.\#(event).tmp" "$BENCH_STATE_FILE.\#(event).json"; fi"#)
    }

    /// Records the session that just started as the tab's own.
    public static var recordSession: [String: Any] { command(#"if [ -n "$BENCH_SESSION_FILE" ]; then cat > "$BENCH_SESSION_FILE"; fi"#) }
    /// Forgets the tab's session, once you've ended it yourself.
    public static var forgetSession: [String: Any] { command(#"if [ -n "$BENCH_SESSION_FILE" ]; then rm -f "$BENCH_SESSION_FILE"; fi"#) }
    /// Clears the tab's state when the agent exits.
    public static var clearState: [String: Any] { command(#"if [ -n "$BENCH_STATE_FILE" ]; then rm -f "$BENCH_STATE_FILE"; fi"#) }

    /// Tells the agent, once, that `bench` has changed since its session
    /// started. What it prints is added to the prompt being sent. The
    /// file is found from the state file's folder so it also works in a
    /// session started before this hook existed, if the agent picks the
    /// hook up there.
    public static var commandsChanged: [String: Any] { command(#"if [ -n "$BENCH_STATE_FILE" ]; then f="$(dirname "$(dirname "$BENCH_STATE_FILE")")/bench-commands"; m="$BENCH_STATE_FILE.commands"; now=$(head -n 1 "$f" 2>/dev/null); if [ -n "$now" ] && [ "$now" != "${BENCH_COMMANDS:-}" ] && [ "$now" != "$(cat "$m" 2>/dev/null)" ]; then printf '%s' "$now" > "$m"; tail -n +2 "$f"; fi; fi"#) }
}

/// Single quotes keep the shell from touching anything inside.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// The hooks a Claude Code session is started with, so it reports what
/// it's doing: on the Mac, and on a Workbench host with no screen.
public enum ClaudeHooks {
    /// Subagents run the tab's hooks too, and keep working in the
    /// background while Claude asks you something. Their tool calls would
    /// replace the question's tool file and mark the tab working, and the
    /// chat view would drop the question. So a subagent's call (Claude Code
    /// adds `agent_id` only for those) does nothing while the tab waits on
    /// a question or a plan approval.
    private static func ignoringSubagentsDuringPicker(_ hook: [String: Any]) -> [String: Any] {
        guard let command = hook["command"] as? String else { return hook }
        var wrapped = hook
        wrapped["command"] = #"input=$(cat); case "$input" in *'"agent_id":'*) if [ "$(cat "$BENCH_STATE_FILE" 2>/dev/null)" = waiting ] && grep -Eq '"tool_name": *"(AskUserQuestion|ExitPlanMode)"' "$BENCH_STATE_FILE.tool.json" 2>/dev/null; then exit 0; fi ;; esac; printf '%s' "$input" | { "#
            + command + "; }"
        return wrapped
    }

    /// Claude Code hands its status line command the plan's 5-hour and
    /// weekly usage. This one saves that for `PlanUsageMonitor` (only when
    /// it has the numbers), then runs your own status line, if you have
    /// one, so the terminal looks the same as it does without Bench.
    private static let statusLineCommand =
        #"input=$(cat); case "$input" in *'"rate_limits"'*) if [ -n "$BENCH_STATUS_FILE" ]; then printf '%s' "$input" > "$BENCH_STATUS_FILE.$$" && mv -f "$BENCH_STATUS_FILE.$$" "$BENCH_STATUS_FILE"; fi ;; esac; if [ -n "$BENCH_USER_STATUS_LINE" ]; then printf '%s' "$input" | /bin/bash -c "$BENCH_USER_STATUS_LINE"; fi"#

    /// Bench's settings for a Claude tab: its hooks, plus a status line
    /// that keeps the user's own padding.
    public static func settings(userStatusLine: [String: Any]?) -> [String: Any] {
        var settings = hooks
        var statusLine: [String: Any] = ["type": "command", "command": statusLineCommand]
        if let padding = userStatusLine?["padding"] { statusLine["padding"] = padding }
        settings["statusLine"] = statusLine
        return settings
    }

    private typealias Hook = AgentHookCommands

    public static var hooks: [String: Any] { [
        "hooks": [
            "SessionStart": [[
                "hooks": [Hook.recordSession,
                          // Also tells the state watcher, for the model and
                          // the new transcript after /clear.
                          Hook.saveEvent("start")],
            ]],
            "SessionEnd": [[
                "matcher": "prompt_input_exit|logout",
                "hooks": [Hook.forgetSession],
            ], [
                "hooks": [Hook.clearState],
            ]],
            "UserPromptSubmit": [["hooks": [Hook.writeState(.working), Hook.saveEvent("prompt"), Hook.commandsChanged]]],
            // Runs before each tool, including before asking permission for it.
            "PreToolUse": [["hooks": [ignoringSubagentsDuringPicker(Hook.saveEvent("tool"))]], [
                // These put a picker on screen without a Notification, so
                // mark the tab as waiting for you right away.
                "matcher": "AskUserQuestion|ExitPlanMode",
                "hooks": [Hook.writeState(.waiting)],
            ]],
            // Runs after each tool, including right after you approve one.
            "PostToolUse": [["hooks": [ignoringSubagentsDuringPicker(Hook.writeState(.working))]]],
            "Notification": [[
                "matcher": "permission_prompt|elicitation_dialog",
                "hooks": [Hook.writeState(.waiting), Hook.saveEvent("question")],
            ]],
            "Stop": [["hooks": [Hook.writeState(.done), Hook.saveEvent("stop")]]],
            // Wakes Bench up to see that a subagent finished.
            "SubagentStop": [["hooks": [Hook.saveEvent("agent")]]],
            // A model switch picked in the chat view (Mac or phone) goes
            // ahead without Claude's "Switch model?" question, which only
            // its terminal could answer. The chat view asks first itself.
            // `/model` typed in the terminal still gets Claude's question.
            "PreModelSwitch": [["hooks": [Hook.command(#"m="$BENCH_STATE_FILE.model-ok"; if [ -n "$BENCH_STATE_FILE" ] && [ -n "$(find "$m" -mmin -1 2>/dev/null)" ]; then rm -f "$m"; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreModelSwitch","permissionDecision":"allow"}}'; fi"#)]]],
            // Runs right after the model changes, however it happened, so
            // the chat view shows the new one without waiting for a reply.
            // Prints nothing: what it prints would reach Claude.
            "PostModelSwitch": [["hooks": [Hook.saveEvent("model")]]],
            // Summarizing the conversation to make room, and done with it.
            "PreCompact": [["hooks": [Hook.saveEvent("compact")]]],
            "PostCompact": [["hooks": [Hook.saveEvent("compacted")]]],
        ],
    ] }
}
