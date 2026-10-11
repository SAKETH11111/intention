import AppKit

/// What a recording of a new dictation trigger makes of the keys pressed:
/// the keys held so far, and once all of them are let go, the trigger
/// they make or why the trigger cannot use it. No AppKit event delivery is
/// in it, so `./dev mac-dictation-test` can drive it.
///
/// The trigger is held, so only modifier keys can be one: any other key
/// would also type into the field. One key on its own starts dictation the
/// moment it goes down, so it must be one that shortcuts and typing rarely
/// use: Fn or a right-hand Control, Option or Command. Two or more held
/// together wait out `HoldDetector.armDelay` alone first, so any of
/// Control, Option, Shift and Command can be a pair, either side of each
/// key. Fn is left out of pairs: only Fn on its own is taken from other
/// apps, so in a pair another app's Fn shortcut would start as well.
struct KeyRecording {
    enum Outcome: Equatable {
        case recorded(HoldKey.Key)
        /// The keys cannot be a trigger, with one short line saying why.
        /// Recording goes on, so the person can try again.
        case refused(String)
        case cancelled
    }

    /// The modifiers down at the last modifier change, read from its flags
    /// alone, so a release that never arrived is corrected by the next.
    private var down: Set<HoldKey.Modifier> = []
    /// Every modifier pressed since all were last up: what the attempt is.
    private var pressed: Set<HoldKey.Modifier> = []
    /// Keys other than modifiers that are down, by key code.
    private var keysDown: Set<UInt16> = []
    /// The attempt was refused, so nothing is recorded until every key in
    /// it, modifier or not, is up and a new attempt starts.
    private var refused = false
    /// Whether the keyboard still shows a key down, so one whose release
    /// went unseen does not hold an attempt refused. `KeyRecorder` asks
    /// the keyboard; left as it is, a key stays down until its release.
    var keyboardShowsDown: (UInt16) -> Bool = { _ in true }

    /// The keys pressed in the attempt so far, for the field to show, or
    /// nil before the first.
    var shown: String? {
        pressed.isEmpty ? nil : Self.key(for: pressed).title
    }

    static let escape: UInt16 = 53

    static let notModifier = "Only fn, Control, Option, Shift and Command can be held to dictate."
    static let sameKey = "Hold two different keys, or one key on its own."
    static let shift = "Shift on its own would start with every capital letter. Try fn or two keys together."
    static let fnInPair = "fn works only on its own, since other apps listening for it would start too."

    static func leftHand(_ modifier: HoldKey.Modifier) -> String {
        "\(modifier.title) is in too many shortcuts. Try the right-hand key, fn, or two keys together."
    }

    mutating func receive(_ input: HoldKey.Recorded) -> Outcome? {
        switch input {
        case let .key(keyCode, _):
            // Escape cancels, whatever else is held.
            if keyCode == Self.escape { return .cancelled }
            // A key whose release went unseen is forgotten first.
            settle()
            keysDown.insert(keyCode)
            return refuse()
        case let .keyUp(keyCode):
            keysDown.remove(keyCode)
            settle()
            return nil
        case let .modifiers(keyCode, flags):
            let now = Set(HoldKey.Modifier.allCases.filter { flags.rawValue & $0.deviceMask != 0 })
            let changed = HoldKey.Modifier(keyCode: keyCode)
            // A key going down alone while the flags show the earlier keys
            // up with no release seen, or going down again when its own
            // release was never seen: the earlier attempt ended unseen, and
            // this press starts a new one.
            if let changed, now == [changed], down.contains(changed) || !down.subtracting(now).isEmpty {
                pressed = []
                down = []
                settle()
            }
            down = now
            // Caps Lock, or a modifier the trigger does not know.
            guard changed != nil else { return refuse() }
            settle()
            guard !refused else { return nil }
            pressed.formUnion(down)
            // An attempt ends when every key is up.
            guard down.isEmpty, !pressed.isEmpty else { return nil }
            defer { pressed = [] }
            return Self.outcome(for: pressed)
        }
    }

    private mutating func refuse() -> Outcome {
        pressed = []
        refused = true
        settle()
        return .refused(Self.notModifier)
    }

    /// A refused attempt ends once nothing in it is still down.
    private mutating func settle() {
        keysDown = keysDown.filter(keyboardShowsDown)
        if down.isEmpty, keysDown.isEmpty { refused = false }
    }

