import BenchKit
import Dispatch
import Foundation
import HostKit

// A first probe: run a command in a headless terminal and print its screen.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "probe", arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: workbench-host probe <folder> <command> [text to send]\n".utf8))
    exit(64)
}
guard let terminal = HeadlessTerminal(command: arguments[2], folder: arguments[1], environment: [:]) else {
    FileHandle.standardError.write(Data("couldn't start\n".utf8))
    exit(1)
}
terminal.onExit = { code in
    print("---- exited \(code)\n\(terminal.screen ?? "")")
    exit(0)
}
let driver = ClaudeTerminalDriver()
var tick = 0
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    tick += 1
    let screen = terminal.screen ?? ""
    print("---- t=\(tick) title=\(terminal.title ?? "-") box=\(driver.messageBox(in: screen) ?? "-") mode=\(driver.permissionMode(in: screen)?.rawValue ?? "-") trust=\(driver.startupPrompt(in: screen) != nil)")
    if tick == 3, driver.startupPrompt(in: screen) != nil { terminal.press(.downArrow) }
    if tick == 4, StartupPrompt.cursorIsOn("Yes, I trust this folder", in: screen) { terminal.press(.returnKey) }
    if tick == 8 || tick == 20 { print(screen) }
    if tick == 9, arguments.count > 3 {
        terminal.sendText(arguments[3])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { terminal.press(.returnKey) }
    }
    if tick == 21 { terminal.hangUp() }
}
timer.resume()
dispatchMain()
