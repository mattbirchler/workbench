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

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
    usage: workbench-host <command>

      serve [--port N] [--bind ADDRESS]   Run the host. Devices connect to it here.
      pair [--relay] [--host NAME]        Print the link that pairs a Mac or iPhone.
      add <folder>                        Add a folder as a project.
      projects                            List the projects.
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
    for note in notes { print(note) }
    print("""

        Pairing link:

          \(info.url?.absoluteString ?? "")

        On a Mac: Workbench, the + beside This Mac in the sidebar, then paste the link.
        On an iPhone: open the link there (send it to yourself), or paste it into the pairing screen.
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

default:
    fail(usage, code: 64)
}
