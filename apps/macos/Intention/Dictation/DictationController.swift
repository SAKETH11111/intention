import AppKit

/// Runs dictation: the person starts it by clicking the dot or holding the
/// dictation key, speaks, and stops it the same way; the finished text goes
/// into the field they were in. Held, the key is push-to-talk: letting it
/// go ends the dictation. Space pressed while it is held makes the
/// dictation hands-free, so it goes on once the key is let go, as one
/// started by a click does; pressing the key again and letting it go ends
/// either, as a click on the dot or the foot's sun does. Escape drops
/// any dictation while it records;
/// with none recording, Escape cancels a pending email write.
///
/// A press of the key, a click on the dot or the foot's Dictate hint
/// starts recording at once whenever none records, even while earlier
/// dictations' text is still on its way: being recognized, cleaned,
/// written into an email or inserted. Those go on and end as they would
/// have. Every trigger and the foot's clicks act on the one recording;
/// Escape cancels it first, then a pending email when none records. Text
/// goes into fields in the order the dictations started:
/// words that come back before an earlier dictation has ended wait for it,
/// whether it inserted, was refused or failed, and only then is the field
/// asked whether it is an email body, so nothing interleaves and one email
/// is written at a time. The inserter then holds every insertion, whether
/// or not dictations overlapped, until the one before can no longer land
/// after it (`TextInserter`), and refuses it within two seconds of an
/// earlier write whose effect is unknown, which keeps the words in history
/// as any refusal does. What a dictation that ends while another records
/// has to say waits until it stops, and then each thing is said in turn.
///
/// Audio streams to the endpoint while the person speaks. When they stop,
/// the endpoint answers with the transcript and then the finished text,
/// which goes wherever the person's cursor is when it is ready, in any app,
/// as it does with other dictation apps. It is not inserted into a secure
/// field, where nothing takes text, or into Intention's own windows, and the
/// indicator then says why (`notInserted`). Every dictation that
/// produced text, inserted or not, goes into `history`. A broken connection
/// is retried once with the whole recording; after that the dictation is
/// kept in history with its audio in memory, to retry from there. Silence
/// inserts nothing, and the indicator says why, naming the microphone the
/// recording came from: a recording with no sound in it at all ends at the
/// stop, and nothing came through; one the endpoint found no words in was
/// either nearly all digital silence, and almost nothing came through, or
/// it heard no words. One with real sound in it (`worthRetrying`) is kept
/// in history with its audio, as a failed one is, for Retry.
/// Dictation never presses Return or anything that sends.
///
/// When the field is the body of an email being written, in Mail or in
/// Gmail, and "Write emails for me" is on, the finished words are the cue
/// for an email instead: `EmailWriter` has the server write it from the
/// words, the body's text and the person's own mail, and the email goes
/// where the words would have, with no preview. When the email cannot be
/// written, for any reason, the words go in as they were and the person is
/// told beside the dot. Nothing said is lost. Anywhere else dictation
/// types the words as it always has, and reads nothing more of the field
/// than it did before. A dictation with no words is no cue: it ends as
/// silence anywhere does, before the field is asked whether it is an
/// email body.
///
/// Each connection presents a speech grant for the account signed in when
/// the dictation started. Signing out, or the backend refusing this Mac's
/// key, cancels what is running and forgets every retry's audio, and a
/// grant or answer that arrives for an earlier account is dropped. Words
/// that have come back are never dropped that way, since the insertion is
/// this Mac's own and needs no account: no email is asked for under
/// another account, and in an email body the words go in in its place,
/// with the notice.
///
/// Once the words are back, a dictation into an email body waits on the
/// body read, the server and the insertion, and a cancel or an account
/// change can arrive during any of them. How the dictation ends is decided
/// once, by `decide`, and whoever decides carries it out: the dictation's
/// own continuation, inserting the email or the words; a cancel, keeping
/// the words in history; or an account change while the email is written,
/// typing the words. Every continuation asks `isOpen` after each await
/// before it acts, and every cancel and account change asks it before
/// touching the dictation, so nothing goes in twice, nothing said is lost
/// and history gets one entry.
@MainActor
@Observable
final class DictationController {
    enum Phase: Sendable, Equatable {
        case idle, recording, processing
        /// The words were spoken into an email being written and are on
        /// their way to the server that writes the email; the dot pulses
        /// and says so beside itself. Any other indicator shows the same
        /// `caption`. It lasts while the email is written and while it goes
        /// in. Once it is decided that no email is coming and the words go
        /// in in its place, the phase is `processing` again, so nothing
        /// says an email is on its way while the words are typed.
        case writingEmail

        /// What an indicator says while `writingEmail` lasts.
        static let writingEmailCaption = "Writing your email…"

        /// What an indicator says beside itself for a phase, or nothing
        /// for one the dot alone shows.
        var caption: String? { caption(email: .init()) }

        func caption(email: EmailFeedback) -> String? {
            self == .writingEmail ? email.caption ?? Self.writingEmailCaption : nil
        }
    }

    /// A pending email can be cancelled until insertion decides its end.
    /// The wait message describes elapsed time, without claiming progress.
    struct EmailFeedback: Sendable, Equatable {
        var pending = false
        var slow = false
        var caption: String? { pending && slow ? "Still waiting. Esc cancels" : nil }
    }

    static let emailWaitNoticeDelay: Duration = .seconds(15)
    /// Tests move this clock by hand; the app measures continuous time.
    @ObservationIgnored var emailWaitClock: any WriterClock = ContinuousWriterClock()
    private(set) var emailFeedback = EmailFeedback() {
        didSet { if emailFeedback != oldValue { emailFeedbackChanged?(emailFeedback) } }
    }
    @ObservationIgnored var emailFeedbackChanged: ((EmailFeedback) -> Void)?

    /// A word to the person once a dictation has ended, for an outcome the
    /// field alone does not show. Shown beside the dot for
    /// `noticeDuration`, and until then by any other indicator.
    enum Notice: Sendable, Equatable {
        /// The email could not be written, so the words went in as they were.
        case typedTranscript(DraftReason?)
        case mailImportPending
        /// The text went in by pasting and what the person had copied was
        /// not put back: macOS does not let Intention read the clipboard, or a
        /// copy made meanwhile came first. Their clipboard is never
        /// replaced without a word.
        case clipboardReplaced
        /// The first email Intention wrote from this person's words went in,
        /// outside setup: said once, so they know where it came from and
        /// that the app's own Command-Z takes it back.
        case firstEmail
        case recordingLimit
        case insertionUncertain
        case nothingToPaste

        /// The receipt's reason when the server ended the request. Intention's
        /// own wait running out and writing the server reports off take the
        /// reason whose words are true for them; anything else keeps the
        /// generic notice.
        static func typedTranscript(for problem: EmailWriter.Problem) -> Notice {
            switch problem {
            case let .abstained(reason), let .cancelled(reason): .typedTranscript(reason)
            case .timedOut: .typedTranscript(.timeout)
            case .unavailable(.mailPolicyUnconfigured): .typedTranscript(.mailPolicyUnconfigured)
            case .unavailable(.disabled), .unavailable(.notConfigured): .typedTranscript(.productionDisabled)
            default: .typedTranscript(nil)
            }
        }

        var text: String {
            switch self {
            case let .typedTranscript(reason):
                switch reason {
                case .intentionUnresolved:
                    "Didn't catch what the email should say, so I typed your words"
                case .costLimit:
                    "Intention couldn't clear this email's cost, so I typed your words"
                case .timeout, .transportUnknown, .invalidResponse, .contextPreparing,
                     .qualificationUnavailable, .eligibilityChanged, .configurationRetired:
                    "Couldn't finish writing the email, so I typed your words"
                case .inputTooLarge:
                    "Too much text to write from, so I typed your words"
                case .mailPolicyUnconfigured, .productionDisabled:
                    "Email writing is off right now, so I typed your words"
                default:
                    "Couldn't write it, so I typed what you said"
                }
            case .mailImportPending: "Still reading your email, try again in a few minutes"
            case .clipboardReplaced: "Pasted it, which replaced what you'd copied"
            case .firstEmail: "Written from what you said. ⌘Z takes it back"
            case .recordingLimit: "Recording stopped at the 20-minute safety limit"
            case .insertionUncertain: "May have gone in. Check before pasting again."
            case .nothingToPaste: "Nothing to paste yet"
            }
        }
    }

    enum Trigger {
        /// Clicked on, clicked off.
        case click
        /// Recording while the dictation key is held.
        case hold
        /// Held, then Space: recording goes on once the key is let go.
        case handsFree
    }

    /// Why dictation could not start, shown in the menu bar item.
    enum Problem: String {
        case notConfigured, signedOut, microphoneDenied, microphoneUnavailable
    }

    /// Why a dictation ended with nothing to insert, for the indicator to say.
    enum Silence: Sendable, Equatable {
        case neverStarted
        /// The microphone sent no sound at all.
        case microphone
        /// The endpoint found no words, and nearly every sample was exactly
        /// zero: a capture that failed, or a headset that mutes itself
        /// between words worn by someone who said next to nothing. Either
        /// way little came through, which is what the person is told.
        case nearlyNothing
        /// There was sound, but the endpoint found no words in it.
        case words
    }

    /// A dictation that ended with no words, as the person is told of it:
    /// why, which microphone it recorded from, and what they can do.
    struct EmptyResult: Sendable, Equatable {
        let silence: Silence
        /// The input it recorded from, the last one if it moved, or nil
        /// when none opened, as with the lid closed on a MacBook's only
        /// microphone. A name can identify the person ("Alex's
        /// AirPods"), so it is shown only in their own notice and history
        /// on this Mac: never logged, sent or stored anywhere else.
        let device: String?
        /// History's entry that keeps the recording for Retry, when it had
        /// real sound (`worthRetrying`); nil otherwise.
        let retry: UUID?
        /// Something can be done about it: it can be retried; or it lasted
        /// `shortestKept` or more and the microphone sent nothing or almost
        /// nothing, which is what a wrong or failed input sends; or it was
        /// faint and lasted `longestEmptyPress` or more, as speech from
        /// earbuds away from the mouth is. The indicator then opens the
        /// popup with a way to switch the microphone, and Retry when there
        /// is one; anything else, most often a tap or a press with nothing
        /// said, it says in one line.
        let actionable: Bool
    }

