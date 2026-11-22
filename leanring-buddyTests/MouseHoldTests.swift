//
//  MouseHoldTests.swift
//  leanring-buddyTests
//
//  Holding the mouse down and letting go as two of Jev's moves: where
//  holds are offered, the moves while held, letting go somewhere else
//  needing a clear pick, and a press-hold-drop job in steps.
//

import Foundation
import Testing
@testable import Dottie

struct MouseHoldTests {
    private typealias Plan = DottieJevDriverPlan

    private let screenTexts = [
        Plan.ScreenText(text: "photo.jpg", centerX: 200, centerY: 300),
        Plan.ScreenText(text: "Trash", centerX: 900, centerY: 900)
    ]

    @Test func dragAndHoldRequestsOfferHoldingOnScreenTexts() {
        let moves = Plan.holdMoves(screenTexts: screenTexts, screenControls: [], taskText: "drag photo.jpg somewhere")
        #expect(moves.contains(.holdMouseDown(label: "photo.jpg", centerX: 200, centerY: 300)))
        #expect(moves.contains(.holdMouseDown(label: "Trash", centerX: 900, centerY: 900)))
    }

    @Test func slidersCanBeHeld() {
        let slider = Plan.ScreenControl(label: "Volume", kind: "slider", centerX: 500, centerY: 100)
        let moves = Plan.holdMoves(screenTexts: [], screenControls: [slider], taskText: "turn it up")
        #expect(moves == [.holdMouseDown(label: "Volume", centerX: 500, centerY: 100)])
    }

    @Test func holdsStayFewWhenTheRequestDoesntAskForThem() {
        let manyTexts = (0..<60).map { Plan.ScreenText(text: "Item \($0)", centerX: 100, centerY: Double($0 * 10)) }
        #expect(Plan.holdMoves(screenTexts: manyTexts, screenControls: [], taskText: "open the settings").count <= Plan.maximumDoubleAndRightClickTargets)
        #expect(Plan.holdMoves(screenTexts: manyTexts, screenControls: [], taskText: "press and hold the record button").count <= Plan.maximumHoldTargets)
    }

    @Test func whileHeldOnlyLettingGoIsOffered() {
        let options = Plan.optionsWhileHoldingMouse(heldLabel: "photo.jpg", screenTexts: screenTexts, screenControls: [], alreadyTriedSignatures: [])
        let moves = options.map(\.move)
        #expect(moves.first == .releaseMouseHere)
        #expect(moves.contains(.releaseMouseOn(label: "Trash", centerX: 900, centerY: 900)))
        // Not onto itself, and nothing but letting go (or handing over).
        #expect(!moves.contains(.releaseMouseOn(label: "photo.jpg", centerX: 200, centerY: 300)))
        #expect(moves.last == .noneFits)
        #expect(!moves.contains(.finished))
    }

    @Test func whileHeldStaysUnderJevsLimit() {
        let manyTexts = (0..<400).map { Plan.ScreenText(text: "Item \($0)", centerX: 100, centerY: Double($0)) }
        let options = Plan.optionsWhileHoldingMouse(heldLabel: "x", screenTexts: manyTexts, screenControls: [], alreadyTriedSignatures: [])
        #expect(options.count <= Plan.maximumOptions)
        #expect(options.last?.move == .noneFits)
        #expect(Set(options.map(\.key)).count == options.count)
    }

    @Test func lettingGoFarAwayIsADrop() {
        #expect(DottieMouseHoldPlan.releaseMovesTheHeldThing(heldX: 200, heldY: 300, releaseX: 900, releaseY: 900))
        #expect(!DottieMouseHoldPlan.releaseMovesTheHeldThing(heldX: 200, heldY: 300, releaseX: 205, releaseY: 302))
    }

