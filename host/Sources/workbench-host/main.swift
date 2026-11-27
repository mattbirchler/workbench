import BenchKit
import Dispatch
import Foundation
import HostKit

// workbench-host: Workbench with no window, for a Linux box.
//
//   workbench-host serve [--port N] [--bind ADDRESS]
//   workbench-host pair [--relay] [--host NAME]
//   workbench-host add <folder>
//   workbench-host projects
//   workbench-host service install | remove
//   workbench-host status

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
    usage: workbench-host <command>

      serve [--port N] [--bind ADDRESS]   Run the host. Devices connect to it here.
      pair [--relay] [--host NAME]        Show the code and link that pair a Mac or iPhone.
      add <folder>                        Add a folder as a project.
      projects                            List the projects.
      service install [--port N]          Keep the host running in the background (systemd).
      service remove                      Stop doing that.
      status                              Whether it's running, and what it needs.
      version

    """

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { fail(usage, code: 64) }
let command = arguments.removeFirst()
var options: [String: String] = [:]
var plain: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument.hasPrefix("--"), let next = arguments.first, !next.hasPrefix("--"), argument != "--relay" {
        options[String(argument.dropFirst(2))] = arguments.removeFirst()
    } else {
        plain.append(argument)
    }
}

switch command {
case "version", "--version":
    print(WorkbenchHost.version)

case "serve":
    let port = options["port"].flatMap(Int.init) ?? WorkbenchHost.defaultPort
    let bind = options["bind"] ?? "127.0.0.1"
    let host: WorkbenchHost
    do {
        host = try WorkbenchHost()
        try host.run(bind: bind, port: port)
    } catch {
        fail("workbench-host: couldn't start: \(error)")
    }
    // Asked to stop: end the sessions so each can be resumed next time.
    signal(SIGPIPE, SIG_IGN)
    var sources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            host.stop()
            // A moment for Claude Code to save and go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        }
        source.resume()
        sources.append(source)
    }
    // kill -USR1: log what each session's terminal shows.
    signal(SIGUSR1, SIG_IGN)
    let screens = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    screens.setEventHandler { host.sessions.logScreens() }
    screens.resume()
    sources.append(screens)
    dispatchMain()

case "pair":
    let paths = HostPaths.standard
    do { try paths.prepare() } catch { fail("workbench-host: \(error.localizedDescription)") }
    var pairing = HostPairing.load(paths.pairing)
    let port = options["port"].flatMap(Int.init) ?? WorkbenchHost.defaultPort
    let wantsRelay = plain.contains("--relay") || options["relay-address"] != nil
    if wantsRelay {
        pairing.useRelay(address: options["relay-address"] ?? RelayLink.defaultAddress)
        pairing.save(paths.pairing)
    }
    // A name given by hand wins: a reverse proxy of your own, say.
    var name = options["host"]
    var notes: [String] = []
    if name == nil, let tailnet = Reach.tailnetName() {
        switch Reach.serve(port: port, name: tailnet) {
        case .ready:
            name = tailnet
            notes.append("Reachable on your Tailscale network as \(tailnet).")
        case .failed(let said):
            notes.append("Tailscale is here, but Serve couldn't be set up: \(said)")
            notes.append("To fix that, run:  sudo tailscale serve --bg --https=443 --set-path=/ws http://127.0.0.1:\(port)")
        }
    }
    if pairing.relayEndpoint != nil { notes.append("Reachable through the Workbench relay.") }
    guard name != nil || pairing.relayEndpoint != nil else {
        fail("""
            This machine isn't on a Tailscale network, so devices have no way to reach it yet. Either:

              Install Tailscale here (https://tailscale.com/download/linux), sign in, and run this again.
              Or run:  workbench-host pair --relay
                 to go through the Workbench relay. Nothing to install, and what passes
                 through is sealed with the pairing code, so the relay can't read it.
            """)
    }
    let id = pairing.id ?? UUID().uuidString.lowercased()
    let info = PairingInfo(host: name ?? PairingInfo.localOnlyHost(mac: id), token: pairing.token, relay: pairing.relayEndpoint)
    pairing.id = id
    pairing.hostName = info.host
    pairing.save(paths.pairing)
    for note in notes { print(note) }
    let link = info.url?.absoluteString ?? ""
    if !plain.contains("--no-qr"), let code = QRCode(link) {
        print("\nScan this with the Workbench app on your iPhone:\n")
        for line in code.terminalLines() { print("  " + line) }
    }
    print("""

        Pairing link:

          \(link)

        On a Mac: Workbench, the + beside This Mac in the sidebar, then paste the link.
        On an iPhone: scan the code above, or choose Enter Details and paste the link.
        Anyone with this link can run commands here as you. Treat it like a password.
        """)

case "add":
    guard let folder = plain.first else { fail(usage, code: 64) }
    let paths = HostPaths.standard
    do { try paths.prepare() } catch { fail("workbench-host: \(error.localizedDescription)") }
    let store = HostStore(file: paths.store)
    let full = URL(fileURLWithPath: FolderListing.expand(folder, home: NSHomeDirectory()),
                   relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL.path
    switch store.addProject(path: full) {
    case .added(let project): print("Added \(project.name) (\(project.path))")
    case .alreadyHere(let project): print("\(project.name) is already a project (\(project.path))")
    case .notAFolder: fail("There's no folder at \(full).")
    }

case "projects":
    let store = HostStore(file: HostPaths.standard.store)
    if store.projects.isEmpty { print("No projects yet. Add one with: workbench-host add <folder>") }
    for project in store.projects { print("\(project.name)\t\(project.path)") }

case "service":
    switch plain.first {
    case "install":
        do {
            for line in try Service.install(port: options["port"].flatMap(Int.init) ?? WorkbenchHost.defaultPort) { print(line) }
        } catch {
            fail("workbench-host: couldn't set up the service: \(error.localizedDescription)")
        }
    case "remove", "uninstall":
        for line in Service.uninstall() { print(line) }
    default:
        fail(usage, code: 64)
    }

case "status":
    print("Workbench host \(WorkbenchHost.version)")
    switch Service.state {
    case "active"?: print("Service:   running in the background")
    case let state?: print("Service:   \(state). Look at:  journalctl --user -u workbench-host")
    case nil: print("Service:   not set up. Run:  workbench-host service install")
    }
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
    let claude = Reach.run(shell, ["-l", "-c", "PATH=\"$HOME/.local/bin:$PATH\"; command -v claude"], timeout: 10)
    if let claude, claude.status == 0 {
        print("Claude:    \(claude.output.split(separator: "\n").last.map(String.init) ?? "installed")")
    } else {
        print("Claude:    not found. Install Claude Code, then run claude once here to sign in.")
    }
    let pairing = HostPairing.load(HostPaths.standard.pairing)
    if let tailnet = Reach.tailnetName() { print("Tailscale: \(tailnet)") } else { print("Tailscale: not on a tailnet") }
    print("Relay:     \(pairing.relayEndpoint == nil ? "off (turn on with: workbench-host pair --relay)" : "on")")
    let count = HostStore(file: HostPaths.standard.store).projects.count
    print("Projects:  \(count)")

default:
    fail(usage, code: 64)
}
