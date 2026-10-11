import Foundation
@testable import Inserter
import Testing

struct InsertionCheckClipboardTests {
    private struct RestoreState: Decodable {
        let expectedRestoreChangeCount: Int?
    }

    private struct StoredSnapshot: Decodable {
        struct Item: Decodable, Equatable {
            let type: String
            let data: Data
        }
        let items: [[Item]]
    }

    private func snapshot() throws -> PasteboardOwner.Snapshot {
        // Two items, including a non-text type with zero and high bytes.
        let json = """
        {"items":[[{"type":"public.utf8-plain-text","data":"c2F2ZWQgY29weQ=="},
                   {"type":"co.intention.tests.binary","data":"AAD/"}],
                  [{"type":"public.html","data":"PGI+Y29weTwvYj4="}]],
         "complete":true,"changeCount":12}
        """
        return try JSONDecoder().decode(PasteboardOwner.Snapshot.self, from: Data(json.utf8))
    }

    private func readable(_ string: String?, changeCount: Int) throws -> PasteboardOwner.Backup {
        let items = string.map {
            "[[{\"type\":\"public.utf8-plain-text\",\"data\":\"\(Data($0.utf8).base64EncodedString())\"}]]"
        } ?? "[]"
        return .copied(try JSONDecoder().decode(PasteboardOwner.Snapshot.self,
            from: Data("{\"items\":\(items),\"complete\":true,\"changeCount\":\(changeCount)}".utf8)))
    }

    private func withFile(_ body: (InsertionCheckClipboard.RecoveryFile) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("intention-clipboard-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(.init(url: root.appendingPathComponent("private/clipboard.json")))
    }

    @MainActor
    private func withFile(_ body: @MainActor (InsertionCheckClipboard.RecoveryFile) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("intention-clipboard-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(.init(url: root.appendingPathComponent("private/clipboard.json")))
    }

    private func expectEveryItemAndType(_ snapshot: PasteboardOwner.Snapshot) throws {
        let items = try JSONDecoder().decode(StoredSnapshot.self, from: JSONEncoder().encode(snapshot)).items
        #expect(items.count == 2)
        #expect(items.first == [.init(type: "public.utf8-plain-text", data: Data("saved copy".utf8)),
                                .init(type: "co.intention.tests.binary", data: Data([0, 0, 255]))])
        #expect(items.last == [.init(type: "public.html", data: Data("<b>copy</b>".utf8))])
        #expect(snapshot.complete)
        #expect(snapshot.changeCount == 12)
    }

