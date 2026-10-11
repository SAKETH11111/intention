import Foundation

/// How long one reply proposal took and how it ended, on the monotonic
/// clock. `ReplyProposal` marks each boundary as it happens and hands the
/// finished timing to `Telemetry.record` once per proposal, however often
/// its card was shown again.
///
/// Stages are the intervals between consecutive marks: open runs from the
/// reply opening, or for a proposal asked for when its Gmail thread opened
/// from the thread opening, to the request being sent, write from the request to the
/// proposal arriving, and show from its arrival to the card on screen. A
/// proposal that arrived after focus left its reply, and never showed,
/// ends late, with its arrival counted, so slow requests stay in the
/// latency figures; one the person typed over before it arrived ends
/// overtaken, and one cancelled for another reason before the server
/// answered ends cancelled, both at the cancel, with no arrival or show
/// invented. No text, address or app identity is held here.
struct ProposalTiming: Sendable {
    enum Stage: String, CaseIterable, Sendable {
        case open, write, show
    }

    /// How a proposal ended, by the fixed names telemetry reports.
    enum Outcome: String, CaseIterable, Sendable {
        /// The card was shown and nothing more happened to it before the
        /// timing was recorded.
        case shown
        /// It arrived after focus left its reply and never showed.
        case late
        /// The person typed into the reply before it arrived, so its
        /// request was cancelled; no arrival is recorded.
        case overtaken
        /// The bindings refused it before it showed.
        case dropped
        /// It ended before the server answered.
        case cancelled
        /// The server answered with an error.
        case failed
        /// The server answered without text.
        case abstained
        /// The server recorded the person's accept.
        case accepted
        /// The accepted text is in the field.
        case inserted
        /// The person spoke a change while the card showed.
        case changed
        /// The rewritten reply is in the field.
        case changeInserted
        /// The field changed while the card showed.
        case ignored
        /// Escape ended it.
        case dismissed
        /// It ended without the person returning to the reply.
        case left
        /// Its five minutes passed.
        case expired
        /// An accept whose insertion was refused.
        case insertRefused
        /// An accepted or changed reply was pasted and the field did not
        /// show it, so whether it went in is not known.
        case unconfirmed
        /// The server refused to admit its card: the account had been shown
        /// its day's count of proposals, so it never showed.
        case limited
        /// The server could not be told the card was about to show, even
        /// once more after a pause, so it never showed.
        case unreported
    }

    /// What asked for a proposal: the reply's body taking focus, or, for
    /// Gmail, the thread opening before any reply did.
    enum Trigger: String, Sendable {
        case reply, thread
    }

    struct Interval: Sendable, Equatable {
        let stage: Stage
        /// Seconds from the reply opening.
        let start: Double
        let duration: Double
    }

    /// Wall-clock time the reply opened, which anchors the reported spans.
    let startDate: Date
    private let startInstant: ContinuousClock.Instant
    /// The instant each stage ended, in stage order.
    private var ends: [ContinuousClock.Instant] = []
    /// When the proposal ended, which can be long after its last stage.
    private var stopped: ContinuousClock.Instant?
    private(set) var outcome: Outcome?
    var insertionResult: InsertionResult?
    var failure: EmailWriter.Problem?
    var diagnostics = EmailWriter.ProposalDiagnostics()
    var httpStatusClass: String? { failure?.httpStatusClass ?? diagnostics.lastHTTPStatusClass }
    var trigger = Trigger.reply
    /// When the reply's body took focus, which for a proposal asked for when
    /// its thread opened can be long after the opening that anchors it.
    var replyFocused: ContinuousClock.Instant?

    init(startDate: Date = Date(), at instant: ContinuousClock.Instant = .now) {
        self.startDate = startDate
        startInstant = instant
    }

    /// The stage running now, or nil once the card has shown or the
    /// proposal has ended.
    var currentStage: Stage? {
        outcome == nil && ends.count < Stage.allCases.count ? Stage.allCases[ends.count] : nil
    }

    /// Ends the current stage and begins the next. Marks after the outcome
    /// is known are ignored, so a late callback cannot rewrite a timing.
    mutating func endStage(at instant: ContinuousClock.Instant = .now) {
        guard currentStage != nil else { return }
        ends.append(max(instant, ends.last ?? startInstant))
    }

    /// Ends the proposal with `outcome`, once; later calls are ignored. A
    /// late proposal ends the write stage at its arrival, `instant`, if it
    /// is still running, so the arrival counts; any other outcome leaves a
    /// running stage uncounted.
    mutating func finish(_ outcome: Outcome, at instant: ContinuousClock.Instant = .now) {
        guard self.outcome == nil else { return }
        if outcome == .late, currentStage == .write { endStage(at: instant) }
        self.outcome = outcome
        stopped = max(instant, ends.last ?? startInstant)
    }

    /// The completed stages, in order.
    var intervals: [Interval] {
        var previous = startInstant
        return zip(Stage.allCases, ends).map { stage, end in
            defer { previous = end }
            return Interval(stage: stage, start: seconds(previous - startInstant), duration: seconds(end - previous))
        }
    }

    /// Seconds from the reply opening to the proposal arriving, for shown
    /// and late proposals alike. Nil when it never arrived.
    var untilArrival: Double? {
        ends.count > Stage.write.index ? seconds(ends[Stage.write.index] - startInstant) : nil
    }

    /// Seconds from the reply opening to the card first showing: the wait
    /// proposals are judged by. Nil when it never showed.
    var untilShown: Double? {
        ends.count > Stage.show.index ? seconds(ends[Stage.show.index] - startInstant) : nil
    }

    /// Seconds from the reply's body taking focus to the card first
    /// showing, the wait the person sees once they open a reply. Nil when
    /// it never showed or no reply took focus.
    var untilShownFromReply: Double? {
        guard ends.count > Stage.show.index, let replyFocused else { return nil }
        return seconds(max(ends[Stage.show.index] - replyFocused, .zero))
    }

    /// Seconds from the thread or request opening to this reply's focus,
    /// present even when admission or the display read prevented showing.
    var untilReplyFocus: Double? {
        replyFocused.map { seconds($0 - startInstant) }
    }

    /// Seconds from the reply opening to the outcome. For a cancelled
    /// proposal, the time until the cancel. Nil until there is an outcome.
    var elapsed: Double? {
        guard outcome != nil, let stopped else { return nil }
        return seconds(stopped - startInstant)
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

extension ProposalTiming {
    /// The timing of a proposal the controller ended, from the instants
    /// it marked: each stage ends at its mark, and a mark that never came
    /// leaves that stage and the ones after it uncounted. The wall-clock
    /// start is placed back from `now`, the proposal's end, by its whole
    /// span.
    init(_ outcome: Outcome, trace: ProposalTrace, now: Date = Date()) {
        let opened = trace.opened ?? trace.ended
        let span = trace.ended - opened
        let parts = span.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        self.init(startDate: now.addingTimeInterval(-seconds), at: opened)
        trigger = trace.trigger
        replyFocused = trace.replyFocused
        insertionResult = trace.insertionResult
        failure = trace.failure
        diagnostics = trace.diagnostics
        for mark in [trace.requested, trace.arrived, trace.shown] {
            guard let mark else { break }
            endStage(at: mark)
        }
        finish(outcome, at: trace.ended)
    }
}

private extension ProposalTiming.Stage {
    var index: Int { Self.allCases.firstIndex(of: self)! }
}
