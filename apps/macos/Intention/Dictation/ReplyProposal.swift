import AppKit
import Foundation
import os

/// Where a proposal card's first line of text starts, in AppKit screen
/// coordinates, and how much room the body gives it. The controller
/// derives it from the caret tracker's reading, or from the body's own
/// frame when the tracker has no caret, so the card sits where the words
/// will land; the card never reads anything itself.
typealias ProposalCardAnchor = ProposalCard.Anchor

/// What the controller asks of the card on screen. `ProposalCard` is the
/// one on screen; the checks use a double.
@MainActor
protocol ProposalCardPresenting: AnyObject {
    /// Shows `text` at `anchor`; false when it fits neither below nor
    /// above, in which case the card is hidden.
    func show(text: String, dictationKeyName: String, at anchor: ProposalCardAnchor) -> Bool
    func hide()
    var isShown: Bool { get }
    /// While a dictation records, the Tab button does nothing and the card stays.
    var acceptsInput: Bool { get set }
    var confirmingReplacement: Bool { get set }
    /// False leaves the normal card shown when no spot clears the selection.
    func beginConfirmation(keeping clear: ProposalCard.KeepClear?) -> Bool
    /// What the card leaves in view while `confirmingReplacement` is true.
    var keepClear: ProposalCard.KeepClear? { get set }
    /// Runs on the main actor only for the explicit Accessibility press.
    var accepted: () -> Void { get set }
    /// Runs on the main actor whenever the screen locks or the displays
    /// sleep, whether or not a card shows, after a shown card hid itself:
    /// the controller stops taking Tab, shows the card again only after a
    /// fresh check, and latches an accept on its way.
    var screenLockedOrAsleep: () -> Void { get set }
}

extension ProposalCard: ProposalCardPresenting {}

/// The reads a proposal makes on Accessibility executors. The inserter
/// makes them against the apps; the checks script them.
@MainActor
protocol ProposalReading: AnyObject {
    /// Whether the focused field could be Gmail's reply body. Nil
    /// `expecting` reads whichever field has focus, as the scan on each
    /// focus change does; a proposal's reread of its own body passes the
    /// body, and the read then refuses with `focusChanged` before it reads
    /// anything of another field. `blank` also asks whether that body holds
    /// only line breaks (`ProposalCandidate.blank`).
    func readProposalCandidate(expecting: ExpectedFocus?, blank: Bool) -> ProposalCandidateRead
    /// A notice body read that does not queue behind insertion jobs.
    func readProposalSnapshot(expecting: ExpectedFocus, visibility: Bool) -> ComposeRead
    /// The read voice compose makes of an email body and what the window
    /// shows around it, made only while `expecting` has focus: anything
    /// else answers `focusChanged` and reads nothing of the field now
    /// focused. `visibility` also reads what shows the body's first line
    /// in view, for a card placed from the body's frame.
    func readFocusedEmailDraft(text: Bool, expecting: ExpectedFocus?, visibility: Bool) -> ComposeRead
}

extension TextInserter: ProposalReading {}

/// What a proposal needs of the dot's observation of the caret: which
/// process and field have focus, when the tracker began the read that
/// found it, whether the field's text or selection changed, and where the
/// caret and its field are in Accessibility coordinates, from the
/// tracker's reading or its estimate for a flat Gmail body with no caret
/// yet. `AppModel` makes it from `CaretTracker.Observation`; the checks
/// make it up.
struct ProposalObservation: Equatable, Sendable {
    var pid: pid_t?
    /// Changes whenever the focused text element changes.
    var focus: Int
    /// Changes whenever the field's text or selection changes.
    var edit: Int
    var startedAt: ContinuousClock.Instant
    /// The tracker found a focused field, whether or not it placed a caret.
    var focused: Bool
    /// The caret and its field, placed or estimated.
    var caret: CGRect?
    var field: CGRect?
    var selection: FieldRange? = nil
}

/// A screen the card can be on: its frame and its visible frame, in AppKit
/// coordinates. The app reads `NSScreen`; the checks make screens up.
struct ProposalScreen: Equatable, Sendable {
    var frame: CGRect
    var visible: CGRect
}

/// What a reply proposal shows, for the caret dot: nothing, a request on
/// its way, or its card on screen (`DictationIndicators.dotLook`).
enum ProposalPresentation: Equatable, Sendable {
    case idle, pending, shown
}

/// What a dictation's words are to the reply proposals, asked once the
/// words have come back for an email body (`ReplyProposalController.parentForWords`).
enum ProposalParentAnswer: Equatable, Sendable {
    /// No card showed when the recording began: the words are written into
    /// an email as voice compose writes them.
    case noCard
    /// The card that showed when the recording began, still bound as it was
    /// made: the writer regenerates from it.
    case parent(ProposalParent)
    /// A card showed when the recording began, and it ended during the
    /// recording or the reply changed since recording began: no email is
    /// asked for, and the words are typed with the notice.
    case lost
}

/// The proposal a recording began over, which dictation keeps with the
/// recording (`ReplyProposalController.dictationStarted`), so the words that
/// come back are a change to it whatever happens meanwhile: regenerated
/// from it while it still stands, and otherwise typed with the notice and
/// marked as a change.
struct ProposalChangeIntention: Equatable, Sendable {
    let generation: UInt64
    /// Started with this recording, independent of earlier proposal reads.
    let snapshot: ComposeRead

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && lhs.snapshot === rhs.snapshot
    }
}

/// How a proposal ended, in the fixed names the log and telemetry carry.
/// Never shown: overtaken, which nothing ends a proposal as since October
/// 8, 2026, when typing stopped cancelling the request; late, when it arrived while focus was away and
/// never showed; dropped, when the bindings refused it before it showed;
/// cancelled for another reason, a dictation starting, leaving for another
/// reply or a setting going off; failed, or abstained, when the server
/// answered without text. Shown, and then: inserted into the field after
/// the person's accept, changed by the person's words and the change
/// inserted, ignored when an insertion is cancelled after
/// the accept, dismissed by Escape, left when
/// the person never came back to it, expired when its five minutes passed
/// on screen, its insertion refused, or unconfirmed when a paste went out
/// and the field did not show it. The controller never ends one as merely
/// shown.
typealias ProposalOutcome = ProposalTiming.Outcome

/// The first thing that keeps proposals from being made now, as a fixed
/// name the log carries as "proposal.off.<name>" (`ReplyProposalController.gate`).
enum ProposalGate: String, Equatable, Sendable {
    /// "Draft replies for me" is off.
    case setting
    /// "Write emails for me" is off.
    case writesEmails
    /// The dot at the caret is hidden.
    case indicator
    case accessibility
    /// The writer itself is switched off, as it is while "Write emails for
    /// me" is off.
    case writerDisabled = "writer.disabled"
    /// This build names no backend.
    case writerNotConfigured = "writer.notConfigured"
    /// The writer holds no signed-in account.
    case writerSignedOut = "writer.signedOut"
    /// The server reported writing off or not configured, remembered
    /// until the account changes.
    case writerUnavailable = "writer.unavailable"
}

/// What cancelled an accept after the person's Tab or Accessibility
/// press: Escape, an edit in the body, focus leaving it, a screen lock,
/// display sleep or a reset. Set once on the main actor, and read on the
/// main actor after each await of the accept and by the inserter's final
/// check on its executor, after its last read of the field and right
/// before the write or the paste key, so a latch set while the inserter
/// reads the field or waits for the clipboard still refuses the write.
final class AcceptLatch: Sendable {
    private struct State {
        var cause: ProposalOutcome?
        var selectionChecks = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let selectionValidation = DispatchGroup()

    /// Latches with `cause`, unless something latched it first.
    func set(_ cause: ProposalOutcome) {
        state.withLock { if $0.cause == nil { $0.cause = cause } }
    }

    var cause: ProposalOutcome? { state.withLock { $0.cause } }
    func beginSelectionCheck() {
        state.withLock { $0.selectionChecks += 1; selectionValidation.enter() }
    }
    func endSelectionCheck() {
        state.withLock { $0.selectionChecks -= 1; selectionValidation.leave() }
    }

    /// Only the insertion executor waits here, before it rereads the field.
    /// Selection reads run independently and finish through the main actor.
    func waitForSelection(until deadline: ContinuousClock.Instant) {
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        if seconds > 0 { _ = selectionValidation.wait(timeout: .now() + seconds) }
    }

    var refuses: Bool { state.withLock { $0.cause != nil || $0.selectionChecks > 0 } }

}

/// Proposes a reply when a reply opens: watches the caret tracker for
/// focus landing in Gmail's reply body, reads the untouched body and what
/// the window shows around it the way voice compose does, asks the draft
/// route for a proposal with the fixed cue, shows it on the card at the
/// caret, and puts it in when the person accepts. It never writes into a
/// field by itself: acceptance is Tab or an explicit Accessibility press,
/// and a spoken change goes through dictation. The person's
/// typing and editor changes leave the proposal available. Tab selects a
/// non-empty body first; a second Tab confirms replacement of that exact
/// visible selection. Accessibility events never attribute edits to keys.
/// The design is docs/design/auto-draft-reply.md; the states below are
/// its pending, shown, hidden and ended.
///
/// In Gmail the request can start earlier, when the thread opens
/// (`threadOpened`, from `GmailThreadWatch`), from what the thread view
/// shows. Its answer is held for that thread (`HeldThread`) and taken by
/// the reply when its body takes focus and reads as the same thread, with
/// the reads and checks every proposal gets, so the card shows with no
/// request then; a reply that reads otherwise asks afresh as before.
///
/// One proposal is kept at a time: one left for another reply ends. Every
/// body read is bound to the body's element in the app's launch, so it
/// reads nothing of another field, and a hidden card shows again only after
/// a fresh read of everything it is bound to. The last `endedLimit` bodies
/// whose proposal ended are not proposed into again; see `endedBodies` for
/// what that memory does not cover.
///
/// Nothing read here is logged: the log carries the fixed outcome names
/// of `ProposalOutcome`, the fixed names of the gates that stop a reply
/// before a request, and stage timings only.
@MainActor
final class ReplyProposalController {
    /// Focus must stay in the body this long, with no change to the field
    /// and no key pressed, before anything beyond the field's description
    /// is read. A change with no key pressed since the settle began starts
    /// the wait again; one after a key press is the person's and ends it.
    static let settle: Duration = .milliseconds(250)
    /// How long a proposal is kept for the body it was made for, from its
    /// arrival; it does not restart. A recording over the card keeps the
    /// card on screen past it, but words that come back after it find the
    /// parent gone.
    static let keep: Duration = .seconds(5 * 60)
    /// How long an accept may take from the person's action to the write:
    /// the writer's limit for one request, since the server's accept, the
    /// read before inserting and the write all fall inside it.
    static let acceptLimit: Duration = EmailWriter.requestLimit
    /// How many bodies whose proposal ended are remembered, so none is
    /// proposed into again; the oldest goes first.
    static let endedLimit = 16
    /// The fixed cue of a proposal, the writer's.
    static let cue = EmailWriter.proposalCue
    /// What a proposal is bound to: a change to any of it ends the
    /// proposal for good.
    struct Binding: Sendable {
        var account: Int
        var pid: pid_t
        var started: UInt64?
        var element: AXElement
        /// The tracker's focus serial for the body; it changes when focus
        /// leaves and comes back, which the element does not.
        var focus: Int
        var threadID: String
        var recipients: [WritingRecipient]
        var subject: String
        var thread: String
        var body: String
        /// The selection when this binding's body was read.
        var selection: FieldRange

        init(account: Int, focus: Int, capture: ComposeCapture) {
            self.account = account
            pid = capture.field.pid
            started = capture.field.started
            element = capture.field.element
            self.focus = focus
            threadID = capture.observation.threadID ?? ""
            recipients = capture.observation.recipients
            subject = capture.observation.subject
            thread = capture.observation.thread
            body = capture.observation.body
            selection = capture.selection
        }

        /// The body as a later read must find it focused.
        var expectation: ExpectedFocus { ExpectedFocus(pid: pid, started: started, element: element) }

        /// Whether a fresh read of the reply still reads as bound: the same
        /// element in the same launch of the app, the whole body read, the
        /// selection, and the thread's id, recipients, subject, thread and
        /// body as they were. The selection is compared here, from the read
        /// itself, so a caret moved before the tracker reports the edit
        /// still refuses.
        func matches(_ capture: ComposeCapture) -> Bool {
            matchesApartFromBody(capture) && capture.selection == selection && body == capture.observation.body
        }

        func differences(_ capture: ComposeCapture, account: Int) -> [String] {
            let observation = capture.observation
            var names: [String] = []
            if recipients != observation.recipients { names.append("recipients") }
            if subject != observation.subject { names.append("subject") }
            if thread != observation.thread { names.append("thread") }
            if threadID != (observation.threadID ?? "") { names.append("threadID") }
            if !capture.bodyComplete || !body.utf8.elementsEqual(observation.body.utf8) { names.append("body") }
            if self.account != account { names.append("account") }
            if capture.field.pid != pid || capture.field.started != started || !capture.field.element.sameElement(as: element) { names.append("element") }
            return names
        }

        /// Gmail may finish its header after its initially blank reply was read.
        func allowsHeaderCompletion(_ capture: ComposeCapture, account: Int) -> Bool {
            let names = differences(capture, account: account)
            return !names.isEmpty && names.allSatisfy { $0 == "recipients" || $0 == "subject" }
                && (recipients == capture.observation.recipients || recipients.isEmpty && !capture.observation.recipients.isEmpty)
                && (subject == capture.observation.subject || subject.isEmpty && !capture.observation.subject.isEmpty)
                && ReplyProposalController.isBlank(capture)
        }

        /// `matches` without the body's text and selection, which a reply
        /// the person or editor may change:
        /// the same element in the same launch, the whole body read, and the
        /// thread's id, recipients, subject and thread as they were.
        func matchesApartFromBody(_ capture: ComposeCapture) -> Bool {
            let observation = capture.observation
            return capture.field.pid == pid && capture.field.started == started && capture.field.element.sameElement(as: element)
                && capture.bodyComplete && threadID == (observation.threadID ?? "") && recipients == observation.recipients
                && subject == observation.subject && thread == observation.thread
        }
    }

    /// Named in the log as "proposal.state.<name>" when it refuses a candidate.
    private enum State: String, Equatable {
        case idle
        /// Focus landed in a candidate body; waiting out `settle`.
        case settling
        /// The body and its surroundings are being read.
        case reading
        /// The request is on its way.
        case pending
        /// Arrived and not on screen: out of sight, or waiting for its
        /// check before showing.
        case hidden
        /// The card is on screen.
        case shown
        /// Accepted: the server's accept, the read before inserting and the
        /// write are on their way.
        case accepting
        /// Changed by the person's words: dictation writes the change.
        case changing
    }

    /// The body's frame in Accessibility coordinates, for the card's width
    /// with a caret, and, for a card placed with none, where the body is and
    /// what shows its first line in view (`BodyVisibility`): the body's
    /// position sampled with its scroll area's and window's frames at the
    /// end of one read, after its text and surroundings, and the same before
    /// and after them, so a position is judged only by the frames read with
    /// it. Every read that gives them replaces both. The evidence is as
    /// fresh as that read, so a card placed from it takes no accept while a
    /// newer observation's reread is on its way (`readGeometry`).
    private struct Geometry {
        var frame: CGRect?
        var visibility: BodyVisibility?

        init(frame: CGRect? = nil, visibility: BodyVisibility? = nil) {
            self.frame = frame
            self.visibility = visibility
        }

        /// The body's sampled frame, only while its first line is inside the
        /// visible part of its scroll area and its window.
        var visibleFrame: CGRect? {
            guard let visibility, visibility.showsFirstLine else { return nil }
            return visibility.body
        }
    }

