//
//  DottieScreenJobHints.swift
//  leanring-buddy
//
//  Guiding a screen job while it works: "no, use the search bar, it's
//  faster" typed or said mid-job goes to the job instead of starting a new
//  turn. Jev and the step model get it on their next step and try it first;
//  a hint whose first moves change the screen counts as working and stays
//  the way for the rest of the job, one that changes nothing for 3 moves
//  is dropped. When the job finishes, the hints that worked are kept as
//  lessons for that app, so the next job starts the user's way. The
//  sorting of words is pure, so it can be unit tested.
//

import Foundation

enum DottieScreenJobHintPlan {
    /// Moves after a hint that change nothing before it's dropped.
    static let movesWithoutChangeToDropAHint = 3
    static let maximumHintCharacters = 300

    enum Status: String, Equatable {
        case trying
        case worked
        case didntHelp
    }

    struct Hint: Equatable {
        let text: String
        var status: Status = .trying
        var movesWithoutChange = 0

        /// The hint after one more move: changing the screen means it's
        /// working; 3 moves that change nothing mean it didn't help.
        func updated(afterMoveChangedScreen moveChangedScreen: Bool) -> Hint {
            guard status == .trying else { return self }
            var updatedHint = self
            if moveChangedScreen {
                updatedHint.status = .worked
            } else {
                updatedHint.movesWithoutChange += 1
                if updatedHint.movesWithoutChange >= movesWithoutChangeToDropAHint { updatedHint.status = .didntHelp }
            }
            return updatedHint
        }
    }

    /// Words that end a job instead of guiding it: those go the usual way
    /// (stop_screen_task, Escape), whatever follows them.
    private static let stoppingPhrases = ["stop", "cancel", "never mind", "nevermind", "forget it", "quit"]
    /// Words that pause first: guidance only when a way follows
    /// ("wait, use the other one").
    private static let pausingPhrases = ["pause", "hold on", "wait"]

    /// How guidance starts: a correction, a way to do it, or a place.
    private static let guidanceOpenings = [
        "no ", "no,", "nope", "not that", "not there", "wrong", "instead", "try ", "use ", "do it ", "you can", "you could",
        "you should", "it's faster", "its faster", "faster", "quicker", "don't ", "dont ", "do not ", "just ", "click ",
        "double click", "right click", "press ", "hit ", "type ", "go back", "scroll ", "drag ", "hold ",
        "the button", "the icon", "it's under", "its under", "it's in", "its in", "it's on", "its on",
        "look for", "first ", "then ", "actually", "rather"
    ]

    /// Words anywhere in the line that only make sense as guidance.
    private static let guidanceWords = ["faster", "quicker", "instead", "this way", "that way", "shortcut", "the other one", "not that one"]

