import AppKit
import ScreenCaptureKit

/// Memory-only field crops. The capture filter admits only the target
/// window; the source rectangle restricts pixels to the field. No audio, file
/// output, OCR or network path.
///
/// While Accessibility cannot place the caret, one stream captures the
/// focused field. It starts after a full identity, security and geometry
/// check of the target; while it runs the check repeats every 100 ms, and a
/// frame is used only while the latest passing check is under 300 ms old and
/// the target is unchanged. A failed check, any other target, another
/// frontmost app or focus leaving for a refused app stops it.
///
/// An app that exposes no accessible text at all, such as Codex, has no
/// field boundary; its focused window is the target instead. That window is
/// captured only within `opaqueArming` of a key or click in it, and the caret
/// is looked for only in a band: around a click, around what changed in the
/// window between the frame before a keystroke and the frame after it, then
/// around the caret. After that the last caret found stays shown without
/// capture until the next input, see `park`.
@MainActor
final class VisualCaretCapture {
    var enabled = false {
        didSet { if !enabled { stopStream(); remembered = nil; opaqueReading = nil; parked = nil; invalidate() } }
    }
    /// A position, or nil, and whether blinking confirmed it rather than
    /// one frame alone.
    var onReading: ((CaretTracker.Reading?, _ confirmed: Bool) -> Void)?
    private var target: VisualCaretTarget?
    private let worker = BlinkCaretWorker()
    private var generation = 0
    private var stream: FieldStream?
    /// Identifies the current stream to its stop report.
    private var streamSerial = 0
    private var streamTarget: VisualCaretTarget?
    private var starting = false
    private var validatedAt: TimeInterval = 0
    /// The newest sample handed on; an older one, such as the first-frame
    /// screenshot arriving after stream frames, is dropped.
    private var lastSampleAt: TimeInterval = 0
    /// After the system stops a stream, the next one waits until then.
    private var retryAt: TimeInterval = 0
    private var validating = false
    private var processing = false
    private var pending: FieldScreenshot.Sample?
    private var tracker: CaretTracker?

    private var loggedEvent: String?

    private func diagnostic(_ event: String, duration: Double? = nil) {
        #if DEBUG
        CaretFixtureMode.diagnostic(event, duration: duration)
        #endif
        // Outcome names only, when they change.
        if ["capture-initial-validation-denied", "capture-window-unmatched", "capture-threw", "pixels-unresolved", "visual-published",
            "stream-revalidation-denied", "stream-stopped-by-system", "stream-frontmost-changed", "opaque-region-from-key", "opaque-disarmed", "opaque-parked", "opaque-caret-predicted"].contains(event), event != loggedEvent {
            loggedEvent = event
            AppLog.caret("visual " + event)
        }
    }

    func invalidate() {
        diagnostic("visual-invalidated")
        generation += 1
        let version = generation
        Task { await worker.reset(generation: version) }
        onReading?(nil, false)
    }

    /// Restarts blink evidence after input without withdrawing the last
    /// published position; the next Accessibility read replaces it.
    func restart() {
        guard target != nil else { return }
        generation += 1
        let version = generation
        Task { await worker.reset(generation: version) }
    }

    /// Focus left for a refused app, Intention or nothing: no stream outlives it.
    func stop() {
        if target != nil { diagnostic("target-changed") }
        if target?.opaque == true, stream != nil { park() }
        target = nil
        stopStream()
        invalidate()
    }

    // MARK: Opaque windows

    /// How long after a key or click an opaque window may be captured.
    static let opaqueArming: TimeInterval = 3
    private var lastInputAt: TimeInterval = 0
    private var lastOpaqueCaretAt: TimeInterval = 0
    /// The last caret pixels found in an opaque window, and that window.
    private var opaqueReading: (target: VisualCaretTarget, reading: CaretTracker.Reading)?
    /// A caret kept after capture of its window ended, see `park`.
    private var parked: (target: VisualCaretTarget, reading: CaretTracker.Reading)?
    /// Where in an opaque window the caret is looked for, in global points.
    private var opaqueRegion: CGRect?
    /// The newest sample, kept as the frame before the next keystroke.
    private var latestSample: FieldScreenshot.Sample?
    private var pendingKey: (at: TimeInterval, before: FieldScreenshot.Sample, kind: KeyKind)?
    /// The last caret placed in an opaque window, by pixels or by a key.
    private var lastOpaqueCaret: CGRect?
    /// The last click, kept for a window recognised as opaque just after it.
    private var lastClick: (point: CGPoint, at: TimeInterval)?