    private enum Admission {
        case reported(EmailWriter.Admission)
        case interrupted(visibility: UInt64)
    }

    private struct Current {
        var binding: Binding
        var capture: ComposeCapture
        /// For the card's width with a caret, and for a card placed with none.
        var geometry: Geometry
        var proposal: EmailWriter.Proposal?
        var failure: EmailWriter.Problem?
        var diagnostics = EmailWriter.ProposalDiagnostics()
        var generation: UInt64
        var opened: ContinuousClock.Instant
        var requested: ContinuousClock.Instant?
        var arrived: ContinuousClock.Instant?
        var shownAt: ContinuousClock.Instant?
        /// When its keep time ends, from its arrival: a timer ends it then,
        /// and the clock is compared wherever it is used, so a timer that
        /// fires late, or one deferred for a recording, never lets it stand.
        var expires: ContinuousClock.Instant?
        /// The answer arrived while focus was away from the reply.
        var arrivedAway = false
        /// The person's accept, once there is one.
        var latch: AcceptLatch?
        /// What asked for it: the reply's body taking focus, or its thread
        /// opening, which `opened` then marks.
        var trigger = ProposalTiming.Trigger.reply
        /// When the reply's body took focus.
        var replyFocused: ContinuousClock.Instant?
        /// Each body gets its own sample, independently of the proposal's
        /// first showing and focus retained above for its lifetime.
        var replyOpened: ContinuousClock.Instant?
        var replyShown: ContinuousClock.Instant?
        /// The server's admission of its card, asked once for the proposal
        /// and kept with it, so a card shown again, or one taken back from
        /// `held`, waits on no second request (`admission(for:)`).
        var admission: Task<Admission, Never>?
        /// The thread view exposed no sender address. Its receipt must promise
        /// participant validation before the reply can use its proposal.
        var requiresThreadParticipants = false
        /// Fences binding reads when the body or its selection changes.
        var edits = 0
        var askedAgain = false
        var retentionID = UUID()
        var retentionScope: String?
    }

    /// A Gmail thread the watch reported open, as a held answer is keyed:
    /// the account, the browser's launch and the thread's id.
    struct ThreadKey: Equatable, Sendable {
        var account: Int
        var pid: pid_t
        var started: UInt64?
        var threadID: String
    }

    /// The answer for a thread, held until a reply in it takes focus, its
    /// keep time passes, the thread reads differently, or a reset: asked
    /// for when the thread opened, or a proposal a reply took and left,
    /// unused, for another reply. At most one is on its way at a time.
    private struct HeldThread {
        let key: ThreadKey
        /// What the thread view or the reply showed, as it was sent.
        let body: EmailBody
        let generation: UInt64
        let opened: ContinuousClock.Instant
        var requested: ContinuousClock.Instant?
        var answer: HeldAnswer
        var importNoticePending = false
        var diagnostics = EmailWriter.ProposalDiagnostics()
        var retentionID = UUID()
        var retentionScope: String?
    }

    /// A completed proposal held for its thread, with what it carries from
    /// the reply that may already have shown it.
    private struct Kept {
        let proposal: EmailWriter.Proposal
        let arrived: ContinuousClock.Instant
        let expires: ContinuousClock.Instant
        var admission: Task<Admission, Never>?
        var askedAgain = false
        var shown: ContinuousClock.Instant?
        var replyFocused: ContinuousClock.Instant?
        var trigger = ProposalTiming.Trigger.thread
        /// A proposal held after leaving its reply can return to that element
        /// with typed text. Thread-view proposals have no reply binding yet.
        var replyBinding: Binding?
    }

    private enum HeldAnswer {
        case pending
        case ready(Kept)
        /// No proposal will come for this thread as it reads: the server
        /// abstained, or the newest message is the person's own. The reply
        /// asks for none either until the keep time passes. `hint` is true
        /// until a reply has said so (`nothingToAnswer`), and only when
        /// there is nothing to answer: the newest message is the person's
        /// own, or the server answered `nothing_to_answer`.
        case nothing(expires: ContinuousClock.Instant, hint: Bool)

        var isPending: Bool {
            if case .pending = self { true } else { false }
        }

        var expires: ContinuousClock.Instant? {
            switch self {
            case .pending: nil
            case let .ready(kept): kept.expires
            case let .nothing(expires, _): expires
            }
        }

        var arrived: ContinuousClock.Instant? {
            if case let .ready(kept) = self { kept.arrived } else { nil }
        }
    }

    /// How many threads' answers are held; the oldest goes first.
    static let heldLimit = 8

    private let inserter: TextInserter
    private let reader: any ProposalReading
    private let writer: EmailWriter
    private let screens: () -> [ProposalScreen]
    private let settle: Duration
    private let keep: Duration
    private let acceptLimit: Duration
    private let card: any ProposalCardPresenting
    @ObservationIgnored var archive: InteractionArchive?
    private let history: DictationHistory
    /// Tells the dictation key's tap to take a plain Tab for the card with
    /// this generation, or nil to stop.
    private let takeTab: (UInt64?) -> Void
    /// The person's dictation key as Settings names it, for the card's key row.
    private let dictationKeyName: () -> String
    /// The first gate that keeps proposals from being made now, or nil
    /// when they may be (`gate(draftsReplies:writesEmails:dotChosen:accessibility:writer:)`).
    private let gate: () -> ProposalGate?
    /// The account counter dictation keeps, so a proposal made under one
    /// account is never shown or accepted under another.
    private let account: () -> Int
    /// Whether dictation is idle: no candidate starts while it records,
    /// finishes or writes.
    private let dictationIdle: () -> Bool
    /// Runs when an accepted proposal could not go in, with why and the
    /// text, for the popup that offers Copy.
    var notInserted: ((EditReason, String) -> Void)?
    var insertionUncertain: (() -> Void)?
    /// A visible end to an unavailable proposal, including a second binding failure.
    var unavailable: (() -> Void)?
    /// A context failure is shown only while its reply has focus.
    var mailImportPending: (() -> Void)?
    /// Runs when an untouched reply gets no proposal because there is
    /// nothing to answer, for the quiet hint beside the dot: once for each
    /// thread as it reads, never for a refocus or a reread of it.
    var nothingToAnswer: (() -> Void)?
    /// Runs when a proposal ends, with its outcome, for telemetry.
    var ended: ((ProposalOutcome, ProposalTrace) -> Void)?
    /// Runs once when a reply lets go of its proposal, separately from the
    /// proposal's lifetime, which can span several reply bodies.
    var replyEnded: ((ProposalOutcome, ProposalTrace) -> Void)?
    /// Delays a queued thread request in synthetic scheduling checks.
    var beforeThreadRequest: (() async -> Void)?
    /// Runs when what the proposal shows changes, for the caret dot.
    var presentationChanged: ((ProposalPresentation) -> Void)?
    /// Runs when an accepted proposal went in, with whether the clipboard
    /// it borrowed went back (nil when none was borrowed), so the app says
    /// so as it does for a dictation (`DictationController.proposalInserted`).
    var clipboardReported: ((Bool?) -> Void)?

    private var state = State.idle {
        didSet { if state != oldValue { present() } }
    }
    private var presented = ProposalPresentation.idle
    private var current: Current?
    private var quitting = false
    private var lastObservation: ProposalObservation?
    /// A focus as the tracker counts it: the process and its focus serial.
    private struct FocusKey: Equatable {
        let pid: pid_t?
        let focus: Int

        init(_ observation: ProposalObservation) {
            pid = observation.pid
            focus = observation.focus
        }
    }
    /// The focus a candidate read was last started for. An observation of
    /// a focused field under any other focus starts one, so each focus is
    /// read once: when it lands, when the tracker first finds the field
    /// under that focus readable after finding it absent, or, when
    /// dictation held the read off, once dictation is idle again.
    private var candidateFocus: FocusKey?
    /// The candidate read on its way, nil once it has answered or was
    /// cancelled.
    private var candidateTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    /// Changes with every candidate's settle and every cancel of one, so a
    /// settle that wakes after another began leaves it alone.
    private var settleID: UInt64 = 0
    private var keepTask: Task<Void, Never>?
    private var validityTask: Task<Void, Never>?
    private let validityInterval: Duration
    private var generations: UInt64 = 0
    /// Changes when the card shows or hides and when focus moves. A display
    /// check shows the card only if it has not changed since the check
    /// began, and Tab is taken with the value it had when the card showed.
    private var visibility: UInt64 = 0
    /// The generation Tab was taken with for the card on screen.
    private var tabGeneration: UInt64?
    /// The visibility a display check in flight began at.
    private var checkingAt: UInt64? {
        didSet { present() }
    }
    /// Counts display checks, so only the latest clears `checkingAt`.
    private var displayChecks: UInt64 = 0
    /// Where the card last failed to fit; it is not checked again until
    /// the anchor moves.
    private var unplaced: ProposalCardAnchor?
    /// The proposal a recording began over, until the dictation ends or
    /// asks for its parent, for the card's accepts; dictation keeps the
    /// same proposal as its `ProposalChangeIntention`.
    private var recordingBound: UInt64? { recordingIntention?.generation }
    private(set) var recordingIntention: ProposalChangeIntention?
    /// Counts the key presses the dictation key's monitors see.
    private var keySerial = 0
    /// When the last of them came, for a settle: a change while a reply
    /// settles is the person's after a key since the settle began
    /// (`typed(since:)`).
    private var lastKeyPress: ContinuousClock.Instant?
    /// A blank read permits reuse of a held thread proposal after editing
    /// starts. This is admission evidence, never permission to replace text.
    private var blankObserved = false
    /// The gate's answer as last logged, so the log carries it once per
    /// change rather than on each of the tracker's observations, about
    /// thirty a second. Nil until the first answer.
    private var loggedGate: LoggedGate?
    private struct LoggedGate: Equatable {
        let gate: ProposalGate?
    }
    /// The last reason an observation started no candidate, with its
    /// focus, logged once per focus and reason for the same cause.
    private var skipped: Skipped?
    private struct Skipped: Equatable {
        let focus: FocusKey
        let name: String
    }
    /// A read of the body's frame for a card placed from it is on its way.
    private var readingGeometry = false
    /// The visibility that read began at, so an accept knows whether it
    /// was asked for the card now on screen.
    private var geometryAt: UInt64?
    /// An accept made while that read was on its way for the card on
    /// screen, by Tab, the button or the tap: it waits for the read's
    /// evidence and is made then only if the card is still placed, within
    /// the limit that began at the first press.
    private var deferredAccept: HeldAccept?
    /// The latest accept's work, from recording acceptance to the text
    /// going in; `acceptance` names it while it is on its way.
    private var accepting: Task<Void, Never>?
    /// Bodies whose proposal ended, most recent last, so none is proposed
    /// into again. A body is named by its process, the app's launch and
    /// its native element, nothing more, which limits what this does: only
    /// the last `endedLimit` are kept, and the oldest goes even while its
    /// body is still open, so returning to it then proposes again; an
    /// element Gmail reuses for another thread is still named the same, so
    /// that thread's reply gets no proposal until the element is evicted;
    /// and a reset (`reset`) forgets nothing but does not remember the
    /// body it ended, so the same reply can be proposed into again once
    /// proposals are back on.
    private var endedBodies: [ExpectedFocus] = []
    /// Answers held for Gmail threads, oldest first.
    private var held: [HeldThread] = []
    /// Lets go of held answers when the first of their keep times passes.
    private var heldExpiry: Task<Void, Never>?
    /// An open refused during dictation gets one fresh page read once idle.
    /// The watch rereads the page then, so leaving the thread cannot submit
    /// the snapshot that was refused.
    var retryThreadOpen: (() -> Void)?
    private var deferredThreadOpen = false

    init(inserter: TextInserter, reader: (any ProposalReading)? = nil, writer: EmailWriter, card: any ProposalCardPresenting,
         history: DictationHistory, takeTab: @escaping (UInt64?) -> Void, dictationKeyName: @escaping () -> String,
         gate: @escaping () -> ProposalGate?, account: @escaping () -> Int, dictationIdle: @escaping () -> Bool,
         screens: @escaping () -> [ProposalScreen] = { NSScreen.screens.map { ProposalScreen(frame: $0.frame, visible: $0.visibleFrame) } },
         settle: Duration = ReplyProposalController.settle, keep: Duration = ReplyProposalController.keep,
         acceptLimit: Duration = ReplyProposalController.acceptLimit,
         validityInterval: Duration = .seconds(5)) {
        self.inserter = inserter
        self.reader = reader ?? inserter
        self.writer = writer
        self.screens = screens
        self.settle = settle
        self.keep = keep
        self.acceptLimit = acceptLimit
        self.validityInterval = validityInterval
        self.card = card
        self.history = history
        self.takeTab = takeTab
        self.dictationKeyName = dictationKeyName
        self.gate = gate
        self.account = account
        self.dictationIdle = dictationIdle
        card.accepted = { [weak self] in self?.accept(by: "accessibility") }
        card.screenLockedOrAsleep = { [weak self] in self?.screenLockedOrAsleep() }
    }

    /// The first thing that keeps proposals from being made, or nil when
    /// they may be: "Draft replies for me" on, "Write emails for me" on,
    /// the dot as the indicator, Accessibility granted, and the writer able
    /// to write now, which needs a backend and a signed-in account and
    /// writing not remembered as unavailable. The microphone plays no part:
    /// a card is read and accepted without it.
    static func gate(draftsReplies: Bool, writesEmails: Bool, dotChosen: Bool, accessibility: Bool,
                     writer: EmailWriter) -> ProposalGate? {
        if !draftsReplies { return .setting }
        if !writesEmails { return .writesEmails }
        if !dotChosen { return .indicator }
        if !accessibility { return .accessibility }
        if !writer.isEnabled { return .writerDisabled }
        switch writer.availability {
        case nil: return nil
        case .notConfigured?: return .writerNotConfigured
        case .signedOut?: return .writerSignedOut
        default: return .writerUnavailable
        }
    }

    /// Whether proposals may be made now. The gate's answer is logged when
    /// it differs from the last one logged: "proposal.on", or
    /// "proposal.off.<gate>" naming the first gate that is shut.
    private func isEnabled() -> Bool {
        guard !quitting else { return false }
        let answer = gate()
        if loggedGate != LoggedGate(gate: answer) {
            loggedGate = LoggedGate(gate: answer)
            log(answer.map { "proposal.off.\($0.rawValue)" } ?? "proposal.on")
        }
        return answer == nil
    }

    /// Logs why an observation under `focus` started no candidate, once
    /// for the same focus and reason, since observations come about
    /// thirty times a second. `name` is one of this controller's fixed names.
    private func logSkipped(_ name: String, focus: FocusKey) {
        let now = Skipped(focus: focus, name: name)
        guard skipped != now else { return }
        skipped = now
        log(name)
    }

    /// Connects the proposals to the dictation key's monitors and tap and
    /// to dictation, as the app runs them: Tab taken while the card shows
    /// accepts, Escape dismisses or latches an accept, any key press
    /// restarts a settle and stands behind the field's next changes, and
    /// dictation tells the proposals when it records
    /// and asks them for a spoken change's parent.
    func connect(to holdKey: HoldKey, dictation: DictationController) {
        dictation.proposals = self
        holdKey.onMouseDown = { [weak self] in self?.clicked() }
        holdKey.onScroll = { [weak self] in self?.confirmationGeometryChanged() }
        holdKey.tabTaken = { [weak self] generation in self?.tabTaken(generation: generation) }
        holdKey.escapePressed = { [weak self] in self?.escapePressed() }
        holdKey.keyPressed = { [weak self] code, flags in self?.keyPressed(keyCode: code, flags: flags) }
    }

    /// Whether a Gmail thread opening may be read for a proposal now: the
    /// gate is open. `GmailThreadWatch` reads nothing while it is shut.
    var watchesThreads: Bool { gate() == nil }

