import AppKit

/// Intention's mark: the listening dot over a caret, drawn as its own
/// vector here. The dot is a slightly wide oval (a true circle at small
/// sizes, see `handFrom`) and the stem a rounded caret bar.
enum OwnHandMark {
    static let dotPath = "M 62.50 -1.00 C 82.66 -1.00 99.00 14.45 99.00 33.50 C 99.00 52.55 82.66 68.00 62.50 68.00 C 42.34 68.00 26.00 52.55 26.00 33.50 C 26.00 14.45 42.34 -1.00 62.50 -1.00 Z"
    static let stemPath = "M 62.50 92.00 C 62.50 92.00 62.50 92.00 62.50 92.00 C 70.51 92.00 77.00 98.49 77.00 106.50 C 77.00 147.83 77.00 189.17 77.00 230.50 C 77.00 238.51 70.51 245.00 62.50 245.00 C 62.50 245.00 62.50 245.00 62.50 245.00 C 54.49 245.00 48.00 238.51 48.00 230.50 C 48.00 189.17 48.00 147.83 48.00 106.50 C 48.00 98.49 54.49 92.00 62.50 92.00 Z"

    /// The dot's colour while a dictation records, on the caret and in
    /// the popup alike: a red a little warmer than the system's, so it sits with
    /// the paper and ink.
    static let recording = NSColor(srgbRed: 0.86, green: 0.25, blue: 0.21, alpha: 1)
    /// The menu bar mark's dot when a dictation was not inserted: the
    /// one warm attention mark, #E0784F.
    static let attention = NSColor(srgbRed: 0xE0 / 255, green: 0x78 / 255, blue: 0x4F / 255, alpha: 1)

    /// View box of the dot alone and of the full mark.
    static let dotBox = CGRect(x: 26, y: -1, width: 73, height: 69)
    static let markBox = CGRect(x: -5, y: -5, width: 124, height: 256)

    /// Parses the absolute M, C and Z commands used by the paths above.
    static func cgPath(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var numbers: [CGFloat] = []
        var command: Character = " "
        func flush() {
            switch command {
            case "M" where numbers.count >= 2:
                path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "C" where numbers.count >= 6:
                path.addCurve(
                    to: CGPoint(x: numbers[4], y: numbers[5]),
                    control1: CGPoint(x: numbers[0], y: numbers[1]),
                    control2: CGPoint(x: numbers[2], y: numbers[3])
                )
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers.removeAll()
        }
        for token in data.split(separator: " ") {
            if let first = token.first, first.isLetter {
                flush()
                command = first
                if command == "Z" { flush() }
            } else if let value = Double(token) {
                numbers.append(CGFloat(value))
            }
        }
        flush()
        return path
    }

    /// Below this width the dot is a true circle. The oval belongs to the
    /// large surfaces (setup and the menu bar's logo); at a dot's size it
    /// would read as poor anti-aliasing, so every small dot is round.
    nonisolated static let handFrom: CGFloat = 20

    /// The mark's dot `diameter` wide, and the size of its box: from
    /// `handFrom` up the mark's own oval, not a circle, with y growing
    /// downward; below it a true circle.
    static func dot(diameter: CGFloat) -> (path: CGPath, size: CGSize) {
        guard diameter >= handFrom else {
            return (CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter), transform: nil),
                    CGSize(width: diameter, height: diameter))
        }
        let scale = min(diameter / dotBox.width, diameter / dotBox.height)
        var transform = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -dotBox.minX, y: -dotBox.minY)
        let path = cgPath(dotPath).copy(using: &transform) ?? CGMutablePath()
        return (path, CGSize(width: dotBox.width * scale, height: dotBox.height * scale))
    }

    /// The full mark for the menu bar: a template image, or with `dot` the
    /// mark's dot in that colour and its stem in the menu bar's text colour,
    /// as dictation uses to show it is recording.
    static func menuBarImage(height: CGFloat = 16, dot: NSColor? = nil) -> NSImage {
        let scale = height / markBox.height
        let size = NSSize(width: ceil(markBox.width * scale), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -markBox.minX, y: -markBox.minY)
            context.addPath(cgPath(stemPath))
            context.setFillColor((dot == nil ? NSColor.black : NSColor.labelColor).cgColor)
            context.fillPath()
            context.addPath(cgPath(dotPath))
            context.setFillColor((dot ?? NSColor.black).cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = dot == nil
        image.accessibilityDescription = "Intention"
        return image
    }
}

/// The resting dot as every surface that draws it shows it: solid, with a
/// hairline of the other tone round it along this outline, so it is found
/// at a glance on any desktop or page. By day ink inside a toned-down paper,
/// by night paper inside the night's blue. Either tone stands 3:1 or more
/// against whatever is behind it. Kept here, beside the dot's shape, so the
/// foot mark and setup's own dots share one set of values.
extension OwnHandMark {
    /// The hairline's width, an even ring just outside the dot.
    nonisolated static let restEdge: CGFloat = 1.5

    /// The resting dot `diameter` wide, `scale` times, as two true circles
    /// round `centre`: the hairline's disc, `restEdge` wider each side, and
    /// the dot drawn over it. A disc under the dot rather than a stroked
    /// ring, since a ring's inner edge and the dot's would each be
    /// anti-aliased on the same circle and let the desktop show through
    /// between them as a faint seam; this way the ring's inner edge is the
    /// dot's own, over the opaque hairline ink.
    nonisolated static func restingDot(diameter: CGFloat, scale: CGFloat = 1, centre: CGPoint = .zero) -> (edge: CGPath, core: CGPath) {
        func circle(_ width: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: centre.x - width / 2, y: centre.y - width / 2, width: width, height: width), transform: nil)
        }
        return (circle((diameter + 2 * restEdge) * scale), circle(diameter * scale))
    }

    /// The resting dot's solid ink: the ink by day, the paper by night.
    nonisolated static func restInk(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.933, green: 0.937, blue: 0.914, alpha: 1)
            : NSColor(srgbRed: 0.125, green: 0.165, blue: 0.180, alpha: 1)
    }

    /// The hairline round it: paper a little toned down so it does not glare
    /// on a dark desktop by day, the night's blue by night.
    nonisolated static func restEdgeInk(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0x14 / 255.0, green: 0x1F / 255.0, blue: 0x40 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xE6 / 255.0, green: 0xE7 / 255.0, blue: 0xE2 / 255.0, alpha: 1)
    }
}
