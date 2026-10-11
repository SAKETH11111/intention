import Foundation
@testable import Dictation
import Testing

@MainActor
struct HistoryTallyTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-10-08T19:00:00Z") }

    @Test func aWeekBeyondTheHistoryLimitKeepsEveryWordAndLifetimeEmail() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: date("2025-01-01T19:00:00Z"), text: "Older email", outcome: .inserted, spoken: "Old cue"))
        for day in 5...11 {
            for _ in 0..<20 {
                history.add(.init(id: UUID(), date: date("2026-10-\(String(format: "%02d", day))T19:00:00Z"),
                                  text: "Four counted words !!! 123", outcome: .inserted, speechDuration: 3))
            }
        }
        history.add(.init(id: UUID(), date: now, text: "Written email body", outcome: .notInserted, spoken: "Longer cue to ignore"))
        #expect(history.entries.count == 100)
        let expected = HistoryStats(wordsThisWeek: 563, wordsPerMinute: 80, emailsWritten: 2)
        #expect(history.stats(now: now, calendar: calendar) == expected)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == expected)
        #expect(history.stats(now: date("2026-10-12T19:00:00Z"), calendar: calendar).wordsThisWeek == 0)
    }

    @Test func retryReplacesItsContributionOnceThroughAddAndUpdate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = DictationHistory(file: file)
        let original = DictationHistory.Entry(id: UUID(), date: now, text: "Partial transcript", outcome: .failed, speechDuration: 6)
        history.add(original)
        let replacement = DictationHistory.Entry(id: original.id, date: date("2026-10-12T19:00:00Z"),
                                                text: "Four recovered words here", outcome: .notInserted, reason: "retried", speechDuration: 99)
        history.add(replacement)
        history.update(replacement)
        let reloaded = DictationHistory(file: file)
        reloaded.update(replacement)
        for _ in 0..<100 { reloaded.add(.init(id: UUID(), date: now, text: "Extra", outcome: .inserted)) }
        #expect(reloaded.stats(now: now, calendar: calendar) == HistoryStats(wordsThisWeek: 104, wordsPerMinute: 40, emailsWritten: 0))
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == reloaded.stats(now: now, calendar: calendar))
    }

    @Test func retryMovesItsWordsFromTheOriginalDayAcrossTimeZonesAndRelaunch() throws {
        var zone = TimeZone(identifier: "America/Los_Angeles")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = DictationHistory(file: file, timeZone: { zone })
        let original = DictationHistory.Entry(id: UUID(), date: date("2026-10-05T06:30:00Z"),
                                              text: "Partial transcript", outcome: .failed, speechDuration: 6)
        history.add(original)
        zone = TimeZone(identifier: "America/New_York")!
        let reloaded = DictationHistory(file: file, timeZone: { zone })
        reloaded.update(.init(id: original.id, date: now, text: "Four recovered words here", outcome: .notInserted, reason: "retried"))
        var newYork = calendar
        newYork.timeZone = zone
        newYork.firstWeekday = 2
        #expect(reloaded.stats(now: now, calendar: newYork).wordsThisWeek == 4)
        #expect(reloaded.dailyTally.reduce(0) { $0 + $1.words } == 4)
        #expect(reloaded.dailyTally.allSatisfy { $0.words >= 0 })
        #expect(DictationHistory(file: file).stats(now: now, calendar: newYork).wordsThisWeek == 4)
    }

    @Test func unreadableTallyRecoversRetainedHistoryAndPreservesTheOriginalBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: now, text: "Three retained words", outcome: .inserted, speechDuration: 3))
        let unreadable = Data("broken tally bytes".utf8)
        try unreadable.write(to: tally)
        let reloaded = DictationHistory(file: file)
        #expect(reloaded.stats(now: now, calendar: calendar).wordsThisWeek == 3)
        reloaded.add(.init(id: UUID(), date: now, text: "Two more", outcome: .inserted))
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar).wordsThisWeek == 5)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let preserved = files.filter { $0.lastPathComponent.hasPrefix("history-tally-unreadable-") }
        #expect(preserved.count == 1)
        if let copy = preserved.first { #expect(try Data(contentsOf: copy) == unreadable) }
        #expect(reloaded.clear())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func clearRemovesTheTallyAndStartsFresh() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: now, text: "One email", outcome: .inserted, spoken: "Cue"))
        #expect(FileManager.default.fileExists(atPath: tally.path))
        #expect(history.clear())
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: tally.path))
        let empty = HistoryStats(wordsThisWeek: 0, wordsPerMinute: nil, emailsWritten: 0)
        #expect(history.stats(now: now, calendar: calendar) == empty)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == empty)
        history.add(.init(id: UUID(), date: now, text: "Fresh", outcome: .inserted, speechDuration: 2))
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == HistoryStats(wordsThisWeek: 1, wordsPerMinute: 30, emailsWritten: 0))
    }

    @Test func savedTallyContainsOnlyDaysNumbersAndRetainedRowIdentities() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = DictationHistory(file: folder.appendingPathComponent("history.json"))
        history.add(.init(id: UUID(), date: now, text: "Synthetic confidential body", outcome: .inserted,
                          spoken: "Synthetic confidential cue", device: "Synthetic personal microphone", speechDuration: 5))
        let data = try Data(contentsOf: folder.appendingPathComponent("history-tally.json"))
        let days = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(days.count == 1)
        let day = try #require(days.first)
        #expect(Set(day.keys) == ["day", "words", "speechSeconds", "pacedWords", "emailsWritten", "contributions"])
        #expect(day.filter { $0.key != "contributions" }.values.allSatisfy { $0 is NSNumber })
        let contributions = try #require(day["contributions"] as? [[String: Any]])
        let contribution = try #require(contributions.first)
        #expect(contributions.count == 1)
        #expect(Set(contribution.keys) == ["id", "words", "speechSeconds", "pacedWords", "emailsWritten"])
        #expect(contribution["id"] as? String == history.entries.first?.id.uuidString)
        #expect(contribution.filter { $0.key != "id" }.values.allSatisfy { $0 is NSNumber })
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func oldEntriesSeedOnceAfterMergingRetries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let id = UUID()
        let entries: [DictationHistory.Entry] = [
            .init(id: id, date: now, text: "Recovered two", outcome: .notInserted, reason: "retried"),
            .init(id: id, date: now, text: "", outcome: .failed),
            .init(id: UUID(), date: now, text: "One email body", outcome: .inserted, spoken: "Cue"),
            .init(id: UUID(), date: now, text: "Unused draft", outcome: .notInserted, proposal: .unused),
            .init(id: UUID(), date: now, text: "Timed words", outcome: .inserted, speechDuration: 2)
        ]
        try JSONEncoder().encode(entries).write(to: file)
        let history = DictationHistory(file: file)
        let expected = HistoryStats(wordsThisWeek: 7, wordsPerMinute: 60, emailsWritten: 1)
        #expect(history.stats(now: now, calendar: calendar) == expected)
        let tally = folder.appendingPathComponent("history-tally.json")
        #expect(FileManager.default.fileExists(atPath: tally.path))
        let seeded = try Data(contentsOf: tally)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == expected)
        #expect(try Data(contentsOf: tally) == seeded)
        for _ in 0..<100 { history.add(.init(id: UUID(), date: now, text: "Extra", outcome: .inserted)) }
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == HistoryStats(wordsThisWeek: 107, wordsPerMinute: 60, emailsWritten: 1))
    }

    @Test func paceUsesOnlyRecordedDurationsAcrossTrimming() {
        let history = DictationHistory(file: nil)
        history.add(.init(id: UUID(), date: now, text: "Two words", outcome: .inserted, speechDuration: 2))
        history.add(.init(id: UUID(), date: now, text: "", outcome: .failed, speechDuration: 2))
        history.add(.init(id: UUID(), date: now, text: "Old email body has six words", outcome: .inserted, spoken: "Cue"))
        history.add(.init(id: UUID(), date: now, text: "Accepted proposal has five words", outcome: .inserted, proposal: .accepted))
        for _ in 0..<100 { history.add(.init(id: UUID(), date: now, text: "Untimed", outcome: .inserted)) }
        #expect(history.stats(now: now, calendar: calendar).wordsPerMinute == 30)
        history.clear()
        history.add(.init(id: UUID(), date: now, text: "Old words", outcome: .inserted))
        #expect(history.stats(now: now, calendar: calendar).wordsPerMinute == nil)
    }
}


