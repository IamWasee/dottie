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
//  quick. A job can run for thousands of moves (Wasee, 27 Nov: enterprise
//  jobs), so only what still matters is kept: round 1 (the recipe), the
//  last few rounds and this round; older rounds become a count. Every 100
//  moves the driver saves this to a file and starts again from that file
//  (DottieJobLedger), so a long job's state never fills with old details.
//  Pure, so it can be unit tested.
//

import Foundation

struct DottieJobMemory: Equatable {
    /// A job never repeats more than this, whatever the words say.
    static let maximumRounds = 1_000
    /// Finished rounds after round 1 kept move by move; older ones are counted.
    static let recentRoundsKept = 3
    /// Moves of one round kept move by move: the first few and the newest.
    static let firstMovesKeptPerRound = 4
    static let newestMovesKeptPerRound = 30
    /// The longest the memory text gets, so it never slows a step down.
    static let maximumStateCharacters = 1500
    /// Moves shown in full; longer lists keep the first few and the newest.
    static let movesShownInFull = 14

    let totalRounds: Int
    private(set) var currentRound = 1
    /// Round 1's moves: the recipe every later round follows.
    private(set) var recipe: [String] = []
    /// The newest finished rounds after round 1, oldest first.
    private(set) var recentRounds: [[String]] = []
    /// Finished rounds after round 1 no longer kept move by move.
    private(set) var roundsForgotten = 0
    private(set) var movesInForgottenRounds = 0
    /// This round's moves (its first few and newest when it runs long).
    private(set) var movesThisRound: [String] = []
    /// Moves of this round left out of the middle of `movesThisRound`.
    private(set) var movesDroppedThisRound = 0
    /// Every move the job made, kept or not.
    private(set) var totalMovesNoted = 0

    init(totalRounds: Int) {
        self.totalRounds = min(max(totalRounds, 1), Self.maximumRounds)
    }

    init(taskText: String) {
        self.init(totalRounds: Self.roundCount(in: taskText))
    }

    /// Rebuilt from a saved page: nothing that isn't in the page comes back.
    init(ledgerPage: DottieJobLedger.Page) {
        self.init(totalRounds: ledgerPage.totalRounds)
        currentRound = min(max(ledgerPage.currentRound, 1), totalRounds)
        recipe = ledgerPage.recipe
        recentRounds = Array(ledgerPage.recentRounds.suffix(Self.recentRoundsKept))
        roundsForgotten = ledgerPage.roundsForgotten
        movesInForgottenRounds = ledgerPage.movesInForgottenRounds
        movesThisRound = ledgerPage.movesThisRound
        movesDroppedThisRound = ledgerPage.movesDroppedThisRound
        totalMovesNoted = ledgerPage.totalMoves
    }

    var isRepeatedJob: Bool { totalRounds > 1 }
    var hasRoundsLeft: Bool { currentRound < totalRounds }
    /// The moves still kept, in order (round 1, recent rounds, this round).
    var allMoves: [String] {
        let earlierRounds = currentRound > 1 ? [recipe] + recentRounds : []
        return earlierRounds.flatMap { $0 } + movesThisRound
    }

