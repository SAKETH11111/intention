import AppKit
import SwiftUI

/// Shows a dictation's text that could not go in, with why in a line above
/// it, a button that copies the text and one that closes, as Wispr Flow's
/// card does. It opens out of the foot mark, above its dot, or beside the
/// caret dot, or above the foot of the screen under the pointer when
/// neither is shown. A reply proposal refused after the
/// person accepted it (`showDraft`) says to copy it, and opens above the
/// caret instead. The text shown is what Copy copies, cut with a line
/// that says so when it runs long. It closes itself after `shown`, and stays
/// while the pointer is over it. Clicks on it never take focus from the
/// field below or activate Intention. Under reduced motion it appears and goes
/// without moving.
///
/// It also says, in one line, that a dictation came back
/// with no words, naming the microphone it recorded from, when the person
/// can do something about it (`showEmpty`): Retry, when its audio waits in
/// history, and Switch mic, which opens Settings. The foot's and the dot's
/// notices about silence say the rest, and take no click.
@MainActor
final class InsertionPopup {
    /// Where the popup opens from, in screen coordinates.
    enum Anchor: Equatable {
        /// The foot mark's dot: the popup opens upward from above it.
        case foot(CGRect)
        /// The dot's click target: the popup opens sideways from beside it.
        case dot(CGRect)
        /// Neither shows: the foot of the screen the pointer is on.
        case screenFoot
        /// A reply proposal's caret: the dot over it and the card, when it
        /// still shows. The popup opens upward from above it, its left
        /// edge at the rect's, over the thread above the reply rather than
        /// the compose's formatting bar and Send row below the body; below
        /// the rect only when the screen leaves no room above.
        case caret(CGRect)
    }

    /// How long the popup stays without the pointer over it.
    static let shown: Duration = .seconds(4)
    /// Lines of a dictation's text the popup shows, and of a reply
    /// proposal's, which is longer and whose sign-off should show when it
    /// fits. Past them the text is cut and says so.
    static let dictationLines = 4
    static let draftLines = 9
    /// What a refused reply proposal's popup says first.
    static let draftTitle = "Couldn't put it in. Copy it instead"
    /// Space between the foot or the dot and the popup.
    static let gap: CGFloat = 6

    /// Puts the text on the clipboard, concealed when it is masked; false
    /// when it could not.
    var copy: (String, _ concealed: Bool) -> Bool = { _, _ in false }
    /// Sends the history entry's kept audio again (`DictationController.retry`).
    var retry: (UUID) -> Void = { _ in }
    /// Opens Settings, where the microphone is chosen.
    var switchMicrophone: () -> Void = {}
    /// Runs when a popup that was shown goes away.
    var ended: () -> Void = {}
    /// Whether the window goes on screen at all; the checks keep it off and
    /// read what it would show.
    var showsWindow = true
    /// Light or Dark, as chosen in Settings, read when a popup opens.
    var appearance: () -> Appearance = { Appearance.current }
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?

    private let panel = PopupPanel()
    private var closes: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var locked = false
    private var screensAsleep = false
    /// What the popup shows in place of words meant for a password field.
    static let hidden = String(repeating: "\u{2022}", count: 8)

    /// What is shown now, for the checks.
    private(set) var current: (words: String, text: String)?
    /// The dictated text and whether it is masked, held only while the
    /// popup is up, for Copy.
    private var copyable: (text: String, concealed: Bool)?
    /// The history entry Retry sends again, while a popup about a
    /// dictation with no words that offers it is up.
    private(set) var retryEntry: UUID?
    /// A popup about a dictation with no words is up, which offers Switch mic.
    private var offersMicrophone = false
    private(set) var hovered = false

