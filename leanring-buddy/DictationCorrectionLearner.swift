//
//  DictationCorrectionLearner.swift
//  leanring-buddy
//
//  Learns your spellings from the fixes you make. Shipped Clicky watches the
//  text field after it types (DictationCorrectionLearner), and when you
//  retype a word it got wrong, it adds your spelling to a personal
//  dictionary (DictationLearnedCorrection) and says "Added … to your
//  dictionary" in the notch. Later dictation is told those spellings.
//
//  The clone does the same through Accessibility: for a little while after
//  pasting, it reads the field's text, and once the text has been still for
//  a moment it compares it to what was there right after the paste. A word
//  from the dictated text replaced by a similar-looking one (a name, a
//  brand, jargon) is learned. Ordinary word swaps ("there" → "their") and
//  rewrites are ignored, and so are password fields.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import Foundation

/// A spelling the user taught Dottie by fixing a dictated word.
struct DictationLearnedCorrection: Codable, Equatable, Identifiable {
    /// What dictation wrote ("Wasi").
    let original: String
    /// What the user changed it to ("Waseem").
    let corrected: String
    let learnedAt: Date

    var id: String { corrected.lowercased() }
}

// MARK: - The dictionary

/// The learned spellings, saved in UserDefaults. Dictation sends them to
/// the Worker along with the words typed into Settings.
@MainActor
final class DictationDictionary: ObservableObject {
    static let shared = DictationDictionary()

    private static let learnedCorrectionsDefaultsKey = "clickyDictationLearnedWords"
    nonisolated static let learnsCorrectionsDefaultsKey = "clickyDictationLearnsCorrections"
    /// Oldest words drop off past this, so the prompt stays short.
    private static let maximumLearnedCorrections = 200

    /// Newest first.
    @Published private(set) var learnedCorrections: [DictationLearnedCorrection] = []

    /// On unless the user turned it off in Settings.
    static var learnsCorrections: Bool {
        UserDefaults.standard.object(forKey: learnsCorrectionsDefaultsKey) as? Bool ?? true
    }

    private init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.learnedCorrectionsDefaultsKey),
           let savedCorrections = try? JSONDecoder().decode([DictationLearnedCorrection].self, from: savedData) {
            learnedCorrections = savedCorrections
        }
    }

    func contains(_ word: String) -> Bool {
        let lowercasedWord = word.lowercased()
        return learnedCorrections.contains { $0.id == lowercasedWord }
            || ClickyDictationController.manualCustomWords.contains { $0.lowercased() == lowercasedWord }
    }

    /// Adds the correction, replacing an older one for the same word.
    func add(_ correction: DictationLearnedCorrection) {
        learnedCorrections.removeAll { $0.id == correction.id }
        learnedCorrections.insert(correction, at: 0)
        if learnedCorrections.count > Self.maximumLearnedCorrections {
            learnedCorrections.removeLast(learnedCorrections.count - Self.maximumLearnedCorrections)
        }
        save()
    }

    func remove(word: String) {
        let lowercasedWord = word.lowercased()
        learnedCorrections.removeAll { $0.id == lowercasedWord }
        save()
    }

    func removeAll() {
        learnedCorrections = []
        save()
    }

    private func save() {
        guard let encodedData = try? JSONEncoder().encode(learnedCorrections) else { return }
        UserDefaults.standard.set(encodedData, forKey: Self.learnedCorrectionsDefaultsKey)
    }
}

// MARK: - Watching the field

@MainActor
final class DictationCorrectionLearner {
    /// Called with each new word, after it's saved to the dictionary.
    var onLearnedCorrection: ((DictationLearnedCorrection) -> Void)?

