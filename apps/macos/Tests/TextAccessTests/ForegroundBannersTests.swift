import Foundation
@testable import Intention
import Testing
import UserNotifications

struct ForegroundBannersTests {
    /// macOS asks the delegate on a queue of its own; a main-actor callback
    /// would trap here under -enable-actor-data-race-checks. Neither
    /// argument can be made outside macOS and the delegate reads neither,
    /// so stand-ins of the right size are passed.
    @Test func answersOnABackgroundQueue() async {
        let options = await withCheckedContinuation { (done: CheckedContinuation<UNNotificationPresentationOptions, Never>) in
            DispatchQueue.global().async {
                ForegroundBanners.shared.userNotificationCenter(
                    unsafeBitCast(NSObject(), to: UNUserNotificationCenter.self),
                    willPresent: unsafeBitCast(NSObject(), to: UNNotification.self)
                ) { done.resume(returning: $0) }
            }
        }
        #expect(options == [.banner, .list])
    }
}
