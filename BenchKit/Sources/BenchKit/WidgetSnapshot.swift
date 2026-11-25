import Foundation
import Security

/// What the widgets show: the Mac's sessions as the app last saw them. The
/// app saves it and the widget extension reads it.
public struct WidgetSnapshot: Codable, Sendable, Hashable {
    public var macName: String
    public var state: DashboardAttributes.ContentState
    public var savedAt: Date
    /// The app's theme for the phone in light and in dark, or nil for
    /// plain widgets.
    public var light: DashboardColors?
    public var dark: DashboardColors?

    public init(macName: String, state: DashboardAttributes.ContentState, savedAt: Date = .now,
                light: DashboardColors? = nil, dark: DashboardColors? = nil) {
        self.macName = macName
        self.state = state
        self.savedAt = savedAt
        self.light = light
        self.dark = dark
    }

    /// Widgets only hear from the Mac while the app is open, so past this
    /// they say when they were last right instead of looking current.
    public static let staleAfter: TimeInterval = 20 * 60

    public func isStale(at date: Date) -> Bool { date.timeIntervalSince(savedAt) > Self.staleAfter }

    /// True when the widgets would look different for `other`: the same
    /// sessions doing the same things, whenever each was saved.
    public func shows(sameAs other: WidgetSnapshot) -> Bool {
        var copy = other
        copy.savedAt = savedAt
        return copy == self
    }

    // MARK: Saving

    // In the keychain group the app already shares with its notification
    // extension, rather than an app group: it holds a few hundred bytes,
    // and needs nothing new set up for signing.
    private static let account = "widget-snapshot"

    private static var match: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: NotificationKeys.accessGroup,
        ]
    }

    /// Replaces what the widgets show. Nil clears it, as when you unpair.
    public static func save(_ snapshot: WidgetSnapshot?) {
        SecItemDelete(match as CFDictionary)
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        var add = match
        add[kSecValueData as String] = data
        // Widgets draw while the phone is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func load() -> WidgetSnapshot? {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
