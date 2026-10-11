import AppKit
import SwiftUI

/// A proposed reply on a sheet of paper at the caret, offered before the
/// person asked for anything. Its first line of text starts where the caret
/// is, so it reads as the words that will land there, and one row under the
/// text says what can be done: Tab accepts or selects the body for a second
/// Tab confirmation, and holding the dictation key and speaking changes it.
/// Typing keeps the card. Only Tab and an Accessibility press accept.
///
/// It never becomes key or main, never takes focus from the field and reads
/// nothing from any app: `ReplyProposal` hands it the text, the key's name
/// and where the caret is, and decides when it shows and what a press means.
/// Two windows make it up, as for the foot mark: the drawing, which takes no
/// mouse event at all, and a clear target offering the Accessibility action.
/// Mouse events never run the acceptance action.
/// It fades in over `fadeIn`, or under reduced motion appears at once. A
/// locked screen or sleeping displays hide it, and it shows nothing until
/// they are back; the controller shows it again then. Nothing about the
/// text is logged.
@MainActor
final class ProposalCard {
    /// Where the card's first line of text starts, in AppKit screen
    /// coordinates: the caret's left edge and top, so the card's padding
    /// hangs outside the field's text edge and the text reads as the words
    /// that will land there. The card is placed from `textOrigin` alone,
    /// its first line 19 points tall whatever the caret's height.
    struct Anchor: Equatable, Sendable {
        var textOrigin: CGPoint
        /// The field's width from the caret to its right edge.
        var bodyWidth: CGFloat
        /// The visible frame of the screen the field is on.
        var screen: CGRect
    }

    /// What the card leaves in view while a second Tab would replace the
    /// selection, in AppKit screen coordinates, so the person sees what
    /// they are agreeing to replace.
    struct KeepClear: Equatable, Sendable {
        /// The body's frame and the selection's together, kept clear
        /// wherever the screen has room.
        var body: CGRect
        /// The part of the selection that shows: the selection's frame where
        /// Accessibility gave one, the body's otherwise, cut to the body's
        /// scroll area and window. Confirmation requires a spot that
        /// leaves all of it visible.
        var selection: CGRect
    }

    /// Room around the text inside the sheet.
    nonisolated static let topPadding: CGFloat = 9
    nonisolated static let bottomPadding: CGFloat = 9
    nonisolated static let sidePadding: CGFloat = 14
    /// About 65 characters of DM Sans at 13.5 points, so a line reads at a
    /// glance.
    nonisolated static let maximumTextWidth: CGFloat = 450
    /// Below this the key row's longest words, or the name of the
    /// longest trigger Settings records, would not fit a line, so a field
    /// this narrow gets no card rather than one that spills out of its
    /// sheet.
    nonisolated static let minimumTextWidth: CGFloat = 200
    /// Opened above the caret, the sheet's bottom edge, padding included,
    /// sits this far above the caret's top edge.
    nonisolated static let aboveGap: CGFloat = 6
    /// Room between the sheet and what a confirmation keeps clear.
    nonisolated static let clearGap: CGFloat = 8
    /// Transparent room around the sheet inside the window, for its shadow.
    nonisolated static let shadowRoom: CGFloat = OverApp.floatRoom
    /// How much bigger than the Tab button the click target is, so the
    /// button is easy to hit.
    nonisolated static let targetOutset = CGSize(width: 4, height: 3)
    /// Seconds the card takes to fade in.
    nonisolated static let fadeIn: TimeInterval = 0.12
    nonisolated static let announcement = "Reply draft ready. Tab puts it in."
    /// What VoiceOver calls the Tab button.
    nonisolated static let buttonName = "Use this draft"

    /// The same row explains the second Tab while the body is selected,
    /// and the card moves off the selection (`keepClear`).
    var confirmingReplacement = false {
        didSet {
            guard oldValue != confirmingReplacement, let shownWith else { return }
            _ = show(text: shownWith.text, dictationKeyName: shownWith.keyName, at: shownWith.anchor)
        }
    }
    /// What a confirmation keeps in view. Set it before
    /// `confirmingReplacement` turns true; it counts only while that is
    /// true, and without it the card stays at its anchor.
    var keepClear: KeepClear?

