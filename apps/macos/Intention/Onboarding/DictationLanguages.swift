import Foundation

/// What setup needs from dictation to ask which languages the person
/// dictates in: the saved choice and a way to save a new one. Setup has
/// no question to ask without it.
struct DictationLanguages {
    /// Two-letter codes such as "en" and "es". Empty means English only.
    var current: @MainActor () -> [String]
    var save: @MainActor ([String]) -> Void
}

/// The rules of that question, shared by setup and Settings: which
/// languages are offered and in what order, how many can be picked, and
/// what is stored.
enum LanguageChoice {
    /// The endpoint takes at most this many.
    static let limit = 5

    /// The languages dictation has been measured in besides English, in the
    /// order of evaluations/speech. Others still work; these are the ones
    /// with numbers behind them.
    static let measured = ["es", "fr", "de", "pt", "it", "ru", "hi", "zh", "ja", "ar"]

    /// The two-letter ISO 639-1 code of a locale identifier, lowercased:
    /// "en-US" is "en", "zh-Hans-CN" is "zh" and "pt_BR" is "pt". A
    /// language with no two-letter code, such as Filipino ("fil"), has
    /// none here. The endpoint refuses a dictation whose languages are
    /// anything else, so nothing else is ever offered or saved.
    static func code(of identifier: String) -> String? {
        guard let code = Locale.Language(identifier: identifier).languageCode?.identifier.lowercased(),
              isCode(code) else { return nil }
        return code
    }

    static func isCode(_ code: String) -> Bool {
        code.count == 2 && code.allSatisfy { $0.isASCII && $0.isLowercase }
    }

    /// Every language offered: English, then the Mac's own preferred
    /// languages in its order, then the measured ones, then any already
    /// picked that is none of those, so it can still be taken away.
    static func offered(preferred identifiers: [String], chosen: [String] = []) -> [String] {
        var seen: Set<String> = []
        return (["en"] + identifiers.compactMap(code(of:)) + measured + chosen.filter(isCode))
            .filter { seen.insert($0).inserted }
    }

    /// The ones shown as buttons, the rest being under More: English, the
    /// Mac's own (three at most), and anything already picked.
    static func shown(preferred identifiers: [String], chosen: [String]) -> [String] {
        // Repeats go before the three are counted: a Mac that prefers two
        // kinds of Spanish still has two places left.
        var own: Set<String> = []
        let first = identifiers.compactMap(code(of:)).filter { $0 != "en" && own.insert($0).inserted }.prefix(3)
        var seen: Set<String> = []
        return (["en"] + first + chosen).filter { seen.insert($0).inserted }
    }

    /// The choice after one language is pressed. A sixth is not added, and
    /// the last one cannot be taken away: dictation needs a language.
    static func toggled(_ code: String, in chosen: [String]) -> [String] {
        if chosen.contains(code) {
            return chosen.count > 1 ? chosen.filter { $0 != code } : chosen
        }
        return chosen.count < limit ? chosen + [code] : chosen
    }

    /// What the person sees picked for a saved choice: nothing saved, or
    /// nothing usable, is English.
    static func chosen(from saved: [String]) -> [String] {
        let codes = self.saved(for: saved)
        return codes.isEmpty ? ["en"] : codes
    }

    /// What is saved for a choice: two-letter codes only, no repeats, five
    /// at most. English alone is saved as nothing, the default, which
    /// keeps those people on the fastest route.
    static func saved(for chosen: [String]) -> [String] {
        var seen: Set<String> = []
        let codes = Array(chosen.filter { isCode($0) && seen.insert($0).inserted }.prefix(limit))
        return codes == ["en"] ? [] : codes
    }

    /// A language's name in that language, as its speakers know it.
    static func name(_ code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
