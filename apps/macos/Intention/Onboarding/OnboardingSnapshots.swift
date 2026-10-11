#if OFFSCREEN_RENDER
import AppKit
import SwiftUI

/// `--onboarding-snapshots <directory>` draws each setup page to a PNG and
/// quits. The pages are drawn off screen from scripted
/// state: no window appears, and no network, keychain or permission is
/// touched, so it also runs beside another development instance.
@MainActor
enum OnboardingSnapshots {
    static func renderIfRequested(arguments: [String]) {
        OffscreenRenderGuard.requireInstalled()
        if let index = arguments.firstIndex(of: "--fn-reliability-snapshots"), arguments.indices.contains(index + 1) {
            var failed: Bool?
            NSApp.setActivationPolicy(.prohibited)
            Task {
                do { try await renderFn(to: URL(fileURLWithPath: arguments[index + 1])); failed = false }
                catch { print(error); failed = true }
            }
            while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
            exit(failed == true ? 1 : 0)
        }
        guard let index = arguments.firstIndex(of: "--onboarding-snapshots"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        var failed: Bool?
        Task {
            do {
                try await render(to: directory)
                failed = false
            } catch {
                failed = true
            }
        }
        while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
        exit(failed == true ? 1 : 0)
    }

    /// The browser's sign-in, scripted: open until cancelled, or at once
    /// returning `answer`, a callback or nil for a sign-in closed unfinished.
    private final class SnapshotConsent: MailConsentSession {
        private let returned: (@Sendable (URL?) -> Void)?
        private let answer: URL??

        init(returned: (@Sendable (URL?) -> Void)? = nil, answer: URL?? = .none) {
            self.returned = returned
            self.answer = answer
        }

        func start() -> Bool {
            if let answer, let returned { returned(answer) }
            return true
        }

        func cancel() {}
    }

    /// The callback a provider sends when the person declines, for the
    /// state in `authorization`.
    private static func declined(_ authorization: URL) -> URL? {
        let state = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        return URL(string: "intention-mail://oauth/gmail?state=\(state ?? "")&error=denied")
    }

    private static let registration = #"{"account_id":"11111111-1111-4111-8111-111111111111","device_id":"22222222-2222-4222-8222-222222222222","device_key":"synthetic-device-key"}"#

    /// `sent` is the sent mail read and, when the server knows it, the
    /// total, sent both on the connection and as the list's `learning`.
    private static func mailbox(_ state: String, _ stored: Int, voiceReady: Bool = false, sent: (read: Int, total: Int?)? = nil) -> String {
        let read = sent.map { "\($0.read)" } ?? "null"
        let total = sent?.total.map { "\($0)" } ?? "null"
        let percent = sent.flatMap { sent in sent.total.map { "\(sent.read * 100 / max(1, $0))" } } ?? "null"
        let stage = voiceReady ? "ready" : state == "ready" ? "learning" : "reading"
        let learning = sent == nil && !voiceReady ? "" : #","learning":{"stage":"\#(stage)","percent":\#(voiceReady ? "100" : percent),"sent_read":\#(read),"sent_total":\#(total),"connection_id":"33333333-3333-4333-8333-333333333333"}"#
        return #"{"connections":[{"id":"33333333-3333-4333-8333-333333333333","provider":"gmail","address":"synthetic@example.com","state":"\#(state)","stored_messages":\#(stored),"backfill_done":\#(state == "ready"),"blocked_messages":0,"reconciling":false,"last_synced_at":null,"error_code":null,"connected_at":"2026-10-03T10:00:00Z","voice_ready":\#(voiceReady),"voice_examples":\#(voiceReady ? 4 : 1),"sent_read":\#(read),"sent_total":\#(total)}]\#(learning)}"#
    }

    /// A model on the scripted backend and grants, at sign-in or signed
    /// in, with the scripted dictation and writer.
    private static func model(_ granted: Grants, _ speech: Speech, _ writer: Writer,
                              signedIn: Bool, screenRecordingDue: Bool = true,
                              mail: MailAuthentication = MailAuthentication(makeSession: { _, _ in SnapshotConsent() })) -> OnboardingModel {
        let suite = "co.intention.mac.onboarding-snapshots." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey(signedIn ? "synthetic-device-key" : nil),
            permissions: SetupPermissions(isGranted: { granted.set.contains($0) }, request: { _ in }),
            mail: mail,
            dictation: FirstDictation(isAvailable: { speech.available }, keyName: { speech.key }, phase: { speech.phase }, latest: { speech.latest },
                                      missed: { speech.missed }, silent: { speech.silent },
                                      silenceWasMicrophone: { speech.silenceWasMicrophone },
                                      keyNames: { ["fn", "right option", "right command", "Control + Option", "Control + Command", "Option + Command"] },
                                      chooseKey: { speech.key = $0 }, recording: { speech.recording },
                                      startRecording: { if speech.recordingStarts { speech.recording = FirstDictation.Recording(isRecording: true) } },
                                      cancelRecording: { speech.recording = FirstDictation.Recording() },
                                      hasFnKey: { speech.hasFn },
                                      listener: speech.listener),
            practice: PracticeReply(isAvailable: { writer.isAvailable }, write: { _, _, _ in await writer.answer() }),
            languages: DictationLanguages(current: { speech.languages }, save: { speech.languages = $0 }),
            loginItem: SetupLoginItem(isOn: { false }, answer: { _ in }),
            screenRecordingDue: { screenRecordingDue },
            fullName: OnboardingFixture.syntheticName, preferredLanguages: ["en-US", "es-MX", "hi-IN"],
            defaults: defaults, settle: .milliseconds(300)
        )
        model.mailAnchor = NSWindow()
        return model
    }