    /// Whether something the user said while a job runs guides that job,
    /// rather than stopping it or asking about something else.
    /// While a screen job waits on a question, the user's next words are
    /// the answer (Wasee, 28 Nov: an answer to the job's question became a
    /// new job queued behind it), unless they say to stop.
    static func isAnswerToWaitingQuestion(_ text: String) -> Bool {
        let lowercasedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowercasedText.isEmpty, lowercasedText.count <= 1000 else { return false }
        let paddedText = " " + lowercasedText.replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression) + " "
        return !stoppingPhrases.contains(where: { paddedText.hasPrefix(" \($0) ") })
    }

    static func isGuidance(_ text: String) -> Bool {
        let lowercasedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lowercasedText.count >= 4, lowercasedText.count <= maximumHintCharacters else { return false }
        let paddedText = " " + lowercasedText.replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression) + " "
        if stoppingPhrases.contains(where: { paddedText.hasPrefix(" \($0) ") }) { return false }
        if pausingPhrases.contains(where: { paddedText.hasPrefix(" \($0) ") }) {
            return guidanceWords.contains { lowercasedText.contains($0) } || lowercasedText.contains(" use ") || lowercasedText.contains(" try ")
        }
        if lowercasedText.hasSuffix("?") && !guidanceWords.contains(where: { lowercasedText.contains($0) }) { return false }
        if guidanceOpenings.contains(where: { lowercasedText.hasPrefix($0) }) { return true }
        return guidanceWords.contains { lowercasedText.contains($0) }
    }

    /// What Jev's state and the step model's note say about the user's
    /// hints: the newest one still being tried first, then the ones that worked.
    static func stateText(hints: [Hint]) -> String {
        var lines: [String] = []
        let workedHints = hints.filter { $0.status == .worked }
        let tryingHints = hints.filter { $0.status == .trying }
        if let newestTryingHint = tryingHints.last {
            lines.append("The user just told Dottie, while she works: \"\(newestTryingHint.text)\". Do it their way now, before anything else.")
        }
        if !workedHints.isEmpty {
            lines.append("The user's way worked, so keep doing it like that: " + workedHints.map { "\"\($0.text)\"" }.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// The lesson kept for the app when the job finished: the user's own way.
    static func lessonText(for hint: Hint) -> String {
        "The user showed a faster way while Dottie worked: \"\(hint.text)\". Do it that way."
    }

    /// Keys the hint names ("press command k", "use cmd+shift+n"), as a key
    /// combination Dottie can press, or nil.
    static func keyCombination(in hintText: String) -> String? {
        let lowercasedHint = hintText.lowercased()
        let keyWords = "(?:command|cmd|shift|option|opt|alt|control|ctrl|fn|⌘)"
        let pattern = "(?<![a-z])\(keyWords)(?:[ +]+(?:\(keyWords)|[a-z0-9]{1,6}))+"
        guard let range = lowercasedHint.range(of: pattern, options: .regularExpression) else { return nil }
        let spokenKeys = String(lowercasedHint[range])
        // Drop trailing words that aren't keys ("command k instead").
        var words = spokenKeys.replacingOccurrences(of: "+", with: " ").split(separator: " ").map(String.init)
        while !words.isEmpty {
            if let keyCombination = DottieInstantCommands.keyCombination(fromSpokenKeys: words.joined(separator: " ")) {
                return keyCombination
            }
            words.removeLast()
        }
        return nil
    }
}

/// The hints for the job that's running now. The voice and typed turns
/// add to it; the Jev driver and the step model take what's new each step.
@MainActor
final class DottieScreenJobHints {
    static let shared = DottieScreenJobHints()

    private(set) var hints: [DottieScreenJobHintPlan.Hint] = []
    /// Whether a screen job is running to take hints (set by its runner).
    var jobIsRunning = false
    /// How many hints the step loops have already picked up.
    private var handedOutCount = 0

    func add(_ hintText: String) {
        let trimmedHint = String(hintText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(DottieScreenJobHintPlan.maximumHintCharacters))
        guard !trimmedHint.isEmpty else { return }
        hints.append(DottieScreenJobHintPlan.Hint(text: trimmedHint))
        DottieLog.notice("🧭 The user guided the screen job: \(trimmedHint)")
    }

    /// Hints given since the last call.
    func takeNew() -> [DottieScreenJobHintPlan.Hint] {
        let newHints = Array(hints.dropFirst(handedOutCount))
        handedOutCount = hints.count
        return newHints
    }

    var hasHints: Bool { !hints.isEmpty }

    /// One more move was made: every hint still being tried learns whether
    /// it changed the screen.
    func noteMove(changedScreen: Bool) {
        hints = hints.map { $0.updated(afterMoveChangedScreen: changedScreen) }
    }

    var stateText: String { DottieScreenJobHintPlan.stateText(hints: hints) }

    /// A new job starts with no hints.
    func reset() {
        hints = []
        handedOutCount = 0
    }

    /// The job finished: hints that worked (or were still being tried when
    /// it finished, so they led to the end) become lessons for the app.
    func keepWorkingHintsAsLessons(taskText: String, appName: String?) {
        for hint in hints where hint.status != .didntHelp {
            DottieScreenLessons.shared.add(DottieScreenJobHintPlan.lessonText(for: hint), task: taskText, appName: appName, cameFromSuccess: true)
        }
    }
}
