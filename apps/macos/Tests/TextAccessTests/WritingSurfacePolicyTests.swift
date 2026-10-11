import Darwin
import Dispatch
@testable import Intention
import Testing

struct WritingSurfacePolicyTests {
    @Test func onlyTextControlsAreAdmittedAsTheFocusedField() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            #expect(WritingSurfacePolicy.allowsMetadata(role: role, subrole: nil, focused: true))
        }
        #expect(!WritingSurfacePolicy.allowsMetadata(role: "AXUnknown", subrole: nil, focused: true))
        #expect(!WritingSurfacePolicy.allowsMetadata(role: "AXButton", subrole: nil, focused: true))
    }

    @Test func everyChromeChannelIsAChromiumBrowserAndElectronAppsAreNot() {
        for id in ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
                   "org.chromium.Chromium", "com.microsoft.edgemac.Beta", "com.brave.Browser.nightly", "company.thebrowser.Browser"] {
            #expect(WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: id))
        }
        for id in ["com.t3tools.t3code", "com.openai.codex", "com.tinyspeck.slackmacgap", "com.apple.Safari", "com.google.drivefs"] {
            #expect(!WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: id))
        }
        #expect(!WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: nil))
    }

    /// The caret tracker and the inserter ask the policy on their own
    /// Accessibility thread, never the main one. Asked from a background
    /// queue here, as they ask it, the answers are the same, and nothing in
    /// it is isolated to the main actor, which would trap at runtime.
    @Test func thePolicyAnswersOnABackgroundQueueAsTheTrackerAsksIt() async {
        let answers = await withCheckedContinuation { (done: CheckedContinuation<[Bool], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: [
                    pthread_main_np() == 0,
                    WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: "com.google.Chrome.beta"),
                    !WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: "com.t3tools.t3code"),
                    WritingSurfacePolicy.secure(subrole: .absent, role: .text("AXTextArea"), focused: true) == false,
                    WritingSurfacePolicy.exposure(role: .text("AXGroup"), subrole: .text("AXSecureTextField")) == .secure,
                    WritingSurfacePolicy.allowsMetadata(role: "AXTextArea", subrole: nil, focused: true),
                    // The cover rule runs on the same thread, after each hit test.
                    CaretCover.covered(by: [.element(role: "AXMenuItem", subrole: nil), .joins(insideField: true)]),
                    !CaretCover.covered(by: [.element(role: "AXStaticText", subrole: nil), .field]),
                ])
            }
        }
        #expect(answers == [true, true, true, true, true, true, true, true])
    }

    /// Code editors are in scope, as they are for other dictation apps: an
    /// editor's text area, or one inside a source-code group, is a field
    /// like any other.
    @Test func codeEditorsAreAdmittedAndSecureMetadataIsRefusedAnywhere() {
        for subrole in ["AXSourceCode", "AXCodeEditor"] {
            #expect(WritingSurfacePolicy.allowsMetadata(role: "AXTextArea", subrole: subrole, focused: true))
            #expect(WritingSurfacePolicy.allowsMetadata(role: "AXGroup", subrole: subrole, focused: false))
        }
        #expect(WritingSurfacePolicy.allowsMetadata(role: "AXSourceCodeEditor", subrole: nil, focused: false))
        #expect(!WritingSurfacePolicy.allowsMetadata(role: "AXTextArea", subrole: "AXSecureTextField", focused: true))
        #expect(!WritingSurfacePolicy.allowsMetadata(role: "AXGroup", subrole: "AXSecureTextField", focused: false))
        #expect(WritingSurfacePolicy.allowsMetadata(role: "AXWindow", subrole: "AXStandardWindow", focused: false))
    }

    /// The rule `AXWritingSurface.secureAncestry` applies to each element
    /// from the field up to its window.
    @Test func anElementIsSecureBySubroleOrRoleAndUnknownWhenEitherGoesUnanswered() {
        typealias A = WritingSurfacePolicy.Answer
        let secure = A.text("AXSecureTextField")
        for focused in [true, false] {
            #expect(WritingSurfacePolicy.secure(subrole: secure, role: .text("AXTextField"), focused: focused) == true)
            #expect(WritingSurfacePolicy.secure(subrole: .absent, role: secure, focused: focused) == true)
            // A secure answer wins over another that did not come back.
            #expect(WritingSurfacePolicy.secure(subrole: .unanswered, role: secure, focused: focused) == true)
            #expect(WritingSurfacePolicy.secure(subrole: .absent, role: .text("AXGroup"), focused: focused) == false)
            // A wrapper whose role goes unanswered might be a secure one.
            #expect(WritingSurfacePolicy.secure(subrole: .absent, role: .unanswered, focused: focused) == nil)
            #expect(WritingSurfacePolicy.secure(subrole: .unanswered, role: .text("AXGroup"), focused: focused) == nil)
            #expect(WritingSurfacePolicy.secure(subrole: .unexpected, role: .text("AXGroup"), focused: focused) == nil)
            #expect(WritingSurfacePolicy.secure(subrole: .absent, role: .unexpected, focused: focused) == nil)
        }
        // A toolbar group's generic failure is no answer on an ancestor,
        // never on the field itself.
        #expect(WritingSurfacePolicy.secure(subrole: .genericFailure, role: .genericFailure, focused: false) == false)
        #expect(WritingSurfacePolicy.secure(subrole: .genericFailure, role: .text("AXTextArea"), focused: true) == nil)
        #expect(WritingSurfacePolicy.secure(subrole: .absent, role: .genericFailure, focused: true) == nil)
    }

    /// What each element of a window says about it, for the scan before an
    /// unread paste: nothing, text, or a field that is secure or might be.
    /// A secure role or subrole, or an answer that did not come back, is
    /// the last: the person's cursor could be in a password field.
    @Test func eachElementOfAWindowIsNothingTextOrPossiblySecure() {
        typealias A = WritingSurfacePolicy.Answer
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXWebArea"] {
            #expect(WritingSurfacePolicy.exposure(role: .text(role), subrole: .absent) == .text)
        }
        #expect(WritingSurfacePolicy.exposure(role: .text("AXSecureTextField"), subrole: .absent) == .secure)
        #expect(WritingSurfacePolicy.exposure(role: .text("AXTextField"), subrole: .text("AXSecureTextField")) == .secure)
        // A group a toolkit marks secure only by its subrole.
        #expect(WritingSurfacePolicy.exposure(role: .text("AXGroup"), subrole: .text("AXSecureTextField")) == .secure)
        #expect(WritingSurfacePolicy.exposure(role: .text("AXGroup"), subrole: .absent) == .nothing)
        #expect(WritingSurfacePolicy.exposure(role: .text("AXButton"), subrole: .genericFailure) == .nothing)
        for unanswered in [A.unanswered, .unexpected, .genericFailure, .absent] {
            #expect(WritingSurfacePolicy.exposure(role: unanswered, subrole: .absent) == .secure)
        }
        for unanswered in [A.unanswered, .unexpected] {
            #expect(WritingSurfacePolicy.exposure(role: .text("AXGroup"), subrole: unanswered) == .secure)
            #expect(WritingSurfacePolicy.exposure(role: .text("AXTextField"), subrole: unanswered) == .secure)
        }
    }

    @Test func aFocusedWebAreaIsAdmittedOnlyAsAnEditableDocument() {
        #expect(!WritingSurfacePolicy.allowsMetadata(role: "AXWebArea", subrole: nil, focused: true))
        #expect(WritingSurfacePolicy.allowsMetadata(role: "AXWebArea", subrole: nil, focused: true, editableDocument: true))
        #expect(!WritingSurfacePolicy.allowsMetadata(role: "AXGroup", subrole: nil, focused: true, editableDocument: true))
        #expect(!WritingSurfacePolicy.allowsMetadata(role: "AXWebArea", subrole: "AXSecureTextField", focused: true, editableDocument: true))
    }

    @Test func onlyTerminalsTextAreaTypesWithoutSettableText() {
        #expect(WritingSurfacePolicy.admitsTypingWithoutSettableText(bundleIdentifier: "com.apple.Terminal", role: "AXTextArea"))
        #expect(!WritingSurfacePolicy.admitsTypingWithoutSettableText(bundleIdentifier: "com.apple.Terminal", role: "AXTextField"))
        #expect(!WritingSurfacePolicy.admitsTypingWithoutSettableText(bundleIdentifier: "com.apple.TextEdit", role: "AXTextArea"))
        #expect(!WritingSurfacePolicy.admitsTypingWithoutSettableText(bundleIdentifier: nil, role: "AXTextArea"))
    }
}
