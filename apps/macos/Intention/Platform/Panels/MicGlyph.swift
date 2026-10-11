import CoreGraphics

/// The microphone the resting foot dot turns into under the pointer, in
/// place of a "Dictate" slip: the dot becomes the capsule's head, and the
/// cradle, the stem and the foot draw in under it as strokes. True geometry
/// at the mark's sizes, as the small-size rule asks: even strokes at pen
/// 1.5 with round caps, straight edges on whole pixels, no bitmap. Every
/// path is centred on the dot's own centre, in the flipped coordinates the
/// mark draws in (y grows down), and fits the 26-point envelope.
enum MicGlyph {
    /// The capsule: the head of the microphone.
    static let headWidth: CGFloat = 7
    static let headHeight: CGFloat = 11
    /// The strokes' pen.
    static let pen: CGFloat = 1.5
    /// The cradle's half circle, at its stroke's centre line.
    static let cradleRadius: CGFloat = 6.5
    /// The foot's length between its round caps' centres.
    static let footWidth: CGFloat = 6
    /// The glyph's extent with its caps, 14.5 by 18 points.
    static let size = CGSize(width: 2 * cradleRadius + pen, height: 18)

    /// The glyph's parts at a display's `scale`, with each straight edge
    /// moved to the nearest whole pixel: the capsule's sides, top and
    /// bottom, the stem's sides and the foot's top and bottom. The curves
    /// stay true.
    struct Shape: Equatable {
        /// The capsule's rectangle; its corners are half its width.
        var head: CGRect
        /// The cradle's centre and the stem's and foot's centre lines.
        var cradleCentre: CGPoint
        var stem: (top: CGPoint, bottom: CGPoint)
        var foot: (left: CGPoint, right: CGPoint)

        static func == (a: Shape, b: Shape) -> Bool {
            a.head == b.head && a.cradleCentre == b.cradleCentre && a.stem == b.stem && a.foot == b.foot
        }

        /// The capsule's outline, grown by `by` on every side.
        func headPath(grownBy by: CGFloat = 0) -> CGPath {
            let rect = head.insetBy(dx: -by, dy: -by)
            return FootSlip.outline(rect, radius: rect.width / 2)
        }

        /// The cradle, drawn from its left arm round the bottom to its right.
        var cradle: CGPath {
            let path = CGMutablePath()
            path.addArc(center: cradleCentre, radius: MicGlyph.cradleRadius, startAngle: .pi, endAngle: 0, clockwise: true)
            return path
        }

        var stemPath: CGPath {
            let path = CGMutablePath()
            path.move(to: stem.top)
            path.addLine(to: stem.bottom)
            return path
        }

        var footPath: CGPath {
            let path = CGMutablePath()
            path.move(to: foot.left)
            path.addLine(to: foot.right)
            return path
        }

        /// Everything the glyph covers with its pen, for the click target.
        var bounds: CGRect {
            let half = MicGlyph.pen / 2
            let cradle = CGRect(x: cradleCentre.x - MicGlyph.cradleRadius - half, y: cradleCentre.y - half,
                                width: 2 * (MicGlyph.cradleRadius + half), height: MicGlyph.cradleRadius + 2 * half)
            let feet = CGRect(x: foot.left.x - half, y: foot.left.y - half, width: foot.right.x - foot.left.x + 2 * half, height: 2 * half)
            return head.union(cradle).union(feet)
        }
    }

    /// The glyph at `scale`. The cradle's arms stand at the capsule's lower
    /// third, with the same gap under the capsule as beside it.
    static func shape(scale: CGFloat) -> Shape {
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let top = -size.height / 2
        // The capsule's left side on a pixel, the glyph moving with it.
        let shift = snap(-headWidth / 2) + headWidth / 2
        let head = CGRect(x: -headWidth / 2 + shift, y: snap(top), width: headWidth, height: headHeight)
        let cradleCentre = CGPoint(x: head.midX, y: head.maxY - 3.5)
        let stemX = snap(head.midX - pen / 2) + pen / 2
        let footTop = snap(-top - pen)
        let footY = footTop + pen / 2
        return Shape(head: head, cradleCentre: cradleCentre,
                     stem: (CGPoint(x: stemX, y: cradleCentre.y + cradleRadius), CGPoint(x: stemX, y: footY)),
                     foot: (CGPoint(x: head.midX - footWidth / 2, y: footY), CGPoint(x: head.midX + footWidth / 2, y: footY)))
    }
}
