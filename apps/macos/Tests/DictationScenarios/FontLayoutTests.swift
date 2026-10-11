import AppKit
import CoreText
@testable import Dictation
import SwiftUI
import Testing

/// Font registration is process-wide. Keep each measurement synchronous on
/// the main actor so another layout test cannot run inside the font's scope.
@MainActor
private func withBundledDMSans(_ measure: () throws -> Void) throws {
    let url = try #require(Bundle.module.url(forResource: "DM-Sans", withExtension: "ttf"))
    var error: Unmanaged<CFError>?
    let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    if !registered {
        let failure = try #require(error?.takeRetainedValue())
        // A host that already owns this font keeps its registration.
        try #require(CFErrorGetCode(failure) == CTFontManagerError.alreadyRegistered.rawValue)
    }
    defer {
        if registered {
            #expect(CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil))
        }
    }
    let font = try #require(NSFont(name: "DM Sans", size: 11.5))
    #expect(font.familyName == "DM Sans")
    try measure()
}

@MainActor
struct FontLayoutTests {
    @Test func theLongestDictationKeycapFitsTheNarrowestCard() throws {
        try withBundledDMSans {
            let name = "Control + Option + Shift + Command"
            // Measure the cap itself without an outer fixed-width frame,
            // which would conceal a child overflowing a 200 pt column.
            let cap = NSHostingView(rootView: ProposalCardView.KeyName(label: name)).fittingSize
            #expect(cap.width <= 200)
            #expect(cap.height > 0)
            for withWords in [false, true] {
                let row = NSHostingView(rootView: ProposalCardView.KeyRow(keyName: name, withWords: withWords)
                    .frame(width: 200)).fittingSize
                #expect(row.width == 200)
                #expect(row.height > 0)
            }
        }
    }

    @Test func theDictateSlipKeepsItsEdgesAndDotOnWholePixels() throws {
        try withBundledDMSans {
            let slip = FootSlip(text: "Dictate", key: "fn")
            #expect(slip.size.width.truncatingRemainder(dividingBy: 2) == 0)
            let frame = slip.frame(around: CGPoint(x: 180, y: 26), opening: .centre)
            let dot = FootSlip.dot(in: frame, opening: .centre)
            #expect(frame.midX == 180)
            // The resting mark including its hairline has a 16 pt diameter.
            for scale: CGFloat in [1, 2] {
                for edge in [frame.minX, frame.maxX, frame.minY, frame.maxY,
                             dot.x - 8, dot.x + 8, dot.y - 8, dot.y + 8] {
                    #expect((edge * scale).rounded() == edge * scale)
                }
            }
        }
    }
}
