import CoreGraphics

/// Independent painted-pixel oracle for the lab's green caret and gray or
/// green dot. It shares no detector or placement code with the candidate.
enum CaretPixelOracle {
    static func locate(_ pixels: [UInt8], width: Int, height: Int, scale: CGFloat, dark: Bool, allowedCaret: CGRect? = nil, background: [UInt8]? = nil) -> (caret: CGRect?, dot: CGRect?) {
        var green = [Bool](repeating: false, count: width * height)
        var mask = green
        for i in mask.indices {
            let p = i * 4
            green[i] = Int(pixels[p + 1]) - Int(pixels[p]) > 45 && Int(pixels[p + 1]) - Int(pixels[p + 2]) > 45
            let darkBackground = dark
            let grayInk = darkBackground
                ? min(pixels[p], pixels[p + 1], pixels[p + 2]) > 90
                : max(pixels[p], pixels[p + 1], pixels[p + 2]) < 190
            if let background, background.count == pixels.count {
                mask[i] = (0..<3).contains { abs(Int(pixels[p + $0]) - Int(background[p + $0])) >= 16 }
            } else { mask[i] = green[i] || grayInk }
        }
        func components(_ input: [Bool]) -> [CGRect] {
            var mask = input
            var components: [CGRect] = []
            for i in mask.indices where mask[i] {
                var queue = [i], index = 0, left = i % width, right = left, top = i / width, bottom = top
                mask[i] = false
                while index < queue.count {
                    let p = queue[index]; index += 1
                    let x = p % width, y = p / width
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                    for (nx, ny) in [(x-1,y), (x+1,y), (x,y-1), (x,y+1)] where nx >= 0 && nx < width && ny >= 0 && ny < height {
                        let n = ny * width + nx
                        if mask[n] { mask[n] = false; queue.append(n) }
                    }
                }
                if queue.count >= 4 { components.append(CGRect(x: CGFloat(left)/scale, y: CGFloat(top)/scale, width: CGFloat(right-left+1)/scale, height: CGFloat(bottom-top+1)/scale)) }
            }
            return components
        }
        let stems = components(green).filter { $0.width <= 3 && $0.height >= 8 && (allowedCaret?.contains($0) ?? true) }
        var stem = stems.count == 1 ? stems[0] : nil
        var bareStemRect: CGRect?
        if let background, background.count == pixels.count {
            let bareGreen = mask.indices.map { i in
                let p = i * 4
                return Int(background[p + 1]) - Int(background[p]) > 45 && Int(background[p + 1]) - Int(background[p + 2]) > 45
            }
            let bareStems = components(bareGreen).filter { $0.width <= 3 && $0.height >= 8 && (allowedCaret?.contains($0) ?? true) }
            bareStemRect = bareStems.count == 1 ? bareStems[0] : nil
            if bareStems.count == 1 {
                let expected = bareStems[0]
                var foreground = 0, total = 0
                for y in Int(expected.minY * scale)..<Int(expected.maxY * scale) {
                    for x in Int(expected.minX * scale)..<Int(expected.maxX * scale) {
                        let i = y * width + x, p = i * 4
                        let ink = dark ? min(pixels[p], pixels[p + 1], pixels[p + 2]) > 90 : max(pixels[p], pixels[p + 1], pixels[p + 2]) < 190
                        if green[i] || ink { foreground += 1 }
                        total += 1
                    }
                }
                // The composite must itself contain foreground at the expected
                // stem. A blink transition between captures is not evidence.
                // A dot covering/joining the stem therefore fails placement
                // instead of silently disappearing from the denominator.
                if foreground * 2 >= total, stem == nil || expected.contains(stem!) { stem = expected }
            }
        }
        // A field border or the previous line's glyphs can cross the dot
        // where their ink matches the dot's, leaving thin holes in the
        // difference image. Bridge gaps of up to two pixels between changed
        // pixels along rows and columns; a real gap between dot and stem is
        // not in the difference image.
        var bridged = mask
        if background != nil {
            // A blink between the two captures puts the stem itself in the
            // difference image; it must not be bridged into the dot.
            for rect in [stem, bareStemRect].compactMap({ $0 }) {
                let x0 = max(0, Int(rect.minX * scale) - 1), x1 = min(width, Int(rect.maxX * scale) + 1)
                let y0 = max(0, Int(rect.minY * scale)), y1 = min(height, Int(rect.maxY * scale))
                for y in y0..<y1 { for x in x0..<x1 { mask[y * width + x] = false; bridged[y * width + x] = false } }
            }
            for x in 0..<width {
                var lastChanged = -10
                for y in 0..<height where mask[y * width + x] {
                    if y - lastChanged > 1, y - lastChanged <= 3 {
                        for fill in (lastChanged + 1)..<y { bridged[fill * width + x] = true }
                    }
                    lastChanged = y
                }
            }
            for y in 0..<height {
                var lastChanged = -10
                for x in 0..<width where mask[y * width + x] {
                    if x - lastChanged > 1, x - lastChanged <= 3 {
                        for fill in (lastChanged + 1)..<x { bridged[y * width + fill] = true }
                    }
                    lastChanged = x
                }
            }
        }
        let dots = components(bridged).filter {
            $0.width >= 5 && $0.width <= 20 && $0.height >= 5 && $0.height <= 20 && abs($0.width - $0.height) < 3
                && (stem == nil || ($0.maxY <= stem!.minY && stem!.minY - $0.maxY < 32 && abs($0.midX - stem!.midX) < 32))
        }
        let dot = dots.count == 1 ? dots[0] : nil
        return (stem, dot)
    }