    /// What `GmailThreadWatch` calls on its Accessibility thread for each
    /// thread it reads open. It reaches the main actor itself, at once on
    /// the main thread and through the main queue anywhere else, so it is
    /// safe to call from any queue.
    nonisolated static func threadReporter(to controller: ReplyProposalController) -> @Sendable (GmailThreadView) -> Void {
        { [weak controller] view in
            if Thread.isMainThread {
                MainActor.assumeIsolated { controller?.threadOpened(view) }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { controller?.threadOpened(view) }
                }
            }
        }
    }

    /// The threads whose answers are held, by key, with whether each is
    /// still on its way, for the checks.
    var heldThreads: [(key: ThreadKey, pending: Bool)] { held.map { ($0.key, $0.answer.isPending) } }

    /// What is on screen or kept, for the checks.
    var isShown: Bool { state == .shown }
    var isPending: Bool { state == .pending }
    var isHidden: Bool { state == .hidden }
    /// Whether an accept is on its way.
    var isAccepting: Bool { state == .accepting }
    /// The accept on its way, from the server's record of it to its text
    /// going in or being refused; nil when none is. A recording that starts
    /// meanwhile starts at once, and dictation puts its text in only once
    /// this has ended, as it waits for an earlier dictation's.
    var acceptance: Task<Void, Never>? { state == .accepting ? accepting : nil }
    // MARK: Gmail threads

    /// A Gmail thread opened in its thread view, read once for this open by
    /// `GmailThreadWatch`. Under the same gates as a reply, a proposal is
    /// asked for from what it shows, as a reply in it would be asked, and
    /// held for the thread. Another thread's request still on its way, and
    /// a reply's request in another thread, are cancelled by id first; an
    /// answer that has come stays until its keep time passes. A thread
    /// whose answer is held, or whose reply's proposal is kept, and that
    /// reads as it did, asks for nothing again, and nor does one whose
    /// newest message is the person's own.
    func threadOpened(_ view: GmailThreadView) {
        deferredThreadOpen = false
        guard isEnabled() else { return }
        log("proposal.thread.opened")
        let key = ThreadKey(account: account(), pid: view.pid, started: view.started, threadID: view.threadID)
        let body = Self.threadBody(view)
        pruneHeld()
        // The person left whatever other thread a request is on its way for.
        if let index = held.firstIndex(where: { $0.answer.isPending && $0.key != key }) { discardHeld(at: index) }
        if state == .pending, let current, Self.key(of: current.binding) != key { end(.cancelled) }
        if let index = held.firstIndex(where: { $0.key == key }) {
            // A thread that answers nothing is held by its messages and subject
            // alone, as `takeHeld` holds it: a reply's own request recorded the
            // reply's recipients, not the newest sender.
            let answersNothing = if case .nothing = held[index].answer { true } else { false }
            if Self.refusal(of: held[index].body, for: body, expired: false, recipients: !answersNothing) == nil {
                // Read the same: what is held, or on its way, stands.
                return log("proposal.thread.reused")
            }
            // A new message, or the thread reads otherwise: what is held
            // answers the thread as it was.
            discardHeld(at: index)
        }
        // The proposal of a reply in this thread stands.
        if let current, Self.key(of: current.binding) == key, [.pending, .hidden, .shown, .accepting, .changing].contains(state) {
            return log("proposal.thread.reused")
        }
        guard dictationIdle() else {
            deferredThreadOpen = true
            return log("proposal.busy.dictation")
        }
        guard state != .accepting, state != .changing else { return log("proposal.state.\(state.rawValue)") }
        let now = ContinuousClock.now
        if let sender = view.newestSender, let account = view.account, sender.caseInsensitiveCompare(account) == .orderedSame {
            log("proposal.thread.skipped.own")
            return hold(HeldThread(key: key, body: body, generation: 0, opened: now, answer: .nothing(expires: now + keep, hint: true)))
        }
        generations &+= 1
        let generation = generations
        hold(HeldThread(key: key, body: body, generation: generation, opened: now, requested: now, answer: .pending))
        log("proposal.thread.requested")
        Task { [weak self] in
            await self?.beforeThreadRequest?()
            await self?.requestThread(generation, body: body)
        }
    }

    /// The proposal a thread's request asked for, held for the thread, or,
    /// when its reply took the request while it was on its way, handed to
    /// that reply's proposal as its own request's answer is.
    private func requestThread(_ generation: UInt64, body: EmailBody) async {
        // Adoption can move the entry before this task gets the actor. A
        // cancelled or replaced entry must still prevent a queued request.
        guard held.contains(where: { $0.generation == generation && $0.answer.isPending })
            || (current?.generation == generation && state == .pending) else { return }
        var diagnostics = EmailWriter.ProposalDiagnostics()
        let outcome = await writer.propose(body: body, diagnosed: { [weak self] update in
            diagnostics = update
            self?.recordDiagnostics(update, generation: generation)
        }) { [weak self] id, scope in
            self?.bindRetention(generation, id: id, scope: scope)
        }
        if current?.generation == generation { return received(outcome, generation: generation, diagnostics: diagnostics) }
        guard let index = held.firstIndex(where: { $0.generation == generation }), held[index].answer.isPending else { return }
        let now = ContinuousClock.now
        switch outcome {
        case let .success(proposal):
            held[index].answer = .ready(Kept(proposal: proposal, arrived: now, expires: now + keep))
            log("proposal.thread.arrived")
            scheduleHeldExpiry()
        case let .failure(problem):
            log("proposal.\(EmailWriter.name(problem))")
            let entry = held[index]
            switch problem {
            case let .abstained(reason):
                held[index].answer = .nothing(expires: entry.opened + keep, hint: reason == .nothingToAnswer)
                held[index].importNoticePending = problem.isMailImportPending
                report(entry, .abstained, arrived: now, failure: problem, diagnostics: diagnostics)
                scheduleHeldExpiry()
            case .withdrawn, .cancelled:
                held.remove(at: index)
                report(entry, .cancelled, failure: problem, diagnostics: diagnostics)
            default:
                held.remove(at: index)
                report(entry, .failed, failure: problem, diagnostics: diagnostics)
            }
        }
    }

    /// What a reply in the thread would send, as the thread view shows it:
    /// Gmail's empty reply body, the newest message's sender as the one it
    /// goes to, the thread's subject as a reply's, the messages and the id.
    static func threadBody(_ view: GmailThreadView) -> EmailBody {
        let subject = view.subject.isEmpty || view.subject.contains(ComposeInput.replyPrefix) ? view.subject : "Re: \(view.subject)"
        return EmailBody(bundleIdentifier: nil, body: "\n",
                         recipients: view.newestSender.map { [WritingRecipient(address: $0, role: .to)] } ?? [],
                         subject: subject, thread: view.thread, threadID: view.threadID, kind: .reply, inThread: true)
    }

    /// Why a reply that read as `fresh` cannot take what was asked for its
    /// thread from `sent`, by the fixed name the log carries as
    /// "proposal.thread.refused.<name>", or nil when it can: the thread's
    /// messages, known recipients unless `recipients` is false, and the
    /// subject read the same, a reply's `Re:` aside, and its time has not
    /// passed. A thread that answers nothing is held by its messages and
    /// subject alone. Unknown recipients require the server's participant
    /// admission capability in `takeHeld`. A reply to the person's own message goes to
    /// whoever they wrote to, not to its sender.
    static func refusal(of sent: EmailBody, for fresh: EmailBody, expired: Bool, recipients: Bool = true,
                        allowUnknownRecipients: Bool = false) -> String? {
        if expired { return "expired" }
        if sent.threadID != fresh.threadID { return "thread" }
        if sent.thread != fresh.thread { return "thread" }
        let addresses = { (body: EmailBody) in body.recipients.map { $0.address.lowercased() } }
        if recipients, !(allowUnknownRecipients && sent.recipients.isEmpty), addresses(sent) != addresses(fresh) { return "recipients" }
        if baseSubject(sent.subject) != baseSubject(fresh.subject) { return "subject" }
        return nil
    }

    /// A subject without the `Re:` or its like a reply puts before it.
    static func baseSubject(_ subject: String) -> String {
        var rest = Substring(subject)
        while let match = rest.firstMatch(of: ComposeInput.replyPrefix) { rest = rest[match.range.upperBound...] }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func key(of binding: Binding) -> ThreadKey {
        ThreadKey(account: binding.account, pid: binding.pid, started: binding.started, threadID: binding.threadID)
    }

    private func hold(_ original: HeldThread) {
        var entry = original
        if entry.retentionScope == nil { entry.retentionScope = archive?.scope }
        held.removeAll { $0.key == entry.key && !$0.answer.isPending }
        held.append(entry)
        while held.count > Self.heldLimit { discardHeld(at: held.firstIndex { !$0.answer.isPending } ?? 0) }
        scheduleHeldExpiry()
    }

    /// Lets go of the answers whose keep time has passed, each reported
    /// as ended when its time passed; one a reply showed goes to history
    /// as proposed and not used, as a shown proposal that is left does.
    private func pruneHeld() {
        let now = ContinuousClock.now
        for index in held.indices.reversed() {
            guard let expires = held[index].answer.expires, now >= expires else { continue }
            let entry = held.remove(at: index)
            if case .ready = entry.answer { report(entry, .left, at: expires) }
        }
    }

    /// Wakes when the first held answer's keep time passes and lets it go,
    /// so no proposal's text stays held past it while nothing else runs.
    private func scheduleHeldExpiry() {
        heldExpiry?.cancel()
        guard let first = held.compactMap(\.answer.expires).min() else {
            heldExpiry = nil
            return
        }
        heldExpiry = Task { [weak self] in
            try? await Task.sleep(until: first)
            guard !Task.isCancelled, let self else { return }
            self.pruneHeld()
            self.scheduleHeldExpiry()
        }
    }

    /// Lets go of one held answer: one on its way is cancelled by id, and
    /// one that came is reported as left.
    private func discardHeld(at index: Int) {
        let entry = held.remove(at: index)
        switch entry.answer {
        case .pending:
            writer.cancelProposal()
            var diagnostics = entry.diagnostics
            diagnostics.failureKind = .withdrawn
            report(entry, .cancelled, failure: .withdrawn, diagnostics: diagnostics)
        case .ready:
            report(entry, .left)
        case .nothing:
            break
        }
        scheduleHeldExpiry()
    }

    /// Cancels by id the thread request on its way, if there is one, before
    /// the writer is asked for anything else, since it serves one request
    /// at a time; what has come stays held.
    private func cancelThreadRequest() {
        guard let index = held.firstIndex(where: { $0.answer.isPending }) else { return }
        discardHeld(at: index)
    }

    /// Reports a held answer no reply took, as `close` reports a proposal:
    /// the fixed name in the log, the timing to telemetry. One no card
    /// showed keeps no history; one a reply showed and left goes to history
    /// as proposed and not used.
    private func report(_ entry: HeldThread, _ outcome: ProposalOutcome, arrived: ContinuousClock.Instant? = nil,
                        at ended: ContinuousClock.Instant = .now, failure: EmailWriter.Problem? = nil,
                        diagnostics: EmailWriter.ProposalDiagnostics = .init()) {
        log("proposal.thread.\(outcome.rawValue)")
        var diagnostics = diagnostics
        var shown: ContinuousClock.Instant?, replyFocused: ContinuousClock.Instant?, trigger = ProposalTiming.Trigger.thread
        if case let .ready(kept) = entry.answer {
            diagnostics = kept.proposal.diagnostics
            shown = kept.shown
            replyFocused = kept.replyFocused
            trigger = kept.trigger
            if shown != nil {
                history.add(.init(id: UUID(), date: Date(), text: kept.proposal.text, outcome: .notInserted, reason: outcome.rawValue,
                                  spoken: nil, proposal: .unused))
            }
        }
        let trace = ProposalTrace(opened: entry.opened, requested: entry.requested, arrived: arrived ?? entry.answer.arrived,
                                  shown: shown, ended: ended, trigger: trigger, replyFocused: replyFocused, failure: failure, diagnostics: diagnostics)
        archiveClient(entry.retentionID, scope: entry.retentionScope, outcome: outcome, trace: trace)
        self.ended?(outcome, trace)
    }

    /// A proposal that came and that nobody used, left because focus went
    /// to another reply: held for its thread again, with its admission and
    /// what it carries, until its keep time passes, so a reply there takes
    /// it once more after the usual reads. Nothing else is held again: a
    /// proposal accepted, dismissed, edited over, changed or past its time
    /// is never offered again.
    private func holdAgain(_ current: Current) -> Bool {
        guard let proposal = current.proposal, let arrived = current.arrived, let expires = current.expires,
              ContinuousClock.now < expires, current.latch == nil else { return false }
        keepTask?.cancel()
        keepTask = nil
        validityTask?.cancel()
        validityTask = nil
        if state == .shown {
            card.hide()
            takeTab(nil)
        }
        tabGeneration = nil
        visibility &+= 1
        reportReply(current, .left)
        let kept = Kept(proposal: proposal, arrived: arrived, expires: expires, admission: current.admission, askedAgain: current.askedAgain, shown: current.shownAt,
                        replyFocused: current.replyFocused, trigger: current.trigger, replyBinding: current.binding)
        hold(HeldThread(key: Self.key(of: current.binding), body: current.capture.observation, generation: current.generation,
                        opened: current.opened, requested: current.requested, answer: .ready(kept),
                        retentionID: current.retentionID, retentionScope: current.retentionScope))
        log("proposal.thread.heldAgain")
        cancelReplacement()
        insertionSelection = nil
        self.current = nil
        checkingAt = nil
        unplaced = nil
        deferredAccept = nil
        state = .idle
        card.acceptsInput = true
        return true
    }

    /// The reply read as `capture` takes what is held for its thread, when
    /// it reads as it was sent: an answer that came shows after the check
    /// every card gets, after its admission, with no request; one
    /// still on its way becomes this reply's own request and shows when it
    /// comes, after the same check; and a thread that answers nothing asks
    /// for nothing. False when nothing is held for the thread, or what is
    /// held was refused and let go, and the reply asks afresh.
    ///
    private func takeHeld(_ capture: ComposeCapture, focus: Int, geometry: Geometry, replyFocused: ContinuousClock.Instant) -> Bool {
        pruneHeld()
        let key = ThreadKey(account: account(), pid: capture.field.pid, started: capture.field.started,
                            threadID: capture.observation.threadID ?? "")
        guard let index = held.firstIndex(where: { $0.key == key }) else { return false }
        let entry = held[index]
        if !Self.isBlank(capture), case let .ready(kept) = entry.answer, let binding = kept.replyBinding {
            guard binding.account == account(), binding.matchesApartFromBody(capture) else { return false }
        }
        let answersNothing = if case .nothing = entry.answer { true } else { false }
        // A reply's own proposal can also be held again. Only a request
        // made from the thread view needs the unknown-sender capability.
        let fromThread = if case let .ready(kept) = entry.answer { kept.trigger == .thread } else { true }
        let requestedWithoutRecipients = if case let .ready(kept) = entry.answer {
            kept.proposal.requestedWithoutRecipients
        } else { entry.body.recipients.isEmpty }
        let unknownRecipients = fromThread && requestedWithoutRecipients
        if let reason = Self.refusal(of: entry.body, for: capture.observation,
                                     expired: entry.answer.expires.map { ContinuousClock.now >= $0 } ?? false,
                                     recipients: !answersNothing, allowUnknownRecipients: unknownRecipients) {
            log("proposal.thread.refused.\(reason)")
            discardHeld(at: index)
            return false
        }
        if answersNothing {
            // Kept, so a later focus in the same reply asks for nothing either,
            // and says why only the first time.
            log("proposal.thread.nothing")
            if entry.importNoticePending, Self.isBlank(capture) {
                held[index].importNoticePending = false
                mailImportPending?()
            }
            if case let .nothing(expires, hint: true) = entry.answer, Self.isBlank(capture) {
                held[index].answer = .nothing(expires: expires, hint: false)
                nothingToAnswer?()
            }
            state = .idle
            return true
        }
        if unknownRecipients, case let .ready(kept) = entry.answer, !kept.proposal.checksThreadParticipants {
            log("proposal.thread.refused.recipientCapability")
            discardHeld(at: index)
            return false
        }
        held.remove(at: index)
        scheduleHeldExpiry()
        current = Current(binding: Binding(account: key.account, focus: focus, capture: capture), capture: capture, geometry: geometry,
                          generation: entry.generation, opened: entry.opened, requested: entry.requested, trigger: .thread,
                          replyFocused: replyFocused, replyOpened: replyFocused)
        current?.diagnostics = entry.diagnostics
        current?.retentionID = entry.retentionID
        current?.retentionScope = entry.retentionScope
        current?.requiresThreadParticipants = unknownRecipients
        if !unknownRecipients { log("proposal.thread.adopted") }
        guard case let .ready(kept) = entry.answer else {
            // Still on its way: it arrives as this reply's own request does.
            state = .pending
            return true
        }
        current?.proposal = kept.proposal
        current?.diagnostics = kept.proposal.diagnostics
        current?.arrived = kept.arrived
        current?.expires = kept.expires
        current?.admission = kept.admission
        current?.askedAgain = kept.askedAgain
        current?.shownAt = kept.shown
        current?.trigger = kept.trigger
        if kept.shown != nil { current?.replyFocused = kept.replyFocused ?? replyFocused }
        keepUntil(kept.expires, generation: entry.generation)
        state = .hidden
        if focusIsOnBinding { startDisplayCheck() }
        return true
    }

    // MARK: Watching the caret

    /// Observations keep placement and bindings current. Text edits never
    /// invalidate a proposal; only the visible replacement consent expires.
    func observe(_ observation: ProposalObservation) {
        let previous = lastObservation
        lastObservation = observation
        let focusChanged = previous?.focus != observation.focus || previous?.pid != observation.pid
        if focusChanged {
            visibility &+= 1
            blankObserved = false
        }
        guard isEnabled() else { return reset() }
        let edited = previous != nil && !focusChanged && previous?.edit != observation.edit
        if let current {
            let inBody = observation.focused && observation.pid == current.binding.pid && observation.focus == current.binding.focus
            if edited { self.current?.edits += 1 }
            if focusChanged || !inBody { cancelReplacement() }
            switch state {
            case .accepting:
                if !inBody {
                    current.latch?.set(.left)
                    card.hide()
                }
                else if edited, let expected = insertionSelection {
                    if observation.selection != expected.wholeSelection { current.latch?.set(.ignored) }
                    else { verifySelectionNotice(expected, generation: current.generation) }
                } else if edited { current.latch?.set(.ignored) }
                return
            case .changing: return
            case .pending, .hidden, .shown:
                if inBody, preparingReplacement || pendingReplacement != nil,
                   let frame = observation.field, let before = previous?.field, frame != before {
                    endConfirmationWithoutRoom()
                    return
                }
                if inBody, let selected = pendingReplacement {
                    if observation.selection != selected.selection {
                        cancelReplacement()
                    } else if edited {
                        validateReplacement(selected, generation: current.generation)
                    }
                }
                if state == .shown {
                    guard inBody else { hide(); break }
                    // Selecting the body removes its caret. Keep the card's
                    // placed anchor and Tab consent through that transition.
                    if preparingReplacement || pendingReplacement != nil { return }
                    if let anchor = anchor(from: observation) { place(anchor) } else { hide() }
                    if observation.caret == nil { readGeometry() }
                    return
                }
                if state == .hidden, inBody, !focusChanged {
                    if let anchor = anchor(from: observation), anchor != unplaced { display() }
                    else if observation.caret == nil, observation.focused { readGeometry() }
                    return
                }
            case .idle, .settling, .reading: break
            }
        }
        guard observation.focused else { return }
        let focus = FocusKey(observation)
        if focus != candidateFocus { candidate(observation) }
        else { logSkipped("proposal.focus.unchanged", focus: focus) }
    }

    var voiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }

