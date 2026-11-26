import Foundation
import Testing
@testable import BenchKit

@Suite struct PairingInfoTests {
    @Test func roundTripsWithLocalPart() throws {
        let info = PairingInfo(host: "a.ts.net", token: "t", local: .init(mac: "m1", fingerprint: "ab"))
        #expect(PairingInfo(url: try #require(info.url)) == info)
    }

    @Test func oldCodesStillParse() throws {
        let url = try #require(URL(string: "bench://pair?host=a.ts.net&token=t"))
        let info = try #require(PairingInfo(url: url))
        #expect(info.local == nil)
    }

    @Test func ignoresHalfALocalPart() throws {
        let url = try #require(URL(string: "bench://pair?host=a.ts.net&token=t&mac=m1"))
        let info = try #require(PairingInfo(url: url))
        #expect(info.local == nil)
    }

    @Test func decodesSavedPairingsFromBeforeLocal() throws {
        let json = Data(#"{"host":"a","token":"t"}"#.utf8)
        let info = try JSONDecoder().decode(PairingInfo.self, from: json)
        #expect(info.local == nil)
    }

    @Test func localOnlyHasNoTailscaleURL() {
        let info = PairingInfo(host: PairingInfo.localOnlyHost(mac: "m1"), token: "t")
        #expect(info.socketURL == nil)
        #expect(info.isLocalOnly)
    }

    @Test func roundTripsWithRelayPart() throws {
        let room = RelayRoom.make().id
        let info = PairingInfo(host: PairingInfo.localOnlyHost(mac: "abc"), token: "t",
                               local: .init(mac: "abc", fingerprint: "ff"), relay: RelayEndpoint(url: "wss://relay.example", room: room))
        let url = try #require(info.url)
        let parsed = try #require(PairingInfo(url: url))
        #expect(parsed == info)
        #expect(parsed.relay?.relayURL == URL(string: "wss://relay.example"))
    }

    @Test func ignoresARelayPartThatMakesNoSense() throws {
        let room = RelayRoom.make().id
        // Half of it, a web address, and a room that isn't one.
        for query in ["relay=wss://relay.example", "relay=https://relay.example&room=\(room)", "relay=wss://relay.example&room=nope"] {
            let url = try #require(URL(string: "bench://pair?host=mac.ts.net&token=t&\(query)"))
            let parsed = try #require(PairingInfo(url: url))
            #expect(parsed.relay == nil)
        }
    }

    @Test func decodesSavedPairingsFromBeforeTheRelay() throws {
        let saved = Data(#"{"host":"mac.ts.net","token":"t"}"#.utf8)
        #expect(try JSONDecoder().decode(PairingInfo.self, from: saved).relay == nil)
    }
}