    private static func renderFn(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SetupStyle.registerFonts()
        FirstDictationField.still = true
        SetupMotion.isStill = true
        // Mail comes first, so the key check is reached with a mailbox
        // connected, as `render` connects one.
        let replies = Replies()
        AlphaStub.answer = { replies.answer($0) }
        replies.set("/v1/mail/connections", .init(json: mailbox("ready", 6120)))
        replies.set("/v1/setup/reply-thread", .init(json: OnboardingFixture.demoThreadJSON))
        let grants = Grants()
        grants.set = [.microphone, .accessibility]
        for appearance in [Appearance.light, .dark] {
            Appearance.current = appearance
            let speech = Speech()
            let model = model(grants, speech, Writer(), signedIn: true)
            // At the screen's scale, and at 1x for a screen without Retina.
            try await OnboardingFixture.keyCheckStills(model, listener: speech.listener) { name in
                try await save(model, "\(name)-\(appearance.rawValue)", in: directory)
                try await save(model, "\(name)-\(appearance.rawValue)@1x", in: directory, scale: 1)
            }
        }
    }

    private static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let replies = Replies()
        AlphaStub.answer = { replies.answer($0) }
        let granted = Grants(), speech = Speech(), writer = Writer()
        SetupStyle.registerFonts()
        FirstDictationField.still = true
        SetupMotion.isStill = true
        let pause = Duration.milliseconds(450)

