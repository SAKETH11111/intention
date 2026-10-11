import CoreGraphics

/// Where the dot goes over a caret. Pure geometry, in AppKit coordinates.
enum DotPlacement {
    /// The visible proposal sheet covers the caret even though its window
    /// passes clicks through. Both rectangles use the same coordinates;
    /// transparent shadow room is excluded from the sheet.
    static func caretCovered(_ caret: CGRect, by proposalSheet: CGRect?) -> Bool {
        proposalSheet?.intersects(caret) == true
    }

    /// Converts an Accessibility rectangle to AppKit coordinates.
    static func appKitRect(fromAccessibility rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The caret is the stem of the "i". The dot is three quarters of the
    /// caret's height across, between 8 and 16 pt: about 12 pt on 14 pt
    /// text, the size that read right beside a real caret. It sits a fifth
    /// of the caret's height above it.
    static func dotDiameter(forCaretHeight height: CGFloat) -> CGFloat {
        min(max(height * 0.75, 8), 16)
    }

    struct Dot: Equatable {
        var center: CGPoint
        var diameter: CGFloat
    }

    /// The clickable mark's geometry, also used by captions when it is hidden.
    static func anchor(for dot: Dot) -> CGRect {
        let side = dot.diameter + 4
        return CGRect(x: (dot.center.x - side / 2).rounded(), y: (dot.center.y - side / 2).rounded(), width: side, height: side)
    }

    /// The dot over a caret in AppKit coordinates, centred on the caret,
    /// which apps draw centred on the reported insertion x. `field` is the
    /// focused field's frame. Where it leaves little room above the text,
    /// as a single-line input does, the dot tucks closer to the caret but
    /// keeps its size, so it never changes between an empty field and a
    /// typed one.
    static func dot(aboveCaret line: CGRect, in field: CGRect? = nil) -> Dot {
        let diameter = dotDiameter(forCaretHeight: line.height)
        // Large fonts and tall terminal carets must retain the same small
        // visible separation rather than pushing the dot away from the stem.
        var gap = min(5, max(1, line.height * 0.2))
        if let field, field.maxY > line.maxY {
            let room = field.maxY - line.maxY - 1
            if gap + diameter > room {
                gap = max(1.5, room - diameter)
            }
        }
        let center = CGPoint(x: line.midX, y: line.maxY + gap + diameter / 2)
        return Dot(center: center, diameter: diameter)
    }
}
