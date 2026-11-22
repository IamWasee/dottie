//
//  DottieJobMemory.swift
//  leanring-buddy
//
//  A screen job's short running memory: every move and tool call it made,
//  and, for a job that repeats the same task ("do this 3 times"), which
//  round it's on, what the first round did (the recipe for the rest) and
//  what's left. Jev and the step model only saw the last few moves, and
//  the "you already did this" checks fought repeating on purpose, so round
//  one went perfectly and round two got lost. Kept short so steps stay
//  quick. Pure, so it can be unit tested.
//

import Foundation

struct DottieJobMemory: Equatable {
    /// A job never repeats more than this, whatever the words say.
    static let maximumRounds = 20
    /// The longest the memory text gets, so it never slows a step down.
    static let maximumStateCharacters = 1500
    /// Moves shown in full; longer lists keep the first few and the newest.
    static let movesShownInFull = 14

    let totalRounds: Int
    private(set) var currentRound = 1
    /// The moves of each round, in order: index 0 is round 1.
    private(set) var movesByRound: [[String]] = [[]]

    init(totalRounds: Int) {
        self.totalRounds = min(max(totalRounds, 1), Self.maximumRounds)
    }

    init(taskText: String) {
        self.init(totalRounds: Self.roundCount(in: taskText))
    }

    var isRepeatedJob: Bool { totalRounds > 1 }
    var hasRoundsLeft: Bool { currentRound < totalRounds }
    var movesThisRound: [String] { movesByRound.last ?? [] }
    var allMoves: [String] { movesByRound.flatMap { $0 } }

    mutating func noteMove(_ moveSummary: String) {
        let trimmedSummary = moveSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }
        movesByRound[movesByRound.count - 1].append(trimmedSummary)
    }

    /// Closes the round in progress and starts the next. False (and nothing
    /// changes) on the last round, or when this round made no move yet: a
    /// new round starts on the screen the last one left, which can look
    /// finished before anything was done.
    @discardableResult
    mutating func finishRound() -> Bool {
        guard hasRoundsLeft, !movesThisRound.isEmpty else { return false }
        currentRound += 1
        movesByRound.append([])
        return true
    }

    /// "do it 3 times", "three times", "twice", "x3": how many times the job
    /// repeats the same task, or 1.
    static func roundCount(in taskText: String) -> Int {
        let lowercasedTask = taskText.lowercased()
        let numberWords: [String: Int] = [
            "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20
        ]
        if lowercasedTask.range(of: #"\btwice\b"#, options: .regularExpression) != nil { return 2 }
        if lowercasedTask.range(of: #"\bthrice\b"#, options: .regularExpression) != nil { return 3 }
        let timesPattern = #"\b(\d{1,2}|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty)\s+(?:more\s+)?times\b"#
        // "x3" only: "2x" is usually a speed or a size.
        let multiplierPattern = #"\bx\s?(\d{1,2})\b"#
        for pattern in [timesPattern, multiplierPattern] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: lowercasedTask, range: NSRange(lowercasedTask.startIndex..., in: lowercasedTask)) else { continue }
            for groupIndex in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: groupIndex), in: lowercasedTask) else { continue }
                let countText = String(lowercasedTask[range])
                if let count = Int(countText) ?? numberWords[countText], count >= 2 {
                    return min(count, maximumRounds)
                }
            }
        }
        return 1
    }

    /// A list of moves, short: all of them when few, else the first few,
    /// how many were left out, and the newest.
    static func compactList(_ moves: [String]) -> String {
        guard moves.count > movesShownInFull else { return moves.joined(separator: "; ") }
        let firstMoves = moves.prefix(4)
        let newestMoves = moves.suffix(movesShownInFull - 4)
        let leftOutCount = moves.count - firstMoves.count - newestMoves.count
        return firstMoves.joined(separator: "; ") + "; … \(leftOutCount) more …; " + newestMoves.joined(separator: "; ")
    }

    /// What Jev's state and the step model's note say about the job so far.
    func stateText() -> String {
        var lines: [String] = []
        if isRepeatedJob {
            lines.append("This job is the same task \(totalRounds) times in a row. Now on round \(currentRound) of \(totalRounds).")
            if movesByRound.count > 1 {
                let firstRound = movesByRound[0]
                lines.append("Round 1 is done and worked (\(firstRound.count) moves): \(Self.compactList(firstRound)). Do the same steps again for the next one.")
                if currentRound > 2 {
                    let doneRounds = movesByRound[1..<(movesByRound.count - 1)]
                    let doneCounts = doneRounds.map { "\($0.count)" }.joined(separator: ", ")
                    lines.append("Rounds 2 to \(currentRound - 1) are done too (\(doneCounts) moves).")
                }
            }
            if movesThisRound.isEmpty {
                lines.append("This round: nothing done yet.")
            } else {
                lines.append("This round so far: \(Self.compactList(movesThisRound)).")
            }
            lines.append(hasRoundsLeft
                ? "When this round is done, say so (\"this round is done\") and start round \(currentRound + 1)."
                : "This is the last round: when it's done, the whole job is done.")
        } else if allMoves.isEmpty {
            lines.append("Nothing has been done yet.")
        } else {
            lines.append("Done so far, in order (\(allMoves.count) moves): \(Self.compactList(allMoves)).")
        }
        let stateText = lines.joined(separator: "\n")
        return stateText.count > Self.maximumStateCharacters ? String(stateText.prefix(Self.maximumStateCharacters)) + "…" : stateText
    }
}
