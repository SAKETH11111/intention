import AppKit
import os
import Carbon

/// Watches the dictation trigger held for hold-to-talk: one modifier key on
/// its own, or two or more modifiers held together. It observes that
/// trigger's presses and releases, and which other keys are down, by key
/// code, to tell a pair pressed alone from a shortcut; a key's code is kept
/// in memory only until that key comes up and is never stored or logged.
/// The rules are in `HoldDetector`, which has
/// no AppKit in it, so `./dev mac-dictation-test` can drive them; the one
/// clock, the arm delay a pair waits out before it counts as held, is a
/// timer here.
///
/// A hold confirmed after 300 ms records until release. Two short taps
/// within 300 ms start hands-free recording. Space pressed while it is held makes the dictation hands-free,
/// so it goes on after the key is let go, until the key is pressed again,
/// the dot or the foot's sun is clicked, or it is cancelled; Escape
/// cancels any dictation while it records. Those rules are dictation's;
/// this reports the press, the release, the Space and the Escape.
///
/// Modifier changes and those keys come from `TriggerTap`, an event tap at
/// the HID level. While Fn is the dictation key, that tap removes Fn's own
/// press and release from the event stream, and the globe key's own key
/// event that follows a tap of it, so other apps listening for Fn, such as
/// Wispr Flow (whose tap sits at the later session level) or the globe
/// key's emoji picker, do not start as well. Fn still modifies other keys,
/// since each key event carries its own flags. It also removes Space
/// pressed with the dictation key held, so no space is typed and no
/// shortcut such as Command-Space opens, and Escape while a dictation
/// records or an email write is pending, so the app in front does not act
/// on it too (`KeyClaims`).
/// Every other key and modifier passes through untouched, and a
/// combination's modifiers are never removed: they are Control, Option and
/// Command, which every app's shortcuts rely on, and a combination cannot
/// be told from a shortcut's first modifier until its second arrives, by
/// which time the first has already passed. While a reply proposal's card
/// shows, the tap also takes a plain Tab press, its autorepeats and its
/// release from the app, and reports it as accepting the proposal
/// (`takeTab`); Shift-Tab and every other key pass. A taken Tab still
/// reaches the trigger's rules, so a pair pressed while it is held stays a
/// shortcut. Until the tap can be created, which needs the Accessibility
/// grant, ordinary monitors watch without removing anything, and no Tab is
/// taken.
///
/// A release can go unseen: secure input, a moment with the tap disabled
/// or another app's tap ahead of this one can each keep it from Intention,
/// and the recording would run on. So while the key is held the keyboard
/// state is read every `watchInterval`, and once it has shown the key down
/// and then shows it up, that is the release.
@MainActor
final class HoldKey {
    // The new gestures stay off until their separate review in #488.
    static let handsFreeAvailable = false
    let handsFreeEnabled: Bool
    /// One physical modifier key, by side. A single-key trigger is read by
    /// this key's own code and device bit.
    enum Modifier: String, CaseIterable, Sendable {
        /// Fn, or the globe key on newer keyboards, as Wispr Flow uses.
        case function
        case leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand, leftShift, rightShift

        /// Virtual key codes from Carbon's Events.h.
        var keyCode: UInt16 {
            switch self {
            case .function: 63
            case .leftControl: 59
            case .rightControl: 62
            case .leftOption: 58
            case .rightOption: 61
            case .leftCommand: 55
            case .rightCommand: 54
            case .leftShift: 56
            case .rightShift: 60
            }
        }

        init?(keyCode: UInt16) {
            guard let modifier = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
            self = modifier
        }

        /// The bit set while this key is down. Fn has one flag; the others
        /// have device bits of their own (NX_DEVICELCTLKEYMASK and its
        /// siblings), so holding the other side's key too does not hide a
        /// release.
        var deviceMask: UInt {
            switch self {
            case .function: NSEvent.ModifierFlags.function.rawValue
            case .leftControl: 0x1
            case .rightControl: 0x2000
            case .leftOption: 0x20
            case .rightOption: 0x40
            case .leftCommand: 0x8
            case .rightCommand: 0x10
            case .leftShift: 0x2
            case .rightShift: 0x4
            }
        }

        /// The same modifier on the keyboard's other side, nil for Fn.
        var otherSide: Modifier? {
            switch self {
            case .function: nil
            case .leftControl: .rightControl
            case .rightControl: .leftControl
            case .leftOption: .rightOption
            case .rightOption: .leftOption
            case .leftCommand: .rightCommand
            case .rightCommand: .leftCommand
            case .leftShift: .rightShift
            case .rightShift: .leftShift
            }
        }

        var family: Family {
            switch self {
            case .function: .function
            case .leftControl, .rightControl: .control
            case .leftOption, .rightOption: .option
            case .leftCommand, .rightCommand: .command
            case .leftShift, .rightShift: .shift
            }
        }

        var title: String {
            switch self {
            case .function: "Fn (globe)"
            case .leftControl: "Left Control"
            case .rightControl: "Right Control"
            case .leftOption: "Left Option"
            case .rightOption: "Right Option"
            case .leftCommand: "Left Command"
            case .rightCommand: "Right Command"
            case .leftShift: "Left Shift"
            case .rightShift: "Right Shift"
            }
        }
    }

    /// A modifier whichever side it is on, as a combination reads it, in
    /// the order the Mac names modifiers.
    enum Family: String, CaseIterable, Comparable, Sendable {
        case function, control, option, shift, command

        /// The device-independent flag, set for either side's key.
        var flag: NSEvent.ModifierFlags {
            switch self {
            case .function: .function
            case .control: .control
            case .option: .option
            case .shift: .shift
            case .command: .command
            }
        }

        var title: String {
            switch self {
            case .function: "Fn"
            case .control: "Control"
            case .option: "Option"
            case .shift: "Shift"
            case .command: "Command"
            }
        }

        static func < (left: Family, right: Family) -> Bool {
            allCases.firstIndex(of: left)! < allCases.firstIndex(of: right)!
        }
    }

    /// The dictation trigger: one modifier key held on its own, read by its
    /// key code and side, or two or more modifiers held together, either
    /// side of each. Which ones a person may choose is `KeyRecording`'s.
    enum Key: Hashable, Identifiable, Sendable {
        case single(Modifier)
        case combination(Set<Family>)

        static let function = Key.single(.function)
        static let rightOption = Key.single(.rightOption)
        static let rightCommand = Key.single(.rightCommand)
        static let controlOption = Key.combination([.control, .option])
        static let controlCommand = Key.combination([.control, .command])
        static let optionCommand = Key.combination([.option, .command])

        /// The triggers setup's last page offers in place of Fn. Settings
        /// records any key the trigger can use.
        static let suggested: [Key] = [.function, .rightOption, .rightCommand, .controlOption, .controlCommand, .optionCommand]

        var id: String { rawValue }

        /// How the trigger is saved: a single key by its name, such as
        /// "rightOption", and a combination by its modifiers joined with
        /// "+", such as "control+option". The three pairs offered before
        /// keys were recorded were saved as "controlOption",
        /// "controlCommand" and "optionCommand", and still read.
        var rawValue: String {
            switch self {
            case let .single(modifier): modifier.rawValue
            case let .combination(families): families.sorted().map(\.rawValue).joined(separator: "+")
            }
        }

        init?(rawValue: String) {
            switch rawValue {
            case "controlOption": self = .controlOption
            case "controlCommand": self = .controlCommand
            case "optionCommand": self = .optionCommand
            default:
                if let modifier = Modifier(rawValue: rawValue) {
                    self = .single(modifier)
                    return
                }
                let families = rawValue.split(separator: "+").map { Family(rawValue: String($0)) }
                guard families.count >= 2, !families.contains(nil) else { return nil }
                let set = Set(families.compactMap { $0 })
                guard set.count == families.count else { return nil }
                self = .combination(set)
            }
        }

        var title: String {
            switch self {
            case let .single(modifier): modifier.title
            case let .combination(families): families.sorted().map(\.title).joined(separator: " + ")
            }
        }

        var isCombination: Bool {
            if case .combination = self { return true }
            return false
        }

        /// The single key's code. A combination has no key of its own; it
        /// is read from the flags.
        var keyCode: UInt16? {
            if case let .single(modifier) = self { return modifier.keyCode }
            return nil
        }

        /// The bits that are set while the trigger is down: the single
        /// key's own bit, or for a combination the device-independent bits,
        /// so either side of each key counts.
        var mask: UInt {
            switch self {
            case let .single(modifier): modifier.deviceMask
            case let .combination(families): families.reduce(NSEvent.ModifierFlags()) { $0.union($1.flag) }.rawValue
            }
        }

        /// The device-independent flags of every key in the trigger, either
        /// side, which any key event pressed with the trigger down carries.
        var families: NSEvent.ModifierFlags {
            switch self {
            case let .single(modifier): modifier.family.flag
            case let .combination(families): families.reduce(NSEvent.ModifierFlags()) { $0.union($1.flag) }
            }
        }

        /// Whether `flags` hold this trigger's modifiers and no other: no
        /// other family, and for a single key not the same modifier on the
        /// other side either, as Left Command held with Right Command.
        func isAlone(in flags: NSEvent.ModifierFlags) -> Bool {
            guard flags.intersection(HoldDetector.modifiers) == families else { return false }
            guard case let .single(modifier) = self, let other = modifier.otherSide else { return true }
            return flags.rawValue & other.deviceMask == 0
        }

        /// The key code whose own press and release the tap removes while
        /// this is the trigger, or nil for none: only Fn is taken, and only
        /// while dictation can run, so Fn is left to other apps otherwise.
        /// Every other key and every combination passes through untouched.
        func consumedKeyCode(dictationAvailable: Bool) -> UInt16? {
            self == .function && dictationAvailable ? keyCode : nil
        }

        /// Whether any of the given keyboard states, as `CGEventSource`
        /// reports its flags, shows every one of this trigger's keys down.
        /// For a pair, one of its keys down is not enough.
        func isDown(in states: [UInt]) -> Bool {
            states.contains { $0 & mask == mask }
        }

        /// Whether the flags show this trigger's keys down and no other
        /// modifier, as a hold the trigger accepts has them: setup's key
        /// check counts only such a press.
        func isAlone(in flags: UInt) -> Bool {
            isDown(in: [flags]) && Modifier.allCases.allSatisfy { contains(keyCode: $0.keyCode) || flags & $0.deviceMask == 0 }
        }

        /// Only a trigger modifier's own transition can release it. Flags
        /// on Caps Lock, mouse and ordinary key events can omit Fn.
        func contains(keyCode: UInt16) -> Bool {
            switch self {
            case let .single(modifier): keyCode == modifier.keyCode
            case let .combination(families): HoldKey.Modifier(keyCode: keyCode).map { families.contains($0.family) } ?? false
            }
        }
    }

    var key: Key {
        didSet {
            if recording {
                deferredKey = key == oldValue ? nil : key
                key = oldValue
                return
            }
            if key != oldValue {
                detector.key = key
                release()
                gesture.reset()
            }
            updateConsumption()
            if key != oldValue {
                skippedListenerCheck = false
                onListenerProblem(key == .function ? listener.problem : nil)
                // A press of the earlier trigger, or of the new one while it
                // was another key, proves nothing about this one.
                listener.resetProof()
            }
        }
    }
    private var deferredKey: Key?
    private var deferredRecorder: (@MainActor (Recorded) -> Void)?
    private var hasDeferredRecorder = false

