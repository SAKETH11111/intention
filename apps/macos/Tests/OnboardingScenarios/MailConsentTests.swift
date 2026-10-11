import AppKit
@testable import Onboarding
import Testing

// Shares the existing serialized suite because AlphaStub has one responder.
extension OnboardingScenarioTests {
    @Test func nativeConsentReportsStartFailureAndTimeoutSeparately() async throws {
        for starts in [false, true] {
            let world = NativeMail.World()
            world.consentStarts = starts
            world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
            AlphaStub.answer = { world.answer($0) }
            let client = try #require(AlphaStub.client())
            let mail = MailAuthentication(makeSession: { url, callback in
                world.makeConsent(url, callback: callback)
            }, consentTimeout: .zero)
            do {
                _ = try await mail.connect(provider: .gmail, client: client,
                                           deviceKey: "synthetic-device-key", anchor: NSWindow())
                Issue.record("A failed consent session must report its reason")
            } catch AlphaClient.MailFailure.couldNotOpen {
                #expect(!starts)
            } catch AlphaClient.MailFailure.timedOut {
                #expect(starts)
            } catch {
                Issue.record("Consent reported the wrong failure")
            }
            #expect(world.sessions.first?.cancelled == true)
            #expect(world.sent("/v1/mail/gmail/complete") == 0)
        }
    }

