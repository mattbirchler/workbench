import BenchKit
import CHostTerminal
import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif

/// A program running in a terminal nobody is looking at.
///
/// The Mac runs each agent in an on-screen terminal, types into it and
/// reads its screen. A host has no screen, so this stands in for one: the
/// program runs on a pseudo-terminal, and everything it draws goes into
/// Ghostty's terminal engine in memory. `screen` is then what a window
/// would be showing, and `press` sends what the key would.
///
/// Everything here runs on the main queue.
public final class HeadlessTerminal {
    public let pid: pid_t
    public private(set) var isRunning = true
    /// The program's exit status, once it has ended.
    public private(set) var exitStatus: Int32?
    /// Called once, when the program ends.
    public var onExit: ((Int32) -> Void)?
    /// When the program last drew anything.
    public private(set) var lastOutput = Date()

    private let master: Int32
    private var terminal: OpaquePointer?
    private var readSource: DispatchSourceRead?
    private var waitTimer: DispatchSourceTimer?
    private var pending = Data()
    private var writeSource: DispatchSourceWrite?
    public private(set) var cols: UInt16
    public private(set) var rows: UInt16

    /// Runs a shell command line the way a new terminal tab would: in your
    /// login shell, so your PATH and profile apply.
    public init?(command: String, folder: String, environment: [String: String], cols: UInt16 = 120, rows: UInt16 = 40) {
        self.cols = cols
        self.rows = rows
        let shell = Self.userShell
        var env = ProcessInfo.processInfo.environment
        // A terminal every machine knows. Ghostty's own name needs its
        // terminfo entry installed.
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        for name in ["NO_COLOR", "CI", "INSIDE_EMACS", "TMUX", "STY"] { env[name] = nil }
        // Where Claude Code's installer puts it, in case the profile doesn't.
        let home = env["HOME"] ?? NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:" + (env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        for (key, value) in environment { env[key] = value }

        // Login and interactive, so both kinds of profile are read.
        let argv = [shell, "-l", "-i", "-c", command]
        let cArgv = Self.cStrings(argv)
        let cEnv = Self.cStrings(env.map { "\($0.key)=\($0.value)" })
        defer {
            Self.free(cArgv, count: argv.count)
            Self.free(cEnv, count: env.count)
        }
        var fd: Int32 = -1
        let pid = wb_spawn(shell, cArgv, cEnv, folder, cols, rows, &fd)
        guard pid > 0, fd >= 0 else { return nil }
        self.pid = pid
        master = fd

        terminal = wb_terminal_new(cols, rows, { userdata, data, count in
            // The terminal answering the program: straight back down the pty.
            guard let userdata, let data, count > 0 else { return }
            Unmanaged<HeadlessTerminal>.fromOpaque(userdata).takeUnretainedValue().write(Data(bytes: data, count: count))
        }, Unmanaged.passUnretained(self).toOpaque())

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        readSource = source

        // Linux has no process sources, so the exit is polled for.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.checkExit() }
        timer.resume()
        waitTimer = timer
    }

    deinit {
        readSource?.cancel()
        waitTimer?.cancel()
        writeSource?.cancel()
        if isRunning { kill(-pid, SIGHUP) }
        close(master)
        if let terminal { wb_terminal_free(terminal) }
    }

    // MARK: Reading

    private func drain() {
        guard let terminal else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { return }
            lastOutput = Date()
            wb_terminal_feed(terminal, buffer, count)
        }
    }

    private func checkExit() {
        var status: Int32 = 0
        guard isRunning, waitpid(pid, &status, WNOHANG) == pid else { return }
        drain()
        isRunning = false
        waitTimer?.cancel()
        readSource?.cancel()
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        exitStatus = code
        onExit?(code)
    }

    /// Everything the terminal holds, scrollback first.
    public var text: String? {
        guard let terminal else { return nil }
        var count = 0
        guard let bytes = wb_terminal_text(terminal, &count) else { return nil }
        defer { Foundation.free(bytes) }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    /// What a window this size would be showing: the last screenful.
    public var screen: String? {
        guard let text else { return nil }
        let lines = text.components(separatedBy: "\n")
        return lines.suffix(Int(rows)).joined(separator: "\n")
    }

    /// The window title the program set, if any.
    public var title: String? {
        guard let terminal else { return nil }
        var count = 0
        guard let bytes = wb_terminal_title(terminal, &count) else { return nil }
        defer { Foundation.free(bytes) }
        let title = String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
        return title.isEmpty ? nil : title
    }

    // MARK: Typing

    /// Types text the way a paste does: marked as pasted when the program
    /// asked for that, so line breaks in it don't send the message early.
    public func sendText(_ text: String) {
        guard let terminal, !text.isEmpty else { return }
        // Nothing in a paste may end it early or act as a key.
        let safe = String(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7f) })
        if wb_terminal_brackets_paste(terminal) {
            write(Data("\u{1b}[200~\(safe)\u{1b}[201~".utf8))
        } else {
            write(Data(safe.replacingOccurrences(of: "\n", with: "\r").utf8))
        }
    }

    public func press(_ key: AgentKey) {
        guard let terminal else { return }
        var mods: Int32 = 0
        var digit: Int32 = 0
        let code: wb_key
        switch key {
        case .returnKey: code = WB_KEY_RETURN
        case .controlReturn: code = WB_KEY_RETURN; mods = WB_MOD_CONTROL
        case .escape: code = WB_KEY_ESCAPE
        case .rightArrow: code = WB_KEY_RIGHT
        case .downArrow: code = WB_KEY_DOWN
        case .upArrow: code = WB_KEY_UP
        case .backspace: code = WB_KEY_BACKSPACE
        case .backTab: code = WB_KEY_TAB; mods = WB_MOD_SHIFT
        case .notes: code = WB_KEY_N
        case .digit(let number): code = WB_KEY_DIGIT; digit = Int32(max(1, min(9, number)))
        }
        var out = [CChar](repeating: 0, count: 64)
        let count = wb_terminal_key(terminal, code, digit, mods, &out, out.count)
        guard count > 0 else { return }
        write(Data(out.prefix(count).map { UInt8(bitPattern: $0) }))
    }

    public func resize(cols: UInt16, rows: UInt16) {
        guard let terminal, cols != self.cols || rows != self.rows, cols > 0, rows > 0 else { return }
        self.cols = cols
        self.rows = rows
        wb_terminal_resize(terminal, cols, rows)
        wb_pty_resize(master, cols, rows)
    }

    /// Ends the program the way closing a terminal window does.
    public func hangUp() {
        guard isRunning else { return }
        kill(-pid, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isRunning else { return }
            kill(-self.pid, SIGKILL)
        }
    }

    // MARK: Writing

    private func write(_ data: Data) {
        guard isRunning else { return }
        pending.append(data)
        flush()
    }

    private func flush() {
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { Foundation.write(master, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: .main)
                    source.setEventHandler { [weak self] in
                        self?.writeSource?.cancel()
                        self?.writeSource = nil
                        self?.flush()
                    }
                    source.resume()
                    writeSource = source
                }
                return
            } else {
                pending.removeAll()
                return
            }
        }
    }

    // MARK: Helpers

    static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/sh"
    }

    private static func cStrings(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
        pointer[strings.count] = nil
        return pointer
    }

    private static func free(_ pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
        for index in 0..<count { Foundation.free(pointer[index]) }
        pointer.deallocate()
    }
}