    /// Whether dictation can run. When it cannot, Fn is left to other apps.
    var dictationAvailable = true {
        didSet {
            if !dictationAvailable { cancelPending() }
            updateConsumption()
        }
    }
    /// Whether the tap takes Space with the key held now: whenever a press
    /// of the key starts a dictation or is the one recording's, even while
    /// an earlier dictation's text is on its way. Unavailable dictation and
    /// Settings recording a key leave it to the app in front, as
    /// Command-Space is to Spotlight.
    var takesSpace: Bool { handsFreeEnabled && recorder == nil && dictationAvailable }
    // Called only on the main actor, so a hook may capture and change
    // main-actor state, as the checks' counters do.
    var onPress: @MainActor () -> Void = {}
    /// Whether a press with nothing recording is only shown, as on setup's
    /// shortcut page: it starts nothing and is not a rejection. A press
    /// while something records still goes to `onPress`, so the key can end
    /// a dictation a click started.
    var pressOnlyShows: @MainActor () -> Bool = { false }
    /// A press is eligible but has not passed the audio hold gate yet.
    var onPendingChanged: @MainActor (Bool) -> Void = { _ in }
    private(set) var keyPending = false
    private var pendingBegan: TimeInterval?

    /// Withdraw the pending press as well as its appearance. A later timer
    /// cannot turn a cancelled press into a recording.
    func cancelPending() {
        guard !recording else { return setPending(false) }
        setPending(false)
        guard gesture.waiting || detector.arming else { return }
        gesture.shortcut()
        gestureTimer?.invalidate()
        gestureTimer = nil
        arm?.invalidate()
        arm = nil
        if detector.arming { act(detector.release()) }
        withdrawHold()
    }