    @Test func consentFailuresRemainVisibleUntilAnotherConnectSucceeds() async {
        for starts in [false, true] {
            let world = NativeMail.World()
            world.consentStarts = starts
            let model = NativeMail.model(world, consentTimeout: .seconds(1))
            world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
            await model.connect(.gmail)
            #expect(model.mailProblem == (starts ? .timedOut : .couldNotOpen))
            #expect(!model.isConnecting)
            #expect(model.awaiting == nil)
            #expect(world.sessions.first?.cancelled == true)
            #expect(world.sent("/v1/mail/gmail/complete") == 0)
            await model.refreshMail()
            #expect(model.mailProblem == (starts ? .timedOut : .couldNotOpen))

            let abandoned = world.consentCallback
            world.consentStarts = true
            world.reply("/v1/mail/gmail/complete", .init(json: "{\"connection_id\":\"\(NativeMail.connectionID)\"}"))
            world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 12)))
            let retry = Task { await model.retryMail() }
            #expect(await NativeMail.eventually { world.sessions.count == 2 })
            #expect(model.mailProblem == nil)
            abandoned?(nil)
            world.consentCallback?(NativeMail.callback())
            await retry.value
            #expect(model.mailProblem == nil)
            #expect(!model.isConnecting)
            #expect(model.connections.first?.storedMessages == 12)
            #expect(world.sent("/v1/mail/gmail/complete") == 1)
            #expect(world.returns == 1)
        }
    }

    @Test func missingCallbackOffersRetryAndDictation() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        let connecting = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        let callback = world.consentCallback
        await Task.detached { callback?(nil) }.value
        await connecting.value
        #expect(model.mailProblem == .cancelled)
        #expect(model.retryMailProvider == .gmail)
        #expect(!model.isConnecting)
        #expect(model.awaiting == nil)
        #expect(world.sent("/v1/mail/gmail/complete") == 0)
        model.continueWithDictationOnly()
        #expect(model.step == .tryIt)
        model.continueFromDictation()
        #expect(model.step == .done)
        #expect(model.recapOffers == .init(writesEmails: false, proposesReplies: false))
    }

    @Test func delayedRetryCannotStartConsentAfterSetupClosesAndReopens() async {
        let world = NativeMail.World(), model = NativeMail.model(world, consentTimeout: .milliseconds(20))
        #expect(await NativeMail.declineMail(model, world: world))
        #expect(model.retryMailProvider == .gmail)
        let reads = world.sent("/v1/mail/connections")
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#, delay: 0.1))
        let retry = Task { await model.retryMail() }
        #expect(await NativeMail.eventually { world.sent("/v1/mail/connections") > reads })
        model.windowClosed()
        model.mailAnchor = NSWindow()
        #expect(model.step == .mail)
        await retry.value
        #expect(world.sent("/v1/mail/gmail/connect") == 1)
        #expect(world.sessions.count == 1)
        #expect(!model.isConnecting)
    }

    @Test(arguments: [false, true])
    func closedGmailRespectsOutlookFlagAndDictationAcrossRelaunch(_ offersOutlook: Bool) async {
        let world = NativeMail.World(), defaults = NativeMail.defaults()
        let model = NativeMail.model(world, defaults: defaults, offersOutlook: offersOutlook)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":["gmail","outlook"],"gmail_connect_open":false}"#))
        await model.refreshMail()
        #expect(!model.gmailConnectOpen)
        #expect(model.mailOffer(for: .gmail) == .nothing)
        #expect(model.mailOffer(for: .outlook) == (offersOutlook ? .connect : .nothing))
        #expect(model.offeredMailProviders == (offersOutlook ? [.outlook] : []))
        #expect(model.mailPageHeight == 112)
        await model.connect(.gmail)
        #expect(world.sent("/v1/mail/gmail/connect") == 0)
        model.continueFromMail()
        #expect(model.step == .tryIt)
        #expect(model.dictationOnlySetup)
        let resumed = NativeMail.model(world, defaults: defaults)
        #expect(resumed.step == .tryIt)
        #expect(resumed.dictationOnlySetup)
        resumed.continueFromDictation()
        #expect(resumed.step == .done)
        #expect(world.sent("/v1/setup/reply-thread") == 0)
    }

    @Test func continueWithDictationCancelsConsentAndIgnoresALateCallback() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        let pending = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        let callback = world.consentCallback
        model.continueWithDictationOnly()
        let returned = NativeMail.callback()
        await Task.detached { callback?(returned) }.value
        await pending.value
        #expect(!model.isConnecting)
        #expect(model.mailProblem == nil)
        #expect(world.sessions.first?.cancelled == true)
        #expect(world.sent("/v1/mail/gmail/complete") == 0)
        model.continueFromDictation()
        #expect(model.step == .done)
    }

    @Test func staleOpenGmailAnswerIsClosedAtConnectWithoutBlockingSetup() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        await model.refreshMail()
        #expect(model.gmailConnectOpen)
        world.reply("/v1/mail/gmail/connect", .init(status: 409))
        await model.connect(.gmail)
        #expect(!model.gmailConnectOpen)
        #expect(model.mailProblem == nil)
        #expect(!model.isConnecting)
        model.continueFromMail()
        model.continueFromDictation()
        #expect(model.step == .done)
    }

    @Test(arguments: ["ready", "reconnect_required"])
    func closedDifferentIdentityExplainsRefusalAndLetsExistingGmailRetry(_ state: String) async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        let existing = NativeMail.connection(state: state, stored: 140)
            .dropLast() + #", "gmail_connect_open":false}"#
        world.reply("/v1/mail/connections", .init(json: String(existing)))
        await model.refreshMail()
        let unchanged = model.connections
        let offer: OnboardingModel.MailOffer = state == "ready" ? .nothing : .reconnect
        #expect(model.mailOffer(for: .gmail) == offer)
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        world.reply("/v1/mail/gmail/complete", .init(status: 409))
        let connect = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        let callback = world.consentCallback
        let returned = NativeMail.callback()
        await Task.detached { callback?(returned) }.value
        await connect.value
        #expect(model.mailProblem == .gmailClosed)
        #expect(model.retryMailProvider == .gmail)
        #expect(model.connections == unchanged)
        #expect(model.mailOffer(for: .gmail) == offer)
        await model.refreshMail()
        #expect(model.mailProblem == .gmailClosed)
        #expect(model.retryMailProvider == .gmail)
        world.reply("/v1/mail/gmail/complete", .init(json: "{\"connection_id\":\"\(NativeMail.connectionID)\"}"))
        let retry = Task { await model.retryMail() }
        #expect(await NativeMail.eventually { world.sessions.count == 2 })
        world.consentCallback?(NativeMail.callback())
        await retry.value
        #expect(model.mailProblem == nil)
        #expect(model.connections == unchanged)
        #expect(world.sent("/v1/mail/gmail/complete") == 2)
    }

    @Test func closedGmailCanConnectOutlookAndKeepTheReplyExercise() async {
        let world = NativeMail.World(), model = NativeMail.model(world, offersOutlook: true)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":["gmail","outlook"],"gmail_connect_open":false}"#))
        await model.refreshMail()
        world.reply("/v1/mail/outlook/connect", .init(json: NativeMail.consent("outlook")))
        world.reply("/v1/mail/outlook/complete", .init(json: "{\"connection_id\":\"\(NativeMail.connectionID)\"}"))
        let connecting = Task { await model.connect(.outlook) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        let json = String(NativeMail.connection("outlook").dropLast()) + #","available_providers":["gmail","outlook"],"gmail_connect_open":false}"#
        world.reply("/v1/mail/connections", .init(json: json))
        world.consentCallback?(NativeMail.callback("outlook"))
        await connecting.value
        #expect(model.availableConnections.count == 1)
        model.continueFromMail()
        model.continueFromDictation()
        #expect(model.step == .reply)
        #expect(!model.dictationOnlySetup)
    }

    @Test func aConsentTimeoutCanFinishSetupWithDictationOnly() async {
        let world = NativeMail.World(), model = NativeMail.model(world, consentTimeout: .milliseconds(20))
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        await model.connect(.gmail)
        #expect(model.mailProblem == .timedOut)
        #expect(model.retryMailProvider == .gmail)
        model.continueWithDictationOnly()
        model.continueFromDictation()
        #expect(model.step == .done)
        #expect(!model.isConnecting)
    }

    @Test func aConnectedMailboxRemainsUsableWhenNewGmailCloses() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        let json = String(NativeMail.connection().dropLast()) + #","available_providers":["gmail"],"gmail_connect_open":false}"#
        world.reply("/v1/mail/connections", .init(json: json))
        await model.refreshMail()
        #expect(model.availableConnections.count == 1)
        model.continueFromMail()
        #expect(!model.dictationOnlySetup)
        model.continueFromDictation()
        #expect(model.step == .reply)
    }

    @Test func replacingTheAccountClearsItsDeclinedMailWarningBeforeRefresh() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 12)))
        await model.refreshMail()
        #expect(await NativeMail.declineMail(model, world: world))
        #expect(model.mailProblem == .denied)

        try keys.save("replacement-device-key")
        #expect(model.backendKey == "replacement-device-key")
        #expect(model.connections.isEmpty)
        #expect(model.mailProblem == nil)
        // A new account starts setup over on the mail page.
        #expect(model.step == .mail)

        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 8)))
        await model.refreshMail()
        #expect(world.requests.last?.authorization == "Bearer replacement-device-key")
        #expect(model.connections.first?.storedMessages == 8)
        #expect(model.mailProblem == nil)
    }

    @Test func deletingTheAccountClearsItsDeclinedMailWarningBeforeRecovery() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 12)))
        await model.refreshMail()
        #expect(await NativeMail.declineMail(model, world: world))
        #expect(model.mailProblem == .denied)

        try keys.delete()
        let requests = world.sent("/v1/mail/connections")
        await model.refreshMail()
        #expect(world.sent("/v1/mail/connections") == requests)
        #expect(model.backendKey == nil)
        #expect(model.connections.isEmpty)
        #expect(model.mailProblem == nil)
        #expect(model.step == .signIn)

        try keys.save("recovered-device-key")
        await model.refreshMail()
        #expect(world.requests.last?.authorization == "Bearer recovered-device-key")
        #expect(model.connections.first?.storedMessages == 12)
        #expect(model.mailProblem == nil)
    }

    @Test func unreadableAndSameKeyReadsKeepTheDeclinedWarningUntilReplacementIsConfirmed() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 12)))
        await model.refreshMail()
        #expect(await NativeMail.declineMail(model, world: world))
        #expect(model.mailProblem == .denied)
        #expect(model.backendKey == "synthetic-device-key")
        await model.refreshMail()
        #expect(model.mailProblem == .denied)

        keys.unreadable = true
        let requests = world.sent("/v1/mail/connections")
        await model.refreshMail()
        #expect(world.sent("/v1/mail/connections") == requests)
        #expect(model.mailProblem == .denied)
        #expect(model.connections.first?.storedMessages == 12)
        #expect(model.step == .mail)

        keys.unreadable = false
        await model.refreshMail()
        #expect(world.requests.last?.authorization == "Bearer synthetic-device-key")
        #expect(model.mailProblem == .denied)

        keys.unreadable = true
        try keys.save("replacement-device-key")
        await model.refreshMail()
        #expect(model.mailProblem == .denied)
        keys.unreadable = false
        await model.refreshMail()
        #expect(world.requests.last?.authorization == "Bearer replacement-device-key")
        #expect(model.connections.first?.storedMessages == 12)
        #expect(model.mailProblem == nil)
    }

    @Test func speechKeyRefusalCancelsPendingNativeConsent() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        var changes: [Bool] = []
        model.accountChanged = { changes.append($0) }
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        let consent = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        let abandoned = world.consentCallback
        model.backendKeyRefused("an-earlier-key")
        #expect(model.isConnecting)
        #expect(changes.isEmpty)
        model.backendKeyRefused("synthetic-device-key")
        abandoned?(NativeMail.callback())
        await consent.value
        #expect(changes == [false])
        #expect(model.backendKey == nil)
        #expect(model.step == .signIn)
        #expect(model.signInProblem == .signedOut)
        #expect(world.sessions.first?.cancelled == true)
        #expect(model.awaiting == nil)
        #expect(!model.isConnecting)
        #expect(world.sent("/v1/mail/gmail/complete") == 0)
        #expect(world.returns == 0)
    }

    @Test func confirmedKeyChangesNotifyDictationBeforeAStaleSpeechRefusal() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        var changes: [Bool] = []
        model.accountChanged = { changes.append($0) }
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        let consent = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        let abandoned = world.consentCallback
        try keys.save("replacement-device-key")
        // A speech request for the earlier key returns before the mail watcher.
        model.backendKeyRefused("synthetic-device-key")
        #expect(model.backendKey == "replacement-device-key")
        #expect(model.signInProblem == nil)
        #expect(model.step == .mail)
        #expect(changes == [true])
        abandoned?(NativeMail.callback())
        await consent.value
        #expect(world.sessions.first?.cancelled == true)
        #expect(world.sent("/v1/mail/gmail/complete") == 0)
        #expect(world.returns == 0)
        // Repeated reads do not reset dictation. An unreadable store withholds
        // its credential without claiming an account change or deleting it.
        #expect(model.backendKey == "replacement-device-key")
        keys.unreadable = true
        #expect(model.backendKey == nil)
        model.backendKeyRefused("replacement-device-key")
        #expect(changes == [true])
        keys.unreadable = false
        #expect(model.backendKey == "replacement-device-key")
        #expect(changes == [true])
        try keys.delete()
        await model.refreshMail()
        #expect(changes == [true, false])
        #expect(model.backendKey == nil)
        try keys.save("another-device-key")
        #expect(model.backendKey == "another-device-key")
        #expect(changes == [true, false, true])
    }

    @Test func recoveringAnUnreadableLaunchKeyEnablesDictationOnce() async {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        keys.unreadable = true
        let model = NativeMail.model(world, keys: keys)
        var changes: [Bool] = []
        model.accountChanged = { changes.append($0) }
        #expect(model.backendKey == nil)
        #expect(changes.isEmpty)
        keys.unreadable = false
        #expect(model.backendKey == "synthetic-device-key")
        #expect(changes == [true])
        #expect(model.backendKey == "synthetic-device-key")
        #expect(changes == [true])
    }

    @Test func closingSetupCancelsPermissionWatchAndNativeMailTogether() async {
        let world = NativeMail.World()
        world.granted = [.microphone]
        AlphaStub.answer = { world.answer($0) }
        let requests = PermissionAlert.Requests(settle: .zero)
        var asked: [SetupPermission] = []
        var opened = 0
        var outcome: PermissionAlert.Outcome?
        let model = OnboardingModel(client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { permission in
                outcome = await requests.request({ asked.append(permission) }, clock: ContinuousClock(), look: { nil },
                    open: { opened += 1; return false }, arrived: { false })
            }),
            mail: MailAuthentication(makeSession: { url, callback in world.makeConsent(url, callback: callback) }),
            defaults: NativeMail.defaults(), settle: .milliseconds(1))
        model.mailAnchor = NSWindow()
        model.returned = { world.returns += 1 }
        var changes: [Bool] = []
        model.accountChanged = { changes.append($0) }
        let permission = model.allow(.accessibility)
        #expect(await NativeMail.eventually { asked == [.accessibility] })
        // A grant can arrive before the alert watch ends. Closing setup
        // cancels that watch together with the mail consent session.
        world.granted.insert(.accessibility)
        model.refreshPermissions()
        #expect(model.step == .mail)
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        let consent = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        let abandoned = world.consentCallback
        let returns = world.returns
        model.windowClosed()
        abandoned?(NativeMail.callback())
        await consent.value
        await permission.value
        #expect(outcome == .cancelled)
        #expect(opened == 0)
        #expect(asked == [.accessibility])
        #expect(model.granted == [.microphone, .accessibility])
        #expect(world.sessions.first?.cancelled == true)
        #expect(model.mailAnchor == nil)
        #expect(model.awaiting == nil)
        #expect(!model.isConnecting)
        #expect(world.sent("/v1/mail/gmail/complete") == 0)
        #expect(world.returns == returns)
        #expect(model.backendKey == "synthetic-device-key")
        #expect(changes.isEmpty)
    }

    @Test func nativeConsentCompletesBeforeRefreshingProgressForBothProviders() async {
        for provider in AlphaClient.MailProvider.allCases {
            let world = NativeMail.World()
            let model = NativeMail.model(world, offersOutlook: true)
            world.reply("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":["gmail","outlook"]}"#))
            await model.refreshMail()
            world.reply("/v1/mail/\(provider.rawValue)/connect", .init(json: NativeMail.consent(provider.rawValue)))
            world.reply("/v1/mail/\(provider.rawValue)/complete", .init(json: "{\"connection_id\":\"\(NativeMail.connectionID)\"}"))
            world.reply("/v1/mail/connections", .init(json: NativeMail.connection(provider.rawValue, stored: 12)))
            let task = Task { await model.connect(provider) }
            #expect(await NativeMail.eventually { world.consentCallback != nil })
            #expect(model.awaiting == provider)
            #expect(model.connections.isEmpty)
            world.consentCallback?(NativeMail.callback(provider.rawValue))
            await task.value
            #expect(model.awaiting == nil)
            #expect(model.connections.first?.storedMessages == 12)
            #expect(world.sent("/v1/mail/\(provider.rawValue)/complete") == 1)
            #expect(world.requests.last { $0.path.hasSuffix("/complete") }?.authorization == "Bearer synthetic-device-key")
            #expect(world.returns == 1)
        }
    }

    @Test func reconnectKeepsProgressAndPollingCannotCompleteConsent() async {
        let world = NativeMail.World()
        let current = NativeMail.model(world)
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        world.reply("/v1/mail/gmail/complete", .init(json: "{\"connection_id\":\"\(NativeMail.connectionID)\"}"))
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(state: "reconnect_required", stored: 40)))
        await current.refreshMail()
        let task = Task { await current.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 40, connectedAt: "2026-10-04T11:00:00Z")))
        await current.refreshMail()
        #expect(current.awaiting == .gmail)
        #expect(current.connections.first?.storedMessages == 40)
        world.consentCallback?(NativeMail.callback())
        await task.value
        #expect(current.awaiting == nil)
        #expect(current.connections.first?.storedMessages == 40)
        #expect(world.sent("/v1/mail/gmail/complete") == 1)
    }

    @Test func abandoningOrChangingTheDeviceCancelsTheNativeSession() async throws {
        for action in ["close", "skip", "revoke", "replace", "delete"] {
            let world = NativeMail.World(), keys = MemoryDeviceKey("synthetic-device-key")
            let model = NativeMail.model(world, keys: keys)
            world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
            let task = Task { await model.connect(.gmail) }
            #expect(await NativeMail.eventually { world.consentCallback != nil })
            let oldCallback = world.consentCallback
            switch action {
            case "close": model.windowClosed()
            case "skip": model.continueFromMail()
            case "replace": try keys.save("replacement-device-key"); await model.refreshMail()
            case "delete": try keys.delete(); await model.refreshMail()
            default: world.reply("/v1/mail/connections", .init(status: 401)); await model.refreshMail()
            }
            oldCallback?(NativeMail.callback())
            await task.value
            #expect(model.awaiting == nil)
            #expect(!model.isConnecting)
            #expect(world.sessions.first?.cancelled == true)
            #expect(model.mailProblem == nil)
            #expect(world.sent("/v1/mail/gmail/complete") == 0)
            #expect(world.returns == 0)
        }
    }

    @Test func aChangedKeyAtCallbackCannotSendCompletionWithTheEarlierCredential() async throws {
        let world = NativeMail.World(), keys = MemoryDeviceKey("synthetic-device-key")
        let model = NativeMail.model(world, keys: keys)
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        let task = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        try keys.save("replacement-device-key")
        world.consentCallback?(NativeMail.callback())
        await task.value
        #expect(world.sent("/v1/mail/gmail/complete") == 0)
        #expect(model.connections.isEmpty)
    }

    @Test func denialAndInvalidCallbacksLeaveProgressAndDoNotCompleteConsent() async {
        for query in ["state=\(NativeMail.state)&error=denied", "state=wrong&code=synthetic", "state=\(NativeMail.state)&code=x&code=y"] {
            let world = NativeMail.World(), model = NativeMail.model(world)
            world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 12)))
            world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
            await model.refreshMail()
            let task = Task { await model.connect(.gmail) }
            #expect(await NativeMail.eventually { world.consentCallback != nil })
            world.consentCallback?(URL(string: "intention-mail://oauth/gmail?\(query)")!)
            await task.value
            #expect(world.sent("/v1/mail/gmail/complete") == 0)
            #expect(model.connections.first?.storedMessages == 12)
            #expect(model.mailProblem == (query.contains("error=denied") ? .denied : .unavailable(.gmail)))
        }
    }

    @Test func settingsReconnectRefusesALateCallbackFromTheClosedWindow() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        world.reply("/v1/mail/gmail/complete", .init(json: "{\"connection_id\":\"\(NativeMail.connectionID)\"}"))
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 40)))
        model.continueFromMail()
        model.continueFromDictation()
        model.finish()
        model.reopenMail()
        let old = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        let abandoned = world.consentCallback
        model.windowClosed()
        await old.value
        #expect(model.isFinished)
        model.reopenMail()
        model.mailAnchor = NSWindow()
        let new = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.sessions.count == 2 })
        abandoned?(NativeMail.callback())
        try? await Task.sleep(for: .milliseconds(20))
        #expect(world.sent("/v1/mail/gmail/complete") == 0)
        #expect(model.awaiting == .gmail)
        world.consentCallback?(NativeMail.callback())
        await new.value
        #expect(world.sent("/v1/mail/gmail/complete") == 1)
        #expect(model.connections.first?.storedMessages == 40)
        model.continueFromMail()
        #expect(model.isFinished)
    }

    @Test func settingsMailForAReplacementAccountOpensTheExampleInstead() throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        model.continueFromMail()
        model.continueFromDictation()
        model.finish()
        #expect(model.isFinished)
        try keys.save("replacement-device-key")
        model.reopenMail()
        #expect(model.step == .mail)
        // The same account reopens mail as before.
        model.continueFromMail()
        model.continueFromDictation()
        model.finish()
        model.reopenMail()
        #expect(model.step == .mail)
    }

    @Test func theMailWatcherReadsTheReplacementAccountOnItsMailPage() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 12)))
        try keys.save("replacement-device-key")
        let watching = Task { await model.watchMail() }
        #expect(await NativeMail.eventually { world.sent("/v1/mail/connections") > 0 })
        watching.cancel()
        await watching.value
        #expect(model.step == .mail)
        #expect(world.requests.last?.authorization == "Bearer replacement-device-key")
    }

    @Test func eachMailRowOffersReconnectingOnlyWhenTheServerSaysItIsNeeded() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        // Before the server answers, nothing is known, and Settings says so.
        #expect(!model.hasReadMail)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.refreshMail()
        #expect(model.hasReadMail)
        #expect(model.mailOffer(for: .gmail) == .connect)
        // Written out from the server's states and error codes
        // (apps/server/src/intention/alpha/mail_sync.py): only a connection
        // the server must be given again, or one it stopped for good, asks
        // for it. A failed pass is retried by the server itself.
        let cases: [(state: String, error: String?, offer: OnboardingModel.MailOffer)] = [
            ("syncing", nil, .nothing),
            ("ready", nil, .nothing),
            ("syncing", "sync_failed", .nothing),
            ("ready", "sync_paused", .reconnect),
            ("reconnect_required", "reconnect_required", .reconnect),
            ("reconnect_required", nil, .reconnect),
            // The address changed at the provider; the server refuses a new
            // address beside the kept one (mail.py), so reconnecting cannot help.
            ("reconnect_required", "mail_identity_changed", .stuck),
        ]
        for (state, error, offer) in cases {
            world.reply("/v1/mail/connections", .init(json: NativeMail.connection(state: state, stored: 140, error: error)))
            await model.refreshMail()
            #expect(model.mailOffer(for: .gmail) == offer, "\(state) \(error ?? "no error")")
            // Older server responses offer only Gmail.
            #expect(model.mailOffer(for: .outlook) == .nothing)
        }
    }

    @Test func settingsReadsOnceAtEachStepWhileOpenAndStopsWhenClosed() async {
        let world = NativeMail.World(), steps = NativeMail.PollSteps()
        let model = NativeMail.model(world, steps: steps)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 140)))
        let following = Task { await model.followMail() }
        // One read at once, then it waits for the next step.
        #expect(await NativeMail.eventually { steps.pauses == 1 })
        #expect(world.sent("/v1/mail/connections") == 1)
        #expect(model.connections.first?.storedMessages == 140)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 161)))
        steps.step()
        #expect(await NativeMail.eventually { steps.pauses == 2 })
        #expect(world.sent("/v1/mail/connections") == 2)
        #expect(model.connections.first?.storedMessages == 161)
        // Closed while it waits: the loop ends, and with it every read.
        following.cancel()
        await following.value
        #expect(world.sent("/v1/mail/connections") == 2)
        #expect(steps.pauses == 2)
    }

    @Test func closingSettingsMidReadStopsReadingAndChangesNothing() async {
        let world = NativeMail.World(), steps = NativeMail.PollSteps()
        let model = NativeMail.model(world, steps: steps)
        // The server never answers, so the read is still on its way when
        // Settings closes, however slow the machine.
        world.reply("/v1/mail/connections", .init(stalls: true))
        let following = Task { await model.followMail() }
        #expect(await NativeMail.eventually { world.sent("/v1/mail/connections") == 1 })
        following.cancel()
        await following.value
        // The loop has ended without pausing, so no read can follow.
        #expect(steps.pauses == 0)
        #expect(world.sent("/v1/mail/connections") == 1)
        // The cancelled read is not a failure and leaves nothing read.
        #expect(!model.mailReadFailed)
        #expect(!model.hasReadMail)
        #expect(model.connections.isEmpty)
    }

    @Test func anotherAccountStartsWithItsMailboxesUnreadEvenWhenTheFirstReadFails() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.refreshMail()
        #expect(model.hasReadMail)
        try keys.save("replacement-device-key")
        #expect(model.backendKey == "replacement-device-key")
        #expect(!model.hasReadMail)
        // Its first read fails: Settings keeps saying it is checking rather
        // than offering to connect a mailbox it has not heard about.
        world.reply("/v1/mail/connections", .init(status: 500))
        await model.refreshMail()
        #expect(!model.hasReadMail)
        // Settings says the list could not be read and offers setup's page.
        #expect(model.mailReadFailed)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 140)))
        await model.refreshMail()
        #expect(model.hasReadMail)
        #expect(!model.mailReadFailed)
        #expect(model.mailOffer(for: .gmail) == .nothing)
    }

    @Test func aFailedReadAfterAShownListKeepsItAndSaysItMayBeOutOfDate() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 140)))
        await model.refreshMail()
        #expect(!model.mailReadFailed)
        // The server fails the next read: the mailbox stays, and Settings
        // shows its line saying the list may be out of date.
        world.reply("/v1/mail/connections", .init(status: 500))
        await model.refreshMail()
        #expect(model.connections.first?.storedMessages == 140)
        #expect(model.hasReadMail)
        #expect(model.mailReadFailed)
        #expect(model.mailProblem == nil)
        // Unreachable, then answering with an error: the line says the
        // server answered, not that it couldn't be reached.
        world.reply("/v1/mail/connections", .init(failure: .notConnectedToInternet))
        await model.refreshMail()
        #expect(model.mailProblem == .unreachable)
        world.reply("/v1/mail/connections", .init(status: 500))
        await model.refreshMail()
        #expect(model.mailProblem == nil)
        #expect(model.mailReadFailed)
        // A read that succeeds again takes the line away.
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 161)))
        await model.refreshMail()
        #expect(!model.mailReadFailed)
        #expect(model.connections.first?.storedMessages == 161)
    }

    @Test func anAccountReplacedWhileAPermissionRequestWaitsCancelsIt() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let (held, release) = AsyncStream<Void>.makeStream()
        var seenCancelled: Bool?
        var waiting = false
        AlphaStub.answer = { world.answer($0) }
        let permissions = SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in
            // Stands in for macOS's alert, still unanswered.
            waiting = true
            for await _ in held { break }
            seenCancelled = Task.isCancelled
        })
        let model = OnboardingModel(client: AlphaStub.client(), keys: keys, permissions: permissions,
                                    mail: MailAuthentication(), defaults: NativeMail.defaults(), settle: .milliseconds(1))
        model.continueFromMail()
        #expect(model.step == .permissions)
        let asking = model.allow(.accessibility)
        #expect(await NativeMail.eventually { waiting })
        // Another account's key takes this one's place, as Settings' mail
        // polling or a relaunch would find it, and setup starts again.
        try keys.save("replacement-device-key")
        #expect(model.backendKey == "replacement-device-key")
        #expect(model.step == .mail)
        release.yield()
        await asking.value
        #expect(seenCancelled == true)
    }

    @Test func aServerWithoutMailRoutesCountsAsAnswered() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        world.reply("/v1/mail/connections", .init(status: 404))
        await model.refreshMail()
        #expect(model.hasReadMail)
        #expect(!model.isMailOffered)
    }

    @Test func reconcilingAndUnknownStatesAreReportedAsTheirActualProcessing() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        for (state, reconciling, standing) in [("ready", true, OnboardingModel.MailStanding.checking),
                                               ("future_state", false, .stopped)] {
            let json = NativeMail.connection(state: state, stored: 12)
                .replacingOccurrences(of: "\"reconciling\":false", with: "\"reconciling\":\(reconciling)")
            world.reply("/v1/mail/connections", .init(json: json))
            await model.refreshMail()
            #expect(model.connections.map(OnboardingModel.standing(of:)) == [standing])
            #expect(model.mailImport == .imported(12))
            #expect(model.isMailWorking == reconciling)
        }
    }

    @Test func mailWatchingRetriesUnreadableKeysWithoutUsingTheCachedIdentity() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 12)))
        keys.unreadable = true
        var ended = false
        let watching = Task { await model.watchMail(); ended = true }
        defer { watching.cancel() }
        #expect(await NativeMail.eventually { keys.failedReads >= 2 || ended })
        #expect(!ended)
        #expect(world.sent("/v1/mail/connections") == 0)
        #expect(model.step == .mail)
        keys.unreadable = false
        #expect(await NativeMail.eventually { model.connections.first?.storedMessages == 12 })
        #expect(!ended)
        world.reply("/v1/mail/connections", .init(status: 401))
        #expect(await NativeMail.eventually { model.signInProblem == .signedOut })
        #expect(await NativeMail.eventually { ended })
        await watching.value
    }

    @Test func unreadableConsentCancelsAndRecoveryUsesOnlyTheReplacementKey() async throws {
        let world = NativeMail.World(), keys = NativeMail.KeyStore()
        let model = NativeMail.model(world, keys: keys)
        world.reply("/v1/mail/gmail/connect", .init(json: NativeMail.consent()))
        let consent = Task { await model.connect(.gmail) }
        #expect(await NativeMail.eventually { world.consentCallback != nil })
        keys.unreadable = true
        world.consentCallback?(NativeMail.callback())
        await consent.value
        #expect(world.sent("/v1/mail/gmail/complete") == 0)
        #expect(!model.isConnecting)
        try keys.save("replacement-device-key")
        keys.unreadable = false
        world.reply("/v1/mail/connections", .init(json: NativeMail.connection(stored: 8)))
        await model.refreshMail()
        #expect(world.requests.last?.authorization == "Bearer replacement-device-key")
        #expect(model.connections.first?.storedMessages == 8)
    }

    @Test func anEmptyMailboxCheckingRetainedMailReportsChecksRatherThanAPause() async {
        let world = NativeMail.World(), model = NativeMail.model(world)
        for state in ["syncing", "ready"] {
            let json = NativeMail.connection(state: state)
                .replacingOccurrences(of: "\"reconciling\":false", with: "\"reconciling\":true")
            world.reply("/v1/mail/connections", .init(json: json))
            await model.refreshMail()
            #expect(model.isMailWorking)
            #expect(model.mailImport == .checking)
            model.continueFromMail()
            #expect(model.mailImport == .checking)
        }
    }

}

