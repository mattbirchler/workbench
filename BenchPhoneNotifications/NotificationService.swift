import BenchKit
import UserNotifications

/// Opens sealed notifications from the Mac before they're shown. The push
/// carries a placeholder and the real words encrypted with the paired
/// Mac's key (see NotificationSeal); this swaps them in. If it can't, the
/// placeholder shows, which still says to open Workbench.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let info = content.userInfo
        if let sealed = info[NotificationSeal.payloadKey] as? String,
           let keyID = info[NotificationSeal.keyIDKey] as? String,
           let key = NotificationKeys.key(id: keyID),
           let opened = NotificationSeal.open(sealed, with: key) {
            content.title = opened.title
            content.body = opened.body
            // The app reads these when the notification is tapped.
            var userInfo = info
            userInfo[NotificationSeal.payloadKey] = nil
            userInfo["project"] = opened.project
            userInfo["session"] = opened.session
            userInfo["url"] = opened.url
            userInfo["host"] = opened.host
            content.userInfo = userInfo
            // Sealed with the words, so the relay and Apple don't learn
            // what kind of notification this is.
            if let category = opened.category { content.categoryIdentifier = category }
        }
        contentHandler(content)
    }
}