    private func setPending(_ pending: Bool) {
        guard pending != keyPending else { return }
        keyPending = pending
        if pending, let began = pendingBegan {
            AppLog.pressStage("dotRequested", at: now(), since: began)
        }
        onPendingChanged(pending)
    }
    var onRelease: @MainActor () -> Void = {}
    /// Another key went down while the key was held.
    var onOtherKey: @MainActor () -> Void = {}
    /// A click came while the key was held.
    var onClick: @MainActor () -> Void = {}
    /// Space went down with the key held, which the tap took: the person
    /// asks for hands-free dictation.
    var onHandsFree: @MainActor () -> Void = {}
    /// Escape went down while a recording or pending email could cancel.
    var onEscape: @Sendable @MainActor () -> Void = {} {
        didSet {
            let action = onEscape
            escapeAction.withLock { $0 = action }
            updateConsumption()
        }
    }
    private nonisolated let escapeAction = OSAllocatedUnfairLock<@Sendable @MainActor () -> Void>(initialState: {})
    /// The screen locked, after any hold it ended was released: no key
    /// holds a hands-free or clicked dictation, so the app ends it here.
    var onLock: @MainActor () -> Void = {}
    /// Runs on the main actor with the generation `takeTab` was given when
    /// the tap took a plain Tab press.
    var tabTaken: @MainActor (UInt64) -> Void = { _ in }
    /// Runs on the main actor when Escape is pressed anywhere, from the tap
    /// once there is one and the ordinary monitors until then, before the
    /// press is handled. Escape is taken from the app only while a
    /// dictation records or an email write is pending (`onEscape`);
    /// otherwise the app gets it too.
    var escapePressed: @MainActor () -> Void = {}
    /// Runs on the main actor for every key press the tap or, until there
    /// is one, the ordinary monitors report, repeats included and the keys
    /// the tap takes among them, before the press is handled; a reply
    /// proposal waiting for a reply to settle starts its wait again.
    var keyPressed: @MainActor (UInt16, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// The generation Tab is taken for, kept so a tap created later takes
    /// it too.
    private var tabGeneration: UInt64?
    /// Whether the latest press had the key down on its own, with no other
    /// modifier or key held, as a press meant for dictation has; one that
    /// did not may be the start of a shortcut.
    var pressWasAlone: Bool { detector.pressAlone }
    /// Whether a dictation records now; the app sets it. Escape cancels
    /// this recording before any pending email. A key still held
    /// when no dictation records, as after Escape ended one, or when its press started none, takes no Space.
    var recording = false {
        didSet {
            guard recording != oldValue else { return }
            updateConsumption()
            setPending(false)
            if !recording {
                gesture.reset()
                gestureTimer?.invalidate()
                gestureTimer = nil
                if held { withdrawHold() }
                if let deferredKey {
                    self.deferredKey = nil
                    key = deferredKey
                }
                if hasDeferredRecorder {
                    let next = deferredRecorder
                    hasDeferredRecorder = false
                    deferredRecorder = nil
                    recorder = next
                }
            }
        }
    }

    /// Whether an email write is pending. Escape cancels it when no
    /// recording owns Escape, until insertion has decided its end.
    var pendingEmailWrite = false {
        didSet { if pendingEmailWrite != oldValue { updateConsumption() } }
    }

    var takesEscape: Bool { recorder == nil && (recording || pendingEmailWrite) }

    /// A modifier change or key press, as Settings records a new trigger.
    enum Recorded: Equatable {
        case modifiers(keyCode: UInt16, flags: NSEvent.ModifierFlags)
        /// `isRepeat` is a held key's auto-repeat, not a press of its own.
        case key(keyCode: UInt16, isRepeat: Bool = false)
        case keyUp(keyCode: UInt16)
    }

    /// Set while Settings records a new trigger. Every modifier change and
    /// key press then goes here in place of the trigger's rules, so holding
    /// the old trigger starts nothing, and key presses in Intention's own
    /// windows go no further. The tap also takes Fn's press and release
    /// meanwhile, so pressing Fn to record it does not start Wispr Flow or
    /// the globe key's picker too; the recorder still hears it.
    var recorder: (@MainActor (Recorded) -> Void)? {
        didSet {
            if recording {
                deferredRecorder = recorder
                hasDeferredRecorder = true
                recorder = oldValue
                return
            }
            deferredRecorder = nil
            hasDeferredRecorder = false
            if recorder != nil {
                // Also a press the tap has seen and the main actor has not.
                tap?.withdrawAll()
                release()
                gesture.reset()
            }
            updateConsumption()
        }
    }

    private var detector: HoldDetector
    private var gesture = DictationGesture()
    private(set) var gestureTimer: Timer?
    private var eventTime: TimeInterval?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private let holdDelay: TimeInterval
    /// The press handed to dictation has already lasted the tap window.
    private(set) var holdWasConfirmed = false
    private var held: Bool { detector.held }
    private var started = false
    private var monitors: [Any] = []
    private var tap: TriggerTap?
    let listener = FnListenerHealth()
    private var recovery = FnListenerRecovery()
    private var healthTimer: Timer?
    private var tapEpoch = 0
    private var tapStartedAt: TimeInterval = 0
    private var recentInputs: [InputStamp] = []
    private var latestKeyTime: [UInt16: TimeInterval] = [:]
    private var latestTriggerTime: TimeInterval?
    private var retainedPresses: TriggerTap.PressState?
    private var skippedListenerCheck = false
    var scheduleMonitorFallback: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
    var onListenerProblem: (String?) -> Void = { _ in }
    var onShortHold: () -> Void = {}
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    var secureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
    var diagnostic: (ClientEventName, ClientEventOutcome?) -> Void = { DiagnosticEvents.shared.note($0, outcome: $1) }

    private struct InputStamp: Equatable {
        var kind: Int
        var code: UInt16
        var flags: UInt
        var time: TimeInterval
    }
    /// How long a pair must be held alone; `HoldDetector.armDelay`, or a
    /// shorter wait in the checks so they stay quick.
    private let armDelay: TimeInterval
    /// Runs while a pair is down alone, and presses when it has been held
    /// for `armDelay`. Readable so the checks can see which wait is running.
    private(set) var arm: Timer?
    private var lockObserver: NSObjectProtocol?
    /// How often the keyboard is read while the key is held.
    static let watchInterval: TimeInterval = 0.1
    private let watchInterval: TimeInterval
    /// How long the keyboard must show the key up, at every reading and
    /// with nothing the tap has seen on its way here, before that counts as
    /// its release. The keyboard's state can be ahead of the tap by the
    /// events queued for it, a Space pressed before the key came up among
    /// them, and those reach the tap within milliseconds, so a Space it
    /// took always lands before such a release; a release the tap never
    /// sees ends the hold this much late, instead of never.
    static let unseenReleaseWait: TimeInterval = 1
    private let unseenReleaseWait: TimeInterval
    /// Reads the keyboard while the key is held (`checkKeyboard`).
    /// Readable so checks can step the watch without a run-loop deadline.
    private(set) var watch: Timer?
    /// The keyboard has shown every key of the trigger down during this
    /// hold. Only then does it showing them up count as the release: a key
    /// another process posted, as the dictation checks do, never shows in
    /// the keyboard's state, and ends with its own release alone.
    private var keyboardShowedDown = false
    /// Whether the keyboard showed every key of the trigger down, as the
    /// tap read it, at the change that completed the trigger or any since
    /// while it has been arming or held.
    private var keyboardShowsKey = false
    /// Readings in a row that showed the key up, with nothing from the tap
    /// on its way (`checkKeyboard`, `unseenReleaseWait`).
    private var readingsUp = 0
    /// Which press of the trigger the latest modifier change belongs to, as
    /// the tap counted them, so a hold the tap has since seen end is not
    /// published to it (`KeyClaims.held(_:generation:)`).
    private var generation = 0
    private var holdUsesTap = false
    private var holdTapEpoch: Int?
    private var holdGeneration = 0
    /// What was last published to the tap about the trigger being held as
    /// a dictation's; the checks read it.
    private(set) var publishedHold = false
    /// Tap deliveries still on their way to the main actor.
    private let inFlight = InFlight()
    /// The latest press whose Space, taken for hands-free, has been handled.
    private var handsFreeHandled: Int?

    /// Watches nothing until `start`, so the checks can hand it the events
    /// its monitors and tap would deliver.
    init(handsFreeEnabled: Bool = HoldKey.handsFreeAvailable, key: Key, holdDelay: TimeInterval = DictationGesture.window, armDelay: TimeInterval = HoldDetector.armDelay, watchInterval: TimeInterval = HoldKey.watchInterval,
         unseenReleaseWait: TimeInterval = HoldKey.unseenReleaseWait) {
        self.handsFreeEnabled = handsFreeEnabled
        self.key = key
        self.holdDelay = holdDelay
        self.armDelay = armDelay
        self.watchInterval = watchInterval
        self.unseenReleaseWait = unseenReleaseWait
        detector = HoldDetector(key: key)
        detector.keyboardShowsDown = keyboardShowsKeyDown
    }

    /// Whether the keyboard still shows a key down, which the trigger's
    /// rules ask before letting a pair start over a key whose release may
    /// have been missed. The checks give a made-up keyboard.
    var keyboardShowsKeyDown: (UInt16) -> Bool = HoldKey.keyboardShowsDown {
        didSet { detector.keyboardShowsDown = keyboardShowsKeyDown }
    }

    /// Starts watching: the monitors for keys and clicks, the tap for
    /// modifier changes once Accessibility allows it, and the lock screen.
    func start() {
        guard !started else { return }
        started = true
        let watched: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: watched, handler: Self.globalMonitor(for: self)) {
            monitors.append(global)
        }
        // Intention's own windows, such as history, do not reach the global monitor.
        if let local = NSEvent.addLocalMonitorForEvents(matching: watched, handler: Self.localMonitor(for: self)) {
            monitors.append(local)
        }
        startTap()
        // A locked screen takes the keyboard from every app; a release then
        // never arrives, so locking counts as one.
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                self?.release()
                self?.onLock()
            }
        }
    }

    /// Rechecks trust without prompting, and keeps watching after installation.
    /// A run-loop heartbeat checks the thread; real input proves delivery.
    private func startTap() {
        checkListener()
        let timer = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.checkListener() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    func retryListener() {
        recovery.retry(at: now())
        checkListener()
    }

    func reportSkippedListenerCheck() {
        guard key == .function, listener.state != .live else { return }
        skippedListenerCheck = true
        onListenerProblem(listener.problem ?? "Can't hear fn, quit and reopen Intention")
    }

    func checkListener() {
        let time = now()
        let secure = secureInputEnabled()
        let healthy = tap.map { time - tapStartedAt < 3 || $0.isHealthy(at: time) } ?? false
        let previous = recovery.state
        let action = recovery.poll(trusted: accessibilityTrusted(), secureInput: secure, healthy: healthy, at: time)
        if previous != .blockedBySecureInput, recovery.state == .blockedBySecureInput {
            diagnostic(.fnSecureInput, nil)
        }
        if let action {
            invalidateTap()
            if case let .rebuild(reason) = action { rebuildTap(reason: reason) }
        }
        publishListener()
        tap?.ping()
    }

    private func invalidateTap() {
        cancelPending()
        tapEpoch += 1
        holdUsesTap = false
        if let tap { retainedPresses = tap.stop() }
        tap = nil
        // Preserve an owned recording until its own release or keyboard watch.
        inputMayHaveBeenLost()
    }

    private func rebuildTap(reason: FnListenerRecovery.Reason) {
        let epoch = tapEpoch
        diagnostic(.fnListenerRebuilt, ClientEventOutcome(rawValue: reason.rawValue))
        tapStartedAt = now()
        tap = TriggerTap(presses: retainedPresses, deliver: { [weak self] delivery in self?.tapDelivered(delivery, epoch: epoch) },
                         claimed: { [weak self] claim, generation, cancellation in
                             self?.tapClaimed(claim, generation: generation, cancellation: cancellation, epoch: epoch)
                         },
                         input: { [weak self] input, tab in self?.tapInput(input, tabTaken: tab, epoch: epoch) },
                         disabled: { [weak self] in self?.tapWasDisabled(epoch: epoch) })
        if let tap {
            // A rebuild starts from the keyboard now. Retained press ownership
            // still balances consumed releases, but missed key-ups must not
            // become held keys in the replacement listener.
            tap.seed(keysDown: Self.keysShownDown())
            updateConsumption()
            tap.start()
        }
        recovery.attached(tap != nil, at: now())
    }

    private func publishListener() {
        let before = listener.problem
        listener.update(recovery.state)
        let recoveredAfterSkip = skippedListenerCheck && recovery.state == .live
        if recoveredAfterSkip { skippedListenerCheck = false }
        if before != listener.problem || recoveredAfterSkip { onListenerProblem(listener.problem) }
    }

    #if DEBUG
    func proveListenerForTesting() {
        _ = recovery.poll(trusted: true, secureInput: false, healthy: true, at: now())
        recovery.receivedFromTap()
        publishListener()
    }

    func listenerActionForTesting(at time: TimeInterval) -> FnListenerRecovery.Action? {
        recovery.poll(trusted: true, secureInput: false, healthy: true, at: time)
    }
    #endif

    private func tapReceived(epoch: Int?) -> Bool {
        guard epoch == nil || epoch == tapEpoch else { return false }
        recovery.receivedFromTap()
        publishListener()
        return true
    }

    private func firstDelivery(_ input: Monitored) -> Bool {
        guard let time = input.time, time > 0 else { return true }
        let kind: Int = switch input.kind {
        case .modifiers: 0
        case .keyDown: 1
        case .keyUp: 2
        case .mouseDown: 3
        case .scroll: 4
        }
        let stamp = InputStamp(kind: kind, code: input.keyCode, flags: input.flags, time: time)
        guard !recentInputs.contains(stamp) else { return false }
        if input.kind == .modifiers || Self.isKey(input) {
            // A delayed fallback press must not follow its already handled
            // release when the tap loses proof between the two deliveries.
            guard time >= (latestKeyTime[input.keyCode] ?? 0) else { return false }
            latestKeyTime[input.keyCode] = time
        }
        recentInputs.append(stamp)
        if recentInputs.count > 128 { recentInputs.removeFirst() }
        return true
    }

    /// A key, release, click or modifier change a monitor saw, copied out
    /// of its event so that it can cross to the main actor.
    struct Monitored: Equatable, Sendable {
        enum Kind: Sendable { case keyDown, keyUp, mouseDown, scroll, modifiers }
        let kind: Kind
        let keyCode: UInt16
        let flags: UInt
        /// A key down that is a held key's auto-repeat.
        let isRepeat: Bool
        /// A Tab the proposal tap consumed never reached the focused field.
        let proposalTab: Bool
        var time: TimeInterval? = nil

        init(kind: Kind, keyCode: UInt16 = 0, flags: UInt = 0, isRepeat: Bool = false, proposalTab: Bool = false) {
            self.kind = kind
            self.keyCode = keyCode
            self.flags = flags
            self.isRepeat = isRepeat
            self.proposalTab = proposalTab
        }

        /// Nil for an event the monitors do not watch. A click has no key
        /// code, and asking for one raises, so it is not read.
        init?(_ event: NSEvent) {
            let flags = event.modifierFlags.rawValue
            switch event.type {
            case .keyDown: self.init(kind: .keyDown, keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat)
            case .keyUp: self.init(kind: .keyUp, keyCode: event.keyCode, flags: flags)
            case .scrollWheel: self.init(kind: .scroll, flags: flags)
            case .flagsChanged: self.init(kind: .modifiers, keyCode: event.keyCode, flags: flags)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: self.init(kind: .mouseDown, flags: flags)
            default: return nil
            }
            time = event.timestamp
        }
    }

    /// The handler the global monitor is given. It is built outside the
    /// main actor, so Swift cannot take it for main-actor code and trap
    /// when AppKit calls it from another queue; `received` reaches the
    /// main actor.
    nonisolated static func globalMonitor(for hold: HoldKey) -> @Sendable (NSEvent) -> Void {
        { [weak hold] event in
            if let input = Monitored(event) { hold?.received(input) }
        }
    }

    /// The handler the local monitor is given, built the same way.
    nonisolated static func localMonitor(for hold: HoldKey) -> @Sendable (NSEvent) -> NSEvent? {
        { [weak hold] event in
            guard let hold, let input = Monitored(event) else { return event }
            return hold.receivedInWindow(input) ? nil : event
        }
    }

    /// Where both monitors hand what they saw. AppKit calls its monitors on
    /// the main thread, where this acts at once; from any other queue it
    /// goes to the main queue first, in order.
    nonisolated func received(_ input: Monitored) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(input) } }
            return
        }
        MainActor.assumeIsolated { handle(input) }
    }

    /// The local monitor's: also whether Intention's own window must not get
    /// the event, which holds only for a key during a recording. It is read
    /// before handling, since the press that ends a recording, such as
    /// Escape, is the recording's too. Off the main thread the window gets
    /// everything.
    nonisolated func receivedInWindow(_ input: Monitored) -> Bool {
        guard Thread.isMainThread else {
            received(input)
            return false
        }
        return MainActor.assumeIsolated {
            let keeps = recorder != nil && (input.kind == .keyDown || input.kind == .keyUp)
            handle(input)
            return keeps
        }
    }

    /// What a monitor saw. Once there is a tap, it reports every modifier
    /// change, key and click itself, in the order they came, and the
    /// monitors' copies, which reach the main actor by another route, are
    /// left alone; except that while Settings records, keys reach the
    /// recorder from the monitors, in the same turn the local monitor keeps
    /// them from Intention's window, as Escape must be kept when it cancels.
    private func handle(_ input: Monitored) {
        // A monitor can be delivered before the tap's main-queue hop. Give
        // that hop a short head start, then accept any unmatched input.
        if recovery.tapProven, !(recorder != nil && Self.isKey(input)) {
            scheduleMonitorFallback(0.08) { [weak self] in
                self?.monitorFallback(input)
            }
        } else { monitorFallback(input) }
    }

    private func monitorFallback(_ input: Monitored) {
        let fromGap = tap != nil && input.time.map { $0 < tapStartedAt } == true
        if let tap, fromGap {
            // A monitor delivery from the gap can queue until after the new
            // tap is installed. Reconcile it under that tap's own lock too.
            tap.observePassed(input)
        } else if tap == nil { retainedPresses?.observePassed(input) }
        guard firstDelivery(input) else { return }
        if fromGap, reconcileLateGapInput(input) { return }
        recovery.receivedFromMonitor(at: now(), observingKeys: recorder == nil
            && (Self.isKey(input) || input.kind == .modifiers))
        publishListener()
        apply(input, fromMonitor: true)
    }

    /// A passed key from before the current trigger still updates what is
    /// down, but cannot turn that newer press into a shortcut.
    func reconcileLateGapInput(_ input: Monitored) -> Bool {
        guard let time = input.time, let latestTriggerTime, time < latestTriggerTime else { return false }
        if Self.isKey(input) { detector.observePassedKey(input.keyCode, down: input.kind == .keyDown) }
        return true
    }

    private static func isKey(_ input: Monitored) -> Bool {
        input.kind == .keyDown || input.kind == .keyUp
    }

    var onMouseDown: () -> Void = {}
    var onScroll: () -> Void = {}

    private func apply(_ input: Monitored, fromMonitor: Bool = false) {
        let flags = NSEvent.ModifierFlags(rawValue: input.flags)
        if input.kind == .keyDown, !input.proposalTab { pressed(keyCode: input.keyCode, flags: flags, isRepeat: input.isRepeat) }
        // Only monitors without a tap need this fallback. An Escape the
        // tap let through keeps that decision even if an email became
        // pending before its queued delivery reached the main actor.
        if fromMonitor, recorder == nil, input.kind == .keyDown,
           input.keyCode == KeyClaims.escape, !input.isRepeat, takesEscape { onEscape() }
        switch input.kind {
        case .keyDown: keyDown(keyCode: input.keyCode, flags: flags, isRepeat: input.isRepeat)
        case .keyUp: keyUp(keyCode: input.keyCode)
        case .mouseDown:
            onMouseDown()
            mouseDown(flags: flags)
        case .scroll:
            cancelPending()
            if !held { gesture.shortcut() }
            onScroll()
        case .modifiers: modifiersChanged(Delivery(keyCode: input.keyCode, flags: flags.rawValue, time: input.time))
        }
    }

    /// Reports a key press to `keyPressed`, and Escape's own press to
    /// `escapePressed`, before it is handled.
    private func pressed(keyCode: UInt16, flags: NSEvent.ModifierFlags = [], isRepeat: Bool) {
        keyPressed(keyCode, flags)
        if keyCode == KeyClaims.escape, !isRepeat {
            cancelPending()
            escapePressed()
        }
    }

    /// A key or click the tap let through, or a Tab it took while a reply
    /// proposal's card shows, from its own thread, behind the modifier
    /// changes it handed over before it. A taken Tab goes to the trigger's
    /// rules as one let through does, so a Tab held while a pair goes down
    /// keeps the pair a shortcut, and its press then reports `generation`
    /// to `tabTaken`. While Settings records, the monitors hand the
    /// recorder its keys instead.
    nonisolated func tapInput(_ input: Monitored, tabTaken generation: UInt64? = nil, epoch: Int? = nil) {
        inFlight.add()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.inFlight.remove()
                guard self.tapReceived(epoch: epoch) else {
                    // A swallowed Tab still belongs to the proposal whose
                    // generation was captured before this tap was retired.
                    if let generation { self.tabTaken(generation) }
                    return
                }
                if (self.recorder == nil || !Self.isKey(input)), self.firstDelivery(input) { self.apply(input) }
                if let generation { self.tabTaken(generation) }
            }
        }
    }

    /// One modifier change as the tap saw it: its key and flags, the
    /// hardware keyboard's flags as the tap read them, which already show
    /// the change, whether the keyboard itself sent it, and which press of
    /// the trigger it belongs to (`KeyClaims.generation`).
    struct Delivery: Sendable {
        var keyCode: UInt16
        var flags: UInt
        var keyboard: UInt? = nil
        var fromKeyboard = false
        var generation = 0
        /// No key other than a modifier was down at this change, as the
        /// tap counted them in the events' order (`KeyClaims.keysClear`);
        /// nil from a monitor, where the rules count for themselves.
        var keysClear: Bool? = nil
        var time: TimeInterval? = nil
        var tapOwned = false
    }

    /// The tap's own thread hands each modifier change here.
    nonisolated func tapDelivered(_ delivery: Delivery, epoch: Int? = nil) {
        inFlight.add()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.inFlight.remove()
                let current = self.tapReceived(epoch: epoch)
                // Retirement cannot discard the release already taken for
                // the current hold, and cannot apply it to a newer press.
                let ownsRelease = epoch != nil && epoch == self.holdTapEpoch
                    && delivery.generation == self.holdGeneration
                    && self.key.contains(keyCode: delivery.keyCode)
                    && !self.key.isDown(in: [delivery.flags])
                    && (self.held || self.detector.arming)
                guard current || ownsRelease else { return }
                var input = Monitored(kind: .modifiers, keyCode: delivery.keyCode, flags: delivery.flags)
                input.time = delivery.time
                if self.firstDelivery(input) { self.modifiersChanged(delivery, epoch: epoch) }
            }
        }
    }

    nonisolated func tapDelivered(keyCode: UInt16, flags: UInt) {
        tapDelivered(Delivery(keyCode: keyCode, flags: flags))
    }

    /// The tap's thread hands over each key it took for dictation, with
    /// the press it came with and Escape's cancellation target at that press.
    nonisolated func tapClaimed(_ claim: KeyClaims.Claim, generation: Int = 0,
                               cancellation: (@Sendable @MainActor () -> Void)? = nil, epoch: Int? = nil) {
        let cancellation = cancellation ?? escapeAction.withLock { $0 }
        inFlight.add()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.inFlight.remove()
                // An Escape already swallowed by a retired tap still cancels
                // its captured owner. It cannot prove the new tap is live.
                if !self.tapReceived(epoch: epoch) {
                    if claim == .escape { cancellation() }
                    return
                }
                self.claimed(claim, generation: generation, cancellation: cancellation)
            }
        }
    }

    /// A key the tap took: Space with the key held, or Escape.
    func claimed(_ claim: KeyClaims.Claim, generation: Int = 0,
                 cancellation: (@Sendable @MainActor () -> Void)? = nil) {
        pressed(keyCode: claim == .escape ? KeyClaims.escape : KeyClaims.space, isRepeat: false)
        switch claim {
        case .handsFree:
            guard handsFreeEnabled else { return }
            // A taken key can queue behind a shortcut's rejection. Keep
            // that decision with its press, rather than starting afterward.
            let alreadyHandsFree = recording && handsFreeHandled == generation
            handsFreeHandled = generation
            guard generation == self.generation, gesture.inProgress || alreadyHandsFree else { return }
            act(detector.space())
            if held, watch == nil { holdStarted() }
            if recording {
                publishedHold = true
                tap?.held(true, generation: generation)
            } else { withdrawHold() }
        case .escape: (cancellation ?? onEscape)()
        }
    }

    /// The tap's thread says macOS turned the tap off for a moment.
    nonisolated func tapWasDisabled(epoch: Int? = nil) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard epoch == nil || epoch == self.tapEpoch else { return }
                self.recovery.request(.disabled, at: self.now())
                self.publishListener()
                self.inputMayHaveBeenLost()
            }
        }
    }

    /// The keys other than modifiers the keyboard state shows down now, read
    /// once when the tap begins and kept as the tap keeps its own.
    nonisolated static func keysShownDown() -> Set<UInt16> {
        Set((0..<128).map(UInt16.init).filter { !(54...63).contains($0) && keyboardShowsDown($0) })
    }

    /// Whether the keyboard state shows a key down: the hardware state for
    /// a real key, the session state for one another process posted.
    nonisolated static func keyboardShowsDown(_ keyCode: UInt16) -> Bool {
        [CGEventSourceStateID.hidSystemState, .combinedSessionState].contains { CGEventSource.keyState($0, key: CGKeyCode(keyCode)) }
    }

    /// macOS disabled the tap for a moment, and a release in that moment
    /// would be lost. A pair still waiting out its arm delay is dropped
    /// unless the keyboard state still shows both its keys down, so a lost
    /// release cannot turn into a press. A hold is left to the keyboard
    /// watch, which now counts the key as having been down, so a release in
    /// that moment ends it once the keyboard has shown the key up for
    /// `unseenReleaseWait`, after anything the tap took before.
    private func inputMayHaveBeenLost() {
        // A missed click can leave the body and selection unchanged. Use
        // its cancellation path before repairing the dictation hold.
        onMouseDown()
        if detector.arming, !key.isDown(in: keyboardFlags()) { return dropArming() }
        // A timeout is not evidence of a release. Keep the evidence from
        // the press, and let the keyboard watch confirm an actual release.
        AppLog.dictation("key.tapReenabled")
    }

    /// The modifier flags the keyboard shows now: the hardware state for a
    /// real key, the session state for one another process posted. The
    /// checks give a made-up keyboard.
    var keyboardFlags: () -> [UInt] = {
        [CGEventSourceStateID.hidSystemState, .combinedSessionState].map { UInt(CGEventSource.flagsState($0).rawValue) }
    }

    /// What the tap takes from now on: Fn's presses, Space with the key
    /// held and Escape. A key already down keeps its own answer until it
    /// comes up; see `ConsumedHolds` and `KeyClaims`. While Settings
    /// records, Space and Escape go to the recorder like any key.
    private func updateConsumption() {
        let recording = recorder != nil
        tap?.configure(consumed: recording ? Modifier.function.keyCode : key.consumedKeyCode(dictationAvailable: dictationAvailable),
                       trigger: key, takesSpace: takesSpace,
                       escapeCancels: takesEscape, escapeCancellation: onEscape)
        tap?.takeTab(tabGeneration)
    }

    /// Takes a plain Tab (key code 48, no modifiers) from the app while set,
    /// remembers that press so its release and any autorepeat are taken
    /// too, and reports it through `tabTaken` with the generation it was
    /// set with. Nil stops taking Tab; a press already taken still has its
    /// release taken. Without the tap nothing is taken and `tabTaken`
    /// never runs.
    func takeTab(generation: UInt64?) {
        tabGeneration = generation
        tap?.takeTab(generation)
    }

    /// A modifier went down or came up, from a monitor until there is a tap.
    func modifiersChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        modifiersChanged(Delivery(keyCode: keyCode, flags: flags.rawValue))
    }

    /// A modifier change from the tap. Whether the trigger's keys are
    /// physically down is read from the change itself when the keyboard
    /// sent it, and otherwise from the keyboard's state with it, or now.
    func modifiersChanged(_ delivery: Delivery, epoch: Int? = nil) {
        if key.contains(keyCode: delivery.keyCode), let time = delivery.time { latestTriggerTime = time }
        if delivery.keyCode == 63 {
            diagnostic(.fnReceived, delivery.flags & Modifier.function.deviceMask != 0 ? .pressed : .released)
        }
        // Setup's key check: the trigger's own presses prove it, and any
        // other modifier going down is named, so a person holding another
        // app's shortcut learns which key Intention saw. Keys pressed for the
        // recorder are a new shortcut being chosen, not a check of this one.
        let at = delivery.time ?? now(), date = Date().addingTimeInterval((delivery.time ?? now()) - now())
        if recorder == nil {
            if key.contains(keyCode: delivery.keyCode) {
                // Pressed over another key already down, by the tap's count
                // at the event's own time, it is a shortcut's, which the
                // rules reject too. A monitor's copy carries no count, and
                // the rules settle stale keys only later in this call, so
                // it is taken as clear.
                let clear = delivery.keysClear ?? true
                listener.receivedTrigger(down: key.isAlone(in: delivery.flags) && clear, at: at, date: date)
            } else if let other = Modifier(keyCode: delivery.keyCode), delivery.flags & other.deviceMask != 0 {
                listener.receivedOtherKey(other == .function ? "fn" : other.title.lowercased(), date: date)
            }
        }
        eventTime = delivery.time
        defer { eventTime = nil }
        if !held, !detector.arming {
            holdUsesTap = delivery.tapOwned
            holdTapEpoch = epoch
            holdGeneration = delivery.generation
        }
        let keyCode = delivery.keyCode, generation = delivery.generation
        // Timestamped owner transitions retain their event-time flags:
        // hardware may already include the following press. Unrelated
        // events cannot release the trigger; the watch recovers lost ups.
        let flags = Self.modifierFlags(key: key, delivery: delivery)
        if let recorder {
            // A press on its way when Settings began recording is Settings'.
            tap?.held(false, generation: generation)
            return recorder(.modifiers(keyCode: keyCode, flags: flags))
        }
        let shows = delivery.fromKeyboard && key.isDown(in: [delivery.flags])
            || key.isDown(in: delivery.keyboard.map { [$0] } ?? keyboardFlags())
        // Kept from the change that completed the trigger for as long as it
        // is arming or held, so a later change, such as Caps Lock, read
        // after a release that went unseen, does not erase it.
        keyboardShowsKey = held || detector.arming ? keyboardShowsKey || shows : shows
        // Fresh evidence the key is down, as a press again whose release
        // went unseen, starts the wait for an unseen release over.
        if shows { readingsUp = 0 }
        self.generation = generation
        act(detector.modifiersChanged(keyCode: keyCode, flags: flags, keysClear: delivery.keysClear))
    }

    /// The tap's hardware snapshot can disprove a spurious Fn-up flag.
    /// Posted test events keep their own flags, independent of hardware.
    nonisolated static func modifierFlags(key: Key, delivery: Delivery) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: delivery.flags)
        if delivery.time == nil, key == .function, delivery.keyCode == 63, delivery.fromKeyboard,
           key.isDown(in: delivery.keyboard.map { [$0] } ?? []) { flags.insert(.function) }
        return flags
    }

    func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool = false) {
        if let recorder { return recorder(.key(keyCode: keyCode, isRepeat: isRepeat)) }
        // Globe is Fn's companion event, not a second physical key.
        guard keyCode != KeyClaims.globe else { return }
        // A key typed with the trigger held is a shortcut, which the trigger
        // rejects, so setup's check does not count that press either.
        listener.discardPress()
        if !held { gesture.shortcut() }
        act(detector.keyDown(keyCode: keyCode, flags: flags))
    }

    func keyUp(keyCode: UInt16) {
        detector.keyUp(keyCode: keyCode)
        recorder?(.keyUp(keyCode: keyCode))
    }

    func mouseDown(flags: NSEvent.ModifierFlags) {
        guard recorder == nil else { return }
        if !held { gesture.shortcut() }
        act(detector.mouseDown(flags: flags))
    }

    private func act(_ event: HoldDetector.Event?) {
        switch event {
        case .arm?:
            // Both waits start at the native press, even if delivery was late.
            let elapsed = max(0, now() - (eventTime ?? now()))
            let remaining = max(0, armDelay - elapsed)
            prepareGesture()
            arm?.invalidate()
            if remaining == 0 { armDelayElapsed() }
            else {
                let timer = Timer(timeInterval: remaining, repeats: false) { @Sendable [weak self] _ in
                    MainActor.assumeIsolated { self?.armDelayElapsed() }
                }
                // Common modes, so a pair pressed while a menu is open still counts.
                RunLoop.main.add(timer, forMode: .common)
                arm = timer
            }
        case .press?:
            // Before the press is handed on, which can hold the main actor
            // for a second while a headset's microphone opens.
            holdStarted()
            if !gesture.inProgress { prepareGesture() }
            // Confirmation may already have fired while this pair was
            // still arming, when a delayed delivery made both timers due.
            else if gestureTimer == nil { confirmHold() }
        case .release?:
            setPending(false)
            if gesture.waiting, key == .function {
                diagnostic(.fnShort, nil)
                if listener.offerShortHint(at: now()) { onShortHold() }
            }
            holdStopped()
            gestureTimer?.invalidate()
            gestureTimer = nil
            if let action = gesture.release(at: eventTime ?? now()) { perform(action) }
        case .otherKey?:
            setPending(false)
            if key == .function, gesture.waiting, !recording { diagnostic(.fnRejected, .shortcut) }
            if !holdWasConfirmed, !recording { withdrawHold() }
            gesture.shortcut()
            gestureTimer?.invalidate()
            gestureTimer = nil
            onOtherKey()
        case .handsFree?:
            setPending(false)
            gesture.space()
            gestureTimer?.invalidate()
            gestureTimer = nil
            onHandsFree()
        case .click?:
            setPending(false)
            if key == .function, gesture.waiting, !recording { diagnostic(.fnRejected, .click) }
            if !holdWasConfirmed, !recording { withdrawHold() }
            gesture.shortcut()
            gestureTimer?.invalidate()
            gestureTimer = nil
            onClick()
        case nil: break
        }
        if gesture.inProgress, !held, !detector.arming, event != .release {
            setPending(false)
            gesture.shortcut()
            gestureTimer?.invalidate()
            gestureTimer = nil
        }
        // Whatever ended the wait must not fire for a later pair press.
        if !detector.arming {
            arm?.invalidate()
            arm = nil
        }
    }

    private func prepareGesture() {
        holdWasConfirmed = false
        let pressedAt = eventTime ?? now()
        let alone = detector.arming || detector.pressAlone
        if key == .function, !alone, !recording { diagnostic(.fnRejected, .shortcut) }
        let action = gesture.press(at: pressedAt, alone: alone, recording: recording)
        if let action { perform(action) }
        else if gesture.waiting {
            guard dictationAvailable, recorder == nil else { return cancelPending() }
            pendingBegan = pressedAt
            AppLog.pressStage("keydown", at: pressedAt, since: pressedAt)
            setPending(true)
            let remaining = max(0, holdDelay - max(0, now() - pressedAt))
            if remaining == 0 { confirmHold() }
            else {
                let timer = Timer(timeInterval: remaining, repeats: false) { @Sendable [weak self] _ in
                    MainActor.assumeIsolated { self?.confirmHold() }
                }
                RunLoop.main.add(timer, forMode: .common)
                gestureTimer = timer
            }
        }
    }

    static func instructions(for key: Key) -> String {
        handsFreeAvailable
            ? "Hold to dictate. Double-tap or " + FirstDictation.keycap(key) + " + Space for hands-free."
            : "Hold it anywhere you can type, speak, and let go."
    }

    private func confirmHold() {
        gestureTimer?.invalidate()
        gestureTimer = nil
        guard held, gesture.waiting else { return }
        // Hardware can advance while read, and the tap can queue a
        // shortcut during that read. Check deliveries afterward, then
        // commit under the same lock that rejects shortcut candidates.
        let down = holdDelay == 0 || !keyboardShowsKey || key.isDown(in: keyboardFlags())
            || key == .function && keyboardShowsKeyDown(63)
        if !inFlight.isEmpty {
            let timer = Timer(timeInterval: 0.01, repeats: false) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.confirmHold() }
            }
            RunLoop.main.add(timer, forMode: .common)
            gestureTimer = timer
            return
        }
        guard down else {
            release()
            gesture.reset()
            return
        }
        if holdUsesTap, let tap, !tap.held(true, generation: generation) {
            gesture.shortcut()
            withdrawHold()
            return
        }
        guard let action = gesture.confirm() else { return }
        holdWasConfirmed = true
        if let began = pendingBegan { AppLog.pressStage("holdConfirmed", at: now(), since: began) }
        setPending(false)
        publishedHold = detector.pressAlone
        perform(action)
    }

    private func perform(_ action: DictationGesture.Action) {
        switch action {
        case .press:
            if !recording, pressOnlyShows() {
                withdrawHold()
                return
            }
            onPress()
            if !recording {
                if key == .function { diagnostic(.fnRejected, .unavailable) }
                withdrawHold()
            }
        case .release: onRelease()
        case .handsFree: if handsFreeEnabled { onHandsFree() }
        }
    }

    /// A pair has been down alone for its arm delay. One whose release went
    /// unseen meanwhile, which the keyboard showed down when it completed
    /// and shows up now, does not start.
    private func armDelayElapsed() {
        if keyboardShowsKey, !key.isDown(in: keyboardFlags()) { return dropArming() }
        act(detector.armDelayElapsed())
    }

    /// Ends a pair's wait whose release went unseen, and takes the pair's
    /// keys from the keyboard, so the key that came up starts a new wait
    /// when it comes down again.
    private func dropArming() {
        listener.endHold()
        act(detector.release())
        detector.keyboardShows(NSEvent.ModifierFlags(rawValue: keyboardFlags().first ?? 0))
    }

    /// The trigger is held from now: the tap may take Space with it, and
    /// the keyboard is watched for a release that never arrives, with
    /// the keyboard as it was at the change that completed the trigger as
    /// its first reading, since a busy main actor may not read it again
    /// before the key is up.
    private func holdStarted() {
        // A press with another modifier or key held is a shortcut's, and
        // Space with it is the shortcut's too.
        publishedHold = detector.pressAlone && (recording || holdDelay == 0)
        if publishedHold { tap?.held(true, generation: generation) }
        keyboardShowedDown = keyboardShowsKey
        readingsUp = 0
        watch?.invalidate()
        let timer = Timer(timeInterval: watchInterval, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.checkKeyboard() }
        }
        // Common modes, so a menu that is open does not stop it.
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    /// Tells the tap the press held now is no dictation's, so Space with it
    /// types as usual.
    private func withdrawHold() {
        setPending(false)
        publishedHold = false
        tap?.held(false, generation: generation)
    }

    private func holdStopped() {
        publishedHold = false
        tap?.held(false, generation: generation)
        watch?.invalidate()
        watch = nil
        keyboardShowedDown = false
        readingsUp = 0
    }

    /// Ends the hold when the keyboard, having shown the key down, has
    /// shown it up for `unseenReleaseWait` and no release has come.
    private func checkKeyboard() {
        guard held else { return holdStopped() }
        // Read before asking what is on its way, so a change the tap hands
        // over while the keyboard is read is counted as on its way.
        let down = key.isDown(in: keyboardFlags()) || key == .function && keyboardShowsKeyDown(63)
        guard inFlight.isEmpty else {
            readingsUp = 0
            return
        }
        if down {
            keyboardShowedDown = true
            readingsUp = 0
        } else if keyboardShowedDown {
            readingsUp += 1
            guard Double(readingsUp) * watchInterval >= unseenReleaseWait else { return }
            // The tap answers under the lock it takes Space under: not while
            // a Space taken with this press is still on its way here, and
            // otherwise it withdraws the press first, so no Space can be
            // taken for it between this answer and the release.
            if holdUsesTap, let tap, !tap.withdraw(generation: generation, handled: handsFreeHandled) { return }
            AppLog.dictation("key.releaseUnseen")
            release()
            // The rules missed the release too: they take the keyboard as it
            // is, so a pair whose one key is still down arms again when the
            // other comes down.
            detector.keyboardShows(NSEvent.ModifierFlags(rawValue: keyboardFlags().first ?? 0))
        }
    }

    private func release() {
        setPending(false)
        // A release the keyboard watch recovered, or one forced on the
        // trigger, shows setup's shortcut up again. Only a release that
        // arrives proves the key, so the pending press stays for one still
        // on its way.
        listener.endHold()
        act(detector.release())
    }
}

