import AppKit
import Testing
@testable import Dictation

struct DictationTimingDiagnosticsTests {
    private let origin = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        origin + .milliseconds(milliseconds)
    }

    @Test func offsetsKeepTheSynchronousStopSeparateFromLegacyStages() {
        var timing = DictationTiming(at: origin)
        timing.mark(.streamRequested, at: at(30))
        timing.mark(.stopRequested, at: at(1000))
        timing.mark(.audioStopped, at: at(1250))
        timing.endStage(at: at(1250))
        timing.mark(.stopSent, at: at(1400))
        timing.mark(.transcriptReceived, at: at(1500))
        timing.endStage(at: at(1500))
        timing.mark(.cleanedTextReceived, at: at(1750))
        timing.endStage(at: at(1750))
        timing.mark(.insertStarted, at: at(1800))
        timing.mark(.insertConfirmed, at: at(2000))
        timing.endStage(at: at(2000))

        #expect(timing.markOffsets == [
            "stream_requested": 0.03, "stop_requested": 1, "audio_stopped": 1.25,
            "stop_sent": 1.4, "transcript_received": 1.5, "cleaned_text_received": 1.75,
            "insert_started": 1.8, "insert_confirmed": 2,
        ])
        #expect(timing.intervals == [
            .init(stage: .record, start: 0, duration: 1.25),
            .init(stage: .transcribe, start: 1.25, duration: 0.25),
            .init(stage: .clean, start: 1.5, duration: 0.25),
            .init(stage: .insert, start: 1.75, duration: 0.25),
        ])
        #expect(timing.afterStop == 0.75)
        #expect(timing.retainedTimings["record"] == 1.25)
        #expect(timing.retainedTimings["elapsed"] == 2)
        #expect(timing.retainedTimings["stop_requested"] == 1)
    }

    @Test func missingEventsStayAbsentAndDoNotAdvanceStages() {
        var timing = DictationTiming(at: origin)
        #expect(timing.markOffsets.isEmpty)
        timing.mark(.cleanedTextReceived, at: at(100))
        #expect(timing.currentStage == .record)
        #expect(timing.intervals.isEmpty)
        #expect(timing.markOffsets == ["cleaned_text_received": 0.1])
        #expect(timing.retainedTimings["transcript_received"] == nil)
        #expect(timing.retainedTimings["insert_confirmed"] == nil)
    }

    @Test func executorConfirmationDoesNotShortenTheLegacyInsertionDuration() {
        var timing = DictationTiming(at: origin)
        for milliseconds in [100, 200, 300] { timing.endStage(at: at(milliseconds)) }
        timing.mark(.insertStarted, at: at(350))
        timing.mark(.insertConfirmed, at: at(400))
        timing.endStage(at: at(900))

        #expect(timing.markOffsets["insert_confirmed"] == 0.4)
        #expect(timing.intervals.last == .init(stage: .insert, start: 0.3, duration: 0.6))
        #expect(timing.elapsed == 0.9)
        #expect(timing.afterStop == 0.8)
    }

    @Test func marksKeepTheirFirstInstantWithoutDependingOnCallOrder() {
        var timing = DictationTiming(at: origin)
        timing.mark(.stopRequested, at: at(100))
        timing.mark(.streamRequested, at: at(20))
        timing.mark(.stopRequested, at: at(200))
        timing.mark(.audioStopped, at: at(-10))
        #expect(timing.markOffsets == ["stop_requested": 0.1, "stream_requested": 0.02, "audio_stopped": 0])
    }

    @Test(arguments: ["cancelled", "failed", "silent", "inserted"])
    func terminalTimingsRejectEveryLateMarkAndReset(outcome: String) {
        var timing = DictationTiming(at: origin)
        timing.mark(.streamRequested, at: at(10))
        switch outcome {
        case "cancelled": timing.cancel(at: at(100))
        case "failed": timing.fail(at: at(100))
        case "silent": timing.silent(.heardNothing, at: at(100))
        default:
            for time in [25, 50, 75, 100] { timing.endStage(at: at(time)) }
        }
        let retained = timing.retainedTimings
        for mark in DictationTiming.Mark.allCases { timing.mark(mark, at: at(200)) }
        timing.resetAttemptMarks()
        #expect(timing.retainedTimings == retained)
        #expect(timing.markOffsets == ["stream_requested": 0.01])
        #expect(timing.elapsed == 0.1)
    }

    @Test func reconnectClearsOptionalMarksAndPreservesLegacyStagesAndTheSnapshot() {
        var timing = DictationTiming(at: origin)
        timing.mark(.streamRequested, at: at(10))
        timing.mark(.stopRequested, at: at(100))
        timing.mark(.audioStopped, at: at(120))
        timing.endStage(at: at(120))
        timing.mark(.stopSent, at: at(130))
        timing.mark(.transcriptReceived, at: at(140))
        timing.endStage(at: at(140))
        let firstAttempt = timing
        timing.resetAttemptMarks()
        #expect(timing.markOffsets.isEmpty)
        #expect(timing.intervals == firstAttempt.intervals)
        #expect(timing.currentStage == .clean)
        timing.mark(.streamRequested, at: at(200))
        timing.mark(.stopSent, at: at(210))
        timing.mark(.cleanedTextReceived, at: at(220))
        #expect(timing.markOffsets == ["stream_requested": 0.2, "stop_sent": 0.21, "cleaned_text_received": 0.22])
        #expect(firstAttempt.markOffsets["stop_requested"] == 0.1)
        #expect(firstAttempt.markOffsets["transcript_received"] == 0.14)
    }
}

