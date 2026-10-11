import AVFoundation
import AppKit
@testable import Dictation
import Testing

/// Plays scripted audio into dictation: some chunks as soon as recording
/// starts, before the connection is ready, and one partial chunk at the stop.
/// Samples are `level`, except that the first `zeros` of every hundred are
/// exactly zero, so the audio is never silent unless asked to be. With a
/// `device`, it says it opened a microphone of that name, as `Microphone`
/// does; without one it names none, as a recording played in its place.
@MainActor
final class ScriptedSource: SpeechAudioSource {
    let chunks: Int
    private let level: Int16
    private let zeros: Int
    private let device: String?
    private var audio: (@Sendable (Data) -> Void)?
    private var interrupted: (@MainActor () -> Void)?
    private(set) var running = false
    var whileStarting: (() throws -> Void)?

    init(chunks: Int = 3, level: Int16 = 257, zeros: Int = 0, device: String? = nil) {
        self.chunks = chunks
        self.level = level
        self.zeros = zeros
        self.device = device
    }

    private func samples(_ bytes: Int) -> Data {
        let samples = (0..<bytes / 2).map { $0 % 100 < zeros ? Int16(0) : level.littleEndian }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Chunks handed on per recording: those at the start and the last one.
    var sent: Int { chunks + 1 }

    func start(audio: @escaping @Sendable (Data) -> Void, interrupted: @escaping @MainActor () -> Void,
               device opened: @escaping @MainActor (String) -> Void) throws {
        try whileStarting?()
        running = true
        self.audio = audio
        self.interrupted = interrupted
        if let device { opened(device) }
        for _ in 0..<chunks { audio(samples(SpeechAudioConverter.chunkBytes)) }
    }

    /// One more chunk of speech, as the microphone hands it on mid-recording.
    func say(_ chunk: Data) {
        audio?(chunk)
    }

    /// The microphone gives out mid-recording, as a device that cannot be
    /// reopened does: recording stops and dictation is told.
    func interrupt() {
        guard running, let interrupted else { return }
        stop()
        self.interrupted = nil
        interrupted()
    }

    /// What recording hands chunks to, for handing one on from another queue.
    var callback: (@Sendable (Data) -> Void)? { audio }

    func stop() {
        guard running else { return }
        running = false
        audio?(samples(1_000))
        audio = nil
    }
}

/// Chunks handed on by the microphone's path, from whichever thread.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Data] = []

    func add(_ chunk: Data) {
        lock.withLock { all.append(chunk) }
    }

    var chunks: [Data] { lock.withLock { all } }
}

