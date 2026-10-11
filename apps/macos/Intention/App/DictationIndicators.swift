import CoreGraphics

/// How dictation's phase, notice and silence reach the indicators: the
/// foot mark shows the phase and the notice, read together whenever either
/// changes, and `phase` and `notice` take each change for the dot and
/// anything else that follows dictation. `silence` says in one line, through
/// the chosen indicator, why a dictation inserted nothing, and `nothing`
/// takes one the person can do something about
/// (`DictationController.EmptyResult.actionable`), for the popup that
/// offers Retry and another microphone, since neither the foot's words nor
/// the dot's caption takes a click.
///
/// Dictation holds back what it says about a dictation that ended while
/// another records until that one stops, so nothing here covers a
/// recording. A notice the foot shows for its own time, such as silence,
/// keeps that time while text goes in, and the foot then shows what the
/// phase and notice call for, not rest.
///
/// AppModel wires the indicators through this, and the scenario tests
/// (`theFootShowsTheEmailBeingWrittenAndTheNoticeAsTheDotDoes`, and
/// `foot(for:)` in DictationScenarioTests.swift) through the same call, so
/// the tests cover the wiring the app runs.
@MainActor
enum DictationIndicators {
    /// The app and the nonnative checks share the exact trigger bindings.
    /// Pending feedback never starts audio or claims a shortcut.
    /// `startsDictation` is asked at each press with nothing recording:
    /// false leaves the hold to show itself only, as on setup's shortcut
    /// page.
    static func connectTrigger(_ key: HoldKey, dictation: DictationController,
                               startsDictation: @escaping @MainActor () -> Bool = { true },
                               pending: @escaping @MainActor (Bool) -> Void) {
        key.onPendingChanged = pending
        key.pressOnlyShows = { !startsDictation() }
        key.onPress = { [weak key, weak dictation] in
            guard let key else { return }
            dictation?.holdBegan(alone: key.pressWasAlone, confirmed: key.holdWasConfirmed)
        }
        key.onRelease = { [weak dictation] in dictation?.holdEnded() }
        key.onOtherKey = { [weak dictation] in dictation?.keyPressedDuringHold() }
        key.onHandsFree = { [weak dictation] in dictation?.holdBecameHandsFree() }
        key.onEscape = dictation.escapeCancellation()
        key.onLock = { [weak key, weak dictation] in
            key?.cancelPending()
            dictation?.screenLocked()
        }
        key.onClick = { [weak dictation] in dictation?.clickedDuringHold() }
    }

    /// A read's start time cannot date the focus change it discovered.
    /// Forward observations to proposals without cancelling a pending key.
    static func caretObserver(_ observe: @escaping @MainActor (ProposalObservation) -> Void)
        -> @MainActor (CaretTracker.Observation) -> Void {
        { observe(ProposalObservation($0)) }
    }

    static func select(_ style: IndicatorStyle, dictation: DictationController, foot: FootMark, isEmailBody: Bool) {
        foot.saysWords = saysWords(style: style, isEmailBody: isEmailBody)
        if let issue = dictation.recordingIssue { dictation.recordingIssueChanged?(issue) }
    }

    nonisolated static func saysWords(style: IndicatorStyle, isEmailBody: Bool) -> Bool {
        style == .foot || !isEmailBody
    }

    nonisolated static func wordsThroughFoot(style: IndicatorStyle, isEmailBody: Bool, footHasRoom: Bool) -> Bool {
        style == .foot || (!isEmailBody && footHasRoom)
    }