    /// The app must say which element has focus within this long of the
    /// trigger for the text before its caret to be the writing's context: an
    /// answer any later could name a field the person moved to since.
    /// Opening the microphone and reading the field's text do not count.
    static let targetDeadline: Duration = .milliseconds(300)
    /// A hold shorter than this was a tap, not a dictation.
    static let shortestHold: Duration = .milliseconds(300)
    /// The endpoint takes at most twenty minutes.
    static let longest: Duration = .seconds(20 * 60 - 5)
    @ObservationIgnored var recordingLimit: Duration = longest
    @ObservationIgnored var frontmostBundle: @MainActor () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    /// How long a notice stays beside the dot.
    static let noticeDuration: Duration = .seconds(4)
    /// A recording whose loudest sample stays below this, about -60 dBFS,
    /// had no sound in it. Speech peaks far above it, and so does a working
    /// microphone's own hiss within a second or two, while an input that
    /// delivers digital silence stays at or next to zero.
    static let quietestSound = 33
    /// A recording the endpoint found no words in, with at least this share
    /// of its samples exactly zero, had next to nothing come through. Intention
    /// 0.1.0 recorded a Bluetooth headset that way, 93% zero with fragments
    /// between; the same headset recorded directly while its wearer spoke
    /// was 69% zero, from muting itself between words.
    nonisolated static let mostlyZero = 0.9
    /// An empty answer is kept for Retry only after real sound, and only
    /// a recording at least this many seconds long counts
    /// (`worthRetrying`). A held key's tap, under `shortestHold`, never
    /// gets this far, and a click on and off again, or a single short word,
    /// lasts under a second; anything longer is what a person meant to say
    /// and would want back. Shorter ones are said in one line, never the
    /// popup.
    nonisolated static let shortestKept = 1.0
    /// Real sound peaks at or above this, about -30 dBFS, the line
    /// `levelName` draws between faint and sound (`worthRetrying`). Speech
    /// close to a microphone peaks well above it; a working microphone's
    /// hiss in a quiet room stays well below it, so a press with nothing
    /// said is not kept.
    nonisolated static let speechPeak = 1036
    /// A recording with no words that stayed faint, under `speechPeak`, is
    /// a press with nothing said only when it is shorter than this: someone
    /// who changes their mind lets go within a few seconds, while speech
    /// into a microphone that is not at the mouth, earbuds in a pocket or
    /// on the desk, arrives at about -60 dBFS under the room's noise for as
    /// long as the person talks (114.6 seconds on October 8, 2026). Longer,
    /// the popup offers another microphone; sending it again finds nothing,
    /// so it offers no Retry.
    nonisolated static let longestEmptyPress = 5.0
    /// The reason history keeps for a dictation kept for Retry after the
    /// endpoint found no words in its real sound.
    static let noWords = "noWords"

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if phase != .recording { handsFree = false }
            phaseChanged?(phase)
        }
    }
    /// No key holds this recording open. A double-tap, key with Space or
    /// click starts it; a key tap, Space or Done ends it, and Escape cancels.
    private(set) var handsFree = false
    @ObservationIgnored var recordingIssueChanged: ((String?) -> Void)?
    private(set) var recordingIssue: String? {
        didSet { if recordingIssue != oldValue { recordingIssueChanged?(recordingIssue) } }
    }
    private(set) var notice: Notice? {
        didSet { if notice != oldValue { noticeChanged?(notice) } }
    }
    @ObservationIgnored var noticeChanged: ((Notice?) -> Void)?
    /// The latest paste could not put the person's clipboard back. The menu
    /// bar item offers to allow reading the clipboard while this holds and
    /// macOS does not let Intention read it; the next paste that puts the
    /// clipboard back clears it, and so does a press of that offer once
    /// access is allowed.
    var pasteReplacedClipboard = false
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    /// What the indicators are to say about dictations that ended, or a
    /// reply proposal's insertion, while another dictation records or the
    /// last thing said still has its time, oldest first: silence, a notice
    /// or the not-inserted popup, each with how many `noticeDuration`s it
    /// shows for. They wait until no dictation records, so nothing covers
    /// the recording's controls and voice or speaks over the person, and
    /// then come one at a time, each for its whole time (`say`).
    @ObservationIgnored private var heldBack: [(pauses: Int, words: () -> Void)] = []
    /// The time the last thing said shows, kept whether or not anything
    /// waits behind it yet, so whatever comes meanwhile waits for its end.
    /// A recording that starts takes what shows away and ends it.
    @ObservationIgnored private var saying: Task<Void, Never>?
    /// Called when the last thing said has had its time and nothing waits
    /// to be said, so `hasMoreToSay` is false. The indicator that showed it
    /// can end first, while the app was not quiet yet, so the app tries a
    /// waiting update again here.
    @ObservationIgnored var doneSaying: (() -> Void)?
    /// How long each notice stays; tests step it by hand.
    @ObservationIgnored var noticePause: @MainActor () async -> Void = { try? await Task.sleep(for: noticeDuration) }
    private(set) var problem: Problem? {
        didSet {
            if problem != oldValue { problemChanged?(problem) }
            // Each time the microphone is found unusable, even the same way
            // again, so setup's Retry can clear the last one and still see
            // the next.
            if problem == .microphoneDenied || problem == .microphoneUnavailable { microphoneProblemAt = Date() }
            watchPermission()
        }
    }
    /// When the microphone was last found unusable.
    private(set) var microphoneProblemAt: Date?
    /// Whether a dictation may begin: not without an endpoint, a signed-in
    /// account, a microphone that may be used or one that opens. It follows
    /// sign-in and sign-out at once and says nothing about the network; a
    /// grant or connection that fails is that dictation's failure. The
    /// dictation key takes Fn from other apps only while it is true.
    var available: Bool { phase == .recording || problem == nil }
    @ObservationIgnored var problemChanged: ((Problem?) -> Void)?
    @ObservationIgnored var archive: InteractionArchive?
    /// Observed, so setup's fields take words held during a refused quit.
    private var quitting = false
    var isQuitting: Bool { quitting }
    @ObservationIgnored private var setupScopes: [UUID: String] = [:]
    let history: DictationHistory
    /// Display changes, plus one idle notification when the last hidden audio
    /// drain settles, so a waiting update rechecks `isBusy` after retention.
    @ObservationIgnored var phaseChanged: ((Phase) -> Void)?
    /// How loud each chunk of the recording is, from 0 to 1, on the main
    /// actor, about ten times a second while a dictation records, for the
    /// indicators to show that Intention hears the person. Nothing is called
    /// once recording stops.
    @ObservationIgnored var levelChanged: ((Double) -> Void)?
    /// A dictation ended with nothing to insert. The indicator says why and
    /// names the microphone, after the phase has gone back to idle. Setup's
    /// own dictations say it on setup's page instead (`setupSilence`).
    @ObservationIgnored var silent: ((EmptyResult) -> Void)?
    /// A dictation's text could not go in, why, and the text, for the
    /// indicator to say so and offer a copy. Setup's own dictations are
    /// shown on setup's page instead.
    @ObservationIgnored var notInserted: ((EditReason, String) -> Void)?
    /// A reply proposal's text could not go in after the person accepted
    /// it, why, and the text (`proposalNotInserted`).
    @ObservationIgnored var proposalRefused: ((EditReason, String) -> Void)?
    /// The reply proposals, told when a recording starts and when no
    /// dictation is open any more, asked, when the words come back for an
    /// email body, whether a proposal is their parent, and asked when a
    /// recording starts for the accepted proposal going in, whose text goes
    /// in before the recording's. A proposal's insertion reports its
    /// clipboard here, and the app sends its refusals here
    /// (`proposalNotInserted`), so the notice, the popup and the menu say
    /// so as they do for a dictation's, after any recording.
    @ObservationIgnored var proposals: ReplyProposalController? {
        didSet {
            proposals?.clipboardReported = { [weak self] restored in self?.proposalInserted(clipboardRestored: restored) }
        }
    }
    /// Whether a dictation starting now is setup's own: setup's window has
    /// the keyboard and is on its last page. The app says. There is no
    /// field on that page, and it shows the words itself.
    @ObservationIgnored var isForSetup: (() -> Bool)?
    /// Whether an email Intention wrote has gone in before, outside setup, and
    /// how to record that one has. The app keeps it in preferences. While
    /// it is false, the next such email shows `Notice.firstEmail` and sets
    /// it; without both, no email says so.
    @ObservationIgnored var firstEmailWritten: (() -> Bool)?
    @ObservationIgnored var setFirstEmailWritten: (() -> Void)?
    /// Called once for each dictation, not setup's own, whose text went in
    /// (history's `inserted`): `email` is true for an email the server
    /// wrote and false for typed words, the words typed in an email's
    /// place included.
    @ObservationIgnored var didInsert: ((_ email: Bool) -> Void)?
    /// When the newest dictation made on setup's last page came back with
    /// no words at all, as when the wrong microphone is chosen. History
    /// keeps no row for it, since there is nothing to show or retry, but
    /// the page says so. Silence in another app is nobody's: that app
    /// shows nothing, and it leaves the page's own silence standing.
    private(set) var setupSilence: Date?
    /// Whether that silence was the microphone sending nothing, or nearly
    /// nothing, rather than sound with no words in it, so the page can say
    /// which.
    private(set) var setupSilenceFromMicrophone = false
    @ObservationIgnored private let inserter: TextInserter
    /// Reads an email body and what its window shows once the words come
    /// back: the inserter, or in the checks a reader that also scripts the
    /// page around the scripted field, as the reply proposals' checks do.
    @ObservationIgnored var emailBodies: any ProposalReading
    @ObservationIgnored private let endpoint: DictationEndpoint?
    /// Writes an email from words spoken into an email body; nil in a
    /// build with no draft route.
    @ObservationIgnored let writer: EmailWriter?
    @ObservationIgnored private let vocabulary: any DictationVocabulary
    @ObservationIgnored private var accountReset: Task<Void, Never>?
    @ObservationIgnored private let source: SpeechAudioSource
    @ObservationIgnored private let usesMicrophone: Bool
    /// Every dictation that has not ended, oldest first: at most one
    /// records, the newest, and the rest have stopped and their text is on
    /// its way.
    @ObservationIgnored private var open: [Session] = []
    /// A retry from history while it runs.
    @ObservationIgnored private var retrying: RetryRun?
    @ObservationIgnored private var signedIn: Bool
    /// Changes with every sign-in and sign-out. Work started under an
    /// earlier value never connects or reports.
    /// Counts the accounts this Mac has been signed in under, so work begun
    /// under one is never released under another; the reply proposals
    /// read it for the same reason.
    @ObservationIgnored private(set) var account = 0
    /// Rechecks a refused microphone, since macOS posts nothing when the
    /// person allows it in System Settings.
    @ObservationIgnored private var permissionCheck: Timer?
    #if DEBUG
    /// Each finished dictation's insertion, nil when nothing was inserted,
    /// its timing and its text, for the dictation checks.
    @ObservationIgnored var onOutcome: ((InsertionResult?, DictationTiming, String) -> Void)?
    /// Open dictations whose finished text the controller has accepted.
    var pendingTextCount: Int {
        open.filter { isOpen($0) && $0.text != nil }.count
    }
    /// Await preparation without timing sleeps and inspect its actual attachment.
    func preparationForTesting() -> (task: Task<Void, Never>?, stream: DictationStream?) {
        (open.last?.preparing, open.last?.stream)
    }
    #endif

    /// `source` nil records from the microphone.
    /// The languages the person dictates in, sent with every dictation;
    /// empty means English.
    var languages: [String] = []

    /// `signedIn` is whether this Mac holds a device key at launch;
    /// `accountChanged` follows it from there. `microphone` is the person's
    /// choice of microphone, read as each dictation opens one.
    init(inserter: TextInserter, history: DictationHistory, endpoint: DictationEndpoint?, source: SpeechAudioSource? = nil,
         microphone: @escaping @MainActor () -> MicrophonePreference = { .builtIn },
         signedIn: Bool = true, vocabulary: any DictationVocabulary = EmptyVocabulary(), writer: EmailWriter? = nil) {
        self.inserter = inserter
        emailBodies = inserter
        self.history = history
        self.endpoint = endpoint
        self.source = source ?? Microphone(preference: microphone)
        self.signedIn = signedIn
        self.vocabulary = vocabulary
        self.writer = writer
        usesMicrophone = source == nil
        if endpoint == nil {
            problem = .notConfigured
        } else if !signedIn {
            problem = .signedOut
        }
        if usesMicrophone, [.denied, .restricted].contains(Microphone.permission) { problem = problem ?? .microphoneDenied }
        // Observers do not run for assignments made in the initializer.
        watchPermission()
        history.willClear = { [weak self] in self?.cancelRetry() }
    }

    private func watchPermission() {
        guard problem == .microphoneDenied, usesMicrophone else {
            permissionCheck?.invalidate()
            permissionCheck = nil
            return
        }
        guard permissionCheck == nil else { return }
        permissionCheck = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Microphone.permission == .authorized, self.problem == .microphoneDenied else { return }
                self.problem = nil
            }
        }
    }

    /// This Mac signed in, signed out, had its key refused or replaced by
    /// another account's. A dictation still recording or waiting for its
    /// words is cancelled, the audio kept for Retry is forgotten so it is
    /// never sent under another account, and no grant fetched before is
    /// used again. Words that have come back stay this Mac's: an email
    /// still being written cannot come for this account, so the writer
    /// withdraws its request and the words are typed now, with the notice,
    /// as for any email that could not be written; while the body is still
    /// read, the dictation goes on and asks for no email under another
    /// account (`writeEmail`). Text already going in, the email or the
    /// words, is left to finish, and history records how it went. Every
    /// open dictation is treated so, the one recording and each one on its
    /// way.
    func accountChanged(signedIn: Bool) {
        account += 1
        self.signedIn = signedIn
        for session in open {
            if session.text == nil {
                cancel(session)
            } else if session.phase == .writingEmail, let words = session.text, decide(session) {
                // Decided here, before the words go in, so a cancel or
                // another account change from now on is refused and
                // `writeEmail` leaves the session alone when the writer
                // answers. No email is coming, so the indicators say so now,
                // before the task that types the words starts.
                AppLog.dictation("email.accountChanged")
                set(session, .processing)
                Task { await insert(words, session, notice: .typedTranscript(nil), proposal: session.change != nil ? .changed : nil) }
            }
        }
        cancelRetry()
        writer?.accountChanged(signedIn: signedIn)
        history.forgetRetries()
        let previous = accountReset, vocabulary = vocabulary, credentials = endpoint?.credentials
        accountReset = Task {
            await previous?.value
            await vocabulary.reset()
            await credentials?.reset()
        }
        guard endpoint != nil else { return }
        if !signedIn {
            problem = .signedOut
        } else if problem == .signedOut {
            problem = usesMicrophone && [.denied, .restricted].contains(Microphone.permission) ? .microphoneDenied : nil
        }
    }

    /// "Write emails for me" turned on or off in Settings. Off, words in an
    /// email body are typed as they are, so an email still being written is
    /// given up the way an account change gives it up: decided here, its
    /// request withdrawn by the writer, and the words typed now with the
    /// notice, since the person spoke them for that field. Off while the
    /// body is read, `writeEmail` asks for nothing. Text already going in,
    /// the email or the words, is left to finish.
    func writesEmailsChanged(_ on: Bool) {
        for session in open where !on && session.phase == .writingEmail {
            guard let words = session.text, decide(session) else { continue }
            AppLog.dictation("email.switchedOff")
            set(session, .processing)
            Task { await insert(words, session, notice: .typedTranscript(nil), proposal: session.change != nil ? .changed : nil) }
        }
        writer?.isEnabled = on
    }

    // MARK: - Triggers

    /// A click on the dot: stops the dictation recording, or starts one,
    /// even while earlier ones' text is on its way.
    func toggle() {
        if let session = recording {
            guard session.trigger != .hold else { return }
            stop(session, reason: "click")
        } else { start(.click) }
    }

    /// The dictation key went down. It starts a dictation, or marks one no
    /// key holds open, started by a click or made hands-free, to end when
    /// the key comes up, unless another key or a click comes first: the
    /// key may be the start of a shortcut, such as Right Command and Left.
    /// A press made with another modifier or key already held, `alone`
    /// false, is one: it starts nothing and marks nothing. A dictation it
    /// starts keeps when the key went down, so its coming up soon after is
    /// a tap (`holdEnded`).
    func holdBegan(alone: Bool = true, confirmed: Bool = false) {
        guard alone else { return }
        if let session = recording {
            if session.trigger != .hold { session.endsAtRelease = true }
        } else {
            let pressed = ContinuousClock.now
            start(.hold)
            if let session = recording, session.trigger == .hold {
                session.keyDown = confirmed ? pressed - Self.shortestHold : pressed
            }
        }
    }

    /// The dictation key came up: a held dictation ends and goes in, and so
    /// does one the key's press marked to. A hold shorter than
    /// `shortestHold`, from the key going down to it coming up, was a tap:
    /// the recording it began is dropped. A recording the microphone ended
    /// meanwhile is no longer recording, so it is finished as any other and accepts nothing, and a
    /// dictation the press marked to end, started by a click or made
    /// hands-free, simply ends.
    func holdEnded() {
        guard let session = recording, session.trigger == .hold || session.endsAtRelease else { return }
        guard session.trigger == .hold, let pressed = session.keyDown, ContinuousClock.now - pressed < Self.shortestHold else {
            return stop(session, reason: "keyRelease")
        }
        session.timing.endStage()
        cancel(session)
    }

    /// Space went down while the dictation key was held: the dictation goes
    /// on once the key is let go, as one started by a click does, and the
    /// key's press that came with it ends nothing.
    func holdBecameHandsFree() {
        guard let session = recording else {
            start(.handsFree)
            handsFree = recording != nil
            return
        }
        session.endsAtRelease = false
        guard session.trigger == .hold else {
            stop(session, reason: "handsFreeSpace")
            return
        }
        session.trigger = .handsFree
        handsFree = true
        AppLog.dictation("handsFree")
    }

    /// The screen locked. Nobody is there to end a dictation no key holds
    /// open, so it ends as a release would end a held one, and the
    /// microphone closes.
    func screenLocked() {
        guard let session = recording else { return }
        AppLog.dictation("screenLocked")
        stop(session, reason: "screenLocked")
    }

    /// Escape cancels the recording first. With none recording, it cancels
    /// the email still being written and keeps the spoken words in history.
    func escapePressed() {
        escapeCancellation()()
    }

    /// Bound when Escape is claimed, so a recording that stops before the
    /// press runs cannot redirect its cancellation to an earlier email.
    func escapeCancellation() -> @Sendable @MainActor () -> Void {
        guard let session = recording ?? open.first(where: { $0.phase == .writingEmail && isOpen($0) }) else { return {} }
        let phase = session.phase
        return { [weak self, weak session] in
            guard let self, let session, self.isOpen(session), session.phase == phase else { return }
            AppLog.dictation("escape")
            self.cancel(session)
        }
    }

    /// A click came while the dictation key was held, as Command-click on a
    /// link: the press was the click's, and ends nothing when the key comes
    /// up.
    func clickedDuringHold() {
        recording?.endsAtRelease = false
    }

    /// Another key went down while the dictation key was held. A press
    /// that was to end a dictation no key holds open was a shortcut's, and
    /// ends nothing.
    func keyPressedDuringHold() {
        recording?.endsAtRelease = false
        // A confirmed hold remains a recording while other keys change.
        // HoldKey rejects shortcuts before confirming a hold.
    }

    /// Drops the dictation recording; with none recording, each one on its
    /// way whose text is not yet going in, or else the retry in progress.
    func cancel() {
        if let recording { return cancel(recording) }
        guard !open.isEmpty else { return cancelRetry() }
        for session in open { cancel(session) }
    }

    private func cancelRetry() {
        guard let run = retrying else { return }
        retrying = nil
        run.cancel()
        showPhase()
        AppLog.dictation("retry.cancelled")
    }

    /// Cancel undecided attempts before the persistence barrier. An insertion already
    /// issued must finish under its existing safety rules before the app can exit.
    /// Setup's fields read `isQuitting` and take no new words from here on, so
    /// none is inserted after the barrier; a refused quit gives them the words.
    func prepareToQuit() async -> Bool {
        quitting = true
        proposals?.beginQuit()
        for session in open { cancel(session) }
        cancelRetry()
        while !open.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        await proposals?.finishQuit()
        let saved = await archive?.flush() ?? true
        if !saved {
            quitting = false
            proposals?.resumeAfterQuitRefused()
        }
        return saved
    }

    func recordSetupInsertion(_ text: String, at: Date) {
        guard let entry = history.entries.first(where: { $0.date == at }),
              let id = entry.retentionID, let scope = setupScopes[entry.id] else { return }
        archive?.event(id, kind: "dictation_inserted", payload: ["text": .string(text),
            "outcome": .string("inserted"), "target_kind": .string("setup"),
            "at": .number(Date().timeIntervalSince1970)], scope: scope)
    }

    /// Also used by the history's direct Clear action, through `willClear`.
    @discardableResult
    func clearHistory() -> Bool { history.clear() }

    var canPasteLast: Bool {
        guard mayPasteNow else { return false }
        return lastDictation != nil
    }

    /// Nothing else is on its way in. A paste asked for while the inserter
    /// still holds an earlier paste's clipboard would wait for it and then
    /// land in whatever field has focus by then.
    private var mayPasteNow: Bool {
        !quitting && phase == .idle && proposals?.acceptance == nil && !inserter.isSettling
    }

    /// The newest dictation with text, never a reply proposal: one the
    /// person ignored or dismissed must not go in by this route without
    /// their own accept.
    private var lastDictation: DictationHistory.Entry? {
        history.entries.first { $0.proposal == nil && !$0.text.isEmpty }
    }

    /// Uses the same insertion and refusal path as finished dictation.
    /// Ignore a press while busy: a queued paste could land in a different
    /// field after the person has moved on.
    func pasteLast() {
        guard mayPasteNow else {
            AppLog.dictation("pasteLast.busy")
            return
        }
        guard let entry = lastDictation else {
            AppLog.dictation("pasteLast.empty")
            say { self.show(.nothingToPaste) }
            return
        }
        let session = Session(trigger: .click, account: account, earlier: [], acceptance: nil)
        session.phase = .processing
        session.retentionScope = archive?.scope
        session.retryOf = entry.retentionID
        session.text = entry.text
        // Text already in history going in again, not a new dictation: it
        // adds no row, no words to the tally and no retained attempt.
        session.pasting = true
        // The text already exists, so only insertion takes time.
        for _ in 0..<3 { session.timing.endStage(at: session.started) }
        open.append(session)
        showPhase()
        // Decide before yielding, so an account change cannot cancel this
        // local insertion or turn it into an email-writing request.
        guard decide(session) else { return }
        Task { await insert(entry.text, session) }
    }

    /// Sends a failed dictation's audio again and keeps the text in history
    /// for the person to copy. It is not inserted: the field it was meant
    /// for has long since moved on. Like a new dictation, none starts once
    /// quitting has begun, since its record could miss the last flush.
    func retry(_ id: UUID) {
        guard !quitting, phase == .idle, signedIn, let endpoint, let saved = history.retry(for: id),
              var entry = history.entries.first(where: { $0.id == id }) else { return }
        let run = RetryRun(audio: saved)
        retrying = run
        showPhase()
        let retainedScope = archive?.scope
        let retainedID = UUID()
        let parentID = entry.retentionID ?? entry.id
        let retainedStart = Date()
        DiagnosticEvents.shared.note(.dictationAttempt, at: retainedStart, interactionID: retainedID)
        let retainedLanguages = saved.start.languages
        let retainedAudio = archive == nil ? [] : saved.chunks
        var retainedTranscript = ""
        var retainedSpeech: Data?
        var retainedText = ""
        var retainedOutcome = "cancelled"
        var retainedReason: String? = "cancelled"
        run.retain = { [weak self, weak run] in
            guard let run, !run.retained else { return }
            run.retained = true
            DiagnosticEvents.shared.note(.dictationFinished,
                outcome: DiagnosticEvents.Outcome(rawValue: retainedOutcome) ?? .other,
                interactionID: retainedID, startedAt: retainedStart)
            self?.archive?.dictation(.init(id: retainedID, historyID: id, retryOf: parentID,
                startedAt: retainedStart, finishedAt: Date(), transcript: retainedTranscript,
                formatted: retainedText, text: retainedText, outcome: retainedOutcome, reason: retainedReason,
                microphone: entry.device, languages: retainedLanguages, speech: retainedSpeech),
                audio: retainedAudio, scope: retainedScope)
        }
        run.task = Task {
            defer { run.retain?(); run.retain = nil }
            let outcome: Result<String, Error>
            var grant: String?
            do {
                await accountReset?.value
                guard retrying === run else { return }
                grant = try await endpoint.credentials.grant()
                // Cancelled, or another account since: nothing is sent.
                guard retrying === run, let grant else { return }
                // The original start, so the text is cleaned and spaced as
                // it would have been.
                guard var start = run.audio?.start else { return }
                let words = await vocabulary.words(register: start.register, before: start.before)
                guard retrying === run else { return }
                start.names = words.names
                start.terms = words.terms
                start.vocabularyExpiresAt = words.expiresAt
                let stream = DictationStream(url: endpoint.url, grant: grant, start: start,
                    evidence: archive?.speech(retainedID, scope: retainedScope))
                run.stream = stream
                let transfer = run.send(to: stream)
                await Self.upload(stream, byteCount: transfer.bytes)
                guard retrying === run else { return }
                outcome = .success(try await Self.text(from: stream, within: transfer.timeout) { reply in
                    if case let .retention(data) = reply { retainedSpeech = data }
                    if case let .transcript(text) = reply { retainedTranscript = text }
                    if case let .text(text, _, dropped) = reply {
                        retainedText = text
                        entry.languageNote = DictationHistory.languageNote(dropped: dropped, selected: start.languages)
                    }
                })
            } catch {
                // A refused grant is not offered again; the next retry asks
                // for a new one.
                if case .unauthorized? = error as? DictationStreamError, let grant { await endpoint.credentials.refused(grant) }
                outcome = .failure(error)
            }
            // Cancelled: the entry stays as it was, ready to retry again.
            guard retrying === run else { return }
            retrying = nil
            run.audio = nil
            run.task = nil
            run.stream = nil
            showPhase()
            switch outcome {
            case let .success(text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                // No words this time either: the entry stays failed, its
                // audio kept, rather than marked recovered with nothing.
                entry.outcome = .failed
                entry.reason = Self.noWords
                AppLog.dictation("retry.noWords")
            case let .success(text):
                entry.text = text
                entry.outcome = .notInserted
                entry.reason = "retried"
                AppLog.dictation("retry.answered")
            case let .failure(error):
                entry.reason = (error as? DictationStreamError)?.name ?? "unreachable"
                AppLog.dictation("retry.failed")
            }
            retainedOutcome = entry.outcome.rawValue
            retainedReason = entry.reason
            entry.retentionID = retainedID
            history.update(entry)
        }
    }

    /// Whether a dictation is open or a retry runs.
    var isBusy: Bool { !open.isEmpty || retrying != nil }

    /// The dictation recording now, the newest open one while it records.
    private var recording: Session? {
        open.last.flatMap { $0.phase == .recording && !$0.audioStopped ? $0 : nil }
    }

    /// Whether `session` has not ended.
    private func isLive(_ session: Session) -> Bool {
        open.contains { $0 === session }
    }

    private func set(_ session: Session, _ phase: Phase) {
        session.phase = phase
        session.emailWaitTimer?.cancel()
        session.emailWaitIsLong = false
        if phase == .writingEmail {
            let clock = emailWaitClock
            let deadline = clock.now + Self.emailWaitNoticeDelay
            session.emailWaitTimer = Task { [weak self] in
                do { try await clock.sleep(until: deadline) } catch { return }
                guard !Task.isCancelled, let self, self.isOpen(session), session.phase == .writingEmail else { return }
                session.emailWaitIsLong = true
                self.refreshEmailFeedback()
            }
        }
        showPhase()
    }

    private func refreshEmailFeedback() {
        let waiting = open.first { $0.phase == .writingEmail && isOpen($0) }
        emailFeedback = EmailFeedback(pending: waiting != nil, slow: waiting?.emailWaitIsLong ?? false)
    }

    /// The phase the indicators show for every open dictation together:
    /// recording while one records, then an email being written while one
    /// is, then processing while any text or a retry is on its way. Idle
    /// again, however the last of them ended, the reply proposals are told
    /// (`ReplyProposalController.dictationEnded`): a card a recording was
    /// bound to takes accepts again, and a reply focused meanwhile is
    /// proposed into. Not before, since a proposal accepted while an
    /// earlier dictation's text is still on its way could go in ahead of
    /// it or be refused by it.
    private func showPhase() {
        let was = phase
        // Terminal drains retain their audio and waiters, but have no work to show.
        // A decided insertion still shows until it ends.
        let visible = open.filter { !$0.endingAfterDrain }
        phase = if recording != nil {
            .recording
        } else if visible.contains(where: { $0.phase == .writingEmail }) {
            .writingEmail
        } else if !visible.isEmpty || retrying != nil {
            .processing
        } else {
            .idle
        }
        refreshEmailFeedback()
        if phase == .idle, was != .idle { proposals?.dictationEnded() }
        // The recording stopped or was dropped: what waited for it is said
        // now, after the indicators have taken the new phase.
        sayHeldBack()
    }

    /// Something about an ended dictation is still waiting to be said, or
    /// the last thing said still has its time, so the app is not quiet: an
    /// update must not relaunch it over that. `doneSaying` says when that
    /// time ends with nothing more to say; a recording that ends it sooner
    /// keeps the app busy itself.
    var hasMoreToSay: Bool { !heldBack.isEmpty || saying != nil }

    /// Says what `words` say about a dictation that has ended, which shows
    /// for `pauses` of `noticeDuration`: now, or once no dictation records
    /// and what was said before it has had its time.
    private func say(pauses: Int = 1, _ words: @escaping () -> Void) {
        heldBack.append((pauses, words))
        sayHeldBack()
    }

    /// Says the oldest of what waits, unless a dictation records or the
    /// last one said still has its time, and the next once that time has
    /// passed. Each indicator shows a notice or the popup for
    /// `noticeDuration` (`FootMark.noticeShown`,
    /// `InsertionPopup.shown`), and each replaces its own last one, so two
    /// said together would leave only the second. The time is kept even
    /// when nothing waits behind it, since another dictation's result or a
    /// proposal's refusal can come a moment later. A recording that starts
    /// meanwhile takes what shows away, as before, and ends its time with
    /// it (`start`).
    private func sayHeldBack() {
        guard recording == nil, saying == nil, !heldBack.isEmpty else { return }
        let (pauses, words) = heldBack.removeFirst()
        words()
        saying = Task { [weak self, pause = noticePause] in
            for _ in 0..<pauses { await pause() }
            guard !Task.isCancelled, let self else { return }
            self.saying = nil
            self.sayHeldBack()
            if !self.hasMoreToSay { self.doneSaying?() }
        }
    }

    // MARK: - One dictation

    private func start(_ trigger: Trigger) {
        guard !quitting, recording == nil else { return }
        guard let endpoint else {
            problem = .notConfigured
            return
        }
        // Without an account no grant can come, so the microphone stays shut.
        guard signedIn else {
            problem = .signedOut
            return
        }
        if usesMicrophone {
            switch Microphone.permission {
            case .authorized:
                break
            case .notDetermined:
                // The first dictation asks; recording starts on the next.
                Task {
                    let allowed = await Microphone.requestPermission()
                    // Signed out while macOS asked: that stays the problem.
                    guard problem != .signedOut else { return }
                    problem = allowed ? nil : .microphoneDenied
                }
                return
            default:
                problem = .microphoneDenied
                return
            }
        }
        // An accepted reply proposal may be going in: this records at once, and
        // its text waits for the proposal's, as for an earlier dictation's.
        let session = Session(trigger: trigger, account: account, earlier: open, acceptance: proposals?.acceptance)
        DiagnosticEvents.shared.note(.dictationAttempt, interactionID: session.attemptID)
        session.retentionScope = archive?.scope
        session.forSetup = isForSetup?() ?? false
        let tape = session.tape
        // Asked for before the microphone opens, which can take a second on a
        // Bluetooth headset, so the read starts at the trigger.
        let fieldRead = inserter.readFocusedField()
        // Bind the proposal and begin its whole-body snapshot before audio
        // startup, so startup edits cannot become its baseline.
        session.change = proposals?.dictationStarted()
        // Publish Escape's owner before asynchronous audio startup. A queued
        // press stays with this recording if its microphone later fails.
        open.append(session)
        handsFree = trigger != .hold
        showPhase()
        problem = nil
        recordingIssue = nil
        // Clear the previous notice while already busy, before microphone
        // startup can synchronously report a new recovery warning.
        show(nil)
        saying?.cancel()
        saying = nil
        let levels = RecordingLevels { @MainActor [weak self, weak session] level in
            guard let self, let session, session.phase == .recording, self.isLive(session) else { return }
            self.levelChanged?(level)
        }
        session.levels = levels
        do {
            // A lost input reports recovery without finalizing the session.
            // Audio already captured waits for the person's release or Done.
            try source.start(audio: { @Sendable chunk in tape.append(chunk) }, levels: levels, interrupted: { [weak self] in
                guard let self, session.phase == .recording, !session.audioStopped, self.isLive(session) else { return }
                self.problem = .microphoneUnavailable
                self.recordingIssue = "Reconnecting microphone…"
                AppLog.dictation("microphone.interrupted")
            }, device: { [weak self] name in
                guard let self, session.phase == .recording, !session.audioStopped, self.isLive(session) else { return }
                session.device = name
                self.problem = nil
                self.recordingIssue = nil
            }, issue: { [weak self] issue in
                guard let self, session.phase == .recording, !session.audioStopped, self.isLive(session) else { return }
                self.recordingIssue = issue == .restarting
                    ? "Microphone didn't start. Restarting…" : "Microphone didn't start. Try again."
            }, failed: { [weak self] error in
                self?.startFailed(error, session: session)
            })
        } catch {
            startFailed(error, session: session)
            return
        }
        AppLog.dictation("recording")
        let frontmost = frontmostBundle()
        // Finding the field and opening the connection overlap the first
        // words; audio waits on the tape until the connection can take it.
        session.preparing = Task {
            let (found, began) = await fieldRead.value
            guard isOpen(session) else { return }
            let late = (began ?? .now) - session.started > Self.targetDeadline
            let field = late ? nil : try? found.get()
            session.field = field
            session.notedAt = began
            session.start = DictationStart(register: Self.register(of: field?.bundleIdentifier ?? frontmost), before: field?.before,
                                           languages: languages)
            let missed: EditReason? = late ? .targetUnresponsive : { if case let .failure(reason) = found { reason } else { nil } }()
            AppLog.dictation(field != nil ? "target.found" : "target.\(missed?.rawValue ?? "none")")
            // The grant usually comes from memory; when it has to be fetched,
            // the audio waits on the tape.
            do {
                await accountReset?.value
                guard isOpen(session), session.account == account else { return }
                let grant = try await endpoint.credentials.grant()
                guard isOpen(session), session.account == account else { return }
                session.grant = grant
            } catch {
                guard isOpen(session) else { return }
                session.access = error as? DictationStreamError ?? .unreachable
                return
            }
            guard isOpen(session), session.account == account, let grant = session.grant else { return }
            let words = await vocabulary.words(register: session.start.register, before: session.start.before)
            guard isOpen(session), session.account == account else { return }
            session.start.names = words.names
            session.start.terms = words.terms
            session.start.vocabularyExpiresAt = words.expiresAt
            session.timing.mark(.streamRequested)
            let stream = DictationStream(url: endpoint.url, grant: grant, start: session.start,
            evidence: archive?.speech(session.attemptID, scope: session.retentionScope))
            session.stream = stream
            session.streamAttemptID = session.attemptID
            tape.attach(stream)
        }
        session.limit = Task { [weak self, limit = recordingLimit] in
            try? await Task.sleep(for: limit)
            if !Task.isCancelled, let self {
                self.stop(session, reason: "safetyLimit")
                self.say { self.show(.recordingLimit) }
            }
        }
    }

    private func startFailed(_ error: Error, session: Session) {
        guard isOpen(session), !session.audioStopped, session.phase == .recording else { return }
        session.preparing?.cancel()
        session.stream?.cancel()
        session.levels?.close()
        session.limit?.cancel()
        problem = (error as? Microphone.Failure) == .permissionDenied ? .microphoneDenied : .microphoneUnavailable
        end(session, "notStarted.\(problem?.rawValue ?? "")")
    }

    /// Retire the source synchronously, then wait asynchronously for its
    /// final PCM. A replacement recording can start while this one drains.
    private func drain(_ session: Session, completion: @escaping @MainActor () -> Void = {}) {
        session.audioStopped = true
        session.audioDraining = true
        source.stop { neverStarted in
            guard session.audioDraining else { return }
            session.microphoneNeverStarted = neverStarted
            session.audioDraining = false
            completion()
            let waiting = session.afterAudioDrain
            session.afterAudioDrain = []
            waiting.forEach { $0() }
        }
    }

    private func stop(_ session: Session, reason: String) {
        guard session.phase == .recording, !session.audioStopped, isOpen(session) else { return }
        session.timing.mark(.stopRequested)
        AppLog.dictation("stop.\(reason)")
        recordingIssue = nil
        session.limit?.cancel()
        session.levels?.close()
        session.stopped = .now
        session.timing.endStage()
        drain(session) { [weak self] in
            guard let self, self.isOpen(session) else { return }
            session.timing.mark(.audioStopped)
            AppLog.dictation("stopped.\(Self.levelName(peak: session.tape.peak, zeroShare: session.tape.zeroShare))")
            self.set(session, .processing)
            Task { await self.finish(session) }
        }
        showPhase()
    }

    /// A cancel decides how the dictation ends, unless something decided
    /// first: once text is going in, it is refused.
    private func cancel(_ session: Session) {
        guard decide(session) else { return }
        session.preparing?.cancel()
        if session.phase == .recording, !session.audioStopped { recordingIssue = nil }
        session.limit?.cancel()
        if session.phase == .recording, !session.audioStopped {
            session.levels?.close()
            drain(session)
        }
        session.stream?.cancel()
        session.importStreamTiming()
        session.timing.cancel()
        Telemetry.record(session.timing)
        // Before the words come back there is nothing to keep.
        guard let words = session.text else { return end(session, "cancelled") }
        // The words came back and wait for an earlier dictation, the body is
        // being read or the email written: an email on its way, which is
        // this dictation's only while it is written, is withdrawn with the
        // server and nothing it answers is released, and the words stay in
        // history to copy. Words for a reply proposal's change end the
        // proposal, as words coming back always do.
        if session.phase == .writingEmail { writer?.cancel() }
        if let change = session.change { proposals?.changeLost(change) }
        history.add(.init(id: session.historyID, date: Date(), text: words, outcome: .notInserted, reason: "cancelled",
                          forSetup: session.forSetup ? true : nil, proposal: session.change != nil ? .changed : nil,
                          speechDuration: session.tape.seconds, retentionID: session.attemptID))
        report(nil, session, "")
        end(session, session.phase == .writingEmail ? "email.cancelled" : "cancelled.afterWords")
    }

    /// Whether nothing has decided yet how `session` ends: it has not
    /// ended, and no cancel, account change or insertion has decided for
    /// it. The one check of `Session.decided`: a continuation asks it after
    /// each await before acting, and `decide` asks it before deciding.
    private func isOpen(_ session: Session) -> Bool {
        !session.decided && isLive(session)
    }

    /// Decides how `session` ends, once. True for the first caller while it
    /// is open, which then carries its decision out: an insertion, a cancel
    /// that keeps the words, or the words typed after an account change.
    /// False for every caller after, which leaves the session alone.
    private func decide(_ session: Session) -> Bool {
        guard isOpen(session) else { return false }
        session.decided = true
        session.emailWaitTimer?.cancel()
        refreshEmailFeedback()
        return true
    }

    private func finish(_ session: Session) async {
        guard isOpen(session) else { return }
        // Silence from the microphone is known at the stop; the endpoint
        // would only answer it with no words, after the person had waited.
        guard session.tape.peak >= Self.quietestSound else {
            session.stream?.cancel()
            nothingToInsert(session, session.microphoneNeverStarted ? .neverStarted : .microphone)
            return
        }
        await session.preparing?.value
        guard isOpen(session) else { return }
        let text: String
        do {
            text = try await answer(session)
        } catch {
            guard isOpen(session) else { return }
            let reason = (error as? DictationStreamError)?.name ?? "unreachable"
            session.importStreamTiming()
            session.timing.fail()
            Telemetry.record(session.timing)
            history.add(.init(id: session.historyID, date: Date(), text: session.transcript ?? "", outcome: .failed, reason: reason,
                              forSetup: session.forSetup ? true : nil, device: session.device,
                              speechDuration: session.tape.seconds, retentionID: session.attemptID),
                        retry: .init(chunks: session.tape.recorded, start: Self.withoutVocabulary(session.start)))
            report(nil, session, "")
            end(session, "failed.\(reason)")
            return
        }
        guard isOpen(session) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            nothingToInsert(session, session.tape.zeroShare >= Self.mostlyZero ? .nearlyNothing : .words)
            return
        }
        session.text = text
        // Text goes in in the order the dictations started. Words back
        // before an earlier dictation has ended wait for it here, a cancel
        // still reaching them, and only then is the field asked whether it
        // is an email body: the body read then sees the earlier text, and
        // the writer serves one email at a time.
        let followed = await session.waitForEarlier()
        guard isOpen(session) else { return }
        // Words spoken into the body of an email being written, with the
        // switch on, are the cue for an email. A field that could not be
        // one, by the app and labels noted at the start, is typed into
        // without another read. The rest are told apart on the inserter's
        // executor from their roles, their own description and their
        // page's address, and only an email body's text is read, and only
        // when an email can be written now. Anywhere else, and whenever
        // that cannot be told, the words go in as they are, as they always
        // have.
        if let field = session.field, let writer, writer.isWanted,
           ComposeAccess.couldBeEmailBody(bundleIdentifier: field.bundleIdentifier, labels: field.labels, gmailBody: field.gmailBody) {
            // The reads and the writing are timed as the email stage, which
            // ends when text starts going in, so insert times the insertion
            // alone.
            session.timing.waitForEmail()
            let read = await emailBodies.readFocusedEmailDraft(text: writer.availability == nil, expecting: nil, visibility: false).value
            // Cancelled while the body was read: the cancel kept the words.
            // An account change meanwhile left the dictation to go on here.
            guard isOpen(session) else { return }
            switch read {
            // The body read must name the very element the words were for:
            // the same launch of the same app, the same object. A field
            // replaced or refocused since is left to plain dictation.
            case let .success(.emailBody(capture)) where capture.field.pid == field.pid && capture.field.started == field.started
                && capture.field.element.sameElement(as: field.element):
                // From here whatever goes in, the email or the words in its
                // place, goes into the field noted at the start, which binds
                // the text before the caret and the field's labels as they
                // were then, with the body read's guard, which binds the
                // selection and the text around it as they were when the
                // body was read, so a selection made since, even one that
                // grew forward from the caret and left the text before it
                // unchanged, is not written over. A dictation that waited
                // for earlier ones keeps that note's identity and labels, so
                // an element the app reused for another compose is still
                // refused. Only its text before the caret is the body
                // read's, and only when an earlier dictation's text was
                // known to show in this element since the note, which moved
                // the caret; anything else that changed it leaves the note
                // as it was.
                var target = field
                if followed, capture.field.labels == field.labels, let noted = session.notedAt,
                   await inserter.showedText(in: field, since: noted) {
                    target.before = capture.field.before
                }
                guard isOpen(session) else { return }
                target.stillCurrent = capture.field.stillCurrent
                target.didConfirmCaretCollapse = capture.field.didConfirmCaretCollapse
                session.field = target
                // Words spoken while a proposal's card showed change the
                // proposal: the writer regenerates from it, and the result
                // goes in as any dictated email does. A card that ended, or
                // a reply that no longer reads as it was bound, gets no
                // email: the words are typed with the notice, marked as a
                // change in history.
                let parent = await proposals?.parentForWords(capture, intention: session.change,
                                                            isCurrent: { self.isOpen(session) }) ?? .noCard
                guard isOpen(session) else { return }
                switch parent {
                case let .parent(parent):
                    await writeChange(session, writer: writer, parent: parent, words: text, body: capture.observation,
                                      emailGuard: capture.emailField.stillCurrent)
                case .lost:
                    AppLog.dictation("email.parentLost")
                    await typeInstead(text, session)
                case .noCard:
                    await writeEmail(session, writer: writer, cue: text, body: capture.observation,
                                     emailGuard: capture.emailField.stillCurrent)
                }
                return
            // An email body no email can come from: its text could not be
            // read, or writing is off on the server or this Mac is signed
            // out. The words go in and the person is told why they are
            // words. A field the insertion refuses shows history's reason
            // instead, as for any dictation.
            case let .success(.emailBodyWithoutText(reason)):
                AppLog.dictation("email.\(reason.map { "unread.\($0.rawValue)" } ?? writer.availability.map(EmailWriter.name) ?? "unread")")
                await typeInstead(text, session, because: reason == nil ? writer.availability : nil)
                return
            default:
                break
            }
        }
        // Words spoken over a proposal's card that cannot become its change
        // here, with writing off, no email body read or the body a
        // different field, are still the change the person asked for.
        if session.change != nil {
            AppLog.dictation("email.parentLost")
            await typeInstead(text, session)
            return
        }
        await type(text, session)
    }

    /// Types the words with the notice, since no email comes from them:
    /// marked in history as a change to a reply proposal when the recording
    /// began over one, which then ends as changed. Decided here, once, as
    /// `type` decides.
    @discardableResult
    private func typeInstead(_ words: String, _ session: Session, because problem: EmailWriter.Problem? = nil) async -> InsertionResult? {
        guard decide(session) else { return nil }
        if let change = session.change { proposals?.changeLost(change) }
        let notice = problem.map(Notice.typedTranscript(for:)) ?? .typedTranscript(nil)
        return await insert(words, session, notice: notice, proposal: session.change != nil ? .changed : nil)
    }

    /// Has the server rewrite the proposal from the person's words and puts
    /// the result into the field, as `writeEmail` does for a dictated
    /// email. When no email comes the words go in instead with the notice,
    /// and either way history marks the entry as a change and the proposal
    /// is over, with what the insertion did.
    private func writeChange(_ session: Session, writer: EmailWriter, parent: ProposalParent, words: String, body: EmailBody,
                             emailGuard: FocusedField.Guard?) async {
        if session.account != account {
            AppLog.dictation("email.accountChanged")
            proposals?.changeEnded(nil)
            await type(words, session, notice: .typedTranscript(nil), proposal: .changed)
            return
        }
        if !writer.isEnabled {
            AppLog.dictation("email.switchedOff")
            proposals?.changeEnded(nil)
            await type(words, session, notice: .typedTranscript(nil), proposal: .changed)
            return
        }
        if let problem = writer.availability {
            AppLog.dictation("email.\(EmailWriter.name(problem))")
            proposals?.changeEnded(nil)
            await type(words, session, notice: .typedTranscript(for: problem), proposal: .changed)
            return
        }
        set(session, .writingEmail)
        AppLog.dictation("email.changing")
        let outcome = await writer.revise(parent, words: words, body: body)
        guard isOpen(session) else { proposals?.changeEnded(nil); return }
        switch outcome {
        case let .success(draft):
            session.draftID = writer.lastAcceptedRequestID
            AppLog.dictation("email.changed")
            session.field?.stillCurrent = emailGuard
            let result = await type(draft, session, spoken: words, proposal: .changed)
            proposals?.changeEnded(result)
        case let .failure(problem):
            AppLog.dictation("email.\(EmailWriter.name(problem))")
            set(session, .processing)
            proposals?.changeEnded(nil)
            await type(words, session, notice: problem.isMailImportPending ? .mailImportPending : .typedTranscript(for: problem), proposal: .changed)
        }
    }

    /// Has the server write the email from the words and the body, and
    /// puts it into the field. When no email comes, for any reason, the
    /// words go in instead and the notice says so.
    /// `emailGuard` is the field's guard for the email itself, which also
    /// checks once that the body still reads as it was sent; the words in
    /// its place keep the field's own.
    private func writeEmail(_ session: Session, writer: EmailWriter, cue: String, body: EmailBody,
                            emailGuard: FocusedField.Guard?) async {
        // The account changed while the body was read: no email is asked
        // for under another account than the words were spoken under.
        if session.account != account {
            AppLog.dictation("email.accountChanged")
            await type(cue, session, notice: .typedTranscript(nil))
            return
        }
        // The switch went off while the body was read: no email is asked
        // for, and the words go in now.
        if !writer.isEnabled {
            AppLog.dictation("email.switchedOff")
            await type(cue, session, notice: .typedTranscript(nil))
            return
        }
        // Writing the server has said is off: nothing to wait on, so the
        // words go in now.
        if let problem = writer.availability {
            AppLog.dictation("email.\(EmailWriter.name(problem))")
            await type(cue, session, notice: .typedTranscript(for: problem))
            return
        }
        set(session, .writingEmail)
        AppLog.dictation("email.writing")
        let outcome = await writer.write(cue: cue, body: body)
        // Cancelled meanwhile: the cancel kept the words. The account
        // changed meanwhile: `accountChanged` is typing them. From the
        // answer to the insertion nothing waits, so the field is protected
        // there by the body read's guard and the inserter's own checks.
        guard isOpen(session) else { return }
        switch outcome {
        case let .success(draft):
            session.draftID = writer.lastAcceptedRequestID
            AppLog.dictation("email.written")
            session.field?.stillCurrent = emailGuard
            await type(draft, session, spoken: cue)
        case let .failure(problem):
            AppLog.dictation("email.\(EmailWriter.name(problem))")
            // No email is coming: the words go in as a dictation's do, and
            // the indicators show that while they do. Nothing awaited since
            // `isOpen`, so `type` decides for this session.
            set(session, .processing)
            await type(cue, session, notice: problem.isMailImportPending ? .mailImportPending : .typedTranscript(for: problem))
        }
    }

    /// Decides that `text` goes into the field and puts it in, unless how
    /// the dictation ends was decided already; answers what the insertion
    /// did, or nil when there was none.
    @discardableResult
    private func type(_ text: String, _ session: Session, notice: Notice? = nil, spoken: String? = nil,
                      proposal: DictationHistory.Entry.Proposal? = nil) async -> InsertionResult? {
        guard decide(session) else { return nil }
        return await insert(text, session, notice: notice, spoken: spoken, proposal: proposal)
    }

    /// Puts the finished text of a dictation decided to go in into the
    /// field noted at the start and records how it went. `notice` is shown
    /// once the text is in or may be; a text that did not go in has
    /// history's mark instead. `spoken` is what the person said when `text` is an email
    /// written from it, kept with the email in history so nothing said is
    /// lost.
    @discardableResult
    private func insert(_ text: String, _ session: Session, notice: Notice? = nil, spoken: String? = nil,
                        proposal: DictationHistory.Entry.Proposal? = nil) async -> InsertionResult {
        if session.timing.currentStage == .email { session.timing.endStage() }
        // The server spaced the words for the text before the caret when
        // the dictation started. One that waited for another may find that
        // text there now, so its words are spaced again, by the same rule,
        // for the text before the caret the write itself reads. An email
        // is written from the body as it is now and needs nothing.
        let spaced = spoken == nil && session.followed
        let confirmation = InsertionConfirmation()
        let inserted: (result: InsertionResult, text: String)
        if session.forSetup {
            // Setup's own dictation belongs to its page, even once setup is
            // closed.
            inserted = (.notInserted(.ownApp), text)
        } else if let field = session.field, field.stillCurrent != nil {
            // An email, or the words in its place, goes only into the body
            // that was read, as its guard binds it.
            session.timing.mark(.insertStarted)
            inserted = await inserter.insert(text, into: field, spaced: spaced, linkEmailFooter: spoken != nil,
                                             destination: session.destination.record, confirmation: confirmation)
        } else {
            // Anywhere else, wherever the cursor is now: the person may have
            // moved it while speaking or while the text was written, and
            // sees where it is.
            session.timing.mark(.insertStarted)
            inserted = await inserter.insert(text, spaced: spaced, destination: session.destination.record, confirmation: confirmation)
        }
        let (result, text) = inserted
        session.importStreamTiming()
        var entry = DictationHistory.Entry(id: session.historyID, date: Date(), text: text, outcome: .inserted,
                                           forSetup: session.forSetup ? true : nil,
                                           languageNote: DictationHistory.languageNote(dropped: session.droppedLanguages, selected: session.start.languages),
                                           spoken: spoken, proposal: proposal, speechDuration: session.tape.seconds)
        switch result {
        case let .inserted(_, clipboardRestored):
            if let confirmedAt = confirmation.confirmedAt { session.timing.mark(.insertConfirmed, at: confirmedAt) }
            session.timing.endStage()
            if let clipboardRestored { pasteReplacedClipboard = !clipboardRestored }
            // A paste that could not put the clipboard back says so, after
            // the email's own notice when there is one: the foot holds one
            // line, too short for both.
            let replaced: Notice? = clipboardRestored == false ? .clipboardReplaced : nil
            // The first email Intention writes says once where it came from.
            let first: Notice? = spoken != nil && !session.forSetup && claimFirstEmail() ? .firstEmail : nil
            if let shown = notice ?? first {
                say(pauses: replaced == nil ? 1 : 2) { self.show(shown, then: replaced) }
            } else if let replaced {
                say { self.show(replaced) }
            }
        case let .notInserted(reason):
            session.timing.failInsertion(result)
            entry.outcome = .notInserted
            entry.reason = reason.rawValue
        case let .unknown(reason):
            session.timing.failInsertion(result)
            entry.outcome = .uncertain
            entry.reason = reason.rawValue
            // The text may have gone in, so the person is told what it is.
            say { self.show(.insertionUncertain) }
        }
        // A paste did no speech work, so it is not timed as a dictation.
        if !session.pasting { Telemetry.record(session.timing) }
        let shownBySetup = isForSetup?() ?? false
        entry.retentionID = session.attemptID
        if !session.pasting { history.add(entry, shownBySetup: shownBySetup) }
        report(result, session, text)
        end(session, "insert.\(TextInserter.name(result))")
        if case let .notInserted(reason) = result, !(session.forSetup && shownBySetup) {
            say { self.notInserted?(reason, text) }
        }
        // An insertion already under way finishes after sign-out, but its
        // first-use milestones still belong to the account that started it.
        if case .inserted = result, !session.forSetup, !session.pasting, session.account == account {
            didInsert?(spoken != nil)
        }
        return result
    }

    /// True once: for the first email Intention writes and puts in, which it
    /// records as written so no later one says so.
    private func claimFirstEmail() -> Bool {
        guard let firstEmailWritten, let setFirstEmailWritten, !firstEmailWritten() else { return false }
        setFirstEmailWritten()
        return true
    }

    /// An accepted reply proposal went in, through the clipboard when
    /// `clipboardRestored` is not nil: one that could not be put back says
    /// so and sets the menu's offer, as a dictation's paste does.
    func proposalInserted(clipboardRestored: Bool?) {
        guard let clipboardRestored else { return }
        pasteReplacedClipboard = !clipboardRestored
        if !clipboardRestored { say { self.show(.clipboardReplaced) } }
    }

    func proposalInsertionUncertain() {
        say { self.show(.insertionUncertain) }
    }

    /// A refused proposal shows its popup on the deciding event, including
    /// during another recording or notice, and offers its text for Copy:
    /// the proposal's own popup when the app gives one
    /// (`proposalRefused`), otherwise a dictation's.
    func proposalNotInserted(_ reason: EditReason, _ text: String) {
        (proposalRefused ?? notInserted)?(reason, text)
    }

    /// Shows `notice` beside the dot for `noticeDuration`, then `next` for
    /// as long, or with nil takes the one there away, as the next dictation
    /// does, which also drops `next`.
    private func show(_ notice: Notice?, then next: Notice? = nil) {
        noticeTimer?.cancel()
        noticeTimer = nil
        self.notice = notice
        guard notice != nil else { return }
        noticeTimer = Task { [weak self, pause = noticePause] in
            await pause()
            guard !Task.isCancelled else { return }
            self?.show(next)
        }
    }

    /// Ends a dictation that has no words to insert and says why.
    private func nothingToInsert(_ session: Session, _ silence: Silence) {
        session.importStreamTiming()
        switch silence {
        case .microphone, .neverStarted: session.timing.silent(.heardNothing)
        case .nearlyNothing: session.timing.silent(.heardAlmostNothing)
        case .words: session.timing.cancel()
        }
        Telemetry.record(session.timing)
        report(nil, session, "")
        // Setup's own page shows its silence itself, and history keeps no
        // row for it, whatever came through.
        if session.forSetup {
            setupSilenceFromMicrophone = silence != .words
            setupSilence = Date()
            end(session, Self.outcome(silence))
            return
        }
        let tape = session.tape
        // A transcript of fillers alone, which the endpoint cleans to
        // nothing on purpose, was heard: the microphone worked, and a retry
        // would be cleaned away the same.
        let heard = !(session.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Words the endpoint could not find in real sound: the recording
        // waits in history for Retry, in memory as a failed one's does,
        // marked by its reason and the microphone it came from.
        var retry: UUID?
        if silence == .words, !heard, Self.worthRetrying(seconds: tape.seconds, peak: tape.peak, zeroShare: tape.zeroShare) {
            let entry = DictationHistory.Entry(id: session.historyID, date: Date(), text: "", outcome: .failed, reason: Self.noWords,
                                               device: session.device, speechDuration: tape.seconds, retentionID: session.attemptID)
            history.add(entry, retry: .init(chunks: tape.recorded, start: Self.withoutVocabulary(session.start)))
            retry = entry.id
        }
        end(session, Self.outcome(silence) + (retry == nil ? "" : ".kept"))
        // Nothing or almost nothing from the microphone for a second or
        // more is what a wrong or failed input sends, and faint sound with
        // no words for longer than a press with nothing said lasts is what
        // a microphone away from the mouth sends: switching it is the way
        // out, so the popup offers it even with nothing to retry.
        // How long it recorded, from the audio or the clock, whichever is
        // longer: with the lid closed on the only microphone no audio comes
        // at all, however long the key is held.
        let recorded = max(tape.seconds, session.stopped.map { ($0 - session.started) / .seconds(1) } ?? 0)
        let wrongInput = !heard && (silence == .words ? recorded >= Self.longestEmptyPress : recorded >= Self.shortestKept)
        let empty = EmptyResult(silence: silence, device: session.device, retry: retry, actionable: retry != nil || wrongInput)
        say { self.silent?(empty) }
    }

    /// The log's fixed name for how a dictation with nothing to insert ended.
    private static func outcome(_ silence: Silence) -> String {
        switch silence {
        case .microphone: "silent.microphone"
        case .neverStarted: "silent.microphoneNeverStarted"
        case .nearlyNothing: "silent.nearlyNothing"
        case .words: "silent.words"
        }
    }

    private func report(_ result: InsertionResult?, _ session: Session, _ text: String) {
        #if DEBUG
        onOutcome?(result, session.timing, text)
        #endif
    }

    /// The finished text, from the connection opened while recording or, if
    /// that broke, from one more connection sent the whole recording.
    private func answer(_ session: Session) async throws -> String {
        let limit = Self.answerTimeout(session.tape.recorded)
        let marks: (DictationReply) -> Void = { reply in
            session.importStreamTiming()
            if case let .retention(data) = reply { session.speech = data; return }
            if case let .transcript(text) = reply {
                session.transcript = text
                session.attemptTranscript = text
            }
            if case let .text(_, _, dropped) = reply {
                session.droppedLanguages = dropped
            }
            if session.timing.currentStage == .transcribe { session.timing.endStage() }
            if case .text = reply, session.timing.currentStage == .clean { session.timing.endStage() }
        }
        if let stream = session.stream {
            await Self.upload(stream, session.tape.recorded)
            do {
                return try await Self.text(from: stream, within: limit, marks)
            } catch let error as DictationStreamError where !Self.retryable(error) {
                throw error
            } catch {
                guard isOpen(session) else { throw error }
                retain(session, reason: (error as? DictationStreamError)?.name ?? "unreachable", failedAttempt: true)
                session.retryOf = session.attemptID
                session.attemptID = UUID()
                session.speech = nil
                session.attemptTranscript = nil
                session.timing.resetAttemptMarks()
                // Retried below, with a new grant if the endpoint refused this one.
                if case .unauthorized? = error as? DictationStreamError, let grant = session.grant {
                    await endpoint?.credentials.refused(grant)
                }
            }
        } else if let failure = session.access, !Self.retryable(failure) {
            throw failure
        }
        guard isOpen(session), session.account == account, let endpoint else { throw DictationStreamError.unreachable }
        let grant = try await endpoint.credentials.grant()
        guard isOpen(session), session.account == account else { throw DictationStreamError.signedOut }
        AppLog.dictation("reconnecting")
        session.grant = grant
        let words = await vocabulary.words(register: session.start.register, before: session.start.before)
        guard isOpen(session), session.account == account else { throw DictationStreamError.signedOut }
        session.start.names = words.names
        session.start.terms = words.terms
        session.start.vocabularyExpiresAt = words.expiresAt
        session.timing.mark(.streamRequested)
        let stream = DictationStream(url: endpoint.url, grant: grant, start: session.start,
                evidence: archive?.speech(session.attemptID, scope: session.retentionScope))
        session.stream = stream
        session.streamAttemptID = session.attemptID
        session.tape.attach(stream)
        await Self.upload(stream, session.tape.recorded)
        return try await Self.text(from: stream, within: limit, marks)
    }

    /// Ends `session` and lets any later dictation waiting on it go on.
    /// Every way a dictation ends comes here, a speech or connection
    /// failure among them; the last one open to end tells the reply
    /// proposals (`showPhase`).
    private func end(_ session: Session, _ outcome: String) {
        if session.audioDraining {
            guard !session.endingAfterDrain else { return }
            session.endingAfterDrain = true
            session.afterAudioDrain.append { [weak self] in self?.end(session, outcome) }
            showPhase()
            return
        }
        guard let index = open.firstIndex(where: { $0 === session }) else { return }
        retain(session, reason: outcome)
        session.emailWaitTimer?.cancel()
        open.remove(at: index)
        session.ended()
        let wasIdle = phase == .idle
        showPhase()
        // Cancellation already hid this drain. Retention and waiter release
        // must finish before a waiting update can retry its quiet check.
        if wasIdle, phase == .idle, !isBusy { phaseChanged?(.idle) }
        AppLog.dictation(outcome)
    }

    private func retain(_ session: Session, reason: String, failedAttempt: Bool = false) {
        session.importStreamTiming()
        // Stream cancellation can race its read failure. The first terminal snapshot
        // owns this attempt ID; a later callback must never enqueue conflicting bytes.
        guard let archive, !session.pasting, session.retainedAttempts.insert(session.attemptID).inserted else { return }
        let entry = failedAttempt ? nil : history.entries.first { $0.id == session.historyID }
        let outcome = entry?.outcome.rawValue ?? (reason.contains("cancelled") ? "cancelled" : "failed")
        let destination = session.destination.value
        let record = RetainedDictation(id: session.attemptID, historyID: session.historyID, retryOf: session.retryOf,
            startedAt: session.timing.startDate, finishedAt: Date(), transcript: session.attemptTranscript ?? "",
            formatted: session.text ?? "", text: entry?.text ?? "", outcome: outcome, reason: entry?.reason ?? reason,
            targetBundleID: session.forSetup ? Bundle.main.bundleIdentifier : destination?.bundleID ?? session.field?.bundleIdentifier,
            targetKind: session.forSetup ? "setup" : destination?.kind ?? session.field?.kind, microphone: session.device, languages: session.start.languages,
            timings: session.timing.retainedTimings, speech: session.speech)
        if session.forSetup, let scope = session.retentionScope { setupScopes[session.historyID] = scope }
        archive.dictation(record, audio: session.tape.recorded, scope: session.retentionScope)
        if let draftID = session.draftID, let entry, !failedAttempt {
            archive.event(draftID, kind: "draft_inserted", payload: ["text": .string(entry.text),
                "outcome": .string(entry.outcome.rawValue), "at": .string(ISO8601DateFormatter().string(from: Date()))],
                scope: session.retentionScope)
        }
    }

    private static func withoutVocabulary(_ start: DictationStart) -> DictationStart {
        var start = start
        start.names = []
        start.terms = []
        start.vocabularyExpiresAt = nil
        return start
    }

    // MARK: - Rules

    /// Waits for the finished text, passing each reply to `marks` first.
    private static func text(from stream: DictationStream, within limit: Duration,
                             _ marks: (DictationReply) -> Void) async throws -> String {
        let timer = Task {
            try? await Task.sleep(for: limit)
            if !Task.isCancelled { stream.expire() }
        }
        defer { timer.cancel() }
        for try await reply in stream.replies {
            marks(reply)
            if case let .text(text, _, _) = reply { return text }
        }
        throw DictationStreamError.unreachable
    }

    /// The endpoint answers within about a second of the stop; recognizing
    /// the end of a long dictation and cleaning it in parts takes longer.
    nonisolated static func answerTimeout(_ chunks: [Data]) -> Duration {
        let seconds = Double(chunks.reduce(0) { $0 + $1.count }) / 2 / SpeechAudioConverter.sampleRate
        return .seconds(8) + .seconds(seconds / 60)
    }

    /// Sends the stop and waits until it, and the audio before it, has gone
    /// out, for at most 30 seconds or as long as the audio takes at 400
    /// kbit/s; a connection that stalls longer fails on the answer's wait.
    private static func upload(_ stream: DictationStream, _ chunks: [Data]) async {
        await upload(stream, byteCount: chunks.reduce(0) { $0 + $1.count })
    }

    static func upload(_ stream: DictationStream, byteCount: Int,
                       wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async {
        let cap = Duration.seconds(max(30, Double(byteCount) / 50_000))
        // Whichever ends first; a send that never completes is left behind,
        // and a send that does cancels the timer.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let first = FirstOnly()
            let timer = Task {
                await wait(cap)
                if first.claim() { done.resume() }
            }
            Task {
                await stream.finish()
                timer.cancel()
                if first.claim() { done.resume() }
            }
        }
    }

    /// A recording's loudness as a fixed name for the log: its loudest
    /// sample, about -60 dBFS and below being no sound at all and -30 dBFS
    /// and below faint, then the share of samples that are exactly zero,
    /// which a working microphone's hiss rarely gives and a capture that
    /// failed, or a headset that mutes itself, gives in runs.
    nonisolated static func levelName(peak: Int, zeroShare: Double) -> String {
        let level = peak < 33 ? "silent" : peak < speechPeak ? "faint" : "sound"
        let zeros = zeroShare >= 0.9 ? "most" : zeroShare >= 0.1 ? "some" : "few"
        return "level.\(level).zeros.\(zeros)"
    }

    /// Whether a recording the endpoint found no words in had real sound,
    /// worth sending again: at least `shortestKept` long, its loudest
    /// sample at least `speechPeak`, and less than `mostlyZero` of it
    /// exactly zero, since zeros sent again hold no more words. It says
    /// nothing of where the sound came from: speech into another
    /// microphone, or the room, is real sound too, which is why the popup
    /// names the microphone beside Retry.
    nonisolated static func worthRetrying(seconds: Double, peak: Int, zeroShare: Double) -> Bool {
        seconds >= shortestKept && peak >= speechPeak && zeroShare < mostlyZero
    }

    /// Worth one more connection: the network or the endpoint failed, not
    /// the request, or the endpoint refused a grant, which is replaced.
    nonisolated static func retryable(_ error: DictationStreamError) -> Bool {
        switch error {
        case .unreachable, .malformed, .unauthorized: true
        case let .refused(reason): !["too_long", "bad_start", "bad_message", "language_unsupported"].contains(reason)
        case .signedOut, .limited, .timedOut: false
        }
    }

    /// The register the cleanup writes in, from the app being dictated into.
    /// Browsers count as other, since their tabs are not read.
    nonisolated static func register(of bundleIdentifier: String?) -> String {
        switch bundleIdentifier {
        case "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron":
            "email"
        case "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "notion.id", "com.linear":
            "work"
        case "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord":
            "personal"
        default:
            "other"
        }
    }
}

