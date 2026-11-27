#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation

/// The sealing between a Mac and one device over the relay. Over Tailscale
/// the secure connection ends at the Mac. Through the relay it ends at the
/// relay, so what the two say needs a layer of its own that the relay
/// can't open.
///
/// Both ends hold the pairing token. Each connection starts with a short
/// handshake, three frames:
///
///   device -> Mac   hello: version, a one-time public key, 16 random bytes
///   Mac -> device   the same from the Mac, then a sealed confirmation
///   device -> Mac   a sealed confirmation
///
/// The keys come from the two one-time keys and the pairing token together.
/// Without the token nobody in between can work them out, and because the
/// one-time keys are thrown away, a recording can't be opened later even if
/// the token leaks. A confirmation that doesn't open means the other end
/// has a different pairing code.
///
/// After that every frame is sealed with ChaCha20-Poly1305 under a counter
/// that must arrive in order, so a frame that's replayed, dropped, moved or
/// changed fails to open.
public enum RelayHandshake {
    static let version: UInt8 = 1
    static let helloLength = 1 + 32 + 16
    static let confirmation = Data("workbench-relay-confirm".utf8)

    /// A device's side, between sending its hello and getting the reply.
    public struct Guest: Sendable {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let hello: Data

        /// The first frame to send.
        public var frame: Data { hello }

        public init() {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            hello = RelayHandshake.hello(publicKey: privateKey.publicKey)
        }

        /// Checks the Mac's reply. Returns the channel and the confirmation
        /// to send back, or throws `wrongPairing`.
        public func finish(reply: Data, token: String, room: String) throws -> (channel: RelayChannel, confirm: Data) {
            guard reply.count > RelayHandshake.helloLength else { throw RelayError.wrongPairing }
            let theirs = Data(reply.prefix(RelayHandshake.helloLength))
            var channel = try RelayHandshake.channel(mine: privateKey, guestHello: hello, hostHello: theirs,
                                                     token: token, room: room, isGuest: true)
            guard try channel.openFrame(Data(reply.dropFirst(RelayHandshake.helloLength))) == RelayHandshake.confirmation else {
                throw RelayError.wrongPairing
            }
            // Sealed first: the channel that's handed back has to have
            // counted it.
            let confirm = try channel.sealFrame(RelayHandshake.confirmation)
            return (channel, confirm)
        }
    }

    /// The Mac's side, between sending its reply and getting the device's
    /// confirmation.
    public struct Host: Sendable {
        var channel: RelayChannel
        /// The frame to send back.
        public let frame: Data

        public init(hello: Data, token: String, room: String) throws {
            guard hello.count == RelayHandshake.helloLength else { throw RelayError.wrongPairing }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let mine = RelayHandshake.hello(publicKey: privateKey.publicKey)
            var channel = try RelayHandshake.channel(mine: privateKey, guestHello: hello, hostHello: mine,
                                                     token: token, room: room, isGuest: false)
            frame = mine + (try channel.sealFrame(RelayHandshake.confirmation))
            self.channel = channel
        }

        /// Checks the device's confirmation, or throws `wrongPairing`.
        public func finish(confirm: Data) throws -> RelayChannel {
            var channel = channel
            guard try channel.openFrame(confirm) == RelayHandshake.confirmation else { throw RelayError.wrongPairing }
            return channel
        }
    }

    static func hello(publicKey: Curve25519.KeyAgreement.PublicKey) -> Data {
        // The system's generator, which is the secure one on every platform.
        var generator = SystemRandomNumberGenerator()
        let random = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data([version]) + publicKey.rawRepresentation + Data(random)
    }

    static func channel(mine: Curve25519.KeyAgreement.PrivateKey, guestHello: Data, hostHello: Data,
                        token: String, room: String, isGuest: Bool) throws -> RelayChannel {
        let theirs = isGuest ? hostHello : guestHello
        guard theirs.first == version, !token.isEmpty,
              let theirKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs.dropFirst().prefix(32)),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: theirKey) else {
            throw RelayError.wrongPairing
        }
        // The token goes in with the shared secret, so the keys can only be
        // made by someone who holds both. Both hellos and the room go in
        // the salt, which ties the keys to this one connection.
        let material = shared.withUnsafeBytes { Data($0) } + Data(token.utf8)
        let salt = Data(SHA256.hash(data: guestHello + hostHello + Data(room.lowercased().utf8)))
        let keys = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt,
                                          info: Data("workbench-relay-v1".utf8), outputByteCount: 64)
            .withUnsafeBytes { Data($0) }
        let toHost = SymmetricKey(data: keys.prefix(32)), toGuest = SymmetricKey(data: keys.suffix(32))
        return RelayChannel(sendKey: isGuest ? toHost : toGuest, receiveKey: isGuest ? toGuest : toHost)
    }
}

/// One end of a sealed connection, once the handshake is done. Messages of
/// any size go in. Frames small enough for the relay come out, and go back
/// in at the other end to become the same messages.
public struct RelayChannel: Sendable {
    /// The most message bytes in one frame. With the seal's 17 bytes of
    /// overhead it stays well under the relay's 256 KB frame limit.
    public static let chunkSize = 128 * 1024
    /// The largest message put back together. Bigger than any file or
    /// transcript page the apps send.
    public static let maxMessage = 64 * 1024 * 1024

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var partial = Data()

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    /// Seals a message as one or more frames, to send in this order.
    public mutating func seal(_ message: Data) throws -> [Data] {
        guard message.count <= Self.maxMessage else { throw RelayError.tooLarge }
        var frames: [Data] = []
        var rest = message[...]
        repeat {
            let chunk = rest.prefix(Self.chunkSize)
            rest = rest.dropFirst(chunk.count)
            frames.append(try sealFrame(Data([rest.isEmpty ? 1 : 0]) + chunk))
        } while !rest.isEmpty
        return frames
    }

    /// Opens the next frame. Returns a message when this frame completes
    /// one, nil when more frames are to come. Throws `wrongPairing` for a
    /// frame that doesn't open, after which the connection is no use.
    public mutating func open(_ frame: Data) throws -> Data? {
        let plain = try openFrame(frame)
        guard let last = plain.first else { throw RelayError.wrongPairing }
        guard partial.count + plain.count - 1 <= Self.maxMessage else { throw RelayError.tooLarge }
        partial.append(plain.dropFirst())
        guard last == 1 else { return nil }
        defer { partial = Data() }
        return Data(partial)
    }

    mutating func sealFrame(_ plain: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(sent))
        sent += 1
        // A fresh buffer that starts at zero. CryptoKit hands back a slice
        // of a longer one, which traps anyone who indexes it from 0.
        var frame = Data(capacity: box.ciphertext.count + box.tag.count)
        frame.append(box.ciphertext)
        frame.append(box.tag)
        return frame
    }

    mutating func openFrame(_ frame: Data) throws -> Data {
        guard frame.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(received), ciphertext: frame.dropLast(16), tag: frame.suffix(16)),
              let plain = try? ChaChaPoly.open(box, using: receiveKey) else {
            throw RelayError.wrongPairing
        }
        received += 1
        return plain
    }

    /// Each key seals each counter once, so the counter can be the nonce.
    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        // 12 bytes is always a valid nonce.
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