    private static func clickBand(_ click: CGPoint, in window: CGRect) -> CGRect {
        // The caret lands on the clicked line, at most a few hundred points
        // to the side, as at the start of an empty input.
        CGRect(x: click.x - 300, y: click.y - 36, width: 600, height: 72).intersection(window)
    }

    /// Which kind of key was pressed; never which character.
    enum KeyKind { case printable, delete, other }

    /// A key or click reached the frontmost app. `click` is the pointer in
    /// global points for a click, nil for a key.
    func noteInput(click: CGPoint?, key: KeyKind = .other) {
        let now = ProcessInfo.processInfo.systemUptime
        lastInputAt = now
        if let click { lastClick = (click, now) }
        guard let target, target.opaque else { return }
        if let click {
            // A click can move the caret anywhere: only a caret found after
            // it may be kept once capture ends.
            lastOpaqueCaretAt = 0
            if target.windowFrame.contains(click) { opaqueRegion = Self.clickBand(click, in: target.windowFrame) }
        } else if let before = latestSample {
            pendingKey = (now, before, key)
        }
    }

    /// Five lines tall around `rect`, and `margin` to either side of it:
    /// blink evidence needs every other change, such as an animated status
    /// elsewhere in the window, kept out.
    private static func band(around rect: CGRect, lineHeight: CGFloat, margin: CGFloat, in window: CGRect) -> CGRect {
        CGRect(x: rect.minX - margin, y: rect.midY - lineHeight * 2.5, width: rect.width + margin * 2, height: lineHeight * 5)
            .intersection(window)
    }

    func update(_ next: VisualCaretTarget?, tracker: CaretTracker) {
        self.tracker = tracker
        if let next, let current = target, current.sameBoundary(as: next) {
            // Same boundary: keep the stream. A moved selection restarts
            // blink evidence; the latest focus and input time are kept.
            if current != next { restart() }
            target = next
        } else if target != nil || next != nil {
            diagnostic("target-changed")
            if target?.opaque == true, stream != nil { park() }
            target = next
            opaqueRegion = nil
            latestSample = nil
            pendingKey = nil
            lastOpaqueCaret = nil
            opaqueReading = nil
            // A click just before the window was recognised as opaque.
            if let next, next.opaque, let lastClick, ProcessInfo.processInfo.systemUptime - lastClick.at <= Self.opaqueArming,
               next.windowFrame.contains(lastClick.point) {
                opaqueRegion = Self.clickBand(lastClick.point, in: next.windowFrame)
            }
            stopStream()
            invalidate()
            // The same field in the same state as when pixels last placed
            // its caret, such as after switching apps and back: show that
            // position at once while pixels confirm it again. An opaque
            // window shows only a caret kept when its capture ended.
            if enabled, let next, next.opaque {
                if let parked, parked.target.sameBoundary(as: next) { onReading?(parked.reading, false) }
            } else if enabled, let next, let remembered, remembered.target == next, remembered.target.empty == next.empty,
               ProcessInfo.processInfo.systemUptime - remembered.at < 60 {
                diagnostic("visual-remembered")
                onReading?(remembered.reading, false)
            }
        }
        guard enabled, let next else { stopStream(); return }
        if next.opaque, ProcessInfo.processInfo.systemUptime - lastInputAt > Self.opaqueArming {
            if stream != nil {
                diagnostic("opaque-disarmed")
                park()
                stopStream()
            }
            if let parked, parked.target.sameBoundary(as: next) { onReading?(parked.reading, false) }
            return
        }
        guard streamTarget == nil, !starting, ProcessInfo.processInfo.systemUptime >= retryAt else { return }
        guard CGPreflightScreenCaptureAccess() else { invalidate(); return }
        startStream(next, tracker: tracker)
    }

