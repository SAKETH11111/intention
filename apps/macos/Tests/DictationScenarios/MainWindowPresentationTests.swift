import AppKit
import Testing
@testable import Dictation

/// The window overrides ordering, so no test activates an app or shows a window.
@Suite(.serialized)
@MainActor
struct MainWindowPresentationTests {
    @Test func firstOpenPromotesThenWaitsBeforeActivatingAndMakingKey() {
        let rig = PresentationRig()
        rig.presentation.show(rig.window)
        #expect(rig.log.events == [.regular, .order])
        #expect(rig.turns.callbacks.count == 1)
        rig.turns.run()
        #expect(rig.log.events == [.regular, .order, .activate, .key])
    }

    @Test func openWindowBehindAnotherAppStillActivatesAndMakesKey() {
        let rig = PresentationRig()
        rig.window.shown = true
        rig.dock.willOpen(rig.window)
        rig.log.events.removeAll()
        rig.presentation.show(rig.window)
        #expect(rig.log.events == [.activate, .key])
        #expect(rig.turns.callbacks.isEmpty)
    }

    @Test func activeAppRefreshesActivationAndMakesTheRequestedWindowKey() {
        let rig = PresentationRig()
        rig.log.active = true
        rig.window.shown = true
        rig.dock.willOpen(rig.window)
        rig.log.events.removeAll()
        rig.presentation.show(rig.window)
        #expect(rig.log.events == [.activate, .key])
    }

    @Test func closingBeforeThePolicyTurnCancelsActivation() {
        let rig = PresentationRig()
        rig.presentation.show(rig.window)
        rig.presentation.cancel()
        // Cancellation must work even before AppKit updates visibility.
        rig.turns.run()
        #expect(rig.log.events == [.regular, .order])
    }

    @Test func hiddenWindowDoesNotActivateAfterThePolicyTurn() {
        let rig = PresentationRig()
        rig.presentation.show(rig.window)
        rig.window.shown = false
        rig.turns.run()
        #expect(rig.log.events == [.regular, .order])
    }

    @Test func secondRequestDuringPromotionJoinsTheDeferredActivation() {
        let rig = PresentationRig()
        rig.presentation.show(rig.window)
        rig.presentation.show(rig.window)
        // No activation in the promotion's turn, and one deferred callback.
        #expect(rig.log.events == [.regular, .order, .order])
        #expect(rig.turns.callbacks.count == 1)
        rig.turns.run()
        #expect(rig.log.events == [.regular, .order, .order, .activate, .key])
    }

    @Test func switchingToAnotherAppBeforeThePolicyTurnKeepsThatApp() {
        let rig = PresentationRig()
        rig.front.pid = 101
        rig.presentation.show(rig.window)
        rig.front.pid = 202
        rig.turns.run()
        #expect(rig.log.events == [.regular, .order])
    }

    @Test func intentionAlreadyInFrontAfterThePolicyTurnStillMakesTheWindowKey() {
        let rig = PresentationRig()
        rig.front.pid = 101
        rig.presentation.show(rig.window)
        rig.front.pid = ProcessInfo.processInfo.processIdentifier
        rig.turns.run()
        #expect(rig.log.events == [.regular, .order, .activate, .key])
    }

    @Test func deferredCallbackReachesMainActorFromBackgroundQueue() async {
        let rig = PresentationRig()
        rig.presentation.show(rig.window)
        let callback = rig.turns.callbacks.removeFirst()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                callback()
                continuation.resume()
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(rig.log.events == [.regular, .order, .activate, .key])
    }

    @Test func policyChangesAloneNeverActivate() async {
        let rig = PresentationRig()
        rig.dock.willOpen(rig.window)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(rig.log.events == [.regular, .accessory])
        #expect(rig.turns.callbacks.isEmpty)
    }
}

@MainActor
private final class PresentationRig {
    let log = PresentationLog()
    let turns = PresentationTurns()
    let window: PresentationWindow
    let front = PresentationFront()
    let dock: DockActivationController
    let presentation: MainWindowPresentation

    init() {
        window = PresentationWindow(log: log)
        dock = DockActivationController(windows: { [window] in [window] }, apply: { [log] in
            log.events.append($0 == .regular ? .regular : .accessory)
        })
        presentation = MainWindowPresentation(dock: dock, activate: { [log] in
            log.events.append(.activate)
            log.active = true
        }, frontmost: { [front] in front.pid }, nextTurn: { [turns] in turns.callbacks.append($0) })
    }
}

@MainActor
private final class PresentationLog {
    enum Event { case regular, accessory, order, activate, key }
    var events: [Event] = []
    var active = false
}

/// The app in front, as NSWorkspace would report it.
@MainActor
private final class PresentationFront {
    var pid: pid_t? = 101
}

@MainActor
private final class PresentationTurns {
    var callbacks: [@Sendable () -> Void] = []
    func run() {
        let pending = callbacks
        callbacks.removeAll()
        for callback in pending { callback() }
    }
}

@MainActor
private final class PresentationWindow: NSWindow {
    let log: PresentationLog
    var shown = false
    override var isVisible: Bool { shown }

    init(log: PresentationLog) {
        self.log = log
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("intention.main")
        isReleasedWhenClosed = false
    }

    override func orderFrontRegardless() {
        shown = true
        log.events.append(.order)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        shown = true
        log.events.append(.key)
    }
}
