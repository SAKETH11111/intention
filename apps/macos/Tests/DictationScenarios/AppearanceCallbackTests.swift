import AppKit
@testable import Dictation
import SwiftUI
import Testing

/// The appearance callbacks and their notification delivery run without
/// putting a window on screen or changing the app's shared preference.
@MainActor
@Suite(.serialized)
struct AppearanceCallbackTests {
    static func offMain(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                body()
                done.resume()
            }
        }
    }

    static func postOffMain() async {
        await offMain { NotificationCenter.default.post(name: .intentionAppearanceChanged, object: nil) }
    }

    static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aShownCaptionChangesAppearanceInPlaceAndStaysHiddenAfterItEnds() async throws {
        let caption = DotCaption()
        caption.showsWindow = false
        var look = Appearance.light
        caption.appearance = { MainActor.assertIsolated(); return look }
        let dot = DotPlacement.Dot(center: CGPoint(x: 400, y: 500), diameter: 12)
        caption.show("Synthetic caption", beside: dot, on: CGRect(x: 0, y: 80, width: 1440, height: 795))
        let host = try #require(caption.window.contentView as? NSHostingView<DotCaptionView>)
        let frame = caption.window.frame
        look = .dark
        await Self.offMain { caption.appearanceChanged() }
        #expect(await Self.eventually { host.rootView.appearance == .dark })
        #expect(caption.window.appearance?.name == .darkAqua)
        #expect(host.rootView.text == "Synthetic caption")
        #expect(caption.window.contentView === host)
        #expect(caption.window.frame == frame)
        look = .light
        await Self.postOffMain()
        #expect(host.rootView.appearance == .light)
        caption.hide()
        look = .dark
        await Self.postOffMain()
        #expect(host.rootView.appearance == .light)
        #expect(!caption.window.isVisible)
    }

    @Test func aShownNoticeChangesAppearanceWithoutRestartingItsWait() async throws {
        for atFoot in [false, true] {
            let notice = DotNotice()
            notice.showsWindow = false
            var look = Appearance.light
            var reads = 0
            notice.appearance = { MainActor.assertIsolated(); reads += 1; return look }
            var ended = 0
            notice.ended = { ended += 1 }
            notice.show(.notice("Synthetic notice"), beside: atFoot ? nil : CGRect(x: 400, y: 500, width: 20, height: 20),
                        for: .milliseconds(400))
            let host = try #require(notice.window.contentView)
            let frame = notice.window.frame
            try await Task.sleep(for: .milliseconds(250))
            notice.window.alphaValue = 0.45
            let before = reads
            look = .dark
            await Self.offMain { notice.appearanceChanged() }
            #expect(await Self.eventually { reads > before })
            #expect(notice.window.appearance?.name == .darkAqua)
            #expect(notice.window.contentView === host)
            #expect(notice.window.frame == frame)
            #expect(notice.window.alphaValue == 0.45)
            #expect(notice.current == "Synthetic notice")
            #expect(ended == 0)
            look = .light
            await Self.postOffMain()
            #expect(notice.window.appearance?.name == .aqua)
            try await Task.sleep(for: .milliseconds(200))
            #expect(!notice.isShown)
            #expect(ended == 1)
            await Self.postOffMain()
            #expect(notice.window.contentView == nil)
        }
    }
}
