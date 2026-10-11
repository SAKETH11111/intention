import Foundation

/// The Screen Recording page titles from System Settings' privacy extension.
/// An empty set leaves the page unrecognized, so the guide draws nothing.
enum SettingsPageTitles {
    private static let extensionPath = "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex"

    /// Read at the start of each guide visit, outside its repeated Accessibility reads.
    static func load(preferredLanguages: [String]? = nil) -> Set<String> {
        guard let bundle = Bundle(path: extensionPath),
              let url = bundle.url(forResource: "Localizable", withExtension: "loctable"),
              let data = try? Data(contentsOf: url),
              let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let languages = preferredLanguages ?? systemPreferredLanguages() else { return [] }
        return screenRecordingTitles(in: table, localizations: bundle.localizations, preferredLanguages: languages)
    }

    static func systemPreferredLanguages(
        read: (String) -> [String]? = {
            CFPreferencesCopyAppValue("AppleLanguages" as CFString, $0 as CFString) as? [String]
        }
    ) -> [String]? {
        read("com.apple.systempreferences")
    }

    /// Select as System Settings does from its own localizations, not from
    /// Intention's bundle. Foundation may return its default localization when
    /// no preference matches; reject that fallback unless a preference has
    /// the same language code. Other choices include supported aliases such
    /// as Norwegian `nb` selecting the table's `no`.
    static func screenRecordingTitles(in table: [String: Any], localizations: [String],
                                      preferredLanguages: [String]) -> Set<String> {
        guard let language = Bundle.preferredLocalizations(from: localizations, forPreferences: preferredLanguages).first,
              localizations.contains(language),
              let fallback = Bundle.preferredLocalizations(from: localizations, forPreferences: []).first,
              let code = Locale.Language(identifier: language).languageCode?.identifier,
              language != fallback || preferredLanguages.contains(where: { preference in
                  Locale.Language(identifier: preference).languageCode?.identifier == code
              }),
              let strings = table[language] as? [String: Any],
              let audio = strings["SCREENANDAUDIOCAPTURE"] as? String, !audio.isEmpty,
              let screen = strings["SCREEN_CAPTURE"] as? String, !screen.isEmpty else { return [] }
        return [audio, screen]
    }
}
