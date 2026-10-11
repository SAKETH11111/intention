import Foundation

/// The rules for the hint that teaches voice compose where it is needed:
/// when the caret lands in the body of an email being written, a few words
/// beside the dot, or above the foot mark, say which key to hold. Kept apart from
/// AppKit and Accessibility so `./dev mac-dictation-test` checks them.
enum EmailHint {
    /// How many times the hint is shown at most.
    static let limit = 3
    /// How long each showing lasts.
    static let duration: Duration = .seconds(4)

    /// Whether the hint has retired for good: Intention has written an email
    /// and put it in, or the hint has shown `limit` times. Nothing is read
    /// for it again.
    static func retired(shown: Int, firstEmailWritten: Bool) -> Bool {
        firstEmailWritten || shown >= limit
    }

    /// Whether the hint is wanted now: it has not retired, and an email
    /// could be written from a dictation now ("Write emails for me" is on
    /// and dictation can begin). Those two can change back, as when setup
    /// signs in, so they pause the hint rather than retire it.
    static func wanted(shown: Int, firstEmailWritten: Bool, canWriteEmails: Bool) -> Bool {
        !retired(shown: shown, firstEmailWritten: firstEmailWritten) && canWriteEmails
    }

    /// The words, for the dictation key as setup prints it
    /// (`FirstDictation.keycap`): "fn", "right option" or "Control + Option".
    static func words(key: String) -> String {
        "Hold \(key) and say your reply"
    }
}

/// When the hint shows and for how long. Told by `EmailBodyWatch` each time
/// keyboard focus moves to a new element, whether it is an email body, it
/// shows the words through `say` for `EmailHint.duration`, counts the
/// showing, and takes them away early when focus leaves the body or a
/// dictation starts. It reads nothing itself; the app gives it the
/// preferences and the key through closures, and tests script them.
@MainActor
final class EmailHints {
    /// How many times the hint has been shown.
    private let shown: () -> Int
    /// Counts one more showing.
    private let countShown: () -> Void
    private let firstEmailWritten: () -> Bool
    /// Whether an email could be written from a dictation now.
    private let canWriteEmails: () -> Bool
    /// The dictation key as setup prints it.
    private let keyName: () -> String

    /// The words to show now, or nil to take them away.
    var say: (String?) -> Void = { _ in }
    /// Whether nothing else is being said: no dictation runs and no notice
    /// or popup about one shows. The hint never covers those, and is not
    /// counted when it waits for them.
    var quiet: () -> Bool = { true }
    /// How long the words stay; tests step it by hand.
    var pause: @MainActor () async -> Void = { try? await Task.sleep(for: EmailHint.duration) }
    /// The wait between looks while the hint waits for something else to
    /// end; tests step it by hand.
    var retryPause: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
    /// How many looks a waiting hint takes before it gives up on this field.
    static let retries = 40
    /// The words showing, if any.
    private(set) var words: String?
    private var ends: Task<Void, Never>?
    /// The look taken again and again while the body has focus and
    /// something else is being said, since the watch reports a field once.
    private var waiting: Task<Void, Never>?

    init(shown: @escaping () -> Int, countShown: @escaping () -> Void, firstEmailWritten: @escaping () -> Bool,
         canWriteEmails: @escaping () -> Bool, keyName: @escaping () -> String) {
        self.shown = shown
        self.countShown = countShown
        self.firstEmailWritten = firstEmailWritten
        self.canWriteEmails = canWriteEmails
        self.keyName = keyName
    }

    /// Whether the hint has retired for good; the watch then stops.
    var retired: Bool {
        EmailHint.retired(shown: shown(), firstEmailWritten: firstEmailWritten())
    }

    /// Whether the hint is wanted now. The watch reads nothing while it is
    /// not.
    var wanted: Bool {
        EmailHint.wanted(shown: shown(), firstEmailWritten: firstEmailWritten(), canWriteEmails: canWriteEmails())
    }

    /// Keyboard focus moved to a new element, which is or is not the body
    /// of an email being written.
    func focusChanged(emailBody: Bool) {
        waiting?.cancel()
        waiting = nil
        guard emailBody else { return end() }
        guard words == nil, wanted else { return }
        guard quiet() else {
            // A notice or popup is still up. The watch will not report this
            // field again, so look again until it is quiet, or give up.
            waiting = Task { [weak self, retryPause] in
                for _ in 0..<EmailHints.retries {
                    await retryPause()
                    guard !Task.isCancelled, let self else { return }
                    if self.words == nil, self.wanted, self.quiet() {
                        self.waiting = nil
                        self.show()
                        return
                    }
                }
                self?.waiting = nil
            }
            return
        }
        show()
    }

    private func show() {
        countShown()
        let words = EmailHint.words(key: keyName())
        self.words = words
        say(words)
        ends = Task { [weak self, pause] in
            await pause()
            guard !Task.isCancelled else { return }
            self?.end()
        }
    }

    /// A dictation started: the person has the key in hand, so the words go,
    /// and a hint waiting its turn gives up.
    func dictationStarted() {
        waiting?.cancel()
        waiting = nil
        end()
    }

    private func end() {
        ends?.cancel()
        ends = nil
        guard words != nil else { return }
        words = nil
        say(nil)
    }

    /// What `EmailBodyWatch` calls on its Accessibility thread for each new
    /// focused element. It reaches the main actor itself, at once on the
    /// main thread and through the main queue anywhere else, so it is safe
    /// to call from any queue.
    nonisolated static func reporter(to hints: EmailHints) -> @Sendable (_ emailBody: Bool) -> Void {
        { [weak hints] emailBody in
            if Thread.isMainThread {
                MainActor.assumeIsolated { hints?.focusChanged(emailBody: emailBody) }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { hints?.focusChanged(emailBody: emailBody) }
                }
            }
        }
    }
}
