import XCTest
@testable import HostKit

final class HostStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("alpha"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL { folder.appendingPathComponent("state.json") }

    func testAddingAFolderTwiceKeepsOneProject() {
        let store = HostStore(file: file)
        guard case .added(let project) = store.addProject(path: folder.appendingPathComponent("alpha").path) else {
            return XCTFail("the folder should be added")
        }
        XCTAssertEqual(project.name, "alpha")
        guard case .alreadyHere = store.addProject(path: folder.appendingPathComponent("alpha").path) else {
            return XCTFail("the second add should find the first")
        }
        XCTAssertEqual(store.addProject(path: folder.appendingPathComponent("missing").path), .notAFolder)
        XCTAssertEqual(store.projects.count, 1)
    }

    func testProjectsSurviveARestartAndRenames() {
        let first = HostStore(file: file)
        guard case .added(let project) = first.addProject(path: folder.appendingPathComponent("alpha").path) else { return XCTFail() }
        first.rename(project.id, to: "  Website ")
        let second = HostStore(file: file)
        XCTAssertEqual(second.projects.map(\.name), ["Website"])
        second.removeProject(project.id)
        XCTAssertTrue(HostStore(file: file).projects.isEmpty)
    }

    /// `workbench-host add` writes the file while the host is running.
    func testARunningStoreSeesProjectsAddedFromOutside() throws {
        let running = HostStore(file: file)
        XCTAssertFalse(running.reloadIfChanged())
        let other = HostStore(file: file)
        _ = other.addProject(path: folder.appendingPathComponent("alpha").path)
        // Some filesystems keep dates to the second.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertTrue(running.reloadIfChanged())
        XCTAssertEqual(running.projects.map(\.name), ["alpha"])
    }

    func testPairingKeepsItsTokenAndGainsARelayRoomOnce() {
        let file = folder.appendingPathComponent("pairing.json")
        var pairing = HostPairing.load(file)
        XCTAssertNil(pairing.relayEndpoint)
        pairing.useRelay(address: "wss://relay.example.com")
        pairing.save(file)
        var again = HostPairing.load(file)
        XCTAssertEqual(again.token, pairing.token)
        XCTAssertEqual(again.relayEndpoint?.room, pairing.relayEndpoint?.room)
        again.useRelay(address: "wss://relay.example.com")
        XCTAssertEqual(again.relayKey, pairing.relayKey)
    }

    func testTheServiceRunsTheInstalledProgramOnItsPort() {
        let unit = Service.unit(program: "/home/me/.local/bin/workbench-host", port: 4000)
        XCTAssertTrue(unit.contains("ExecStart=\"/home/me/.local/bin/workbench-host\" serve --port 4000"))
        XCTAssertTrue(unit.contains("Restart=always"))
    }
}
