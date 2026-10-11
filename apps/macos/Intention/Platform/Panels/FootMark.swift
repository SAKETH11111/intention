import AppKit

/// What the foot mark shows. It follows dictation's phase exactly: the
/// resting dot, the sun while the microphone is open, and the warm sun
/// while Intention turns the recording into text, with words only where the
/// dot does not say them, such as the email being written when the caret
/// dot is hidden. After a dictation, a notice says for a few seconds what
/// the field alone does not show: the words typed in place of an email, in
/// the words dictation gives (`FootState(phase:notice:)`), or why a
/// dictation that went nowhere inserted nothing (`show`).
enum FootState: Equatable {
    case resting
    case listening
    /// Words on their way, with what to say about them, if anything.
    case working(String?)
    /// Said once dictation is over, over the resting dot.
    case notice(String)

    /// An ordinary dictation's text on its way: the warm sun says it.
    static let writing = FootState.working(nil)
    /// A recording with no sound in it.
    static let heardNothing = FootState.notice("Intention heard nothing from your microphone")
    /// A recording with no words found in it that was nearly all silence.
    static let heardAlmostNothing = FootState.notice("Your microphone sent almost nothing")
    /// A recording with sound but no words in it.
    static let heardNoWords = FootState.notice("Intention heard no words")
}

/// What the foot's mark shows and what a click there does, from its
/// state, whether the pointer is over it and whether it says words at all
/// (`FootMark.saysWords`): the dot at rest, the microphone under the
/// pointer, the sun while listening, which is its own stop button, the warm
/// sun while Intention writes, and a notice. Neither sun shows anything more
/// under the pointer: the microphone belongs to the resting dot alone. Glyphs
/// before words: the email being written is the warm sun's, with no words of
/// its own.
enum FootPresentation: Equatable {
    case rest
    /// The microphone, which a click dictates from.
    case hint
    /// The microphone with the dictation key's cap beside it, after a press
    /// of the key too short to dictate.
    case keyHint
    case listening
    case writing
    case notice(String)

    init(state: FootState, hovering: Bool, saysWords: Bool) {
        switch state {
        case .resting: self = hovering ? .hint : .rest
        case .listening: self = .listening
        case .working: self = .writing
        case let .notice(words): self = saysWords ? .notice(words) : hovering ? .hint : .rest
        }
    }
}

/// What the person asks of the foot mark.
enum FootAction: Equatable {
    case start, cancel, done
}

/// The foot mark: Intention's dot at the foot of the screen, where the pill
/// was until October 10, 2026. It waits as the resting ink dot near the
/// bottom centre of the screen the pointer is on, 14 points above a Dock
/// that stays shown or 22 above the screen's edge, under a Dock that slides
/// up over it, since its windows sit one level below the Dock's
/// (`FootWindow.level`). Under the pointer the dot itself opens into a
/// slip saying "Dictate" with the key (`FootSlip`), and a click there
/// starts a dictation. While the microphone is
/// open it is the sun (`SunDotView`), and a click on it ends the dictation
/// and inserts the text; Escape cancels it. Then it warms and breathes
/// while Intention works, and settles back into the dot when the text has
/// gone. Once a dictation opens it stays on its display until it rests
/// again.
///
/// It paints only where it cannot touch the focused field: when the field
/// the caret dot tracks reaches down into the foot (`isClear`), as a chat
/// app's composer does, nothing shows at the foot, no mark and no slip,
/// and the caret dot carries the red (`painting`). Two windows make it up:
/// `FootWindow` draws it and takes no mouse event, and `FootTargetWindow`,
/// over the dot or its open slip, takes the pointer and clicks without taking
/// focus or activating Intention. It needs no permission: nothing is read
/// from any app to place it.
///
/// The person can move it: pressed and dragged past `dragThreshold`, it
/// lifts, follows the pointer, and three paper slots show on every display
/// (`FootSlotsView`), at the bottom centre and the middle of each side;
/// let go, it springs into the slot nearest where it was thrown
/// (`FootPlacement.snap`), and that display keeps the choice (`chose`).
/// Settings sets one for every display (`slotsChanged`), and VoiceOver
/// offers the same moves on the dot's button. Every rule above holds at a
/// side: the focused-field rule along that edge, a Dock on that side, which
/// the slot sits beside, or hiding there, which may slide over it, and the
/// words beside the dot toward the screen's middle. A drag starts only from
/// the resting dot; during a dictation a press is a click.
@MainActor
final class FootMark {
    /// The drawing window's size: room for the longest words and the
    /// mark's bloom.
    static let windowSize = CGSize(width: 360, height: 96)
    /// Where the dot's centre sits in the drawing window, with room below it
    /// for the whole listening sun (`SunDotView.envelope`).
    static let dotInWindow = CGPoint(x: 180, y: 30)
    /// The dot's centre above a Dock that stays shown, or above the
    /// screen's edge, or the strip macOS keeps there for a hidden Dock: the
    /// whole listening sun's radius, so none of it falls behind the Dock or
    /// off the screen, where a ring would show as a crescent.
    nonisolated static let aboveDock = SunDotView.envelope
    nonisolated static let aboveEdge = SunDotView.envelope
    /// A popup opened from the foot starts this far above the dot's centre.
    nonisolated static let wordsGap: CGFloat = 20
    /// The square around the dot that takes the pointer.
    nonisolated static let reach: CGFloat = 32
    /// The focused field must end this far above the foot's floor, plus
    /// `margin`, for the foot to paint: the whole listening sun above the
    /// floor and below the field.
    nonisolated static let clearance = 2 * SunDotView.envelope
    nonisolated static let margin: CGFloat = 8
    /// Half the width of the foot's column, which a field has to cross to
    /// touch the foot.
    nonisolated static let column: CGFloat = 120
    /// The drawing window at a side slot: wider, for the slip opening from
    /// the dot toward the screen's middle, and taller above the dot than
    /// below it, for the tooltip over the pill and its float.
    static let sideWindowSize = CGSize(width: 440, height: 128)
    /// How far the pointer must move with the button down before a press
    /// becomes a drag rather than a click.
    nonisolated static let dragThreshold: CGFloat = 4

    /// The drawing window's size and where the dot sits in it at `slot`: at
    /// a side, near the window's outer end, with the whole listening sun
    /// inside it and the slip's room toward the screen's middle.
    static func layout(for slot: FootSlot) -> (size: CGSize, dot: CGPoint) {
        switch slot {
        case .bottom: (windowSize, dotInWindow)
        case .left: (sideWindowSize, CGPoint(x: 30, y: 48))
        case .right: (sideWindowSize, CGPoint(x: sideWindowSize.width - 30, y: 48))
        }
    }

    /// One display, as far as placing the foot goes.
    struct Screen: Equatable {
        var id: CGDirectDisplayID
        var frame: CGRect
        /// The frame less the menu bar and a Dock that stays shown, as
        /// `NSScreen.visibleFrame` gives it.
        var usable: CGRect
        /// What the display's choice of slot is kept under: its UUID, which
        /// outlives a reboot or a reconnection, unlike `id`
        /// (`FootPlacement.displayKey`).
        var key = ""
    }

    /// What the foot is placed by: the displays and the pointer, and
    /// whether its windows go on screen at all. The app reads the system's;
    /// the checks give made-up displays and keep the windows off screen.
    struct Desktop {
        var screens: @MainActor () -> [Screen]
        var pointer: @MainActor () -> CGPoint
        var showsWindow = true
        /// The edge the Dock is set to, for a display whose frame does not
        /// show it, as in a full-screen space (`FootPlacement.dock`): the
        /// system's setting for the app, none on the checks' made-up desks.
        var dockEdge: @MainActor () -> FootSlot? = { nil }

        @MainActor static var system: Desktop {
            Desktop(screens: { NSScreen.screens.map(Screen.init) }, pointer: { NSEvent.mouseLocation },
                    dockEdge: { FootPlacement.systemDockEdge() })
        }
    }