/// One dictation's state, from the start of recording to its outcome.
@MainActor
private final class Session {
    /// How it started; a hold made hands-free becomes `.handsFree`.
    var trigger: DictationController.Trigger
    /// The dictation key went down while it recorded with no key holding
    /// it open; it ends when the key comes up.
    var endsAtRelease = false
    let historyID = UUID()
    var attemptID = UUID()
    var retryOf: UUID?
    /// Paste last dictation putting an earlier dictation's text in again.
    var pasting = false
    var retentionScope: String?
    var speech: Data?
    var attemptTranscript: String?
    var retainedAttempts: Set<UUID> = []
    var draftID: UUID?
    let destination = RetainedDestination()
    let started = ContinuousClock.now
    /// When recording stopped.
    var stopped: ContinuousClock.Instant?
    var microphoneNeverStarted = false
    var audioStopped = false
    var audioDraining = false
    var endingAfterDrain = false
    var afterAudioDrain: [@MainActor () -> Void] = []
    let tape = DictationTape()
    var levels: RecordingLevels?
    var timing = DictationTiming()
    /// The field focused when recording started, read for the writing's
    /// context and to tell an email body. Plain dictation goes wherever the
    /// cursor is when its words come; an email goes only here.
    var field: FocusedField?
    /// When the app said which element had focus for `field`.
    var notedAt: ContinuousClock.Instant?
    var start = DictationStart(register: "other")
    /// The account it started under (`DictationController.account`).
    let account: Int
    /// The grant its connection presented.
    var grant: String?
    /// Why no grant came while recording.
    var access: DictationStreamError?
    var stream: DictationStream?
    var streamAttemptID: UUID?

