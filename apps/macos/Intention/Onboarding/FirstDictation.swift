import Foundation

/// What setup's last page needs from dictation, so the page can show a
/// first dictation without knowing how one is recorded or sent.
struct FirstDictation {
    enum Phase: Equatable {
        case idle, listening, finishing
    }

    /// What the page shows.
    enum Moment: Equatable {
        /// This build has no dictation.
        case unavailable
        case waiting, listening, finishing
        case heard(String)
    }

    /// What Settings' key recorder is doing, as the shortcut page shows it.
    struct Recording: Equatable {
        var isRecording = false
        /// The keys held in the attempt so far.
        var shown: String?
        /// Why the last attempt cannot be a shortcut, with how to try again.
        var refusal: String?
    }

    /// Whether dictation can be tried now. Asked each time the page is
    /// drawn, because the answer can change while setup is open: a build
    /// may only learn where to send a dictation once the person has signed
    /// in.
    var isAvailable: @MainActor () -> Bool = { true }
    /// Whether the last try could not use the microphone: it would not
    /// open, or the person has not allowed it. The page stays on its first
    /// dictation and says so, since holding the key again is the way out.
    var microphoneFailed: @MainActor () -> Bool = { false }
    /// When it was last found unusable; nil when that is not known, as in
    /// the fixture, where a failure stands until the microphone works.
    var microphoneFailedAt: @MainActor () -> Date? = { nil }
    /// The key to hold, as printed on the keyboard: "fn".
    var keyName: @MainActor () -> String
    var phase: @MainActor () -> Phase
    /// The newest words spoken on this page, and when they were finished.
    /// Words dictated into another app are not this page's.
    var latest: @MainActor () -> (text: String, at: Date)?
    /// When the newest dictation made on this page failed: the server could
    /// not be reached, or it did not finish the text.
    var missed: @MainActor () -> Date? = { nil }
    /// When the newest dictation made on this page came back with no
    /// words at all, as when the wrong microphone is chosen or the key
    /// was let go before anything was said.
    var silent: @MainActor () -> Date? = { nil }
    /// Whether that silence was the microphone's own, nothing at all coming
    /// through it, rather than sound with no words in it.
    var silenceWasMicrophone: @MainActor () -> Bool = { false }
    /// Every key that can be held, as printed on the keyboard, the
    /// person's own among them. Which key is theirs to decide: Fn is also
    /// what other dictation apps use.
    var keyNames: @MainActor () -> [String] = { [] }
    /// Makes the key with that name the one to hold.
    var chooseKey: @MainActor (String) -> Void = { _ in }
    /// Settings' own key recorder: what it is doing, and starting and
    /// stopping it. What it records is saved where Settings saves it.
    var recording: @MainActor () -> Recording = { Recording() }
    var startRecording: @MainActor () -> Void = {}
    var cancelRecording: @MainActor () -> Void = {}
    /// Whether a keyboard with fn is connected; nil when no keyboard could
    /// be read.
    var hasFnKey: @MainActor () -> Bool? = { nil }
    /// A click on the page's dot: starts a dictation, or ends the one
    /// running, as a click on the foot dot, or on the dot above an email's
    /// caret, does.
    var toggle: @MainActor () -> Void = {}
    var inserted: @MainActor (String, Date) -> Void = { _, _ in }
    /// True from the start of quitting until the quit is refused. Setup's
    /// fields take no words and the writer is asked nothing meanwhile, so
    /// nothing goes in or is recorded after retention's last save.
    var isQuitting: @MainActor () -> Bool = { false }

    /// Read live from the same listener that drives dictation. Nil is used
    /// by builds and fixtures without keyboard input.
    var listener: FnListenerHealth? = nil
    var retryListener: @MainActor () -> Void = {}
    var skippedKeyCheck: @MainActor () -> Void = {}

    /// Dictated words as they go into the page's field between `before`,
    /// the text up to the caret, and `after`, the text that follows it: a
    /// space first when they would otherwise run into a word or the end of
    /// a sentence, and one last when a word follows. None after an opening
    /// quote or bracket, and none in Chinese or Japanese, which put no
    /// space between sentences. Elsewhere the dictation service sees the
    /// text before the caret and spaces its answer; on this page it is
    /// told of no field, so the page does it.
    static func spaced(_ words: String, after before: String, before after: String = "") -> String {
        guard let first = words.unicodeScalars.first, let end = words.unicodeScalars.last else { return words }
        let apart = CharacterSet.whitespacesAndNewlines
        let opening = CharacterSet(charactersIn: "([{\u{201C}\u{2018}\u{00AB}\u{300C}\u{300E}\u{FF08}")
        var spaced = words
        if let last = before.unicodeScalars.last, !apart.contains(last), !apart.contains(first), !opening.contains(last),
           !isUnspaced(last), !isUnspaced(first) {
            spaced = " " + spaced
        }
        if let next = after.unicodeScalars.first, CharacterSet.alphanumerics.contains(next), !apart.contains(end),
           !isUnspaced(next), !isUnspaced(end) {
            spaced += " "
        }
        return spaced
    }

    /// Han, kana and their punctuation, which are written without spaces.
    /// Fullwidth Latin letters and digits are not among them: they are
    /// words like any other.
    private static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        // Fullwidth punctuation and halfwidth kana.
        case 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF9F: true
        default: false
        }
    }
}
