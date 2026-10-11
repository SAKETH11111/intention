import AppKit
import Testing
@testable import Dictation

@Suite(.serialized)
@MainActor
struct DockActivationTests {
    @Test func reopeningRepairsAResetPolicyAndRetriesARejectedPromotion() async {
        let window = Window(.history)
        var actual = DockPolicy.accessory
        var applied: [DockPolicy] = []
        var rejectsPromotion = true
        let controller = DockActivationController(windows: { [window] }, readPolicy: { actual }, apply: {
            applied.append($0)
            if !rejectsPromotion { actual = $0 }
        })
        controller.willOpen(window)
        #expect(controller.policy == .accessory)
        rejectsPromotion = false
        controller.willOpen(window)
        window.shown = true
        await drainMainQueue()
        #expect(actual == .regular)
        actual = .accessory
        controller.willOpen(window)
        #expect(actual == .regular)
        #expect(applied == [.regular, .regular, .regular])
    }

    @Test func policyCountsOnlyApplicationWindows() {
        #expect(DockPolicy.forWindows([]) == .accessory)
        let overlays: Set<IntentionWindowKind> = [.caretDot, .footMark, .card, .popup]
        #expect(DockPolicy.forWindows(overlays) == .accessory)
        for kind in [IntentionWindowKind.history, .settings, .onboarding, .reportProblem, .settingsGuide, .update] {
            #expect(DockPolicy.forWindows(overlays.union([kind])) == .regular)
        }
        #expect(DockPolicy.forWindows([.history, .onboarding]) == .regular)
    }

    @Test func classificationIncludesdisabled updaterPanelsAndExcludesAllOverlays() {
        let history = Window(.history)
        let setup = Window(.onboarding)
        let report = Window(.reportProblem)
        #expect(DockActivationController.kind(of: history) == .history)
        #expect(DockActivationController.kind(of: setup) == .onboarding)
        #expect(DockActivationController.kind(of: report) == .reportProblem)
        let updater = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        #expect(DockActivationController.kind(of: updater) == .update)
        let guide = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        #expect(DockActivationController.kind(of: guide) == nil)
        let card = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        #expect(DockActivationController.kind(of: card) == nil)
        let borderless = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        #expect(DockActivationController.kind(of: borderless) == nil)
    }

