//
//  DottieFormFill.swift
//  leanring-buddy
//
//  A form's boxes filled in one go. Adding a patient was eight or more Jev
//  steps, each a screenshot, a Jev call and a wait, for boxes whose values
//  were already known (the speed review, 28 Nov). The text-writing call
//  that runs as a job starts (DottieJevTextPieces) now also names each box
//  and its value ("BOX First Name = Jane"); once two or more of them match
//  text boxes on screen, Dottie types them all straight away without
//  asking Jev, each kept as its own step so later rounds replay it. Never
//  for password, card or code boxes. Foundation only, so it can be unit
//  tested.
//

import Foundation

enum DottieFormFillPlan {
    /// One box of a form and what goes in it.
    struct FormBox: Equatable {
        let label: String
        let value: String
    }

    /// A box to fill now: the box as written and the text box on screen.
    struct BoxToFill: Equatable {
        let box: FormBox
        let control: DottieJevDriverPlan.ScreenControl
    }

    static let maximumBoxes = 12
    static let maximumValueLength = 200
    /// One box isn't worth skipping Jev for; two or more are.
    static let minimumBoxesToFillAtOnce = 2

    /// Boxes never filled from a written list, whatever the model wrote.
    private static let privateBoxWords = ["password", "passcode", "pin", "cvv", "cvc", "security code", "card number", "otp",
                                          "one time code", "verification code", "2fa"]

    /// "BOX First Name = Jane" lines out of the writing call's answer.
    static func formBoxes(fromAnswer answerText: String) -> [FormBox] {
        var seenLabels = Set<String>()
        var boxes: [FormBox] = []
        for line in answerText.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.uppercased().hasPrefix("BOX "), let equalsIndex = trimmedLine.firstIndex(of: "=") else { continue }
            let label = trimmedLine[trimmedLine.index(trimmedLine.startIndex, offsetBy: 4)..<equalsIndex]
                .trimmingCharacters(in: CharacterSet(charactersIn: " :\"'"))
            let value = trimmedLine[trimmedLine.index(after: equalsIndex)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
            guard !label.isEmpty, !value.isEmpty, value.count <= maximumValueLength, !isPrivateBox(label),
                  seenLabels.insert(DottieAppMemoryPlan.comparableWords(label)).inserted else { continue }
            boxes.append(FormBox(label: label, value: value))
            if boxes.count == maximumBoxes { break }
        }
        return boxes
    }

    static func isPrivateBox(_ label: String) -> Bool {
        let comparableLabel = " " + DottieAppMemoryPlan.comparableWords(label) + " "
        return privateBoxWords.contains { comparableLabel.contains(" " + $0 + " ") }
    }

    /// The written boxes that match text boxes on this screen (each text box
    /// used once, the closest label wins), top to bottom and left to right;
    /// empty unless at least two match. Boxes already filled this round are
    /// left out.
    static func boxesToFill(
        formBoxes: [FormBox], screenControls: [DottieJevDriverPlan.ScreenControl], alreadyFilledLabels: Set<String>
    ) -> [BoxToFill] {
        let textBoxes = screenControls.filter { $0.kind == "text box" && !isPrivateBox($0.label) }
        var usedControlIndices = Set<Int>()
        var matches: [BoxToFill] = []
        for box in formBoxes where !alreadyFilledLabels.contains(DottieAppMemoryPlan.comparableWords(box.label)) {
            var best: (index: Int, score: Double)?
            for (controlIndex, control) in textBoxes.enumerated() where !usedControlIndices.contains(controlIndex) {
                let score = DottieLooseLabels.similarity(box.label, control.label)
                guard score >= DottieLooseLabels.sameControlScore else { continue }
                if let currentBest = best, currentBest.score >= score { continue }
                best = (controlIndex, score)
            }
            guard let best else { continue }
            usedControlIndices.insert(best.index)
            matches.append(BoxToFill(box: box, control: textBoxes[best.index]))
        }
        guard matches.count >= minimumBoxesToFillAtOnce else { return [] }
        // Rows within 15 (of 1000) count as one row, read left to right.
        return matches.sorted { first, second in
            if abs(first.control.centerY - second.control.centerY) > 15 { return first.control.centerY < second.control.centerY }
            return first.control.centerX < second.control.centerX
        }
    }

    /// The model's instructions for naming the boxes, added to the
    /// text-writing prompt for jobs that look like they fill in a form.
    static let promptAddition = """
    If the job fills in a form, also write one line per box as BOX <the box's name as the form shows it> = <what goes in it>, \
    for example BOX First Name = Jane. Only boxes the user gave values for; for a job that repeats for several people or \
    items, only the first one's boxes. Never a password, card number or code.
    """
}
