#if DEBUG
import AppKit
import ScreenCaptureKit

/// Records the insertion checks as a video a person can follow: a caption
/// names each step and its outcome, and steps pause long enough to see.
///
/// The recording includes only listed windows: Intention's own (the dot, the
/// captions, the menu bar item) and the fixture windows the checks opened,
/// matched by their unique names. Any other window, including one opened
/// mid-run by an app under test, stays out. The list is rebuilt at each
/// caption, and if it cannot be applied the recording stops and the run
/// reports a failure.
@MainActor
final class InsertionDemo {
    private let caption = CaptionPanel()
    private var stream: SCStream?
    /// The recording's delegate, kept alive while it records.
    private var recording: NSObject?
    private var display: SCDisplay?
    private var fixtures: [(pid: pid_t, title: String)] = []
    /// Why the recording stopped early, if it did.
    private(set) var failure: String?

    /// Starts recording the main display to `url`. Returns false when
    /// capture is unavailable, such as without Screen Recording.
    func start(recordingTo url: URL) async -> Bool {
        guard #available(macOS 15.0, *) else { return false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return false }
            self.display = display
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.showsCursor = true
            let stream = SCStream(filter: try await filter(), configuration: configuration, delegate: nil)
            let output = SCRecordingOutputConfiguration()
            output.outputURL = url
            output.outputFileType = .mov
            output.videoCodecType = .h264
            let recording = Recording()
            try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: recording))
            try await stream.startCapture()
            self.stream = stream
            self.recording = recording
            return true
        } catch {
            return false
        }
    }

    /// Adds the window of `pid` whose title contains `title` to the
    /// recording.
    func include(pid: pid_t, title: String) async {
        fixtures.append((pid, title))
        await refresh()
    }

    private func refresh() async {
        guard let stream else { return }
        do {
            try await stream.updateContentFilter(try await filter())
        } catch {
            failure = "the recording's window list could not be updated, so it stopped"
            await stop()
        }
    }

    func stop() async {
        caption.orderOut(nil)
        let stopping = stream
        stream = nil
        try? await stopping?.stopCapture()
    }

    /// Shows `text` and waits `seconds` so it can be read.
    func say(_ text: String, for seconds: Double = 1.2) async {
        await refresh()
        caption.show(text)
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func filter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let own = ProcessInfo.processInfo.processIdentifier
        // Chrome shortens a long title in the middle, so the name's end,
        // which holds its unique token, identifies the window.
        let windows = content.windows.filter { window in
            guard let pid = window.owningApplication?.processID else { return false }
            return pid == own || fixtures.contains { $0.pid == pid && (window.title ?? "").contains($0.title.suffix(24)) }
        }
        return SCContentFilter(display: display ?? content.displays[0], including: windows)
    }
}

@available(macOS 15.0, *)
private final class Recording: NSObject, SCRecordingOutputDelegate {}

/// A caption strip at the bottom of the screen. It never takes focus or
/// clicks, so the field under test keeps the keyboard.
private final class CaptionPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.78)
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 16, y: 18, width: 868, height: 28)
        contentView?.addSubview(label)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ text: String) {
        label.stringValue = text
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.minY + 24))
        }
        orderFrontRegardless()
    }
}
#endif
