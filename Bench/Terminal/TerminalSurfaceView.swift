import AppKit
import BenchKit
import GhosttyKit
import Synchronization
import UniformTypeIdentifiers

@MainActor
protocol TerminalSurfaceDelegate: AnyObject {
    func terminal(_ view: TerminalSurfaceView, didSetTitle title: String)
    func terminal(_ view: TerminalSurfaceView, didChangeDirectory path: String)
    func terminal(_ view: TerminalSurfaceView, didNotify title: String, body: String)
    func terminal(_ view: TerminalSurfaceView, requestedGoToTab tab: ghostty_action_goto_tab_e) -> Bool
    func terminalDidRingBell(_ view: TerminalSurfaceView)
    /// A program reported progress (OSC 9;4). Claude Code uses this while it works.
    func terminal(_ view: TerminalSurfaceView, didReportProgress active: Bool)
    func terminalRequestedNewTab(_ view: TerminalSurfaceView)
    func terminalDidClose(_ view: TerminalSurfaceView)
    /// The program ended with an error, so Ghostty is about to show
    /// "Process exited" and wait for a key. True if the delegate dealt
    /// with it instead.
    func terminalChildExited(_ view: TerminalSurfaceView) -> Bool
    /// Clicked, so it has the keyboard now. Only clicks count, not focus
    /// AppKit hands out on its own, like to the first view in a new window.
    func terminalWasClicked(_ view: TerminalSurfaceView)
    /// Ghostty's "go to split" keys. True if there was another pane to go to.
    func terminalRequestedOtherPane(_ view: TerminalSurfaceView) -> Bool
}

extension TerminalSurfaceDelegate {
    func terminalWasClicked(_ view: TerminalSurfaceView) {}
    func terminalRequestedOtherPane(_ view: TerminalSurfaceView) -> Bool { false }
    func terminalChildExited(_ view: TerminalSurfaceView) -> Bool { false }
}

/// An AppKit view hosting one libghostty surface (one shell process).
/// Keyboard, IME, and mouse handling are adapted from Ghostty's macOS app (MIT licensed).
final class TerminalSurfaceView: NSView {
    weak var delegate: TerminalSurfaceDelegate?
    private(set) var surface: ghostty_surface_t?
    var cellSize: NSSize = .zero

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?
    private var focused = false

    struct Launch {
        var workingDirectory: String
        /// Typed into the shell once it starts, e.g. "claude\n". The shell stays
        /// around after the command exits.
        var initialInput: String?
        /// The program to run, as a shell command line. nil uses Ghostty's
        /// default (the user's login shell).
        var command: String?
        /// Extra environment variables for the shell and what it runs.
        var environment: [String: String] = [:]
    }

    init(launch: Launch) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true

