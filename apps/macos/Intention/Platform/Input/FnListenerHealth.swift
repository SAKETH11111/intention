import Foundation
import Observation

/// A tap is only proven after it delivers an event. Quiet keyboards are not
/// failures; a disabled port, stalled run loop or sustained monitor-only key
/// traffic is. The monitor winning one main-queue race is not a failure.
struct FnListenerRecovery {
    enum State: String, Sendable { case checking, live, waitingForAccessibility, blockedBySecureInput, failed }
    enum Reason: String, Sendable { case start, trustChanged, secureInputEnded, disabled, healthCheck, monitorMiss, retry }
    enum Action: Equatable { case stop, rebuild(Reason) }

    static let retryLimit = 4
    static let monitorSilenceLimit: TimeInterval = 3
    private(set) var state = State.checking
    private(set) var tapProven = false
    private(set) var attempts = 0
    private var trust: Bool?
    private var secure = false
    private var pending: Reason? = .start
    private var due: TimeInterval = 0
    private var nextAllowed: TimeInterval = 0
    private var monitorKeysSince: TimeInterval?

    mutating func poll(trusted: Bool, secureInput: Bool, healthy: Bool, at now: TimeInterval) -> Action? {
        if trust != trusted {
            trust = trusted
            attempts = 0
            pending = .trustChanged
            due = now
            tapProven = false
            if !trusted { state = .waitingForAccessibility; return .stop }
            state = .checking
        }
        if secure != secureInput {
            secure = secureInput
            tapProven = false
            if secure { state = .blockedBySecureInput; return .stop }
            attempts = 0
            pending = .secureInputEnded
            state = .checking
            due = now
        }
        guard trusted else { state = .waitingForAccessibility; return nil }
        guard !secure else { state = .blockedBySecureInput; return nil }
        if !healthy, pending == nil { request(.healthCheck, at: now) }
        guard let reason = pending, now >= max(due, nextAllowed) else { return nil }
        guard attempts < Self.retryLimit else { state = .failed; return nil }
        attempts += 1
        nextAllowed = now + min(30, pow(2, Double(attempts)))
        pending = nil
        state = .checking
        tapProven = false
        monitorKeysSince = nil
        return .rebuild(reason)
    }

    mutating func attached(_ succeeded: Bool, at now: TimeInterval) {
        monitorKeysSince = nil
        guard !succeeded else { return }
        state = .failed
        request(.healthCheck, at: now)
    }

    mutating func request(_ reason: Reason, at now: TimeInterval) {
        tapProven = false
        if pending != reason { due = now + (reason == .disabled ? 2 : 0) }
        pending = reason
        state = .checking
    }

    mutating func retry(at now: TimeInterval) {
        attempts = 0
        request(.retry, at: now)
    }

    mutating func receivedFromTap() {
        guard trust == true, !secure else { return }
        // The budget limits consecutive failed recoveries. A working tap
        // earns a fresh budget without bypassing the next allowed rebuild.
        attempts = 0
        tapProven = true
        monitorKeysSince = nil
        pending = nil
        state = .live
    }

    mutating func receivedFromMonitor(at now: TimeInterval, observingKeys: Bool = true) {
        guard trust == true, !secure else { return }
        // The monitor is useful input even if tap installation failed. It
        // never proves the tap or cancels its recovery budget.
        state = .live
        if observingKeys {
            // Start at the first unmatched key, so a quiet keyboard does not
            // make its first monitor delivery look like a dead tap. Any tap
            // delivery resets this interval, even if its monitor copy won.
            if monitorKeysSince == nil { monitorKeysSince = now }
            if pending == nil, let monitorKeysSince, now - monitorKeysSince >= Self.monitorSilenceLimit {
                request(.monitorMiss, at: now)
            }
        }
    }
}

@MainActor @Observable
final class FnListenerHealth {
    private(set) var state = FnListenerRecovery.State.checking
    struct Press: Equatable {
        let began: Date
        let ended: Date
    }
    private(set) var completedPress: Press?
    /// The latest modifier pressed that is not the trigger, as setup names
    /// it, and when: someone holding the shortcut they are used to from
    /// another app is told which key Intention saw.
    private(set) var otherKey: (name: String, at: Date)?
    /// Whether the trigger's keys are held alone now, for setup's shortcut
    /// page to press its caps down without starting a dictation.
    private(set) var isHeld = false
    private var pressedAt: (time: TimeInterval, date: Date)?
    private var lastHint: TimeInterval?
    static let hintInterval: TimeInterval = 30

    func update(_ state: FnListenerRecovery.State) {
        self.state = state
        if state != .live { resetProof() }
    }

    func resetProof() {
        pressedAt = nil
        completedPress = nil
        otherKey = nil
        isHeld = false
    }

    /// Only the trigger's own keys going down and then up proves setup's
    /// key, whichever the trigger is. A keyboard-state recovery, another
    /// modifier or a click cannot do so.
    func receivedTrigger(down: Bool, at time: TimeInterval, date: Date) {
        // A press after the shortcut was last shown up starts afresh; the
        // press of one still held keeps its start.
        if down, !isHeld { pressedAt = (time, date) }
        isHeld = down
        if !down, let pressedAt, time >= pressedAt.time {
            completedPress = Press(began: pressedAt.date, ended: date)
            self.pressedAt = nil
        }
    }

    /// A modifier that is not the trigger went down. A press of the
    /// trigger it joins proves nothing, as the trigger itself rejects it.
    func receivedOtherKey(_ name: String, date: Date) {
        otherKey = (name, date)
        discardPress()
    }

    /// HoldKey ended the hold itself, as for a release that never arrived:
    /// the shortcut is no longer shown held. Its pending press is kept, so
    /// a release still on its way can prove it; nothing else can.
    func endHold() {
        isHeld = false
    }

    /// Another key joined the trigger's press: the trigger rejects such a
    /// gesture, so the press proves nothing.
    func discardPress() {
        pressedAt = nil
        isHeld = false
    }

    func offerShortHint(at now: TimeInterval) -> Bool {
        guard lastHint.map({ now - $0 >= Self.hintInterval }) ?? true else { return false }
        lastHint = now
        return true
    }

    var problem: String? { Self.problem(for: state) }
    static func problem(for state: FnListenerRecovery.State) -> String? {
        switch state {
        case .live, .checking: nil
        case .waitingForAccessibility: "Allow Accessibility to use fn"
        case .blockedBySecureInput: "Secure input is blocking fn"
        case .failed: "Can't hear fn, quit and reopen Intention"
        }
    }
}
