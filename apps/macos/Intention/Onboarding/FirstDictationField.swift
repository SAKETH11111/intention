import AppKit
import SwiftUI

/// The text field on setup's last page: a real one the person can click
/// into, type in and edit, with Intention's dot above its caret as in an email
/// Intention can write, since the same field later takes the practice reply. Each dictation made on the page is put at the caret once,
/// replacing a selection.
///
/// The page writes the words itself. Intention's inserter and its dot panel
/// are for other apps and refuse Intention's own windows, so that nothing of
/// Intention's, such as the invite code field or the history window, can ever
/// be written into by a dictation; this field is not an exception to that.
struct FirstDictationField: NSViewRepresentable {
    /// The newest words dictated on the page, and when they arrived.
    let words: (text: String, at: Date)?
    let isListening: Bool
    /// While Intention writes the words down or writes the email: the dot
    /// breathes in ink.
    var isWorking = false
    /// Shown while the field is empty.
    let placeholder: String?
    /// What Return does, as the page's main button would. Return never
    /// breaks the line: this is a field for a sentence, and Return ended
    /// setup on this page before it had a field. Option-Return still does.
    var submit: (() -> Void)?
    /// The most lines the field shows before it scrolls, so the page's
    /// actions always stay clear of the sheet.
    var mostLines: CGFloat = 4
    /// Reports only this insertion's exact text and arrival identity to retention.
    var inserted: ((String, Date) -> Void)?
    /// What a click on the dot does: starts a dictation into this field,
    /// or ends the one running, as the dot above an email's caret or the foot dot does.
    /// Nil leaves the dot a drawing that takes no click.
    var dotClicked: (() -> Void)?
    /// Whether a dot stands above the caret: in the practice reply, which
    /// is an email, and not in the plain field of the first dictation,
    /// since Intention shows no caret dot in a plain field.
    var showsDot = true

    /// Set while stills and the hidden demo are drawn. Their window never
    /// has the keyboard, so the field would show neither caret nor dot;
    /// with this set it draws both where they would be.
    nonisolated(unsafe) static var still = false

    func makeNSView(context: Context) -> FieldView { FieldView() }

    func updateNSView(_ view: FieldView, context: Context) {
        view.placeholder = placeholder
        view.submit = submit
        view.dotClicked = dotClicked
        view.showsDot = showsDot
        view.isListening = isListening
        view.isWorking = isWorking
        view.mostLines = mostLines
        view.inserted = inserted
        view.take(words)
    }

