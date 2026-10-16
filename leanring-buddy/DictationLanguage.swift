//
//  DictationLanguage.swift
//  leanring-buddy
//
//  Which language dictation listens for. Shipped Clicky has the same
//  setting (DictationLanguage, DictationLanguageCatalog): auto-detect is on
//  by default and follows you across languages mid-sentence; pinning one
//  language gives the most accurate results when you only speak that one.
//
//  The pick goes to the Worker's /dictate route as the language's English
//  name, which Gemini reads in its prompt.
//

import Foundation

struct DictationLanguage: Identifiable, Hashable {
    /// ISO 639 code, like "en" or "pt".
    let code: String

    var id: String { code }

    /// In the user's own language, for Settings ("Deutsch" → "German" for
    /// an English speaker).
    var displayName: String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: Locale.current) ?? code
    }

    /// In English, for the prompt.
    var englishName: String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

enum DictationLanguageCatalog {
    static let autoDetectDefaultsKey = "clickyDictationAutoDetect"
    static let languageCodeDefaultsKey = "clickyDictationLanguage"

    /// Languages Gemini transcribes well, sorted by name when shown.
    static let languages: [DictationLanguage] = [
        "ar", "bn", "bg", "ca", "zh", "hr", "cs", "da", "nl", "en", "et", "fil", "fi", "fr",
        "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "ko", "lv", "lt", "ms",
        "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl", "es", "sw",
        "sv", "ta", "te", "th", "tr", "uk", "ur", "vi"
    ]
    .map(DictationLanguage.init(code:))
    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    /// On unless the user pinned a language in Settings.
    static var isAutoDetectEnabled: Bool {
        UserDefaults.standard.object(forKey: autoDetectDefaultsKey) as? Bool ?? true
    }

    /// The Mac's own language when it's in the list, else English.
    static var defaultLanguageCode: String {
        let systemLanguageCode = Locale.current.language.languageCode?.identifier ?? "en"
        return languages.contains { $0.code == systemLanguageCode } ? systemLanguageCode : "en"
    }

    /// The pinned language, or nil while auto-detect is on.
    static var pinnedLanguage: DictationLanguage? {
        guard !isAutoDetectEnabled else { return nil }
        let savedLanguageCode = UserDefaults.standard.string(forKey: languageCodeDefaultsKey) ?? defaultLanguageCode
        return languages.first { $0.code == savedLanguageCode } ?? DictationLanguage(code: defaultLanguageCode)
    }
}
