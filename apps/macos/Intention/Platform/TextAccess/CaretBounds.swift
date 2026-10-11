import ApplicationServices
import Foundation

/// Where a field's insertion point is on screen, from Accessibility bounds
/// alone. A preceding character is inspected only to exclude a trailing
/// newline or corroborate a boundary. Rectangles are in Accessibility
/// coordinates.
enum CaretBounds {
    /// How a text engine reports the bounds of a zero-length range.
    enum CollapsedMode: Equatable, Sendable {
        /// The rectangle is the painted insertion point.
        case direct
        /// The x is right but the rectangle is one line above the painted
        /// insertion point. AppKit text views do this for every collapsed
        /// range, including empty fields, empty lines and both wrap
        /// affinities, while their character bounds are correct.
        case lineAbove
    }

    /// The insertion point of a native text view from its collapsed range,
    /// which answers where character pairs cannot: empty fields, empty lines,
    /// one-character fields and wraps. An adjacent character decides the
    /// engine's collapsed mode whenever one is on the caret's line; `mode`
    /// carries what was learned for the app.
    static func nativeInsertionPoint(in element: AXElement, at location: Int, field: CGRect?, mode: inout CollapsedMode?) -> CGRect? {
        guard let collapsed = bounds(element, FieldRange(location: location, length: 0)), collapsed.width <= 2 else {
            return insertionPoint(in: element, at: location)
        }
        for index in [location, location - 1] where index >= 0 {
            guard let character = bounds(element, FieldRange(location: index, length: 1)) else { continue }
            // A line break's box sits at the start of the empty line above
            // the caret, level with AppKit's raised collapsed range; it
            // would teach the wrong mode.
            if index < location, (try? element.string(for: FieldRange(location: index, length: 1)).get())?
                .unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) != false { continue }
            if let learned = collapsedMode(collapsed: collapsed, character: character) {
                mode = learned
                break
            }
        }
        return placed(collapsed, mode: mode ?? containedMode(collapsed, in: field) ?? .lineAbove)
    }

    /// A character on the caret's line shares the collapsed range's height
    /// and has an edge at its x; its top then shows which mode applies.
    /// Characters on another line fail the x test and decide nothing.
    static func collapsedMode(collapsed: CGRect, character: CGRect) -> CollapsedMode? {
        guard usable(collapsed), usable(character), character.width > 0,
              abs(collapsed.height - character.height) <= 0.5,
              min(abs(collapsed.minX - character.minX), abs(collapsed.minX - character.maxX)) <= 1 else { return nil }
        let rise = character.minY - collapsed.minY
        if abs(rise) <= 0.5 { return .direct }
        if abs(rise - collapsed.height) <= 0.5 { return .lineAbove }
        return nil
    }

    /// Without a character to compare, the field decides when exactly one
    /// reading lies inside it.
    static func containedMode(_ collapsed: CGRect, in field: CGRect?) -> CollapsedMode? {
        guard let field else { return nil }
        let bounds = field.insetBy(dx: -1, dy: -1)
        let direct = bounds.contains(collapsed)
        let below = bounds.contains(collapsed.offsetBy(dx: 0, dy: collapsed.height))
        guard direct != below else { return nil }
        return direct ? .direct : .lineAbove
    }

    static func placed(_ collapsed: CGRect, mode: CollapsedMode) -> CGRect {
        line(at: collapsed.minX, mode == .lineAbove ? collapsed.offsetBy(dx: 0, dy: collapsed.height) : collapsed)
    }

    /// The insertion point in a web text control. Chromium answers a
    /// collapsed text range for inputs and textareas, and only a text marker
    /// for rich editors; empty controls answer neither with a usable
    /// rectangle. Callers exclude a control whose text is its generated
    /// placeholder, whose marker sits after the placeholder rather than at
    /// the caret.
    static func webInsertionPoint(in element: AXElement, at location: Int, field: CGRect?) -> CGRect? {
        func inside(_ rect: CGRect) -> Bool {
            guard let field else { return true }
            return field.insetBy(dx: -4, dy: -4).contains(CGPoint(x: rect.minX, y: rect.midY))
        }
        // WebKit reports the painted caret, two points wide; Chromium a
        // zero-width line. Either way the caret is centred on the rectangle.
        if let collapsed = bounds(element, FieldRange(location: location, length: 0)), collapsed.width <= 2, inside(collapsed) {
            return line(at: collapsed.midX, collapsed)
        }
        if let marker = selectedMarkerBounds(element), marker.width <= 2, inside(marker) {
            return line(at: marker.midX, marker)
        }
        if location > 0, let before = bounds(element, FieldRange(location: location - 1, length: 1)), before.width > 0, inside(before),
           let preceding = try? element.string(for: FieldRange(location: location - 1, length: 1)).get(),
           !preceding.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
            return line(at: before.maxX, before)
        }
        if let after = bounds(element, FieldRange(location: location, length: 1)), after.width > 0, inside(after) {
            return line(at: after.minX, after)
        }
        return nil
    }

    /// Where a web control's text starts: its first character's left edge,
    /// which assumes left-aligned, left-to-right text. Remembered so an
    /// emptied control keeps its caret, and used for a control whose only
    /// text is a placeholder.
    static func webTextStart(in element: AXElement, field: CGRect?) -> CGRect? {
        if let first = bounds(element, FieldRange(location: 0, length: 1)), first.width > 0,
           field.map({ $0.insetBy(dx: -4, dy: -4).contains(CGPoint(x: first.minX, y: first.midY)) }) ?? true {
            return line(at: first.minX, first)
        }
        return nil
    }

    /// Where the caret of an empty rich editor starts, from its first line's
    /// element: a placeholder text box has the caret's own top and height; a
    /// bare empty paragraph has its line box, in which the caret is centred
    /// and, on a tall line, about seven tenths of it. Left-aligned,
    /// left-to-right text is assumed. An estimate: pixels replace it.
    static func emptyEditorLine(in element: AXElement, field: CGRect?) -> CGRect? {
        var node = element
        var found: (frame: CGRect, text: Bool, leaf: Bool)?
        for _ in 0..<3 {
            guard case let .success(value) = node.value(kAXChildrenAttribute), let children = value as? [AXUIElement],
                  let first = children.first else { break }
            let child = AXElement(ref: first)
            guard case let .success(frame) = child.frame(), usable(frame), frame.height >= 8, frame.height <= 80,
                  field.map({ $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.minX, y: frame.midY)) }) ?? true else { break }
            let text = (try? child.string(kAXRoleAttribute).get()) == kAXStaticTextRole
            let grandchildren = (try? child.value(kAXChildrenAttribute).get()).flatMap { $0 as? [AXUIElement] } ?? []
            found = (frame, text, grandchildren.isEmpty)
            if text { break }
            node = child
        }
        guard let found else { return nil }
        // Chromium paints the caret one point below its text box's top
        // (measured in two placeholder fixtures, macOS 27).
        if found.text { return CGRect(x: found.frame.minX, y: found.frame.minY + 1, width: 0, height: found.frame.height) }
        var height = found.frame.height
        if found.leaf, height >= 22 { height = (height * 0.7).rounded() }
        return CGRect(x: found.frame.minX, y: found.frame.midY - height / 2, width: 0, height: height)
    }

    /// The caret of an editor that draws its own text and keeps keyboard
    /// focus in a control one or two points wide, moved to the caret so the
    /// system's input method window opens there: Monaco in Visual Studio
    /// Code and Cursor places its text area at the caret, a point wide and a
    /// line tall, and Chromium answers no text geometry for it. That frame
    /// is the caret. A control that is not also a line tall says nothing.
    static func caretFromControlFrame(_ frame: CGRect) -> CGRect? {
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width >= 0, frame.width <= 2, frame.height >= 8, frame.height <= 80 else { return nil }
        return CGRect(x: frame.midX, y: frame.minY, width: 0, height: frame.height)
    }

    /// The caret estimate of a focused web text control that reports a
    /// width but no height, as Gmail's empty compose body does in Chromium
    /// (944 by 0 points on October 7, 2026), which answers no text geometry,
    /// has no line element and is too flat to capture: a line 18 points
    /// tall at the control's top-left corner, where such a body draws its
    /// caret. An estimate: pixels in `flatControlBand` confirm it.
    static func flatControlLine(_ frame: CGRect) -> CGRect? {
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width >= 40, frame.height >= 0, frame.height <= 2 else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: 0, height: 18)
    }

    /// Where pixels look for the caret of such a flat control: forty points
    /// below its top edge and four above, its own width, inside `bounds`.
    /// Its caret is on the first line, and a field laid out below it stays
    /// out of the band.
    static func flatControlBand(below control: CGRect, within bounds: CGRect) -> CGRect {
        CGRect(x: control.minX, y: control.minY - 4, width: control.width, height: 44).intersection(bounds)
    }

    /// Where pixels look for the caret of such a control: a band five lines
    /// tall and 150 points to either side of it, inside `bounds`, the
    /// nearest element of the control's own ancestry large enough to be
    /// its editor.
    static func controlBand(around control: CGRect, within bounds: CGRect) -> CGRect {
        CGRect(x: control.minX - 150, y: control.midY - control.height * 2.5, width: control.width + 300, height: control.height * 5)
            .intersection(bounds)
    }

    static func selectedMarkerBounds(_ element: AXElement) -> CGRect? {
        guard case let .success(marker) = element.value("AXSelectedTextMarkerRange"),
              case let .success(value) = element.parameterized("AXBoundsForTextMarkerRange", marker),
              case let .success(rect) = AXElement.decodeRect(value), usable(rect) else { return nil }
        return rect
    }

    /// The insertion point at a UTF-16 location, as a zero-width line.
    ///
    /// Same-line character pairs resolve the interior first. At native
    /// boundaries and wraps, a collapsed range can corroborate exactly one
    /// edge of the adjacent character while that character supplies vertical
    /// geometry. The character after the caret is tried before the one before
    /// it, because at the start of a line the one before is the previous
    /// line's line break.
    static func insertionPoint(in element: AXElement, at location: Int) -> CGRect? {
        let after = bounds(element, FieldRange(location: location, length: 1))
        let before = location > 0 ? bounds(element, FieldRange(location: location - 1, length: 1)) : nil
        if let after, let before, abs(before.minY - after.minY) < 0.5,
           abs(before.height - after.height) < 0.5 {
            // Logical character order is reversed inside RTL text. A shared
            // edge corroborated by both neighbours resolves either direction
            // without treating a collapsed-range anchor as caret evidence.
            return sharedInsertionPoint(before: before, after: after)
        }
        if let after, let collapsed = bounds(element, FieldRange(location: location, length: 0)),
           let witness = nativeBoundaryInsertionPoint(collapsed: collapsed, character: after) {
            return witness
        }
        if let after, before == nil, location == 0 {
            // If the source omits the collapsed range, two characters can
            // still prove a document-start edge. A one-character field stays
            // unresolved instead of assuming left-to-right text.
            guard let following = bounds(element, FieldRange(location: location + 1, length: 1)) else { return nil }
            return oppositeBoundaryInsertionPoint(edge: after, neighbor: following, edgePrecedesNeighbor: true)
        }
        if let before {
            // A trailing newline's character box occupies the old line.
            // Its right edge is not the insertion point on the new empty line.
            guard let preceding = try? element.string(for: FieldRange(location: location - 1, length: 1)).get(),
                  !preceding.isEmpty,
                  !preceding.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else { return nil }
            if let collapsed = bounds(element, FieldRange(location: location, length: 0)),
               let witness = nativeBoundaryInsertionPoint(collapsed: collapsed, character: before) {
                return witness
            }
            // If the source omits the collapsed range, corroborate the last
            // character's direction from its predecessor. One-character,
            // wrapped, overlapping, or bidi-ambiguous cases remain hidden.
            guard location > 1,
                  let previous = bounds(element, FieldRange(location: location - 2, length: 1)) else { return nil }
            return oppositeBoundaryInsertionPoint(edge: before, neighbor: previous, edgePrecedesNeighbor: false)
        }
        // A collapsed AppKit range can report the previous line's y even
        // in an empty field. It remains a pixel-search anchor, never a direct
        // placement without character geometry.
        return nil
    }

    static func sharedInsertionPoint(before: CGRect, after: CGRect) -> CGRect? {
        guard usable(before), usable(after), before.width > 0, after.width > 0,
              abs(before.minY - after.minY) < 0.5, abs(before.height - after.height) < 0.5 else { return nil }
        let leftToRight = abs(before.maxX - after.minX) <= 0.5
        let rightToLeft = abs(before.minX - after.maxX) <= 0.5
        guard leftToRight != rightToLeft else { return nil }
        let x = leftToRight ? (before.maxX + after.minX) / 2 : (before.minX + after.maxX) / 2
        return line(at: x, after)
    }

    /// The caret at either document boundary is the non-shared edge of its
    /// only adjacent character. Direction comes only from a same-line,
    /// uniquely shared neighbour pair; no writing-direction default is used.
    static func oppositeBoundaryInsertionPoint(edge: CGRect, neighbor: CGRect, edgePrecedesNeighbor: Bool) -> CGRect? {
        let shared = edgePrecedesNeighbor
            ? sharedInsertionPoint(before: edge, after: neighbor)
            : sharedInsertionPoint(before: neighbor, after: edge)
        guard let shared else { return nil }
        let sharesMinimum = abs(edge.minX - shared.minX) <= 0.5
        let sharesMaximum = abs(edge.maxX - shared.minX) <= 0.5
        guard sharesMinimum != sharesMaximum else { return nil }
        return line(at: sharesMinimum ? edge.maxX : edge.minX, edge)
    }

    /// AppKit's collapsed AX line box can be one character-height above the
    /// painted insertion line. It contributes only a uniquely corroborated x;
    /// the adjacent character always supplies y and height. This is native
    /// AX geometry, not a pixel or marker publication path.
    static func nativeBoundaryInsertionPoint(collapsed: CGRect, character: CGRect) -> CGRect? {
        guard usable(collapsed), usable(character), collapsed.width <= 2, character.width > 0,
              abs(collapsed.height - character.height) <= 0.5,
              abs((character.minY - collapsed.minY) - character.height) <= 0.5 else { return nil }
        let matchesMinimum = abs(collapsed.minX - character.minX) <= 0.5
        let matchesMaximum = abs(collapsed.minX - character.maxX) <= 0.5
        guard matchesMinimum != matchesMaximum else { return nil }
        return line(at: collapsed.minX, character)
    }

    /// Independent candidate rectangles for pixel validation. A marker is a
    /// candidate only; generated content can make its x incorrect.
    static func anchors(in element: AXElement, at location: Int?) -> [CaretSearchAnchor] {
        var result: [CaretSearchAnchor] = []
        if let location {
            if let rect = bounds(element, FieldRange(location: location, length: 0)), rect.width <= 2 { result.append(.init(bounds: rect, source: .textRange)) }
            if let rect = insertionPoint(in: element, at: location), !result.contains(where: { $0.bounds == rect }) { result.append(.init(bounds: rect, source: .textRange)) }
        }
        if case let .success(marker) = element.value("AXSelectedTextMarkerRange"),
           case let .success(value) = element.parameterized("AXBoundsForTextMarkerRange", marker),
           case let .success(rect) = AXElement.decodeRect(value), usable(rect), rect.width <= 2,
           !result.contains(where: { $0.bounds == rect }) { result.append(.init(bounds: rect, source: .textMarker)) }
        return result
    }

    /// The color of the text beside the insertion point, from its attributes.
    /// Accessibility returns a character with its attributes; the character
    /// is dropped here and only the color leaves this function.
    static func ink(in element: AXElement, at location: Int) -> Ink? {
        for range in [FieldRange(location: location - 1, length: 1), FieldRange(location: location, length: 1)] where range.location >= 0 {
            var cfRange = range.cfRange
            guard let parameter = AXValueCreate(.cfRange, &cfRange),
                  case let .success(value) = element.parameterized(kAXAttributedStringForRangeParameterizedAttribute, parameter),
                  CFGetTypeID(value) == CFAttributedStringGetTypeID()
            else { continue }
            let attributed = value as! CFAttributedString
            guard CFAttributedStringGetLength(attributed) > 0,
                  let color = CFAttributedStringGetAttribute(attributed, 0, "AXForegroundColor" as CFString, nil),
                  CFGetTypeID(color) == CGColor.typeID,
                  let ink = Ink(color as! CGColor)
            else { continue }
            return ink
        }
        return nil
    }

    /// Rejects the empty and document-sized rectangles some apps return.
    static func usable(_ rect: CGRect) -> Bool {
        rect.height > 0 && rect.height < 200 && rect.origin != .zero
    }

    private static func bounds(_ element: AXElement, _ range: FieldRange) -> CGRect? {
        guard case let .success(rect) = element.bounds(for: range), usable(rect) else { return nil }
        return rect
    }

    /// A caret at `x`, reported zero wide; apps draw it centred there.
    private static func line(at x: CGFloat, _ rect: CGRect) -> CGRect {
        CGRect(x: x, y: rect.minY, width: 0, height: rect.height)
    }
}

/// A text color in sRGB.
struct Ink: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    init?(_ color: CGColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = IntentionCopyMatchedColor(color, space),
              let parts = converted.components, parts.count >= 3, converted.alpha > 0.1
        else { return nil }
        red = parts[0]
        green = parts[1]
        blue = parts[2]
    }
}
