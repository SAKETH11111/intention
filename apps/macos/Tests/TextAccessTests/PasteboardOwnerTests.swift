import AppKit
@testable import Intention
import Testing

/// Has a second process copy "copied meanwhile" to the private pasteboard
/// named `name`, as plain text, HTML and a custom type. Its clearing takes
/// the clipboard from this process as another app's does.
@discardableResult
private func anotherProcessCopies(to name: NSPasteboard.Name) -> Bool {
    guard name.rawValue.hasPrefix("co.intention.tests.") else {
        Issue.record("another process copies only to a test's private pasteboard")
        return false
    }
    let script = """
    ObjC.import('AppKit');
    var pasteboard = $.NSPasteboard.pasteboardWithName('\(name.rawValue)');
    pasteboard.clearContents;
    var item = $.NSPasteboardItem.alloc.init;
    item.setStringForType('copied meanwhile', 'public.utf8-plain-text');
    item.setStringForType('<i>copied meanwhile</i>', 'public.html');
    item.setStringForType('custom data', 'co.intention.tests.custom');
    pasteboard.writeObjects($([item])) ? 'copied' : 'not copied';
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", script]
    let output = Pipe()
    process.standardOutput = output
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        Issue.record("the other process did not start: \(error)")
        return false
    }
    // A stalled pasteboard service or interpreter fails the test instead of
    // holding up the suite.
    guard finished.wait(timeout: .now() + .seconds(10)) == .success else {
        process.terminate()
        Issue.record("the other process did not finish within ten seconds")
        return false
    }
    let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, said == "copied" else {
        Issue.record("the other process did not copy: exit \(process.terminationStatus), said \(said)")
        return false
    }
    return true
}

/// Runs against a private pasteboard, never the person's clipboard.
@MainActor
struct PasteboardOwnerTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
    private let custom = NSPasteboard.PasteboardType("co.intention.tests.custom")

    private func fill() {
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("<b>second</b>", forType: .html)
        pasteboard.writeObjects([first, second])
    }

    private func written(_ write: PasteboardOwner.Write) throws -> Int {
        guard case let .written(changeCount) = write else { throw EditReason.pasteUnavailable }
        return changeCount
    }

    @Test func restoresEveryItemAndTypeAfterABorrowedWrite() async throws {
        defer { pasteboard.releaseGlobally() }
        fill()
        let owner = PasteboardOwner(pasteboard: pasteboard)
        let snapshot = try #require(await owner.backUp().snapshot)
        #expect(snapshot.complete)
        let changeCount = try written(owner.writeTransient("Synthetic insertion", ifUnchangedSince: snapshot.changeCount))
        #expect(pasteboard.string(forType: .string) == "Synthetic insertion")
        #expect(owner.restore(snapshot, ifUnchangedSince: changeCount))
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "first")
        #expect(items.first?.data(forType: custom) == Data([1, 2, 3]))
        #expect(items.last?.string(forType: .html) == "<b>second</b>")
    }

    @Test func readsNothingWhenMacOSWouldAsk() async {
        defer { pasteboard.releaseGlobally() }
        fill()
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { false })
        #expect(!owner.mayReadOtherApps)
        guard case .notAllowed = await owner.backUp() else {
            Issue.record("expected no copy")
            return
        }
    }

    @Test func aCopyMadeAfterTheBackupIsNeverOverwritten() async throws {
        defer { pasteboard.releaseGlobally() }
        fill()
        let owner = PasteboardOwner(pasteboard: pasteboard)
        let snapshot = try #require(await owner.backUp().snapshot)
        // The person copies something before Intention writes.
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        #expect(owner.writeTransient("Synthetic insertion", ifUnchangedSince: snapshot.changeCount) == .changed)
        #expect(pasteboard.string(forType: .string) == "copied meanwhile")
    }

    @Test func marksItsTextSoClipboardManagersSkipIt() throws {
        defer { pasteboard.releaseGlobally() }
        let owner = PasteboardOwner(pasteboard: pasteboard)
        _ = try written(owner.writeTransient("Synthetic insertion", ifUnchangedSince: nil))
        let types = pasteboard.pasteboardItems?.first?.types ?? []
        for type in PasteboardOwner.transientTypes {
            #expect(types.contains(type))
        }
    }

    @Test func leavesALaterCopyAlone() async throws {
        defer { pasteboard.releaseGlobally() }
        fill()
        let owner = PasteboardOwner(pasteboard: pasteboard)
        let snapshot = try #require(await owner.backUp().snapshot)
        let changeCount = try written(owner.writeTransient("Synthetic insertion", ifUnchangedSince: snapshot.changeCount))
        // The person copies something before the paste settles.
        pasteboard.clearContents()
        pasteboard.setString("copied later", forType: .string)
        #expect(!owner.restore(snapshot, ifUnchangedSince: changeCount))
        #expect(pasteboard.string(forType: .string) == "copied later")
    }

    @Test func tellsOffTheMainThreadWhetherItsWriteIsStillThere() async throws {
        defer { pasteboard.releaseGlobally() }
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { false })
        let changeCount = try written(owner.writeTransient("Synthetic insertion", ifUnchangedSince: nil))
        let stillHolds = owner.stillHolds(changeCount)
        #expect(await Task.detached { stillHolds() }.value)
        // The person copies something before the paste key.
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        #expect(await !Task.detached { stillHolds() }.value)
        #expect(pasteboard.string(forType: .string) == "copied meanwhile")
    }

    @Test func aFailedWriteIsPutBackOverItsOwnClearing() async throws {
        defer { pasteboard.releaseGlobally() }
        fill()
        let owner = PasteboardOwner(pasteboard: pasteboard, put: { _, _ in false })
        let snapshot = try #require(await owner.backUp().snapshot)
        #expect(owner.writeTransient("Synthetic insertion", ifUnchangedSince: snapshot.changeCount) == .failed)
        // Intention cleared the clipboard and wrote nothing.
        #expect(pasteboard.pasteboardItems?.isEmpty != false)
        let cleared = pasteboard.changeCount
        owner.putBack(snapshot)
        // Back without another clearing, every item and type.
        #expect(pasteboard.changeCount == cleared)
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "first")
        #expect(items.first?.data(forType: custom) == Data([1, 2, 3]))
        #expect(items.last?.string(forType: .html) == "<b>second</b>")
    }

    @Test func aCopyAnotherAppMadeAsTheWriteFailedIsNotOverwritten() async throws {
        defer { pasteboard.releaseGlobally() }
        fill()
        // Another app copies between Intention's clearing and its write, which
        // then fails as a write after another app's clearing does. A second
        // process plays that app, since this one owns every clearing it makes.
        let owner = PasteboardOwner(pasteboard: pasteboard, put: { pasteboard, item in
            anotherProcessCopies(to: pasteboard.name)
            return pasteboard.writeObjects([item])
        })
        let snapshot = try #require(await owner.backUp().snapshot)
        #expect(owner.writeTransient("Synthetic insertion", ifUnchangedSince: snapshot.changeCount) == .failed)
        owner.putBack(snapshot)
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 1)
        #expect(items.first?.string(forType: .string) == "copied meanwhile")
        #expect(items.first?.string(forType: .html) == "<i>copied meanwhile</i>")
        #expect(items.first?.data(forType: custom) == Data("custom data".utf8))
    }

    @Test func aClearingMovesTheCountByOneAndItsWriteDoesNot() throws {
        defer { pasteboard.releaseGlobally() }
        // A new pasteboard starts at zero. Clearing moves the count by one,
        // and writing one item with three types does not move it.
        #expect(pasteboard.changeCount == 0)
        let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { false })
        #expect(owner.writeTransient("Synthetic insertion", ifUnchangedSince: nil) == .written(1))
        #expect(pasteboard.changeCount == 1)
        #expect(pasteboard.pasteboardItems?.first?.types.count == 3)
        #expect(owner.writeTransient("Synthetic insertion", ifUnchangedSince: 1) == .written(2))
    }

    @Test func aCopyMadeInsideItsWriteIsNotTakenForItsOwn() async throws {
        defer { pasteboard.releaseGlobally() }
        for readable in [true, false] {
            fill()
            // Another app copies after Intention's item is written and before
            // Intention reads the count again.
            let owner = PasteboardOwner(pasteboard: pasteboard, mayRead: { readable }, put: { pasteboard, item in
                let wrote = pasteboard.writeObjects([item])
                pasteboard.clearContents()
                let other = NSPasteboardItem()
                other.setString("copied meanwhile", forType: .string)
                other.setString("<i>copied meanwhile</i>", forType: .html)
                other.setData(Data("custom data".utf8), forType: custom)
                pasteboard.writeObjects([other])
                return wrote
            })
            let snapshot = await owner.backUp().snapshot
            #expect((snapshot != nil) == readable)
            #expect(owner.writeTransient("Synthetic insertion", ifUnchangedSince: snapshot?.changeCount) == .changed)
            let items = pasteboard.pasteboardItems ?? []
            #expect(items.count == 1)
            #expect(items.first?.string(forType: .string) == "copied meanwhile")
            #expect(items.first?.string(forType: .html) == "<i>copied meanwhile</i>")
            #expect(items.first?.data(forType: custom) == Data("custom data".utf8))
        }
    }

    @Test func restoresAnEmptyClipboardAsEmpty() async throws {
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let owner = PasteboardOwner(pasteboard: pasteboard)
        let snapshot = try #require(await owner.backUp().snapshot)
        let changeCount = try written(owner.writeTransient("Synthetic insertion", ifUnchangedSince: snapshot.changeCount))
        #expect(owner.restore(snapshot, ifUnchangedSince: changeCount))
        #expect((pasteboard.pasteboardItems ?? []).isEmpty)
    }
}
