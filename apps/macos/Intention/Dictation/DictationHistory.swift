import Foundation

/// Every recent dictation, so no words are lost when insertion fails or
/// lands somewhere unexpected. The person opens it from the menu bar item to
/// copy text out.
///
/// Entries are kept in a file in a folder of the app's Application Support
/// folder that only the person's account can open, so they survive a relaunch or an
/// update. Each holds the finished text, or the transcript when the finished
/// text never came. Only the newest `limit` are kept. A separate daily tally
/// retains totals across trimming; Clear removes both files.
/// The audio of a dictation that never produced text stays in memory only,
/// with the start it was sent with, for Retry, until Intention quits or the
/// account changes. A separate background archive persists every finished
/// attempt and uploads it to the alpha account, including this audio.
@MainActor
@Observable
final class DictationHistory {
    static let limit = 100

    /// `day` encodes the local Gregorian date as UTC midnight, so a later
    /// timezone or calendar choice keeps it on the day it was recorded.
    /// Pace needs its own numerator because old entries have no duration.
    struct DailyTally: Codable {
        let day: Date
        var words = 0
        var speechSeconds = 0.0
        var pacedWords = 0
        var emailsWritten = 0
        /// Only retained rows need an identity here. Trimmed rows keep their
        /// aggregate totals, and their contribution records are discarded.
        struct Contribution: Codable, Equatable {
            let id: UUID
            let words: Int
            let speechSeconds: Double
            let pacedWords: Int
            let emailsWritten: Int
        }
        var contributions: [Contribution]? = []

        mutating func apply(_ contribution: Contribution, by change: Int) {
            words += contribution.words * change
            speechSeconds += contribution.speechSeconds * Double(change)
            pacedWords += contribution.pacedWords * change
            emailsWritten += contribution.emailsWritten * change
        }

        func date(in calendar: Calendar) -> Date? {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = gregorian.dateComponents([.year, .month, .day], from: day)
            gregorian.timeZone = calendar.timeZone
            return gregorian.date(from: components)
        }
    }

    struct Entry: Codable, Identifiable, Equatable, Sendable {
        enum Outcome: String, Codable, Sendable {
            /// The field shows the text.
            case inserted
            /// Nothing was written; `reason` says why.
            case notInserted
            /// A write was made and the field did not confirm it. The text
            /// may be there, or on the clipboard after a paste.
            case uncertain
            /// No text came back; `reason` says why. Retry while the audio
            /// is still in memory.
            case failed
        }

        /// What became of a reply draft Intention proposed when a reply opened.
        /// The names are saved in the history file and fixed.
        enum Proposal: String, Codable, Sendable {
            /// Put in with Tab or the card's button.
            case accepted
            /// Rewritten from what the person said while the card showed.
            case changed
            /// Ended any other way; the text is kept to read and copy.
            case unused

            /// The short word the history window shows beside the entry.
            var mark: String {
                switch self {
                case .accepted: "Draft"
                case .changed: "Draft, changed"
                case .unused: "Draft, not used"
                }
            }
        }

        let id: UUID
        let date: Date
        var text: String
        var outcome: Outcome
        /// A fixed name such as "focusChanged" or "unreachable".
        var reason: String?
        /// Started on setup's last page, even if it closes before the
        /// words arrive. Absent on every other dictation.
        var forSetup: Bool?
        /// A supported-language fallback reported by this dictation's endpoint.
        var languageNote: String?
        /// What the person said, when `text` is an email written from it,
        /// so their words are kept whether or not the email went in.
        var spoken: String?
        /// Set when `text` is a reply draft Intention proposed, or one rewritten
        /// from it; absent on every other entry, and on entries saved before
        /// proposals existed.
        var proposal: Proposal?
        /// The microphone a dictation that came back with no words recorded
        /// from, kept with it for this person to read here; absent on every
        /// other entry. Never logged; included in the private interaction archive.
        var device: String?
        /// Recorded PCM seconds, absent on entries predating duration tracking.
        var speechDuration: Double?
        /// The civil day used when this entry contributed to the tally.
        var tallyDay: Date?
        /// The immutable upload attempt, independent of a history row Retry replaces.
        var retentionID: UUID?

