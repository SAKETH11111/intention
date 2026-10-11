import AppKit

/// Launch arguments for development evidence. They run only when passed
/// explicitly.
///
/// `--caret-permissions <file>` writes the Accessibility, Screen Recording
/// and microphone grants and the on-screen setting as JSON, then quits.
///
/// `--telemetry-check <dsn>` sends one synthetic dictation timing, a
/// synthetic first run's setup and first dictation, and one test message to
/// that disabled telemetry DSN, then quits.
///
/// `--dictation-stream-check <recording> <file> [--terms <list>] [--languages <codes>]` streams the
/// recording at speaking pace to the build's dictation endpoint through the
/// app's own audio conversion and connection, writes the replies and how
/// long after the stop each arrived as JSON, then quits. `--terms` names a
/// file of names and terms, one per line, sent with the start, and
/// `--languages` the person's languages, such as `en,es`. It inserts nothing. Use only
/// synthetic recordings: the file holds what was said.
@MainActor
enum DevelopmentCommands {
    #if DEBUG
    /// Run through LaunchServices so TCC evaluates Intention's signed identity.
    /// This reads permission flags only, without starting AX or screen capture.
    static func checkCaretPermissions(arguments: [String]) {
        guard let path = value(after: "--caret-permissions", in: arguments) else { return }
        // Explicit, diagnostic-only request. Never changes the persistent
        // visual fallback preference or starts a tracker/capture.
        if arguments.contains("--request-test-permissions") {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = CGRequestScreenCaptureAccess()
        }
        let flags = [
            "accessibilityGranted": AXIsProcessTrusted(),
            "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
            "visualCaretEnabled": Preferences.findsCaretOnScreen(saved: Preferences.savedCaretChoice(in: .standard)),
            "microphone": ["notDetermined", "restricted", "denied", "authorized"][min(Microphone.permission.rawValue, 3)],
        ] as [String: Any]
        do {
            let data = try JSONSerialization.data(withJSONObject: flags, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            exit(0)
        } catch {
            exit(1)
        }
    }

    /// Proves a DSN receives dictation latency and first-run timing before a
    /// release depends on it. Runs before the app model, so it starts no
    /// tracking or prompts.
    static func checkTelemetry(arguments: [String]) {
        if arguments.contains("--telemetry-check") { exit(1) }
    }

    static func checkDictationStream(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--dictation-stream-check"), arguments.indices.contains(index + 2) else { return }
        let recording = URL(fileURLWithPath: arguments[index + 1])
        let output = URL(fileURLWithPath: arguments[index + 2])
        let terms = value(after: "--terms", in: arguments)
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .map { $0.split(separator: "\n").map(String.init).filter { !$0.isEmpty } } ?? []
        let languages = value(after: "--languages", in: arguments)?.split(separator: ",").map(String.init) ?? []
        Task {
            var report: [String: Any] = [:]
            do {
                report = try await streamCheck(recording, terms: terms, languages: languages)
            } catch {
                report["error"] = (error as? DictationStreamError)?.name ?? String(describing: type(of: error))
            }
            let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            exit((try? data.write(to: output, options: .atomic)) != nil && report["error"] == nil ? 0 : 1)
        }
        // Keep the app from launching while the check runs on the main actor.
        while true { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    }

    private static func streamCheck(_ recording: URL, terms: [String], languages: [String]) async throws -> [String: Any] {
        // The signed-in device key gets a grant, as the app's own dictation does.
        guard let url = DictationEndpoint.address(), let client = AlphaClient.configured() else {
            throw DictationStreamError.unauthorized
        }
        let key = try KeychainDeviceKey().read()
        let grant = try await SpeechGrants(client: client, key: { key }, keyRefused: { _ in }).grant()
        let playback = try RecordingPlayback(url: recording)
        let tape = DictationTape()
        var start = DictationStart(register: "other")
        start.terms = terms
        start.languages = languages
        let stream = DictationStream(url: url, grant: grant, start: start)
        tape.attach(stream)
        try playback.start(audio: { tape.append($0) }, interrupted: {}, device: { _ in })
        try await Task.sleep(for: playback.duration + .milliseconds(100))
        playback.stop()
        let stopped = ContinuousClock.now
        await stream.finish()
        var report: [String: Any] = ["audioSeconds": tape.seconds, "frames": tape.recorded.count]
        let milliseconds = { ((ContinuousClock.now - stopped) / .milliseconds(1)).rounded() }
        for try await reply in stream.replies {
            switch reply {
            case let .transcript(text):
                report["transcript"] = text
                report["transcriptAfterMs"] = milliseconds()
            case let .text(text, cleaned, _):
                report["text"] = text
                report["cleaned"] = cleaned
                report["textAfterMs"] = milliseconds()
            case .retention:
                break
            }
        }
        return report
    }
    #endif

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
