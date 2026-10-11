import AppKit
@testable import Dictation
import Foundation
import os
import Testing

/// The Report a problem prompt's states over scripted sends, and its window
/// opened, replaced and closed without ever being shown.
@MainActor
@Suite(.serialized)
struct ReportProblemPanelTests {
    @Test func sendsTheTrimmedNoteAndSaysSentOnlyAfterTheSendReturns() async {
        var sent: [String] = []
        let prompt = ReportProblemPrompt(send: { sent.append($0) })
        prompt.text = "  The dot vanished in Notes.\n"
        await prompt.submit()
        #expect(sent == ["The dot vanished in Notes."])
        #expect(prompt.phase == .sent)
        #expect(!prompt.canSend)
        await prompt.submit()
        #expect(sent.count == 1)
    }

    @Test func aFailedSendSaysWhyAndOffersTheSameNoteAgain() async {
        var attempts = 0
        let prompt = ReportProblemPrompt(send: { _ in
            attempts += 1
            if attempts == 1 { throw ProblemReportSubmission.Failure.sendFailed }
        })
        prompt.text = "Paste failed"
        await prompt.submit()
        #expect(prompt.phase == .failed("Couldn't send. Try again.", retry: true))
        #expect(prompt.canSend)
        await prompt.submit()
        #expect(attempts == 2)
        #expect(prompt.phase == .sent)
    }

    @Test func editingAfterAFailureMakesItANewSendRatherThanARetry() async {
        let prompt = ReportProblemPrompt(send: { _ in throw ProblemReportSubmission.Failure.sendFailed })
        prompt.text = "Paste failed"
        await prompt.submit()
        prompt.text = "Paste failed in Notes"
        #expect(prompt.phase == .editing)
    }

    @Test func signedOutAndNoServerSayWhyAndDoNotRetry() async {
        for (failure, words) in [(ProblemReportSubmission.Failure.signedOut, "Sign in to send a report."),
                                 (.unavailable, "Reporting isn't available in this build.")] {
            let prompt = ReportProblemPrompt(send: { _ in throw failure })
            await prompt.submit()
            #expect(prompt.phase == .failed(words, retry: false))
            #expect(!prompt.canSend)
            prompt.text = "edited"
            #expect(prompt.phase == .failed(words, retry: false))
        }
    }

    @Test func anUnknownErrorSaysTheGenericWords() async {
        let prompt = ReportProblemPrompt(send: { _ in throw URLError(.timedOut) })
        await prompt.submit()
        #expect(prompt.phase == .failed(ProblemReportSubmission.Failure.sendFailed.userFacingMessage, retry: true))
    }

    @Test func rateLimitDisablesRetryEvenAfterEditingUntilTheDeadline() async {
        var attempts = 0
        let prompt = ReportProblemPrompt(send: { _ in
            attempts += 1
            if attempts == 1 { throw ProblemReportSubmission.Failure.rateLimited(until: Date().addingTimeInterval(0.1)) }
        })
        await prompt.submit()
        #expect(!prompt.canSend)
        prompt.text = "edited"
        #expect(!prompt.canSend)
        await prompt.submit()
        #expect(attempts == 1)
        await until { prompt.canSend }
        await prompt.submit()
        #expect(attempts == 2 && prompt.phase == .sent)
    }

    @Test func aNoteOverTheLimitIsNeverSent() async {
        var calls = 0
        let prompt = ReportProblemPrompt(send: { _ in calls += 1 })
        prompt.text = String(repeating: "a", count: ProblemReportSubmission.maxTextLength + 1)
        #expect(prompt.isTooLong && !prompt.canSend)
        await prompt.submit()
        #expect(calls == 0 && prompt.phase == .editing)
        prompt.text = String(repeating: "a", count: ProblemReportSubmission.maxTextLength)
        #expect(prompt.canSend)
    }

    @Test func aSecondSendWaitsForTheFirst() async {
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let prompt = ReportProblemPrompt(send: { _ in
            calls += 1
            await withCheckedContinuation { release = $0 }
        })
        let first = Task { await prompt.submit() }
        await until { release != nil }
        #expect(prompt.phase == .sending && !prompt.canSend)
        await prompt.submit()
        #expect(calls == 1)
        release?.resume()
        await first.value
        #expect(prompt.phase == .sent)
    }

    @Test func pickingTheMenuAgainWhileOpenBringsBackTheSameReport() {
        var presented: [NSWindow] = []
        var made = 0
        let panel = ReportProblemPanel(present: { presented.append($0) })
        panel.open { made += 1; return Self.submission() }
        panel.prompt?.text = "half written"
        let first = panel.window
        panel.open { made += 1; return Self.submission() }
        #expect(made == 1)
        #expect(presented.count == 2 && presented[0] === presented[1] && panel.window === first)
        #expect(panel.prompt?.text == "half written")
        panel.close()
    }