/// The rules of hold-to-talk, with nothing of AppKit's event delivery in
/// them: what each modifier change, key press and click means for the
/// chosen trigger. `HoldKey` feeds it what it sees and acts on the answer.
///
/// A single key is held from its own press to its own release. A
/// combination is held from the moment all of its modifiers have been down
/// alone, with no other modifier and no other key, for `armDelay`, until
/// any of them comes up. Until the delay has passed the pair is only
/// arming: a key, a click or a third modifier in that time is a shortcut
/// such as Control+Option+Left, and ends the wait with no event at all, so
/// nothing opens the microphone or reads the field for it. Only the change
/// that completes the pair starts a wait, so a pair whose wait ended that
/// way, or that was completed over another key or modifier, stays a
/// shortcut's until one of its own keys comes up and it is pressed again.
/// In either case another key going down while the trigger is held is
/// reported, and dictation decides what a key pressed that soon means.
/// A tap waits for another tap; a hold opens audio only after 300 ms.
/// Times are monotonic seconds, supplied by HoldKey or a test. A shortcut
/// clears the candidate so a modifier used for typing cannot start audio.
struct DictationGesture {
    enum Action: Equatable { case press, release, handsFree }
    static let window: TimeInterval = 0.3
    private var pressedAt: TimeInterval?
    private var firstTap: TimeInterval?
    private var secondTap = false
    private var activeHold = false
    private var endingRecording = false
    var waiting: Bool { pressedAt != nil && !activeHold && !endingRecording }
    var inProgress: Bool { pressedAt != nil }

