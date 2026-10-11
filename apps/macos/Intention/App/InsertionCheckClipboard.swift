#if DEBUG
import Foundation
import Darwin

/// Clipboard cleanup for the Debug checks, separate from the inserter's borrow.
enum InsertionCheckClipboard {
    enum Decision: Equatable {
        case restore
        case pastedText
        case newerCopy
        case unreadable
    }

    static func cleanupDecision(string: String?, sentinels: Set<String>, pastedStrings: Set<String>) -> Decision {
        guard let string else { return .unreadable }
        if sentinels.contains(string) { return .restore }
        if pastedStrings.contains(string) { return .pastedText }
        return .newerCopy
    }

    @MainActor
    static func cleanUp(_ saved: PasteboardOwner.Snapshot, file: RecoveryFile, inserters: [TextInserter],
                        sentinels: Set<String>, pastedStrings: Set<String>,
                        timeout: Duration = TextInserter.lateReadWindow + .seconds(1),
                        read: () async -> PasteboardOwner.Backup,
                        restore: (PasteboardOwner.Snapshot, Int) -> Bool) async throws -> Outcome {
        guard await waitForClipboardReturns(inserters, timeout: timeout) else { return .restorationPending }
        guard let current = await read().snapshot, current.complete else { return .unreadable }
        if current.checkMatches(saved) {
            try file.discard()
            return .restored
        }
        let decision = cleanupDecision(string: current.checkString, sentinels: sentinels, pastedStrings: pastedStrings)
        if decision == .newerCopy {
            // A failed restore can leave only the saved plain text, missing
            // other items or types. That is no proof of a later copy.
            guard current.changeCount != saved.changeCount,
                  current.checkString != saved.checkString else { return .unreadable }
            if current.checkIsTransient { return .pastedText }
        }
        return try file.finish(saved, decision: decision, changeCount: current.changeCount, restore: restore)
    }

    @MainActor
    private static func waitForClipboardReturns(_ inserters: [TextInserter], timeout: Duration) async -> Bool {
        // Yield on the main actor so the inserters' late return tasks can
        // finish. Cancellation or a deadline keeps the durable copy intact.
        let deadline = ContinuousClock.now + timeout
        while inserters.contains(where: { $0.clipboardRestorationPending }) {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }
        return !Task.isCancelled
    }

    enum Outcome: Equatable {
        case restored
        case pastedText
        case newerCopy
        case restoreFailed
        case invalidBackup
        case unreadable
        case restorationPending

        /// A retained copy must be resolved before any scene can borrow again.
        var mayStartRun: Bool { self == .restored || self == .newerCopy }
    }

    /// The saved copy and its file identity belong to the whole check run.
    @MainActor
    final class Run {
        private(set) var saved: PasteboardOwner.Snapshot?
        private var snapshotID: UUID?
        private var preparedSentinels: Set<String> = []
        private(set) var stopped = false
        private(set) var pasteUnconfirmed = false
        let file: RecoveryFile

        init(file: RecoveryFile) { self.file = file }

        func stopBorrowing() { stopped = true }

        func recordInsertion(_ result: InsertionResult?, with inserter: TextInserter) {
            if case .unknown = result, inserter.clipboardRestorationPending { pasteUnconfirmed = true }
        }

        func mayPrepareSentinel(inserters: [TextInserter],
                                timeout: Duration = TextInserter.lateReadWindow + .seconds(1)) async -> Bool {
            guard !stopped else { return false }
            guard await InsertionCheckClipboard.waitForClipboardReturns(inserters, timeout: timeout) else {
                stopped = true
                return false
            }
            // Even a refused next case waits before reading or saving the
            // clipboard, including a borrow made by the app's dictation path.
            return !pasteUnconfirmed && !stopped
        }

        func prepareSentinel(current: PasteboardOwner.Snapshot, ownsCurrent: Bool, sentinels: Set<String>,
                             currentChangeCount: () -> Int) async throws -> Bool {
            guard !stopped, current.complete, currentChangeCount() == current.changeCount else { return false }
            let sentinels = sentinels.union(preparedSentinels)
            let replacingSnapshot = saved == nil || !ownsCurrent
            if replacingSnapshot { saved = current }
            guard let saved else { return false }
            do {
                snapshotID = try await file.prepareSentinel(saved, replacingSnapshot: replacingSnapshot,
                    snapshotID: snapshotID, sentinels: sentinels, changeCount: current.changeCount)
                guard currentChangeCount() == current.changeCount else {
                    stopped = true
                    // This sentinel was not placed. A count change can be
                    // an earlier inserter returning one of our old sentinels.
                    try await file.abortSentinel(snapshotID: snapshotID, sentinels: preparedSentinels,
                                                 changeCount: current.changeCount)
                    return false
                }
                preparedSentinels = sentinels
                return true
            } catch {
                stopped = true
                throw error
            }
        }

