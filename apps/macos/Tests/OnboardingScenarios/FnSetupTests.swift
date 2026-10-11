import AppKit
import Testing
@testable import Onboarding

@MainActor
struct FnSetupTests {
    private func model(_ health: FnListenerHealth, keys: MemoryDeviceKey = MemoryDeviceKey("synthetic-key"), key: String = "fn",
                       retry: @escaping @MainActor () -> Void = {}, skipped: @escaping @MainActor () -> Void = {}) -> OnboardingModel {
        let defaults = UserDefaults(suiteName: "FnSetupTests." + UUID().uuidString)!
        let model = OnboardingModel(client: nil, keys: keys,
            permissions: SetupPermissions(isGranted: { _ in true }, request: { _ in }),
            dictation: FirstDictation(keyName: { key }, phase: { .idle }, latest: { nil },
                listener: health, retryListener: retry, skippedKeyCheck: skipped), defaults: defaults)
        model.continueFromMail()
        model.continueFromShortcut()
        return model
    }

    @Test func grantsAndATapAloneDoNotProveFn() {
        let health = FnListenerHealth()
        health.update(.live)
        let model = model(health)
        #expect(model.step == .tryIt)
        #expect(model.firstKeyCheck == .waiting)
        health.receivedTrigger(down: true, at: 1, date: Date())
        #expect(model.firstKeyCheck == .waiting)
        health.receivedTrigger(down: false, at: 2, date: Date())
        #expect(model.firstKeyCheck == .works)
        health.update(.blockedBySecureInput)
        #expect(model.firstKeyCheck == .problem(.blockedBySecureInput))
        health.update(.live)
        #expect(model.firstKeyCheck == .waiting)
    }

    @Test func timeoutShowsFailureAndRetryResetsTheWait() {
        let health = FnListenerHealth()
        var retries = 0
        let model = model(health, retry: { retries += 1 })
        // Nothing is said before the wait is over.
        model.checkFirstKey(at: Date().addingTimeInterval(OnboardingModel.keyCheckWait - 1))
        #expect(model.firstKeyCheck == .waiting)
        model.checkFirstKey(at: Date().addingTimeInterval(OnboardingModel.keyCheckWait + 1))
        #expect(model.firstKeyCheck == .notSeen(other: nil))
        #expect(model.firstKeyMessage == "Intention hasn't seen fn yet. Press it once, or change the shortcut.")
        model.retryFirstKey()
        #expect(retries == 1)
        #expect(model.firstKeyCheck == .waiting)
    }

    @Test func skippingKeepsANoteAndReportsTheUnverifiedKey() {
        let health = FnListenerHealth()
        var skipped = 0
        let model = model(health, skipped: { skipped += 1 })
        model.continueFromDictation()
        #expect(model.step == .reply)
        #expect(model.keyCheckSkipped)
        #expect(skipped == 1)
    }

    @Test func anotherAccountStartsWithAFreshCheckAndNoSkippedNote() throws {
        let health = FnListenerHealth()
        let keys = MemoryDeviceKey("synthetic-key")
        let model = model(health, keys: keys)
        model.checkFirstKey(at: Date().addingTimeInterval(OnboardingModel.keyCheckWait + 1))
        model.continueFromDictation()
        #expect(model.keyCheckSkipped)
        try keys.save("another-synthetic-key")
        #expect(model.backendKey == "another-synthetic-key")
        // A new account starts again at mail, and chooses its shortcut again after.
        #expect(model.step == .mail)
        #expect(!model.keyCheckSkipped)
        #expect(model.firstKeyCheck == .waiting)
    }

    @Test func signingOutClearsThePreviousCheck() {
        let health = FnListenerHealth()
        let model = model(health)
        model.checkFirstKey(at: Date().addingTimeInterval(OnboardingModel.keyCheckWait + 1))
        model.continueFromDictation()
        model.backendKeyRefused("synthetic-key")
        #expect(model.step == .signIn)
        #expect(!model.keyCheckSkipped)
        #expect(model.firstKeyCheck == .waiting)
    }

    @Test func completedPairBeforePageOpenedDoesNotPass() {
        let health = FnListenerHealth()
        health.update(.live)
        let old = Date().addingTimeInterval(-10)
        health.receivedTrigger(down: true, at: 1, date: old)
        health.receivedTrigger(down: false, at: 2, date: old)
        let model = model(health)
        #expect(model.firstKeyCheck == .waiting)
    }

    @Test func permissionNotificationCanArriveOnAWorkerQueue() async {
        let permission = AccessibilityPermission()
        let callback = AccessibilityPermission.notificationHandler(for: permission)
        await Task.detached { callback(Notification(name: .init("synthetic.permission"))) }.value
        try? await Task.sleep(for: .milliseconds(300))
        // Refresh is read-only; no prompt and no main-actor assertion trap.
        _ = permission.isGranted
    }
    @Test func pressBeforePageOrRetryCannotProveTheNewCheck() {
        let health = FnListenerHealth()
        health.update(.live)
        health.receivedTrigger(down: true, at: 1, date: Date().addingTimeInterval(-10))
        let model = model(health)
        health.receivedTrigger(down: false, at: 2, date: Date())
        #expect(model.firstKeyCheck == .waiting)
        health.receivedTrigger(down: true, at: 3, date: Date())
        model.retryFirstKey()
        health.receivedTrigger(down: false, at: 4, date: Date())
        #expect(model.firstKeyCheck == .waiting)
        health.receivedTrigger(down: true, at: 5, date: Date())
        health.receivedTrigger(down: false, at: 6, date: Date())
        #expect(model.firstKeyCheck == .works)
    }

}