    static func connect(_ dictation: DictationController, foot: FootMark, key: HoldKey? = nil,
                        phase: @escaping (DictationController.Phase) -> Void,
                        notice: @escaping (DictationController.Notice?) -> Void,
                        silence: @escaping (FootState) -> Void,
                        nothing: @escaping (DictationController.EmptyResult) -> Void,
                        email: @escaping (DictationController.EmailFeedback) -> Void = { _ in },
                        announce: @escaping (String) -> Void = { _ in },
                        recordingIssue: @escaping (String?) -> Void = { _ in },
                        follow: ((FootState) -> Void)? = nil) {
        let followState: (FootState) -> Void = { [weak foot] state in
            if let follow { follow(state) } else { foot?.follow(state) }
        }
        key?.dictationAvailable = dictation.available
        if key != nil {
            dictation.problemChanged = { [weak dictation, weak key] _ in
                if let dictation { key?.dictationAvailable = dictation.available }
            }
        }
        var announcedWait = false
        func announceWait(phase: DictationController.Phase, feedback: DictationController.EmailFeedback) {
            guard let caption = feedback.caption else {
                announcedWait = false
                return
            }
            // A newer recording owns Escape and must not hear advice for
            // the older email. Say it once when that email shows again.
            guard phase == .writingEmail, !announcedWait else { return }
            announcedWait = true
            announce(caption)
        }
        dictation.phaseChanged = { [weak dictation, weak key] new in
            guard let dictation else { return }
            followState(FootState(phase: new, notice: dictation.notice, email: dictation.emailFeedback))
            key?.dictationAvailable = dictation.available
            phase(new)
            announceWait(phase: new, feedback: dictation.emailFeedback)
        }
        dictation.recordingIssueChanged = { [weak foot] words in
            recordingIssue(words)
            foot?.recordingIssue = words
        }
        dictation.noticeChanged = { [weak dictation] new in
            guard let dictation else { return }
            followState(FootState(phase: dictation.phase, notice: new, email: dictation.emailFeedback))
            notice(new)
        }
        dictation.silent = { empty in empty.actionable ? nothing(empty) : silence(FootState(empty)) }
        dictation.emailFeedbackChanged = { [weak dictation] feedback in
            guard let dictation else { return }
            followState(FootState(phase: dictation.phase, notice: dictation.notice, email: feedback))
            email(feedback)
            announceWait(phase: dictation.phase, feedback: feedback)
        }
        email(dictation.emailFeedback)
        foot.afterNotice = { [weak dictation] in
            dictation.map { FootState(phase: $0.phase, notice: $0.notice, email: $0.emailFeedback) } ?? .resting
        }
    }

    /// Apply words only to their owner. A caret notice must neither keep a
    /// hidden foot notice alive nor restart the foot's four-second timer.
    @discardableResult
    static func follow(_ state: FootState?, words: String?, atFoot: Bool, timed: Bool,
                       allowCaretFallback: Bool = true, foot: FootMark, timedWords: inout String?) -> Bool {
        // A geometry-only refresh with no words must leave the practice
        // email's warm foot, owned by onboarding, alone.
        guard let state else { return atFoot }
        if words != nil { foot.saysWords = atFoot }
        // Its own timer may already have ended while the hint's owner is
        // about to clear the words. Never move an expired slip to the caret.
        let timedNoticeEnded = atFoot && timed && timedWords == words && !foot.showsNotice
        if atFoot, timed, let words {
            if timedWords != words {
                timedWords = words
                foot.show(.notice(words))
            }
        } else {
            timedWords = nil
            var next = state
            if !atFoot, case .notice = next { next = .resting }
            if !atFoot || words == nil, foot.showsNotice { foot.state = .resting }
            foot.follow(next)
        }
        // Showing a notice can choose a different display and slot. Check
        // the slip that actually opened as well as preflighting its room.
        if atFoot, allowCaretFallback, !timedNoticeEnded, words != nil, foot.slipFrame == nil {
            return follow(state, words: words, atFoot: false, timed: timed,
                          allowCaretFallback: false, foot: foot, timedWords: &timedWords)
        }
        return atFoot
    }

    /// What the caret dot shows, from dictation's phase, the reply
    /// proposal's presentation and whether the foot mark paints. A
    /// dictation's own look comes first: while it records, full ink when
    /// the foot's sun carries the red, so one red mark shows, and red with
    /// its halo when nothing paints at the foot; the pulse while its text or
    /// email is on its way. With no dictation running, a proposal on its
    /// way pulses as words on their way do, with no caption, and a
    /// proposal's card on screen puts the dot at full ink.
    /// `CaretDotController` draws what this answers.
    static func dotLook(phase: DictationController.Phase, proposal: ProposalPresentation, footCarriesRed: Bool = false) -> DotLook {
        switch phase {
        case .recording: footCarriesRed ? .heard : .recording
        case .processing, .writingEmail: .working
        case .idle:
            switch proposal {
            case .idle: .resting
            case .pending: .working
            case .shown: .proposed
            }
        }
    }