        // Sign in.
        let model = model(granted, speech, writer, signedIn: false)
        replies.set("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        try await save(model, "01-sign-in", in: directory)
        model.enter("482")
        try await save(model, "02-sign-in-typing", in: directory)
        replies.set("/v1/invites/redeem", .init(status: 401))
        model.enter("482913")
        try await Task.sleep(for: .milliseconds(100))
        try await save(model, "03-sign-in-refused", in: directory)
        replies.set("/v1/invites/redeem", .init(status: 201, json: registration))
        model.enter("https://demo.intention.example/invite#482 913")
        try await Task.sleep(for: .milliseconds(60))
        try await save(model, "04-sign-in-accepted", in: directory)
        try await Task.sleep(for: pause)

        // Mail, straight after sign-in: the offer, the browser's three
        // clicks, the import that runs through the rest of setup.
        replies.set("/v1/mail/connections", .init(json: #"{"connections":[]}"#, delay: 0.5))
        try await save(model, "05-mail-checking", in: directory)
        replies.set("/v1/mail/connections", .init(status: 500))
        await model.refreshMail()
        try await save(model, "05-mail-failed", in: directory)
        replies.set("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.refreshMail()
        try await save(model, "05-mail", in: directory)
        replies.set("/v1/mail/gmail/connect", .init(json: "{\"authorization_url\":\"https://accounts.google.com/o/oauth2/v2/auth?state=\(String(repeating: "s", count: 32))\"}"))
        let consent = Task { await model.connect(.gmail) }
        try await Task.sleep(for: .milliseconds(100))
        try await save(model, "06-mail-browser", in: directory)
        model.windowClosed()
        await consent.value
        replies.set("/v1/mail/connections", .init(json: mailbox("syncing", 1240)))
        await model.refreshMail()
        try await save(model, "07-mail-importing", in: directory)
        model.continueFromMail()

        // Permissions: one Allow, the microphone's tick, the list to find.
        try await save(model, "08-permissions", in: directory)
        await model.request(.microphone)
        granted.set = [.microphone]
        model.refreshPermissions()
        try await Task.sleep(for: pause)
        await model.request(.accessibility)
        try await save(model, "09-permissions-list", in: directory)
        granted.set = [.microphone, .accessibility]
        model.refreshPermissions()
        try await save(model, "10-permissions-allowed", in: directory)
        try await Task.sleep(for: pause)

        // The shortcut: fn, the shared recorder listening, a refusal, keys
        // recorded, and a keyboard without fn, which leads with recording.
        model.readKeyboards()
        try await save(model, "10b-shortcut", in: directory)
        model.recordShortcut()
        speech.recording = FirstDictation.Recording(isRecording: true, shown: "right option")
        try await save(model, "10c-shortcut-recording", in: directory)
        speech.recording = FirstDictation.Recording(isRecording: true, shown: nil, refusal: "Shift on its own would start with every capital letter. Try fn or two keys together.")
        try await save(model, "10d-shortcut-refused", in: directory)
        speech.recording = FirstDictation.Recording(isRecording: true)
        model.checkShortcut(at: Date().addingTimeInterval(OnboardingModel.recordingWait + 1))
        try await save(model, "10h-shortcut-nothing-pressed", in: directory)
        // Each render's page task ends with its view and stops the recorder,
        // as closing the window does; this one listens again.
        speech.recording = FirstDictation.Recording(isRecording: true)
        speech.listener.update(.failed)
        try await save(model, "10i-shortcut-keyboard-unheard", in: directory)
        speech.listener.update(.checking)
        speech.recording = FirstDictation.Recording()
        speech.recordingStarts = false
        model.recordShortcut()
        try await save(model, "10j-shortcut-could-not-start", in: directory)
        speech.recordingStarts = true
        model.useFn()
        speech.recording = FirstDictation.Recording()
        speech.key = "Control + Option"
        try await save(model, "10e-shortcut-recorded", in: directory)
        speech.listener.receivedTrigger(down: true, at: 1, date: Date())
        try await save(model, "10f-shortcut-held", in: directory)
        speech.listener.receivedTrigger(down: false, at: 2, date: Date())
        speech.hasFn = false
        speech.key = "fn"
        model.readKeyboards()
        try await save(model, "10g-shortcut-no-fn", in: directory)
        speech.hasFn = true
        model.readKeyboards()
        model.continueFromShortcut()

        // The first dictation, its key check, what went wrong, and the page
        // when dictation cannot run.
        try await save(model, "11-try-it", in: directory)
        speech.listener.update(.live)
        speech.listener.receivedOtherKey("right command", date: Date())
        try await save(model, "11b-try-it-other-key", in: directory)
        model.checkFirstKey(at: Date().addingTimeInterval(OnboardingModel.keyCheckWait + 1))
        speech.listener.resetProof()
        try await save(model, "11c-try-it-key-not-seen", in: directory)
        speech.listener.receivedTrigger(down: true, at: 1, date: Date())
        speech.listener.receivedTrigger(down: false, at: 2, date: Date())
        try await save(model, "11d-try-it-key-works", in: directory)
        speech.silent = Date()
        speech.silenceWasMicrophone = true
        try await save(model, "11e-try-it-microphone-silent", in: directory)
        speech.silenceWasMicrophone = false
        speech.silent = nil
        speech.missed = Date()
        try await save(model, "11f-try-it-server", in: directory)
        model.retryFirstDictation()
        speech.missed = nil
        model.retryFirstKey()
        speech.available = false
        try await save(model, "11-try-it-unavailable", in: directory)
        speech.available = true
        model.toggleLanguage("hi")
        try await save(model, "12-try-it-two-languages", in: directory)
        model.toggleLanguage("hi")
        speech.phase = .listening
        try await save(model, "13-try-it-listening", in: directory)
        speech.phase = .idle
        speech.silent = Date()
        try await save(model, "14-try-it-silent", in: directory)
        speech.latest = (OnboardingFixture.demoDictation, Date())
        try await save(model, "15-try-it-heard", in: directory)
        model.continueFromDictation()

        // The reply to one of the person's own threads, here the made-up
        // one: spoken, with the writer, written; and typed when no email
        // came.
        speech.silent = nil
        replies.set("/v1/setup/reply-thread", .init(json: OnboardingFixture.demoThreadJSON))
        await model.refreshReplySubject()
        try await save(model, "17-reply-own-waiting", in: directory)
        // Setup keeps the day design under a Mac set to Dark.
        Appearance.current = .dark
        try await save(model, "17-reply-own-waiting-mac-dark", in: directory)
        Appearance.current = .light
        speech.phase = .listening
        try await save(model, "18-reply-own-listening", in: directory)
        speech.phase = .idle
        speech.latest = (PracticeReply.ownCue, Date())
        let writing = Task { await model.replyTick() }
        try await Task.sleep(for: .milliseconds(100))
        try await save(model, "19-reply-own-writing", in: directory)
        writer.finish(.success(OnboardingFixture.demoOwnReply))
        await writing.value
        try await save(model, "20-reply-own-written", in: directory)
        Appearance.current = .dark
        try await save(model, "20-reply-own-written-mac-dark", in: directory)
        Appearance.current = .light
        speech.latest = ("tell them Cedar Ridge", Date())
        let typing = Task { await model.replyTick() }
        try await Task.sleep(for: .milliseconds(50))
        writer.finish(.failure(PracticeReply.Failure(name: "abstained.timeout")))
        await typing.value
        try await save(model, "21-reply-typed", in: directory)
        speech.latest = ("say Cedar Ridge works", Date())
        let pending = Task { await model.replyTick() }
        try await Task.sleep(for: .milliseconds(50))
        writer.finish(.failure(PracticeReply.Failure(name: "abstained.mail_import_pending")))
        await pending.value
        try await save(model, "21b-reply-typed-import-pending", in: directory)
        // A fresh account's mail still being read when the writer is asked.
        speech.latest = ("tell her 1 works", Date())
        let preparing = Task { await model.replyTick() }
        try await Task.sleep(for: .milliseconds(50))
        writer.finish(.failure(PracticeReply.Failure(name: "abstained.context_preparing")))
        await preparing.value
        try await save(model, "21b-reply-mail-still-read", in: directory)
        model.finish()
        // The last page as most people reach it: the mail still coming in.
        replies.set("/v1/mail/connections", .init(json: mailbox("syncing", 6120, sent: (1240, 3000))))
        await model.refreshMail()
        try await save(model, "22-open-at-login", in: directory)
        replies.set("/v1/mail/connections", .init(json: mailbox("syncing", 6120, sent: (1240, nil))))
        await model.refreshMail()
        try await save(model, "22-open-at-login-no-total", in: directory)
        replies.set("/v1/mail/connections", .init(json: mailbox("syncing", 6120)))
        await model.refreshMail()
        try await save(model, "22-open-at-login-no-counts", in: directory)
        replies.set("/v1/mail/connections", .init(json: mailbox("ready", 6120, sent: (2, 2))))
        await model.refreshMail()
        try await save(model, "22-open-at-login-imported", in: directory)
        replies.set("/v1/mail/connections", .init(json: mailbox("syncing", 9480, voiceReady: true, sent: (3000, 3000))))
        await model.refreshMail()
        try await save(model, "22-open-at-login-voice-ready", in: directory)

        // Maya's message, when the import isn't far enough along or no
        // thread is waiting on the person, written as before.
        for (reason, name) in [("preparing", "23-reply-fallback-preparing"), ("no_candidate", "23-reply-fallback-no-candidate")] {
            let fallback = self.model(granted, speech, writer, signedIn: true, screenRecordingDue: false)
            replies.set("/v1/mail/connections", .init(json: mailbox("syncing", 320)))
            replies.set("/v1/setup/reply-thread", .init(json: #"{"thread":null,"reason":"\#(reason)"}"#))
            await fallback.refreshMail()
            fallback.continueFromMail()
            fallback.continueFromShortcut()
            fallback.continueFromDictation()
            await fallback.refreshReplySubject()
            try await save(fallback, name, in: directory)
            if reason == "preparing" {
                speech.latest = (PracticeReply.directCue, Date())
                let maya = Task { await fallback.replyTick() }
                try await Task.sleep(for: .milliseconds(50))
                writer.finish(.success(PracticeReply.exampleEmail))
                await maya.value
                try await save(fallback, "24-reply-fallback-written", in: directory)
            }
        }

        // The moment before the server answers which thread to show.
        let looking = self.model(granted, speech, writer, signedIn: true, screenRecordingDue: false)
        replies.set("/v1/mail/connections", .init(json: mailbox("syncing", 320)))
        replies.set("/v1/setup/reply-thread", .init(stalls: true))
        await looking.refreshMail()
        looking.continueFromMail()
        looking.continueFromShortcut()
        looking.continueFromDictation()
        try await save(looking, "16-reply-looking", in: directory)

        // The reply page without a mailbox shows the example, and the last
        // page without Screen Recording to ask for shows the login row.
        let skipped = self.model(granted, speech, writer, signedIn: true, screenRecordingDue: false)
        replies.set("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        skipped.continueFromMail()
        skipped.continueFromShortcut()
        skipped.continueFromDictation()
        try await save(skipped, "25-reply-example", in: directory)
        speech.latest = (PracticeReply.directCue, Date())
        try await save(skipped, "25b-reply-example-heard", in: directory)
        skipped.finish()
        try await save(skipped, "26-open-at-login-plain", in: directory)

        // New Gmail sign-ins closed, with Outlook offered and without, and
        // with a Gmail mailbox already connected; then a Gmail sign-in
        // declined, closed unfinished and timed out.
        let closed = #","gmail_connect_open":false}"#
        for (providers, name) in [(#"["gmail","outlook"]"#, "05b-mail-gmail-closed-outlook"), (#"["gmail"]"#, "05c-mail-gmail-closed")] {
            let capped = self.model(granted, speech, writer, signedIn: true)
            replies.set("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":\#(providers)"# + closed))
            await capped.refreshMail()
            try await save(capped, name, in: directory)
        }
        let kept = self.model(granted, speech, writer, signedIn: true)
        replies.set("/v1/mail/connections", .init(json: String(mailbox("syncing", 1240).dropLast()) + closed))
        await kept.refreshMail()
        try await save(kept, "05d-mail-gmail-closed-connected", in: directory)
        replies.set("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":["gmail","outlook"]}"#))
        let sessions: [(MailAuthentication, String)] = [
            (MailAuthentication(makeSession: { url, returned in SnapshotConsent(returned: returned, answer: declined(url)) }), "06b-mail-denied"),
            (MailAuthentication(makeSession: { _, returned in SnapshotConsent(returned: returned, answer: .some(nil)) }), "06c-mail-cancelled"),
            (MailAuthentication(makeSession: { _, _ in SnapshotConsent() }, consentTimeout: .milliseconds(80)), "06d-mail-timed-out"),
        ]
        for (mail, name) in sessions {
            let failing = self.model(granted, speech, writer, signedIn: true, mail: mail)
            await failing.refreshMail()
            await failing.connect(.gmail)
            try await save(failing, name, in: directory)
        }

        // The guide at a drawn stand-in for the System Settings window, placed
        // by the same layout the live guide uses.
        let scenes: [(String, GuideScene)] = [
            ("settings-guide-list", GuideScene(windowX: 150, mark: .list)),
            ("settings-guide-row", GuideScene(windowX: 120, mark: .row)),
            ("settings-guide-row-screen-edge", GuideScene(windowX: GuideScene.screen.width - GuideScene.window.width - 6, mark: .row)),
            // The Screen Recording guide outside setup follows Settings' Dark.
            ("settings-guide-list-dark", GuideScene(windowX: 150, mark: .list, look: .dark)),
            ("settings-guide-row-dark", GuideScene(windowX: 120, mark: .row, look: .dark)),
        ]
        for (name, scene) in scenes {
            try await composed(scene, size: GuideScene.screen, to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// Draws `scene` off screen at 2x with SwiftUI's own renderer, which
    /// keeps the guide's float, two blurred shapes that `cacheDisplay`
    /// draws sharp, and orders no window onto the screen.
    private static func composed(_ scene: some View, size: CGSize, to file: URL) async throws {
        let renderer = ImageRenderer(content: scene.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
    }

    /// A screen with a window drawn like System Settings' permission list,
    /// Intention's line second, and the guide over it. Every name is made up.
    private struct GuideScene: View {
        enum Mark { case list, row }

        static let screen = CGSize(width: 1100, height: 680)
        static let window = CGSize(width: 715, height: 470)
        private static let names = ["Clipboard Tool", "Intention", "Keyboard Helper", "Notes Sync", "Window Manager"]
        private static let rowTop: CGFloat = 112
        private static let rowHeight: CGFloat = 44
        private static let toggle = CGSize(width: 32, height: 19)

        let windowX: CGFloat
        let mark: Mark
        var look: Appearance = .light
        private let windowTop: CGFloat = 70

        var body: some View {
            let height = Self.screen.height
            // The stand-in's frames in AppKit screen coordinates, measured
            // from the bottom left, as the live guide receives them.
            let window = CGRect(x: windowX, y: height - windowTop - Self.window.height, width: Self.window.width, height: Self.window.height)
            let toggleTop = windowTop + Self.rowTop + Self.rowHeight + (Self.rowHeight - Self.toggle.height) / 2
            let toggle = CGRect(x: window.maxX - 34 - Self.toggle.width, y: height - toggleTop - Self.toggle.height,
                                width: Self.toggle.width, height: Self.toggle.height)
            let screen = CGRect(origin: .zero, size: Self.screen)
            let content: SettingsGuideView.Content
            let panel: CGRect
            switch mark {
            case .list:
                content = .list
                panel = SettingsGuideLayout.listPanel(window: window, screen: screen)
            case .row:
                let row = SettingsGuideLayout.row(toggle: toggle, window: window, screen: screen)
                content = .row(row)
                panel = row.panel
            }
            return ZStack(alignment: .topLeading) {
                Color(red: 0.42, green: 0.50, blue: 0.58)
                settings.offset(x: windowX, y: windowTop)
                SettingsGuideView(content: content, look: look)
                    .frame(width: panel.width, height: panel.height)
                    .offset(x: panel.minX, y: height - panel.maxY)
            }
            .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topLeading)
            .environment(\.colorScheme, .light)
        }

        private var settings: some View {
            let gray = Color(white: 0.93)
            return ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.985))
                RoundedRectangle(cornerRadius: 12).fill(gray).frame(width: 210)
                Text("Privacy & Security")
                    .font(.system(size: 15, weight: .bold))
                    .offset(x: 230, y: 64)
                VStack(spacing: 0) {
                    ForEach(Array(Self.names.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 10) {
                            Group {
                                if name == "Intention" {
                                    Image(nsImage: SetupStyle.image("AppIcon", "icns")).resizable()
                                } else {
                                    RoundedRectangle(cornerRadius: 6).fill(Color(hue: Double(index) / 5, saturation: 0.35, brightness: 0.8))
                                }
                            }
                            .frame(width: 24, height: 24)
                            Text(name).font(.system(size: 13))
                            Spacer()
                            Capsule().fill(Color(white: 0.82))
                                .frame(width: Self.toggle.width, height: Self.toggle.height)
                                .overlay(alignment: .leading) { Circle().fill(.white).frame(width: 15).padding(.leading, 2) }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: Self.rowHeight)
                        .overlay(alignment: .bottom) { if index < Self.names.count - 1 { Divider().padding(.leading, 48) } }
                    }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(gray))
                .frame(width: Self.window.width - 230 - 20)
                .offset(x: 230, y: Self.rowTop)
            }
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: Self.window.width, height: Self.window.height, alignment: .topLeading)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
    }

    /// `scale` draws at that many pixels a point instead of the screen's.
    private static func save(_ model: OnboardingModel, _ name: String, in directory: URL, scale: Int? = nil) async throws {
        do {
            let frame = CGRect(origin: .zero, size: OnboardingView.size)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.appearance = Appearance.current.nsAppearance
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let host = NSHostingView(rootView: OnboardingView(model: model) { _ in })
            host.sizingOptions = []
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Let SwiftUI settle its first layout before drawing.
            try await Task.sleep(for: .milliseconds(120))
            let fixed = scale.flatMap { scale in
                NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width) * scale, pixelsHigh: Int(frame.height) * scale,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            }
            fixed?.size = frame.size
            guard let bitmap = fixed ?? host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: AlphaStub.Reply] = [:]

        func set(_ path: String, _ reply: AlphaStub.Reply) {
            lock.withLock { replies[path] = reply }
        }

        func answer(_ request: URLRequest) -> AlphaStub.Reply {
            lock.withLock { replies[request.url?.path ?? ""] ?? .init(status: 404) }
        }
    }

    @MainActor
    private final class Grants {
        var set: Set<SetupPermission> = []
    }

    @MainActor
    private final class Speech {
        let listener = FnListenerHealth()
        var available = true
        var languages: [String] = []
        var phase = FirstDictation.Phase.idle
        var latest: (text: String, at: Date)?
        var missed: Date?
        var silent: Date?
        var silenceWasMicrophone = false
        var key = "fn"
        var recording = FirstDictation.Recording()
        var recordingStarts = true
        var hasFn: Bool? = true
    }

    /// The scripted writer: each ask waits until the render finishes it.
    @MainActor
    private final class Writer {
        var isAvailable = true
        private var pending: CheckedContinuation<Result<String, PracticeReply.Failure>, Never>?

        func answer() async -> Result<String, PracticeReply.Failure> {
            await withCheckedContinuation { pending = $0 }
        }

        func finish(_ result: Result<String, PracticeReply.Failure>) {
            pending?.resume(returning: result)
            pending = nil
        }
    }
}
#endif
