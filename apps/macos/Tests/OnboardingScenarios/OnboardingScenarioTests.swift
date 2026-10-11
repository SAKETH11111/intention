// AppKit rather than Foundation: the Command Line Tools cannot load the
// overlay that importing Foundation beside Testing asks for.
import AppKit
@testable import Onboarding
import Testing

/// The production setup flow and alpha client against a backend that
/// answers inside the process, a device key kept in memory and scripted
/// permission grants. Nothing here reaches the network, the keychain or
/// the system's privacy settings.
@MainActor
@Suite(.serialized)
struct OnboardingScenarioTests {
    private static let code = "482913"
    private static let registration = """
    {"account_id":"11111111-1111-4111-8111-111111111111","device_id":"22222222-2222-4222-8222-222222222222","device_key":"synthetic-device-key"}
    """

    /// What the scripted Mac and backend hold, and what the flow did to them.
    private final class World: @unchecked Sendable {
        let lock = NSLock()
        var granted: Set<SetupPermission> = []
        var requested: [SetupPermission] = []
        var opened: [URL] = []
        var returns = 0
        /// Moments a test wants to measure from.
        var marks: [ContinuousClock.Instant] = []
        var requests: [(path: String, authorization: String?, body: String, method: String?)] = []
        var replies: [String: AlphaStub.Reply] = [:]

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
                requests.append((path, request.value(forHTTPHeaderField: "Authorization"), body, request.httpMethod))
                return replies[path] ?? AlphaStub.Reply(status: 404)
            }
        }

        func sent(_ path: String) -> Int {
            lock.withLock { requests.filter { $0.path == path }.count }
        }
    }

    private func defaults() -> UserDefaults {
        let name = "OnboardingScenarioTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func model(_ world: World, keys: DeviceKeyStore = MemoryDeviceKey(), defaults: UserDefaults? = nil,
                       settle: Duration = .milliseconds(5), offersOutlook: Bool = OnboardingModel.offersOutlookByDefault) -> OnboardingModel {
        AlphaStub.answer = { world.answer($0) }
        let permissions = SetupPermissions(
            isGranted: { world.granted.contains($0) },
            request: { world.requested.append($0) }
        )
        let model = OnboardingModel(client: AlphaStub.client(), keys: keys, permissions: permissions,
                                    mail: MailAuthentication(), defaults: defaults ?? self.defaults(),
                                    pollInterval: .milliseconds(10), settle: settle, offersOutlook: offersOutlook)
        model.mailAnchor = NSWindow()
        model.returned = { world.returns += 1 }
        return model
    }

    /// A model signed in on the first page after the code, with both grants.
    private func atMail(_ world: World, keys: MemoryDeviceKey = MemoryDeviceKey("synthetic-device-key"),
                        defaults: UserDefaults? = nil, offersOutlook: Bool = OnboardingModel.offersOutlookByDefault) -> OnboardingModel {
        world.granted = [.accessibility, .microphone]
        let model = model(world, keys: keys, defaults: defaults, offersOutlook: offersOutlook)
        return model
    }

    private static func connection(_ provider: String = "gmail", state: String = "syncing", stored: Int = 0,
                                   error: String? = nil, connectedAt: String = "2026-10-03T10:00:00Z") -> String {
        """
        {"connections":[{"id":"33333333-3333-4333-8333-333333333333","provider":"\(provider)","address":"synthetic@example.com",\
        "state":"\(state)","backfill_done":\(state == "ready"),"pages_imported":1,"messages_imported":\(stored),\
        "excluded_messages":0,"blocked_messages":0,"stored_messages":\(stored),"last_synced_at":null,\
        "error_code":\(error.map { "\"\($0)\"" } ?? "null"),"connected_at":"\(connectedAt)","reconciling":false}]}
        """
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - Invite code

    @Test func theDigitsAreReadFromTypingSpacedCodesAndInviteLinks() {
        #expect(OnboardingModel.digits(in: "482913") == "482913")
        #expect(OnboardingModel.digits(in: " 482 913\n") == "482913")
        #expect(OnboardingModel.digits(in: "482-913") == "482913")
        #expect(OnboardingModel.digits(in: "https://demo.intention.example/invite#482913") == "482913")
        // Digits in the address itself are not the code.
        #expect(OnboardingModel.digits(in: "https://demo2.intention.example:8443/invite#482913") == "482913")
        #expect(OnboardingModel.digits(in: "https://demo.intention.example/invite") == "")
        #expect(OnboardingModel.digits(in: "abc") == "")
        #expect(OnboardingModel.digits(in: "４８２９１３") == "")
    }

    @Test func theGreetingUsesTheTimeOfDayAndTheFirstName() {
        #expect(OnboardingModel.greeting(hour: 8, fullName: "Ada Lovelace") == "Good morning, Ada.")
        #expect(OnboardingModel.greeting(hour: 14, fullName: "Ada") == "Good afternoon, Ada.")
        #expect(OnboardingModel.greeting(hour: 20, fullName: "") == "Good evening.")
        #expect(OnboardingModel.greeting(hour: 3, fullName: "Ada Lovelace") == "Hello, Ada.")
        #expect(OnboardingModel.greeting(hour: 8, fullName: "Averyveryverylongsinglename") == "Good morning.")
    }

    // MARK: - Sign in

    @Test func theSixthDigitSignsInSavesTheKeyAndTurnsThePage() async throws {
        let world = World(), keys = MemoryDeviceKey(), store = defaults()
        world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
        let model = model(world, keys: keys, defaults: store)
        #expect(model.step == .signIn)
        model.enter("48291")
        #expect(model.digits == "48291")
        #expect(world.requests.isEmpty)
        model.enter("482913")
        #expect(await eventually { model.step == .mail })
        #expect(model.signInProblem == nil)
        #expect(model.digits.isEmpty)
        #expect(try keys.read() == "synthetic-device-key")
        #expect(world.requests.map(\.path) == ["/v1/invites/redeem"])
        #expect(world.requests[0].body.contains("\"482913\""))
        // A relaunch resumes on the same page.
        #expect(self.model(world, keys: keys, defaults: store).step == .mail)
    }

    @Test func dictationFollowsSignInAndAKeyRefusedElsewhere() async throws {
        let world = World(), keys = MemoryDeviceKey()
        world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
        let model = model(world, keys: keys)
        var changes: [Bool] = []
        model.accountChanged = { changes.append($0) }
        #expect(model.backendKey == nil)
        model.enter("482913")
        #expect(await eventually { model.backendKey == "synthetic-device-key" })
        #expect(changes == [true])
        // A refusal of a key that has since been replaced changes nothing.
        model.backendKeyRefused("an-earlier-key")
        #expect(changes == [true])
        // Dictation's grant request was refused with 401: signed out, as for setup's own.
        model.backendKeyRefused("synthetic-device-key")
        #expect(changes == [true, false])
        #expect(model.backendKey == nil)
        #expect(model.signInProblem == .signedOut)
        #expect(model.step == .signIn)
        #expect(try keys.read() == nil)
    }

    @Test func aPastedInviteLinkSignsInAndMoreDigitsThanSixAreDropped() async {
        let world = World()
        world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
        let model = model(world)
        model.enter("https://demo.intention.example/invite#4829139999")
        #expect(model.digits == "482913")
        #expect(await eventually { model.step == .mail })
        #expect(world.requests[0].body.contains("\"482913\""))
    }

    @Test func aMacThatAlreadyAllowsBothConnectsMailBeforeTheFirstDictation() async {
        let world = World()
        world.granted = [.microphone, .accessibility]
        world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
        let model = model(world)
        model.enter(Self.code)
        #expect(await eventually { model.step == .mail })
        #expect(world.requested.isEmpty)
    }

    @Test func aPageAnEarlierBuildSavedResumesAfterTheCode() {
        // "example" was a page until October 2026. A key is still there,
        // so setup goes on from the code, not back to it.
        let world = World(), store = defaults()
        store.set("example", forKey: "onboardingStep")
        #expect(model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).step == .mail)
        world.granted = [.microphone, .accessibility]
        #expect(model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).step == .mail)
    }

    @Test func aRefusedCodeClearsTheCellsForAnother() async throws {
        let world = World(), keys = MemoryDeviceKey()
        world.reply("/v1/invites/redeem", .init(status: 401, json: #"{"detail":"invalid_invite"}"#))
        let model = model(world, keys: keys)
        model.enter(Self.code)
        #expect(await eventually { model.signInProblem == .invalidCode })
        #expect(model.step == .signIn)
        #expect(model.digits.isEmpty)
        #expect(try keys.read() == nil)
        // The message stays until the person starts another code.
        model.enter("1")
        #expect(model.signInProblem == nil)
        #expect(world.sent("/v1/invites/redeem") == 1)
    }

    @Test func tooManyWrongCodesAreReportedAsAPause() async {
        let world = World()
        world.reply("/v1/invites/redeem", .init(status: 429, json: #"{"detail":"too_many_attempts"}"#))
        let model = model(world)
        model.enter(Self.code)
        #expect(await eventually { model.signInProblem == .tooManyTries })
        #expect(model.digits.isEmpty)
        // The short limits name their ten minutes.
        world.reply("/v1/invites/redeem", .init(status: 429, headers: ["Retry-After": "600"]))
        model.enter("111111")
        #expect(await eventually { world.sent("/v1/invites/redeem") == 2 && !model.isSigningIn })
        #expect(model.signInProblem == .tooManyTries)
    }

    @Test func aDayLongPauseIsNotCalledTenMinutes() async {
        let world = World()
        world.reply("/v1/invites/redeem", .init(status: 429, headers: ["Retry-After": "83400"]))
        let model = model(world)
        model.enter(Self.code)
        #expect(await eventually { model.signInProblem == .paused })
        #expect(model.digits.isEmpty)
    }

    @Test func anUnreachableServerAndAFailingOneAreToldApartAndKeepTheCode() async {
        let world = World()
        let model = model(world)
        world.reply("/v1/invites/redeem", .init(failure: .notConnectedToInternet))
        model.enter(Self.code)
        #expect(await eventually { model.signInProblem == .unreachable })
        #expect(model.digits == Self.code)
        #expect(model.canRetry)
        world.reply("/v1/invites/redeem", .init(status: 503, json: #"{"detail":"storage_unavailable"}"#))
        await model.signIn()
        #expect(model.signInProblem == .server)
        #expect(model.step == .signIn)
    }

    @Test func aBuildWithoutABackendSaysSo() async {
        let model = OnboardingModel(client: nil, keys: MemoryDeviceKey(),
                                    permissions: SetupPermissions(isGranted: { _ in false }, request: { _ in }),
                                    defaults: defaults())
        model.enter(Self.code)
        #expect(await eventually { model.signInProblem == .notConfigured })
    }

    @Test func aKeyThatCouldNotBeSavedIsSavedOnRetryWithoutSpendingTheInviteAgain() async throws {
        let world = World(), keys = MemoryDeviceKey()
        world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
        keys.refusesSaves = true
        let model = model(world, keys: keys)
        model.enter(Self.code)
        #expect(await eventually { model.signInProblem == .notSaved })
        #expect(model.step == .signIn)
        #expect(model.canRetry)
        keys.refusesSaves = false
        await model.signIn()
        #expect(await eventually { model.step == .mail })
        #expect(try keys.read() == "synthetic-device-key")
        #expect(world.sent("/v1/invites/redeem") == 1)
    }

    // MARK: - Resuming

    @Test func aMacWithoutAKeySignsInEvenAfterSetupFinished() {
        let world = World(), store = defaults()
        store.set("done", forKey: "onboardingStep")
        #expect(model(world, defaults: store).step == .signIn)
    }

    @Test func aMacWhoseKeyIsGoneDoesNotInheritAFinishedSetup() async {
        let world = World(), store = defaults()
        store.set("done", forKey: "onboardingStep")
        let model = model(world, defaults: store)
        world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
        model.enter(Self.code)
        #expect(await eventually { model.step == .mail })
        // Closing the window does not end a setup that has only begun.
        model.windowClosed()
        #expect(model.step == .mail)
        #expect(!self.model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).isFinished)
    }

    @Test func anUnfinishedSetupGoesBackForAMissingPermission() {
        let world = World(), store = defaults()
        store.set("tryIt", forKey: "onboardingStep")
        store.set(2, forKey: "onboardingStepOrder")
        world.granted = [.accessibility]
        #expect(model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).step == .permissions)
        world.granted = [.accessibility, .microphone]
        #expect(model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).step == .tryIt)
    }

    /// 0.0.5 and earlier saved the permissions and the first dictation
    /// before mail; such a setup resumes on mail once, and what this build
    /// saves is kept.
    @Test func aSetupSavedBeforeMailMovedResumesOnMail() {
        for saved in ["permissions", "shortcut", "tryIt"] {
            let world = World(), store = defaults()
            world.granted = [.accessibility, .microphone]
            store.set(saved, forKey: "onboardingStep")
            let model = model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store)
            #expect(model.step == .mail)
            #expect(store.integer(forKey: "onboardingStepOrder") == 2)
            // The next launch keeps mail rather than moving it again.
            #expect(self.model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).step == .mail)
        }
        for saved in ["mail", "reply", "openAtLogin", "done"] {
            let world = World(), store = defaults()
            world.granted = [.accessibility, .microphone]
            store.set(saved, forKey: "onboardingStep")
            let expected = OnboardingModel.Step(rawValue: saved)!
            #expect(model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).step == (expected == .openAtLogin ? .done : expected))
        }
        // Saved by this build: the first dictation stays where it was.
        let world = World(), store = defaults()
        world.granted = [.accessibility, .microphone]
        store.set("tryIt", forKey: "onboardingStep")
        store.set(2, forKey: "onboardingStepOrder")
        #expect(model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).step == .tryIt)
    }

    @Test func aFinishedSetupStaysFinishedWhenAPermissionIsWithdrawn() {
        let world = World(), store = defaults()
        store.set("done", forKey: "onboardingStep")
        let model = model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store)
        #expect(model.isFinished)
    }

    @Test func anUnreadableKeyStoreDoesNotAskForAnotherInvite() {
        struct Locked: DeviceKeyStore {
            func read() throws -> String? { throw CocoaError(.fileReadNoPermission) }
            func save(_ key: String) throws {}
            func delete() throws {}
        }
        let world = World(), store = defaults()
        store.set("done", forKey: "onboardingStep")
        #expect(model(world, keys: Locked(), defaults: store).isFinished)
    }


    // MARK: - Permissions

    @Test func oneAllowCarriesThroughBothPermissionsAndThePageTurnsByItself() async {
        let world = World()
        let model = model(world, keys: MemoryDeviceKey("synthetic-device-key"))
        model.continueFromMail()
        #expect(model.step == .permissions)
        #expect(model.currentAsk == .microphone)
        #expect(SetupPermission.allCases == [.microphone, .accessibility])
        let watching = Task { await model.watchPermissions() }
        defer { watching.cancel() }

        // The page's one button asks for the first that is not allowed.
        await model.allowNext()?.value
        #expect(world.requested == [.microphone])
        world.granted = [.microphone]
        // Accessibility is asked for without another press.
        #expect(await eventually { world.requested == [.microphone, .accessibility] })
        #expect(model.currentAsk == .accessibility)
        #expect(model.asked == [.microphone, .accessibility])
        #expect(model.step == .permissions)
        #expect(world.returns == 1)

        world.granted = [.microphone, .accessibility]
        #expect(await eventually { model.step == .tryIt })
        #expect(world.returns == 2)
        #expect(world.requested == [.microphone, .accessibility])
    }

    @Test func aGrantMadeWithoutPressingAllowDoesNotRaiseTheNextPrompt() async {
        let world = World()
        let model = model(world, keys: MemoryDeviceKey("synthetic-device-key"))
        model.continueFromMail()
        // The microphone was allowed in System Settings by hand.
        world.granted = [.microphone]
        model.refreshPermissions()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(world.requested.isEmpty)
        #expect(model.currentAsk == .accessibility)
        #expect(model.step == .permissions)
    }

    @Test func closingTheWindowStopsTheNextPermissionFromBeingAskedFor() async {
        let world = World()
        let model = model(world, keys: MemoryDeviceKey("synthetic-device-key"), settle: .milliseconds(80))
        model.continueFromMail()
        #expect(model.step == .permissions)
        await model.request(.microphone)
        world.granted = [.microphone]
        model.refreshPermissions()
        // The person closes setup while the microphone's tick is showing.
        model.windowClosed()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(world.requested == [.microphone])
    }

    @Test func aWindowClosedWhileTheLastTickShowsTurnsThePageWhenItReopens() async {
        let world = World()
        world.granted = [.accessibility]
        let model = model(world, keys: MemoryDeviceKey("synthetic-device-key"), settle: .milliseconds(80))
        model.continueFromMail()
        #expect(model.step == .permissions)
        await model.request(.microphone)
        world.granted = [.accessibility, .microphone]
        model.refreshPermissions()
        // Both are allowed and the tick is showing when the person closes setup.
        model.windowClosed()
        try? await Task.sleep(for: .milliseconds(250))
        // Opening it again starts the page's watch, as the window does.
        let watching = Task { await model.watchPermissions() }
        defer { watching.cancel() }
        #expect(await eventually { model.step == .tryIt })
        #expect(world.requested == [.microphone])
    }

    @Test func aWindowClosedWhileMacOSAsksLeadsToNoFurtherRequest() async {
        let world = World()
        let permissions = SetupPermissions(
            isGranted: { world.granted.contains($0) },
            request: { permission in
                world.requested.append(permission)
                // macOS's alert stays up for a moment, then the person allows it.
                try? await Task.sleep(for: .milliseconds(80))
                world.granted.insert(permission)
            }
        )
        let model = OnboardingModel(client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
                                    permissions: permissions, defaults: defaults(),
                                    pollInterval: .milliseconds(10), settle: .milliseconds(5))
        model.continueFromMail()
        var reported: [Bool] = []
        model.permissionReported = { permission, allowed in
            if permission == .microphone { reported.append(allowed) }
        }
        let asking = Task { await model.request(.microphone) }
        #expect(await eventually { world.requested == [.microphone] })
        model.windowClosed()
        await asking.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(world.requested == [.microphone])
        // The answer was kept, and Accessibility waits to be asked for.
        #expect(model.granted == [.microphone])
        #expect(reported == [true])
        model.refreshPermissions()
        #expect(reported == [true])
        #expect(model.currentAsk == .accessibility)
        #expect(model.step == .permissions)
    }

    @Test func theLastTickShowsInFullWhenTwoGrantsComeCloseTogether() async {
        let world = World()
        let model = model(world, keys: MemoryDeviceKey("synthetic-device-key"), settle: .milliseconds(400))
        model.continueFromMail()
        #expect(model.step == .permissions)
        world.granted = [.microphone]
        model.refreshPermissions()
        // Accessibility follows before the microphone's tick has had its
        // 400 ms, so the microphone's timer comes due first.
        try? await Task.sleep(for: .milliseconds(280))
        world.granted = [.microphone, .accessibility]
        // Taken before the grant is read, so a pause between the two lines
        // can only lengthen what is measured.
        let second = ContinuousClock.now
        model.refreshPermissions()
        let watching = Task { await model.watchPermissions() }
        defer { watching.cancel() }
        #expect(await eventually { model.step == .tryIt })
        #expect(ContinuousClock.now - second >= .milliseconds(390))
    }

    @Test func aGrantAnsweredAfterSetupReopenedStillShowsItsTick() async {
        let world = World()
        world.granted = [.accessibility]
        let permissions = SetupPermissions(
            isGranted: { world.granted.contains($0) },
            request: { permission in
                world.requested.append(permission)
                try? await Task.sleep(for: .milliseconds(80))
                world.granted.insert(permission)
                world.marks.append(.now)
            }
        )
        let model = OnboardingModel(client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
                                    permissions: permissions, defaults: defaults(),
                                    pollInterval: .milliseconds(10), settle: .milliseconds(400))
        model.continueFromMail()
        #expect(model.step == .permissions)
        let asking = Task { await model.request(.microphone) }
        #expect(await eventually { world.requested == [.microphone] })
        // Closed and opened again while macOS's alert is still up.
        model.windowClosed()
        let watching = Task { await model.watchPermissions() }
        defer { watching.cancel() }
        await asking.value
        #expect(await eventually { model.step == .tryIt })
        #expect(ContinuousClock.now - world.marks[0] >= .milliseconds(390))
        #expect(world.requested == [.microphone])
    }

    // MARK: - Mail

    @Test func anAnswerForAnEarlierKeyDoesNotReachTheAccountSignedInSince() async throws {
        let late: [AlphaStub.Reply] = [
            .init(json: Self.connection(stored: 12), delay: 0.5),
            .init(status: 401, delay: 0.5),
        ]
        for reply in late {
            let world = World(), keys = MemoryDeviceKey("earlier-device-key")
            let model = atMail(world, keys: keys)
            // The earlier account's request is still on its way back.
            world.reply("/v1/mail/connections", reply)
            let slow = Task { await model.refreshMail() }
            #expect(await eventually { world.sent("/v1/mail/connections") == 1 })
            // Meanwhile the server refuses that key, and someone else signs in.
            world.reply("/v1/mail/connections", .init(status: 401))
            await model.refreshMail()
            #expect(model.signInProblem == .signedOut)
            world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
            world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
            model.enter(Self.code)
            #expect(await eventually { model.step == .mail })
            await slow.value
            #expect(model.connections.isEmpty)
            #expect(model.step == .mail)
            #expect(model.signInProblem == nil)
            #expect(try keys.read() == "synthetic-device-key")
        }
    }

    @Test func aSupersededMailboxReadCannotRestoreReadinessOrLowerTheCount() async {
        for staleFails in [false, true] {
            let world = World()
            let model = atMail(world)
            let old = Self.connection(stored: 10).replacingOccurrences(of: "\"reconciling\":false", with: "\"reconciling\":false,\"voice_ready\":true,\"sent_read\":10,\"sent_total\":100")
            let fresh = Self.connection(stored: 20).replacingOccurrences(of: "\"reconciling\":false", with: "\"reconciling\":true,\"voice_ready\":false,\"sent_read\":20,\"sent_total\":100")
            var observed = 0
            model.mailChanged = { _ in observed += 1 }
            world.reply("/v1/mail/connections", staleFails ? .init(status: 401, delay: 0.2) : .init(json: old, delay: 0.2))
            let slow = Task { await model.refreshMail() }
            #expect(await eventually { world.sent("/v1/mail/connections") == 1 })
            world.reply("/v1/mail/connections", .init(json: fresh))
            await model.refreshMail()
            await slow.value
            #expect(model.connections.first?.sentRead == 20)
            #expect(model.connections.first?.reconciling == true)
            #expect(model.voice == .learning)
            #expect(model.signInProblem == nil)
            #expect(observed == 1)
        }
    }

    @Test func aConsentPageDoesNotOpenOnceThePersonHasLeftThePage() async {
        for leave in [{ (model: OnboardingModel) in model.windowClosed() }, { $0.continueFromMail() }] {
            let world = World()
            let model = atMail(world)
            world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
            world.reply("/v1/mail/gmail/connect",
                        .init(json: #"{"authorization_url":"https://consent.invalid/synthetic"}"#, delay: 0.15))
            let connecting = Task { await model.connect(.gmail) }
            #expect(await eventually { world.sent("/v1/mail/gmail/connect") == 1 })
            leave(model)
            await connecting.value
            #expect(world.opened.isEmpty)
            #expect(model.awaiting == nil)
        }
    }

    @Test func aMailboxThatStoppedOrWaitsForARetryIsNotShownAsComingIn() async {
        let cases: [(state: String, error: String?, standing: OnboardingModel.MailStanding, working: Bool)] = [
            ("syncing", nil, .syncing, true),
            ("ready", nil, .upToDate, false),
            ("syncing", "sync_failed", .retrying, false),
            ("ready", "sync_failed", .retrying, false),
            ("syncing", "sync_paused", .stopped, false),
            ("ready", "sync_paused", .stopped, false),
            ("reconnect_required", "reconnect_required", .needsReconnect, false),
            ("reconnect_required", "sync_paused", .needsReconnect, false),
        ]
        let world = World()
        let model = atMail(world)
        for (state, error, standing, working) in cases {
            world.reply("/v1/mail/connections", .init(json: Self.connection(state: state, stored: 40, error: error)))
            await model.refreshMail()
            #expect(model.connections.map(OnboardingModel.standing(of:)) == [standing], "\(state) \(error ?? "no error")")
            #expect(model.isMailWorking == working, "\(state) \(error ?? "no error")")
        }
    }

    @Test func theLastPageSaysMailIsBeingReadOnlyWhenSomeCanArrive() async {
        let world = World()
        let model = atMail(world)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.refreshMail()
        #expect(model.mailImport == .notConnected)
        let cases: [(state: String, stored: Int, error: String?, learning: OnboardingModel.MailImport)] = [
            ("syncing", 0, nil, .started),
            ("syncing", 0, "sync_failed", .stalled),
            ("reconnect_required", 0, "reconnect_required", .stalled),
            ("syncing", 0, "sync_paused", .stalled),
            ("syncing", 12, nil, .imported(12)),
            // Already imported messages remain counted after a pause.
            ("reconnect_required", 12, "reconnect_required", .imported(12)),
        ]
        for (state, stored, error, learning) in cases {
            world.reply("/v1/mail/connections", .init(json: Self.connection(state: state, stored: stored, error: error)))
            await model.refreshMail()
            #expect(model.mailImport == learning, "\(state) \(stored) \(error ?? "no error")")
        }
    }

    @Test func aProviderTheServerCannotConnectIsReportedAndNothingOpens() async {
        let world = World()
        let model = atMail(world, offersOutlook: true)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":["gmail","outlook"]}"#))
        await model.refreshMail()
        world.reply("/v1/mail/outlook/connect", .init(status: 503, json: #"{"detail":"mail_not_configured"}"#))
        await model.connect(.outlook)
        #expect(model.mailProblem == .unavailable(.outlook))
        #expect(model.awaiting == nil)
        #expect(world.opened.isEmpty)
    }

    @Test func mailProvidersFollowServerConfigurationAndOlderServersOfferOnlyGmail() async {
        let world = World(), model = atMail(world, offersOutlook: true)
        #expect(model.availableProviders.isEmpty)
        let cases: [(json: String, providers: [AlphaClient.MailProvider])] = [
            (#"{"connections":[]}"#, [.gmail]),
            (#"{"connections":[],"available_providers":["gmail"]}"#, [.gmail]),
            (#"{"connections":[],"available_providers":["outlook","unknown","gmail","outlook"]}"#, [.gmail, .outlook]),
            (#"{"connections":[],"available_providers":["outlook"]}"#, [.outlook]),
            (#"{"connections":[],"available_providers":[]}"#, []),
            (#"{"connections":[],"available_providers":["unknown"]}"#, []),
            (#"{"connections":[]}"#, [.gmail]),
        ]
        for (json, providers) in cases {
            world.reply("/v1/mail/connections", .init(json: json))
            await model.refreshMail()
            #expect(model.availableProviders == providers)
            #expect(model.isMailOffered == !providers.isEmpty)
            #expect(model.mailOffer(for: .outlook) == (providers.contains(.outlook) ? .connect : .nothing))
        }
        await model.connect(.outlook)
        #expect(world.sent("/v1/mail/outlook/connect") == 0)
        #expect(model.mailProblem == nil)
    }

    @Test(arguments: [false, true])
    func outlookFlagControlsNewOffersAndOneProviderLayout(enabled: Bool) async {
        let world = World(), model = atMail(world, offersOutlook: enabled)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":["gmail","outlook"]}"#))
        await model.refreshMail()
        #expect(!OnboardingModel.offersOutlookByDefault)
        #expect(model.availableProviders == [.gmail, .outlook])
        #expect(model.offeredMailProviders == (enabled ? [.gmail, .outlook] : [.gmail]))
        #expect(model.mailPageHeight == (enabled ? 256 : 112))
        #expect(model.mailOffer(for: .outlook) == (enabled ? .connect : .nothing))
        #expect(model.canAddMail)
        if !enabled {
            await model.connect(.outlook)
            #expect(world.sent("/v1/mail/outlook/connect") == 0)
            #expect(model.awaiting == nil)
        }
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":["outlook"]}"#))
        await model.refreshMail()
        #expect(model.isMailOffered == enabled)
        #expect(model.canAddMail == enabled)
    }

    @Test(arguments: [false, true], ["syncing", "ready", "reconnect_required"])
    func existingOutlookKeepsStatusAndReconnectWhenNewOffersAreHidden(enabled: Bool, state: String) async throws {
        let world = World(), model = atMail(world, offersOutlook: enabled)
        let json = Self.connection("outlook", state: state, stored: 4212).dropLast() + #", "available_providers":["gmail","outlook"]}"#
        world.reply("/v1/mail/connections", .init(json: String(json)))
        await model.refreshMail()
        let row = try #require(model.settingsConnections.first)
        #expect(row.provider == "outlook")
        #expect(row.state == state)
        #expect(row.storedMessages == 4212)
        #expect(model.availableConnections == [row])
        #expect(model.mailImport != .notConnected)
        #expect(model.isMailWorking == (state == "syncing"))
        #expect(model.mailOffer(for: .outlook) == (state == "reconnect_required" ? .reconnect : .nothing))
        #expect(model.offeredMailProviders == (state == "reconnect_required" ? [.gmail, .outlook] : [.gmail]))
        #expect(model.canAddMail) // Gmail remains available.
    }

    @Test func gmailOnlyAccountOffersNoAddAccountWithOutlookHidden() async {
        let world = World(), model = atMail(world)
        let json = Self.connection("gmail", state: "ready").dropLast() + #", "available_providers":["gmail","outlook"]}"#
        world.reply("/v1/mail/connections", .init(json: String(json)))
        await model.refreshMail()
        #expect(!model.canAddMail)
        #expect(model.offeredMailProviders.isEmpty)
        #expect(model.mailPageHeight == 176)
    }

    @Test(arguments: [204, 500, 401])
    func existingOutlookCanDisconnectWithFlagOff(status: Int) async throws {
        let world = World(), keys = MemoryDeviceKey("synthetic-device-key")
        let model = atMail(world, keys: keys)
        // Even a server that no longer offers Outlook must leave it manageable.
        world.reply("/v1/mail/connections", .init(json: Self.connection("outlook", state: "ready")))
        await model.refreshMail()
        let row = try #require(model.settingsConnections.first)
        let path = "/v1/mail/connections/\(row.id.uuidString)"
        world.reply(path, .init(status: status))
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[],"available_providers":["gmail","outlook"]}"#))
        await model.disconnectMail(row)
        let request = try #require(world.lock.withLock { world.requests.first { $0.path == path } })
        #expect(request.method == "DELETE")
        #expect(request.authorization == "Bearer synthetic-device-key")
        #expect(request.body.isEmpty)
        #expect(model.disconnectingMail == nil)
        #expect(model.settingsConnections.isEmpty == (status != 500))
        #expect(model.mailDisconnectFailed == (status == 500))
        if status == 204 {
            #expect(model.mailOffer(for: .outlook) == .nothing)
            #expect(model.offeredMailProviders == [.gmail])
        }
        if status == 401 { #expect(model.backendKey == nil) }
    }

    @Test func pollingClearsDisconnectFailureOnlyAfterConfirmingItsMailboxIsGone() async throws {
        let world = World(), model = atMail(world)
        let original = Self.connection("outlook", state: "ready")
        world.reply("/v1/mail/connections", .init(json: original))
        await model.refreshMail()
        let row = try #require(model.settingsConnections.first)
        world.reply("/v1/mail/connections/\(row.id.uuidString)", .init(status: 500))
        await model.disconnectMail(row)
        #expect(model.mailDisconnectFailed)
        world.reply("/v1/mail/connections", .init(status: 500))
        await model.refreshMail()
        #expect(model.mailDisconnectFailed)
        world.reply("/v1/mail/connections", .init(json: original))
        await model.refreshMail()
        #expect(model.mailDisconnectFailed)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.refreshMail()
        #expect(!model.mailDisconnectFailed)
        #expect(model.settingsConnections.isEmpty)
    }

    @Test func aLateDisconnectErrorDoesNotUndoPollingConfirmation() async throws {
        let world = World(), model = atMail(world)
        world.reply("/v1/mail/connections", .init(json: Self.connection("outlook", state: "ready")))
        await model.refreshMail()
        let row = try #require(model.settingsConnections.first)
        let path = "/v1/mail/connections/\(row.id.uuidString)"
        world.reply(path, .init(status: 500, delay: 0.2))
        let disconnect = Task { await model.disconnectMail(row) }
        #expect(await eventually { world.sent(path) == 1 })
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.refreshMail()
        #expect(model.settingsConnections.isEmpty)
        await disconnect.value
        #expect(!model.mailDisconnectFailed)
    }

    @Test func oldProgressCannotResurrectDisconnectedOutlook() async throws {
        let world = World(), model = atMail(world)
        let original = Self.connection("outlook", state: "ready")
        world.reply("/v1/mail/connections", .init(json: original))
        await model.refreshMail()
        let row = try #require(model.settingsConnections.first)
        world.reply("/v1/mail/connections", .init(json: original, delay: 0.2))
        let oldRead = Task { await model.refreshMail() }
        #expect(await eventually { world.sent("/v1/mail/connections") == 2 })
        world.reply("/v1/mail/connections/\(row.id.uuidString)", .init(status: 204))
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.disconnectMail(row)
        await oldRead.value
        #expect(model.settingsConnections.isEmpty)
    }

    @Test func mailControlsWaitForDisconnectToFinish() async throws {
        let world = World(), model = atMail(world)
        world.reply("/v1/mail/connections", .init(json: Self.connection("outlook", state: "ready")))
        await model.refreshMail()
        let row = try #require(model.settingsConnections.first)
        let path = "/v1/mail/connections/\(row.id.uuidString)"
        world.reply(path, .init(status: 500, delay: 0.1))
        #expect(model.canChangeMail)
        let disconnect = Task { await model.disconnectMail(row) }
        #expect(await eventually { world.sent(path) == 1 })
        #expect(!model.canChangeMail)
        await model.connect(.gmail)
        #expect(world.sent("/v1/mail/gmail/connect") == 0)
        await disconnect.value
        #expect(model.canChangeMail)
        #expect(model.settingsConnections == [row])
    }

    @Test func disconnectUsesTheSameMailboxAfterItsProgressChanges() async throws {
        let world = World(), model = atMail(world)
        world.reply("/v1/mail/connections", .init(json: Self.connection("outlook", stored: 4)))
        await model.refreshMail()
        let rowWhenConfirmed = try #require(model.settingsConnections.first)
        world.reply("/v1/mail/connections", .init(json: Self.connection("outlook", stored: 40)))
        await model.refreshMail()
        let path = "/v1/mail/connections/\(rowWhenConfirmed.id.uuidString)"
        world.reply(path, .init(status: 204))
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.disconnectMail(rowWhenConfirmed)
        #expect(world.sent(path) == 1)
        #expect(model.settingsConnections.isEmpty)
    }

    @Test(arguments: [204, 500])
    func oldDisconnectCannotChangeTheReplacementAccount(status: Int) async throws {
        let world = World(), keys = MemoryDeviceKey("synthetic-device-key")
        let model = atMail(world, keys: keys)
        world.reply("/v1/mail/connections", .init(json: Self.connection("outlook", state: "ready")))
        await model.refreshMail()
        let row = try #require(model.settingsConnections.first)
        let path = "/v1/mail/connections/\(row.id.uuidString)"
        world.reply(path, .init(status: status, delay: 0.1))
        let disconnect = Task { await model.disconnectMail(row) }
        #expect(await eventually { world.sent(path) == 1 })
        try keys.save("replacement-device-key")
        #expect(model.backendKey == "replacement-device-key")
        world.reply("/v1/mail/connections", .init(json: Self.connection("gmail", state: "ready")))
        await model.refreshMail()
        await disconnect.value
        #expect(model.settingsConnections.map(\.provider) == ["gmail"])
        #expect(!model.mailDisconnectFailed)
    }

    @Test func discoveryMustAnswerBeforeAnyProviderCanConnect() async {
        for reply in [AlphaStub.Reply(json: #"{"connections":[],"available_providers":["outlook"]}"#, delay: 0.1),
                      AlphaStub.Reply(status: 500, delay: 0.1)] {
            let world = World(), model = atMail(world)
            world.reply("/v1/mail/connections", reply)
            let connecting = Task { await model.connect(.gmail) }
            #expect(await eventually { world.sent("/v1/mail/connections") == 1 })
            #expect(model.availableProviders.isEmpty)
            #expect(!model.hasReadMail)
            #expect(world.sent("/v1/mail/gmail/connect") == 0)
            await connecting.value
            #expect(world.sent("/v1/mail/gmail/connect") == 0)
        }
    }

    @Test func closingSetupDuringDiscoveryCannotStartConsentAfterItAnswers() async {
        let world = World(), model = atMail(world)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#, delay: 0.1))
        let connecting = Task { await model.connect(.gmail) }
        #expect(await eventually { world.sent("/v1/mail/connections") == 1 })
        model.windowClosed()
        await connecting.value
        #expect(world.sent("/v1/mail/gmail/connect") == 0)
        #expect(model.mailProblem == nil)
    }

    @Test func unavailableMailboxesStayInProgressButAreHiddenFromSetupAndSettings() async throws {
        let world = World(), keys = MemoryDeviceKey("synthetic-device-key")
        let model = atMail(world, keys: keys)
        let connection = Self.connection("outlook", state: "reconnect_required")
        world.reply("/v1/mail/connections", .init(json: connection))
        await model.refreshMail()
        #expect(model.connections.count == 1)
        #expect(model.availableConnections.isEmpty)
        #expect(model.mailOffer(for: .outlook) == .nothing)
        #expect(model.mailImport == .notConnected)
        #expect(!model.isMailWorking)

        world.reply("/v1/mail/connections", .init(json: Self.connection("outlook", state: "syncing", stored: 40)))
        await model.refreshMail()
        #expect(model.mailImport == .notConnected)
        #expect(!model.isMailWorking)

        let configured = connection.dropLast() + #", "available_providers":["gmail","outlook"]}"#
        world.reply("/v1/mail/connections", .init(json: String(configured)))
        await model.refreshMail()
        #expect(model.availableConnections.count == 1)
        #expect(model.mailOffer(for: .outlook) == .reconnect)

        try keys.save("replacement-device-key")
        #expect(model.backendKey == "replacement-device-key")
        #expect(model.availableProviders.isEmpty)
        #expect(model.availableConnections.isEmpty)
    }

    @Test func aConsentPageThatIsNotHTTPSIsNeverOpened() async {
        let world = World()
        let model = atMail(world)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        world.reply("/v1/mail/gmail/connect", .init(json: #"{"authorization_url":"http://accounts.google.com/synthetic"}"#))
        await model.connect(.gmail)
        #expect(world.opened.isEmpty)
        #expect(model.mailProblem == .unavailable(.gmail))
        world.reply("/v1/mail/gmail/connect", .init(json: #"{"authorization_url":"file:///etc/passwd"}"#))
        await model.connect(.gmail)
        #expect(world.opened.isEmpty)
    }

    @Test func aRevokedKeySignsTheMacOut() async throws {
        let world = World(), keys = MemoryDeviceKey("synthetic-device-key")
        let model = atMail(world, keys: keys)
        world.reply("/v1/mail/connections", .init(status: 401, json: #"{"detail":"unauthorized"}"#))
        await model.refreshMail()
        #expect(model.step == .signIn)
        #expect(model.signInProblem == .signedOut)
        #expect(try keys.read() == nil)
    }

    @Test func aRevokedKeyThatCannotBeDeletedIsNotUsedAgain() async throws {
        let world = World(), store = defaults(), keys = MemoryDeviceKey("synthetic-device-key")
        store.set("done", forKey: "onboardingStep")
        let model = atMail(world, keys: keys, defaults: store)
        model.reopenMail()
        keys.refusesDeletes = true
        world.reply("/v1/mail/connections", .init(status: 401, json: #"{"detail":"unauthorized"}"#))
        await model.refreshMail()
        #expect(model.step == .signIn)
        #expect(try keys.read() == "synthetic-device-key")
        // The next launch still asks for a code, and sends nothing with the old key.
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        let relaunched = self.model(world, keys: keys, defaults: store)
        #expect(relaunched.step == .signIn)
        await relaunched.refreshMail()
        #expect(world.sent("/v1/mail/connections") == 1)
    }

    @Test func aNewAccountAfterASignOutStartsSetupFromTheBeginning() async throws {
        let world = World(), store = defaults(), keys = MemoryDeviceKey("synthetic-device-key")
        store.set("done", forKey: "onboardingStep")
        world.granted = [.microphone]
        let model = self.model(world, keys: keys, defaults: store)
        #expect(model.isFinished)
        model.reopenMail()
        world.reply("/v1/mail/connections", .init(status: 401, json: #"{"detail":"unauthorized"}"#))
        await model.refreshMail()
        #expect(model.step == .signIn)
        world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
        model.enter(Self.code)
        #expect(await eventually { model.step == .mail })
        // Closing the window now leaves setup unfinished; the old account's "done" is gone.
        model.windowClosed()
        #expect(!model.isFinished)
        #expect(!self.model(world, keys: keys, defaults: store).isFinished)
    }

    @Test func aServerWithoutMailSaysSoInPlaceOfConnectButtons() async {
        let world = World()
        let model = atMail(world)
        #expect(model.isMailOffered)
        await model.refreshMail()
        #expect(!model.isMailOffered)
        #expect(model.mailProblem == nil)
        // Once the server has the routes, the rows come back.
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.refreshMail()
        #expect(model.isMailOffered)
        model.continueFromMail()
        #expect(model.step == .tryIt)
    }

    @Test func aDroppedConnectionWhileWatchingClearsWhenItComesBack() async {
        let world = World()
        let model = atMail(world)
        world.reply("/v1/mail/connections", .init(failure: .networkConnectionLost))
        await model.refreshMail()
        #expect(model.mailProblem == .unreachable)
        world.reply("/v1/mail/connections", .init(json: Self.connection(stored: 3)))
        await model.refreshMail()
        #expect(model.mailProblem == nil)
        #expect(model.connections.count == 1)
    }

    @Test func mailCanWaitAndBeConnectedLaterFromSettings() async {
        let world = World(), store = defaults(), keys = MemoryDeviceKey("synthetic-device-key")
        let model = atMail(world, keys: keys, defaults: store)
        model.continueFromMail()
        model.continueFromDictation()
        model.finish()
        #expect(model.isFinished)
        #expect(self.model(world, keys: keys, defaults: store).isFinished)
        model.reopenMail()
        #expect(model.step == .mail)
        // Closing the window there leaves setup finished.
        model.windowClosed()
        #expect(model.isFinished)
        // And so does going on from it: the first dictation is not asked for twice.
        model.reopenMail()
        model.continueFromMail()
        #expect(model.isFinished)
    }

    @Test func reachingTheEndOfSetupTellsTheAppOnceAndConnectingMailLaterDoesNot() async {
        let world = World(), store = defaults(), keys = MemoryDeviceKey("synthetic-device-key")
        let model = atMail(world, keys: keys, defaults: store)
        var finishes = 0
        model.finished = { finishes += 1 }
        model.continueFromMail()
        model.continueFromDictation()
        #expect(finishes == 0)
        model.finish()
        #expect(finishes == 1)
        // Finishing again, or connecting mail from Settings, is not setup finishing.
        model.finish()
        model.reopenMail()
        model.continueFromMail()
        model.windowClosed()
        #expect(model.isFinished)
        #expect(finishes == 1)
        // Nor is a launch with setup already finished.
        let again = self.model(world, keys: keys, defaults: store)
        again.finished = { finishes += 1 }
        again.finish()
        again.windowClosed()
        #expect(finishes == 1)
    }

    // MARK: - Languages

    @Test func theMacsOwnLanguagesAreOfferedFirstAfterEnglish() {
        #expect(LanguageChoice.code(of: "en-US") == "en")
        #expect(LanguageChoice.code(of: "zh-Hans-CN") == "zh")
        #expect(LanguageChoice.code(of: "pt_BR") == "pt")
        #expect(LanguageChoice.code(of: "fil-PH") == nil)
        #expect(LanguageChoice.code(of: "yue-Hant-HK") == nil)
        #expect(LanguageChoice.code(of: "EN-us") == "en")
        #expect(LanguageChoice.code(of: "zh-Hans") == "zh")
        // A Mac that prefers the same language twice over offers it once.
        #expect(LanguageChoice.offered(preferred: ["pt-BR", "pt-PT", "fil-PH", "en-US"]).prefix(3) == ["en", "pt", "es"])
        #expect(LanguageChoice.offered(preferred: ["te-IN", "en-US", "hi-IN"])
            == ["en", "te", "hi", "es", "fr", "de", "pt", "it", "ru", "zh", "ja", "ar"])
        #expect(LanguageChoice.offered(preferred: []) == ["en"] + LanguageChoice.measured)
        // English, the Mac's own (three at most) and whatever is picked are buttons.
        #expect(LanguageChoice.shown(preferred: ["en-US"], chosen: ["en"]) == ["en"])
        #expect(LanguageChoice.shown(preferred: ["hi-IN", "en-GB", "te-IN", "ta-IN", "kn-IN"], chosen: ["en", "ja"])
            == ["en", "hi", "te", "ta", "ja"])
    }

    @Test func upToFiveLanguagesAndNeverNone() {
        #expect(LanguageChoice.toggled("es", in: ["en"]) == ["en", "es"])
        #expect(LanguageChoice.toggled("en", in: ["en", "es"]) == ["es"])
        #expect(LanguageChoice.toggled("es", in: ["es"]) == ["es"])
        let five = ["en", "es", "fr", "de", "pt"]
        #expect(LanguageChoice.toggled("it", in: five) == five)
        #expect(LanguageChoice.toggled("pt", in: five) == ["en", "es", "fr", "de"])
        // English alone is saved as nothing, the default.
        #expect(LanguageChoice.saved(for: ["en"]) == [])
        #expect(LanguageChoice.saved(for: ["es"]) == ["es"])
        #expect(LanguageChoice.saved(for: ["en", "hi"]) == ["en", "hi"])
        #expect(LanguageChoice.chosen(from: []) == ["en"])
        #expect(LanguageChoice.chosen(from: ["hi", "en"]) == ["hi", "en"])
        // Only two-letter codes are ever saved, with no repeats and five at most.
        #expect(LanguageChoice.saved(for: ["eng", "hi", "HI", "hi", "fil"]) == ["hi"])
        #expect(LanguageChoice.saved(for: ["en", "es", "fr", "de", "pt", "it"]) == ["en", "es", "fr", "de", "pt"])
        #expect(LanguageChoice.chosen(from: ["eng"]) == ["en"])
    }

    @Test func aPickedLanguageIsSavedAtOnceAndEnglishIsTheDefault() {
        @MainActor final class Saved { var codes: [String] = []; var writes = 0 }
        let world = World(), saved = Saved()
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        func make() -> OnboardingModel {
            OnboardingModel(
                client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
                permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
                languages: DictationLanguages(current: { saved.codes }, save: { saved.codes = $0; saved.writes += 1 }),
                preferredLanguages: ["en-US", "hi-IN"], defaults: defaults()
            )
        }
        let model = make()
        #expect(model.chosenLanguages == ["en"])
        #expect(saved.writes == 0)
        model.toggleLanguage("hi")
        #expect(model.chosenLanguages == ["en", "hi"])
        #expect(saved.codes == ["en", "hi"])
        // The only language left cannot be pressed away, and nothing is written for it.
        model.toggleLanguage("en")
        model.toggleLanguage("hi")
        #expect(model.chosenLanguages == ["hi"])
        #expect(saved.codes == ["hi"])
        #expect(saved.writes == 2)
        // A later launch shows what was saved.
        #expect(make().chosenLanguages == ["hi"])
        // Back to English alone is saved as the default.
        model.toggleLanguage("en")
        model.toggleLanguage("hi")
        #expect(saved.codes == [])
        // Settings changes the same choice. The page shows what is saved
        // now and adds to that, not to what it showed before.
        saved.codes = ["es"]
        #expect(model.chosenLanguages == ["es"])
        model.toggleLanguage("hi")
        #expect(saved.codes == ["es", "hi"])
    }

    @Test func twoKindsOfOneLanguageTakeOnePlaceBesideEnglish() {
        // Mexican and European Spanish are one button, so French and Hindi
        // both still fit before More.
        #expect(LanguageChoice.shown(preferred: ["es-MX", "es-ES", "en-US", "fr-FR", "hi-IN", "de-DE"], chosen: ["en"])
            == ["en", "es", "fr", "hi"])
    }

    @Test func aPickedLanguageTheMacNoLongerPrefersCanStillBeTakenAway() {
        // Korean was picked while it was one of the Mac's languages. It is
        // offered still, once, and a saved value that is no code is not.
        #expect(LanguageChoice.offered(preferred: ["en-US"], chosen: ["ko", "es", "fil"])
            == ["en", "es", "fr", "de", "pt", "it", "ru", "hi", "zh", "ja", "ar", "ko"])
    }

    @Test func aBuildWithoutDictationAsksNothingAboutLanguages() {
        let world = World()
        let model = atMail(world)
        #expect(model.languages == nil)
        model.toggleLanguage("es")
        #expect(model.chosenLanguages == ["en"])
    }

    // MARK: - First dictation

    @Test func theLastPageShowsOnlyADictationMadeWhileItIsOpen() async {
        @MainActor final class Speech {
            var phase = FirstDictation.Phase.idle
            var latest: (text: String, at: Date)? = ("said before setup", Date(timeIntervalSinceNow: -60))
        }
        let world = World(), speech = Speech()
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
            dictation: FirstDictation(keyName: { "fn" }, phase: { speech.phase }, latest: { speech.latest }),
            defaults: defaults()
        )
        model.continueFromMail()
        #expect(model.step == .shortcut)
        model.continueFromShortcut()
        #expect(model.step == .tryIt)
        #expect(model.firstDictation == .waiting)
        speech.phase = .listening
        #expect(model.firstDictation == .listening)
        speech.phase = .finishing
        #expect(model.firstDictation == .finishing)
        speech.phase = .idle
        speech.latest = ("Running ten minutes late.", Date())
        #expect(model.firstDictation == .heard("Running ten minutes late."))
        model.continueFromDictation()
        #expect(model.step == .reply)
        model.finish()
        #expect(model.isFinished)
    }

    /// A stand-in for dictation on the last page, and what the page did to it.
    @MainActor private final class Dictation {
        var phase = FirstDictation.Phase.idle
        var latest: (text: String, at: Date)?
        var missed: Date?
        var silent: Date?
        var key = "fn"
        var isAvailable = true
        var microphoneFailed = false
        var quitting = false
        var insertions: [(String, Date)] = []

        var port: FirstDictation {
            FirstDictation(isAvailable: { self.isAvailable }, microphoneFailed: { self.microphoneFailed },
                           keyName: { self.key }, phase: { self.phase },
                           latest: { self.latest }, missed: { self.missed }, silent: { self.silent },
                           keyNames: { ["fn", "right option", "right command"] }, chooseKey: { self.key = $0 },
                           inserted: { self.insertions.append(($0, $1)) }, isQuitting: { self.quitting })
        }
    }

    private func atLastPage(_ dictation: Dictation, languages: DictationLanguages? = nil) -> OnboardingModel {
        let world = World()
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
            dictation: dictation.port, languages: languages, defaults: defaults()
        )
        // Mail comes before the shortcut and the first dictation.
        #expect(model.step == .mail)
        model.continueFromMail()
        #expect(model.step == .shortcut)
        model.continueFromShortcut()
        return model
    }

    @Test func aMicrophoneThatWouldNotOpenKeepsThePageOnItsFirstDictation() {
        let dictation = Dictation()
        let languages = DictationLanguages(current: { [] }, save: { _ in })
        let model = atLastPage(dictation, languages: languages)
        #expect(!model.firstDictationNeedsMicrophone)
        // The key was held and the microphone would not open. The page
        // still asks for a first dictation, with a word about why.
        dictation.microphoneFailed = true
        #expect(model.firstDictation == .waiting)
        #expect(model.firstDictationNeedsMicrophone)
        #expect(model.asksLanguages)
        // While the next try is being made it says nothing of the last.
        dictation.phase = .listening
        #expect(!model.firstDictationNeedsMicrophone)
    }

    @Test func dictationThatBecomesAvailableDuringSetupIsOfferedThen() {
        // A build that learns where to send dictations only after sign-in:
        // the page has nothing to offer at first, and asks nothing.
        let dictation = Dictation()
        dictation.isAvailable = false
        let model = atLastPage(dictation, languages: DictationLanguages(current: { [] }, save: { _ in }))
        #expect(model.firstDictation == .unavailable)
        #expect(!model.asksLanguages)
        dictation.isAvailable = true
        #expect(model.firstDictation == .waiting)
        #expect(model.asksLanguages)
        // With nowhere to save an answer there is no question either way.
        #expect(!atLastPage(Dictation()).asksLanguages)
    }

    @Test func theKeyToHoldIsThePersonsToChoose() {
        let dictation = Dictation()
        let model = atLastPage(dictation)
        model.chooseDictationKey("right option")
        #expect(dictation.key == "right option")
        // Only a key dictation offers can be chosen.
        model.chooseDictationKey("caps lock")
        #expect(dictation.key == "right option")
        // The dictation page goes back to the shortcut to change it.
        model.changeShortcut()
        #expect(model.step == .shortcut)
    }

    @Test func aTryThatCameBackWithNoWordsIsSaidToHaveMissed() {
        let dictation = Dictation()
        // One that failed before the page opened is not this page's.
        dictation.missed = Date(timeIntervalSinceNow: -60)
        let model = atLastPage(dictation)
        #expect(!model.firstDictationMissed)
        dictation.missed = Date()
        #expect(model.firstDictationMissed)
        #expect(model.firstDictation == .waiting)
        // Not while the next try is being made, and not once words arrive.
        dictation.phase = .listening
        #expect(!model.firstDictationMissed)
        dictation.phase = .idle
        let heard = Date()
        dictation.latest = ("Running ten minutes late.", heard)
        #expect(!model.firstDictationMissed)
        #expect(model.firstDictation == .heard("Running ten minutes late."))
        // Another try after those words fails: the page reports the newest
        // try and does not go on showing the earlier success.
        dictation.missed = heard.addingTimeInterval(5)
        #expect(model.firstDictation == .waiting)
        #expect(model.firstDictationMissed)
        // And words after that are shown again.
        dictation.latest = ("Save me a seat.", heard.addingTimeInterval(9))
        #expect(model.firstDictation == .heard("Save me a seat."))
        #expect(!model.firstDictationMissed)
    }

    @Test func aTryThatHeardNothingIsSaidToHaveHeardNothing() {
        let dictation = Dictation()
        // Silence from before the page opened is not this page's.
        dictation.silent = Date(timeIntervalSinceNow: -60)
        let model = atLastPage(dictation)
        #expect(!model.firstDictationSilent)
        #expect(model.firstDictation == .waiting)
        let silent = Date()
        dictation.silent = silent
        #expect(model.firstDictationSilent)
        #expect(!model.firstDictationMissed)
        #expect(model.firstDictation == .waiting)
        // Not while the next try is being made.
        dictation.phase = .listening
        #expect(!model.firstDictationSilent)
        dictation.phase = .idle
        // The newest try decides, whichever way it ended.
        dictation.missed = silent.addingTimeInterval(5)
        #expect(!model.firstDictationSilent)
        #expect(model.firstDictationMissed)
        dictation.silent = silent.addingTimeInterval(9)
        #expect(model.firstDictationSilent)
        #expect(!model.firstDictationMissed)
        dictation.latest = ("Save me a seat.", silent.addingTimeInterval(12))
        #expect(model.firstDictation == .heard("Save me a seat."))
        #expect(!model.firstDictationSilent)
        // Silence after words takes the page back to asking.
        dictation.silent = silent.addingTimeInterval(20)
        #expect(model.firstDictation == .waiting)
        #expect(model.firstDictationSilent)
    }

    @Test func theFieldIsGivenEachArrivalOfWordsWhateverWasTriedAfter() {
        let dictation = Dictation()
        // Words from before the page opened are not this page's.
        dictation.latest = ("Earlier.", Date(timeIntervalSinceNow: -60))
        let model = atLastPage(dictation)
        #expect(model.firstDictationWords == nil)
        let heard = Date()
        dictation.latest = ("Running ten minutes late.", heard)
        #expect(model.firstDictationWords?.text == "Running ten minutes late.")
        #expect(model.firstDictationWords?.at == heard)
        // A later try that fails or hears nothing takes the page back to
        // asking, and the words already in the field are still its newest.
        dictation.missed = heard.addingTimeInterval(5)
        dictation.silent = heard.addingTimeInterval(9)
        dictation.phase = .listening
        #expect(model.firstDictation == .listening)
        #expect(model.firstDictationWords?.at == heard)
        // A second sentence, even the same one, is a new arrival.
        dictation.phase = .idle
        dictation.latest = ("Running ten minutes late.", heard.addingTimeInterval(20))
        #expect(model.firstDictationWords?.at == heard.addingTimeInterval(20))
    }

    @Test func wordsPutAfterTextGetASpaceOnlyWhereTheyWouldRunIntoIt() {
        #expect(FirstDictation.spaced("Save me a seat.", after: "") == "Save me a seat.")
        #expect(FirstDictation.spaced("Save me a seat.", after: "Running late.") == " Save me a seat.")
        #expect(FirstDictation.spaced("Save me a seat.", after: "Running late. ") == "Save me a seat.")
        #expect(FirstDictation.spaced("Save me a seat.", after: "Running late.\n") == "Save me a seat.")
        #expect(FirstDictation.spaced(" Save me a seat.", after: "Running late.") == " Save me a seat.")
        #expect(FirstDictation.spaced("", after: "Running late.") == "")
        // Not after an opening quote or bracket.
        #expect(FirstDictation.spaced("hello", after: "He said \u{201C}") == "hello")
        #expect(FirstDictation.spaced("hello", after: "(") == "hello")
        // Chinese and Japanese put no space between sentences.
        #expect(FirstDictation.spaced("给我留个座位。", after: "我迟到了。") == "给我留个座位。")
        #expect(FirstDictation.spaced("席を取っておいて。", after: "遅れます。") == "席を取っておいて。")
        // In the middle of text, a space on the side a word follows.
        #expect(FirstDictation.spaced("mighty", after: "Hello ", before: "there") == "mighty ")
        #expect(FirstDictation.spaced("mighty", after: "Hello", before: " there") == " mighty")
        #expect(FirstDictation.spaced("mighty", after: "Hello", before: "there") == " mighty ")
        #expect(FirstDictation.spaced("there", after: "Hello ", before: ".") == "there")
        #expect(FirstDictation.spaced("留个座位", after: "给我", before: "吧") == "留个座位")
        // Fullwidth letters are words; fullwidth punctuation is not.
        #expect(FirstDictation.spaced("hello", after: "\u{FF21}\u{FF22}\u{FF23}") == " hello")
        #expect(FirstDictation.spaced("hello", after: "\u{FF21}\u{FF22}", before: "\u{FF11}") == " hello ")
        #expect(FirstDictation.spaced("给我留个座位", after: "我迟到了\u{FF01}") == "给我留个座位")
        // Hindi and Arabic do.
        #expect(FirstDictation.spaced("मेरे लिए जगह रखना।", after: "देर हो रही है।") == " मेरे लिए जगह रखना।")
    }

    @Test func aBuildWithoutDictationStillEndsSetup() {
        let world = World()
        let model = atMail(world)
        model.continueFromMail()
        #expect(model.firstDictation == .unavailable)
        model.continueFromDictation()
        model.finish()
        #expect(model.isFinished)
    }

    // MARK: - Open at login

    /// Stands in for Login Items: whether Intention opens at login, and every
    /// answer the last page gave.
    @MainActor private final class LoginItems {
        var isOn = false
        var answers: [Bool] = []

        var port: SetupLoginItem {
            SetupLoginItem(isOn: { self.isOn }, answer: { self.answers.append($0) })
        }
    }

    private func atDictation(_ loginItems: LoginItems?, defaults: UserDefaults) -> OnboardingModel {
        let world = World()
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
            loginItem: loginItems?.port, defaults: defaults
        )
        model.continueFromMail()
        model.continueFromDictation()
        return model
    }

    /// The last page's voice line follows the server: ready only when it
    /// says so, imported when the import is done without it, and every
    /// list read reaches `VoiceReady` through `mailChanged`.
    @Test func theVoiceFollowsTheServersSignal() async {
        let world = World()
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }), defaults: defaults()
        )
        var seen: [[AlphaClient.MailConnection]] = []
        model.mailChanged = { seen.append($0) }
        #expect(model.voice == .unknown)
        func list(_ state: String, voice: String) -> AlphaStub.Reply {
            .init(json: #"{"connections":[{"id":"33333333-3333-4333-8333-333333333333","provider":"gmail","address":"synthetic@example.com","state":"\#(state)","stored_messages":40,"backfill_done":false,"blocked_messages":0,"reconciling":false,"last_synced_at":null,"error_code":null,"connected_at":"2026-10-03T10:00:00Z"\#(voice)}]}"#)
        }
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await model.refreshMail()
        #expect(model.voice == .noMail)
        world.reply("/v1/mail/connections", list("syncing", voice: #","voice_ready":false,"voice_examples":2"#))
        await model.refreshMail()
        #expect(model.voice == .learning)
        // Ready can come while the import still runs.
        world.reply("/v1/mail/connections", list("syncing", voice: #","voice_ready":true,"voice_examples":4"#))
        await model.refreshMail()
        #expect(model.voice == .ready)
        // Done without the signal, as with little sent mail or an older
        // server: imported, never ready.
        world.reply("/v1/mail/connections", list("ready", voice: #","voice_ready":false,"voice_examples":1"#))
        await model.refreshMail()
        #expect(model.voice == .imported)
        world.reply("/v1/mail/connections", list("ready", voice: ""))
        await model.refreshMail()
        #expect(model.voice == .imported)
        world.reply("/v1/mail/connections", list("reconnect_required", voice: ""))
        await model.refreshMail()
        #expect(model.voice == .stopped)
        // Every list read reaches it, changed or not.
        #expect(seen.count == 6)
        #expect(seen.last?.first?.voiceReady == nil)
        // The recap promises everything unless the settings say otherwise.
        #expect(model.recapOffers == .init(writesEmails: true, proposesReplies: true))
        model.offers = { .init(writesEmails: true, proposesReplies: false) }
        #expect(model.recapOffers == .init(writesEmails: true, proposesReplies: false))
    }

    @Test func setupEndsByAskingAboutLoginAndRegistersNothingBeforeTheAnswer() {
        for opens in [true, false] {
            let loginItems = LoginItems()
            let model = atDictation(loginItems, defaults: defaults())
            #expect(model.step == .reply)
            #expect(model.asksOpenAtLogin)
            // The question is not asked before the person reaches it.
            model.answerOpenAtLogin(true)
            #expect(loginItems.answers.isEmpty)
            model.finish()
            #expect(model.step == .openAtLogin)
            #expect(!model.isFinished)
            #expect(loginItems.answers.isEmpty)
            model.answerOpenAtLogin(opens)
            #expect(model.isFinished)
            #expect(loginItems.answers == [opens])
            // Asked once.
            model.answerOpenAtLogin(!opens)
            #expect(loginItems.answers == [opens])
        }
    }

    @Test func aMacThatAlreadyOpensIntentionAtLoginIsNotAsked() {
        let loginItems = LoginItems()
        loginItems.isOn = true
        let model = atDictation(loginItems, defaults: defaults())
        model.finish()
        #expect(model.isFinished)
        #expect(loginItems.answers.isEmpty)
        // Nor is a build with nowhere to save the answer.
        let unasked = atDictation(nil, defaults: defaults())
        #expect(!unasked.asksOpenAtLogin)
        unasked.finish()
        #expect(unasked.isFinished)
    }

    @Test func closingTheLastPageFinishesSetupWithoutOpeningAtLogin() {
        let loginItems = LoginItems()
        let model = atDictation(loginItems, defaults: defaults())
        model.finish()
        #expect(model.step == .openAtLogin)
        model.windowClosed()
        #expect(model.isFinished)
        #expect(loginItems.answers.isEmpty)
    }

    @Test func setupFinishesOnceTheLoginQuestionIsLeftNotBefore() {
        for leave in ["yes", "no", "close"] {
            let model = atDictation(LoginItems(), defaults: defaults())
            var finishes = 0
            model.finished = { finishes += 1 }
            model.finish()
            #expect(finishes == 0)
            switch leave {
            case "yes": model.answerOpenAtLogin(true)
            case "no": model.answerOpenAtLogin(false)
            default: model.windowClosed()
            }
            #expect(finishes == 1)
            model.windowClosed()
            #expect(finishes == 1)
        }
    }

    @Test func aRelaunchOnTheLastPageAsksAgain() {
        let store = defaults()
        let loginItems = LoginItems()
        atDictation(loginItems, defaults: store).finish()
        let relaunched = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { _ in true }, request: { _ in }),
            loginItem: loginItems.port, defaults: store
        )
        #expect(relaunched.step == .openAtLogin)
        relaunched.answerOpenAtLogin(true)
        #expect(relaunched.isFinished)
        #expect(loginItems.answers == [true])
    }

    @Test func aRelaunchOnTheLastPageAfterIntentionOpensAtLoginFinishesSetup() {
        let store = defaults()
        let loginItems = LoginItems()
        atDictation(loginItems, defaults: store).finish()
        // Turned on in Settings, or by an earlier yes, before the relaunch.
        loginItems.isOn = true
        let relaunched = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { _ in true }, request: { _ in }),
            loginItem: loginItems.port, defaults: store
        )
        #expect(relaunched.isFinished)
        #expect(loginItems.answers.isEmpty)
    }

    // MARK: - First email

    @Test func mailCanBeSkippedBeforePermissionsOrBeforeDictation() {
        let world = World()
        let model = model(world, keys: MemoryDeviceKey("synthetic-device-key"))
        #expect(model.step == .mail)
        model.continueFromMail()
        #expect(model.step == .permissions)
        let ready = World()
        ready.granted = [.microphone, .accessibility]
        let granted = self.model(ready, keys: MemoryDeviceKey("synthetic-device-key"))
        #expect(granted.step == .mail)
        granted.continueFromMail()
        #expect(granted.step == .tryIt)
        granted.continueFromDictation()
        #expect(granted.step == .reply)
    }

    @Test func savedMailStaysBeforePermissionsIncludingAfterAnUnreadableKey() {
        for grants: Set<SetupPermission> in [[], [.microphone, .accessibility]] {
            let world = World(), store = defaults(), keys = MemoryDeviceKey("synthetic-device-key")
            store.set("mail", forKey: "onboardingStep")
            world.granted = grants
            #expect(model(world, keys: keys, defaults: store).step == .mail)
            keys.refusesReads = true
            let waiting = model(world, keys: keys, defaults: store)
            keys.refusesReads = false
            waiting.retryKeyRead()
            #expect(waiting.step == .mail)
        }
        for saved in ["tryIt", "reply", "openAtLogin"] {
            let world = World(), store = defaults()
            store.set(saved, forKey: "onboardingStep")
            store.set(2, forKey: "onboardingStepOrder")
            #expect(model(world, keys: MemoryDeviceKey("synthetic-device-key"), defaults: store).step == .permissions)
        }
    }

    private static let ownThreadJSON = #"{"thread":{"thread_id":"AAQkAD12+/=","sender_name":"Alex Example","sender_address":"alex@example.com","subject":"Thursday","message":"Can we meet Thursday?","sent_at":"2026-10-10T12:34:56.123Z"},"reason":null}"#

    private func subjectModel(_ world: World, dictation: Dictation = Dictation(), writer: Writer = Writer(),
                              keys: MemoryDeviceKey = MemoryDeviceKey("synthetic-device-key"),
                              step: String = "reply", subjectInterval: Duration = .milliseconds(30),
                              subjectTimeout: Duration = .milliseconds(80)) async -> OnboardingModel {
        let store = defaults()
        store.set(step, forKey: "onboardingStep")
        store.set(2, forKey: "onboardingStepOrder")
        world.granted = [.microphone, .accessibility]
        world.reply("/v1/mail/connections", .init(json: Self.connection(stored: 3)))
        AlphaStub.answer = { world.answer($0) }
        let model = OnboardingModel(client: AlphaStub.client(), keys: keys,
                                    permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
                                    dictation: dictation.port, practice: writer.port, defaults: store,
                                    replySubjectInterval: subjectInterval, replySubjectTimeout: subjectTimeout)
        await model.refreshMail()
        return model
    }

    @Test func replyThreadStageRequiresDisplayAndDoesNotCountPrefetchOrRedraws() async throws {
        let world = World()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
        let model = await subjectModel(world, step: "tryIt")
        var events: [(UUID, OnboardingModel.ReplyThreadOutcome, Date)] = []
        model.recordReplyThreadShown = { events.append(($0, $1, $2)) }
        model.replyThreadIsVisible = { true }
        let watching = Task { await model.watchDictation() }
        #expect(await eventually { if case .own = model.replySubject { true } else { false } })
        #expect(events.isEmpty)
        model.replyThreadShown(.ownThread)
        #expect(events.isEmpty)
        model.continueFromDictation()
        #expect(model.step == .reply)
        model.replyThreadIsVisible = { false }
        model.replyThreadShown(.ownThread)
        #expect(events.isEmpty)
        model.replyThreadIsVisible = { true }
        let at = Date(timeIntervalSince1970: 1791670000)
        model.replyThreadShown(.ownThread, at: at)
        model.replyThreadShown(.ownThread)
        #expect(events.count == 1)
        #expect(events.first?.1 == .ownThread)
        #expect(events.first?.2 == at)
        model.replyThreadShown(.example, at: at)
        model.replyThreadShown(.example)
        #expect(events.count == 2)
        #expect(events.first?.0 == events.last?.0)
        #expect(events.last?.1 == .example)
        watching.cancel()
        await watching.value
    }

    @Test func replySubjectUsesTheAuthenticatedRouteAndDecodesTheOwnThread() async throws {
        let world = World()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
        let model = await subjectModel(world)
        #expect(model.replySubject == .looking)
        await model.refreshReplySubject()
        guard case let .own(thread) = model.replySubject else { Issue.record("Expected own thread"); return }
        #expect(thread.id == "AAQkAD12+/=")
        #expect(thread.senderName == "Alex Example")
        #expect(thread.senderAddress == "alex@example.com")
        #expect(thread.subject == "Thursday")
        #expect(thread.message == "Can we meet Thursday?")
        #expect(abs(thread.sentAt.timeIntervalSince1970 - 1791635696.123) < 0.001)
        let request = try #require(world.requests.last)
        #expect(request.path == "/v1/setup/reply-thread")
        #expect(request.authorization == "Bearer synthetic-device-key")
    }

    @Test func replySubjectExplainsPreparationAndMissingCandidatesAndBoundsFailures() async {
        let answers: [(AlphaStub.Reply, OnboardingModel.ExampleReason)] = [
            (.init(json: #"{"thread":null,"reason":"preparing"}"#), .preparing),
            (.init(json: #"{"thread":null,"reason":"no_candidate"}"#), .noCandidate),
            (.init(json: #"{"thread":null,"reason":"no_mail"}"#), .unavailable),
            (.init(status: 404), .unavailable),
            (.init(status: 503, json: #"{"detail":"setup_reply_busy"}"#), .unavailable),
            (.init(failure: .notConnectedToInternet), .unavailable),
            (.init(stalls: true), .unavailable),
        ]
        for (answer, reason) in answers {
            let world = World()
            world.reply("/v1/setup/reply-thread", answer)
            let model = await subjectModel(world)
            let started = ContinuousClock.now
            await model.refreshReplySubject()
            #expect(model.replySubject == .example(reason))
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }

    /// A failure that can pass is asked again while the page is untouched,
    /// so the person's own thread still arrives; an older server's 404 is
    /// final.
    /// A brief failure while a reason shows keeps that reason, so the
    /// page's words hold still until the server answers again.
    @Test func aBriefSubjectFailureKeepsTheReasonAlreadyShown() async {
        let world = World()
        world.reply("/v1/setup/reply-thread", .init(json: #"{"thread":null,"reason":"preparing"}"#))
        let model = await subjectModel(world)
        await model.refreshReplySubject()
        #expect(model.replySubject == .example(.preparing))
        world.reply("/v1/setup/reply-thread", .init(status: 503, json: #"{"detail":"setup_reply_busy"}"#))
        await model.refreshReplySubject()
        #expect(model.replySubject == .example(.preparing))
    }

    @Test func aBriefSubjectFailureIsAskedAgainAndA404IsNot() async {
        for failure in [AlphaStub.Reply(status: 503, json: #"{"detail":"setup_reply_busy"}"#),
                        AlphaStub.Reply(failure: .networkConnectionLost)] {
            let world = World()
            world.reply("/v1/setup/reply-thread", failure)
            let model = await subjectModel(world)
            let watching = Task { await model.watchReply() }
            #expect(await eventually { model.replySubject == .example(.unavailable) })
            world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
            #expect(await eventually { if case .own = model.replySubject { true } else { false } })
            watching.cancel()
            await watching.value
        }
        let world = World()
        world.reply("/v1/setup/reply-thread", .init(status: 404))
        let model = await subjectModel(world)
        let watching = Task { await model.watchReply() }
        #expect(await eventually { model.replySubject == .example(.unavailable) })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(world.sent("/v1/setup/reply-thread") == 1)
        watching.cancel()
        await watching.value
    }

    @Test func aStalledSubjectLookupResolvesAtTheFiveSecondDeadline() async {
        let world = World()
        world.reply("/v1/setup/reply-thread", .init(stalls: true))
        let model = await subjectModel(world, subjectTimeout: .seconds(5))
        #expect(model.replySubject == .looking)
        let started = ContinuousClock.now
        await model.refreshReplySubject()
        #expect(ContinuousClock.now - started < .seconds(6))
        #expect(model.replySubject == .example(.unavailable))
        #expect(world.sent("/v1/setup/reply-thread") == 1)
    }

    @Test func replySubjectPrefetchSurvivesTheTurnFromDictationToReply() async {
        let world = World()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
        let model = await subjectModel(world, step: "tryIt")
        let watching = Task { await model.watchDictation() }
        #expect(await eventually { if case .own = model.replySubject { true } else { false } })
        watching.cancel()
        await watching.value
        let selected = model.replySubject
        model.continueFromDictation()
        #expect(model.replySubject == selected)
        let reply = Task { await model.watchReply() }
        try? await Task.sleep(for: .milliseconds(80))
        reply.cancel()
        await reply.value
        #expect(world.sent("/v1/setup/reply-thread") == 1)
    }

    @Test func skippingAnActiveFirstDictationKeepsItsEndOffTheReplyPage() async {
        for phase: FirstDictation.Phase in [.listening, .finishing] {
            for end in ["words", "missed", "silent"] {
                let world = World(), dictation = Dictation(), writer = Writer()
                world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
                let model = await subjectModel(world, dictation: dictation, writer: writer, step: "tryIt")
                dictation.phase = phase
                model.continueFromDictation()
                #expect(model.step == .reply)
                #expect(model.reply == .waiting)
                // A click ending the carried recording must not lock the subject.
                model.toggleDictation()
                await model.replyTick()
                #expect(writer.asked.isEmpty)
                let ended = Date()
                switch end {
                case "words": dictation.latest = ("Words for the first page.", ended)
                case "missed": dictation.missed = ended
                default: dictation.silent = ended
                }
                dictation.phase = .idle
                // Even a lookup that finishes before the next tick may select
                // the real thread. The earlier attempt does not own its subject.
                await model.refreshReplySubject()
                guard case .own = model.replySubject else {
                    Issue.record("The first dictation locked the reply subject")
                    continue
                }
                await model.replyTick()
                await model.replyTick()
                #expect(writer.asked.isEmpty)
                #expect(model.replyWords == nil)
                #expect(model.reply == .waiting)
                #expect(!model.replyMissed)
                #expect(!model.replySilent)

                dictation.phase = .listening
                await model.replyTick()
                #expect(model.reply == .listening)
                dictation.phase = .idle
                dictation.latest = ("Thursday works for me.", Date())
                let writing = Task { await model.replyTick() }
                #expect(await eventually { writer.asked == ["Thursday works for me."] })
                #expect(writer.threads.first.flatMap { $0 }?.id == "AAQkAD12+/=")
                writer.answer(.success("See you Thursday."))
                await writing.value
                #expect(model.replyWords?.text == "See you Thursday.")
            }
        }
    }

    @Test func enteringReplyDuringAPrefetchDoesNotWaitForTheNextPollingInterval() async {
        let world = World()
        world.reply("/v1/setup/reply-thread", .init(stalls: true))
        let model = await subjectModel(world, step: "tryIt", subjectInterval: .seconds(10))
        let firstPage = Task { await model.watchDictation() }
        #expect(await eventually { world.sent("/v1/setup/reply-thread") == 1 })
        model.continueFromDictation()
        firstPage.cancel()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
        let replyPage = Task { await model.watchReply() }
        #expect(await eventually { if case .own = model.replySubject { true } else { false } })
        replyPage.cancel()
        await firstPage.value
        await replyPage.value
        #expect(world.sent("/v1/setup/reply-thread") == 2)
    }

    @Test func replySubjectRetriesWhileWaitingThenStopsAtOwnThread() async {
        for reason in ["preparing", "no_candidate"] {
            let world = World()
            world.reply("/v1/setup/reply-thread", .init(json: "{\"thread\":null,\"reason\":\"\(reason)\"}"))
            let model = await subjectModel(world)
            let watching = Task { await model.watchReply() }
            #expect(await eventually { world.sent("/v1/setup/reply-thread") >= 2 })
            world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
            #expect(await eventually { if case .own = model.replySubject { true } else { false } })
            let count = world.sent("/v1/setup/reply-thread")
            try? await Task.sleep(for: .milliseconds(90))
            #expect(world.sent("/v1/setup/reply-thread") == count)
            watching.cancel()
            await watching.value
        }
    }

    @Test func aSubjectAlreadyInFlightCannotReplaceOneAfterRecordingStarts() async {
        let world = World(), dictation = Dictation()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON, delay: 0.04))
        let model = await subjectModel(world, dictation: dictation)
        let request = Task { await model.refreshReplySubject() }
        #expect(await eventually { world.sent("/v1/setup/reply-thread") == 1 })
        dictation.phase = .listening
        await request.value
        #expect(model.replySubject == .example(.unavailable))
        dictation.phase = .idle
        await model.refreshReplySubject()
        #expect(world.sent("/v1/setup/reply-thread") == 1)
        #expect(model.replySubject == .example(.unavailable))
    }

    @Test func writerReceivesOwnThreadOrNilForTheExampleAndNeverChangesAfterWriting() async {
        for own in [true, false] {
            let world = World(), dictation = Dictation(), writer = Writer()
            world.reply("/v1/setup/reply-thread", own ? .init(json: Self.ownThreadJSON) : .init(json: #"{"thread":null,"reason":"preparing"}"#))
            let model = await subjectModel(world, dictation: dictation, writer: writer)
            await model.refreshReplySubject()
            let selected = model.replySubject
            dictation.latest = ("Answer how I would", Date())
            let writing = Task { await model.replyTick() }
            #expect(await eventually { writer.asked.count == 1 })
            #expect((writer.threads.first.flatMap { $0 } != nil) == own)
            world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
            await model.refreshReplySubject()
            writer.answer(.success("Thursday works."))
            await writing.value
            await model.refreshReplySubject()
            #expect(model.replySubject == selected)
            #expect(world.sent("/v1/setup/reply-thread") == 1)
        }
    }

    @Test func keyReplacementAndSignOutDropTheSubjectAndIgnoreEarlierAnswers() async throws {
        let world = World(), keys = MemoryDeviceKey("synthetic-device-key")
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
        let model = await subjectModel(world, keys: keys)
        await model.refreshReplySubject()
        try keys.save("replacement-key")
        model.retryKeyRead()
        #expect(model.replySubject == .looking)
        #expect(model.step == .mail)
        model.continueFromMail()
        #expect(model.step == .shortcut)
        model.continueFromShortcut()
        await model.refreshMail()
        model.continueFromDictation()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON, delay: 0.04))
        let pending = Task { await model.refreshReplySubject() }
        #expect(await eventually { world.sent("/v1/setup/reply-thread") == 2 })
        model.backendKeyRefused("replacement-key")
        await pending.value
        #expect(model.replySubject == .looking)
        #expect(model.step == .signIn)
    }

    @Test func anUnreadableKeyResolvesLookingWithoutSendingARequest() async {
        let world = World(), keys = MemoryDeviceKey("synthetic-device-key")
        let model = await subjectModel(world, keys: keys)
        keys.refusesReads = true
        await model.refreshReplySubject()
        #expect(model.replySubject == .example(.unavailable))
        #expect(world.sent("/v1/setup/reply-thread") == 0)
        #expect(model.isKeyUnreadable)
    }

    @Test func subjectRefusalSignsOutAndNoMailboxNeverAsks() async {
        let world = World()
        world.reply("/v1/setup/reply-thread", .init(status: 401))
        let model = await subjectModel(world)
        await model.refreshReplySubject()
        #expect(model.signInProblem == .signedOut)
        #expect(model.replySubject == .looking)
        let empty = World()
        let noMail = await subjectModel(empty)
        empty.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        await noMail.refreshMail()
        await noMail.refreshReplySubject()
        #expect(noMail.reply == .unavailable)
        #expect(noMail.replySubject == .example(.unavailable))
        #expect(empty.sent("/v1/setup/reply-thread") == 0)
    }

    /// A stand-in for the writer on the reply page: each ask waits until
    /// the test answers it.
    @MainActor private final class Writer {
        var isAvailable = true
        var unavailable: PracticeReply.Unavailable?
        var asked: [String] = []
        var threads: [AlphaClient.ReplyThread?] = []
        private var pending: [CheckedContinuation<Result<String, PracticeReply.Failure>, Never>] = []

        var port: PracticeReply {
            PracticeReply(isAvailable: { self.isAvailable }, unavailable: { self.unavailable }, write: { cue, thread, _ in
                self.asked.append(cue)
                self.threads.append(thread)
                return await withCheckedContinuation { self.pending.append($0) }
            })
        }

        func answer(_ result: Result<String, PracticeReply.Failure>, at index: Int = 0) {
            guard pending.indices.contains(index) else { return }
            pending.remove(at: index).resume(returning: result)
        }
    }

    /// A model on the reply page, with a mailbox connected unless told
    /// otherwise, the scripted dictation and the scripted writer.
    private func atReply(_ dictation: Dictation, _ writer: Writer, mailbox: Bool = true, provider: String = "gmail",
                         record: FirstRunRecord? = nil, screenRecordingDue: Bool = false,
                         loginItem: SetupLoginItem? = nil) async -> OnboardingModel {
        let world = World()
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        world.reply("/v1/mail/connections", .init(json: mailbox ? Self.connection(provider, stored: 3) : #"{"connections":[]}"#))
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
            dictation: dictation.port, practice: writer.port, loginItem: loginItem,
            screenRecordingDue: { screenRecordingDue }, record: record, defaults: defaults()
        )
        await model.refreshMail()
        model.continueFromMail()
        model.continueFromShortcut()
        model.continueFromDictation()
        #expect(model.step == .reply)
        return model
    }

    @Test func oldReplyInsertionKeepsOriginalDictationAfterNewWriteStarts() async throws {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer)
        let original = Date()
        dictation.latest = ("first cue", original)
        let first = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        writer.answer(.success("First answer"))
        await first.value
        let answer = try #require(model.replyWords)
        dictation.latest = ("second cue", original.addingTimeInterval(1))
        let second = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 2 })
        model.windowClosed()
        model.replyInserted(answer.text, at: answer.at)
        #expect(dictation.insertions.count == 1)
        #expect(dictation.insertions.first?.0 == "First answer")
        #expect(dictation.insertions.first?.1 == original)
        writer.answer(.success("Second answer"))
        await second.value
        // A callback for the earlier answer still names it after the next one arrives.
        model.replyInserted(answer.text, at: answer.at)
        #expect(dictation.insertions.last?.1 == original)
    }

    /// The practice email arrives after quitting began. The page's real
    /// field takes nothing then, so nothing goes in after the last save, and
    /// no new dictation goes to the writer. Refused, the quit gives the
    /// field the held email once, recorded against its own dictation.
    @Test func aPracticeEmailArrivingWhileQuittingWaitsUntilTheQuitIsRefused() async throws {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer)
        let field = FirstDictationField.FieldView(frame: CGRect(x: 0, y: 0, width: 388, height: 60))
        field.inserted = model.replyInserted
        let spoken = Date()
        dictation.latest = ("tell her 1 works", spoken)
        let tick = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        dictation.quitting = true
        writer.answer(.success("Hey Maya, 1 works for me."))
        await tick.value
        #expect(model.replyWords?.text == "Hey Maya, 1 works for me.")
        field.take(model.replyFieldWords)
        #expect(dictation.insertions.isEmpty)
        dictation.latest = ("actually say 12:30", spoken.addingTimeInterval(1))
        var tickEnded = false
        let quitTick = Task { await model.replyTick(); tickEnded = true }
        // The tick either returns without asking or asks and waits on the
        // writer. One that asked fails here, and its ask is answered so the
        // task ends instead of holding the suite.
        #expect(await eventually { tickEnded || writer.asked.count > 1 })
        let askedWhileQuitting = writer.asked.count > 1
        #expect(!askedWhileQuitting)
        if askedWhileQuitting { writer.answer(.failure(PracticeReply.Failure(name: "quit"))) }
        await quitTick.value
        dictation.quitting = false
        field.take(model.replyFieldWords)
        field.take(model.replyFieldWords)
        #expect(dictation.insertions.count == 1)
        #expect(dictation.insertions.first?.0 == "Hey Maya, 1 works for me.")
        #expect(dictation.insertions.first?.1 == spoken)
        let next = Task { await model.replyTick() }
        let askedAfterRefusal = await eventually { writer.asked == ["tell her 1 works", "actually say 12:30"] }
        #expect(askedAfterRefusal)
        if askedAfterRefusal { writer.answer(.success("Hi Maya, 12:30 works.")) }
        else { next.cancel() }
        await next.value
    }

    /// The first dictation's words come back while quitting: the field
    /// takes them only once the quit is refused.
    @Test func firstDictationWordsArrivingWhileQuittingWaitUntilTheQuitIsRefused() {
        let dictation = Dictation()
        let model = atLastPage(dictation)
        let field = FirstDictationField.FieldView(frame: CGRect(x: 0, y: 0, width: 388, height: 60))
        field.inserted = model.firstDictationInserted
        dictation.quitting = true
        let at = Date().addingTimeInterval(1)
        dictation.latest = ("Running late.", at)
        #expect(model.firstDictationWords?.text == "Running late.")
        field.take(model.firstDictationFieldWords)
        #expect(dictation.insertions.isEmpty)
        dictation.quitting = false
        field.take(model.firstDictationFieldWords)
        #expect(dictation.insertions.map(\.0) == ["Running late."])
        #expect(dictation.insertions.first?.1 == at)
    }

    @Test func wordsSpokenOnTheReplyPageGoToTheWriterAndTheEmailComesBack() async {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer)
        #expect(model.isPracticeAvailable)
        #expect(model.reply == .waiting)
        dictation.phase = .listening
        #expect(model.reply == .listening)
        dictation.phase = .finishing
        #expect(model.reply == .finishing)
        dictation.phase = .idle
        dictation.latest = ("yeah 1 works, see you there", Date())
        let tick = Task { await model.replyTick() }
        #expect(await eventually { writer.asked == ["yeah 1 works, see you there"] })
        #expect(model.reply == .writing)
        #expect(model.replySpoken == "yeah 1 works, see you there")
        writer.answer(.success("Hey Maya, 1 works for me. See you Thursday!"))
        await tick.value
        #expect(model.reply == .written)
        #expect(model.replyWords?.text == "Hey Maya, 1 works for me. See you Thursday!")
        #expect(model.replySpoken == nil)
        #expect(model.replySaid == "yeah 1 works, see you there")
        #expect(model.replyNotice == nil)
        // The same words are not sent twice.
        await model.replyTick()
        #expect(writer.asked.count == 1)
    }

    @Test func whenNoEmailComesTheWordsAreTypedWithTheNotice() async {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer)
        dictation.latest = ("tell her 1 works", Date())
        let tick = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        writer.answer(.failure(PracticeReply.Failure(name: "abstained.timeout")))
        await tick.value
        #expect(model.reply == .typed)
        #expect(model.replyWords?.text == "tell her 1 works")
        #expect(model.replyNotice == PracticeReply.typedNotice)
        #expect(model.replyFailure == "The writer took too long.")
        // A later try asks again.
        dictation.latest = ("tell her 1 works please", Date())
        let again = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 2 })
        #expect(model.replyNotice == nil)
        #expect(model.replyFailure == nil)
        writer.answer(.success("Hi Maya, 1 works."))
        await again.value
        #expect(model.reply == .written)
    }

    @Test func retryReplyUsesTheSameWordsAndThreadAndOnlyRunsAfterFailure() async {
        let world = World(), dictation = Dictation(), writer = Writer()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
        let model = await subjectModel(world, dictation: dictation, writer: writer)
        await model.refreshReplySubject()
        await model.retryReply()
        #expect(writer.asked.isEmpty)
        dictation.latest = ("answer how I would", Date())
        let first = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        let subject = model.replySubject
        writer.answer(.failure(.init(name: "abstained.mail_import_pending")))
        await first.value
        #expect(model.reply == .typed)
        let retry = Task { await model.retryReply() }
        #expect(await eventually { writer.asked.count == 2 })
        #expect(model.reply == .writing)
        #expect(model.replyFailure == nil)
        #expect(model.replyNotice == nil)
        #expect(writer.asked == ["answer how I would", "answer how I would"])
        #expect(writer.threads[0]?.id == "AAQkAD12+/=")
        #expect(writer.threads[1] == writer.threads[0])
        #expect(model.replySubject == subject)
        await model.retryReply()
        #expect(writer.asked.count == 2)
        writer.answer(.success("Thursday works."))
        await retry.value
        #expect(model.reply == .written)
        #expect(model.replyWords?.text == "Thursday works.")
        await model.retryReply()
        #expect(writer.asked.count == 2)
    }

    @Test func closingDuringRetryDropsItsAnswerAndKeepsTheOriginalFailure() async {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer)
        dictation.latest = ("answer how I would", Date())
        let first = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        writer.answer(.failure(.init(name: "timedOut")))
        await first.value
        let retry = Task { await model.retryReply() }
        #expect(await eventually { writer.asked.count == 2 })
        model.windowClosed()
        writer.answer(.success("A late reply"))
        await retry.value
        #expect(model.reply == .typed)
        #expect(model.replyFailureName == "timedOut")
        #expect(model.replyNotice == PracticeReply.typedNotice)
        #expect(model.replyWords?.text == "answer how I would")
    }

    @Test func exampleChoiceClearsTheFailedReplyAndStaysLockedUntilLeavingTheVisit() async {
        for failed in [false, true] {
            let world = World(), dictation = Dictation(), writer = Writer()
            world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
            let model = await subjectModel(world, dictation: dictation, writer: writer)
            await model.refreshReplySubject()
            if failed {
                dictation.latest = ("answer how I would", Date())
                let first = Task { await model.replyTick() }
                #expect(await eventually { writer.asked.count == 1 })
                model.useExampleReply()
                #expect(model.replySubject != .example(.unavailable))
                writer.answer(.failure(.init(name: "timedOut")))
                await first.value
                #expect(model.reply == .typed)
            }
            model.useExampleReply()
            #expect(model.reply == .waiting)
            #expect(model.replySubject == .example(.unavailable))
            #expect(model.replyWords == nil)
            #expect(model.replySpoken == nil)
            #expect(model.replySaid == nil)
            #expect(model.replyFailure == nil)
            #expect(model.replyNotice == nil)
            await model.replyTick()
            #expect(writer.asked.count == (failed ? 1 : 0))
            await model.refreshReplySubject()
            #expect(world.sent("/v1/setup/reply-thread") == 1)
            dictation.latest = ("tell her 1 works", Date())
            let example = Task { await model.replyTick() }
            #expect(await eventually { writer.asked.count == (failed ? 2 : 1) })
            #expect(writer.threads.last! == nil)
            writer.answer(.success("Hey Maya, 1 works."))
            await example.value
            #expect(model.replyWords?.text == "Hey Maya, 1 works.")
            #expect(model.replySubject == .example(.unavailable))
            model.connectMailForReply()
            model.continueFromMail()
            #expect(model.step == .reply)
            await model.refreshReplySubject()
            #expect(world.sent("/v1/setup/reply-thread") == 2)
            #expect(model.replySubject != .example(.unavailable))
        }
    }

    @Test func choosingTheExampleKeepsACarriedFirstDictationOffTheReply() async {
        let world = World(), dictation = Dictation(), writer = Writer()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
        let model = await subjectModel(world, dictation: dictation, writer: writer, step: "tryIt")
        await model.refreshReplySubject()
        dictation.phase = .finishing
        model.continueFromDictation()
        #expect(model.reply == .waiting)
        model.useExampleReply()
        #expect(model.replySubject == .example(.unavailable))
        dictation.latest = ("Words for the first page", Date())
        dictation.phase = .idle
        await model.replyTick()
        await model.replyTick()
        #expect(writer.asked.isEmpty)
        #expect(model.replyWords == nil)
        #expect(model.reply == .waiting)
    }

    @Test func lateAnswerFromAnEarlierVisitCannotClearOrReplaceTheRetry() async {
        let world = World(), dictation = Dictation(), writer = Writer()
        world.reply("/v1/setup/reply-thread", .init(json: Self.ownThreadJSON))
        let model = await subjectModel(world, dictation: dictation, writer: writer)
        await model.refreshReplySubject()
        var ended = 0
        model.replyEnded = { ended += 1 }
        dictation.latest = ("old words", Date())
        let old = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        model.connectMailForReply()
        #expect(model.step == .mail)
        model.continueFromMail()
        #expect(model.step == .reply)
        await model.refreshReplySubject()
        dictation.latest = ("current words", Date())
        let current = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 2 })
        writer.answer(.failure(.init(name: "timedOut")), at: 1)
        await current.value
        #expect(ended == 1)
        let retry = Task { await model.retryReply() }
        #expect(await eventually { writer.asked.count == 3 })
        #expect(writer.asked == ["old words", "current words", "current words"])
        #expect(writer.threads[2] == writer.threads[1])
        let failedWords = model.replyWords?.text
        writer.answer(.success("Old answer"))
        await old.value
        #expect(ended == 1)
        #expect(model.reply == .writing)
        #expect(model.replySpoken == "current words")
        #expect(model.replyWords?.text == failedWords)
        writer.answer(.success("Current answer"))
        await retry.value
        #expect(ended == 2)
        #expect(model.replyWords?.text == "Current answer")
    }

    /// A fresh account's mail is still being read when the practice email
    /// is asked for: the page says so, not only that it typed the words.
    @Test func eachReasonNoEmailCameIsSaidExactly() {
        // A reason this build doesn't know says nothing about mail.
        #expect(PracticeReply.reason(for: "abstained.unrecognized") == "The writer sent nothing back.")
        #expect(PracticeReply.typedLead(for: "abstained.unrecognized", key: "fn")
                == "The writer sent nothing back. Intention typed your words instead. Hold fn to try again, or continue.")
        #expect(PracticeReply.reason(for: "abstained.mail_import_pending") == "Still reading your email, try again in a few minutes")
        #expect(PracticeReply.typedLead(for: "abstained.mail_import_pending", key: "fn") == "Still reading your email, try again in a few minutes.")
        #expect(PracticeReply.reason(for: "abstained.context_preparing") == "Your mail is still being read. Try again in a few minutes.")
        #expect(PracticeReply.reason(for: "request.unreachable") == "Intention couldn't reach its server.")
        #expect(PracticeReply.reason(for: "unavailable.disabled") == "Email writing isn't on for your account yet.")
        #expect(PracticeReply.reason(for: "abstained.invalid_response") == "The writer sent nothing back.")
        #expect(PracticeReply.typedLead(for: "abstained.context_preparing", key: "fn")
            == "Your mail is still being read, so Intention typed your words instead. Try again in a few minutes, or continue.")
        #expect(PracticeReply.typedLead(for: "timedOut", key: "right option")
            == "The writer took too long. Intention typed your words instead. Hold right option to try again, or continue.")
    }

    /// Without a mailbox the page shows the example, says what is missing,
    /// offers to connect mail, and words said there are said to have gone
    /// nowhere rather than ignored.
    @Test func theExampleSaysWhyAndWordsSaidOnItAreNotIgnored() async {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer, mailbox: false)
        #expect(model.reply == .unavailable)
        #expect(model.replyUnavailableReason == "Connect your mail to try it here, and so it sounds like you.")
        #expect(model.replyNeedsMail)
        #expect(!model.replyHeardWithoutWriter)
        dictation.latest = ("yeah 1 works, see you there", Date())
        #expect(model.replyHeardWithoutWriter)
        await model.replyTick()
        #expect(writer.asked.isEmpty)
        model.connectMailForReply()
        #expect(model.step == .mail)
        // Writing off in Settings is said as that, with no offer to connect.
        let off = Writer()
        off.isAvailable = false
        off.unavailable = .writingOff
        let other = await atReply(Dictation(), off)
        #expect(other.reply == .unavailable)
        #expect(other.replyUnavailableReason == "Write emails for me is off in Intention's Settings.")
        #expect(!other.replyNeedsMail)
    }

    @Test func theFootHearsWhenThePracticeEmailStartsAndEnds() async {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer)
        var heard: [String] = []
        model.replyStarted = { heard.append("started") }
        model.replyEnded = { heard.append("ended") }
        dictation.latest = ("yeah 1 works, see you there", Date())
        let tick = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        #expect(heard == ["started"])
        writer.answer(.success("Hey Maya, 1 works for me. See you Thursday!"))
        await tick.value
        #expect(heard == ["started", "ended"])
    }

    @Test func wordsFromTheDictationPageAreNotTakenForAReply() async {
        let dictation = Dictation(), writer = Writer()
        dictation.latest = ("Running ten minutes late.", Date())
        let model = await atReply(dictation, writer)
        await model.replyTick()
        #expect(writer.asked.isEmpty)
        #expect(model.reply == .waiting)
    }

    @Test func withoutAMailboxTheReplyPageShowsTheExample() async {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer, mailbox: false)
        #expect(!model.isPracticeAvailable)
        #expect(model.reply == .unavailable)
        dictation.latest = ("yeah 1 works", Date())
        await model.replyTick()
        #expect(writer.asked.isEmpty)
        // So does a build whose writer is off, and one with no dictation.
        let withMail = await atReply(dictation, writer)
        writer.isAvailable = false
        #expect(withMail.reply == .unavailable)
        writer.isAvailable = true
        dictation.isAvailable = false
        #expect(withMail.reply == .unavailable)
    }

    @Test func anUnavailableMailboxCannotEnableThePracticeWriterOrVoiceRecap() async {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer, provider: "outlook")
        #expect(model.connections.count == 1)
        #expect(model.availableConnections.isEmpty)
        #expect(model.voice == .noMail)
        #expect(!model.isPracticeAvailable)
        #expect(model.reply == .unavailable)
        dictation.latest = ("say one works", Date())
        await model.replyTick()
        #expect(writer.asked.isEmpty)
    }

    @Test func anAnswerThatComesAfterThePageHasGoneIsDropped() async {
        let dictation = Dictation(), writer = Writer()
        let model = await atReply(dictation, writer)
        dictation.latest = ("yeah 1 works", Date())
        let tick = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        model.finish()
        #expect(model.isFinished)
        writer.answer(.success("Hey Maya, 1 works."))
        await tick.value
        #expect(model.replyWords == nil)
        #expect(model.replySpoken == nil)
    }

    @Test func theDotIsClickableOnlyOnThePracticePages() async {
        let dictation = Dictation(), writer = Writer()
        var toggles = 0
        let world = World()
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        var port = dictation.port
        port.toggle = { toggles += 1 }
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
            dictation: port, practice: writer.port, defaults: defaults()
        )
        #expect(model.step == .mail)
        #expect(!model.isPracticePage)
        model.toggleDictation()
        #expect(toggles == 0)
        model.continueFromMail()
        // Holding the keys on the shortcut page only shows they are heard:
        // no dictation, and no dot there to click.
        #expect(model.step == .shortcut)
        #expect(!model.isPracticePage)
        #expect(model.holdOnlyShows)
        model.toggleDictation()
        #expect(toggles == 0)
        model.continueFromShortcut()
        #expect(model.step == .tryIt)
        #expect(model.isPracticePage)
        #expect(!model.holdOnlyShows)
        model.toggleDictation()
        #expect(toggles == 1)
        model.continueFromDictation()
        #expect(model.isPracticePage)
        model.toggleDictation()
        #expect(toggles == 2)
        // Not while dictation cannot run.
        dictation.isAvailable = false
        model.toggleDictation()
        #expect(toggles == 2)
    }

    @Test func theLastPageSaysWhetherScreenRecordingComesNext() async {
        let dictation = Dictation(), writer = Writer()
        let asked = await atReply(dictation, writer, screenRecordingDue: true)
        #expect(asked.asksScreenRecordingNext)
        let notAsked = await atReply(dictation, writer, screenRecordingDue: false)
        #expect(!notAsked.asksScreenRecordingNext)
    }

    @Test func theWindowFloatsOnlyWhileTheBrowserHasTheConsent() async {
        let world = World()
        let model = atMail(world)
        #expect(!model.isAwaitingMail)
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        // The server never answers, so no browser session is ever made;
        // the page is awaiting the consent from the moment Connect is pressed.
        world.reply("/v1/mail/gmail/connect", .init(stalls: true))
        let consent = Task { await model.connect(.gmail) }
        #expect(await eventually { model.isAwaitingMail })
        model.windowClosed()
        await consent.value
        #expect(!model.isAwaitingMail)
    }

    // MARK: - First-run record

    @Test func eachFirstIsNotedOnceAsSetupGoes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("first-run-" + UUID().uuidString)
        let file = folder.appendingPathComponent("first-run.json")
        var now = Date(timeIntervalSince1970: 1_000_000)
        let record = FirstRunRecord.stored(at: file, now: { now })
        let world = World(), store = defaults()
        world.reply("/v1/invites/redeem", .init(status: 201, json: Self.registration))
        world.reply("/v1/mail/connections", .init(json: Self.connection(stored: 3)))
        let dictation = Dictation(), writer = Writer()
        AlphaStub.answer = { world.answer($0) }
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey(),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
            dictation: dictation.port, practice: writer.port, record: record,
            defaults: store, pollInterval: .milliseconds(10), settle: .milliseconds(5)
        )
        model.windowShown()
        now += 1
        model.enter(Self.code)
        #expect(await eventually { model.step == .mail })
        await model.refreshMail()
        model.continueFromMail()
        now += 1
        world.granted = [.microphone, .accessibility]
        model.refreshPermissions()
        #expect(await eventually { model.step == .shortcut })
        model.continueFromShortcut()
        now += 1
        dictation.latest = ("Running late.", Date())
        let watching = Task { await model.watchDictation() }
        #expect(await eventually { FirstRunRecord.read(file)[.firstSetupDictation] != nil })
        watching.cancel()
        now += 1
        model.continueFromDictation()
        now += 1
        dictation.latest = ("yeah 1 works", Date())
        let tick = Task { await model.replyTick() }
        #expect(await eventually { writer.asked.count == 1 })
        writer.answer(.success("Hey Maya."))
        await tick.value
        now += 1
        model.finish()
        // Opening the window again, or finishing again, adds nothing.
        model.windowShown()
        let marks = FirstRunRecord.read(file)
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(marks[.setupOpened] == start)
        #expect(marks[.signedIn] == start + 1)
        #expect(marks[.permissionsGranted] == start + 2)
        #expect(marks[.firstSetupDictation] == start + 3)
        #expect(marks[.mailboxConnected] == start + 1)
        #expect(marks[.firstSetupEmail] == start + 5)
        #expect(marks[.setupFinished] == start + 6)
        #expect(marks[.firstDictation] == nil)
        // A record read back keeps every mark.
        let later = FirstRunRecord.stored(at: file, now: { start + 99 })
        later.mark(.setupOpened)
        later.mark(.firstDictation)
        #expect(FirstRunRecord.read(file)[.setupOpened] == start)
        #expect(FirstRunRecord.read(file)[.firstDictation] == start + 99)
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Keychain

    @Test func aKeyTheKeychainWillNotGiveUpIsSaidAndCanBeReadAgain() async {
        let world = World(), store = defaults(), keys = MemoryDeviceKey("synthetic-device-key")
        store.set("done", forKey: "onboardingStep")
        keys.refusesReads = true
        let model = model(world, keys: keys, defaults: store)
        var changes: [Bool] = []
        model.accountChanged = { changes.append($0) }
        // Setup stays where it was, finished, with no account for dictation.
        #expect(model.isFinished)
        #expect(model.isKeyUnreadable)
        #expect(model.backendKey == nil)
        // Try Again while the keychain still refuses changes nothing.
        model.retryKeyRead()
        #expect(model.isKeyUnreadable)
        #expect(changes.isEmpty)
        // The person clicked Always Allow.
        keys.refusesReads = false
        model.retryKeyRead()
        #expect(!model.isKeyUnreadable)
        #expect(model.backendKey == "synthetic-device-key")
        #expect(changes == [true])
        #expect(model.isFinished)
    }


    @Test func aRelaunchOntoTheReplyPageReadsTheMailboxListFirst() async {
        let world = World(), store = defaults()
        world.granted = [.microphone, .accessibility]
        world.reply("/v1/mail/connections", .init(json: Self.connection(stored: 3)))
        store.set("reply", forKey: "onboardingStep")
        AlphaStub.answer = { world.answer($0) }
        let dictation = Dictation(), writer = Writer()
        let model = OnboardingModel(
            client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
            permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
            dictation: dictation.port, practice: writer.port, defaults: store, pollInterval: .milliseconds(10)
        )
        #expect(model.step == .reply)
        // Nothing has been read yet, so the page cannot know about the mailbox.
        #expect(!model.isPracticeAvailable)
        let watching = Task { await model.watchReply() }
        defer { watching.cancel() }
        #expect(await eventually { model.isPracticeAvailable })
        #expect(model.reply == .waiting)
    }

    @Test func aKeyReadAgainAfterAFailedLaunchReadResumesSetupAfterTheCode() {
        let world = World(), store = defaults(), keys = MemoryDeviceKey("synthetic-device-key")
        keys.refusesReads = true
        // Nothing saved beyond the code, as after an older build's example page.
        store.set("example", forKey: "onboardingStep")
        let model = model(world, keys: keys, defaults: store)
        #expect(model.step == .signIn)
        #expect(model.isKeyUnreadable)
        keys.refusesReads = false
        model.retryKeyRead()
        #expect(!model.isKeyUnreadable)
        #expect(model.step == .mail)
        // With both grants in, mail still comes first.
        let allowed = World(), second = MemoryDeviceKey("synthetic-device-key")
        allowed.granted = [.microphone, .accessibility]
        second.refusesReads = true
        let other = self.model(allowed, keys: second, defaults: defaults())
        #expect(other.step == .signIn)
        second.refusesReads = false
        other.retryKeyRead()
        #expect(other.step == .mail)
    }

}


extension OnboardingScenarioTests {
    @Test func permissionsReportDenialAndOneGrantWithoutPollingDuplicates() async {
        let world = World()
        let setup = model(world, keys: MemoryDeviceKey("synthetic-device-key"))
        var outcomes: [Bool] = []
        setup.permissionReported = { permission, granted in
            if permission == .microphone { outcomes.append(granted) }
        }
        await setup.request(.microphone)
        #expect(outcomes == [false])
        world.granted.insert(.microphone)
        setup.refreshPermissions()
        setup.refreshPermissions()
        #expect(outcomes == [false, true])
    }

    /// A signed-in model with both grants and the first dictation's port,
    /// whose key check reads `listener`.
    private func withKeyCheck(_ world: World, listener: FnListenerHealth) -> OnboardingModel {
        world.granted = [.accessibility, .microphone]
        AlphaStub.answer = { world.answer($0) }
        let model = OnboardingModel(client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
                                    permissions: SetupPermissions(isGranted: { world.granted.contains($0) }, request: { _ in }),
                                    mail: MailAuthentication(),
                                    dictation: FirstDictation(keyName: { "fn" }, phase: { .idle }, latest: { nil }, listener: listener),
                                    defaults: defaults(), pollInterval: .milliseconds(10))
        model.mailAnchor = NSWindow()
        return model
    }

    /// `--fn-reliability-snapshots` takes each still on the page it names:
    /// past mail and the shortcut, the dictation page in each key check
    /// state, then the reply page after the skip.
    @Test func theKeyCheckStillsAreTakenOnThePagesTheyShow() async throws {
        let world = World()
        world.reply("/v1/mail/connections", .init(json: OnboardingFixture.connections("ready")))
        world.reply("/v1/setup/reply-thread", .init(json: OnboardingFixture.demoThreadJSON))
        let listener = FnListenerHealth()
        let model = withKeyCheck(world, listener: listener)
        var stills: [String] = []
        var pages: [OnboardingModel.Step] = []
        var checks: [OnboardingModel.KeyCheck?] = []
        try await OnboardingFixture.keyCheckStills(model, listener: listener) { name in
            stills.append(name)
            pages.append(model.step)
            checks.append(model.firstKeyCheck)
        }
        #expect(stills == ["fn-waiting", "fn-works", "fn-failed", "fn-secure", "fn-skipped"])
        #expect(pages == [.tryIt, .tryIt, .tryIt, .tryIt, .reply])
        #expect(checks == [.waiting, .works, .problem(.failed), .problem(.blockedBySecureInput), .problem(.blockedBySecureInput)])
        #expect(model.keyCheckSkipped)
    }

    /// Setup that would not reach the key check, as when the stills went
    /// on from a mail page that had no mailbox, takes no still at all.
    @Test func theKeyCheckStillsRefuseAPageTheyDoNotShow() async {
        let world = World()
        world.reply("/v1/mail/connections", .init(json: #"{"connections":[]}"#))
        let listener = FnListenerHealth()
        let model = withKeyCheck(world, listener: listener)
        var stills: [String] = []
        await #expect(throws: OnboardingFixture.WrongPage.self) {
            try await OnboardingFixture.keyCheckStills(model, listener: listener) { stills.append($0) }
        }
        #expect(stills.isEmpty)
        #expect(model.step == .mail)
    }
}
