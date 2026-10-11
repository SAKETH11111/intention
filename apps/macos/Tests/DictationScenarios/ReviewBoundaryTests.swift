import Foundation
@testable import Dictation
import Testing

@MainActor
struct ReviewBoundaryTests {
    @Test func clearDeletesHistoryWithoutReadAccess() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: Date(), text: "Synthetic words", outcome: .inserted))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        #expect((try? Data(contentsOf: file)) == nil)
        #expect(history.clear())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(history.entries.isEmpty)
        #expect(history.dailyTally.isEmpty)
        #expect(!history.canClear)
        #expect(!DictationHistory(file: file).canClear)
    }

    @Test func clearDeletesTheUnreadableTallySetAsideAtStartup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: Date(), text: "Synthetic words", outcome: .inserted))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tally.path)
        #expect((try? Data(contentsOf: tally)) == nil)
        let loaded = DictationHistory(file: file)
        let preserved = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("history-tally-unreadable-") })
        #expect((try? Data(contentsOf: preserved)) == nil)
        #expect(loaded.dailyTally.reduce(0) { $0 + $1.words } == 2)
        #expect(loaded.clear())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!loaded.canClear)
        #expect(!DictationHistory(file: file).canClear)
    }

    @Test(arguments: ["history.json", "history-tally-unreadable-synthetic.json", "history-clear-unreadable-synthetic.json"])
    func clearDeletesUnreadableFilesWhenNoRowsOrReadableBackupExist(_ name: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unreadable = folder.appendingPathComponent(name)
        try Data("Synthetic unreadable bytes".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        #expect((try? Data(contentsOf: unreadable)) == nil)
        let history = DictationHistory(file: folder.appendingPathComponent("history.json"))
        #expect(history.entries.isEmpty)
        #expect(history.dailyTally.isEmpty)
        #expect(history.canClear)
        #expect(history.clear())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!history.canClear)
    }

    @Test func clearSucceedsWhenDeletionThrowsAfterRemovingTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let history = DictationHistory(file: file, removeFile: { path in
            try FileManager.default.removeItem(at: path)
            throw CocoaError(.fileWriteUnknown)
        })
        history.add(.init(id: UUID(), date: Date(), text: "Synthetic words", outcome: .notInserted))
        #expect(history.clear())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!history.canClear)
    }

    @Test func failedTranscriptStillOffersItsKeptRetry() throws {
        let history = DictationHistory(file: nil)
        let entry = DictationHistory.Entry(id: UUID(), date: Date(), text: "Synthetic partial transcript", outcome: .failed, reason: "timedOut")
        history.add(entry, retry: .init(chunks: [Data([1, 2])], start: .init(register: "work")))
        let row = try #require(history.sections(matching: "", now: Date(), calendar: .current).first?.rows.first)
        #expect(row.canRetry)
        #expect(RowPresentation(row).actions == [.copy, .retry])
    }

    @Test func clearMustReportFailureIfAttentionMarkerCannotBeDeleted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let marker = folder.appendingPathComponent("needs-attention")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: Date(), text: "Synthetic words", outcome: .notInserted))
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: marker.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: marker.path)
        #expect(!history.clear())
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(DictationHistory(file: file).needsAttention)
    }

    @Test func leftoverFilesRemainClearableWithoutRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        for name in ["history.json", "history-tally.json", "needs-attention", "history-clear-recovery.json",
                     "history-tally-unreadable-synthetic.json", "history-clear-unreadable-synthetic.json"] {
            let path = folder.appendingPathComponent(name)
            try Data().write(to: path)
            let history = DictationHistory(file: file)
            #expect(history.entries.isEmpty)
            #expect(history.canClear)
            #expect(history.clear())
            #expect(!history.canClear)
        }
    }

    @Test func failedTallyDeletionLeavesHistoryForTheRemainingCounts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let history = DictationHistory(file: file)
        let entry = DictationHistory.Entry(id: UUID(), date: Date(), text: "Synthetic words", outcome: .notInserted)
        history.add(entry, retry: .init(chunks: [Data([1,2])], start: .init(register: "work")))
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: tally.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: tally.path)
        #expect(!history.clear())
        #expect(DictationHistory(file: file).entries.map { value in var copy = value; copy.tallyDay = nil; return copy } == [entry])
        #expect(history.retry(for: entry.id) == nil)
    }
}

