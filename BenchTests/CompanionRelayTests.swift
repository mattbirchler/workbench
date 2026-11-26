import BenchKit
import Foundation
import Testing
@testable import Bench

/// The whole way through: the real client, the real relay (started from
/// relay-live on a spare port) and the real companion server. Skipped where
/// Node or the relay's packages aren't installed.
@MainActor
@Suite(.enabled(if: LocalRelay.isAvailable), .serialized)
struct CompanionRelayTests {
    private func startRelay() async throws -> (process: Process, url: String) {
        let port = Int.random(in: 20000...50000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LocalRelay.node ?? "")
        process.arguments = ["start.js"]
        process.currentDirectoryURL = LocalRelay.folder
        process.environment = ["PORT": "\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<50 {
            if let (_, response) = try? await URLSession.shared.data(from: health), (response as? HTTPURLResponse)?.statusCode == 200 {
                return (process, "ws://127.0.0.1:\(port)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw RelayError.closed(0)
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), "\(what) didn't happen in time")
    }

    private func server(projectID: UUID, folder: URL) throws -> CompanionServer {
        let state = folder.appendingPathComponent("state.json")
        try Data("""
        {"projects":[{"id":"\(projectID.uuidString)","path":"\(folder.path)","tabs":[]}],"pins":[],"groups":[]}
        """.utf8).write(to: state)
        let store = AppStore(fileURL: state)
        let terminals = TerminalManager(store: store)
        let pullRequests = PullRequests()
        let snapshots = CompanionSnapshots(store: store, terminals: terminals, pullRequests: pullRequests, deployments: Deployments(),
                                           monitors: RepoMonitors(), files: FileListMonitors(), icons: ProjectIcons(),
                                           cleaner: WorktreeCleaner(store: store, terminals: terminals, pullRequests: pullRequests),
                                           shortcuts: TabShortcuts(), ports: PortScanner())
        return CompanionServer(snapshots: snapshots, token: { "pairing-code" }, port: 0)
    }

    @Test func aClientReachesTheMacThroughTheRelayAlone() async throws {
        let (process, address) = try await startRelay()
        defer { process.terminate() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relay-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectID = UUID()
        let server = try server(projectID: projectID, folder: folder)

        // The Mac hosts its room, and tells clients about a room that has
        // moved since they paired.
        let room = RelayRoom.make()
        let moved = RelayEndpoint(url: address, room: RelayRoom.make().id)
        server.relayEndpoint = { moved }
        var usage = RelayUsage()
        server.onRelayUsage = { usage = usage + $0 }
        let host = RelayHost(relay: try #require(URL(string: address)), room: room, token: { "pairing-code" })
        let serving = Task { try? await host.run() }
        let arrivals = Task { for await connection in host.connections { server.accept(relay: connection) } }
        defer {
            host.close()
            serving.cancel()
            arrivals.cancel()
        }

        // A Mac with no Tailscale and no home network in reach: only the relay.
        let pairing = PairingInfo(host: PairingInfo.localOnlyHost(mac: "relay-test"), token: "pairing-code",
                                  relay: RelayEndpoint(url: address, room: room.id))
        let client = CompanionClient(deviceName: "Test phone", features: [CompanionFeature.relay])
        var heard: RelayEndpoint?
        client.onRelayChange = { _, relay in heard = relay }
        // The Mac's socket to the relay may still be opening, so the first
        // tries can find nobody home. The client retries on its own.
        client.connect(pairing)
        defer { client.disconnect() }
        try await until("the client connecting") { client.status == .connected }
        #expect(client.path == .relay)
        try await until("the project list arriving") { client.snapshot?.projects.contains { $0.id == projectID } == true }
        try await until("the phone being listed") { server.connectedDevices == ["Test phone"] }
        #expect(server.hasRelayClients)
        try await until("the Mac saying where its room is now") { heard == moved }
        #expect(usage.connections >= 1)
        #expect(usage.messagesIn >= 2)
        #expect(usage.messagesOut >= 2)
        #expect(usage.bytesOut > 0)
    }

    @Test func theWrongPairingCodeAsksForANewOne() async throws {
        let (process, address) = try await startRelay()
        defer { process.terminate() }
        let room = RelayRoom.make()
        let host = RelayHost(relay: try #require(URL(string: address)), room: room, token: { "pairing-code" })
        let serving = Task { try? await host.run() }
        defer {
            host.close()
            serving.cancel()
        }
        let client = CompanionClient(deviceName: "Test phone", features: [CompanionFeature.relay])
        client.connect(PairingInfo(host: PairingInfo.localOnlyHost(mac: "relay-test"), token: "an old code",
                                   relay: RelayEndpoint(url: address, room: room.id)))
        defer { client.disconnect() }
        try await until("the client being turned away") { client.needsRepair }
        #expect(client.problem == PairingInfo.rejectedMessage)
        #expect(client.status == .disconnected)
    }
}

/// Where the relay's code is, and whether it can run here.
enum LocalRelay {
    nonisolated static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("relay-live")
    nonisolated static let node: String? = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    nonisolated static var isAvailable: Bool {
        node != nil && FileManager.default.fileExists(atPath: folder.appendingPathComponent("node_modules/ws").path)
    }
}
