import AppKit

/// The sun dot, Intention's mark at the foot of the screen, drawn as Core
/// Animation layers so a change of state never repaints a bitmap. At rest
/// it is a true circle, solid, with an even hairline of the opposite tone
/// round it, so it is found at a glance on any desktop: by day ink inside paper,
/// by night paper inside the night's blue (`restInk`, `restEdgeInk`). The
/// moment a dictation
/// starts it is the gradient sun, springing up past its size
/// with one ripple, so the person sees it is on before they speak. While it
/// records it follows the voice: the disc grows from 16 points in silence
/// toward 24 with the smoothed level, the painting's own bloom in its
/// pigment swells and strengthens with it, a louder sound sends the mark's
/// hand-drawn outline out as a ring, and in silence
/// the sun breathes, so it never looks still while it listens. Once the
/// recording stops it warms toward the accent and breathes, one breath
/// every three seconds with nothing moving, so it never pretends to know
/// how long the words take, and when they land it settles back to the
/// resting dot in 260 ms. By night (`Sky.moon`) the disc is the moon, the
/// same pigment in the lamp's colour.
///
/// An animation runs only while its state needs it: the breaths while
/// listening and writing, a short ease to each new level, a ripple for
/// under a second, and the transitions between states; at rest nothing
/// runs. Under Reduce Motion nothing moves: while listening the sun shows
/// at its size inside the dot's outline in its pigment, and each state
/// cuts to the next. The view draws and nothing else: it takes no mouse event and
/// reads nothing from any app. The onboarding window can show it as it is.
@MainActor
final class SunDotView: NSView {
    enum Phase: Equatable, Sendable {
        case resting, listening, writing
    }

    /// The sun by day, the moon by night (`SkyClock`).
    enum Sky: Equatable, Sendable {
        case sun, moon
    }

    /// The resting dot's width, the caret dot's at body text.
    nonisolated static let restWidth: CGFloat = 13
    /// The hairline round the resting dot, outside its 13 points
    /// (`OwnHandMark.restEdge`).
    nonisolated static let restEdge = OwnHandMark.restEdge
    /// The moon's night hairline, as the resting dot's draws.
    nonisolated static let moonEdge: CGFloat = 1.5
    /// The disc's diameter while it listens.
    nonisolated static let disc: CGFloat = 16
    /// The painting is its disc and a bloom around it: the disc is 230 of
    /// the art's 385 pixels.
    nonisolated static let bloom: CGFloat = 385.0 / 230.0
    /// The square the view needs: everything the listening sun paints, out
    /// to `envelope`.
    nonisolated static let side: CGFloat = 56
    /// How far a ripple's ring travels, its radius at the end.
    nonisolated static let rippleReach: CGFloat = 26
    /// How far the listening sun paints from its centre at most: the bloom
    /// at its loudest at the top of the breath, or a ripple's last ring with
    /// half its last stroke, the dot's outline being a little wider than tall.
    nonisolated static var reach: CGFloat {
        let ring = outline(radius: rippleReach).boundingBox
        let ringReach = max(ring.maxX, -ring.minX, ring.maxY, -ring.minY) + 0.25
        return max(disc * bloom / 2 * SunVoice.look(1).halo * SunVoice.breath, ringReach)
    }
    /// The whole animated mark's radius, in whole points: the foot rests this
    /// far above its floor and needs twice it clear above that, plus the
    /// field's margin (`FootMark.aboveDock`, `clearance`).
    nonisolated static var envelope: CGFloat { reach.rounded(.up) }
    /// The accent the sun warms toward while Intention writes.
    nonisolated static let accent = NSColor(srgbRed: 0xE0 / 255.0, green: 0x78 / 255.0, blue: 0x4F / 255.0, alpha: 1)
    /// The lamp, the moon's colour, drawn when its painting is missing.
    nonisolated static let lamp = NSColor(srgbRed: 0xF2 / 255.0, green: 0xD9 / 255.0, blue: 0xA0 / 255.0, alpha: 1)

    var phase = Phase.resting {
        didSet {
            guard phase != oldValue else { return }
            change(from: oldValue)
            if slip != nil { placeFace(animated: true) }
            // A press shows only on the resting dot, and leaving rest ends
            // it, so a dictation's end never brings a stale press back.
            if phase != .resting { keyPending = false }
        }
    }
    var sky = Sky.sun {
        didSet {
            guard sky != oldValue else { return }
            paint()
        }
    }
    /// The words the mark opens into, under the pointer or for a notice, or
    /// nil for the mark as it is. A slip of the floating paper grows out of
    /// the dot, which glides to its end, in about 300 ms, and closes back
    /// under the dot; under Reduce Motion the slip fades in and out.
    var slip: FootSlip? {
        didSet { if slip != oldValue { morph(from: oldValue) } }
    }
    /// What the mark grows into in its own place instead of a slip, under
    /// the pointer and after a press too short to dictate: the pill with the
    /// microphone, and above it the tooltip naming the dictation key. Nil
    /// for the mark as it is.
    var glyph: Glyph? {
        didSet { if glyph != oldValue { morphGlyph(from: oldValue) } }
    }

    struct Glyph: Equatable, Sendable {
        /// The dictation key's name (`FirstDictation.keycap`), drawn as caps
        /// in the tooltip.
        var key: String
        /// Whether the tooltip shows: only where it keeps clear of the
        /// focused field.
        var tooltip = true
    }

    /// The pill the dot grows into, centred on the dot: 24 by 34 points with
    /// corners of 8, in the dot's ink, with the dot's hairline round it.
    nonisolated static let pillSize = CGSize(width: 24, height: 34)
    nonisolated static let pillRadius: CGFloat = 8
    /// How long the pill takes to fold back into the dot.
    nonisolated static let folding: Duration = .milliseconds(160)
    /// The air between the pill's top and the tooltip.
    nonisolated static let tooltipGap: CGFloat = 6
    /// The tooltip's height and its padding either side of its words.
    nonisolated static let tooltipHeight: CGFloat = 28
    nonisolated static let tooltipPadding: CGFloat = 12

    /// Where the tooltip may stand across, in the view's coordinates: inside
    /// the foot's window, which keeps it on the screen at a side slot.
    var tooltipRoom: (minX: CGFloat, maxX: CGFloat) = (-.infinity, .infinity) {
        didSet {
            guard tooltipRoom != oldValue, let glyph else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            drawTooltip(glyph.key)
            placeTooltip()
            CATransaction.commit()
        }
    }

    /// Which way the slip opens: evenly at the bottom of the screen, toward
    /// the middle at a side.
    var opening = FootSlip.Opening.centre
    /// The slip's frame in the view while it is open, for the clicks and the
    /// focused field.
    var slipFrame: CGRect? {
        slip?.frame(around: CGPoint(x: bounds.midX, y: bounds.midY), opening: opening)
    }
    /// Where the dot sits now, for the checks: its resting centre, or the
    /// end of the open slip.
    var dotCentre: CGPoint {
        guard let frame = slipFrame else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        return FootSlip.dot(in: frame, opening: opening)
    }

    /// The voice's smoothed level, from 0 to 1, about fifty times a second
    /// while a dictation records. Taken only while listening.
    var level = 0.0 {
        didSet { heard(level) }
    }
    /// Increase Contrast, read each time the slip is drawn; the checks set
    /// their own.
    var increasesContrast: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    /// Whether the person holds the resting dot to move it: it grows to
    /// `liftScale` on the hand's spring and settles back when let go, or
    /// under Reduce Motion simply changes size.
    var lifted = false {
        didSet { if lifted != oldValue { lift() } }
    }
    /// Whether the dictation key is down and its hold not yet confirmed: the
    /// resting dot lifts as in the hand, so the press shows before recording
    /// starts, and settles back if the press ends short. Apart from `lifted`,
    /// so either ending leaves the other's lift in place. Taken only at rest.
    var keyPending = false {
        didSet {
            if phase != .resting { keyPending = false }
            if keyPending != oldValue { lift() }
        }
    }
    nonisolated static let liftScale: CGFloat = 1.3
    /// Whether the dot is drawn lifted now, held or pressed.
    private var raised = false
    /// Reduce Motion, read at each change; the checks set their own.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Called on the main actor once a folding pill is the dot again, at the
    /// fold's end or at once when Reduce Motion cuts it short.
    var onFolded: () -> Void = {}
    /// The clock a louder sound is timed by; the checks set their own.
    var now: () -> CFTimeInterval = CACurrentMediaTime
    /// How many ripples have gone out, the start's included, for the checks.
    private(set) var ripples = 0

