//
//  DottieLooseLabels.swift
//  leanring-buddy
//
//  Finding a remembered button again when its words changed a little.
//  App memory and saved tasks used to act only when a label read exactly
//  the same, so "Inbox (3)" didn't match "Inbox (5)", "Updated 2 min ago"
//  didn't match "Updated 5 min ago" and "Nov 26 report" didn't match
//  "Nov 27 report" (the app memory review, 27 Nov). Here counts, numbers,
//  dates and times are left out before comparing, and when several texts
//  fit, the one of the same kind (button, link, text box) nearest to where
//  the remembered one sat wins. Foundation only, so it can be unit tested.
//

import Foundation

enum DottieLooseLabels {
    /// Words that only say when, never what: left out before comparing.
    static let timeWords: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april", "may", "jun", "june",
        "jul", "july", "aug", "august", "sep", "sept", "september", "oct", "october", "nov", "november",
        "dec", "december", "mon", "monday", "tue", "tues", "tuesday", "wed", "wednesday", "thu", "thur",
        "thurs", "thursday", "fri", "friday", "sat", "saturday", "sun", "sunday", "today", "yesterday",
        "tomorrow", "am", "pm", "ago", "now", "sec", "secs", "second", "seconds", "min", "mins", "minute",
        "minutes", "hr", "hrs", "hour", "hours", "day", "days", "week", "weeks", "month", "months", "year", "years"
    ]
    /// Two labels at least this alike are the same control.
    static let sameControlScore = 0.6
    /// A remembered control further than this (0-1000) from where it sat
    /// is somewhere else on a changed page, not the one Dottie used.
    static let farthestMove = 350.0

    /// The words that name a control: lowercased, without counts in
    /// brackets, numbers, dates and times. One pass over the letters, no
    /// regular expressions: it runs for every text on every screen.
    static func coreWords(_ label: String) -> [String] {
        var words: [String] = []
        var currentWord = ""
        var bracketDepth = 0
        func endWord() {
            if !currentWord.isEmpty, !currentWord.contains(where: \.isNumber), !timeWords.contains(currentWord) {
                words.append(currentWord)
            }
            currentWord = ""
        }
        for character in label.lowercased() {
            if character == "(" || character == "[" {
                endWord()
                bracketDepth += 1
            } else if character == ")" || character == "]" {
                currentWord = ""
                bracketDepth = max(0, bracketDepth - 1)
            } else if bracketDepth > 0 {
                continue
            } else if character.isLetter || character.isNumber {
                currentWord.append(character)
            } else {
                endWord()
            }
        }
        endWord()
        return words
    }

    /// How alike two labels are, 0 to 1. Labels made only of numbers or
    /// dates are alike only when they read the same.
    static func similarity(_ firstLabel: String, _ secondLabel: String) -> Double {
        similarity(firstLabel, Set(coreWords(firstLabel)), secondLabel, Set(coreWords(secondLabel)))
    }

    /// The same, with each label's core words already worked out.
    static func similarity(_ firstLabel: String, _ firstWords: Set<String>, _ secondLabel: String, _ secondWords: Set<String>) -> Double {
        if firstWords.isEmpty || secondWords.isEmpty {
            let firstComparable = DottieAppMemoryPlan.comparableWords(firstLabel)
            return !firstComparable.isEmpty && firstComparable == DottieAppMemoryPlan.comparableWords(secondLabel) ? 1 : 0
        }
        let sharedCount = firstWords.intersection(secondWords).count
        let jaccard = Double(sharedCount) / Double(firstWords.union(secondWords).count)
        // "Rename" and "Rename column": every word of the shorter one is in
        // the longer one, which has at most two more.
        let shorter = firstWords.count <= secondWords.count ? firstWords : secondWords
        let longer = firstWords.count <= secondWords.count ? secondWords : firstWords
        if shorter.isSubset(of: longer), longer.count - shorter.count <= 2 {
            return max(jaccard, 0.8)
        }
        return jaccard
    }

    /// Something on the screen now that a remembered control could be.
    struct Candidate: Equatable {
        let label: String
        /// "button", "link", "text box"…, nil for text read off the screen.
        let role: String?
        let centerX: Double
        let centerY: Double
    }

    /// The candidate that is the remembered control: alike enough, not of
    /// another kind when both kinds are known, and not far from where it
    /// was; the most alike wins, then the nearest.
    static func bestMatch(
        forLabel rememberedLabel: String, role rememberedRole: String?,
        centerX rememberedX: Double?, centerY rememberedY: Double?,
        among candidates: [Candidate]
    ) -> Candidate? {
        let rememberedWords = Set(coreWords(rememberedLabel))
        let rememberedComparable = DottieAppMemoryPlan.comparableWords(rememberedLabel)
        var best: (candidate: Candidate, score: Double)?
        for candidate in candidates {
            let labelScore = similarity(rememberedLabel, rememberedWords, candidate.label, Set(coreWords(candidate.label)))
            guard labelScore >= sameControlScore else { continue }
            if let rememberedRole, let candidateRole = candidate.role,
               rememberedRole.lowercased() != candidateRole.lowercased() { continue }
            // Reading exactly the same beats being nearer ("Invoice 1043"
            // over "Invoice 1044" that moved into its place).
            var score = labelScore + (DottieAppMemoryPlan.comparableWords(candidate.label) == rememberedComparable ? 0.1 : 0)
            if let rememberedX, let rememberedY {
                let distance = hypot(candidate.centerX - rememberedX, candidate.centerY - rememberedY)
                guard distance <= farthestMove else { continue }
                // Nearness breaks ties; it never outweighs reading the same.
                score -= distance / 4000
            }
            if let currentBest = best, currentBest.score >= score { continue }
            best = (candidate, score)
        }
        return best?.candidate
    }
}