    mutating func press(at time: TimeInterval, alone: Bool, recording: Bool) -> Action? {
        guard alone else { reset(); return nil }
        pressedAt = time
        secondTap = firstTap.map { time - $0 <= Self.window } ?? false
        firstTap = nil
        endingRecording = recording
        return recording ? .press : nil
    }

    mutating func confirm() -> Action? {
        guard waiting else { return nil }
        activeHold = true
        secondTap = false
        return .press
    }

    mutating func release(at time: TimeInterval) -> Action? {
        guard let pressedAt else { return nil }
        defer { self.pressedAt = nil; activeHold = false; endingRecording = false; secondTap = false }
        if activeHold || endingRecording { firstTap = nil; return .release }
        guard time - pressedAt < Self.window else { firstTap = nil; return nil }
        if secondTap { firstTap = nil; return .handsFree }
        firstTap = pressedAt
        return nil
    }

    mutating func space() { reset() }
    mutating func shortcut() {
        // Once a hold is confirmed, other input cannot end its recording.
        firstTap = nil
        secondTap = false
        if !activeHold { pressedAt = nil; endingRecording = false }
    }
    mutating func reset() {
        pressedAt = nil
        firstTap = nil
        secondTap = false
        activeHold = false
        endingRecording = false
    }
}

struct HoldDetector {
    enum Event: Equatable {
        /// A pair is down alone; `armDelayElapsed` is due after `armDelay`.
        case arm
        case press, release, otherKey
        /// Space went down while the trigger was held.
        case handsFree
        /// A click with the trigger held, as Command-click is with Right
        /// Command chosen.
        case click
    }