    /// Whether the foot shows at all.
    var enabled = false {
        didSet { if enabled != oldValue { update(choosing: true) } }
    }
    /// Whether the foot says words beyond its hint: true when the caret dot
    /// is hidden and cannot say them beside the caret.
    var saysWords = false {
        didSet { if saysWords != oldValue { update(choosing: false) } }
    }
    /// The dictation key's name, for the key hint's cap, read each time it
    /// shows.
    var keyName: () -> String = { "fn" }
    var recordingIssue: String? { didSet { if recordingIssue != oldValue { update(choosing: false) } } }
    /// Light or Dark, as chosen in Settings, read each time the foot shows.
    var appearance: () -> Appearance = { Appearance.current }
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
    /// The sky the clock says. The mark turns only while it rests, never in
    /// the middle of a dictation.
    var sky = SunDotView.Sky.sun {
        didSet { if state == .resting { mark.sky = sky } }
    }
    /// The focused field's frame in AppKit screen coordinates, from the
    /// caret dot's observations, or nil when none is known.
    var focusedField: CGRect? {
        didSet { if focusedField != oldValue { update(choosing: false) } }
    }
    var state: FootState = .resting {
        didSet {
            guard state != oldValue else { return }
            if state == .resting { mark.sky = sky }
            // A dictation started with the dot in the hand or on its way
            // drops the move; the foot is placed again below, with its
            // buttons for the new state.
            if state != .resting { endMoving() }
            // Opening from rest looks for the display the person is on;
            // turning from listening to working, or closing, does not.
            if state != .resting { keyHintSerial &+= 1; keyHinting = false }
            update(choosing: oldValue == .resting)
            if state != timedNotice { timedNotice = nil }
            if case .notice = oldValue, !showsNotice { noticeEnded() }
        }
    }
    /// The voice's smoothed level, from 0 to 1, about fifty times a second,
    /// for the sun. Taken only while listening.
    var level = 0.0 {
        didSet {
            guard state == .listening else { return }
            mark.level = level
            // Each level also asks whether a Dock has slid up over the sun,
            // so no timer runs for it.
            checkCarriesRed()
        }
    }
    /// The foot's own menu, made when it opens (`FootMenu`), or nil for none.
    var menu: @MainActor () -> NSMenu? = { nil }
    /// What a click on the foot asks for.
    var onAction: (FootAction) -> Void = { _ in }
    /// The slot chosen for a display, read each time the foot is placed.
    var slotFor: (Screen) -> FootSlot = { _ in .bottom }
    /// Keeps the slot the person dragged the dot to, or chose with
    /// VoiceOver, for that display, with every display connected now, whose
    /// own places it leaves as they are.
    var chose: (FootSlot, Screen, [Screen]) -> Void = { _, _, _ in }
    /// The slot the foot is placed in.
    private(set) var slot = FootSlot.bottom
    /// Runs when the foot starts or stops being able to show a recording's
    /// red (`carriesRed`), so the caret dot carries it while the foot
    /// cannot.
    var carriesRedChanged: (Bool) -> Void = { _ in }
    /// Whether work can be shown at the foot, independently of recording red.
    var paintingChanged: (Bool) -> Void = { _ in }
    /// Placement may leave room for the mark but not its words.
    var wordSpaceChanged: @MainActor () -> Void = {}
    private var wordSpaceChangePending = false

    private func reportWordSpaceChange() {
        guard !wordSpaceChangePending else { return }
        wordSpaceChangePending = true
        // Observe completed placement and state changes, not a partially
        // updated notice or a panel still moving between displays.
        DispatchQueue.main.async { @Sendable [weak self] in
            guard let self else { return }
            self.wordSpaceChangePending = false
            self.wordSpaceChanged()
        }
    }
    /// How far above the screen's edge a pointer may summon a Dock set to
    /// hide over the foot: past the tallest Dock.
    nonisolated static let dockReveal: CGFloat = 130
    /// How long a Dock may take to hide again once the pointer has left
    /// it: its delay and its slide down, with room to spare.
    static let dockHides: Duration = .milliseconds(1500)
    /// The clock the Dock's grace is kept on; the checks set their own.
    var now: () -> ContinuousClock.Instant = { .now }
    /// When a Dock was last possibly over the foot.
    private var dockSeen: ContinuousClock.Instant?
    /// How long a notice stays before the foot rests again.
    static let noticeShown: Duration = .seconds(4)
    /// Waits out `noticeShown`, throwing once cancelled. The app sleeps on
    /// the continuous clock; the checks end the wait themselves.
    private let noticeWait: @MainActor (Duration) async throws -> Void
    /// The latest notice's wait and the rest after it, which the checks
    /// await once they have ended the wait.
    private(set) var noticeEnds: Task<Void, Never>?
    /// Runs when the foot stops showing a notice, at its end or because a
    /// dictation started.
    var noticeEnded: () -> Void = {}
    /// What the foot shows once a notice from `show` has had its time:
    /// rest, unless what it follows says otherwise. Dictation's indicators
    /// make it what dictation's phase and notice call for then
    /// (`DictationIndicators.connect`).
    var afterNotice: () -> FootState = { .resting }
    /// The notice `show` put up, while it shows.
    private var timedNotice: FootState?
    /// Whether the foot holds a notice.
    var showsNotice: Bool {
        if case .notice = state { return true }
        return false
    }

    /// The drawing window and the one that takes its clicks, which the
    /// checks read and click without putting them on screen.
    let panel = FootWindow()
    let target = FootTargetWindow()
    /// The mark itself.
    let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
    private var hovering = false
    /// Changes whenever the pointer comes or goes, so a late end of the
    /// hint does not undo a newer hover.
    private var hoverSerial = 0
    /// How long the pointer rests on the dot before it opens into its slip,
    /// and how long the slip stays after the pointer leaves, so a pointer
    /// passing over the foot does not flicker it.
    var hoverDelay: Duration = .milliseconds(150)
    static let hoverGrace: Duration = .milliseconds(250)
    private let desktop: Desktop
    /// The display the foot was last placed on, see `place`.
    private var display: CGDirectDisplayID?
    /// Whether the windows are placed on a display, until next hidden.
    private var placed = false
    /// Whether the foot paints now: shown, placed and clear of the field.
    private(set) var painting = false {
        didSet { if painting != oldValue { checkCarriesRed(); paintingChanged(painting) } }
    }
    /// Whether a person can see the foot's sun: it paints, and no Dock set
    /// to hide can have slid up over it, which a pointer at the foot of the
    /// foot's screen may have brought up. Where the Dock is not known to be
    /// away, the caret dot carries the red instead, so a recording is never
    /// shown only under the Dock.
    private(set) var carriesRed = false {
        didSet { if carriesRed != oldValue { carriesRedChanged(carriesRed) } }
    }
    /// The display the foot is placed on, while placed.
    private var placedScreen: Screen?
    /// Whether the mark is open into its slip now: there are words to say
    /// and the slip keeps clear of the focused field.
    private var slipShowing = false
    private var locked = false
    private var screensAsleep = false
    private var observers: [NSObjectProtocol] = []
    /// The Dock's edge from its own settings, read again when the displays
    /// or the Dock change.
    private var dockEdge: FootSlot?
    /// A drag under way: where on the dot the pointer took hold, and which
    /// slot the dot would land in now.
    private struct Drag {
        var grab: CGVector
        var target: FootSnap?
    }
    private var drag: Drag?
    /// Each display's slots while a drag is under way or leaving.
    private var slotWindows: [CGDirectDisplayID: FootSlotsWindow] = [:]
    /// The spring into a slot after a drag or a move.
    private let glide = FootGlide()
    /// Whether the dot is in the hand or springing into a slot, when the
    /// foot leaves its windows where they are.
    var isMoving: Bool { drag != nil || glide.isRunning }

