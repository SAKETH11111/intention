import Foundation

/// When each first happened on this Mac, for the first-run timing report:
/// setup opened, signed in, both grants in, the first words on setup's
/// page, a mailbox connected, the first email written on setup's page,
/// setup finished, and the first dictation and the first email outside
/// setup, an email counting as a dictation too. Fixed names and times only,
/// written once each; no text, address or identity.
/// `scripts/first-run-report.sh` reads the file, and the app hands each new
/// mark to `reported`, which sends the same intervals to telemetry.
struct FirstRunRecord {
    enum Event: String, CaseIterable, Sendable {
        case setupOpened, signedIn, permissionsGranted, firstSetupDictation, mailboxConnected, firstSetupEmail,
             setupFinished, firstDictation, firstEmail
    }

    /// Notes that `event` happened now, if it has not happened before.
    var mark: @MainActor (Event) -> Void

    /// Where the app keeps the record: beside dictation history, in a
    /// folder only the person's account can open.
    static var defaultFile: URL? {
        let identifier = Bundle.main.bundleIdentifier ?? "co.intention.mac"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("first-run.json")
    }

    /// A record kept in `file`, read and written whole on each mark. Nil
    /// `file` keeps nothing, as in a render or a test that gives none.
    /// `reported` is called after each new mark has been saved, with every
    /// mark so far and the one just made; a repeat, or a mark already in
    /// `file` when it is read, calls nothing, so each event is reported at
    /// most once on this Mac. A mark whose save fails is kept and reported
    /// with the next mark that saves, with its own time, so a relaunch that
    /// reads the file never reports what was already reported. A quit in
    /// the moment between the save and the report loses that report; it is
    /// never made twice.
    @MainActor
    static func stored(at file: URL? = defaultFile, now: @escaping () -> Date = Date.init,
                       reported: @escaping @MainActor (_ marks: [Event: Date], _ event: Event) -> Void = { _, _ in })
        -> FirstRunRecord {
        let store = Store(file: file, now: now, reported: reported)
        return FirstRunRecord(mark: { store.mark($0) })
    }

    /// The marks in `file`, by event, for the report and the tests.
    static func read(_ file: URL) -> [Event: Date] {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var marks: [Event: Date] = [:]
        for (name, time) in raw {
            guard let event = Event(rawValue: name), let date = formatter.date(from: time) else { continue }
            marks[event] = date
        }
        return marks
    }

    @MainActor
    private final class Store {
        private let file: URL?
        private let now: () -> Date
        private let reported: @MainActor ([Event: Date], Event) -> Void
        private var marks: [Event: Date]
        /// Marks made since the last save that succeeded, in order, still
        /// to be reported once they are in the file.
        private var unreported: [Event] = []

        init(file: URL?, now: @escaping () -> Date, reported: @escaping @MainActor ([Event: Date], Event) -> Void) {
            self.file = file
            self.now = now
            self.reported = reported
            marks = file.map(FirstRunRecord.read) ?? [:]
        }

        func mark(_ event: Event) {
            guard marks[event] == nil else { return }
            marks[event] = now()
            unreported.append(event)
            guard write() else { return }
            let pending = unreported
            unreported = []
            for event in pending { reported(marks, event) }
        }

        /// Whether the marks are in the file; true with no file to keep.
        private func write() -> Bool {
            guard let file else { return true }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let raw = Dictionary(uniqueKeysWithValues: marks.map { ($0.key.rawValue, formatter.string(from: $0.value)) })
            guard let data = try? JSONEncoder().encode(raw) else { return false }
            let folder = file.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.write(to: file, options: [.atomic])
            } catch {
                return false
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        }
    }
}