    /// How long a pair must be held alone before it is a dictation request.
    /// A shortcut's letter or arrow follows its modifiers within about 100
    /// ms when typed as one motion, and keyboard firmware has long used 200
    /// ms as the line between a tap and a hold (QMK's and ZMK's default
    /// tapping term). Each dictation with a pair starts this much later
    /// than one with a single key, which has no such wait; speech begins
    /// later than that after a press-to-talk key goes down, and the window
    /// `DictationController` drops a shortcut within is three times longer,
    /// so a shortcut typed slowly after the pair is still dropped.
    static let armDelay: TimeInterval = 0.2

    var key: HoldKey.Key {
        // A pair chosen while its keys are down must be let go first.
        didSet { if key != oldValue { pairDown = true } }
    }
    private(set) var held = false
    /// A pair is down alone and its arm delay is running.
    private(set) var arming = false
    /// The latest press had the key down on its own: a pair always does,
    /// and a single key when no other modifier or key was held with it.
    private(set) var pressAlone = true
    /// Whether every key of the pair was down at the last modifier change.
    /// It starts out true, as if the pair were already down, so a pair
    /// held when watching began must be let go before it can start.
    private var pairDown = true
    /// The keys other than modifiers that are down, by key code, from
    /// their presses and releases; each is forgotten when it comes up. A
    /// combination completed over any of them is a shortcut, such as
    /// Control+A with Option added, and does not start.
    private var keysDown: Set<UInt16> = []
    /// The keys other than modifiers down now, for the tap to start from.
    var keysHeld: Set<UInt16> { keysDown }
    /// Whether the keyboard still shows a key down. A release can go
    /// unseen, as secure input or a locked screen hides key events, so a
    /// key the keyboard shows up is forgotten before a pair is let start.
    /// `HoldKey` asks the keyboard; left as it is, a key stays down until
    /// its release is seen.
    var keyboardShowsDown: (UInt16) -> Bool = { _ in true }

    /// The modifier bits a combination is compared against. Caps Lock is
    /// left out, since it stays set while the light is on.
    static let modifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]

    init(key: HoldKey.Key) {
        self.key = key
    }

    /// `keysClear`, when the tap says, is whether any key other than a
    /// modifier was down at this change in the events' order; without it
    /// the rules use their own count, checked against the keyboard. The
    /// tap's word is taken over the keyboard's, which by the time the main
    /// actor reads it may already show a release still on its way here.
    mutating func modifiersChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags, keysClear: Bool? = nil) -> Event? {
        let down = flags.intersection(Self.modifiers)
        if key.isCombination {
            // Unrelated modifier changes cannot release the pair either.
            if (held || arming), !key.contains(keyCode: keyCode) {
                if down.subtracting(NSEvent.ModifierFlags(rawValue: key.mask)).isEmpty { return nil }
                if arming { arming = false; return nil }
                return .otherKey
            }
            let wanted = NSEvent.ModifierFlags(rawValue: key.mask)
            let wasDown = pairDown
            pairDown = down.isSuperset(of: wanted)
            if held {
                guard pairDown else { return release() }
                // Another modifier with it is a shortcut in the making.
                return down == wanted ? nil : .otherKey
            }
            if arming {
                // A key let go or a third modifier added ends the wait. A
                // change that leaves the pair alone, such as Caps Lock, does not.
                if !pairDown { return release() }
                if down != wanted { arming = false }
                return nil
            }
            // Only the press that completes the pair starts a wait. Letting
            // go of a third modifier, or of a key, while the pair stays down
            // leaves the shortcut it was part of as it was.
            guard pairDown, !wasDown, down == wanted, keysClear ?? !anyKeyDown() else { return nil }
            arming = true
            return .arm
        }
        if keyCode == key.keyCode {
            let isDown = flags.rawValue & key.mask != 0
            if isDown, !held {
                held = true
                pressAlone = key.isAlone(in: flags) && (keysClear ?? !anyKeyDown())
                return .press
            } else if !isDown, held {
                return release()
            }
        } else if held {
            // Another event's flags are not this key's release. A missed
            // release is recovered by the hardware watch, after a second.
            guard let modifier = HoldKey.Modifier(keyCode: keyCode),
                  flags.contains(modifier.family.flag) else { return nil }
            return .otherKey
        }
        return nil
    }

    /// Space went down with the trigger held, and the tap took it: the
    /// person wants the dictation to go on once the key is let go.
    mutating func space() -> Event? {
        guard held || arming else { return nil }
        arming = false
        held = true
        pressAlone = true
        return .handsFree
    }

    /// The keyboard shows these modifiers down, read from its state after a
    /// release that never arrived. Only whether a pair's keys are all down
    /// is taken from it; nothing is reported.
    mutating func keyboardShows(_ flags: NSEvent.ModifierFlags) {
        guard key.isCombination else { return }
        pairDown = flags.intersection(Self.modifiers).isSuperset(of: NSEvent.ModifierFlags(rawValue: key.mask))
    }

    /// `armDelay` has passed since `.arm`. The pair is a dictation request
    /// if nothing has ended the wait since.
    mutating func armDelayElapsed() -> Event? {
        guard arming else { return nil }
        arming = false
        held = true
        pressAlone = true
        return .press
    }

    /// Other keys can identify a shortcut before the hold is confirmed.
    /// Their flags cannot release a modifier; the hardware watch recovers
    /// a release that the tap missed.
    mutating func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Event? {
        guard keyCode != KeyClaims.globe else { return nil }
        keysDown.insert(keyCode)
        arming = false
        guard held else { return nil }
        return .otherKey
    }

    mutating func keyUp(keyCode: UInt16) {
        keysDown.remove(keyCode)
    }

    mutating func observePassedKey(_ keyCode: UInt16, down: Bool) {
        guard keyCode != KeyClaims.globe else { return }
        if down { keysDown.insert(keyCode) }
        else { keysDown.remove(keyCode) }
    }

    /// Whether any key other than a modifier is down, once those the
    /// keyboard shows up, whose release was missed, are forgotten.
    private mutating func anyKeyDown() -> Bool {
        keysDown = keysDown.filter(keyboardShowsDown)
        return !keysDown.isEmpty
    }

    /// A click while a pair is arming is a click with those modifiers, such
    /// as Option+Command+click, and ends the wait silently. One while the
    /// key is held is reported as a click with it, such as Command-click on
    /// a link; it is no shortcut's key, since a click on the dot or the
    /// foot while the key is held is a click on dictation's own controls.
    mutating func mouseDown(flags: NSEvent.ModifierFlags) -> Event? {
        arming = false
        guard held else { return nil }
        return .click
    }

    mutating func release() -> Event? {
        let wasArming = arming
        arming = false
        guard held || wasArming else { return nil }
        held = false
        return .release
    }
}

/// Which modifier changes the tap drops. A press of the consumed key is
/// dropped, and so is that press's release, even when what is consumed
/// changed while the key was down; a press let through has its release let
/// through too. So no app sees Fn come up without having seen it go down,
/// or the reverse, when the chosen key, dictation's availability or a
/// recording in Settings changes in the middle of a hold.
struct ConsumedHolds {
    /// The key whose presses are dropped from now on, or nil for none.
    var consumed: UInt16?
    /// The keys whose press was dropped and whose release is still to come.
    private var dropped: Set<UInt16> = []

    mutating func observePassed(keyCode: UInt16) { dropped.remove(keyCode) }

    mutating func drops(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard let modifier = HoldKey.Modifier(keyCode: keyCode) else { return false }
        guard flags.rawValue & modifier.deviceMask == 0 else {
            // A press. One whose release was lost answers afresh.
            guard keyCode == consumed else {
                dropped.remove(keyCode)
                return false
            }
            dropped.insert(keyCode)
            return true
        }
        return dropped.remove(keyCode) != nil
    }
}

/// Which key presses the tap takes besides Fn's own, decided on the tap's
/// thread as each arrives, since a key let through has already reached the
/// app in front. Space is taken when it goes down with the dictation key
/// held, which makes the dictation hands-free, so it neither types a space
/// nor opens a shortcut such as Command-Space; a pair counts as held only
/// once past its arm delay, so Control-Option-Space typed as one motion is
/// still VoiceOver's. Escape is taken while a dictation records or an email
/// write is pending, and cancels the recording first. While Fn is taken,
/// so is the globe key's own key event that
/// macOS sends after a tap of Fn. A key taken going down is taken until it
/// comes up, its repeats included, so no app sees half of a press. Only a
/// key's code and the modifier flags are read; nothing is kept but the
/// codes of the keys down until each comes up, checked against the keyboard
/// at a press of the trigger.
struct KeyClaims {
    enum Claim: Equatable, Sendable {
        /// Space with the dictation key held.
        case handsFree
        /// Escape while a recording can cancel.
        case escape
    }

    /// What the tap does with one key event: takes it out of the stream or
    /// lets it through, and what a press it took asks for.
    struct Answer: Equatable {
        var take: Bool
        var claim: Claim?
    }

    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    /// The globe key's own key code, which macOS sends as a key press and
    /// release after a tap of Fn on keyboards with a globe key.
    static let globe: UInt16 = 179

    /// The dictation key, whose state is followed from every modifier
    /// change whether or not Space is taken now.
    var trigger: HoldKey.Key? {
        didSet {
            guard trigger != oldValue else { return }
            down = false
            pressedEligible = false
            published = false
        }
    }
    /// Whether Space with the key held is taken: dictation can run and
    /// Settings records no key.
    var takesSpace = false
    var escapeCancels = false
    /// The latest Fn press or release was taken, so its globe event is too.
    private(set) var takesGlobe = false
    /// Every key of the trigger is down, from the latest modifier change.
    private var down = false
    /// Gap events older than this press update keys without rejecting it.
    private var pressedAt: TimeInterval?
    /// Counts each time the trigger's keys all come down; `HoldKey` names
    /// the press its hold belongs to by it.
    private(set) var generation = 0
    /// A single key came down on its own while Space could be taken, so a
    /// Space typed right after it, as Fn-Space is, is taken before the main
    /// actor has heard of the press.
    private var pressedEligible = false
    /// The keys other than modifiers the tap let through and has not seen
    /// come up, by code, in the order the events came, so a single key
    /// pressed with one of them held, as A held and then Fn, is no press of
    /// its own, while a Space pressed just after Fn, which the tap has not
    /// yet seen when it handles Fn, is not held against it. Each code is
    /// forgotten when its key comes up, and never stored or logged, as the
    /// hold rules on the main actor keep theirs.
    private var keysDown: Set<UInt16> = []
    /// Whether the keyboard still shows a key down, asked at each press of
    /// the dictation key, so a key whose release the tap never saw is
    /// forgotten; a key the keyboard shows down stays, and a key not yet
    /// seen is never added. Asked only when every release the keyboard
    /// has made came before the press (`releasesPrecede`): a release made
    /// after it is still on its way to the tap, and its key was down at
    /// the press. The tap asks the keyboard; the checks leave every key
    /// down until its release.
    var keyShowsDown: @Sendable (UInt16) -> Bool = { _ in true }
    /// No key other than a modifier is down, in the events' order, as of
    /// the latest modifier change, and the trigger's press, if it is down,
    /// came after the tap knew which keys were held.
    var keysClear: Bool { keysDown.isEmpty && !pressBeforeStart }
    /// Changes stamped at or before this, in the ticks tap events carry,
    /// may have queued for the tap before it knew which keys were held
    /// (`TriggerTap.start`), so the trigger's press among them is never
    /// taken as made alone. A change with no stamp is not judged by it.
    var startedAt: UInt64 = 0
    private var pressBeforeStart = false
    /// The press a Space was taken with for hands-free, as numbered by
    /// `generation`, so the keyboard watch never ends that press's hold
    /// before the main actor has heard of the Space
    /// (`withdraw(generation:handled:)`).
    private(set) var handsFreeGeneration: Int?
    /// `HoldKey` said this press of the trigger is a dictation's hold: a
    /// pair past its arm delay, or a single key pressed on its own, which
    /// covers a press made while dictation could not yet run, as when the
    /// press itself retried a microphone that had failed to open.
    private var published = false
    /// A shortcut rejected this press before the main actor could confirm
    /// it. A delayed confirmation cannot reclaim its Space afterward.
    private var rejected = false
    private var taken: Set<UInt16> = []