    func importStreamTiming() {
        // A reconnect can be awaiting credentials while the old stream finishes.
        // Its transport observations belong only to the already retained attempt.
        guard streamAttemptID == attemptID, let stream else { return }
        timing.markTransport(stream.timingSnapshot)
    }

    var transcript: String?
    /// The input it records from, the last one if it moved
    /// (`EmptyResult.device`).
    var device: String?
    /// The finished text, once it has come.
    var text: String?
    var droppedLanguages: [String] = []
    var preparing: Task<Void, Never>?
    var limit: Task<Void, Never>?
    /// How the dictation ends has been decided: its text is on its way
    /// into the field, or it was cancelled. Set only by
    /// `DictationController.decide` and read only by `isOpen`.
    var decided = false
    /// Started on setup's last page.
    var forSetup = false
    /// When the dictation key went down, for a recording the key's hold
    /// began; its coming up within `DictationController.shortestHold` is a tap.
    var keyDown: ContinuousClock.Instant?
    /// The reply proposal whose card showed when recording started, which
    /// the words that come back change (`ReplyProposalController.dictationStarted`).
    var change: ProposalChangeIntention?
    /// What it is doing: recording, then `processing`, or `writingEmail`
    /// while its email is written and goes in.
    var phase: DictationController.Phase = .recording
    var emailWaitIsLong = false
    var emailWaitTimer: Task<Void, Never>?
    /// The dictations open when it started, which end before its text goes
    /// in.
    private var earlier: [Session]
    /// The accepted reply proposal going in when it started
    /// (`ReplyProposalController.acceptance`), whose text goes in before
    /// this one's, as an earlier dictation's does.
    private var acceptance: Task<Void, Never>?
    /// It started while another was open or a proposal went in, and its
    /// text went in after that ended.
    private(set) var followed = false
    private var hasEnded = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(trigger: DictationController.Trigger, account: Int, earlier: [Session], acceptance: Task<Void, Never>?) {
        self.trigger = trigger
        self.account = account
        self.earlier = earlier
        self.acceptance = acceptance
    }