    /// Tries the confirmation row and placement together. With no clear
    /// spot, keeps the normal card at its existing anchor so the controller
    /// can release the confirmation's Tab without losing the proposal.
    func beginConfirmation(keeping clear: KeepClear?) -> Bool {
        guard let shownWith else { return false }
        keepClear = clear
        confirmingReplacement = true
        guard isShown else {
            confirmingReplacement = false
            keepClear = nil
            _ = show(text: shownWith.text, dictationKeyName: shownWith.keyName, at: shownWith.anchor)
            return false
        }
        return true
    }
    /// While a dictation records, the button and Tab do nothing.
    var acceptsInput = true
    /// Runs only when VoiceOver presses the Accessibility action, while
    /// `acceptsInput` is true. Called on the main actor. The card stays up;
    /// ending it is the controller's.
    var accepted: () -> Void = {}
    /// Runs on the main actor whenever the screen locks or the displays go
    /// to sleep, whether or not a card shows, after hiding a shown one: the
    /// controller lets Tab go and shows the card again later, and an accept
    /// already under way, whose card is gone, is stopped as well.
    var screenLockedOrAsleep: () -> Void = {}
    /// Whether the windows go on screen at all; the checks keep them off
    /// and read what they would show.
    var showsWindow = true
    /// Whether the card fades in. The app follows the system's setting.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Whether a new card says its key row in words rather than pictures:
    /// the first card after setup does, once (`keyWordsShown` records it);
    /// every card after shows the keys as keycaps and a microphone, with
    /// the words kept for VoiceOver. A confirmation always says its words.
    var keyWordsDue: () -> Bool = { false }
    var keyWordsShown: () -> Void = {}
    /// Whether the card on screen says its keys in words.
    private(set) var keyWords = false
    /// The draft that said its keys in words, as its hash, kept across a
    /// hide: the controller hides the card while the body scrolls away,
    /// the field narrows, the screen locks or a confirmation finds no room,
    /// and the same draft comes back in words. A different draft ends it.
    /// A hash, so nothing of the text stays once the card is gone.
    private var wordsDraft: Int?
    /// Light or Dark, as chosen in Settings, read when a card is drawn.
    var appearance: () -> Appearance = { Appearance.current }
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
    /// The appearance the card on screen was drawn in, so showing the same
    /// card again after Light or Dark changed redraws it rather than
    /// keeping the old one.
    private var drawnAppearance: Appearance?

    /// What is shown now, for the checks: the text and the key row's words.
    private(set) var current: (text: String, keys: String)?
    /// How many times the sheet and key row were measured, and how many
    /// times the windows were placed, for the checks.
    private(set) var measurements = 0
    private(set) var placements = 0
    /// The sheet's frame when shown, in screen coordinates, without the
    /// shadow's room.
    private(set) var frame: CGRect? {
        didSet { if frame != oldValue { frameChanged(frame) } }
    }
    /// Publishes only the visible sheet, on show, move and hide. The dot
    /// cannot discover this click-through drawing through AX hit testing.
    var frameChanged: (CGRect?) -> Void = { _ in }
    var isShown: Bool { current != nil }

    /// The drawing and the click target, which the checks read and click
    /// without putting them on screen.
    let panel = ProposalCardPanel()
    let target = ProposalCardTargetWindow()
    private var observers: [NSObjectProtocol] = []
    /// What the card on screen was last shown with. The controller shows it
    /// again on every observation of the caret, about 30 a second, and the
    /// same text and key name at the same anchor change nothing.
    private var shownWith: (text: String, keyName: String, anchor: Anchor, confirming: Bool, keepClear: KeepClear?)?
    /// The sheet's and key row's sizes for the card on screen. Measuring
    /// lays the sheet out in hosting views on the main thread, so it is done
    /// once per text, key name and column width, not on every move.
    private var measured: Measured?
    private var locked = false
    private var screensAsleep = false