    @Test func restoresAReturnedSentinelEvenAfterAnUnconfirmedPaste() {
        #expect(InsertionCheckClipboard.cleanupDecision(string: "sentinel", sentinels: ["sentinel"],
            pastedStrings: ["synthetic paste"]) == .restore)
    }

    @Test func leavesPastedTextForAnAppThatMayStillReadIt() {
        #expect(InsertionCheckClipboard.cleanupDecision(string: "synthetic paste", sentinels: ["sentinel"],
            pastedStrings: ["synthetic paste"]) == .pastedText)
    }

    @Test func reportsANewerCopyAfterAnUnconfirmedPaste() {
        #expect(InsertionCheckClipboard.cleanupDecision(string: "new copy", sentinels: ["sentinel"],
            pastedStrings: ["synthetic paste"]) == .newerCopy)
    }

    @Test @MainActor
    func failedSentinelRestoreStopsLaterCasesAndKeepsTheOriginalBackup() async throws {
        try await withFile { file in
            let run = InsertionCheckClipboard.Run(file: file)
            #expect(try await run.prepareSentinel(current: snapshot(), ownsCurrent: false,
                sentinels: ["failed sentinel"], currentChangeCount: { 12 }))
            let bytes = try Data(contentsOf: file.url)
            // The sentinel write left an empty clipboard, and the immediate
            // restore also failed. A later case must not save that empty copy.
            #expect(try run.restoreFailedSentinel(changeCount: 13) { _, _ in false } == .restoreFailed)
            let stateBytes = try Data(contentsOf: file.stateURL)
            #expect(try JSONDecoder().decode(RestoreState.self, from: stateBytes).expectedRestoreChangeCount == 14)
            let empty = try #require(readable(nil, changeCount: 14).snapshot)
            #expect(try await run.prepareSentinel(current: empty, ownsCurrent: false,
                sentinels: ["later sentinel"], currentChangeCount: { 14 }) == false)
            #expect(run.stopped)
            try expectEveryItemAndType(#require(run.saved))
            #expect(try await run.cleanUp(inserters: [], sentinels: ["failed sentinel"], pastedStrings: [],
                read: {
                    Issue.record("a stopped run must leave its backup for the next launch")
                    return .copied(empty)
                }, restore: { _, _ in
                    Issue.record("a stopped run must not retry or discard its backup")
                    return true
                }) == nil)
            #expect(try Data(contentsOf: file.url) == bytes)
            #expect(try Data(contentsOf: file.stateURL) == stateBytes)
        }
    }

    @Test(arguments: [false, true], [nil, "copied since", "skipped sentinel"] as [String?]) @MainActor
    func skippedSentinelWriteNeverRestoresOverANewerClear(laterCase: Bool, laterString: String?) async throws {
        try await withFile { file in
            let run = InsertionCheckClipboard.Run(file: file)
            if laterCase {
                #expect(try await run.prepareSentinel(current: snapshot(), ownsCurrent: false,
                    sentinels: ["earlier sentinel"], currentChangeCount: { 12 }))
            }
            let current = try laterCase ? #require(readable("earlier sentinel", changeCount: 20).snapshot) : snapshot()
            var countReads = 0
            #expect(try await run.prepareSentinel(current: current, ownsCurrent: laterCase,
                sentinels: ["skipped sentinel"], currentChangeCount: {
                    countReads += 1
                    // Another app clears during the off-actor file save.
                    return countReads == 1 ? current.changeCount : current.changeCount + 1
                }) == false)
            let state = try JSONDecoder().decode(InsertionCheckClipboard.RecoveryFile.SentinelRecord.self,
                                                 from: Data(contentsOf: file.stateURL))
            #expect(state.sentinelWriteAborted == true)
            #expect(state.expectedSentinelChangeCount == nil)
            let empty = try readable(laterString, changeCount: current.changeCount + 1)
            #expect(try await run.cleanUp(inserters: [], sentinels: ["skipped sentinel"], pastedStrings: [],
                read: { empty }, restore: { _, _ in
                    Issue.record("cleanup must leave the newer clear alone")
                    return true
                }) == nil)
            var wroteClipboard = false
            let outcome = try InsertionCheckClipboard.RecoveryFile(url: file.url).recover(current: empty) { _, _ in
                wroteClipboard = true
                return true
            }
            #expect(!wroteClipboard)
            #expect(outcome == .newerCopy)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test(arguments: ["first sentinel", "second sentinel"]) @MainActor
    func abortedPreparationStillRecognizesEveryEarlierSentinel(returned: String) async throws {
        try await withFile { file in
            let run = InsertionCheckClipboard.Run(file: file)
            #expect(try await run.prepareSentinel(current: snapshot(), ownsCurrent: false,
                sentinels: ["first sentinel"], currentChangeCount: { 12 }))
            let second = try #require(readable("first sentinel", changeCount: 20).snapshot)
            #expect(try await run.prepareSentinel(current: second, ownsCurrent: true,
                sentinels: ["first sentinel", "second sentinel"], currentChangeCount: { 20 }))
            let bytes = try Data(contentsOf: file.url)
            let current = try #require(readable("second sentinel", changeCount: 30).snapshot)
            var reads = 0
            #expect(try await run.prepareSentinel(current: current, ownsCurrent: true,
                sentinels: ["first sentinel", "second sentinel", "aborted sentinel"], currentChangeCount: {
                    reads += 1
                    // A late inserter return changes the count during the save.
                    return reads == 1 ? 30 : 31
                }) == false)
            #expect(run.stopped)
            #expect(try Data(contentsOf: file.url) == bytes)
            var restored = false
            let outcome = try InsertionCheckClipboard.RecoveryFile(url: file.url)
                .recover(current: readable(returned, changeCount: 31)) { copy, count in
                    try? expectEveryItemAndType(copy)
                    #expect(count == 31)
                    restored = true
                    return true
                }
            #expect(restored)
            #expect(outcome == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
            #expect(!FileManager.default.fileExists(atPath: file.stateURL.path))
        }
    }

    @Test @MainActor
    func anAbortedSentinelRecoveryRecordsRestorationBeforeWritingAndRetries() async throws {
        try await withFile { file in
            let id = try await file.prepareSentinel(snapshot(), replacingSnapshot: true, snapshotID: nil,
                sentinels: ["earlier sentinel"], changeCount: 20)
            try await file.abortSentinel(snapshotID: id, sentinels: ["earlier sentinel"], changeCount: 30)
            let original = try Data(contentsOf: file.url)
            let outcome = try file.recover(current: readable("earlier sentinel", changeCount: 31)) { _, count in
                #expect(count == 31)
                // Simulate a crash or failure just after clearContents. The
                // next launch needs ownership recorded before this write.
                let data = try? Data(contentsOf: file.stateURL)
                let state = data.flatMap { try? JSONDecoder().decode(RestoreState.self, from: $0) }
                #expect(state?.expectedRestoreChangeCount == 32)
                return false
            }
            #expect(outcome == .restoreFailed)
            #expect(try Data(contentsOf: file.url) == original)
            for string in [nil, "saved copy"] as [String?] {
                var restored = false
                let retry = try InsertionCheckClipboard.RecoveryFile(url: file.url)
                    .recover(current: readable(string, changeCount: 32)) { copy, count in
                        #expect(count == 32)
                        try? expectEveryItemAndType(copy)
                        restored = true
                        // Keep the same interrupted state for both probes.
                        return false
                    }
                #expect(restored)
                #expect(retry == .restoreFailed)
                #expect(FileManager.default.fileExists(atPath: file.url.path))
                #expect(try Data(contentsOf: file.url) == original)
            }
            #expect(try file.recover(current: readable(nil, changeCount: 33)) { _, _ in true } == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test @MainActor
    func aRestoreMarkerWriteFailureLeavesTheClipboardAndBackupUntouched() async throws {
        try await withFile { file in
            let saved = try snapshot()
            _ = try await file.prepareSentinel(saved, replacingSnapshot: true, snapshotID: nil,
                sentinels: ["sentinel"], changeCount: 20)
            let original = try Data(contentsOf: file.url)
            let originalState = try Data(contentsOf: file.stateURL)
            let pending = file.stateURL.deletingLastPathComponent().appendingPathComponent(".clipboard-state-pending")
            try Data("interrupted state write".utf8).write(to: pending)
            var wroteClipboard = false
            #expect(throws: POSIXError.self) {
                try file.finish(saved, decision: .restore, changeCount: 21) { _, _ in
                    wroteClipboard = true
                    return true
                }
            }
            #expect(!wroteClipboard)
            #expect(try Data(contentsOf: file.url) == original)
            #expect(try Data(contentsOf: file.stateURL) == originalState)
            #expect(try file.recover(current: readable("sentinel", changeCount: 21)) { _, _ in true } == .restored)
        }
    }

    @Test(arguments: [nil, "saved copy", "newer copy"] as [String?]) @MainActor
    func aCopyAfterAnInterruptedRestoreIsNeverOverwritten(string: String?) async throws {
        try await withFile { file in
            _ = try await file.prepareSentinel(snapshot(), replacingSnapshot: true, snapshotID: nil,
                sentinels: ["sentinel"], changeCount: 20)
            #expect(try file.recover(current: readable("sentinel", changeCount: 21)) { _, _ in false } == .restoreFailed)
            let outcome = try file.recover(current: readable(string, changeCount: 25)) { _, _ in
                Issue.record("a later copy is outside the restore's recorded count")
                return false
            }
            #expect(outcome == (string == "newer copy" ? .newerCopy : .unreadable))
            #expect(FileManager.default.fileExists(atPath: file.url.path) == (outcome == .unreadable))
        }
    }

    @Test @MainActor
    func interruptedSentinelWriteRestoresAnEmptyClipboardAtTheExpectedCount() async throws {
        try await withFile { file in
            _ = try await file.prepareSentinel(snapshot(), replacingSnapshot: true, snapshotID: nil,
                sentinels: ["sentinel"], changeCount: 20)
            // clearContents advanced the count, then the process died before
            // writeObjects put the sentinel there.
            var restored = false
            let outcome = try InsertionCheckClipboard.RecoveryFile(url: file.url)
                .recover(current: readable(nil, changeCount: 21)) { copy, count in
                    #expect(count == 21)
                    try? expectEveryItemAndType(copy)
                    restored = true
                    return true
                }
            #expect(outcome == .restored)
            #expect(restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test @MainActor
    func sentinelUpdatesLeaveTheSavedSnapshotBytesUntouched() async throws {
        try await withFile { file in
            let saved = try snapshot()
            let id = try await file.prepareSentinel(saved, replacingSnapshot: true, snapshotID: nil,
                sentinels: ["first sentinel"], changeCount: 20)
            let bytes = try Data(contentsOf: file.url)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            _ = try await file.prepareSentinel(saved, replacingSnapshot: false, snapshotID: id,
                sentinels: ["first sentinel", "second sentinel"], changeCount: 30)
            #expect(try Data(contentsOf: file.url) == bytes)
            #expect(try FileManager.default.attributesOfItem(atPath: file.url.path)[.systemFileNumber] as? UInt64
                == attributes[.systemFileNumber] as? UInt64)
            let outcome = try file.recover(current: readable("second sentinel", changeCount: 31)) { copy, _ in
                try? expectEveryItemAndType(copy)
                return true
            }
            #expect(outcome == .restored)
        }
    }

    @Test @MainActor
    func aLargeSnapshotSaveLetsTheMainActorKeepRunning() async throws {
        try await withFile { file in
            let payload = Data(repeating: 0x5a, count: 4_194_304).base64EncodedString()
            let json = "{\"items\":[[{\"type\":\"co.intention.tests.binary\",\"data\":\"\(payload)\"}]],\"complete\":true,\"changeCount\":12}"
            let saved = try JSONDecoder().decode(PasteboardOwner.Snapshot.self, from: Data(json.utf8))
            var mainActorRan = false
            let heartbeat = Task { @MainActor in mainActorRan = true }
            _ = try await file.prepareSentinel(saved, replacingSnapshot: true, snapshotID: nil,
                sentinels: ["sentinel"], changeCount: 20)
            #expect(mainActorRan)
            await heartbeat.value
        }
    }

    @Test func writesEveryItemAndTypeInA0600FileAnd0700Directory() throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            let directory = try FileManager.default.attributesOfItem(atPath: file.url.deletingLastPathComponent().path)
            #expect(directory[.posixPermissions] as? Int == 0o700)
            let record = try JSONDecoder().decode(InsertionCheckClipboard.RecoveryFile.Record.self, from: Data(contentsOf: file.url))
            try expectEveryItemAndType(record.snapshot)
            #expect(record.sentinels == ["sentinel"])
            #expect(record.changeCount == 20)
        }
    }

    @Test func deletesTheFileAfterRestoringAtCleanup() throws {
        try withFile { file in
            let saved = try snapshot()
            try file.save(saved, sentinels: ["sentinel"], changeCount: 20)
            var restored: PasteboardOwner.Snapshot?
            let outcome = try file.finish(saved, decision: .restore, changeCount: 23) { copy, count in
                restored = copy
                #expect(count == 23)
                return true
            }
            try expectEveryItemAndType(#require(restored))
            #expect(outcome == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test(arguments: [InsertionCheckClipboard.Decision.newerCopy, .pastedText])
    func retainsPastedTextAndDiscardsOnlyAProvenNewerCopy(decision: InsertionCheckClipboard.Decision) throws {
        try withFile { file in
            let saved = try snapshot()
            try file.save(saved, sentinels: ["sentinel"], changeCount: 20)
            let outcome = try file.finish(saved, decision: decision, changeCount: 23) { _, _ in
                Issue.record("a declined cleanup must not restore the clipboard")
                return false
            }
            #expect(outcome == (decision == .pastedText ? .pastedText : .newerCopy))
            #expect(FileManager.default.fileExists(atPath: file.url.path) == (decision == .pastedText))
        }
    }

    @Test(arguments: [false, true])
    func unreadableRecoveryKeepsTheCopyForTheNextStart(changing: Bool) throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            let outcome = try file.recover(current: changing ? .changing : .notAllowed) { _, _ in
                Issue.record("an unreadable clipboard must not be overwritten")
                return false
            }
            #expect(outcome == .unreadable)
            #expect(outcome?.mayStartRun == false)
            #expect(FileManager.default.fileExists(atPath: file.url.path))
            var restored = false
            let nextRun = InsertionCheckClipboard.RecoveryFile(url: file.url)
            let retried = try nextRun.recover(current: readable("sentinel", changeCount: 23)) { copy, _ in
                try? expectEveryItemAndType(copy)
                restored = true
                return true
            }
            #expect(retried == .restored)
            #expect(restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func restoresACrashedRunsSentinelAtTheNextStart() throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["first sentinel", "second sentinel"], changeCount: 20)
            let nextRun = InsertionCheckClipboard.RecoveryFile(url: file.url)
            var restored: PasteboardOwner.Snapshot?
            let outcome = try nextRun.recover(current: readable("first sentinel", changeCount: 24)) { copy, count in
                restored = copy
                #expect(count == 24)
                return true
            }
            try expectEveryItemAndType(#require(restored))
            #expect(outcome == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func restoresAnUnchangedClipboardAtTheNextStart() throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            var restored: PasteboardOwner.Snapshot?
            let outcome = try file.recover(current: readable(nil, changeCount: 20)) { copy, count in
                restored = copy
                #expect(count == 20)
                return true
            }
            try expectEveryItemAndType(#require(restored))
            #expect(outcome == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test(arguments: ["person copied since", "synthetic paste"])
    func leavesALaterCopyAloneAndDeletesTheCrashFile(string: String) throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            let outcome = try file.recover(current: readable(string, changeCount: 21)) { _, _ in
                Issue.record("a later copy must not be restored over")
                return false
            }
            #expect(outcome == .newerCopy)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func replacingTheBackupKeepsItPrivateAndUsesTheNewestSavedCopy() throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["old sentinel"], changeCount: 20)
            let empty = try JSONDecoder().decode(PasteboardOwner.Snapshot.self,
                from: Data("{\"items\":[],\"complete\":true,\"changeCount\":30}".utf8))
            try file.save(empty, sentinels: ["old sentinel", "new sentinel"], changeCount: 31)
            #expect(try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int == 0o600)
            let outcome = try file.recover(current: readable("new sentinel", changeCount: 32)) { copy, count in
                #expect(copy.checkString == nil)
                #expect(copy.changeCount == 30)
                #expect(count == 32)
                return true
            }
            #expect(outcome == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func discardsAPartialAtomicWriteOnTheNextStart() throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            let pending = file.url.deletingLastPathComponent().appendingPathComponent(".clipboard-pending")
            try Data("partial snapshot".utf8).write(to: pending)
            let outcome = try file.recover(current: readable("new copy", changeCount: 21)) { _, _ in
                Issue.record("a partial file must not authorize restoration")
                return false
            }
            #expect(outcome == .newerCopy)
            #expect(!FileManager.default.fileExists(atPath: pending.path))
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func keepsAnInvalidCrashFileAndStopsWithoutRestoring() throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            try Data("incomplete JSON".utf8).write(to: file.url)
            let outcome = try file.recover(current: readable("sentinel", changeCount: 20)) { _, _ in
                Issue.record("an invalid file must not authorize restoration")
                return false
            }
            #expect(outcome == .invalidBackup)
            #expect(outcome?.mayStartRun == false)
            #expect(FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func cleanupKeepsAFailedRestoreForRetryAtTheNextStart() throws {
        try withFile { file in
            let saved = try snapshot()
            try file.save(saved, sentinels: ["sentinel"], changeCount: 20)
            let outcome = try file.finish(saved, decision: .restore, changeCount: 23) { _, _ in false }
            #expect(outcome == .restoreFailed)
            #expect(!outcome.mayStartRun)
            #expect(FileManager.default.fileExists(atPath: file.url.path))
            let retried = try InsertionCheckClipboard.RecoveryFile(url: file.url)
                .recover(current: readable("sentinel", changeCount: 23)) { copy, _ in
                    try? expectEveryItemAndType(copy)
                    return true
                }
            #expect(retried == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test @MainActor
    func failedRestorationLeavingAnEmptyClipboardRetriesAtTheRecordedCount() async throws {
        try await withFile { file in
            let saved = try snapshot()
            try file.save(saved, sentinels: ["sentinel"], changeCount: 20)
            #expect(try file.finish(saved, decision: .restore, changeCount: 23) { _, _ in false } == .restoreFailed)
            let empty = try JSONDecoder().decode(PasteboardOwner.Snapshot.self,
                from: Data("{\"items\":[],\"complete\":true,\"changeCount\":24}".utf8))
            var restored: PasteboardOwner.Snapshot?
            let restore: (PasteboardOwner.Snapshot, Int) -> Bool = { copy, count in
                #expect(count == 24)
                restored = copy
                return true
            }
            let nextRun = InsertionCheckClipboard.RecoveryFile(url: file.url)
            let retried = try nextRun.recover(current: .copied(empty), restore: restore)
            try expectEveryItemAndType(#require(restored))
            #expect(retried == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test(arguments: [false, true])
    func ambiguousRecoveryKeepsTheCopy(partial: Bool) throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            let items = partial ? "[[{\"type\":\"public.utf8-plain-text\",\"data\":\"c2F2ZWQgY29weQ==\"}]]" : "[]"
            let current = try JSONDecoder().decode(PasteboardOwner.Snapshot.self,
                from: Data("{\"items\":\(items),\"complete\":true,\"changeCount\":24}".utf8))
            let outcome = try file.recover(current: .copied(current)) { _, _ in
                Issue.record("an ambiguous clipboard must not be overwritten")
                return false
            }
            #expect(outcome == .unreadable)
            #expect(outcome?.mayStartRun == false)
            #expect(FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func recoveringAnAlreadyRestoredWholeCopyRemovesTheBackupWithoutWriting() throws {
        try withFile { file in
            let saved = try snapshot()
            try file.save(saved, sentinels: ["sentinel"], changeCount: 20)
            let outcome = try file.recover(current: .copied(saved)) { _, _ in
                Issue.record("a complete restored copy does not need another write")
                return false
            }
            #expect(outcome == .restored)
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func aTransientPasteIsKeptForRecoveryAtTheNextStart() throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            let json = """
            {"items":[[{"type":"public.utf8-plain-text","data":"cGFzdGU="},
                       {"type":"org.nspasteboard.TransientType","data":""}]],"complete":true,"changeCount":24}
            """
            let current = try JSONDecoder().decode(PasteboardOwner.Snapshot.self, from: Data(json.utf8))
            let outcome = try file.recover(current: .copied(current)) { _, _ in
                Issue.record("a pending paste must not be overwritten")
                return false
            }
            #expect(outcome == .pastedText)
            #expect(outcome?.mayStartRun == false)
            #expect(FileManager.default.fileExists(atPath: file.url.path))
        }
    }

    @Test func keepsTheBackupAfterARestoreFails() throws {
        try withFile { file in
            try file.save(snapshot(), sentinels: ["sentinel"], changeCount: 20)
            let outcome = try file.recover(current: readable("sentinel", changeCount: 23)) { _, count in
                #expect(count == 23)
                // PasteboardOwner refuses if the count moved after the read.
                return false
            }
            #expect(outcome == .restoreFailed)
            #expect(outcome?.mayStartRun == false)
            #expect(FileManager.default.fileExists(atPath: file.url.path))
        }
    }
}
