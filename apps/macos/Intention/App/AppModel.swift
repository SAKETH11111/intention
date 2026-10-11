import AppKit

/// Wires setup, the caret dot, dictation, text insertion, login item and
/// updates to the person's settings and permissions.
@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    let permission: AccessibilityPermission
    let loginItem: LoginItem
    @ObservationIgnored let caretDot = CaretDotController()
    /// The foot mark, at the foot of the screen whichever indicator is
    /// chosen, and the clock that makes it the sun or the moon.
    @ObservationIgnored let foot = FootMark()
    private(set) var footHiddenUntil: Date?
    @ObservationIgnored private let skyClock = SkyClock()
    /// The reply proposal's card at the caret, and the rules that show it.
    @ObservationIgnored let proposalCard = ProposalCard()
    @ObservationIgnored let proposals: ReplyProposalController
    @ObservationIgnored private let dotNotice = DotNotice()
    @ObservationIgnored private let insertionPopup = InsertionPopup()
    /// The Report a problem window, opened from the menu bar item.
    @ObservationIgnored let problemReportPanel = ReportProblemPanel()
    @ObservationIgnored private(set) var diagnosticAccount: DiagnosticAccount?
    @ObservationIgnored let updater = AppUpdater()
    @ObservationIgnored let clipboard: PasteboardOwner
    @ObservationIgnored let inserter: TextInserter
    let dictation: DictationController
    /// Writes an email from the words dictated into an email body, when
    /// "Write emails for me" is on.
    let writer: EmailWriter
    @ObservationIgnored private let eventSender: ClientEventSender?
    @ObservationIgnored let holdKey: HoldKey
    @ObservationIgnored private let pasteShortcut = PasteShortcut()
    /// The inputs, followed while Settings shows the Microphone choice.
    let microphones = AudioInputWatch(read: AppModel.inputsShown)
    /// Shared by the Settings picker and the foot menu. Creating it reads
    /// device properties only; the caller explicitly starts and stops levels.
    @ObservationIgnored lazy var microphoneMenu: MicrophoneMenu = {
        #if OFFSCREEN_RENDER
        // A Settings render draws made-up inputs at made-up levels.
        let render = SettingsSnapshot.isRequested
        #else
        let render = false
        #endif
        let engine: any MicrophoneMeterEngine
        #if OFFSCREEN_RENDER
        engine = render ? SettingsSnapshot.Meter() : NativeMicrophoneMeter()
        #else
        engine = NativeMicrophoneMeter()
        #endif
        let menu = MicrophoneMenu(inputs: microphones.inputs, engine: engine,
                                  authorized: { render || Microphone.permission == .authorized },
                                  preference: { [preferences] in preferences.microphone },
                                  choose: { [weak self] in self?.setMicrophone($0) })
        menu.setRecording(dictation.phase == .recording)
        microphones.changed = { [weak menu] in menu?.updateInputs($0) }
        return menu
    }()
    /// Records a new dictation key from Settings.
    let keyRecorder: KeyRecorder
    let onboarding: OnboardingModel
    let learningProgress = LearningProgress()
    @ObservationIgnored private lazy var onboardingWindow = OnboardingWindow(model: onboarding) { [weak self] in self?.setupLanding() }
    /// The one notification, when the person's voice is ready; nil while a
    /// fixture or a harness runs the app.
    @ObservationIgnored private var voiceReady: VoiceReady?
    /// Rings Intention's switch in the Screen Recording list for one visit as
    /// setup ends, whether Intention or macOS's alert opens the page then.
    /// The request at launch has no guide.
    @ObservationIgnored private let screenRecordingGuide = SettingsGuide(list: .screenRecording, appearance: { Appearance.current })
    /// The one request for Screen Recording Intention makes by itself.
    @ObservationIgnored private lazy var screenRecording = ScreenRecordingRequest(
        preferences: preferences, requestFromPress: { [weak self] ask in self?.requestScreenRecording(ask) })
    /// Whether launch opens setup: it is unfinished and a person, not a
    /// development harness, is running the app.
    @ObservationIgnored let opensSetupAtLaunch: Bool
    /// The hint beside an email body, until the first email is written.
    @ObservationIgnored private lazy var emailHints = EmailHints(
        shown: { [preferences] in preferences.emailHintsShown },
        countShown: { [preferences] in preferences.emailHintsShown += 1 },
        firstEmailWritten: { [preferences] in preferences.firstEmailWritten },
        canWriteEmails: { [preferences, dictation] in preferences.writesEmails && dictation.available },
        keyName: { [preferences] in FirstDictation.keycap(preferences.dictationKey) })
    @ObservationIgnored private lazy var emailBodyWatch = EmailBodyWatch(changed: EmailHints.reporter(to: emailHints))
    /// Gmail threads opening in a Chromium browser, for a reply proposal
    /// asked for before the person clicks Reply.
    @ObservationIgnored private lazy var threadWatch = GmailThreadWatch(opened: ReplyProposalController.threadReporter(to: proposals))
    #if DEBUG
    /// The last development insertion outcome, shown in the menu.
    var lastEditOutcome: String?
    #endif
    /// Intention's window: Home, with Settings as a sheet over it.
    @ObservationIgnored private(set) lazy var mainWindow = MainWindow(model: self)

    /// What `open` brings forward: Home, or Settings over it.
    enum Window { case settings, history }

    init() {
        DiagnosticEvents.shared.beginAccountCheck()
        #if DEBUG
        // A Debug build given --proposal-log keeps the reply proposal's
        // fixed names from the app log as well, since the unified log
        // cannot be read from a shell on the Mac the timing run uses.
        AppLog.mirrorProposals(to: { ProposalLog.shared.note($0) })
        #endif
        #if OFFSCREEN_RENDER
        SettingsSnapshot.configurePreferencesIfRequested()
        #endif
        preferences = Preferences()
        Appearance.current = preferences.appearance
        permission = AccessibilityPermission()
        clipboard = PasteboardOwner()
        inserter = TextInserter(pasteboard: clipboard)
        loginItem = LoginItem()
        // Setup is built after dictation, since it saves languages through
        // it, so speech grants reach setup's device key through this link.
        let setupKey = SetupKey()
        let endpoint = Self.dictationEndpoint(setupKey)
        let writer = EmailWriter(drafts: Self.drafts(setupKey), signedIn: false,
                                 addSentWithIntention: { false })
        writer.isEnabled = preferences.writesEmails
        self.writer = writer
        #if DEBUG
        // Setup's fixture and the renders that use it hold history in memory
        // and keep no upload queue: its made-up key must never carry this
        // Mac's dictations anywhere.
        let isolated = OnboardingFixture.isRequested
        #else
        let isolated = false
        #endif
        let history = isolated ? DictationHistory(file: nil) : DictationHistory()
        let archive: InteractionArchive? = nil
        let eventSender = archive.map { ClientEventSender(archive: $0) }
        self.eventSender = eventSender
        DiagnosticEvents.shared.setSink { @Sendable name, outcome, date, interactionID in
            eventSender?.record(name, outcome: outcome, at: date, interactionID: interactionID)
        }
        writer.retentionScope = { archive?.scope }
        writer.recordReceipt = { id, count, at, scope in
            archive?.event(id, kind: "draft_received", payload: [
                "voice_examples": .number(Double(count)), "at": .number(at.timeIntervalSince1970)
            ], scope: scope)
        }
        writer.recordInsertion = { id, text, scope in
            archive?.event(id, kind: "draft_inserted", payload: ["text": .string(text),
                "outcome": .string("inserted"), "target_kind": .string("setup"),
                "at": .number(Date().timeIntervalSince1970)], scope: scope)
        }

        let dictation = DictationController(inserter: inserter, history: history, endpoint: endpoint,
                                            source: Self.recordingInPlaceOfMicrophone(), microphone: { [preferences] in preferences.microphone },
                                            signedIn: false, vocabulary: Self.personalVocabulary(setupKey), writer: writer)
        self.dictation = dictation
        dictation.archive = archive
        let holdKey = HoldKey(key: preferences.dictationKey)
        self.holdKey = holdKey
        // A proposal is made only with the setting on, email writing on, the
        // dot chosen, Accessibility granted and the writer able to write
        // now, and never while dictation runs. The writer learns of the
        // account from `dictation.accountChanged`, at launch and from setup.
        let preferences = preferences, permission = permission
        // The first card after setup says its keys in words once.
        proposalCard.keyWordsDue = { !preferences.cardKeyWordsShown }
        proposalCard.keyWordsShown = { preferences.cardKeyWordsShown = true }
        proposals = ReplyProposalController(
            inserter: inserter, writer: writer, card: proposalCard, history: history,
            takeTab: { holdKey.takeTab(generation: $0) },
            // The key as every caret surface and setup print it: "fn",
            // "right option", or a combination's own name.
            dictationKeyName: { FirstDictation.keycap(preferences.dictationKey) },
            gate: {
                ReplyProposalController.gate(draftsReplies: preferences.draftsReplies, writesEmails: preferences.writesEmails,
                                             dotChosen: preferences.indicator == .dot, accessibility: permission.isGranted,
                                             writer: writer)
            },
            account: { dictation.account },
            dictationIdle: { dictation.phase == .idle })
        proposals.archive = archive
        // One recorder, Settings' and setup's shortcut page's alike.
        let recorder = KeyRecorder(holdKey: holdKey, save: { [preferences, holdKey] in Self.apply(key: $0, preferences, holdKey) })
        keyRecorder = recorder
        // Setup is built before this model can be referred to, so it saves
        // through the same functions `setDictationLanguages` and
        // `setDictationKey` do.
        let languages = DictationLanguages(
            current: { [preferences] in preferences.dictationLanguages },
            save: { [preferences, dictation] in Self.apply(languages: $0, preferences, dictation) }
        )
        var first = FirstDictation.of(dictation, key: { [preferences] in preferences.dictationKey },
                                      chooseKey: { [preferences, holdKey] in Self.apply(key: $0, preferences, holdKey) },
                                      recorder: recorder, hasFnKey: { KeyboardInventory.hasFnKey(KeyboardInventory.connected()) })
        first.listener = holdKey.listener
        first.retryListener = { [weak holdKey] in holdKey?.retryListener() }
        first.skippedKeyCheck = { [weak holdKey] in
            holdKey?.reportSkippedListenerCheck()
        }
        let opensAtLogin = SetupLoginItem(
            isOn: { [loginItem, preferences] in
                loginItem.refresh()
                return loginItem.state != .off || preferences.loginItemPending
            },
            answer: { [loginItem, preferences] in if $0 { Self.apply(opensAtLogin: true, loginItem, preferences) } }
        )
        // Setup asks whether Screen Recording comes next through this link,
        // since the request is this model's and this model is not built yet.
        let screenRecordingLink = ScreenRecordingLink()
        onboarding = Self.onboarding(permission: permission, clipboard: clipboard, languages: languages, dictation: first,
                                     practice: PracticeReply.of(writer), loginItem: opensAtLogin,
                                     screenRecordingDue: { screenRecordingLink.isDue() })
        setupKey.onboarding = onboarding
        // Intention opens at login only once the person has said so, at the
        // end of setup or in Settings. A yes given from a copy outside
        // Applications waits for a launch from there.
        if preferences.loginItemPending, LoginItem.isStable() {
            Self.apply(opensAtLogin: true, loginItem, preferences)
        }
        #if DEBUG
        caretDot.visualFallbackEnabled = CaretFixtureMode.scope?.visual ?? preferences.visualCaretEnabled
        let requestsPermissions = CaretFixtureMode.scope == nil && NSClassFromString("XCTestCase") == nil
        // A fixture, a hosted test or an insertion check drives the app
        // itself, so setup stays out of its way.
        let hasPerson = requestsPermissions && !CommandLine.arguments.contains("--insertion-checks")
        #else
        caretDot.visualFallbackEnabled = preferences.visualCaretEnabled
        let requestsPermissions = true
        let hasPerson = true
        #endif
        opensSetupAtLaunch = hasPerson && !onboarding.isFinished
        screenRecordingLink.isDue = { [weak self] in self?.screenRecording.due ?? false }
        wireDictation()
        // Setup explains each permission before macOS asks for it. Once it
        // is finished, a missing one is asked for at launch.
        if requestsPermissions, !opensSetupAtLaunch {
            // The dot needs Accessibility to find the caret; ask at launch
            // rather than wait for the person to open the menu.
            if !permission.isGranted { permission.prompt() }
            screenRecording.atLaunch()
        }
        if requestsPermissions {
            onboarding.finished = { [weak self] in
                guard let self else { return }
                voiceReady?.setupFinished(connections: onboarding.availableConnections)
                screenRecording.afterSetup()
            }
            #if DEBUG
            let notifies = !OnboardingFixture.isRequested
            #else
            let notifies = true
            #endif
            if notifies {
                let voice = VoiceReady(notifier: SystemNotifications.voiceReady(), read: { [onboarding] in await onboarding.refreshMail() },
                                       mayAsk: { [onboarding] in onboarding.isFinished })
                onboarding.mailChanged = { [weak self, weak voice, weak onboarding] connections in
                    self?.learningProgress.observe(connections, learning: onboarding?.learning)
                    voice?.observe(connections)
                }
                onboarding.offers = { [preferences] in
                    OnboardingModel.Offers(writesEmails: preferences.writesEmails,
                                           proposesReplies: preferences.writesEmails && preferences.draftsReplies
                                               && preferences.indicator == .dot)
                }
                voiceReady = voice
                if onboarding.backendKey != nil { voice.check() }
            }
        }
        #if OFFSCREEN_RENDER
        // A hosted test and a Settings render show nothing of their own.
        let shows = false
        #elseif DEBUG
        let shows = NSClassFromString("XCTestCase") == nil
        #else
        let shows = true
        #endif
        if shows {
            // The indicator first, so for a person who hid the caret dot it
            // starts with its reading stopped.
            apply(indicator: preferences.indicator)
            foot.sky = skyClock.sky
            skyClock.changed = { [weak self] sky in self?.foot.sky = sky }
            skyClock.start()
            foot.enabled = true
            pasteShortcut.start()
            caretDot.start()
            emailBodyWatch.start(while: { [emailHints] in emailHints.wanted }, until: { [emailHints] in emailHints.retired })
            proposals.retryThreadOpen = { [weak self] in self?.threadWatch.retryOpen() }
            threadWatch.start(while: { [proposals] in proposals.watchesThreads })
        }
    }

    /// Clicking the dot or the foot mark and holding the dictation key all
    /// drive dictation; the indicators show its phase, and an update waits
    /// until it is idle.
    private func wireDictation() {
        footHiddenUntil = preferences.footHiddenUntil
        foot.hiddenChanged = { [weak self] until in
            guard let self else { return }
            self.footHiddenUntil = until
            self.preferences.footHiddenUntil = until
        }
        if let until = footHiddenUntil { foot.hide(until: until) }
        pasteShortcut.onPaste = { [weak self] in self?.dictation.pasteLast() }
        caretDot.onClick = { [weak self] in self?.dictation.toggle() }
        foot.onAction = { [weak self] in self?.dictation.respond(to: $0) }
        foot.keyName = { [preferences] in FirstDictation.keycap(preferences.dictationKey) }
        // The foot's own menu, made as it opens, so it lists the microphones
        // and whether there is a dictation to paste as they are then.
        foot.menu = { [weak self] in self?.footMenu() }
        // Where the foot rests on each display, as dragged there or chosen in
        // Settings.
        foot.slotFor = { [preferences] in preferences.dotPosition(onDisplay: $0.key) }
        foot.chose = { [preferences] slot, screen, connected in
            preferences.chooseDotPosition(slot, onDisplay: screen.key, keeping: connected.map(\.key))
        }
        // The foot keeps clear of the focused field, and while it cannot
        // paint the caret dot carries the red.
        caretDot.focusedFieldChanged = { [weak self] field in
            self?.foot.focusedField = field
            self?.updateWordRouting()
        }
        foot.wordSpaceChanged = { [weak self] in self?.updateWordRouting() }
        foot.carriesRedChanged = { [weak self] carries in self?.caretDot.footCarriesRed = carries }
        foot.paintingChanged = { [weak self] paints in
            guard let self else { return }
            self.caretDot.footPaints = paints
            self.updateWordRouting()
        }
        caretDot.emailBodyChanged = { [weak self] _ in self?.updateWordRouting() }
        caretDot.caretAnchorChanged = { [weak self] in self?.updateWordRouting() }
        caretDot.footCarriesRed = foot.carriesRed
        caretDot.footPaints = foot.painting
        // The voice, for the foot's sun and the caret dot's halo while listening.
        dictation.levelChanged = { [weak self] level in
            self?.foot.level = level
            self?.caretDot.level = level
        }
        // On setup's shortcut page a hold is only shown, there.
        DictationIndicators.connectTrigger(holdKey, dictation: dictation, startsDictation: { [weak self] in
            guard let self else { return true }
            return !(self.onboarding.holdOnlyShows && self.onboardingWindow.isKey)
        }) { [weak foot] in
            foot?.setKeyPending($0)
        }
        // The reply proposals follow the caret through the dot's
        // observations, take Tab through the dictation key's tap while the
        // card shows, hear Escape and key presses through its tap or
        // monitors, hand a spoken change's parent to dictation, and set the
        // dot's look while a proposal is on its way or shown.
        proposals.connect(to: holdKey, dictation: dictation)
        caretDot.observationChanged = DictationIndicators.caretObserver { [weak self] observation in
            self?.proposals.observe(observation)
        }
        caretDot.geometryChanged = { [weak self] in self?.proposals.confirmationGeometryChanged() }
        proposals.presentationChanged = { [weak self] presentation in self?.caretDot.proposalPresentation = presentation }
        proposalCard.frameChanged = { [weak self] frame in self?.caretDot.proposalCardFrame = frame }
        // An accept refusal is shown on the event that decides it.
        proposals.notInserted = { [weak self] reason, text in self?.dictation.proposalNotInserted(reason, text) }
        proposals.insertionUncertain = { [weak self] in self?.dictation.proposalInsertionUncertain() }
        proposals.unavailable = { [weak self] in self?.dotNotice.show(.notice("No reply draft available"), beside: self?.caretDot.caretAnchor) }
        proposals.mailImportPending = { [weak self] in
            self?.dotNotice.show(.notice(DictationController.Notice.mailImportPending.text), beside: self?.caretDot.caretAnchor)
        }
        // Only beside a known caret: the hint must belong to a field.
        proposals.nothingToAnswer = { [weak self] in
            guard let self, let mark = self.caretDot.caretAnchor else { return }
            self.dotNotice.show(.notice("Nothing to reply to"), beside: mark, for: DotNotice.hintShown, fades: true)
        }
        proposals.ended = { outcome, trace in
            if trace.replyFocused == nil { Telemetry.record(ProposalTiming(outcome, trace: trace)) }
        }
        proposals.replyEnded = { outcome, trace in
            Telemetry.record(ProposalTiming(outcome, trace: trace))
            #if DEBUG
            ProposalLog.shared.record(outcome, trace: trace)
            #endif
        }
        dictation.languages = preferences.dictationLanguages
        // A dictation is setup's own when setup's window has the keyboard
        // and is on its dictation page. Its words go to that page. One made
        // with Settings or history in front, or with setup closed, is not.
        dictation.isForSetup = { [weak self] in
            guard let self else { return false }
            return FirstDictation.isSetupsOwn(onPracticePage: self.onboarding.isPracticePage,
                                              windowHasKeyboard: self.onboardingWindow.isKey)
        }
        // Dictation, and the email writer with it, can begin once this Mac
        // holds a key: at launch, or as soon as setup signs in. Both stop
        // when the key is gone or refused.
        let archive = dictation.archive
        onboarding.replyThreadIsVisible = { [weak self] in self?.onboardingWindow.isVisible == true }
        onboarding.recordReplyThreadShown = { id, outcome, at in
            archive?.event(id, kind: "setup_reply_thread_shown", payload: [
                "outcome": .string(outcome.rawValue), "at": .number(at.timeIntervalSince1970)
            ], scope: archive?.scope)
        }
        let history = dictation.history
        archive?.bind(key: onboarding.backendKey)
        archive?.importHistory(history.entries)
        dictation.accountChanged(signedIn: onboarding.backendKey != nil)
        #if DEBUG
        // The fixture's made-up key would be refused, signing the fixture out.
        let fixture = OnboardingFixture.isRequested
        #else
        let fixture = false
        #endif
        diagnosticAccount = DiagnosticAccount(journal: .shared, read: { [weak onboarding] in
            guard let onboarding else { return .unreadable }
            if let key = onboarding.backendKey { return .key(key) }
            return onboarding.isKeyUnreadable ? .unreadable : .signedOut
        }, identify: { key in
            guard !fixture, let client = AlphaClient.configured() else { throw AlphaClient.Failure.invalidResponse }
            return try await client.identity(deviceKey: key).accountID
        }, refused: { [weak onboarding] key in onboarding?.backendKeyRefused(key) })
        diagnosticAccount?.identityChanged = { [weak self, weak onboarding, eventSender] accountID in
            Telemetry.identify(accountID: accountID)
            self?.learningProgress.setAccount(accountID)
            if accountID != nil, let onboarding, onboarding.hasReadMail {
                self?.learningProgress.observe(onboarding.connections, learning: onboarding.learning)
            }
            if accountID != nil {
                eventSender?.bind(scope: archive?.scope)
                if let onboarding {
                    DiagnosticEvents.shared.note(onboarding.granted.contains(.microphone) ? .permissionMicrophoneGranted : .permissionMicrophoneDenied)
                    DiagnosticEvents.shared.note(onboarding.granted.contains(.accessibility) ? .permissionAccessibilityGranted : .permissionAccessibilityDenied)
                }
                if let self {
                    DiagnosticEvents.shared.note(self.screenRecording.isGranted() ? .permissionScreenGranted : .permissionScreenDenied)
                }
            } else {
                eventSender?.beginAccountCheck(scope: archive?.scope, buffer: onboarding?.backendKey != nil)
            }
        }
        onboarding.permissionReported = { permission, granted in
            let name: ClientEventName = switch permission {
            case .microphone: granted ? .permissionMicrophoneGranted : .permissionMicrophoneDenied
            case .accessibility: granted ? .permissionAccessibilityGranted : .permissionAccessibilityDenied
            }
            DiagnosticEvents.shared.note(name)
        }
        screenRecording.reported = { granted in
            DiagnosticEvents.shared.note(granted ? .permissionScreenGranted : .permissionScreenDenied)
        }
        screenRecording.startMonitoring()
        if let diagnosticAccount {
            AlphaClient.observeSuccessfulResponses(DiagnosticAccount.serverResponded(diagnosticAccount))
            diagnosticAccount.refresh()
        }
        DiagnosticEvents.shared.note(.appLaunched)
        var diagnosticKey = onboarding.backendKey
        onboarding.accountChanged = { [weak self] signedIn in
            self?.holdKey.cancelPending()
            let nextKey = self?.onboarding.backendKey
            archive?.bind(key: nextKey)
            if diagnosticKey != nil, diagnosticKey != nextKey {
                DiagnosticEvents.shared.clear()
            }
            let changed = diagnosticKey != nextKey
            diagnosticKey = nextKey
            self?.diagnosticAccount?.refresh()
            if changed, nextKey != nil { DiagnosticEvents.shared.note(.signedIn) }
            self?.proposals.reset()
            self?.dictation.accountChanged(signedIn: signedIn)
            self?.threadWatch.refresh(accountChanged: true)
            // Nothing more is read or announced for the earlier account.
            self?.voiceReady?.accountChanged()
            if signedIn { self?.voiceReady?.check() }
        }
        // The foot warms while the writer works on the practice email, and
        // follows dictation again once it is in. An update that waited for
        // the practice reply installs then.
        onboarding.replyStarted = { [weak self] in
            // A recording started meanwhile keeps the foot's sun.
            guard let self, dictation.phase == .idle else { return }
            foot.follow(.writing)
        }
        onboarding.replyEnded = { [weak self] in
            guard let self else { return }
            foot.follow(FootState(phase: dictation.phase, notice: dictation.notice, email: dictation.emailFeedback))
            DispatchQueue.main.async { [weak self] in self?.installUpdateWhenQuiet() }
        }
        // A notice says what the field alone does not show, beside the dot
        // or above the foot mark, and to VoiceOver: that the words were
        // typed in place of an email (dictation's `notice`), or why a dictation
        // inserted nothing (`silence`), which never reaches an email, or,
        // when Retry or another microphone can help, the popup says it
        // (`nothing`). What ended while another dictation records waits for
        // it to stop.
        DictationIndicators.connect(dictation, foot: foot, key: holdKey, phase: { [weak self] phase in
            guard let self else { return }
            if phase != .idle { self.emailHints.dictationStarted() }
            self.microphoneMenu.setRecording(phase == .recording)
            self.caretDot.dictationPhase = phase
            // Escape is taken from the app in front only while it cancels,
            // and Space only for a key held for a dictation recording.
            self.holdKey.onEscape = self.dictation.escapeCancellation()
            self.holdKey.recording = phase == .recording
            if phase == .idle {
                // Next turn, after a notice the dictation's end shows.
                DispatchQueue.main.async { [weak self] in self?.installUpdateWhenQuiet() }
            } else if phase == .recording {
                // A new dictation takes the last one's words away. One that
                // ends while another records says so once that one stops,
                // and one that ends while another is on its way keeps its
                // own notice or popup until the next starts.
                self.silenceEnds?.cancel()
                self.silenceWords = nil
                self.updateWordRouting()
                self.dotNotice.hide()
                self.insertionPopup.hide()
            }
        }, notice: { [weak self] notice in
            guard let self else { return }
            self.sayOnDot(notice?.text)
            if let notice {
                self.announce(notice.text)
            } else {
                self.installUpdateWhenQuiet()
            }
        }, silence: { [weak self] notice in self?.say(notice) }, nothing: { [weak self] empty in self?.offer(empty) },
        email: { [weak self] feedback in
            guard let self else { return }
            self.caretDot.emailFeedback = feedback
            self.holdKey.onEscape = self.dictation.escapeCancellation()
            self.holdKey.pendingEmailWrite = feedback.pending
        }, announce: { [weak self] in self?.announce($0) }, recordingIssue: { [weak self] words in
            guard let self else { return }
            self.updateWordRouting()
        }, follow: { [weak self] state in self?.updateWordRouting(following: state) })
        foot.afterNotice = { [weak self] in
            guard let self else { return .resting }
            let state = FootState(phase: self.dictation.phase, notice: self.dictation.notice, email: self.dictation.emailFeedback)
            if !self.caretDot.wordsAtFoot, case .notice = state { return .resting }
            return state
        }
        // Text that could not go in is never dropped silently: the
        // indicator the person chose opens a popup that says why, shows the
        // text and copies it. History keeps it either way.
        insertionPopup.copy = { [weak self] text, concealed in self?.clipboard.copy(text, concealed: concealed) ?? false }
        // A dictation that came back with no words: Retry sends its kept
        // audio again, as a history row's Retry does, and opens Home, where
        // its words come with Copy, since a retry is never inserted; with
        // another dictation still on its way the row offers Retry once it
        // has ended. Switch mic opens Settings over Home, on the section
        // that holds the Microphone menu.
        insertionPopup.retry = { [weak self] entry in
            self?.dictation.retry(entry)
            self?.open(.history)
        }
        insertionPopup.switchMicrophone = { [weak self] in self?.open(.settings) }
        dictation.notInserted = { [weak self] reason, text in
            guard let self else { return }
            self.insertionPopup.show(reason, text: text, from: self.popupAnchor)
        }
        // A refused reply proposal's popup opens above the caret, so it
        // leaves the compose's own controls below the body in view.
        dictation.proposalRefused = { [weak self] reason, text in
            guard let self else { return }
            self.insertionPopup.showDraft(reason, text: text, from: self.proposalPopupAnchor)
        }
        // A caption the dot took away while it was due goes to the foot of
        // the screen for its own full time.
        caretDot.noticeLost = { [weak self] words in
            guard let self, self.preferences.indicator == .dot else { return }
            self.sayOnDot(words)
        }
        updater.isBusy = { [weak self] in self?.isBusy ?? false }
        problemReportPanel.didClose = { [weak self] in self?.installUpdateWhenQuiet() }
        // The first email Intention writes says so once, and the hint beside an
        // email body retires with it. The hint waits while anything else is said.
        dictation.firstEmailWritten = { [preferences] in preferences.firstEmailWritten }
        dictation.setFirstEmailWritten = { [preferences] in preferences.firstEmailWritten = true }
        // The first dictation and the first email outside setup, for the
        // first-run report. Fixed names and times only.
        dictation.didInsert = { [weak self] email in
            guard let record = self?.onboarding.record else { return }
            record.mark(.firstDictation)
            if email { record.mark(.firstEmail) }
        }
        emailHints.quiet = { [weak self] in !(self?.isBusy ?? true) }
        emailHints.say = { [weak self] words in self?.sayHint(words) }
        // An update waits while a notice about the last dictation shows,
        // since installing relaunches Intention, and is tried again when the
        // notice goes, and when its time ends (`hasMoreToSay`), which can
        // come after.
        foot.noticeEnded = { [weak self] in self?.installUpdateWhenQuiet() }
        dotNotice.ended = { [weak self] in self?.installUpdateWhenQuiet() }
        insertionPopup.ended = { [weak self] in self?.installUpdateWhenQuiet() }
        dictation.doneSaying = { [weak self] in self?.installUpdateWhenQuiet() }
        holdKey.onListenerProblem = { [weak self] words in
            guard let self, self.preferences.dictationKey == .function,
                  let words else {
                self?.foot.inputProblem = nil
                return
            }
            self.foot.inputProblem = words
            if self.dictation.phase == .idle { self.announce(words) }
        }
        holdKey.onShortHold = { [weak self] in
            guard let self, self.dictation.phase == .idle else { return }
            self.foot.showKeyHint()
        }
        permission.onChange = { [weak holdKey] in holdKey?.checkListener() }
        holdKey.start()
    }

    /// Whether Intention opens at login, or will once it is opened from
    /// Applications.
    var opensAtLogin: Bool {
        loginItem.state != .off || preferences.loginItemPending
    }

    func setOpensAtLogin(_ opens: Bool) {
        Self.apply(opensAtLogin: opens, loginItem, preferences)
    }

    /// The one place opening at login is turned on or off, for setup's
    /// last page and Settings alike. A copy outside Applications, such as
    /// one run from the disk image or Downloads, can move or disappear and
    /// leave a login item that opens nothing, so a yes there waits for the
    /// next launch from Applications.
    private static func apply(opensAtLogin opens: Bool, _ loginItem: LoginItem, _ preferences: Preferences) {
        if opens, !LoginItem.isStable() {
            preferences.loginItemPending = true
            return
        }
        loginItem.set(opens)
        // A registration macOS refused is tried again at the next launch.
        preferences.loginItemPending = opens && loginItem.state == .off
    }

    func setAppearance(_ appearance: Appearance) {
        preferences.appearance = appearance
        Appearance.current = preferences.appearance
    }

    /// The person's temporary hide applies across launches and expires on its own.
    /// The foot dot's menu (`FootMenu`), with what each item does. The
    /// inputs are read as it opens: an open menu holds the main thread, so
    /// nothing follows them while it shows, and the list is as they are now.
    func footMenu() -> NSMenu {
        microphoneMenu.updateInputs(Self.inputsShown())
        return FootMenu.make(microphones: microphoneMenu.rows, canPasteLast: dictation.canPasteLast,
                      actions: FootMenu.Actions(hide: { [weak self] in self?.hideFoot(for: .seconds(3600)) },
                                                settings: { [weak self] in self?.open(.settings) },
                                                microphone: { [weak self] in self?.microphoneMenu.choose($0) },
                                                history: { [weak self] in self?.open(.history) },
                                                pasteLast: { [weak self] in self?.dictation.pasteLast() }))
    }

    func hideFoot(for duration: Duration) {
        let parts = duration.components
        let until = Date().addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        foot.hide(until: until)
        footHiddenUntil = foot.hiddenUntil
        preferences.footHiddenUntil = footHiddenUntil
    }

    func showFootAgain() {
        foot.showAgain()
        footHiddenUntil = nil
        preferences.footHiddenUntil = nil
    }

    /// Settings' dot position, for every display; the dot springs there.
    func setDotPosition(_ slot: FootSlot) {
        preferences.chooseDotPositionEverywhere(slot)
        foot.slotsChanged()
    }

    func setIndicator(_ style: IndicatorStyle) {
        preferences.indicator = style
        apply(indicator: style)
        AppLog.event(style == .foot ? "Indicator: foot" : "Indicator: dot")
    }

    /// The caret dot shows only when chosen. It stops reading the caret and
    /// capturing when hidden, so the foot mark alone needs no Screen
    /// Recording, and the foot then says the words the dot would.
    /// "Draft replies for me": off ends any proposal on its way or on screen.
    func setDraftsReplies(_ on: Bool) {
        preferences.draftsReplies = on
        if !on { proposals.reset() }
        threadWatch.refresh()
    }

    private func apply(indicator style: IndicatorStyle) {
        if style != .dot { proposals.reset() }
        threadWatch.refresh()
        dotNotice.hide()
        insertionPopup.hide()
        wordRoute.reset()
        caretDot.shown = style == .dot
        updateWordRouting()
    }

    /// A dictation is running or a notice about one shows.
    private var isBusy: Bool {
        dictation.isBusy || dictation.hasMoreToSay || dictation.notice != nil || silenceWords != nil || foot.showsNotice || dotNotice.isShown || insertionPopup.isShown
            // Setup's reply page waiting on the writer: a relaunch then
            // would lose the person's first email.
            || onboarding.replySpoken != nil || problemReportPanel.blocksUpdates
    }

    /// Where setup's sun lands as setup ends: the foot mark's dot, while
    /// the foot shows.
    private func setupLanding() -> SetupLanding? {
        guard let frame = foot.markFrame else { return nil }
        // The mark cuts its painting's bloom 2 points past the disc on every
        // desktop, so the flying sun does too.
        return SetupLanding(frame: frame, side: SunDotView.disc * SunDotView.bloom,
                            level: FootWindow.footLevel, cutsBloom: true,
                            isMoon: foot.mark.sky == .moon, restColor: foot.mark.restInk, restRadius: SunDotView.restWidth / 2 + OwnHandMark.restEdge,
                            cover: { [foot] time in foot.coverForSun(at: time) }, arrive: { [foot] in foot.receiveSun() },
                            uncover: { [foot] in foot.uncover() })
    }

    /// Where the insertion popup opens from: the foot mark's dot when the
    /// foot alone is selected, otherwise the known caret anchor.
    private var popupAnchor: InsertionPopup.Anchor {
        if preferences.indicator == .foot {
            // At a side, the popup opens beside the dot as it does beside the
            // caret dot, toward the screen's middle.
            return foot.markFrame.map { foot.slot == .bottom ? .foot($0) : .dot($0) } ?? .screenFoot
        }
        return DictationIndicators.popupAnchor(caretAnchor: caretDot.caretAnchor)
    }

    /// Where a refused proposal's popup opens from: above the dot and the
    /// card, when they show, or the foot of the screen.
    private var proposalPopupAnchor: InsertionPopup.Anchor {
        let near = [caretDot.caretAnchor, proposalCard.frame].compactMap { $0 }
        guard let first = near.first else { return .screenFoot }
        return .caret(near.dropFirst().reduce(first) { $0.union($1) })
    }

    private func installUpdateWhenQuiet() {
        if !isBusy { updater.installIfWaiting() }
    }

    /// Resolve current storage at the action boundary, so a stale row cannot
    /// copy cleared text or bypass the entry's clipboard concealment.
    func copy(_ row: HistoryRow) -> Bool {
        dictation.history.copy(row.id, to: clipboard)
    }

    func retry(_ row: HistoryRow) { dictation.retry(row.id) }

    func switchMicrophone() { open(.settings) }

    @discardableResult
    func clearHistory() -> Bool { dictation.clearHistory() }

    /// Opens the main window on Home, or with Settings over it on General,
    /// whose first lines hold the dictation key and the Microphone menu.
    func open(_ window: Window) {
        holdKey.cancelPending()
        mainWindow.show(settings: window == .settings ? .general : nil)
    }

    /// Says that a dictation came back with no words, naming its
    /// microphone, in the popup from the indicator the person chose, with
    /// Switch mic and, when its audio was kept, Retry: neither the foot's
    /// notice nor the dot's caption takes a click.
    private func offer(_ empty: DictationController.EmptyResult) {
        insertionPopup.showEmpty(FootState.words(for: empty), retrying: empty.retry, from: popupAnchor)
    }

    private var wordRoute = NoticeWordRoute()
    private var routingWords = false
    private var timedFootWords: String?
    private var renderedWords: String?
    private var renderedAtFoot = false
    private var renderedWithCaret = false
    private var renderedAsHint = false
    private var renderedIssue = false

    /// All foot availability, including a future user hide, belongs here.
    private func footCanSay(_ words: String) -> Bool { foot.canShowWords(words) }

    /// Pick once per notice. A later loss of room can move it to the caret;
    /// a new email classification never moves words that are already visible.
    private func updateWordRouting(following: FootState? = nil) {
        guard !routingWords else { return }
        routingWords = true
        defer { routingWords = false }
        let phaseWords = dictation.phase.caption(email: dictation.emailFeedback)
        let notice = dictation.recordingIssue ?? dictation.notice?.text ?? silenceWords
        let hint = dictation.phase == .idle && notice == nil ? hintWords : nil
        let words = phaseWords ?? notice ?? hint
        let hasRoom = words.map(footCanSay) ?? false
        var atFoot: Bool
        if phaseWords != nil {
            wordRoute.reset()
            atFoot = DictationIndicators.wordsThroughFoot(style: preferences.indicator, isEmailBody: caretDot.isEmailBody, footHasRoom: hasRoom)
        } else {
            atFoot = wordRoute.choose(words, style: preferences.indicator, isEmailBody: caretDot.isEmailBody, footHasRoom: hasRoom)
        }
        // Set word ownership before either show or follow can open a slip.
        if words == nil {
            DictationIndicators.select(preferences.indicator, dictation: dictation, foot: foot, isEmailBody: caretDot.isEmailBody)
        } else {
            foot.saysWords = atFoot
        }
        foot.recordingIssue = dictation.recordingIssue
        var state = following
        if state == nil, words != nil || renderedWords != nil {
            state = FootState(phase: dictation.phase, notice: dictation.notice, email: dictation.emailFeedback)
        }
        let timed = phaseWords == nil && dictation.recordingIssue == nil && dictation.notice == nil && words != nil
        let displayedAtFoot = DictationIndicators.follow(state, words: words, atFoot: atFoot, timed: timed,
            allowCaretFallback: preferences.indicator == .dot, foot: foot, timedWords: &timedFootWords)
        if atFoot && !displayedAtFoot {
            _ = wordRoute.choose(words, style: preferences.indicator, isEmailBody: caretDot.isEmailBody, footHasRoom: false)
            atFoot = false
        }
        caretDot.wordsAtFoot = atFoot
        let hasCaret = caretDot.caretAnchor != nil
        let asHint = hint != nil && phaseWords == nil
        let issue = dictation.recordingIssue != nil
        guard renderedWords != words || renderedAtFoot != atFoot || renderedWithCaret != hasCaret
                || renderedAsHint != asHint || renderedIssue != issue else { return }
        let wasIssue = renderedIssue
        renderedWords = words
        renderedAtFoot = atFoot
        renderedWithCaret = hasCaret
        renderedAsHint = asHint
        renderedIssue = issue
        if !asHint { caretDot.hint = nil }
        if asHint || phaseWords != nil { caretDot.notice = nil }
        if words == nil, wasIssue { dotNotice.hide() }
        // The email wait is already rendered by the controller's phase.
        guard phaseWords == nil else { dotNotice.hide(); return }
        DictationIndicators.sayOnDot(words, caretAnchor: caretDot.caretAnchor,
            recordingIssue: dictation.recordingIssue, throughFoot: atFoot,
            caption: { [caretDot] in
                if asHint { caretDot.hint = $0 } else { caretDot.notice = $0 }
            }, panel: { [dotNotice] notice, duration in
                if let notice { dotNotice.show(notice, beside: nil, for: duration) } else { dotNotice.hide() }
            })
    }

    private var silenceWords: String?
    private var silenceEnds: Task<Void, Never>?

    private func say(_ notice: FootState) {
        guard case let .notice(words) = notice else { return }
        silenceEnds?.cancel()
        silenceWords = words
        updateWordRouting()
        silenceEnds = Task { [weak self] in
            try? await Task.sleep(for: FootMark.noticeShown)
            guard !Task.isCancelled, let self else { return }
            self.silenceWords = nil
            self.updateWordRouting()
            self.installUpdateWhenQuiet()
        }
        announce(words)
    }

    private func sayOnDot(_: String?) { updateWordRouting() }

    private var hintWords: String?

    private func sayHint(_ words: String?) {
        hintWords = words
        if let words { announce(words) }
        updateWordRouting()
    }

    private func announce(_ words: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The one place a choice of dictation key takes effect, for Settings
    /// and for setup alike.
    private static func apply(key: HoldKey.Key, _ preferences: Preferences, _ holdKey: HoldKey) {
        preferences.dictationKey = key
        holdKey.key = key
    }

    /// The languages the person dictates in, as two-letter codes; empty
    /// means English. Setup asks for them and Settings changes them.
    func setDictationLanguages(_ codes: [String]) {
        Self.apply(languages: codes, preferences, dictation)
    }

    /// The one place a choice of languages takes effect, for Settings and
    /// for setup alike.
    private static func apply(languages codes: [String], _ preferences: Preferences, _ dictation: DictationController) {
        preferences.dictationLanguages = codes
        dictation.languages = codes
    }

    /// Debug builds launched with `--dictation-audio <file>` dictate that
    /// recording instead of the microphone.
    private static func recordingInPlaceOfMicrophone() -> SpeechAudioSource? {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--dictation-audio"), index + 1 < arguments.count else { return nil }
        do {
            return try RecordingPlayback(url: URL(fileURLWithPath: arguments[index + 1]))
        } catch {
            AppLog.event("Dictation recording could not be read; using the microphone")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The endpoint this build names, with speech grants for the device key
    /// setup holds. Nil without an endpoint or a backend to grant access, and
    /// in setup's fixture, whose made-up key no backend grants anything for:
    /// sending it to the configured backend would be refused and sign the
    /// fixture out.
    private static func personalVocabulary(_ setupKey: SetupKey) -> any DictationVocabulary {
        #if DEBUG
        if OnboardingFixture.isRequested { return EmptyVocabulary() }
        #endif
        guard let client = AlphaClient.configured() else { return EmptyVocabulary() }
        return PersonalVocabulary(client: client, key: { setupKey.onboarding?.backendKey },
                                  keyRefused: { setupKey.onboarding?.backendKeyRefused($0) })
    }

    /// The draft route for the device key setup holds. Nil without a
    /// backend, and in setup's fixture, whose made-up key no backend
    /// accepts.
    private static func drafts(_ setupKey: SetupKey) -> (any DraftService)? {
        #if DEBUG
        if OnboardingFixture.isRequested { return nil }
        #endif
        guard let client = AlphaClient.configured() else { return nil }
        return AlphaDraftService(client: client, key: { setupKey.onboarding?.backendKey },
                                 keyRefused: { setupKey.onboarding?.backendKeyRefused($0) })
    }

    /// This Mac's inputs. A Settings render shows made-up ones, so a
    /// picture of Settings names nobody's headset.
    private static var inputsShown: @MainActor () -> AudioInputs {
        #if OFFSCREEN_RENDER
        if SettingsSnapshot.isRequested { return { SettingsSnapshot.inputs } }
        #endif
        return AudioHardware.inputs
    }

    /// The microphone, from Settings. The next dictation opens what it
    /// picks; one recording now keeps its device.
    func setMicrophone(_ preference: MicrophonePreference) {
        preferences.microphone = preference
        switch preference {
        case .builtIn: AppLog.event("Microphone: built-in")
        case .systemDefault: AppLog.event("Microphone: system default")
        case .device: AppLog.event("Microphone: a device by name")
        }
    }

    /// "Write emails for me", from Settings: whether words dictated into an
    /// email body become an email, or are typed as they are.
    func setWritesEmails(_ on: Bool) {
        preferences.writesEmails = on
        if !on { proposals.reset() }
        dictation.writesEmailsChanged(on)
        threadWatch.refresh()
    }

    private static func dictationEndpoint(_ setupKey: SetupKey) -> DictationEndpoint? {
        #if DEBUG
        if OnboardingFixture.isRequested { return nil }
        #endif
        guard let url = DictationEndpoint.address(), let client = AlphaClient.configured() else { return nil }
        let grants = SpeechGrants(client: client, key: { setupKey.onboarding?.backendKey },
                                  keyRefused: { setupKey.onboarding?.backendKeyRefused($0) })
        return DictationEndpoint(url: url, credentials: grants)
    }

    private static func onboarding(permission: AccessibilityPermission, clipboard: PasteboardOwner, languages: DictationLanguages,
                                   dictation: FirstDictation, practice: PracticeReply, loginItem: SetupLoginItem,
                                   screenRecordingDue: @escaping @MainActor () -> Bool) -> OnboardingModel {
        let permissions = SetupPermissions.system(accessibility: permission, clipboard: clipboard)
        #if DEBUG
        if OnboardingFixture.isRequested {
            return OnboardingFixture.model(permissions: permissions, dictation: dictation, languages: languages)
        }
        #endif
        return OnboardingModel(client: AlphaClient.configured(), keys: KeychainDeviceKey(), permissions: permissions,
                               dictation: dictation, practice: practice, languages: languages, loginItem: loginItem,
                               screenRecordingDue: screenRecordingDue, record: DiagnosticEvents.shared.observing(FirstRunRecord.stored(reported: { marks, event in
                                   // Setup finished and the first dictation and email after it
                                   // reach disabled telemetry once each; other marks build no report.
                                   if let timing = FirstRunTiming(marks: marks, after: event) { Telemetry.record(timing) }
                               })))
    }

    /// From the menu bar item, after macOS was told not to give Intention its
    /// key: reads it again, so macOS asks again.
    func retryKeyRead() {
        onboarding.retryKeyRead()
    }

    func showSetup() {
        onboardingWindow.show()
    }

    /// Opens setup at its mail step, to connect a mailbox after setup.
    func showMailSetup() {
        onboarding.reopenMail()
        onboardingWindow.show()
    }

    /// The menu bar item's "Allow the clipboard…", offered after a paste
    /// replaced the person's clipboard because macOS would not let Intention
    /// read it. Setup's optional row asks the same way, but its page turns
    /// once the required grants are in, so many people never reach it.
    /// The item stays until Intention may read the clipboard, so a person who
    /// answered Don't Allow can try again from it.
    func allowClipboard() {
        Task {
            await SetupPermissions.askToReadClipboard(clipboard)
            if clipboard.mayReadOtherApps { dictation.pasteReplacedClipboard = false }
        }
    }

    /// Connect or Reconnect from Settings, in one click: setup's mail page
    /// opens, since the consent is presented from its window, and the
    /// connection starts there at once.
    func connectMail(_ provider: AlphaClient.MailProvider) {
        showMailSetup()
        Task { await onboarding.connect(provider) }
    }

    /// `ask` says whether it asked macOS; a request that no longer applies
    /// when its turn comes opens nothing and starts no visit.
    private func requestScreenRecording(_ ask: @escaping @MainActor () -> Bool) {
        // The request puts Intention in the list only once macOS's alert for
        // it has been answered, so an alert in front is left there: its
        // button opens the page, and the guide waits for that visit. macOS
        // shows the alert only once, so when none comes up, opening the
        // page is the only thing the request can do. See `PermissionAlert`.
        Task {
            // The option may be turned off again while the alert is looked
            // for; then nothing opens and no visit starts.
            var asked = false
            let outcome = await PermissionAlert.request({ asked = ask() }) {
                guard asked, self.preferences.visualCaretEnabled else { return false }
                self.openScreenRecordingSettings()
                return true
            }
            if asked, outcome == .alertInFront, preferences.visualCaretEnabled { screenRecordingGuide.guideNextVisit() }
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            screenRecordingGuide.open(url)
        }
    }

    #if DEBUG
    /// Synthetic text for trying insertion in real apps, with an accented
    /// letter, CJK and an emoji ZWJ sequence so UTF-16 offsets are exercised.
    static let sampleText = "Synthetic text from Intention: café, 東京, 👩‍💻."

    /// Development menu actions; dictation will call the inserter directly.
    /// The short wait lets keyboard focus settle back on the field after the
    /// menu closes.
    func insertSampleText() {
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            lastEditOutcome = TextInserter.name(await inserter.insert(Self.sampleText))
        }
    }
    #endif
}

/// Setup's model, for the speech grants dictation was built with before it.
@MainActor
private final class SetupKey {
    weak var onboarding: OnboardingModel?
}

/// Whether macOS will be asked for Screen Recording as setup ends, read by
/// setup's last page. Filled in once the app model holds its request.
@MainActor
private final class ScreenRecordingLink {
    var isDue: @MainActor () -> Bool = { false }
}
