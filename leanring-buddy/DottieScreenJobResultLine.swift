//
//  DottieScreenJobResultLine.swift
//  leanring-buddy
//
//  What Dottie says when a screen job ends. The result used to go back
//  through a whole voice turn (the talker, then Claude Haiku with its tools
//  and often a screenshot) just to turn "Your rank is 312th" into a fun
//  sentence: $0.03 to $0.05 a job, and the instruction showed in Home as if
//  the user had typed it. The job's own answer is already written for the
//  user, so it is said as it is. Foundation only, so it can be unit tested.
//

import Foundation

nonisolated enum DottieScreenJobResultLine {
    /// How a failed job's result starts (CompanionManager and the TV runner).
    static let failurePrefix = "it couldn't be finished: "

    /// The line to say. `closingMessage` is a smart replay's own line, said
    /// word for word in place of the result.
    static func spokenLine(resultText: String, waitingCount: Int = 0, closingMessage: String? = nil) -> String {
        let trimmedClosingMessage = closingMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var line: String
        if !trimmedClosingMessage.isEmpty {
            line = trimmedClosingMessage
        } else {
            let trimmedResult = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedResult.lowercased().hasPrefix(failurePrefix) {
                let reason = String(trimmedResult.dropFirst(failurePrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                line = reason.isEmpty ? "I couldn't finish that." : "I couldn't finish that: \(reason)"
            } else {
                line = trimmedResult.isEmpty ? "Done." : trimmedResult
            }
        }
        line = sentenceCased(endingWithPunctuation(line))
        if waitingCount > 0 {
            line += " On to the next one."
        }
        return line
    }

    /// The exchange kept for the next turns' history, so "do it again"
    /// still knows which job was meant.
    static func historyUserLine(taskText: String) -> String {
        "(the on-screen job \"\(taskText.prefix(200))\" finished)"
    }

    private static func endingWithPunctuation(_ text: String) -> String {
        guard let lastCharacter = text.last else { return text }
        return ".!?\"')".contains(lastCharacter) ? text : text + "."
    }

    private static func sentenceCased(_ text: String) -> String {
        guard let firstCharacter = text.first, firstCharacter.isLowercase else { return text }
        return firstCharacter.uppercased() + text.dropFirst()
    }
}
