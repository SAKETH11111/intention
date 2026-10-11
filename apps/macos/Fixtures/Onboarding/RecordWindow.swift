import AppKit
import ScreenCaptureKit

// Records one window of one process to an MP4 by its window number, so the
// window is captured on its own wherever it sits, even behind the desktop.
// Usage: RecordWindow <pid> <window title> <seconds> <output.mp4>
// The process that runs this needs Screen Recording.
@main
struct RecordWindow {
    @MainActor
    static func main() async {
        OffscreenRenderGuard.prepare()
        if CommandLine.arguments.contains("--render-dry-run") { return }
        // ScreenCaptureKit needs this process connected to the window server.
        _ = NSApplication.shared
        let arguments = CommandLine.arguments
        guard arguments.count == 5, let pid = pid_t(arguments[1]), let seconds = Double(arguments[3]) else {
            print("usage: RecordWindow <pid> <window title> <seconds> <output.mp4>")
            exit(2)
        }
        do {
            var found: SCWindow?
            for _ in 0..<50 where found == nil {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                // A window is listed before it has its size; wait for that too.
                found = content.windows.first {
                    $0.owningApplication?.processID == pid && $0.title == arguments[2] && $0.frame.width > 100 && $0.frame.height > 100
                }
                if found == nil { try await Task.sleep(for: .milliseconds(100)) }
            }
            guard let window = found else {
                print("no such window")
                exit(1)
            }
            print("window \(window.windowID) \(Int(window.frame.width))x\(Int(window.frame.height))")
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            // The window's own pixels: twice its points on a Retina display.
            configuration.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = URL(fileURLWithPath: arguments[4])
            recording.videoCodecType = .h264
            recording.outputFileType = .mp4
            let outcome = Outcome()
            let output = SCRecordingOutput(configuration: recording, delegate: outcome)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            // When the picture starts, on the clock the demo stamps its
            // sounds with, so they can be laid under the video afterwards.
            FileHandle.standardError.write(Data("capture \(ProcessInfo.processInfo.systemUptime)\n".utf8))
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            // Removing the output closes the file. A file that could not be
            // written is reported only to the delegate, so wait for its word.
            try stream.removeRecordingOutput(output)
            for _ in 0..<100 where outcome.ended == nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            do {
                try await stream.stopCapture()
            } catch where outcome.ended != nil {
                // The window went away as the demo ended, so the stream had
                // already stopped by itself; the file is written all the same.
            }
            switch outcome.ended {
            case .finished: print("recorded \(arguments[4])")
            case let .failed(error): throw error
            case nil:
                print("failed: the recording did not finish")
                exit(1)
            }
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
}

/// How the recording ended, heard from ScreenCaptureKit on its own queue.
private final class Outcome: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    enum End {
        case finished
        case failed(Error)
    }

    private let lock = NSLock()
    private var end: End?

    var ended: End? { lock.withLock { end } }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { if end == nil { end = .finished } }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.withLock { end = .failed(error) }
    }
}
