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

    // MARK: Board sizes

    private let laptopScreen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func everyBoardIsASquareOnTheScreenAndTheScreenSurfaceHasNone() {
        #expect(DottieTeaching.Surface.screen.boardRect(on: laptopScreen) == nil)
        for surface in DottieTeaching.Surface.allCases where surface != .screen {
            guard let board = surface.boardRect(on: laptopScreen) else {
                Issue.record("\(surface) should open a board")
                continue
            }
            #expect(board.width == board.height)
            #expect(laptopScreen.contains(board))
        }
    }

    @Test func boardSizesScaleTheBoardWithinLimits() {
        let usualBoard = DottieTeaching.Surface.board_right.boardRect(on: laptopScreen)!
        let smallBoard = DottieTeaching.Surface.board_right.boardRect(on: laptopScreen, sizeScale: 0.65)!
        let hugeBoard = DottieTeaching.Surface.board_right.boardRect(on: laptopScreen, sizeScale: 10)!
        let tinyBoard = DottieTeaching.Surface.board_right.boardRect(on: laptopScreen, sizeScale: 0.01)!
        #expect(smallBoard.width < usualBoard.width)
        #expect(abs(hugeBoard.width - (875 - 48)) < 0.5)
        #expect(tinyBoard.width == 160)
        // A right-hand board stays against the right edge at any size.
        #expect(abs(hugeBoard.maxX - (laptopScreen.maxX - 24)) < 0.5)
    }

    @Test func everyBoardSizeNameIsUnderstood() {
        for boardSize in DottieTeaching.BoardSize.allCases {
            #expect(plan([["kind": "point", "points": ["500,500"]]], extra: ["board_size": boardSize.rawValue])?.boardSize == boardSize)
        }
        #expect(plan([["kind": "point", "points": ["500,500"]]], extra: ["board_size": "LARGE"])?.boardSize == .large)
        #expect(plan([["kind": "point", "points": ["500,500"]]], extra: ["board_size": "gigantic"])?.boardSize == nil)
    }

    @Test func aSmallerBoardShrinksFromItsSizeNowAndNeverBelowTheFloor() {
        let currentBoard = CGRect(x: 600, y: 200, width: 400, height: 400)
        let smallerBoard = DottieTeaching.BoardSize.smaller.resized(currentBoard, usualBoardSide: 600, on: laptopScreen)
        #expect(abs(smallerBoard.width - 300) < 0.5)
        #expect(abs(smallerBoard.midX - currentBoard.midX) < 0.5)
        let tinyBoard = CGRect(x: 600, y: 200, width: 170, height: 170)
        #expect(DottieTeaching.BoardSize.smaller.resized(tinyBoard, usualBoardSide: 600, on: laptopScreen).width == 160)
        let mediumBoard = DottieTeaching.BoardSize.medium.resized(currentBoard, usualBoardSide: 600, on: laptopScreen)
        #expect(abs(mediumBoard.width - 600) < 0.5)
    }

    // MARK: Every kind of step

    /// One valid step of every kind, as Live would send it.
    private static let oneStepOfEveryKind: [[String: Any]] = [
        ["kind": "line", "points": ["100,100", "300,300"]],
        ["kind": "curve", "points": ["100,500", "300,400", "500,500"]],
        ["kind": "polygon", "points": ["100,100", "200,100", "150,200"]],
        ["kind": "arrow", "points": ["100,100", "400,100"]],
        ["kind": "double_arrow", "points": ["100,200", "400,200"]],
        ["kind": "circle", "points": ["500,500", "560,500"]],
        ["kind": "box", "points": ["100,100", "300,200"]],
        ["kind": "highlight", "points": ["100,300", "300,350"]],
        ["kind": "underline", "points": ["100,400", "300,420"]],
        ["kind": "angle", "points": ["500,500", "700,500", "600,350"], "text": "40°"],
        ["kind": "right_angle", "points": ["500,500", "700,500", "500,300"]],
        ["kind": "point", "points": ["600,600"], "text": "A"],
        ["kind": "text", "points": ["100,800"], "text": "x² + 1"],
        ["kind": "ticks", "points": ["100,900", "300,900"], "text": "2"],
        ["kind": "measure", "points": ["100,950", "400,950"], "text": "5 cm"],
        ["kind": "brace", "points": ["600,900", "900,900"], "text": "n"],
        ["kind": "axes", "points": ["100,900", "900,900", "100,100"]],
        ["kind": "plot", "points": ["100,100", "900,900"], "text": "x^2 - 3"],
        ["kind": "cross", "points": ["800,200"]],
        ["kind": "check", "points": ["850,200"]],
        ["kind": "grid", "points": ["100,100", "900,900"], "text": "8x8"],
        ["kind": "chart", "points": ["100,100", "900,900"], "text": "Mon: 12; Tue: 9; Wed: 15", "style": "bar"],
        ["kind": "sketch", "points": ["500,500"], "text": "a house with a door"]
    ]

    private func boardSpace(_ board: CGRect = CGRect(x: 800, y: 100, width: 600, height: 600)) -> DottieTeaching.Space {
        DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { _, _ in nil })
    }

    @Test func theTestListCoversEveryKind() {
        let coveredKinds = Set(Self.oneStepOfEveryKind.compactMap { $0["kind"] as? String })
        #expect(coveredKinds == Set(DottieTeaching.Kind.allCases.map(\.rawValue)))
    }

    @Test func everyKindPassesTheCheckWhenGivenProperly() {
        let fullPlan = plan(Self.oneStepOfEveryKind)
        #expect(fullPlan?.steps.count == Self.oneStepOfEveryKind.count)
        #expect(fullPlan?.problems == [])
    }

    @Test func everyKindExceptSketchDrawsInsideTheBoard() {
        let board = CGRect(x: 800, y: 100, width: 600, height: 600)
        let fullPlan = plan(Self.oneStepOfEveryKind)!
        for step in fullPlan.steps where step.kind != .sketch {
            guard let drawn = DottieTeaching.draw(step, in: boardSpace(board)) else {
                Issue.record("\(step.kind) drew nothing")
                continue
            }
            #expect(!drawn.figures.isEmpty)
            #expect(drawn.duration > 0)
            #expect(!drawn.penPath.isEmpty)
            for penPoint in drawn.penPath {
                #expect(board.insetBy(dx: -120, dy: -120).contains(penPoint), "\(step.kind) pen left the board")
            }
        }
    }

    @Test func axesFromTwoPointsDrawBothArrowsFromTheOrigin() {
        let axesPlan = plan([["kind": "axes", "points": ["100,900", "900,100"], "text": "Quantity, Price"]])!
        let drawn = DottieTeaching.draw(axesPlan.steps[0], in: boardSpace())!
        let arrows = drawn.figures.filter { if case .stroke = $0.shape { return true } else { return false } }
        let labels = drawn.figures.filter { if case .text = $0.shape { return true } else { return false } }
        #expect(arrows.count == 2)
        #expect(labels.count == 2)
    }

    // MARK: Every check path

    @Test func textAndSketchStepsNeedText() {
        #expect(plan([["kind": "text", "points": ["100,100"]]])?.problems.first?.contains("text to write") == true)
        #expect(plan([["kind": "sketch", "points": ["500,500"]]])?.problems.first?.contains("what to draw") == true)
        #expect(plan([["kind": "sketch", "points": ["500,500"], "caption": "a horse"]])?.problems == [])
    }

    @Test func chartsNeedNumbersUnlessTheyGraphTheCircledArea() {
        #expect(plan([["kind": "chart", "points": ["100,100", "900,900"]]])?.problems.first?.contains("data") == true)
        #expect(plan([["kind": "chart", "points": ["100,100", "900,900"], "text": "circled"]])?.problems == [])
        #expect(plan([["kind": "chart", "points": ["100,100", "900,900"], "text": "1, 3; 2, 5"]])?.problems == [])
    }

    @Test func plotsNeedARealFunction() {
        #expect(plan([["kind": "plot", "points": ["100,100", "900,900"]]])?.problems.count == 1)
        #expect(plan([["kind": "plot", "points": ["100,100", "900,900"], "text": "y = sin(x)/x"]])?.problems == [])
    }

    @Test func pointsMayBeNumbersWithSpacesAnchorEdgesOrTheCircledArea() {
        #expect(plan([["kind": "line", "points": ["100, 200", "300 400"]]])?.problems == [])
        #expect(plan([["kind": "line", "points": ["circled.right", "900,900"]]])?.problems == [])
        #expect(plan([["kind": "line", "points": ["(100,200)", "300,400"]]])?.problems == [])
        #expect(plan([["kind": "line", "points": ["somewhere", "300,400"]]])?.problems.count == 1)
        #expect(plan([["kind": "line", "points": ["title.left", "300,400"]]])?.problems.count == 1)
    }

    @Test func eachBadStepIsNamedByItsNumber() {
        let mixedPlan = plan([
            ["kind": "line", "points": ["100,100", "200,200"]],
            ["kind": "plot", "points": ["100,100", "900,900"], "text": "supply"],
            ["kind": "angle", "points": ["100,100"]]
        ])
        #expect(mixedPlan?.problems.count == 2)
        #expect(mixedPlan?.problems[0].hasPrefix("step 2 (plot)") == true)
        #expect(mixedPlan?.problems[1].hasPrefix("step 3 (angle)") == true)
    }

    @Test func unknownKindsAndEmptyPlansAreDropped() {
        #expect(plan([["kind": "hologram", "points": ["1,1"]]]) == nil)
        #expect(plan([]) == nil)
        #expect(DottieTeaching.Plan(arguments: [:]) == nil)
    }

    @Test func keepDefaultsToTrue() {
        #expect(plan([["kind": "point", "points": ["5,5"]]])?.keepsDrawing == true)
        #expect(plan([["kind": "point", "points": ["5,5"]]], extra: ["keep": false])?.keepsDrawing == false)
    }

    // MARK: Refitting and labels

    @Test func refittingScalesTextDotsAndFillsToo() {
        let oldBoard = CGRect(x: 0, y: 0, width: 100, height: 100)
        let newBoard = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard case .text(_, let origin, let fontSize) = DottieFigure(shape: .text("A", origin: CGPoint(x: 10, y: 10), fontSize: 20)).refitted(from: oldBoard, to: newBoard).shape,
              case .dot(let center, let radius) = DottieFigure(shape: .dot(center: CGPoint(x: 50, y: 50), radius: 4)).refitted(from: oldBoard, to: newBoard).shape,
              case .fill(let fillPoints) = DottieFigure(shape: .fill(points: [CGPoint(x: 25, y: 25)])).refitted(from: oldBoard, to: newBoard).shape else {
            Issue.record("shapes keep their kind")
            return
        }
        #expect(origin == CGPoint(x: 20, y: 20))
        #expect(fontSize == 40)
        #expect(center == CGPoint(x: 100, y: 100))
        #expect(radius == 8)
        #expect(fillPoints == [CGPoint(x: 50, y: 50)])
        // Text never shrinks past readable.
        guard case .text(_, _, let shrunkSize) = DottieFigure(shape: .text("A", origin: .zero, fontSize: 18)).refitted(from: newBoard, to: oldBoard).shape else { return }
        #expect(shrunkSize == 12)
    }

    @Test func aStepWithNoTextIsNotNudged() {
        var drawn = DottieTeaching.DrawnStep()
        drawn.add(.stroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)], closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                  ink: .gold, pen: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)])
        let nudged = DottieTeaching.nudgedClearOfText(drawn, occupiedTextRects: [CGRect(x: -100, y: -100, width: 400, height: 400)])
        #expect(nudged.penPath == drawn.penPath)
    }

    @Test func aLabelBuriedUnderManyGivesUpAfterAFewLines() {
        var drawn = DottieTeaching.DrawnStep()
        drawn.addText("Label", origin: CGPoint(x: 100, y: 500), fontSize: 26, ink: .gold)
        let wall = [CGRect(x: 0, y: -2_000, width: 1_000, height: 4_000)]
        let nudged = DottieTeaching.nudgedClearOfText(drawn, occupiedTextRects: wall)
        guard case .text(_, let origin, _) = nudged.figures[0].shape else { return }
        #expect(origin.y < 500)
        #expect(origin.y > 500 - 26 * 2 * 0.6 * 0.8 * 9)
    }

    @Test func onlyWrittenTextTakesUpSpaceAndItIsTrimmedTopAndBottom() {
        let label = DottieFigure(shape: .text("SUPPLY", origin: CGPoint(x: 100, y: 100), fontSize: 20))
        let dot = DottieFigure(shape: .dot(center: CGPoint(x: 50, y: 50), radius: 4))
        let rects = DottieTeaching.textRects(of: [dot, label, dot])
        #expect(rects.count == 1)
        #expect(abs(rects[0].height - label.bounds.height * 0.6) < 0.01)
        #expect(rects[0].width == label.bounds.width)
        #expect(DottieTeaching.textRects(of: []).isEmpty)
        #expect(DottieTeaching.textRects(of: [dot]).isEmpty)
    }
}