    /// Returns once every dictation open when this one started has ended,
    /// and the reply proposal going in then has gone in or been refused,
    /// and whether there was one.
    func waitForEarlier() async -> Bool {
        followed = !earlier.isEmpty || acceptance != nil
        if let acceptance { await acceptance.value }
        for session in earlier where !session.hasEnded {
            await withCheckedContinuation { session.waiting.append($0) }
        }
        earlier = []
        acceptance = nil
        return followed
    }

    /// It has ended: those waiting for it go on.
    func ended() {
        hasEnded = true
        earlier = []
        let waiting = waiting
        self.waiting = []
        waiting.forEach { $0.resume() }
    }
}

/// A retry from history while it runs; its connection once it has a grant.
@MainActor
private final class RetryRun {
    var stream: DictationStream?
    var task: Task<Void, Never>?
    var audio: DictationHistory.Retry?
    var retained = false
    var retain: (() -> Void)?

    init(audio: DictationHistory.Retry) { self.audio = audio }

    /// No asynchronous frame retains the PCM: Clear can release it even if
    /// the credentials or vocabulary provider has not returned yet.
    func send(to stream: DictationStream) -> (bytes: Int, timeout: Duration) {
        let chunks = audio?.chunks ?? []
        chunks.forEach(stream.send)
        let bytes = chunks.reduce(0) { $0 + $1.count }
        return (bytes, DictationController.answerTimeout(chunks))
    }

    func cancel() {
        retain?()
        retain = nil
        audio = nil
        task?.cancel()
        task = nil
        stream?.cancel()
        stream = nil
    }
}

/// True for the first caller of `claim` only.
private final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { claimed = true }
        return !claimed
    }
}