        guard let app = GhosttyRuntime.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // libghostty copies these while creating the surface, so they only
        // need to live until ghostty_surface_new returns.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ string: String) -> UnsafeMutablePointer<CChar> {
            let pointer = strdup(string)!
            owned.append(pointer)
            return pointer
        }
        defer { owned.forEach { free($0) } }

        config.working_directory = UnsafePointer(c(launch.workingDirectory))
        if let input = launch.initialInput { config.initial_input = UnsafePointer(c(input)) }
        if let command = launch.command { config.command = UnsafePointer(c(command)) }
        var env = launch.environment.map { ghostty_env_var_s(key: c($0.key), value: c($0.value)) }
        surface = env.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return ghostty_surface_new(app, &config)
        }
        updateColorScheme()

        updateTrackingAreas()
        register()
        registerForDraggedTypes(Self.droppedTypes)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// A view that's gone must take its surface with it: libghostty keeps
    /// the view's address as the surface's userdata, and hands it back in
    /// every callback.
    deinit {
        Self.live.withLock { $0[UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())] = nil }
        // Views go away on the main thread; the surface must go with them.
        MainActor.assumeIsolated { close() }
    }

    /// Frees the surface, which ends the shell. Call before dropping the view.
    func close() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    // MARK: Views by address

    /// Every live view by its address, so a callback that lands after a
    /// hop to the main thread can tell a view from a freed one.
    nonisolated private final class WeakView: @unchecked Sendable {
        nonisolated(unsafe) weak var view: TerminalSurfaceView?
        init(_ view: TerminalSurfaceView) { self.view = view }
    }

    nonisolated private static let live = Mutex<[UInt: WeakView]>([:])

    private func register() {
        Self.live.withLock { $0[UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())] = WeakView(self) }
    }

    /// The view libghostty's userdata points at, or nil once it's gone.
    nonisolated static func view(forUserdata userdata: UnsafeMutableRawPointer) -> TerminalSurfaceView? {
        let address = UInt(bitPattern: userdata)
        return live.withLock { $0[address]?.view }
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Whether something other than the shell itself is running (e.g. Claude).
    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    func perform(binding action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Layout

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Taking a focused terminal out of the window (as a tab moves into
        // a split) skips resignFirstResponder, so it would go on thinking it
        // had the keyboard and take Cmd+V from the side that does.
        if focused, window?.firstResponder !== self { setFocused(false) }
        updateContentScale()
        updateSurfaceSize()
        updateColorScheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorScheme()
    }

    private var lastColorScheme: ghostty_color_scheme_e?

    /// Tells Ghostty whether macOS is in light or dark mode, so a config like
    /// `theme = light:Rose Pine Dawn,dark:Rose Pine` follows the system.
    /// Background tabs catch up when they're shown again.
    func updateColorScheme() {
        guard let surface else { return }
        let scheme = effectiveAppearance.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        guard scheme != lastColorScheme else { return }
        lastColorScheme = scheme
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateContentScale()
        updateSurfaceSize()
    }

    private func updateContentScale() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scaled = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocused(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func setFocused(_ value: Bool) {
        focused = value
        if let surface { ghostty_surface_set_focus(surface, value) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Sends text as if it were pasted. Programs that support bracketed
    /// paste, like Claude Code, take multi-line text as one input without
    /// submitting it.
    func sendText(_ text: String) {
        guard let surface else { return }
        let bytes = Array(text.utf8)
        // An empty buffer has no base address, and an empty answer from the
        // phone used to get here.
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ghostty_surface_text(surface, $0, UInt(buffer.count))
            }
        }
    }

    nonisolated enum SpecialKey: Equatable, Sendable {
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

        var keyCode: UInt16 {
            switch self {
            case .returnKey, .controlReturn: 36
            case .escape: 53
            case .rightArrow: 124
            case .downArrow: 125
            case .upArrow: 126
            case .backspace: 51
            case .digit(let n): [18, 19, 20, 21, 23, 22, 26, 28, 25][max(0, min(8, n - 1))]
            case .backTab: 48
            case .notes: 45
            }
        }
        var characters: String {
            switch self {
            case .returnKey, .controlReturn: "\r"
            case .escape: "\u{1b}"
            case .rightArrow: String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
            case .downArrow: String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
            case .upArrow: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
            case .backspace: "\u{7f}"
            case .digit(let n): String(max(1, min(9, n)))
            case .backTab: "\u{19}"
            case .notes: "n"
            }
        }
        var charactersIgnoringModifiers: String {
            switch self {
            case .backTab: "\t"
            default: characters
            }
        }
        /// Keys that type a character, which goes along with the press.
        var isPrintable: Bool {
            switch self {
            case .digit, .notes: true
            default: false
            }
        }
        var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .controlReturn: .control
            case .backTab: .shift
            case .rightArrow, .downArrow, .upArrow: [.numericPad, .function]
            default: []
            }
        }
    }

    /// The column the cursor is in, counting from 0.
    func cursorColumn() -> Int? {
        guard let surface else { return nil }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let size = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard size.cell_width_px > 0 else { return nil }
        // The point is in points; the cell size is in pixels.
        return Int((x * scale / Double(size.cell_width_px)).rounded(.down))
    }

    /// The text on screen right now, top to bottom.
    func visibleText() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Presses a key as if typed, even when this terminal isn't focused or
    /// on screen. Unlike `sendText`, programs see a real key press: Return
    /// submits instead of being pasted as a newline.
    func press(_ key: SpecialKey) {
        guard let surface else { return }
        for (type, action) in [(NSEvent.EventType.keyDown, GHOSTTY_ACTION_PRESS), (.keyUp, GHOSTTY_ACTION_RELEASE)] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                isARepeat: false, keyCode: key.keyCode
            ) else { continue }
            var ghosttyEvent = Self.keyEvent(event, action)
            if key.isPrintable, type == .keyDown {
                // A printable key carries its text.
                key.characters.withCString { text in
                    ghosttyEvent.text = text
                    _ = ghostty_surface_key(surface, ghosttyEvent)
                }
            } else {
                // Control characters carry no text; libghostty encodes them from the key code.
                _ = ghostty_surface_key(surface, ghosttyEvent)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        delegate?.terminalWasClicked(self)
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event) }
    }

    @discardableResult
    private func sendButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Self.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(Self.momentum(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    private static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: pointerStyle = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: pointerStyle = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: pointerStyle = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: pointerStyle = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: pointerStyle = .crosshair
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: pointerStyle = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: pointerStyle = .resizeUpDown
        default: pointerStyle = .arrow
        }
    }

    private var pointerStyle: NSCursor = .arrow {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: pointerStyle)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Respect configs such as macos-option-as-alt.
        let translationFlags = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationFlags.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }

        // Reuse the original event when nothing changed. AppKit's IME relies on identity.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                if markedTextBefore {
                    sendCommittedText(action, text: text)
                } else {
                    sendKey(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            if Self.isComposingControl(event.characters, composing: composing) { return }
            sendKey(action, event: event, translationEvent: translationEvent,
                    text: Self.ghosttyCharacters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Every view in the window is offered key equivalents, not just the
        // first responder, so only the terminal that has the keyboard acts.
        guard event.type == .keyDown, focused, window?.firstResponder === self else { return false }

        var bindingFlags: ghostty_binding_flags_e?
        if let surface {
            var key = Self.keyEvent(event, GHOSTTY_ACTION_PRESS)
            var flags = ghostty_binding_flags_e(0)
            let isBinding = (event.characters ?? "").withCString { ptr in
                key.text = ptr
                return ghostty_surface_key_is_binding(surface, key, &flags)
            }
            if isBinding { bindingFlags = flags }
        }

        // Performable bindings (Cmd+C, Cmd+V) skip the menu, as in Ghostty:
        // when there's nothing to do, like Cmd+C with no terminal selection,
        // Ghostty hands the key to the program instead. Claude Code relies on
        // that to copy its own selection when copyOnSelect is off. Through
        // the Edit menu the key was swallowed and nothing was copied.
        if let bindingFlags, Self.isPerformable(bindingFlags) {
            keyDown(with: event)
            return true
        }

        // Bench's own menu shortcuts (new tab, switch project, ...) win over
        // Ghostty's other keybindings.
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }

        if bindingFlags != nil {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }
        keyDown(with: final)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        let mods = Self.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        sendKey(action, event: event)
    }

    @discardableResult
    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var key = Self.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        key.composing = composing
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20 {
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    private func sendCommittedText(_ action: ghostty_input_action_e, text: String) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let string = markedText.string
            string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(string.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { perform(binding: "copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform(binding: "paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { perform(binding: "select_all") }

    // MARK: Helpers

    /// Whether a binding only takes effect when it has something to act on,
    /// passing the key to the program otherwise.
    static func isPerformable(_ flags: ghostty_binding_flags_e) -> Bool {
        flags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue != 0
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    private static func keyEvent(
        _ event: NSEvent,
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = mods(event.modifierFlags)
        // Control and command never contribute to text translation.
        key.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// The event's text, minus control characters and function-key private-use
    /// codepoints, which libghostty encodes itself.
    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20
    }
}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: max(height, cellSize.height))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let value as NSAttributedString: chars = value.string
        case let value as String: chars = value
        default: return
        }

        unmarkText()

        if var accumulator = keyTextAccumulator {
            accumulator.append(chars)
            keyTextAccumulator = accumulator
            return
        }
        if !chars.isEmpty { sendCommittedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    override func doCommand(by selector: Selector) {
        // A command-modified key that AppKit turned into a selector: send it
        // back through so keyDown can encode it.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}

// MARK: Drops

/// Files dropped on the terminal type their paths, escaped for the shell,
/// the way Terminal and Ghostty do. Claude Code takes a dropped image path
/// as an attachment, so a screenshot dragged onto a Claude tab reaches
/// Claude. A picture with no file behind it (dragged from a web page) is
/// saved to a temporary file first, and text types as itself.
extension TerminalSurfaceView {
    static let droppedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .string, .png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier),
    ]

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        Self.dropText(from: info.draggingPasteboard, load: false) == nil ? [] : .copy
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { draggingEntered(info) }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard surface != nil, let text = Self.dropText(from: info.draggingPasteboard, load: true) else { return false }
        window?.makeFirstResponder(self)
        // A space after a path, so the next thing typed or dropped doesn't
        // run into it.
        sendText(text.hasSuffix(" ") ? text : text + " ")
        return true
    }

    /// What a drop would type. With `load` false it only checks there's
    /// something, without saving a picture to disk.
    private static func dropText(from pasteboard: NSPasteboard, load: Bool) -> String? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if let text = TerminalDrop.text(forPaths: files.map(\.path)) { return text }
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            return url.absoluteString
        }
        let bitmaps: [NSPasteboard.PasteboardType] = [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]
        if pasteboard.availableType(from: bitmaps) != nil {
            guard load else { return "" }
            return savedPicture(from: pasteboard).flatMap { TerminalDrop.text(forPaths: [$0.path]) }
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty { return string }
        return nil
    }

    /// Writes a dropped picture to a PNG in the temporary folder.
    private static func savedPicture(from pasteboard: NSPasteboard) -> URL? {
        let png: Data? = pasteboard.data(forType: .png) ?? {
            guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }()
        guard let png else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Dropped image \(UUID().uuidString.prefix(8)).png")
        do { try png.write(to: file) } catch { return nil }
        return file
    }
}