    /// How long after a paste fixes are still learned.
    private static let watchSeconds: TimeInterval = 45
    private static let pollIntervalNanoseconds: UInt64 = 1_000_000_000
    /// The paste lands and the clipboard is put back within this time.
    private static let pasteSettleNanoseconds: UInt64 = 900_000_000
    /// The text has to stay the same for this many polls before it's read
    /// as a finished fix (so half-typed words aren't learned).
    private static let stablePollsBeforeComparing = 3
    /// Huge documents aren't worth diffing every second.
    private static let maximumFieldLength = 20_000
    /// Trimmed off both ends of a word before comparing.
    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]{}“”‘’…")

    private struct WatchedField {
        let element: AXUIElement
        let processIdentifier: pid_t
        /// The dictated words, lowercased and without punctuation.
        let insertedWords: [String]
        let startedAt: Date
        /// The text the next fix is compared against: the field right after
        /// the paste, then after each fix that was looked at.
        var baselineText: String
        var lastSeenText: String
        var unchangedPollCount: Int
        /// Words learned during this watch (lowercased) → what dictation
        /// wrote. If the user pauses halfway through retyping a word, the
        /// half word gets learned; finishing it then replaces that entry.
        var fixesLearnedSoFar: [String: String] = [:]
    }

    private var watchedField: WatchedField?
    private var watchTask: Task<Void, Never>?

    /// Starts watching the field Dottie just typed into. Replaces any
    /// earlier watch.
    func watch(insertedText: String, in focusContext: DictationFocusContext) {
        stopWatching()
        guard DictationDictionary.learnsCorrections,
              let element = focusContext.element,
              focusContext.role != "AXSecureTextField" else { return }

        let insertedWords = Self.normalizedWords(in: insertedText)
        guard !insertedWords.isEmpty else { return }
        let processIdentifier = focusContext.processIdentifier

        watchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pasteSettleNanoseconds)
            guard let self, !Task.isCancelled else { return }

            AXUIElementSetMessagingTimeout(element, 0.5)
            // Only watch when the paste really is in the field's text.
            guard let textAfterPaste = Self.readableText(of: element),
                  Self.containsWords(insertedWords, in: Self.normalizedWords(in: textAfterPaste)) else { return }

            self.watchedField = WatchedField(
                element: element,
                processIdentifier: processIdentifier,
                insertedWords: insertedWords,
                startedAt: Date(),
                baselineText: textAfterPaste,
                lastSeenText: textAfterPaste,
                unchangedPollCount: 0
            )

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                guard !Task.isCancelled, self.poll() else { break }
            }
        }
    }

    /// Stops watching (a new dictation is starting). A fix that has
    /// stopped changing is still learned; one being typed right now isn't,
    /// so half a word never ends up in the dictionary.
    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        if var watchedField, watchedField.unchangedPollCount >= 1,
           watchedField.lastSeenText != watchedField.baselineText {
            learnFixes(from: watchedField.baselineText, to: watchedField.lastSeenText, in: &watchedField)
        }
        watchedField = nil
    }

    /// One look at the field. Returns false once watching should end.
    private func poll() -> Bool {
        guard var field = watchedField else { return false }

        let isStillFocused = Self.isFocused(field.element, processIdentifier: field.processIdentifier)
        let hasTimedOut = Date().timeIntervalSince(field.startedAt) > Self.watchSeconds
        // Never read what's typed while a password field has the keyboard.
        guard !IsSecureEventInputEnabled(),
              let currentText = Self.readableText(of: field.element) else {
            watchedField = nil
            return false
        }

        if currentText == field.lastSeenText {
            field.unchangedPollCount += 1
        } else {
            field.lastSeenText = currentText
            field.unchangedPollCount = 0
        }

        let isSettled = field.unchangedPollCount >= Self.stablePollsBeforeComparing
        if (isSettled || !isStillFocused || hasTimedOut) && currentText != field.baselineText {
            learnFixes(from: field.baselineText, to: currentText, in: &field)
            field.baselineText = currentText
        }

        guard isStillFocused, !hasTimedOut else {
            watchedField = nil
            return false
        }
        watchedField = field
        return true
    }

    // MARK: - Finding fixes

    private func learnFixes(from oldText: String, to newText: String, in field: inout WatchedField) {
        let dictionary = DictationDictionary.shared
        let foundFixes = Self.corrections(
            from: oldText,
            to: newText,
            insertedWords: field.insertedWords,
            fixesLearnedSoFar: field.fixesLearnedSoFar
        )
        for (correction, replacedWord) in foundFixes {
            if let replacedWord {
                dictionary.remove(word: replacedWord)
                field.fixesLearnedSoFar[replacedWord.lowercased()] = nil
            }
            guard !dictionary.contains(correction.corrected) else { continue }
            dictionary.add(correction)
            field.fixesLearnedSoFar[correction.corrected.lowercased()] = correction.original
            onLearnedCorrection?(correction)
        }
    }

    /// The fixes between two versions of the field's text that look like
    /// spelling fixes to the dictated words. A fix to a word learned
    /// moments ago comes back with that word, so it can be replaced.
    static func corrections(
        from oldText: String,
        to newText: String,
        insertedWords: [String],
        fixesLearnedSoFar: [String: String] = [:]
    ) -> [(correction: DictationLearnedCorrection, replacedWord: String?)] {
        let oldWords = oldText.split(whereSeparator: \.isWhitespace).map(String.init)
        let newWords = newText.split(whereSeparator: \.isWhitespace).map(String.init)

        var foundFixes: [(correction: DictationLearnedCorrection, replacedWord: String?)] = []
        for changedSpan in changedSpans(from: oldWords, to: newWords) {
            // A word or two (a name split in two) fixed to one or two words.
            guard (1...3).contains(changedSpan.oldRange.count),
                  (1...2).contains(changedSpan.newRange.count) else { continue }

            let originalWords = oldWords[changedSpan.oldRange].map { $0.trimmingCharacters(in: edgePunctuation) }
            let correctedWords = newWords[changedSpan.newRange].map { $0.trimmingCharacters(in: edgePunctuation) }
            guard !originalWords.contains(where: \.isEmpty), !correctedWords.contains(where: \.isEmpty) else { continue }

            let changedText = originalWords.joined(separator: " ")
            let corrected = correctedWords.joined(separator: " ")
            // Fixing a word learned moments ago: it stands for what
            // dictation wrote in the first place.
            let earlierOriginal = fixesLearnedSoFar[changedText.lowercased()]
            let original = earlierOriginal ?? changedText
            let previousWord = changedSpan.newRange.lowerBound > 0 ? newWords[changedSpan.newRange.lowerBound - 1] : nil
            let isSentenceStart = previousWord.map { $0.last.map { ".!?".contains($0) } ?? true } ?? true

            guard earlierOriginal != nil || containsWords(originalWords.map { $0.lowercased() }, in: insertedWords),
                  looksLikeSpellingFix(original: original, corrected: corrected, isSentenceStart: isSentenceStart) else { continue }
            foundFixes.append((
                correction: DictationLearnedCorrection(original: original, corrected: corrected, learnedAt: Date()),
                replacedWord: earlierOriginal != nil ? changedText : nil
            ))
        }
        return foundFixes
    }

    private static func looksLikeSpellingFix(original: String, corrected: String, isSentenceStart: Bool) -> Bool {
        guard (2...40).contains(corrected.count),
              corrected.rangeOfCharacter(from: .letters) != nil,
              original != corrected else { return false }

        let hasUppercase = corrected.rangeOfCharacter(from: .uppercaseLetters) != nil
        if original.lowercased() == corrected.lowercased() {
            // Only casing changed: learn names and brands ("waseem" →
            // "Waseem", "iphone" → "iPhone"), not a capital at the start
            // of a sentence.
            let hasInnerUppercase = corrected.dropFirst().contains { $0.isUppercase }
            return hasInnerUppercase || (hasUppercase && !isSentenceStart && original == original.lowercased())
        }

        // Spelled alike: at most half the letters differ.
        let originalLetters = original.lowercased().filter { $0.isLetter || $0.isNumber }
        let correctedLetters = corrected.lowercased().filter { $0.isLetter || $0.isNumber }
        let longerLength = max(originalLetters.count, correctedLetters.count)
        guard longerLength > 0,
              Double(editDistance(Array(originalLetters), Array(correctedLetters))) / Double(longerLength) <= 0.5 else { return false }

        // Swapping one everyday word for another ("there" → "their") is a
        // grammar fix; a dictionary entry wouldn't help.
        return hasUppercase || !isSpelledCorrectly(corrected)
    }

    private static func isSpelledCorrectly(_ text: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: text, startingAt: 0).location == NSNotFound
    }

    // MARK: - Diffing words

    private struct ChangedSpan {
        let oldRange: Range<Int>
        let newRange: Range<Int>
    }

    /// The runs of words that differ between the two texts, from a longest
    /// common subsequence of the part between the shared start and end.
    private static func changedSpans(from oldWords: [String], to newWords: [String]) -> [ChangedSpan] {
        var sharedPrefixCount = 0
        while sharedPrefixCount < min(oldWords.count, newWords.count),
              oldWords[sharedPrefixCount] == newWords[sharedPrefixCount] {
            sharedPrefixCount += 1
        }
        var sharedSuffixCount = 0
        while sharedSuffixCount < min(oldWords.count, newWords.count) - sharedPrefixCount,
              oldWords[oldWords.count - 1 - sharedSuffixCount] == newWords[newWords.count - 1 - sharedSuffixCount] {
            sharedSuffixCount += 1
        }

        let oldMiddle = Array(oldWords[sharedPrefixCount..<(oldWords.count - sharedSuffixCount)])
        let newMiddle = Array(newWords[sharedPrefixCount..<(newWords.count - sharedSuffixCount)])
        if oldMiddle.isEmpty || newMiddle.isEmpty { return [] }
        // Big rewrites aren't spelling fixes, and the table grows fast.
        guard oldMiddle.count <= 80, newMiddle.count <= 80 else { return [] }

        // commonLengths[i][j]: longest common subsequence of oldMiddle[i...]
        // and newMiddle[j...].
        var commonLengths = Array(repeating: Array(repeating: 0, count: newMiddle.count + 1), count: oldMiddle.count + 1)
        for oldIndex in stride(from: oldMiddle.count - 1, through: 0, by: -1) {
            for newIndex in stride(from: newMiddle.count - 1, through: 0, by: -1) {
                commonLengths[oldIndex][newIndex] = oldMiddle[oldIndex] == newMiddle[newIndex]
                    ? commonLengths[oldIndex + 1][newIndex + 1] + 1
                    : max(commonLengths[oldIndex + 1][newIndex], commonLengths[oldIndex][newIndex + 1])
            }
        }

        var changedSpans: [ChangedSpan] = []
        var oldIndex = 0
        var newIndex = 0
        var spanStart: (old: Int, new: Int)?
        func closeSpan() {
            if let start = spanStart {
                changedSpans.append(ChangedSpan(
                    oldRange: (sharedPrefixCount + start.old)..<(sharedPrefixCount + oldIndex),
                    newRange: (sharedPrefixCount + start.new)..<(sharedPrefixCount + newIndex)
                ))
                spanStart = nil
            }
        }
        while oldIndex < oldMiddle.count || newIndex < newMiddle.count {
            if oldIndex < oldMiddle.count, newIndex < newMiddle.count, oldMiddle[oldIndex] == newMiddle[newIndex] {
                closeSpan()
                oldIndex += 1
                newIndex += 1
                continue
            }
            if spanStart == nil { spanStart = (oldIndex, newIndex) }
            if newIndex >= newMiddle.count
                || (oldIndex < oldMiddle.count && commonLengths[oldIndex + 1][newIndex] >= commonLengths[oldIndex][newIndex + 1]) {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        closeSpan()
        // Pure insertions or deletions (more typing, a deleted word) aren't fixes.
        return changedSpans.filter { !$0.oldRange.isEmpty && !$0.newRange.isEmpty }
    }

    private static func editDistance(_ first: [Character], _ second: [Character]) -> Int {
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }
        var previousRow = Array(0...second.count)
        for firstIndex in 1...first.count {
            var currentRow = [firstIndex] + Array(repeating: 0, count: second.count)
            for secondIndex in 1...second.count {
                let substitutionCost = first[firstIndex - 1] == second[secondIndex - 1] ? 0 : 1
                currentRow[secondIndex] = min(
                    previousRow[secondIndex] + 1,
                    currentRow[secondIndex - 1] + 1,
                    previousRow[secondIndex - 1] + substitutionCost
                )
            }
            previousRow = currentRow
        }
        return previousRow[second.count]
    }

    // MARK: - Helpers

    static func normalizedWords(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: edgePunctuation).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// True when `words` appear in order, next to each other, in `allWords`.
    private static func containsWords(_ words: [String], in allWords: [String]) -> Bool {
        guard !words.isEmpty, words.count <= allWords.count else { return false }
        for startIndex in 0...(allWords.count - words.count)
        where Array(allWords[startIndex..<(startIndex + words.count)]) == words {
            return true
        }
        return false
    }

    private static func readableText(of element: AXUIElement) -> String? {
        var valueObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueObject) == .success,
              let text = valueObject as? String,
              text.count <= maximumFieldLength else { return nil }
        return text
    }

    private static func isFocused(_ element: AXUIElement, processIdentifier: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else { return false }
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else { return false }
        return CFEqual(focusedElementValue, element)
    }
}
