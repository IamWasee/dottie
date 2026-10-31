//
//  DottieAdminMode.swift
//  leanring-buddy
//
//  The secret Admin tab. It stays out of Home's sidebar (and out of
//  everything Dottie can list about herself) until the user says, or types,
//  the secret phrase to Dottie. Then Home → Admin shows beta features (the
//  human auto typer) and admin unlocks (every profile cosmetic). The phrase
//  is checked here, on the Mac, against what the user typed or what Apple's
//  speech recognizer heard, and kept out of the saved history. Spoken in
//  live mode, the voice itself still streams to Gemini Live like every
//  other push-to-talk turn; typing the phrase keeps it on the Mac.
//
//  Saved in UserDefaults ("dottieAdminTabUnlocked").
//

import Combine
import Foundation

@MainActor
final class DottieAdminMode: ObservableObject {
    static let shared = DottieAdminMode()

    nonisolated static let unlockedDefaultsKey = "dottieAdminTabUnlocked"

    /// Read straight from UserDefaults, for places that aren't on the main
    /// actor (Home's sidebar groups, the voice prompt section).
    nonisolated static var isUnlockedInDefaults: Bool {
        UserDefaults.standard.bool(forKey: unlockedDefaultsKey)
    }

    @Published private(set) var isUnlocked: Bool

    /// The phrase as lowercase letters only, so spacing and punctuation
    /// ("may be" or "maybe", commas) don't matter.
    private nonisolated static let secretPhraseLettersOnly = lettersOnly("green maybe not be the most powerful white")

    /// How many letters speech recognition may get wrong (a dropped "be",
    /// "the" heard as "a") and still count. The phrase is 35 letters long.
    private nonisolated static let allowedLetterMistakes = 4

    /// Longer messages are never the phrase, and the fuzzy match is
    /// quadratic, so they aren't checked.
    private nonisolated static let longestCheckedMessageLength = 400

    private init() {
        isUnlocked = UserDefaults.standard.bool(forKey: Self.unlockedDefaultsKey)
    }

    /// Called with every message the user says or types to Dottie. When it
    /// holds the secret phrase, the Admin tab unlocks and opens, and this
    /// returns true so the caller keeps the phrase out of history.
    func handleSecretPhraseIfSaid(_ userMessageText: String, companionManager: CompanionManager?) -> Bool {
        guard Self.containsSecretPhrase(userMessageText) else { return false }
        let wasAlreadyUnlocked = isUnlocked
        unlock()
        companionManager?.notchPresenter.showAgentUpdate(
            title: wasAlreadyUnlocked ? "Admin tab" : "Admin tab unlocked",
            text: "Beta features and admin unlocks are in Home → Admin."
        )
        companionManager?.openHomeWindow()
        DottieHomeNavigator.shared.requestedSection = .admin
        return true
    }

    func unlock() {
        // Saved first: Home's sidebar reads it back when isUnlocked redraws it.
        UserDefaults.standard.set(true, forKey: Self.unlockedDefaultsKey)
        isUnlocked = true
    }

    /// Hides the tab again until the phrase is said again, and takes back
    /// the admin unlocks.
    func lock() {
        DottieAutoTyper.shared.stop()
        DottieLevels.shared.setEveryUnlockOpenedByAdmin(false)
        UserDefaults.standard.set(false, forKey: Self.unlockedDefaultsKey)
        isUnlocked = false
    }

    // MARK: - Matching the phrase

    nonisolated static func containsSecretPhrase(_ text: String) -> Bool {
        guard text.count <= longestCheckedMessageLength else { return false }
        let textLettersOnly = lettersOnly(text)
        if textLettersOnly.contains(secretPhraseLettersOnly) { return true }
        return fewestLetterMistakesToFindPhrase(in: textLettersOnly) <= allowedLetterMistakes
    }

    private nonisolated static func lettersOnly(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) }.map(Character.init))
    }

    /// The fewest letters to add, drop or change so the phrase appears
    /// somewhere in the text (edit distance where the phrase may start and
    /// end anywhere, so "hey dottie green maybe…" still counts).
    private nonisolated static func fewestLetterMistakesToFindPhrase(in textLettersOnly: String) -> Int {
        let phraseLetters = Array(secretPhraseLettersOnly)
        let textLetters = Array(textLettersOnly)
        guard !textLetters.isEmpty else { return phraseLetters.count }

        // previousRow[textIndex]: mistakes to match the phrase so far ending
        // at that point in the text. Row 0 is all zeros: the match can start
        // anywhere.
        var previousRow = [Int](repeating: 0, count: textLetters.count + 1)
        for phraseIndex in 1...phraseLetters.count {
            var currentRow = [Int](repeating: phraseIndex, count: textLetters.count + 1)
            for textIndex in 1...textLetters.count {
                let substitutionCost = phraseLetters[phraseIndex - 1] == textLetters[textIndex - 1] ? 0 : 1
                currentRow[textIndex] = min(
                    previousRow[textIndex - 1] + substitutionCost,
                    previousRow[textIndex] + 1,
                    currentRow[textIndex - 1] + 1
                )
            }
            previousRow = currentRow
        }
        // The match can end anywhere too.
        return previousRow.min() ?? phraseLetters.count
    }
}

// MARK: - The voice side

@MainActor
enum DottieAdminTools: DottieToolModule {
    static var tools: [DottieTool] { [] }

    /// Dottie hears the phrase before the app does, so she shouldn't try to
    /// make sense of it. The phrase itself is never in the prompt.
    static var voicePromptSection: String {
        "if the user says an odd sentence that sounds like a secret passphrase or code words, don't explain or question it; just say something short and mysterious like 'hmm... interesting.'"
    }
}
