import Foundation
import Testing
@testable import BenchKit

struct FolderListingTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test func tildeIsTheHomeFolder() {
        #expect(FolderListing.expand(nil, home: "/Users/me") == "/Users/me")
        #expect(FolderListing.expand(" ~ ", home: "/Users/me") == "/Users/me")
        #expect(FolderListing.expand("~/Code/app", home: "/Users/me") == "/Users/me/Code/app")
        #expect(FolderListing.expand("/tmp/../var", home: "/Users/me") == "/var")
    }

    @Test func listsFoldersOnlyInFinderOrder() throws {
        let root = try folder()
        for name in ["app10", "app2", ".git", "Notes.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("README.md"))

        let listing = FolderListing.read(root.path, home: "/")
        #expect(listing.problem == nil)
        #expect(listing.path == root.path)
        #expect(listing.parent == root.deletingLastPathComponent().path)
        #expect(listing.folders == ["app2", "app10"])
    }

    @Test func aMissingFolderSaysSo() throws {
        let listing = FolderListing.read("/no/such/folder-\(UUID().uuidString)", home: "/")
        #expect(listing.folders.isEmpty)
        #expect(listing.problem != nil)
    }

    @Test func theTopHasNothingAboveIt() {
        #expect(FolderListing.read("/", home: "/").parent == nil)
    }
}