    /// The resting dot: its hairline's disc, with the dot itself
    /// (`restCore`) over it (`OwnHandMark.restingDot`). Their paths are drawn
    /// at the size the dot shows, the held size included, never scaled by a
    /// transform, so each frame is rasterized at the display's own pixels
    /// whatever the renderer does with a scaled layer; and both are centred
    /// on the layers' origin, which `layout` puts on the pixel grid.
    private let rest = CAShapeLayer()
    private let restCore = CAShapeLayer()
    /// The float's far, soft shadow under the held dot; the near one is the
    /// dot's own.
    private let heldShadow = CALayer()
    /// The mark itself: the dot, the sun and what goes with them, which
    /// glides to the end of an open slip and shrinks a little to sit in it.
    private let face = CALayer()
    /// The slip the mark opens into (`FootSlip`): the floating paper with
    /// its half-point edge, under it the float's near and far shadows, and
    /// the words.
    private let slipLayer = CALayer()
    private let slipBody = CAShapeLayer()
    private let slipNear = CAShapeLayer()
    private let slipFar = CAShapeLayer()
    private let slipWords = CALayer()
    /// Everything that listens, breathing slowly in silence: the halo and
    /// the disc.
    private let breather = CALayer()
    /// The painting's bloom round the disc, in its own pigment, scaled and
    /// strengthened by the voice.
    private let halo = CALayer()
    /// The disc's scale for the voice, apart from the painting's own rise
    /// and settle.
    private let swell = CALayer()
    /// The disc as a whole: its scale and opacity, and the dark mask.
    private let painting = CALayer()
    /// The art inside it, with the warmth and the rim, faded out
    /// under the settle's tint as the disc settles.
    private let art = CALayer()
    /// The warm painting over the plain one, faded in while writing.
    private let warmth = CALayer()
    /// A line round the moon's disc, so the pale lamp reads on a light
    /// desktop: by day a soft brown, by night the resting dot's night-blue
    /// hairline, outside the disc and inside the drawn rings, which vanishes
    /// on a dark desktop and gives the moon its shadow side on a light one.
    /// Hidden for the sun, which reads on every desktop by day.
    private let rim = CAShapeLayer()
    /// Cuts the painting's own bloom to 2 points beyond the disc on every
    /// desktop: drawn on white, it reads as a grey ring on a dark
    /// one and a cream band on a light one, which round the disc makes it
    /// an egg. The bloom in the pigment (`halo`) takes its place.
    private let cut = CAGradientLayer()
    /// The disc in the resting dot's own translucent ink, over the art,
    /// faded in as the art fades out while the disc settles, so the disc
    /// ends in the dot's colour over whatever the desktop is.
    private let settleTint = CAShapeLayer()
    /// Rings in the pigment that a start and a louder sound send out, used
    /// in turn; three is more than can be seen at once.
    private let rings = (0..<3).map { _ in CAShapeLayer() }
    private var nextRing = 0
    /// Under Reduce Motion, the steady ring that says the sun is listening.
    private let steady = CAShapeLayer()
    /// The pill the dot grows into under the pointer: its hairline in the
    /// ground tone, as the dot's, the pill in the dot's ink, and on it the
    /// microphone (`MicGlyph`), its capsule and three strokes, in the
    /// other tone.
    private let mic = CALayer()
    private let pillEdge = CAShapeLayer()
    private let pill = CAShapeLayer()
    private let micHead = CAShapeLayer()
    private let micStrokes = (0..<3).map { _ in CAShapeLayer() }
    /// The tooltip above the pill: the floating paper with its edge, the
    /// float's two shadows, and "Dictate" with the key's caps.
    private let tooltip = CALayer()
    private let tooltipBody = CAShapeLayer()
    private let tooltipNear = CAShapeLayer()
    private let tooltipFar = CAShapeLayer()
    private let tooltipWords = CALayer()
    /// Counts the glyph's folds, so a fold's late swap back to the dot is
    /// dropped once the glyph opens again.
    private var folds = 0
    /// When the voice rises well above where it has been.
    private var voice = SunVoice()
    /// Counts the slip's closes, so a Reduce Motion close's late cut home is
    /// dropped once the slip opens again.
    private var closes = 0
    /// When the last level came, for how long to ease to the next.
    private var lastHeard: CFTimeInterval?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let outer = Self.restWidth + 2 * Self.restEdge
        rest.bounds = CGRect(x: -outer / 2, y: -outer / 2, width: outer, height: outer)
        restCore.bounds = rest.bounds
        restCore.position = .zero
        drawRest(scale: 1)
        rest.addSublayer(restCore)
        let side = Self.disc * Self.bloom
        painting.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        art.frame = painting.bounds
        art.contentsGravity = .resizeAspect
        painting.opacity = 0
        warmth.frame = art.bounds
        warmth.contentsGravity = .resizeAspect
        // The paintings are 160 pixels shown 18 to 80 pixels wide, 2 to 9
        // times smaller by the display, the voice and the slip; sampled from
        // mipmaps their pigment holds still as their size changes.
        [art, warmth, halo].forEach { $0.minificationFilter = .trilinear }
        warmth.opacity = 0
        rim.fillColor = nil
        settleTint.path = CGPath(ellipseIn: CGRect(x: (side - Self.disc) / 2, y: (side - Self.disc) / 2, width: Self.disc, height: Self.disc),
                                 transform: nil)
        settleTint.opacity = 0
        art.addSublayer(warmth)
        art.addSublayer(rim)
        painting.addSublayer(art)
        painting.addSublayer(settleTint)
        halo.bounds = painting.bounds
        halo.contentsGravity = .resizeAspect
        halo.opacity = 0
        halo.setValue(SunVoice.look(0).halo, forKeyPath: "transform.scale")
        for ring in rings {
            ring.fillColor = nil
            ring.lineWidth = 1.5
            ring.lineJoin = .round
            ring.lineCap = .round
            ring.opacity = 0
        }
        steady.path = Self.outline(radius: Self.disc / 2 + 3.5)
        steady.fillColor = nil
        steady.lineWidth = 1.5
        steady.lineJoin = .round
        steady.isHidden = true
        breather.addSublayer(halo)
        swell.addSublayer(painting)
        breather.addSublayer(swell)
        cut.type = .radial
        cut.frame = painting.bounds
        cut.startPoint = CGPoint(x: 0.5, y: 0.5)
        cut.endPoint = CGPoint(x: 1, y: 1)
        cut.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        cut.locations = [0, (Self.disc / 2) / (side / 2), (Self.disc / 2 + 2) / (side / 2)] as [NSNumber]
        // The dot sits under the disc, so it can show while the disc settles
        // over it and is only seen once the disc has gone.
        heldShadow.bounds = rest.bounds
        heldShadow.shadowPath = CGPath(ellipseIn: rest.bounds.insetBy(dx: Self.restWidth * 0.2, dy: Self.restWidth * 0.2), transform: nil)
        heldShadow.shadowOpacity = 0
        rest.shadowOpacity = 0
        face.addSublayer(heldShadow)
        face.addSublayer(rest)
        rings.forEach { face.addSublayer($0) }
        face.addSublayer(steady)
        face.addSublayer(breather)
        for stroke in micStrokes {
            stroke.fillColor = nil
            stroke.lineWidth = MicGlyph.pen
            stroke.lineCap = .round
            stroke.strokeStart = 0.5
            stroke.strokeEnd = 0.5
        }
        ([pillEdge, pill, micHead] + micStrokes).forEach { mic.addSublayer($0) }
        mic.isHidden = true
        tooltipBody.lineWidth = 0.5
        for (shade, blur, drop) in [(tooltipNear, CGFloat(2), CGFloat(2)), (tooltipFar, 24, 12)] {
            shade.shadowRadius = blur / 2
            shade.shadowOffset = CGSize(width: 0, height: drop)
            shade.shadowOpacity = 1
            tooltip.addSublayer(shade)
        }
        tooltip.addSublayer(tooltipBody)
        tooltip.addSublayer(tooltipWords)
        tooltip.opacity = 0
        // The pill above the tooltip, so the tooltip's float falls under it
        // and the pill stays one flat colour.
        face.addSublayer(tooltip)
        face.addSublayer(mic)
        slipLayer.opacity = 0
        slipWords.opacity = 0
        slipWords.contentsGravity = .center
        slipBody.lineWidth = 0.5
        // One float: two shadows of the surface's own shape.
        for (shade, blur, drop) in [(slipNear, CGFloat(2), CGFloat(2)), (slipFar, 24, 12)] {
            shade.shadowRadius = blur / 2
            shade.shadowOffset = CGSize(width: 0, height: drop)
            shade.shadowOpacity = 1
            slipLayer.addSublayer(shade)
        }
        slipLayer.addSublayer(slipBody)
        slipLayer.addSublayer(slipWords)
        // The dot over its slip, so it shows at the slip's end.
        layer?.addSublayer(slipLayer)
        layer?.addSublayer(face)
        rasterize()
        layout()
        paint()
        // Reduce Motion turned on while the sun breathes stops the breath at
        // once; turned off, the breath comes back for the rest of the wait.
        let changed = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        let center = NSWorkspace.shared.notificationCenter
        observer = (center, center.addObserver(forName: changed, object: nil, queue: .main) { [weak self] _ in
            self?.displayOptionsChanged()
        })
    }

    /// The display options observation, removed with the view, since the
    /// onboarding window and the renders make and drop views of their own.
    nonisolated(unsafe) private var observer: (NotificationCenter, NSObjectProtocol)?

    deinit {
        if let observer { observer.0.removeObserver(observer.1) }
    }

    /// The display options changed. Safe to call from any queue: it reaches
    /// the main actor itself, at once on the main thread and through the
    /// main queue anywhere else.
    nonisolated func displayOptionsChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.motionChanged() } }
            return
        }
        MainActor.assumeIsolated { motionChanged() }
    }

    private func motionChanged() {
        // The display options carry Increase Contrast too, which the slip's
        // edges and the tooltip's edge and caps follow.
        if slip != nil { drawSlip() }
        if glyph != nil { drawGlyph() }
        let still = reducesMotion()
        if still {
            layers.forEach { $0.removeAllAnimations() }
            // A microphone folding away is gone at once; one opening is
            // there, its model already at its end.
            if glyph == nil, !mic.isHidden { endFold() }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        listen(still: still, starting: false)
        CATransaction.commit()
        if !still, phase == .writing, !isBreathing {
            painting.add(Self.breath(), forKey: "breath")
        }
    }

    /// Every layer that animates.
    private var layers: [CALayer] { markLayers + [face, slipLayer, slipBody, slipNear, slipFar, slipWords] + micLayers }
    /// The microphone's layers.
    private var micLayers: [CALayer] { [pillEdge, pill, micHead, tooltip] + micStrokes }
    /// The layers of the mark as it is, which a change of phase resets
    /// without touching an open slip.
    private var markLayers: [CALayer] { [rest, restCore, heldShadow, breather, halo, swell, painting, art, warmth, settleTint] + rings }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func updateLayer() {}

    /// The display's pixels to a point: the window's, or 2 out of one; the
    /// checks set their own.
    var backingScale: CGFloat = 2 {
        didSet {
            rasterize()
            if slip != nil { drawSlip() }
            if glyph != nil { drawGlyph() }
            guard backingScale != oldValue else { return }
            layout()
            // The open slip's end moves onto the new pixels in the model
            // alone: a glide under way runs on to its end, and a closing
            // slip's dot keeps to its end until its own cut home.
            guard slip != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            face.transform = faceInSlip
            CATransaction.commit()
        }
    }

    /// Every drawn layer at the display's pixels.
    private func rasterize() {
        ([rest, restCore, painting, art, warmth, rim, settleTint, halo, steady, slipBody, slipNear, slipFar, slipWords,
          pillEdge, pill, micHead, tooltipBody, tooltipNear, tooltipFar, tooltipWords] + rings + micStrokes)
            .forEach { $0.contentsScale = backingScale }
    }

    /// `point` moved to the nearest whole pixel of the window, wherever the
    /// view sits in it. The resting dot is 16 points with its hairline, an
    /// even number of pixels at 1x and 2x, so a centre on a pixel corner puts
    /// its edge the same distance into the pixels on every side and it
    /// anti-aliases evenly all round.
    private func snapped(_ point: CGPoint) -> CGPoint {
        let shown = convert(point, to: nil)
        let grid = CGPoint(x: (shown.x * backingScale).rounded() / backingScale, y: (shown.y * backingScale).rounded() / backingScale)
        return convert(grid, from: nil)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rest.position = snapped(centre)
        heldShadow.position = rest.position
        mic.position = rest.position
        placeTooltip()
        steady.position = centre
        rings.forEach { $0.position = centre }
        // Bounds and position, never frame: these layers carry transforms
        // (the face moved into an open slip, the swell's voice), and setting
        // a moved layer's frame moves it back.
        for layer in [face, slipLayer, slipBody, slipNear, slipFar, breather, swell] {
            layer.bounds = bounds
            layer.position = centre
        }
        halo.position = centre
        painting.position = centre
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backingScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
        if slip != nil { drawSlip() }
        if glyph != nil { drawGlyph() }
    }

    /// The brand's ink, which the held dot takes by day.
    nonisolated static let ink = NSColor(srgbRed: 0x20 / 255.0, green: 0x2A / 255.0, blue: 0x2E / 255.0, alpha: 1)

    /// The held dot's ink: the resting ink at full strength.
    private var heldInk: NSColor { restInk.withAlphaComponent(1) }

    /// The hairline round the resting dot on this desktop
    /// (`OwnHandMark.restEdgeInk`).
    var restEdgeInk: NSColor { OwnHandMark.restEdgeInk(dark: isDark) }

    /// The resting dot's two circles at `scale` times its size.
    private func drawRest(scale: CGFloat) {
        let shape = OwnHandMark.restingDot(diameter: Self.restWidth, scale: scale)
        rest.path = shape.edge
        restCore.path = shape.core
    }

    /// The resting dot as drawn now, for the checks: its two circles, how
    /// much the layers over them scale them, and where its centre shows in
    /// the view.
    var restDrawing: (edge: CGPath?, core: CGPath?, scale: CGFloat, centre: CGPoint) {
        let scale = rest.transform.m11 * restCore.transform.m11 * face.transform.m11
        return (rest.path, restCore.path, scale, CGPoint(x: rest.position.x + face.transform.m41, y: rest.position.y + face.transform.m42))
    }

    /// The lift's animation of the dot's circles, for the checks.
    var liftSteps: [CGPath] { ((restCore.animation(forKey: "lift") as? CAKeyframeAnimation)?.values as? [CGPath]) ?? [] }

    /// The dot taken in the hand or pressed by the key, or let go: to
    /// `liftScale` and back on the
    /// spring of response 0.26 s and damping 0.72 that the design gives what
    /// the hand touches, with the float under it, which comes and goes in
    /// 160 ms, as the slots do. The dot's circles are redrawn at each step of
    /// the spring rather than scaled, so it stays sharp as it grows. Its ink
    /// is already solid at rest, so the ink's own change is a no-op kept for
    /// a dot drawn lighter at rest.
    private func lift() {
        let lifted = self.lifted || keyPending
        guard lifted != raised else { return }
        raised = lifted
        let scale = lifted ? Self.liftScale : 1
        let from = heldShadow.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? (lifted ? 1 : Self.liftScale)
        let fromFill = restCore.presentation()?.fillColor ?? restCore.fillColor
        let shadows: [(CALayer, Float)] = [(rest, isDark ? 0.4 : 0.08), (heldShadow, isDark ? 0.8 : 0.35)]
        let still = reducesMotion()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [rest, restCore, heldShadow] {
            layer.removeAnimation(forKey: "lift")
            layer.removeAnimation(forKey: "shade")
        }
        heldShadow.transform = CATransform3DMakeScale(scale, scale, 1)
        drawRest(scale: scale)
        restCore.removeAnimation(forKey: "ink")
        restCore.fillColor = (lifted ? heldInk : restInk).cgColor
        for (layer, strength) in shadows {
            let start = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
            layer.shadowOpacity = lifted ? strength : 0
            guard !still else { continue }
            let shade = CABasicAnimation(keyPath: "shadowOpacity")
            shade.fromValue = start
            shade.toValue = layer.shadowOpacity
            shade.duration = 0.16
            layer.add(shade, forKey: "shade")
        }
        if !still {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.mass = 1
            spring.stiffness = 584
            spring.damping = 34.8
            spring.fromValue = from
            spring.toValue = scale
            spring.duration = spring.settlingDuration
            heldShadow.add(spring, forKey: "lift")
            // The same spring, sampled at 120 a second, as the circles' paths.
            let sizes = Self.spring(from: from, to: scale, duration: spring.duration)
            let shapes = sizes.map { OwnHandMark.restingDot(diameter: Self.restWidth, scale: $0) }
            for (layer, paths) in [(rest, shapes.map(\.edge)), (restCore, shapes.map(\.core))] {
                let steps = CAKeyframeAnimation(keyPath: "path")
                steps.values = paths
                steps.duration = spring.duration
                steps.calculationMode = .linear
                layer.add(steps, forKey: "lift")
            }
            let ink = CABasicAnimation(keyPath: "fillColor")
            ink.fromValue = fromFill
            ink.toValue = restCore.fillColor
            ink.duration = 0.16
            restCore.add(ink, forKey: "ink")
        }
        CATransaction.commit()
    }

    /// The lift's spring from `from` to `to`, mass 1, stiffness 584 and
    /// damping 34.8 starting at rest, as `CASpringAnimation` runs it, sampled
    /// at 120 a second over `duration`, its last sample `to`.
    nonisolated static func spring(from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> [CGFloat] {
        let natural = 584.0.squareRoot(), ratio = 34.8 / (2 * natural)
        let damped = natural * (1 - ratio * ratio).squareRoot()
        let count = max(2, Int((duration * 120).rounded(.up)) + 1)
        return (0..<count).map { step in
            guard step < count - 1 else { return to }
            let time = duration * Double(step) / Double(count - 1)
            let left = exp(-ratio * natural * time) * (cos(damped * time) + ratio * natural / damped * sin(damped * time))
            return to + (from - to) * CGFloat(left)
        }
    }

    /// Whether an animation is on any layer, for the checks: nothing should
    /// run at rest.
    var isAnimating: Bool {
        layers.contains { !($0.animationKeys() ?? []).isEmpty }
    }

    /// Whether the writing breath runs, for the checks.
    var isBreathing: Bool { painting.animation(forKey: "breath") != nil }
    /// Whether the listening breath runs, for the checks.
    var isBreathingInSilence: Bool { breather.animation(forKey: "breath") != nil }
    /// Whether the slip's words still show, for the checks.
    var slipWordsShow: Bool { slipWords.opacity > 0 && slipWords.contents != nil }
    /// The mark's face: its layer's position and how far its transform
    /// moves it, for the checks.
    var facePosition: CGPoint { face.position }
    var faceOffset: CGPoint { CGPoint(x: face.transform.m41, y: face.transform.m42) }
    /// Whether the outline is morphing between the mark and its slip, for
    /// the checks.
    var isMorphing: Bool { slipBody.animation(forKey: "morph") != nil }
    /// Whether the mark is gliding into or out of a slip, for the checks.
    var isGliding: Bool { face.animation(forKey: "glide") != nil }
    /// Whether the steady ring shows, for the checks.
    var showsSteadyRing: Bool { !steady.isHidden }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The resting dot's ink, solid so it holds against any desktop with its
    /// hairline: the brand's ink by day, its paper by night. Setup's sun
    /// settles into it when it lands while the mark is the moon
    /// (`SetupFlight`).
    var restInk: NSColor { OwnHandMark.restInk(dark: isDark) }

    /// The colours and paintings for the sky and the appearance.
    private func paint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rest.fillColor = restEdgeInk.cgColor
        restCore.fillColor = (raised ? heldInk : restInk).cgColor
        pillEdge.fillColor = restEdgeInk.cgColor
        pill.fillColor = restInk.cgColor
        micHead.fillColor = restEdgeInk.cgColor
        micStrokes.forEach { $0.strokeColor = restEdgeInk.cgColor }
        settleTint.fillColor = restInk.cgColor
        // One float under the held dot, as the slip's: by day
        // ink at 8 and 35 percent, by night black at 40 and the deep night at
        // 80, the far one scaled down to a dot this small.
        rest.shadowColor = isDark ? NSColor.black.cgColor : Self.ink.cgColor
        rest.shadowOffset = CGSize(width: 0, height: 2)
        rest.shadowRadius = 1
        heldShadow.shadowColor = isDark ? NSColor(srgbRed: 2 / 255.0, green: 8 / 255.0, blue: 30 / 255.0, alpha: 1).cgColor : Self.ink.cgColor
        heldShadow.shadowOffset = CGSize(width: 0, height: isDark ? 8 : 6)
        heldShadow.shadowRadius = isDark ? 7 : 5
        // On a light desktop the moon's pigment is laid deeper, so the pale
        // lamp does not sink into a pale background.
        let art = Self.art(sky, deep: sky == .moon && !isDark)
        self.art.contents = art.plain
        warmth.contents = art.warm
        rim.isHidden = sky == .sun
        // By night the hairline is the resting dot's, 1.5 points just outside
        // the disc; by day the old soft line. By night the bloom's cut stays
        // opaque over the hairline and clears half a point past it, so no
        // bloom shows outside the line as a cream band.
        let side = Self.disc * Self.bloom
        let ring = isDark ? Self.disc + Self.moonEdge : Self.disc + 0.5
        rim.path = CGPath(ellipseIn: CGRect(x: (side - ring) / 2, y: (side - ring) / 2, width: ring, height: ring), transform: nil)
        rim.lineWidth = isDark ? Self.moonEdge : 0.75
        rim.strokeColor = isDark ? restEdgeInk.cgColor : NSColor(srgbRed: 0.42, green: 0.33, blue: 0.16, alpha: 0.38).cgColor
        let lined = sky == .moon && isDark
        let held = lined ? Self.disc / 2 + Self.moonEdge : Self.disc / 2
        cut.locations = [0, held / (side / 2), (held + (lined ? 0.5 : 2)) / (side / 2)] as [NSNumber]
        painting.mask = cut
        let pigment = pigment
        halo.contents = Self.bloom(of: art.plain)
        rings.forEach { $0.strokeColor = pigment.cgColor }
        steady.strokeColor = pigment.withAlphaComponent(0.85).cgColor
        CATransaction.commit()
    }

    /// The painting's own colour, for the halo and the rings: the sun's
    /// orange, the moon's lamp, laid deeper on a light desktop as its disc
    /// is. On a dark desktop the sun's is lightened, since a fading ring of
    /// the plain orange over a dark blue reads brown.
    private var pigment: NSColor {
        switch sky {
        case .sun: isDark ? Self.sunLight : Self.sunPigment
        case .moon: isDark ? Self.lamp : Self.deepLamp
        }
    }

    /// The sun painting's orange, sampled across its disc, and lightened.
    nonisolated static let sunPigment = NSColor(srgbRed: 0xFA / 255.0, green: 0x73 / 255.0, blue: 0x2A / 255.0, alpha: 1)
    nonisolated static let sunLight = NSColor(srgbRed: 0xFF / 255.0, green: 0x9E / 255.0, blue: 0x62 / 255.0, alpha: 1)

    /// From `old` to `phase`: the sun springs up as the dot fades and
    /// listens, warms when the recording stops, and settles back into the
    /// dot when the words land.
    private func change(from old: Phase) {
        voice = SunVoice()
        lastHeard = nil
        let still = reducesMotion()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        painting.removeAnimation(forKey: "breath")
        switch phase {
        case .listening, .writing:
            if old == .resting {
                // A lift letting go runs on under the fade, so a dot pressed
                // by the key shrinks as the sun rises rather than jumping.
                for layer in markLayers {
                    for key in layer.animationKeys() ?? [] where !["lift", "shade", "ink"].contains(key) {
                        layer.removeAnimation(forKey: key)
                    }
                }
                warmth.opacity = 0
                rest.opacity = 0
                painting.opacity = 1
                painting.transform = CATransform3DIdentity
                if !still {
                    // The dot fades out over 160 ms as the disc springs up
                    // from half its size about 11% past its own, and is
                    // within 2% of it by 240 ms, where setup's landing sun
                    // fades out over it (`SetupFlight`).
                    rest.add(Self.fade(from: 1, to: 0, duration: 0.16), forKey: "fade")
                    let rise = CASpringAnimation(keyPath: "transform.scale")
                    rise.mass = 1
                    rise.stiffness = 520
                    rise.damping = 26
                    rise.fromValue = 0.5
                    rise.toValue = 1
                    rise.duration = rise.settlingDuration
                    painting.add(rise, forKey: "rise")
                }
            }
            listen(still: still, starting: old == .resting)
            let warm: Float = phase == .writing ? 1 : 0
            if warmth.opacity != warm {
                warmth.opacity = warm
                if !still { warmth.add(Self.fade(from: 1 - warm, to: warm, duration: 0.3), forKey: "warm") }
            }
            if phase == .writing, !still {
                // Starting as the warmth settles.
                let breath = Self.breath()
                breath.beginTime = CACurrentMediaTime() + 0.4
                painting.add(breath, forKey: "breath")
            }
        case .resting:
            // The warmth stays on the settling disc, which hides it once gone.
            listen(still: still, starting: false)
            painting.removeAllAnimations()
            rest.opacity = 1
            painting.opacity = 0
            painting.transform = CATransform3DIdentity
            if !still {
                // The disc shrinks to 72% over 260 ms and over its last 110 ms
                // its paint fades out under the dot's own solid ink, so it
                // ends in the dot's colour over any desktop. Over the same
                // 110 ms the dot comes up under it, its solid ink hidden by
                // the disc of the same ink and its hairline fading in round
                // it (`fadeEdgeIn`), so at 260 ms the disc goes into the dot
                // as it rests, with no frame where the hairline appears.
                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.fromValue = 1
                shrink.toValue = 0.72
                shrink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                let shown = CABasicAnimation(keyPath: "opacity")
                shown.fromValue = 1
                shown.toValue = 1
                let settle = CAAnimationGroup()
                settle.animations = [shrink, shown]
                settle.duration = 0.26
                painting.add(settle, forKey: "settle")
                let tint = CAKeyframeAnimation(keyPath: "opacity")
                tint.values = [0, 0, 1]
                tint.keyTimes = [0, 0.15 / 0.26, 1] as [NSNumber]
                tint.duration = 0.26
                settleTint.add(tint, forKey: "settle")
                let fading = CAKeyframeAnimation(keyPath: "opacity")
                fading.values = [1, 1, 0]
                fading.keyTimes = [0, 0.15 / 0.26, 1] as [NSNumber]
                fading.duration = 0.26
                art.add(fading, forKey: "settle")
                // Discrete: hidden until 150 ms, then shown; one more key time
                // than values.
                let hidden = CAKeyframeAnimation(keyPath: "opacity")
                hidden.values = [0, 1]
                hidden.keyTimes = [0, 0.15 / 0.26, 1] as [NSNumber]
                hidden.calculationMode = .discrete
                hidden.duration = 0.26
                rest.add(hidden, forKey: "fade")
                fadeEdgeIn(after: 0.15)
            }
        }
        CATransaction.commit()
    }

    /// The listening layers for `phase`. Listening, the halo comes up to
    /// its quiet glow and the breath starts once the rise has settled, or
    /// under Reduce Motion the steady ring shows. Any other phase takes the
    /// voice away: the disc and the halo ease home over 300 ms as the sun
    /// warms or settles, and the breath stops. `starting` is a dictation's
    /// first moment, which sends the start's ripple.
    private func listen(still: Bool, starting: Bool) {
        let listening = phase == .listening
        steady.isHidden = !(listening && still)
        breather.removeAnimation(forKey: "breath")
        if listening, !still {
            ease(halo, "opacity", to: SunVoice.look(0).glow, over: 0.25)
            let breath = CABasicAnimation(keyPath: "transform.scale")
            breath.fromValue = 1
            breath.toValue = SunVoice.breath
            breath.duration = 1.2
            breath.autoreverses = true
            breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breath.beginTime = CACurrentMediaTime() + (starting ? 0.35 : 0)
            breather.add(breath, forKey: "breath")
            if starting {
                // Inside an open slip the sun's start shows in the slip.
                if slip == nil { ripple() }
                voice.rippled(at: now())
            }
            return
        }
        let away = still ? 0 : 0.3
        ease(halo, "opacity", to: Float(0), over: away)
        ease(halo, "transform.scale", to: SunVoice.look(0).halo, over: away)
        ease(swell, "transform.scale", to: CGFloat(1), over: away)
        if !still, let scale = breather.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat, scale != 1 {
            breather.add(Self.ease("transform.scale", from: scale, to: 1, over: away), forKey: "home")
        }
        if still { rings.forEach { $0.removeAllAnimations(); $0.opacity = 0 } }
    }

    /// The voice while listening: the disc and the halo ease to its level
    /// over about the time since the last one, 50 ms at the microphone's
    /// fifty a second and up to 150 ms for a level on its own, as setup's
    /// landing gives (`FootMark.receiveSun`), so it swells rather than
    /// jumps; a louder sound sends a ripple out.
    private func heard(_ level: Double) {
        guard phase == .listening, !reducesMotion() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let time = now()
        let over = min(0.15, max(0.05, time - (lastHeard ?? -.infinity)))
        lastHeard = time
        let look = voice.hear(level, at: time)
        ease(swell, "transform.scale", to: look.disc, over: over)
        ease(halo, "transform.scale", to: look.halo, over: over)
        ease(halo, "opacity", to: look.glow, over: over)
        if look.ripple, slip == nil { ripple(disc: look.disc) }
        CATransaction.commit()
    }

    /// The mark's width as it shows: the dot at rest, the disc as the voice
    /// and the breath have it while listening, the disc while writing.
    private var dotDiameter: CGFloat {
        guard phase != .resting else { return Self.restWidth }
        let swelled = (swell.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        let breath = (breather.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        return Self.disc * swelled * breath
    }

    /// How the mark sits in an open slip: moved to the slip's end, and the
    /// sun a little smaller, so it and its bloom fit the slip's height.
    private var faceInSlip: CATransform3D {
        guard let frame = slipFrame else { return CATransform3DIdentity }
        let dot = FootSlip.dot(in: frame, opening: opening)
        let scale: CGFloat = phase == .resting ? 1 : 0.7
        // In whole pixels, so the dot keeps its even edge at the slip's end.
        let end = snapped(dot)
        let moved = CATransform3DMakeTranslation(end.x - rest.position.x, end.y - rest.position.y, 0)
        return CATransform3DScale(moved, scale, scale, 1)
    }

    /// Where the dot shows in the view this frame: its resting centre moved
    /// by the face's glide into or out of a slip as it stands now.
    var shownDotCentre: CGPoint {
        let moved = face.presentation()?.transform ?? face.transform
        return CGPoint(x: bounds.midX + moved.m41, y: bounds.midY + moved.m42)
    }

    /// Closes the slip, or folds the glyph, at once, with no glide or fade,
    /// and puts the dot home: for a dot taken in the hand, which must stay
    /// under the pointer.
    func closeSlipAtOnce() {
        slip = nil
        glyph = nil
        folds &+= 1
        endFold()
        closes &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        [face, slipLayer, slipBody, slipNear, slipFar, slipWords].forEach { $0.removeAllAnimations() }
        face.transform = CATransform3DIdentity
        slipLayer.opacity = 0
        slipWords.opacity = 0
        CATransaction.commit()
    }

    /// The pill and the microphone at the display's pixels, and the
    /// tooltip for the desktop now. While the glyph folds away its paths
    /// stay as they were.
    private func drawGlyph() {
        let shape = MicGlyph.shape(scale: backingScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let glyph {
            pillEdge.path = Self.pillPath(grownBy: Self.restEdge)
            pill.path = Self.pillPath()
            micHead.path = shape.headPath()
            drawTooltip(glyph.key)
        }
        for (layer, path) in zip(micStrokes, [shape.cradle, shape.stemPath, shape.footPath]) { layer.path = path }
        placeTooltip()
        CATransaction.commit()
    }

    /// The pill's outline round the dot's centre, grown by `by` on every
    /// side. Its sides fall on whole points from a centre on the pixel grid.
    private static func pillPath(grownBy by: CGFloat = 0) -> CGPath {
        let size = CGSize(width: pillSize.width + 2 * by, height: pillSize.height + 2 * by)
        return FootSlip.outline(CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), radius: pillRadius + by)
    }

    /// The tooltip's paper, edge, shadows and words for `key`, as wide as
    /// its words and the room across allow.
    private func drawTooltip(_ key: String) {
        let colours = FootSlip.colours(dark: isDark, contrast: increasesContrast())
        let room = tooltipRoom.maxX - tooltipRoom.minX - 2 * Self.tooltipPadding
        let words = FootSlip.tooltipWords(key, dark: isDark, contrast: increasesContrast(), scale: backingScale, fitting: room)
        let size = CGSize(width: (words.size.width + 2 * Self.tooltipPadding).rounded(.up), height: Self.tooltipHeight)
        tooltip.bounds = CGRect(origin: .zero, size: size)
        let path = FootSlip.outline(tooltip.bounds, radius: FootSlip.radius)
        tooltipBody.path = path
        tooltipBody.fillColor = colours.paper.cgColor
        tooltipBody.strokeColor = colours.edge.cgColor
        // The slip's float: by day ink at 8% near and 35% far, by night black
        // at 40% near and a deep navy at 80% far.
        tooltipNear.path = path
        tooltipNear.fillColor = colours.paper.cgColor
        tooltipNear.shadowColor = (isDark ? NSColor.black.withAlphaComponent(0.4) : Self.ink.withAlphaComponent(0.08)).cgColor
        tooltipFar.path = path
        tooltipFar.fillColor = colours.paper.cgColor
        tooltipFar.shadowColor = (isDark ? NSColor(srgbRed: 0x02 / 255.0, green: 0x08 / 255.0, blue: 0x14 / 255.0, alpha: 0.8)
            : Self.ink.withAlphaComponent(0.35)).cgColor
        tooltipFar.shadowRadius = isDark ? 16 : 12
        tooltipFar.shadowOffset = CGSize(width: 0, height: isDark ? 16 : 12)
        tooltipWords.contents = words.image
        tooltipWords.frame = CGRect(x: Self.tooltipPadding, y: 0, width: words.size.width, height: Self.tooltipHeight)
    }

    /// The tooltip centred over the pill, `tooltipGap` above it, moved across
    /// to stay inside `tooltipRoom`; on whole pixels.
    private func placeTooltip() {
        let size = tooltip.bounds.size
        var x = mic.position.x - size.width / 2
        x = min(max(x, tooltipRoom.minX), tooltipRoom.maxX - size.width)
        let y = mic.position.y - Self.pillSize.height / 2 - Self.tooltipGap - size.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tooltip.frame = CGRect(x: (x * backingScale).rounded() / backingScale, y: (y * backingScale).rounded() / backingScale,
                               width: size.width, height: size.height)
        CATransaction.commit()
    }

    /// The glyph as drawn, for the checks: whether it shows, the
    /// microphone's parts at the display's pixels, the pill's and the
    /// capsule's outlines as set, how far each stroke has drawn, and where
    /// the tooltip stands if it is up.
    var glyphDrawing: (shown: Bool, shape: MicGlyph.Shape, pill: CGRect?, head: CGRect?, strokes: [CGFloat], tooltip: CGRect?) {
        (!mic.isHidden, MicGlyph.shape(scale: backingScale), pill.path?.boundingBoxOfPath, micHead.path?.boundingBoxOfPath,
         micStrokes.map { $0.strokeEnd - $0.strokeStart }, tooltip.opacity > 0 ? tooltip.frame : nil)
    }

    /// The tooltip's edge colour as drawn, for the checks.
    var tooltipEdge: CGColor? { tooltipBody.strokeColor }

    /// Whether the tooltip's opacity is changing, for the checks.
    var tooltipFading: Bool { tooltip.animation(forKey: "opacity") != nil }

    /// Where the tooltip stands while any of it can show, a fade in or out
    /// under way included, in the view's coordinates.
    var tooltipShowing: CGRect? { tooltip.opacity > 0 || tooltipFading ? tooltip.frame : nil }

    /// Takes the tooltip away at once, whatever the glyph is doing, as when
    /// the focused field comes under it.
    func dropTooltip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tooltip.removeAnimation(forKey: "opacity")
        tooltip.opacity = 0
        CATransaction.commit()
    }

    /// The glyph's centre in the view: the dot's, on the pixel grid.
    var glyphCentre: CGPoint { mic.position }

    /// Whether the resting dot shows, for the checks.
    var restShown: Bool { !rest.isHidden }

    /// The pill's change under way, for the checks: the outline it starts
    /// from and the one it ends at, each by its bounds.
    var pillMorph: (from: CGRect, to: CGRect)? {
        guard let change = pill.animation(forKey: "path") as? CABasicAnimation,
              let from = change.fromValue, let to = change.toValue else { return nil }
        return ((from as! CGPath).boundingBoxOfPath, (to as! CGPath).boundingBoxOfPath)
    }

    /// The resting dot's circle and its hairline's, as the pill's start and
    /// end, drawn with the pill's own elements.
    private static var dotPaths: (core: CGPath, edge: CGPath) {
        let core = restWidth, edge = restWidth + 2 * restEdge
        return (FootSlip.outline(CGRect(x: -core / 2, y: -core / 2, width: core, height: core), radius: core / 2),
                FootSlip.outline(CGRect(x: -edge / 2, y: -edge / 2, width: edge, height: edge), radius: edge / 2))
    }

    /// From `old`'s glyph, or the mark as it is, to `glyph`. In, over 200
    /// ms: the dot's circle and its hairline grow into the pill in the first
    /// 140 ms, the capsule grows from its own centre from 60 ms, the cradle
    /// draws from its bottom out to both arms from 90 ms, the stem from 140
    /// ms and the foot from its middle from 170 ms, and the tooltip fades in
    /// 80 ms after the pill has arrived. Out, over 160 ms, the same backward:
    /// the tooltip goes first, and the dot is back where the pill has become
    /// its circle again. Under Reduce Motion the glyph and the dot swap.
    private func morphGlyph(from old: Glyph?) {
        let still = reducesMotion()
        folds &+= 1
        let fold = folds
        let now = CACurrentMediaTime()
        let shape = MicGlyph.shape(scale: backingScale)
        let dot = Self.dotPaths
        let opened = (pill: Self.pillPath(), edge: Self.pillPath(grownBy: Self.restEdge), head: shape.headPath())
        let seed = FootSlip.outline(CGRect(x: shape.head.midX, y: shape.head.midY, width: 0, height: 0), radius: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let glyph {
            // From where a fold under way has got to, or the dot.
            let folding = !mic.isHidden
            let fromPill = folding ? pill.presentation()?.path ?? dot.core : dot.core
            let fromEdge = folding ? pillEdge.presentation()?.path ?? dot.edge : dot.edge
            let fromHead = folding ? micHead.presentation()?.path ?? seed : seed
            let fromStrokes = micStrokes.map { stroke in
                folding ? (stroke.presentation()?.strokeEnd ?? 0) - (stroke.presentation()?.strokeStart ?? 0) : 0
            }
            let fromTooltip = folding ? tooltip.presentation()?.opacity ?? 0 : 0
            drawGlyph()
            mic.isHidden = false
            rest.isHidden = true
            if old == nil {
                animate(pill, "path", from: fromPill, to: opened.pill, at: now, begin: 0, duration: 0.14, still: still)
                animate(pillEdge, "path", from: fromEdge, to: opened.edge, at: now, begin: 0, duration: 0.14, still: still)
                animate(micHead, "path", from: fromHead, to: opened.head, at: now, begin: 0.06, duration: 0.1, still: still)
                for (index, (begin, duration)) in [(0.09, 0.07), (0.14, 0.035), (0.17, 0.03)].enumerated() {
                    draw(index, from: fromStrokes[index], to: 1, at: now, begin: begin, duration: duration, still: still)
                }
            }
            // A field come under the tooltip takes it away at once, so it
            // never covers the field while it fades.
            animate(tooltip, "opacity", from: fromTooltip, to: Float(glyph.tooltip ? 1 : 0),
                    at: now, begin: old == nil ? 0.28 : 0, duration: 0.12, still: still || !glyph.tooltip)
        } else {
            animate(tooltip, "opacity", from: tooltip.presentation()?.opacity ?? 0, to: Float(0), at: now, begin: 0, duration: 0.08, still: still)
            for (index, (begin, duration)) in [(0.04, 0.05), (0.02, 0.03), (0.0, 0.03)].enumerated() {
                let shown = (micStrokes[index].presentation()?.strokeEnd ?? 1) - (micStrokes[index].presentation()?.strokeStart ?? 0)
                draw(index, from: shown, to: 0, at: now, begin: begin, duration: duration, still: still)
            }
            animate(micHead, "path", from: micHead.presentation()?.path ?? opened.head, to: seed, at: now, begin: 0.04, duration: 0.06, still: still)
            animate(pill, "path", from: pill.presentation()?.path ?? opened.pill, to: dot.core, at: now, begin: 0.06, duration: 0.1, still: still)
            animate(pillEdge, "path", from: pillEdge.presentation()?.path ?? opened.edge, to: dot.edge, at: now, begin: 0.06, duration: 0.1, still: still)
            if still {
                endFold()
            } else {
                // The dot comes back once the pill is its circle again.
                Task { [weak self] in
                    try? await Task.sleep(for: Self.folding)
                    guard let self, self.folds == fold, self.glyph == nil else { return }
                    self.endFold()
                }
            }
        }
        CATransaction.commit()
    }

    /// The glyph gone and the dot back in its place.
    private func endFold() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        micLayers.forEach { $0.removeAllAnimations() }
        for (index, layer) in micStrokes.enumerated() {
            let ends = Self.drawn(0, stroke: index)
            layer.strokeStart = ends.start
            layer.strokeEnd = ends.end
        }
        tooltip.opacity = 0
        mic.isHidden = true
        rest.isHidden = false
        CATransaction.commit()
        onFolded()
    }

    /// Sets `key` on `layer` to `value`, from `from` with the motion
    /// language's change curve, `begin` after `now` for `duration`, or at
    /// once under Reduce Motion.
    private func animate(_ layer: CALayer, _ key: String, from: Any?, to value: Any, at now: CFTimeInterval, begin: CFTimeInterval,
                         duration: CFTimeInterval, still: Bool) {
        layer.setValue(value, forKeyPath: key)
        guard !still, let from else {
            layer.removeAnimation(forKey: key)
            return
        }
        let change = CABasicAnimation(keyPath: key)
        change.fromValue = from
        change.toValue = value
        change.beginTime = now + begin
        change.duration = duration
        change.fillMode = .backwards
        change.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        layer.add(change, forKey: key)
    }

    /// How much of stroke `index` shows when `fraction` of it is drawn: the
    /// cradle from its bottom out to both arms, the stem from the cradle
    /// down, the foot from its middle out to both ends.
    private static func drawn(_ fraction: CGFloat, stroke index: Int) -> (start: CGFloat, end: CGFloat) {
        index == 1 ? (0, fraction) : (0.5 - fraction / 2, 0.5 + fraction / 2)
    }

    /// Draws stroke `index` from `from` of it to `to`.
    private func draw(_ index: Int, from: CGFloat, to: CGFloat, at now: CFTimeInterval, begin: CFTimeInterval,
                      duration: CFTimeInterval, still: Bool) {
        let start = Self.drawn(from, stroke: index), end = Self.drawn(to, stroke: index)
        let layer = micStrokes[index]
        animate(layer, "strokeStart", from: start.start, to: end.start, at: now, begin: begin, duration: duration, still: still)
        animate(layer, "strokeEnd", from: start.end, to: end.end, at: now, begin: begin, duration: duration, still: still)
    }


    /// The hairline fades in round the dot over 110 ms, `delay` from now,
    /// where the dot comes in from a disc of its own ink: as a dictation's
    /// sun settles and as setup's moon hands over to the mark. Under Reduce
    /// Motion it is simply there.
    func fadeEdgeIn(after delay: CFTimeInterval = 0) {
        guard !reducesMotion() else { return }
        let fade = CABasicAnimation(keyPath: "fillColor")
        fade.fromValue = restEdgeInk.withAlphaComponent(0).cgColor
        fade.toValue = restEdgeInk.cgColor
        fade.duration = 0.11
        if delay > 0 {
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
        }
        rest.add(fade, forKey: "edge")
    }

    /// The resting dot's two tones as drawn, for the checks: the hairline's
    /// fill and, over it, the dot's own, or nil where a layer is not in the
    /// dot.
    var restTones: (edge: CGColor?, core: CGColor?) {
        (rest.fillColor, restCore.superlayer === rest ? restCore.fillColor : nil)
    }

    /// Whether the hairline is fading in, or waiting to, for the checks.
    var isFadingEdgeIn: Bool { rest.animation(forKey: "edge") != nil }

    /// Moves the mark to where the slip, or no slip, puts it. Opening from
    /// the dot, `after` holds it still for the slip's first frames, so the
    /// short capsule never shows the dot at one end like a switch's knob.
    private func placeFace(animated: Bool, after delay: CFTimeInterval = 0) {
        let target = faceInSlip
        let shown = face.presentation()?.transform ?? face.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.transform = target
        if animated, !reducesMotion(), !CATransform3DEqualToTransform(shown, target) {
            let glide = CASpringAnimation(keyPath: "transform")
            glide.mass = 1
            glide.stiffness = 420
            glide.damping = 32
            glide.fromValue = shown
            glide.toValue = target
            glide.duration = glide.settlingDuration
            if delay > 0 {
                glide.beginTime = CACurrentMediaTime() + delay
                glide.fillMode = .backwards
            }
            face.add(glide, forKey: "glide")
        } else {
            face.removeAnimation(forKey: "glide")
        }
        CATransaction.commit()
    }

    /// The paper, its edge, its shadows and its words for the desktop now.
    /// New words on an open slip go before the next come.
    private func drawSlip() {
        guard let slip, let frame = slipFrame else { return }
        let colours = FootSlip.colours(dark: isDark, contrast: increasesContrast())
        let ink = NSColor(srgbRed: 0x20 / 255.0, green: 0x2A / 255.0, blue: 0x2E / 255.0, alpha: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slipBody.fillColor = colours.paper.cgColor
        slipBody.strokeColor = colours.edge.cgColor
        // Day: ink at 8% near and 35% far; night: black at 40% near and a
        // deep navy at 80% far.
        slipNear.fillColor = colours.paper.cgColor
        slipNear.shadowColor = (isDark ? NSColor.black.withAlphaComponent(0.4) : ink.withAlphaComponent(0.08)).cgColor
        slipFar.fillColor = colours.paper.cgColor
        slipFar.shadowColor = (isDark ? NSColor(srgbRed: 0x02 / 255.0, green: 0x08 / 255.0, blue: 0x14 / 255.0, alpha: 0.8)
            : ink.withAlphaComponent(0.35)).cgColor
        slipFar.shadowRadius = isDark ? 16 : 12
        slipFar.shadowOffset = CGSize(width: 0, height: isDark ? 16 : 12)
        let words = slip.image(dark: isDark, contrast: increasesContrast(), opening: opening, scale: backingScale)
        if !reducesMotion(), let before = slipWords.contents, slipWords.opacity > 0 {
            // The old words fade out once over 120 ms as the slip changes
            // size under them, and the new fade in over the grow's 180 ms.
            // Discrete key frames take one more key time than values.
            let contents = CAKeyframeAnimation(keyPath: "contents")
            contents.values = [before, words as Any]
            contents.keyTimes = [0, 0.4, 1]
            contents.calculationMode = .discrete
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 0, 1]
            fade.keyTimes = [0, 0.4, 1]
            let swap = CAAnimationGroup()
            swap.animations = [contents, fade]
            swap.duration = 0.3
            slipWords.add(swap, forKey: "swap")
        }
        slipWords.contents = words
        slipWords.frame = slip.wordsFrame(in: frame, opening: opening)
        CATransaction.commit()
    }

    /// Sets the slip's outline, on the paper and both shadows, from `from`
    /// with `animation`'s timing, or at once.
    private func outline(_ path: CGPath, from: CGPath?, spring: Bool) {
        for shape in [slipBody, slipNear, slipFar] {
            shape.path = path
            shape.removeAnimation(forKey: "morph")
            guard let from else { continue }
            let change: CABasicAnimation
            if spring {
                let grow = CASpringAnimation(keyPath: "path")
                grow.mass = 1
                grow.stiffness = 420
                grow.damping = 32
                grow.duration = grow.settlingDuration
                change = grow
            } else {
                change = CABasicAnimation(keyPath: "path")
                change.duration = 0.26
                change.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            }
            change.fromValue = from
            change.toValue = path
            shape.add(change, forKey: "morph")
        }
    }

    /// From `old`'s slip, or the mark as it is, to `slip`'s. Opening, the
    /// paper grows on a spring out of the dot's own circle while the dot
    /// glides to its end, and the words come up once it is half open.
    /// Closing, the words go first, the paper shrinks back into the dot's
    /// circle as the dot glides home, and goes as it lands. Between two
    /// slips the paper eases to the new size and the words change.
    private func morph(from old: FootSlip?) {
        let still = reducesMotion()
        let home = CGPoint(x: bounds.midX, y: bounds.midY)
        let diameter = dotDiameter * (phase == .resting ? 1 : 0.7)
        let shownPath = slipBody.presentation()?.path ?? slipBody.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let frame = slipFrame {
            let seed = CGRect(x: home.x - diameter / 2, y: home.y - diameter / 2, width: diameter, height: diameter)
            if old == nil { slipWords.contents = nil }
            drawSlip()
            let path = FootSlip.outline(frame, radius: FootSlip.radius)
            slipLayer.opacity = 1
            slipWords.opacity = 1
            if still {
                outline(path, from: nil, spring: false)
                [slipLayer, slipWords].forEach { $0.removeAnimation(forKey: "fade") }
                if old == nil { slipLayer.add(Self.fade(from: 0, to: 1, duration: 0.2), forKey: "fade") }
            } else {
                outline(path, from: old == nil ? FootSlip.outline(seed, radius: diameter / 2) : shownPath, spring: true)
                slipLayer.removeAnimation(forKey: "fade")
                if old == nil {
                    let words = CABasicAnimation(keyPath: "opacity")
                    words.fromValue = 0
                    words.toValue = 1
                    // Once the dot has all but reached its end, never under it.
                    words.beginTime = CACurrentMediaTime() + 0.15
                    words.duration = 0.16
                    words.fillMode = .backwards
                    slipWords.add(words, forKey: "fade")
                }
            }
            placeFace(animated: true, after: old == nil ? 0.05 : 0)
        } else if old != nil {
            let seed = CGRect(x: home.x - diameter / 2, y: home.y - diameter / 2, width: diameter, height: diameter)
            slipLayer.opacity = 0
            if still {
                // The slip fades out whole, its paper and words as they are.
                [slipLayer, slipWords].forEach { $0.removeAllAnimations() }
                slipLayer.add(Self.fade(from: 1, to: 0, duration: 0.2), forKey: "fade")
            } else {
                slipWords.opacity = 0
                slipWords.add(Self.fade(from: slipWords.presentation()?.opacity ?? 1, to: 0, duration: 0.1), forKey: "fade")
                outline(FootSlip.outline(seed, radius: diameter / 2), from: shownPath, spring: false)
                // The paper holds until it is the dot's circle under the dot,
                // then goes.
                let held = CAKeyframeAnimation(keyPath: "opacity")
                held.values = [1, 1, 0]
                held.keyTimes = [0, 0.85, 1]
                held.duration = 0.26
                slipLayer.add(held, forKey: "fade")
            }
            if still {
                // The dot stays at the slip's end while the slip fades, then
                // cuts home as it goes, so it never sits on the fading words.
                closes &+= 1
                let close = closes
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, self.closes == close, self.slip == nil else { return }
                    self.placeFace(animated: false)
                }
            } else {
                placeFace(animated: true)
            }
        }
        CATransaction.commit()
    }

    /// One ring in the pigment, from just past the bloom out to
    /// `rippleReach` over 750 ms, thinning to half a point and fading as it
    /// goes.
    private func ripple(disc target: CGFloat? = nil) {
        ripples += 1
        let ring = rings[nextRing]
        nextRing = (nextRing + 1) % rings.count
        // From 3 points past the farthest the bloom reaches for the disc the
        // voice is taking it to, 1.5 times it, so paper always shows between
        // the ring and the bloom, even as the bloom grows; and 6 points short
        // of its end, so it always travels.
        let shown = (swell.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        let disc = Self.disc / 2 * max(shown, target ?? shown)
        let start = min(disc * SunVoice.bloomReach + 3, Self.rippleReach - 6)
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = Self.outline(radius: start)
        grow.toValue = Self.outline(radius: Self.rippleReach)
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.35, 1)
        // Strong for its first half and thinning as it goes, since a ring
        // only fading reads muddy over a dark desktop.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.85, 0]
        fade.keyTimes = [0, 0.5, 1]
        let thin = CABasicAnimation(keyPath: "lineWidth")
        thin.fromValue = 1.5
        thin.toValue = 0.5
        let wave = CAAnimationGroup()
        wave.animations = [grow, fade, thin]
        wave.duration = 0.75
        ring.path = Self.outline(radius: Self.rippleReach)
        ring.opacity = 0
        ring.add(wave, forKey: "ripple")
    }

    /// The dot's own outline, `radius` across half its width,
    /// round the layer's position: the shape a ring leaves the mark in.
    nonisolated static func outline(radius: CGFloat) -> CGPath {
        let shape = OwnHandMark.dot(diameter: radius * 2)
        var centred = CGAffineTransform(translationX: -shape.size.width / 2, y: -shape.size.height / 2)
        return shape.path.copy(using: &centred) ?? shape.path
    }

    /// The bloom: the disc's own colour spread
    /// out past its edge, never lightened, at full strength to the disc's
    /// edge, 0.6 of the way out, and fading to nothing at the edge of the
    /// image, so it reads as the paint spreading, orange into a pale orange
    /// fringe, with no band and no edge of its own. The disc inside it sits
    /// under the painting.
    private static func bloom(of art: CGImage?) -> CGImage? {
        guard let art else { return nil }
        let rect = CGRect(x: 0, y: 0, width: art.width, height: art.height)
        guard let context = CGContext(data: nil, width: art.width, height: art.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Only the disc, inside the paper's own bloom, drawn larger so
        // its pigment fills the image to the edge.
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        let spread = (Self.bloom / 1.05 - 1) / 2
        context.draw(art, in: rect.insetBy(dx: -rect.width * spread, dy: -rect.height * spread))
        context.restoreGState()
        let black = NSColor.black
        let edge = 1 / Self.bloom
        guard let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                    colors: [black, black, black.withAlphaComponent(0.6), black.withAlphaComponent(0.22),
                                             black.withAlphaComponent(0)].map(\.cgColor) as CFArray,
                                    locations: [0, edge, 0.75, 0.88, 1]) else { return context.makeImage() }
        context.setBlendMode(.destinationIn)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        context.drawRadialGradient(fade, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: rect.width / 2,
                                   options: [.drawsAfterEndLocation])
        return context.makeImage()
    }

    /// Sets `layer`'s `key` to `value` and, given time, eases there from
    /// where it shows now, so a new level never jumps from the last target.
    /// A layer already there, with nothing moving it, is left alone, so
    /// nothing runs at rest.
    private func ease<Value>(_ layer: CALayer, _ key: String, to value: Value, over duration: CFTimeInterval) {
        if layer.animation(forKey: key) == nil, (layer.value(forKeyPath: key) as? NSObject)?.isEqual(value as AnyObject) == true { return }
        let shown = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        layer.setValue(value, forKeyPath: key)
        guard duration > 0, let shown else {
            layer.removeAnimation(forKey: key)
            return
        }
        layer.add(Self.ease(key, from: shown, to: value, over: duration), forKey: key)
    }

    private static func ease(_ key: String, from: Any, to: Any, over duration: CFTimeInterval) -> CABasicAnimation {
        let ease = CABasicAnimation(keyPath: key)
        ease.fromValue = from
        ease.toValue = to
        ease.duration = duration
        ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return ease
    }

    /// One breath every 3 s, from full to 85% and back, until removed.
    private static func breath() -> CABasicAnimation {
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 1
        breath.toValue = 0.85
        breath.duration = 1.5
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return breath
    }

    private static func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return fade
    }

    /// The sky's painting and its warm copy, loaded once, `deep` with the
    /// moon's pigment laid deeper for a light desktop. A bundle without the
    /// paintings, as the scenario checks build, gets a plain disc.
    private static func art(_ sky: Sky, deep: Bool) -> (plain: CGImage?, warm: CGImage?) {
        let key = "\(sky)\(deep)"
        if let cached = cache[key] { return cached }
        let name = sky == .sun ? "FootSun" : "FootMoon"
        let image = Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
            ?? disc(sky == .sun ? OwnHandMark.recording : lamp)
        let base = deep ? image.flatMap { tint($0, toward: deepLamp, by: 0.42) } : image
        // The moon warms less than the sun: its lamp is near the accent already.
        let art = (plain: base, warm: base.flatMap { tint($0, toward: accent, by: sky == .sun ? 0.45 : 0.2) })
        cache[key] = art
        return art
    }

    private static var cache: [String: (plain: CGImage?, warm: CGImage?)] = [:]
    /// The lamp's pigment laid deeper, for the moon on a light desktop.
    nonisolated static let deepLamp = NSColor(srgbRed: 0xD4 / 255.0, green: 0xA8 / 255.0, blue: 0x55 / 255.0, alpha: 1)

    /// `image` with `colour` laid over its disc at `amount`, fading out just
    /// past the disc's edge so the faint bloom keeps its own colour, and
    /// its alpha kept.
    private static func tint(_ image: CGImage, toward colour: NSColor, by amount: CGFloat) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [colour.withAlphaComponent(amount).cgColor, colour.withAlphaComponent(amount).cgColor,
                                                 colour.withAlphaComponent(0).cgColor] as CFArray,
                                        locations: [0, 0.92, 1.08 / 1.08]) else { return nil }
        context.draw(image, in: rect)
        context.setBlendMode(.sourceAtop)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let disc = rect.width / bloom / 2
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: disc * 1.08, options: [])
        return context.makeImage()
    }

    /// A flat disc with the art's proportions, in place of a missing painting.
    private static func disc(_ colour: NSColor) -> CGImage? {
        let side = 160
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let inner = CGFloat(side) / bloom
        context.setFillColor(colour.cgColor)
        context.fillEllipse(in: CGRect(x: (CGFloat(side) - inner) / 2, y: (CGFloat(side) - inner) / 2, width: inner, height: inner))
        return context.makeImage()
    }
}