    /// The checks hand their own notification centers, so a lock they post
    /// reaches only this card.
    init(screenEvents: NotificationCenter = DistributedNotificationCenter.default(),
         workspaceEvents: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        SetupStyle.registerFonts()
        let watched: [(NotificationCenter, Notification.Name, ScreenEvent)] = [
            (screenEvents, .init("com.apple.screenIsLocked"), .locked),
            (screenEvents, .init("com.apple.screenIsUnlocked"), .unlocked),
            (workspaceEvents, NSWorkspace.screensDidSleepNotification, .asleep),
            (workspaceEvents, NSWorkspace.screensDidWakeNotification, .awake),
        ]
        for (center, name, event) in watched {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.screen(event)
            })
        }
        target.accessibilityPressed = { [weak self] in self?.press() ?? false }
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
        guard let shownWith, let measured, let host = panel.contentView as? NSHostingView<ProposalCardView> else { return }
        let look = appearance()
        drawnAppearance = look
        panel.appearance = look.nsAppearance
        target.appearance = look.nsAppearance
        host.rootView = ProposalCardView(paragraphs: Self.paragraphs(of: shownWith.text), keyName: shownWith.keyName,
                                         textWidth: measured.textWidth, fades: false, confirmingReplacement: shownWith.confirming,
                                         withWords: measured.withWords, appearance: look)
    }

    /// Shows `text` with its first line at `anchor`, in place of anything
    /// shown before, and answers whether it is on screen. Below the caret
    /// when the whole sheet fits inside the screen's visible frame, above
    /// it otherwise, with the sheet's bottom edge, padding included, 6
    /// points above the caret's top edge; when it fits neither way, or the
    /// field is too narrow to read it in, nothing is shown, and a card
    /// shown before goes. The card is never cut. The text column is at most
    /// 450 points and at least 200, the body less 14 points of padding on
    /// each side, so a body narrower than 228 points gets no card.
    /// VoiceOver hears that a draft is ready when the card appears or its
    /// text changes. Shown again with the same text and key name at the
    /// same anchor, it moves and measures nothing. While a confirmation
    /// waits with `keepClear`, the anchor gives only the column's width and
    /// the screen, and the card goes where `confirmationPlacement` puts it.
    @discardableResult
    func show(text: String, dictationKeyName: String, at anchor: Anchor) -> Bool {
        guard !locked, !screensAsleep, var width = Self.textWidth(for: anchor) else {
            hide()
            return false
        }
        panel.appearance = appearance().nsAppearance
        target.appearance = panel.appearance
        let keepClear = confirmingReplacement ? keepClear : nil
        if let shownWith, shownWith.text == text, shownWith.keyName == dictationKeyName, shownWith.anchor == anchor,
           shownWith.confirming == confirmingReplacement, shownWith.keepClear == keepClear {
            if drawnAppearance != appearance() { redrawAppearance() }
            return true
        }
        let paragraphs = Self.paragraphs(of: text)
        // A new draft decides once whether its keys are said in words; the
        // same draft moved, redrawn or back after a hide keeps what it showed.
        let withWords = current?.text == text ? keyWords : wordsDraft == text.hashValue || keyWordsDue()
        var placed: CGRect?
        if let keepClear {
            guard let clear = Self.confirmationPlacement(textWidth: width, keepClear: keepClear, screen: anchor.screen, height: {
                self.measure(paragraphs: paragraphs, text: text, keyName: dictationKeyName, textWidth: $0, withWords: withWords).sheet.height
            }) else {
                hide()
                return false
            }
            placed = clear.sheet
            width = clear.textWidth
        }
        let size = measure(paragraphs: paragraphs, text: text, keyName: dictationKeyName, textWidth: width, withWords: withWords)
        guard let sheet = placed ?? Self.placement(of: size.sheet, at: anchor) else {
            hide()
            return false
        }
        let keys = confirmingReplacement ? "Tab again to replace what's selected" : Self.keyWords(dictationKeyName)
        let isNew = current?.text != text
        let confirmationChanged = shownWith?.confirming != confirmingReplacement
        // The same card moved, as when the body scrolls, keeps its view and
        // its VoiceOver elements, so it neither fades in again nor leaves
        // VoiceOver holding a button that presses nothing.
        let moved = current?.text == text && current?.keys == keys && frame?.size == sheet.size
        current = (text, keys)
        if isNew {
            keyWords = withWords
            if withWords, wordsDraft != text.hashValue { keyWordsShown() }
            wordsDraft = withWords ? text.hashValue : nil
        }
        frame = sheet
        shownWith = (text, dictationKeyName, anchor, confirmingReplacement, keepClear)
        placements += 1
        let button = Self.buttonFrame(size, in: sheet)
        let textArea = CGRect(x: sheet.minX + Self.sidePadding, y: button.maxY,
                              width: width, height: sheet.maxY - Self.topPadding - button.maxY)
        let window = sheet.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom)
        if moved {
            if panel.frame != window { panel.setFrame(window, display: false) }
            target.move(textFrame: textArea, button: button)
            if drawnAppearance != appearance() { redrawAppearance() }
        } else {
            let view = ProposalCardView(paragraphs: paragraphs, keyName: dictationKeyName, textWidth: width, fades: isNew && !reduceMotion(), confirmingReplacement: confirmingReplacement,
                                        withWords: withWords, appearance: appearance())
            panel.install(view, frame: window)
            drawnAppearance = view.appearance
            if isNew {
                target.elements(text: text, textFrame: textArea, button: button)
            } else {
                target.move(textFrame: textArea, button: button)
            }
        }
        target.buttonLabel(confirmingReplacement ? keys : Self.buttonName)
        // The key row's words, read by VoiceOver whether or not they show;
        // a confirmation's are already its label.
        target.buttonHelp(confirmingReplacement ? nil : keys)
        target.cover(button.insetBy(dx: -Self.targetOutset.width, dy: -Self.targetOutset.height))
        if showsWindow {
            panel.orderFrontRegardless()
            target.orderFrontRegardless()
        }
        if isNew || confirmationChanged, let app = NSApp {
            NSAccessibility.post(element: app, notification: .announcementRequested,
                                 userInfo: [.announcement: confirmingReplacement ? keys : Self.announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        return true
    }

    func hide() {
        // A draft measured for a placement that then failed was never
        // current, so its measurement is dropped here first; nothing of
        // the text stays once the card is gone or was never shown.
        shownWith = nil
        measured = nil
        guard current != nil else { return }
        current = nil
        frame = nil
        panel.orderOut(nil)
        target.orderOut(nil)
        target.clear()
        // The view holds the text it showed; nothing of it stays once the
        // card is gone.
        panel.contentView = nil
    }

    /// Whether the drawing still holds a view, for the checks.
    var holdsContent: Bool { panel.contentView != nil }
    /// Whether a measurement of some text is still kept, for the checks.
    var holdsMeasurement: Bool { measured != nil }

    /// The explicit Accessibility press, on the main actor.
    /// Answers whether it was taken: only while a card shows and
    /// `acceptsInput` is true.
    @discardableResult
    func press() -> Bool {
        guard isShown, acceptsInput else { return false }
        accepted()
        return true
    }

    enum ScreenEvent: Sendable {
        case locked, unlocked, asleep, awake
    }

    /// Where the lock and sleep notifications are handed. They are observed
    /// on the main queue, where this acts at once; from any other queue it
    /// goes to the main queue first.
    nonisolated func screen(_ event: ScreenEvent) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(event) } }
            return
        }
        MainActor.assumeIsolated { apply(event) }
    }

    private func apply(_ event: ScreenEvent) {
        switch event {
        case .locked: locked = true
        case .unlocked: locked = false
        case .asleep: screensAsleep = true
        case .awake: screensAsleep = false
        }
        guard event == .locked || event == .asleep else { return }
        if isShown { hide() }
        screenLockedOrAsleep()
    }

    // MARK: - Geometry

    /// The text column's width: at most `maximumTextWidth`, never wider
    /// than the field from the caret less the padding, nor than the
    /// screen. Nil when that leaves less than `minimumTextWidth`.
    nonisolated static func textWidth(for anchor: Anchor) -> CGFloat? {
        let width = min(maximumTextWidth, anchor.bodyWidth - 2 * sidePadding, anchor.screen.width - 2 * sidePadding).rounded(.down)
        return width >= minimumTextWidth ? width : nil
    }

    /// The sheet's frame for a sheet of `size`: its first line of text at
    /// the anchor and the rest running down, or when that does not fit,
    /// its bottom edge `aboveGap` above the caret's top. Either is taken
    /// only when the whole sheet lies inside the visible frame, top and
    /// bottom, after it is moved left or right to stay on the screen. Nil
    /// when it fits neither way, so the card is never cut.
    nonisolated static func placement(of size: CGSize, at anchor: Anchor) -> CGRect? {
        let screen = anchor.screen
        guard size.width <= screen.width else { return nil }
        let x = min(max(anchor.textOrigin.x - sidePadding, screen.minX), screen.maxX - size.width)
        let fits = { (sheet: CGRect) in sheet.minY >= screen.minY && sheet.maxY <= screen.maxY }
        let below = CGRect(x: x, y: anchor.textOrigin.y + topPadding - size.height, width: size.width, height: size.height)
        if fits(below) { return below }
        let above = CGRect(x: x, y: anchor.textOrigin.y + aboveGap, width: size.width, height: size.height)
        if fits(above) { return above }
        return nil
    }

    /// Where the sheet goes while a second Tab would replace the selection:
    /// off the body and the selection, below them where the screen has
    /// room, otherwise beside them, right then left, otherwise above them,
    /// each inside the visible frame. Below and above keep the column's
    /// width and line its text up with the body's left edge; beside, the
    /// column narrows to the room there, down to `minimumTextWidth`, its
    /// top level with theirs. Where none of those leaves the body clear,
    /// the same order is tried around the selection's visible part alone,
    /// so the card may cover the page's own controls around the body but
    /// not what would be replaced. Nil when no spot leaves the visible
    /// selection whole, the selection is not on this screen, or the sheet
    /// fits nowhere on it. The controller then ends confirmation.
    /// `height` measures the sheet for a column width.
    nonisolated static func confirmationPlacement(textWidth: CGFloat, keepClear: KeepClear, screen: CGRect,
                                                  height: (CGFloat) -> CGFloat) -> (sheet: CGRect, textWidth: CGFloat)? {
        let selection = keepClear.selection.intersection(screen)
        guard !selection.isNull else { return nil }
        let width = textWidth + 2 * sidePadding
        let tall = height(textWidth)
        guard width <= screen.width, tall <= screen.height else { return nil }
        let left = { (x: CGFloat, w: CGFloat) in min(max(x, screen.minX), screen.maxX - w) }
        let bottom = { (y: CGFloat, h: CGFloat) in min(max(y, screen.minY), screen.maxY - h) }
        // Each spot around `region` in order, kept on screen across the
        // side it opens on. Never move it back over the selected text.
        func spots(around region: CGRect) -> [(sheet: CGRect, textWidth: CGFloat)] {
            let x = left(region.minX - sidePadding, width)
            let below = CGRect(x: x, y: region.minY - clearGap - tall, width: width, height: tall)
            let above = CGRect(x: x, y: region.maxY + clearGap, width: width, height: tall)
            var found = [(below, textWidth)]
            for right in [true, false] {
                let room = right ? screen.maxX - region.maxX - clearGap : region.minX - clearGap - screen.minX
                let column = min(textWidth, (room - 2 * sidePadding).rounded(.down))
                guard column >= minimumTextWidth else { continue }
                let w = column + 2 * sidePadding, h = column == textWidth ? tall : height(column)
                guard h <= screen.height else { continue }
                let sideX = right ? region.maxX + clearGap : region.minX - clearGap - w
                found.append((CGRect(x: sideX, y: bottom(region.maxY - h, h), width: w, height: h), column))
            }
            found.append((above, textWidth))
            return found
        }
        for region in [keepClear.body.union(keepClear.selection).intersection(screen), selection] {
            if let spot = spots(around: region).first(where: { screen.contains($0.sheet) && !$0.sheet.intersects(region) }) {
                return spot
            }
        }
        return nil
    }

    /// The draft's paragraphs: blank lines separate them, and a single
    /// line break stays a break within one.
    nonisolated static func paragraphs(of text: String) -> [String] {
        var paragraphs: [String] = []
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy(\.isWhitespace) {
                if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
                lines = []
            } else {
                lines.append(String(line))
            }
        }
        if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
        return paragraphs
    }

    /// The key row's words in order, as the checks read them.
    nonisolated static func keyWords(_ keyName: String) -> String {
        "Tab to use this hold \(keyName) and say what to change or type your own"
    }

    /// The sheet's size, padding included, the key row's height and the
    /// Tab button's size, measured for one text, key name and column width.
    private struct Measured {
        let text: String
        let keyName: String
        let textWidth: CGFloat
        let confirming: Bool
        let withWords: Bool
        let sheet: CGSize
        let rowHeight: CGFloat
        let button: CGSize
    }

    private func measure(paragraphs: [String], text: String, keyName: String, textWidth: CGFloat, withWords: Bool) -> Measured {
        if let measured, measured.text == text, measured.keyName == keyName, measured.textWidth == textWidth, measured.confirming == confirmingReplacement,
           measured.withWords == withWords { return measured }
        measurements += 1
        let sheet = NSHostingView(rootView: ProposalCardView.Sheet(paragraphs: paragraphs, keyName: keyName, textWidth: textWidth, confirmingReplacement: confirmingReplacement,
                                                                     withWords: withWords)).fittingSize
        let row = NSHostingView(rootView: ProposalCardView.KeyRow(keyName: keyName, confirmingReplacement: confirmingReplacement, withWords: withWords).frame(width: textWidth)).fittingSize
        let button = NSHostingView(rootView: ProposalCardView.UseButton(withWords: withWords)).fittingSize
        let fresh = Measured(text: text, keyName: keyName, textWidth: textWidth, confirming: confirmingReplacement, withWords: withWords,
                             sheet: CGSize(width: textWidth + 2 * Self.sidePadding, height: sheet.height.rounded(.up)),
                             rowHeight: row.height.rounded(.up), button: CGSize(width: button.width.rounded(.up), height: button.height))
        measured = fresh
        return fresh
    }

    /// The Tab button in screen coordinates: the first group of the key
    /// row, at its top left, the row being the last thing in the sheet.
    private static func buttonFrame(_ measured: Measured, in sheet: CGRect) -> CGRect {
        CGRect(x: sheet.minX + sidePadding, y: sheet.minY + bottomPadding + measured.rowHeight - measured.button.height,
               width: measured.button.width, height: measured.button.height)
    }
}