    /// Input cancels consent, irrespective of what edit an editor later reports.
    func keyPressed(keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        // VoiceOver delivers this key and AXPress separately, in either order.
        // Only AXPress accepts; its own activation key must preserve consent.
        if keyCode == 49, flags.intersection(.deviceIndependentFlagsMask) == [.control, .option],
           voiceOverEnabled() { return }
        keySerial &+= 1
        lastKeyPress = .now
        cancelReplacement()
        if state == .accepting { current?.latch?.set(keyCode == 53 ? .dismissed : .ignored) }
        if deferredAccept != nil, keyCode != 53, let text = current?.proposal?.text {
            hide()
            finishLatched(.ignored, text: text)
        }
    }

    /// Every mouse down cancels consent without restoring the selection.
    func clicked() {
        deferredAccept = nil
        cancelReplacement()
        if state == .accepting { current?.latch?.set(.ignored) }
    }

    /// Whether a key went down at or after `start`. Without a start every
    /// key press counts.
    private func typed(since start: ContinuousClock.Instant?) -> Bool {
        guard let lastKeyPress else { return false }
        return start.map { lastKeyPress >= $0 } ?? true
    }

    /// Focus landed somewhere: on the inserter's executor, read whether it
    /// is Gmail's reply body in a Chromium browser, at the cost of the
    /// focused element, its description and, for that body, its frame and
    /// whether it is blank (`blankObserved`). While dictation is busy nothing is
    /// read, and the focus is left untried for `dictationEnded`.
    private func candidate(_ observation: ProposalObservation) {
        cancelCandidate()
        let key = FocusKey(observation)
        guard dictationIdle() else { return logSkipped("proposal.busy.dictation", focus: key) }
        guard state != .accepting, state != .changing else { return logSkipped("proposal.state.\(state.rawValue)", focus: key) }
        candidateFocus = key
        let first = reader.readProposalCandidate(expecting: nil, blank: true)
        candidateTask = Task { [weak self] in
            var read = first
            var expectedFocus: ExpectedFocus?
            // Transient reads get two retries under the same tracker focus.
            // Keeping one task owns both waits, so a refocus cancels them too.
            for attempt in 0...2 {
                let found = await read.value
                if let focus = read.focus { expectedFocus = focus }
                guard let self, !Task.isCancelled else { return }
                guard self.lastObservation.map(FocusKey.init) == key else { return self.log("proposal.candidate.focusMoved") }
                if let reason = read.rejection { self.log("proposal.candidate.reject.\(reason.rawValue)") }
                guard self.isEnabled() else { self.candidateTask = nil; return }
                guard self.dictationIdle() else {
                    self.candidateFocus = nil
                    self.candidateTask = nil
                    return self.log("proposal.busy.dictation")
                }
                if case let .failure(reason) = found, [.busy, .targetUnresponsive].contains(reason), attempt < 2 {
                    self.log("proposal.candidate.retry")
                    try? await Task.sleep(for: .milliseconds(attempt == 0 ? 100 : 250))
                    guard !Task.isCancelled, self.lastObservation.map(FocusKey.init) == key else { return }
                    read = self.reader.readProposalCandidate(expecting: expectedFocus, blank: true)
                    continue
                }
                self.candidateTask = nil
                switch found {
                case let .success(candidate?):
                    if candidate.blank == true { self.blankObserved = true }
                    self.landed(in: candidate, observation: observation)
                case .success(nil): self.log("proposal.candidate.none")
                case let .failure(reason): self.log("proposal.candidate.\(reason.rawValue)")
                }
                return
            }
        }
    }

    /// Focus is in a Gmail reply body. The body a proposal is bound to is
    /// checked and shown again; a body whose proposal ended gets none; any
    /// other ends the proposal there is and waits out its settle.
    private func landed(in candidate: ProposalCandidate, observation: ProposalObservation) {
        if let current, [.pending, .hidden, .shown].contains(state), candidate.pid == current.binding.pid,
           candidate.started == current.binding.started, candidate.element.sameElement(as: current.binding.element) {
            self.current?.binding.focus = observation.focus
            self.current?.geometry = Geometry(frame: candidate.frame, visibility: candidate.visibility)
            if state == .hidden { display() }
            return
        }
        guard state != .accepting, state != .changing else { return log("proposal.state.\(state.rawValue)") }
        if endedBodies.contains(where: { candidate.pid == $0.pid && candidate.started == $0.started && candidate.element.sameElement(as: $0.element) }) {
            log("proposal.endedBody")
            return
        }
        // Another reply: the proposal there is is over before this reply's
        // settle begins, so ending it cannot cancel the new wait.
        if let current {
            // One that came and was not used is held for its thread again.
            if state == .pending || !holdAgain(current) { end(state == .pending ? .cancelled : .left) }
        }
        settleThenRead(candidate, observation: observation, opened: observation.startedAt)
    }

    /// Waits out the settle with the same focus, no edit and no key press,
    /// then reads the body. A key press, or a change to the body with no
    /// key pressed since the settle began, which is Gmail's own as the
    /// reply opens, starts the wait again, during the read as before it. A
    /// change can adopt a held answer when the reply was initially read as
    /// empty. This settling rule does not authorize replacing its text.
    private func settleThenRead(_ candidate: ProposalCandidate, observation: ProposalObservation, opened: ContinuousClock.Instant) {
        settleID &+= 1
        let id = settleID, focus = observation.focus, began = ContinuousClock.now
        state = .settling
        settleTask = Task { [weak self] in
            var edit = observation.edit
            while true {
                guard let keys = self?.keySerial, let settle = self?.settle else { return }
                try? await Task.sleep(for: settle)
                guard let self else { return }
                switch self.settled(id, during: .settling, focus: focus, edit: edit, keys: keys, began: began, candidate: candidate) {
                case .over: return
                case .typing:
                    return await self.readTyped(candidate, id: id, focus: focus, opened: opened)
                case let .again(changed): edit = changed
                case .quiet:
                    guard let changed = await self.read(candidate, id: id, focus: focus, edit: edit, keys: keys, began: began,
                                                        opened: opened) else { return }
                    edit = changed
                }
            }
        }
    }

    /// Where a settle stands after its wait or its read.
    private enum Settled {
        /// Nothing changed and no key went down.
        case quiet
        /// Wait again, from this edit serial.
        case again(Int)
        /// The person typed in a reply that may take a held draft.
        case typing
        /// Given up, or taken over by something that ended it.
        case over
    }

    /// Whether the candidate still settles, after its wait or while its body
    /// was read (`during`): the same settle and focus, proposals on and
    /// dictation idle, and then whether the body changed or a key went down.
    /// Each reason a candidate is given up here is logged by a fixed name.
    private func settled(_ id: UInt64, during: State, focus: Int, edit: Int, keys: Int, began: ContinuousClock.Instant,
                         candidate: ProposalCandidate) -> Settled {
        // Something else ended the settle and says why itself.
        guard settleID == id, state == during else { return .over }
        guard lastObservation?.focus == focus else {
            dropCandidate(id, "proposal.settle.focusMoved")
            return .over
        }
        guard isEnabled() else {
            dropCandidate(id, nil)
            return .over
        }
        guard dictationIdle() else {
            dropCandidate(id, "proposal.busy.dictation")
            return .over
        }
        let now = lastObservation?.edit ?? edit
        if now != edit {
            if blankObserved || mayRestoreReply(for: candidate), mayHoldDraft(for: candidate) { return .typing }
            if typed(since: began) {
                dropCandidate(id, "proposal.settle.typed")
                return .over
            }
            log("proposal.settle.bodyChanged")
            return .again(now)
        }
        return keySerial != keys ? .again(edit) : .quiet
    }

    /// The body and its surroundings, as voice compose reads them, bound to
    /// the candidate, then the request. Only an untouched inline reply in
    /// Gmail's thread view with the thread's id gets one, and only with no
    /// edit and no key press while it was read; otherwise the settle starts
    /// again from the edit serial this answers, or nil when it is over.
    private func read(_ candidate: ProposalCandidate, id: UInt64, focus: Int, edit: Int, keys: Int, began: ContinuousClock.Instant,
                      opened: ContinuousClock.Instant) async -> Int? {
        state = .reading
        let read = await reader.readFocusedEmailDraft(text: true, expecting: candidate.expectation, visibility: true).value
        switch settled(id, during: .reading, focus: focus, edit: edit, keys: keys, began: began, candidate: candidate) {
        case .over: return nil
        case .typing:
            // Typed into while it was read: read again, for a held draft alone.
            await readTyped(candidate, id: id, focus: focus, opened: opened)
            return nil
        case let .again(changed):
            state = .settling
            return changed
        case .quiet: break
        }
        guard case let .success(.emailBody(capture)) = read, capture.field.pid == candidate.pid,
              capture.field.started == candidate.started, capture.field.element.sameElement(as: candidate.element),
              Self.isReply(capture), (Self.isBlank(capture) || mayRestoreReply(capture) || blankObserved && mayHoldDraft(for: candidate)) else {
            logNotReply(read, expecting: candidate.expectation)
            state = .idle
            return nil
        }
        let geometry = Geometry(frame: capture.field.frame ?? candidate.frame, visibility: capture.visibility)
        if takeHeld(capture, focus: focus, geometry: geometry, replyFocused: opened) { return nil }
        guard Self.isBlank(capture) else { state = .idle; return nil }
        // Another thread's request on its way: the writer serves one at a time.
        cancelThreadRequest()
        generations &+= 1
        let generation = generations
        current = Current(binding: Binding(account: account(), focus: focus, capture: capture), capture: capture,
                          geometry: geometry, generation: generation, opened: opened, requested: .now, replyFocused: opened, replyOpened: opened)
        current?.retentionScope = archive?.scope
        state = .pending
        log("proposal.requested")
        // Its own task, so a focus change that cancels the next candidate
        // leaves the request alone.
        Task { [weak self] in await self?.request(generation) }
        return nil
    }

    /// Whether a draft held for a Gmail thread in the candidate's browser,
    /// under this account, could be what a typed reply there takes.
    private func mayHoldDraft(for candidate: ProposalCandidate) -> Bool {
        let account = account()
        return held.contains { $0.key.account == account && $0.key.pid == candidate.pid && $0.key.started == candidate.started }
    }

    /// The original reply may regain its proposal after focus cleared the
    /// blank-body observation. The full read still verifies its thread.
    private func mayRestoreReply(for candidate: ProposalCandidate) -> Bool {
        held.contains {
            guard case let .ready(kept) = $0.answer, let binding = kept.replyBinding else { return false }
            return binding.account == account() && binding.pid == candidate.pid && binding.started == candidate.started
                && binding.element.sameElement(as: candidate.element)
        }
    }

    private func mayRestoreReply(_ capture: ComposeCapture) -> Bool {
        held.contains {
            guard case let .ready(kept) = $0.answer, let binding = kept.replyBinding else { return false }
            return binding.account == account() && binding.matchesApartFromBody(capture)
        }
    }