    /// The regression: reopening after a sent report closed nothing, so the
    /// sent window stayed up beside the new one.
    @Test func reopeningAfterASentReportClosesTheSentWindow() async {
        var presented: [NSWindow] = []
        let panel = ReportProblemPanel(present: { presented.append($0) })
        panel.open { Self.submission() }
        guard let sentWindow = panel.window, let prompt = panel.prompt else { Issue.record("no window"); return }
        let closedSent = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: sentWindow, queue: nil) { _ in
            closedSent.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await prompt.submit()
        #expect(prompt.phase == .sent)
        panel.open { Self.submission() }
        #expect(presented.count == 2 && presented[1] !== sentWindow && panel.window === presented[1])
        #expect(closedSent.withLock { $0 } == 1)
        panel.close()
        #expect(closedSent.withLock { $0 } == 1)
    }

    /// AppKit may post the close notice off the main thread. The handler
    /// reaches the main actor itself, and a notice from a replaced window
    /// leaves the open one alone.
    @Test func aCloseNoticeFromABackgroundQueueForgetsOnlyItsOwnWindow() async {
        let panel = ReportProblemPanel(present: { _ in })
        panel.open { Self.submission() }
        guard let first = panel.window else { Issue.record("no window"); return }
        let firstID = ObjectIdentifier(first)
        panel.close()
        panel.open { Self.submission() }
        guard let second = panel.window else { Issue.record("no window"); return }
        let fromFirst = ReportProblemPanel.closed(panel, window: firstID)
        let fromSecond = ReportProblemPanel.closed(panel, window: ObjectIdentifier(second))
        let offMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                fromFirst(Notification(name: NSWindow.willCloseNotification))
                fromSecond(Notification(name: NSWindow.willCloseNotification))
                done.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(offMain)
        await until { panel.window == nil }
        #expect(panel.prompt == nil)
        second.close()
    }

    @Test func anOpenReportHoldsUpdatesUntilItCloses() async {
        let panel = ReportProblemPanel(present: { _ in })
        var closed = 0
        panel.didClose = { closed += 1; #expect(!panel.blocksUpdates) }
        panel.open { Self.submission() }
        #expect(panel.blocksUpdates)
        panel.prompt?.text = "Unsent note"
        panel.open { Self.submission() }
        #expect(panel.blocksUpdates && closed == 0)
        await panel.prompt?.submit()
        #expect(panel.blocksUpdates)
        panel.open { Self.submission() }
        #expect(panel.blocksUpdates && closed == 0)
        panel.close()
        #expect(!panel.blocksUpdates && closed == 1)
    }

    @Test func closingDuringSendHoldsUpdatesUntilTheUploadFinishes() async {
        let panel = ReportProblemPanel(present: { _ in })
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        var readyToInstall = 0
        panel.didClose = { if !panel.blocksUpdates { readyToInstall += 1 } }
        panel.open { Self.submission { _ in
            await withCheckedContinuation { continuation in waiting.withLock { $0 = continuation } }
        } }
        guard let prompt = panel.prompt else { Issue.record("no prompt"); return }
        let send = Task { await prompt.submit() }
        await until { waiting.withLock { $0 != nil } }
        panel.close()
        #expect(panel.blocksUpdates && readyToInstall == 0)
        waiting.withLock { $0 }?.resume()
        await send.value
        #expect(!panel.blocksUpdates && readyToInstall == 1)
    }

    @Test func closingTheWindowForgetsItsReport() async {
        let panel = ReportProblemPanel(present: { _ in })
        panel.open { Self.submission() }
        panel.window?.performClose(nil)
        await until { panel.window == nil }
        #expect(panel.prompt == nil)
    }

    private static func submission(send: @escaping @Sendable (ProblemReport) async throws -> Void = { _ in }) -> ProblemReportSubmission {
        let report = ProblemReport(
            report_id: UUID(), text: nil, app_version: "0.1.3", app_build: "15", macos_version: "26.6.2",
            frontmost_bundle_id: "com.example.fixture", captured_at: "2026-10-09T20:00:00.000Z",
            window_started_at: "2026-10-09T19:30:00.000Z", events: [], events_truncated: false,
            setup: .init(finished: true, signed_in: true, microphone: true, accessibility: true, screen_recording: true),
            mail_import: .init(known: true, read_failed: false, connections: 1, importing: 0, ready: 1, reconnect: 0))
        return ProblemReportSubmission(report: report, upload: send)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