    /// Capture of an opaque window ends `opaqueArming` after the last key or
    /// click, whatever pixels still show. The caret cannot move without input
    /// to that app, so one pixels confirmed in the last second, after any
    /// click, stays shown without capture until input arms capture again,
    /// or when the person comes back to the same window.
    private func park() {
        guard let opaqueReading, ProcessInfo.processInfo.systemUptime - lastOpaqueCaretAt <= 1 else {
            parked = nil
            return
        }
        diagnostic("opaque-parked")
        parked = opaqueReading
    }

    /// The last position pixels placed and the exact target it was placed
    /// in, including selection and anchors. Memory only.
    private var remembered: (target: VisualCaretTarget, reading: CaretTracker.Reading, at: TimeInterval)?

    private func startStream(_ next: VisualCaretTarget, tracker: CaretTracker) {
        starting = true
        let version = generation
        let began = ProcessInfo.processInfo.systemUptime
        firstFrameLogged = false
        streamBegan = began
        Task {
            defer { starting = false }
            // A busy reader skips this round; the next observation retries.
            guard let passed = await permitted(next, tracker: tracker) else { return }
            guard passed else {
                diagnostic("capture-initial-validation-denied")
                if generation == version { invalidate() }
                return
            }
            let passedAt = ProcessInfo.processInfo.systemUptime
            do {
                diagnostic("stream-validated", duration: ProcessInfo.processInfo.systemUptime - began)
                let frontWindowID = FieldScreenshot.frontWindowID(for: next.pid, frame: next.windowFrame)
                func matching(_ content: SCShareableContent) -> [SCWindow] {
                    content.windows.filter {
                        $0.windowID == frontWindowID && $0.owningApplication?.processID == next.pid
                            && $0.frame == next.windowFrame && $0.isOnScreen
                    }
                }
                // A window list fetched when the app came forward usually
                // already holds this window; otherwise fetch it now.
                // It names windows and frames only, and the target window must
                // match it exactly, so a list up to a minute old serves.
                var content = prefetched.flatMap { ProcessInfo.processInfo.systemUptime - $0.at < 60 ? $0.content : nil }
                if content.map({ matching($0).count != 1 }) ?? true {
                    let fetched = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    prefetched = (ProcessInfo.processInfo.systemUptime, fetched)
                    content = fetched
                }
                guard let content else { return }
                diagnostic("stream-content", duration: ProcessInfo.processInfo.systemUptime - began)
                let matches = matching(content)
                guard matches.count == 1, let window = matches.first,
                      let display = content.displays.first(where: { $0.frame.contains(next.field) }) else {
                    diagnostic("capture-window-unmatched")
                    invalidate()
                    return
                }
                guard enabled, target?.sameBoundary(as: next) == true, streamTarget == nil else { return }
                streamSerial += 1
                let serial = streamSerial
                let stream = try FieldStream(window: window, display: display, field: next.field, onSample: { [weak self] sample in
                    Task { @MainActor in self?.received(sample, from: next) }
                }, onStop: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.stream != nil, self.streamSerial == serial else { return }
                        self.diagnostic("stream-stopped-by-system")
                        self.retryAt = ProcessInfo.processInfo.systemUptime + 1
                        self.stopStream()
                        self.invalidate()
                    }
                })
                self.stream = stream
                streamTarget = next
                validatedAt = passedAt
                // One screenshot, checked before and after like any other,
                // places the dot on first focus. It runs before the stream
                // starts: run together, each slows the other by about 40 ms.
                // The check that admitted this stream, under 50 ms old,
                // serves as the screenshot's check before; the check after
                // is always fresh.
                var checks = 0
                do {
                    let sample = try await FieldScreenshot.capture(window: window, display: display, field: next.field, validate: { [weak self] in
                        guard let self else { return false }
                        checks += 1
                        if checks == 1, ProcessInfo.processInfo.systemUptime - passedAt < 0.05 {
                            return self.enabled && self.target?.sameBoundary(as: next) == true
                                && NSWorkspace.shared.frontmostApplication?.processIdentifier == next.pid
                        }
                        return await self.permitted(next, tracker: tracker) == true
                    })
                    diagnostic("first-screenshot-sample", duration: ProcessInfo.processInfo.systemUptime - began)
                    received(sample, from: next)
                } catch {
                    diagnostic("first-screenshot-failed")
                }
                guard self.stream === stream else { return }
                try await stream.start()
                // Stopped or replaced while starting: `start` has already
                // stopped the capture it began.
                guard self.stream === stream else { return }
                diagnostic("stream-started", duration: ProcessInfo.processInfo.systemUptime - began)
            } catch {
                diagnostic("capture-threw")
                if streamTarget?.sameBoundary(as: next) == true { stopStream() }
                invalidate()
            }
        }
    }

    private var prefetched: (at: TimeInterval, content: SCShareableContent)?

    /// Fetches the on-screen window list ahead of need, when an app comes
    /// forward. It holds window identities and frames only, no pixels.
    func prefetch() {
        guard enabled, CGPreflightScreenCaptureAccess() else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            prefetched = (ProcessInfo.processInfo.systemUptime, content)
        }
    }

    /// Window identities fetched earlier may name frames from before a
    /// display change.
    func discardPrefetch() {
        prefetched = nil
    }

    /// No image outlives the stream: the frame kept for the next keystroke
    /// and the detector's frames go with it. The published position stays.
    private func stopStream() {
        let held = stream != nil || streamTarget != nil || latestSample != nil
        stream?.stop()
        stream = nil
        streamTarget = nil
        pending = nil
        lastSampleAt = 0
        latestSample = nil
        pendingKey = nil
        guard held else { return }
        let version = generation
        Task { await worker.reset(generation: version) }
    }

    private func received(_ sample: FieldScreenshot.Sample, from next: VisualCaretTarget) {
        guard enabled, let current = target, streamTarget?.sameBoundary(as: current) == true, current.sameBoundary(as: next) else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == next.pid else {
            diagnostic("stream-frontmost-changed")
            stopStream()
            invalidate()
            return
        }
        guard sample.capturedAt > lastSampleAt else { return }
        // No frame of an opaque window is used past its arming, even if no
        // tracker read has stopped the stream yet.
        if current.opaque, ProcessInfo.processInfo.systemUptime - lastInputAt > Self.opaqueArming {
            diagnostic("opaque-disarmed")
            park()
            stopStream()
            return
        }
        lastSampleAt = sample.capturedAt
        if current.opaque {
            // What changed between the frame before a keystroke and one at
            // least 50 ms after it is where typing happens. A band that
            // already holds it stays: moving it resets blink evidence, while
            // the caret drawn solid after input is found in it at once.
            if let pending = pendingKey, sample.capturedAt - pending.at >= 0.05 {
                pendingKey = nil
                let window = current.windowFrame
                Task {
                    guard let changed = await worker.changedRect(from: pending.before, to: sample), changed.height <= 120,
                          target?.sameBoundary(as: current) == true else { return }
                    predictCaret(after: pending.kind, changed: changed, in: current)
                    guard opaqueRegion.map({ !$0.contains(changed) }) ?? true else { return }
                    diagnostic("opaque-region-from-key")
                    opaqueRegion = Self.band(around: changed, lineHeight: max(16, min(changed.height, 40)), margin: 100, in: window)
                }
            }
            latestSample = sample
        }
        revalidate(current)
        guard ProcessInfo.processInfo.systemUptime - validatedAt < 0.3 else { return }
        // Keep only the newest frame while one is being analysed.
        guard !processing else { pending = sample; return }
        process(sample, target: current)
    }

    /// Some apps fade their caret on a fixed cycle that input does not
    /// reset, as Codex does, leaving it undrawn for a few hundred ms while
    /// typing. A narrow change on the caret's line, a glyph or two, shows
    /// where it went: after a delete, the left edge of what changed; after
    /// a printable key, the right edge. That position shows unconfirmed
    /// until pixels see the caret.
    private func predictCaret(after kind: KeyKind, changed: CGRect, in current: VisualCaretTarget) {
        guard kind != .other, let last = lastOpaqueCaret, changed.width <= last.height * 3,
              changed.minY <= last.maxY, changed.maxY >= last.minY else { return }
        let caret = CGRect(x: kind == .delete ? changed.minX : changed.maxX, y: last.minY, width: 0, height: last.height)
        lastOpaqueCaret = caret
        diagnostic("opaque-caret-predicted")
        onReading?(CaretTracker.Reading(caret: caret, field: current.field, ink: nil), false)
    }

    /// The check repeats every 100 ms while the stream runs. A busy reader
    /// skips a round; frames stop being used once the last pass is 300 ms
    /// old, and a failed check stops the stream.
    private func revalidate(_ current: VisualCaretTarget) {
        guard ProcessInfo.processInfo.systemUptime - validatedAt > 0.1, !validating, let tracker else { return }
        validating = true
        Task {
            let passed = await permitted(current, tracker: tracker)
            validating = false
            if passed == true { validatedAt = ProcessInfo.processInfo.systemUptime }
            else if passed == false, streamTarget?.sameBoundary(as: current) == true {
                diagnostic("stream-revalidation-denied")
                stopStream()
                invalidate()
            }
        }
    }

    private var firstFrameLogged = false
    private var streamBegan: TimeInterval = 0

    private func process(_ sample: FieldScreenshot.Sample, target next: VisualCaretTarget) {
        if !firstFrameLogged {
            firstFrameLogged = true
            diagnostic("stream-first-frame", duration: ProcessInfo.processInfo.systemUptime - streamBegan)
        }
        processing = true
        let version = generation
        var sample = sample
        if next.opaque, let region = opaqueRegion, let part = sample.cropped(to: region) { sample = part }
        Task {
            let caret = await worker.observe(sample, generation: version, time: sample.capturedAt, anchors: next.anchors,
                                             solidSince: next.focusedAt)
            let rgb = await worker.ink(generation: version)
            let confirmed = await worker.confirmed(generation: version)
            processing = false
            if generation == version, streamTarget?.sameBoundary(as: next) == true, target?.sameBoundary(as: next) == true {
                if let caret, let rgb {
                    diagnostic("visual-published")
                    let ink = Ink(CGColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1))
                    let reading = CaretTracker.Reading(caret: caret, field: next.field, ink: ink)
                    remembered = (next, reading, ProcessInfo.processInfo.systemUptime)
                    if next.opaque {
                        lastOpaqueCaretAt = ProcessInfo.processInfo.systemUptime
                        lastOpaqueCaret = caret
                        opaqueReading = (next, reading)
                        // Follow the caret with a band around it; recentring
                        // resets blink evidence, so only when the caret nears
                        // an edge or the band is still the wide first one.
                        let snug = Self.band(around: caret, lineHeight: caret.height, margin: 150, in: next.windowFrame)
                        if let region = opaqueRegion, region.width <= snug.width + 1,
                           region.insetBy(dx: region.width / 4, dy: region.height / 4).contains(CGPoint(x: caret.midX, y: caret.midY)) {
                        } else {
                            opaqueRegion = snug
                        }
                    }
                    onReading?(reading, confirmed)
                } else {
                    diagnostic("pixels-unresolved")
                    onReading?(nil, false)
                }
            }
            if let pending, let current = target, streamTarget?.sameBoundary(as: current) == true {
                self.pending = nil
                process(pending, target: current)
            }
        }
    }

    /// Nil when the reader was too busy to check, which is not a denial.
    private func permitted(_ target: VisualCaretTarget, tracker: CaretTracker) async -> Bool? {
        guard enabled, self.target?.sameBoundary(as: target) == true,
              CGPreflightScreenCaptureAccess(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return false }
        guard let passed = await tracker.validate(target) else { return nil }
        return passed && enabled && self.target?.sameBoundary(as: target) == true
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }
}