        var isConcealed: Bool {
            ["secureField", "targetUnresponsive", "earlierUnsettled", "earlierUnsettledNearby"].contains(reason ?? "")
        }

        func replacing(_ original: Entry) -> Entry {
            Entry(id: original.id, date: original.date, text: text, outcome: outcome, reason: reason,
                  forSetup: forSetup, languageNote: languageNote, spoken: spoken, proposal: proposal,
                  device: device ?? original.device, speechDuration: original.speechDuration ?? speechDuration, tallyDay: tallyDay, retentionID: retentionID ?? original.retentionID)
        }
    }

    static func languageNote(dropped: [String], selected: [String], locale: Locale = .current) -> String? {
        let dropped = Array(Set(dropped)).sorted()
        let used = (selected.isEmpty ? ["en"] : selected).filter { !dropped.contains($0) }
        guard !dropped.isEmpty, !used.isEmpty else { return nil }
        func names(_ codes: [String]) -> String {
            ListFormatter.localizedString(byJoining: codes.map { locale.localizedString(forLanguageCode: $0) ?? $0 })
        }
        let availability = dropped.count == 1 ? "isn't" : "aren't"
        let recognition = used.count == 1 ? "as" : "using"
        return "\(names(dropped)) \(availability) available on this server; this was heard \(recognition) \(names(used))."
    }

    /// What Retry needs: the audio and the start the dictation was sent with.
    struct Retry {
        let chunks: [Data]
        let start: DictationStart
    }

    private(set) var entries: [Entry] = []
    private(set) var dailyTally: [DailyTally] = []
    @ObservationIgnored private var tallyWriteAllowed = true
    @ObservationIgnored private var loading = false
    private var clearFailed = false
    /// A dictation was not inserted since the person last opened history.
    /// Kept as a marker file beside the history, so the notice survives a
    /// relaunch or an update.
    var needsAttention = false {
        didSet {
            guard !loading, needsAttention != oldValue, let marker else { return }
            if needsAttention {
                createFolder()
                FileManager.default.createFile(atPath: marker.path, contents: nil)
            } else {
                try? FileManager.default.removeItem(at: marker)
            }
        }
    }
    // Observable because Retry availability changes without changing the saved entries.
    private var retries: [UUID: Retry] = [:]
    /// The controller discards a pending or live retry before Clear touches the file.
    @ObservationIgnored var willClear: (() -> Void)?
    @ObservationIgnored private let removeFile: (URL) throws -> Void
    @ObservationIgnored private let timeZone: () -> TimeZone
    @ObservationIgnored private let file: URL?
    private var marker: URL? { file?.deletingLastPathComponent().appendingPathComponent("needs-attention") }
    private var tallyFile: URL? { file?.deletingLastPathComponent().appendingPathComponent("history-tally.json") }

    /// `file` nil keeps history in memory only, as tests do.
    init(file: URL? = DictationHistory.defaultFile, timeZone: @escaping () -> TimeZone = { .current },
         removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.removeFile = removeFile
        self.timeZone = timeZone
        self.file = file
        load()
    }

