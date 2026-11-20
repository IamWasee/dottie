//
//  TeachingStepLeniencyTests.swift
//  leanring-buddyTests
//
//  Tests for drawing what Live actually sends. "Explain supply and demand"
//  drew nothing in 1.0.75: every plan was refused by the step checker and
//  Live retried 35 times. Points written as "(300, 700)" or as lone
//  numbers now read, the steps that can be drawn are drawn even when one
//  can't be, and every refusal is saved with its reasons.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

@MainActor
struct TeachingStepLeniencyTests {
    private let board = CGRect(x: 0, y: 0, width: 600, height: 600)

    private func plan(_ steps: [[String: Any]]) -> DottieTeaching.Plan? {
        DottieTeaching.Plan(arguments: ["steps": steps])
    }

    private func pointsAreEqual(_ reference: String, _ expected: (Double, Double)) -> Bool {
        guard let numbers = DottieTeaching.pointNumbers(reference) else { return false }
        return numbers.0 == expected.0 && numbers.1 == expected.1
    }

    // MARK: - Reading a point

    @Test func theUsualStyleStillReads() {
        #expect(pointsAreEqual("300,700", (300, 700)))
        #expect(pointsAreEqual("300, 700", (300, 700)))
    }

    @Test func bracketsAndSpacesRead() {
        #expect(pointsAreEqual("(300, 700)", (300, 700)))
        #expect(pointsAreEqual("[300 700]", (300, 700)))
        #expect(pointsAreEqual("300 700", (300, 700)))
    }

    @Test func xAndYLabelsRead() {
        #expect(pointsAreEqual("x=300 y=700", (300, 700)))
        #expect(pointsAreEqual("x: 300, y: 700", (300, 700)))
    }

    @Test func decimalsAndNegativesRead() {
        #expect(pointsAreEqual("-5.5,10", (-5.5, 10)))
        #expect(pointsAreEqual("120.25, 880.75", (120.25, 880.75)))
    }

    @Test func oneOrThreeNumbersAreNotAPoint() {
        #expect(DottieTeaching.pointNumbers("300") == nil)
        #expect(DottieTeaching.pointNumbers("1,2,3") == nil)
        #expect(DottieTeaching.pointNumbers("") == nil)
    }

    @Test func wordsMeanANameNotAPoint() {
        #expect(DottieTeaching.pointNumbers("label2 top 5") == nil)
        #expect(DottieTeaching.pointNumbers("demand curve start") == nil)
    }

    // MARK: - Lone numbers

    @Test func loneNumbersArePairedUp() {
        #expect(DottieTeaching.pairingLoneNumbers(["300", "700", "500", "200"]) == ["300,700", "500,200"])
    }

    @Test func anOddCountOfLoneNumbersIsLeftAsGiven() {
        #expect(DottieTeaching.pairingLoneNumbers(["300", "700", "500"]) == ["300", "700", "500"])
    }

    @Test func pointsAlreadyInPairsAreLeftAsGiven() {
        #expect(DottieTeaching.pairingLoneNumbers(["300,700", "500,200"]) == ["300,700", "500,200"])
        #expect(DottieTeaching.pairingLoneNumbers(["circled", "500"]) == ["circled", "500"])
        #expect(DottieTeaching.pairingLoneNumbers(["500"]) == ["500"])
        #expect(DottieTeaching.pairingLoneNumbers([]) == [])
    }

    @Test func aPlanSentWithLoneNumbersHasNoProblems() throws {
        let lonePlan = try #require(plan([["kind": "line", "points": ["100", "900", "900", "100"]]]))
        #expect(lonePlan.steps[0].points == ["100,900", "900,100"])
        #expect(lonePlan.problems.isEmpty)
    }

    @Test func aPlanSentWithBracketedPointsHasNoProblems() throws {
        let bracketPlan = try #require(plan([["kind": "curve", "points": ["(150, 200)", "(500, 550)", "(850, 800)"]]]))
        #expect(bracketPlan.problems.isEmpty)
    }

    // MARK: - Where a point lands

