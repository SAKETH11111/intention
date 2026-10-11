import AppKit

/// First-run setup, done rather than read: sign in with an invite code,
/// connect mail so its import runs through the rest of setup, allow the two
/// permissions, dictate into the page's own field and try the dot, speak a
/// reply to one of the person's own threads, or Maya's made-up message when
/// none is ready, and have the real writer answer, then say whether Intention
/// opens at login.
///
/// The device key lives in the `DeviceKeyStore` and the grants in macOS, so
/// the only thing remembered here is how far the person got. Setup resumes
/// from there after a relaunch, which granting Screen Recording can force.
/// Nothing reaches the network before the person submits a code, and the
/// mailbox list is read only while the mail step or the last page is on
/// screen, Settings shows it, or `VoiceReady` waits for an import to end.
/// The thread to answer is asked for only while the dictation or reply
/// page shows.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: String, CaseIterable, Comparable {
        /// `shortcut` is the key to hold: fn, or any keys the person records
        /// with Settings' own recorder, asked only where there is dictation.
        /// `tryIt` is the first dictation, into the page's own field, with
        /// the dot to click after it. `reply` answers an imported thread,
        /// with Maya's example when no suitable thread is available.
        /// `openAtLogin` is the last page,
        /// asked only while Intention does not already open at login; `done`
        /// has no page and means setup is finished.
        case signIn, mail, permissions, shortcut, tryIt, reply, openAtLogin, done

        static func < (left: Step, right: Step) -> Bool {
            allCases.firstIndex(of: left)! < allCases.firstIndex(of: right)!
        }
    }

    enum SignInProblem: Equatable {
        /// A code the server refused: wrong, used or expired.
        case invalidCode
        /// Too many wrong codes from here; the server asks for a pause of
        /// ten minutes.
        case tooManyTries
        /// Too many wrong codes from everyone in a day; the server has
        /// stopped taking codes for hours.
        case paused
        case unreachable
        case server
        /// Signed in, but the key could not be saved. Trying again saves
        /// the same key rather than spending the invite twice.
        case notSaved
        /// This build names no backend.
        case notConfigured
        /// The server no longer accepts this Mac's key.
        case signedOut
    }

    enum MailProblem: Equatable {
        /// The server cannot start this provider's connection.
        case unavailable(AlphaClient.MailProvider)
        case unreachable
        case denied
        case gmailClosed
        case couldNotOpen
        case timedOut
        case cancelled
    }

    private(set) var step: Step {
        // A request still waiting when the permissions page goes, as it
        // turns or an account change sends setup back, opens nothing over
        // the page that follows.
        didSet {
            if oldValue == .permissions, step != .permissions { asking.forEach { $0.cancel() } }
            // However the shortcut page is left, an account reset included,
            // Settings' recorder stops taking the keyboard.
            if oldValue == .shortcut, step != .shortcut { dictation?.cancelRecording() }
        }
    }
    /// The digits of the invite code entered so far, six at most.
    private(set) var digits = ""
    private(set) var isSigningIn = false
    private(set) var signInProblem: SignInProblem?
    @ObservationIgnored private var inviteFilePath: String?
    private(set) var granted: Set<SetupPermission> = []
    /// The ones the person has pressed Allow for, so the page can say what
    /// to do next in macOS's alert and the System Settings list.
    private(set) var asked: Set<SetupPermission> = []
    private(set) var connections: [AlphaClient.MailConnection] = []
    private(set) var learning: AlphaClient.MailLearning?
    /// Change this default to offer new Outlook connections again. Existing
    /// connections and their writer eligibility still follow the server.
    static let offersOutlookByDefault = false
    @ObservationIgnored private let offersOutlook: Bool
    @ObservationIgnored private var mailDisconnectAttempt: UUID?
    private(set) var disconnectingMail: UUID?
    private var failedMailDisconnect: UUID?
    var mailDisconnectFailed: Bool { failedMailDisconnect != nil }
    var settingsConnections: [AlphaClient.MailConnection] {
        connections.filter { AlphaClient.MailProvider(rawValue: $0.provider) != nil }
    }
    var canChangeMail: Bool { false }
    var canAddMail: Bool { false }
    private var permittedMailProviders: [AlphaClient.MailProvider] {
        availableProviders.filter { provider in
            provider != .outlook || offersOutlook || connections.contains { $0.provider == provider.rawValue }
        }
    }
    var offeredMailProviders: [AlphaClient.MailProvider] { [] }

    /// Two providers leave room under their rows. One provider, or a line
    /// while mail is checked, gets paper just deep enough for the row and
    /// the envelope drawing beside it.
    /// The paper grows past this to fit consent opened under a row;
    /// connected mail keeps its own space above the offers.
    var mailPageHeight: CGFloat {
        let rows: CGFloat = availableConnections.isEmpty
            ? (offeredMailProviders.count > 1 ? 256 : 112)
            : 176 + 52 * CGFloat(offeredMailProviders.count)
        return rows + (awaiting == nil ? 0 : 62)
    }
    private(set) var availableProviders: [AlphaClient.MailProvider] = []
    private(set) var gmailConnectOpen = true
    private(set) var retryMailProvider: AlphaClient.MailProvider?
    var dictationOnlySetup: Bool { false }
    private static let dictationOnlyKey = "setupDictationOnly"
    var availableConnections: [AlphaClient.MailConnection] {
        connections.filter { connection in availableProviders.contains { $0.rawValue == connection.provider } }
    }
    /// The provider whose native authentication session is active.
    private(set) var awaiting: AlphaClient.MailProvider?
    private(set) var isConnecting = false
    /// False once the server has answered that it has no providers or mail routes.
    private(set) var isMailOffered = false
    /// Whether the server has answered for the mailbox list since launch,
    /// so Settings says it is checking rather than offering to connect a
    /// mailbox that is in fact connected.
    private(set) var hasReadMail = false
    /// The last attempt to read the mailbox list failed, so Settings can
    /// say so and offer setup's mail page rather than keep checking.
    private(set) var mailReadFailed = false
    private(set) var mailProblem: MailProblem?
    /// The keychain would not give up the key: macOS asked the person and
    /// was told no, or the keychain is locked. Dictation has no account
    /// until a read succeeds, so the menu bar item says so and offers one.
    private(set) var isKeyUnreadable = false

    /// Called with true when this Mac signs in and false when it is signed
    /// out, so dictation follows the account.
    @ObservationIgnored var accountChanged: ((Bool) -> Void)?
    /// A fixed permission and its observed grant, never a system message.
    @ObservationIgnored var permissionReported: ((SetupPermission, Bool) -> Void)?
    /// Called when setup first reaches its end, however the last page was
    /// left, so a permission setup does not ask for is asked for then and
    /// not only at the next launch. Main actor only, written into the type
    /// so it cannot be handed to a framework callback that runs elsewhere.
    @ObservationIgnored var finished: (@MainActor () -> Void)?

    /// Called when something the person did outside Intention has landed, a
    /// grant in System Settings or consent in the browser, so the window
    /// can come back to the front.
    @ObservationIgnored var returned: (() -> Void)?
    /// What the last page's recap may promise, read from the person's
    /// settings; nil, as in the fixture, promises everything.
    @ObservationIgnored var offers: (@MainActor () -> Offers)?
    /// Called with the mailbox list each time one is read, changed or not,
    /// so `VoiceReady` sees every list the server gives.
    @ObservationIgnored var mailChanged: (@MainActor ([AlphaClient.MailConnection]) -> Void)?
    @ObservationIgnored private var mailReadID: UUID?
    /// Called when the reply page's writer has answered, or its answer was
    /// dropped, so work that waited for the page to be quiet, such as an
    /// update's install, can go ahead. Main actor only.
    @ObservationIgnored var replyEnded: (@MainActor () -> Void)?
    /// Runs as the writer starts on the practice email, so the foot mark
    /// warms while it writes, as after a dictation in Gmail.
    @ObservationIgnored var replyStarted: (@MainActor () -> Void)?

    /// Nil in a build without dictation; the dictation and reply pages then
    /// only say what Intention does.
    @ObservationIgnored let dictation: FirstDictation?
    /// Nil in a build without a writer; the reply page then shows the
    /// example in place of a real email.
    @ObservationIgnored let practice: PracticeReply?
    /// Nil in a build without dictation; the dictation page then asks
    /// nothing about languages.
    @ObservationIgnored let languages: DictationLanguages?
    /// Nil where nothing should be registered with macOS, as in the
    /// fixture; setup then asks nothing about opening at login.
    @ObservationIgnored let loginItem: SetupLoginItem?
    /// Whether macOS will be asked for Screen Recording as setup ends, so
    /// the last page can show the switch before the alert comes. Nil means
    /// it will not be.
    @ObservationIgnored let screenRecordingDue: (@MainActor () -> Bool)?
    /// Where each first is noted for the first-run report; nil keeps none.
    @ObservationIgnored let record: FirstRunRecord?
    /// The name the first page greets, the Mac account's own unless a
    /// fixture or a render gives a made-up one, so no recording of setup
    /// carries the person's name.
    @ObservationIgnored let fullName: String
    /// The Mac's own preferred languages, which the question offers first.
    @ObservationIgnored let preferredLanguages: [String]
    /// The languages picked, as two-letter codes. Read from where they are
    /// saved each time, because Settings changes the same choice.
    var chosenLanguages: [String] { LanguageChoice.chosen(from: languages?.current() ?? []) }
    /// When the dictation page opened, or Retry cleared what went wrong, so
    /// an earlier dictation is not shown on it. Observed, so Retry redraws.
    private var tryItOpened = Date()
    /// When the reply page opened, so words from the dictation page are not
    /// taken for a reply.
    @ObservationIgnored private var replyOpened = Date()
    /// An attempt still ending when the first dictation page was left
    /// belongs to that page, including its words, silence or failure.
    private var awaitingFirstDictation = false
    /// The words the writer is working from, while it works.
    private(set) var replySpoken: String?
    /// The words the written email came from, which the page shows beside
    /// it as "You said".
    private(set) var replySaid: String?
    /// What the reply page's field takes: the email, or the words typed in
    /// its place, and when they came.
    private(set) var replyWords: (text: String, at: Date)?
    /// Said under the field when the words were typed because no email came.
    private(set) var replyNotice: String?
    /// The writer's fixed name for why no email came.
    private(set) var replyFailureName: String?
    /// Why no email came, said exactly, beside the notice.
    var replyFailure: String? { replyFailureName.map(PracticeReply.reason(for:)) }
    /// The arrival the writer was last asked about, so each is asked once.
    @ObservationIgnored private var replyHandled: Date?
    @ObservationIgnored private var replyWrite: UUID?
    /// Field callbacks name an answer, which can outlive a newer dictation or window.
    @ObservationIgnored private var replyOrigins: [Date: Date] = [:]

    @ObservationIgnored private let client: AlphaClient?
    @ObservationIgnored private let keys: DeviceKeyStore
    @ObservationIgnored private let permissions: SetupPermissions
    @ObservationIgnored private let mail: any MailConnecting
    @ObservationIgnored var mailAnchor: NSWindow?
    @ObservationIgnored private var mailTask: Task<UUID, any Error>?
    @ObservationIgnored private var mailAttempt: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pollInterval: Duration
    /// The wait between Settings' reads of the mailbox list while it is
    /// open: five seconds in the app, stepped by hand in the checks. It
    /// returns at once when the task is cancelled.
    @ObservationIgnored private let followPause: @Sendable () async -> Void
    /// How long a tick stays on screen before setup moves on by itself.
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private var deviceKey: String?
    /// A key the server issued that the store refused.
    @ObservationIgnored private var unsavedKey: String?
    /// Counts the times the window has closed. Work started for the person
    /// that is still waiting when it closes, the next permission request or
    /// a consent page about to open, compares this and stops, so nothing
    /// opens in front of someone who has left setup.
    @ObservationIgnored private var closes = 0
    /// Permission requests still waiting. Closing the window cancels them,
    /// so one that would open System Settings after its wait opens nothing
    /// in front of someone who has left setup. An answer macOS gives later
    /// is still kept.
    @ObservationIgnored private var asking: Set<Task<Void, Never>> = []
    /// When the latest permission's tick has shown for long enough that the
    /// page may turn.
    @ObservationIgnored private var tickUntil = ContinuousClock.now

    private static let stepKey = "onboardingStep"
    /// Which page order the saved step belongs to: 2 since mail comes
    /// straight after sign-in.
    private static let orderKey = "onboardingStepOrder"
    private static let order = 2
    private static let signedOutKey = "onboardingSignedOut"

    init(client: AlphaClient?, keys: DeviceKeyStore, permissions: SetupPermissions, mail: any MailConnecting = MailAuthentication(),
         dictation: FirstDictation? = nil, practice: PracticeReply? = nil, languages: DictationLanguages? = nil,
         loginItem: SetupLoginItem? = nil, screenRecordingDue: (@MainActor () -> Bool)? = nil, record: FirstRunRecord? = nil,
         fullName: String = NSFullUserName(), preferredLanguages: [String] = Locale.preferredLanguages, defaults: UserDefaults = .standard,
         pollInterval: Duration = .seconds(2), followPause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(5)) },
         settle: Duration = .milliseconds(900), replySubjectInterval: Duration = .seconds(10),
         replySubjectTimeout: Duration = .seconds(5), offersOutlook: Bool = OnboardingModel.offersOutlookByDefault) {
        self.offersOutlook = offersOutlook
        self.replySubjectInterval = replySubjectInterval
        self.replySubjectTimeout = replySubjectTimeout
        self.settle = settle
        self.dictation = dictation
        self.practice = practice
        self.languages = languages
        self.loginItem = loginItem
        self.screenRecordingDue = screenRecordingDue
        self.record = record
        self.fullName = fullName
        self.preferredLanguages = preferredLanguages
        self.client = client
        self.keys = keys
        self.permissions = permissions
        self.mail = mail
        self.defaults = defaults
        self.pollInterval = pollInterval
        self.followPause = followPause
        // A value an earlier build saved for a page that no longer exists
        // reads as nothing saved, and the key below decides where to resume.
        step = defaults.string(forKey: Self.stepKey).flatMap(Step.init(rawValue:)) ?? .signIn
        // Builds before mail moved second saved the permissions and the
        // first dictation before mail, so such a setup resumes on mail once.
        // The order marker keeps what this build saves as it is.
        if defaults.integer(forKey: Self.orderKey) < Self.order {
            if [.permissions, .shortcut, .tryIt].contains(step) {
                step = .mail
                defaults.set(Step.mail.rawValue, forKey: Self.stepKey)
            }
            defaults.set(Self.order, forKey: Self.orderKey)
        }
        refreshPermissions()
        if defaults.bool(forKey: Self.signedOutKey) {
            // The server refused the stored key, and deleting it may have
            // failed then; it is not used again either way.
            try? keys.delete()
            step = .signIn
            return
        }
        do {
            deviceKey = try keys.read()
            if deviceKey == nil {
                // No key means no account on this Mac, so whoever signs in
                // next starts setup from the beginning; progress saved for
                // an earlier account is not theirs.
                defaults.removeObject(forKey: Self.stepKey)
                step = .signIn
            } else if step == .signIn {
                // Signed in with nothing further saved: on to what comes
                // after the code.
                step = afterSignIn
            } else if step != .done {
                // A missing required grant sends an unfinished setup back
                // to ask for it. A finished one is left alone; the menu bar
                // item asks instead.
                step = resumedStep
            }
        } catch {
            // An unreadable store says nothing about the key. Asking for a
            // second invite would strand the first account, so stay put,
            // and say so in the menu bar item.
            AppLog.event("Device key could not be read")
            isKeyUnreadable = true
        }
        // The last question, saved before a quit, is not asked again once
        // Intention opens at login another way, as from Settings meanwhile.
        if step == .openAtLogin, !asksOpenAtLogin { advance(to: .done) }
    }

    var isFinished: Bool { step == .done }
    var hasRequiredPermissions: Bool { SetupPermission.required.allSatisfy(granted.contains) }
    /// The one to ask for now: the first that is not granted.
    var currentAsk: SetupPermission? { SetupPermission.required.first { !granted.contains($0) } }
    var inviteCode: String? { digits.count == Self.codeLength ? digits : nil }
    /// Whether a dictation made now is one of setup's pages' own: the two
    /// pages with a field of their own are showing.
    var isPracticePage: Bool { step == .tryIt || step == .reply }
    /// Whether holding the shortcut now only shows it is heard, pressing
    /// the page's caps down, and starts no dictation: on the shortcut page,
    /// which has no field, so no dictation's words can cross to the next.
    var holdOnlyShows: Bool { step == .shortcut }

    /// Whether the shortcut's keys are held now, alone.
    var shortcutHeld: Bool { dictation?.listener?.isHeld == true }
    /// Whether the person is finishing a mail connection in the browser,
    /// so the window can stay above it with the three clicks in view.
    var isAwaitingMail: Bool { awaiting != nil }

    static let codeLength = 6

    /// The page after the code: mail, so its import runs through the rest
    /// of setup.
    private var afterSignIn: Step { .mail }

    /// The page after the permissions: the shortcut, where there is
    /// dictation to choose one for, or else the first dictation's page,
    /// which then only says what Intention does. Also where mail leads on a
    /// Mac that already allows both.
    private var afterPermissions: Step { dictation == nil ? .tryIt : .shortcut }

    /// Where an unfinished setup resumes with a key: sign-in and mail as
    /// themselves, since mail comes before the permissions, and a later
    /// page back to the permissions while one is missing.
    private var resumedStep: Step {
        guard step >= .permissions, step != .done else { return step }
        guard hasRequiredPermissions else { return .permissions }
        if step == .reply, dictationOnlySetup { return asksOpenAtLogin ? .openAtLogin : .done }
        return max(step, afterPermissions)
    }

    /// Takes what the person typed or pasted into the code cells: digits, a
    /// code written with spaces, or the whole invite link, whose code
    /// follows "#". The sixth digit signs in; there is no button to press.
    func enter(_ input: String) {
        guard !isSigningIn else { return }
        let entered = String(Self.digits(in: input).prefix(Self.codeLength))
        guard entered != digits else { return }
        digits = entered
        if signInProblem == .invalidCode { signInProblem = nil }
        if inviteCode != nil { Task { await signIn() } }
    }

    nonisolated static func digits(in input: String) -> String {
        let code = input.split(separator: "#", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return code.filter { $0.isASCII && $0.isNumber }
    }

    /// The greeting on the first page: the time of day, and the person's
    /// first name when the Mac knows it.
    nonisolated static func greeting(hour: Int, fullName: String) -> String {
        let time = switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Hello"
        }
        guard let name = fullName.split(separator: " ").first, name.count <= 14 else { return "\(time)." }
        return "\(time), \(name)."
    }

    /// The setup window came on screen. Noted once, as where the first-run
    /// clock starts.
    func windowShown() {
        record?.mark(.setupOpened)
    }

    // MARK: - Sign in

    func signIn(code suppliedCode: String? = nil) async {
        guard !isSigningIn else { return }
        if let unsavedKey {
            keep(unsavedKey)
            return
        }
        let code: String
        if let supplied = suppliedCode ?? inviteCode { code = supplied }
        else if let inviteFilePath {
            do { code = try ProtectedInvite.read(path: inviteFilePath) }
            catch { signInProblem = .invalidCode; return }
        } else { return }
        guard let client else {
            signInProblem = .notConfigured
            return
        }
        isSigningIn = true
        signInProblem = nil
        defer { isSigningIn = false }
        do {
            let registration = try await client.signIn(inviteCode: code)
            keep(registration.deviceKey)
        } catch AlphaClient.Failure.rejected(401), AlphaClient.Failure.rejected(422) {
            // Cleared so the next digit typed starts a new code.
            digits = ""
            signInProblem = .invalidCode
        } catch let AlphaClient.Failure.tooManyRequests(retryAfter) {
            digits = ""
            // The server's short limits ask for ten minutes. A longer wait
            // is its daily limit, and "ten minutes" would not be true.
            signInProblem = (retryAfter ?? 0) > 15 * 60 ? .paused : .tooManyTries
        } catch is URLError {
            signInProblem = .unreachable
        } catch {
            signInProblem = .server
        }
    }

    #if DEBUG
    func signInFromFileIfRequested(arguments: [String]) async {
        guard step == .signIn, deviceKey == nil, !isSigningIn,
              let index = arguments.firstIndex(of: "--sign-in-file"),
              arguments.indices.contains(index + 1) else { return }
        do {
            inviteFilePath = arguments[index + 1]
            let code = try ProtectedInvite.read(path: arguments[index + 1])
            await signIn(code: code)
        } catch {
            signInProblem = .invalidCode
        }
    }
    #endif

    private func keep(_ key: String) {
        do {
            try keys.save(key)
        } catch {
            AppLog.event("Device key could not be saved")
            unsavedKey = key
            signInProblem = .notSaved
            return
        }
        cancelMail()
        unsavedKey = nil
        inviteFilePath = nil
        deviceKey = key
        isKeyUnreadable = false
        signInProblem = nil
        defaults.removeObject(forKey: Self.signedOutKey)
        record?.mark(.signedIn)
        setupInteractionID = UUID()
        shownReplyOutcomes.removeAll()
        accountChanged?(true)
        // The filled cells stay on screen for a moment before the page turns.
        Task {
            try? await Task.sleep(for: settle)
            digits = ""
            if step == .signIn { advance(to: afterSignIn) }
        }
    }

    /// Whether the code just entered was accepted and the page is about to
    /// turn.
    var isSignedIn: Bool { step == .signIn && deviceKey != nil }

    /// Whether a Try Again makes sense: a key is waiting to be saved, or
    /// the code is still in the cells after the server could not be asked.
    var canRetry: Bool {
        guard !isSigningIn, deviceKey == nil else { return false }
        return unsavedKey != nil || ((inviteCode != nil || inviteFilePath != nil) && signInProblem != nil)
    }

    /// The server refused the key, so this Mac needs a new invite.
    private func signedOut() {
        cancelMail()
        // Remembered, because a key that could not be deleted would be read
        // at the next launch and skip sign-in. And the next account starts
        // setup from the beginning; it does not inherit this one's progress.
        defaults.set(true, forKey: Self.signedOutKey)
        defaults.removeObject(forKey: Self.stepKey)
        try? keys.delete()
        deviceKey = nil
        connections = []
        disconnectingMail = nil
        mailDisconnectAttempt = nil
        failedMailDisconnect = nil
        learning = nil
        availableProviders = []
        gmailConnectOpen = true
        retryMailProvider = nil
        defaults.removeObject(forKey: Self.dictationOnlyKey)
        hasReadMail = false
        mailReadFailed = false
        awaiting = nil
        mailProblem = nil
        signInProblem = .signedOut
        resetFirstKeyCheck()
        openReply()
        step = .signIn
        setupInteractionID = UUID()
        shownReplyOutcomes.removeAll()
        accountChanged?(false)
    }

    /// The device key for Intention's other requests to the backend, such as
    /// dictation's speech grants; nil while signed out.
    var backendKey: String? { currentKey() }

    /// Another request made with `key` was refused (401), so this Mac is
    /// signed out as when one of setup's own is. A key replaced since is
    /// left alone.
    func backendKeyRefused(_ key: String) {
        guard key == currentKey() else { return }
        signedOut()
    }

    /// From the menu bar item, after the keychain refused to give up the
    /// key: reads it again, which makes macOS ask again. A read that
    /// succeeds signs dictation in; one that fails leaves the item there.
    func retryKeyRead() {
        _ = readCurrentKey()
    }

    // MARK: - Permissions

    /// From the Allow button. The press is taken before the button
    /// returns, so a window closed between the press and the request's
    /// turn stops it before macOS is asked. The task is returned for tests
    /// to wait on.
    @discardableResult
    func allow(_ permission: SetupPermission) -> Task<Void, Never> {
        let closes = closes
        return Task {
            guard closes == self.closes else { return }
            await request(permission)
        }
    }

    /// The page's one button: asks for whatever is not yet allowed, in
    /// order. One press carries through both.
    @discardableResult
    func allowNext() -> Task<Void, Never>? {
        currentAsk.map(allow)
    }

    func request(_ permission: SetupPermission) async {
        let wasGranted = granted.contains(permission)
        asked.insert(permission)
        let closes = closes
        let asking = Task {
            // The window can close before this task begins; then macOS is
            // not asked at all.
            guard !Task.isCancelled else { return }
            await permissions.request(permission)
        }
        self.asking.insert(asking)
        await asking.value
        self.asking.remove(asking)
        guard closes == self.closes else {
            // The window closed while macOS was asking. The answer is kept
            // and gets its tick, and it leads to no further request.
            let found = Set(SetupPermission.allCases.filter(permissions.isGranted))
            if !found.isSubset(of: granted) { tickUntil = .now + settle }
            granted = found
            permissionReported?(permission, found.contains(permission))
            return
        }
        refreshPermissions()
        if wasGranted == granted.contains(permission) {
            permissionReported?(permission, permissions.isGranted(permission))
        }
    }

    /// Rereads the grants until cancelled, since the person changes them in
    /// System Settings, outside Intention.
    func watchPermissions() async {
        while !Task.isCancelled {
            refreshPermissions()
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    func refreshPermissions() {
        let found = Set(SetupPermission.allCases.filter(permissions.isGranted))
        guard found != granted else { return turnWhenSettled() }
        let gained = found.subtracting(granted)
        let changed = found.symmetricDifference(granted)
        granted = found
        for permission in changed { permissionReported?(permission, found.contains(permission)) }
        guard !gained.isEmpty, step == .permissions else { return }
        returned?()
        // One press carries the person through: once they have allowed one,
        // the next is asked for without another press, and the page turns by
        // itself when the last is in. The tick shows for a moment first.
        let pressedAllow = !gained.isDisjoint(with: asked)
        let closes = closes
        tickUntil = .now + settle
        Task {
            try? await Task.sleep(for: settle)
            guard closes == self.closes, step == .permissions else { return }
            if let next = currentAsk {
                if pressedAllow, !asked.contains(next) { await request(next) }
            } else {
                turnWhenSettled()
            }
        }
    }

    /// Turns the page once everything is allowed and the latest tick has had
    /// its moment. Each grant's own timer calls this, and so does every
    /// reread of the grants, so the turn still happens when its timer was
    /// dropped with a closed window, and never before the last tick has
    /// shown, whichever grant's timer comes first.
    private func turnWhenSettled() {
        guard step == .permissions, hasRequiredPermissions, ContinuousClock.now >= tickUntil else { return }
        record?.mark(.permissionsGranted)
        resetFirstKeyCheck()
        advance(to: afterPermissions)
    }

    // MARK: - Shortcut

    /// Whether the shortcut page leads with recording one: no keyboard with
    /// fn was connected when the page opened, as with most keyboards not
    /// made by Apple. Unknown leads with fn, which almost every Mac has.
    private(set) var leadsWithRecording = false

    /// Reads the keyboards as the shortcut page opens.
    func readKeyboards() {
        leadsWithRecording = dictation?.hasFnKey() == false
    }

    /// What the shared recorder is doing, as the shortcut page shows it.
    var shortcutRecording: FirstDictation.Recording { dictation?.recording() ?? FirstDictation.Recording() }

    /// Whether the key to hold is fn.
    var holdsFn: Bool { dictation?.keyName() == "fn" }

    func useFn() {
        dictation?.cancelRecording()
        recordingStarted = nil
        recordingRefusedToStart = false
        chooseDictationKey("fn")
    }

    /// Listens for the keys the person presses next, with Settings' own
    /// recorder, which saves them once they are let go; pressed again it
    /// stops listening.
    func recordShortcut() {
        guard let dictation else { return }
        if dictation.recording().isRecording {
            dictation.cancelRecording()
            recordingStarted = nil
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let dictation else { return }
        recordingExpired = false
        dictation.startRecording()
        // The recorder does not start while a dictation is recording.
        recordingRefusedToStart = !dictation.recording().isRecording
        recordingStarted = recordingRefusedToStart ? nil : Date()
    }

    /// How long the recorder listens with no key pressed before the page
    /// says it has seen none.
    static let recordingWait: TimeInterval = 5
    @ObservationIgnored private var recordingStarted: Date?
    private var recordingExpired = false
    private var recordingRefusedToStart = false

    /// What went wrong while choosing a shortcut, each with Retry.
    enum ShortcutProblem: Equatable {
        /// The keys pressed cannot be a shortcut, with the recorder's reason.
        case refused(String)
        /// The recorder has listened for `recordingWait` and seen no key.
        case nothingPressed
        /// The recorder would not start, as while a dictation records.
        case couldNotStart
        /// The keyboard listener cannot hear anything, so neither can the recorder.
        case listener(FnListenerRecovery.State)
    }

    var shortcutProblem: ShortcutProblem? {
        if recordingRefusedToStart { return .couldNotStart }
        let recording = shortcutRecording
        guard recording.isRecording else { return nil }
        if let refusal = recording.refusal { return .refused(refusal) }
        guard recordingExpired, recording.shown == nil else { return nil }
        // Setup's own window can still hear keys when the listener for other
        // apps cannot, so a listener that cannot hear is named only once the
        // recorder has heard nothing either.
        switch dictation?.listener?.state {
        case let state? where state == .waitingForAccessibility || state == .blockedBySecureInput || state == .failed:
            return .listener(state)
        default: return .nothingPressed
        }
    }

    var shortcutProblemMessage: String? {
        switch shortcutProblem {
        case let .refused(reason)?: reason
        case .nothingPressed?: "Intention hasn't seen a key yet. Press the keys you want, then let go."
        case .couldNotStart?: "Intention can't record while it's dictating. Let go of your shortcut, then retry."
        case let .listener(state)?: Self.listenerMessage(state)
        case nil: nil
        }
    }

    /// The same words for a listener that cannot hear, wherever setup checks keys.
    static func listenerMessage(_ state: FnListenerRecovery.State) -> String {
        switch state {
        case .blockedBySecureInput: "A password field or Secure Keyboard Entry is holding the keyboard. Click somewhere else, then retry."
        case .waitingForAccessibility: "Allow Accessibility in System Settings, then retry."
        case .failed, .checking, .live: "Intention can't hear the keyboard. If Retry doesn't help, quit and reopen Intention."
        }
    }

    /// Starts listening for keys again, after asking the keyboard listener
    /// to recover when it is the one that could not hear.
    func retryShortcut() {
        guard let dictation else { return }
        if case .listener? = shortcutProblem { dictation.retryListener() }
        dictation.cancelRecording()
        startRecording()
    }

    /// A deterministic tick shared by the page's watcher and its tests.
    func checkShortcut(at date: Date = Date()) {
        guard let started = recordingStarted, shortcutRecording.isRecording else { return }
        if shortcutRecording.shown != nil || shortcutRecording.refusal != nil {
            // A key was seen: the wait starts again from here.
            recordingStarted = date
            recordingExpired = false
        } else if date.timeIntervalSince(started) >= Self.recordingWait {
            recordingExpired = true
        }
    }

    /// Follows the shortcut page while it shows, so a recorder that hears
    /// nothing says so.
    func watchShortcut() async {
        readKeyboards()
        while !Task.isCancelled, step == .shortcut {
            checkShortcut()
            try? await Task.sleep(for: .milliseconds(200))
        }
        dictation?.cancelRecording()
    }

    /// On from the shortcut to try it, with a fresh check of the key.
    func continueFromShortcut() {
        guard step == .shortcut else { return }
        recordingRefusedToStart = false
        recordingStarted = nil
        dictation?.cancelRecording()
        resetFirstKeyCheck()
        advance(to: .tryIt)
    }

    /// Back from the first dictation to choose another shortcut.
    func changeShortcut() {
        guard step == .tryIt, dictation != nil else { return }
        advance(to: .shortcut)
    }

    // MARK: - First dictation

    /// The check of the shortcut on the dictation page, whichever it is: a
    /// press of it, down and up, proves it.
    enum KeyCheck: Equatable {
        case waiting, works
        /// No press of the shortcut has come: another modifier, named, was
        /// pressed instead, or nil when nothing was in `keyCheckWait`.
        case notSeen(other: String?)
        /// The keyboard listener cannot hear anything at all.
        case problem(FnListenerRecovery.State)
    }
    /// How long the page waits for a press before it says none has come.
    /// What it says then blames nothing, so a wait short enough that nothing
    /// seems to hang is fine.
    static let keyCheckWait: TimeInterval = 5
    private var keyCheckStarted: Date?
    private var keyCheckExpired = false
    var keyCheckSkipped: Bool { defaults.bool(forKey: "fnCheckSkipped") }

    private func resetFirstKeyCheck() {
        tryItOpened = Date()
        keyCheckStarted = nil
        keyCheckExpired = false
        defaults.removeObject(forKey: "fnCheckSkipped")
        dictation?.listener?.resetProof()
    }

    var firstKeyCheck: KeyCheck? {
        guard let listener = dictation?.listener else { return nil }
        switch listener.state {
        case .waitingForAccessibility, .blockedBySecureInput, .failed: return .problem(listener.state)
        case .checking, .live: break
        }
        let since = keyCheckStarted ?? tryItOpened
        if let completed = listener.completedPress, completed.began >= since, completed.ended >= completed.began {
            return .works
        }
        // Holding the shortcut is a press on its way, whatever came before.
        guard firstDictation != .listening else { return .waiting }
        if let other = listener.otherKey, other.at >= since { return .notSeen(other: other.name) }
        return keyCheckExpired ? .notSeen(other: nil) : .waiting
    }

    /// What the key row says about the check, naming the shortcut.
    var firstKeyMessage: String? {
        let key = dictation?.keyName() ?? "fn"
        return switch firstKeyCheck {
        case .waiting: "Press \(key) once to check it"
        case .works: "\(key) works"
        case let .notSeen(other?): "Intention saw \(other), not \(key). Hold \(key), or change the shortcut."
        case .notSeen(nil): "Intention hasn't seen \(key) yet. Press it once, or change the shortcut."
        case let .problem(state): Self.listenerMessage(state)
        case nil: nil
        }
    }

    /// Whether the key row says something went wrong, rather than what to do.
    var firstKeyFailed: Bool {
        switch firstKeyCheck {
        case .notSeen?, .problem?: true
        case .waiting?, .works?, nil: false
        }
    }

    func retryFirstKey() {
        keyCheckStarted = Date()
        keyCheckExpired = false
        dictation?.listener?.resetProof()
        dictation?.retryListener()
    }

    /// A deterministic tick shared by the page's watcher and its tests.
    func checkFirstKey(at date: Date = Date()) {
        if keyCheckStarted == nil { keyCheckStarted = tryItOpened }
        if date.timeIntervalSince(keyCheckStarted ?? date) >= Self.keyCheckWait { keyCheckExpired = true }
    }

    /// What the dictation page shows: waiting for the key, listening,
    /// finishing, or the words of a dictation made since the page opened.
    var firstDictation: FirstDictation.Moment {
        guard let dictation, dictation.isAvailable() else { return .unavailable }
        switch dictation.phase() {
        case .listening: return .listening
        case .finishing: return .finishing
        case .idle:
            // The newest try made on this page decides: words, unless a
            // later try failed or heard nothing, which takes the page back
            // to asking.
            if case let .words(text)? = lastTry(since: tryItOpened)?.end { return .heard(text) }
            return .waiting
        }
    }

    /// The newest words dictated since the dictation page opened, and when
    /// they arrived, whatever was tried after them. The page's field takes
    /// each arrival once and keeps it.
    func firstDictationInserted(_ text: String, at: Date) { dictation?.inserted(text, at) }

    func replyInserted(_ text: String, at: Date) {
        guard let original = replyOrigins[at] else { return }
        dictation?.inserted(text, original)
        practice?.inserted(text, original)
    }

    /// What the pages' fields are given: their words, held back while the
    /// app quits and given again if the quit is refused.
    var firstDictationFieldWords: (text: String, at: Date)? { isQuitting ? nil : firstDictationWords }
    var replyFieldWords: (text: String, at: Date)? { isQuitting ? nil : replyWords }
    private var isQuitting: Bool { dictation?.isQuitting() ?? false }

    var firstDictationWords: (text: String, at: Date)? {
        words(since: tryItOpened)
    }

    private func words(since opened: Date) -> (text: String, at: Date)? {
        guard let latest = dictation?.latest(), latest.at >= opened else { return nil }
        return latest
    }

    /// How a try on a page can end.
    private enum TryEnd: Equatable {
        case words(String), missed, silent
    }

    /// How the newest try made since a page opened ended, by when it
    /// ended. Tries from before the page opened are not that page's.
    private func lastTry(since opened: Date) -> (end: TryEnd, at: Date)? {
        guard let dictation else { return nil }
        var ends: [(end: TryEnd, at: Date)] = []
        if let latest = dictation.latest() { ends.append((.words(latest.text), latest.at)) }
        if let missed = dictation.missed() { ends.append((.missed, missed)) }
        if let silent = dictation.silent() { ends.append((.silent, silent)) }
        return ends.filter { $0.at >= opened }.max { $0.at < $1.at }
    }

    /// Whether the dictation page asks about languages: there is somewhere
    /// to save the answer, and dictation, when the page has it, can be tried.
    var asksLanguages: Bool {
        languages != nil && (dictation?.isAvailable() ?? true)
    }

    /// Whether the page should say the microphone could not be used, in
    /// place of asking again as if nothing had happened.
    var firstDictationNeedsMicrophone: Bool {
        guard let dictation, firstDictation == .waiting, dictation.microphoneFailed() else { return false }
        // A failure Retry has cleared stays cleared until the next one.
        return dictation.microphoneFailedAt().map { $0 >= tryItOpened } ?? true
    }

    /// Whether the last try on this page failed, so the page says so in
    /// place of asking again as if nothing had happened.
    var firstDictationMissed: Bool {
        firstDictation == .waiting && lastTry(since: tryItOpened)?.end == .missed
    }

    /// Whether the last try on this page came back with no words at all,
    /// so the page says so and what to check.
    var firstDictationSilent: Bool {
        firstDictation == .waiting && lastTry(since: tryItOpened)?.end == .silent
    }

    /// What went wrong with the last try on the dictation page, said
    /// exactly, or nil when nothing did: the microphone would not open or
    /// sent only silence, there was sound but no words, or the words did
    /// not come back from the server.
    var firstDictationProblem: String? {
        let key = dictation?.keyName() ?? "fn"
        if firstDictationNeedsMicrophone {
            return "Intention couldn't open the microphone. Allow it in System Settings, then retry."
        }
        if firstDictationSilent {
            return dictation?.silenceWasMicrophone() == true
                ? "The microphone sent only silence. Choose another in Intention's Settings, then retry."
                : "Intention heard sound but no words. Hold \(key), say a sentence, then let go."
        }
        if firstDictationMissed { return "The words didn't come back from Intention's server." }
        return nil
    }

    /// Clears what went wrong, so the page asks for a dictation again.
    func retryFirstDictation() {
        guard step == .tryIt else { return }
        if keyCheckStarted == nil { keyCheckStarted = tryItOpened }
        tryItOpened = Date()
    }

    func chooseDictationKey(_ name: String) {
        guard let dictation, dictation.keyNames().contains(name) else { return }
        dictation.chooseKey(name)
    }

    /// A click on a page's dot: the second trigger, tried where it is
    /// taught. Starts a dictation into the page's field, or ends one.
    func toggleDictation() {
        guard isPracticePage, let dictation, dictation.isAvailable() else { return }
        if step == .reply, !awaitingFirstDictation { lockReplySubject() }
        dictation.toggle()
    }

    /// On from the first dictation, with or without one made.
    func continueFromDictation() {
        guard step == .tryIt else { return }
        let skipped = firstKeyCheck != nil && firstKeyCheck != .works
        defaults.set(skipped, forKey: "fnCheckSkipped")
        if skipped { dictation?.skippedKeyCheck() }
        awaitingFirstDictation = (dictation?.phase() ?? .idle) != .idle
        replyOpened = Date()
        advance(to: dictationOnlySetup ? (asksOpenAtLogin ? .openAtLogin : .done) : .reply)
    }

    // MARK: - Languages

    /// One language pressed on the dictation page. The choice is saved at
    /// once, so the first dictation already uses it.
    func toggleLanguage(_ code: String) {
        guard let languages else { return }
        let chosen = chosenLanguages
        let next = LanguageChoice.toggled(code, in: chosen)
        guard next != chosen else { return }
        languages.save(LanguageChoice.saved(for: next))
    }

    // MARK: - Mail

    func connect(_ provider: AlphaClient.MailProvider) async {
        guard step == .mail, !isConnecting, disconnectingMail == nil, !Task.isCancelled else { return }
        let opening = closes, startingKey = currentKey()
        if !hasReadMail { await refreshMail() }
        guard closes == opening, startingKey == currentKey(), step == .mail, !isConnecting, !Task.isCancelled,
              hasReadMail, disconnectingMail == nil, isMailOffered, permittedMailProviders.contains(provider) else { return }
        guard provider != .gmail || gmailConnectOpen || connections.contains(where: { $0.provider == "gmail" }) else { return }
        guard let client, let deviceKey = currentKey(), let anchor = mailAnchor else {
            mailProblem = .unavailable(provider)
            return
        }
        let attempt = UUID()
        mailAttempt = attempt
        isConnecting = true
        awaiting = provider
        mailProblem = nil
        retryMailProvider = nil
        defer {
            if mailAttempt == attempt {
                mailAttempt = nil
                mailTask = nil
                isConnecting = false
                awaiting = nil
            }
        }
        let task = Task {
            try await mail.connect(provider: provider, client: client, deviceKey: deviceKey, anchor: anchor,
                                   isCurrent: { [weak self] in
                guard let self else { return false }
                return self.currentKey() == deviceKey && self.mailAttempt == attempt && self.step == .mail
            })
        }
        mailTask = task
        do {
            _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard currentKey() == deviceKey, mailAttempt == attempt, step == .mail else { return }
            await refreshMail()
            guard mailAttempt == attempt, step == .mail else { return }
            defaults.removeObject(forKey: Self.dictationOnlyKey)
            returned?()
        } catch _ where mailAttempt != attempt || currentKey() != deviceKey {
            // An abandoned attempt cannot affect the next account or window.
        } catch AlphaClient.MailFailure.cancelled {
            mailProblem = .cancelled
        } catch is CancellationError {
        } catch AlphaClient.MailFailure.denied {
            mailProblem = .denied
        } catch AlphaClient.MailFailure.couldNotOpen {
            mailProblem = .couldNotOpen
        } catch AlphaClient.MailFailure.timedOut {
            mailProblem = .timedOut
        } catch AlphaClient.Failure.rejected(401) {
            signedOut()
        } catch AlphaClient.Failure.rejected(404) {
            isMailOffered = false
        } catch AlphaClient.Failure.rejected(409) where provider == .gmail {
            gmailConnectOpen = false
            if connections.contains(where: { $0.provider == "gmail" }) {
                mailProblem = .gmailClosed
            }
        } catch is URLError {
            mailProblem = .unreachable
        } catch {
            mailProblem = .unavailable(provider)
        }
        if mailProblem != nil, mailAttempt == attempt { retryMailProvider = provider }
    }

    func retryMail() async {
        guard let provider = retryMailProvider, step == .mail else { return }
        let opening = closes, startingKey = currentKey()
        await refreshMail()
        guard closes == opening, startingKey == currentKey(), step == .mail, !Task.isCancelled else { return }
        await connect(provider)
    }

    func continueWithDictationOnly() {
        guard step == .mail else { return }
        leaveMail(dictationOnly: true)
    }

    private func cancelMail() {
        mailAttempt = nil
        mailTask?.cancel()
        mailTask = nil
        mail.cancel()
        isConnecting = false
        awaiting = nil
    }

    /// Rereads the connected mailboxes and their progress until cancelled.
    func watchMail() async {
        while !Task.isCancelled, step == .mail {
            switch readCurrentKey() {
            case .available:
                // A replacement account read just now moves setup back to
                // its start; its mailbox list is not read off the mail page.
                guard step == .mail, !Task.isCancelled else { return }
                await refreshMail()
            case .absent: return
            case .unreadable: break
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    func refreshMail() async {
        guard let client, let deviceKey = currentKey() else { return }
        let readID = UUID()
        mailReadID = readID
        do {
            let progress = try await client.mailConnections(deviceKey: deviceKey)
            // An answer for a key this Mac no longer holds: another account
            // may have signed in since, and this list is not theirs.
            // A newer read may have observed a rescan or advanced count while
            // this answer was delayed. Only the newest request may publish.
            guard deviceKey == currentKey(), mailReadID == readID else { return }
            // A server that gained the mail routes since the last answer.
            availableProviders = progress.availableProviders
            gmailConnectOpen = progress.gmailConnectOpen
            if !gmailConnectOpen, retryMailProvider == .gmail, !progress.connections.contains(where: { $0.provider == "gmail" }) {
                retryMailProvider = nil
                mailProblem = nil
            }
            hasReadMail = true
            // Logged when the reading recovers, not at every poll.
            if mailReadFailed { AppLog.mail("list.recovered") }
            mailReadFailed = false
            let found = progress.connections
            if found != connections { connections = found }
            if let failedMailDisconnect, !found.contains(where: { $0.id == failedMailDisconnect }) {
                self.failedMailDisconnect = nil
            }
            isMailOffered = false
            learning = progress.learning
            mailChanged?(found)
            if !found.isEmpty { record?.mark(.mailboxConnected) }
            if mailProblem == .unreachable { mailProblem = nil }
        } catch _ where deviceKey != currentKey() || mailReadID != readID {
            // A superseded read cannot sign out or mark a newer answer failed.
        } catch AlphaClient.Failure.rejected(401) {
            signedOut()
        } catch AlphaClient.Failure.rejected(404) {
            // A server without the mail routes; the page says so in place
            // of buttons that could only fail.
            isMailOffered = false
            hasReadMail = true
            mailReadFailed = false
        } catch let error as URLError where error.code == .cancelled {
            // Settings closed while reading; that says nothing about mail.
        } catch is CancellationError {
            // The same, from the task rather than the request.
        } catch is URLError {
            mailProblem = .unreachable
            readFailed()
        } catch {
            // A server that cannot list mailboxes cannot connect one
            // either, and Connect says so when the person tries. It did
            // answer, so an earlier read's unreachable no longer holds.
            if mailProblem == .unreachable { mailProblem = nil }
            readFailed()
        }
    }

    /// Disconnect only a listed connection under the account that requested
    /// it. A late response cannot remove a new account's row, and a failed
    /// request keeps the row visible with an explicit failure.
    func disconnectMail(_ connection: AlphaClient.MailConnection) async {
        guard !isConnecting, disconnectingMail == nil, !Task.isCancelled,
              let client, let key = currentKey(),
              settingsConnections.contains(where: { $0.id == connection.id && $0.provider == connection.provider }) else { return }
        let attempt = UUID()
        mailDisconnectAttempt = attempt
        disconnectingMail = connection.id
        failedMailDisconnect = nil
        defer {
            if mailDisconnectAttempt == attempt {
                mailDisconnectAttempt = nil
                disconnectingMail = nil
            }
        }
        do {
            try await client.disconnectMail(connectionID: connection.id, deviceKey: key)
            guard currentKey() == key, mailDisconnectAttempt == attempt else { return }
            // Invalidate a read begun before deletion, before publishing the
            // confirmed removal. A new read sees the committed server state.
            mailReadID = nil
            connections.removeAll { $0.id == connection.id }
            isMailOffered = false
            if learning?.connectionID == connection.id { learning = nil }
            mailChanged?(connections)
            await refreshMail()
        } catch {
            guard currentKey() == key, mailDisconnectAttempt == attempt else { return }
            if case AlphaClient.Failure.rejected(401) = error { signedOut() }
            else if connections.contains(where: { $0.id == connection.id }) {
                failedMailDisconnect = connection.id
            }
        }
    }

    /// The mailbox list could not be read. Logged when the reading starts
    /// failing, not at every poll.
    private func readFailed() {
        if !mailReadFailed { AppLog.mail("list.failed") }
        mailReadFailed = true
    }

    /// Keeps the mailbox list current while Settings or setup's last page
    /// shows it: read at once, then after each `followPause`, until it
    /// closes and the task is cancelled. No read starts after that: a read
    /// cancelled on its way returns, and so does the pause. The same
    /// reading setup's mail page polls.
    func followMail() async {
        while !Task.isCancelled {
            await refreshMail()
            guard !Task.isCancelled else { return }
            await followPause()
        }
    }

    /// What a mail row offers for one provider, for setup's mail page and
    /// Settings alike.
    enum MailOffer: Equatable {
        /// None of its mailboxes is connected.
        case connect
        /// One needs it: access was refused, revoked or expired, or the
        /// server stopped syncing it for good.
        case reconnect
        /// Its mailboxes are syncing, checking, up to date, or waiting for
        /// a retry the server runs by itself.
        case nothing
        /// One has stopped for a reason connecting again cannot fix, such
        /// as its address changing; nothing is offered, and it is not shown
        /// as connected either.
        case stuck
    }

    func mailOffer(for provider: AlphaClient.MailProvider) -> MailOffer { .nothing }

    /// What a mailbox's sync is doing, read from the server's state and
    /// error code together: a mailbox whose state still says syncing or
    /// ready may have a pass waiting to be retried, or may have stopped.
    enum MailStanding: Equatable {
        case syncing
        /// A pass failed and the server will run it again.
        case retrying
        /// The server gave up; nothing more arrives until the mailbox is
        /// connected again.
        case stopped
        case upToDate
        /// The server is validating retained mail after reconnect or a policy change.
        case checking
        /// Intention can no longer read the mailbox, as when the person's
        /// permission was withdrawn or expired, or an older connection
        /// needs fresh consent. Connecting again brings it back.
        case needsReconnect
        /// The mailbox's address changed at the provider. Connecting again
        /// cannot fix it: the server refuses a second address for the
        /// provider while the first connection is kept (mail.py).
        case addressChanged

        /// Only connecting again brings more mail.
        var needsConnectingAgain: Bool { self == .needsReconnect || self == .stopped }
        /// Nothing more arrives, whatever the person can do in Intention.
        var isBroken: Bool { needsConnectingAgain || self == .addressChanged }
    }

    nonisolated static func standing(of connection: AlphaClient.MailConnection) -> MailStanding {
        if connection.errorCode == "mail_identity_changed" { return .addressChanged }
        if connection.state == "reconnect_required" { return .needsReconnect }
        switch connection.errorCode {
        case "sync_paused": return .stopped
        case "sync_failed": return .retrying
        default:
            if connection.reconciling { return .checking }
            switch connection.state {
            case "ready": return .upToDate
            case "syncing": return .syncing
            default: return .stopped
            }
        }
    }

    /// Whether Intention is doing something on the mail page that the person
    /// is waiting for: consent in the browser, or mail coming in now. A
    /// pass that waits for its retry is not coming in.
    var isMailWorking: Bool {
        awaiting != nil || availableConnections.contains { [.syncing, .checking].contains(Self.standing(of: $0)) }
    }

    /// What a page can say about mail: nothing is connected, mail has
    /// started coming in, this many messages have been imported, or
    /// nothing is in and no mailbox can bring any until it is connected
    /// again.
    enum MailImport: Equatable {
        case notConnected
        case started
        case checking
        case imported(Int)
        case stalled
    }

    var mailImport: MailImport {
        let connections = availableConnections
        guard !connections.isEmpty else { return .notConnected }
        let count = connections.reduce(0) { $0 + $1.storedMessages }
        if count > 0 { return .imported(count) }
        let standings = connections.map(Self.standing(of:))
        if standings.contains(.syncing) { return .started }
        if standings.contains(.checking) { return .checking }
        return .stalled
    }

    /// Which of the recap's lines are true on this Mac: an email written
    /// from a dictation needs "Write emails for me", and a proposed reply
    /// also needs "Draft replies for me" and the dot.
    struct Offers: Equatable {
        var writesEmails = true
        var proposesReplies = true
    }

    var recapOffers: Offers {
        dictationOnlySetup ? Offers(writesEmails: false, proposesReplies: false) : offers?() ?? Offers()
    }

    /// How far Intention has come reading the person's mail for their voice,
    /// for the last page.
    enum Voice: Equatable {
        /// No list has been read since launch, so nothing is said yet.
        case unknown
        case noMail
        /// The server says a mailbox has enough sent mail for the voice.
        case ready
        /// A mailbox is still coming in, or waits for a retry.
        case learning
        /// The import is up to date and the server has not said the voice
        /// is ready, as with little sent mail or an older server: the page
        /// says only that the mail is in, and promises nothing.
        case imported
        /// Every mailbox has stopped and needs Settings.
        case stopped
    }

    var voice: Voice {
        guard hasReadMail else { return .unknown }
        let connections = availableConnections
        guard !connections.isEmpty else { return .noMail }
        if connections.contains(where: VoiceReady.isReady) { return .ready }
        if connections.contains(where: VoiceReady.isImporting) { return .learning }
        return connections.contains { Self.standing(of: $0) == .upToDate } ? .imported : .stopped
    }

    /// Mail can wait: dictation works without it, and Settings reopens
    /// this step.
    func continueFromMail() {
        guard step == .mail else { return }
        leaveMail(dictationOnly: !gmailConnectOpen && availableConnections.isEmpty)
    }

    private func leaveMail(dictationOnly: Bool) {
        defaults.set(dictationOnly, forKey: Self.dictationOnlyKey)
        cancelMail()
        // A setup that already finished was reopened only for mail, and the
        // reply page's own Connect mail comes back to the reply.
        openReply()
        let next: Step = reached == .done ? .done
            : reached >= .reply ? (dictationOnlySetup ? (asksOpenAtLogin ? .openAtLogin : .done) : .reply)
            : hasRequiredPermissions ? afterPermissions : .permissions
        advance(to: next)
    }

    // MARK: - First email

    enum ReplySubject: Equatable {
        case looking
        case own(AlphaClient.ReplyThread)
        case example(ExampleReason)
    }

    enum ReplyThreadOutcome: String { case ownThread = "own_thread", example }
    @ObservationIgnored var replyThreadIsVisible: () -> Bool = { false }
    @ObservationIgnored var recordReplyThreadShown: ((UUID, ReplyThreadOutcome, Date) -> Void)?
    @ObservationIgnored private var setupInteractionID = UUID()
    @ObservationIgnored private var shownReplyOutcomes: Set<String> = []

    /// Called by the displayed card, never by the thread prefetch or page selection.
    func replyThreadShown(_ outcome: ReplyThreadOutcome, at: Date = Date()) {
        guard backendKey != nil, step == .reply, replyThreadIsVisible(),
              shownReplyOutcomes.insert(outcome.rawValue).inserted else { return }
        recordReplyThreadShown?(setupInteractionID, outcome, at)
    }

    enum ExampleReason: Equatable { case preparing, noCandidate, unavailable }
    private(set) var replySubject: ReplySubject = .looking
    @ObservationIgnored private var subjectGeneration = UUID()
    @ObservationIgnored private var subjectRequest: UUID?
    @ObservationIgnored private var subjectLocked = false
    /// The last ask failed with anything but an older server's 404 or a
    /// refused key (a timeout, a lost connection, a server error, an answer
    /// this build can't read), so the page asks again while untouched.
    @ObservationIgnored private var subjectRetries = false
    @ObservationIgnored private let replySubjectInterval: Duration
    @ObservationIgnored private let replySubjectTimeout: Duration

    /// Once a reply attempt starts, even silence or failure must leave the
    /// message in place. The first dictation page does not lock its prefetch.
    private var canChangeReplySubject: Bool {
        if step == .reply, !awaitingFirstDictation,
           (reply != .waiting && reply != .unavailable) || replySpoken != nil || replyWords != nil || lastTry(since: replyOpened) != nil {
            lockReplySubject()
        }
        return !subjectLocked
    }

    private func lockReplySubject() {
        subjectLocked = true
        // A recording can begin before the lookup returns. Choose the
        // fallback now so the pending answer cannot change what it answers
        // or leave the page looking forever after its deadline.
        if case .looking = replySubject {
            replySubject = .example(.unavailable)
            logExampleSubject()
        }
    }

    private func resetReplySubject() {
        subjectRetries = false
        subjectGeneration = UUID()
        subjectRequest = nil
        subjectLocked = false
        replySubject = .looking
    }

    /// A separate watcher lets recording and writing progress while the
    /// subject request waits. Only the visible practice pages own it.
    private func watchReplySubject() async {
        // The preceding page may still be cancelling its prefetch. Wait
        // for that request to leave before the first ask on this page,
        // rather than delaying an untouched looking state for ten seconds.
        while !Task.isCancelled, subjectRequest != nil, step == .tryIt || step == .reply {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await refreshReplySubject()
        while !Task.isCancelled, step == .tryIt || step == .reply {
            try? await Task.sleep(for: replySubjectInterval)
            guard !Task.isCancelled else { return }
            switch replySubject {
            case .looking, .example(.preparing), .example(.noCandidate): await refreshReplySubject()
            // A brief failure is asked again; an older server's 404 is not.
            case .example(.unavailable) where subjectRetries: await refreshReplySubject()
            case .own, .example(.unavailable): break
            }
        }
    }

    func refreshReplySubject() async {
        guard !Task.isCancelled, step == .tryIt || step == .reply else { return }
        guard isPracticeAvailable else {
            if canChangeReplySubject { replySubject = .example(.unavailable) }
            return
        }
        guard canChangeReplySubject, subjectRequest == nil else { return }
        if case .own = replySubject { return }
        guard let client, let key = currentKey() else {
            if (step == .tryIt || step == .reply), canChangeReplySubject {
                replySubject = .example(.unavailable)
                logExampleSubject()
            }
            return
        }
        guard isPracticeAvailable, step == .tryIt || step == .reply else { return }
        let generation = subjectGeneration, request = UUID()
        subjectRequest = request
        defer { if subjectRequest == request { subjectRequest = nil } }
        do {
            let answer = try await client.setupReplyThread(deviceKey: key, timeout: replySubjectTimeout)
            guard key == currentKey(), generation == subjectGeneration, !Task.isCancelled, isPracticeAvailable,
                  step == .tryIt || step == .reply, canChangeReplySubject else { return }
            subjectRetries = false
            if let thread = answer.thread {
                replySubject = .own(thread)
                AppLog.compose("setup.subject.own")
            } else {
                switch answer.reason {
                case .preparing: replySubject = .example(.preparing)
                case .noCandidate: replySubject = .example(.noCandidate)
                case .noMail, nil: replySubject = .example(.unavailable)
                }
                logExampleSubject()
            }
        } catch {
            guard key == currentKey(), generation == subjectGeneration, !Task.isCancelled else { return }
            if case AlphaClient.Failure.rejected(401) = error {
                signedOut()
            } else if (step == .tryIt || step == .reply), canChangeReplySubject {
                if case AlphaClient.Failure.rejected(404) = error { subjectRetries = false } else { subjectRetries = true }
                // A failure between answers keeps the reason already shown,
                // so the page's words don't flicker while the server recovers.
                if replySubject == .looking || !subjectRetries, replySubject != .example(.unavailable) {
                    replySubject = .example(.unavailable)
                    logExampleSubject()
                }
            }
        }
    }

    private func logExampleSubject() {
        switch replySubject {
        case .example(.preparing): AppLog.compose("setup.subject.example.preparing")
        case .example(.noCandidate): AppLog.compose("setup.subject.example.no_candidate")
        case .example(.unavailable): AppLog.compose("setup.subject.example.unavailable")
        default: break
        }
    }

    /// What the reply page shows.
    enum ReplyMoment: Equatable {
        /// The writer cannot be asked: no mailbox, no writer in this build,
        /// writing off or this Mac signed out. The page shows the example.
        case unavailable
        case waiting, listening, finishing
        /// The words are with the writer.
        case writing
        /// The email is in the field.
        case written
        /// No email came, so the words went in as they were, with the notice.
        case typed
    }

    /// A signed-in demo may try the real writer using the visible synthetic
    /// thread. The server decides availability; a refusal shows the dictated
    /// words and the existing failure notice.
    var isPracticeAvailable: Bool {
        guard let practice, let dictation, practice.isAvailable(), dictation.isAvailable() else { return false }
        return true
    }

    var reply: ReplyMoment {
        guard isPracticeAvailable else { return .unavailable }
        if awaitingFirstDictation { return .waiting }
        if replySpoken != nil { return .writing }
        switch dictation?.phase() {
        case .listening?: return .listening
        case .finishing?: return .finishing
        default: break
        }
        guard replyWords != nil else { return .waiting }
        return replyNotice == nil ? .written : .typed
    }

    var replyNeedsMicrophone: Bool {
        guard !awaitingFirstDictation, let dictation, reply == .waiting else { return false }
        return dictation.microphoneFailed()
    }

    var replyMissed: Bool {
        !awaitingFirstDictation && reply == .waiting && lastTry(since: replyOpened)?.end == .missed
    }

    var replySilent: Bool {
        !awaitingFirstDictation && reply == .waiting && lastTry(since: replyOpened)?.end == .silent
    }

    private func openReply() {
        resetReplySubject()
        awaitingFirstDictation = false
        replyOpened = Date()
        replyHandled = nil
        replyWrite = nil
        replySpoken = nil
        replySaid = nil
        replyWords = nil
        replyNotice = nil
        replyFailureName = nil
    }

    /// Follows the reply page while it shows: each new dictation made on it
    /// goes to the writer once, and what comes back goes to the field. Run
    /// by the page and cancelled when it leaves, so a write still on its
    /// way then puts nothing on a page that has gone.
    func watchReply() async {
        // A relaunch onto this page has read no mailbox list yet, and the
        // list decides whether the writer can be asked.
        if !hasReadMail, step == .reply { await refreshMail() }
        let subject = Task { await watchReplySubject() }
        defer { subject.cancel() }
        while !Task.isCancelled, step == .reply {
            await replyTick()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// One look at the reply page: a dictation made on it since the last
    /// look goes to the writer, and the call returns once the answer is in
    /// the field. The renders call it directly.
    func replyTick() async {
        if awaitingFirstDictation {
            if (dictation?.phase() ?? .idle) == .idle {
                replyOpened = Date()
                awaitingFirstDictation = false
            }
            return
        }
        _ = canChangeReplySubject
        // Only while the writer can be asked: without a mailbox the page
        // shows the example, and words spoken on it stay in history.
        guard step == .reply, !isQuitting, isPracticeAvailable, let latest = words(since: replyOpened), latest.at != replyHandled,
              replySpoken == nil else { return }
        replyHandled = latest.at
        await write(latest.text, original: latest.at)
    }

    /// Retry exactly the words and subject of the failed attempt.
    func retryReply() async {
        guard step == .reply, !isQuitting, reply == .typed,
              let words = replyWords, let original = replyOrigins[words.at] else { return }
        await write(words.text, original: original)
    }

    /// Keep Maya's example for the rest of this visit, with a fresh field
    /// and no earlier dictation eligible to start another write.
    func useExampleReply() {
        guard step == .reply, !isQuitting, reply == .typed || reply == .waiting,
              case .own = replySubject else { return }
        let carriedDictation = awaitingFirstDictation
        openReply()
        awaitingFirstDictation = carriedDictation
        replySubject = .example(.unavailable)
        lockReplySubject()
        logExampleSubject()
    }

    private func write(_ spoken: String, original: Date) async {
        guard let practice else { return }
        let opened = replyOpened, opening = closes, attempt = UUID()
        let previousNotice = replyNotice, previousFailure = replyFailureName
        replyWrite = attempt
        replySpoken = spoken
        replyNotice = nil
        replyFailureName = nil
        replyStarted?()
        let thread: AlphaClient.ReplyThread?
        if case let .own(own) = replySubject { thread = own } else { thread = nil }
        let result = await practice.write(spoken, thread, original)
        // An older completion must not cool the foot mark while the new
        // attempt is still writing. The final active answer reports quiet.
        defer { if replySpoken == nil { replyEnded?() } }
        // The page left, or was reopened, while the writer worked: its
        // answer belongs to nobody now.
        guard replyWrite == attempt else { return }
        replyWrite = nil
        guard !Task.isCancelled, step == .reply, replyOpened == opened, closes == opening else {
            replySpoken = nil
            replyNotice = previousNotice
            replyFailureName = previousFailure
            return
        }
        replySpoken = nil
        let answeredAt = Date()
        replyOrigins[answeredAt] = original
        switch result {
        case let .success(email):
            AppLog.compose("setup.written")
            replyWords = (email, answeredAt)
            replySaid = spoken
            record?.mark(.firstSetupEmail)
        case let .failure(failure):
            AppLog.compose("setup.failed.\(failure.name)")
            replyWords = (spoken, answeredAt)
            replySaid = nil
            replyNotice = PracticeReply.typedNotice
            replyFailureName = failure.name
        }
    }

    /// Why the reply page shows the example in place of a real email, said
    /// exactly: what would let the writer be asked.
    var replyUnavailableReason: String {
        switch practice?.unavailable() {
        case .writingOff?: return "Write emails for me is off in Intention's Settings."
        case .signedOut?: return "This Mac is signed out of Intention."
        case .noWriter?: return "This build of Intention has no email writer."
        case nil: break
        }
        if connections.isEmpty { return "No mailbox is connected. This is an example; live dictation is available." }
        if availableConnections.isEmpty { return "Intention can't write from your mailbox's provider right now." }
        if dictation?.isAvailable() == false { return "Dictation isn't available right now." }
        return "Writing isn't available right now. Try it in Gmail or Mail later."
    }

    /// Whether words were said on the reply page while it shows the
    /// example, so the page says the writer was not asked, and why.
    var replyHeardWithoutWriter: Bool {
        reply == .unavailable && words(since: replyOpened) != nil
    }

    /// Whether the example's way forward is connecting mail.
    var replyNeedsMail: Bool { false }

    /// Back from the reply page to connect a mailbox, so the practice email
    /// can be written for real.
    func connectMailForReply() {
        guard step == .reply else { return }
        advance(to: .mail)
    }

    /// Follows the dictation page while it shows, to note the first words.
    func watchDictation() async {
        if !hasReadMail, step == .tryIt { await refreshMail() }
        let subject = Task { await watchReplySubject() }
        defer { subject.cancel() }
        while !Task.isCancelled, step == .tryIt {
            checkFirstKey()
            if firstDictationWords != nil { record?.mark(.firstSetupDictation) }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Ends the reply page: on to the login question, or done.
    func finish() {
        guard step == .reply else { return }
        advance(to: asksOpenAtLogin ? .openAtLogin : .done)
    }

    // MARK: - Open at login

    /// Asked at the end, once the person has seen what Intention does, and
    /// only while it does not already open at login.
    var asksOpenAtLogin: Bool {
        loginItem.map { !$0.isOn() } ?? false
    }

    /// Whether macOS will ask for Screen Recording as setup ends, so the
    /// last page shows the switch to turn on before the alert comes.
    var asksScreenRecordingNext: Bool {
        screenRecordingDue?() ?? false
    }

    /// The answer to the last page. Either one finishes setup; nothing is
    /// registered with macOS unless it is yes.
    func answerOpenAtLogin(_ opens: Bool) {
        guard step == .openAtLogin else { return }
        AppLog.event(opens ? "Setup login answer: yes" : "Setup login answer: no")
        loginItem?.answer(opens)
        advance(to: .done)
    }

    /// Shows the mail step again after setup finished, to connect another
    /// mailbox or one skipped the first time.
    func reopenMail() {
        // The key is read first: a replacement account restarts setup, and
        // must not be sent on to mail.
        guard currentKey() != nil, isFinished else { return }
        step = .mail
    }

    /// Closing the window cancels pending permission requests and the native
    /// consent session, then returns a finished setup reopened for mail to done.
    func windowClosed() {
        closes += 1
        asking.forEach { $0.cancel() }
        cancelMail()
        mailAnchor = nil
        // Closing the last page leaves Intention out of Login Items, as Not
        // Now does; Settings can still turn it on.
        if step == .openAtLogin { advance(to: .done) }
        if reached == .done, step != .signIn { step = .done }
    }

    /// An unreadable store provides no current credential, but does not prove
    /// that the account changed. The watcher retries this result without sending.
    private enum KeyReading {
        case available(String), absent, unreadable
    }

    private func currentKey() -> String? {
        guard case let .available(key) = readCurrentKey() else { return nil }
        return key
    }

    /// Clear the previous account's state only after a confirmed key change.
    private func readCurrentKey() -> KeyReading {
        guard !defaults.bool(forKey: Self.signedOutKey) else { return .absent }
        let found: String?
        do {
            found = try keys.read()
        } catch {
            cancelMail()
            isKeyUnreadable = true
            return .unreadable
        }
        isKeyUnreadable = false
        let previous = deviceKey
        if let previous, found != previous {
            setupInteractionID = UUID()
            shownReplyOutcomes.removeAll()
            cancelMail()
            // A permission request made for the earlier account opens
            // nothing for the next one.
            asking.forEach { $0.cancel() }
            connections = []
            disconnectingMail = nil
            mailDisconnectAttempt = nil
            failedMailDisconnect = nil
            learning = nil
            availableProviders = []
            gmailConnectOpen = true
            retryMailProvider = nil
            defaults.removeObject(forKey: Self.dictationOnlyKey)
            // The list read was the earlier account's.
            hasReadMail = false
            mailReadFailed = false
            mailProblem = nil
            defaults.removeObject(forKey: Self.stepKey)
            // A new account starts setup over, after the code: it does not
            // inherit this one's progress.
            resetFirstKeyCheck()
            openReply()
            step = found == nil ? .signIn : afterSignIn
        }
        if previous == nil, found != nil, step != .done {
            // The first read that succeeds, after one that failed at launch
            // or after the keychain gave the key back: setup resumes as a
            // launch with the key would, not on the sign-in page.
            step = step == .signIn ? afterSignIn : resumedStep
        }
        deviceKey = found
        // A confirmed replacement also resets speech grants, active dictation
        // and retry audio. A failed read above makes no account-change claim.
        if found != previous { accountChanged?(found != nil) }
        return found.map(KeyReading.available) ?? .absent
    }

    /// The furthest step the person has got to, across launches.
    private var reached: Step {
        defaults.string(forKey: Self.stepKey).flatMap(Step.init(rawValue:)) ?? .signIn
    }

    private func advance(to next: Step) {
        let finishing = next == .done && reached < .done
        step = next
        if next > reached { defaults.set(next.rawValue, forKey: Self.stepKey) }
        if finishing {
            record?.mark(.setupFinished)
            finished?()
        }
    }
}
