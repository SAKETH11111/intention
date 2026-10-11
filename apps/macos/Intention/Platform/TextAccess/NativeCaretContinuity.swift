/// Decides where the dot rests from the caret evidence so far, independent
/// of AppKit and of typed characters.
///
/// Typing never blanks a known position: the dot stays until a newer read
/// replaces it. A read that finds no caret clears it at once; a read that
/// finds a caret it cannot place keeps the last position on the same field
/// for `hold`. A boundary (another field, window or app) rejects every
/// observation queued before it; the old position stands only until the
/// first read after it, at most `boundaryGrace`, so the dot moves to the
/// new field instead of flickering off and on. While paused, as while the
/// caret dot is hidden, it shows nothing and takes nothing in.
struct NativeCaretContinuity<Reading: Equatable> {
    typealias Status = CaretEvidenceStatus

    /// How long a position survives unresolved reads on its field.
    static var hold: Duration { .milliseconds(500) }
    /// How long a position survives without any fresh read, such as while
    /// an app is slow to answer.
    static var silence: Duration { .milliseconds(750) }
    /// How long a position survives a boundary with no read after it.
    static var boundaryGrace: Duration { .milliseconds(100) }

    private(set) var generation = 0
    /// Whether reading has stopped: nothing is shown, and every observation
    /// and visual confirmation is refused, so no read that was already on
    /// its way, or that arrives anyway, can bring the dot back.
    private(set) var paused = false
    private var placed: (reading: Reading, at: ContinuousClock.Instant, focus: Int)?
    private var latest: (status: Status, focus: Int, at: ContinuousClock.Instant)?
    private var boundaryAt: ContinuousClock.Instant?
    private var hint: Reading?
    /// Visual confirmation, used only while Accessibility is unresolved. A
    /// frame that confirms nothing leaves it to age out after `hold`, so the
    /// dot does not flicker between keystrokes.
    var visual: Reading? {
        get { visualEvidence?.reading }
        set { visualEvidence = newValue.map { ($0, .now) } }
    }
    private var visualEvidence: (reading: Reading, at: ContinuousClock.Instant)?

    mutating func confirmVisual(_ reading: Reading?, at time: ContinuousClock.Instant) {
        guard !paused else { return }
        if let reading { visualEvidence = (reading, time) }
    }

    mutating func advance() { generation &+= 1 }
    func accepts(_ observationGeneration: Int) -> Bool { !paused && observationGeneration == generation }

    /// Forgets all evidence and refuses more until `resume`.
    mutating func pause() {
        clear()
        paused = true
    }

    /// Takes evidence again, from reads started after this.
    mutating func resume() {
        guard paused else { return }
        paused = false
        advance()
    }

    /// Forgets all evidence, as when focus moves to an app the dot does
    /// not mark.
    mutating func clear() {
        advance()
        placed = nil
        latest = nil
        visual = nil
        hint = nil
        boundaryAt = nil
    }

    /// Another field, window or app may now have focus. Evidence stands
    /// only until the next read says whether the field changed.
    mutating func boundary(at time: ContinuousClock.Instant) {
        advance()
        boundaryAt = time
    }

    mutating func record(_ status: Status, reading: Reading?, hint: Reading? = nil, focus: Int, at time: ContinuousClock.Instant) {
        guard !paused else { return }
        self.hint = status == .unresolved ? hint : nil
        if latest?.focus != focus { visual = nil }
        if placed?.focus != focus { placed = nil }
        latest = (status, focus, time)
        if let boundaryAt, time >= boundaryAt { self.boundaryAt = nil }
        switch status {
        case .placed:
            // Accessibility supersedes an older visual confirmation.
            if let reading { placed = (reading, time, focus) }
            visual = nil
        case .absent:
            placed = nil
            visual = nil
        case .unresolved:
            break
        }
    }

    /// Which evidence `shown` answers from, for diagnostics.
    func source(at now: ContinuousClock.Instant) -> String {
        guard let shown = shown(at: now) else { return "none" }
        if latest?.status == .placed { return "accessibility" }
        if shown == visualEvidence?.reading { return "visual" }
        return shown == hint ? "hint" : "held"
    }

    func shown(at now: ContinuousClock.Instant) -> Reading? {
        guard !paused, let latest, now - latest.at <= Self.silence else { return nil }
        if let boundaryAt, now - boundaryAt > Self.boundaryGrace { return nil }
        switch latest.status {
        case .absent:
            return nil
        case .placed:
            return placed?.reading
        case .unresolved:
            if let visualEvidence, now - visualEvidence.at <= Self.hold { return visualEvidence.reading }
            if let hint { return hint }
            guard let placed, placed.focus == latest.focus, now - placed.at <= Self.hold else { return nil }
            return placed.reading
        }
    }
}

/// Whether a read found a caret to mark.
enum CaretEvidenceStatus: Equatable, Sendable {
    case placed
    /// No usable caret: no text field, a secure field, a selection, or a
    /// caret scrolled out of view.
    case absent
    /// A text field with a caret whose geometry the read could not resolve.
    /// The previous position may stand briefly.
    case unresolved
}
