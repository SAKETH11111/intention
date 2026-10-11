import AppKit

/// A stationary transparent surface holding the dot as one Core Animation
/// layer. Moving the dot changes that layer's position only: no bitmap is
/// redrawn, so the window server applies it with the next display frame.
@MainActor
final class DotMarkView: NSView {
    /// What the dot is showing: at rest the field's own ink, red while a
    /// dictation records and the foot mark cannot show it, the field's ink
    /// at full strength while it records and the foot's sun shows it, a
    /// pulse while its text is on its way, an email is being written from
    /// it or a reply proposal is, and the field's ink at full strength while
    /// a reply proposal's card shows.
    enum Look: Equatable {
        case resting, recording, heard, working, proposed
    }

    private var diameter: CGFloat = 0
    private var ink: NSColor?
    private var center: CGPoint?
    private let dot = CAShapeLayer()
    /// A soft copy of the dot behind it while recording, which grows with
    /// the person's voice, so the dot shows Intention hears them.
    private let halo = CAShapeLayer()

    var look = Look.resting {
        didSet { if look != oldValue { applyLook() } }
    }

    /// The voice's smoothed level, about fifty times a second, taken only
    /// while recording. Each eases the halo to its new size over the 20 ms
    /// to the next, so it moves only while the person is heard; under
    /// reduced motion it stays still.
    var level = 0.0 {
        didSet {
            guard look == .recording, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.02)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            halo.transform = Self.haloScale(level)
            CATransaction.commit()
        }
    }

    /// From the dot's own size and a bit, quiet, to under twice it, loud,
    /// which stays clear of the line of text below the caret's top.
    static func haloScale(_ heard: Double) -> CATransform3D {
        let scale = 1.3 + 0.55 * heard
        return CATransform3DMakeScale(scale, scale, 1)
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        dot.isHidden = true
        dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // The first placement may come with no ink, the same nil the layer
        // starts with, so the fill is set here rather than left to the
        // layer's own black.
        dot.fillColor = Self.resting(ink: nil).cgColor
        halo.isHidden = true
        halo.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        halo.fillColor = OwnHandMark.recording.withAlphaComponent(0.22).cgColor
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
    }

    override func updateLayer() {}

    /// AppKit rescales only the layers it creates. The dot's own layer is
    /// matched to the display, or a Retina screen would blur the mark's
    /// edges into a plain round blob.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        dot.contentsScale = window?.backingScaleFactor ?? 2
        halo.contentsScale = dot.contentsScale
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func fill(ink: NSColor?) -> CGColor {
        switch look {
        case .recording: OwnHandMark.recording.cgColor
        case .proposed, .heard: Self.proposed(ink: ink).cgColor
        case .resting, .working: Self.resting(ink: ink).cgColor
        }
    }

    /// The dot's color while a reply proposal's card shows: the field's own
    /// ink at full strength, so the dot reads as the card's; with no ink
    /// known, the same mid grey as at rest.
    static func proposed(ink: NSColor?) -> NSColor {
        ink.map { $0.withAlphaComponent(1) } ?? NSColor(white: 0.5, alpha: 1)
    }

    /// The dot's color at rest: the field's own ink at six tenths, so the
    /// dot reads as the text's own; with no ink known, as in an empty field
    /// before anything is typed or pixels confirm the caret, a mid grey at
    /// full strength, which shows on a light page and a dark one alike.
    /// Until October 7, 2026 an unknown ink gave a faint grey, which on a
    /// white page read as no dot at all.
    static func resting(ink: NSColor?) -> NSColor {
        ink.map { $0.withAlphaComponent(0.6) } ?? NSColor(white: 0.5, alpha: 1)
    }

    /// Red while recording, inside a halo that grows with the voice. While
    /// the text is on its way, which takes under a second, the dot pulses,
    /// or with reduced motion dims; the pulse ends with that look.
    private func applyLook() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.removeAnimation(forKey: "processing")
        dot.opacity = 1
        dot.fillColor = fill(ink: ink)
        halo.transform = Self.haloScale(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0)
        halo.isHidden = look != .recording || center == nil
        if look == .working {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                dot.opacity = 0.4
            } else {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.25
                pulse.duration = 0.45
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.add(pulse, forKey: "processing")
            }
        }
        CATransaction.commit()
    }

    /// What the dot is filled with now, for tests.
    var currentFill: CGColor? { dot.fillColor }

    func clearMark() {
        guard center != nil else { return }
        center = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.isHidden = true
        halo.isHidden = true
        CATransaction.commit()
    }

    /// `ink` nil means the field's text color is not known.
    func place(diameter: CGFloat, ink: NSColor?, center: CGPoint) {
        guard self.diameter != diameter || self.ink != ink || self.center != center else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if self.diameter != diameter {
            let shape = OwnHandMark.dot(diameter: diameter)
            dot.bounds = CGRect(origin: .zero, size: shape.size)
            dot.path = shape.path
            halo.bounds = dot.bounds
            halo.path = shape.path
        }
        if let scale = window?.backingScaleFactor, dot.contentsScale != scale {
            dot.contentsScale = scale
            halo.contentsScale = scale
        }
        if self.ink != ink { dot.fillColor = fill(ink: ink) }
        dot.position = center
        halo.position = center
        dot.isHidden = false
        halo.isHidden = look != .recording
        CATransaction.commit()
        self.diameter = diameter
        self.ink = ink
        self.center = center
        #if DEBUG
        if let window { CaretFixtureMode.dotDraw(frame: window.frame, center: center) }
        #endif
    }
}