extension DictationScenarioTests {
    @Test(arguments: ["direct", "paste", "alreadyPresent", "refused", "unconfirmed"])
    func insertionConfirmationIsCapturedOnTheExecutorBeforeClipboardRestoration(kind: String) async throws {
        MockField.reset()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
        field.pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString("saved clipboard", forType: .string)
        let inserter = TextInserter(pasteboard: PasteboardOwner(pasteboard: pasteboard, mayRead: { true }))
        inserter.pasteOnly = kind == "paste"
        if kind == "alreadyPresent" { field.selection = FieldRange(location: 1, length: 1) }
        if kind == "refused" { field.secure = true }
        if kind == "unconfirmed" { field.writes = .ignore }
        let text = kind == "alreadyPresent" ? "b" : "hello"
        let confirmed = ContinuousClock.now
        let pasteboardName = pasteboard.name
        let confirmation = InsertionConfirmation {
            #expect(!Thread.isMainThread)
            if kind == "paste" {
                #expect(NSPasteboard(name: pasteboardName).string(forType: .string) == text)
            }
            return confirmed
        }
        let inserted = await inserter.insert(text, spaced: false, confirmation: confirmation)

        switch kind {
        case "refused":
            #expect(inserted.result == .notInserted(.secureField))
            #expect(confirmation.confirmedAt == nil)
        case "unconfirmed":
            #expect(inserted.result == .unknown(.writeUnconfirmed))
            #expect(confirmation.confirmedAt == nil)
        default:
            #expect(inserted.result == .inserted(kind == "paste" ? .paste : .selectedText,
                                               clipboardRestored: kind == "paste" ? true : nil))
            #expect(confirmation.confirmedAt == confirmed)
            #expect(field.text == (kind == "alreadyPresent" ? "abc" : "ahellobc"))
        }
        #expect(pasteboard.string(forType: .string) == "saved clipboard")
        if kind == "alreadyPresent" { #expect(field.accessibilityWrites == 0) }
    }

    @Test(arguments: ["confirmed", "refused", "unconfirmed", "setup"])
    func diagnosticInsertionMarksFollowTheActualResult(kind: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        if kind == "refused" { field.secure = true }
        if kind == "unconfirmed" { field.writes = .ignore }
        dictation.isForSetup = { kind == "setup" }
        var recorded: DictationTiming?
        dictation.onOutcome = { _, timing, _ in recorded = timing }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let timing = try #require(recorded)
        let marks = timing.markOffsets
        for key in ["stream_requested", "stop_requested", "audio_stopped", "stop_sent",
                    "transcript_received", "cleaned_text_received"] {
            #expect(marks[key] != nil)
        }
        #expect((marks["stop_requested"] ?? 0) <= (marks["audio_stopped"] ?? 0))
        #expect((marks["audio_stopped"] ?? 0) <= (marks["stop_sent"] ?? 0))
        // URLSession can deliver a receive before its successful send callback.
        // Each mark records its own callback boundary, without imposing their order.
        #expect((marks["transcript_received"] ?? 0) <= (marks["cleaned_text_received"] ?? 0))
        #expect((marks["insert_started"] != nil) == (kind != "setup"))
        #expect((marks["insert_confirmed"] != nil) == (kind == "confirmed"))
        if kind == "confirmed" {
            #expect((marks["cleaned_text_received"] ?? 0) <= (marks["insert_started"] ?? 0))
            #expect((marks["insert_started"] ?? 0) <= (marks["insert_confirmed"] ?? 0))
        }
    }

    @Test func retainedReconnectDoesNotInheritTheFirstAttemptsStopMarks() async throws {
        let server = try await ScriptedEndpoint([.refuse("internal"), .answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deliveries = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await deliveries.add(key: key, path: path, bytes: bytes)
            return 204
        }
        archive.bind(key: "synthetic-key")
        let dictation = controller(server.endpoint)
        dictation.archive = archive
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(await archive.flush())
        #expect(await deliveries.waitForCount(2))
        let items = await deliveries.all.filter { $0.path.hasPrefix("v1/retention/dictations/") }
        #expect(items.count == 2)
        let records = try items.map { item in
            let length = item.bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            return try #require(JSONSerialization.jsonObject(with: item.bytes.subdata(in: 4..<(4 + length))) as? [String: Any])
        }
        let first = try #require(records.first)
        let second = try #require(records.last)
        let initial = try #require(first["timings"] as? [String: Double])
        let retry = try #require(second["timings"] as? [String: Double])
        #expect(first["retry_of"] == nil)
        #expect(second["retry_of"] as? String != nil)
        #expect(initial["stop_requested"] != nil)
        #expect(initial["audio_stopped"] != nil)
        #expect(initial["stop_sent"] != nil)
        #expect(initial["insert_started"] == nil)
        #expect(retry["stop_requested"] == nil)
        #expect(retry["audio_stopped"] == nil)
        #expect(retry["stream_requested"] != nil)
        #expect(retry["stop_sent"] != nil)
        #expect(retry["insert_confirmed"] != nil)
        #expect(retry["record"] == initial["record"])
    }

    @Test func refusedConnectionDoesNotClaimTheStopWasSent() async throws {
        let server = try await RefusingServer()
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var recorded: DictationTiming?
        dictation.onOutcome = { _, timing, _ in recorded = timing }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let timing = try #require(recorded)
        #expect(timing.markOffsets["stream_requested"] != nil)
        for key in ["stop_sent", "transcript_received", "cleaned_text_received", "insert_started", "insert_confirmed"] {
            #expect(timing.markOffsets[key] == nil)
        }
    }
}

