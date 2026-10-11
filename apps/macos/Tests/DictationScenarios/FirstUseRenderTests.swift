import AppKit
import SwiftUI
import Testing
@testable import Dictation

/// Optional off-screen evidence, using only the production views and synthetic text.
@MainActor
struct FirstUseRenderTests {
    @Test func renderFirstUseStatesWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["INTENTION_FIRST_USE_SHOTS"] else { return }
        // The script links the guard at process startup, so dyld also
        // intercepts registration and custom allocation in this executable.
        // Looking in the process never loads a missing guard as a fallback.
        let handle = try #require(dlopen(nil, RTLD_NOW))
        defer { _ = handle } // Keep the guard loaded for the process lifetime.
        let symbol = try #require(dlsym(handle, "IntentionRenderGuardRequire"))
        unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        SetupStyle.registerFonts()
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = DictationHistory(file: nil)
        let date = Date(timeIntervalSince1970: 1_791_655_200)
        history.add(.init(id: UUID(), date: date, text: "Hi Priya,\n\nThursday at 10 works for me.\n\nSam", outcome: .uncertain, reason: "readbackMismatch", spoken: "Say Thursday works"))
        let row = try #require(history.sections(matching: "", now: date, calendar: .current).first?.rows.first)
        for look in Appearance.allCases {
            try await save(HistoryRowView(row: row, isHovered: false, isUnfolded: true, retryEnabled: true,
                                          act: { _ in }, hover: { _ in }, toggleFold: {})
                .frame(width: 680).padding(24).background(look == .light ? Color.white : Color.black).appearance(look), name: "uncertain-\(look.rawValue)", in: directory)
            try await save(PopupView(content: .words(why: InsertionPopup.words(for: .noTextField), text: "Thursday at 10 works for me.", cut: false, copy: { true }),
                                     opensFrom: .bottom, reduceMotion: true, close: {}, appearance: look),
                           name: "no-field-\(look.rawValue)", in: directory)
            let empty = DictationController.EmptyResult(silence: .neverStarted, device: "MacBook Pro Microphone", retry: nil, actionable: true)
            try await save(PopupView(content: .nothing(line: FootState.words(for: empty), retry: nil, switchMicrophone: {}),
                                     opensFrom: .bottom, reduceMotion: true, close: {}, appearance: look),
                           name: "no-audio-\(look.rawValue)", in: directory)
            for (name, words) in [
                ("uncertain-notice", DictationController.Notice.insertionUncertain.text),
                ("restart-notice", "Microphone didn't start. Restarting…"),
                ("no-audio-notice", FootState.words(for: empty)),
            ] {
                try await save(NoticeCapsule(words: words, appearance: look).padding(NoticeCapsule.shadowRoom),
                               name: "\(name)-\(look.rawValue)", in: directory)
            }
        }
        #expect(!NSApp.isActive)
    }

    private func save(_ view: some View, name: String, in directory: URL) async throws {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let bounds = host.bounds
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
            pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        host.cacheDisplay(in: bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        #expect(!window.isVisible)
        #expect(!NSApp.isActive)
    }
}