/// Dictation from the trigger to the field, against a local stand-in for the
/// endpoint and the scripted field from the inserter scenarios, which holds
/// "abc" with the caret after "a".
@MainActor
@Suite(.serialized)
struct DictationScenarioTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
    var field: MockField { .shared }

    func controller(_ endpoint: DictationEndpoint?, source: any SpeechAudioSource = ScriptedSource(),
                            signedIn: Bool = true, clipboardReadable: Bool = true, owner: PasteboardOwner? = nil) -> DictationController {
        MockField.reset()
        MockField.shared.pasteboard = pasteboard
        let inserter = TextInserter(pasteboard: owner ?? PasteboardOwner(pasteboard: pasteboard, mayRead: { clipboardReadable }))
        return DictationController(inserter: inserter, history: DictationHistory(file: nil), endpoint: endpoint, source: source,
                                   signedIn: signedIn)
    }

    /// Lets the field be found and the connection open, as the first words
    /// of a real dictation would.
    func speak() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    func idle(_ controller: DictationController) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while controller.phase != .idle, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.phase == .idle)
    }

    @Test func pasteLastUsesTheNewestFinishedTextAndNeverLogsIt() async throws {
        let dictation = controller(nil)
        dictation.history.add(.init(id: UUID(), date: Date(timeIntervalSince1970: 100), text: "Older synthetic words", outcome: .inserted))
        dictation.history.add(.init(id: UUID(), date: Date(timeIntervalSince1970: 200), text: "Newest synthetic words.",
                                   outcome: .inserted, spoken: "the original spoken cue"))
        let before = AppLog.dictationLines.all.count
        #expect(dictation.canPasteLast)
        dictation.pasteLast()
        #expect(dictation.phase == .processing)
        #expect(!dictation.canPasteLast)
        // A second press during insertion cannot enqueue another paste.
        dictation.pasteLast()
        await idle(dictation)
        #expect(dictation.canPasteLast)
        #expect(field.text == "aNewest synthetic words.bc")
        #expect(field.accessibilityWrites == 1)
        #expect(dictation.history.entries.first?.text == "Newest synthetic words.")
        #expect(dictation.history.entries.first?.outcome == .inserted)
        // Pasted again, not dictated again: no new row.
        #expect(dictation.history.entries.count == 2)
        let logged = AppLog.dictationLines.all.dropFirst(before)
        #expect(logged.contains { $0.hasPrefix("dictation insert.inserted.") })
        #expect(!logged.contains { $0.contains("synthetic") || $0.contains("spoken cue") })
        #expect(!AppLog.edits.contains { $0.contains("synthetic") || $0.contains("spoken cue") })
    }

    /// A reply proposal is never the last dictation: one the person ignored
    /// must not go in without their own accept, and an accepted one was not
    /// dictated either.
    @Test func pasteLastSkipsReplyProposals() async {
        let dictation = controller(nil)
        dictation.history.add(.init(id: UUID(), date: Date(timeIntervalSince1970: 100), text: "Dictated synthetic words", outcome: .inserted))
        dictation.history.add(.init(id: UUID(), date: Date(timeIntervalSince1970: 200), text: "Unused synthetic draft", outcome: .notInserted,
                                   proposal: .unused))
        dictation.history.add(.init(id: UUID(), date: Date(timeIntervalSince1970: 300), text: "Accepted synthetic draft", outcome: .inserted,
                                   proposal: .accepted))
        #expect(dictation.canPasteLast)
        dictation.pasteLast()
        await idle(dictation)
        #expect(field.text == "aDictated synthetic wordsbc")
        let onlyProposals = controller(nil)
        onlyProposals.history.add(.init(id: UUID(), date: Date(), text: "Unused synthetic draft", outcome: .notInserted, proposal: .unused))
        #expect(!onlyProposals.canPasteLast)
    }

    @Test func pasteLastUsesTheKeptTranscriptWhenFormattingNeverFinished() async {
        let dictation = controller(nil)
        dictation.history.add(.init(id: UUID(), date: Date(), text: "unfinished synthetic transcript", outcome: .failed))
        dictation.pasteLast()
        await idle(dictation)
        #expect(field.text == "aunfinished synthetic transcriptbc")
    }

    @Test func pasteLastRefusesASecureFieldAndOffersConcealedCopy() async {
        let dictation = controller(nil)
        dictation.history.add(.init(id: UUID(), date: Date(), text: "Synthetic private words", outcome: .inserted))
        let popup = InsertionPopup()
        popup.showsWindow = false
        defer { popup.hide() }
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        popup.copy = { owner.copy($0, concealed: $1) }
        dictation.notInserted = { popup.show($0, text: $1, from: .screenFoot) }
        field.secure = true
        dictation.pasteLast()
        await idle(dictation)
        #expect(field.text == "abc")
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.textReadsWhileSecure == 0)
        // The refusal is said in the popup; history keeps its one row as it was.
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.history.entries.first?.outcome == .inserted)
        #expect(popup.current?.text == InsertionPopup.hidden)
        #expect(popup.copyText())
        #expect(pasteboard.string(forType: .string) == "Synthetic private words")
        #expect(pasteboard.types?.contains(PasteboardOwner.concealedType) == true)
    }

    @Test(arguments: [EditReason.noTextField, .ownApp])
    func pasteLastRefusesMissingFieldsAndIntentionsOwnWindows(_ reason: EditReason) async {
        let dictation = controller(nil)
        dictation.history.add(.init(id: UUID(), date: Date(), text: "Synthetic saved words", outcome: .inserted))
        var refusals: [EditReason] = []
        dictation.notInserted = { reason, _ in refusals.append(reason) }
        if reason == .ownApp {
            field.appPID = ProcessInfo.processInfo.processIdentifier
        } else {
            field.focused = false
        }
        dictation.pasteLast()
        await idle(dictation)
        #expect(field.text == "abc")
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(refusals == [reason])
        #expect(dictation.history.entries.count == 1)
        #expect(dictation.history.entries.first?.outcome == .inserted)
    }

    @Test func pasteLastDoesNothingWhileRecordingOrWaitingForText() async throws {
        let server = try await ScriptedEndpoint([.answerLate(after: 0.3, transcript: "new recording", text: "New recording.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.history.add(.init(id: UUID(), date: Date(), text: "Saved synthetic words", outcome: .inserted))
        dictation.toggle()
        #expect(dictation.phase == .recording)
        #expect(!dictation.canPasteLast)
        dictation.pasteLast()
        #expect(field.text == "abc")
        #expect(dictation.history.entries.count == 1)
        await speak()
        dictation.toggle()
        #expect(dictation.phase == .processing)
        #expect(!dictation.canPasteLast)
        dictation.pasteLast()
        await idle(dictation)
        #expect(field.text == "aNew recording.bc")
        #expect(dictation.history.entries.count == 2)
    }

    @Test func pasteLastWaitsOutAnEarlierPastesClipboardHold() async {
        // After a paste no field showed, the inserter holds the clipboard
        // for a while; a paste asked for then would land wherever focus
        // went meanwhile, so it is not offered and a press does nothing.
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        let dictation = controller(nil, owner: owner)
        dictation.history.add(.init(id: UUID(), date: Date(), text: "Saved synthetic words", outcome: .inserted))
        owner.borrow()
        #expect(!dictation.canPasteLast)
        let before = AppLog.dictationLines.all.count
        dictation.pasteLast()
        #expect(dictation.phase == .idle)
        #expect(field.text == "abc")
        #expect(Array(AppLog.dictationLines.all.dropFirst(before)) == ["dictation pasteLast.busy"])
        owner.giveBack()
        #expect(dictation.canPasteLast)
        dictation.pasteLast()
        await idle(dictation)
        #expect(field.text == "aSaved synthetic wordsbc")
    }

    @Test func pasteLastWithNoWordsUsesTheExistingNoticePath() {
        let dictation = controller(nil)
        let before = AppLog.dictationLines.all.count
        var notices: [String] = []
        #expect(!dictation.canPasteLast)
        dictation.noticeChanged = { if let notice = $0 { notices.append(notice.text) } }
        dictation.pasteLast()
        #expect(dictation.phase == .idle)
        #expect(field.accessibilityWrites == 0)
        #expect(dictation.history.entries.isEmpty)
        #expect(notices == ["Nothing to paste yet"])
        #expect(Array(AppLog.dictationLines.all.dropFirst(before)) == ["dictation pasteLast.empty"])
    }

    @Test func retentionCancellationKeepsOneSnapshotAndDoesNotBlockLaterUploads() async throws {
        let server = try await ScriptedEndpoint([.answerLate(after: 0.6, transcript: "late", text: "Late.")])
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = InteractionArchive(directory: folder) { _, _, _ in throw URLError(.notConnectedToInternet) }
        archive.bind(key: "synthetic-key")
        let dictation = controller(server.endpoint)
        dictation.archive = archive
        dictation.toggle()
        await speak()
        dictation.toggle()
        await speak()
        dictation.accountChanged(signedIn: false)
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await archive.flush()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await archive.flush())
        let id = UUID()
        archive.dictation(.init(id: id, historyID: id, startedAt: Date(), finishedAt: Date(),
                               transcript: "next", formatted: "Next.", text: "Next.", outcome: "inserted"),
                          audio: [], scope: archive.scope)
        #expect(await archive.flush())
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let envelopes = try files.filter { $0.pathExtension == "json" }.map {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])
        }
        #expect(envelopes.filter { ($0["path"] as? String)?.hasPrefix("v1/retention/dictations/") == true }.count == 2)
        #expect(envelopes.filter { $0["path"] as? String == "v1/retention/events" }.count == 3)
    }

    @Test func retentionFinishesAnActiveRecordingBeforeQuit() async throws {
        let server = try await ScriptedEndpoint([.cancelledRetention(data: Data("{}".utf8), delay: 0.1)])
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deliveries = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, data in
            await deliveries.add(key: key, path: path, bytes: data)
            return 204
        }
        archive.bind(key: "synthetic-key")
        let dictation = controller(server.endpoint)
        dictation.archive = archive
        dictation.toggle()
        await speak()
        #expect(!(await dictation.prepareToQuit()))
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await archive.flush()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await dictation.prepareToQuit())
        #expect(dictation.phase == .idle)
        #expect(await deliveries.waitForCount(4))
        let item = try #require(await deliveries.firstDictation)
        let count = item.bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let metadata = try JSONSerialization.jsonObject(with: item.bytes.subdata(in: 4..<(4 + count))) as? [String: Any]
        #expect(metadata?["outcome"] as? String == "cancelled")
        #expect(metadata?["target_kind"] as? String != nil)
    }

    @Test func blockedArchiveDoesNotDelayDictationAndKeepsItsAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let barrier = ArchiveBarrier()
        let delivered = ArchiveDeliveries()
        let archive = InteractionArchive(directory: folder) { key, path, bytes in
            await barrier.wait()
            await delivered.add(key: key, path: path, bytes: bytes)
            return 204
        }
        archive.bind(key: "synthetic-device-key")
        let server = try await ScriptedEndpoint([
            .answer(transcript: "hello there", text: "Hello there."),
            .answer(transcript: "hello there", text: "Hello there.")
        ])
        defer { server.stop() }
        // Measure the same scripted path without retention before comparing
        // the uploader path. The sender stays blocked throughout insertion.
        let baseline = controller(server.endpoint)
        baseline.toggle()
        await speak()
        let baselineStop = ContinuousClock.now
        baseline.toggle()
        await idle(baseline)
        let baselineLatency = ContinuousClock.now - baselineStop
        let dictation = controller(server.endpoint)
        dictation.archive = archive
        dictation.toggle()
        await speak()
        let stopped = ContinuousClock.now
        dictation.toggle()
        await idle(dictation)
        let retainedLatency = ContinuousClock.now - stopped
        print("Retention insertion baseline=\(baselineLatency) queued=\(retainedLatency)")
        #expect(retainedLatency < .seconds(2))
        #expect(retainedLatency <= baselineLatency + .milliseconds(100))
        #expect(field.text == "aHello there.bc")
        #expect(await delivered.count == 0)
        #expect(await archive.flush())
        await barrier.release()
        #expect(await delivered.waitForCount(1))
        let bytes = try #require(await delivered.first?.bytes)
        let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let json = try #require(try JSONSerialization.jsonObject(with: bytes.subdata(in: 4..<(4 + length))) as? [String: Any])
        #expect(json["transcript"] as? String == "hello there")
        #expect(json["text"] as? String == "Hello there.")
        #expect(json["outcome"] as? String == "inserted")
        #expect(json["target_kind"] as? String == "native")
        #expect(bytes.count > 4 + length)
    }

    @Test func aClickedDictationGoesIntoTheFieldItStartedIn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "um hello there", text: "Hello there.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        var phases: [DictationController.Phase] = []
        dictation.phaseChanged = { phases.append($0) }
        dictation.toggle()
        #expect(dictation.phase == .recording)
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(phases == [.recording, .processing, .idle])
        #expect(field.text == "aHello there.bc")
        let connection = try #require(server.connections.first)
        #expect(server.connections.count == 1)
        #expect(connection.frames == source.sent)
        #expect(connection.stopFrames == source.sent)
        // The scripted app is Mail, and the text before the caret is "a".
        #expect(connection.start["app"] as? String == "email")
        #expect(connection.start["before"] as? String == "a")
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.text == "Hello there.")
        #expect(entry.outcome == .inserted)
        #expect(!dictation.history.needsAttention)
    }

    /// The foot as the app wires it, with `respond(to:)` and the phase. The
    /// clicks go to the foot's click target through its own hit testing
    /// (`NSWindow.click` in FootMarkTests.swift); nothing is posted to the
    /// system and no window is put on screen. `saysWords` is true when the
    /// caret dot is hidden, as the app sets it.
    func foot(for dictation: DictationController, saysWords: Bool = true,
              noticeWait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
              popup: @escaping (DictationController.EmptyResult) -> Void = { _ in }) -> FootMark {
        let screen = FootMark.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                     usable: CGRect(x: 0, y: 80, width: 1440, height: 795))
        let foot = FootMark(desktop: .init(screens: { [screen] }, pointer: { CGPoint(x: 700, y: 400) }, showsWindow: false),
                            noticeWait: noticeWait)
        // The pointer has rested on the foot, so its slip opens at once.
        foot.hoverDelay = .zero
        foot.enabled = true
        foot.saysWords = saysWords
        foot.onAction = { dictation.respond(to: $0) }
        // Silence goes to the foot, as AppModel's `say` sends it with the
        // caret dot hidden, and an empty result worth acting on to `popup`,
        // as AppModel opens the insertion popup for it.
        DictationIndicators.connect(dictation, foot: foot, phase: { _ in }, notice: { _ in }, silence: { foot.show($0) },
                                    nothing: popup)
        dictation.levelChanged = { foot.level = $0 }
        return foot
    }

    /// A click on the foot's click target, which takes one anywhere on it.
    func click(_ foot: FootMark) {
        foot.target.click(at: CGPoint(x: foot.target.frame.width / 2, y: foot.target.frame.height / 2))
    }

    /// VoiceOver's other action on the listening sun, Cancel dictation.
    func cancel(_ foot: FootMark) throws {
        let view = try #require(foot.target.contentView)
        let done = try #require(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        let cancel = try #require(done.accessibilityCustomActions()?.first { $0.name == "Cancel dictation" })
        let target = try #require(cancel.target as? NSObject)
        _ = target.perform(cancel.selector, with: cancel)
    }

    @Test func theFootsHintStartsADictationAndAClickOnTheSunInsertsIt() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "um hello there", text: "Hello there.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation)
        foot.hover(true)
        #expect(foot.presentation == .hint)
        click(foot)
        #expect(dictation.phase == .recording)
        // The sun is its own stop button and shows nothing more.
        #expect(foot.presentation == .listening)
        await speak()
        click(foot)
        #expect(dictation.phase != .recording)
        // While the text is on its way the warm sun says so, under the
        // pointer too: the microphone belongs to the resting dot.
        #expect(foot.state == .writing)
        #expect(foot.presentation == .writing)
        await idle(dictation)
        #expect(foot.state == .resting)
        #expect(field.text == "aHello there.bc")
        #expect(dictation.history.entries.first?.outcome == .inserted)
    }

    /// A dictation started from the foot's hint has no key to let go:
    /// Escape cancels it, nothing goes in and nothing stays in history, and
    /// the foot rests rather than staying on the sun.
    @Test func escapeCancelsADictationStartedFromTheFoot() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation, saysWords: false)
        foot.hover(true)
        click(foot)
        #expect(dictation.phase == .recording)
        await speak()
        dictation.escapePressed()
        #expect(dictation.phase == .idle)
        #expect(foot.state == .resting)
        #expect(foot.mark.phase == .resting)
        await speak()
        #expect(field.text == "abc")
        #expect(field.accessibilityWrites == 0)
        #expect(dictation.history.entries.isEmpty)
        #expect(server.connections.allSatisfy { $0.stopFrames == nil })
    }

    /// Escape is Intention's only while a dictation records, however it was
    /// started: the trigger's tap takes it, so it never reaches the field's
    /// app, where it could close a compose or a dialog, and lets it through
    /// at every other time. Wired as AppModel wires it, from the phase.
    @Test func escapeIsTakenFromTheAppOnlyWhileADictationStartedFromTheFootRecords() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation, saysWords: false)
        let key = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        key.onEscape = { dictation.escapePressed() }
        DictationIndicators.connect(dictation, foot: foot, phase: { key.recording = $0 == .recording }, notice: { _ in },
                                    silence: { _ in }, nothing: { _ in })
        var claims = KeyClaims()
        func escapeTaken() -> Bool {
            claims.escapeCancels = key.takesEscape
            let down = claims.key(KeyClaims.escape, down: true, flags: []).take
            _ = claims.key(KeyClaims.escape, down: false, flags: [])
            return down
        }
        #expect(!escapeTaken())
        foot.hover(true)
        click(foot)
        #expect(dictation.phase == .recording)
        #expect(escapeTaken())
        await speak()
        dictation.escapePressed()
        #expect(dictation.phase == .idle)
        #expect(!escapeTaken())
        #expect(field.text == "abc")
    }

    @Test func voiceOversCancelOnTheSunDropsTheDictationAndInsertsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation)
        // A click on the bare dot shows the hint; a click on that starts it.
        click(foot)
        #expect(dictation.phase == .idle)
        #expect(foot.presentation == .hint)
        click(foot)
        #expect(dictation.phase == .recording)
        await speak()
        try cancel(foot)
        await idle(dictation)
        #expect(foot.state == .resting)
        #expect(field.text == "abc")
        #expect(field.accessibilityWrites == 0)
        #expect(dictation.history.entries.isEmpty)
        // The endpoint was never told the recording had ended.
        #expect(server.connections.allSatisfy { $0.stopFrames == nil })
    }

    @Test func theVoiceReachesTheFootOnlyWhileRecording() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource(chunks: 0)
        let dictation = controller(server.endpoint, source: source)
        var levels: [Double] = []
        dictation.levelChanged = { levels.append($0) }
        dictation.toggle()
        let audio = try #require(source.callback)
        // Sustain each input until it is observable, even if main-actor
        // deliveries coalesce while a loaded runner is busy.
        let loud = Self.sustain(audio, amplitude: 16_000)
        defer { loud.cancel() }
        #expect(await eventually { levels.max().map { $0 > 0.9 } == true })
        loud.cancel()
        let quiet = Self.sustain(audio, amplitude: 20)
        defer { quiet.cancel() }
        #expect(await eventually { levels.last.map { $0 < 0.05 } == true })
        quiet.cancel()
        dictation.toggle()
        let stoppedCount = levels.count
        await idle(dictation)
        // The chunk recording closes with is not shown.
        #expect(levels.count == stoppedCount)
    }

    /// The microphone hands chunks on from its own audio thread. A chunk
    /// sent from a background queue, as it does, reaches the indicators on
    /// the main thread, with no main-actor closure called off it, which
    /// would trap at runtime.
    @Test func aChunkFromTheAudioThreadReachesTheIndicatorsOnTheMainThread() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource(chunks: 0)
        let dictation = controller(server.endpoint, source: source)
        var heard: [(level: Double, main: Bool)] = []
        dictation.levelChanged = { heard.append(($0, Thread.isMainThread)) }
        dictation.toggle()
        await speak()
        heard.removeAll()
        let audio = try #require(source.callback)
        let loud = Self.sustain(audio, amplitude: 16_000)
        defer { loud.cancel() }
        let sentOffMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInteractive).async { @Sendable in
                audio(Self.tone(amplitude: 16_000))
                done.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(sentOffMain)
        #expect(await eventually { heard.map(\.level).max().map { $0 > 0.9 } == true })
        #expect(heard.allSatisfy { $0.main })
        loud.cancel()
        dictation.cancel()
        await idle(dictation)
    }

    nonisolated static func sustain(_ audio: @escaping @Sendable (Data) -> Void,
                                    amplitude: Double) -> DispatchSourceTimer {
        let chunk = tone(amplitude: amplitude)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "co.intention.tests.sustainedAudio"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { @Sendable in audio(chunk) }
        timer.resume()
        return timer
    }

    /// 100 ms of a 200 Hz tone at `amplitude`, as 16 kHz 16-bit PCM.
    nonisolated static func tone(amplitude: Double) -> Data {
        var data = Data()
        for index in 0..<1_600 {
            let sample = Int16(amplitude * sin(Double(index) * 2 * .pi * 200 / 16_000))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func aPasteThatCannotPutTheClipboardBackStillGoesInAndSaysSo() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello there", text: "Hello there.")])
        defer { server.stop() }
        // macOS does not let Intention read the clipboard, and the field takes
        // only a paste.
        let dictation = controller(server.endpoint, clipboardReadable: false)
        field.writes = .refuse
        pasteboard.clearContents()
        pasteboard.setString("the person's clipboard", forType: .string)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello there.bc")
        #expect(pasteboard.string(forType: .string) == "Hello there.")
        #expect(dictation.notice == .clipboardReplaced)
        #expect(DictationController.Notice.clipboardReplaced.text == "Pasted it, which replaced what you'd copied")
        // The menu bar item offers to allow reading the clipboard from now on.
        #expect(dictation.pasteReplacedClipboard)
    }

    @Test func checkPreparationWaitsForAnUnconfirmedDictationBeforeACrashAndRestart() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First.")])
        defer { server.stop() }
        MockField.reset()
        field.pasteboard = pasteboard
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("the person's clipboard", forType: .string)
        item.setData(Data([0, 255, 0]), forType: .init("co.intention.tests.binary"))
        pasteboard.writeObjects([item])
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        let saved = try #require(await owner.backUp().snapshot)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("intention-dictation-clipboard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = InsertionCheckClipboard.RecoveryFile(url: root.appendingPathComponent("clipboard.json"))
        let run = InsertionCheckClipboard.Run(file: file)
        #expect(try await run.prepareSentinel(current: saved, ownsCurrent: false,
            sentinels: ["first sentinel"], currentChangeCount: { pasteboard.changeCount }))
        let backupBytes = try Data(contentsOf: file.url)
        let stateBytes = try Data(contentsOf: file.stateURL)
        pasteboard.clearContents()
        pasteboard.setString("first sentinel", forType: .string)
        let dictationInserter = TextInserter(pasteboard: owner)
        let dictation = DictationController(inserter: dictationInserter, history: DictationHistory(file: nil),
            endpoint: server.endpoint, source: ScriptedSource(), signedIn: true)
        field.writes = .refuse
        field.pastesLand = false
        dictation.onOutcome = { result, _, _ in
            run.recordInsertion(result, with: dictationInserter)
        }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(run.pasteUnconfirmed)
        #expect(dictationInserter.clipboardRestorationPending)
        #expect(pasteboard.string(forType: .string) == "First.")
        // The second scene asks to prepare immediately inside the late-read
        // window. It must wait for the dictation borrow even when refusing.
        #expect(await run.mayPrepareSentinel(inserters: [dictationInserter]) == false)
        #expect(!dictationInserter.clipboardRestorationPending)
        #expect(pasteboard.string(forType: .string) == "first sentinel")
        #expect(try Data(contentsOf: file.url) == backupBytes)
        #expect(try Data(contentsOf: file.stateURL) == stateBytes)
        // Simulate exit without cleanup, then a new process reading the file.
        // On the unfixed gate, let the pending return finish before recovery.
        if dictationInserter.clipboardRestorationPending {
            try await Task.sleep(for: TextInserter.lateReadWindow + .milliseconds(100))
        }
        let outcome = try InsertionCheckClipboard.RecoveryFile(url: file.url)
            .recover(current: await owner.backUp()) { copy, changeCount in
                #expect(copy.checkMatches(saved))
                return owner.restore(copy, ifUnchangedSince: changeCount)
            }
        #expect(outcome == .restored)
        let restored = try #require(await owner.backUp().snapshot)
        #expect(restored.checkMatches(saved))
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(!FileManager.default.fileExists(atPath: file.stateURL.path))
    }

    @Test func anUnconfirmedAccessibilityDictationAfterACopyAllowsLaterCheckCases() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First.")])
        defer { server.stop() }
        MockField.reset()
        field.pasteboard = pasteboard
        let inserter = TextInserter(pasteboard: PasteboardOwner(pasteboard: pasteboard, mayRead: { true }))
        let dictation = DictationController(inserter: inserter, history: DictationHistory(file: nil),
            endpoint: server.endpoint, source: ScriptedSource(), signedIn: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("intention-dictation-copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let run = InsertionCheckClipboard.Run(file: .init(url: root.appendingPathComponent("clipboard.json")))
        var outcome: InsertionResult?
        var timing: DictationTiming?
        dictation.onOutcome = { result, recorded, _ in
            timing = recorded
            outcome = result
            run.recordInsertion(result, with: inserter)
        }
        field.writes = .ignore
        dictation.toggle()
        await speak()
        // This copy belongs to the person, during playback and before the
        // insertion. The unknown Accessibility write never borrowed it.
        pasteboard.clearContents()
        pasteboard.setString("copied during playback", forType: .string)
        dictation.toggle()
        await idle(dictation)
        #expect(outcome == .unknown(.writeUnconfirmed))
        #expect(timing?.insertionResult == .unknown(.writeUnconfirmed))
        #expect(!inserter.clipboardRestorationPending)
        #expect(!run.pasteUnconfirmed)
        #expect(await run.mayPrepareSentinel(inserters: [inserter]))
        #expect(pasteboard.string(forType: .string) == "copied during playback")
    }

    /// A paste that lands while an earlier unconfirmed paste still holds the
    /// person's copy puts it back when that wait ends, so nothing says the
    /// clipboard was replaced and the menu bar item offers nothing.
    @Test func aPasteRightAfterAnUnconfirmedOneDoesNotSayTheClipboardWasReplaced() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "first", text: "First."),
                                                 .answer(transcript: "second", text: "Second.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.writes = .refuse
        field.pastesLand = false
        pasteboard.clearContents()
        pasteboard.setString("the person's clipboard", forType: .string)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.first?.outcome == .uncertain)
        field.pastesLand = true
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.first?.outcome == .inserted)
        #expect(dictation.notice == nil)
        #expect(!dictation.pasteReplacedClipboard)
        try await Task.sleep(for: .milliseconds(2_300))
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
    }

    @Test func aPasteThatPutsTheClipboardBackSaysNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello there", text: "Hello there.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        // An earlier paste replaced the clipboard, before access was allowed.
        dictation.pasteReplacedClipboard = true
        field.writes = .refuse
        pasteboard.clearContents()
        pasteboard.setString("the person's clipboard", forType: .string)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello there.bc")
        #expect(pasteboard.string(forType: .string) == "the person's clipboard")
        #expect(dictation.notice == nil)
        #expect(!dictation.pasteReplacedClipboard)
    }

    @Test func textGoesIntoTheFieldThePersonMovedTo() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var refused: [EditReason] = []
        dictation.notInserted = { reason, _ in refused.append(reason) }
        dictation.toggle()
        await speak()
        // The person clicks into another field before stopping, and the
        // text goes where their cursor is, as with other dictation apps.
        field.focusedElement = 2
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.outcome == .inserted)
        #expect(refused.isEmpty)
    }

    @Test func aFieldWhoseAccessibilityObjectWasReplacedStillGetsTheText() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        // Same field, same place, new object, as Chrome does while a page updates.
        field.objectGeneration = 1
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        #expect(dictation.history.entries.first?.outcome == .inserted)
    }

    @Test func aFieldClickedIntoAfterTheStartGetsTheText() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        // Nothing editable has focus when recording starts, as in Finder.
        field.focused = false
        dictation.toggle()
        await speak()
        // The person clicks into a field before stopping.
        field.focused = true
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        #expect(dictation.history.entries.first?.outcome == .inserted)
        // Nothing was read from the field for the writing's context.
        #expect(server.connections.first?.start["before"] == nil)
    }

    @Test func withNoTextBoxTheTextStaysInHistoryAndThePopupSaysWhy() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        field.focused = false
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "noTextField")
        #expect(refused.map(\.0) == [.noTextField])
        #expect(refused.map(\.1) == ["Hello."])
    }

    @Test func aDictationOnSetupsLastPageIsThatPagesAndIsNotReportedAsLost() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello."),
                                                 .answer(transcript: "later", text: "Later.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        // Setup's last page is waiting and Intention is in front: no field.
        var onSetupPage = true
        dictation.isForSetup = { onSetupPage }
        var refused: [EditReason] = []
        dictation.notInserted = { reason, _ in refused.append(reason) }
        field.focused = false
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let first = try #require(dictation.history.entries.first)
        #expect(first.outcome == .notInserted)
        #expect(first.forSetup == true)
        #expect(dictation.history.setupWords?.text == "Hello.")
        #expect(dictation.history.setupMiss == nil)
        // The page shows those words, so nothing was lost, and no popup says so.
        #expect(!dictation.history.needsAttention)
        #expect(field.accessibilityWrites == 0)
        #expect(refused.isEmpty)

        // With the page still open, the person dictates into another app
        // and the field goes away. Those words are not the page's, and
        // they are reported.
        onSetupPage = false
        field.focused = true
        dictation.toggle()
        await speak()
        field.focused = false
        dictation.toggle()
        await idle(dictation)
        let second = try #require(dictation.history.entries.first)
        #expect(second.text == "Later.")
        #expect(second.outcome == .notInserted)
        #expect(second.forSetup == nil)
        #expect(dictation.history.setupWords?.text == "Hello.")
        #expect(dictation.history.needsAttention)
        #expect(refused == [.noTextField])
    }

    @Test func closingSetupWhileDictationFinishesRaisesANoticeAndKeepsItsWords() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var onSetupPage = true
        dictation.isForSetup = { onSetupPage }
        var refused: [EditReason] = []
        dictation.notInserted = { reason, _ in refused.append(reason) }
        field.focused = false
        dictation.toggle()
        await speak()
        // A field elsewhere has focus by the time the words come; setup's
        // words still go only to its page.
        field.focused = true
        dictation.toggle()
        #expect(dictation.phase == .processing)
        // Closing the window makes AppModel's isForSetup closure false.
        onSetupPage = false
        await idle(dictation)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.forSetup == true)
        #expect(entry.outcome == .notInserted)
        #expect(dictation.history.needsAttention)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(refused == [.ownApp])
        // Reopening setup still shows the words, without clearing the notice.
        onSetupPage = true
        #expect(dictation.history.setupWords?.text == "Hello.")
        #expect(dictation.history.needsAttention)
    }

    @Test func setupOriginAloneDoesNotSuppressTheHistoryNotice() {
        let history = DictationHistory(file: nil)
        history.add(.init(id: UUID(), date: Date(), text: "Hello.", outcome: .notInserted, forSetup: true))
        #expect(history.needsAttention)
        #expect(history.setupWords?.text == "Hello.")
    }

    @Test func aFailedDictationOnSetupsPageIsAMissEvenWithItsTranscript() {
        let history = DictationHistory(file: nil)
        let earlier = Date(timeIntervalSince1970: 1_800_000_000), later = Date(timeIntervalSince1970: 1_800_000_060)
        // Words that arrived on the page, then a try whose finished text
        // never came though its transcript did.
        history.add(.init(id: UUID(), date: earlier, text: "Running late.", outcome: .notInserted, reason: "noTextField", forSetup: true),
                    shownBySetup: true)
        #expect(!history.needsAttention)
        history.add(.init(id: UUID(), date: later, text: "um running late", outcome: .failed, reason: "timedOut", forSetup: true),
                    shownBySetup: true)
        #expect(history.setupWords?.text == "Running late.")
        #expect(history.setupWords?.at == earlier)
        #expect(history.setupMiss == later)
        // A failure is a failure wherever it was made.
        #expect(history.needsAttention)
        // Failures and words from other apps are not the page's.
        let elsewhere = DictationHistory(file: nil)
        elsewhere.add(.init(id: UUID(), date: earlier, text: "Hello.", outcome: .inserted))
        elsewhere.add(.init(id: UUID(), date: later, text: "", outcome: .failed, reason: "unreachable"))
        #expect(elsewhere.setupWords == nil)
        #expect(elsewhere.setupMiss == nil)
    }

    @Test func aFieldReadTooLongAfterTheTriggerGivesNoContextAndStillGetsTheText() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        // A busy app answers after the deadline; focus may have moved by then,
        // so its text is not the writing's context.
        field.focusReadDelay = 0.4
        dictation.toggle()
        try await Task.sleep(for: .milliseconds(600))
        field.focusReadDelay = 0
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        #expect(dictation.history.entries.first?.outcome == .inserted)
        #expect(server.connections.first?.start["before"] == nil)
    }

    @Test func aFieldWhoseTextCannotBeReadGetsAPasteMarkedUnconfirmed() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var refused: [EditReason] = []
        dictation.notInserted = { reason, _ in refused.append(reason) }
        field.unreadable = true
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys == ["paste"])
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.outcome == .uncertain)
        #expect(entry.reason == "unreadableField")
        // Unconfirmed is not refused: no popup.
        #expect(refused.isEmpty)
    }

    @Test func copyingFromHistoryWaitsForAPasteToFinish() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        pasteboard.clearContents()
        pasteboard.setString("the dictation being pasted", forType: .string)
        // Two pastes overlap; the first one's late timer ends only its own hold.
        owner.borrow()
        owner.borrow()
        owner.giveBack()
        #expect(!owner.copy("an older dictation"))
        #expect(pasteboard.string(forType: .string) == "the dictation being pasted")
        owner.giveBack()
        #expect(owner.copy("an older dictation"))
        #expect(pasteboard.string(forType: .string) == "an older dictation")
    }

    @Test func aPasswordFieldAtTheStartGetsNothingAndHistorySaysWhy() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var refused: [(EditReason, String)] = []
        dictation.notInserted = { refused.append(($0, $1)) }
        var timing: DictationTiming?
        dictation.onOutcome = { _, recorded, _ in timing = recorded }
        field.secure = true
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.accessibilityWrites == 0)
        #expect(field.textReadsWhileSecure == 0)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.outcome == .notInserted)
        #expect(entry.reason == "secureField")
        #expect(timing?.insertionResult == .notInserted(.secureField))
        #expect(refused.map(\.0) == [.secureField])
        // Nothing from a secure field reaches the endpoint.
        #expect(server.connections.first?.start["before"] == nil)
    }

    /// Words for a window that turned out to hold a password field, at
    /// admission or at either check before the paste, reach the popup
    /// hidden, and Copy marks them concealed.
    @Test(arguments: [false, true], [1, 2, 3])
    func wordsForAWindowWithAPasswordFieldAreHiddenInThePopup(focusOnAGroup: Bool, secureAtScan: Int) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hunter two", text: "hunter2")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let popup = InsertionPopup()
        popup.showsWindow = false
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { true })
        popup.copy = { owner.copy($0, concealed: $1) }
        dictation.notInserted = { popup.show($0, text: $1, from: .screenFoot) }
        if focusOnAGroup {
            field.role = "AXGroup"
            field.selectionUnanswered = true
        } else {
            field.focused = false
        }
        // The dictation's own read of the field at the trigger scans too.
        field.bareWindow = true
        dictation.toggle()
        await speak()
        dictation.toggle()
        field.bareScans = 0
        field.bareAnswers = Array(repeating: true, count: secureAtScan - 1) + [false]
        field.secureInWindow = true
        await idle(dictation)
        #expect(field.keys.isEmpty)
        #expect(dictation.history.entries.first?.reason == "secureField")
        #expect(popup.current?.text == InsertionPopup.hidden)
        #expect(popup.copyText())
        #expect(pasteboard.types?.contains(PasteboardOwner.concealedType) == true)
        popup.hide()
    }

    @Test func aComposerReusedForTheChannelThePersonOpenedGetsTheText() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        // Another channel in the same window: the composer object is new,
        // in the same place, and holds that channel's draft, with the caret
        // where the person left it there.
        field.objectGeneration = 1
        field.text = "xyz"
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "xHello.yz")
        #expect(dictation.history.entries.first?.outcome == .inserted)
    }

    @Test func aComposerReusedJustBeforeThePasteGetsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        field.text = ""
        field.selection = FieldRange(location: 0, length: 0)
        var refused: [EditReason] = []
        dictation.notInserted = { reason, _ in refused.append(reason) }
        field.writes = .refuse
        field.labelAfterRefusal = "Message #random"
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "")
        #expect(field.keys.isEmpty)
        #expect(dictation.history.entries.first?.reason == "focusChanged")
        #expect(refused == [.focusChanged])
    }

    @Test func aDroppedConnectionIsRetriedWithTheWholeRecording() async throws {
        let server = try await ScriptedEndpoint([.drop(afterFrames: 2), .answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        #expect(server.connections.count == 2)
        #expect(server.connections.last?.frames == source.sent)
        #expect(server.connections.last?.stopFrames == source.sent)
    }

    @Test(arguments: [true, false]) func droppedLanguagesRecordANoteWithoutPreventingInsertion(reportsDropped: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.", droppedLanguages: reportsDropped ? ["es"] : nil)])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.languages = ["en", "es"]
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let entry = try #require(dictation.history.entries.first)
        #expect(field.text == "aHello.bc")
        #expect(entry.outcome == .inserted)
        #expect(server.connections.count == 1)
        let spanish = Locale.current.localizedString(forLanguageCode: "es")!
        let english = Locale.current.localizedString(forLanguageCode: "en")!
        #expect(entry.languageNote == (reportsDropped ? "\(spanish) isn't available on this server; this was heard as \(english)." : nil))
    }

    @Test func anUnsupportedLanguageKeepsItsReasonWithoutAnAutomaticRetry() async throws {
        let server = try await ScriptedEndpoint([.refuse("language_unsupported")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(server.connections.count == 1)
        #expect(field.text == "abc")
        #expect(dictation.history.entries.first?.reason == "refused.language_unsupported")
    }

    @Test func aFailedDictationKeepsItsAudioToRetryFromHistory() async throws {
        let server = try await ScriptedEndpoint([.refuse("internal"), .refuse("internal"), .answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        // The connection opened while recording and one retry both failed.
        #expect(server.connections.count == 2)
        #expect(field.text == "abc")
        let failed = try #require(dictation.history.entries.first)
        #expect(failed.outcome == .failed)
        #expect(failed.reason == "refused.internal")
        #expect(dictation.history.retry(for: failed.id)?.chunks.count == 4)

        dictation.retry(failed.id)
        #expect(dictation.phase == .processing)
        await idle(dictation)
        let recovered = try #require(dictation.history.entries.first)
        #expect(recovered.id == failed.id)
        #expect(recovered.text == "Hello.")
        #expect(recovered.outcome == .notInserted)
        #expect(recovered.reason == "retried")
        #expect(dictation.history.retry(for: failed.id) == nil)
        // A retry is never inserted: the field has moved on.
        #expect(field.text == "abc")
    }

    @Test func aRetryCanBeCancelledAndStaysReadyToRetry() async throws {
        let server = try await ScriptedEndpoint([.refuse("internal"), .refuse("internal"), .silent])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let failed = try #require(dictation.history.entries.first)
        dictation.retry(failed.id)
        await speak()
        #expect(dictation.phase == .processing)
        dictation.cancel()
        #expect(dictation.phase == .idle)
        await speak()
        #expect(server.connections.last?.cancelled == true)
        #expect(dictation.history.entries.first?.reason == "refused.internal")
        #expect(dictation.history.retry(for: failed.id) != nil)
    }

    @Test func noRetryStartsOnceQuitHasBegun() async throws {
        let server = try await ScriptedEndpoint([.refuse("internal"), .refuse("internal"), .answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = InteractionArchive(directory: folder) { _, _, _ in throw URLError(.notConnectedToInternet) }
        archive.bind(key: "synthetic-key")
        let dictation = controller(server.endpoint)
        dictation.archive = archive
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let failed = try #require(dictation.history.entries.first)
        #expect(server.connections.count == 2)
        // The persistence barrier has passed: a retry now would record audio
        // the app exits without saving, so it is refused like a new dictation.
        #expect(await dictation.prepareToQuit())
        dictation.retry(failed.id)
        #expect(dictation.phase == .idle)
        await speak()
        #expect(server.connections.count == 2)
        #expect(dictation.history.entries.first?.reason == "refused.internal")
        #expect(dictation.history.retry(for: failed.id) != nil)
    }

    @Test func aRefusedGrantIsReplacedOnceThenTheDictationFails() async throws {
        // The endpoint refuses a grant, as one that expired between fetch and
        // use; the recording goes again with a new one.
        let grants = ScriptedGrants([.success("v1.expired"), .success("v1.fresh")])
        let server = try await RefusingServer(credentials: grants)
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.outcome == .failed)
        #expect(entry.reason == "unauthorized")
        // The first refused grant was dropped and one more was asked for.
        #expect(server.presented == ["v1.expired", "v1.fresh"])
        #expect(await grants.refusals == ["v1.expired"])
    }

    @Test func eachConnectionPresentsTheAccountsGrant() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        #expect(server.presented == [ScriptedEndpoint.grant])
    }

    @Test func withoutAGrantNothingConnectsAndTheAudioWaitsForRetry() async throws {
        let grants = ScriptedGrants([.failure(.limited)])
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")], credentials: grants)
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(server.presented.isEmpty)
        #expect(field.text == "abc")
        let entry = try #require(dictation.history.entries.first)
        #expect(entry.outcome == .failed)
        #expect(entry.reason == "limited")
        #expect(dictation.history.retry(for: entry.id) != nil)
    }

    @Test func aGrantThatCouldNotBeFetchedIsAskedForOnceMore() async throws {
        let grants = ScriptedGrants([.failure(.unreachable), .success(ScriptedEndpoint.grant)])
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")], credentials: grants)
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        #expect(server.connections.count == 1)
    }

    @Test func aSignedOutMacDoesNotListenUntilItSignsIn() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source, signedIn: false)
        var problems: [DictationController.Problem?] = []
        dictation.problemChanged = { problems.append($0) }
        #expect(!dictation.available)
        #expect(dictation.problem == .signedOut)
        dictation.toggle()
        #expect(dictation.phase == .idle)
        #expect(!source.running)
        // Setup saves a key: dictation can begin at once, without a relaunch.
        dictation.accountChanged(signedIn: true)
        #expect(dictation.available)
        #expect(problems == [nil])
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        // Signing out turns it off again.
        dictation.accountChanged(signedIn: false)
        #expect(!dictation.available)
        #expect(problems == [nil, .signedOut])
        await speak()
        #expect(await server.credentials.resets == 2)
    }

    @Test func signingOutWhileTheGrantIsFetchedConnectsNothing() async throws {
        for signsInAgain in [false, true] {
            let grants = ScriptedGrants(delay: .milliseconds(400))
            let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")], credentials: grants)
            defer { server.stop() }
            let source = ScriptedSource()
            let dictation = controller(server.endpoint, source: source)
            dictation.toggle()
            await speak()
            // Signed out, or into another account, while the grant is on its way.
            dictation.accountChanged(signedIn: false)
            if signsInAgain { dictation.accountChanged(signedIn: true) }
            #expect(dictation.phase == .idle)
            #expect(!source.running)
            try await Task.sleep(for: .milliseconds(600))
            #expect(await grants.given.count == 1)  // the late grant arrived
            #expect(server.presented.isEmpty)  // and was never used
            #expect(field.text == "abc")
            #expect(dictation.history.entries.isEmpty)
            #expect(dictation.available == signsInAgain)
        }
    }

    @Test func anAccountChangeForgetsRetryAudioAndFencesARunningRetry() async throws {
        let server = try await ScriptedEndpoint([.refuse("internal"), .refuse("internal"), .silent])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let failed = try #require(dictation.history.entries.first)
        dictation.retry(failed.id)
        await speak()
        #expect(dictation.phase == .processing)
        // Another account signs in: the retry stops and its audio is gone.
        dictation.accountChanged(signedIn: true)
        #expect(dictation.phase == .idle)
        await speak()
        #expect(server.connections.last?.cancelled == true)
        #expect(dictation.history.retry(for: failed.id) == nil)
        #expect(dictation.history.entries.first?.reason == "refused.internal")
        let connections = server.connections.count
        dictation.retry(failed.id)
        #expect(dictation.phase == .idle)
        await speak()
        #expect(server.connections.count == connections)
    }

    @Test func silenceInsertsNothingAndSaysNoWordsWereHeard() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        var said: [DictationController.Silence] = []
        dictation.silent = { said.append($0.silence) }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "abc")
        #expect(dictation.history.entries.isEmpty)
        #expect(said == [.words])
        // Not setup's: this one was for the field.
        #expect(dictation.setupSilence == nil)
    }

    /// Intention 0.1.0 recorded a Bluetooth headset as 93% exact zeros with
    /// fragments of sound between, and the endpoint found no words: almost
    /// nothing came through.
    @Test func noWordsFromAudioThatIsNearlyAllZeroSaysAlmostNothingCameThrough() async throws {
        for (zeros, expected) in [(93, DictationController.Silence.nearlyNothing), (90, .nearlyNothing), (89, .words), (69, .words)] {
            let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
            defer { server.stop() }
            let dictation = controller(server.endpoint, source: ScriptedSource(level: 9_000, zeros: zeros))
            var said: [DictationController.Silence] = []
            dictation.silent = { said.append($0.silence) }
            dictation.toggle()
            await speak()
            dictation.toggle()
            await idle(dictation)
            // The endpoint was asked: there was sound to send.
            #expect(server.connections.first?.stopFrames != nil)
            #expect(said == [expected])
            #expect(field.text == "abc")
        }
    }

    /// The first alpha's microphone sent digital silence for whole
    /// dictations with a Bluetooth headset, and the person saw nothing
    /// happen. Silence from the microphone now ends the dictation at the
    /// stop, without waiting on the endpoint, and the indicator says so.
    @Test func aMicrophoneThatSentOnlySilenceIsSaidSoAtTheStop() async throws {
        // Below 33 of 32768, about -60 dBFS, either way up.
        for level: Int16 in [0, -1, 32, -32] {
            let server = try await ScriptedEndpoint([.silent])
            defer { server.stop() }
            let dictation = controller(server.endpoint, source: ScriptedSource(level: level))
            var said: [DictationController.Silence] = []
            var phases: [DictationController.Phase] = []
            dictation.silent = {
                #expect(dictation.phase == .idle)
                said.append($0.silence)
            }
            dictation.phaseChanged = { phases.append($0) }
            dictation.toggle()
            await speak()
            dictation.toggle()
            // The endpoint never answers; the stop alone ends it.
            await idle(dictation)
            #expect(said == [.microphone])
            #expect(phases == [.recording, .processing, .idle])
            #expect(field.text == "abc")
            #expect(dictation.history.entries.isEmpty)
            #expect(dictation.setupSilence == nil)
            #expect(server.connections.allSatisfy { $0.stopFrames == nil })
        }
    }

    /// With the lid closed and only the built-in microphone listed, the
    /// microphone opens nothing, and the dictation ends at the stop as one
    /// that heard nothing, without opening the cut-off microphone and
    /// moving off it three times first.
    @Test func withOnlyTheCutOffMicrophoneTheDictationSaysItHeardNothing() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let hardware = StandInHardware(MadeUpInputs.inputs([MadeUpInputs.builtIn], default: MadeUpInputs.builtIn, lidClosed: true))
        hardware.checksOnceOpen = true
        let dictation = controller(server.endpoint, source: Microphone(preference: { .builtIn }, hardware: hardware))
        var said: [DictationController.Silence] = []
        dictation.silent = { said.append($0.silence) }
        dictation.toggle()
        await speak()
        #expect(dictation.phase == .recording)
        dictation.toggle()
        await idle(dictation)
        #expect(said == [.microphone])
        #expect(hardware.opened.map(\.name) == [])
        #expect(field.text == "abc")
    }

    @Test func theQuietestSoundIsHeard() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: ScriptedSource(level: -33))
        var said = false
        dictation.silent = { _ in said = true }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(!said)
        #expect(field.text == "aHello.bc")
    }

    @Test func silenceFromTheMicrophoneOnSetupsLastPageIsThatPages() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: ScriptedSource(level: 0))
        dictation.isForSetup = { true }
        field.focused = false
        var said = false
        dictation.silent = { _ in said = true }
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.setupSilence != nil)
        #expect(!said)
    }

    @Test func silenceOnSetupsLastPageIsThatPages() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: ""), .answer(transcript: "", text: "")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.isForSetup = { true }
        field.focused = false
        #expect(dictation.setupSilence == nil)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let silent = try #require(dictation.setupSilence)
        #expect(dictation.history.entries.isEmpty)
        #expect(!dictation.history.needsAttention)
        // Silence in another app, with setup still open behind it, leaves
        // the page's own standing.
        dictation.isForSetup = { false }
        field.focused = true
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.setupSilence == silent)
    }

    @Test func aHeldKeyDictates() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.holdBegan()
        try await Task.sleep(for: DictationController.shortestHold + .milliseconds(50))
        dictation.holdEnded()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test func aTapOfTheKeyIsNotADictation() async throws {
        // Were a tap sent at all, the silent answer would be remembered.
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: "")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        dictation.isForSetup = { true }
        dictation.holdBegan()
        #expect(dictation.phase == .recording)
        dictation.holdEnded()
        #expect(dictation.phase == .idle)
        #expect(!source.running)
        await speak()
        #expect(field.text == "abc")
        #expect(dictation.history.entries.isEmpty)
        // A tap says nothing, on setup's page or anywhere.
        #expect(dictation.setupSilence == nil)
        #expect(server.connections.allSatisfy { $0.stopFrames == nil })
    }

    @Test func aShortcutPressedWithTheKeyDropsTheRecording() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.holdBegan()
        await speak()
        dictation.keyPressedDuringHold()
        #expect(dictation.phase == .recording)
        dictation.holdEnded()
        await speak()
        #expect(field.text == "abc")
        #expect(!server.connections.isEmpty)
        #expect(server.connections.allSatisfy { $0.stopFrames == nil })
        #expect(server.connections.allSatisfy { $0.cancelled })
    }

    @Test func holdingTheKeyAndPressingSpaceGoesHandsFreeUntilTheKeyIsPressedAgain() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.holdBegan()
        dictation.holdBecameHandsFree()
        #expect(dictation.handsFree)
        // Let go at once: a hands-free dictation is no tap, and goes on.
        dictation.holdEnded()
        #expect(dictation.phase == .recording)
        await speak()
        #expect(dictation.phase == .recording)
        // The key pressed again ends it when it comes up, and puts the text in.
        dictation.holdBegan()
        #expect(dictation.phase == .recording)
        dictation.holdEnded()
        #expect(dictation.phase == .processing)
        #expect(!dictation.handsFree)
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        #expect(dictation.history.entries.count == 1)
    }

    @Test func aHandsFreeDictationEndsWithAClickOnTheFootsSunWithTheDotChosen() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation, saysWords: false)
        dictation.holdBegan()
        #expect(foot.target.buttons.map(\.name) == ["Stop dictating"])
        dictation.holdBecameHandsFree()
        #expect(foot.presentation == .listening)
        dictation.holdEnded()
        await speak()
        click(foot)
        #expect(dictation.phase == .processing)
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test(arguments: ["foot", "escape"])
    func voiceOversCancelOrEscapeDropsAHandsFreeDictation(_ way: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let foot = foot(for: dictation, saysWords: false)
        dictation.holdBegan()
        dictation.holdBecameHandsFree()
        dictation.holdEnded()
        await speak()
        #expect(dictation.phase == .recording)
        if way == "foot" {
            try cancel(foot)
        } else {
            dictation.escapePressed()
        }
        #expect(dictation.phase == .idle)
        #expect(!dictation.handsFree)
        await speak()
        #expect(field.text == "abc")
        #expect(dictation.history.entries.isEmpty)
        #expect(server.connections.allSatisfy { $0.stopFrames == nil })
    }

    @Test(arguments: ["held", "clicked"])
    func escapeDropsAnyRecording(_ way: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        if way == "held" { dictation.holdBegan() } else { dictation.toggle() }
        await speak()
        dictation.escapePressed()
        #expect(dictation.phase == .idle)
        if way == "held" { dictation.holdEnded() }
        await speak()
        #expect(field.text == "abc")
        // Escape once nothing records does nothing.
        dictation.escapePressed()
        #expect(dictation.phase == .idle)
    }

    @Test(arguments: ["handsFree", "clicked"])
    func lockingTheScreenEndsADictationNoKeyHolds(_ way: String) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        if way == "clicked" {
            dictation.toggle()
        } else {
            dictation.holdBegan()
            dictation.holdBecameHandsFree()
            dictation.holdEnded()
        }
        await speak()
        #expect(dictation.phase == .recording)
        dictation.screenLocked()
        #expect(dictation.phase == .processing)
        await idle(dictation)
        #expect(dictation.history.entries.count == 1)
    }

    @Test func holdingTheKeyAndPressingSpaceFinishesAClickedDictation() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.holdBegan()
        dictation.holdBecameHandsFree()
        dictation.holdEnded()
        #expect(dictation.phase != .recording)
        #expect(!dictation.handsFree)
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test func aShortcutsKeyFromTheTapIsHandledBeforeTheKeysReleaseHoweverBusyTheMainThread() async throws {
        // Right Command chosen, a clicked dictation running: Command-C comes
        // from the tap's own thread as one stream, Right Command down, C down
        // and up, Right Command up, all queued while the main thread is busy.
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let hold = HoldKey(handsFreeEnabled: true, key: .rightCommand, holdDelay: 0)
        hold.keyboardFlags = { [0, 0] }
        hold.onPress = { dictation.holdBegan(alone: hold.pressWasAlone) }
        hold.onRelease = { dictation.holdEnded() }
        hold.onOtherKey = { dictation.keyPressedDuringHold() }
        dictation.toggle()
        await speak()
        let command = NSEvent.ModifierFlags.command.rawValue | 0x10
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                hold.tapDelivered(HoldKey.Delivery(keyCode: 54, flags: command, fromKeyboard: true))
                hold.tapInput(HoldKey.Monitored(kind: .keyDown, keyCode: 8, flags: command))
                hold.tapInput(HoldKey.Monitored(kind: .keyUp, keyCode: 8, flags: command))
                hold.tapDelivered(HoldKey.Delivery(keyCode: 54, flags: 0, fromKeyboard: true))
                done.resume()
            }
        }
        await speak()
        #expect(dictation.phase == .recording)
        dictation.toggle()
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test func aClickOnTheDotWhileTheKeyIsHeldWaitsForTheKeysRelease() async throws {
        // The click carries the key's flag; it is no shortcut's key, so the
        // held dictation is not dropped, and the dot's click ends it.
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let hold = HoldKey(handsFreeEnabled: true, key: .function, holdDelay: 0)
        hold.keyboardFlags = { [0, 0] }
        hold.onPress = { dictation.holdBegan(alone: hold.pressWasAlone) }
        hold.onRelease = { dictation.holdEnded() }
        hold.onOtherKey = { dictation.keyPressedDuringHold() }
        hold.onClick = { dictation.clickedDuringHold() }
        hold.modifiersChanged(keyCode: 63, flags: [.function])
        try await Task.sleep(for: .milliseconds(350))
        hold.mouseDown(flags: [.function])
        #expect(dictation.phase == .recording)
        dictation.toggle()
        #expect(dictation.phase == .recording)
        hold.modifiersChanged(keyCode: 63, flags: [])
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test func aPressWithAnotherModifierHeldStartsNothing() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        dictation.holdBegan(alone: false)
        #expect(dictation.phase == .idle)
        #expect(!source.running)
    }

    @Test func aPressOfTheKeyEndsADictationStartedByAClick() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.holdBegan()
        #expect(dictation.phase == .recording)
        dictation.holdEnded()
        #expect(dictation.phase == .processing)
        await idle(dictation)
        #expect(field.text == "aHello.bc")
        #expect(server.connections.count == 1)
    }

    @Test(arguments: [false, true])
    func theKeyUsedInAShortcutLeavesADictationWithNoKeyHoldingItRunning(handsFree: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let hold = HoldKey(handsFreeEnabled: true, key: .rightCommand, holdDelay: 0, watchInterval: 0.02)
        hold.keyboardFlags = { [0, 0] }
        hold.onPress = { dictation.holdBegan(alone: hold.pressWasAlone) }
        hold.onRelease = { dictation.holdEnded() }
        hold.onOtherKey = { dictation.keyPressedDuringHold() }
        hold.onHandsFree = { dictation.holdBecameHandsFree() }
        hold.onClick = { dictation.clickedDuringHold() }
        let command = NSEvent.ModifierFlags.command.rawValue | 0x10
        if handsFree {
            hold.modifiersChanged(keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: command))
            hold.claimed(.handsFree)
            hold.modifiersChanged(keyCode: 54, flags: [])
        } else {
            dictation.toggle()
        }
        await speak()
        // Shift held, then Right Command, then Left: Shift-Command-Left,
        // selecting to the line's start.
        hold.modifiersChanged(keyCode: 56, flags: [.shift])
        hold.modifiersChanged(keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: command | NSEvent.ModifierFlags.shift.rawValue))
        hold.keyDown(keyCode: 123, flags: NSEvent.ModifierFlags(rawValue: command | NSEvent.ModifierFlags.shift.rawValue))
        hold.keyUp(keyCode: 123)
        hold.modifiersChanged(keyCode: 54, flags: [.shift])
        hold.modifiersChanged(keyCode: 56, flags: [])
        #expect(dictation.phase == .recording)
        // Shift and Right Command with no other key, a press that was not
        // alone, ends nothing either.
        hold.modifiersChanged(keyCode: 56, flags: [.shift])
        hold.modifiersChanged(keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: command | NSEvent.ModifierFlags.shift.rawValue))
        hold.modifiersChanged(keyCode: 54, flags: [.shift])
        hold.modifiersChanged(keyCode: 56, flags: [])
        #expect(dictation.phase == .recording)
        // Command-click on a link, and Command-right-click, through the
        // handler the global monitor is given.
        let monitor = HoldKey.globalMonitor(for: hold)
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            hold.modifiersChanged(keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: command))
            monitor(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: command), timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            hold.modifiersChanged(keyCode: 54, flags: [])
            #expect(dictation.phase == .recording)
        }
        // Pressed and let go on its own, the key ends it.
        hold.modifiersChanged(keyCode: 54, flags: NSEvent.ModifierFlags(rawValue: command))
        hold.modifiersChanged(keyCode: 54, flags: [])
        #expect(dictation.phase == .processing)
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    @Test func releasingTheKeyEndsTheDictationWhenOnlyTheKeyboardStateShowsIt() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let hold = HoldKey(handsFreeEnabled: true, key: .rightOption, holdDelay: 0, watchInterval: 0.02, unseenReleaseWait: 0.1)
        final class Keyboard { var flags: UInt = 0 }
        let keyboard = Keyboard()
        hold.keyboardFlags = { [keyboard.flags, 0] }
        hold.onPress = { dictation.holdBegan() }
        hold.onRelease = { dictation.holdEnded() }
        let down = NSEvent.ModifierFlags.option.rawValue | 0x40
        keyboard.flags = down
        hold.modifiersChanged(keyCode: 61, flags: NSEvent.ModifierFlags(rawValue: down))
        #expect(dictation.phase == .recording)
        try await Task.sleep(for: DictationController.shortestHold + .milliseconds(50))
        // The key comes up and its release never reaches the tap.
        keyboard.flags = 0
        await idle(dictation)
        #expect(field.text == "aHello.bc")
    }

    /// People pause while they think. Ten and a half seconds of silence, as
    /// the microphone delivers it, chunk by chunk in real time, in the
    /// middle of a held and of a hands-free dictation, neither ends it nor
    /// drops a chunk of what came before or after.
    @Test(arguments: [false, true])
    func aLongPauseNeitherEndsTheDictationNorDropsItsWords(handsFree: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "before after", text: "Before. After.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        dictation.holdBegan()
        if handsFree {
            dictation.holdBecameHandsFree()
            dictation.holdEnded()
        }
        await speak()
        let silence = Data(count: SpeechAudioConverter.chunkBytes)
        for _ in 0..<105 {
            source.say(silence)
            try await Task.sleep(for: .milliseconds(100))
            #expect(dictation.phase == .recording)
        }
        let speech = Data(repeating: 0x40, count: SpeechAudioConverter.chunkBytes)
        source.say(speech)
        if handsFree { dictation.holdBegan() }
        dictation.holdEnded()
        await idle(dictation)
        #expect(field.text == "aBefore. After.bc")
        let connection = try #require(server.connections.first)
        #expect(connection.frames == source.sent + 106)
        #expect(connection.stopFrames == source.sent + 106)
    }

    @Test func cancellingWhileProcessingInsertsNothing() async throws {
        let server = try await ScriptedEndpoint([.silent])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        #expect(dictation.phase == .processing)
        dictation.cancel()
        #expect(dictation.phase == .idle)
        await speak()
        #expect(field.text == "abc")
        #expect(dictation.history.entries.isEmpty)
    }

    @Test func withoutAnEndpointDictationIsOff() {
        let source = ScriptedSource()
        let dictation = controller(nil, source: source)
        #expect(dictation.problem == .notConfigured)
        dictation.toggle()
        #expect(dictation.phase == .idle)
        #expect(!source.running)
    }
}