/// What the voice does to the listening sun, apart from the view so the
/// checks can play levels through it. The level is the smoothed one,
/// about fifty a second (`LevelFollower`).
///
/// The sun shows the voice against its own recent peak, so a quiet voice
/// or a far microphone moves it as much as a loud one, and the dips
/// between syllables, which stay high on the level's own scale, move it
/// clearly; silence still brings it home.
struct SunVoice {
    /// What the sun shows for one level: the disc's scale, the halo's scale
    /// and strength, and whether a ripple goes out.
    struct Look: Equatable {
        var disc: CGFloat
        var halo: CGFloat
        var glow: Float
        var ripple = false
    }

    /// The farthest the bloom reaches, at the loudest, as a multiple of the
    /// disc's radius.
    static let bloomReach: CGFloat = 1.5
    /// The listening breath's top, from the sun's own size.
    static let breath: CGFloat = 1.07
    /// The lowest the peak falls to, so room noise in a long silence never
    /// reads as a voice.
    static let quietestPeak = 0.45

    /// The sun for `loudness`, the level against the peak from 0 to 1: the
    /// disc from 16 points toward 24, the bloom reaching from 1.1 to 1.5
    /// times the disc as it is then, so 9 to 18 points from the centre, and
    /// its strength from 35%, so the sun reads as listening in silence, to
    /// full. The bloom's scale is of the painting, whose own bloom reaches
    /// `SunDotView.bloom` times the disc.
    static func look(_ loudness: Double) -> Look {
        let loudness = min(1, max(0, loudness))
        let disc = 1 + 0.5 * CGFloat(loudness)
        let reach = 1.1 + (bloomReach - 1.1) * CGFloat(loudness)
        return Look(disc: disc, halo: disc * reach / SunDotView.bloom, glow: Float(0.35 + 0.65 * loudness))
    }