    init(desktop: Desktop = .system, hiddenUntil: Date? = nil,
         dateNow: @escaping @MainActor () -> Date = { Date() },
         hideWait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         noticeWait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.desktop = desktop
        self.noticeWait = noticeWait
        self.dateNow = dateNow
        self.hideWait = hideWait
        SetupStyle.registerFonts()
        let content = NSView(frame: CGRect(origin: .zero, size: Self.windowSize))
        content.wantsLayer = true
        content.addSubview(mark)
        mark.onFolded = { [weak self] in
            guard let self, self.foldingCover != nil else { return }
            self.foldingCover = nil
            self.cover()
        }
        panel.setContentSize(Self.windowSize)
        panel.contentView = content
        arrange(for: .bottom)
        dockEdge = desktop.dockEdge()
        target.onHover = { [weak self] inside in self?.hover(inside) }
        target.onPress = { [weak self] in self?.press() }
        target.onAction = { [weak self] action in self?.onAction(action) }
        target.onDragBegan = { [weak self] point in self?.beginDrag(at: point) ?? false }
        target.onDragMoved = { [weak self] point in self?.dragMoved(to: point) }
        target.onDragEnded = { [weak self] point, velocity in self?.endDrag(at: point, velocity: velocity) }
        target.onMove = { [weak self] slot in self?.move(to: slot) }
        target.onMenu = { [weak self] event in self?.openMenu(with: event) }
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.locked = locked
                    self?.update(choosing: true)
                }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers += [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = true
                    self?.update(choosing: true)
                }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = false
                    self?.update(choosing: true)
                }
            },
            // At rest the foot follows the person to the screen they work
            // on, judged by the pointer when they switch apps. While a
            // dictation runs it stays where it opened.
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .resting else { return }
                    self.place(choosing: true)
                }
            },
            // A display added, removed or rearranged, or the Dock moved:
            // placed again, on the same display while a dictation runs.
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            },
        ]
        appearanceObserver = NotificationCenter.default.addObserver(forName: .intentionAppearanceChanged, object: nil, queue: .main) { @Sendable [weak self] _ in
            self?.appearanceChanged()
        }
        if let hiddenUntil { hide(until: hiddenUntil) }
    }

    /// Whether the foot shows at all. The person's hide (`hiddenUntil`) puts
    /// away only the resting dot: a recording, Intention's work on it and a
    /// notice still show at the foot, since they may have no other place
    /// to show, and the dot goes again once it rests.
    private var visible: Bool { enabled && !locked && !screensAsleep && (hiddenUntil == nil || state != .resting) }

    // MARK: - The person's temporary hide

    private(set) var hiddenUntil: Date?
    var hiddenChanged: (Date?) -> Void = { _ in }
    private let dateNow: @MainActor () -> Date
    private let hideWait: @MainActor (Duration) async throws -> Void
    private(set) var hideEnds: Task<Void, Never>?

    /// A new hide replaces the earlier deadline. An expired deadline shows
    /// the foot immediately, including when restored at launch.
    func hide(until date: Date) {
        hideEnds?.cancel()
        hideEnds = nil
        let remaining = date.timeIntervalSince(dateNow())
        guard remaining > 0 else { showAgain(); return }
        hiddenUntil = date
        update(choosing: true)
        hiddenChanged(date)
        let wait = hideWait
        hideEnds = Task { [weak self] in
            do { try await wait(.seconds(remaining)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.showAgain()
        }
    }

    func showAgain() {
        hideEnds?.cancel()
        hideEnds = nil
        guard hiddenUntil != nil else { return }
        hiddenUntil = nil
        update(choosing: true)
        hiddenChanged(nil)
    }

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
    }

    /// A framework callback may arrive off the main actor, including in tests.
    nonisolated func appearanceChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.redrawAppearance() }
            return
        }
        MainActor.assumeIsolated { redrawAppearance() }
    }

    private func redrawAppearance() {
        guard painting else { return }
        let look = appearance()
        // The mark follows the window's appearance and redraws its slip.
        panel.appearance = look.nsAppearance
        target.appearance = look.nsAppearance
    }

    /// The dictation key is down and its hold not yet confirmed, true, or the
    /// press ended short, was confirmed or cannot start a dictation, false.
    /// The resting dot lifts as it does in the hand and settles back when
    /// the press ends; a confirmed hold turns it into the sun as before. Only
    /// the resting dot shows a press, and leaving rest drops it
    /// (`SunDotView.keyPending`), so false may come late or twice.
    func setKeyPending(_ pending: Bool) {
        mark.keyPending = pending
    }

    /// Setup's sun landing in the mark as setup ends: the mark shows its
    /// sun under the flying one as it arrives, with no recording, and once
    /// the flying one has faded out over it (`SetupFlight.hold` and `fade`)
    /// swells once and settles to rest as after a dictation.
    /// A dictation started meanwhile takes the mark over. The mark must be
    /// the sun: under the moon, setup settles its own sun (`SetupFlight`).
    func receiveSun() {
        uncover()
        guard state == .resting, painting, mark.sky == .sun else { return }
        arriving = true
        applyLook()
        let wait = landingWait
        Task { [weak self] in
            for (pause, level) in [(400, 0.6), (100, 0.0)] {
                try? await wait(.milliseconds(pause))
                guard let self, self.arriving, self.state == .resting else { return }
                self.mark.level = level
            }
            try? await wait(.milliseconds(120))
            guard let self, self.arriving else { return }
            self.arriving = false
            self.applyLook()
        }
    }

    /// Whether setup's sun is landing, which the foot's own updates keep
    /// until it settles or a dictation takes the mark.
    private var arriving = false
    /// How the landing waits between its steps; the checks drive it
    /// themselves rather than race the clock.
    var landingWait: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// Hides the resting dot at media time `time`, as setup's falling sun
    /// first reaches it, so it never shows under the sun's soft edge. Core
    /// Animation times the hide, so it lands on its frame however late the
    /// main thread is, and the view is hidden then too. `receiveSun` or `uncover` shows the dot again under
    /// the landed sun, and so does a dictation, or a second after `time`,
    /// should neither come.
    func coverForSun(at time: CFTimeInterval = CACurrentMediaTime()) {
        guard state == .resting else { return }
        covers &+= 1
        let cover = covers
        covered = true
        let lead = max(0, time - CACurrentMediaTime())
        let hide = CAKeyframeAnimation(keyPath: "opacity")
        // Discrete: each value holds from its key time to the next, so
        // there is one more key time than values.
        hide.values = [1, 0]
        hide.keyTimes = [0, NSNumber(value: lead / (lead + 2)), 1]
        hide.calculationMode = .discrete
        hide.duration = lead + 2
        hide.fillMode = .forwards
        hide.isRemovedOnCompletion = false
        mark.layer?.add(hide, forKey: "cover")
        Task { [weak self] in
            // The view itself is hidden at the same moment, in case AppKit
            // dropped the animation from the layer it owns: then at worst a
            // frame late.
            try? await Task.sleep(for: .milliseconds(Int(lead * 1000)))
            guard let self, self.covers == cover, self.covered else { return }
            self.mark.alphaValue = 0
            try? await Task.sleep(for: .seconds(1))
            // Only this cover's own fallback: a later landing keeps its own.
            guard self.covers == cover else { return }
            self.uncover()
        }
    }

    /// Counts covers, so a fallback shows the dot only for its own.
    private var covers = 0

    /// Shows the resting dot again after `coverForSun`. Setup's moon has
    /// settled into the dot's own solid ink over it, so the hairline fades in
    /// round that disc rather than appearing round it at once.
    func uncover() {
        guard covered else { return }
        covered = false
        mark.layer?.removeAnimation(forKey: "cover")
        mark.alphaValue = 1
        if state == .resting { mark.fadeEdgeIn() }
    }

    /// Whether the mark is hidden for setup's landing sun.
    private(set) var covered = false

    /// Shows `notice` for `noticeShown`, then `afterNotice`, unless a
    /// dictation has started meanwhile.
    func show(_ notice: FootState) {
        timedNotice = notice
        state = notice
        noticeEnds?.cancel()
        let wait = noticeWait
        noticeEnds = Task { [weak self] in
            do { try await wait(Self.noticeShown) } catch { return }
            guard !Task.isCancelled, let self, self.state == notice else { return }
            self.timedNotice = nil
            self.state = self.afterNotice()
        }
    }

    /// Shows `next`, what the foot follows calls for now, as dictation's
    /// phase and notice do. A notice from `show` keeps its whole time over
    /// working or rest, and `afterNotice` then says what follows it; a
    /// recording, or another notice, takes its place at once.
    func follow(_ next: FootState) {
        if let timedNotice, state == timedNotice {
            switch next {
            case .resting, .working: return
            case .listening, .notice: break
            }
        }
        state = next
    }

    /// What the foot shows now.
    /// Keyboard health has no caret to anchor to, so its existing slip is
    /// shown at the foot even when the caret indicator is selected.
    var inputProblem: String? {
        didSet { update(choosing: false) }
    }
    /// Whether the key hint shows: the pill and its tooltip, as under the
    /// pointer, for `keyHintShown` after a press too short to dictate, over
    /// the resting dot, until a dictation starts or the dot is taken.
    private var keyHinting = false
    private var keyHintSerial = 0
    static let keyHintShown: Duration = .seconds(2)

    func showKeyHint() {
        guard state == .resting else { return }
        keyHintSerial &+= 1
        let serial = keyHintSerial
        keyHinting = true
        update(choosing: false)
        let wait = noticeWait
        Task { [weak self] in
            do { try await wait(Self.keyHintShown) } catch { return }
            guard let self, self.keyHintSerial == serial else { return }
            self.keyHinting = false
            self.update(choosing: false)
        }
    }

    var presentation: FootPresentation {
        if state == .resting, let inputProblem { return .notice(inputProblem) }
        if state == .resting, keyHinting, !isMoving { return .keyHint }
        return FootPresentation(state: state, hovering: hovering, saysWords: saysWords)
    }

    /// The dot's square in AppKit screen coordinates while the foot paints,
    /// where the dot is now, at the end of an open slip or at rest, for a
    /// popup opened from it.
    var markFrame: CGRect? {
        painting ? dotSquare.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) : nil
    }

    /// The dot's square in the drawing window's coordinates: where it rests,
    /// or at the end of its open slip, where it has gone.
    private var dotSquare: CGRect {
        let centre = slipShowing ? mark.convert(mark.dotCentre, to: panel.contentView) : Self.layout(for: slot).dot
        return CGRect(x: centre.x - Self.reach / 2, y: centre.y - Self.reach / 2, width: Self.reach, height: Self.reach)
    }

    /// The dot's centre on screen at rest, wherever its window is now.
    private var dotOnScreen: CGPoint {
        let dot = Self.layout(for: slot).dot
        return CGPoint(x: panel.frame.minX + dot.x, y: panel.frame.minY + dot.y)
    }

    /// Sizes the drawing window's content for `slot`, puts the mark where
    /// that slot's layout has it, and opens its slip toward the screen's
    /// middle.
    private func arrange(for slot: FootSlot) {
        self.slot = slot
        let layout = Self.layout(for: slot)
        mark.frame.origin = CGPoint(x: layout.dot.x - SunDotView.side / 2, y: layout.dot.y - SunDotView.side / 2)
        mark.opening = switch slot {
        case .bottom: .centre
        case .left: .rightward
        case .right: .leftward
        }
        let room = Self.tooltipRoom(for: slot)
        mark.tooltipRoom = (room.minX - mark.frame.minX, room.maxX - mark.frame.minX)
    }
    /// The slip's last frame and the dot's square in it, still taking clicks
    /// while the slip closes and the dot glides home (`closing`).
    private var closingCover: CGRect?
    private var closings = 0
    /// The pill's frame while it folds back into the dot, taking clicks
    /// until the mark says the dot is back (`SunDotView.onFolded`).
    private var foldingCover: CGRect?
    /// How long a closing slip keeps its clicks: the paper's 260 ms and a
    /// little more for the dot's glide; and how long a slip changing words
    /// keeps its old shape's, the sun's spring glide to its new end.
    static let closing: Duration = .milliseconds(320)
    static let resizing: Duration = .milliseconds(560)

    /// The slip the mark is open into, in the drawing window's coordinates,
    /// while it shows.
    var slipFrame: CGRect? {
        guard slipShowing, let frame = mark.slipFrame else { return nil }
        return mark.convert(frame, to: panel.contentView)
    }

    /// The words the mark opens into now: a notice, or over the listening
    /// sun a microphone that is reconnecting.
    private var shownSlip: FootSlip? {
        if saysWords, state == .listening, let recordingIssue { return FootSlip(text: recordingIssue) }
        if case let .notice(text) = presentation { return FootSlip(text: text) }
        return nil
    }

    /// What the mark grows into in its own place: the pill with the
    /// microphone, with its tooltip where that keeps clear of the focused
    /// field, under the pointer and for the key hint alike.
    private var shownGlyph: SunDotView.Glyph? {
        switch presentation {
        case .hint, .keyHint:
            let key = keyName()
            return SunDotView.Glyph(key: key, tooltip: tooltipClear(key))
        case .rest, .listening, .writing, .notice: return nil
        }
    }

    /// `choosing` lets the foot move to the display under the pointer; one
    /// coming back after it was hidden always may.
    private func update(choosing: Bool) {
        defer { reportWordSpaceChange() }
        guard visible else {
            placed = false
            hideWindows()
            // A hidden target hears nothing of the pointer, so the hint is
            // not kept for when the foot comes back; that asks the pointer
            // afresh.
            hoverSerial &+= 1
            hovering = false
            applyLook()
            return
        }
        // Read before the target shrinks back to the dot: a pointer over
        // the slip when a dictation ends is over the foot, though not over
        // the dot.
        let pointer = desktop.pointer()
        let wasOver = painting && target.frame.contains(pointer)
        if !invites { hovering = false }
        place(choosing: choosing || !placed)
        // Where the foot offers the microphone it follows the pointer
        // itself, since a pointer that stays put enters nothing anew: one
        // still over the foot when the text lands gets the microphone at
        // once, and the first click starts a dictation. One that the target
        // does not reach sees it go after the usual grace.
        if invites, painting, wasOver || target.frame.contains(pointer) {
            hovering = true
            applyLook()
            cover()
            if !target.frame.contains(pointer) { hover(false) }
        } else if hovering, !(invites && painting) {
            hovering = false
            applyLook()
            cover()
        } else {
            applyLook()
            cover()
        }
    }

    private func hideWindows() {
        endMoving()
        // A pointer resting on a foot that hides has left it.
        hoverSerial &+= 1
        painting = false
        panel.orderOut(nil)
        target.orderOut(nil)
        target.buttons = []
    }

    /// The mark's phase and its slip for the state now.
    private func applyLook() {
        panel.appearance = appearance().nsAppearance
        target.appearance = panel.appearance
        if state != .resting {
            arriving = false
            uncover()
        }
        mark.phase = switch state {
        case .resting where arriving: .listening
        case .resting, .notice: .resting
        case .listening: .listening
        case .working: .writing
        }
        if state != .listening, !arriving { mark.level = 0 }
        var shown = shownSlip
        if let slip = shown, !keepsClear(slip) { shown = nil }
        if slipShowing, shown != mark.slip, let frame = slipFrame {
            // The slip closing, or changing words and size, keeps the clicks
            // of where it and its sun were until the sun is where it goes.
            closingCover = frame.union(dotSquare)
            closings &+= 1
            let closing = closings
            let wait = shown == nil ? Self.closing : Self.resizing
            Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, self.closings == closing else { return }
                self.closingCover = nil
                self.cover()
            }
        }
        slipShowing = shown != nil
        if mark.slip != shown { mark.slip = shown }
        let glyph = shownGlyph
        // The pill folding keeps its clicks until it is the dot again.
        if glyph != nil {
            foldingCover = nil
        } else if mark.glyph != nil, !mark.reducesMotion() {
            foldingCover = pillFrame
        }
        if mark.glyph != glyph { mark.glyph = glyph }
        // A tooltip still showing, as one fading out with the folding pill,
        // leaves at once when the field comes under it. The glyph cannot
        // say so then: it is nil before and after.
        if let tip = mark.tooltipShowing,
           !clearOfField(CGRect(x: mark.frame.minX + tip.minX, y: mark.frame.maxY - tip.maxY, width: tip.width, height: tip.height)) {
            mark.dropTooltip()
        }
    }

    /// Tests the same paper and shadow clearance as the rendered slip,
    /// without entering a notice state or starting its timer.
    func canShowWords(_ words: String) -> Bool {
        painting && keepsClear(FootSlip(text: words))
    }

    /// Where the tooltip may stand across the foot's window at `slot`, in
    /// the window's coordinates: 8 points in from either side.
    static func tooltipRoom(for slot: FootSlot) -> (minX: CGFloat, maxX: CGFloat) {
        (8, layout(for: slot).size.width - 8)
    }

    /// The tooltip's frame in the window's coordinates, as the mark places
    /// it: centred over the pill, `tooltipGap` above it, inside its room.
    func tooltipFrame(_ key: String) -> CGRect {
        let dot = Self.layout(for: slot).dot
        let room = Self.tooltipRoom(for: slot)
        let words = FootSlip.tooltipSize(key, fitting: room.maxX - room.minX - 2 * SunDotView.tooltipPadding)
        let width = (words.width + 2 * SunDotView.tooltipPadding).rounded(.up)
        let x = min(max(dot.x - width / 2, room.minX), room.maxX - width)
        let y = dot.y + SunDotView.pillSize.height / 2 + SunDotView.tooltipGap
        return CGRect(x: x, y: y, width: width, height: SunDotView.tooltipHeight)
    }

    /// Whether the tooltip and its float keep clear of the focused field,
    /// as a slip must.
    private func tooltipClear(_ key: String) -> Bool { clearOfField(tooltipFrame(key)) }

    /// Whether `frame`, in the window's coordinates, keeps clear of the
    /// focused field with the float's reach round it.
    private func clearOfField(_ frame: CGRect) -> Bool {
        let onScreen = frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            .insetBy(dx: -FootSlip.shadowReach, dy: -FootSlip.shadowReach)
        return focusedField.map { !$0.insetBy(dx: -Self.margin, dy: -Self.margin).intersects(onScreen) } ?? true
    }

    /// The pill with its hairline, in the window's coordinates, round the
    /// dot where it rests.
    private var pillFrame: CGRect {
        let dot = Self.layout(for: slot).dot
        let size = CGSize(width: SunDotView.pillSize.width + 2 * SunDotView.restEdge, height: SunDotView.pillSize.height + 2 * SunDotView.restEdge)
        return CGRect(x: dot.x - size.width / 2, y: dot.y - size.height / 2, width: size.width, height: size.height)
    }

    private func keepsClear(_ slip: FootSlip) -> Bool {
        let centre = Self.layout(for: slot).dot
        let frame = slip.frame(around: centre, opening: mark.opening)
            .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            .insetBy(dx: -FootSlip.shadowReach, dy: -FootSlip.shadowReach)
        return focusedField.map { !$0.insetBy(dx: -Self.margin, dy: -Self.margin).intersects(frame) } ?? true
    }

    /// Where clicks are taken, in the drawing window's coordinates: the
    /// dot's square, wherever the dot is, with the slip whenever one is open,
    /// under the pointer or not, as for the email being written or a
    /// microphone reconnecting, with a closing slip until it is home, and
    /// with the pill while it shows and while it folds.
    /// Nothing while a notice shows, when a click has nothing to do.
    private var clickable: CGRect? {
        if case .notice = presentation, !isInputProblem { return nil }
        // The pill is taller than the dot's square.
        var square = dotSquare
        if shownGlyph != nil { square = square.union(pillFrame) }
        if let foldingCover { square = square.union(foldingCover) }
        let open = slipFrame.map { square.union($0) } ?? square
        return closingCover.map { open.union($0) } ?? open
    }

    /// Puts the click target over what can be clicked, above the foot.
    private func cover() {
        // A dot in the hand or on its way keeps its target where the press
        // began, which holds the drag's mouse events; it moves once placed.
        guard !isMoving else { return }
        guard painting, let clickable else {
            target.orderOut(nil)
            target.buttons = []
            return
        }
        let origin = panel.frame.origin
        let frame = clickable.offsetBy(dx: origin.x, dy: origin.y)
        target.cover(frame, shown: desktop.showsWindow)
        target.buttons = buttons(over: target.frame)
    }

    /// What VoiceOver offers on the foot: Dictate at rest, and while
    /// listening Stop dictating, with Cancel dictation as its other action,
    /// since the sun has no cancel button of its own. The working sun offers
    /// nothing, as it shows nothing under the pointer.
    private func buttons(over frame: CGRect) -> [FootButton] {
        // Moving the dot is offered at rest, as a drag is.
        let moves = state == .resting ? FootSlot.allCases.filter { $0 != slot } : []
        return switch presentation {
        case .rest, .hint, .keyHint: [FootButton(name: "Dictate", frame: frame, action: .start, moves: moves, help: keyName())]
        case .listening: [FootButton(name: "Stop dictating", frame: frame, action: .done, also: [("Cancel dictation", .cancel)])]
        case .writing: []
        case .notice: isInputProblem ? [FootButton(name: "Dictate", frame: frame, action: .start)] : []
        }
    }

    private var isInputProblem: Bool { state == .resting && inputProblem != nil }

    /// Whether the pointer over the foot turns the mark into the
    /// microphone: at rest only. The listening sun is its own stop button,
    /// and while Intention writes a microphone would promise what a click
    /// cannot do.
    private var invites: Bool {
        switch state {
        case .resting: true
        case .listening, .working: false
        case .notice: !saysWords
        }
    }

    /// The pointer came over the foot or left it. The mark turns into the
    /// microphone once the pointer has rested on it for `hoverDelay`, or at
    /// once for a click, and back a moment after the pointer leaves; a
    /// notice ignores it.
    func hover(_ inside: Bool, at once: Bool = false) {
        hoverSerial &+= 1
        if inside {
            guard invites, !hovering else { return }
            guard !once, hoverDelay > .zero else {
                hovering = true
                applyLook()
                cover()
                return
            }
            let serial = hoverSerial
            Task { [weak self] in
                try? await Task.sleep(for: self?.hoverDelay ?? .zero)
                guard let self, self.hoverSerial == serial, !self.hovering, self.painting, self.invites else { return }
                self.hovering = true
                self.applyLook()
                self.cover()
            }
            return
        }
        let serial = hoverSerial
        Task { [weak self] in
            try? await Task.sleep(for: Self.hoverGrace)
            guard let self, self.hoverSerial == serial, self.hovering else { return }
            self.hovering = false
            self.applyLook()
            self.cover()
        }
    }

    /// A click on the target. On the bare dot, as when the pointer arrived
    /// with the click and no hover came first, it only turns the dot into
    /// the microphone: recording starts from a mark the person can see. On
    /// the microphone it dictates. On the listening sun it ends the
    /// dictation and puts the text in; Escape cancels it. On the working sun
    /// it does nothing.
    func press() {
        switch presentation {
        case .rest: hover(true, at: true)
        case .writing: break
        case .hint, .keyHint: onAction(.start)
        case .listening: onAction(.done)
        case .notice: if isInputProblem { onAction(.start) }
        }
    }

    /// The displays or the Dock changed: the Dock is read again and the foot
    /// placed again. A display gone or rearranged under a dot in the hand or
    /// on its way drops the move, which may have no screen left to finish
    /// on. The checks call this for one foot rather than posting the system's
    /// notice, which every foot alive in a parallel check would hear.
    func screensChanged() {
        dockEdge = desktop.dockEdge()
        endMoving()
        place(choosing: state == .resting)
    }

    /// The press on the resting dot has moved past `dragThreshold` from
    /// `point`, in AppKit screen coordinates: the dot lifts into the hand
    /// and every display shows its slots. Anything but the resting dot,
    /// painted and placed, stays a click, and the answer is false.
    func beginDrag(at point: CGPoint) -> Bool {
        guard state == .resting, painting, !arriving, drag == nil else { return false }
        glide.stop()
        // Taken where it shows, which with the hint open is the slip's end,
        // or on its way there or back: the slip closes at once and the
        // window follows, so the drawn dot stays under the pointer.
        let shown = mark.convert(mark.shownDotCentre, to: panel.contentView)
        let dot = CGPoint(x: panel.frame.minX + shown.x, y: panel.frame.minY + shown.y)
        drag = Drag(grab: CGVector(dx: point.x - dot.x, dy: point.y - dot.y), target: nil)
        hoverSerial &+= 1
        hovering = false
        // A key hint showing goes with the dot taken in the hand.
        keyHintSerial &+= 1
        keyHinting = false
        mark.closeSlipAtOnce()
        applyLook()
        mark.lifted = true
        showSlots()
        dragMoved(to: point)
        return true
    }

    /// The dot follows the pointer, held where it was taken, and the slot
    /// it would land in if let go here, still, shows its dot.
    func dragMoved(to point: CGPoint) {
        guard let current = drag else { return }
        let held = CGPoint(x: point.x - current.grab.dx, y: point.y - current.grab.dy)
        let dot = Self.layout(for: slot).dot
        panel.setFrameOrigin(CGPoint(x: held.x - dot.x, y: held.y - dot.y))
        let target = snap(held, pointer: point, velocity: .zero)
        drag?.target = target
        for (id, window) in slotWindows { window.slots.target = id == target?.display ? target?.slot : nil }
    }

    /// Let go at `point` with the pointer moving at `velocity`, in points a
    /// second: the slots go, and the dot springs into the slot it was
    /// thrown toward on the display under the pointer, which keeps it. The
    /// dot keeps its full ink and float until it lands (`settle`).
    func endDrag(at point: CGPoint, velocity: CGVector) {
        guard let current = drag else { return }
        let held = CGPoint(x: point.x - current.grab.dx, y: point.y - current.grab.dy)
        drag = nil
        hideSlots()
        let screens = desktop.screens()
        guard let landing = snap(held, pointer: point, velocity: velocity), let screen = screens.first(where: { $0.id == landing.display }) else {
            mark.lifted = false
            update(choosing: false)
            return
        }
        display = landing.display
        chose(landing.slot, screen, screens)
        settle(into: landing.slot, on: screen, from: held, velocity: velocity)
    }

    /// Opens the foot's menu at the dot: from `event`, a right click or a
    /// Control-click, or for VoiceOver's Show Menu just below the dot. Its
    /// hint closes first, so the menu does not open over its own words. The
    /// foot's window never activates Intention, so focus stays in the field.
    func openMenu(with event: NSEvent?) {
        guard painting, !isMoving, let menu = menu(), let view = target.contentView else { return }
        hoverSerial &+= 1
        if hovering {
            hovering = false
            applyLook()
            cover()
        }
        if let event {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: CGPoint(x: view.bounds.minX, y: view.bounds.minY), in: view)
        }
    }

    /// VoiceOver's move of the resting dot to `slot` on its display, kept as
    /// a drag's would be, and said aloud once it is on its way.
    func move(to slot: FootSlot) {
        guard state == .resting, painting, !isMoving, let screen = placedScreen, slot != self.slot else { return }
        chose(slot, screen, desktop.screens())
        settle(into: slot, on: screen, from: dotOnScreen, velocity: .zero)
        NSAccessibility.post(element: target, notification: .announcementRequested,
                             userInfo: [.announcement: "Dot moved to the \(slot.title.lowercased())",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The slot chosen in Settings changed: the dot springs to its new place
    /// on the display it is on.
    /// A spring still under way turns toward the new place from where the
    /// dot is; a dot in the hand keeps the drag, whose drop chooses again.
    func slotsChanged() {
        guard visible, placed, drag == nil, let screen = placedScreen, slotFor(screen) != slot || glide.isRunning else { return }
        let from = dotOnScreen
        glide.stop()
        settle(into: slotFor(screen), on: screen, from: from, velocity: .zero)
    }

    /// The slot the dot held at `point` would land in, thrown at `velocity`,
    /// on the display under `pointer`: the hand decides the display, so a dot
    /// taken off its centre and let go just across onto the next display
    /// lands there, and the dot's throw decides the slot.
    private func snap(_ point: CGPoint, pointer: CGPoint, velocity: CGVector) -> FootSnap? {
        let all = desktop.screens().map { (screen: $0, dock: FootPlacement.dock(on: $0, systemEdge: dockEdge)) }
        let under = all.filter { $0.screen.frame.contains(pointer) }
        return FootPlacement.snap(release: point, velocity: velocity, screens: under.isEmpty ? all : under, from: display ?? 0)
    }

    /// The fastest throw the spring starts with, so a wild flick still lands
    /// without a long overshoot.
    nonisolated static let fastestThrow: CGFloat = 2400

    /// Springs the dot from `from` into `slot` on `screen`, or puts it there
    /// at once under Reduce Motion or where nothing paints, then places the
    /// foot as usual, which hides it if the focused field is at that slot.
    private func settle(into slot: FootSlot, on screen: Screen, from: CGPoint, velocity: CGVector) {
        let dock = FootPlacement.dock(on: screen, systemEdge: dockEdge)
        arrange(for: slot)
        let layout = Self.layout(for: slot)
        let end = FootPlacement.dotCentre(for: slot, on: screen, dock: dock)
        // The window takes the slot's shape with the dot where it is now.
        panel.setFrame(CGRect(origin: CGPoint(x: from.x - layout.dot.x, y: from.y - layout.dot.y), size: layout.size), display: true)
        // Landed: a held dot lets go of its ink and float, and the foot is
        // placed as usual.
        let finish = { [weak self] in
            guard let self else { return }
            self.mark.lifted = false
            self.update(choosing: false)
        }
        // Off screen, as in the checks, the display link never fires and the
        // glide lands by its clock (`FootGlide.longest`).
        guard painting, !mark.reducesMotion(), let view = panel.contentView else { return finish() }
        let speed = hypot(velocity.dx, velocity.dy)
        let scale = speed > Self.fastestThrow ? Self.fastestThrow / speed : 1
        let spring = FootSpring.bounded(from: from, to: end, velocity: CGVector(dx: velocity.dx * scale, dy: velocity.dy * scale),
                                        outward: Self.outward(of: slot))
        glide.start(spring, on: view, apply: { [weak self] point in
            self?.panel.setFrameOrigin(CGPoint(x: point.x - layout.dot.x, y: point.y - layout.dot.y))
        }, done: finish)
    }

    /// The way out of the screen at `slot`, toward its edge.
    static func outward(of slot: FootSlot) -> CGVector {
        switch slot {
        case .bottom: CGVector(dx: 0, dy: -1)
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        }
    }

    /// Changes whenever the slots are shown, so the end of an older fade
    /// does not hide slots a newer drag showed.
    private var slotsSerial = 0

    /// Every display's slots, under the dot, arriving from their edges.
    private func showSlots() {
        slotsSerial &+= 1
        let screens = desktop.screens()
        for (id, window) in slotWindows where !screens.contains(where: { $0.id == id }) {
            window.orderOut(nil)
            slotWindows[id] = nil
        }
        for screen in screens {
            let window = slotWindows[screen.id] ?? FootSlotsWindow()
            slotWindows[screen.id] = window
            window.slots.reducesMotion = mark.reducesMotion
            window.cover(screen.frame, centres: FootPlacement.slotCentres(on: screen, dock: FootPlacement.dock(on: screen, systemEdge: dockEdge)))
            window.slots.target = nil
            if desktop.showsWindow { window.orderFrontRegardless() }
            window.slots.arrive()
        }
        if desktop.showsWindow { panel.orderFrontRegardless() }
    }

    /// The slots fade, and their windows go once they have.
    private func hideSlots() {
        let serial = slotsSerial
        for window in slotWindows.values {
            window.slots.target = nil
            window.slots.leave { [weak self, weak window] in
                guard self?.slotsSerial == serial else { return }
                window?.orderOut(nil)
            }
        }
    }

    /// Drops a drag or a spring under way, as when the foot hides, with no
    /// choice made.
    private func endMoving() {
        guard isMoving else { return }
        drag = nil
        glide.stop()
        mark.lifted = false
        hideSlots()
    }

    /// Whether the slots show, for the checks.
    var showsSlots: Bool { drag != nil }

    /// Puts the windows at the foot of a display: the one under the pointer
    /// when `choosing`, otherwise the one it was on, unless that display is
    /// gone. Nothing paints where the focused field reaches the foot.
    private func place(choosing: Bool) {
        defer { reportWordSpaceChange() }
        guard visible, !isMoving else { return }
        guard let screen = Self.screen(among: desktop.screens(), pointer: desktop.pointer(), keeping: choosing ? nil : display) else {
            placed = false
            hideWindows()
            return
        }
        display = screen.id
        placedScreen = screen
        placed = true
        let dock = FootPlacement.dock(on: screen, systemEdge: dockEdge)
        arrange(for: slotFor(screen))
        let frame = Self.frame(for: slot, on: screen, dock: dock)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        guard FootPlacement.isClear(of: focusedField, slot: slot, on: screen, dock: dock) else {
            hovering = false
            hideWindows()
            return
        }
        painting = true
        if desktop.showsWindow, !panel.isVisible { panel.orderFrontRegardless() }
        // The words may now meet the field, as when the Dock moved them up.
        applyLook()
        cover()
        checkCarriesRed()
    }

    /// The sun carries the red unless a Dock may be over it now, or was
    /// within `dockHides`, as it can still be sliding back down.
    private func checkCarriesRed() {
        let instant = now()
        if let placedScreen, FootPlacement.dockMayCover(slot: slot, on: placedScreen, dock: FootPlacement.dock(on: placedScreen, systemEdge: dockEdge),
                                                         pointer: desktop.pointer()) { dockSeen = instant }
        let dockAway = dockSeen.map { instant - $0 >= Self.dockHides } ?? true
        carriesRed = painting && dockAway
    }

    /// Whether a Dock set to hide may have slid up over the foot on
    /// `screen`: the Dock takes no room there, so it hides or sits at a
    /// side, and the pointer is within `dockReveal` of that screen's foot,
    /// where it brings a hidden Dock up. A Dock at the side gives the same
    /// answer, which only puts the red back on the caret dot for a moment.
    static func dockMayCover(on screen: Screen, pointer: CGPoint) -> Bool {
        let dockHides = screen.usable.minY - screen.frame.minY <= margin
        return dockHides && screen.frame.contains(pointer) && pointer.y - screen.frame.minY < dockReveal
    }

    /// The display `kept` while it is still connected, otherwise the one
    /// under the pointer, otherwise the first.
    static func screen(among screens: [Screen], pointer: CGPoint, keeping kept: CGDirectDisplayID?) -> Screen? {
        if let kept, let screen = screens.first(where: { $0.id == kept }) { return screen }
        return screens.first { $0.frame.contains(pointer) } ?? screens.first
    }

    /// The dot's centre at the bottom centre of `screen`: `aboveDock` over
    /// a Dock that stays shown at the bottom, which is outside the usable
    /// area, otherwise `aboveEdge` over the usable area's foot, the
    /// screen's edge or the few points macOS may keep there for bringing
    /// back a hidden Dock.
    static func dotCentre(on screen: Screen) -> CGPoint {
        let usable = screen.usable
        let dockBelow = usable.minY - screen.frame.minY > margin
        return CGPoint(x: usable.midX.rounded(), y: usable.minY + (dockBelow ? aboveDock : aboveEdge))
    }

    /// The drawing window's frame on `screen`.
    static func frame(on screen: Screen) -> CGRect {
        let centre = dotCentre(on: screen)
        return CGRect(origin: CGPoint(x: centre.x - dotInWindow.x, y: centre.y - dotInWindow.y), size: windowSize)
    }

    /// The drawing window's frame at `slot` on `screen`.
    static func frame(for slot: FootSlot, on screen: Screen, dock: FootDock) -> CGRect {
        let centre = FootPlacement.dotCentre(for: slot, on: screen, dock: dock)
        let layout = layout(for: slot)
        return CGRect(origin: CGPoint(x: centre.x - layout.dot.x, y: centre.y - layout.dot.y), size: layout.size)
    }

    /// Where words placed at the foot by others, such as a notice beside no
    /// dot, may begin: above the foot dot, where its own words go.
    static func wordsBottom(on screen: Screen) -> CGFloat {
        dotCentre(on: screen).y + wordsGap
    }

    /// Whether the foot keeps clear of `field`, the focused field's frame
    /// in AppKit screen coordinates: no field, one on another display or
    /// beside the foot's column, or one that ends at least `clearance` plus
    /// `margin` above the Dock's top or the screen's edge. A chat app's
    /// composer at the foot of a full-screen window is not, and then
    /// nothing paints at the foot.
    static func isClear(of field: CGRect?, on screen: Screen) -> Bool {
        guard let field, field.intersects(screen.frame) else { return true }
        let centre = dotCentre(on: screen)
        guard field.minX < centre.x + column, field.maxX > centre.x - column else { return true }
        return field.minY - margin - screen.usable.minY >= clearance
    }
}

extension FootMark.Screen {
    @MainActor init(_ screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let id = number?.uint32Value ?? 0
        self.init(id: id, frame: screen.frame, usable: screen.visibleFrame, key: FootPlacement.displayKey(for: id))
    }
}

/// One of the foot's buttons as VoiceOver finds it, placed in screen
/// coordinates, with any other actions it offers.
struct FootButton {
    var name: String
    var frame: CGRect
    var action: FootAction
    var also: [(name: String, action: FootAction)] = []
    /// The slots VoiceOver can move the dot to, as further actions.
    var moves: [FootSlot] = []
    /// What VoiceOver says after the name when asked: the dictation key.
    var help: String?
}

/// The borderless window that draws the foot. It takes no mouse event at
/// all: clicks on the dot go to `FootTargetWindow` over it, and everywhere
/// else to the app below.
@MainActor
final class FootWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        level = Self.footLevel
        #if DEBUG
        title = "foot surface"
        #endif
    }

    /// One below the Dock's level, for the foot and its click target alike:
    /// above app windows, floating panels and launchers such as Raycast and
    /// Stage Manager's strip, and under a Dock that slides up from hiding,
    /// which would otherwise show the foot over its icons. The caret dot
    /// keeps the status bar's level.
    static let footLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A clear window over the part of the foot that can be clicked, which
/// takes the pointer and clicks for it, as `DotTargetWindow` does for the
/// caret dot. It never becomes key or activates Intention, so a click leaves
/// focus and the caret in the field below. Every point of it takes the
/// mouse, so it covers only the dot, and its slip while the hint shows.
@MainActor
final class FootTargetWindow: NSPanel {
    /// The pointer came over the window, true, or left it, false.
    var onHover: (Bool) -> Void = { _ in }
    /// A click anywhere on it.
    var onPress: () -> Void = {}
    /// A press from VoiceOver on one of `buttons` or one of their actions.
    var onAction: (FootAction) -> Void = { _ in }
    /// A press that moved past `FootMark.dragThreshold`, from where it began
    /// in AppKit screen coordinates; the answer is whether a drag started.
    var onDragBegan: (CGPoint) -> Bool = { _ in false }
    /// The pointer moved during a drag, and where to.
    var onDragMoved: (CGPoint) -> Void = { _ in }
    /// The drag ended there, with the pointer's speed in points a second.
    var onDragEnded: (CGPoint, CGVector) -> Void = { _, _ in }
    /// VoiceOver's move of the dot to a slot.
    var onMove: (FootSlot) -> Void = { _ in }
    /// A right click or Control-click, with its event, or VoiceOver's Show
    /// Menu, without one: open the foot's menu.
    var onMenu: (NSEvent?) -> Void = { _ in }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = FootWindow.footLevel
        // Set explicitly, so the whole window takes the mouse. Left at its
        // default, the window server passes the pointer through any pixel
        // that is fully transparent, as all of this window's are.
        ignoresMouseEvents = false
        #if DEBUG
        title = "foot target"
        #endif
        let view = FootTargetView()
        view.onHover = { [weak self] in self?.onHover($0) }
        view.onPress = { [weak self] in self?.onPress() }
        view.onAction = { [weak self] in self?.onAction($0) }
        view.onDragBegan = { [weak self] in self?.onDragBegan($0) ?? false }
        view.onDragMoved = { [weak self] in self?.onDragMoved($0) }
        view.onDragEnded = { [weak self] in self?.onDragEnded($0, $1) }
        view.onMove = { [weak self] in self?.onMove($0) }
        view.onMenu = { [weak self] in self?.onMenu($0) }
        contentView = view
    }

    /// The foot's buttons, named and placed in screen coordinates, which
    /// VoiceOver finds and presses here, since the drawing has none.
    var buttons: [FootButton] = [] {
        didSet { (contentView as? FootTargetView)?.buttons = buttons }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Moves over `rect`, in AppKit screen coordinates, and shows unless
    /// `shown` is false, as in the checks.
    func cover(_ rect: CGRect, shown: Bool) {
        let frame = rect.integral
        if self.frame != frame { setFrame(frame, display: false) }
        if shown { orderFrontRegardless() }
    }
}

private final class FootTargetView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onPress: () -> Void = {}
    var onAction: (FootAction) -> Void = { _ in }
    var onDragBegan: (CGPoint) -> Bool = { _ in false }
    var onDragMoved: (CGPoint) -> Void = { _ in }
    var onDragEnded: (CGPoint, CGVector) -> Void = { _, _ in }
    var onMove: (FootSlot) -> Void = { _ in }
    var onMenu: (NSEvent?) -> Void = { _ in }
    var buttons: [FootButton] = [] {
        didSet {
            // VoiceOver can keep an element it was given. The same buttons
            // placed again, as on another display, keep theirs and move;
            // others replace them, and a replaced one presses nothing.
            if buttons.map(\.action) == elements.map(\.action), buttons.map(\.moves) == elements.map(\.moves) {
                zip(elements, buttons).forEach { element, button in
                    element.setAccessibilityFrame(button.frame)
                    // The key named in the help can have changed.
                    element.setAccessibilityHelp(button.help)
                }
                return
            }
            elements.forEach { $0.press.active = false }
            elements = buttons.map { button in
                FootButtonElement(button, parent: self, press: FootPress(
                    { [weak self] action in self?.onAction(action) }, move: { [weak self] slot in self?.onMove(slot) },
                    menu: { [weak self] in self?.onMenu(nil) }))
            }
        }
    }
    /// Where the press began, in screen coordinates, while the button is down.
    private var downAt: CGPoint?
    /// Whether the press has moved past `FootMark.dragThreshold` and asked
    /// for a drag, and whether the drag started.
    private var travelled = false
    private var dragging = false
    /// The pointer's latest positions with their times, for the speed it is
    /// let go at.
    private var trail: [(time: TimeInterval, point: CGPoint)] = []
    private var elements: [FootButtonElement] = []

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { elements }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    /// A click acts on the release, so a press that moves past
    /// `FootMark.dragThreshold` can become a drag instead. Where the foot
    /// refuses a drag, as while listening, the press stays a click if it is
    /// let go over the target, however it moved there.
    /// A right click, or a Control-click as the Mac takes it, opens the
    /// foot's menu, and is neither a click nor the start of a drag.
    /// While a left press is held, as during a drag, a right click or a
    /// Control-click is ignored, so the press still ends as it began.
    override func rightMouseDown(with event: NSEvent) {
        guard downAt == nil else { return }
        onMenu(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            guard downAt == nil else { return }
            onMenu(event)
            return
        }
        let point = screenPoint(of: event)
        downAt = point
        travelled = false
        dragging = false
        trail = [(event.timestamp, point)]
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt else { return }
        let point = screenPoint(of: event)
        record(point, at: event.timestamp)
        if !travelled, hypot(point.x - downAt.x, point.y - downAt.y) > FootMark.dragThreshold {
            travelled = true
            dragging = onDragBegan(downAt)
        }
        if dragging { onDragMoved(point) }
    }

    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        let point = screenPoint(of: event)
        record(point, at: event.timestamp)
        downAt = nil
        if dragging {
            dragging = false
            onDragEnded(point, speed())
        } else if !travelled || window?.frame.contains(point) == true {
            onPress()
        }
    }

    private func screenPoint(of event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    private func record(_ point: CGPoint, at time: TimeInterval) {
        trail.append((time, point))
        trail.removeAll { time - $0.time > 0.1 }
    }

    /// The pointer's speed over its last tenth of a second; none when it
    /// stood still before the release.
    private func speed() -> CGVector {
        guard let first = trail.first, let last = trail.last, last.time - first.time > 0.008 else { return .zero }
        let span = CGFloat(last.time - first.time)
        return CGVector(dx: (last.point.x - first.point.x) / span, dy: (last.point.y - first.point.y) / span)
    }
}

