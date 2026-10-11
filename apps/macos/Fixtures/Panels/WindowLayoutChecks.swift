import AppKit
import SwiftUI

/// A SwiftUI app is essential here: a command-line NSApplication does not
/// reproduce the preferredContentSize constraint loop from the shipping app.
/// Settings creates no window. Every production window stays unordered, and
/// all input and submissions are synthetic.
@main
struct WindowLayoutChecks: App {
    @NSApplicationDelegateAdaptor(WindowLayoutDelegate.self) var delegate
    init() { OffscreenRenderGuard.prepare() }
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class WindowLayoutDelegate: NSObject, NSApplicationDelegate {
    private var failures = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        Task {
            await checkReport()
                print("Window layout checks: \(failures == 0 ? "passed" : "FAILED")")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
        fflush(stdout)
    }

    private func settle(_ window: NSWindow, width: CGFloat) async {
        // Let AppKit's real display-cycle observer run between layout passes.
        // The old NSHostingController loops here and raises NSGenericException.
        for _ in 0..<4 {
            window.updateConstraintsIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
        expect(!window.isVisible && !NSApp.isActive, "a check took over the screen")
        guard let view = window.contentView else { expect(false, "missing content"); return }
        expect(view.bounds.width == width, "content width changed: \(view.bounds)")
        expect(view.bounds.height > 200 && view.bounds.height < 1000, "invalid content height: \(view.bounds)")
        let size = window.frame.size
        try? await Task.sleep(for: .milliseconds(60))
        expect(window.frame.size == size, "window did not settle")
    }

    private func checkReport() async {
        Appearance.current = .light
        let panel = ReportProblemPanel(present: { window in
            self.expect(window.frame.width == ReportProblemView.width && window.frame.height > 200,
                        "Report reached presentation with a zero or incomplete size")
        })
        panel.open { Self.submission() }
        guard let window = panel.window, let prompt = panel.prompt else { expect(false, "Report did not open"); return }
        await settle(window, width: ReportProblemView.width)
        let shortHeight = window.frame.height
        prompt.text = String(repeating: "A synthetic report with several lines. ", count: 18)
        await settle(window, width: ReportProblemView.width)
        expect(window.frame.height > shortHeight, "Report did not grow with the note")
        let longHeight = window.frame.height
        prompt.text = "A short synthetic note."
        await settle(window, width: ReportProblemView.width)
        expect(window.frame.height < longHeight, "Report did not shrink with the note")
        for appearance in [Appearance.dark, .light, .dark] {
            Appearance.current = appearance
            await settle(window, width: ReportProblemView.width)
            expect(window.appearance?.name == appearance.nsAppearance?.name, "Report appearance did not update")
        }
        await prompt.submit()
        await settle(window, width: ReportProblemView.width)
        expect(prompt.phase == .sent, "synthetic report was not sent")
        panel.open { Self.submission() }
        expect(panel.window !== window, "Report reused the sent window")
        if let reopened = panel.window { await settle(reopened, width: ReportProblemView.width) }
        panel.close()
    }


    private static func submission() -> ProblemReportSubmission {
        let report = ProblemReport(
            report_id: UUID(), text: nil, app_version: "0.0.1", app_build: "21", macos_version: "fixture",
            frontmost_bundle_id: "com.example.fixture", captured_at: "2026-10-10T17:50:00Z",
            window_started_at: "2026-10-10T17:49:00Z", events: [], events_truncated: false,
            setup: .init(finished: true, signed_in: true, microphone: true, accessibility: true, screen_recording: true),
            mail_import: .init(known: true, read_failed: false, connections: 0, importing: 0, ready: 0, reconnect: 0))
        return ProblemReportSubmission(report: report, upload: { _ in })
    }
}
