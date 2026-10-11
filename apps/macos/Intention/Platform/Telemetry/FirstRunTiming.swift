import Foundation

/// What one first-run report sends to `Telemetry.record`, built from the
/// marks of `FirstRunRecord` at the moment one of them lands. Event names
/// and times only; no text, address or identity is held here.
///
/// Three marks report, each once, since the record notes each first once:
/// setup finished sends a "setup" report from setup opened to setup
/// finished, with a step per interval between the marks of setup in order,
/// skipping those that never happened; the first dictation and the first
/// email outside setup each send a "first_use" report from setup finished
/// to that use. A use before setup finished sends nothing, since there is no
/// end of setup to measure from yet. Every other mark reports nothing.
///
/// The measures are the ones `scripts/first-run-report.sh` prints, from the
/// marks present when the report is made. The steps follow the marks'
/// own times, since a setup resumed after a lost grant reaches its pages
/// out of the usual order. The marks are wall-clock times, which a clock
/// correction can move backwards between two of them, so a report is made
/// only from a timeline that runs forward: a setup that finished no later
/// than it opened reports nothing, a step whose mark falls before setup
/// opened or after it finished is left out, and a measure that would be
/// negative is left out.
struct FirstRunTiming: Sendable, Equatable {
    typealias Event = FirstRunRecord.Event

    enum Measure: String, CaseIterable, Sendable {
        /// Setup opened to the first words on setup's page.
        case timeToFirstDictation = "time_to_first_dictation"
        /// Setup opened to the first email written on setup's page, or,
        /// when none was, outside setup.
        case timeToFirstEmail = "time_to_first_email"
        /// Setup opened to setup finished.
        case setupLength = "setup_length"
        /// Setup finished to the first dictation outside setup.
        case timeToRealUse = "time_to_real_use"
    }

    enum Kind: String, Sendable {
        case setup
        case firstUse = "first_use"
    }

    /// One interval of setup, named by the mark that ends it.
    struct Step: Sendable, Equatable {
        let event: Event
        let start: Date
        let end: Date
    }

    let kind: Kind
    let start: Date
    let end: Date
    /// Setup's steps, in order; empty for a first use.
    let steps: [Step]
    /// Seconds, for the measures this report carries.
    let measures: [Measure: Double]
    /// Fixed keys and values: `mailbox` and `setup_email` as `true` or
    /// `false` for setup, `kind` as `dictation` or `email` for a first use.
    let tags: [String: String]

    /// The report for `event` having just been marked, or nil when that
    /// mark reports nothing.
    init?(marks: [Event: Date], after event: Event) {
        switch event {
        case .setupFinished:
            guard let opened = marks[.setupOpened], let finished = marks[.setupFinished], finished > opened else { return nil }
            kind = .setup
            start = opened
            end = finished
            steps = Self.steps(marks)
            measures = Dictionary(uniqueKeysWithValues: [Measure.timeToFirstDictation, .timeToFirstEmail, .setupLength]
                .compactMap { measure in Self.seconds(measure, in: marks).map { (measure, $0) } })
            tags = ["mailbox": marks[.mailboxConnected] != nil ? "true" : "false",
                    "setup_email": marks[.firstSetupEmail] != nil ? "true" : "false"]
        case .firstDictation, .firstEmail:
            guard let finished = marks[.setupFinished], let used = marks[event], used >= finished else { return nil }
            kind = .firstUse
            start = finished
            end = used
            steps = []
            if event == .firstDictation {
                measures = Self.seconds(.timeToRealUse, in: marks).map { [.timeToRealUse: $0] } ?? [:]
                tags = ["kind": "dictation"]
            } else {
                // An email written on setup's page was already measured with setup.
                let first = marks[.firstSetupEmail] == nil ? Self.seconds(.timeToFirstEmail, in: marks) : nil
                measures = first.map { [.timeToFirstEmail: $0] } ?? [:]
                tags = ["kind": "email"]
            }
        default:
            return nil
        }
    }

    /// The marks of setup after it opened, in the order setup reaches them.
    static let setupSteps: [Event] = [
        .signedIn, .permissionsGranted, .firstSetupDictation, .mailboxConnected, .firstSetupEmail, .setupFinished,
    ]

    /// Setup's steps from `marks`, in the order of their times, with the
    /// usual order of setup deciding a tie: each runs from the mark before
    /// it, or setup opening, to its own. A mark that falls before setup
    /// opened or after it finished is left out.
    static func steps(_ marks: [Event: Date]) -> [Step] {
        guard let opened = marks[.setupOpened], let finished = marks[.setupFinished] else { return [] }
        let usual = Dictionary(uniqueKeysWithValues: setupSteps.enumerated().map { ($1, $0) })
        let kept = setupSteps.compactMap { event in marks[event].map { (event: event, mark: $0) } }
            .filter { $0.mark >= opened && $0.mark <= finished }
            .sorted { $0.mark != $1.mark ? $0.mark < $1.mark : usual[$0.event]! < usual[$1.event]! }
        var previous = opened
        return kept.map { event, mark in
            defer { previous = mark }
            return Step(event: event, start: previous, end: mark)
        }
    }

    /// `measure` in seconds from `marks`, or nil until both of its marks
    /// are present, or when the clock ran backwards between them.
    static func seconds(_ measure: Measure, in marks: [Event: Date]) -> Double? {
        let (from, to): (Event, Event) = switch measure {
        case .timeToFirstDictation: (.setupOpened, .firstSetupDictation)
        case .timeToFirstEmail: (.setupOpened, marks[.firstSetupEmail] != nil ? .firstSetupEmail : .firstEmail)
        case .setupLength: (.setupOpened, .setupFinished)
        case .timeToRealUse: (.setupFinished, .firstDictation)
        }
        guard let start = marks[from], let end = marks[to], end >= start else { return nil }
        return end.timeIntervalSince(start)
    }
}
