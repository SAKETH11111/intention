#if DEBUG
import AppKit

/// A stand-in for the alpha backend that answers inside the process, for
/// the onboarding tests and for walking through setup in a Debug build
/// without a server (`--onboarding-fixture`). No socket is opened and no
/// real account, invite or mailbox is involved.
final class AlphaStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var json = "{}"
        var headers: [String: String] = [:]
        /// Fails the request as the network would instead of answering.
        var failure: URLError.Code?
        /// How long the answer takes, so a demo shows the wait.
        var delay: TimeInterval = 0
        /// Never answers, as a server that hangs: the request ends only when
        /// it is cancelled, however long a check takes to cancel it.
        var stalls = false
    }

    /// Answers each request. Set before the first one is sent.
    nonisolated(unsafe) static var answer: @Sendable (URLRequest) -> Reply = { _ in Reply(status: 404) }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlphaStub.self]
        return URLSession(configuration: configuration)
    }

    static func client() -> AlphaClient? {
        try? AlphaClient(endpoint: URL(string: "https://service.invalid")!, session: session())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var wait: Timer?

    override func startLoading() {
        let reply = Self.answer(request)
        guard !reply.stalls else { return }
        guard reply.delay > 0 else { return deliver(reply) }
        // Waits on the loading thread's run loop without holding the
        // thread, so a slow answer does not hold back the ones after it.
        let wait = Timer(timeInterval: reply.delay, repeats: false) { [weak self] _ in self?.deliver(reply) }
        RunLoop.current.add(wait, forMode: .common)
        self.wait = wait
    }

    private func deliver(_ reply: Reply) {
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers.merging(["Content-Type": "application/json"]) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        wait?.invalidate()
    }
}

