//
//  BoardLetteringTests.swift
//  leanring-buddyTests
//
//  Unit tests for the Cognito-style board: words in capitals, math and
//  color markings left exactly as written, the plain light pen by default,
//  and curves drawn at a steady, readable pace.
//

import CoreGraphics
import Testing
@testable import Dottie

@MainActor
struct BoardLetteringTests {

    @Test func wordsAreWrittenInCapitals() {
        #expect(DottieTeaching.boardLettering("Demand shifts left") == "DEMAND SHIFTS LEFT")
        #expect(DottieTeaching.boardLettering("Supply") == "SUPPLY")
    }

    @Test func mathAndNumbersStayExactlyAsWritten() {
        for mathText in ["x² + 1", "p = ¼x²", "5 cm", "40°", "y = 2x", "H₂O", "θ", "a/b", "f(x)"] {
            #expect(DottieTeaching.boardLettering(mathText) == mathText, "\(mathText) must not change")
        }
    }

    @Test func singleLettersAndMarkingsStayAsWritten() {
        #expect(DottieTeaching.boardLettering("x") == "x")
        #expect(DottieTeaching.boardLettering("A") == "A")
        #expect(DottieTeaching.boardLettering("x y") == "x y")
        #expect(DottieTeaching.boardLettering("{red:key part}") == "{red:key part}")
        #expect(DottieTeaching.boardLettering("**bold** words") == "**bold** words")
        #expect(DottieTeaching.boardLettering("") == "")
    }

    @Test func aTextStepIsDrawnInCapitalsWithTheLightPen() {
        guard let plan = DottieTeaching.Plan(arguments: ["steps": [["kind": "text", "points": ["100,100"], "text": "Equilibrium"]]]) else {
            Issue.record("the plan should parse")
            return
        }
        let space = DottieTeaching.Space(boardRect: CGRect(x: 0, y: 0, width: 600, height: 600), anchorFrames: [:], screenPoint: { _, _ in nil })
        let drawn = DottieTeaching.draw(plan.steps[0], in: space)
        guard case .text(let writtenText, _, _) = drawn?.figures.first?.shape else {
            Issue.record("a text step writes text")
            return
        }
        #expect(writtenText == "EQUILIBRIUM")
        #expect(drawn?.figures.first?.ink == .white)
    }

    @Test func aColorGivenForMeaningIsKept() {
        let plan = DottieTeaching.Plan(arguments: ["steps": [["kind": "line", "points": ["100,100", "500,500"], "color": "blue"]]])!
        let space = DottieTeaching.Space(boardRect: CGRect(x: 0, y: 0, width: 600, height: 600), anchorFrames: [:], screenPoint: { _, _ in nil })
        #expect(DottieTeaching.draw(plan.steps[0], in: space)?.figures.first?.ink == .blue)
    }

    @Test func curvesAreDrawnAtAboutThreeHundredThirtyPointsASecond() {
        let longLine = [CGPoint(x: 0, y: 0), CGPoint(x: 330, y: 0)]
        #expect(abs(DottieTeaching.DrawnStep.penDuration(longLine) - 1) < 0.01)
        // Tiny marks still take a moment, and long ones are capped.
        #expect(DottieTeaching.DrawnStep.penDuration([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0)]) == 0.3)
        #expect(DottieTeaching.DrawnStep.penDuration([CGPoint(x: 0, y: 0), CGPoint(x: 5_000, y: 0)]) == 2.4)
    }
}
