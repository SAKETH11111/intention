import AppKit
import Foundation
import os
@testable import Dictation
import Testing

@MainActor
struct HistoryPresentationTests {
    @Test func clearingDropsAudioEvenWhenTheFileCannotBeRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let history = DictationHistory(file: file)
        let entry = DictationHistory.Entry(id: UUID(), date: Date(), text: "", outcome: .failed)
        history.add(entry, retry: .init(chunks: [Data([1, 2])], start: .init(register: "work")))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(!history.clear())
        #expect(history.retry(for: entry.id) == nil)
        #expect(history.entries.map { value in var copy = value; copy.tallyDay = nil; return copy } == [entry])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aRepeatedIdentityReplacesItsRowAndPreservesItsDate() {
        let history = DictationHistory(file: nil)
        let original = DictationHistory.Entry(id: UUID(), date: Date(timeIntervalSince1970: 100), text: "", outcome: .failed)
        history.add(original, retry: .init(chunks: [Data([1, 2])], start: .init(register: "work")))
        history.add(.init(id: original.id, date: Date(timeIntervalSince1970: 200), text: "Recovered words", outcome: .notInserted, reason: "retried"))
        #expect(history.entries.count == 1)
        #expect(history.entries.first?.date == original.date)
        #expect(history.entries.first?.text == "Recovered words")
        #expect(history.retry(for: original.id) == nil)
    }
}