    /// The trigger the keys make, before asking whether it can be one.
    private static func key(for modifiers: Set<HoldKey.Modifier>) -> HoldKey.Key {
        modifiers.count == 1 ? .single(modifiers.first!) : .combination(Set(modifiers.map(\.family)))
    }

    static func outcome(for modifiers: Set<HoldKey.Modifier>) -> Outcome {
        if modifiers.count == 1, let modifier = modifiers.first {
            switch modifier {
            case .function, .rightControl, .rightOption, .rightCommand: return .recorded(.single(modifier))
            case .leftShift, .rightShift: return .refused(shift)
            case .leftControl, .leftOption, .leftCommand: return .refused(leftHand(modifier))
            }
        }
        // Left and right Option together are one modifier, as a pair reads them.
        let families = Set(modifiers.map(\.family))
        guard families.count >= 2 else { return .refused(sameKey) }
        // The tap takes Fn from other apps only when Fn is the trigger on its
        // own; in a pair, Wispr Flow and the globe key would hear it too.
        return families.contains(.function) ? .refused(fnInPair) : .recorded(.combination(families))
    }
}

/// Records a new dictation trigger for Settings: while it listens, the
/// trigger's watch hands it every modifier change and key press in place
/// of starting dictation, and the trigger the keys make is saved once they
/// are let go. Escape, or the window losing the keyboard, cancels.
@MainActor
@Observable
final class KeyRecorder {
    private(set) var isRecording = false
    /// The keys held in the current attempt.
    private(set) var shown: String?
    /// Why the last attempt cannot be a trigger, until the next begins.
    private(set) var refusal: String?

    @ObservationIgnored private var recording = KeyRecording()
    @ObservationIgnored private let holdKey: HoldKey
    @ObservationIgnored private let save: @MainActor (HoldKey.Key) -> Void
    /// Watches for any window losing the keyboard while recording.
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    /// Where windows announce losing the keyboard; the checks give their own.
    @ObservationIgnored private let notifications: NotificationCenter
    /// Writes one fixed name to the log; the checks read what it wrote.
    @ObservationIgnored private let log: @MainActor (String) -> Void

    init(holdKey: HoldKey, notifications: NotificationCenter = .default,
         log: @escaping @MainActor (String) -> Void = { AppLog.dictation($0) },
         save: @escaping @MainActor (HoldKey.Key) -> Void) {
        self.holdKey = holdKey
        self.notifications = notifications
        self.log = log
        self.save = save
    }

    func start() {
        // Editing the trigger cannot manufacture a release of a recording.
        guard !holdKey.recording else { return }
        if isRecording { stop() }
        recording = KeyRecording()
        recording.keyboardShowsDown = HoldKey.keyboardShowsDown
        shown = nil
        refusal = nil
        isRecording = true
        holdKey.recorder = { [weak self] in self?.receive($0) }
        // Delivered on the main queue whoever posts it, and @Sendable, so
        // a post from another queue cannot trip Swift's isolation check.
        resignObserver = notifications.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) {
            @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func cancel() {
        guard isRecording else { return }
        stop()
    }

    private func stop() {
        isRecording = false
        shown = nil
        holdKey.recorder = nil
        if let resignObserver { notifications.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func receive(_ input: HoldKey.Recorded) {
        let outcome = recording.receive(input)
        shown = recording.shown
        switch outcome {
        case let .recorded(key)?:
            log("key.recorded")
            refusal = nil
            save(key)
            stop()
        case let .refused(reason)?:
            if Self.isPress(input) { log("key.refused") }
            refusal = reason
        case .cancelled?:
            stop()
        case nil:
            if shown != nil { refusal = nil }
        }
    }

    /// One refusal is logged per physical press, decided by the event
    /// alone with nothing kept between presses: a key down that is not an
    /// auto-repeat, or a modifier change, which never repeats. A held
    /// letter logs once, and pressing it twice logs twice.
    private static func isPress(_ input: HoldKey.Recorded) -> Bool {
        switch input {
        case let .key(_, isRepeat): !isRepeat
        case .modifiers: true
        case .keyUp: false
        }
    }

    #if DEBUG
    /// Shows the field listening after the given input, without taking the
    /// trigger's events, for the Settings render.
    func preview(_ inputs: [HoldKey.Recorded]) {
        isRecording = true
        for input in inputs { receive(input) }
    }
    #endif
}
