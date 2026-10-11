import Foundation
import CoreGraphics

/// Two-state blink evidence, in native pixels. A single difference is never
/// enough: it could be typing, a selection or a repaint. Three alternating
/// transitions must affect the same filled stem or terminal block and nothing else in the crop.
struct BlinkCaretDetector {
    struct Frame {
        let width: Int
        let height: Int
        let pixels: [UInt8] // RGBA, top row first
    }

    struct RGB: Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }
    private(set) var ink: RGB?
    private var previous: Frame?
    private var settled: Frame?
    private var phase: Frame?
    private var candidate: CGRect?
    private var transitions = 0
    private var lastTransition: TimeInterval?
    private var lastSample: TimeInterval?
    /// Set when the candidate came from one frame just after focus or input
    /// rather than from blinking, until a blink of that stroke confirms it.
    private var seeded = false
    private var seedConfirmed = false

    /// The current candidate was confirmed by blinking, not only by one frame.
    var confirmed: Bool { candidate != nil && transitions >= 3 && (!seeded || seedConfirmed) }

    mutating func reset() { self = Self() }

    var hasCandidate: Bool { candidate != nil }

    /// Apps draw the caret solid for about half a second after focus or
    /// input before it starts blinking.
    static let solidCaretInterval: TimeInterval = 0.45

    /// How long unchanged frames keep the caret after its last transition.
    /// A seeded caret can stay solid for a second or more after input before
    /// it starts blinking, as Terminal's does; until a blink confirms it, it
    /// is kept for up to `seededHold`.
    static let seededHold: TimeInterval = 3
    private var holdWithoutTransition: TimeInterval { seeded && !seedConfirmed ? Self.seededHold : 0.9 }

    /// Accepts a caret found in a single frame just after focus or input,
    /// when apps draw the caret solid. Later frames keep it only while every
    /// change stays on it, as blinking does.
    mutating func seed(_ rect: CGRect, in frame: Frame, time: TimeInterval) {
        reset()
        previous = frame
        settled = frame
        phase = frame
        candidate = rect
        transitions = 3
        lastTransition = time
        lastSample = time
        seeded = true
        ink = color(frame, in: rect)?.ink
    }

    /// The caret in one frame of a field while it is drawn solid: the only
    /// thin vertical stroke clearly taller than every other ink column. Text
    /// and placeholder glyphs are shorter than the caret, which spans the
    /// whole line. Edge columns and rows are excluded, since they hold the
    /// field's border and focus ring. Returns native-pixel coordinates.
    static func solidCaret(in frame: Frame, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, scale >= 1, frame.width > 8, frame.height > 8,
              frame.pixels.count == frame.width * frame.height * 4 else { return nil }
        let width = frame.width, height = frame.height
        let margin = max(2, Int((2 * scale).rounded()))
        guard width > margin * 2 + 1, height > margin * 2 + 1 else { return nil }
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for i in stride(from: 0, to: frame.pixels.count, by: 4) {
            let r = Int(frame.pixels[i]), g = Int(frame.pixels[i + 1]), b = Int(frame.pixels[i + 2])
            let key = (r / 16) * 256 + (g / 16) * 16 + b / 16
            let old = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (old.count + 1, old.red + r, old.green + g, old.blue + b)
        }
        // One colour covers at least a third of the crop. A crop can span a
        // window's background and a lighter input box, as in Codex.
        guard let background = buckets.values.max(by: { $0.count < $1.count }),
              background.count * 3 >= width * height else { return nil }
        let bg = (background.red / background.count, background.green / background.count, background.blue / background.count)
        func ink(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return max(abs(Int(frame.pixels[i]) - bg.0), abs(Int(frame.pixels[i + 1]) - bg.1),
                       abs(Int(frame.pixels[i + 2]) - bg.2)) >= 48
        }
        // The longest vertical ink run in each column.
        var runs: [(x: Int, top: Int, length: Int)] = []
        for x in 0..<width {
            var best = (top: 0, length: 0), start: Int?
            for y in 0..<height {
                if ink(x, y) {
                    if start == nil { start = y }
                } else if let top = start {
                    if y - top > best.length { best = (top, y - top) }
                    start = nil
                }
            }
            if let top = start, height - top > best.length { best = (top, height - top) }
            // A column at the field's side edge that is ink from top to
            // bottom is its border. A caret can sit at that edge, as in
            // composers whose frame starts at their text, but leaves a gap.
            if x < margin || x >= width - margin, best.length >= height - 1 { continue }
            runs.append((x, best.top, best.length))
        }
        // In a crop taller than about two lines, a stroke through its top or
        // bottom edge is a box's side or a divider, as a composer's is in a
        // band around it; only a one-line crop holds a caret that spans it.
        if CGFloat(height) > 40 * scale {
            runs = runs.filter { $0.top >= margin && $0.top + $0.length <= height - margin }
        }
        // In a field taller than a line, a stroke through its top or bottom
        // edge is a border, divider or window corner, never the caret, and
        // does not compete with it. A field about one line tall, as chat
        // composers are, holds a caret that spans it.
        if let tallest = runs.map(\.length).max(), CGFloat(height) > CGFloat(tallest) * 1.6 {
            runs = runs.filter { $0.top >= margin && $0.top + $0.length <= height - margin }
        }
        // A stroke taller than any caret is a box's side or a divider.
        runs = runs.filter { CGFloat($0.length) <= 80 * scale }
        guard let longest = runs.map(\.length).max(), CGFloat(longest) >= 8 * scale else { return nil }
        let tall = runs.filter { Double($0.length) >= Double(longest) * 0.9 }
        guard let first = tall.first, let last = tall.last,
              last.x - first.x + 1 == tall.count, CGFloat(tall.count) <= 3 * scale,
              !zip(tall, tall.dropFirst()).contains(where: { $1.x != $0.x + 1 }),
              runs.allSatisfy({ run in tall.contains(where: { $0.x == run.x }) || Double(run.length) < Double(longest) * 0.8 })
        else { return nil }
        let top = tall.map(\.top).min()!, bottom = tall.map { $0.top + $0.length }.max()!
        // A stroke through a tall field's top or bottom edge is a divider or
        // border. A field about one line tall, as chat composers are, holds
        // a caret that spans it; its side borders were excluded above.
        let oneLine = CGFloat(height) <= CGFloat(longest) * 1.6
        guard oneLine || (top >= margin && bottom <= height - margin) else { return nil }
        return CGRect(x: first.x, y: top, width: tall.count, height: bottom - top)
    }

    mutating func observe(_ frame: Frame, scale: CGFloat, time: TimeInterval) -> CGRect? {
        guard scale.isFinite, scale >= 1, frame.width > 0, frame.height > 0,
              frame.width <= 4096, frame.height <= 4096,
              frame.pixels.count == frame.width * frame.height * 4 else {
            reset()
            return nil
        }
        if let lastSample, time <= lastSample || time - lastSample > 0.35 { reset() }
        lastSample = time
        defer { previous = frame }
        guard let previous, previous.width == frame.width, previous.height == frame.height else {
            reset()
            lastSample = time
            return nil
        }
        // AppKit fades its insertion indicator through several partial stems.
        // Those intermediate samples are not alternating blink phases. Compare
        // endpoints only after two consecutive samples agree within the noise
        // threshold. A change elsewhere still invalidates acquired evidence.
        let sampleDifference = changedBounds(previous, frame)
        if sampleDifference.count != 0 {
            if let candidate, !(seeded ? candidate.insetBy(dx: -scale, dy: -scale) : candidate).contains(sampleDifference.rect) {
                reset()
                lastSample = time
                return nil
            }
            guard transitions >= 3, let lastTransition, time - lastTransition <= holdWithoutTransition else { return nil }
            return candidate
        }
        guard let settled else {
            self.settled = frame
            return nil
        }
        defer { self.settled = frame }
        let difference = changedBounds(settled, frame)
        if difference.count == 0 {
            guard transitions >= 3, let lastTransition, time - lastTransition <= holdWithoutTransition else { return nil }
            return candidate
        }
        let rect = difference.rect
        let interval = lastTransition.map { time - $0 }
        if seeded, let candidate, candidate.insetBy(dx: -scale, dy: -scale).contains(rect) {
            // The seeded caret blinking confirms it.
            phase = settled
            lastTransition = time
            seedConfirmed = true
            return candidate
        }
        // Reject underlines, partial stems, text redraws and multiple blinking
        // regions. The one-pixel rim also refuses clipped edge candidates.
        guard rect.minX >= 1, rect.minY >= 1,
              rect.maxX < CGFloat(frame.width), rect.maxY < CGFloat(frame.height),
              rect.width <= 16 * scale, rect.width <= rect.height * 0.8,
              rect.height >= 8 * scale, rect.height <= 80 * scale,
              Double(difference.count) >= Double(rect.width * rect.height) * 0.9 else {
            reset()
            lastSample = time
            return nil
        }
        if candidate == rect, let interval, (0.2...0.9).contains(interval),
           let phase, changedBounds(phase, frame).count == 0 {
            transitions += 1
        } else {
            transitions = 1
        }
        if let before = color(settled, in: rect), let after = color(frame, in: rect) {
            ink = before.contrast > after.contrast ? before.ink : after.ink
        } else {
            ink = nil
        }
        phase = settled
        candidate = rect
        lastTransition = time
        return transitions >= 3 ? rect : nil
    }

    /// Estimate the background from the dominant color in a wider patch.
    /// Immediate neighbours can be glyph stems and cannot identify the blank
    /// phase reliably. A patterned background without a dominant color denies ink.
    private func color(_ frame: Frame, in rect: CGRect) -> (ink: RGB, contrast: CGFloat)? {
        let padding = max(8, min(32, Int(rect.height / 2)))
        let x0 = max(0, Int(rect.minX) - padding), x1 = min(frame.width, Int(rect.maxX) + padding)
        let y0 = max(0, Int(rect.minY) - padding), y1 = min(frame.height, Int(rect.maxY) + padding)
        var buckets: [Int: (count: Int, red: Double, green: Double, blue: Double)] = [:]
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 where !rect.contains(CGPoint(x: x, y: y)) {
                let i = (y * frame.width + x) * 4
                let r = Int(frame.pixels[i]), g = Int(frame.pixels[i + 1]), b = Int(frame.pixels[i + 2])
                let key = (r / 16) * 256 + (g / 16) * 16 + b / 16
                let old = buckets[key] ?? (0, 0, 0, 0)
                buckets[key] = (old.count + 1, old.red + Double(r), old.green + Double(g), old.blue + Double(b))
                count += 1
            }
        }
        guard let background = buckets.values.max(by: { $0.count < $1.count }),
              Double(background.count) >= Double(count) * 0.5 else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * frame.width + x) * 4
                red += Double(frame.pixels[i]); green += Double(frame.pixels[i + 1]); blue += Double(frame.pixels[i + 2])
            }
        }
        let area = Double(rect.width * rect.height) * 255
        let divisor = Double(background.count) * 255
        let ink = RGB(red: red / area, green: green / area, blue: blue / area)
        let contrast = max(abs(ink.red - background.red / divisor), abs(ink.green - background.green / divisor), abs(ink.blue - background.blue / divisor))
        return (ink, CGFloat(contrast))
    }

    private func changedBounds(_ a: Frame, _ b: Frame) -> (rect: CGRect, count: Int) {
        var minX = b.width, minY = b.height, maxX = -1, maxY = -1, count = 0
        for y in 0..<b.height {
            for x in 0..<b.width {
                let i = (y * b.width + x) * 4
                let delta = max(abs(Int(a.pixels[i]) - Int(b.pixels[i])),
                                abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1])),
                                abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2])))
                if delta >= 32 {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return (count == 0 ? .zero : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), count)
    }
}