extension HistoryPresentationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        value.locale = Locale(identifier: "en_US_POSIX")
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-10-08T19:00:00Z") }

    private func rows(_ history: DictationHistory, search: String = "") -> [HistoryRow] {
        history.sections(matching: search, now: now, calendar: calendar).flatMap(\.rows)
    }

    @Test func eachStateKeepsTextAndOnlyMissedInsertionHasAReason() throws {
        let history = DictationHistory(file: nil)
        let entries: [DictationHistory.Entry] = [
            .init(id: UUID(), date: now, text: "Landed", outcome: .inserted),
            .init(id: UUID(), date: now, text: "Kept", outcome: .notInserted, reason: "fieldChanged"),
            .init(id: UUID(), date: now, text: "Maybe", outcome: .uncertain),
            .init(id: UUID(), date: now, text: "", outcome: .failed, reason: "noWords", device: "Studio Headset"),
            .init(id: UUID(), date: now, text: "Heard transcript", outcome: .failed, reason: "timedOut")
        ]
        entries.forEach { history.add($0) }
        let actual = Dictionary(uniqueKeysWithValues: rows(history).map { ($0.id, $0) })
        #expect(actual[entries[0].id]?.state == .inserted)
        #expect(actual[entries[0].id]?.reason == nil)
        #expect(actual[entries[1].id]?.state == .didNotGoIn)
        #expect(actual[entries[1].id]?.reason == "The text box changed while Intention was typing.")
        #expect(actual[entries[2].id]?.state == .uncertain)
        #expect(actual[entries[2].id]?.reason == "May have gone in. Check before pasting again.")
        #expect(actual[entries[3].id]?.state == .heardNothing(device: "Studio Headset"))
        #expect(actual[entries[3].id]?.reason == nil)
        #expect(actual[entries[4].id]?.state == .didNotGoIn)
        #expect(actual[entries[4].id]?.text == "Heard transcript")
        #expect(actual[entries[4].id]?.reason == "The dictation server did not answer in time.")
    }

    @Test func kindsAndUnusedProposals() {
        let history = DictationHistory(file: nil)
        history.add(.init(id: UUID(), date: now, text: "Unused", outcome: .notInserted, proposal: .unused))
        #expect(history.isEmpty)
        history.add(.init(id: UUID(), date: now, text: "Words", outcome: .inserted))
        history.add(.init(id: UUID(), date: now, text: "Email", outcome: .notInserted, spoken: "Say hello"))
        history.add(.init(id: UUID(), date: now, text: "Accepted", outcome: .inserted, proposal: .accepted))
        history.add(.init(id: UUID(), date: now, text: "Changed", outcome: .notInserted, spoken: "Make it shorter", proposal: .changed))
        let actual = Dictionary(uniqueKeysWithValues: rows(history).map { ($0.text, $0.kind) })
        #expect(!history.isEmpty)
        #expect(actual.count == 4)
        #expect(actual["Words"] == .dictation)
        #expect(actual["Email"] == .email(spoken: "Say hello"))
        #expect(actual["Accepted"] == .proposal)
        #expect(actual["Changed"] == .proposal)
        #expect(rows(history, search: "SHORTER").map(\.text) == ["Changed"])
    }

    @Test(arguments: ["secureField", "targetUnresponsive", "earlierUnsettled", "earlierUnsettledNearby"])
    func concealedWordsAndCuesNeverReachRowsOrSearch(_ reason: String) throws {
        let history = DictationHistory(file: nil)
        let entry = DictationHistory.Entry(id: UUID(), date: now, text: "Secret text", outcome: .notInserted,
                                           reason: reason, spoken: "Secret cue")
        history.add(entry)
        let row = try #require(rows(history).first)
        #expect(row.isConcealed)
        #expect(row.text.isEmpty)
        #expect(row.kind == .email(spoken: nil))
        #expect(rows(history, search: "secret").isEmpty)
        #expect(history.entries.first?.text == "Secret text")
    }

    @Test(arguments: [
        ("retried", "The recovered text is ready to copy."),
        ("focusChanged", "The text box changed while Intention was typing."),
        ("fieldChanged", "The text box changed while Intention was typing."),
        ("composeChanged", "The text box changed while Intention was typing."),
        ("appEnded", "The app quit."),
        ("noTextField", "Click in the message body, then try again. Your text is here to copy."),
        ("secureField", "Intention does not insert into password fields."),
        ("ownApp", "Intention does not insert into its own window."),
        ("targetUnresponsive", "The app did not respond."),
        ("busy", "The app did not respond."),
        ("permissionMissing", "Accessibility is not allowed."),
        ("clipboardBusy", "The clipboard changed while Intention was pasting."),
        ("pasteUnavailable", "Intention could not use the clipboard."),
        ("earlierUnsettled", "Your last dictation into this field didn't show, so Intention won't type there. Copy this and paste it yourself, or dictate into another field."),
        ("earlierUnsettledNearby", "Your last dictation in this window could still appear. Dictate again in a few seconds."),
        ("cancelled", "It was cancelled before it went in."),
        ("unknown", "The text could not be inserted.")
    ])
    func insertionReasonsArePlainSentences(_ reason: String, expected: String) throws {
        let history = DictationHistory(file: nil)
        history.add(.init(id: UUID(), date: now, text: "Kept", outcome: .notInserted, reason: reason))
        #expect(try #require(rows(history).first).reason == expected)
    }

    @Test(arguments: [
        ("unauthorized", "The dictation server refused this copy of Intention."),
        ("timedOut", "The dictation server did not answer in time."),
        ("unreachable", "Could not reach the dictation server."),
        ("refused.language_unsupported", "The dictation server supports none of your selected languages."),
        ("unknown", "The dictation server could not finish it.")
    ])
    func speechFailureReasonsKeepTheExistingMeaning(_ reason: String, expected: String) throws {
        let history = DictationHistory(file: nil)
        history.add(.init(id: UUID(), date: now, text: "Transcript", outcome: .failed, reason: reason))
        #expect(try #require(rows(history).first).reason == expected)
    }

    @Test func sectionsUseThePersonsDayAndYearWithNewestFirst() {
        let history = DictationHistory(file: nil)
        for (time, text) in [
            ("2026-10-08T18:00:00Z", "Today later"),
            ("2026-10-08T07:05:00Z", "Today earlier"),
            ("2026-10-08T06:59:00Z", "Yesterday"),
            ("2026-10-06T18:00:00Z", "Tuesday"),
            ("2025-10-06T18:00:00Z", "Last year")
        ] { history.add(.init(id: UUID(), date: date(time), text: text, outcome: .inserted)) }
        let sections = history.sections(matching: "", now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Tuesday, October 6", "Monday, October 6, 2025"])
        #expect(sections.first?.rows.map(\.text) == ["Today later", "Today earlier"])
        #expect(Set(sections.map(\.id)).count == 4)
    }

    @Test func searchFindsFinishedWordsAndSpokenWordsWithoutCaseOrAccents() {
        let history = DictationHistory(file: nil)
        history.add(.init(id: UUID(), date: now, text: "Meet at the café", outcome: .inserted))
        history.add(.init(id: UUID(), date: now, text: "Dear Ana", outcome: .inserted, spoken: "Réponds demain"))
        #expect(rows(history, search: "CAFE").map(\.text) == ["Meet at the café"])
        #expect(rows(history, search: "REPONDS").map(\.text) == ["Dear Ana"])
        #expect(rows(history, search: "  ").count == 2)
        #expect(rows(history, search: "missing").isEmpty)
    }

    @Test func weeklyWordsUseCalendarWeeksAndEmailBodies() {
        let history = DictationHistory(file: nil)
        for (time, text, outcome) in [
            ("2026-10-05T06:59:00Z", "Previous Sunday words", DictationHistory.Entry.Outcome.inserted),
            ("2026-10-05T07:00:00Z", "Monday two", .notInserted),
            ("2026-10-12T06:59:00Z", "Sunday three words", .uncertain),
            ("2026-10-12T07:00:00Z", "Next week excluded", .inserted)
        ] { history.add(.init(id: UUID(), date: date(time), text: text, outcome: outcome)) }
        history.add(.init(id: UUID(), date: now, text: "Email body has five words", outcome: .inserted, spoken: "A much longer spoken cue that must not be counted"))
        history.add(.init(id: UUID(), date: now, text: "Unused proposal excluded", outcome: .notInserted, proposal: .unused))
        #expect(history.stats(now: now, calendar: calendar).wordsThisWeek == 10)
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        #expect(history.stats(now: now, calendar: sundayFirst).wordsThisWeek == 10)
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = calendar.timeZone
        hebrew.firstWeekday = 2
        #expect(history.stats(now: now, calendar: hebrew).wordsThisWeek == 10)
        // Sunday-first includes the earlier Sunday and excludes the later one.
        history.add(.init(id: UUID(), date: date("2026-10-04T19:00:00Z"), text: "Extra Sunday", outcome: .inserted))
        #expect(history.stats(now: now, calendar: calendar).wordsThisWeek == 10)
        #expect(history.stats(now: now, calendar: sundayFirst).wordsThisWeek == 12)
    }

    @Test func paceUsesOnlyNewDurationsAndDividesTotals() {
        let history = DictationHistory(file: nil)
        history.add(.init(id: UUID(), date: now, text: "Old words do not count in pace", outcome: .inserted))
        #expect(history.stats(now: now, calendar: calendar).wordsPerMinute == nil)
        history.add(.init(id: UUID(), date: now, text: "one two three four", outcome: .inserted, speechDuration: 2))
        history.add(.init(id: UUID(), date: now, text: "five six", outcome: .notInserted, speechDuration: 4))
        // Six words in six seconds is 60 WPM, not the average of 120 and 30.
        #expect(history.stats(now: now, calendar: calendar).wordsPerMinute == 60)
        history.add(.init(id: UUID(), date: now, text: "", outcome: .failed, speechDuration: 6))
        #expect(history.stats(now: now, calendar: calendar).wordsPerMinute == 30)
        history.add(.init(id: UUID(), date: now, text: "Ignored zero duration", outcome: .inserted, speechDuration: 0))
        history.add(.init(id: UUID(), date: now, text: "Ignored negative duration", outcome: .inserted, speechDuration: -1))
        #expect(history.stats(now: now, calendar: calendar).wordsPerMinute == 30)
    }

    @Test func emailsWrittenCountBodiesAllTimeRegardlessOfInsertion() {
        let history = DictationHistory(file: nil)
        for outcome in [DictationHistory.Entry.Outcome.inserted, .notInserted, .uncertain] {
            history.add(.init(id: UUID(), date: date("2025-01-01T00:00:00Z"), text: "Email body", outcome: outcome, spoken: "Cue"))
        }
        history.add(.init(id: UUID(), date: now, text: "Partial cue", outcome: .failed, spoken: "Cue"))
        history.add(.init(id: UUID(), date: now, text: " ", outcome: .inserted, spoken: "Cue"))
        history.add(.init(id: UUID(), date: now, text: "Accepted", outcome: .inserted, proposal: .accepted))
        #expect(history.stats(now: now, calendar: calendar).emailsWritten == 3)
    }

    @Test func legacyRetryPairsCollapseOnlyWhenNoWordsCanBeLost() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let id = UUID(), ambiguousID = UUID()
        let original = date("2026-10-07T19:00:00Z")
        let saved: [DictationHistory.Entry] = [
            .init(id: id, date: now, text: "Recovered words", outcome: .notInserted, reason: "retried"),
            .init(id: id, date: original, text: "", outcome: .failed),
            .init(id: ambiguousID, date: now, text: "Different final", outcome: .notInserted, reason: "retried"),
            .init(id: ambiguousID, date: original, text: "Original transcript", outcome: .failed),
            .init(id: UUID(), date: now, text: "Unlinked recovery", outcome: .notInserted, reason: "retried"),
            .init(id: UUID(), date: original, text: "", outcome: .failed)
        ]
        try JSONEncoder().encode(saved).write(to: file)
        let history = DictationHistory(file: file)
        #expect(history.entries.count == 5)
        #expect(history.entries.first(where: { $0.id == id })?.date == original)
        #expect(Set(history.entries.map(\.id)).count == 5)
        #expect(Set(history.entries.filter { !$0.text.isEmpty }.map(\.text)) == ["Recovered words", "Different final", "Original transcript", "Unlinked recovery"])
        #expect(history.entries.allSatisfy { $0.speechDuration == nil })
        #expect(DictationHistory(file: file).entries == history.entries)
    }
}