/// What pressing one of the foot's buttons does, kept on the main actor so
/// a press that arrives from another queue can reach it there. It goes
/// inactive when the foot's buttons are replaced or it hides, and then
/// presses nothing, even for a press queued before that.
@MainActor
final class FootPress {
    var active = true
    private let action: (FootAction) -> Void
    private let move: (FootSlot) -> Void
    private let menu: () -> Void

    init(_ action: @escaping (FootAction) -> Void, move: @escaping (FootSlot) -> Void = { _ in }, menu: @escaping () -> Void = {}) {
        self.action = action
        self.move = move
        self.menu = menu
    }

    func runMenu() -> Bool {
        guard active else { return false }
        menu()
        return true
    }

    func run(_ action: FootAction) -> Bool {
        guard active else { return false }
        self.action(action)
        return true
    }

    func run(move slot: FootSlot) -> Bool {
        guard active else { return false }
        move(slot)
        return true
    }
}

/// One of the foot's buttons as VoiceOver sees it. Pressing it, or one of
/// its other actions, does what a click does, and like a click it moves no
/// focus.
private final class FootButtonElement: NSAccessibilityElement {
    let action: FootAction
    /// The other actions VoiceOver offers, in `accessibilityCustomActions`'
    /// order, the moves after them.
    private let others: [FootAction]
    let moves: [FootSlot]
    let press: FootPress