        func restoreFailedSentinel(changeCount: Int,
                                   restore: (PasteboardOwner.Snapshot, Int) -> Bool) throws -> Outcome? {
            guard !stopped, let saved else { return nil }
            // Freeze the run before restoration. A failure, including a file
            // error, leaves the only original copy for the next launch.
            stopped = true
            let outcome = try file.finish(saved, decision: .restore, changeCount: changeCount, restore: restore)
            if outcome.mayStartRun {
                self.saved = nil
                snapshotID = nil
                preparedSentinels.removeAll()
                stopped = false
            }
            return outcome
        }

        func cleanUp(inserters: [TextInserter], sentinels: Set<String>, pastedStrings: Set<String>,
                     read: () async -> PasteboardOwner.Backup,
                     restore: (PasteboardOwner.Snapshot, Int) -> Bool) async throws -> Outcome? {
            guard !stopped, let saved else { return nil }
            stopped = true
            return try await InsertionCheckClipboard.cleanUp(saved, file: file, inserters: inserters,
                sentinels: sentinels, pastedStrings: pastedStrings, read: read, restore: restore)
        }
    }

    struct RecoveryFile: Sendable {
        let url: URL
        private var temporary: URL { url.deletingLastPathComponent().appendingPathComponent(".clipboard-pending") }
        var stateURL: URL { url.deletingLastPathComponent().appendingPathComponent("clipboard-state.json") }
        private var stateTemporary: URL { url.deletingLastPathComponent().appendingPathComponent(".clipboard-state-pending") }

        static var defaultURL: URL {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let identifier = Bundle.main.bundleIdentifier ?? "co.intention.mac"
            return support.appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("InsertionChecks", isDirectory: true)
                .appendingPathComponent("clipboard.json")
        }

        struct Record: Codable {
            let snapshot: PasteboardOwner.Snapshot
            let sentinels: Set<String>
            let changeCount: Int
            // Optional fields retain recovery compatibility with older checks.
            let snapshotID: UUID?
            let expectedSentinelChangeCount: Int?
        }

        struct SentinelRecord: Codable {
            let snapshotID: UUID?
            let sentinels: Set<String>
            let changeCount: Int
            let expectedSentinelChangeCount: Int?
            let sentinelWriteAborted: Bool?
            var expectedRestoreChangeCount: Int? = nil
        }

        /// Save before changing the clipboard, including a sentinel before
        /// placing it. Atomic replacement leaves the last full copy intact
        /// if a write fails. The temporary file is private from its creation.
        @discardableResult
        func save(_ snapshot: PasteboardOwner.Snapshot, sentinels: Set<String>, changeCount: Int,
                  expectedSentinelChangeCount: Int? = nil) throws -> UUID {
            let id = UUID()
            let record = Record(snapshot: snapshot, sentinels: sentinels, changeCount: changeCount,
                                snapshotID: id, expectedSentinelChangeCount: expectedSentinelChangeCount)
            // An old small record must never describe the replacement snapshot.
            for file in [stateURL, stateTemporary] where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            try write(try JSONEncoder().encode(record), to: url, temporary: temporary)
            return id
        }

        private func write(_ data: Data, to target: URL, temporary: URL) throws {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        /// The payload is encoded and written only when the person's saved
        /// copy changes. Later cases write just the small sentinel record.
        /// File work runs off the main actor; the caller must recheck the
        /// clipboard count after this returns and before clearing it.
        func prepareSentinel(_ snapshot: PasteboardOwner.Snapshot, replacingSnapshot: Bool, snapshotID: UUID?,
                             sentinels: Set<String>, changeCount: Int) async throws -> UUID {
            try await Task.detached(priority: .utility) {
                let (expected, overflow) = changeCount.addingReportingOverflow(1)
                guard !overflow else { throw POSIXError(.EOVERFLOW) }
                let id: UUID
                if replacingSnapshot {
                    id = try save(snapshot, sentinels: sentinels, changeCount: changeCount,
                                  expectedSentinelChangeCount: expected)
                } else {
                    guard let snapshotID else { throw POSIXError(.EINVAL) }
                    id = snapshotID
                }
                let state = SentinelRecord(snapshotID: id, sentinels: sentinels, changeCount: changeCount,
                                           expectedSentinelChangeCount: expected, sentinelWriteAborted: nil)
                try write(try JSONEncoder().encode(state), to: stateURL, temporary: stateTemporary)
                return id
            }.value
        }

        func abortSentinel(snapshotID: UUID?, sentinels: Set<String>, changeCount: Int) async throws {
            guard let snapshotID else { throw POSIXError(.EINVAL) }
            try await Task.detached(priority: .utility) {
                let state = SentinelRecord(snapshotID: snapshotID, sentinels: sentinels, changeCount: changeCount,
                                           expectedSentinelChangeCount: nil, sentinelWriteAborted: true)
                try write(try JSONEncoder().encode(state), to: stateURL, temporary: stateTemporary)
            }.value
        }

        func finish(_ snapshot: PasteboardOwner.Snapshot, decision: Decision, changeCount: Int,
                    restore: (PasteboardOwner.Snapshot, Int) -> Bool) throws -> Outcome {
            let outcome: Outcome
            switch decision {
            case .restore:
                try beginRestoration(changeCount: changeCount)
                outcome = restore(snapshot, changeCount) ? .restored : .restoreFailed
            case .pastedText: outcome = .pastedText
            case .newerCopy: outcome = .newerCopy
            case .unreadable: outcome = .unreadable
            }
            // Pasted text, failed writes and unknown ownership still need
            // the durable copy. Only a complete restore or a proven later
            // copy makes it safe to delete.
            if outcome.mayStartRun { try discard() }
            return outcome
        }

        private func beginRestoration(changeCount: Int) throws {
            let snapshotID: UUID?
            let sentinels: Set<String>
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let state = try JSONDecoder().decode(SentinelRecord.self, from: Data(contentsOf: stateURL))
                snapshotID = state.snapshotID
                sentinels = state.sentinels
            } else {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
                snapshotID = record.snapshotID
                sentinels = record.sentinels
            }
            let (expected, overflow) = changeCount.addingReportingOverflow(1)
            guard !overflow else { throw POSIXError(.EOVERFLOW) }
            // Persist ownership before restore clears the clipboard. An
            // aborted sentinel write no longer describes this restore, and
            // the original payload stays intact through every retry.
            let state = SentinelRecord(snapshotID: snapshotID, sentinels: sentinels,
                changeCount: changeCount, expectedSentinelChangeCount: nil,
                sentinelWriteAborted: nil, expectedRestoreChangeCount: expected)
            try write(try JSONEncoder().encode(state), to: stateURL, temporary: stateTemporary)
        }