    @Test func aDropNeedsAClearPick() {
        let unsureDrop = Plan.Answer(move: .releaseMouseOn(label: "Trash", centerX: 900, centerY: 900), probability: 0.3, confidence: 0.6, doneProbability: 0)
        #expect(Plan.decision(for: unsureDrop, heldMouseAt: (centerX: 200, centerY: 300)) == .unsure)
        let sureDrop = Plan.Answer(move: .releaseMouseOn(label: "Trash", centerX: 900, centerY: 900), probability: 0.7, confidence: 0.6, doneProbability: 0)
        #expect(Plan.decision(for: sureDrop, heldMouseAt: (centerX: 200, centerY: 300)) == .act(sureDrop.move))
        let letGoHere = Plan.Answer(move: .releaseMouseHere, probability: 0.3, confidence: 0.6, doneProbability: 0)
        #expect(Plan.decision(for: letGoHere, heldMouseAt: (centerX: 200, centerY: 300)) == .act(.releaseMouseHere))
    }

    @Test func holdingNeedsAClearPick() {
        #expect(Plan.movesNeedingClearPick(.holdMouseDown(label: "a", centerX: 1, centerY: 1)))
        #expect(!Plan.movesNeedingClearPick(.releaseMouseHere))
    }

    @Test func holdAndReleaseReadClearly() {
        let hold = Plan.Move.holdMouseDown(label: "photo.jpg", centerX: 1, centerY: 1)
        #expect(hold.description.contains("don't let go yet"))
        #expect(hold.summary == "pressed and held the mouse on photo.jpg")
        #expect(Plan.Move.releaseMouseOn(label: "Trash", centerX: 1, centerY: 1).summary == "moved what was held onto Trash and let go")
        #expect(hold.signature != Plan.Move.click(label: "photo.jpg", centerX: 1, centerY: 1).signature)
    }

    /// "Drag photo.jpg to the Trash" in two decisions: hold on the photo,
    /// look again, let go on the Trash.
    @Test func aDragInStepsHoldsThenDrops() throws {
        let taskText = "drag photo.jpg to the trash"
        var heldAt: (label: String, centerX: Double, centerY: Double)?
        var movesSoFar: [String] = []
        let wanted: [Plan.Move] = [.holdMouseDown(label: "photo.jpg", centerX: 200, centerY: 300), .releaseMouseOn(label: "Trash", centerX: 900, centerY: 900)]
        for wantedMove in wanted {
            let options = heldAt.map {
                Plan.optionsWhileHoldingMouse(heldLabel: $0.label, screenTexts: screenTexts, screenControls: [], alreadyTriedSignatures: [])
            } ?? Plan.options(screenTexts: screenTexts, textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [], taskText: taskText)
            let body = Plan.requestBody(goal: taskText, movesSoFar: movesSoFar, knownHowTo: "", options: options, isHoldingMouse: heldAt != nil)
            #expect(JSONSerialization.isValidJSONObject(body))
            if heldAt != nil { #expect((body["state"] as? String)?.contains("held down right now") == true) }
            let key = try #require(options.first { $0.move == wantedMove }?.key)
            let answerData = try JSONSerialization.data(withJSONObject: ["answers": [
                Plan.choiceQuestionName: ["choice": key, "probabilities": [key: 0.75], "confidence": 0.7],
                Plan.doneQuestionName: ["noul": 0.05]
            ]])
            let parsed = try #require(Plan.answer(fromAnswer: answerData, options: options))
            guard case .act(let move) = Plan.decision(for: parsed, heldMouseAt: heldAt.map { (centerX: $0.centerX, centerY: $0.centerY) }) else {
                Issue.record("a clear pick should act")
                return
            }
            if case .holdMouseDown(let label, let centerX, let centerY) = move { heldAt = (label, centerX, centerY) } else { heldAt = nil }
            movesSoFar.append(move.summary)
        }
        #expect(heldAt == nil)
        #expect(movesSoFar == ["pressed and held the mouse on photo.jpg", "moved what was held onto Trash and let go"])
    }
}