@Suite struct DictationRuleTests {
    @Test func audioIsConvertedTo16kHzMonoChunks() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let converter = try #require(SpeechAudioConverter(from: input))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        for channel in 0..<2 {
            for frame in 0..<24_000 {
                buffer.floatChannelData![channel][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 48_000)
            }
        }
        let chunks = converter.convert(buffer)
        #expect(chunks.allSatisfy { $0.count == SpeechAudioConverter.chunkBytes })
        let total = chunks.reduce(0) { $0 + $1.count } + (converter.finish()?.count ?? 0)
        // Half a second at 16 kHz, 16-bit, including what the resampler held
        // back until the end.
        #expect((15_900...16_100).contains(total))
        let samples = chunks.flatMap { chunk in
            chunk.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        let peak = Double(samples.map { abs(Int($0)) }.max() ?? 0) / Double(Int16.max)
        #expect(abs(peak - 0.5) < 0.05)
    }

    @Test func theStartMessageCarriesTheRegisterAndTextBeforeTheCaret() throws {
        let message = DictationStart(register: "work", before: "Hi team, ").message()
        let start = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        #expect(start["type"] as? String == "start")
        #expect(start["app"] as? String == "work")
        #expect(start["before"] as? String == "Hi team, ")
        #expect(start["names"] as? [String] == [])
        let unread = try #require(try JSONSerialization.jsonObject(with: Data(DictationStart(register: "other").message().utf8)) as? [String: Any])
        #expect(unread["before"] == nil)
        // No languages chosen means English, which the endpoint assumes when the field is absent.
        #expect(unread["languages"] == nil)
        let spanish = DictationStart(register: "other", languages: ["en", "es"]).message()
        let chosen = try #require(try JSONSerialization.jsonObject(with: Data(spanish.utf8)) as? [String: Any])
        #expect(chosen["languages"] as? [String] == ["en", "es"])
    }

    @Test func theMicrophonesRingKeepsOrderAcrossItsEndAndDropsWhatDoesNotFit() throws {
        let ring = SampleRing(capacity: 8)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        func read() -> [Float] {
            guard ring.read(into: buffer) else { return [] }
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        #expect(read() == [])
        ring.write([1, 2, 3, 4, 5, 6], 6)
        #expect(read() == [1, 2, 3, 4])
        // Five more fit beside the two left, wrapping past the end.
        ring.write([7, 8, 9, 10, 11], 5)
        #expect(read() == [5, 6, 7, 8])
        #expect(read() == [9, 10, 11])
        #expect(ring.dropped == 0)
        ring.write([1, 2, 3, 4, 5, 6, 7, 8], 8)
        // A full ring drops a write whole rather than part of it.
        ring.write([9], 1)
        #expect(ring.dropped == 1)
        let drained: [Float] = read() + read() + read()
        #expect(drained == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func everyChannelIsMixedIntoOne() {
        let channels = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(channels.unsafeMutablePointer) }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 4), right = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let mixed = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { [left, right, mixed].forEach { $0.deallocate() } }
        left.update(from: [1, 0.5, 0, -1], count: 4)
        // A microphone on the second channel alone still comes through.
        right.update(from: [0, 0.5, 0.8, -1], count: 4)
        channels[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: left)
        channels[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: right)
        ChannelMix.average(channels, frames: 4, into: mixed)
        #expect(Array(UnsafeBufferPointer(start: mixed, count: 4)) == [0.5, 0.5, 0.4, -1])
    }

    /// The microphone's path after the device: a second of 48 kHz audio
    /// written in 10 ms blocks as the I/O thread writes it, drained every
    /// 20 ms as the queue drains it, comes out as a second of 16 kHz chunks
    /// at its level, the last partial chunk included.
    @Test func theMicrophonesPathDeliversEverySecondAtItsLevel() throws {
        let collected = Collected()
        let drain = try #require(Drain(sampleRate: 48_000) { collected.add($0) })
        let block = UnsafeMutablePointer<Float>.allocate(capacity: 480)
        defer { block.deallocate() }
        for index in 0..<100 {
            for frame in 0..<480 { block[frame] = 0.5 * sin(2 * .pi * 440 * Float(index * 480 + frame) / 48_000) }
            drain.ring.write(block, 480)
            if index % 2 == 1 { drain.run() }
        }
        drain.stop()
        let chunks = collected.chunks
        #expect(chunks.dropLast().allSatisfy { $0.count == SpeechAudioConverter.chunkBytes })
        let bytes = chunks.reduce(0) { $0 + $1.count }
        #expect((31_800...32_200).contains(bytes))
        #expect(drain.ring.dropped == 0)
        let tape = DictationTape()
        chunks.forEach(tape.append)
        #expect(abs(Double(tape.peak) / 32_768 - 0.5) < 0.05)
        #expect(tape.zeroShare < 0.01)
    }

    /// The timer and the stop run the drain on its own queue, started and
    /// stopped from the main actor as the microphone does. A handler that
    /// inherited the main actor's isolation stops the process here, under
    /// Swift 6's runtime check, the first time the timer fires: Intention's
    /// check binary did exactly that on a real headset.
    @MainActor @Test func theDrainRunsOffTheMainActorOnItsOwnQueue() async throws {
        let collected = Collected()
        let drain = try #require(Drain(sampleRate: 16_000) { collected.add($0) })
        drain.start()
        let block = UnsafeMutablePointer<Float>.allocate(capacity: 1_600)
        defer { block.deallocate() }
        for frame in 0..<1_600 { block[frame] = 0.25 * sin(2 * .pi * 440 * Float(frame) / 16_000) }
        for _ in 0..<5 { drain.ring.write(block, 1_600) }
        // Half a second waits on the ring; the timer, not this test, takes it.
        let deadline = ContinuousClock.now + .seconds(2)
        while collected.chunks.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(collected.chunks.count >= 4)
        drain.ring.write(block, 800)
        drain.stop()
        // The stop drained the rest and the converter: 0.55 s at 16 kHz.
        #expect(collected.chunks.reduce(0) { $0 + $1.count } == 17_600)
    }

    @Test func theTapeKnowsItsLoudestSample() {
        let tape = DictationTape()
        #expect(tape.peak == 0)
        tape.append(Data([0, 0, 0, 0]))
        #expect(tape.peak == 0)
        // 0xFFF6 is -10, little-endian; an odd byte at the end is no sample.
        tape.append(Data([0xF6, 0xFF, 0x05, 0x00, 0x7F]))
        #expect(tape.peak == 10)
        // The most negative sample is the loudest there is.
        tape.append(Data([0x00, 0x80]))
        #expect(tape.peak == 32_768)
        tape.append(Data([0x01, 0x00]))
        #expect(tape.peak == 32_768)
        // Two of the six whole samples were exactly zero.
        #expect(abs(tape.zeroShare - 2.0 / 6) < 1e-9)
        #expect(DictationTape().zeroShare == 1)
    }

    @Test func onlyNetworkAndServerFailuresAreRetried() {
        #expect(DictationController.retryable(.unreachable))
        #expect(DictationController.retryable(.refused("recognizer_failed")))
        #expect(DictationController.retryable(.refused("audio_incomplete")))
        #expect(!DictationController.retryable(.refused("too_long")))
        #expect(!DictationController.retryable(.refused("language_unsupported")))
        // A refused grant is replaced once; an account that is signed out or
        // asked to wait is not tried again at once.
        #expect(DictationController.retryable(.unauthorized))
        #expect(!DictationController.retryable(.signedOut))
        #expect(!DictationController.retryable(.limited))
        #expect(!DictationController.retryable(.timedOut))
    }

    @Test func theRegisterFollowsTheApp() {
        #expect(DictationController.register(of: "com.apple.mail") == "email")
        #expect(DictationController.register(of: "com.tinyspeck.slackmacgap") == "work")
        #expect(DictationController.register(of: "com.apple.MobileSMS") == "personal")
        #expect(DictationController.register(of: "com.google.Chrome") == "other")
        #expect(DictationController.register(of: nil) == "other")
    }

    @Test func aStreamErrorNameNeverCarriesUnknownText() {
        #expect(DictationStreamError.refused("internal").name == "refused.internal")
        #expect(DictationStreamError.refused("language_unsupported").name == "refused.language_unsupported")
        #expect(DictationStreamError.refused("something the server made up").name == "refused.other")
    }

    @MainActor @Test func historySurvivesARelaunchAndKeepsTheNewest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("Dictation/history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = DictationHistory(file: file)
        for index in 0..<(DictationHistory.limit + 5) {
            history.add(.init(id: UUID(), date: Date(), text: "entry \(index)", outcome: .inserted))
        }
        history.add(.init(id: UUID(), date: Date(), text: "", outcome: .failed, reason: "unreachable"),
                    retry: .init(chunks: [Data([1, 2])], start: DictationStart(register: "work")))
        let reopened = DictationHistory(file: file)
        #expect(reopened.entries.count == DictationHistory.limit)
        #expect(reopened.entries.first?.reason == "unreachable")
        #expect(reopened.entries[1].text == "entry \(DictationHistory.limit + 4)")
        // Audio is never written: after a relaunch there is nothing to retry.
        #expect(reopened.retry(for: reopened.entries[0].id) == nil)
        // The notice for a dictation that did not go in survives the relaunch.
        #expect(reopened.needsAttention)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        reopened.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(DictationHistory(file: file).entries.isEmpty)
    }
}
