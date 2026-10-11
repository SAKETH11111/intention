import Foundation

/// How long each stage of one dictation took, measured on the monotonic
/// clock. Dictation marks each boundary as it happens and hands the finished
/// timing to `Telemetry.record`.
///
/// Stages are the intervals between consecutive marks: record runs from the
/// start of recording to its stop, transcribe from the stop to the final
/// transcript, clean from the transcript to the finished text, and insert
/// from the finished text to the text in the field. Transcription can stream
/// while the person speaks; only the part after they stop counts as
/// transcribe, since that is the wait they feel. A dictation into a field
/// that could be an email body, with "Write emails for me" on, has one more
/// stage, email, from the finished text to the start of the insertion: the
/// read of the field and of the body, and the server writing the email when
/// it does. Insert then runs from there, so it measures the insertion alone
/// in every dictation. No text, audio or app identity is held here.
struct DictationTiming: Sendable {
    enum Stage: String, CaseIterable, Sendable {
        case record, transcribe, clean, email, insert
    }

    /// Optional events, independent of the legacy stage boundaries. Values
    /// are seconds since this dictation started, on the same monotonic clock.
    enum Mark: String, CaseIterable, Sendable {
        case stopRequested = "stop_requested"
        case audioStopped = "audio_stopped"
        case streamRequested = "stream_requested"
        case stopSent = "stop_sent"
        case transcriptReceived = "transcript_received"
        case cleanedTextReceived = "cleaned_text_received"
        case insertStarted = "insert_started"
        case insertConfirmed = "insert_confirmed"
    }

    enum Outcome: Sendable, Equatable {
        case inserted
        /// The stage that was running when dictation failed.
        case failed(Stage)
        case cancelled
        /// The microphone sent no sound.
        case heardNothing
        /// Nearly every sample was exactly zero and no words were found.
        case heardAlmostNothing
    }

    struct Interval: Sendable, Equatable {
        let stage: Stage
        /// Seconds from the start of recording.
        let start: Double
        let duration: Double
    }

    /// Wall-clock time recording started, which anchors the reported spans.
    let startDate: Date
    private let startInstant: ContinuousClock.Instant
    /// The instant each stage ended, in stage order.
    private var ends: [ContinuousClock.Instant] = []
    /// When dictation failed or was cancelled, which can be long after the
    /// last stage that finished.
    private var stopped: ContinuousClock.Instant?
    private var marks: [Mark: ContinuousClock.Instant] = [:]
    private(set) var outcome: Outcome?
    private(set) var insertionResult: InsertionResult?
    /// Whether this dictation has the email stage.
    private(set) var waitsForEmail = false

    /// The stages this dictation has, in order.
    private var stages: [Stage] { Stage.allCases.filter { waitsForEmail || $0 != .email } }

    init(startDate: Date = Date(), at instant: ContinuousClock.Instant = .now) {
        self.startDate = startDate
        startInstant = instant
    }

    /// Keeps the first observation of an event. Missing events stay absent,
    /// including a transcript omitted by the endpoint or a refused insertion.
    /// Late callbacks cannot add marks after cancellation or completion.
    mutating func mark(_ mark: Mark, at instant: ContinuousClock.Instant = .now) {
        guard outcome == nil, marks[mark] == nil else { return }
        marks[mark] = max(instant, startInstant)
    }

    /// Imports transport observations before the controller freezes an outcome.
    /// Repeated reads preserve each event's first instant and terminal immutability.
    /// A send callback still pending when the outcome freezes stays absent;
    /// delivery never waits for it solely to complete diagnostics.
    mutating func markTransport(_ snapshot: DictationStream.TimingSnapshot) {
        if let instant = snapshot.stopSent { mark(.stopSent, at: instant) }
        if let instant = snapshot.transcriptReceived { mark(.transcriptReceived, at: instant) }
        if let instant = snapshot.cleanedTextReceived { mark(.cleanedTextReceived, at: instant) }
    }

    /// The controller retains a failed stream attempt before reconnecting.
    /// Only optional marks reset: legacy stages keep timing the whole dictation.
    /// A reconnect has no recording stop, so it must not inherit those marks.
    mutating func resetAttemptMarks() {
        guard outcome == nil else { return }
        marks.removeAll()
    }

    var markOffsets: [String: Double] {
        Dictionary(uniqueKeysWithValues: marks.map { ($0.key.rawValue, seconds($0.value - startInstant)) })
    }

    /// Retention uses seconds for both legacy durations and event offsets.
    /// The fixed event names distinguish offsets from stage durations.
    var retainedTimings: [String: Double] {
        var values = Dictionary(uniqueKeysWithValues: intervals.map { ($0.stage.rawValue, $0.duration) })
        values.merge(markOffsets) { _, offset in offset }
        if let elapsed { values["elapsed"] = elapsed }
        return values
    }

    /// The stage running now, or nil once dictation has finished.
    var currentStage: Stage? {
        outcome == nil && ends.count < stages.count ? stages[ends.count] : nil
    }

    /// Ends the current stage and begins the next. Marks after the outcome
    /// is known are ignored, so a late callback cannot rewrite a timing.
    mutating func endStage(at instant: ContinuousClock.Instant = .now) {
        guard currentStage != nil else { return }
        ends.append(max(instant, ends.last ?? startInstant))
        if ends.count == stages.count { outcome = .inserted }
    }

    /// Makes the stage after clean the email stage, for a dictation into a
    /// field that could be an email body. It applies only while that stage
    /// has not ended, and the next mark ends it.
    mutating func waitForEmail() {
        guard currentStage == .insert, !waitsForEmail else { return }
        waitsForEmail = true
    }

    /// Ends dictation early. The running stage is not counted as completed.
    mutating func fail(at instant: ContinuousClock.Instant = .now) {
        guard let stage = currentStage else { return }
        outcome = .failed(stage)
        stopped = max(instant, ends.last ?? startInstant)
    }

    /// Keeps only the inserter's fixed result, before ending the insert stage.
    mutating func failInsertion(_ result: InsertionResult, at instant: ContinuousClock.Instant = .now) {
        guard currentStage == .insert else { return }
        switch result {
        case .inserted: return
        case .notInserted, .unknown: insertionResult = result
        }
        fail(at: instant)
    }

    mutating func cancel(at instant: ContinuousClock.Instant = .now) {
        end(.cancelled, at: instant)
    }

    /// Ends dictation with nothing heard, `.heardNothing` or
    /// `.heardAlmostNothing`.
    mutating func silent(_ outcome: Outcome, at instant: ContinuousClock.Instant = .now) {
        end(outcome, at: instant)
    }

    private mutating func end(_ early: Outcome, at instant: ContinuousClock.Instant) {
        guard currentStage != nil else { return }
        outcome = early
        stopped = max(instant, ends.last ?? startInstant)
    }

    /// The completed stages, in order.
    var intervals: [Interval] {
        var previous = startInstant
        return zip(stages, ends).map { stage, end in
            defer { previous = end }
            return Interval(stage: stage, start: seconds(previous - startInstant), duration: seconds(end - previous))
        }
    }

    /// Seconds from the start of recording to the outcome, including the time
    /// a failed or cancelled stage ran. Nil until there is an outcome.
    var elapsed: Double? {
        guard outcome != nil, let end = stopped ?? ends.last else { return nil }
        return seconds(end - startInstant)
    }

    /// From the person stopping to the text in the field: the wait that
    /// dictation is judged by. Nil until text is inserted.
    var afterStop: Double? {
        guard outcome == .inserted, let stop = ends.first, let inserted = ends.last else { return nil }
        return seconds(inserted - stop)
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
