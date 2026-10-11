/// What the foot mark shows for a dictation: its phase while one runs,
/// the email's words while one is written, and the notice the dot's
/// caption shows, in the same words
/// (`DictationController.Phase.writingEmailCaption`, `Notice.text`), so
/// the two indicators say the same: over rest, and over an earlier
/// dictation's text still on its way, but never over a recording or an
/// email being written. Kept apart from `FootMark.swift` so the foot's
/// renders build without dictation.
extension FootState {
    init(phase: DictationController.Phase, notice: DictationController.Notice?,
         email: DictationController.EmailFeedback = .init()) {
        switch phase {
        case .idle: self = notice.map { .notice($0.text) } ?? .resting
        case .recording: self = .listening
        case .processing: self = notice.map { .notice($0.text) } ?? .writing
        case .writingEmail: self = .working(phase.caption(email: email) ?? DictationController.Phase.writingEmailCaption)
        }
    }

    /// What the foot says when a dictation ended with nothing to insert:
    /// why, ending with the microphone it recorded from, so a name too long
    /// for the one line loses its end and not the sentence. Without a
    /// name, as when no microphone opened or a recording played in its
    /// place, it says what Intention has always said.
    init(_ empty: DictationController.EmptyResult) {
        self = switch (empty.silence, empty.device) {
        case (.neverStarted, _): .notice("Microphone didn't start. Try again.")
        case (.microphone, nil): .heardNothing
        case (.nearlyNothing, nil): .heardAlmostNothing
        case (.words, nil): .heardNoWords
        case let (.microphone, device?): .notice("No sound from \(device)")
        case let (.nearlyNothing, device?): .notice("Almost no sound from \(device)")
        case let (.words, device?): .notice("Heard no words from \(device)")
        }
    }

    /// The same line, for the popup that offers Retry and another
    /// microphone, so every indicator says the same.
    static func words(for empty: DictationController.EmptyResult) -> String {
        if case let .notice(words) = FootState(empty) { words } else { "" }
    }
}
