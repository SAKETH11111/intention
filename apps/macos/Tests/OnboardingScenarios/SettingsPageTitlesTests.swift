import AppKit
@testable import Onboarding
import Testing

@Suite
struct SettingsPageTitlesTests {
    private static let localizations = ["en", "en_GB", "es", "es_419", "hi", "ja", "no", "zh_HK"]
    private static var table: [String: Any] { [
        "en": ["SCREENANDAUDIOCAPTURE": "Screen & System Audio Recording", "SCREEN_CAPTURE": "Screen Recording"],
        "es": ["SCREENANDAUDIOCAPTURE": "Grabación de pantalla y del audio del sistema",
               "SCREEN_CAPTURE": "Grabación de pantalla"],
        "es_419": ["SCREENANDAUDIOCAPTURE": "Grabación de audio del sistema y pantalla",
                   "SCREEN_CAPTURE": "Grabación de pantalla"],
        "hi": ["SCREENANDAUDIOCAPTURE": "स्क्रीन और सिस्टम ऑडियो रिकॉर्डिंग", "SCREEN_CAPTURE": "स्क्रीन रिकॉर्डिंग"],
        "ja": ["SCREENANDAUDIOCAPTURE": "画面収録とシステムオーディオ録音", "SCREEN_CAPTURE": "画面収録"],
        "no": ["SCREENANDAUDIOCAPTURE": "Skjerm- og systemlydopptak", "SCREEN_CAPTURE": "Skjermopptak"],
        "zh_HK": ["SCREENANDAUDIOCAPTURE": "螢幕與系統錄音", "SCREEN_CAPTURE": "螢幕錄影"],
        "en_GB": ["SCREENANDAUDIOCAPTURE": "Screen & System Audio Recording", "SCREEN_CAPTURE": "Screen Recording"]
    ] }

    @Test func choosesSystemSettingsLanguage() {
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["es"]) == [
            "Grabación de pantalla y del audio del sistema", "Grabación de pantalla"
        ])
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["es-MX"]) == [
            "Grabación de audio del sistema y pantalla", "Grabación de pantalla"
        ])
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["hi"]) == [
            "स्क्रीन और सिस्टम ऑडियो रिकॉर्डिंग", "स्क्रीन रिकॉर्डिंग"
        ])
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["ja"]) == [
            "画面収録とシステムオーディオ録音", "画面収録"
        ])
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["en-US"]) == [
            "Screen & System Audio Recording", "Screen Recording"
        ])
    }

    @Test func unsupportedLanguageDoesNotUseEnglishFallback() {
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["zz"]) == [])
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: []) == [])
    }

    @Test func acceptsFoundationsSupportedLanguageAliases() {
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["nb-NO"]) == [
            "Skjerm- og systemlydopptak", "Skjermopptak"
        ])
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["yue-Hant"]) == [
            "螢幕與系統錄音", "螢幕錄影"
        ])
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["hi-Latn"]) == [
            "Screen & System Audio Recording", "Screen Recording"
        ])
    }

    @Test func readsSystemSettingsLanguagePreference() {
        var requestedDomains: [String] = []
        let languages = SettingsPageTitles.systemPreferredLanguages { domain in
            requestedDomains.append(domain)
            return ["ja"]
        }
        #expect(requestedDomains == ["com.apple.systempreferences"])
        #expect(languages == ["ja"])
    }

    @Test(.enabled(if: Bundle(path: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex")?
        .url(forResource: "Localizable", withExtension: "loctable") != nil))
    func readsRealSystemTableWhenAvailable() {
        #expect(SettingsPageTitles.load(preferredLanguages: ["en"]) == [
            "Screen & System Audio Recording", "Screen Recording"
        ])
    }

    @Test func anotherSupportedPreferenceMayBeUsed() {
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: Self.localizations,
                                                          preferredLanguages: ["zz", "ja"]) == [
            "画面収録とシステムオーディオ録音", "画面収録"
        ])
    }

    @Test func missingTableOrEitherKeyLeavesPageUnknown() {
        #expect(SettingsPageTitles.screenRecordingTitles(in: [:], localizations: Self.localizations,
                                                          preferredLanguages: ["ja"]) == [])
        #expect(SettingsPageTitles.screenRecordingTitles(in: ["ja": ["SCREEN_CAPTURE": "画面収録"]],
                                                          localizations: Self.localizations, preferredLanguages: ["ja"]) == [])
        #expect(SettingsPageTitles.screenRecordingTitles(in: ["ja": ["SCREENANDAUDIOCAPTURE": "画面収録とシステムオーディオ録音"]],
                                                          localizations: Self.localizations, preferredLanguages: ["ja"]) == [])
        #expect(SettingsPageTitles.screenRecordingTitles(in: ["ja": ["SCREENANDAUDIOCAPTURE": "", "SCREEN_CAPTURE": "画面収録"]],
                                                          localizations: Self.localizations, preferredLanguages: ["ja"]) == [])
    }

    @Test func missingLocalizationDoesNotUseATablesOtherLanguage() {
        #expect(SettingsPageTitles.screenRecordingTitles(in: Self.table, localizations: ["en"],
                                                          preferredLanguages: ["ja"]) == [])
    }
}