/// A device key kept in memory, so a fixture run never touches the keychain.
final class MemoryDeviceKey: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    /// Makes the next saves fail, as a locked keychain would.
    var refusesSaves = false
    var refusesDeletes = false
    /// Makes reads fail, as a keychain whose prompt was answered Deny does.
    var refusesReads = false

    init(_ key: String? = nil) {
        self.key = key
    }

    func read() throws -> String? {
        if refusesReads { throw CocoaError(.fileReadNoPermission) }
        return lock.withLock { key }
    }

    func save(_ key: String) throws {
        if refusesSaves { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock { self.key = key }
    }

    func delete() throws {
        if refusesDeletes { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock { key = nil }
    }
}

/// The backend for `--onboarding-fixture`: any six digits sign in, and a
/// connected mailbox appears a few seconds after Connect and then counts
/// up, as a first sync does. The fixture has no writer, so its reply page
/// shows the example; the demo's scripted writer answers a made-up thread.
///
/// `--onboarding-demo` goes further and plays setup by itself for a
/// recording: the grants, both dictations and the written reply are
/// scripted too, so it touches no permission, microphone, account or
/// server, and its window stays behind the desktop where it cannot be seen
/// or clicked.
enum OnboardingFixture {
    static var isDemo: Bool { CommandLine.arguments.contains("--onboarding-demo") }
    static var isRequested: Bool { isDemo || CommandLine.arguments.contains("--onboarding-fixture") }
    /// Who the fixture's first page greets, in place of the Mac account's
    /// name, so pictures and recordings of setup carry no one's name.
    static let syntheticName = "Alex Rivera"
    /// What the demo's person says and what the scripted writer answers.
    static let demoDictation = "Running ten minutes late, save me a seat by the window."
    /// The made-up thread the reply page answers in renders and the demo,
    /// served as `/v1/setup/reply-thread` would serve one of the person's
    /// own, so no picture of setup carries anyone's mail. Its time is fixed
    /// to this morning so the card reads as today's.
    static var demoThreadJSON: String {
        let morning = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()
        let sentAt = ISO8601DateFormatter().string(from: morning)
        return """
        {"thread":{"thread_id":"18c2f0a9d4e7b351","sender_name":"Jordan Ellis","sender_address":"jordan@example.com",\
        "subject":"Offsite venue","message":"Hi! We're down to two places for the offsite: the Harbor Loft downtown or \
        Cedar Ridge lodge. Harbor is cheaper, Cedar has rooms for everyone. Which way are you leaning? I need to tell them \
        by Friday.","sent_at":"\(sentAt)"},"reason":null}
        """
    }
    /// The reply the scripted writer gives to the made-up thread.
    static let demoOwnReply = "Hey Jordan, I'd go with Cedar Ridge. Having everyone under one roof is worth the extra cost. Happy to call them Friday if that helps."
    /// `--settings-mail none|syncing|ready|broken|changed|failed|stale|gmail-closed|gmail-closed-outlook` starts the fixture signed
    /// in with setup finished and one Gmail mailbox in that state, or none,
    /// for drawing Settings' mail rows. `stale` answers the first read as
    /// `ready` and every later one with a server error.
    static var settingsMail: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--settings-mail"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// A deliberately long, made-up address for Settings layout checks.
    private static var settingsAddress: String {
        if isRequested, CommandLine.arguments.contains("--settings-long-address") {
            return "alex.rivera.podcasting.and.community.newsletter@example.com"
        }
        return "synthetic@example.com"
    }

    /// The mailbox list the server would send for each of those states.
    static func connections(_ mail: String) -> String {
        func row(_ state: String, stored: Int, done: Bool, synced: String?, error: String?) -> String {
            """
            {"connections":[{"id":"33333333-3333-4333-8333-333333333333","provider":"gmail","address":"\(settingsAddress)",\
            "state":"\(state)","stored_messages":\(stored),"blocked_messages":0,"backfill_done":\(done),"reconciling":false,\
            "last_synced_at":\(synced.map { "\"\($0)\"" } ?? "null"),"error_code":\(error.map { "\"\($0)\"" } ?? "null"),\
            "connected_at":"2026-10-06T10:00:00Z"}]}
            """
        }
        switch mail {
        case "syncing": return row("syncing", stored: 1240, done: false, synced: "2026-10-06T10:05:00Z", error: nil)
        case "ready": return row("ready", stored: 48213, done: true, synced: "2026-10-06T10:40:00Z", error: nil)
        case "broken": return row("reconnect_required", stored: 15320, done: false, synced: "2026-10-06T10:20:00Z", error: "reconnect_required")
        // The server cannot list the mailboxes.
        case "failed": return "failed"
        case "stale": return "stale"
        case "changed": return row("reconnect_required", stored: 15320, done: false, synced: "2026-10-06T10:20:00Z", error: "mail_identity_changed")
        // Gmail has stopped taking new accounts, alone or beside Outlook.
        case "gmail-closed": return #"{"connections":[],"available_providers":["gmail"],"gmail_connect_open":false}"#
        case "gmail-closed-outlook": return #"{"connections":[],"available_providers":["gmail","outlook"],"gmail_connect_open":false}"#
        default: return #"{"connections":[]}"#
        }
    }

    @MainActor
    /// `dictation` and `languages` are the app's own: the stand-in is for the
    /// backend and the key store. Dictation needs a speech grant for a real
    /// account, so the app gives the fixture none, and the writer needs a
    /// real account too, so the fixture has none and its reply page shows
    /// the example. The demo scripts all of them instead.
    static func model(permissions: SetupPermissions, dictation: FirstDictation? = nil,
                      languages: DictationLanguages? = nil) -> OnboardingModel {
        let suite = "co.intention.mac.onboarding-fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let state = State()
        AlphaStub.answer = { request in state.answer(request) }
        // The last page is asked and its answer forgotten: a fixture adds
        // nothing to Login Items.
        let loginItem = SetupLoginItem(isOn: { false }, answer: { _ in })
        guard isDemo else {
            var keys = MemoryDeviceKey()
            if let mail = settingsMail {
                // Signed in with setup finished, so Settings shows its mail rows.
                defaults.set(OnboardingModel.Step.done.rawValue, forKey: "onboardingStep")
                keys = MemoryDeviceKey("synthetic-device-key")
                state.answerConnections(with: Self.connections(mail))
            }
            return OnboardingModel(client: AlphaStub.client(), keys: keys, permissions: permissions,
                                   mail: FixtureMail(), dictation: dictation, languages: languages, loginItem: loginItem,
                                   fullName: syntheticName, defaults: defaults)
        }
        let script = Script()
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey(),
            permissions: SetupPermissions(isGranted: { script.granted.contains($0) }, request: { _ in }),
            mail: FixtureMail(consentTakes: 3.2),
            dictation: script.port,
            practice: PracticeReply(isAvailable: { true }, write: { _, thread, _ in
                try? await Task.sleep(for: .milliseconds(2600))
                return .success(thread == nil ? PracticeReply.exampleEmail : OnboardingFixture.demoOwnReply)
            }),
            languages: DictationLanguages(current: { script.languages }, save: { script.languages = $0 }),
            loginItem: loginItem, screenRecordingDue: { true }, fullName: syntheticName, defaults: defaults,
            pollInterval: .milliseconds(400)
        )
        Task { await script.play(model) }
        return model
    }

    @MainActor
    private final class FixtureMail: MailConnecting {
        /// How long the made-up consent takes, so a recording shows the
        /// page with the browser's three clicks listed.
        let consentTakes: TimeInterval

        init(consentTakes: TimeInterval = 0) {
            self.consentTakes = consentTakes
        }

        func connect(provider: AlphaClient.MailProvider, client: AlphaClient, deviceKey: String,
                     anchor: NSWindow, isCurrent: @escaping @MainActor () -> Bool) async throws -> UUID {
            let flow = try await client.beginMail(provider: provider, deviceKey: deviceKey)
            if consentTakes > 0 { try? await Task.sleep(for: .milliseconds(Int(consentTakes * 1000))) }
            guard isCurrent(), !Task.isCancelled else { throw AlphaClient.MailFailure.cancelled }
            let callback = URL(string: "intention-mail://oauth/\(provider.rawValue)?state=\(String(repeating: "s", count: 32))&code=synthetic")!
            return try await client.completeMail(flow: flow, callback: callback, deviceKey: deviceKey)
        }
        func cancel() {}
    }

    /// What the demo's person does, and when.
    @MainActor
    @Observable
    final class Script {
        var granted: Set<SetupPermission> = []
        var phase = FirstDictation.Phase.idle
        var latest: (text: String, at: Date)?
        var languages: [String] = []
        /// Waits the given seconds; the checks wait not at all.
        @ObservationIgnored let wait: @MainActor (Double) async -> Void

        init(wait: @escaping @MainActor (Double) async -> Void = { try? await Task.sleep(for: .milliseconds(Int($0 * 1000))) }) {
            self.wait = wait
        }

        /// The dictation the demo's person makes: listening, then writing,
        /// then the words.
        func speak(_ words: String) async {
            phase = .listening
            await wait(2.6)
            phase = .finishing
            await wait(0.7)
            latest = (words, Date())
            phase = .idle
        }

        /// The script's dictation as the app's page reads it.
        var port: FirstDictation {
            FirstDictation(keyName: { "fn" }, phase: { self.phase }, latest: { self.latest })
        }

        /// From the shortcut page: fn as it comes, then the first dictation
        /// and a moment on the words and the dot, then on to mail.
        func firstDictation(_ model: OnboardingModel) async {
            await wait(3.2)
            model.continueFromShortcut()
            await wait(3.2)
            await speak(OnboardingFixture.demoDictation)
            await wait(3.4)
            model.continueFromDictation()
        }

        func play(_ model: OnboardingModel) async {
            await wait(2.0)
            var typed = ""
            for digit in "482913" {
                typed.append(digit)
                model.enter(typed)
                await wait(0.26)
            }
            // Mail: the three clicks show while the made-up consent runs,
            // then the count climbs.
            await wait(2.6)
            await model.connect(.gmail)
            await wait(6.0)
            model.continueFromMail()
            await wait(2.0)
            await model.request(.microphone)
            await wait(1.3)
            granted = [.microphone]
            await wait(3.4)
            granted = [.microphone, .accessibility]
            await firstDictation(model)
            // The reply to the made-up thread: spoken, written by the
            // scripted writer, read.
            await wait(2.8)
            await speak(PracticeReply.ownCue)
            await wait(7.0)
            // The demo ends on the last question, unanswered: an answer
            // closes the window before the recording ends.
            model.finish()
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var connected: [(provider: String, at: Date)] = []
        /// A fixed mailbox list, for drawing Settings in one state.
        private var fixedConnections: String?
        private var staleReads = 0

        func answerConnections(with json: String) {
            lock.withLock { fixedConnections = json }
        }

        func answer(_ request: URLRequest) -> AlphaStub.Reply {
            let path = request.url?.path ?? ""
            return lock.withLock {
                switch path {
                case "/v1/invites/redeem":
                    return .init(status: 201, json: """
                    {"account_id":"11111111-1111-4111-8111-111111111111","device_id":"22222222-2222-4222-8222-222222222222","device_key":"synthetic-device-key"}
                    """, delay: 0.9)
                case "/v1/mail/gmail/connect", "/v1/mail/outlook/connect":
                    let provider = path.split(separator: "/")[2]
                    let base = provider == "gmail" ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
                    return .init(json: "{\"authorization_url\":\"\(base)?state=\(String(repeating: "s", count: 32))\"}")
                case "/v1/mail/gmail/complete", "/v1/mail/outlook/complete":
                    let provider = String(path.split(separator: "/")[2])
                    connected.removeAll { $0.provider == provider }
                    connected.append((provider, Date()))
                    return .init(json: "{\"connection_id\":\"33333333-3333-4333-8333-333333333330\"}")
                case "/v1/setup/reply-thread":
                    return .init(json: OnboardingFixture.demoThreadJSON)
                case "/v1/mail/connections" where fixedConnections == "failed":
                    return .init(status: 500)
                case "/v1/mail/connections" where fixedConnections == "stale":
                    staleReads += 1
                    return staleReads == 1 ? .init(json: OnboardingFixture.connections("ready")) : .init(status: 500)
                case "/v1/mail/connections" where fixedConnections != nil:
                    return .init(json: fixedConnections!)
                case "/v1/mail/connections":
                    let rows = connected.enumerated().filter { $0.element.at <= Date() }.map { index, mailbox in
                        let seconds = Date().timeIntervalSince(mailbox.at)
                        let total = 4200
                        let stored = min(total, Int(seconds * 640))
                        return """
                        {"id":"33333333-3333-4333-8333-33333333333\(index)","provider":"\(mailbox.provider)",\
                        "address":"synthetic@example.com","state":"\(stored == total ? "ready" : "syncing")",\
                        "stored_messages":\(stored),"blocked_messages":0,"backfill_done":\(stored == total),"reconciling":false,"last_synced_at":null,"error_code":null,"connected_at":"\(mailbox.at.timeIntervalSince1970)"}
                        """
                    }
                    return .init(json: #"{"connections":["# + rows.joined(separator: ",") + "]}")
                default:
                    return .init(status: 404)
                }
            }
        }
    }
}
extension OnboardingFixture {
    /// A key check still taken on a page it doesn't show.
    struct WrongPage: Error, CustomStringConvertible {
        let still: String, step: OnboardingModel.Step, check: OnboardingModel.KeyCheck?
        var description: String { "\(still) would show \(step.rawValue) with key check \(check.map { "\($0)" } ?? "none")" }
    }

    /// The key check's stills, `--fn-reliability-snapshots`, in setup's own
    /// order. `model` is signed in on the mail page with both permissions
    /// allowed and a backend whose mailbox list has a mailbox, so it goes on
    /// past mail, and past permissions as setup does once both are allowed,
    /// to the shortcut and the first dictation, whose key row shows each
    /// state. `still` is called only once the model is on the page and in
    /// the state its still is named for; anything else throws, so a change
    /// to setup's order fails the render instead of saving the wrong page.
    @MainActor
    static func keyCheckStills(_ model: OnboardingModel, listener: FnListenerHealth,
                               still: (String) async throws -> Void) async throws {
        func on(_ step: OnboardingModel.Step, _ check: OnboardingModel.KeyCheck?, for name: String) throws {
            guard model.step == step, model.firstKeyCheck == check else {
                throw WrongPage(still: name, step: model.step, check: model.firstKeyCheck)
            }
        }
        guard model.step == .mail else { throw WrongPage(still: "mail", step: model.step, check: nil) }
        await model.refreshMail()
        guard !model.connections.isEmpty else { throw WrongPage(still: "mail connected", step: model.step, check: nil) }
        model.continueFromMail()
        guard model.step == .shortcut else { throw WrongPage(still: "shortcut", step: model.step, check: nil) }
        model.continueFromShortcut()
        try on(.tryIt, .waiting, for: "fn-waiting")
        try await still("fn-waiting")
        listener.update(.live)
        listener.receivedTrigger(down: true, at: 1, date: Date())
        listener.receivedTrigger(down: false, at: 2, date: Date())
        try on(.tryIt, .works, for: "fn-works")
        try await still("fn-works")
        listener.update(.failed)
        try on(.tryIt, .problem(.failed), for: "fn-failed")
        try await still("fn-failed")
        listener.update(.blockedBySecureInput)
        try on(.tryIt, .problem(.blockedBySecureInput), for: "fn-secure")
        try await still("fn-secure")
        // Going on with the listener still unable to hear is the skip.
        model.continueFromDictation()
        await model.refreshReplySubject()
        guard model.step == .reply, model.keyCheckSkipped else {
            throw WrongPage(still: "fn-skipped", step: model.step, check: model.firstKeyCheck)
        }
        try await still("fn-skipped")
    }
}
#endif
