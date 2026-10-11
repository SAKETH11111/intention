import AppKit

// The entry point of the small bundle scripts/dot-voice-shots.sh builds: the
// caret dot (`DotMarkView`, placed by `DotPlacement`) over a line of
// synthetic text in a field, in each look a dictation gives it.
// `--dot-snapshots <directory>` saves each look as a PNG and quits;
// `--dot-demo <seconds>` plays one dictation with a made-up voice, for
// scripts/dot-voice-shots.sh --video to record by the window's title.
// `--before` draws the dot as it was before it heard the voice: red while
// recording, with no halo. Everything is drawn in a window behind the
// desktop picture, never seen; nothing is read from any app.
@main
struct DotVoiceShots: GuardedRender {
    static let demoTitle = "Intention dot demo"

    @MainActor
    static func render() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        let before = arguments.contains("--before")
        if let index = arguments.firstIndex(of: "--dot-snapshots"), arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: arguments[index + 1])
            var failed: Bool?
            Task {
                do {
                    try await snapshots(to: directory, before: before)
                    failed = false
                } catch {
                    FileHandle.standardError.write(Data("dot snapshots failed: \(error)\n".utf8))
                    failed = true
                }
            }
            while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
            exit(failed == true ? 1 : 0)
        }
        guard let index = arguments.firstIndex(of: "--dot-demo"), arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]) else { exit(2) }
        let scene = Scene(before: before)
        scene.window.title = demoTitle
        scene.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        withExtendedLifetime(scene) { app.run() }
    }

    @MainActor
    private static func snapshots(to directory: URL, before: Bool) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let looks: [(String, DotMarkView.Look, [Double])] = [
            ("resting", .resting, []), ("listening-quiet", .recording, [0.05]),
            ("listening-loud", .recording, [1, 1, 1]), ("finishing", .working, []),
        ]
        for (name, look, voice) in looks {
            let scene = Scene(before: before)
            scene.show(look)
            for level in voice { scene.hear(level) }
            // Let the halo's tenth-of-a-second ease and the first frame settle.
            try await Task.sleep(for: .milliseconds(500))
            try scene.save(to: directory.appendingPathComponent("dot-\(name).png"))
            scene.window.orderOut(nil)
        }
    }

    /// A field with a line of synthetic text, the caret after it, and the
    /// dot above the caret, in a window behind the desktop picture.
    @MainActor
    final class Scene {
        static let size = CGSize(width: 360, height: 120)
        let window: NSWindow
        private let mark = DotMarkView()
        private let before: Bool
        /// The dot as it was drawn before this change, for `--before`.
        private let plain = CAShapeLayer()
        private var voice: Timer?

        init(before: Bool) {
            self.before = before
            window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
                window.setFrameOrigin(CGPoint(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.midY - Self.size.height / 2))
            }
            let content = NSView(frame: CGRect(origin: .zero, size: Self.size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.white.cgColor
            let text = NSTextField(labelWithString: "Thanks for the update, I")
            text.font = .systemFont(ofSize: 15)
            text.textColor = NSColor(white: 0.13, alpha: 1)
            text.sizeToFit()
            text.setFrameOrigin(CGPoint(x: 28, y: 36))
            content.addSubview(text)
            let caret = CGRect(x: text.frame.maxX - 1, y: text.frame.minY + 2, width: 1, height: 18)
            let line = NSView(frame: caret)
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
            content.addSubview(line)
            mark.frame = content.bounds
            content.addSubview(mark)
            window.contentView = content
            // The dot as the controller places it, in the view's flipped points.
            let dot = DotPlacement.dot(aboveCaret: caret, in: content.bounds)
            let center = CGPoint(x: dot.center.x, y: Self.size.height - dot.center.y)
            let ink = NSColor(white: 0.13, alpha: 1)
            mark.place(diameter: dot.diameter, ink: ink, center: center)
            if before {
                mark.isHidden = true
                let shape = OwnHandMark.dot(diameter: dot.diameter)
                plain.bounds = CGRect(origin: .zero, size: shape.size)
                plain.path = shape.path
                plain.position = dot.center
                plain.fillColor = ink.withAlphaComponent(0.6).cgColor
                content.layer?.addSublayer(plain)
            }
        }

        /// Shows `look`; before this change, recording was the system's red
        /// and nothing else, and working pulsed as it still does.
        func show(_ look: DotMarkView.Look) {
            mark.look = look
            guard before else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plain.removeAllAnimations()
            plain.opacity = 1
            plain.fillColor = look == .recording ? NSColor.systemRed.cgColor : NSColor(white: 0.13, alpha: 0.6).cgColor
            if look == .working {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.25
                pulse.duration = 0.45
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                plain.add(pulse, forKey: "processing")
            }
            CATransaction.commit()
        }

        func hear(_ level: Double) {
            mark.level = level
        }

        /// Rest, one dictation with a voice that rises and falls, its text on
        /// the way, rest.
        func play() {
            let steps: [(Double, () -> Void)] = [
                (0.8, { self.show(.recording); self.speak() }),
                (4.6, { self.voice?.invalidate(); self.show(.working) }),
                (5.8, { self.show(.resting) }),
            ]
            for (at, step) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { step() }
            }
        }

        private func speak() {
            var tick = 0.0
            voice = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    tick += 0.1
                    self?.hear(max(0, sin(tick * 2.3) * 0.55 + sin(tick * 5.1) * 0.3 + 0.25))
                }
            }
        }

        /// Only this window's own pixels, as the window server composes them.
        func save(to file: URL) throws {
            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: file)
        }
    }
}