    /// Reuse a held answer after the initially empty reply was edited.
    /// No key attribution is needed: acceptance confirms its current body.
    private func readTyped(_ candidate: ProposalCandidate, id: UInt64, focus: Int, opened: ContinuousClock.Instant) async {
        state = .reading
        let read = await reader.readFocusedEmailDraft(text: true, expecting: candidate.expectation, visibility: true).value
        guard settleID == id, state == .reading else { return }
        guard lastObservation?.focus == focus else { return dropCandidate(id, "proposal.settle.focusMoved") }
        guard isEnabled(), dictationIdle(), blankObserved || mayRestoreReply(for: candidate) else { return dropCandidate(id, nil) }
        guard case let .success(.emailBody(capture)) = read, capture.field.pid == candidate.pid,
              capture.field.started == candidate.started, capture.field.element.sameElement(as: candidate.element),
              Self.isReply(capture) else {
            logNotReply(read, expecting: candidate.expectation)
            return dropCandidate(id, nil)
        }
        let geometry = Geometry(frame: capture.field.frame ?? candidate.frame, visibility: capture.visibility)
        if takeHeld(capture, focus: focus, geometry: geometry, replyFocused: opened) { return }
        guard Self.isBlank(capture), let observation = lastObservation else {
            return dropCandidate(id, "proposal.typed.nothingHeld")
        }
        // A held answer in another thread can send a blank reply here on
        // Gmail's setup notices. Settle and reread it through the normal
        // request path, including any input that arrived during this read.
        settleThenRead(candidate, observation: observation, opened: opened)
    }

    /// A settle or body read given up, logged by `name` when there is one.
    /// One dictation held off is tried again once dictation is idle
    /// (`dictationEnded`).
    private func dropCandidate(_ id: UInt64, _ name: String?) {
        guard settleID == id, state == .settling || state == .reading else { return }
        if let name { log(name) }
        state = .idle
        if !dictationIdle() { candidateFocus = nil }
    }

    /// Asks the writer for the proposal and keeps it once it arrives: shown
    /// after a fresh check while focus is in the body, hidden otherwise.
    private func request(_ generation: UInt64) async {
        guard let body = current?.capture.observation else { return }
        var diagnostics = EmailWriter.ProposalDiagnostics()
        let outcome = await writer.propose(body: body, diagnosed: { [weak self] update in
            diagnostics = update
            self?.recordDiagnostics(update, generation: generation)
        }) { [weak self] id, scope in
            self?.bindRetention(generation, id: id, scope: scope)
        }
        received(outcome, generation: generation, diagnostics: diagnostics)
    }

    /// Keep a snapshot while the request runs so cancellation can close its
    /// timing before the writer returns. A replaced request cannot update it.
    private func recordDiagnostics(_ diagnostics: EmailWriter.ProposalDiagnostics, generation: UInt64) {
        if current?.generation == generation, state == .pending {
            current?.diagnostics = diagnostics
        } else if let index = held.firstIndex(where: { $0.generation == generation && $0.answer.isPending }) {
            held[index].diagnostics = diagnostics
        }
    }

    /// The writer's answer for the proposal on its way, whether its reply
    /// asked for it or took it from its thread's request.
    private func received(_ outcome: Result<EmailWriter.Proposal, EmailWriter.Problem>, generation: UInt64,
                          diagnostics: EmailWriter.ProposalDiagnostics) {
        guard current?.generation == generation, state == .pending else { return }
        current?.diagnostics = diagnostics
        current?.failure = nil
        switch outcome {
        case let .success(proposal):
            current?.proposal = proposal
            current?.arrived = .now
            let until = min(current?.expires ?? .now + keep, .now + keep)
            current?.expires = until
            keepUntil(until, generation: generation)
            if focusIsOnBinding {
                // The check starts before the state turns hidden, so the dot
                // keeps pulsing until the card shows.
                startDisplayCheck()
                state = .hidden
            } else {
                state = .hidden
                current?.arrivedAway = true
            }
        case let .failure(problem):
            current?.failure = problem
            log("proposal.\(EmailWriter.name(problem))")
            switch problem {
            case .abstained(.nothingToAnswer):
                if let current { holdNothingToAnswer(current) }
                end(.abstained, cancelRequest: false)
            case .abstained:
                if problem.isMailImportPending {
                    if focusIsOnBinding, gate() == nil { mailImportPending?() }
                } else {
                    unavailable?()
                }
                end(.abstained, cancelRequest: false)
            case .withdrawn, .cancelled:
                if current?.askedAgain == true { unavailable?() }
                end(.cancelled, cancelRequest: false)
            default:
                if current?.askedAgain == true { unavailable?() }
                current?.failure = problem
                end(.failed, cancelRequest: false)
            }
        }
    }

    /// A reply's own request that found nothing to answer: held for its
    /// thread as answering nothing, so another focus there asks for nothing,
    /// with the hint due until it shows. It shows now only when focus is
    /// still in the reply, no dictation has begun and a fresh read finds the
    /// body blank; otherwise
    /// the next untouched reply in the thread says it (`takeHeld`).
    private func holdNothingToAnswer(_ current: Current) {
        let key = Self.key(of: current.binding)
        hold(HeldThread(key: key, body: current.capture.observation, generation: 0, opened: .now,
                        answer: .nothing(expires: .now + keep, hint: true)))
        guard focusIsOnBinding, let focus = lastObservation.map(FocusKey.init) else { return }
        let read = reader.readProposalCandidate(expecting: current.binding.expectation, blank: true)
        Task { [weak self] in
            let found = await read.value
            // A recording started meanwhile leaves the hint due for the next untouched reply.
            guard let self, self.dictationIdle(), self.lastObservation.map(FocusKey.init) == focus,
                  case let .success(candidate?) = found, candidate.blank == true,
                  let index = self.held.firstIndex(where: { $0.key == key }),
                  case let .nothing(expires, hint: true) = self.held[index].answer else { return }
            self.held[index].answer = .nothing(expires: expires, hint: false)
            self.nothingToAnswer?()
        }
    }