/// Scripted authentication sessions and in-process responses only.
@MainActor
private enum NativeMail {
    /// What the scripted Mac and backend hold, and what the flow did to them.
    /// Steps Settings' polling by hand in place of its five-second wait:
    /// each `step()` ends one pause, and a cancelled pause returns at once,
    /// as `Task.sleep` does. Nothing here measures time.
    final class PollSteps: @unchecked Sendable {
        private let lock = NSLock()
        private var granted = 0
        private var waiting: CheckedContinuation<Void, Never>?
        private var cancelled = false
        private var started = 0
        /// How many pauses have begun: one after each read.
        var pauses: Int { lock.withLock { started } }

        func step() {
            let resume: CheckedContinuation<Void, Never>? = lock.withLock {
                if let waiting { self.waiting = nil; return waiting }
                granted += 1
                return nil
            }
            resume?.resume()
        }

        func pause() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let now: Bool = lock.withLock {
                        started += 1
                        if cancelled || Task.isCancelled || granted > 0 {
                            if granted > 0 { granted -= 1 }
                            return true
                        }
                        waiting = continuation
                        return false
                    }
                    if now { continuation.resume() }
                }
            } onCancel: {
                let resume: CheckedContinuation<Void, Never>? = lock.withLock {
                    cancelled = true
                    defer { waiting = nil }
                    return waiting
                }
                resume?.resume()
            }
        }
    }

    final class World: @unchecked Sendable {
        let lock = NSLock()
        var granted: Set<SetupPermission> = []
        var requested: [SetupPermission] = []
        var opened: [URL] = []
        var returns = 0
        var consentCallback: (@Sendable (URL?) -> Void)?
        var sessions: [ConsentSession] = []
        var consentStarts = true

        @MainActor
        func makeConsent(_ url: URL, callback: @escaping @Sendable (URL?) -> Void) -> ConsentSession {
            opened.append(url)
            consentCallback = callback
            let session = ConsentSession(starts: consentStarts)
            sessions.append(session)
            return session
        }

        /// Moments a test wants to measure from.
        var marks: [ContinuousClock.Instant] = []
        var requests: [(path: String, authorization: String?, body: String)] = []
        var replies: [String: AlphaStub.Reply] = ["/v1/mail/connections": .init(json: #"{"connections":[]}"#)]

        func reply(_ path: String, _ reply: AlphaStub.Reply) {
            lock.withLock { replies[path] = reply }
        }

        func answer(_ request: URLRequest) -> AlphaStub.Reply {
            var body = ""
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&buffer, maxLength: buffer.count)
                stream.close()
                body = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
            }
            let path = request.url?.path ?? ""
            return lock.withLock {
                requests.append((path, request.value(forHTTPHeaderField: "Authorization"), body))
                return replies[path] ?? AlphaStub.Reply(status: 404)
            }
        }

        func sent(_ path: String) -> Int {
            lock.withLock { requests.filter { $0.path == path }.count }
        }
    }

    final class KeyStore: DeviceKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var key: String? = "synthetic-device-key"
        private var cannotRead = false
        private var failures = 0
        var unreadable: Bool {
            get { lock.withLock { cannotRead } }
            set { lock.withLock { cannotRead = newValue } }
        }
        var failedReads: Int { lock.withLock { failures } }
        func read() throws -> String? {
            try lock.withLock {
                if cannotRead { failures += 1; throw CocoaError(.fileReadNoPermission) }
                return key
            }
        }
        func save(_ key: String) throws { lock.withLock { self.key = key } }
        func delete() throws { lock.withLock { key = nil } }
    }

    @MainActor
    final class ConsentSession: MailConsentSession {
        var cancelled = false
        let starts: Bool
        init(starts: Bool = true) { self.starts = starts }
        func start() -> Bool { starts }
        func cancel() { cancelled = true }
    }

    static let state = String(repeating: "s", count: 32)
    static let connectionID = "33333333-3333-4333-8333-333333333333"
    static func consent(_ provider: String = "gmail") -> String {
        let base = provider == "gmail" ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        return "{\"authorization_url\":\"\(base)?state=\(state)\"}"
    }
    static func callback(_ provider: String = "gmail", state: String = Self.state) -> URL {
        URL(string: "intention-mail://oauth/\(provider)?state=\(state)&code=synthetic")!
    }

    static func declineMail(_ model: OnboardingModel, world: World) async -> Bool {
        world.reply("/v1/mail/gmail/connect", .init(json: consent()))
        let connecting = Task { await model.connect(.gmail) }
        let opened = await eventually { world.consentCallback != nil }
        if opened {
            // The server translates provider errors, including access_denied,
            // into this fixed callback outcome.
            world.consentCallback?(URL(string: "intention-mail://oauth/gmail?state=\(state)&error=denied")!)
        } else {
            connecting.cancel()
        }
        await connecting.value
        return opened
    }

    static func defaults() -> UserDefaults {
        let name = "OnboardingScenarioTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func model(_ world: World, keys: any DeviceKeyStore = MemoryDeviceKey("synthetic-device-key"),
                        defaults: UserDefaults? = nil, steps: PollSteps = PollSteps(),
                        consentTimeout: Duration = .seconds(540), offersOutlook: Bool = OnboardingModel.offersOutlookByDefault) -> OnboardingModel {
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        let model = OnboardingModel(client: AlphaStub.client(), keys: keys,
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
            mail: MailAuthentication(makeSession: { url, callback in world.makeConsent(url, callback: callback) },
                                     consentTimeout: consentTimeout),
            defaults: defaults ?? self.defaults(), pollInterval: .milliseconds(10), followPause: { await steps.pause() },
            settle: .milliseconds(1), offersOutlook: offersOutlook)
        model.mailAnchor = NSWindow()
        model.returned = { world.returns += 1 }
        // A saved key with no page reached yet starts on mail.
        return model
    }

    static func connection(_ provider: String = "gmail", state: String = "syncing", stored: Int = 0,
                                   error: String? = nil, connectedAt: String = "2026-10-03T10:00:00Z") -> String {
        """
        {"connections":[{"id":"33333333-3333-4333-8333-333333333333","provider":"\(provider)","address":"synthetic@example.com",\
        "state":"\(state)","backfill_done":\(state == "ready"),"pages_imported":1,"messages_imported":\(stored),\
        "excluded_messages":0,"blocked_messages":0,"stored_messages":\(stored),"last_synced_at":null,\
        "error_code":\(error.map { "\"\($0)\"" } ?? "null"),"connected_at":"\(connectedAt)","reconciling":false}]}
        """
    }

    static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

}
