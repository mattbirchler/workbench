#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation

/// A prompt written on the phone while the Mac was asleep, waiting on the
/// relay for the Mac to pick up.
public struct QueuedPrompt: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var projectName: String
    public var prompt: String
    public var queuedAt: Date
    /// The phone's name, so the Mac can say where it came from.
    public var device: String

    public init(id: UUID = UUID(), projectID: UUID, projectName: String, prompt: String, queuedAt: Date = Date(), device: String) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.prompt = prompt
        self.queuedAt = queuedAt
        self.device = device
    }
}

/// Encrypts queued prompts on the phone so only the paired Mac can read
/// them. The relay holds them in the meantime and sees only sealed bytes.
///
/// Both ends derive everything from the pairing token. The mailbox id names
/// the mailbox without revealing the token, and the key is a separate
/// derivation, so knowing the id gets you nowhere. The id is also bound in
/// as associated data, so a sealed prompt can't be moved to another mailbox.
public enum QueueSeal {
    private static func derive(token: String, salt: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
                               salt: Data(salt.utf8), info: Data(), outputByteCount: 32)
    }

    /// The mailbox's name on the relay: 64 lowercase hex characters.
    public static func mailboxID(token: String) -> String {
        derive(token: token, salt: "workbench-queue-id-v1").withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    public static func key(token: String) -> SymmetricKey {
        derive(token: token, salt: "workbench-queue-key-v1")
    }

    public static func seal(_ prompt: QueuedPrompt, key: SymmetricKey, mailbox: String) throws -> String {
        let data = try CompanionCoding.encoder.encode(prompt)
        let box = try AES.GCM.seal(data, using: key, authenticating: Data(mailbox.utf8))
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        return combined.base64EncodedString()
    }

    public static func open(_ sealed: String, key: SymmetricKey, mailbox: String) -> QueuedPrompt? {
        guard let data = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data(mailbox.utf8)) else { return nil }
        return try? CompanionCoding.decoder.decode(QueuedPrompt.self, from: plain)
    }
}