    @Test func openingPromotesBeforeVisibilityAndCloseWaitsForAppKit() async {
        let center = NotificationCenter()
        let window = Window(.history)
        var applied: [DockPolicy] = []
        let controller = DockActivationController(center: center, windows: { [window] }, apply: { applied.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.willOpen(window)
        #expect(applied == [.regular])
        window.shown = true
        await drainMainQueue()
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(applied == [.regular])
        window.shown = false
        await drainMainQueue()
        #expect(applied == [.regular, .accessory])
    }

    @Test func closingSetupKeepsHistoryAndReplacementAvoidsPolicyFlicker() async {
        let center = NotificationCenter()
        let main = Window(.history)
        let setup = Window(.onboarding)
        main.shown = true
        setup.shown = true
        var applied: [DockPolicy] = []
        let controller = DockActivationController(center: center, windows: { [main, setup] }, apply: { applied.append($0) })
        controller.start()
        defer { controller.stop() }
        center.post(name: NSWindow.willCloseNotification, object: setup)
        setup.shown = false
        await drainMainQueue()
        #expect(applied == [.regular])
        center.post(name: NSWindow.willCloseNotification, object: main)
        main.shown = false
        controller.willOpen(setup)
        setup.shown = true
        await drainMainQueue()
        #expect(applied == [.regular])
        center.post(name: NSWindow.willCloseNotification, object: setup)
        setup.shown = false
        await drainMainQueue()
        #expect(applied == [.regular, .accessory])
    }

    @Test func minimizedAndOccludedWindowsStayInDock() async {
        let center = NotificationCenter()
        let window = Window(.history)
        window.minimized = true
        var applied: [DockPolicy] = []
        let controller = DockActivationController(center: center, windows: { [window] }, apply: { applied.append($0) })
        controller.start()
        defer { controller.stop() }
        center.post(name: NSWindow.didMiniaturizeNotification, object: window)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        await drainMainQueue()
        #expect(applied == [.regular])
    }

    @Test func doesNotDemoteWhileClosingWindowIsStillKey() async {
        let center = NotificationCenter()
        let window = Window(.history)
        window.shown = true
        window.key = true
        var applied: [DockPolicy] = []
        let controller = DockActivationController(center: center, windows: { [window] }, apply: { applied.append($0) })
        controller.start()
        defer { controller.stop() }
        center.post(name: NSWindow.willCloseNotification, object: window)
        await drainMainQueue()
        #expect(applied == [.regular])
        window.key = false
        window.shown = false
        center.post(name: NSApplication.didUpdateNotification, object: nil)
        await drainMainQueue()
        #expect(applied == [.regular, .accessory])
    }

    @Test func observerFindsVendorWindowsAndStopsListening() async {
        let center = NotificationCenter()
        let update = Window(.update)
        var applied: [DockPolicy] = []
        let controller = DockActivationController(center: center, windows: { [update] }, apply: { applied.append($0) })
        controller.start()
        controller.start()
        update.shown = true
        center.post(name: NSWindow.didUpdateNotification, object: update)
        await drainMainQueue()
        #expect(applied == [.regular])
        controller.stop()
        update.shown = false
        center.post(name: NSApplication.didUpdateNotification, object: nil)
        await drainMainQueue()
        #expect(applied == [.regular])
    }

    @Test func frameworkCallbackHopsFromBackgroundQueue() async {
        let window = Window(.history)
        window.shown = true
        var applied: [DockPolicy] = []
        let controller = DockActivationController(windows: { [window] }, apply: { applied.append($0) })
        let callback = DockActivationController.observer(controller)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                callback(Notification(name: NSWindow.didBecomeKeyNotification))
                continuation.resume()
            }
        }
        await drainMainQueue()
        #expect(applied == [.regular])
        window.shown = false
        let id = ObjectIdentifier(window)
        // The callback must carry the close identity across the actor hop.
        let closedWindow = window
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                callback(Notification(name: NSWindow.willCloseNotification, object: closedWindow))
                continuation.resume()
            }
        }
        #expect(ObjectIdentifier(window) == id)
        await drainMainQueue()
        #expect(applied == [.regular, .accessory])
    }

    @Test func stopCancelsQueuedPolicyChangesAndOldCallbacksAcrossRestart() async {
        let center = NotificationCenter()
        let window = Window(.history)
        window.shown = true
        var applied: [DockPolicy] = []
        let controller = DockActivationController(center: center, windows: { [window] }, apply: { applied.append($0) })
        controller.start()
        let oldCallback = DockActivationController.observer(controller)
        center.post(name: NSWindow.willCloseNotification, object: window)
        window.shown = false
        controller.stop()
        await drainMainQueue()
        #expect(applied == [.regular])
        controller.start()
        defer { controller.stop() }
        #expect(applied == [.regular, .accessory])
        window.shown = true
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                oldCallback(Notification(name: NSWindow.didUpdateNotification))
                continuation.resume()
            }
        }
        await drainMainQueue()
        #expect(applied == [.regular, .accessory])
        center.post(name: NSWindow.didUpdateNotification, object: window)
        await drainMainQueue()
        #expect(applied == [.regular, .accessory, .regular])
    }

    @Test func updatePresentationPromotesBeforeTheVendorWindowExists() async {
        let center = NotificationCenter()
        let window = Window(.update)
        var applied: [DockPolicy] = []
        let controller = DockActivationController(center: center, windows: { [window] }, apply: { applied.append($0) })
        controller.start()
        defer { controller.stop() }
        controller.willPresentUpdate()
        #expect(applied == [.regular])
        center.post(name: NSApplication.didUpdateNotification, object: nil)
        #expect(applied == [.regular])
        window.shown = true
        await drainMainQueue()
        #expect(applied == [.regular])
        center.post(name: NSWindow.willCloseNotification, object: window)
        window.shown = false
        await drainMainQueue()
        #expect(applied == [.regular, .accessory])
        controller.willPresentUpdate()
        await drainMainQueue()
        #expect(applied == [.regular, .accessory, .regular, .accessory])
    }

    @Test func delayedManualCheckPromotesOnlyAfterTheInstallerProbe() async {
        let center = NotificationCenter()
        let window = Window(.update)
        var applied: [DockPolicy] = []
        let controller = DockActivationController(center: center, windows: { [window] }, apply: { applied.append($0) })
        let presentation = UpdateWindowPresentation(beforeShow: { controller.willPresentUpdate() })
        controller.start()
        defer { controller.stop() }
        // No window exists while the asynchronous installer probe runs.
        await drainMainQueue()
        presentation.updateCheckMayBegin(userInitiated: false)
        await drainMainQueue()
        #expect(applied.isEmpty)
        // disabled updater asks after the probe, then activates and shows the window
        // in the same ordering turn. Policy must already be regular there.
        presentation.updateCheckMayBegin(userInitiated: true)
        #expect(applied == [.regular])
        window.shown = true
        await drainMainQueue()
        #expect(applied == [.regular])
        center.post(name: NSWindow.willCloseNotification, object: window)
        window.shown = false
        await drainMainQueue()
        #expect(applied == [.regular, .accessory])
    }

    @Test func updaterPresentationCallbacksHopFromBackgroundQueue() async {
        var presentations = 0
        let presentation = UpdateWindowPresentation(beforeShow: { presentations += 1 })
        presentation.willShow()
        #expect(presentations == 1)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                presentation.willShow()
                presentation.updateCheckMayBegin(userInitiated: true)
                presentation.willShow()
                continuation.resume()
            }
        }
        await drainMainQueue()
        #expect(presentations == 4)
    }

    @Test func backgroundLaunchesDoNotOpenHome() {
        #expect(MainWindowReopening.shouldOpenAtLaunch(atLogin: false, opensSetup: false, isTestHost: false, arguments: ["Intention"]))
        #expect(!MainWindowReopening.shouldOpenAtLaunch(atLogin: true, opensSetup: false, isTestHost: false, arguments: ["Intention"]))
        #expect(!MainWindowReopening.shouldOpenAtLaunch(atLogin: false, opensSetup: true, isTestHost: false, arguments: ["Intention"]))
        #expect(!MainWindowReopening.shouldOpenAtLaunch(atLogin: false, opensSetup: false, isTestHost: true, arguments: ["Intention"]))
        #expect(MainWindowReopening.shouldHandleReopen(isTestHost: false, arguments: ["Intention"]))
        #expect(!MainWindowReopening.shouldHandleReopen(isTestHost: true, arguments: ["Intention"]))
        for flag in ["--settings-snapshot", "--caret-fixture", "--insertion-checks", "--proposal-log", "--dot-log"] {
            #expect(!MainWindowReopening.shouldOpenAtLaunch(atLogin: false, opensSetup: false, isTestHost: false,
                                                         arguments: ["Intention", flag, "/synthetic/fixture"]))
            #expect(!MainWindowReopening.shouldHandleReopen(isTestHost: false, arguments: ["Intention", flag, "/synthetic/fixture"]))
        }
    }

    @Test func reopeningReachesMainActorFromBackgroundQueue() async {
        var openings = 0
        let open: @MainActor @Sendable () -> Void = { openings += 1 }
        MainWindowReopening.request(open)
        #expect(openings == 1)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                MainWindowReopening.request(open)
                continuation.resume()
            }
        }
        await drainMainQueue()
        #expect(openings == 2)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class Window: NSWindow {
    var shown = false
    var key = false
    var minimized = false
    override var isVisible: Bool { shown }
    override var isKeyWindow: Bool { key }
    override var isMiniaturized: Bool { minimized }

    init(_ kind: IntentionWindowKind) {
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        let name = switch kind {
        case .history: "intention.main"
        case .onboarding: "intention.onboarding"
        case .reportProblem: "intention.report-problem"
        default: "vendor.update"
        }
        identifier = NSUserInterfaceItemIdentifier(name)
    }
}