extension DictationTimingDiagnosticsTests {
    @MainActor
    @Test func bufferedRepliesKeepReceiptTimesBeforeDecodingAndMainActorConsumption() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let clock = DiagnosticClock(at(100))
        let transcriptDecoded = at(200)
        let textDecoded = at(900)
        let stream = DictationStream(url: server.endpoint.url, grant: ScriptedEndpoint.grant,
            start: DictationStart(register: "work"),
            decode: { text in
                let value = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                let type = (value as? [String: Any])?["type"] as? String
                if type == "transcript" { clock.set(transcriptDecoded) }
                if type == "text" { clock.set(textDecoded) }
                return value
            }, now: { clock.instant })
        defer { stream.cancel() }
        #expect(await stream.finish())
        let arrived = await eventually { stream.timingSnapshot.cleanedTextReceived != nil }
        #expect(arrived)

        // Both messages have arrived, but the main actor has consumed neither.
        // Decoding moved the fixture clock, so these also prove capture preceded it.
        let received = stream.timingSnapshot
        #expect(received.transcriptReceived == at(100))
        #expect(received.cleanedTextReceived == at(200))
        var timing = DictationTiming(at: origin)
        timing.endStage(at: at(50))
        for try await reply in stream.replies {
            timing.markTransport(stream.timingSnapshot)
            if timing.currentStage == .transcribe { timing.endStage(at: at(1000)) }
            if case .text = reply, timing.currentStage == .clean { timing.endStage(at: at(1100)) }
        }
        #expect(timing.markOffsets["transcript_received"] == 0.1)
        #expect(timing.markOffsets["cleaned_text_received"] == 0.2)
        #expect(timing.intervals == [
            .init(stage: .record, start: 0, duration: 0.05),
            .init(stage: .transcribe, start: 0.05, duration: 0.95),
            .init(stage: .clean, start: 1, duration: 0.1),
        ])
    }

    @MainActor
    @Test(arguments: [true, false], [true, false])
    func stopCallbackAfterUploadCapRecordsOnlySuccessfulSendsBeforeTheOutcome(succeeded: Bool, afterOutcome: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let clock = DiagnosticClock(at(30_000))
        let stop = DiagnosticStopCallback()
        let stream = DictationStream(url: server.endpoint.url, grant: ScriptedEndpoint.grant,
            start: DictationStart(register: "work"), now: { clock.instant },
            sendMessage: { source, message, completion in
                source.send(message) { error in
                    if case let .string(text) = message, text.contains(#""type":"stop""#) {
                        stop.hold {
                            completion(succeeded ? error : URLError(.networkConnectionLost))
                        }
                    } else { completion(error) }
                }
            })
        defer { stream.cancel() }
        // The injected wait reaches the real 30-second cap without wall-clock waiting.
        await DictationController.upload(stream, byteCount: 0, wait: { cap in
            #expect(cap == .seconds(30))
        })
        let callbackHeld = await eventually { stop.isHeld }
        #expect(callbackHeld)
        let answerBuffered = await eventually { stream.timingSnapshot.cleanedTextReceived != nil }
        #expect(answerBuffered)
        #expect(stream.timingSnapshot.stopSent == nil)

        var timing = DictationTiming(at: origin)
        for try await _ in stream.replies { timing.markTransport(stream.timingSnapshot) }
        if afterOutcome {
            // The answer and insertion may finish while the URLSession send
            // callback is still pending. The published outcome stays fixed.
            for milliseconds in [30_100, 30_200, 30_300, 30_400] { timing.endStage(at: at(milliseconds)) }
        }
        let retainedBeforeCallback = timing.retainedTimings
        clock.set(at(31_000))
        stop.release()
        #expect(stream.timingSnapshot.stopSent == (succeeded ? at(31_000) : nil))
        timing.markTransport(stream.timingSnapshot)
        if afterOutcome {
            #expect(timing.retainedTimings == retainedBeforeCallback)
            #expect(timing.outcome == .inserted)
        } else {
            timing.fail(at: at(40_000))
        }
        #expect(timing.retainedTimings["stop_sent"] == (succeeded && !afterOutcome ? 31 : nil))
        #expect(timing.markOffsets["transcript_received"] != nil)
        #expect(timing.markOffsets["cleaned_text_received"] != nil)
    }

    @Test func importingSnapshotsPreservesFirstAndTerminalMarks() {
        var timing = DictationTiming(at: origin)
        timing.markTransport(.init(stopSent: at(100), transcriptReceived: at(200)))
        timing.markTransport(.init(stopSent: at(300), transcriptReceived: at(400), cleanedTextReceived: at(500)))
        #expect(timing.markOffsets == ["stop_sent": 0.1, "transcript_received": 0.2, "cleaned_text_received": 0.5])
        timing.cancel(at: at(600))
        let retained = timing.retainedTimings
        timing.markTransport(.init(stopSent: at(700), transcriptReceived: at(800), cleanedTextReceived: at(900)))
        #expect(timing.retainedTimings == retained)
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private final class DiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousClock.Instant

    init(_ value: ContinuousClock.Instant) { self.value = value }
    var instant: ContinuousClock.Instant { lock.withLock { value } }
    func set(_ value: ContinuousClock.Instant) { lock.withLock { self.value = value } }
}

private final class DiagnosticStopCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?

    var isHeld: Bool { lock.withLock { completion != nil } }
    func hold(_ completion: @escaping @Sendable () -> Void) { lock.withLock { self.completion = completion } }
    func release() {
        let callback = lock.withLock {
            let callback = completion
            completion = nil
            return callback
        }
        callback?()
    }
}
