import Foundation

/// Settings the person can change, stored in the app's defaults domain.
@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults

    /// Whether the dot finds the caret on screen in fields that report
    /// none; most place it from Accessibility. On unless the person turned
    /// it off or this launch says otherwise, see `findsCaretOnScreen`.
    let visualCaretEnabled: Bool

    /// Whether Intention has asked for Screen Recording on the person's behalf
    /// once, so a declined request is not repeated at every launch.
    var screenRecordingRequested: Bool {
        didSet { defaults.set(screenRecordingRequested, forKey: Key.screenRecordingRequested) }
    }

    /// Whether the person said yes to opening at login from a copy of
    /// Intention outside Applications, which can move or disappear. The next
    /// launch from Applications adds it to Login Items and clears this.
    var loginItemPending: Bool {
        didSet { defaults.set(loginItemPending, forKey: Key.loginItemPending) }
    }

    /// The languages the person dictates in, as two-letter codes such as
    /// "en" and "es". Empty means English only.
    var dictationLanguages: [String] {
        didSet { defaults.set(dictationLanguages, forKey: Key.dictationLanguages) }
    }

    /// The key, or pair of keys, held for hold-to-talk dictation.
    var dictationKey: HoldKey.Key {
        didSet { defaults.set(dictationKey.rawValue, forKey: Key.dictationKey) }
    }

    /// How Intention shows itself while the person writes and dictates: the
    /// dot above the caret in an email Intention can write as well as the foot
    /// mark, unless they chose the foot mark alone. The choice is kept
    /// here only; counting how many people keep each needs the analytics
    /// of #73, which this build does not have.
    var indicator: IndicatorStyle {
        didSet {
            defaults.set(indicator.rawValue, forKey: Key.indicator)
            // A deliberate choice restores the normal permission flow.
            screenRecordingLaunchDeferred = false
            defaults.set(false, forKey: Key.screenRecordingLaunchDeferred)
        }
    }

    /// Restoring the old pill choice to the caret dot must not introduce a
    /// launch alert. Keep that deferral across launches until the person
    /// chooses an indicator; finishing setup can still explain and ask.
    private(set) var screenRecordingLaunchDeferred: Bool

    /// Light unless the person chose Dark in Settings.
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// The last position the person chose for the foot dot. A display
    /// with no choice of its own starts here.
    var dotPosition: FootSlot {
        didSet { defaults.set(dotPosition.rawValue, forKey: Key.dotPosition) }
    }

    /// The foot stays hidden until this wall-clock time, across relaunches.
    var footHiddenUntil: Date? {
        didSet { defaults.set(footHiddenUntil, forKey: Key.footHiddenUntil) }
    }

    /// Positions the person chose by dragging the dot on each display,
    /// kept by display UUID so reconnecting it keeps its choice.
    var dotPositionsByDisplay: [String: FootSlot] {
        didSet { defaults.set(dotPositionsByDisplay.mapValues(\.rawValue), forKey: Key.dotPositionsByDisplay) }
    }

    func dotPosition(onDisplay key: String) -> FootSlot {
        dotPositionsByDisplay[key] ?? dotPosition
    }

    /// A drag chooses for this display and gives displays connected later
    /// the same position. Settings shows the person's latest choice. The
    /// displays in `keeping`, those connected now, keep the place they show,
    /// so a drag on one display never moves the dot on another.
    func chooseDotPosition(_ slot: FootSlot, onDisplay key: String, keeping connected: [String] = []) {
        var positions = dotPositionsByDisplay
        for other in connected where other != key && positions[other] == nil {
            positions[other] = dotPosition
        }
        positions[key] = slot
        dotPositionsByDisplay = positions
        dotPosition = slot
    }

    /// A choice in Settings puts every display in the same position,
    /// including ones the person previously chose by dragging.
    func chooseDotPositionEverywhere(_ slot: FootSlot) {
        dotPosition = slot
        dotPositionsByDisplay = [:]
    }

    /// Whether launch asks macOS for Screen Recording, which it does once,
    /// when the grant is missing. Only the dot uses it, to find the caret
    /// on screen, so a person who chose the foot mark alone is never asked.
    var asksForScreenRecordingAtLaunch: Bool {
        indicator == .dot && visualCaretEnabled && !screenRecordingRequested
    }

    /// The microphone dictation records from: the built-in one, for new
    /// and existing installs alike, unless the person chose the system
    /// default or one device in Settings. A device is kept by its Core
    /// Audio UID, which stays the same across launches and reconnections,
    /// with its name for saying it is not connected.
    var microphone: MicrophonePreference {
        didSet { Self.save(microphone, in: defaults) }
    }

    /// "Write emails for me": on unless the person turned it off. Words
    /// dictated into the body of an email being written become an email
    /// the server writes; off, they are typed as they are, like anywhere else.
    var writesEmails: Bool {
        didSet { defaults.set(writesEmails, forKey: Key.writesEmails) }
    }

    /// "Draft replies for me": on unless the person turned it off. When a
    /// reply opens in Gmail with the dot, Intention asks its writer for a draft
    /// and shows it at the caret; nothing goes in until the person accepts
    /// it. It works only while `writesEmails` is on and the dot is the
    /// indicator (`WritingRow.draftsBlocked`).
    var draftsReplies: Bool {
        didSet { defaults.set(draftsReplies, forKey: Key.draftsReplies) }
    }

    /// "Add 'Sent with Intention' to emails Intention writes": off until chosen.
    var addsSentWithIntention: Bool {
        didSet { defaults.set(addsSentWithIntention, forKey: Key.addsSentWithIntention) }
    }

    /// Whether Intention has written an email from this person's dictation
    /// and put it in, outside setup. Until then the hint beside an email
    /// body may show (`EmailHint`), and the first email says once that it
    /// was written from their words and how to take it back.
    var firstEmailWritten: Bool {
        didSet { defaults.set(firstEmailWritten, forKey: Key.firstEmailWritten) }
    }

    /// Whether a reply card has shown its key row in words. The first card
    /// after setup says it in full once; every card after shows the keys
    /// as pictures, with the words kept for VoiceOver.
    var cardKeyWordsShown: Bool {
        didSet { defaults.set(cardKeyWordsShown, forKey: Key.cardKeyWordsShown) }
    }

    /// How many times the hint beside an email body has shown; it retires
    /// at `EmailHint.limit`.
    var emailHintsShown: Int {
        didSet { defaults.set(emailHintsShown, forKey: Key.emailHintsShown) }
    }

    /// `-visualCaretEnabled NO` or `YES` in the launch arguments, as the
    /// caret lab passes, decides for that launch. Otherwise the choice the
    /// person saved with the Settings switch Intention had until October 6,
    /// 2026 stands: someone who turned capture off keeps it off, though
    /// nothing in Intention turns it back on now. It is on by default.
    nonisolated static func findsCaretOnScreen(arguments: [String] = CommandLine.arguments, saved: Bool?) -> Bool {
        // Only a plain yes or no decides; a flag with no value, or followed
        // by another flag, leaves the saved choice standing.
        guard let index = arguments.firstIndex(of: "-" + Key.visualCaret), arguments.indices.contains(index + 1) else { return saved ?? true }
        switch arguments[index + 1].lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return saved ?? true
        }
    }

    nonisolated static func savedCaretChoice(in defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: Key.visualCaret) as? Bool
    }

    init(defaults: UserDefaults = .standard, arguments: [String] = CommandLine.arguments, now: Date = Date()) {
        self.defaults = defaults
        if !defaults.bool(forKey: Key.indicatorStyleMigrated) {
            // Before the sun dot, "pill" showed an indicator. Without the
            // new-style marker it must not become Hide and disable drafts.
            if defaults.string(forKey: Key.indicator) == "pill" {
                defaults.set(true, forKey: Key.screenRecordingLaunchDeferred)
                defaults.set(IndicatorStyle.dot.rawValue, forKey: Key.indicator)
            }
            defaults.set(true, forKey: Key.indicatorStyleMigrated)
        }
        dictationKey = defaults.string(forKey: Key.dictationKey).flatMap(HoldKey.Key.init(rawValue:)) ?? .single(.rightControl)
        indicator = arguments.contains("--demo-foot-only") ? .foot : defaults.string(forKey: Key.indicator).flatMap(IndicatorStyle.init(rawValue:)) ?? .foot
        screenRecordingLaunchDeferred = defaults.bool(forKey: Key.screenRecordingLaunchDeferred)
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .light
        let savedHide = defaults.object(forKey: Key.footHiddenUntil) as? Date
        let activeHide = savedHide.flatMap { $0 > now ? $0 : nil }
        footHiddenUntil = activeHide
        if activeHide == nil { defaults.removeObject(forKey: Key.footHiddenUntil) }
        dotPosition = defaults.string(forKey: Key.dotPosition).flatMap(FootSlot.init(rawValue:)) ?? .bottom
        dotPositionsByDisplay = (defaults.dictionary(forKey: Key.dotPositionsByDisplay) ?? [:])
            .compactMapValues { ($0 as? String).flatMap(FootSlot.init(rawValue:)) }
        writesEmails = defaults.object(forKey: Key.writesEmails) as? Bool ?? true
        draftsReplies = defaults.object(forKey: Key.draftsReplies) as? Bool ?? true
        addsSentWithIntention = defaults.object(forKey: Key.addsSentWithIntention) as? Bool ?? false
        microphone = Self.savedMicrophone(in: defaults)
        visualCaretEnabled = Self.findsCaretOnScreen(arguments: arguments, saved: Self.savedCaretChoice(in: defaults))
        screenRecordingRequested = defaults.bool(forKey: Key.screenRecordingRequested)
        loginItemPending = defaults.bool(forKey: Key.loginItemPending)
        dictationLanguages = defaults.stringArray(forKey: Key.dictationLanguages) ?? []
        firstEmailWritten = defaults.bool(forKey: Key.firstEmailWritten)
        cardKeyWordsShown = defaults.bool(forKey: Key.cardKeyWordsShown)
        emailHintsShown = defaults.integer(forKey: Key.emailHintsShown)
    }

    /// Anything this build does not know reads as the built-in microphone.
    private static func savedMicrophone(in defaults: UserDefaults) -> MicrophonePreference {
        switch defaults.string(forKey: Key.microphone) {
        case "systemDefault":
            return .systemDefault
        case "device":
            guard let uid = defaults.string(forKey: Key.microphoneDevice), !uid.isEmpty else { return .builtIn }
            return .device(uid: uid, name: defaults.string(forKey: Key.microphoneName) ?? uid)
        default:
            return .builtIn
        }
    }

    private static func save(_ microphone: MicrophonePreference, in defaults: UserDefaults) {
        switch microphone {
        case .builtIn, .systemDefault:
            defaults.set(microphone == .builtIn ? "builtIn" : "systemDefault", forKey: Key.microphone)
            defaults.removeObject(forKey: Key.microphoneDevice)
            defaults.removeObject(forKey: Key.microphoneName)
        case let .device(uid, name):
            defaults.set("device", forKey: Key.microphone)
            defaults.set(uid, forKey: Key.microphoneDevice)
            defaults.set(name, forKey: Key.microphoneName)
        }
    }

    private enum Key {
        /// Read only, see `findsCaretOnScreen`.
        static let visualCaret = "visualCaretEnabled"
        static let screenRecordingRequested = "screenRecordingRequested"
        static let loginItemPending = "loginItemPending"
        static let dictationKey = "dictationKey"
        static let dictationLanguages = "dictationLanguages"
        static let indicator = "indicator"
        static let indicatorStyleMigrated = "indicatorStyleMigrated"
        static let screenRecordingLaunchDeferred = "screenRecordingLaunchDeferred"
        static let appearance = "appearance"
        static let footHiddenUntil = "footHiddenUntil"
        static let dotPosition = "dotPosition"
        static let dotPositionsByDisplay = "dotPositionsByDisplay"
        static let writesEmails = "writesEmails"
        static let draftsReplies = "draftsReplies"
        static let addsSentWithIntention = "addsSentWithIntention"
        static let firstEmailWritten = "firstEmailWritten"
        static let cardKeyWordsShown = "cardKeyWordsShown"
        static let emailHintsShown = "emailHintsShown"
        static let microphone = "microphone"
        static let microphoneDevice = "microphoneDevice"
        static let microphoneName = "microphoneName"
    }
}

/// The two ways Intention can show itself in other apps. The foot mark waits
/// at the foot of the screen either way; with `dot` the dot also sits above
/// the caret of the field being written in, and with `foot` it does not,
/// and Intention needs no Screen Recording. `foot` keeps the raw value of the
/// pill it replaced on October 10, 2026. `Preferences` migrates an old pill
/// choice to Show once; after that the same raw value is a deliberate Hide.
enum IndicatorStyle: String, CaseIterable, Identifiable {
    case dot
    case foot = "pill"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dot: "Show"
        case .foot: "Hide"
        }
    }
}
