import AppKit
import SwiftUI

// The entry point of the small bundle scripts/foot-shots.sh builds: the foot
// mark's sources without the rest of the app. `--foot-snapshots <directory>`
// draws the foot mark in each of its states on a made-up desk, by day and by
// night on a light and a dark desktop, then quits. `--foot-demo <seconds>`
// plays one dictation on four desks at once, the sun and the moon each on a
// light and a dark desktop, in a window behind the desktop picture, drawn and
// animated like any window yet never seen, for scripts/foot-video.sh to
// record by its title, then quits. `--foot-voice <seconds> <file.wav>
// <live|chunks> [composer]` plays a 16 kHz mono recording's loudness into the four
// desks instead, the key held for the whole file: `live` as Intention takes
// it, each 20 ms through `LevelFollower`, `chunks` as builds through 0.1.8
// took it, each 100 ms chunk's level as it ended; `composer` puts a chat
// app's composer at each foot, where the caret dot shows the voice instead.
// The sound is never played
// and nothing of it is kept. The placement's renders and drag video are in
// FootPlacementShots.swift. Every word on the desks is made up.
@main
struct FootShots: GuardedRender {
    /// The demo window's title, which `RecordWindow` finds it by.
    static let demoTitle = "Intention foot demo"

    @MainActor
    static func render() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        SetupStyle.registerFonts()
        if let index = arguments.firstIndex(of: "--foot-snapshots"), arguments.indices.contains(index + 1) {
            var failed: Bool?
            Task {
                do {
                    try await render(to: URL(fileURLWithPath: arguments[index + 1]))
                    failed = false
                } catch {
                    failed = true
                }
            }
            while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
            exit(failed == true ? 1 : 0)
        }
        if let index = arguments.firstIndex(of: "--foot-slip"), arguments.indices.contains(index + 2),
           let seconds = Double(arguments[index + 1]) {
            guard let samples = wave(URL(fileURLWithPath: arguments[index + 2])) else { exit(2) }
            app.setActivationPolicy(.prohibited)
            // `still` plays it under Reduce Motion.
            let still = arguments.indices.contains(index + 3) && arguments[index + 3] == "still"
            let window = demo(looks: slipLooks) { desks in
                if still { desks.forEach { $0.mark.reducesMotion = { true } } }
                slipDemo(samples, desks: desks)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
            withExtendedLifetime(window) { app.run() }
            return
        }
        if let index = arguments.firstIndex(of: "--foot-voice"), arguments.indices.contains(index + 3),
           let seconds = Double(arguments[index + 1]) {
            guard let samples = wave(URL(fileURLWithPath: arguments[index + 2])) else { exit(2) }
            app.setActivationPolicy(.prohibited)
            let composer = arguments.indices.contains(index + 4) && arguments[index + 4] == "composer"
            let window = demo { voice(samples, live: arguments[index + 3] == "live", composer: composer, desks: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
            withExtendedLifetime(window) { app.run() }
            return
        }
        if let index = arguments.firstIndex(of: "--placement-frames"), arguments.indices.contains(index + 2),
           let seconds = Double(arguments[index + 2]) {
            // Never activated and never a window: frames are drawn off screen.
            app.setActivationPolicy(.prohibited)
            exit(renderPlacementFrames(dark: arguments[index + 1] == "dark", seconds: seconds, scale: 2) ? 0 : 1)
        }
        if let index = arguments.firstIndex(of: "--placement-stills"), arguments.indices.contains(index + 1) {
            // Never activated and never ordered front: the stills are drawn
            // off screen.
            app.setActivationPolicy(.prohibited)
            do {
                try renderPlacement(to: URL(fileURLWithPath: arguments[index + 1]))
                exit(0)
            } catch {
                exit(1)
            }
        }
        guard let index = arguments.firstIndex(of: "--foot-demo"), arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]) else { exit(2) }
        app.setActivationPolicy(.prohibited)
        let window = demo(play)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        withExtendedLifetime(window) { app.run() }
    }