    static func selfCheck() -> Bool {
        let width = 140, height = 100
        func raster(dark: Bool = false, dotX: Int? = 65, dotY: Int = 38, glyph: Bool = false, extraCaret: Bool = false) -> [UInt8] {
            var pixels = [UInt8](repeating: dark ? 32 : 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    pixels[i+3] = 255
                    if (64..<66).contains(x) && (50..<70).contains(y) || extraCaret && (95..<97).contains(x) && (50..<70).contains(y) {
                        pixels[i] = 0; pixels[i+1] = 255; pixels[i+2] = 0
                    }
                    if let dotX, pow(Double(x)+0.5-Double(dotX), 2) + pow(Double(y)+0.5-Double(dotY), 2) < 64 {
                        pixels[i] = 160; pixels[i+1] = 160; pixels[i+2] = 160
                    }
                    if glyph && (48..<58).contains(x) && (53..<69).contains(y) {
                        pixels[i] = 140; pixels[i+1] = 140; pixels[i+2] = 140
                    }
                }
            }
            return pixels
        }
        func read(_ pixels: [UInt8], dark: Bool = false, scale: CGFloat = 1) -> (caret: CGRect?, dot: CGRect?) {
            locate(pixels, width: width, height: height, scale: scale, dark: dark)
        }
        var behind = raster(dotX: nil)
        var over = raster()
        for y in 28..<48 {
            for x in 62..<65 {
                let i = (y * width + x) * 4
                for c in 0..<3 {
                    behind[i + c] = 90
                    let inside = pow(Double(x) + 0.5 - 65, 2) + pow(Double(y) + 0.5 - 38, 2) < 64
                    over[i + c] = inside ? 130 : 90
                }
            }
        }
        let overlapping = locate(over, width: width, height: height, scale: 1, dark: false, background: behind)
        var bordered = raster(), borderBare = raster(dotX: nil)
        for x in 0..<width {
            let i = (38 * width + x) * 4
            for c in 0..<3 { bordered[i + c] = 160; borderBare[i + c] = 160 }
        }
        let crossed = locate(bordered, width: width, height: height, scale: 1, dark: false, background: borderBare)
        var glyphed = raster(), glyphBare = raster(dotX: nil)
        for y in 28..<48 {
            for x in [61, 64, 67] {
                let i = (y * width + x) * 4
                for c in 0..<3 { glyphed[i + c] = 160; glyphBare[i + c] = 160 }
            }
        }
        let overGlyphs = locate(glyphed, width: width, height: height, scale: 1, dark: false, background: glyphBare)
        let unchanged = locate(behind, width: width, height: height, scale: 1, dark: false, background: behind)
        let touching = locate(raster(dotY: 48), width: width, height: height, scale: 1, dark: false, background: raster(dotX: nil))
        let covered = locate(raster(dotY: 60), width: width, height: height, scale: 1, dark: false, background: raster(dotX: nil))
        let good = read(raster())
        let dark = read(raster(dark: true), dark: true)
        let missing = read(raster(dotX: nil, glyph: true))
        let moved = read(raster(dotX: 70))
        let gap = read(raster(dotY: 25))
        let ambiguous = read(raster(extraCaret: true))
        let retina = read(raster(), scale: 2)
        let outside = locate(raster(), width: width, height: height, scale: 1, dark: false, allowedCaret: CGRect(x: 0, y: 0, width: 20, height: 100))
        return crossed.dot?.midX == 65 && crossed.dot?.height == 16 && overGlyphs.dot?.midX == 65 && overGlyphs.dot?.width == 16 && touching.caret != nil && touching.dot == nil && covered.caret != nil && covered.dot == nil && overlapping.dot?.midX == 65 && unchanged.dot == nil && good.caret?.midX == 65 && good.dot?.midX == 65 && good.caret!.minY - good.dot!.maxY == 4
            && dark.dot?.midX == 65 && missing.dot == nil && missing.caret != nil
            && moved.dot!.midX - moved.caret!.midX == 5 && gap.caret!.minY - gap.dot!.maxY == 17
            && ambiguous.caret == nil && retina.caret?.midX == 32.5 && outside.caret == nil
    }
}
