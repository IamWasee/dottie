//
//  TeachingJourneyTests.swift
//  leanring-buddyTests
//
//  End-to-end journeys for the drawing board, from the arguments Live
//  sends for explain_on_screen to the figures that land on the board,
//  the way CompanionManager runs them: check the plan, pick the board,
//  draw each step, move labels off each other, resize later. The real
//  overlay window and the cursor aren't part of it.
//

import CoreGraphics
import Testing
@testable import Dottie

@MainActor
struct TeachingJourneyTests {
    private let laptopScreen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    /// Draws a plan the way CompanionManager.runTeaching does: on its
    /// board, text steps moved clear of earlier text.
    private func drawAll(_ plan: DottieTeaching.Plan, on board: CGRect?) -> (figures: [DottieFigure], missedSteps: Int) {
        let space = DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { normalizedX, normalizedY in
            CGPoint(x: normalizedX / 1000 * 1440, y: 875 - normalizedY / 1000 * 875)
        })
        var figures: [DottieFigure] = []
        var occupiedTextRects: [CGRect] = []
        var missedSteps = 0
        for step in plan.steps {
            guard var drawn = DottieTeaching.draw(step, in: space) else {
                missedSteps += 1
                continue
            }
            if step.kind == .text {
                drawn = DottieTeaching.nudgedClearOfText(drawn, occupiedTextRects: occupiedTextRects)
            }
            for figure in drawn.figures {
                if case .text = figure.shape {
                    occupiedTextRects.append(figure.bounds.insetBy(dx: 0, dy: figure.bounds.height * 0.2))
                }
            }
            figures += drawn.figures
        }
        return (figures, missedSteps)
    }

    private func textRects(_ figures: [DottieFigure]) -> [CGRect] {
        figures.compactMap { figure in
            guard case .text = figure.shape else { return nil }
            return figure.bounds.insetBy(dx: 0, dy: figure.bounds.height * 0.2)
        }
    }

    /// The supply-and-demand ask from the user's screenshot: two labels
    /// placed on the same spot, which used to print over each other.
    private let demandShiftArguments: [String: Any] = [
        "steps": [
            ["kind": "axes", "points": ["100,900", "900,100"], "text": "Quantity, Price"],
            ["kind": "line", "points": ["150,200", "850,800"], "color": "blue"],
            ["kind": "text", "points": ["860,800"], "text": "Demand"],
            ["kind": "line", "points": ["150,800", "850,200"], "color": "green"],
            ["kind": "text", "points": ["860,200"], "text": "Supply"],
            ["kind": "arrow", "points": ["500,450", "380,450"], "color": "red"],
            ["kind": "text", "points": ["300,350"], "text": "Demand shifts left"],
            ["kind": "text", "points": ["300,350"], "text": "Price and quantity fall"]
        ]
    ]

    @Test func aSupplyAndDemandGraphLandsWholeOnABoardWithLabelsApart() {
        guard let plan = DottieTeaching.Plan(arguments: demandShiftArguments) else {
            Issue.record("the plan should parse")
            return
        }
        #expect(plan.problems.isEmpty)
        #expect(plan.surface == .board_right)
        let board = plan.surface.boardRect(on: laptopScreen, sizeScale: plan.boardSize?.scaleFromUsualSize ?? 1)
        #expect(board != nil)
        let result = drawAll(plan, on: board)
        #expect(result.missedSteps == 0)
        let strokeCount = result.figures.filter { if case .stroke = $0.shape { return true } else { return false } }.count
        // Two axis arrows, two curves and the shift arrow.
        #expect(strokeCount >= 5)
        let labels = textRects(result.figures)
        for firstIndex in labels.indices {
            for secondIndex in labels.indices where secondIndex > firstIndex {
                #expect(!labels[firstIndex].intersects(labels[secondIndex]), "labels \(firstIndex) and \(secondIndex) overlap")
            }
        }
    }

    @Test func aConceptPlotIsRefusedBeforeAnythingIsDrawnAndTheFixedPlanDraws() {
        let refusedPlan = DottieTeaching.Plan(arguments: ["steps": [
            ["kind": "axes", "points": ["100,900", "900,100"]],
            ["kind": "plot", "points": ["100,100", "900,900"], "text": "demand curve"]
        ]])
        #expect(refusedPlan?.problems.count == 1)
        #expect(refusedPlan?.problems.first?.contains("axes and then line or curve") == true)

        // What Live sends back after reading the reason.
        let fixedPlan = DottieTeaching.Plan(arguments: ["steps": [
            ["kind": "axes", "points": ["100,900", "900,100"]],
            ["kind": "curve", "points": ["150,200", "500,550", "850,800"]],
            ["kind": "text", "points": ["860,800"], "text": "Demand"]
        ]])!
        #expect(fixedPlan.problems.isEmpty)
        let result = drawAll(fixedPlan, on: fixedPlan.surface.boardRect(on: laptopScreen))
        #expect(result.missedSteps == 0)
        #expect(!result.figures.isEmpty)
    }

    @Test func aRealFunctionGraphDrawsItsCurveAndName() {
        let functionPlan = DottieTeaching.Plan(arguments: ["steps": [
            ["kind": "plot", "points": ["100,100", "900,900"], "text": "x^2 - 3", "range": [-5, 5, -5, 25]]
        ]])!
        #expect(functionPlan.surface == .board_right)
        let result = drawAll(functionPlan, on: functionPlan.surface.boardRect(on: laptopScreen))
        #expect(result.missedSteps == 0)
        #expect(textRects(result.figures).count == 1)
    }

    @Test func aGraphAskedForBigOpensABiggerBoardThenGrowsAndShrinksWithItsDrawing() {
        let bigPlan = DottieTeaching.Plan(arguments: [
            "steps": [["kind": "grid", "points": ["100,100", "900,900"]]],
            "board_size": "large"
        ])!
        let usualBoard = bigPlan.surface.boardRect(on: laptopScreen)!
        let bigBoard = bigPlan.surface.boardRect(on: laptopScreen, sizeScale: bigPlan.boardSize!.scaleFromUsualSize)!
        #expect(bigBoard.width > usualBoard.width)
        let drawing = drawAll(bigPlan, on: bigBoard).figures + [DottieFigure(shape: .board(rect: bigBoard))]

        // "make it smaller": add_to_last with only a board size.
        let resizePlan = DottieTeaching.Plan(arguments: ["steps": [], "add_to_last": true, "board_size": "smaller"])!
        #expect(resizePlan.steps.isEmpty)
        let smallerBoard = resizePlan.boardSize!.resized(bigBoard, usualBoardSide: usualBoard.width, on: laptopScreen)
        #expect(smallerBoard.width < bigBoard.width)
        let refitted = drawing.map { $0.refitted(from: bigBoard, to: smallerBoard) }
        for figure in refitted {
            #expect(smallerBoard.insetBy(dx: -2, dy: -2).contains(CGPoint(x: figure.bounds.midX, y: figure.bounds.midY)))
        }
        guard case .board(let refittedBoardRect) = refitted.last?.shape else {
            Issue.record("the board moves with its drawing")
            return
        }
        #expect(abs(refittedBoardRect.width - smallerBoard.width) < 0.5)
    }

    @Test func markingSomethingOnScreenStaysOnTheScreen() {
        let markPlan = DottieTeaching.Plan(arguments: [
            "anchors": [["name": "error", "describe": "the red error message"]],
            "steps": [["kind": "circle", "points": ["error"]], ["kind": "arrow", "points": ["500,500", "error.left"]]]
        ])!
        #expect(markPlan.surface == .screen)
        #expect(markPlan.problems.isEmpty)
        // A drawing with no frame for the turn (a typed ask) still lands on
        // the screen instead of nowhere.
        let freeArrowPlan = DottieTeaching.Plan(arguments: ["steps": [["kind": "arrow", "points": ["100,100", "900,900"]]]])!
        #expect(drawAll(freeArrowPlan, on: nil).missedSteps == 0)
    }
}