    /// Stop offering a retired receipt. Never remove the parent of an active
    /// recording: the server can rebase that recording's cue on fresh context.
    private func watchValidity(_ generation: UInt64) {
        validityTask?.cancel()
        let interval = validityInterval
        validityTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                // Keep the owner only for this read, never across the next sleep.
                guard await self?.checkValidity(generation) == true else { return }
            }
        }
    }

    private func checkValidity(_ generation: UInt64) async -> Bool {
        guard let current, current.generation == generation else { return false }
        guard [.shown, .hidden].contains(state), dictationIdle(), recordingBound == nil,
              let proposal = current.proposal else { return true }
        let retired = await writer.proposalRetired(proposal)
        guard !Task.isCancelled, self.current?.generation == generation else { return false }
        guard [.shown, .hidden].contains(state), dictationIdle(), recordingBound == nil else { return true }
        if retired {
            end(.dropped, cancelRequest: false, remember: false)
            return false
        }
        return true
    }

    /// Ends the proposal with this generation when its keep time passes.
    private func keepUntil(_ until: ContinuousClock.Instant, generation: UInt64) {
        watchValidity(generation)
        keepTask?.cancel()
        keepTask = Task { [weak self] in
            try? await Task.sleep(until: until)
            guard !Task.isCancelled else { return }
            self?.keepPassed(generation)
        }
    }

    /// Whether the body voice compose read is a reply nothing has been typed
    /// into: the caret collapsed at its very start with nothing before it,
    /// the whole body read and holding only line breaks, an inline reply in
    /// the thread view with the thread's id, and not a forward.
    static func isUntouchedReply(_ capture: ComposeCapture) -> Bool {
        isBlank(capture) && isReply(capture)
    }

    static func untouchedReplyFailures(_ capture: ComposeCapture, expecting: ExpectedFocus? = nil) -> [String] {
        var names: [String] = []
        if !capture.field.before.isEmpty { names.append("before") }
        if capture.selection != FieldRange(location: 0, length: 0) { names.append("selection") }
        if !capture.bodyComplete { names.append("bodyIncomplete") }
        if !capture.observation.body.allSatisfy({ $0 == "\n" || $0 == "\r" }) { names.append("bodyNotEmpty") }
        if !capture.observation.inThread { names.append("notInThread") }
        if ComposeInput.threadID(capture.observation.threadID) == nil { names.append("noThreadID") }
        if ComposeInput.mode(of: capture.observation) != .reply { names.append("notReplyMode") }
        if let expecting, capture.field.pid != expecting.pid || capture.field.started != expecting.started
            || !capture.field.element.sameElement(as: expecting.element) { names.append("wrongElement") }
        return names
    }

    private func logNotReply(_ read: Result<ComposeTarget, EditReason>, expecting: ExpectedFocus) {
        log("proposal.notReply")
        if case let .success(.emailBody(capture)) = read {
            for name in Self.untouchedReplyFailures(capture, expecting: expecting) { log("proposal.notReply." + name) }
        } else if case .success(.emailBodyWithoutText) = read {
            log("proposal.notReply.bodyIncomplete")
        } else {
            log("proposal.notReply.wrongElement")
        }
    }

    /// Whether the body holds nothing typed: the caret collapsed at its very
    /// start with nothing before it, and the whole body read and holding
    /// only line breaks.
    nonisolated static func isBlank(_ capture: ComposeCapture) -> Bool {
        capture.field.before.isEmpty && capture.selection == FieldRange(location: 0, length: 0) && capture.bodyComplete
            && capture.observation.body.allSatisfy({ $0 == "\n" || $0 == "\r" })
    }

    /// Whether the body is an inline reply in Gmail's thread view with the
    /// thread's id, read whole, and not a forward, whatever it holds.
    static func isReply(_ capture: ComposeCapture) -> Bool {
        let observation = capture.observation
        return capture.bodyComplete && observation.inThread && ComposeInput.threadID(observation.threadID) != nil
            && ComposeInput.mode(of: observation) == .reply
    }

    // MARK: Showing

    private var focusIsOnBinding: Bool {
        guard let current, let observation = lastObservation else { return false }
        return observation.focused && observation.pid == current.binding.pid && observation.focus == current.binding.focus
    }

    /// Reads the reply again, bound to its body, and shows the card only
    /// when everything reads as bound, focus is still in that body, and
    /// nothing hid the card or moved focus while the read ran. A read that
    /// finds focus elsewhere leaves the proposal hidden; other differences
    /// rebind a completed Gmail header or ask for a fresh proposal once.
    private func display() {
        guard let current, current.proposal != nil, state == .hidden, checkingAt != visibility else { return }
        if isExpired(current) { return keepPassed(current.generation) }
        startDisplayCheck()
    }

    /// Admission must finish before the display read starts. A new message
    /// elsewhere on Gmail's page need not change the focused body's edit
    /// serial, so only a full binding read after the 204 can vouch for the
    /// reply. Later showings reuse admission but still read every binding.
    /// A limit or an unanswered admission ends the proposal without a card.
    ///
    /// The identity and thread bindings stay current while body edits keep
    /// the card available. A notice during the read requires a fresh check.
    private func startDisplayCheck() {
        guard let current, let proposal = current.proposal else { return }
        let generation = current.generation, visible = visibility
        displayChecks &+= 1
        let check = displayChecks
        checkingAt = visible
        let admission = admission(for: proposal)
        Task { [weak self] in
            let admitted = await admission.value
            guard let self else { return }
            // Cleared once the check has decided, so the dot does not rest
            // between a check and the card it shows.
            defer { if self.displayChecks == check, self.checkingAt == visible { self.checkingAt = nil } }
            guard let now = self.current, now.generation == generation, self.state == .hidden,
                  self.displayChecks == check, self.visibility == visible else { return }
            switch admitted {
            case let .interrupted(readVisibility):
                // A return may already be waiting on the interrupted read.
                // Its fresh visibility gets a new read before any server call.
                if visible != readVisibility, self.gate() == nil, self.focusIsOnBinding {
                    self.startDisplayCheck()
                }
                return
            case .reported(.admitted):
                break
            case .reported(.limit):
                log("proposal.limit")
                return self.end(.limited)
            case .reported(.unreported):
                log("proposal.shown.unreported")
                return self.end(.unreported)
            }
            if self.isExpired(now) { return self.keepPassed(generation) }
            guard self.gate() == nil, self.visibility == visible, self.focusIsOnBinding else { return }
            let edits = self.current?.edits
            let answer = await self.reader.readFocusedEmailDraft(text: true, expecting: now.binding.expectation, visibility: true).value
            guard let later = self.current, later.generation == generation, self.state == .hidden,
                  self.displayChecks == check, self.visibility == visible, self.gate() == nil else { return }
            if self.isExpired(later) { return self.keepPassed(generation) }
            if case .failure(.focusChanged) = answer {
                return log("proposal.display.focusChanged")
            }
            // A notice during this read requires another full read.
            guard self.current?.edits == edits else {
                log("proposal.display.editedDuringCheck")
                return self.startDisplayCheck()
            }
            guard case let .success(.emailBody(fresh)) = answer else {
                log("proposal.display.bindingChanged.body")
                return self.retryDisplay(with: nil, generation: generation)
            }
            let differences = later.binding.differences(fresh, account: self.account())
            if !later.binding.matchesApartFromBody(fresh) || self.account() != later.binding.account {
                log("proposal.display.bindingChanged")
                for name in differences { log("proposal.display.bindingChanged." + name) }
                if later.binding.allowsHeaderCompletion(fresh, account: self.account()) {
                    self.current?.binding = Binding(account: later.binding.account, focus: later.binding.focus, capture: fresh)
                    log("proposal.display.rebound")
                } else {
                    return self.retryDisplay(with: fresh, generation: generation)
                }
            }
            // Hidden or left meanwhile: the next return of the caret or of
            // focus checks again.
            guard self.visibility == visible, self.focusIsOnBinding else { return }
            self.current?.capture = fresh
            self.current?.geometry = Geometry(frame: fresh.field.frame, visibility: fresh.visibility)
            self.showIfPlaced()
        }
    }

    /// One new request can recover an arriving or previously shown draft.
    /// A second mismatch ends visibly; identity boundaries never carry a draft.
    private func retryDisplay(with fresh: ComposeCapture?, generation: UInt64) {
        guard let current, current.generation == generation else { return }
        card.hide()
        takeTab(nil)
        tabGeneration = nil
        cancelReplacement()
        guard !current.askedAgain, account() == current.binding.account, focusIsOnBinding else {
            unavailable?()
            return end(.abstained)
        }
        self.current?.askedAgain = true
        // Fence the old admission and display continuations before replacing
        // their proposal under the same generation.
        displayChecks &+= 1
        checkingAt = nil
        state = .pending
        log("proposal.display.askAgain")
        Task { [weak self] in
            guard let self else { return }
            let capture: ComposeCapture?
            if let fresh { capture = fresh }
            else if case let .success(.emailBody(read)) = await self.reader.readFocusedEmailDraft(
                text: true, expecting: current.binding.expectation, visibility: true).value { capture = read }
            else { capture = nil }
            guard self.current?.generation == generation, self.state == .pending else { return }
            guard let capture, Self.isReply(capture),
                  !current.requiresThreadParticipants || Self.isUntouchedReply(capture),
                  capture.field.pid == current.binding.pid, capture.field.started == current.binding.started,
                  capture.field.element.sameElement(as: current.binding.element), self.account() == current.binding.account else {
                self.unavailable?()
                return self.end(.abstained)
            }
            let trace = ProposalTrace(opened: current.opened, requested: current.requested, arrived: current.arrived,
                                      shown: current.shownAt, ended: .now, trigger: current.trigger, replyFocused: current.replyFocused)
            self.archiveClient(current.retentionID, scope: current.retentionScope, outcome: .dropped, trace: trace, reason: "replaced")
            if let proposal = current.proposal {
                self.archiveEvent(proposal, kind: "draft_outcome", outcome: "replaced", trace: trace)
            }
            self.current?.requested = .now
            self.current?.arrived = nil
            self.current?.shownAt = nil
            self.current?.replyShown = nil
            self.current?.expires = nil
            self.current?.arrivedAway = false
            self.current?.retentionID = UUID()
            self.current?.retentionScope = nil
            self.current?.binding = Binding(account: current.binding.account, focus: current.binding.focus, capture: capture)
            self.current?.capture = capture
            self.current?.proposal = nil
            self.current?.admission = nil
            self.current?.requiresThreadParticipants = false
            await self.request(generation)
        }
    }

    /// The server's admission of the current proposal's card: the one
    /// already asked, whatever it answered or will, or a new one. Retries
    /// are the writer's, within the one admission.
    private func admission(for proposal: EmailWriter.Proposal) -> Task<Admission, Never> {
        if let asked = current?.admission { return asked }
        let writer = writer
        guard let bound = current else { return Task { .reported(.unreported) } }
        let generation = bound.generation
        let visible = visibility
        let unknownRecipients = current?.requiresThreadParticipants == true
        // Old servers reject unknown JSON fields. Send recipients only when
        // this receipt promises the participant check.
        let task = Task<Admission, Never> { [weak self] in
            // A reply may take a pending thread request before its receipt
            // says whether this server checks participants.
            if unknownRecipients {
                guard let self else { return .reported(.unreported) }
                guard self.current?.generation == generation, self.visibility == visible else {
                    return self.interruptAdmission(generation: generation, visibility: visible)
                }
                guard proposal.checksThreadParticipants else {
                    log("proposal.thread.refused.recipientCapability")
                    self.retryDisplay(with: nil, generation: generation)
                    return .reported(.unreported)
                }
                log("proposal.thread.adoptedUnknownRecipients")
            }
            var recipients: [WritingRecipient] = []
            if proposal.checksThreadParticipants {
                guard let self else { return .reported(.unreported) }
                guard let now = self.current, now.generation == generation,
                      self.visibility == visible, self.gate() == nil, self.focusIsOnBinding else {
                    return self.interruptAdmission(generation: generation, visibility: visible)
                }
                let answer = await self.reader.readFocusedEmailDraft(text: true, expecting: now.binding.expectation, visibility: true).value
                guard let later = self.current, later.generation == generation,
                      self.visibility == visible, self.gate() == nil, self.focusIsOnBinding else {
                    return self.interruptAdmission(generation: generation, visibility: visible)
                }
                var binding = later.binding
                if case let .success(.emailBody(fresh)) = answer,
                   binding.allowsHeaderCompletion(fresh, account: self.account()) {
                    binding = Binding(account: binding.account, focus: binding.focus, capture: fresh)
                    log("proposal.admission.rebound")
                }
                if unknownRecipients, case let .success(.emailBody(fresh)) = answer {
                    // Participant admission vouches for the recipients visible now.
                    // Every other part of the adopted reply must still match.
                    binding.recipients = fresh.observation.recipients
                }
                let fresh: ComposeCapture? = if case let .success(.emailBody(read)) = answer { read } else { nil }
                // Typing keeps a reply's own proposal. Adopting a thread draft
                // still requires the exact untouched body it was bound to.
                guard let fresh, self.account() == binding.account,
                      unknownRecipients ? binding.matches(fresh) && Self.isUntouchedReply(fresh) : binding.matchesApartFromBody(fresh) else {
                    log("proposal.admission.bindingChanged")
                    self.retryDisplay(with: fresh, generation: generation)
                    return .reported(.unreported)
                }
                self.current?.binding = binding
                self.current?.capture = fresh
                recipients = fresh.observation.recipients.filter { $0.role == .to || $0.role == .cc }
            }
            let reported = await writer.admit(proposal, recipients: recipients) { [weak self] in
                guard let self else { return }
                log("proposal.shown.refused.recipients")
                guard self.current?.generation == generation else {
                    // Focus may have put this proposal back in held while
                    // admission waited. Returning must request afresh too.
                    if let index = self.held.firstIndex(where: { $0.generation == generation }) {
                        self.discardHeld(at: index)
                    }
                    return
                }
                // A refusal while focus is away must not suppress a fresh
                // request when the unchanged reply takes focus again.
                if !self.focusIsOnBinding {
                    self.end(.dropped, cancelRequest: false, remember: false)
                } else {
                    self.retryDisplay(with: nil, generation: generation)
                }
            }
            return .reported(reported)
        }
        current?.admission = task
        return task
    }

    /// Focus interrupted the local read before the server was asked. Drop
    /// that read wherever this generation is now kept, so returning retries
    /// the read without generating another proposal or spending a shown slot.
    private func interruptAdmission(generation: UInt64?, visibility: UInt64) -> Admission {
        if current?.generation == generation { current?.admission = nil }
        if let index = held.firstIndex(where: { $0.generation == generation }),
           case var .ready(kept) = held[index].answer {
            kept.admission = nil
            held[index].answer = .ready(kept)
        }
        return .interrupted(visibility: visibility)
    }

    /// Reads the body's frame and what shows it in view again, with the
    /// candidate read bound to the body, for a card placed from the frame:
    /// a shown card moves with it or hides when the first line is out of
    /// view or the read does not find the body focused, and a hidden one is
    /// checked for showing once the first line is back in view. A shown
    /// card stays drawn meanwhile, and Tab, its button or the tap made
    /// before the read answers is held until it does (`deferredAccept`),
    /// so nothing is accepted on the evidence the read replaces. One read
    /// at a time; the tracker's next observation, about 30 a second, asks
    /// again.
    private func readGeometry() {
        guard !readingGeometry, let current else { return }
        readingGeometry = true
        geometryAt = visibility
        let generation = current.generation, visible = visibility, binding = current.binding
        let read = reader.readProposalCandidate(expecting: binding.expectation, blank: false)
        Task { [weak self] in
            let found = await read.value
            guard let self else { return }
            self.readingGeometry = false
            self.geometryAt = nil
            let held = self.deferredAccept
            self.deferredAccept = nil
            guard self.current?.generation == generation, self.visibility == visible, let observation = self.lastObservation else { return }
            if case let .success(candidate?) = found, candidate.pid == binding.pid, candidate.started == binding.started,
               candidate.element.sameElement(as: binding.element) {
                self.current?.geometry = Geometry(frame: candidate.frame, visibility: candidate.visibility)
            } else {
                // No evidence the body is where it was.
                self.current?.geometry = Geometry()
            }
            switch self.state {
            case .shown:
                // A geometry read begun before first Tab cannot remove the
                // confirmation while the same selected body still has focus.
                if self.focusIsOnBinding, self.preparingReplacement || self.pendingReplacement != nil { return }
                if let anchor = self.anchor(from: observation) {
                    self.place(anchor)
                    // Still placed on fresh evidence: the held accept goes
                    // ahead, with its own check of the body's first line.
                    if let held, self.state == .shown { self.accept(by: held.way, deadline: held.deadline) }
                } else {
                    self.hide()
                }
            case .hidden:
                if let anchor = self.anchor(from: observation), anchor != self.unplaced { self.display() }
            default:
                break
            }
        }
    }

    /// Puts the card at the caret when the tracker has one, or from the
    /// body's frame; otherwise it waits hidden for the next observation.
    private func showIfPlaced() {
        guard let current, let proposal = current.proposal, let observation = lastObservation,
              let anchor = anchor(from: observation) else { return }
        guard card.show(text: proposal.text, dictationKeyName: dictationKeyName(), at: anchor) else {
            unplaced = anchor
            return
        }
        unplaced = nil
        visibility &+= 1
        tabGeneration = visibility
        state = .shown
        card.acceptsInput = recordingBound != current.generation
        takeTab(visibility)
        log("proposal.shown")
        if current.replyShown == nil { self.current?.replyShown = .now }
        if current.shownAt == nil {
            self.current?.shownAt = .now
            if let proposal = current.proposal { archiveEvent(proposal, kind: "draft_shown", outcome: "shown") }
            if current.trigger == .thread { log("proposal.thread.shownOnReply") }
        }
    }

    /// Moves a shown card. One that no longer fits hid itself: Tab goes
    /// back to the app at once, and it shows again only after a fresh check.
    private func place(_ anchor: ProposalCardAnchor) {
        guard let proposal = current?.proposal else { return }
        guard card.show(text: proposal.text, dictationKeyName: dictationKeyName(), at: anchor) else {
            unplaced = anchor
            return markHidden()
        }
    }

    /// The card's anchor, in AppKit coordinates. With a caret, placed or
    /// estimated, the first line starts at the caret's left edge and top
    /// and the card is as wide as the field, or the body's frame where the
    /// estimate has no field, to its right edge. With neither, as Gmail's
    /// zero-height empty body gives without Screen Recording, the first
    /// line starts at the body's top-left and the card is as wide as the
    /// body, but only when the read that gave the frame also found that
    /// top-left corner inside the body's scroll area and its window; a body
    /// scrolled out of view, or one whose read did not say, gets no card.
    func anchor(from observation: ProposalObservation) -> ProposalCardAnchor? {
        let screens = screens()
        guard let primary = screens.first else { return nil }
        let height = primary.frame.height
        let appKit = { DotPlacement.appKitRect(fromAccessibility: $0, primaryScreenHeight: height) }
        let origin: CGPoint, probe: CGPoint, right: CGFloat?
        if let caretRect = observation.caret {
            let caret = appKit(caretRect)
            origin = CGPoint(x: caret.minX, y: caret.maxY)
            probe = CGPoint(x: caret.midX, y: caret.midY)
            right = (observation.field ?? current?.geometry.frame).map(appKit)?.maxX
        } else if observation.focused, let body = current?.geometry.visibleFrame.map(appKit) {
            origin = CGPoint(x: body.minX, y: body.maxY)
            probe = CGPoint(x: body.minX + 1, y: body.maxY - 1)
            right = body.maxX
        } else {
            return nil
        }
        let screen = screens.first { $0.frame.contains(probe) } ?? primary
        let width = max(0, (right ?? screen.visible.maxX) - origin.x)
        return ProposalCardAnchor(textOrigin: origin, bodyWidth: width, screen: screen.visible)
    }

    private func hide() {
        guard state == .shown else { return }
        card.hide()
        markHidden()
    }

    private func markHidden() {
        takeTab(nil)
        tabGeneration = nil
        deferredAccept = nil
        visibility &+= 1
        cancelReplacement()
        state = .hidden
    }

    // MARK: Accepting

    private var pendingReplacement: ComposeCapture?
    private var preparingReplacement = false
    private var replacementSerial: UInt64 = 0
    private var replacementChecks: [UInt64: Int] = [:]
    private var replacementLatch: AcceptLatch?
    private var insertionSelection: ComposeCapture?

    /// A scroll or layout change retires consent before any placement can
    /// use stale geometry. A later Tab starts a new confirmation.
    func confirmationGeometryChanged() {
        if insertionSelection != nil { current?.latch?.set(.ignored) }
        guard pendingReplacement != nil || preparingReplacement else { return }
        endConfirmationWithoutRoom()
    }

    private func endConfirmationWithoutRoom() {
        takeTab(nil)
        tabGeneration = nil
        deferredAccept = nil
        cancelReplacement()
        visibility &+= 1
        if state == .shown {
            tabGeneration = visibility
            takeTab(visibility)
        }
        log("proposal.confirm.noRoom")
    }

    /// Cancelling leaves the selection exactly where the editor has it.
    private func cancelReplacement() {
        replacementChecks[replacementSerial] = nil
        replacementSerial &+= 1
        replacementLatch?.set(.ignored)
        replacementLatch = nil
        preparingReplacement = false
        pendingReplacement = nil
        card.confirmingReplacement = false
        card.keepClear = nil
    }

    /// What the card keeps in view while `selected` waits for its second
    /// Tab, in AppKit coordinates: the body and the selection's bounds,
    /// or the body alone where Accessibility gave none, and the part of
    /// that shown inside the body's scroll area and window. Nil without a
    /// frame for the body, so the card stays where it is.
    func keepClear(for selected: ComposeCapture) -> ProposalCard.KeepClear? {
        guard let primary = screens().first, let body = selected.visibility?.body ?? selected.field.frame else { return nil }
        let appKit = { DotPlacement.appKitRect(fromAccessibility: $0, primaryScreenHeight: primary.frame.height) }
        let selection = selected.selectionFrame.flatMap { $0.isEmpty ? nil : $0 } ?? body
        var shown = selection
        if let visibility = selected.visibility {
            let cut = selection.intersection(visibility.scrollArea).intersection(visibility.window)
            if !cut.isNull { shown = cut }
        }
        return ProposalCard.KeepClear(body: appKit(body.union(selection)), selection: appKit(shown))
    }

    private func matchesSelection(_ fresh: ComposeCapture, _ selected: ComposeCapture, binding: Binding) -> Bool {
        binding.matchesApartFromBody(fresh) && account() == binding.account
            && fresh.observation.body.utf8.elementsEqual(selected.observation.body.utf8)
            && fresh.selection == selected.selection && fresh.wholeSelection == selected.selection
    }

    private func validateReplacement(_ selected: ComposeCapture, generation: UInt64) {
        guard let current else { return }
        let serial = replacementSerial
        replacementChecks[serial, default: 0] += 1
        let read = reader.readProposalSnapshot(expecting: current.binding.expectation, visibility: true)
        Task { [weak self] in
            let answer = await read.value
            // Only the current confirmation may retire checks or react
            // to their results.
            guard let self, self.replacementSerial == serial else { return }
            self.replacementChecks[serial, default: 0] -= 1
            guard let now = self.current, now.generation == generation else { return }
            guard case let .success(.emailBody(fresh)) = answer,
                  self.matchesSelection(fresh, selected, binding: now.binding) else {
                now.latch?.set(.ignored)
                self.cancelReplacement()
                return
            }
            if fresh.visibility != selected.visibility || fresh.selectionFrame != selected.selectionFrame {
                self.endConfirmationWithoutRoom()
            }
        }
    }

    /// The first Tab or Accessibility press reads the body and selects it. Server
    /// acceptance and insertion wait for another press confirming that range.
    private func prepareReplacement(by way: String, deadline: ContinuousClock.Instant) {
        guard !preparingReplacement, let current else { return }
        guard ContinuousClock.now < deadline else { return refuse(current.proposal?.text ?? "", .busy) }
        preparingReplacement = true
        replacementSerial &+= 1
        let serial = replacementSerial, generation = current.generation
        let binding = current.binding, latch = AcceptLatch()
        replacementLatch = latch
        let fromFrame = lastObservation?.caret == nil
        Task { [weak self] in
            guard let self else { return }
            let read = await self.reader.readFocusedEmailDraft(text: true, expecting: binding.expectation, visibility: fromFrame).value
            guard self.replacementSerial == serial, self.current?.generation == generation, self.state == .shown else { return }
            guard case let .success(.emailBody(fresh)) = read, binding.matchesApartFromBody(fresh),
                  self.account() == binding.account, !fromFrame || fresh.visibility?.showsFirstLine == true else {
                self.cancelReplacement()
                self.notInserted?(.composeChanged, current.proposal?.text ?? "")
                return
            }
            guard ContinuousClock.now < deadline else { return self.refuse(current.proposal?.text ?? "", .busy) }
            if Self.isBlank(fresh) {
                self.cancelReplacement()
                self.beginAccept(by: way, deadline: deadline, selected: nil, empty: fresh)
                return
            }
            let selected = await self.inserter.selectWholeField(expecting: binding.expectation,
                finalCheck: Self.acceptGuard(latch: latch, deadline: deadline, email: fresh.emailField.stillCurrent))
            guard self.replacementSerial == serial, self.current?.generation == generation, self.state == .shown else { return }
            guard case let .success(range) = selected else {
                self.cancelReplacement()
                if case let .failure(reason) = selected { self.notInserted?(reason, current.proposal?.text ?? "") }
                return
            }
            // This read also gives the body's frames and the selection's
            // bounds, which the card keeps clear while it waits.
            let after = await self.reader.readFocusedEmailDraft(text: true, expecting: binding.expectation, visibility: true).value
            guard self.replacementSerial == serial, self.current?.generation == generation, self.state == .shown else { return }
            guard !latch.refuses, ContinuousClock.now < deadline,
                  case let .success(.emailBody(whole)) = after, range == fresh.wholeSelection,
                  whole.selection == range, whole.wholeSelection == range,
                  whole.observation.body.utf8.elementsEqual(fresh.observation.body.utf8), binding.matchesApartFromBody(whole),
                  self.account() == binding.account, !fromFrame || whole.visibility?.showsFirstLine == true else {
                self.cancelReplacement()
                self.notInserted?(.composeChanged, current.proposal?.text ?? "")
                return
            }
            self.preparingReplacement = false
            self.replacementLatch = nil
            self.pendingReplacement = whole
            guard self.card.beginConfirmation(keeping: self.keepClear(for: whole)) else {
                self.endConfirmationWithoutRoom()
                return
            }
        }
    }

    private func restoreConfirmation() {
        card.hide()
        cancelReplacement()
        current?.latch = nil
        insertionSelection = nil
        state = .hidden
        display()
    }

    /// Tab, taken by the dictation key's tap while the card shows with this
    /// generation.
    func tabTaken(generation: UInt64) {
        // Taken Tabs reach the trigger rules but are never recorded as field input.
        guard state == .shown, tabGeneration == generation else { return }
        accept(by: "tab")
    }

    /// An accept held for the geometry reread: how the person accepted, for
    /// the log, and the end of the limit that began with that press.
    private struct HeldAccept {
        let way: String
        let deadline: ContinuousClock.Instant
    }

    /// Accepts the shown proposal. `deadline` is given only when a held
    /// press is made at last, so the limit runs from the person's first
    /// press however long the reread took.
    private func accept(by way: String, deadline held: ContinuousClock.Instant? = nil) {
        guard state == .shown, let current, current.proposal != nil, card.acceptsInput, recordingBound == nil,
              dictationIdle() else { return }
        self.current?.failure = nil
        self.current?.diagnostics.failureKind = nil
        // Its five minutes passed and the timer has not run yet.
        if isExpired(current) { return keepPassed(current.generation) }
        let deadline = held ?? ContinuousClock.now + acceptLimit
        // A reread of the body's geometry for this card is on its way: the
        // accept waits for its evidence (`readGeometry`). A second press
        // meanwhile keeps the first one's limit.
        if readingGeometry, geometryAt == visibility {
            deferredAccept = deferredAccept ?? HeldAccept(way: way, deadline: deadline)
            return
        }
        guard !preparingReplacement, replacementChecks[replacementSerial, default: 0] == 0 else { return }
        guard let selected = pendingReplacement else { prepareReplacement(by: way, deadline: deadline); return }
        beginAccept(by: way, deadline: deadline, selected: selected)
    }

    private func beginAccept(by way: String, deadline: ContinuousClock.Instant,
                             selected: ComposeCapture? = nil, empty: ComposeCapture? = nil) {
        guard let current, let proposal = current.proposal else { return }
        let latch = AcceptLatch()
        insertionSelection = selected
        // Confirmation owns exact whole-body selection evidence even when
        // selecting removed the caret and the first line is off screen.
        // Other frame placements still need a fresh visible first line.
        let fromFrame = selected == nil && lastObservation?.caret == nil
        self.current?.latch = latch
        // The card stays, taking no input, until the text lands or is
        // refused (`close`, `refuse`), so the page's empty-body hint under
        // it never shows in between.
        card.acceptsInput = false
        takeTab(nil)
        tabGeneration = nil
        visibility &+= 1
        state = .accepting
        log("proposal.accept.\(way)")
        // The reread held the press past its limit: nothing is asked of the
        // server and nothing goes in, and the popup says so.
        guard ContinuousClock.now < deadline else { return refuse(proposal.text, .busy) }
        let generation = current.generation
        // The writer serves one request at a time.
        cancelThreadRequest()
        accepting = Task { [weak self] in
            await self?.insert(proposal, generation: generation, latch: latch, deadline: deadline, fromFrame: fromFrame, selected: selected, empty: empty)
        }
    }

    /// Starts an independent acceptance record with a 300 ms answer wait,
    /// then reads the reply once more bound
    /// to its body, and puts the text in with the email's guard, the latch
    /// and the deadline checked again as the inserter's final check, after
    /// its last read of the field and right before the write. For a card
    /// placed from the body's frame outside a confirmation, that read also
    /// asks what shows the body, and a first line no longer in view refuses.
    /// Confirmation instead requires the exact selected whole body. A latched accept
    /// inserts nothing and ends as what latched it; a refusal after the
    /// person's own accept, a latched one included, is never silent.
    ///
    /// A confirmed selection must still match exactly. An empty-body Tab
    /// or card press must still find that body empty. Other bindings retain
    /// their existing whole-body replacement behavior.
    private func insert(_ proposal: EmailWriter.Proposal, generation: UInt64, latch: AcceptLatch, deadline: ContinuousClock.Instant,
                        fromFrame: Bool, selected: ComposeCapture?, empty: ComposeCapture?) async {
        guard let binding = current?.binding else { return }
        func failed(_ reason: EditReason, writerRefused: Bool = false) {
            if selected != nil, latch.cause != .dismissed {
                notInserted?(reason, proposal.text)
                restoreConfirmation()
            }
            else if let cause = latch.cause { finishLatched(cause, text: proposal.text) }
            else { refuse(proposal.text, reason, writerRefused: writerRefused) }
        }
        // Confirm before recording acceptance, then repeat the same checks
        // after the bounded answer wait and inside the final write guard.
        if let selected {
            let read = await reader.readFocusedEmailDraft(text: true, expecting: binding.expectation, visibility: fromFrame).value
            guard current?.generation == generation, state == .accepting else { return }
            guard latch.cause == nil, case let .success(.emailBody(fresh)) = read,
                  matchesSelection(fresh, selected, binding: binding),
                  !fromFrame || fresh.visibility?.showsFirstLine == true else { return failed(.composeChanged) }
        }
        guard account() == binding.account, gate() == nil, ContinuousClock.now < deadline else { return failed(.composeChanged) }
        // The server revalidates source authority and can veto acceptance.
        // Give a quick refusal 300 ms; never wait for slow Wi-Fi. The card's
        // exact text is used, and this same record keeps retrying independently.
        let recording = writer.recordAcceptance(proposal, diagnosed: { [weak self] diagnostics, problem in
            guard let self, let current = self.current, current.generation == generation,
                  current.latch === latch, latch.cause == nil, self.state == .accepting else { return }
            self.current?.diagnostics.retried = current.diagnostics.retried || diagnostics.retried
            self.current?.diagnostics.lastHTTPStatusClass = diagnostics.lastHTTPStatusClass ?? current.diagnostics.lastHTTPStatusClass
            if let problem {
                self.current?.failure = problem
                self.current?.diagnostics.failureKind = .acceptanceFailed
            }
        })
        let answer = await writer.acceptanceAnswer(recording, within: min(.milliseconds(300), deadline - .now))
        guard current?.generation == generation, state == .accepting else { return }
        guard latch.cause == nil else { return failed(.composeChanged) }
        if case let .failure(problem)? = answer {
            current?.failure = problem
            current?.diagnostics.failureKind = .acceptanceFailed
            return failed(.busy, writerRefused: true)
        }
        let text = proposal.text
        guard ContinuousClock.now < deadline else { return failed(.busy) }
        let read = await reader.readFocusedEmailDraft(text: true, expecting: binding.expectation, visibility: fromFrame).value
        guard let current, current.generation == generation, state == .accepting else { return }
        guard latch.cause == nil, case let .success(.emailBody(fresh)) = read,
              current.binding.matchesApartFromBody(fresh), account() == binding.account,
              !fromFrame || fresh.visibility?.showsFirstLine == true else { return failed(.composeChanged) }
        var target = fresh
        if let selected {
            guard matchesSelection(fresh, selected, binding: binding) else { return failed(.composeChanged) }
        } else if let empty {
            guard Self.isBlank(fresh), fresh.observation.body == empty.observation.body,
                  fresh.selection == empty.selection else { return failed(.composeChanged) }
        } else if !Self.isBlank(fresh) {
            switch await selectForReplacement(fresh, binding: binding, generation: generation, latch: latch,
                                               deadline: deadline, fromFrame: fromFrame) {
            case let .success(whole): target = whole
            case let .failure(reason): return failed(reason)
            }
        }
        var field = target.field
        let writeGuard: FocusedField.Guard?
        if selected != nil {
            guard let exact = target.replacementGuard else { return failed(.composeChanged) }
            writeGuard = exact
        } else { writeGuard = target.emailField.stillCurrent }
        field.stillCurrent = Self.acceptGuard(latch: latch, deadline: deadline, email: writeGuard)
        let destination = RetainedDestination()
        let inserted = await inserter.insert(text, into: field, spaced: false, linkEmailFooter: true,
            finalCheck: Self.acceptCheck(latch: latch, deadline: deadline),
            destination: { destination.record($0, $1) })
        guard self.current?.generation == generation, state == .accepting else { return }
        let retainedText = inserted.text
        switch inserted.result {
        case let .inserted(_, clipboardRestored):
            clipboardReported?(clipboardRestored)
            archiveEvent(proposal, kind: "draft_inserted", text: retainedText, outcome: "inserted", destination: destination)
            history.add(.init(id: UUID(), date: Date(), text: retainedText, outcome: .inserted, spoken: nil, proposal: .accepted))
            close(.inserted)
        case let .unknown(reason):
            archiveEvent(proposal, kind: "draft_inserted", text: retainedText, outcome: "uncertain", destination: destination)
            history.add(.init(id: UUID(), date: Date(), text: retainedText, outcome: .uncertain, reason: reason.rawValue,
                              spoken: nil, proposal: .accepted))
            close(.unconfirmed, insertionResult: inserted.result)
            insertionUncertain?()
        case let .notInserted(reason): failed(reason)
        }
    }

    /// For an accept over a body the person typed in: selects the whole
    /// body within its own element, through the inserter, with the latch
    /// and the deadline asked right before the selection is set, then
    /// reads the reply once more, bound to the body. The capture that
    /// comes back is what the insertion is guarded by: the selection the
    /// inserter reported, the body's text exactly as `fresh` read it, the
    /// thread's id, recipients, subject and thread as bound, under the same
    /// account and, for a card placed from the body's frame, its first line
    /// in view. The paste or write that follows replaces the selection, so
    /// the text takes the place of the whole body; nothing else is written,
    /// and nothing at all into another element. One selection notice gets
    /// its own exact text and range check. The email guard compares text
    /// again at the write; no notice is ignored on the basis of time.
    private func selectForReplacement(_ fresh: ComposeCapture, binding: Binding, generation: UInt64, latch: AcceptLatch,
                                      deadline: ContinuousClock.Instant, fromFrame: Bool) async -> Result<ComposeCapture, EditReason> {
        log("proposal.accept.replaceWhole")
        insertionSelection = fresh
        let selected = await inserter.selectWholeField(expecting: binding.expectation,
                                                       finalCheck: Self.acceptCheck(latch: latch, deadline: deadline))
        guard current?.generation == generation, state == .accepting else { return .failure(.focusChanged) }
        let range: FieldRange
        switch selected {
        case let .success(whole): range = whole
        case let .failure(reason): return .failure(reason)
        }
        guard latch.cause == nil else { return .failure(.composeChanged) }
        guard ContinuousClock.now < deadline else { return .failure(.busy) }
        let read = await reader.readFocusedEmailDraft(text: true, expecting: binding.expectation, visibility: fromFrame).value
        guard current?.generation == generation, state == .accepting else { return .failure(.focusChanged) }
        guard latch.cause == nil else { return .failure(.composeChanged) }
        guard ContinuousClock.now < deadline else { return .failure(.busy) }
        guard case let .success(.emailBody(whole)) = read, whole.selection == range, whole.wholeSelection == range, fresh.wholeSelection == range,
              whole.observation.body.utf8.elementsEqual(fresh.observation.body.utf8),
              binding.matchesApartFromBody(whole), account() == binding.account,
              !fromFrame || whole.visibility?.showsFirstLine == true else { return .failure(.composeChanged) }
        return .success(whole)
    }

    /// A notice can stand for our selection only if a bound
    /// read proves the exact text and whole-body range. Pending validation
    /// blocks the executor's final check, including a notice during insert.
    private func verifySelectionNotice(_ expected: ComposeCapture, generation: UInt64) {
        guard let current, current.generation == generation, let latch = current.latch else { return }
        latch.beginSelectionCheck()
        let read = reader.readProposalSnapshot(expecting: current.binding.expectation, visibility: false)
        Task { [weak self] in
            let answer = await read.value
            defer { latch.endSelectionCheck() }
            guard let self, let now = self.current, now.generation == generation,
                  case let .success(.emailBody(fresh)) = answer,
                  now.binding.matchesApartFromBody(fresh), self.account() == now.binding.account,
                  fresh.observation.body.utf8.elementsEqual(expected.observation.body.utf8),
                  fresh.wholeSelection == expected.wholeSelection, fresh.selection == expected.wholeSelection else {
                latch.set(.ignored)
                return
            }
        }
    }

    /// The accept's own check, which reads nothing: a latch or the passed
    /// deadline refuses. The inserter asks it last, right before each write
    /// and paste key (`TextInserter.insert`'s `finalCheck`). Nonisolated,
    /// since the executor calls it.
    nonisolated static func acceptCheck(latch: AcceptLatch, deadline: ContinuousClock.Instant) -> FocusedField.Guard {
        { () -> EditReason? in
            if latch.refuses { return .composeChanged }
            if ContinuousClock.now >= deadline { return .busy }
            return nil
        }
    }

    /// The accept's per-write guard, asked by the inserter on its executor
    /// when the insertion starts and before its checks of the field: the
    /// accept's own check, and otherwise the email's own guard decides.
    nonisolated static func acceptGuard(latch: AcceptLatch, deadline: ContinuousClock.Instant,
                                        email: FocusedField.Guard?) -> FocusedField.Guard {
        let check = acceptCheck(latch: latch, deadline: deadline)
        return { () -> EditReason? in
            // Waiting must precede the inserter's field and clipboard reads.
            latch.waitForSelection(until: deadline)
            return check() ?? email?()
        }
    }

    /// An accept the person cancelled: nothing went in, history keeps the
    /// text as proposed and not used, and the popup shows it with Copy, as
    /// every refusal after the person's own accept does.
    private func finishLatched(_ cause: ProposalOutcome, text: String) {
        history.add(.init(id: UUID(), date: Date(), text: text, outcome: .notInserted, reason: cause.rawValue,
                          spoken: nil, proposal: .unused))
        notInserted?(Self.reason(latchedBy: cause), text)
        close(cause)
    }

    /// The popup's reason for an accept the person cancelled: the field
    /// edited, focus or the screen gone, or Escape, which changed what the
    /// person wanted put in.
    nonisolated static func reason(latchedBy cause: ProposalOutcome) -> EditReason {
        switch cause {
        case .ignored: .fieldChanged
        case .dismissed: .composeChanged
        default: .focusChanged
        }
    }

    /// An accept that could not go in: history keeps it and the popup
    /// shows why, with the text and Copy.
    private func refuse(_ text: String, _ reason: EditReason, writerRefused: Bool = false) {
        card.hide()
        takeTab(nil)
        tabGeneration = nil
        history.add(.init(id: UUID(), date: Date(), text: text, outcome: .notInserted, reason: reason.rawValue,
                          spoken: nil, proposal: .accepted))
        notInserted?(reason, text)
        close(.insertRefused, insertionResult: writerRefused ? nil : .notInserted(reason))
    }

    // MARK: Dictation

    /// Recording started. A shown proposal becomes the dictation's parent:
    /// the card takes no accept until the dictation ends, and the answer is
    /// the change intention dictation keeps with the recording. A hidden one
    /// whose body has focus ends as left; a pending one is cancelled so the
    /// dictation's own request stands alone.
    @discardableResult
    func dictationStarted() -> ProposalChangeIntention? {
        cancelReplacement()
        // A candidate the recording interrupts is tried again once it ends.
        if candidateTask != nil || state == .settling || state == .reading { candidateFocus = nil }
        cancelCandidate()
        // The dictation's own request would take the writer from it.
        cancelThreadRequest()
        switch state {
        case .shown:
            guard let current else { return nil }
            let snapshot = ComposeRead()
            let reading = reader.readProposalSnapshot(expecting: current.binding.expectation, visibility: false)
            let generation = current.generation, edits = current.edits
            Task { [weak self] in
                let answer = await reading.value
                // A queued read may begin after Gmail's edit. Its returned body
                // alone cannot prove that no edit happened while it was pending.
                guard let now = self?.current, now.generation == generation, now.edits == edits else {
                    snapshot.finish(.failure(.fieldChanged))
                    return
                }
                snapshot.finish(answer)
            }
            let intention = ProposalChangeIntention(generation: generation, snapshot: snapshot)
            recordingIntention = intention
            card.acceptsInput = false
            // A press held for the geometry reread is dropped: the person
            // chose to change the proposal instead.
            deferredAccept = nil
            return intention
        case .hidden:
            if focusIsOnBinding { end(.left) }
        case .pending:
            end(.cancelled)
        case .idle, .settling, .reading, .accepting, .changing:
            break
        }
        return nil
    }

    /// The words of the recording dictation began with `intention` came back
    /// for the email body `capture` read. With no intention, no card showed
    /// when the recording began, and the words are written as voice compose
    /// writes them. The card that showed is their parent when it is still
    /// kept, its five minutes not passed, and the launch, element, account
    /// and thread still match. The body and selection must match the fresh
    /// snapshot started with this recording, allowing earlier typing;
    /// the card ends, since words came back for it. Otherwise the parent is
    /// lost (`changeLost`).
    func parentForWords(_ capture: ComposeCapture, intention: ProposalChangeIntention?,
                        isCurrent: () -> Bool = { true }) async -> ProposalParentAnswer {
        guard let intention else { return .noCard }
        let snapshot = await intention.snapshot.value
        // Cancelling while the start read finishes must leave the card alone.
        guard isCurrent() else { return .lost }
        if recordingIntention == intention { recordingIntention = nil }
        guard let current, current.generation == intention.generation, let proposal = current.proposal,
              state == .shown || state == .hidden, !isExpired(current),
              case let .success(.emailBody(start)) = snapshot, current.binding.matchesApartFromBody(start),
              Binding(account: current.binding.account, focus: current.binding.focus, capture: start).matches(capture),
              account() == current.binding.account else {
            changeLost(intention)
            return .lost
        }
        if state == .shown { card.hide() }
        takeTab(nil)
        tabGeneration = nil
        visibility &+= 1
        state = .changing
        log("proposal.change")
        return .parent(ProposalParent(requestID: proposal.id, revision: proposal.revision, text: proposal.text))
    }

    /// The words of the recording dictation began with `intention` came back
    /// and are typed in the parent's place, with the notice and the change
    /// mark: the parent was lost, writing is off, the body could not be
    /// read, or the words went to another field. The proposal, if it is
    /// still kept, ends as changed, since words came back for it.
    func changeLost(_ intention: ProposalChangeIntention) {
        if recordingIntention == intention { recordingIntention = nil }
        if current?.generation == intention.generation, state == .shown || state == .hidden { end(.changed) }
        log("proposal.parentLost")
    }

    /// Dictation is idle again, however it ended: cancelled, heard nothing,
    /// failed, went to another field or went in, or a history retry
    /// finished. A card the recording was bound to takes accepts again, and
    /// a proposal whose time passed meanwhile ends now. Then focus that
    /// landed while dictation was busy is tried as a candidate.
    func dictationEnded() {
        if let bound = recordingBound {
            recordingIntention = nil
            if let current, current.generation == bound {
                if state == .shown { card.acceptsInput = true }
                if isExpired(current) { keepPassed(bound) }
            }
        }
        if dictationIdle(), deferredThreadOpen {
            deferredThreadOpen = false
            if isEnabled() { retryThreadOpen?() }
        }
        retryFocus()
    }

    /// `candidate` reads nothing while dictation is busy, and the caret
    /// may send no further observation once it is idle, so the latest one
    /// is tried now when its focus has not been: the candidate read tells
    /// whether it is a reply body, `landed` shows a kept proposal's body
    /// again after its check and refuses a body whose proposal ended, and
    /// any other reply's settle starts from here.
    private func retryFocus() {
        guard let observation = lastObservation, observation.focused, FocusKey(observation) != candidateFocus,
              isEnabled() else { return }
        candidate(observation)
    }

    /// The change written from the parent went in, was refused, or never
    /// came; nil when no insertion was made. Either way the proposal is over.
    func changeEnded(_ result: InsertionResult?) {
        guard state == .changing else { return }
        switch result {
        case .inserted?: end(.changeInserted)
        case .unknown?: end(.unconfirmed, insertionResult: result)
        case .notInserted?, nil: end(.changed)
        }
    }

    // MARK: Ending

    /// Escape, observed and taken only while a dictation records: a shown
    /// card goes and the proposal is over; an accept on its way is latched.
    func escapePressed() {
        switch state {
        case .shown: end(.dismissed)
        case .accepting: current?.latch?.set(.dismissed)
        default: break
        }
    }

    /// Stop new proposals, cancel undecided ones, and retain held outcomes.
    /// An issued insertion keeps its current generation until its result is known.
    func beginQuit() {
        quitting = true
        reset()
    }

    func finishQuit() async {
        if let accepting { await accepting.value }
        if current != nil { end(.cancelled, remember: false) }
    }

    func resumeAfterQuitRefused() { quitting = false }

    /// The account changed, the setting or email writing went off, or the
    /// dot at the caret was hidden. An accept on its way is latched.
    func reset() {
        deferredThreadOpen = false
        cancelCandidate()
        cancelThreadRequest()
        while !held.isEmpty { discardHeld(at: 0) }
        heldExpiry?.cancel()
        heldExpiry = nil
        switch state {
        case .idle, .settling, .reading, .changing: break
        case .accepting: current?.latch?.set(.left)
        case .pending: end(.cancelled, remember: false)
        case .hidden, .shown: end(.left, remember: false)
        }
    }

    /// The screen locked or the displays went to sleep, which the card
    /// reports whether or not it shows: a shown card hides, a kept proposal
    /// may come back after a fresh check, and an accept on its way is
    /// latched, since the card is already gone for it.
    func screenLockedOrAsleep() {
        switch state {
        case .shown: hide()
        case .accepting: current?.latch?.set(.left)
        default: break
        }
    }

    /// The keep time passed: on screen the proposal expired; out of sight
    /// the person never came back to it. A recording bound to it keeps the
    /// card on screen until the dictation ends, which compares the clock;
    /// the words it brings back find the parent gone all the same.
    private func keepPassed(_ generation: UInt64) {
        guard current?.generation == generation else { return }
        if recordingBound == generation { return }
        switch state {
        case .shown: end(.expired)
        case .hidden: end(.left)
        default: break
        }
    }

    private func isExpired(_ current: Current) -> Bool {
        current.expires.map { ContinuousClock.now >= $0 } ?? false
    }

    private func cancelCandidate() {
        candidateTask?.cancel()
        candidateTask = nil
        cancelSettle()
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        settleID &+= 1
        if state == .settling || state == .reading { state = .idle }
    }

    /// Ends the proposal there is: the card goes, a request on its way is
    /// cancelled by id, and a completed draft never used goes to history as
    /// proposed and not used. `remember` keeps the body from being proposed
    /// into again; a reset or a request that never completed does not.
    private func end(_ outcome: ProposalOutcome, cancelRequest: Bool? = nil, remember: Bool = true,
                     insertionResult: InsertionResult? = nil) {
        cancelSettle()
        if state == .pending, cancelRequest ?? true {
            current?.failure = .withdrawn
            current?.diagnostics.failureKind = .withdrawn
        }
        if cancelRequest ?? (state == .pending) { writer.cancelProposal() }
        if state == .shown {
            card.hide()
            takeTab(nil)
        }
        tabGeneration = nil
        visibility &+= 1
        guard let current else {
            state = .idle
            return
        }
        // A draft that arrived while focus was away and never showed was late.
        let outcome = outcome == .left && current.arrivedAway && current.shownAt == nil ? .late : outcome
        if let proposal = current.proposal, ![.changed, .changeInserted, .unconfirmed].contains(outcome) {
            history.add(.init(id: UUID(), date: Date(), text: proposal.text, outcome: .notInserted, reason: outcome.rawValue,
                              spoken: nil, proposal: .unused))
        }
        close(outcome, remember: remember && ![.cancelled, .failed, .abstained].contains(outcome),
              insertionResult: insertionResult)
    }

    /// Reports the proposal's outcome and forgets it, remembering its body
    /// unless told not to.
    private func close(_ outcome: ProposalOutcome, remember: Bool = true, insertionResult: InsertionResult? = nil) {
        guard let current else { return }
        if remember {
            endedBodies.append(current.binding.expectation)
            if endedBodies.count > Self.endedLimit { endedBodies.removeFirst(endedBodies.count - Self.endedLimit) }
        }
        let trace = ProposalTrace(opened: current.opened, requested: current.requested, arrived: current.arrived,
                                  shown: current.shownAt, ended: .now, trigger: current.trigger, replyFocused: current.replyFocused, failure: current.failure, diagnostics: current.diagnostics, insertionResult: insertionResult)
        archiveClient(current.retentionID, scope: current.retentionScope, outcome: outcome, trace: trace)
        if let proposal = current.proposal {
            archiveEvent(proposal, kind: "draft_outcome", outcome: outcome.rawValue, trace: trace)
            if ![.inserted, .accepted, .changed, .changeInserted, .unconfirmed, .shown].contains(outcome) {
                archiveEvent(proposal, kind: "draft_dismissed", outcome: outcome.rawValue)
            }
        }
        log("proposal.\(outcome.rawValue)")
        ended?(outcome, trace)
        reportReply(current, outcome, insertionResult: insertionResult)
        keepTask?.cancel()
        keepTask = nil
        validityTask?.cancel()
        validityTask = nil
        cancelReplacement()
        insertionSelection = nil
        self.current = nil
        checkingAt = nil
        unplaced = nil
        deferredAccept = nil
        state = .idle
        card.hide()
        card.acceptsInput = true
    }

    private func log(_ name: String) {
        AppLog.compose(name)
        archive?.event(UUID(), kind: "proposal_gate", payload: ["reason": .string(name),
            "at": .number(Date().timeIntervalSince1970)], scope: archive?.scope)
    }

    private func bindRetention(_ generation: UInt64, id: UUID, scope: String?) {
        if current?.generation == generation {
            current?.retentionID = id
            current?.retentionScope = scope
        }
        if let index = held.firstIndex(where: { $0.generation == generation }) {
            held[index].retentionID = id
            held[index].retentionScope = scope
        }
    }

    private func archiveClient(_ id: UUID, scope: String?, outcome: ProposalOutcome, trace: ProposalTrace, reason: String? = nil) {
        var payload: [String: JSONValue] = ["outcome": .string(outcome.rawValue),
            "at": .number(Date().timeIntervalSince1970), "trigger": .string(trace.trigger.rawValue)]
        if let reason { payload["reason"] = .string(reason) }
        if let opened = trace.opened {
            payload["elapsed_ms"] = .number((trace.ended - opened) / .milliseconds(1))
            for (name, mark) in [("requested_ms", trace.requested), ("arrived_ms", trace.arrived),
                                 ("shown_ms", trace.shown), ("reply_focused_ms", trace.replyFocused)] {
                if let mark { payload[name] = .number((mark - opened) / .milliseconds(1)) }
            }
        }
        archive?.event(id, kind: "proposal_client", payload: payload, scope: scope)
    }

    private func archiveEvent(_ proposal: EmailWriter.Proposal, kind: String, text: String? = nil,
                              outcome: String, trace: ProposalTrace? = nil, destination: RetainedDestination? = nil) {
        var payload: [String: JSONValue] = ["outcome": .string(outcome), "at": .number(Date().timeIntervalSince1970)]
        if let text { payload["text"] = .string(text) }
        if let target = destination?.value {
            payload["target_kind"] = .string(target.kind)
            if let bundle = target.bundleID { payload["target_bundle_id"] = .string(bundle) }
        }
        if let trace {
            if let ms = trace.openToShownMilliseconds { payload["open_to_shown_ms"] = .number(Double(ms)) }
            if let opened = trace.opened { payload["elapsed_ms"] = .number((trace.ended - opened) / .milliseconds(1)) }
            if let opened = trace.opened {
                for (name, mark) in [("requested_ms", trace.requested), ("arrived_ms", trace.arrived),
                                     ("shown_ms", trace.shown), ("reply_focused_ms", trace.replyFocused)] {
                    if let mark { payload[name] = .number((mark - opened) / .milliseconds(1)) }
                }
            }
            payload["trigger"] = .string(trace.trigger.rawValue)
        }
        archive?.event(proposal.id, kind: kind, payload: payload, scope: proposal.retentionScope)
    }

    private func reportReply(_ current: Current, _ outcome: ProposalOutcome, insertionResult: InsertionResult? = nil) {
        guard let focused = current.replyOpened else { return }
        let trace = ProposalTrace(opened: current.opened, requested: current.requested, arrived: current.arrived,
                                  shown: current.replyShown, ended: .now, trigger: current.trigger, replyFocused: focused, failure: current.failure, diagnostics: current.diagnostics, insertionResult: insertionResult)
        replyEnded?(outcome, trace)
    }

    /// The dot pulses while the request is on its way and while the check
    /// before a first showing runs, and is at full ink while the card shows.
    private func present() {
        let now: ProposalPresentation = switch state {
        case .pending, .accepting: .pending
        case .hidden where checkingAt != nil && current?.shownAt == nil: .pending
        case .shown: .shown
        default: .idle
        }
        guard now != presented else { return }
        presented = now
        presentationChanged?(now)
    }
}