    /// Clear reloads without repairing files, so observing its result cannot
    /// recreate deleted data or change permissions after a failed listing.
    private func load(repair: Bool = true) {
        loading = true
        defer { loading = false }
        entries.removeAll()
        dailyTally.removeAll()
        tallyWriteAllowed = true
        let saved = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Self.mergingSavedRetries(saved)
        if let tallyFile, FileManager.default.fileExists(atPath: tallyFile.path) {
            if let data = try? Data(contentsOf: tallyFile),
               let tally = try? JSONDecoder().decode([DailyTally].self, from: data) {
                dailyTally = tally
            } else {
                AppLog.event("Dictation history tally could not be read")
                if repair {
                    let preserved = tallyFile.deletingLastPathComponent()
                        .appendingPathComponent("history-tally-unreadable-" + UUID().uuidString + ".json")
                    do {
                        try FileManager.default.moveItem(at: tallyFile, to: preserved)
                    } catch {
                        // Never overwrite bytes we could not preserve.
                        tallyWriteAllowed = false
                        AppLog.event("Dictation history unreadable tally could not be preserved")
                    }
                } else {
                    tallyWriteAllowed = false
                }
                for entry in entries { tally(entry, by: 1) }
                if repair { saveTally() }
            }
        } else {
            // Seed only a missing tally, after old retry pairs have merged.
            // Older entries already trimmed from history cannot be recovered.
            for entry in entries { tally(entry, by: 1) }
            if repair, !entries.isEmpty { saveTally() }
        }
        // Old entries have no stored bucket. Bind them to the current civil
        // day once; new entries persist their actual bucket across relaunches.
        for index in entries.indices where entries[index].tallyDay == nil {
            entries[index].tallyDay = day(for: entries[index].date)
        }
        let repaired = reconcileContributions()
        if repair {
            if entries != saved { save() }
            else if repaired { saveTally() }
        }
        needsAttention = marker.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static var defaultFile: URL? {
        let identifier = Bundle.main.bundleIdentifier ?? "co.intention.mac"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("Dictation", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    func add(_ entry: Entry, retry: Retry? = nil, shownBySetup: Bool = false) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            replace(entry, at: index)
        } else {
            var counted = entry
            counted.tallyDay = day(for: entry.date)
            entries.insert(counted, at: 0)
            tally(counted, by: 1)
        }
        retries[entry.id] = entry.outcome == .failed ? retry : nil
        // Origin alone does not mean setup showed the result: its window
        // may have closed while the dictation was finishing.
        let presented = shownBySetup && entry.forSetup == true && entry.outcome == .notInserted
        // A draft nobody asked for that was not used lost nothing the
        // person said, so it raises no notice.
        if entry.outcome != .inserted, !presented, entry.proposal != .unused { needsAttention = true }
        trim()
        save()
    }

    /// The newest words spoken on setup's last page, and when they were
    /// finished. Words meant for another app are never that page's, and a
    /// dictation that failed is not words, even when its transcript came.
    var setupWords: (text: String, at: Date)? {
        entries.first { $0.forSetup == true && $0.outcome != .failed && !$0.text.isEmpty }.map { ($0.text, $0.date) }
    }

    /// When the newest dictation made on setup's last page failed.
    var setupMiss: Date? {
        entries.first { $0.forSetup == true && $0.outcome == .failed }?.date
    }

    func update(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        replace(entry, at: index)
        if entry.outcome != .failed { retries[entry.id] = nil }
        save()
    }

    func copy(_ id: UUID, to clipboard: PasteboardOwner) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return clipboard.copy(entry.text, concealed: entry.isConcealed)
    }

    func retry(for id: UUID) -> Retry? { retries[id] }

    /// Drops every retry's audio, when the account changes: audio recorded
    /// for one account is never sent under another's grant.
    func forgetRetries() {
        retries.removeAll()
    }