    @Test func aBracketedPointLandsWhereThePlainOneDoes() {
        let space = DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { _, _ in nil })
        #expect(space.point("(250, 500)") == space.point("250,500"))
        #expect(space.point("250,500") == CGPoint(x: 150, y: 300))
    }

    @Test func anAnchorStillWinsOverNumbers() {
        let anchorFrame = CGRect(x: 10, y: 10, width: 20, height: 20)
        let space = DottieTeaching.Space(boardRect: board, anchorFrames: ["box1": anchorFrame], screenPoint: { _, _ in nil })
        #expect(space.point("box1") == CGPoint(x: 20, y: 20))
    }

    @Test func aWordThatIsNoAnchorLandsNowhere() {
        let space = DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { _, _ in nil })
        #expect(space.point("somewhere nice") == nil)
    }

    // MARK: - Drawing what can be drawn

    @Test func onlyTheBadStepIsLeftOut() throws {
        let mixedPlan = try #require(plan([
            ["kind": "axes", "points": ["100,900", "900,100"]],
            ["kind": "plot", "points": ["100,100", "900,900"], "text": "demand curve"],
            ["kind": "line", "points": ["150,200", "850,800"]]
        ]))
        #expect(mixedPlan.problems.count == 1)
        let drawablePlan = mixedPlan.keepingOnlyDrawableSteps()
        #expect(drawablePlan.steps.map(\.kind) == [.axes, .line])
        #expect(drawablePlan.problems.isEmpty)
        #expect(drawablePlan.surface == mixedPlan.surface)
    }

    @Test func aGoodPlanKeepsEveryStep() throws {
        let goodPlan = try #require(plan([["kind": "line", "points": ["150,200", "850,800"]], ["kind": "point", "points": ["500,500"]]]))
        #expect(goodPlan.keepingOnlyDrawableSteps().steps.count == 2)
    }

    @Test func aPlanWithNothingDrawableKeepsNoSteps() throws {
        let badPlan = try #require(plan([["kind": "curve", "points": ["somewhere", "elsewhere"]]]))
        #expect(badPlan.keepingOnlyDrawableSteps().steps.isEmpty)
    }

    // MARK: - Saving refusals

    @Test func aRefusalIsSavedWithItsReasons() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("refused-drawings.json")
        DottieTeaching.recordRefusedDrawing(problems: ["step 1 (curve): bad point"], arguments: ["steps": [["kind": "curve"]]],
                                            drewOtherSteps: false, into: fileURL)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]])
        #expect(saved.count == 1)
        #expect(saved[0]["problems"] as? [String] == ["step 1 (curve): bad point"])
        #expect(saved[0]["drewOtherSteps"] as? Bool == false)
        #expect(saved[0]["arguments"] != nil)
    }

    @Test func onlyTheLastFiftyRefusalsAreKept() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("refused-drawings.json")
        for index in 0..<55 {
            DottieTeaching.recordRefusedDrawing(problems: ["refusal \(index)"], arguments: [:], drewOtherSteps: true, into: fileURL)
        }
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]])
        #expect(saved.count == 50)
        #expect(saved.last?["problems"] as? [String] == ["refusal 54"])
        #expect(saved.first?["problems"] as? [String] == ["refusal 5"])
    }

    @Test func argumentsThatAreNotJSONAreLeftOutButTheRefusalIsKept() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("refused-drawings.json")
        DottieTeaching.recordRefusedDrawing(problems: ["x"], arguments: ["when": Date()], drewOtherSteps: false, into: fileURL)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]])
        #expect(saved.count == 1)
        #expect(saved[0]["arguments"] == nil)
    }

    // MARK: - Journey: supply and demand the way Live writes it

    @Test func supplyAndDemandIsDrawnEvenWithOneBadStep() throws {
        let livePlan = try #require(plan([
            ["kind": "axes", "points": ["(100, 900)", "(900, 100)"], "text": "Quantity, Price"],
            ["kind": "line", "points": ["150", "850", "850", "150"], "color": "blue", "text": "Supply"],
            ["kind": "line", "points": ["(150, 150)", "(850, 850)"], "color": "orange", "text": "Demand"],
            ["kind": "plot", "points": ["100,100", "900,900"], "text": "equilibrium"],
            ["kind": "point", "points": ["x=500 y=500"], "text": "E"]
        ]))
        #expect(livePlan.problems.count == 1, "only the concept plot is wrong")
        let drawablePlan = livePlan.keepingOnlyDrawableSteps()
        let space = DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { _, _ in nil })
        var drawnFigures: [DottieFigure] = []
        for step in drawablePlan.steps {
            let drawn = try #require(DottieTeaching.draw(step, in: space), "\(step.kind.rawValue) should draw")
            drawnFigures += drawn.figures
        }
        #expect(drawablePlan.steps.count == 4)
        #expect(drawnFigures.contains { $0.ink == .blue })
        #expect(drawnFigures.contains { $0.ink == .orange })
        #expect(drawnFigures.allSatisfy { board.insetBy(dx: -80, dy: -80).contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) })
    }

    // MARK: - Speed

    @Test func readingThousandsOfPointsIsQuick() {
        let startedAt = Date()
        var readCount = 0
        for index in 0..<10_000 where DottieTeaching.pointNumbers("(\(index % 1000), \(index % 700))") != nil {
            readCount += 1
        }
        #expect(readCount == 10_000)
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