/// When a proposal's stages happened, for telemetry; nothing of its text.
struct ProposalTrace: Equatable, Sendable {
    /// When the reply opened, or for a proposal asked for when its Gmail
    /// thread opened, when the thread did.
    var opened: ContinuousClock.Instant?
    var requested: ContinuousClock.Instant?
    var arrived: ContinuousClock.Instant?
    var shown: ContinuousClock.Instant?
    var ended: ContinuousClock.Instant
    var trigger = ProposalTiming.Trigger.reply
    /// When the reply's body took focus; nil when none did.
    var replyFocused: ContinuousClock.Instant?
    var failure: EmailWriter.Problem?
    var diagnostics: EmailWriter.ProposalDiagnostics
    var insertionResult: InsertionResult?

    init(opened: ContinuousClock.Instant?, requested: ContinuousClock.Instant?, arrived: ContinuousClock.Instant?,
         shown: ContinuousClock.Instant?, ended: ContinuousClock.Instant, trigger: ProposalTiming.Trigger = .reply,
         replyFocused: ContinuousClock.Instant? = nil, failure: EmailWriter.Problem? = nil,
         diagnostics: EmailWriter.ProposalDiagnostics = .init(), insertionResult: InsertionResult? = nil) {
        self.opened = opened
        self.requested = requested
        self.arrived = arrived
        self.shown = shown
        self.ended = ended
        self.trigger = trigger
        self.replyFocused = replyFocused
        self.failure = failure
        self.diagnostics = diagnostics
        self.insertionResult = insertionResult
    }

    /// Milliseconds from the reply opening to the card showing, the number
    /// every build reports; nil when it never showed.
    var openToShownMilliseconds: Int? {
        guard let opened, let shown else { return nil }
        return Int((shown - opened) / .milliseconds(1))
    }
}