    /// Captions follow the selected word surface. The foot may paint even
    /// when its slip cannot open clear of the focused field.
    nonisolated static func caretPresentation(isEmailBody: Bool, phase: DictationController.Phase,
                                             proposal: ProposalPresentation, footCarriesRed: Bool,
                                             footPaints: Bool, captionDue: Bool, wordsAtFoot: Bool = false) -> CaretPresentation {
        let dot: Bool
        if isEmailBody {
            dot = true
        } else {
            switch phase {
            case .recording: dot = !footCarriesRed
            case .processing, .writingEmail: dot = !footPaints
            case .idle: dot = false
            }
        }
        return CaretPresentation(dot: dot, caption: captionDue && !wordsAtFoot)
    }

    nonisolated static func popupAnchor(caretAnchor: CGRect?) -> InsertionPopup.Anchor {
        caretAnchor.map { .dot($0) } ?? .screenFoot
    }

    /// A microphone outage belongs to the selected indicator only, and
    /// ends as soon as recovery succeeds, including the no-caret fallback.
    static func sayRecordingIssue(_ words: String?, throughFoot: Bool, caretAnchor: CGRect?,
                                  caption: (String?) -> Void, panel: (FootState?) -> Void) {
        guard !throughFoot, let words else {
            caption(nil)
            panel(nil)
            return
        }
        sayOnDot(words, caretAnchor: caretAnchor, recordingIssue: words,
                 caption: caption, panel: { state, _ in panel(state) })
    }

    /// The foot owns words when selected or when its slip fits outside email.
    /// Otherwise use the caret caption, falling back to the capsule only
    /// when no caret is known. Clear the other surface before showing words.
    /// Nil clears the caption; timed capsules end on their own, while a
    /// recording issue stays until its recovery callback clears it.
    static func sayOnDot(_ words: String?, caretAnchor: CGRect?, recordingIssue: String? = nil, throughFoot: Bool = false,
                         caption: (String?) -> Void, panel: (FootState?, Duration?) -> Void) {
        guard let words else { return caption(nil) }
        if throughFoot {
            caption(nil)
            panel(nil, nil)
        } else if caretAnchor == nil {
            caption(nil)
            panel(.notice(words), words == recordingIssue ? nil : .seconds(4))
        } else {
            panel(nil, nil)
            caption(words)
        }
    }
}

/// The caret dot's looks: at rest in the field's own ink, red while a
/// dictation records and the foot cannot show it, full ink while it
/// records and the foot's sun shows it (`heard`), pulsing while text is on
/// its way (steady and dimmed under reduced motion), and at full ink while
/// a reply proposal's card shows.
enum DotLook: Equatable, Sendable {
    case resting, recording, heard, working, proposed
}

struct CaretPresentation: Equatable, Sendable {
    var dot: Bool
    var caption: Bool
}

/// A visible notice keeps its owner across classification changes. Losing
/// room at the foot transfers it once; gaining room never moves it back.
struct NoticeWordRoute {
    private var words: String?
    private var atFoot = false

    mutating func choose(_ next: String?, style: IndicatorStyle, isEmailBody: Bool, footHasRoom: Bool) -> Bool {
        let prefersFoot = DictationIndicators.saysWords(style: style, isEmailBody: isEmailBody)
        let hasRoom = style == .foot || footHasRoom
        guard let next else { words = nil; atFoot = false; return false }
        if next != words {
            words = next
            atFoot = prefersFoot && hasRoom
        } else if atFoot && !hasRoom {
            atFoot = false
        }
        return atFoot
    }

    mutating func reset() { words = nil; atFoot = false }
}
