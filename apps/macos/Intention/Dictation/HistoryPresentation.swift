import Foundation

/// Text here is safe to display. Copy resolves the original entry by id and
/// keeps the clipboard's concealment flag; hidden words never enter search.
struct HistoryRow: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let kind: Kind
    let state: State
    let reason: String?
    let languageNote: String?
    let canRetry: Bool
    let isConcealed: Bool

    enum Kind: Equatable {
        case dictation
        case email(spoken: String?)
        case proposal
    }

    enum State: Equatable {
        case inserted
        case uncertain
        case didNotGoIn
        case heardNothing(device: String?)
        case failed
    }
}

struct HistorySection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [HistoryRow]
}

struct HistoryStats: Equatable {
    let wordsThisWeek: Int
    let wordsPerMinute: Int?
    let emailsWritten: Int
}

extension DictationHistory {
    var isEmpty: Bool { entries.allSatisfy { $0.proposal == .unused } }

    func sections(matching search: String, now: Date, calendar: Calendar) -> [HistorySection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = entries.filter { entry in
            guard entry.proposal != .unused else { return false }
            guard !query.isEmpty else { return true }
            guard !entry.isConcealed else { return false }
            return [entry.text, entry.spoken ?? ""].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                         locale: calendar.locale ?? .current) != nil
            }
        }.map { entry in
            let kind: HistoryRow.Kind
            if entry.proposal != nil {
                kind = .proposal
            } else if entry.spoken != nil {
                kind = .email(spoken: entry.isConcealed ? nil : entry.spoken)
            } else {
                kind = .dictation
            }
            let state: HistoryRow.State
            if entry.outcome == .inserted {
                state = .inserted
            } else if entry.outcome == .uncertain {
                state = .uncertain
            } else if entry.outcome == .failed, entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = entry.reason == "noWords" ? .heardNothing(device: entry.device) : .failed
            } else {
                state = .didNotGoIn
            }
            return HistoryRow(id: entry.id, date: entry.date, text: entry.isConcealed ? "" : entry.text,
                              kind: kind, state: state, reason: state == .didNotGoIn || state == .uncertain || state == .failed ? entry.reasonSentence : nil, languageNote: entry.languageNote,
                              canRetry: retry(for: entry.id) != nil, isConcealed: entry.isConcealed)
        }.sorted { $0.date > $1.date }
        let groups = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        return groups.keys.sorted(by: >).map { day in
            let title: String
            if day == today { title = "Today" }
            else if day == yesterday { title = "Yesterday" }
            else {
                formatter.dateFormat = calendar.component(.year, from: day) == calendar.component(.year, from: now)
                    ? "EEEE, MMMM d" : "EEEE, MMMM d, yyyy"
                title = formatter.string(from: day)
            }
            return HistorySection(id: String(day.timeIntervalSince1970), title: title, rows: groups[day] ?? [])
        }
    }

    /// Daily totals survive history trimming. Durations are
    /// never inferred for old entries, and a retry reuses the original one.
    func stats(now: Date, calendar: Calendar) -> HistoryStats {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let wordsThisWeek = dailyTally.filter { tally in
            guard let week, let day = tally.date(in: calendar) else { return false }
            return day >= week.start && day < week.end
        }.reduce(0) { $0 + $1.words }
        let seconds = dailyTally.reduce(0.0) { $0 + $1.speechSeconds }
        let words = dailyTally.reduce(0) { $0 + $1.pacedWords }
        let rate = seconds > 0 ? (Double(words) / seconds * 60).rounded() : nil
        let wordsPerMinute = rate.flatMap { Int(exactly: $0) }
        let emailsWritten = dailyTally.reduce(0) { $0 + $1.emailsWritten }
        return HistoryStats(wordsThisWeek: wordsThisWeek, wordsPerMinute: wordsPerMinute, emailsWritten: emailsWritten)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}

extension DictationHistory.Entry {
    /// The old history wording, expressed as tooltip sentences rather than
    /// row status labels. Fixed reason names stay in the persisted entry.
    var reasonSentence: String? {
        switch outcome {
        case .inserted:
            return nil
        case .uncertain:
            return "May have gone in. Check before pasting again."
        case .notInserted:
            return switch reason {
            case "retried": "The recovered text is ready to copy."
            case "focusChanged", "fieldChanged", "composeChanged": "The text box changed while Intention was typing."
            case "appEnded": "The app quit."
            case "noTextField": "Click in the message body, then try again. Your text is here to copy."
            case "secureField": "Intention does not insert into password fields."
            case "ownApp": "Intention does not insert into its own window."
            case "targetUnresponsive", "busy": "The app did not respond."
            case "permissionMissing": "Accessibility is not allowed."
            case "clipboardBusy": "The clipboard changed while Intention was pasting."
            case "pasteUnavailable": "Intention could not use the clipboard."
            case "earlierUnsettled":
                "Your last dictation into this field didn't show, so Intention won't type there. Copy this and paste it yourself, or dictate into another field."
            case "earlierUnsettledNearby": "Your last dictation in this window could still appear. Dictate again in a few seconds."
            case "cancelled": "It was cancelled before it went in."
            default: "The text could not be inserted."
            }
        case .failed:
            return switch reason {
            case "noWords": device.map { "Heard no words from \($0)." } ?? "Heard no words."
            case "unauthorized": "The dictation server refused this copy of Intention."
            case "timedOut": "The dictation server did not answer in time."
            case "unreachable": "Could not reach the dictation server."
            case "refused.language_unsupported": "The dictation server supports none of your selected languages."
            default: "The dictation server could not finish it."
            }
        }
    }
}