        func recover(current: PasteboardOwner.Backup,
                     restore: (PasteboardOwner.Snapshot, Int) -> Bool) throws -> Outcome? {
            // A crash during the atomic write can leave the temporary file.
            // The clipboard is not changed until save returns, so only the
            // last complete record is needed for recovery.
            for file in [temporary, stateTemporary] where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let record: Record
            do {
                record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
            } catch {
                return .invalidBackup
            }
            guard record.snapshot.complete else { return .invalidBackup }
            let sentinels: Set<String>
            let changeCount: Int
            let expectedSentinelChangeCount: Int?
            let sentinelWriteAborted: Bool
            let expectedRestoreChangeCount: Int?
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let state: SentinelRecord
                do { state = try JSONDecoder().decode(SentinelRecord.self, from: Data(contentsOf: stateURL)) }
                catch { return .invalidBackup }
                guard state.snapshotID == record.snapshotID else { return .invalidBackup }
                sentinels = state.sentinels
                changeCount = state.changeCount
                expectedSentinelChangeCount = state.expectedSentinelChangeCount
                sentinelWriteAborted = state.sentinelWriteAborted == true
                expectedRestoreChangeCount = state.expectedRestoreChangeCount
            } else {
                // A crash before the first small record was written leaves
                // the initial snapshot's metadata, including the pending clear.
                sentinels = record.sentinels
                changeCount = record.changeCount
                expectedSentinelChangeCount = record.expectedSentinelChangeCount
                sentinelWriteAborted = false
                expectedRestoreChangeCount = nil
            }
            guard let current = current.snapshot, current.complete else { return .unreadable }
            // A crash may happen after a successful write but before deletion.
            // Verify every item and type before calling that restoration done.
            if current.checkMatches(record.snapshot) {
                try discard()
                return .restored
            }
            let ownSentinel = current.checkString.map { sentinels.contains($0) } ?? false
            if ownSentinel {
                return try finish(record.snapshot, decision: .restore, changeCount: current.changeCount, restore: restore)
            }
            if sentinelWriteAborted {
                // Only earlier sentinels remain ours after an aborted write.
                // A newer clear or the unplaced sentinel grants no ownership.
                return try finish(record.snapshot, decision: .newerCopy, changeCount: current.changeCount, restore: restore)
            }
            let interruptedSentinel = current.checkIsEmpty && current.changeCount == expectedSentinelChangeCount
            let interruptedRestore = current.changeCount == expectedRestoreChangeCount
                && (current.checkIsEmpty || (current.checkString != nil && current.checkString == record.snapshot.checkString))
            if current.changeCount == changeCount || interruptedSentinel || interruptedRestore {
                return try finish(record.snapshot, decision: .restore, changeCount: current.changeCount, restore: restore)
            }
            // Empty or non-text contents, or only the saved plain text, can
            // be an incomplete restore. Keep the copy until ownership is clear.
            guard let string = current.checkString, string != record.snapshot.checkString else { return .unreadable }
            // The process can crash while a paste still holds transient text.
            // Such text is not evidence that the person made a later copy.
            if current.checkIsTransient { return .pastedText }
            return try finish(record.snapshot, decision: .newerCopy, changeCount: current.changeCount, restore: restore)
        }

        func discard() throws {
            for file in [url, stateURL, temporary, stateTemporary] where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
#endif
