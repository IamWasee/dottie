//
//  DottieTaskMatching.swift
//  leanring-buddy
//
//  Whether something Dottie learned before (a watched how-to, a screen
//  job's learned plan) fits the job in front of her. Both used to match on
//  any shared words, so "open my bull and shit folder" and a Notes job
//  both loaded the plan "Open Finder and show the Downloads folder": they
//  share "open", "and" and "folder". Matching now counts only the words
//  that say what the job is about. Foundation only, so it can be unit
//  tested.
//

import Foundation

nonisolated enum DottieTaskMatching {
    /// Words that say how or that something is done, not what it's about.
    static let genericWords: Set<String> = [
        "the", "and", "for", "with", "into", "onto", "from", "that", "this", "then", "there", "here",
        "can", "you", "your", "please", "could", "would", "will", "just", "now", "again", "all", "any",
        "open", "opens", "opening", "show", "shows", "close", "click", "clicks", "press", "type", "go", "goes",
        "make", "makes", "create", "new", "get", "find", "put", "move", "use", "using", "set", "start",
        "app", "apps", "application", "window", "folder", "folders", "file", "files", "page", "button",
        "mine", "our", "its", "them", "they", "it's", "what", "how", "when", "where", "which", "out", "off"
    ]

    /// The words that say what a job is about: lowercased, generic words
    /// left out, plurals folded ("notes" and "note" are the same word).
    static func contentWords(_ text: String) -> Set<String> {
        let rawWords = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 || $0.contains(where: \.isNumber) }
        return Set(rawWords.filter { !genericWords.contains($0) }.map(singular))
    }

    private static func singular(_ word: String) -> String {
        guard word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }

    /// How alike two jobs are, 0 to 1: the shared content words over the
    /// larger set, so a short ask doesn't fit every longer one that shares
    /// a word with it. 0 when either has no content words.
    static func taskSimilarity(_ firstTask: String, _ secondTask: String) -> Double {
        let firstWords = contentWords(firstTask), secondWords = contentWords(secondTask)
        guard !firstWords.isEmpty, !secondWords.isEmpty else { return 0 }
        return Double(firstWords.intersection(secondWords).count) / Double(max(firstWords.count, secondWords.count))
    }

    /// Whether a how-to Dottie learned by watching fits a job. The job
    /// must share a word with what the how-to is about (its name and goal,
    /// leaving out the app's own name), and either be in the how-to's app
    /// or name it, or share two such words. Being in the same app alone is
    /// not enough: every Finder job used to get the Downloads how-to.
    static func howToFits(taskText: String, frontmostAppName: String?,
                          howToName: String, howToGoal: String, howToAppName: String) -> Bool {
        let appWords = contentWords(howToAppName)
        let taskWords = contentWords(taskText)
        let howToTopicWords = contentWords(howToName + " " + howToGoal).subtracting(appWords)
        let sharedTopicWords = taskWords.intersection(howToTopicWords)
        guard !sharedTopicWords.isEmpty else { return false }
        if sharedTopicWords.count >= 2 { return true }
        let isInHowToApp = frontmostAppName.map { !$0.isEmpty && howToAppName.lowercased().contains($0.lowercased()) } ?? false
        let namesHowToApp = !appWords.isEmpty && !taskWords.isDisjoint(with: appWords)
        return isInHowToApp || namesHowToApp
    }
}