    /// One desk's sky and appearance.
    struct Look {
        var sky: SunDotView.Sky
        var dark: Bool
        /// Where the dot sits: the bottom centre, or the middle of a side.
        var slot = Slot.bottom
        enum Slot { case bottom, left, right }
        var name: String { "\(sky == .sun ? "sun" : "moon")-\(dark ? "dark" : "light")\(slot == .bottom ? "" : slot == .left ? "-left" : "-right")" }
        static let all = [Look(sky: .sun, dark: false), Look(sky: .sun, dark: true), Look(sky: .moon, dark: false), Look(sky: .moon, dark: true)]
    }

    @MainActor
    private static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--layout-proof") {
            for dark in [false, true] {
                for scale: CGFloat in [1, 2] {
                    let desk = Desk(look: Look(sky: dark ? .moon : .sun, dark: dark))
                    desk.mark.reducesMotion = { true }
                    desk.words("Dictate", key: "fn")
                    try await save(desk, scale: scale,
                                   to: directory.appendingPathComponent("foot-hint-\(dark ? "night" : "light")-\(Int(scale))x.png"))
                }
            }
            return
        }
        if CommandLine.arguments.contains("--pill-states") {
            try await renderPill(to: directory)
            return
        }
        let states: [(String, (Desk) -> Void)] = [
            ("resting", { _ in }),
            ("hint", { $0.point(); $0.words("Dictate", key: "fn") }),
            ("listening", { $0.listen() }),
            ("listening-hover", { $0.point(); $0.listen(); $0.words("Done", key: "esc", after: "cancels") }),
            ("writing", { $0.write() }),
            ("writing-email-words", { $0.write(); $0.words("Writing your email\u{2026}") }),
            ("notice-words", { $0.words("Couldn't write it, so I typed what you said") }),
            ("composer-at-foot", { $0.composerAtFoot() }),
        ]
        for look in Look.all {
            for (name, apply) in states {
                let desk = Desk(look: look)
                desk.mark.reducesMotion = { true }
                apply(desk)
                try await save(desk, to: directory.appendingPathComponent("foot-\(name)-\(look.name).png"))
            }
        }
        // The slip at the side slots, by day and by night, its dot at the
        // outer end and its words in their reading order.
        for look in [Look(sky: .sun, dark: false, slot: .left), Look(sky: .sun, dark: true, slot: .left),
                     Look(sky: .sun, dark: false, slot: .right), Look(sky: .sun, dark: true, slot: .right)] {
            for (name, apply) in states where name == "hint" || name == "listening-hover" {
                let desk = Desk(look: look)
                desk.mark.reducesMotion = { true }
                apply(desk)
                try await save(desk, to: directory.appendingPathComponent("foot-\(name)-\(look.name).png"))
            }
        }
    }

    /// The pill and its tooltip under the pointer, the pill alone where a
    /// field would sit under the tooltip, and a short press of Control +
    /// Option: by day and night on light and dark desktops at the bottom,
    /// and by day and night at the right slot, at 1x and 2x, each with a
    /// 10x crop round the pill and the tooltip.
    @MainActor
    private static func renderPill(to directory: URL) async throws {
        let states: [(String, SunDotView.Glyph)] = [
            ("hover-with-tooltip", SunDotView.Glyph(key: "fn")),
            ("hover-pill-alone", SunDotView.Glyph(key: "fn", tooltip: false)),
            ("short-press-control-option", SunDotView.Glyph(key: "Control + Option")),
        ]
        let looks = Look.all + [Look(sky: .sun, dark: false, slot: .right), Look(sky: .moon, dark: true, slot: .right)]
        for look in looks {
            for (name, glyph) in states {
                for scale: CGFloat in [1, 2] {
                    let desk = Desk(look: look)
                    desk.mark.reducesMotion = { true }
                    // As the foot's window gives it: 8 points in from the desk's sides.
                    desk.mark.tooltipRoom = (8 - desk.mark.frame.minX, Desk.size.width - 8 - desk.mark.frame.minX)
                    desk.mark.glyph = glyph
                    let dot = desk.mark.convert(desk.mark.dotCentre, to: desk)
                    let left = min(max(dot.x - 100, 0), Desk.size.width - 200)
                    try await save(desk, scale: scale, detail: CGRect(x: left, y: dot.y - 24, width: 200, height: 80),
                                   to: directory.appendingPathComponent("foot-\(name)-\(look.name)-\(Int(scale))x.png"))
                }
            }
        }
    }

    /// Draws the desk through a never-ordered window. At a `scale`, also a
    /// 10x crop of `detail` (in the desk's points, y up), or of the 24 point
    /// square round the dot.
    @MainActor
    private static func save(_ desk: Desk, scale: CGFloat? = nil, detail: CGRect? = nil, to file: URL) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Desk.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - Desk.size.width / 2, y: screen.frame.midY - Desk.size.height / 2))
        }
        window.contentView = desk
        // Finish animation model values before caching the off-screen view.
        func finish(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.sublayers?.forEach(finish)
        }
        desk.layoutSubtreeIfNeeded()
        if let scale { desk.mark.backingScale = scale }
        desk.layer.map(finish)
        let bitmap: NSBitmapImageRep?
        if let scale {
            bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Desk.size.width * scale), pixelsHigh: Int(Desk.size.height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            bitmap?.size = Desk.size
        } else {
            bitmap = desk.bitmapImageRepForCachingDisplay(in: desk.bounds)
        }
        guard let bitmap else { throw CocoaError(.fileWriteUnknown) }
        desk.cacheDisplay(in: desk.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
        if let scale, let image = bitmap.cgImage {
            let dot = desk.mark.convert(desk.mark.dotCentre, to: desk)
            // The same 24 pt square on both revisions, expanded with nearest
            // neighbour sampling so every source pixel remains visible.
            let box = detail ?? CGRect(x: dot.x - 12, y: dot.y - 12, width: 24, height: 24)
            let crop = CGRect(x: box.minX.rounded(.down) * scale,
                              y: (Desk.size.height - box.maxY).rounded(.down) * scale,
                              width: box.width * scale, height: box.height * scale)
            guard let edge = image.cropping(to: crop),
                  let context = CGContext(data: nil, width: edge.width * 10, height: edge.height * 10,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            context.interpolationQuality = .none
            context.draw(edge, in: CGRect(x: 0, y: 0, width: edge.width * 10, height: edge.height * 10))
            guard let expanded = context.makeImage(),
                  let detail = NSBitmapImageRep(cgImage: expanded).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try detail.write(to: file.deletingPathExtension().appendingPathExtension("edge-10x.png"))
        }
    }

    /// The slip's desks: the sun at the bottom on a light and a dark
    /// desktop, and at the left and right slots.
    static let slipLooks = [Look(sky: .sun, dark: false), Look(sky: .sun, dark: true),
                            Look(sky: .sun, dark: false, slot: .left), Look(sky: .sun, dark: true, slot: .right)]

    @MainActor
    private static func demo(looks: [Look] = Look.all, _ play: ([Desk]) -> Void) -> NSWindow {
        let desks = looks.map { Desk(look: $0) }
        let size = CGSize(width: Desk.size.width * 2, height: Desk.size.height * 2)
        let grid = NSView(frame: CGRect(origin: .zero, size: size))
        for (index, desk) in desks.enumerated() {
            // Sun on the top row, moon below; light on the left, dark on the right.
            desk.frame.origin = CGPoint(x: CGFloat(index % 2) * Desk.size.width, y: CGFloat(1 - index / 2) * Desk.size.height)
            grid.addSubview(desk)
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = demoTitle
        window.contentView = grid
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        }
        window.orderFrontRegardless()
        play(desks)
        return window
    }

    /// Three dictations, 6.5 s each. First by clicks: the pointer comes to
    /// the dot and the hint shows, a click starts it and the sun under the
    /// pointer says how to finish and cancel, seven words, three of them
    /// loud, a click on the sun finishes it, Intention writes for 1.5 s and the
    /// words land. Second by a click and Escape: nothing lands. Third by
    /// the held key, the design's own timeline: key down at 1.3 s, up at
    /// 3.7 s.
    @MainActor
    private static func play(_ desks: [Desk]) {
        let period = 6.5
        let words: [(Double, Bool)] = [(1.36, false), (1.68, false), (2.0, true), (2.31, false), (2.9, true), (3.2, true), (3.45, false)]
        // Each word a fifth of a second of sound, taken every 20 ms through
        // the follower as Intention takes the microphone's.
        var follower = LevelFollower()
        var voice: [(Double, (Desk) -> Void)] = []
        for tick in Int(1.3 / 0.02)..<Int(3.7 / 0.02) {
            let at = Double(tick) * 0.02
            let word = words.first { at >= $0.0 && at < $0.0 + 0.2 }
            let level = follower.advance(to: word.map { $0.1 ? 0.85 : 0.62 } ?? 0.02, seconds: 0.02)
            voice.append((at, { $0.hear(level) }))
        }
        let clicked: [(Double, (Desk) -> Void)] = voice + [
            (0.0, { $0.reset() }),
            (0.3, { $0.point() }),
            (0.6, { $0.words("Dictate", key: "fn") }),
            (1.1, { $0.click { $0.listen(); $0.words("Done", key: "esc", after: "cancels") } }),
            (3.7, { $0.click { $0.write(); $0.words("Dictate", key: "fn") } }),
            (4.2, { $0.leave(); $0.words(nil) }),
            (5.2, { $0.land() }),
        ]
        let cancelled: [(Double, (Desk) -> Void)] = voice.filter { $0.0 < 3 } + [
            (0.0, { $0.reset() }),
            (0.3, { $0.point() }),
            (0.6, { $0.words("Dictate", key: "fn") }),
            (1.1, { $0.click { $0.listen(); $0.words("Done", key: "esc", after: "cancels") } }),
            (3.2, { $0.escape() }),
            (3.5, { $0.leave() }),
        ]
        let held: [(Double, (Desk) -> Void)] = voice + [
            (0.0, { $0.reset() }),
            (1.3, { $0.listen() }),
            (3.7, { $0.write() }),
            (5.2, { $0.land() }),
        ]
        for (round, steps) in [clicked, cancelled, held].enumerated() {
            for (at, step) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(round) * period + at) { desks.forEach(step) }
            }
        }
    }

    /// A recording's loudness on the desks: rest for 0.8 s, the key down
    /// for the whole recording, then Intention writing for 1.5 s and the words
    /// landing. `live` gives the level every 20 ms through the follower,
    /// otherwise each 100 ms chunk's level once the chunk has ended.
    @MainActor
    private static func voice(_ samples: [Int16], live: Bool, composer: Bool, desks: [Desk]) {
        let start = 0.8
        let rate = 16_000.0
        let step = live ? 0.02 : 0.1
        let length = Double(samples.count) / rate
        var follower = LevelFollower()
        func after(_ seconds: Double, _ step: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(step) }
        }
        after(start) { desks.forEach { composer ? $0.composerAtFoot() : $0.listen() } }
        for window in 0..<Int(length / step) {
            let range = Int(Double(window) * step * rate)..<min(samples.count, Int(Double(window + 1) * step * rate))
            let slice = samples[range]
            let level: Double
            if live {
                let power = slice.reduce(0.0) { $0 + pow(Double($1) / 32_768, 2) } / Double(slice.count)
                level = follower.advance(to: SpeechLevel.of(rms: power.squareRoot()), seconds: step)
            } else {
                level = SpeechLevel.of(slice.withUnsafeBufferPointer { Data(buffer: $0) })
            }
            after(start + Double(window + 1) * step) { desks.forEach { $0.hear(level) } }
        }
        after(start + length) { desks.forEach { $0.write() } }
        after(start + length + 1.5) { desks.forEach { $0.land() } }
    }

    /// The mark opening into its slip under the pointer and closing back,
    /// with the voice: the pointer comes, "Dictate" opens after 150 ms, a
    /// click starts listening and the slip turns to the sun's "Done", the
    /// pointer leaves and the sun follows the recording's voice, comes back
    /// and the slip pulses with it, a click and Intention writes under
    /// "Dictate", the words land, and a notice opens from the dot.
    @MainActor
    private static func slipDemo(_ samples: [Int16], desks: [Desk]) {
        let dictate = FootSlip(text: "Dictate", key: "fn")
        let done = FootSlip(text: "Done", key: "esc", after: "cancels")
        func at(_ seconds: Double, _ step: @escaping @MainActor (Desk) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { desks.forEach(step) } }
        }
        at(0) { $0.reset() }
        at(0.4) { $0.point() }
        at(0.95) { $0.mark.slip = dictate }
        at(1.9) { $0.click { $0.listen(); $0.mark.slip = done } }
        at(2.9) { $0.leave() }
        at(3.15) { $0.mark.slip = nil }
        // The voice from the recording's first words, every 20 ms through
        // the follower, until the click that ends it.
        var follower = LevelFollower()
        let start = 2.4, end = 8.9, skip = 0.6
        for tick in 0..<Int((end - start) / 0.02) {
            let from = Int((skip + Double(tick) * 0.02) * 16_000)
            guard from + 320 <= samples.count else { break }
            let slice = samples[from..<from + 320]
            let power = slice.reduce(0.0) { $0 + pow(Double($1) / 32_768, 2) } / 320
            let level = follower.advance(to: SpeechLevel.of(rms: power.squareRoot()), seconds: 0.02)
            at(start + Double(tick + 1) * 0.02) { $0.hear(level) }
        }
        at(6.6) { $0.point() }
        at(7.15) { $0.mark.slip = done }
        at(8.9) { $0.click { $0.write(); $0.mark.slip = dictate } }
        at(9.7) { $0.leave() }
        at(9.95) { $0.mark.slip = nil }
        at(11.0) { $0.land() }
        at(11.8) { $0.mark.slip = FootSlip(text: "Intention heard no words") }
        at(14.0) { $0.mark.slip = nil }
    }

    /// The 16-bit samples of a mono WAV file's data chunk.
    private static func wave(_ file: URL) -> [Int16]? {
        guard let data = try? Data(contentsOf: file), data.count > 12 else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if id == "data" {
                let body = data[offset + 8..<min(data.count, offset + 8 + size)]
                return body.withUnsafeBytes { raw in (0..<body.count / 2).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
            }
            offset += 8 + size + size % 2
        }
        return nil
    }

    /// A made-up desk: a desktop, a notes window with a caret and its dot, a
    /// Dock, and the foot mark above it, as `FootMark` places it.
    @MainActor
    final class Desk: NSView {
        static let size = CGSize(width: 560, height: 300)
        static let dockTop: CGFloat = 52
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        private let caretDot = DotMarkView()
        private let dockView = PassiveView()
        private let sheet = CALayer()
        private let landed = CATextLayer()
        private let composer = CALayer()
        private let look: Look
        private var footShown = true
        /// A drawn arrow pointer standing in for the person's, its tip at
        /// its position, and the Escape key shown when it is pressed.
        private let pointer = CAShapeLayer()
        private let escKey = CATextLayer()
        private static let away = CGPoint(x: 470, y: 60)

        init(look: Look) {
            self.look = look
            super.init(frame: CGRect(origin: .zero, size: Self.size))
            appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
            wantsLayer = true
            let desktop = CAGradientLayer()
            desktop.frame = bounds
            desktop.colors = look.dark ? [Self.rgb(0x182448), Self.rgb(0x121B38)] : [Self.rgb(0xF1EEE4), Self.rgb(0xE6E2D6)]
            layer?.addSublayer(desktop)
            // The notes window holds the caret, so it is the focused field: it
            // ends 64 points above the Dock, where the foot still paints with
            // the whole listening sun and the field's margin between them. At
            // a side slot it keeps clear of the dot's slip.
            let sheetX: CGFloat = switch look.slot {
            case .bottom: 60
            case .left: 140
            case .right: 40
            }
            sheet.frame = CGRect(x: sheetX, y: Self.dockTop + 64, width: look.slot == .bottom ? 440 : 380, height: 176)
            sheet.backgroundColor = look.dark ? Self.rgb(0x1E1E1E) : .white
            sheet.cornerRadius = 12
            sheet.shadowOpacity = 0.18
            sheet.shadowRadius = 10
            sheet.shadowOffset = CGSize(width: 0, height: -4)
            layer?.addSublayer(sheet)
            let ink = look.dark ? NSColor(white: 0.9, alpha: 1) : NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
            for (index, line) in ["Offsite", "Twelve of us, two days.", "Agenda: Q3 deck, roadmap, team dinner", "Book the train for Friday"].enumerated() {
                let text = Self.text(line, ink: ink, size: index == 0 ? 17 : 13, bold: index == 0)
                text.frame = CGRect(x: 24, y: 176 - 40 - CGFloat(index) * 22, width: 400, height: 20)
                sheet.addSublayer(text)
            }
            landed.isHidden = true
            sheet.addSublayer(landed)
            let replacement = Self.text("Call the venue Thursday at 4", ink: ink, size: 13, bold: false)
            landed.string = replacement.string
            landed.font = replacement.font
            landed.fontSize = replacement.fontSize
            landed.foregroundColor = replacement.foregroundColor
            landed.contentsScale = 2
            landed.frame = CGRect(x: 24, y: 176 - 40 - 4 * 22, width: 400, height: 20)
            // A chat app's composer reaching down to the foot, for the
            // focused-field rule; hidden unless asked for.
            composer.frame = CGRect(x: 20, y: Self.dockTop + 6, width: Self.size.width - 40, height: 30)
            composer.cornerRadius = 15
            composer.backgroundColor = look.dark ? Self.rgb(0x2A2A2A) : .white
            composer.borderWidth = 0.5
            composer.borderColor = NSColor(white: look.dark ? 1 : 0, alpha: 0.25).cgColor
            composer.isHidden = true
            layer?.addSublayer(composer)
            let dock = CALayer()
            dock.frame = CGRect(x: 130, y: 6, width: 300, height: Self.dockTop - 10)
            dock.cornerRadius = 12
            dock.backgroundColor = look.dark ? NSColor(white: 0.12, alpha: 0.6).cgColor : NSColor(white: 1, alpha: 0.6).cgColor
            dock.borderWidth = 0.5
            dock.borderColor = NSColor(white: look.dark ? 1 : 0, alpha: 0.14).cgColor
            // The Dock's window sits above the foot's, so it is drawn over the
            // mark, as a person sees it.
            dockView.frame = bounds
            dockView.wantsLayer = true
            dockView.layer?.addSublayer(dock)
            for (index, colour) in [0x3B82F6, 0xF59E0B, 0x10B981, 0xEF4444, 0x8B5CF6, 0x6B7280, 0x0EA5E9, 0xF97316].enumerated() {
                let tile = CALayer()
                tile.frame = CGRect(x: 10 + CGFloat(index) * 36, y: 5, width: 30, height: 30)
                tile.cornerRadius = 7
                tile.backgroundColor = Self.rgb(colour)
                dock.addSublayer(tile)
            }
            caretDot.frame = bounds
            addSubview(caretDot)
            mark.sky = look.sky
            switch look.slot {
            case .bottom:
                mark.frame.origin = CGPoint(x: bounds.midX - SunDotView.side / 2, y: Self.dockTop + FootMark.aboveDock - SunDotView.side / 2)
            case .left:
                mark.frame.origin = CGPoint(x: 22 - SunDotView.side / 2, y: bounds.midY - 40 - SunDotView.side / 2)
                mark.opening = .rightward
            case .right:
                mark.frame.origin = CGPoint(x: bounds.maxX - 22 - SunDotView.side / 2, y: bounds.midY - 40 - SunDotView.side / 2)
                mark.opening = .leftward
            }
            addSubview(mark)
            addSubview(dockView)
            placeCaret(afterLanding: false)
            let arrow = CGMutablePath()
            for (index, point) in [(0, 0), (0, -16), (4.2, -12.2), (7.2, -18.4), (9.8, -17.2), (6.9, -11.2), (12, -11.2)].enumerated() {
                let at = CGPoint(x: point.0, y: point.1)
                if index == 0 { arrow.move(to: at) } else { arrow.addLine(to: at) }
            }
            arrow.closeSubpath()
            pointer.path = arrow
            pointer.fillColor = NSColor.black.cgColor
            pointer.strokeColor = NSColor.white.cgColor
            pointer.lineWidth = 1.2
            pointer.position = Self.away
            pointer.isHidden = true
            layer?.addSublayer(pointer)
            escKey.string = "esc"
            escKey.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            escKey.fontSize = 12
            escKey.alignmentMode = .center
            escKey.foregroundColor = (look.dark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.15, alpha: 1)).cgColor
            escKey.backgroundColor = (look.dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)).cgColor
            escKey.cornerRadius = 5
            escKey.contentsScale = 2
            escKey.frame = CGRect(x: Self.size.width - 64, y: Self.size.height - 30, width: 44, height: 20)
            escKey.opacity = 0
            layer?.addSublayer(escKey)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        /// The pointer comes to rest on the foot dot.
        func point() {
            pointer.isHidden = false
            move(to: CGPoint(x: mark.frame.midX + 2, y: mark.frame.midY - 2))
        }

        /// The pointer goes up and away from the foot.
        func leave() { move(to: Self.away) }

        private func move(to point: CGPoint) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(mark.reducesMotion() ? 0 : 0.4)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            pointer.position = point
            CATransaction.commit()
        }

        /// A click: the pointer darkens and shrinks a little for 120 ms, then
        /// `then` runs, as the foot answers a click.
        func click(_ then: @escaping (Desk) -> Void) {
            pointer.fillColor = NSColor(white: 0.3, alpha: 1).cgColor
            pointer.transform = CATransform3DMakeScale(0.9, 0.9, 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.pointer.fillColor = NSColor.black.cgColor
                self.pointer.transform = CATransform3DIdentity
                then(self)
            }
        }

        /// Escape while listening: the dictation is dropped, the foot rests
        /// at once and nothing lands.
        func escape() {
            escKey.opacity = 1
            words(nil)
            mark.phase = .resting
            caretDot.look = .resting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.escKey.opacity = 0 }
        }

        override var isFlipped: Bool { false }

        /// The caret at the end of the last line, or of the landed line, and
        /// the dot above it; in the composer for the focused-field rule.
        private func placeCaret(afterLanding: Bool) {
            let ink = look.dark ? NSColor(white: 0.9, alpha: 1) : NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
            let x: CGFloat = composer.isHidden ? (afterLanding ? sheet.frame.minX + 24 + 186 : sheet.frame.minX + 24) : 40
            let lineTop: CGFloat = composer.isHidden ? sheet.frame.minY + 176 - 40 - 4 * 22 + 18 : Self.dockTop + 6 + 23
            // The dot's view is flipped, with y down from the desk's top.
            caretDot.place(diameter: 7, ink: ink, center: CGPoint(x: x, y: Self.size.height - lineTop - 6))
            caretLine?.removeFromSuperlayer()
            let caret = CALayer()
            caret.frame = CGRect(x: x - 1, y: lineTop - 17, width: 1.5, height: 16)
            caret.backgroundColor = ink.cgColor
            layer?.addSublayer(caret)
            caretLine = caret
        }
        private var caretLine: CALayer?

        func reset() {
            pointer.isHidden = true
            pointer.position = Self.away
            landed.isHidden = true
            placeCaret(afterLanding: false)
            words(nil)
            mark.phase = .resting
            caretDot.look = .resting
        }

        /// The foot dot opening into its slip, as `FootMark` opens it.
        func words(_ text: String?, key: String? = nil, after: String? = nil, then: (key: String, words: String)? = nil) {
            mark.slip = text.map { text in
                FootSlip(text: text, key: key, after: after, then: then)
            }
        }

        /// Key down: the sun at the foot, and the caret dot in full ink, so
        /// one red mark shows; with the foot hidden, the caret dot red.
        func listen() {
            mark.phase = .listening
            caretDot.look = footShown ? .heard : .recording
        }

        /// The voice's level, for the sun and for the caret dot's halo.
        func hear(_ level: Double) {
            mark.level = level
            caretDot.level = level
        }

        func write() {
            mark.phase = .writing
            caretDot.look = .working
        }

        func land() {
            landed.isHidden = false
            placeCaret(afterLanding: true)
            mark.phase = .resting
            caretDot.look = .resting
        }

        /// A chat app's composer at the foot: nothing paints there, and the
        /// caret dot in the composer turns red with its halo.
        func composerAtFoot() {
            composer.isHidden = false
            footShown = false
            mark.isHidden = true
            placeCaret(afterLanding: false)
            caretDot.look = .recording
            caretDot.level = 0.6
        }

        private static func rgb(_ hex: Int) -> CGColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor
        }

        private static func text(_ string: String, ink: NSColor, size: CGFloat, bold: Bool) -> CATextLayer {
            let text = CATextLayer()
            text.string = string
            text.font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            text.fontSize = size
            text.foregroundColor = ink.cgColor
            text.contentsScale = 2
            return text
        }
    }

    /// A view that only draws, so the Dock over the mark takes no pointer.
    final class PassiveView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