extension DictationScenarioTests {
    @Test func historyRecordsAudioSecondsAndKeepsThemThroughRetry() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "", text: ""), .answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint, source: spokenIntoHeadset())
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        let original = try #require(dictation.history.entries.first)
        // Twelve 3200-byte chunks and the source's final 1000 bytes at 32000 bytes/sec.
        #expect(original.speechDuration == 1.23125)
        let events = OSAllocatedUnfairLock(initialState: [UUID: [DiagnosticEvents.Name]]())
        DiagnosticEvents.shared.setSink { name, _, _, id in
            if let id { events.withLock { $0[id, default: []].append(name) } }
        }
        defer { DiagnosticEvents.shared.setSink(nil) }
        dictation.retry(original.id)
        await idle(dictation)
        let recovered = try #require(dictation.history.entries.first)
        #expect(dictation.history.entries.count == 1)
        #expect(recovered.id == original.id)
        #expect(recovered.date == original.date)
        #expect(recovered.speechDuration == original.speechDuration)
        let retryID = try #require(recovered.retentionID)
        #expect(events.withLock { $0[retryID] } == [.dictationAttempt, .dictationFinished])
    }

    @Test func successfulDictationRecordsAudioRatherThanWallClockDuration() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        dictation.toggle()
        await speak()
        dictation.toggle()
        await idle(dictation)
        #expect(dictation.history.entries.first?.speechDuration == 0.33125)
    }

    @Test func clearCancelsARetryBeforeItCanReturnOrRecreateHistory() async throws {
        let server = try await ScriptedEndpoint([.answerLate(after: 0.4, transcript: "late", text: "Late words")])
        defer { server.stop() }
        let dictation = controller(server.endpoint)
        let entry = DictationHistory.Entry(id: UUID(), date: Date(), text: "", outcome: .failed)
        dictation.history.add(entry, retry: .init(chunks: [Data(repeating: 1, count: 3200)], start: .init(register: "work")))
        dictation.retry(entry.id)
        await speak()
        #expect(dictation.phase == .processing)
        // The old view's direct Clear path must also cancel a live retry.
        #expect(dictation.history.clear())
        #expect(dictation.phase == .idle)
        #expect(dictation.history.retry(for: entry.id) == nil)
        try await Task.sleep(for: .milliseconds(550))
        #expect(dictation.history.entries.isEmpty)
        #expect(server.connections.first?.cancelled == true)
    }

    @Test func clearDropsTheOnlyAudioCopyWhileARetryWaitsForItsGrant() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let grants = ScriptedGrants(delay: .milliseconds(400))
        let dictation = controller(.init(url: server.endpoint.url, credentials: grants))
        let release = AudioRelease()
        let entry = DictationHistory.Entry(id: UUID(), date: Date(), text: "", outcome: .failed)
        dictation.history.add(entry, retry: .init(chunks: [release.audio()], start: .init(register: "work")))
        dictation.retry(entry.id)
        await speak()
        #expect(!release.released)
        #expect(dictation.clearHistory())
        #expect(release.released)
        #expect(dictation.phase == .idle)
        try await Task.sleep(for: .milliseconds(450))
        #expect(server.connections.isEmpty)
        #expect(dictation.history.entries.isEmpty)
    }
}

