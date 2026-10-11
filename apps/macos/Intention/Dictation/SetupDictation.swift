import Foundation

/// What setup's last page is told about dictation, built from the
/// controller, its history and the dictation key. These are the few lines
/// that join setup's rules to dictation's, so they live here, where
/// `./dev mac-dictation-test` runs them against the real controller and
/// history, and not in the app target, which only Xcode can test.
extension FirstDictation {
    /// `key` is the key the person holds, and `chooseKey` makes another one
    /// theirs. `recorder` is Settings' own, which saves what it records
    /// where Settings does; nil leaves the shortcut page offering fn alone.
    @MainActor
    static func of(_ dictation: DictationController, key: @escaping @MainActor () -> HoldKey.Key,
                   chooseKey: @escaping @MainActor (HoldKey.Key) -> Void, recorder: KeyRecorder? = nil,
                   hasFnKey: @escaping @MainActor () -> Bool? = { nil }) -> FirstDictation {
        FirstDictation(
            // Asked live: when dictation cannot begin an attempt the page
            // offers none and asks nothing about languages, and that can
            // change once the person has signed in. A microphone that would
            // not open is the exception: the page keeps its first dictation
            // and says what went wrong, because trying again is the remedy.
            isAvailable: { dictation.available || isMicrophone(dictation.problem) },
            microphoneFailed: { isMicrophone(dictation.problem) },
            microphoneFailedAt: { dictation.microphoneProblemAt },
            keyName: { keycap(key()) },
            phase: { phase(of: dictation.phase) },
            latest: { dictation.history.setupWords },
            missed: { dictation.history.setupMiss },
            silent: { dictation.setupSilence },
            silenceWasMicrophone: { dictation.setupSilenceFromMicrophone },
            keyNames: { HoldKey.Key.suggested.map(keycap) },
            chooseKey: { name in
                guard let key = HoldKey.Key.suggested.first(where: { keycap($0) == name }) else { return }
                chooseKey(key)
            },
            recording: {
                guard let recorder else { return Recording() }
                // A single key held is named as its cap reads, "right
                // option", as the page names the key once it is chosen.
                let shown = recorder.shown.map { shown in
                    HoldKey.Modifier.allCases.first { $0.title == shown }.map { keycap(.single($0)) } ?? shown
                }
                return Recording(isRecording: recorder.isRecording, shown: shown, refusal: recorder.refusal)
            },
            startRecording: { recorder?.start() },
            cancelRecording: { recorder?.cancel() },
            hasFnKey: hasFnKey,
            toggle: { dictation.toggle() },
            inserted: { text, at in dictation.recordSetupInsertion(text, at: at) },
            isQuitting: { dictation.isQuitting }
        )
    }

    /// Dictation's phase as the page shows it.
    static func phase(of phase: DictationController.Phase) -> Phase {
        switch phase {
        case .idle: .idle
        case .recording: .listening
        // Setup's own page has no email body, so an email is never written
        // from it; the words it waits for are the finished text.
        case .processing, .writingEmail: .finishing
        }
    }

    /// Whether what stops dictation is the microphone: it would not open,
    /// or the person has not allowed it.
    static func isMicrophone(_ problem: DictationController.Problem?) -> Bool {
        problem == .microphoneDenied || problem == .microphoneUnavailable
    }

    /// A dictation key as the page prints it, on a keycap and in a sentence:
    /// a single key as its keycap reads, such as "right option", and a pair
    /// by the plain names Settings uses for it, such as "Control + Option".
    static func keycap(_ key: HoldKey.Key) -> String {
        switch key {
        case .single(.function): "fn"
        case let .single(modifier): modifier.title.lowercased()
        case .combination: key.title
        }
    }

    /// Whether a dictation starting now is setup's own: setup's window has
    /// the keyboard and is on one of its two practice pages, the first
    /// dictation or the first email. One made with Settings or the history
    /// window in front, or with setup closed, goes to a field as usual.
    static func isSetupsOwn(onPracticePage: Bool, windowHasKeyboard: @autoclosure () -> Bool) -> Bool {
        onPracticePage && windowHasKeyboard()
    }
}

extension PracticeReply {
    /// The reply page's writer: the one dictation uses in Gmail and Mail,
    /// asked with the person's own thread by its id, its sender as the
    /// recipient and its subject, so the server looks the conversation up in
    /// their imported mail and writes the reply the way it writes a real
    /// one; or with Maya's message and address when there is no thread.
    /// Nothing is read from any window, and nothing is sent.
    @MainActor
    static func of(_ writer: EmailWriter) -> PracticeReply {
        var accepted: [Date: (UUID, String?)] = [:]
        return PracticeReply(
            isAvailable: { writer.isWanted },
            unavailable: {
                if !writer.isEnabled { return .writingOff }
                switch writer.availability {
                case .notConfigured?: return .noWriter
                case .signedOut?: return .signedOut
                default: return nil
                }
            },
            write: { cue, thread, at in
                let scope = writer.retentionScope?()
                switch await writer.write(cue: cue, body: thread.map(Self.body(for:)) ?? body) {
                case let .success(email):
                    accepted[at] = writer.lastAcceptedRequestID.map { ($0, scope) }
                    return .success(email)
                case let .failure(problem):
                    accepted[at] = nil
                    return .failure(Failure(name: EmailWriter.name(problem)))
                }
            },
            inserted: { text, at in
                if let entry = accepted[at] { writer.recordInsertion?(entry.0, text, entry.1) }
            }
        )
    }

    static func body(for thread: AlphaClient.ReplyThread) -> EmailBody {
        EmailBody(bundleIdentifier: nil, body: "",
                  recipients: [WritingRecipient(address: thread.senderAddress, role: .to)],
                  subject: thread.subject, thread: "\(thread.senderName) wrote:\n\(thread.message)",
                  threadID: thread.id, kind: .reply)
    }

    /// Maya's message as the writer takes a body: no text in the reply
    /// yet, the message as the thread, and her address.
    static let body = EmailBody(bundleIdentifier: nil, body: "",
                                recipients: [WritingRecipient(address: Message.address, role: .to)],
                                subject: Message.subject, thread: Message.thread, threadID: nil, kind: .reply)
}
