//
//  BoardLetteringTests.swift
//  leanring-buddyTests
//
//  Unit tests for the Cognito-style board: words, math and color markings
//  written exactly as given (no capitals), the plain light pen by default,
//  and curves drawn at a steady, readable pace.
//

import CoreGraphics
import Testing
@testable import Dottie

@MainActor
struct BoardLetteringTests {

    /// Capitals read as shouting in celly's screenshots, so board words are
    /// written exactly as the model sent them.
    @Test func boardWordsAreWrittenAsGivenNotInCapitals() {
        for writtenText in ["Equilibrium", "Demand shifts left", "x² + 1", "{red:key part}", "**bold** words"] {
            guard let plan = DottieTeaching.Plan(arguments: ["steps": [["kind": "text", "points": ["100,100"], "text": writtenText]]]) else {
                Issue.record("the plan should parse")
                return
            }
            let space = DottieTeaching.Space(boardRect: CGRect(x: 0, y: 0, width: 600, height: 600), anchorFrames: [:], screenPoint: { _, _ in nil })
            guard case .text(let drawnText, _, _) = DottieTeaching.draw(plan.steps[0], in: space)?.figures.first?.shape else {
                Issue.record("a text step writes text")
                return
            }
            #expect(drawnText == DottieMathText.pretty(writtenText))
        }
    }

    @Test func aTextStepIsDrawnWithTheLightPen() {
        let plan = DottieTeaching.Plan(arguments: ["steps": [["kind": "text", "points": ["100,100"], "text": "Equilibrium"]]])!
        let space = DottieTeaching.Space(boardRect: CGRect(x: 0, y: 0, width: 600, height: 600), anchorFrames: [:], screenPoint: { _, _ in nil })
        #expect(DottieTeaching.draw(plan.steps[0], in: space)?.figures.first?.ink == .white)
    }

    @Test func aLabelOfACurveIsWrittenAsGiven() {
        let plan = DottieTeaching.Plan(arguments: ["steps": [["kind": "curve", "points": ["100,800", "500,400", "900,200"], "text": "Demand"]]])!
        let space = DottieTeaching.Space(boardRect: CGRect(x: 0, y: 0, width: 600, height: 600), anchorFrames: [:], screenPoint: { _, _ in nil })
        let texts = DottieTeaching.draw(plan.steps[0], in: space)?.figures.compactMap { figure -> String? in
            if case .text(let text, _, _) = figure.shape { return text }
            return nil
        }
        #expect(texts == ["Demand"])
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