    init() {
        SetupStyle.registerFonts()
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.locked = true
                    self?.hide()
                }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = false }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = true
                    self?.hide()
                }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensAsleep = false }
            },
        ]
        panel.hovered = { [weak self] inside in self?.hover(inside) }
        appearanceObserver = NotificationCenter.default.addObserver(forName: .intentionAppearanceChanged, object: nil, queue: .main) { @Sendable [weak self] _ in
            self?.appearanceChanged()
        }
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
        guard isShown, let host = panel.contentView as? NSHostingView<PopupView> else { return }
        let look = appearance()
        panel.appearance = look.nsAppearance
        let view = host.rootView
        // Keeping the host and root type keeps SwiftUI's Copy and arrival state.
        host.rootView = PopupView(content: view.content, opensFrom: view.opensFrom, reduceMotion: view.reduceMotion,
                                  close: view.close, appearance: look)
    }

    var window: NSPanel { panel }

    /// Whether a popup is up.
    var isShown: Bool { current != nil }

    /// Shows why `text` did not go in, opening from `anchor`, in place of
    /// any popup already up.
    func show(_ reason: EditReason, text: String, from anchor: Anchor) {
        guard !locked, !screensAsleep else { return }
        let words = Self.words(for: reason)
        // Words spoken into a password field may be the password, so they
        // are not shown, nor when the app did not answer whether the field
        // is one, nor when an earlier write refused them before the field
        // was looked at; Copy still has them.
        let masked = [.secureField, .targetUnresponsive, .earlierUnsettled, .earlierUnsettledNearby].contains(reason)
        let shown = masked ? Self.hidden : text
        copyable = (text, masked)
        retryEntry = nil
        offersMicrophone = false
        present(.words(why: words, text: shown, cut: PopupView.cuts(shown, lines: Self.dictationLines),
                       copy: { [weak self] in self?.copyText() ?? false }),
                saying: (words, shown), from: anchor)
    }

    /// Shows a reply proposal that could not go in after the person
    /// accepted it: that it did not go in and to copy it, why in a line
    /// under that, the draft exactly as Copy puts it on the clipboard, cut
    /// visibly when it runs past `draftLines`, and Copy.
    func showDraft(_ reason: EditReason, text: String, from anchor: Anchor) {
        guard !locked, !screensAsleep else { return }
        let why = Self.draftWords(for: reason)
        copyable = (text, false)
        retryEntry = nil
        offersMicrophone = false
        present(.draft(title: Self.draftTitle, why: why, text: text, cut: PopupView.cuts(text, lines: Self.draftLines),
                       copy: { [weak self] in self?.copyText() ?? false }),
                saying: ("\(Self.draftTitle). \(why)", text), from: anchor)
    }

    /// Says `line` about a dictation that came back with no words, opening
    /// from `anchor` in place of any popup already up, with Switch mic and,
    /// when `entry` holds the history entry whose audio was kept, Retry.
    func showEmpty(_ line: String, retrying entry: UUID?, from anchor: Anchor) {
        guard !locked, !screensAsleep else { return }
        copyable = nil
        retryEntry = entry
        offersMicrophone = true
        present(.nothing(line: line, retry: entry == nil ? nil : { [weak self] in self?.pressRetry() },
                         switchMicrophone: { [weak self] in self?.pressSwitchMicrophone() }),
                saying: (line, ""), from: anchor)
    }

    /// Retries the dictation the popup is about, as its Retry button does,
    /// and closes it. Nothing once it is gone or offers no Retry. The retry
    /// starts before the popup closes: closing it can leave the app looking
    /// idle, and a waiting update would then relaunch Intention and drop the
    /// audio the retry needs, which is kept only in memory.
    func pressRetry() {
        guard let entry = retryEntry else { return }
        retry(entry)
        hide()
    }

    /// Opens Settings to switch the microphone, as the popup's button does,
    /// and closes it. Nothing once it is gone.
    func pressSwitchMicrophone() {
        guard offersMicrophone else { return }
        hide()
        switchMicrophone()
    }

    private func present(_ content: PopupView.Content, saying said: (words: String, text: String), from anchor: Anchor) {
        current = said
        hovered = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let view = PopupView(content: content, opensFrom: Self.opening(anchor), reduceMotion: reduceMotion,
                             close: { [weak self] in self?.hide() }, appearance: appearance())
        panel.appearance = appearance().nsAppearance
        let size = panel.install(view)
        panel.setFrame(CGRect(origin: Self.origin(of: size, from: anchor, screens: NSScreen.screens.map(\.visibleFrame),
                                                  pointer: NSEvent.mouseLocation),
                              size: size), display: false)
        if showsWindow { panel.orderFrontRegardless() }
        scheduleClose()
        // VoiceOver hears it too, as it does the foot's notices.
        if let app = NSApp {
            NSAccessibility.post(element: app, notification: .announcementRequested,
                                 userInfo: [.announcement: said.words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func hide() {
        closes?.cancel()
        closes = nil
        guard current != nil else { return }
        current = nil
        copyable = nil
        retryEntry = nil
        offersMicrophone = false
        hovered = false
        panel.orderOut(nil)
        // The view holds the words it showed; nothing of them stays once
        // the popup is gone.
        panel.contentView = nil
        ended()
    }

    /// Copies the dictated text, as the Copy button does. False once the
    /// popup is gone, and when the clipboard could not take it.
    @discardableResult
    func copyText() -> Bool {
        guard let copyable else { return false }
        return copy(copyable.text, copyable.concealed)
    }

    /// Whether the popup's window still holds a view, for the checks.
    var holdsContent: Bool { panel.contentView != nil }

    /// The pointer came over the popup or left it. Over it, the popup stays;
    /// once it leaves, the full time starts again.
    func hover(_ inside: Bool) {
        guard current != nil else { return }
        hovered = inside
        if inside {
            closes?.cancel()
            closes = nil
        } else {
            scheduleClose()
        }
    }

    private func scheduleClose() {
        closes?.cancel()
        closes = Task { [weak self] in
            try? await Task.sleep(for: Self.shown)
            if !Task.isCancelled { self?.hide() }
        }
    }

    /// What the popup says for each reason, in a few plain words.
    static func words(for reason: EditReason) -> String {
        switch reason {
        case .noTextField: "Click in the message body, then try again"
        case .secureField: "This is a password field"
        case .ownApp: "Intention doesn't type into its own windows"
        case .permissionMissing: "Intention needs Accessibility to type"
        case .targetUnresponsive, .busy: "The app didn't respond"
        case .appEnded: "The app quit"
        case .focusChanged, .fieldChanged, .composeChanged: "The text box changed as Intention typed"
        case .clipboardBusy: "The clipboard changed as Intention pasted"
        case .pasteUnavailable: "Intention couldn't use the clipboard"
        case .nothingToInsert, .readbackMismatch, .writeUnconfirmed, .unreadableField: "Intention couldn't type it in"
        // The earlier dictation's text may still appear, and this one could
        // have gone in ahead of it. Waiting does not end this hold: the
        // earlier text showing, or the field going, does, so the words name
        // what does help, the Copy button beside them.
        case .earlierUnsettled: "Last dictation here didn't show. Use Copy"
        // Held for at most ten seconds after the earlier write.
        case .earlierUnsettledNearby: "Wait a few seconds, then dictate again"
        }
    }

    /// Why a reply proposal did not go in, in the person's terms: Intention
    /// did not type into the reply, so "as Intention typed" would mislead.
    static func draftWords(for reason: EditReason) -> String {
        switch reason {
        case .focusChanged: "You left the reply before it went in"
        case .fieldChanged, .composeChanged, .readbackMismatch: "The reply changed before it went in"
        case .busy, .targetUnresponsive: "Intention couldn't finish putting it in"
        default: words(for: reason)
        }
    }

    /// Which side of the popup faces the foot or the dot.
    static func opening(_ anchor: Anchor) -> UnitPoint {
        switch anchor {
        case .foot, .screenFoot: .bottom
        case .dot: .leading
        case .caret: .bottomLeading
        }
    }

    /// Centred above the foot's dot; right of the caret dot and centred on
    /// it, or left of it where the right would leave its screen; centred
    /// above the foot mark's words on the screen under the pointer. Kept
    /// within the screen.
    static func origin(of size: CGSize, from anchor: Anchor, screens: [CGRect], pointer: CGPoint) -> CGPoint {
        // Placed as before the float needed more room: by a box with
        // `PopupView.placedRoom` around the card, which then grows to the
        // window by the float's extra room on every side, so the card lands
        // where it always did and stays on its screen.
        let extra = PopupView.shadowRoom - PopupView.placedRoom
        let placed = placedOrigin(of: CGSize(width: size.width - 2 * extra, height: size.height - 2 * extra),
                                  from: anchor, screens: screens, pointer: pointer)
        return CGPoint(x: placed.x - extra, y: placed.y - extra)
    }

    private static func placedOrigin(of size: CGSize, from anchor: Anchor, screens: [CGRect], pointer: CGPoint) -> CGPoint {
        func usable(_ point: CGPoint) -> CGRect {
            screens.first { $0.insetBy(dx: -1, dy: -1).contains(point) } ?? screens.first ?? .zero
        }
        func clamped(_ point: CGPoint, in screen: CGRect) -> CGPoint {
            CGPoint(x: min(max(point.x, screen.minX), screen.maxX - size.width).rounded(),
                    y: min(max(point.y, screen.minY), screen.maxY - size.height).rounded())
        }
        switch anchor {
        case let .foot(dot):
            let screen = usable(CGPoint(x: dot.midX, y: dot.midY))
            return clamped(CGPoint(x: dot.midX - size.width / 2, y: dot.maxY + gap - PopupView.placedRoom), in: screen)
        case let .dot(mark):
            let screen = usable(CGPoint(x: mark.midX, y: mark.midY))
            let y = mark.midY - size.height / 2
            let right = mark.maxX + gap - PopupView.placedRoom
            if right + size.width <= screen.maxX { return clamped(CGPoint(x: right, y: y), in: screen) }
            return clamped(CGPoint(x: mark.minX - gap + PopupView.placedRoom - size.width, y: y), in: screen)
        case .screenFoot:
            let screen = usable(pointer)
            let y = screen.minY + FootMark.aboveEdge + FootMark.wordsGap - PopupView.placedRoom
            return clamped(CGPoint(x: screen.midX - size.width / 2, y: y), in: screen)
        case let .caret(near):
            let screen = usable(CGPoint(x: near.minX, y: near.midY))
            let x = near.minX - PopupView.placedRoom
            let above = near.maxY + gap - PopupView.placedRoom
            if above + size.height <= screen.maxY { return clamped(CGPoint(x: x, y: above), in: screen) }
            return clamped(CGPoint(x: x, y: near.minY - gap + PopupView.placedRoom - size.height), in: screen)
        }
    }
}

/// The popup's borderless window. It never becomes key or main, so a click
/// on its buttons leaves focus and the caret in the field below, and as a
/// non-activating panel it never activates Intention.
private final class PopupPanel: NSPanel {
    var hovered: (Bool) -> Void = { _ in }

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
        // The caret dot's level.
        level = .statusBar
        #if DEBUG
        title = "insertion popup surface"
        #endif
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Puts `view` in the window and answers its size.
    func install(_ view: PopupView) -> CGSize {
        let host = PopupHost(rootView: view)
        host.hovered = { [weak self] in self?.hovered($0) }
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        contentView = host
        return size
    }
}

/// Takes the first click, so a button works without the window becoming
/// key, and reports the pointer coming over the popup and leaving it in any
/// app's turn.
private final class PopupHost: NSHostingView<PopupView> {
    var hovered: (Bool) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["popup"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["popup": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered(false)
    }
}

/// The popup on the over-app paper (`paper(floats: true)`): the drawn cross in the
/// attention colour and why the text did not go in, in one line, a close
/// cross, the text itself in a well, and Copy as a paper seat button that
/// turns into the drawn check and "Copied"; or, for a dictation that came
/// back with no words, the resting dot and the one line the foot would say
/// beside the close cross, then Switch mic as a small seat button and,
/// when its audio was kept, Retry as the Ink action. It arrives as the spec's
/// surfaces do, 280 ms moving 8 points out of the side that faces the foot
/// or the dot, or with reduced motion fades in where it stands.
struct PopupView: View {
    enum Content {
        /// Text that did not go in, why, and Copy. `cut` says the text runs
        /// past the lines shown.
        case words(why: String, text: String, cut: Bool, copy: () -> Bool)
        /// A reply proposal that did not go in: what to do, why, the draft
        /// and Copy.
        case draft(title: String, why: String, text: String, cut: Bool, copy: () -> Bool)
        /// A dictation with no words: what came through and from which
        /// microphone, in one line, a button that opens Settings to switch
        /// the microphone and, when its audio was kept, Retry.
        case nothing(line: String, retry: (() -> Void)?, switchMicrophone: () -> Void)
    }

    let content: Content
    let opensFrom: UnitPoint
    let reduceMotion: Bool
    let close: () -> Void
    /// Light unless the person chose Dark in Settings.
    let appearance: Appearance
    @State private var open = false
    @State private var copied: Bool?

    /// `copiedAtStart` draws Copy as already pressed, for pictures of it.
    init(content: Content, opensFrom: UnitPoint, reduceMotion: Bool, close: @escaping () -> Void,
         appearance: Appearance = .light, copiedAtStart: Bool? = nil) {
        self.content = content
        self.opensFrom = opensFrom
        self.reduceMotion = reduceMotion
        self.close = close
        self.appearance = appearance
        _copied = State(initialValue: copiedAtStart)
    }

    /// Transparent room around the card for its float.
    static let shadowRoom: CGFloat = OverApp.floatRoom
    /// The room `InsertionPopup` places the card with, from before the
    /// float, so the card keeps its place.
    static let placedRoom: CGFloat = 12
    /// The card's width; the text wraps inside it.
    static let width: CGFloat = 380
    /// Room inside the card around its contents, and inside the text's well.
    static let padding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 10)
    static let wellPadding = EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11)

    var body: some View {
        Contents(content: content, close: close, copied: $copied)
            .frame(width: Self.width)
            .paper(radius: OverApp.radius, floats: true)
            .offset(open || reduceMotion ? .zero : arrivalOffset)
            .opacity(open ? 1 : 0)
            .padding(Self.shadowRoom)
            .appearance(appearance)
            .onAppear {
                withAnimation(reduceMotion ? .linear(duration: 0.12) : OverApp.arrive) { open = true }
            }
    }

    /// Where the card starts its arrival: below its place when it opens
    /// upward from the foot or above the caret, beside it when it opens
    /// from the dot.
    private var arrivalOffset: CGSize {
        switch opensFrom {
        case .leading: CGSize(width: -OverApp.rise, height: 0)
        case .trailing: CGSize(width: OverApp.rise, height: 0)
        default: CGSize(width: 0, height: OverApp.rise)
        }
    }

    /// What the card holds, in the palette's colours.
    private struct Contents: View {
        let content: Content
        let close: () -> Void
        @Binding var copied: Bool?
        @Environment(\.palette) private var palette

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                switch content {
                case let .words(why, text, cut, copy):
                    HStack(alignment: .center, spacing: 8) {
                        DrawnCross(size: 9).foregroundStyle(palette.attention)
                        Text(why)
                            .font(SetupStyle.text(13, .semibold))
                            .foregroundStyle(palette.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        closeButton
                    }
                    well(PopupView.preview(text, lines: InsertionPopup.dictationLines))
                    foot(cut: cut, copy: copy)
                case let .draft(title, why, text, cut, copy):
                    HStack(alignment: .top, spacing: 8) {
                        DrawnCross(size: 9).foregroundStyle(palette.attention)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(SetupStyle.text(13, .semibold))
                                .foregroundStyle(palette.ink)
                            Text(why)
                                .font(SetupStyle.text(12.5, .medium))
                                .foregroundStyle(palette.lead)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                        closeButton
                    }
                    well(PopupView.preview(text, lines: InsertionPopup.draftLines))
                    foot(cut: cut, copy: copy)
                case let .nothing(line, retry, switchMicrophone):
                    HStack(alignment: .top, spacing: 8) {
                        RestingDot(diameter: 6)
                            .padding(.top, 10)
                        // Up to two lines, so the microphone's name, which
                        // is what the person needs to read, shows whole;
                        // past that it loses its end, never the sentence.
                        Text(line)
                            .font(SetupStyle.text(13, .semibold))
                            .foregroundStyle(palette.ink)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                        Spacer(minLength: 8)
                        closeButton
                    }
                    HStack(alignment: .center, spacing: 16) {
                        Spacer()
                        // Switching the microphone is the way out either
                        // way, a small seat button; Retry, when its audio
                        // was kept, is the one to press, as the Ink action.
                        Button("Switch mic", action: switchMicrophone)
                            .buttonStyle(SeatButtonStyle())
                            .focusable(false)
                            .accessibilityLabel("Switch the microphone in Settings")
                        if let retry {
                            Button("Retry", action: retry)
                                .buttonStyle(InkActionStyle(size: 24))
                                .focusable(false)
                                .accessibilityLabel("Retry the dictation")
                        }
                    }
                }
            }
            .padding(PopupView.padding)
        }

        /// The text as Copy would put it on the clipboard, in a well one
        /// step below the paper, so it reads as the thing held, not as
        /// the popup's own words.
        private func well(_ text: some View) -> some View {
            text
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PopupView.wellPadding)
                .background(palette.well.opacity(palette.isNight ? 0.6 : 0.75),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.trailing, 4)
        }

        /// Copy, after a line saying the text was cut when it was. Once
        /// copied, the button is the drawn check and the word, and copies
        /// again if pressed.
        private func foot(cut: Bool, copy: @escaping () -> Bool) -> some View {
            HStack(spacing: 10) {
                if cut {
                    Text("Cut short here. Copy has all of it")
                        .font(SetupStyle.text(12, .medium))
                        .foregroundStyle(palette.lead)
                        .lineLimit(1)
                }
                Spacer()
                // One button with one structure whatever it says, so
                // VoiceOver keeps hold of the same element after a copy, as
                // it did of main's: once copied, the check widens in and the
                // seat fades out; nothing is swapped.
                let done = copied == true
                Button { copied = copy() } label: {
                    HStack(spacing: done ? 6 : 0) {
                        DrawnCheck()
                            .frame(width: done ? 16 : 0)
                            .opacity(done ? 1 : 0)
                        Text(done ? "Copied" : copied == false ? "Copy failed" : "Copy")
                    }
                }
                .buttonStyle(SeatButtonStyle(isBare: done))
                .focusable(false)
                .accessibilityLabel(copied == true ? "Copied" : "Copy the text")
                .padding(.trailing, 4)
            }
        }

        /// The hand's cross in the ink at 64 percent, no circle, on a
        /// target large enough to hit.
        private var closeButton: some View {
            Button(action: close) {
                DrawnCross(size: 10).foregroundStyle(palette.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("Close")
        }
    }

    /// The space that sets the text's lines 1.45 times its size apart, from
    /// DM Sans's own line height.
    @MainActor static var previewLineSpacing: CGFloat {
        let font = NSFont(name: "DM Sans", size: 14) ?? .systemFont(ofSize: 14)
        return max(0, 14 * 1.45 - (font.ascender - font.descender + font.leading))
    }

    /// The text as it would be copied, line breaks and blank lines kept,
    /// to at most `lines` lines.
    static func preview(_ text: String, lines: Int?) -> some View {
        Text(text)
            .font(SetupStyle.text(14, .regular))
            .lineSpacing(previewLineSpacing)
            .lineLimit(lines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Whether `text` runs past `lines` lines in the popup. A cut that
    /// falls at a line break draws no ellipsis, so the popup says so in
    /// words instead of leaving a sign-off silently missing.
    @MainActor static func cuts(_ text: String, lines: Int) -> Bool {
        let column = width - padding.leading - padding.trailing - 4 - wellPadding.leading - wellPadding.trailing
        func height(_ limit: Int?) -> CGFloat {
            NSHostingView(rootView: preview(text, lines: limit).frame(width: column)).fittingSize.height
        }
        return height(nil) > height(lines) + 1
    }
}
