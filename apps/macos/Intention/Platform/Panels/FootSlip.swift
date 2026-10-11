import AppKit

/// What the foot mark says when it opens into a slip: a short slip of the
/// shared floating paper grows out of the dot, with the dot itself, the sun
/// while listening, kept at its end, then the words, then the key as a small
/// cap; it closes back into the dot when they are done. There is no other
/// window or band and no glyph: the dot is the sign (`SunDotView.slip`).
struct FootSlip: Equatable, Sendable {
    var text: String
    /// A key drawn as a small cap after the words, as "fn" after "Dictate".
    var key: String? = nil
    /// Words after the key, as "cancels" after esc.
    var after: String? = nil
    /// A second key and its words, as a hands-free recording's "esc cancels"
    /// after the dictation key that finishes it.
    var thenKey: String? = nil
    var thenWords: String? = nil

    /// The slip's height, its corners, and the room at its far end.
    static let height: CGFloat = 28
    static let radius: CGFloat = 8
    static let padding: CGFloat = 12
    /// The square at the dot's end that holds the dot.
    static let dotRoom: CGFloat = 28
    /// The widest a slip grows, so the longest notice fits the foot's window.
    static let widest: CGFloat = 320
    /// How far the float's shadow spreads past the paper, by night, the
    /// wider: the focused field must keep clear of it too.
    static let shadowReach: CGFloat = 16
    /// A key's name wider than this is drawn with the modifiers' symbols,
    /// as "Control + Option + Shift + Command" is "⌃ ⌥ ⇧ ⌘", so the slip fits.
    static let longestKey: CGFloat = 72

    /// Which way the slip opens. At the bottom it grows evenly either side
    /// of where the dot rests, and the dot glides to its left end; at a side
    /// it grows from the dot toward the screen's middle and the dot stays
    /// put at its outer end, so the dot never crosses the slip.
    enum Opening: Equatable, Sendable {
        case centre, rightward, leftward

        /// Whether the dot sits at the slip's right end. The words keep their
        /// reading order at every slot: only the dot changes ends.
        var dotAtRight: Bool { self == .leftward }
    }

    /// The slip's size for its words.
    @MainActor var size: CGSize {
        // A centred odd-point width puts both ends half a point off the
        // resting dot. Even widths keep the slip and dot on the 1x/2x grid.
        let width = Self.dotRoom + Self.gap + contentWidth + Self.padding
        return CGSize(width: min(Self.widest, (width / 2).rounded(.up) * 2), height: Self.height)
    }