    /// Room above the first line for the dot, which stands 15 points above
    /// the caret's top.
    static let headroom: CGFloat = 13

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FieldView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.height(for: width))
    }

    final class FieldView: NSView, NSTextViewDelegate {
        private let text = Field()
        /// Holds the text once it is taller than the field may grow.
        private let scroll = NSScrollView()
        private let dot = DotView()
        /// The most lines the field shows before it scrolls, so that a
        /// long text never pushes the page's buttons out of the window.
        var mostLines: CGFloat = 4 {
            didSet { if mostLines != oldValue { invalidateIntrinsicContentSize() } }
        }
        /// The text is 16 on 24-point lines, and lines after the first sit a
        /// little further apart, so the dot above a caret on a later line
        /// clears the words over it.
        private static let lineHeight: CGFloat = 24
        private static let lineSpacing: CGFloat = 16
        /// When the words last put in the field arrived, so each arrival
        /// is written once.
        private var taken: Date?
        private static let headroom = FirstDictationField.headroom
        private static let font = FirstDictationField.font(16)
        /// The words of the latest arrival, landing one after another, and
        /// when they started.
        private var landing: (ranges: [NSRange], started: CFTimeInterval)?
        private var landingLink: CADisplayLink?

        var placeholder: String? {
            didSet {
                guard placeholder != oldValue else { return }
                text.setAccessibilityPlaceholderValue(placeholder)
                needsDisplay = true
            }
        }
        var submit: (() -> Void)?
        var inserted: ((String, Date) -> Void)?
        var dotClicked: (() -> Void)? {
            didSet { dot.onClick = dotClicked }
        }
        var showsDot = true {
            didSet { if showsDot != oldValue { placeDot() } }
        }
        var isListening = false {
            didSet { if isListening != oldValue { dot.look = look } }
        }
        var isWorking = false {
            didSet { if isWorking != oldValue { dot.look = look } }
        }

        /// The caret dot's look: the ink at 60% at rest, full ink while
        /// Intention listens, since the sun at the foot carries the listening,
        /// and breathing while Intention works.
        private var look: DotView.Look { isListening ? .listening : isWorking ? .working : .resting }

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            text.delegate = self
            text.isRichText = false
            text.importsGraphics = false
            text.allowsUndo = true
            text.drawsBackground = false
            text.font = Self.font
            text.textColor = NSColor(SetupStyle.ink)
            text.insertionPointColor = NSColor(SetupStyle.ink)
            text.textContainerInset = NSSize(width: 0, height: 0)
            text.textContainer?.lineFragmentPadding = 0
            text.textContainer?.widthTracksTextView = true
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            text.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.setAccessibilityLabel("Your first dictation")
            // Lines sit far enough apart that the dot above a caret on a
            // later line clears the words over it.
            let style = NSMutableParagraphStyle()
            style.lineSpacing = Self.lineSpacing
            style.minimumLineHeight = Self.lineHeight
            style.maximumLineHeight = Self.lineHeight
            text.defaultParagraphStyle = style
            text.typingAttributes = [.font: Self.font, .foregroundColor: NSColor(SetupStyle.ink), .paragraphStyle: style]
            text.focusChanged = { [weak self] in self?.placeDot() }
            scroll.documentView = text
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: NSView.boundsDidChangeNotification,
                                                   object: scroll.contentView)
            addSubview(scroll)
            addSubview(dot)
        }

        /// Whether the caret is in the field: it has the keyboard, in the
        /// window that has it. Intention's dot belongs above a caret, so it
        /// shows only then.
        private var hasCaret: Bool {
            FirstDictationField.still || (window?.isKeyWindow == true && window?.firstResponder === text)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The caret is in the field when the page shows, as it would be
            // in an app the person had clicked into.
            window?.makeFirstResponder(text)
            // Only these two, by name: the text view tells its delegate of
            // typing and of the caret moving through the same centre.
            let windowNames = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            for name in windowNames { NotificationCenter.default.removeObserver(self, name: name, object: nil) }
            guard let window else { return }
            for name in windowNames {
                NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
            }
        }

        /// The window gained or lost the keyboard, or the text scrolled.
        @objc private func keyChanged() {
            placeDot()
        }

        override func layout() {
            super.layout()
            scroll.frame = CGRect(x: 0, y: Self.headroom, width: bounds.width, height: max(0, bounds.height - Self.headroom))
            placeDot()
        }

        /// A second layout of the same text, to measure a width without
        /// disturbing the field's own, which the caret is read from.
        private let measuring: (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) = {
            let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer()
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            return (storage, manager, container)
        }()

        func height(for width: CGFloat) -> CGFloat {
            let line = Self.lineHeight
            guard let shown = text.textStorage, shown.length > 0 else { return Self.headroom + line }
            measuring.storage.setAttributedString(shown)
            measuring.container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            measuring.manager.ensureLayout(for: measuring.container)
            let most = mostLines * line + (mostLines - 1) * Self.lineSpacing
            return Self.headroom + min(max(ceil(measuring.manager.usedRect(for: measuring.container).height), line), most)
        }

        /// Puts newly arrived words at the caret, in place of a selection.
        func take(_ words: (text: String, at: Date)?) {
            guard let words, taken.map({ words.at > $0 }) ?? true else { return }
            taken = words.at
            let selection = text.selectedRange()
            let string = text.string as NSString
            let before = string.substring(to: selection.location), after = string.substring(from: NSMaxRange(selection))
            let written = FirstDictation.spaced(words.text, after: before, before: after)
            text.insertText(written, replacementRange: selection)
            inserted?(written, words.at)
            land(NSRange(location: selection.location, length: (written as NSString).length))
        }

        /// The words just put in land one after another, 42 ms apart, each
        /// fading in over 220 ms. The fade is drawn with the layout
        /// manager's temporary attributes, which are not part of the text
        /// or its undo, and any edit ends it at once. Under Reduce Motion,
        /// and in stills, the words are simply there.
        private func land(_ range: NSRange) {
            guard !SetupMotion.isStill, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            finishLanding()
            var ranges: [NSRange] = []
            (text.string as NSString).enumerateSubstrings(in: range, options: .byWords) { _, word, _, _ in ranges.append(word) }
            guard !ranges.isEmpty else { return }
            let started = CACurrentMediaTime()
            landing = (ranges, started)
            step()
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            landingLink = link
            // The link draws the frames between, and only while the window
            // is on a screen that draws; the words are in full ink when the
            // time is up whether or not it drew them.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(SetupMotion.landing(words: ranges.count) * 1000) + 50))
                guard let self, self.landing?.started == started else { return }
                self.finishLanding()
            }
        }

        /// One frame of the landing, until the last word is in.
        @objc private func step() {
            guard let landing, let manager = text.layoutManager else { return finishLanding() }
            let elapsed = CACurrentMediaTime() - landing.started
            let ink = NSColor(SetupStyle.ink)
            let length = (text.string as NSString).length
            for (index, range) in landing.ranges.enumerated() where NSMaxRange(range) <= length {
                let t = min(1, max(0, (elapsed - Double(index) * 0.042) / 0.22))
                // GSAP's power1.out.
                let eased = 1 - (1 - t) * (1 - t)
                manager.addTemporaryAttribute(.foregroundColor, value: ink.withAlphaComponent(eased), forCharacterRange: range)
            }
            if elapsed >= SetupMotion.landing(words: landing.ranges.count) { finishLanding() }
        }

        private func finishLanding() {
            landingLink?.invalidate()
            landingLink = nil
            guard landing != nil else { return }
            landing = nil
            text.layoutManager?.removeTemporaryAttribute(.foregroundColor,
                                                        forCharacterRange: NSRange(location: 0, length: (text.string as NSString).length))
        }

        /// Whether words are landing, for the checks.
        var isLanding: Bool { landing != nil }

        func textDidChange(_ notification: Notification) {
            // An edit while words land ends the landing, so no letter is
            // left part drawn where the edit moved it.
            finishLanding()
            invalidateIntrinsicContentSize()
            needsDisplay = true
            placeDot()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            placeDot()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            submit?()
            return true
        }

        /// Where the caret is, in this view's coordinates, as AppKit places
        /// it: that holds for right-to-left text, combined characters and
        /// a caret at the end of a wrapped line, which glyph boxes do not.
        /// Nil when it has scrolled out of the field.
        private var caret: CGRect? {
            guard let window else { return nil }
            let length = (text.string as NSString).length
            guard length > 0 else {
                // An empty field has no line to measure.
                return CGRect(x: scroll.frame.minX, y: scroll.frame.minY, width: 2,
                              height: text.layoutManager?.defaultLineHeight(for: Self.font) ?? 25)
            }
            let location = min(text.selectedRange().location, length)
            let onScreen = text.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
            let rect = convert(window.convertFromScreen(onScreen), from: nil)
            guard rect.height >= 1, rect.minY >= scroll.frame.minY - 1, rect.maxY <= scroll.frame.maxY + 1 else { return nil }
            return CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
        }

        /// The dot sits above the caret, as in an email Intention can write.
        private func placeDot() {
            // Not without a caret, not over one scrolled out of view, and
            // not in a plain field.
            guard showsDot, hasCaret, let caret else {
                dot.isHidden = true
                if FirstDictationField.still { needsDisplay = true }
                return
            }
            dot.isHidden = false
            // The dot, 10 across, its top 15 above the caret's.
            let edge = OwnHandMark.restEdge, side = DotView.width + 2 * edge
            let frame = CGRect(x: caret.minX + 0.8 - DotView.width / 2 - edge, y: caret.minY + Self.caretInset - 15 - edge,
                               width: side, height: side)
            dot.frame = frame
            if FirstDictationField.still { needsDisplay = true }
        }

        /// The caret's top below its line's: the caret is 20 tall on a
        /// 24-point line.
        static let caretInset: CGFloat = 2

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if text.string.isEmpty, let placeholder {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: FirstDictationField.font(14.5),
                    .foregroundColor: NSColor(SetupStyle.faint),
                ]
                // Beside the caret, on its line, wrapping to a second line
                // when it is long.
                let room = CGRect(x: 6, y: Self.headroom + 3, width: max(0, bounds.width - 6), height: 48)
                (placeholder as NSString).draw(with: room, options: [.usesLineFragmentOrigin], attributes: attributes)
            }
            if FirstDictationField.still, let caret {
                NSColor(SetupStyle.ink).setFill()
                NSBezierPath(roundedRect: Field.caretRect(caret), xRadius: 0.8, yRadius: 0.8).fill()
            }
        }
    }

    /// The text view, saying when the keyboard comes to it or leaves, with
    /// a caret 1.6 wide and 20 tall.
    final class Field: NSTextView {
        var focusChanged: () -> Void = {}

        static func caretRect(_ line: CGRect) -> CGRect {
            CGRect(x: line.minX, y: line.minY + (line.height - 20) / 2, width: 1.6, height: min(20, line.height))
        }

        override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
            super.drawInsertionPoint(in: Self.caretRect(rect), color: color, turnedOn: flag)
        }

        override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
            // The caret's own redraws cover the wider rectangle AppKit
            // would draw it in.
            super.setNeedsDisplay(rect.insetBy(dx: -1, dy: 0), avoidAdditionalLayout: flag)
        }

        override func becomeFirstResponder() -> Bool {
            defer { focusChanged() }
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            defer { DispatchQueue.main.async { [focusChanged] in focusChanged() } }
            return super.resignFirstResponder()
        }
    }

    /// The setup window's text face at its usual weight, as AppKit names it.
    static func font(_ size: CGFloat) -> NSFont {
        NSFontManager.shared.font(withFamily: "DM Sans", traits: [], weight: 6, size: size)
            ?? .systemFont(ofSize: size, weight: .medium)
    }

    /// The same face for SwiftUI text drawn to read as this field's.
    static func swiftUIFont(_ size: CGFloat) -> Font {
        Font(font(size))
    }

    /// Intention's dot, drawn to fill its frame. With `onClick` set it takes a
    /// click, as the dot above an email's caret or the foot dot does, and the pointer
    /// says so over it; without one it is a drawing the click passes through.
    final class DotView: NSView {
        enum Look { case resting, listening, working }

        var look = Look.resting {
            didSet { if look != oldValue { show() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            show()
            // Reduce Motion turned on while the dot breathes stops the
            // breath at once; turned off, it comes back for the rest of the
            // work.
            let changed = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            let center = NSWorkspace.shared.notificationCenter
            observer = (center, center.addObserver(forName: changed, object: nil, queue: .main) { [weak self] _ in
                self?.displayOptionsChanged()
            })
        }

        /// The display options observation, removed with the view.
        nonisolated(unsafe) private var observer: (NotificationCenter, NSObjectProtocol)?

        deinit {
            if let observer { observer.0.removeObserver(observer.1) }
        }

        /// The display options changed. Safe to call from any queue: it
        /// reaches the main actor itself, at once on the main thread and
        /// through the main queue anywhere else.
        nonisolated func displayOptionsChanged() {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.show() } }
                return
            }
            MainActor.assumeIsolated { show() }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// While Intention works, the breath: from full ink to 28% and back
        /// every 1.2 s on a cosine, removed when the work ends. At rest and
        /// while listening the dot is whole, as it is everywhere.
        private func show() {
            guard let layer else { return }
            layer.removeAnimation(forKey: "breath")
            layer.opacity = 1
            guard look == .working, !SetupMotion.isStill, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 1
            breath.toValue = 0.28
            breath.duration = 0.6
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(breath, forKey: "breath")
        }

        /// Whether the dot breathes, for the checks.
        var isBreathing: Bool { layer?.animation(forKey: "breath") != nil }

        var onClick: (() -> Void)? {
            didSet {
                guard (onClick == nil) != (oldValue == nil) else { return }
                window?.invalidateCursorRects(for: self)
            }
        }

        override var isFlipped: Bool { true }

        /// The dot as it rests everywhere: a circle of solid ink inside an
        /// even hairline of paper. The frame holds the hairline, which lies
        /// outside the dot's own width.
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let shape = OwnHandMark.restingDot(diameter: bounds.width - 2 * OwnHandMark.restEdge,
                                               centre: CGPoint(x: bounds.midX, y: bounds.midY))
            for (path, ink) in [(shape.edge, OwnHandMark.restEdgeInk(dark: false)), (shape.core, OwnHandMark.restInk(dark: false))] {
                context.setFillColor(ink.cgColor)
                context.addPath(path)
                context.fillPath()
            }
        }

        /// The dot's own width at body text, its hairline outside it.
        static let width: CGFloat = 10

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            needsDisplay = true
        }

        /// A click lands on the dot with a little room round its ink, as
        /// the dot's own click target gives it in other apps.
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Not while hidden, as when the caret has scrolled out of the
            // field: the text underneath takes the click then.
            guard onClick != nil, !isHiddenOrHasHiddenAncestor, let superview else { return nil }
            let reach = bounds.insetBy(dx: -6, dy: -6)
            return reach.contains(convert(point, from: superview)) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }

        // To VoiceOver the dot is a button while it takes a click, and
        // nothing at all otherwise, as a drawing.
        override func isAccessibilityElement() -> Bool { onClick != nil }
        override func accessibilityRole() -> NSAccessibility.Role? { onClick != nil ? .button : nil }
        override func accessibilityLabel() -> String? { onClick != nil ? "Intention's dot: start or stop dictating" : nil }

        override func accessibilityPerformPress() -> Bool {
            guard let onClick else { return false }
            onClick()
            return true
        }

        override func resetCursorRects() {
            guard onClick != nil else { return }
            addCursorRect(bounds.insetBy(dx: -6, dy: -6), cursor: .pointingHand)
        }
    }
}