extension ReviewBoundaryTests {
    @Test func unlistableHistoryFolderFailsClearAndKeepsItAvailable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let preserved = folder.appendingPathComponent("history-clear-unreadable-synthetic.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: Date(), text: "Synthetic personal words", outcome: .inserted))
        try Data("Synthetic older personal words".utf8).write(to: preserved)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil)
        #expect(!history.clear())
        #expect(history.canClear)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: preserved.path))
        let loaded = DictationHistory(file: file)
        #expect(loaded.canClear)
        #expect(loaded.entries == history.entries)
        #expect(loaded.dailyTally.reduce(0) { $0 + $1.words } == history.dailyTally.reduce(0) { $0 + $1.words })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(history.clear())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!history.canClear)
    }

    @Test func partialClearOfUnreadableHistoryNeverLeavesOrphanedCountsAfterReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let preserved = folder.appendingPathComponent("history-clear-unreadable-synthetic.json")
        let history = DictationHistory(file: file)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: preserved.path)
            try? FileManager.default.removeItem(at: folder)
        }
        history.add(.init(id: UUID(), date: Date(), text: "Synthetic personal words", outcome: .inserted))
        try Data("Synthetic preserved bytes".utf8).write(to: preserved)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: preserved.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        #expect((try? Data(contentsOf: file)) == nil)
        #expect(!history.clear())
        let loaded = DictationHistory(file: file)
        #expect(loaded.entries.isEmpty)
        #expect(loaded.dailyTally.reduce(0) { $0 + $1.words } == 0)
        #expect(loaded.entries == history.entries)
        #expect(history.dailyTally.reduce(0) { $0 + $1.words } == 0)
        #expect(!FileManager.default.fileExists(atPath: tally.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("history-clear-recovery.json").path))
        #expect(history.canClear)
        #expect(loaded.canClear)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: preserved.path)
        #expect(history.clear())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

extension ReviewBoundaryTests {
    @Test func failedSetAsideTallyDeletionStopsBeforeHistoryAndReloadsRemainingRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let tally = folder.appendingPathComponent("history-tally.json")
        let preserved = folder.appendingPathComponent("history-tally-unreadable-synthetic.json")
        let history = DictationHistory(file: file)
        history.add(.init(id: UUID(), date: Date(), text: "Synthetic counted words", outcome: .inserted))
        try Data("Synthetic set aside counts".utf8).write(to: preserved)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: preserved.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: preserved.path)
        #expect(!history.clear())
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: preserved.path))
        // Clear's reload must not recreate a tally it just deleted.
        #expect(!FileManager.default.fileExists(atPath: tally.path))
        let loaded = DictationHistory(file: file)
        #expect(loaded.entries == history.entries)
        #expect(loaded.dailyTally.reduce(0) { $0 + $1.words } == 3)
        #expect(history.dailyTally.reduce(0) { $0 + $1.words } == 3)
        #expect(history.canClear)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: preserved.path)
        #expect(history.clear())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func clearFailsIfTheFinalFolderListingCannotBeRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let history = DictationHistory(file: file, removeFile: { path in
            try FileManager.default.removeItem(at: path)
            if path.lastPathComponent == file.lastPathComponent {
                try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
            }
        })
        history.add(.init(id: UUID(), date: Date(), text: "Synthetic counted words", outcome: .inserted))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(!history.clear())
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil)
        #expect(history.entries.isEmpty)
        #expect(history.dailyTally.isEmpty)
        #expect(history.canClear)
        #expect(DictationHistory(file: file).canClear)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(history.clear())
        #expect(!history.canClear)
    }

    @Test func clearDeletesEveryOwnedFileAfterDroppingRetryAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let id = UUID()
        var cancelled = false
        var removed: [String] = []
        var audioWasDropped = { false }
        let history = DictationHistory(file: file, removeFile: { path in
            #expect(cancelled)
            #expect(audioWasDropped())
            removed.append(path.lastPathComponent)
            try FileManager.default.removeItem(at: path)
        })
        defer { try? FileManager.default.removeItem(at: folder) }
        audioWasDropped = { [weak history] in history?.retry(for: id) == nil }
        history.willClear = { cancelled = true }
        history.add(.init(id: id, date: Date(), text: "", outcome: .failed),
                    retry: .init(chunks: [Data([1, 2])], start: .init(register: "work")))
        let leftovers = ["history-tally-unreadable-synthetic.json", "history-clear-recovery.json", "history-clear-unreadable-synthetic.json"]
        for name in leftovers {
            let path = folder.appendingPathComponent(name)
            try Data("Synthetic saved bytes".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        }
        #expect(history.clear())
        #expect(Set(removed) == Set(leftovers + ["history.json", "history-tally.json", "needs-attention"]))
        let historyIndex = try #require(removed.firstIndex(of: "history.json"))
        #expect(try #require(removed.firstIndex(of: "history-tally.json")) < historyIndex)
        #expect(try #require(removed.firstIndex(of: "history-tally-unreadable-synthetic.json")) < historyIndex)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(history.entries.isEmpty)
        #expect(history.dailyTally.isEmpty)
        #expect(!history.needsAttention)
        #expect(!history.canClear)
    }
}