    /// The slip's rectangle for a dot resting at `centre`.
    @MainActor func frame(around centre: CGPoint, opening: Opening) -> CGRect {
        let size = size
        let x = switch opening {
        case .centre: centre.x - size.width / 2
        case .rightward: centre.x - Self.dotRoom / 2
        case .leftward: centre.x + Self.dotRoom / 2 - size.width
        }
        return CGRect(x: x, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Where the dot sits inside `frame`: the middle of the room at its end.
    static func dot(in frame: CGRect, opening: Opening) -> CGPoint {
        CGPoint(x: opening.dotAtRight ? frame.maxX - dotRoom / 2 : frame.minX + dotRoom / 2, y: frame.midY)
    }

    /// The words' rectangle inside `frame`, beside the dot's room.
    @MainActor func wordsFrame(in frame: CGRect, opening: Opening) -> CGRect {
        let width = frame.width - Self.dotRoom - Self.gap - Self.padding
        let x = opening.dotAtRight ? frame.minX + Self.padding : frame.minX + Self.dotRoom + Self.gap
        return CGRect(x: x, y: frame.minY, width: width, height: frame.height)
    }

    /// A rounded rectangle with corners of `radius`, at most half its height,
    /// drawn with the same elements at every size, so Core Animation can grow
    /// the dot's circle into the slip.
    static func outline(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        let k: CGFloat = 0.5523 * radius
        let (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX + radius, y: minY))
        path.addLine(to: CGPoint(x: maxX - radius, y: minY))
        path.addCurve(to: CGPoint(x: maxX, y: minY + radius), control1: CGPoint(x: maxX - radius + k, y: minY),
                      control2: CGPoint(x: maxX, y: minY + radius - k))
        path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
        path.addCurve(to: CGPoint(x: maxX - radius, y: maxY), control1: CGPoint(x: maxX, y: maxY - radius + k),
                      control2: CGPoint(x: maxX - radius + k, y: maxY))
        path.addLine(to: CGPoint(x: minX + radius, y: maxY))
        path.addCurve(to: CGPoint(x: minX, y: maxY - radius), control1: CGPoint(x: minX + radius - k, y: maxY),
                      control2: CGPoint(x: minX, y: maxY - radius + k))
        path.addLine(to: CGPoint(x: minX, y: minY + radius))
        path.addCurve(to: CGPoint(x: minX + radius, y: minY), control1: CGPoint(x: minX, y: minY + radius - k),
                      control2: CGPoint(x: minX + radius - k, y: minY))
        path.closeSubpath()
        return path
    }

    /// The shared floating paper and what is drawn on it, by day or by night,
    /// from the app's palette (`Palette.overPaper`, `overEdge`, `ink`, and a
    /// keycap's `paperButton`, `controlEdge` and `paperSeat`).
    struct Colours {
        var paper, edge, ink, capFace, capEdge, capSeat: NSColor
    }

    /// Under Increase Contrast the keycap's edge is raised, as the app's
    /// palette raises `controlEdge`.
    static func colours(dark: Bool, contrast: Bool = false) -> Colours {
        func hex(_ value: Int, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
        }
        var colours = dark
            ? Colours(paper: hex(0x1E2E5C), edge: hex(0xEEEFE9, 0.42), ink: hex(0xEEEFE9), capFace: hex(0x2B3E74),
                      capEdge: hex(0xEEEFE9, 0.5), capSeat: hex(0x060B1F))
            : Colours(paper: hex(0xF9FAF7), edge: hex(0x202A2E, 0.22), ink: hex(0x202A2E), capFace: hex(0xF9FAF7),
                      capEdge: hex(0x202A2E, 0.46), capSeat: hex(0x202A2E, 0.3))
        if contrast {
            colours.edge = colours.ink.withAlphaComponent(0.5)
            colours.capEdge = colours.ink.withAlphaComponent(0.7)
        }
        return colours
    }

    /// The words' width: the words, the key's cap and the words after it.
    @MainActor private var contentWidth: CGFloat {
        pieces.reduce(0) { $0 + $1.width } + CGFloat(max(0, pieces.count - 1)) * Self.gap
    }

    private static let gap: CGFloat = 6
    private static let capHeight: CGFloat = 18

    private enum Piece {
        case words(NSAttributedString), cap(NSAttributedString)

        var width: CGFloat {
            switch self {
            case let .words(text): text.size().width.rounded(.up)
            case let .cap(text): max(20, text.size().width.rounded(.up) + 10)
            }
        }
    }

    /// The words, the key, the words after it, and a second key with its
    /// words, in reading order.
    @MainActor private var pieces: [Piece] {
        var pieces: [Piece] = [.words(Self.text(text, 13, .semibold))]
        if let key { pieces.append(.cap(Self.cap(key))) }
        if let after { pieces.append(.words(Self.text(after, 12.5, .medium))) }
        if let thenKey { pieces.append(.cap(Self.cap(thenKey))) }
        if let thenWords { pieces.append(.words(Self.text(thenWords, 12.5, .medium))) }
        return pieces
    }

    /// The words drawn at the display's `scale`, to fill `wordsFrame`, in
    /// their reading order at every slot, against the dot: from it at the
    /// bottom and the left slot, up to it at the right slot, so "Done", esc
    /// and "cancels" never read as esc cancelling Done.
    @MainActor func image(dark: Bool, contrast: Bool = false, opening: Opening, scale: CGFloat) -> CGImage? {
        let colours = Self.colours(dark: dark, contrast: contrast)
        let size = CGSize(width: max(1, self.size.width - Self.dotRoom - Self.gap - Self.padding), height: Self.height)
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ordered = pieces
        // At the widest slip, the first words give up their end to an
        // ellipsis rather than run past the paper.
        let natural = ordered.reduce(0) { $0 + $1.width } + CGFloat(ordered.count - 1) * Self.gap
        let short = max(0, natural - size.width)
        var x: CGFloat = opening.dotAtRight ? max(0, size.width - natural) : 0
        let middle = size.height / 2
        for (index, piece) in ordered.enumerated() {
            let first = index == 0
            let width = first ? max(0, piece.width - short) : piece.width
            switch piece {
            case let .words(text):
                let tinted = NSMutableAttributedString(attributedString: Self.tinted(text, colours.ink))
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                tinted.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: tinted.length))
                let height = tinted.size().height
                tinted.draw(with: CGRect(x: x, y: middle - height / 2 + 0.5, width: width, height: height),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            case let .cap(text):
                Self.drawCap(text, in: CGRect(x: x, y: middle - Self.capHeight / 2 + 0.75, width: piece.width, height: Self.capHeight), colours: colours)
            }
            x += width + Self.gap
        }
        return context.makeImage()
    }

