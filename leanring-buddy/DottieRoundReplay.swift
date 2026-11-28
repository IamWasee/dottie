//
//  DottieRoundReplay.swift
//  leanring-buddy
//
//  Rounds 2 to N of a repeated job done from round 1's own moves. Wasee
//  (28 Nov): adding 3 patients took 9 minutes, about 100 Jev steps, because
//  every round asked Jev again for the moves it had just made. Now round 1's
//  recorded steps are done again for each later round with that round's
//  details ("(2) John Smith, 02/03/1985" types John where round 1 typed
//  Jane), with no model call per step. A step whose words can't be placed
//  is Jev's to take; a step that doesn't fit the screen hands the rest of
//  that round to Jev, and the next round tries the steps again. Foundation
//  only, so it can be unit tested.
//

import Foundation

enum DottieRoundReplayPlan {
    /// A repeated job's request: what every round shares, and one piece of
    /// details per round, in order.
    struct RoundItems: Equatable {
        let sharedText: String
        let items: [String]
    }

    /// Round 1 needs at least this many steps to be worth doing again.
    static let minimumStepsToReplay = 2

    // MARK: Splitting the request into rounds

    /// The details for each round: a numbered list ("(1) … (2) …"), else a
    /// list after a colon with one per line, one per ";" or one per comma.
    /// Nil when the request has no list with exactly one piece per round.
    static func roundItems(in taskText: String, totalRounds: Int) -> RoundItems? {
        guard totalRounds >= 2 else { return nil }
        if let numberedRoundItems = numberedItems(in: taskText), numberedRoundItems.items.count == totalRounds {
            return numberedRoundItems
        }
        guard let colonIndex = taskText.firstIndex(of: ":") else { return nil }
        let sharedText = String(taskText[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let listText = String(taskText[taskText.index(after: colonIndex)...])
        for separatorPattern in [#"\s*\n\s*"#, #"\s*;\s*"#, #"\s*,\s*(?:and\s+)?|\s+and\s+"#] {
            let pieces = split(listText, byPattern: separatorPattern)
            if pieces.count == totalRounds { return RoundItems(sharedText: sharedText, items: pieces) }
        }
        return nil
    }

    /// "(1) Jane Doe (2) John Smith": the text after each marker, numbered
    /// 1, 2, 3… in order; the shared text is what comes before the first.
    private static func numberedItems(in taskText: String) -> RoundItems? {
        guard let markerExpression = try? NSRegularExpression(pattern: #"(?:^|[\s:;,])\(?(\d{1,2})\)\s"#) else { return nil }
        let fullRange = NSRange(taskText.startIndex..., in: taskText)
        var markerRanges: [Range<String.Index>] = []
        for match in markerExpression.matches(in: taskText, range: fullRange) {
            guard let markerRange = Range(match.range, in: taskText),
                  let numberRange = Range(match.range(at: 1), in: taskText),
                  let markerNumber = Int(taskText[numberRange]) else { continue }
            // Only the run 1, 2, 3…: a stray "(5) " elsewhere isn't a round.
            guard markerNumber == markerRanges.count + 1 else { continue }
            markerRanges.append(markerRange)
        }
        guard markerRanges.count >= 2 else { return nil }
        var items: [String] = []
        for (markerIndex, markerRange) in markerRanges.enumerated() {
            let itemEnd = markerIndex + 1 < markerRanges.count ? markerRanges[markerIndex + 1].lowerBound : taskText.endIndex
            items.append(tidiedItem(String(taskText[markerRange.upperBound..<itemEnd])))
        }
        guard !items.contains(where: \.isEmpty) else { return nil }
        let sharedText = String(taskText[..<markerRanges[0].lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return RoundItems(sharedText: sharedText, items: items)
    }

    private static func split(_ listText: String, byPattern separatorPattern: String) -> [String] {
        guard let separatorExpression = try? NSRegularExpression(pattern: separatorPattern) else { return [] }
        let markedText = separatorExpression.stringByReplacingMatches(
            in: listText, range: NSRange(listText.startIndex..., in: listText), withTemplate: "\u{1F}"
        )
        return markedText.components(separatedBy: "\u{1F}").map(tidiedItem).filter { !$0.isEmpty }
    }

    /// Spaces, list punctuation and a dangling "and" taken off the ends.
    private static func tidiedItem(_ itemText: String) -> String {
        var tidiedText = itemText.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t,;.").union(.whitespacesAndNewlines))
        while tidiedText.lowercased().hasSuffix(" and") {
            tidiedText = String(tidiedText.dropLast(4)).trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        }
        return tidiedText
    }

    // MARK: Round k's words where round 1's were

    /// What round k types or clicks where round 1 used `roundOneText`: the
    /// words at the same spot in round k's details ("Doe" in "Jane Doe,
    /// 01/01/1990" → "Smith" in "John Smith, 02/03/1985"), or nil when
    /// they can't be placed.
    static func valueForRound(_ roundOneText: String, roundOneItem: String, roundItem: String) -> String? {
        let typedWords = words(of: roundOneText)
        guard !typedWords.isEmpty else { return nil }
        let roundOneParts = parts(of: roundOneItem)
        let roundParts = parts(of: roundItem)
        if roundOneParts.count == roundParts.count {
            for (partIndex, roundOnePart) in roundOneParts.enumerated() {
                let roundOneWords = words(of: roundOnePart)
                guard let typedRange = range(of: typedWords, in: roundOneWords) else { continue }
                return valueAtSameSpot(typedRange, roundOneWords: roundOneWords, roundWords: words(of: roundParts[partIndex]))
            }
        }
        // The details are shaped differently: the same spot across all of them.
        let roundOneWords = words(of: roundOneItem)
        guard let typedRange = range(of: typedWords, in: roundOneWords) else { return nil }
        return valueAtSameSpot(typedRange, roundOneWords: roundOneWords, roundWords: words(of: roundItem))
    }

    /// The same spot in round k's words. With as many words, the same
    /// positions; otherwise words both rounds share at the ends ("DOB",
    /// "phone") stay put and the value between them moves: the whole
    /// value, or its first or last word.
    private static func valueAtSameSpot(_ typedRange: Range<Int>, roundOneWords: [String], roundWords: [String]) -> String? {
        guard !roundWords.isEmpty else { return nil }
        if roundOneWords.count == roundWords.count {
            return roundWords[typedRange].joined(separator: " ")
        }
        let sharedLeadingCount = zip(roundOneWords, roundWords).prefix { $0.lowercased() == $1.lowercased() }.count
        let roomForTrailing = min(roundOneWords.count, roundWords.count) - sharedLeadingCount
        let sharedTrailingCount = zip(roundOneWords.reversed(), roundWords.reversed())
            .prefix(roomForTrailing)
            .prefix { $0.lowercased() == $1.lowercased() }.count
        let roundOneValueRange = sharedLeadingCount..<(roundOneWords.count - sharedTrailingCount)
        let roundValueRange = sharedLeadingCount..<(roundWords.count - sharedTrailingCount)
        guard !roundOneValueRange.isEmpty, !roundValueRange.isEmpty,
              typedRange.lowerBound >= roundOneValueRange.lowerBound, typedRange.upperBound <= roundOneValueRange.upperBound else { return nil }
        if typedRange == roundOneValueRange { return roundWords[roundValueRange].joined(separator: " ") }
        if typedRange.count == 1, typedRange.lowerBound == roundOneValueRange.lowerBound { return roundWords[roundValueRange.lowerBound] }
        if typedRange.count == 1, typedRange.upperBound == roundOneValueRange.upperBound { return roundWords[roundValueRange.upperBound - 1] }
        return nil
    }

    /// One round's details cut at commas, semicolons and new lines.
    private static func parts(of itemText: String) -> [String] {
        itemText.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Words as written, with the punctuation around them taken off
    /// (inside stays: 01/01/1990, jane@example.com, 555-1234).
    static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",;:.!?()[]{}\"'“”‘’")) }
            .filter { !$0.isEmpty }
    }

    private static func range(of searchedWords: [String], in allWords: [String]) -> Range<Int>? {
        guard !searchedWords.isEmpty, searchedWords.count <= allWords.count else { return nil }
        let lowercasedSearched = searchedWords.map { $0.lowercased() }
        let lowercasedAll = allWords.map { $0.lowercased() }
        for start in 0...(lowercasedAll.count - lowercasedSearched.count)
        where Array(lowercasedAll[start..<(start + lowercasedSearched.count)]) == lowercasedSearched {
            return start..<(start + lowercasedSearched.count)
        }
        return nil
    }

    private static func contains(_ text: String, wordsOf searchedText: String) -> Bool {
        range(of: words(of: searchedText), in: words(of: text)) != nil
    }

    // MARK: Round k's steps

    /// Where a piece of round 1's text goes in round k.
    enum Placement: Equatable {
        /// Every round uses the same words (from the shared part, or a job
        /// with no list: "search cats 3 times").
        case same
        /// Round k's own words at that spot.
        case value(String)
        /// Round 1's details, but round k's can't be placed: Jev picks.
        case unknown
    }

    static func placement(of roundOneText: String, round: Int, roundItems: RoundItems?, isTyped: Bool) -> Placement {
        guard let roundItems, round >= 2, round <= roundItems.items.count else { return .same }
        let roundOneItem = roundItems.items[0]
        let roundItem = roundItems.items[round - 1]
        if contains(roundItems.sharedText, wordsOf: roundOneText) { return .same }
        guard contains(roundOneItem, wordsOf: roundOneText) else {
            // Typed words the request never said (a model wrote them for
            // round 1's details) can't be trusted for round k; a click on a
            // button's own words is the same every round.
            return isTyped ? .unknown : .same
        }
        // A word that's in every round's details ("female" both times) stays.
        if contains(roundItem, wordsOf: roundOneText) { return .same }
        return valueForRound(roundOneText, roundOneItem: roundOneItem, roundItem: roundItem).map(Placement.value) ?? .unknown
    }

    /// Round 1's steps with round k's words: typed text from round 1's
    /// details becomes round k's (or nothing, so Jev types it), and a click
    /// on round 1's details ("Jane Doe" in a list) clicks round k's (or
    /// has no label, so Jev picks it).
    static func steps(_ roundOneSteps: [DottieAppTaskStep], forRound round: Int, roundItems: RoundItems?) -> [DottieAppTaskStep] {
        roundOneSteps.map { roundOneStep in
            switch roundOneStep.kind {
            case .typeIntoField, .typeText, .searchWeb:
                guard let roundOneText = roundOneStep.text, !roundOneText.isEmpty else { return roundOneStep }
                let roundText: String?
                switch placement(of: roundOneText, round: round, roundItems: roundItems, isTyped: true) {
                case .same: roundText = roundOneText
                case .value(let roundValue): roundText = roundValue
                case .unknown: roundText = nil
                }
                return copy(of: roundOneStep, label: roundOneStep.label, text: roundText)
            case .click, .doubleClick, .rightClick, .hover:
                // One letter or a number ("1", "M") could be anything on screen.
                guard roundOneStep.label.count >= 2, roundOneStep.label.rangeOfCharacter(from: .letters) != nil else { return roundOneStep }
                switch placement(of: roundOneStep.label, round: round, roundItems: roundItems, isTyped: false) {
                case .same: return roundOneStep
                case .value(let roundValue): return copy(of: roundOneStep, label: roundValue, text: roundOneStep.text)
                case .unknown: return copy(of: roundOneStep, label: "", text: roundOneStep.text)
                }
            default:
                return roundOneStep
            }
        }
    }

    private static func copy(of step: DottieAppTaskStep, label: String, text: String?) -> DottieAppTaskStep {
        // The words are already round k's: nothing left to swap in from the request.
        DottieAppTaskStep(kind: step.kind, label: label, role: step.role, centerX: step.centerX, centerY: step.centerY,
                          text: text, textCameFromRequest: false, pressesReturn: step.pressesReturn, pageTitle: step.pageTitle)
    }

    /// Round k as a task the saved-task replay can do step by step, or nil
    /// when round 1 left too few steps.
    static func roundTask(
        roundOneSteps: [DottieAppTaskStep], round: Int, totalRounds: Int, taskText: String,
        appName: String, places: [String], now: Date
    ) -> DottieAppTask? {
        guard round >= 2, round <= totalRounds, roundOneSteps.count >= minimumStepsToReplay else { return nil }
        let roundSteps = steps(roundOneSteps, forRound: round, roundItems: roundItems(in: taskText, totalRounds: totalRounds))
        return DottieAppTask(
            id: UUID(), name: "round \(round) of \(totalRounds)", purpose: "", doneWhen: "", tips: [],
            appName: appName, places: places, exampleRequests: [taskText], steps: roundSteps, stepsRecordedFor: taskText,
            finalPageTitle: nil, timesRun: 0, timesSucceeded: 0, problems: [], createdAt: now, lastUsed: now, isNamed: false
        )
    }

    /// After a replayed step typed into a box: the box being selected and
    /// still empty means the typing went nowhere, so the round goes to Jev.
    static func typingWentNowhere(focusedFieldValue: String?) -> Bool {
        guard let focusedFieldValue else { return false }
        return focusedFieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
