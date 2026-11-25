import Foundation
import Testing
@testable import Bench

/// Saving a file for another Mac writes inside the project and nowhere else.
struct RemoteFileSaveTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func replacesTheFileAndKeepsItsPermissions() throws {
        let root = try folder()
        let file = root.appendingPathComponent("run.sh")
        try Data("old\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        #expect(CompanionServer.write("new\n", toPath: "run.sh", in: root) == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test func writesThroughALinkInsideTheProject() throws {
        let root = try folder()
        let real = root.appendingPathComponent("real.txt")
        try Data("old\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: real)

        #expect(CompanionServer.write("new\n", toPath: "link.txt", in: root) == nil)
        #expect(try String(contentsOf: real, encoding: .utf8) == "new\n")
    }

    @Test func refusesALinkToAFileOutsideTheProject() throws {
        let root = try folder(), elsewhere = try folder()
        let outside = elsewhere.appendingPathComponent("secret.txt")
        try Data("mine\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)

        #expect(CompanionServer.write("theirs\n", toPath: "link.txt", in: root) != nil)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "mine\n")
    }
}