    /// The loudest the voice has been lately, falling back over about two
    /// seconds.
    private var peak = quietestPeak
    /// Where the voice has been: up with it over about 100 ms, so a phrase
    /// sends one ring, and down over about 300 ms, so the dips between
    /// syllables keep it up and a pause between clauses does not.
    private var settled = 0.0
    private var last: CFTimeInterval?
    private var lastRipple = -CFTimeInterval.infinity

    /// A ripple went out at `time` for another reason, the start's.
    mutating func rippled(at time: CFTimeInterval) { lastRipple = time }

    /// The sun for `level` heard at `time`. A louder sound, which sends a
    /// ripple, is a level of 0.5 or more risen by 0.12 or more above where
    /// the voice has been, once the last ripple's 750 ms are over, so one
    /// ring is out at a time, never two in a target, and steady
    /// speech sends a ring with each phrase rather than each syllable.
    mutating func hear(_ level: Double, at time: CFTimeInterval) -> Look {
        let level = min(1, max(0, level))
        let elapsed = last.map { max(0, time - $0) } ?? 0
        last = time
        peak = max(level, Self.quietestPeak + (peak - Self.quietestPeak) * exp(-elapsed / 2))
        // Curved, so the dips between syllables show as clearly as the words.
        var look = Self.look(pow(level / peak, 2))
        let rise = level - settled
        settled += (level - settled) * (1 - exp(-elapsed / (level > settled ? 0.1 : 0.3)))
        if level >= 0.5, rise >= 0.12, time - lastRipple >= 0.75 {
            lastRipple = time
            look.ripple = true
        }
        return look
    }
}