/// Observe release of a synthetic PCM buffer even when a grant ignores cancellation.
private final class AudioRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var didRelease = false
    var released: Bool { lock.withLock { didRelease } }

    func audio() -> Data {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 1)
        pointer.initializeMemory(as: UInt8.self, repeating: 1, count: 65536)
        return Data(bytesNoCopy: pointer, count: 65536, deallocator: .custom { [self] pointer, _ in
            pointer.deallocate()
            lock.withLock { didRelease = true }
        })
    }
}

extension HistoryPresentationTests {
    @Test func copyResolvesCurrentTextAndPreservesConcealment() {
        let history = DictationHistory(file: nil)
        let board = NSPasteboard(name: .init("co.intention.tests.history.\(UUID())"))
        let owner = PasteboardOwner(pasteboard: board, mayRead: { true })
        let secret = DictationHistory.Entry(id: UUID(), date: now, text: "Synthetic secret", outcome: .notInserted, reason: "secureField")
        history.add(secret)
        #expect(history.copy(secret.id, to: owner))
        #expect(board.string(forType: .string) == "Synthetic secret")
        #expect(board.types?.contains(PasteboardOwner.concealedType) == true)
        let ordinary = DictationHistory.Entry(id: UUID(), date: now, text: "Old words", outcome: .inserted)
        history.add(ordinary)
        history.update(.init(id: ordinary.id, date: now, text: "Current words", outcome: .inserted))
        #expect(history.copy(ordinary.id, to: owner))
        #expect(board.string(forType: .string) == "Current words")
        #expect(board.types?.contains(PasteboardOwner.concealedType) == false)
        history.clear()
        #expect(!history.copy(ordinary.id, to: owner))
        #expect(board.string(forType: .string) == "Current words")
    }