    init(_ button: FootButton, parent: NSView, press: FootPress) {
        action = button.action
        others = button.also.map(\.action)
        moves = button.moves
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(button.name)
        setAccessibilityHelp(button.help)
        setAccessibilityFrame(button.frame)
        setAccessibilityParent(parent)
        // A target and selector rather than a closure, so VoiceOver calls
        // back into this element as it does for a press.
        setAccessibilityCustomActions(button.also.map { other in
            NSAccessibilityCustomAction(name: other.name, target: self, selector: #selector(performOther(_:)))
        } + button.moves.map { slot in
            NSAccessibilityCustomAction(name: "Move dot to the \(slot.title.lowercased())", target: self, selector: #selector(performOther(_:)))
        })
    }

    override func accessibilityPerformPress() -> Bool { perform(action) }

    /// VoiceOver's Show Menu opens the foot's menu, as a right click does.
    override func accessibilityPerformShowMenu() -> Bool {
        let press = press
        guard Thread.isMainThread else {
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = press.runMenu() } }
            return true
        }
        return MainActor.assumeIsolated { press.runMenu() }
    }

    @objc private func performOther(_ custom: NSAccessibilityCustomAction) -> Bool {
        guard let index = accessibilityCustomActions()?.firstIndex(where: { $0 === custom }) else { return false }
        if others.indices.contains(index) { return perform(others[index]) }
        let move = index - others.count
        guard moves.indices.contains(move) else { return false }
        let slot = moves[move], press = press
        guard Thread.isMainThread else {
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = press.run(move: slot) } }
            return true
        }
        return MainActor.assumeIsolated { press.run(move: slot) }
    }

    /// Accessibility may call in on any thread. On the main thread the
    /// action runs at once and the answer is whether it was taken; from any
    /// other queue it goes to the main queue, where the button must still
    /// be current, and the answer is only that it was sent.
    private func perform(_ action: FootAction) -> Bool {
        let press = press
        guard Thread.isMainThread else {
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = press.run(action) } }
            return true
        }
        return MainActor.assumeIsolated { press.run(action) }
    }
}
