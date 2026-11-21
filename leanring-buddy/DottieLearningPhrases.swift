//
//  DottieLearningPhrases.swift
//  leanring-buddy
//
//  "Watch me for 30 seconds", "create a smart replay of me doing this" and
//  "done" / "stop watching", caught on the Mac before any model. Teaching
//  Dottie by showing her is the main thing she's for, and in round 1079
//  these asks went to the talker and Claude, which answered as if it were
//  watching without ever starting watch_and_learn or smart_replays.
//  Foundation only, so the matching can be unit tested.
//

import Foundation

enum DottieLearningPhrase: Equatable {
    case startWatching(seconds: Int?)
    case stopWatching
    case startReplay(kind: String)
    case stopReplay

    /// The tool call the phrase stands for (run through the voice tools).
    var toolName: String {
        switch self {
        case .startWatching, .stopWatching: return "watch_and_learn"
        case .startReplay, .stopReplay: return "smart_replays"
        }
    }

    var toolArguments: [String: Any] {
        switch self {
        case .startWatching(let seconds):
            var arguments: [String: Any] = ["action": "start"]
            if let seconds { arguments["seconds"] = seconds }
            return arguments
        case .stopWatching, .stopReplay:
            return ["action": "stop"]
        case .startReplay(let kind):
            return ["action": "start", "kind": kind]
        }
    }

    private static let watchPattern = #"^(?:watch|observe|look at|see) (?:me|what i do|how i do (?:this|it)|this)(?: (?:do|doing) (?:this|it|something))?(?: for (?:(\d+)|(a|an|one|two|three|half a)) (seconds?|secs?|minutes?|mins?))?(?: and (?:learn|remember)(?: (?:it|this|how))?)?$"#
    private static let replayPattern = #"^(?:create|make|record|start|do) (?:a |an )?(smart|commercial) replay(?: of (?:me doing )?(?:this|it|what i do))?$"#
    private static let stopWords: Set<String> = [
        "done", "i'm done", "im done", "i am done", "finished", "i'm finished", "all done", "that's it", "thats it",
        "stop watching", "stop recording", "you can stop", "ok done", "okay done"
    ]

    /// What an already-normalized ask means, or nil when it isn't one of
    /// these. "done" only counts while watching or recording.
    static func phrase(in normalizedText: String, isWatching: Bool, isRecordingReplay: Bool) -> DottieLearningPhrase? {
        if isWatching || isRecordingReplay, stopWords.contains(normalizedText) {
            return isWatching ? .stopWatching : .stopReplay
        }
        if let replayMatch = firstMatch(of: replayPattern, in: normalizedText) {
            return .startReplay(kind: replayMatch[1] ?? "smart")
        }
        if let watchMatch = firstMatch(of: watchPattern, in: normalizedText) {
            return .startWatching(seconds: seconds(number: watchMatch[1], word: watchMatch[2], unit: watchMatch[3]))
        }
        return nil
    }

    /// The line shown in the notch for the tool's answer (written for a
    /// model, so it's reworded here).
    func doneText(forToolResult toolResult: String) -> String {
        let lowercasedResult = toolResult.lowercased()
        switch self {
        case .startWatching:
            guard lowercasedResult.hasPrefix("watching for") else { return Self.sentenceCased(Self.firstSentence(of: toolResult)) }
            let secondsText = toolResult.components(separatedBy: ".").first ?? toolResult
            return Self.sentenceCased(secondsText) + ". Go ahead and do it the way you normally would."
        case .stopWatching:
            if let summary = Self.text(in: toolResult, after: "what you understood: ", before: " tell the user") {
                return "Learned it: \(summary)"
            }
            return Self.sentenceCased(Self.firstSentence(of: toolResult))
        case .startReplay:
            guard lowercasedResult.hasPrefix("watching now") else { return Self.sentenceCased(Self.firstSentence(of: toolResult)) }
            return "Watching. Do the job, then say \u{201C}done\u{201D}."
        case .stopReplay:
            if let saved = Self.text(in: toolResult, after: "saved the ", before: ". read the steps back") {
                return "Saved the " + saved + "."
            }
            return Self.sentenceCased(Self.firstSentence(of: toolResult))
        }
    }

    // MARK: - Helpers

    private static func seconds(number: String?, word: String?, unit: String?) -> Int? {
        let amount: Double?
        if let number, let parsedNumber = Double(number) {
            amount = parsedNumber
        } else if let word {
            let wordAmounts: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "half a": 0.5]
            amount = wordAmounts[word]
        } else {
            amount = nil
        }
        guard let amount, let unit else { return nil }
        let isMinutes = unit.hasPrefix("min")
        return Int(isMinutes ? amount * 60 : amount)
    }

    /// The whole match's capture groups, index 0 being the whole match.
    private static func firstMatch(of pattern: String, in text: String) -> [String?]? {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern),
              let match = regularExpression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { groupIndex in
            Range(match.range(at: groupIndex), in: text).map { String(text[$0]) }
        }
    }

    private static func text(in fullText: String, after openingText: String, before closingText: String) -> String? {
        guard let openingRange = fullText.range(of: openingText) else { return nil }
        let rest = fullText[openingRange.upperBound...]
        let extracted = rest.range(of: closingText).map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstSentence(of text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sentenceEnd = trimmedText.firstIndex(where: { ".!?".contains($0) }) else { return trimmedText }
        return String(trimmedText[...sentenceEnd])
    }

    private static func sentenceCased(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