    private func clearFiles() throws -> [URL] {
        guard let file else { return [] }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A history folder that has never been created holds nothing.
            return []
        }
        return files.filter {
            let name = $0.lastPathComponent
            return name == file.lastPathComponent || name == "history-tally.json" || name == "needs-attention" ||
                name.hasPrefix("history-tally-unreadable-") || name.hasPrefix("history-clear-")
        }
    }

    /// Leftover persisted data stays clearable even when no rows could load.
    /// An unlistable folder cannot prove that the person's data is gone.
    var canClear: Bool {
        !entries.isEmpty || !dailyTally.isEmpty || needsAttention || clearFailed ||
            (try? clearFiles().isEmpty) != true
    }

    /// Clear succeeds only when a checked listing proves all saved data gone.
    /// Rows and totals then describe the files left by the attempt.
    @discardableResult
    func clear() -> Bool {
        willClear?()
        forgetRetries()
        guard let file else {
            entries.removeAll()
            dailyTally.removeAll()
            needsAttention = false
            clearFailed = false
            return true
        }
        // Removal can race with another removal, or throw after deleting.
        // The on-disk result decides whether Clear succeeded.
        func removeChecked(_ path: URL) throws {
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            do {
                try removeFile(path)
            } catch {
                if FileManager.default.fileExists(atPath: path.path) { throw error }
            }
            if FileManager.default.fileExists(atPath: path.path) { throw CocoaError(.fileWriteUnknown) }
        }
        func priority(_ path: URL) -> Int {
            let name = path.lastPathComponent
            if name == "history-tally.json" { return 0 }
            if name.hasPrefix("history-tally-unreadable-") { return 1 }
            if name == file.lastPathComponent { return 2 }
            return 3
        }
        var listed = false
        do {
            let paths = try clearFiles().sorted {
                let left = priority($0), right = priority($1)
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }
            listed = true
            // Stop on a failed count deletion before touching history. Counts
            // must never outlive the history they came from after a partial Clear.
            for path in paths { try removeChecked(path) }
        } catch {
            AppLog.event("Dictation history could not be removed")
        }
        let empty = (try? clearFiles().isEmpty) == true
        clearFailed = !listed || !empty
        load(repair: false)
        return !clearFailed
    }

    private func replace(_ entry: Entry, at index: Int) {
        let original = entries[index]
        var replacement = entry.replacing(original)
        replacement.tallyDay = day(for: replacement.date)
        tally(original, by: -1)
        entries[index] = replacement
        tally(replacement, by: 1)
    }

    private func day(for date: Date) -> Date? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone()
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        return gregorian.date(from: components)
    }

    private func contribution(of entry: Entry) -> DailyTally.Contribution {
        let words = entry.proposal == .unused ? 0 : Self.wordCount(entry.text)
        let duration: Double
        if entry.proposal != .unused, let seconds = entry.speechDuration, seconds.isFinite, seconds > 0 {
            duration = seconds
        } else {
            duration = 0
        }
        let email = entry.proposal != .unused && entry.spoken != nil && entry.outcome != .failed &&
            !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return .init(id: entry.id, words: words, speechSeconds: duration,
                     pacedWords: duration > 0 ? words : 0, emailsWritten: email ? 1 : 0)
    }

    private func removeContribution(for id: UUID) {
        for index in dailyTally.indices {
            guard let contribution = dailyTally[index].contributions?.first(where: { $0.id == id }) else { continue }
            dailyTally[index].apply(contribution, by: -1)
            dailyTally[index].contributions?.removeAll { $0.id == id }
        }
    }

    private func tally(_ entry: Entry, by change: Int) {
        // Subtract only the contribution this tally actually holds. A failed
        // tally write may leave a saved row newer than its persisted counts.
        removeContribution(for: entry.id)
        guard change > 0, let day = entry.tallyDay ?? day(for: entry.date) else { return }
        let index: Int
        if let existing = dailyTally.firstIndex(where: { $0.day == day }) {
            index = existing
        } else {
            index = dailyTally.count
            dailyTally.append(DailyTally(day: day))
        }
        let contribution = contribution(of: entry)
        dailyTally[index].apply(contribution, by: 1)
        dailyTally[index].contributions = (dailyTally[index].contributions ?? []) + [contribution]
    }

    private func reconcileContributions() -> Bool {
        var changed = false
        // Legacy totals have no row identities. Preserve their excess over
        // retained rows, and raise each total to at least those rows' sum.
        // Exact reconciliation becomes possible once identities are saved.
        for index in dailyTally.indices where dailyTally[index].contributions == nil {
            let retained = entries.filter { ($0.tallyDay ?? day(for: $0.date)) == dailyTally[index].day }
                .map { contribution(of: $0) }
            dailyTally[index].words = max(dailyTally[index].words, retained.reduce(0) { $0 + $1.words })
            dailyTally[index].speechSeconds = max(dailyTally[index].speechSeconds, retained.reduce(0) { $0 + $1.speechSeconds })
            dailyTally[index].pacedWords = max(dailyTally[index].pacedWords, retained.reduce(0) { $0 + $1.pacedWords })
            dailyTally[index].emailsWritten = max(dailyTally[index].emailsWritten, retained.reduce(0) { $0 + $1.emailsWritten })
            dailyTally[index].contributions = retained
            changed = true
        }
        for entry in entries {
            let day = entry.tallyDay ?? day(for: entry.date)
            let countedDay = dailyTally.first { $0.contributions?.contains(where: { $0.id == entry.id }) == true }
            let counted = countedDay?.contributions?.first { $0.id == entry.id }
            if countedDay?.day != day || counted != contribution(of: entry) {
                tally(entry, by: 1)
                changed = true
            }
        }
        return changed
    }

    /// Earlier files have no source id linking different-id rows. Only merge
    /// a same-id recovery when its predecessor contains no distinct words.
    /// Ambiguous text stays as a separate row with its own stable saved id.
    private static func mergingSavedRetries(_ saved: [Entry]) -> [Entry] {
        var merged: [Entry] = []
        for entry in saved {
            guard let index = merged.firstIndex(where: { $0.id == entry.id }) else {
                merged.append(entry)
                continue
            }
            let newer = merged[index]
            if newer.reason == "retried", entry.outcome == .failed,
               entry.text.isEmpty || entry.text == newer.text,
               entry.spoken == nil || entry.spoken == "" || entry.spoken == newer.spoken {
                merged[index] = newer.replacing(entry)
            } else {
                merged.append(Entry(id: UUID(), date: entry.date, text: entry.text, outcome: entry.outcome,
                                    reason: entry.reason, forSetup: entry.forSetup, languageNote: entry.languageNote,
                                    spoken: entry.spoken, proposal: entry.proposal, device: entry.device,
                                    speechDuration: entry.speechDuration, tallyDay: entry.tallyDay))
            }
        }
        return merged
    }

    private func trim() {
        guard entries.count > Self.limit else { return }
        for entry in entries[Self.limit...] {
            retries[entry.id] = nil
            for index in dailyTally.indices {
                dailyTally[index].contributions?.removeAll { $0.id == entry.id }
            }
        }
        entries.removeLast(entries.count - Self.limit)
    }

    /// The folder, not the files, keeps other accounts out: an atomic write
    /// replaces the file with one made under the default permissions.
    private func createFolder() {
        guard let folder = file?.deletingLastPathComponent() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(entries) else { return }
        createFolder()
        guard (try? data.write(to: file, options: .atomic)) != nil else {
            AppLog.event("Dictation history could not be saved")
            return
        }
        // Persist rows first so a failed tally write can be repaired from them.
        saveTally()
    }

    private func saveTally() {
        let retained = Set(entries.map(\.id))
        for index in dailyTally.indices {
            dailyTally[index].contributions?.removeAll { !retained.contains($0.id) }
            dailyTally[index].contributions?.sort { $0.id.uuidString < $1.id.uuidString }
        }
        guard tallyWriteAllowed, let tallyFile, let data = try? JSONEncoder().encode(dailyTally.sorted { $0.day < $1.day }) else { return }
        createFolder()
        guard (try? data.write(to: tallyFile, options: .atomic)) != nil else {
            AppLog.event("Dictation history tally could not be saved")
            return
        }
    }
}
