import AppKit
import SwiftUI

// The entry point of the bundle scripts/mail-shots.sh builds: setup's mail
// page with no mailbox, and Settings' mail card with one Outlook mailbox,
// each through a never-ordered window at 1x and 2x. The setup model reads a
// backend answered in process with a device key kept in memory; no AppModel,
// controller, keychain or consent session exists. Settings' confirmation
// dialog is presented by the system outside the cached view, so it is not
// drawn here.
@main
struct MailShots: GuardedRender {
    static func render() throws {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--mail-snapshots"), arguments.indices.contains(index + 1) else { exit(2) }
        let output = URL(fileURLWithPath: arguments[index + 1])
        var failed: Bool?
        Task {
            do { try await draw(to: output); failed = false }
            catch { print(error); failed = true }
        }
        while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
        exit(failed == true ? 1 : 0)
    }

    private static let outlook = #"{"id":"33333333-3333-4333-8333-333333333333","provider":"outlook","address":"alex@example.com","state":"ready","stored_messages":4212,"blocked_messages":0,"backfill_done":true,"reconciling":false,"last_synced_at":null,"error_code":null,"connected_at":"2026-10-01T10:00:00Z","voice_ready":true,"voice_examples":4}"#

    private static func draw(to output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        SetupStyle.registerFonts()
        SetupMotion.isStill = true
        FirstDictationField.still = true
        Appearance.current = .light

        let empty = await model(connections: "")
        empty.reopenMail()
        try await save(OnboardingView(model: empty) { _ in }, "setup-mail-empty", size: OnboardingView.size, to: output)

        let connected = await model(connections: outlook)
        // The mail card's production width is 780 - 176 - (32 * 2).
        let card = SettingsCard { MailLines(model: MailShotsModel(connected)) }
            .frame(width: 540).padding(32).frame(width: 604, height: 300, alignment: .top)
            .background(Palette.day.ground)
        try await save(card, "settings-outlook", size: CGSize(width: 604, height: 300), to: output)
    }

    /// A finished setup signed in with a key held in memory, after one read
    /// of a mailbox list that offers both providers.
    private static func model(connections: String) async -> OnboardingModel {
        let json = #"{"connections":[\#(connections)],"available_providers":["gmail","outlook"]}"#
        AlphaStub.answer = { _ in .init(json: json) }
        let suite = "co.intention.mac.mail-shots." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("done", forKey: "onboardingStep")
        let model = OnboardingModel(client: AlphaStub.client(), keys: MemoryDeviceKey("synthetic-device-key"),
                                    permissions: SetupPermissions(isGranted: { _ in true }, request: { _ in }),
                                    mail: RefusedMailConnection(), fullName: "Alex Rivera", preferredLanguages: ["en-US"],
                                    defaults: defaults)
        await model.refreshMail()
        defaults.removePersistentDomain(forName: suite)
        return model
    }

    private static func save(_ view: some View, _ name: String, size: CGSize, to output: URL) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its first layout before drawing.
        try await Task.sleep(for: .milliseconds(500))
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent("\(name)@\(scale)x.png"))
        }
        precondition(!window.isVisible && !NSApp.isActive, "MailShots ordered a window or activated")
        window.contentView = nil
    }
}

/// What the mail lines call on AppModel. A render opens nothing, so each
/// action does nothing.
@MainActor
final class MailShotsModel {
    let onboarding: OnboardingModel
    init(_ onboarding: OnboardingModel) { self.onboarding = onboarding }
    func showSetup() {}
    func showMailSetup() {}
    func connectMail(_ provider: AlphaClient.MailProvider) {}
}

/// A render cannot start consent or an authentication session.
@MainActor
final class RefusedMailConnection: MailConnecting {
    func connect(provider: AlphaClient.MailProvider, client: AlphaClient, deviceKey: String,
                 anchor: NSWindow, isCurrent: @escaping @MainActor () -> Bool) async throws -> UUID {
        throw CancellationError()
    }
    func cancel() {}
}