/// The card's drawing window. It takes no mouse event at all, so a click
/// on the text goes through to whatever is under the card, and it never
/// becomes key or main.
@MainActor
final class ProposalCardPanel: NSPanel {
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
        level = ProposalCardPanel.cardLevel
        #if DEBUG
        title = "proposal card surface"
        #endif
    }

    /// One below the dot's, so the dot sits in front of the card's top
    /// edge as the design draws it, instead of peeking out from behind it;
    /// still above floating panels such as Spotlight (level 23) and below
    /// menus. The popup and the dot's notices, at the dot's level, open
    /// over the card.
    nonisolated static let cardLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func install(_ view: ProposalCardView, frame: CGRect) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        contentView = host
        setFrame(frame, display: false)
    }
}

/// A clear window offering the draft and acceptance action to VoiceOver.
/// It never becomes key or activates Intention, and mouse input accepts nothing.
@MainActor
final class ProposalCardTargetWindow: NSPanel {
    /// The explicit AXPress action, separate from mouse input.
    var accessibilityPressed: () -> Bool = { false }

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
        level = ProposalCardPanel.cardLevel
        // Set explicitly, so the whole window takes the mouse. Left at its
        // default, the window server passes the pointer through any pixel
        // that is fully transparent, as all of this window's are.
        ignoresMouseEvents = false
        #if DEBUG
        title = "proposal card target"
        #endif
        let view = ProposalCardTargetView()
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func cover(_ rect: CGRect) {
        let frame = rect.integral
        if self.frame != frame { setFrame(frame, display: false) }
    }

