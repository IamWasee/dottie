//
//  TeachingBoardTests.swift
//  leanring-buddyTests
//
//  Unit tests for the drawing board: steps that can't be drawn are caught
//  before Dottie says she drew them, graphs open on a board, the board can
//  be resized with what's on it, and labels don't print over each other.
//

import CoreGraphics
import Testing
@testable import Dottie

@MainActor
struct TeachingBoardTests {

    private func plan(_ steps: [[String: Any]], extra: [String: Any] = [:]) -> DottieTeaching.Plan? {
        var arguments: [String: Any] = ["steps": steps]
        arguments.merge(extra) { _, new in new }
        return DottieTeaching.Plan(arguments: arguments)
    }

    @Test func aConceptGraphAsPlotIsRefused() {
        let demandPlan = plan([["kind": "plot", "points": ["100,100", "900,900"], "text": "demand"]])
        #expect(demandPlan?.problems.count == 1)
        #expect(demandPlan?.problems.first?.contains("function of x") == true)
    }

    @Test func aRealFunctionAndGoodStepsPass() {
        let goodPlan = plan([
            ["kind": "axes", "points": ["100,900", "900,100"], "text": "Quantity, Price"],
            ["kind": "plot", "points": ["100,100", "900,900"], "text": "2x + 1"],
            ["kind": "line", "points": ["150,200", "850,800"]],
            ["kind": "text", "points": ["860,800"], "text": "Demand"]
        ])
        #expect(goodPlan?.problems.isEmpty == true)
    }

    @Test func pointsThatAreNeitherNumbersNorAnchorsAreRefused() {
        let vaguePlan = plan([["kind": "curve", "points": ["demand curve start", "500,500"]]])
        #expect(vaguePlan?.problems.first?.contains("demand curve start") == true)
        let anchoredPlan = plan([["kind": "box", "points": ["title.left"]]],
                                extra: ["anchors": [["name": "title", "describe": "the page title"]]])
        #expect(anchoredPlan?.problems.isEmpty == true)
    }

    @Test func tooFewPointsAreRefused() {
        #expect(plan([["kind": "angle", "points": ["500,500", "600,500"]]])?.problems.count == 1)
        #expect(plan([["kind": "chart", "points": ["100,100", "900,900"], "text": "lots of sales"]])?.problems.count == 1)
    }

    @Test func graphsOpenOnABoardUnlessTheyMarkTheScreen() {
        #expect(plan([["kind": "chart", "points": ["100,100", "900,900"], "text": "Mon: 3; Tue: 5"]])?.surface == .board_right)
        #expect(plan([["kind": "chart", "points": ["circled.right", "900,900"], "text": "circled"]])?.surface == .screen)
        #expect(plan([["kind": "arrow", "points": ["100,100", "900,900"]]])?.surface == .screen)
        #expect(plan([["kind": "grid", "points": ["100,100", "900,900"]]], extra: ["surface": "board_left"])?.surface == .board_left)
    }

    @Test func resizingOnlyNeedsNoSteps() {
        #expect(plan([], extra: ["add_to_last": true, "board_size": "bigger"])?.boardSize == .bigger)
        #expect(plan([], extra: ["board_size": "bigger"]) == nil)
    }

    @Test func aBiggerBoardStaysOnTheScreen() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let currentBoard = CGRect(x: 1000, y: 200, width: 400, height: 400)
        let biggerBoard = DottieTeaching.BoardSize.bigger.resized(currentBoard, usualBoardSide: 600, on: visibleFrame)
        #expect(abs(biggerBoard.width - 520) < 0.5)
        #expect(biggerBoard.maxX <= visibleFrame.maxX - 24 + 0.5)
        let fullBoard = DottieTeaching.BoardSize.full.resized(currentBoard, usualBoardSide: 600, on: visibleFrame)
        #expect(abs(fullBoard.height - (875 - 48)) < 0.5)
        #expect(fullBoard.minY >= 24 - 0.5)
    }

    @Test func refittingMovesADrawingWithItsBoard() {
        let oldBoard = CGRect(x: 100, y: 100, width: 200, height: 200)
        let newBoard = CGRect(x: 0, y: 0, width: 400, height: 400)
        let line = DottieFigure(shape: .stroke(points: [CGPoint(x: 200, y: 200)], closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false))
        guard case .stroke(let points, _, _, _, _, _) = line.refitted(from: oldBoard, to: newBoard).shape else {
            Issue.record("a stroke stays a stroke")
            return
        }
        #expect(points == [CGPoint(x: 200, y: 200)])
        guard case .board(let rect) = DottieFigure(shape: .board(rect: oldBoard)).refitted(from: oldBoard, to: newBoard).shape else {
            Issue.record("a board stays a board")
            return
        }
        #expect(rect == newBoard)
    }

    @Test func aLabelOnTopOfAnotherMovesDown() {
        var drawn = DottieTeaching.DrawnStep()
        drawn.addText("Demand shifts left", origin: CGPoint(x: 100, y: 500), fontSize: 26, ink: .gold)
        let occupied = [CGRect(x: 90, y: 480, width: 300, height: 40)]
        let nudged = DottieTeaching.nudgedClearOfText(drawn, occupiedTextRects: occupied)
        guard case .text(_, let origin, _) = nudged.figures[0].shape else {
            Issue.record("text stays text")
            return
        }
        #expect(origin.y < 500)
        let nudgedRect = nudged.figures[0].bounds.insetBy(dx: 0, dy: nudged.figures[0].bounds.height * 0.2)
        #expect(!occupied[0].intersects(nudgedRect))
        let untouched = DottieTeaching.nudgedClearOfText(drawn, occupiedTextRects: [CGRect(x: 900, y: 900, width: 10, height: 10)])
        guard case .text(_, let untouchedOrigin, _) = untouched.figures[0].shape else { return }
        #expect(untouchedOrigin.y == 500)
    }
}