extension HistoryTallyTests {
    @Test func immutableTallyRepairsMissingRetainedContributionsOnEveryLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let history = DictationHistory(file: file)
        for _ in 0..<105 {
            history.add(.init(id: UUID(), date: now, text: "Old", outcome: .inserted))
        }
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: tally.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: tally.path)
        let saved = try Data(contentsOf: tally)
        history.add(.init(id: UUID(), date: now, text: "New email words", outcome: .inserted,
                          spoken: "Synthetic cue", speechDuration: 3))
        let expected = HistoryStats(wordsThisWeek: 108, wordsPerMinute: 60, emailsWritten: 1)
        for _ in 0..<2 {
            let loaded = DictationHistory(file: file)
            #expect(loaded.entries.count == 100)
            #expect(loaded.stats(now: now, calendar: calendar) == expected)
            #expect(loaded.dailyTally.reduce(0) { $0 + $1.speechSeconds } == 3)
            #expect(try Data(contentsOf: tally) == saved)
        }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: tally.path)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == expected)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == expected)
    }

    @Test func retryReconcilesTheContributionMissingFromAnImmutableTally() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: now, text: "Old", outcome: .inserted))
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: tally.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: tally.path)
        let id = UUID()
        history.add(.init(id: id, date: now, text: "Four partial words here", outcome: .failed, speechDuration: 4))
        let loaded = DictationHistory(file: file)
        loaded.update(.init(id: id, date: now, text: "Two words", outcome: .notInserted, reason: "retried", spoken: "Cue"))
        let expected = HistoryStats(wordsThisWeek: 3, wordsPerMinute: 30, emailsWritten: 1)
        #expect(loaded.stats(now: now, calendar: calendar) == expected)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == expected)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: tally.path)
        let writable = DictationHistory(file: file)
        #expect(writable.stats(now: now, calendar: calendar) == expected)
        writable.update(.init(id: id, date: now, text: "Three final words", outcome: .notInserted, reason: "retried", spoken: "Cue"))
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == HistoryStats(wordsThisWeek: 4, wordsPerMinute: 45, emailsWritten: 1))
    }
}