    /// The draft as static text and the button, in screen coordinates.
    /// A new draft makes new elements; elements from earlier drafts press nothing.
    func elements(text: String, textFrame: CGRect, button: CGRect) {
        guard let view = contentView as? ProposalCardTargetView else { return }
        let press = ProposalCardPress { [weak self] in self?.accessibilityPressed() ?? false }
        view.replace(with: [
            ProposalCardElement(text: text, frame: textFrame, parent: view),
            ProposalCardElement(button: ProposalCard.buttonName, frame: button, parent: view, press: press),
        ])
    }

    /// Moves the elements VoiceOver may hold to the card's new place.
    func move(textFrame: CGRect, button: CGRect) {
        (contentView as? ProposalCardTargetView)?.move([textFrame, button])
    }

    /// Confirmation keeps the button VoiceOver already holds active.
    func buttonLabel(_ label: String) {
        (contentView as? ProposalCardTargetView)?.buttonLabel(label)
    }

    /// What the key row says, read after the button's name, whether the
    /// row shows words or pictures.
    func buttonHelp(_ help: String?) {
        (contentView as? ProposalCardTargetView)?.buttonHelp(help)
    }

    func clear() {
        (contentView as? ProposalCardTargetView)?.replace(with: [])
    }
}

/// The target window's Accessibility container. Mouse input accepts nothing.
final class ProposalCardTargetView: NSView {
    private var elements: [ProposalCardElement] = []

