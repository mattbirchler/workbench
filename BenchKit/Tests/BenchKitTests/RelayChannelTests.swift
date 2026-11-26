import CryptoKit
import Foundation
import Testing
@testable import BenchKit

@Suite struct RelayChannelTests {
    let token = PairingInfo.makeToken()
    let room = RelayRoom.make().id

    /// Both ends of a finished handshake.
    func pair() throws -> (guest: RelayChannel, host: RelayChannel) {
        let hello = RelayHandshake.Guest()
        let host = try RelayHandshake.Host(hello: hello.frame, token: token, room: room)
        let (guest, confirm) = try hello.finish(reply: host.frame, token: token, room: room)
        return (guest, try host.finish(confirm: confirm))
    }

    @Test func roomIDIsTheKeysHash() {
        let room = RelayRoom(key: String(repeating: "00", count: 32))
        #expect(room.id == "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925")
        #expect(RelayRoom.make().key.count == 64)
        #expect(RelayRoom.make().key != RelayRoom.make().key)
    }

    @Test func requestsNameTheRoomAndOnlyTheHostCarriesTheKey() {
        let room = RelayRoom.make()
        let relay = URL(string: "wss://relay.example")!
        let host = room.hostRequest(relay: relay)
        #expect(host.url?.absoluteString == "wss://relay.example/v1/rooms/\(room.id)/host")
        #expect(host.value(forHTTPHeaderField: "Authorization") == "Bearer \(room.key)")
        let guest = RelayRoom.guestRequest(relay: relay, room: room.id)
        #expect(guest.url?.absoluteString == "wss://relay.example/v1/rooms/\(room.id)/guest")
        #expect(guest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func messagesPassBothWays() throws {
        var (guest, host) = try pair()
        let up = try guest.seal(Data("hello mac".utf8))
        #expect(up.count == 1)
        #expect(try host.open(up[0]) == Data("hello mac".utf8))
        let down = try host.seal(Data("hello phone".utf8))
        #expect(try guest.open(down[0]) == Data("hello phone".utf8))
        // An empty message is still a message.
        #expect(try host.open(try guest.seal(Data())[0]) == Data())
    }

    @Test func sealedFramesDontShowTheMessage() throws {
        var (guest, _) = try pair()
        let secret = Data("the project is called Moonshot".utf8)
        let frame = try guest.seal(secret)[0]
        #expect(frame.range(of: secret) == nil)
        #expect(frame.range(of: Data("Moonshot".utf8)) == nil)
    }

    @Test func aBigMessageIsSplitAndPutBackTogether() throws {
        var (guest, host) = try pair()
        let big = Data((0..<(RelayChannel.chunkSize * 2 + 500)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let frames = try guest.seal(big)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.count <= 256 * 1024 })
        #expect(try host.open(frames[0]) == nil)
        #expect(try host.open(frames[1]) == nil)
        #expect(try host.open(frames[2]) == big)
        // The next message starts clean.
        #expect(try host.open(try guest.seal(Data("after".utf8))[0]) == Data("after".utf8))
    }

    @Test func aMessageExactlyOneChunkLongIsOneFrame() throws {
        var (guest, host) = try pair()
        let exact = Data(repeating: 7, count: RelayChannel.chunkSize)
        let frames = try guest.seal(exact)
        #expect(frames.count == 1)
        #expect(try host.open(frames[0]) == exact)
    }

    @Test func aWrongTokenFailsOnBothSides() throws {
        let hello = RelayHandshake.Guest()
        let host = try RelayHandshake.Host(hello: hello.frame, token: "another token", room: room)
        #expect(throws: RelayError.wrongPairing) { try hello.finish(reply: host.frame, token: token, room: room) }

        // A device with the wrong token can't make a confirmation the Mac accepts.
        let stranger = RelayHandshake.Guest()
        let real = try RelayHandshake.Host(hello: stranger.frame, token: token, room: room)
        let pretend = try RelayHandshake.Host(hello: stranger.frame, token: "guess", room: room)
        #expect(throws: RelayError.wrongPairing) { try real.finish(confirm: pretend.frame.suffix(39)) }
    }