extension HistoryTallyTests {
    @Test func staleRecordedContributionIsReplacedOnceAfterRetryAndRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let history = DictationHistory(file: file)
        let id = UUID()
        history.add(.init(id: id, date: now, text: "Four partial words here", outcome: .failed, speechDuration: 4))
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: tally.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: tally.path)
        history.update(.init(id: id, date: now, text: "Two words", outcome: .notInserted, reason: "retried", spoken: "Cue"))
        let expected = HistoryStats(wordsThisWeek: 2, wordsPerMinute: 30, emailsWritten: 1)
        let loaded = DictationHistory(file: file)
        #expect(loaded.stats(now: now, calendar: calendar) == expected)
        loaded.update(.init(id: id, date: now, text: "Three final words", outcome: .notInserted, reason: "retried", spoken: "Cue"))
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == HistoryStats(wordsThisWeek: 3, wordsPerMinute: 45, emailsWritten: 1))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: tally.path)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == HistoryStats(wordsThisWeek: 3, wordsPerMinute: 45, emailsWritten: 1))
    }

    @Test func tallyContributionIdentitiesAreBoundedByRetainedHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = DictationHistory(file: file)
        for _ in 0..<105 { history.add(.init(id: UUID(), date: now, text: "Word", outcome: .inserted)) }
        let tally = try JSONDecoder().decode([DictationHistory.DailyTally].self,
            from: Data(contentsOf: folder.appendingPathComponent("history-tally.json")))
        let ids = tally.flatMap { ($0.contributions ?? []).map(\.id) }
        #expect(ids.count == 100)
        #expect(Set(ids) == Set(history.entries.map(\.id)))
        #expect(tally.reduce(0) { $0 + $1.words } == 105)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar).wordsThisWeek == 105)
    }

    @Test func legacyNumericTallyIsRaisedToTheRetainedRowsAndMigratedOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: now, text: "Three retained words", outcome: .inserted, spoken: "Cue", speechDuration: 3))
        var legacy = history.dailyTally
        for index in legacy.indices {
            legacy[index].contributions = nil
            legacy[index].words = 1
            legacy[index].speechSeconds = 0
            legacy[index].pacedWords = 0
            legacy[index].emailsWritten = 0
        }
        try JSONEncoder().encode(legacy).write(to: tally)
        let expected = HistoryStats(wordsThisWeek: 3, wordsPerMinute: 60, emailsWritten: 1)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == expected)
        #expect(DictationHistory(file: file).stats(now: now, calendar: calendar) == expected)
    }
}