    func replace(with elements: [ProposalCardElement]) {
        self.elements.forEach { $0.press?.active = false }
        self.elements = elements
    }

    func move(_ frames: [CGRect]) {
        zip(elements, frames).forEach { $0.setAccessibilityFrame($1) }
    }

    func buttonLabel(_ label: String) {
        elements.first { $0.press != nil }?.setAccessibilityLabel(label)
    }

    func buttonHelp(_ help: String?) {
        elements.first { $0.press != nil }?.setAccessibilityHelp(help)
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { elements }

    // Absorb the hint's mouse event without forwarding it to acceptance.
    nonisolated override func mouseDown(with event: NSEvent) {}
}

/// What pressing one Tab button element does, kept on the main actor so a
/// press that arrives from another queue can reach it there. It goes
/// inactive when the card's elements are replaced or the card hides, and
/// then presses nothing, even for a press queued before that.
@MainActor
final class ProposalCardPress {
    var active = true
    private let action: () -> Bool

    init(_ action: @escaping () -> Bool) {
        self.action = action
    }

    func run() -> Bool {
        guard active else { return false }
        return action()
    }
}

/// The draft or the Tab button as VoiceOver sees it. Pressing the button
/// invokes only the Accessibility action and moves no focus. One
/// the card no longer shows presses nothing.
final class ProposalCardElement: NSAccessibilityElement {
    /// The button's press; nil for the draft's text.
    let press: ProposalCardPress?

    init(text: String, frame: CGRect, parent: NSView) {
        press = nil
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
        setAccessibilityFrame(frame)
        setAccessibilityParent(parent)
    }

    init(button name: String, frame: CGRect, parent: NSView, press: ProposalCardPress) {
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
        setAccessibilityFrame(frame)
        setAccessibilityParent(parent)
    }

    /// Accessibility may call this on any thread. On the main thread it
    /// presses at once and answers whether the press was taken; from any
    /// other queue the press goes to the main queue, where the element must
    /// still be the card's current one and the card must take input, and
    /// the answer is only that the press was sent.
    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = press.run() } }
            return true
        }
        return MainActor.assumeIsolated { press.run() }
    }
}

/// The card as drawn: flat paper over the mail with the half-point edge and
/// the one float (`paper(floats: true)`), the draft in DM Sans on 19-point lines,
/// then a band one step below the paper holding the key row, where Tab is
/// the one solid key. No title and no close button. Hidden from VoiceOver,
/// which finds the draft and the button on the target window instead.
struct ProposalCardView: View {
    let paragraphs: [String]
    let keyName: String
    let textWidth: CGFloat
    /// Fades in over `ProposalCard.fadeIn`; false under reduced motion,
    /// when the card appears at once.
    let fades: Bool
    var confirmingReplacement = false
    /// Whether the key row says its keys in words (`ProposalCard.keyWordsDue`).
    var withWords = false
    /// Light unless the person chose Dark in Settings.
    var appearance: Appearance = .light
    @State private var shown = false