    @Test func theSameTokenInAnotherRoomFails() throws {
        let hello = RelayHandshake.Guest()
        let host = try RelayHandshake.Host(hello: hello.frame, token: token, room: RelayRoom.make().id)
        #expect(throws: RelayError.wrongPairing) { try hello.finish(reply: host.frame, token: token, room: room) }
    }

    @Test func aRecordedConnectionCantBeReplayed() throws {
        // Someone on the relay records a whole connection...
        let hello = RelayHandshake.Guest()
        let host = try RelayHandshake.Host(hello: hello.frame, token: token, room: room)
        var (guest, confirm) = try hello.finish(reply: host.frame, token: token, room: room)
        let recorded = try guest.seal(Data("delete everything".utf8))[0]

        // ...and plays the device's frames to the Mac again. The Mac's
        // one-time key is new, so the old confirmation doesn't open.
        let again = try RelayHandshake.Host(hello: hello.frame, token: token, room: room)
        #expect(throws: RelayError.wrongPairing) { try again.finish(confirm: confirm) }

        // Inside one connection, a frame can't be played twice either.
        var mac = try host.finish(confirm: confirm)
        #expect(try mac.open(recorded) == Data("delete everything".utf8))
        #expect(throws: RelayError.wrongPairing) { try mac.open(recorded) }
    }

    @Test func changedDroppedAndReorderedFramesFail() throws {
        var (guest, host) = try pair()
        var changed = try guest.seal(Data("allow".utf8))[0]
        changed[0] ^= 1
        #expect(throws: RelayError.wrongPairing) { try host.open(changed) }

        var (phone, mac) = try pair()
        let first = try phone.seal(Data("one".utf8))[0], second = try phone.seal(Data("two".utf8))[0]
        #expect(throws: RelayError.wrongPairing) { try mac.open(second) }
        #expect(try mac.open(first) == Data("one".utf8))

        #expect(throws: RelayError.wrongPairing) { try mac.open(Data([1, 2, 3])) }
    }

    @Test func malformedHellosAreRefused() {
        #expect(throws: RelayError.wrongPairing) { try RelayHandshake.Host(hello: Data(), token: token, room: room) }
        #expect(throws: RelayError.wrongPairing) { try RelayHandshake.Host(hello: Data(repeating: 9, count: 49), token: token, room: room) }
        #expect(throws: RelayError.wrongPairing) { try RelayHandshake.Guest().finish(reply: Data(repeating: 1, count: 20), token: token, room: room) }
        #expect(throws: RelayError.wrongPairing) { try RelayHandshake.Host(hello: RelayHandshake.Guest().frame, token: "", room: room) }
    }

    @Test func aMessageOverTheLimitIsRefused() throws {
        var (guest, _) = try pair()
        #expect(throws: RelayError.tooLarge) { try guest.seal(Data(count: RelayChannel.maxMessage + 1)) }
    }

    @Test func closeCodesBecomeReasons() {
        #expect(RelayError(closeCode: 4404) == .hostOffline)
        #expect(RelayError(closeCode: 4410) == .hostGone)
        #expect(RelayError(closeCode: 4403) == .roomFull)
        #expect(RelayError(closeCode: 4429) == .overLimit)
        #expect(RelayError(closeCode: 4409) == .replaced)
        #expect(RelayError(closeCode: 1001) == .relayRestarting)
        #expect(RelayError(closeCode: 1006) == .closed(1006))
        #expect(RelayError.hostGone.isWorthRetrying)
        #expect(RelayError.relayRestarting.isWorthRetrying)
        #expect(!RelayError.hostOffline.isWorthRetrying)
        #expect(!RelayError.overLimit.isWorthRetrying)
        #expect(!RelayError.wrongPairing.isWorthRetrying)
    }
}
