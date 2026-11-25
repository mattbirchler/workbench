import CryptoKit
import Foundation

/// Encrypts a notification's words on the Mac so only the paired phone can
/// read them. Pushes go through Workbench's relay and Apple on the way, and
/// neither needs more than "something happened".
///
/// Both ends already share the pairing token, so each derives the same key
/// from it. A new pairing code makes a new key. The phone's notification
/// extension finds the key by `keyID`, a hash of the Mac's host, so the
/// host itself never travels in the clear.
public enum NotificationSeal {
    /// The payload key holding the sealed contents.
    public static let payloadKey = "sealed"
    /// The payload key holding which Mac's key opens it.
    public static let keyIDKey = "kid"

    /// What the phone shows if it can't open a notification.
    public static let placeholderTitle = "Workbench"
    public static let placeholderBody = "Open Workbench to see what happened."

    /// The words and links of one notification.
    public struct Contents: Codable, Sendable, Equatable {
        public var title: String
        public var body: String
        public var project: String?
        public var session: String?
        public var url: String?
        public var host: String?
        /// Which buttons the notification gets (see `NotificationActions`).
        /// Nil from a Mac that doesn't say, and for kinds with none.
        public var category: String?

        public init(title: String, body: String, project: String? = nil, session: String? = nil, url: String? = nil, host: String? = nil,
                    category: String? = nil) {
            self.title = title
            self.body = body
            self.project = project
            self.session = session
            self.url = url
            self.host = host
            self.category = category
        }
    }

    public static func key(token: String, host: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
                               salt: Data("workbench-notifications-v1".utf8),
                               info: Data(host.lowercased().utf8),
                               outputByteCount: 32)
    }

    /// A short, stable name for a Mac's key that doesn't reveal its host.
    public static func keyID(host: String) -> String {
        SHA256.hash(data: Data("workbench-kid:\(host.lowercased())".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A collapse id or thread id that groups the same way without saying
    /// what it's about.
    public static func opaque(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Longest body sealed, so a long recap stays inside Apple's 4 KB limit.
    public static let bodyLimit = 1500

    public static func seal(_ contents: Contents, with key: SymmetricKey) throws -> String {
        var trimmed = contents
        if trimmed.body.count > bodyLimit { trimmed.body = String(trimmed.body.prefix(bodyLimit - 1)) + "…" }
        let data = try JSONEncoder().encode(trimmed)
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.coderInvalidValue) }
        return combined.base64EncodedString()
    }

    public static func open(_ sealed: String, with key: SymmetricKey) -> Contents? {
        guard let data = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: plain)
    }
}
