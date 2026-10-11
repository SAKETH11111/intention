import UserNotifications

/// macOS's notifications, for the one Intention posts: that the person's
/// voice is ready (`VoiceReady`). Only the fixed words go to macOS.
enum SystemNotifications {
    @MainActor static func voiceReady() -> VoiceReady.Notifier {
        let pending = Pending()
        let center = UNUserNotificationCenter.current()
        // Without a delegate macOS keeps a notification out of sight while
        // Intention is the active app, as when setup's window is in front.
        center.delegate = ForegroundBanners.shared
        return VoiceReady.Notifier(
            ask: {
                Task { @MainActor in _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
            },
            post: { text in
                // The voice can turn ready while macOS's question is still
                // on screen; asking again waits for that answer, and asks
                // nothing once the person has answered. A change of account
                // meanwhile cancels it.
                pending.task = Task { @MainActor in
                    let center = UNUserNotificationCenter.current()
                    let allowed = (try? await center.requestAuthorization(options: [.alert])) == true
                    guard !Task.isCancelled else { return }
                    guard allowed else {
                        AppLog.mail("voice.ready.not_allowed")
                        return
                    }
                    let content = UNMutableNotificationContent()
                    content.body = text
                    do {
                        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                    } catch {
                        AppLog.mail("voice.ready.not_posted")
                    }
                }
            },
            cancel: { pending.task?.cancel() })
    }

    /// The notification waiting for permission, if any.
    @MainActor private final class Pending {
        var task: Task<Void, Never>?
    }
}

/// Shows Intention's notification as a banner while Intention is active too.
/// macOS calls it on a queue of its own, so it is nonisolated and holds
/// no state.
final class ForegroundBanners: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ForegroundBanners()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