    mutating func noteMove(_ moveSummary: String) {
        let trimmedSummary = moveSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }
        totalMovesNoted += 1
        movesThisRound.append(trimmedSummary)
        // A long round keeps its first moves (how it started) and the newest.
        let keptLimit = Self.firstMovesKeptPerRound + Self.newestMovesKeptPerRound
        if movesThisRound.count > keptLimit {
            movesThisRound.remove(at: Self.firstMovesKeptPerRound)
            movesDroppedThisRound += 1
        }
    }

    /// Closes the round in progress and starts the next. False (and nothing
    /// changes) on the last round, or when this round made no move yet: a
    /// new round starts on the screen the last one left, which can look
    /// finished before anything was done.
    @discardableResult
    mutating func finishRound() -> Bool {
        guard hasRoundsLeft, !movesThisRound.isEmpty else { return false }
        if currentRound == 1 {
            recipe = movesThisRound
        } else {
            recentRounds.append(movesThisRound)
            if recentRounds.count > Self.recentRoundsKept {
                let forgottenRound = recentRounds.removeFirst()
                roundsForgotten += 1
                movesInForgottenRounds += forgottenRound.count
            }
        }
        currentRound += 1
        movesThisRound = []
        movesDroppedThisRound = 0
        return true
    }

    /// "do it 3 times", "three times", "twice", "x3": how many times the job
    /// repeats the same task, or 1.
    static func roundCount(in taskText: String) -> Int {
        let lowercasedTask = taskText.lowercased()
        let numberWords: [String: Int] = [
            "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "hundred": 100
        ]
        if lowercasedTask.range(of: #"\btwice\b"#, options: .regularExpression) != nil { return 2 }
        if lowercasedTask.range(of: #"\bthrice\b"#, options: .regularExpression) != nil { return 3 }
        let timesPattern = #"\b(\d{1,3}(?:,\d{3})|\d{1,5}|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|hundred)\s+(?:more\s+)?times\b"#
        // "x3" only: "2x" is usually a speed or a size.
        let multiplierPattern = #"\bx\s?(\d{1,4})\b"#
        for pattern in [timesPattern, multiplierPattern] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: lowercasedTask, range: NSRange(lowercasedTask.startIndex..., in: lowercasedTask)) else { continue }
            for groupIndex in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: groupIndex), in: lowercasedTask) else { continue }
                let countText = String(lowercasedTask[range]).replacingOccurrences(of: ",", with: "")
                if let count = Int(countText) ?? numberWords[countText], count >= 2 {
                    return min(count, maximumRounds)
                }
            }
        }
        // "add three new patients", "add these two patients": a number of
        // new things, one round each. "add two numbers" isn't (no "new",
        // "these" or "the following"). On the OpenEMR demo (27 Nov) a list
        // of patients ran as one long job and lost its place after the first.
        let numberOfThingsPattern = #"\b(?:add|create|book|make|enter|register|schedule)\s+(?:(?:these|the\s+following)\s+(\d{1,3}|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty)\s+(?:new\s+)?|(\d{1,3}|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty)\s+new\s+)[a-z]+s\b"#
        if let expression = try? NSRegularExpression(pattern: numberOfThingsPattern),
           let match = expression.firstMatch(in: lowercasedTask, range: NSRange(lowercasedTask.startIndex..., in: lowercasedTask)) {
            for groupIndex in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: groupIndex), in: lowercasedTask) else { continue }
                let countText = String(lowercasedTask[range])
                if let count = Int(countText) ?? numberWords[countText], count >= 2 { return min(count, maximumRounds) }
            }
        }
        // A numbered list: "(1) Maria … (2) David … (3) Sarah".
        let numberedItems = numberedListLength(in: lowercasedTask)
        if numberedItems >= 2 { return min(numberedItems, maximumRounds) }
        return 1
    }

    /// How many items a numbered list in the request has: "(1) … (2) …" or
    /// "1) … 2) …", counted from 1 while the numbers follow on.
    static func numberedListLength(in taskText: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: #"(?:^|[\s:;,])\(?(\d{1,2})\)\s"#) else { return 0 }
        var numbersSeen = Set<Int>()
        for match in expression.matches(in: taskText, range: NSRange(taskText.startIndex..., in: taskText)) {
            guard let range = Range(match.range(at: 1), in: taskText), let number = Int(taskText[range]) else { continue }
            numbersSeen.insert(number)
        }
        var listLength = 0
        while numbersSeen.contains(listLength + 1) { listLength += 1 }
        return listLength
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
    /// Where this round is and what to do next always fit; the recipe gives
    /// way when the text runs long (it used to be cut from the end, which
    /// dropped "this round so far" on long jobs).
    func stateText() -> String {
        var headLines: [String] = []
        var recipeLine: String?
        var tailLines: [String] = []
        if isRepeatedJob {
            headLines.append("This job is the same task \(totalRounds) times in a row. Now on round \(currentRound) of \(totalRounds).")
            if currentRound > 1 {
                recipeLine = "Round 1 is done and worked (\(recipe.count) moves): \(Self.compactList(recipe)). Do the same steps again for the next one."
                if currentRound > 2 {
                    tailLines.append(laterRoundsLine())
                }
            }
            tailLines.append(thisRoundLine(emptyText: "This round: nothing done yet.", prefix: "This round so far"))
            tailLines.append(hasRoundsLeft
                ? "When this round is done, say so (\"this round is done\") and start round \(currentRound + 1)."
                : "This is the last round: when it's done, the whole job is done.")
        } else {
            headLines.append(thisRoundLine(emptyText: "Nothing has been done yet.", prefix: "Done so far, in order"))
        }
        let fixedText = (headLines + tailLines).joined(separator: "\n")
        guard let recipeLine else { return Self.clipped(fixedText, to: Self.maximumStateCharacters) }
        let roomForRecipe = Self.maximumStateCharacters - fixedText.count - 2
        guard roomForRecipe > 40 else { return Self.clipped(fixedText, to: Self.maximumStateCharacters) }
        return (headLines + [Self.clipped(recipeLine, to: roomForRecipe)] + tailLines).joined(separator: "\n")
    }

    /// Rounds 2 to the last finished one, short: how many and how long they took.
    private func laterRoundsLine() -> String {
        let keptMoveCount = recentRounds.reduce(0) { $0 + $1.count }
        let laterRoundCount = roundsForgotten + recentRounds.count
        let averageMoves = laterRoundCount > 0 ? Double(movesInForgottenRounds + keptMoveCount) / Double(laterRoundCount) : 0
        var line = "Rounds 2 to \(currentRound - 1) are done too (about \(Int(averageMoves.rounded())) moves each)."
        if let lastRound = recentRounds.last, !lastRound.isEmpty {
            line += " Round \(currentRound - 1) ended with: \(Self.compactList(Array(lastRound.suffix(3))))."
        }
        return line
    }

    private func thisRoundLine(emptyText: String, prefix: String) -> String {
        guard !movesThisRound.isEmpty else { return emptyText }
        let roundMoveCount = movesThisRound.count + movesDroppedThisRound
        let firstMoves = movesThisRound.prefix(Self.firstMovesKeptPerRound)
        let newestMoves = movesThisRound.suffix(Self.movesShownInFull - Self.firstMovesKeptPerRound)
        let hiddenMoveCount = roundMoveCount - firstMoves.count - newestMoves.count
        let keptList = movesThisRound.count <= Self.movesShownInFull && movesDroppedThisRound == 0
            ? movesThisRound.joined(separator: "; ")
            : firstMoves.joined(separator: "; ") + "; … \(hiddenMoveCount) more …; " + newestMoves.joined(separator: "; ")
        return isRepeatedJob ? "\(prefix): \(keptList)." : "\(prefix) (\(roundMoveCount) moves): \(keptList)."
    }

    private static func clipped(_ text: String, to characterLimit: Int) -> String {
        text.count > characterLimit ? String(text.prefix(max(characterLimit, 0))) + "…" : text
    }
}
