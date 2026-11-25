import Foundation

/// The buttons on a notification from the Mac, by name. The Mac says which
/// set a notification gets, and the phone registers what each set holds.
public enum NotificationActions {
    /// The agent wants a yes or no: Allow, Deny and Reply.
    public static let permissionCategory = "permission"
    /// The agent asked something or finished: Reply.
    public static let replyCategory = "reply"

    public static let allow = "allow"
    public static let deny = "deny"
    public static let reply = "reply"
}