    /// The spec's keycap: a paper face, a half-point edge and a 1.5 point
    /// seat under it, 18 tall, the key in DM Sans 600.
    private static func drawCap(_ text: NSAttributedString, in rect: CGRect, colours: Colours) {
        colours.capSeat.setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: -1.5), xRadius: 5, yRadius: 5).fill()
        let face = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        colours.capFace.setFill()
        face.fill()
        colours.capEdge.setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 4.75, yRadius: 4.75)
        edge.lineWidth = 0.5
        edge.stroke()
        let tinted = Self.tinted(text, colours.ink)
        let drawn = tinted.size()
        tinted.draw(at: CGPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2 + 0.5))
    }

    /// The foot's tooltip above its pill: "Dictate" in DM Sans 600, then
    /// the caps of the dictation key `name`, one for a single key and one
    /// for each key of a combination ("Control + Option"), 4 points apart,
    /// as Settings shows the key. Where that is wider than `fitting` the caps
    /// name the modifiers by their symbols, as "⌃" for Control, still one
    /// cap each. The picture, the tooltip's height tall, and its width.
    @MainActor static func tooltipWords(_ name: String, dark: Bool, contrast: Bool = false, scale: CGFloat,
                                        fitting: CGFloat = .infinity) -> (image: CGImage?, size: CGSize) {
        let colours = colours(dark: dark, contrast: contrast)
        let words = tinted(text("Dictate", 13, .semibold), colours.ink)
        let (wordsWidth, labels, capWidths, size) = tooltipLayout(name, fitting: fitting)
        guard let context = CGContext(data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, size) }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let middle = size.height / 2
        let wordsHeight = words.size().height
        words.draw(at: CGPoint(x: 0, y: middle - wordsHeight / 2 + 0.5))
        var x = wordsWidth + gap
        for (label, width) in zip(labels, capWidths) {
            drawCap(label, in: CGRect(x: x, y: middle - capHeight / 2 + 0.75, width: width, height: capHeight), colours: colours)
            x += width + tooltipCapGap
        }
        return (context.makeImage(), size)
    }

    /// The tooltip's words and caps for `name` measured without drawing
    /// them, as `tooltipWords` lays them out: its width and height.
    @MainActor static func tooltipSize(_ name: String, fitting: CGFloat = .infinity) -> CGSize {
        tooltipLayout(name, fitting: fitting).size
    }

    private static let tooltipCapGap: CGFloat = 4

    /// The tooltip's layout: the words' width, the caps' labels and widths,
    /// symbols where the names would not fit, and the whole size.
    @MainActor private static func tooltipLayout(_ name: String, fitting: CGFloat)
        -> (wordsWidth: CGFloat, labels: [NSAttributedString], capWidths: [CGFloat], size: CGSize) {
        let wordsWidth = text("Dictate", 13, .semibold).size().width.rounded(.up)
        let parts = name.components(separatedBy: " + ")
        func widths(_ labels: [NSAttributedString]) -> [CGFloat] { labels.map { Piece.cap($0).width } }
        func total(_ widths: [CGFloat]) -> CGFloat { wordsWidth + gap + widths.reduce(0, +) + tooltipCapGap * CGFloat(widths.count - 1) }
        var labels = parts.map(cap)
        if total(widths(labels)) > fitting { labels = parts.map { text(symbols($0), 11.5, .semibold) } }
        let capWidths = widths(labels)
        return (wordsWidth, labels, capWidths, CGSize(width: total(capWidths), height: height))
    }

    /// `name` with each modifier's word as its symbol, whatever its case.
    private static func symbols(_ name: String) -> String {
        var short = name
        for (word, symbol) in [("Control", "⌃"), ("Option", "⌥"), ("Shift", "⇧"), ("Command", "⌘")] {
            short = short.replacingOccurrences(of: word, with: symbol, options: .caseInsensitive)
        }
        return short
    }

    /// A key's cap label: its name, or the modifiers' symbols where the name
    /// is too long for the slip.
    private static func cap(_ name: String) -> NSAttributedString {
        let label = text(name, 11.5, .semibold)
        guard label.size().width > longestKey else { return label }
        var short = name
        for (word, symbol) in [("Control", "⌃"), ("Option", "⌥"), ("Shift", "⇧"), ("Command", "⌘")] {
            short = short.replacingOccurrences(of: word, with: symbol)
        }
        return text(short.replacingOccurrences(of: " + ", with: " "), 11.5, .semibold)
    }

    private static func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSAttributedString {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: "DM Sans", .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        let font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font])
    }

    private static func tinted(_ text: NSAttributedString, _ colour: NSColor) -> NSAttributedString {
        let tinted = NSMutableAttributedString(attributedString: text)
        tinted.addAttribute(.foregroundColor, value: colour, range: NSRange(location: 0, length: tinted.length))
        return tinted
    }
}

extension FootSlip {
    /// A slip with a second key and its words after the first, as "Done",
    /// the dictation key, then esc and "cancels" while hands-free.
    init(text: String, key: String? = nil, after: String? = nil, then: (key: String, words: String)?) {
        self.init(text: text, key: key, after: after, thenKey: then?.key, thenWords: then?.words)
    }
}