    @Test func savedDurationSurvivesRelaunchAndClearDropsEveryKeptRecording() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = DictationHistory(file: file)
        for index in 0..<3 {
            history.add(.init(id: UUID(), date: now, text: "", outcome: .failed, speechDuration: Double(index + 1)),
                        retry: .init(chunks: [Data([1, 2])], start: .init(register: "work")))
        }
        let ids = history.entries.map(\.id)
        #expect(history.sections(matching: "", now: now, calendar: calendar).flatMap(\.rows).allSatisfy { $0.canRetry })
        #expect(DictationHistory(file: file).entries.map(\.speechDuration) == [3, 2, 1])
        #expect(history.clear())
        #expect(ids.allSatisfy { history.retry(for: $0) == nil })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(history.isEmpty)
    }

    @Test func legacyPairWithDistinctSpokenWordsKeepsBothEntries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let saved: [DictationHistory.Entry] = [
            .init(id: id, date: now, text: "Recovered", outcome: .notInserted, reason: "retried"),
            .init(id: id, date: now, text: "", outcome: .failed, spoken: "Original cue")
        ]
        let file = folder.appendingPathComponent("history.json")
        try JSONEncoder().encode(saved).write(to: file)
        let history = DictationHistory(file: file)
        #expect(history.entries.count == 2)
        #expect(history.entries.contains { $0.spoken == "Original cue" })
        #expect(Set(history.entries.map(\.id)).count == 2)
    }
}
