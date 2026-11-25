import CryptoKit
import Foundation
import Testing
@testable import BenchKit

struct NotificationSealTests {
    let host = "matts-mac-mini.tail1234.ts.net"

    @Test func opensWhatItSeals() throws {
        let contents = NotificationSeal.Contents(title: "Bench: finished", body: "Added the standard row.",
                                                 project: UUID().uuidString, session: UUID().uuidString, host: host)
        let sealed = try NotificationSeal.seal(contents, with: NotificationSeal.key(token: "secret", host: host))
        #expect(!sealed.contains("standard"))
        #expect(NotificationSeal.open(sealed, with: NotificationSeal.key(token: "secret", host: host)) == contents)
    }

    @Test func carriesWhichButtonsToShow() throws {
        let key = NotificationSeal.key(token: "secret", host: host)
        let contents = NotificationSeal.Contents(title: "Claude needs you", body: "Run npm test?", category: NotificationActions.permissionCategory)
        let sealed = try NotificationSeal.seal(contents, with: key)
        #expect(!sealed.contains("permission"))
        #expect(NotificationSeal.open(sealed, with: key)?.category == NotificationActions.permissionCategory)
        // What an older Mac seals has no category, and still opens.
        let older = try AES.GCM.seal(Data(#"{"title":"a","body":"b"}"#.utf8), using: key).combined!.base64EncodedString()
        #expect(NotificationSeal.open(older, with: key) == .init(title: "a", body: "b"))
    }

    @Test func wrongTokenCantOpen() throws {
        let sealed = try NotificationSeal.seal(.init(title: "a", body: "b"), with: NotificationSeal.key(token: "one", host: host))
        #expect(NotificationSeal.open(sealed, with: NotificationSeal.key(token: "two", host: host)) == nil)
        #expect(NotificationSeal.open("not base64!", with: NotificationSeal.key(token: "one", host: host)) == nil)
    }

    @Test func keyIDIsStableAndHidesTheHost() {
        #expect(NotificationSeal.keyID(host: host) == NotificationSeal.keyID(host: host.uppercased()))
        #expect(NotificationSeal.keyID(host: host).count == 16)
        #expect(!NotificationSeal.keyID(host: host).contains("matts"))
    }

    @Test func longBodiesFitApplesLimit() throws {
        let body = String(repeating: "word ", count: 2000)
        let sealed = try NotificationSeal.seal(.init(title: "t", body: body, project: UUID().uuidString, session: UUID().uuidString,
                                                     url: "https://github.com/a/b/pull/1", host: host),
                                               with: NotificationSeal.key(token: "s", host: host))
        #expect(sealed.utf8.count < 3000)
    }
}

struct RegisterPushCompatibilityTests {
    @Test func olderPhonesLeaveSealedOut() throws {
        let encoded = try JSONEncoder().encode(ClientMessage.registerPush(token: "abc"))
        guard case .registerPush(let token, let sealed) = try JSONDecoder().decode(ClientMessage.self, from: encoded) else {
            Issue.record("Wrong case"); return
        }
        #expect(token == "abc")
        #expect(sealed == nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("sealed"))
    }
}