    /// Every modifier change the tap sees, each with the whole keyboard's
    /// flags, and whether the tap dropped it. The trigger coming up ends its
    /// hold here at once, before the main actor hears of it. The globe
    /// key's own event, which follows Fn, is taken when Fn's press or
    /// release was, so it goes wherever Fn went, whatever changed between.
    ///
    /// `releasesArrived` says whether every key the keyboard has let go of
    /// so far, it let go of before this change; the tap works it out from
    /// the change's stamp (`releasesPrecede`) and the checks say.
    mutating func modifiersChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags, dropped: Bool = false, stamp: UInt64 = 0,
                                   at time: TimeInterval? = nil,
                                   releasesArrived: () -> Bool = { true }) {
        let time = time ?? (stamp > 0 ? Double(stamp) / 1_000_000_000 : nil)
        if let time, let pressedAt, time < pressedAt { return }
        if keyCode == HoldKey.Modifier.function.keyCode { takesGlobe = dropped }
        guard let trigger else { return }
        if down, !trigger.contains(keyCode: keyCode) {
            if let modifier = HoldKey.Modifier(keyCode: keyCode), flags.contains(modifier.family.flag),
               !trigger.isAlone(in: flags) { rejectCandidate() }
            return
        }
        let now = switch trigger {
        case let .single(modifier): flags.rawValue & modifier.deviceMask != 0
        case .combination: flags.isSuperset(of: trigger.families)
        }
        if now, !down {
            pressedAt = time
            generation += 1
            published = false
            rejected = false
            // Only the key's own press, made on its own: a trigger chosen
            // while its key was down comes down here with another key's
            // change, and must be let go first.
            // The keyboard is read before the releases' timing, so a key
            // let go between the two counts as let go after the press.
            let shownUp = keysDown.filter { !keyShowsDown($0) }
            if !shownUp.isEmpty, releasesArrived() { keysDown.subtract(shownUp) }
            pressBeforeStart = stamp > 0 && stamp <= startedAt
            pressedEligible = trigger.contains(keyCode: keyCode) && takesSpace && trigger.isAlone(in: flags) && keysClear
        }
        if !now {
            pressedEligible = false
            published = false
            pressBeforeStart = false
        }
        down = now
    }

    /// Whether every key the keyboard has let go of so far, it let go of
    /// before a change made `age` seconds ago, given the seconds since the
    /// keyboard state recorded its latest release. That state records a
    /// release a fraction of a millisecond after the stamp its event
    /// carries (measured on October 7, 2026), so a release stamped after
    /// the change never passes; a millisecond's margin leaves a release
    /// that close to the change counted down until its event arrives.
    static func releasesPrecede(age: TimeInterval, sinceLatestRelease: TimeInterval) -> Bool {
        sinceLatestRelease > age + 0.001
    }

    /// The same for a change stamped `stamp` in clock ticks of
    /// `tickSeconds` each. The latest release is asked for before the clock
    /// is read, so time passing between the two counts against the release,
    /// never for it. A change with no stamp, or stamped after now, is
    /// judged as uncertain.
    static func releasesPrecede(stamp: UInt64, latestRelease: () -> TimeInterval, now: () -> UInt64,
                                tickSeconds: Double) -> Bool {
        guard stamp > 0 else { return false }
        let since = latestRelease()
        let now = now()
        guard now >= stamp else { return false }
        return releasesPrecede(age: Double(now - stamp) * tickSeconds, sinceLatestRelease: since)
    }

    /// `HoldKey` says whether the press numbered `generation` is a
    /// dictation's hold. Word about an earlier press is ignored, and one
    /// the tap has seen end since is not taken. A no, as for a press that
    /// was a shortcut's or one Settings took over, also takes back what
    /// the tap had allowed that press before the main actor heard of it.
    @discardableResult
    mutating func held(_ held: Bool, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        published = held && down && !rejected
        if !held { pressedEligible = false }
        return published
    }

    /// A click, scroll or extra modifier before confirmation belongs to
    /// a shortcut. Confirmed held recordings retain their Space command.
    mutating func rejectCandidate() {
        guard !published else { return }
        pressedEligible = false
        rejected = true
    }

    /// Replace the previous listener's key count with the current keyboard
    /// snapshot. Consumed press ownership is retained separately in `taken`.
    mutating func seed(keysDown keys: Set<UInt16>) {
        keysDown = keys.subtracting([Self.globe])
    }

    /// Settings took the keyboard over: whatever press is down now, even
    /// one the main actor has not yet heard of, is no dictation's.
    mutating func withdrawAll() {
        published = false
        pressedEligible = false
    }

    /// The keyboard watch would end the press numbered `generation` as a
    /// release it never saw. False while a Space taken with that press has
    /// not reached the main actor, `handled` naming the latest press whose
    /// Space has; otherwise the press is withdrawn here, so no Space can be
    /// taken for it between this answer and the release.
    mutating func withdraw(generation: Int, handled: Int?) -> Bool {
        if handsFreeGeneration == generation, handled != generation { return false }
        held(false, generation: generation)
        // The keyboard has shown the key up for a second: its release went
        // unseen here too, so its next press is a press of its own.
        if generation == self.generation { down = false }
        return true
    }

    mutating func key(_ keyCode: UInt16, down: Bool, flags: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Answer {
        let answer = answer(keyCode, down: down, flags: flags, isRepeat: isRepeat)
        if !answer.take, keyCode != Self.globe {
            if down {
                keysDown.insert(keyCode)
                pressedEligible = false
                rejectCandidate()
            } else { keysDown.remove(keyCode) }
        }
        if answer.claim == .handsFree { handsFreeGeneration = generation }
        return answer
    }

    mutating func observePassed(keyCode: UInt16, down: Bool, isRepeat: Bool, at time: TimeInterval? = nil) {
        if !down || !isRepeat { taken.remove(keyCode) }
        guard keyCode != Self.globe else { return }
        if down {
            keysDown.insert(keyCode)
            if !(time.flatMap { time in pressedAt.map { time < $0 } } ?? false) {
                pressedEligible = false
                rejectCandidate()
            }
        } else { keysDown.remove(keyCode) }
    }

    private mutating func answer(_ keyCode: UInt16, down: Bool, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> Answer {
        guard down else { return Answer(take: taken.remove(keyCode) != nil, claim: nil) }
        // A repeat keeps its press's answer: one let through is never
        // taken halfway, or the app would see it go down and never come up.
        if isRepeat { return Answer(take: taken.contains(keyCode), claim: nil) }
        // A press whose release was lost answers afresh.
        taken.remove(keyCode)
        let claim: Claim?
        switch keyCode {
        case Self.space where triggerHeld(flags): claim = .handsFree
        case Self.escape where escapeCancels: claim = .escape
        case Self.globe where takesGlobe: claim = nil
        default: return Answer(take: false, claim: nil)
        }
        taken.insert(keyCode)
        return Answer(take: true, claim: claim)
    }

    /// The trigger is down on its own, and Space came with its keys
    /// alone: with another modifier too, as Option-Command-Space with Right
    /// Command chosen, it is a shortcut's.
    private func triggerHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard takesSpace, let trigger, down, trigger.isAlone(in: flags) else { return false }
        return published || pressedEligible
    }
}

/// Which presses of Tab the tap takes while a reply proposal's card shows.
/// A press of Tab with no modifier held, while a generation is set, is
/// taken and reported with that generation; its autorepeats and its
/// release are taken too, even when the generation was cleared while it
/// was down, so the app never sees Tab come up or repeat without having
/// seen it go down. A press let through has its repeats and release let
/// through. Shift-Tab, Option-Tab and every other key pass. Caps Lock is
/// not a modifier here, so Tab with the light on is still taken.
struct TakenTabs {
    static let tabKeyCode: UInt16 = 48

    /// The generation Tab presses are taken for from now on, or nil.
    var generation: UInt64?
    /// A taken press whose release is still to come.
    private var down = false

    mutating func observePassed(keyCode: UInt16, isRepeat: Bool) {
        if keyCode == Self.tabKeyCode, !isRepeat { down = false }
    }

    /// Whether the tap drops this key event, and for a press newly taken,
    /// the generation to report.
    mutating func decide(_ event: TapEvent) -> (drops: Bool, taken: UInt64?) {
        switch event {
        case let .keyDown(keyCode, flags, isRepeat) where keyCode == Self.tabKeyCode:
            if isRepeat { return (down, nil) }
            // A fresh press answers afresh, even if a release was lost.
            down = false
            guard let generation, flags & HoldDetector.modifiers.rawValue == 0 else { return (false, nil) }
            down = true
            return (true, generation)
        case let .keyUp(keyCode) where keyCode == Self.tabKeyCode:
            defer { down = false }
            return (down, nil)
        default:
            return (false, nil)
        }
    }
}

/// A key's press or release as the tap sees it, by key code. Characters
/// are never read.
enum TapEvent: Equatable, Sendable {
    /// `isRepeat` is a held key's autorepeat.
    case keyDown(keyCode: UInt16, flags: UInt, isRepeat: Bool)
    case keyUp(keyCode: UInt16)
}

/// An active event tap at the HID level for modifier changes and key
/// presses. It sees them before any session-level tap and hands each
/// modifier change on, with its key code and flags, and each key it takes
/// for dictation (`KeyClaims`), from its own thread. Presses of the
/// modifier it is told to consume, and their releases, are dropped from
/// the stream after that, and so is a plain Tab while a reply proposal's
/// card shows (`TakenTabs`); every other modifier change and every key it
/// does not take passes through. Key presses are read for their key code,
/// flags and whether they repeat, and nothing else. It runs on its own
/// thread so a busy main thread never holds up the person's keyboard;
/// macOS disables a tap that answers too slowly, and this one turns itself
/// back on.
final class TriggerTap: @unchecked Sendable {
    private let lock = NSLock()
    struct PressState {
        var holds: ConsumedHolds
        var claims: KeyClaims
        var tabs: TakenTabs
        var eventTimes: [UInt16: TimeInterval] = [:]

        mutating func observePassed(_ input: HoldKey.Monitored) {
            guard input.kind == .modifiers || input.kind == .keyDown || input.kind == .keyUp else { return }
            if let time = input.time {
                guard time > (eventTimes[input.keyCode] ?? 0) else { return }
                eventTimes[input.keyCode] = time
            }
            if input.kind == .modifiers {
                holds.observePassed(keyCode: input.keyCode)
                claims.modifiersChanged(keyCode: input.keyCode, flags: NSEvent.ModifierFlags(rawValue: input.flags), at: input.time)
            } else {
                claims.observePassed(keyCode: input.keyCode, down: input.kind == .keyDown, isRepeat: input.isRepeat, at: input.time)
                tabs.observePassed(keyCode: input.keyCode, isRepeat: input.isRepeat)
            }
        }
    }
    private var eventTimes: [UInt16: TimeInterval] = [:]
    private var holds = ConsumedHolds()
    private var claims = KeyClaims()
    private var tabs = TakenTabs()
    private let deliver: @Sendable (HoldKey.Delivery) -> Void
    private let claimed: @Sendable (KeyClaims.Claim, Int, @escaping @Sendable @MainActor () -> Void) -> Void
    private var escapeCancellation: @Sendable @MainActor () -> Void = {}
    /// A key or click handed on, with the generation of a Tab press taken
    /// for a reply proposal.
    private let input: @Sendable (HoldKey.Monitored, UInt64?) -> Void
    private let disabled: @Sendable () -> Void
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var stopped = false
    private var heartbeat: TimeInterval = 0