    nonisolated static let cornerRadius: CGFloat = OverApp.radius
    nonisolated static let lineHeight: CGFloat = 19
    nonisolated static let paragraphSpacing: CGFloat = 7
    /// The draft's size: the spec's 14, on the host's 19-point lines.
    nonisolated static let textSize: CGFloat = 14

    var body: some View {
        Sheet(paragraphs: paragraphs, keyName: keyName, textWidth: textWidth, confirmingReplacement: confirmingReplacement,
              withWords: withWords)
            .paper(radius: Self.cornerRadius, floats: true)
            .opacity(shown || !fades ? 1 : 0)
            .padding(ProposalCard.shadowRoom)
            .appearance(appearance)
            .accessibilityHidden(true)
            .onAppear {
                guard fades else { return }
                withAnimation(.easeOut(duration: ProposalCard.fadeIn)) { shown = true }
            }
    }

    /// What the sheet holds, sized by its text, which `ProposalCard`
    /// measures to place it. The key row's band runs to the sheet's edges;
    /// its row keeps the text's side padding and the sheet's bottom
    /// padding, so the Tab key sits where `ProposalCard` places VoiceOver's
    /// press.
    struct Sheet: View {
        let paragraphs: [String]
        let keyName: String
        let textWidth: CGFloat
        var confirmingReplacement = false
        var withWords = false
        @Environment(\.palette) private var palette

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: ProposalCardView.paragraphSpacing) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(SetupStyle.text(ProposalCardView.textSize, .regular))
                            .lineSpacing(ProposalCardView.lineSpacing)
                            .foregroundStyle(palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(width: textWidth)
                .padding(.top, ProposalCard.topPadding)
                .padding(.bottom, 10)
                .padding(.horizontal, ProposalCard.sidePadding)
                KeyRow(keyName: keyName, confirmingReplacement: confirmingReplacement, withWords: withWords)
                    .frame(width: textWidth, alignment: .leading)
                    .padding(.top, 8)
                    .padding(.bottom, ProposalCard.bottomPadding)
                    .padding(.horizontal, ProposalCard.sidePadding)
                    .background(palette.well.opacity(palette.isNight ? 0.55 : 0.7))
                    .overlay(alignment: .top) { Rectangle().fill(palette.rule).frame(height: 0.5) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The space between two lines of a paragraph that makes them 19
    /// points apart, from DM Sans's own line height, or the system face's
    /// where DM Sans is not available.
    @MainActor static var lineSpacing: CGFloat {
        let font = NSFont(name: "DM Sans", size: textSize) ?? .systemFont(ofSize: textSize)
        return max(0, lineHeight - (font.ascender - font.descender + font.leading))
    }

    /// What the card's keys do, as pictures: the Tab keycap, then the
    /// dictation key's cap with a microphone after it, since holding it
    /// and speaking changes the draft; typing your own needs no sign. The
    /// first card after setup says it in words instead, once: "Tab to use
    /// this", "hold fn and say what to change", "or type your own"
    /// (`withWords`). Tab is the one solid key in every row, the primary
    /// action. A confirmation always says its words, since what it
    /// replaces must be read. Nothing on the card
    /// can be clicked: the keys are named, not offered. In a narrow field
    /// the row wraps between instructions, Tab always first.
    struct KeyRow: View {
        static let font = SetupStyle.text(12, .medium)
        let keyName: String
        var confirmingReplacement = false
        var withWords = false
        @Environment(\.palette) private var palette

        var body: some View {
            FlowRow(lineSpacing: 5) {
                if confirmingReplacement {
                    KeyName(label: "Tab", isSolid: true)
                    Text("again to replace what's selected").foregroundStyle(palette.ink)
                } else if withWords {
                    UseButton(withWords: true)
                    Text("hold").layoutValue(key: FlowGap.self, value: 16)
                    KeyName(label: keyName)
                    Text("and say what to change")
                    Text("or type your own").layoutValue(key: FlowGap.self, value: 16)
                } else {
                    UseButton(withWords: false)
                    KeyName(label: keyName).layoutValue(key: FlowGap.self, value: 16)
                    // Its own piece, so the longest key name in the narrowest
                    // column wraps it to the next line rather than past the edge.
                    MicGlyph().layoutValue(key: FlowGap.self, value: 5)
                }
            }
            .font(Self.font)
            .foregroundStyle(palette.lead)
            .lineLimit(1)
        }
    }

    /// The Tab key, solid, with "to use this" after it on the card that says its
    /// keys in words, which `ProposalCard` also measures on its own to
    /// place VoiceOver's press over it, so it carries the row's font
    /// rather than inheriting it.
    struct UseButton: View {
        var withWords = false
        @Environment(\.palette) private var palette

        var body: some View {
            HStack(spacing: FlowGap.defaultValue + 1) {
                KeyName(label: "Tab", isSolid: true)
                if withWords {
                    Text("to use this")
                        .font(KeyRow.font.weight(.semibold))
                        .foregroundStyle(palette.ink)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    /// A microphone, drawn as true geometry at the small-size rule: a
    /// capsule, the cradle under it, the stem and the foot, at pen 1.5 in
    /// full ink like the keycaps' letters, 12 points tall. Its frame is the
    /// keycap's, face and seat, so the row places both alike: the capsule
    /// stands on the letters' cap height, from their cap line to their
    /// baseline, with the cradle a point below it and the stem and foot
    /// under that. Strokes sit on half pixels
    /// at 2x so their edges land on pixel edges.
    struct MicGlyph: View {
        @Environment(\.palette) private var palette

        var body: some View {
            Shape()
                .stroke(palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 10.5, height: 19.5)
                .accessibilityHidden(true)
        }

        struct Shape: SwiftUI.Shape {
            func path(in rect: CGRect) -> Path {
                let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x, y: rect.minY + y) }
                var path = Path(roundedRect: CGRect(origin: p(3.25, 5.25), size: CGSize(width: 4, height: 6)), cornerRadius: 2)
                path.move(to: p(0.75, 9.5))
                path.addCurve(to: p(5.25, 13.75), control1: p(0.75, 12), control2: p(2.75, 13.75))
                path.addCurve(to: p(9.75, 9.5), control1: p(7.75, 13.75), control2: p(9.75, 12))
                path.move(to: p(5.25, 13.75))
                path.addLine(to: p(5.25, 15.75))
                path.move(to: p(3.25, 15.75))
                path.addLine(to: p(7.25, 15.75))
                return path
            }
        }
    }

    /// A key's name in the key row, drawn as its cap (`InlineKeycap`).
    struct KeyName: View {
        let label: String
        var isSolid = false

        /// Keep modifier combinations inside the narrowest 200 pt column
        /// without changing the shared keycap's type size or construction.
        private var capLabel: String {
            label.components(separatedBy: " + ").map { name in
                switch name {
                case "Control": "Ctrl"
                case "Option": "Opt"
                case "Command": "Cmd"
                default: name
                }
            }.joined(separator: " + ")
        }

        var body: some View {
            InlineKeycap(label: capLabel, isSolid: isSolid).fixedSize()
        }
    }

    /// The room before a child of a `FlowRow` on the same line: a space
    /// of the key row's font between the words of one instruction, so a
    /// key's name sits in its sentence like any other word, unless a child
    /// says more.
    struct FlowGap: LayoutValueKey {
        static let defaultValue: CGFloat = 3
    }

    /// Lays its children in a row and starts a new line when the next would
    /// pass the proposed width. Each line is as tall as its tallest child,
    /// and children are centred on it.
    struct FlowRow: Layout {
        let lineSpacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let lines = lines(width: proposal.width ?? .infinity, subviews: subviews)
            let width = lines.map(\.width).max() ?? 0
            let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
            return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var y = bounds.minY
            for line in lines(width: bounds.width, subviews: subviews) {
                var x = bounds.minX
                for (position, index) in line.members.enumerated() {
                    let size = subviews[index].sizeThatFits(.unspecified)
                    if position > 0 { x += subviews[index][FlowGap.self] }
                    subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                    x += size.width
                }
                y += line.height + lineSpacing
            }
        }

        private struct Line {
            var members: [Int] = []
            var width: CGFloat = 0
            var height: CGFloat = 0
        }

        /// Children whose gap is the default space stay with the one
        /// before them as one instruction, which starts a new line whole
        /// when it does not fit on the current one; only an instruction
        /// wider than a whole line breaks between its words.
        private func lines(width: CGFloat, subviews: Subviews) -> [Line] {
            var lines: [Line] = []
            var line = Line()
            for index in subviews.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let gap = subviews[index][FlowGap.self]
                let startsInstruction = index == subviews.startIndex || gap > FlowGap.defaultValue
                let needed = startsInstruction ? instructionWidth(from: index, subviews: subviews) : size.width
                if !line.members.isEmpty, line.width + gap + needed > width, startsInstruction || line.width + gap + size.width > width {
                    lines.append(line)
                    line = Line()
                }
                line.width += (line.members.isEmpty ? 0 : gap) + size.width
                line.height = max(line.height, size.height)
                line.members.append(index)
            }
            if !line.members.isEmpty { lines.append(line) }
            return lines
        }

        /// The width of the instruction that starts at `start`, with the
        /// default gaps between its words.
        private func instructionWidth(from start: Int, subviews: Subviews) -> CGFloat {
            var width = subviews[start].sizeThatFits(.unspecified).width
            var index = start + 1
            while index < subviews.endIndex, subviews[index][FlowGap.self] <= FlowGap.defaultValue {
                width += subviews[index][FlowGap.self] + subviews[index].sizeThatFits(.unspecified).width
                index += 1
            }
            return width
        }
    }
}