    /// Nil when macOS refuses the tap, as it does without Accessibility.
    /// `disabled` runs each time macOS turned the tap off, after it is back.
    /// It handles nothing until `start`.
    init?(presses: PressState? = nil, deliver: @escaping @Sendable (HoldKey.Delivery) -> Void,
          claimed: @escaping @Sendable (KeyClaims.Claim, Int, @escaping @Sendable @MainActor () -> Void) -> Void,
          input: @escaping @Sendable (HoldKey.Monitored, UInt64?) -> Void,
          disabled: @escaping @Sendable () -> Void) {
        self.deliver = deliver
        self.claimed = claimed
        self.input = input
        self.disabled = disabled
        if let presses {
            holds = presses.holds
            claims = presses.claims
            tabs = presses.tabs
            eventTimes = presses.eventTimes
        }
        // The hardware state for a real key, the session state for one
        // another process posted, as the rules on the main actor ask.
        claims.keyShowsDown = { HoldKey.keyboardShowsDown($0) }
        let events = [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            .reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events, callback: triggerTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        self.port = port
        self.source = source
    }

    /// Stops only this tap and its owned run loop. The thread retains self
    /// until callbacks have finished, so the callback's unretained pointer
    /// never outlives its owner.
    @discardableResult
    func stop() -> PressState {
        lock.lock()
        stopped = true
        let presses = PressState(holds: holds, claims: claims, tabs: tabs, eventTimes: eventTimes)
        let port = port, source = source, loop = runLoop
        lock.unlock()
        if let port { CFMachPortInvalidate(port) }
        if let source { CFRunLoopSourceInvalidate(source) }
        if let loop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
        return presses
    }

    func isHealthy(at time: TimeInterval) -> Bool {
        lock.withLock {
            !stopped && port.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } == true
                && source.map(CFRunLoopSourceIsValid) == true && time - heartbeat < 3
        }
    }

    func ping() {
        lock.lock()
        let loop = stopped ? nil : runLoop
        lock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { @Sendable [weak self] in
            guard let self else { return }
            self.lock.withLock { self.heartbeat = ProcessInfo.processInfo.systemUptime }
        }
        CFRunLoopWakeUp(loop)
    }

    /// Starts handling events, once `seed` and `configure` have said what
    /// is held and what to take, so no event is judged before then.
    func start() {
        // macOS enables a tap as it creates it, so events may have queued
        // for it before it was seeded; a press among them is not judged alone.
        lock.lock()
        claims.startedAt = Self.clockStamp()
        lock.unlock()
        let thread = Thread { @Sendable [self] in
            lock.lock()
            guard !stopped, let port, let source else { lock.unlock(); return }
            let loop = CFRunLoopGetCurrent()!
            runLoop = loop
            heartbeat = ProcessInfo.processInfo.systemUptime
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.unlock()
            // A bounded run iteration closes the stop-before-run race.
            while !lock.withLock({ stopped }) {
                CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }
            CFRunLoopRemoveSource(loop, source, .commonModes)
            lock.withLock { runLoop = nil }
        }
        thread.name = "co.intention.mac.dictation-key"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The modifier key whose own events are dropped, or nil for none, and
    /// what the keys taken for dictation answer to.
    func configure(consumed keyCode: UInt16?, trigger: HoldKey.Key, takesSpace: Bool, escapeCancels: Bool,
                   escapeCancellation: @escaping @Sendable @MainActor () -> Void = {}) {
        lock.lock()
        holds.consumed = keyCode
        claims.trigger = trigger
        claims.takesSpace = takesSpace
        claims.escapeCancels = escapeCancels
        self.escapeCancellation = escapeCancellation
        lock.unlock()
    }

    /// The generation plain Tab presses are taken for, or nil for none
    /// (`TakenTabs`).
    func takeTab(_ generation: UInt64?) {
        lock.lock()
        tabs.generation = generation
        lock.unlock()
    }

    /// What the tap does with one key press or release: whether it is
    /// dropped, the key it took for dictation, whether it is handed on to
    /// the trigger's rules, and the generation of a Tab press newly taken.
    struct KeyDecision: Equatable {
        var take: Bool
        var claim: KeyClaims.Claim?
        var handOn: Bool
        var tabTaken: UInt64?
    }

    /// Decides one key press or release under the tap's lock, so the checks
    /// can run the very code the tap does. The keys taken for dictation
    /// come first (`KeyClaims`); a key they let through may still be a Tab
    /// taken while a reply proposal's card shows (`TakenTabs`), which goes
    /// to the trigger's rules as a key let through does, and counts as a
    /// key down in `KeyClaims` until it comes up.
    static func key(_ keyCode: UInt16, down: Bool, flags: NSEvent.ModifierFlags, isRepeat: Bool,
                    claims: inout KeyClaims, tabs: inout TakenTabs) -> KeyDecision {
        let answer = claims.key(keyCode, down: down, flags: flags, isRepeat: isRepeat)
        if answer.take { return KeyDecision(take: true, claim: answer.claim, handOn: false) }
        let tab = tabs.decide(down ? .keyDown(keyCode: keyCode, flags: flags.rawValue, isRepeat: isRepeat) : .keyUp(keyCode: keyCode))
        return KeyDecision(take: tab.drops, claim: nil, handOn: true, tabTaken: tab.taken)
    }

    /// Reconciles a passed event queued during the gap before installation.
    func observePassed(_ input: HoldKey.Monitored) {
        lock.lock()
        defer { lock.unlock() }
        var presses = PressState(holds: holds, claims: claims, tabs: tabs, eventTimes: eventTimes)
        presses.observePassed(input)
        holds = presses.holds
        claims = presses.claims
        tabs = presses.tabs
        eventTimes = presses.eventTimes
    }

    /// Keys down before the tap began (`KeyClaims.seed`).
    func seed(keysDown keys: Set<UInt16>) {
        lock.lock()
        claims.seed(keysDown: keys)
        lock.unlock()
    }

    /// Whether the trigger's press numbered `generation` is a dictation's hold.
    @discardableResult
    func held(_ held: Bool, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claims.held(held, generation: generation)
    }

    /// Settings took the keyboard over (`KeyClaims.withdrawAll`).
    func withdrawAll() {
        lock.lock()
        claims.withdrawAll()
        lock.unlock()
    }

    /// Whether the keyboard watch may end this press now
    /// (`KeyClaims.withdraw(generation:handled:)`), decided under the lock
    /// the tap takes Space under.
    func withdraw(generation: Int, handled: Int?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claims.withdraw(generation: generation, handled: handled)
    }

    /// Whether every release the keyboard has made so far came before the
    /// event stamped `timestamp`, from the latest release the hardware or
    /// session state recorded (`KeyClaims.releasesPrecede`), on the event's
    /// nanosecond clock.
    private static func releasesPrecede(_ timestamp: CGEventTimestamp) -> Bool {
        KeyClaims.releasesPrecede(stamp: timestamp, latestRelease: {
            [CGEventSourceStateID.hidSystemState, .combinedSessionState]
                .map { CGEventSource.secondsSinceLastEventType($0, eventType: .keyUp) }.min() ?? 0
        }, now: clockStamp, tickSeconds: 0.000000001)
    }

    private static func clockStamp() -> UInt64 {
        UInt64(Double(mach_absolute_time()) * machTickSeconds * 1_000_000_000)
    }

    private static let machTickSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    /// CGEvent timestamps are nanoseconds since startup, independent of
    /// the machine's Mach timebase. NSEvent uses the same clock in seconds.
    nonisolated static func eventTime(_ timestamp: CGEventTimestamp) -> TimeInterval {
        Double(timestamp) / 1_000_000_000
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Self.reenable({ [self] in
                lock.withLock { if !stopped, let port { CGEvent.tapEnable(tap: port, enable: true) } }
            }, disabled: disabled)
            return false
        case .flagsChanged:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let rawFlags = UInt(event.flags.rawValue)
            // The hardware state already shows this change by the time the
            // tap sees it (observed on October 7, 2026). A key the keyboard
            // sent has no process of its own; one another process posted has.
            let keyboard = UInt(CGEventSource.flagsState(.hidSystemState).rawValue)
            let fromKeyboard = event.getIntegerValueField(.eventSourceUnixProcessID) == 0
            lock.lock()
            guard !stopped else { lock.unlock(); return false }
            eventTimes[keyCode] = Self.eventTime(event.timestamp)
            let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
            let drops = holds.drops(keyCode: keyCode, flags: flags)
            claims.modifiersChanged(keyCode: keyCode, flags: flags, dropped: drops, stamp: event.timestamp,
                                    releasesArrived: { Self.releasesPrecede(event.timestamp) })
            let generation = claims.generation, keysClear = claims.keysClear
            lock.unlock()
            deliver(HoldKey.Delivery(keyCode: keyCode, flags: rawFlags, keyboard: keyboard, fromKeyboard: fromKeyboard,
                                     generation: generation, keysClear: keysClear, time: Self.eventTime(event.timestamp), tapOwned: true))
            return drops
        case .keyDown, .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            lock.lock()
            guard !stopped else { lock.unlock(); return false }
            eventTimes[keyCode] = Self.eventTime(event.timestamp)
            let decision = Self.key(keyCode, down: type == .keyDown, flags: flags, isRepeat: isRepeat, claims: &claims, tabs: &tabs)
            let generation = claims.generation
            let cancellation = escapeCancellation
            lock.unlock()
            if let claim = decision.claim {
                claimed(claim, generation, cancellation)
            } else if decision.handOn {
                // In the same order as the modifier changes around it, so a
                // shortcut's key is never handled after the key's release.
                var observed = HoldKey.Monitored(kind: type == .keyDown ? .keyDown : .keyUp, keyCode: keyCode, flags: flags.rawValue,
                                                isRepeat: isRepeat, proposalTab: decision.take)
                observed.time = Self.eventTime(event.timestamp)
                input(observed, decision.tabTaken)
            }
            return decision.take
        case .scrollWheel:
            lock.lock()
            guard !stopped else { lock.unlock(); return false }
            claims.rejectCandidate()
            lock.unlock()
            var observed = HoldKey.Monitored(kind: .scroll, flags: UInt(event.flags.rawValue))
            observed.time = Self.eventTime(event.timestamp)
            input(observed, nil)
            return false
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            lock.lock()
            guard !stopped else { lock.unlock(); return false }
            claims.rejectCandidate()
            lock.unlock()
            var observed = HoldKey.Monitored(kind: .mouseDown, flags: UInt(event.flags.rawValue))
            observed.time = Self.eventTime(event.timestamp)
            input(observed, nil)
            return false
        default:
            return false
        }
    }

    nonisolated static func reenable(_ enable: @Sendable () -> Void, disabled: @Sendable () -> Void) {
        enable()
        disabled()
    }
}

/// Returns nil to drop the event, which `TriggerTap.handle` decides.
nonisolated private func triggerTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<TriggerTap>.fromOpaque(info).takeUnretainedValue()
    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}

/// How many deliveries from the tap's thread are on their way to the main
/// actor, counted on both.
final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() {
        lock.withLock { count += 1 }
    }

    func remove() {
        lock.withLock { count -= 1 }
    }

    var isEmpty: Bool { lock.withLock { count == 0 } }
}
