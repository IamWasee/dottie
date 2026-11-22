//
//  BoardTextPlacementTests.swift
//  leanring-buddyTests
//
//  Where text lands on the board. celly's screenshots after 1.0.80 showed
//  words running off the board's edge, labels sitting on curves and an
//  arrow left behind on the screen when the board moved; each is checked
//  here.
//

import CoreGraphics
import Testing
@testable import Dottie

@MainActor
struct BoardTextPlacementTests {
    private let board = CGRect(x: 800, y: 100, width: 500, height: 600)

    private func boardSpace() -> DottieTeaching.Space {
        DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { _, _ in nil })
    }

    private func drawn(_ stepArguments: [String: Any], in space: DottieTeaching.Space) -> DottieTeaching.DrawnStep? {
        guard let plan = DottieTeaching.Plan(arguments: ["steps": [stepArguments]]) else { return nil }
        return DottieTeaching.draw(plan.steps[0], in: space)
    }

    private func textFigures(_ drawnStep: DottieTeaching.DrawnStep?) -> [(text: String, origin: CGPoint, fontSize: CGFloat, bounds: CGRect)] {
        (drawnStep?.figures ?? []).compactMap { figure in
            guard case .text(let text, let origin, let fontSize) = figure.shape else { return nil }
            return (text, origin, fontSize, figure.bounds)
        }
    }

    // MARK: Text stays on the board

    @Test func textStartedNearTheRightEdgeIsMovedBackOntoTheBoard() {
        let texts = textFigures(drawn(["kind": "text", "points": ["900,500"], "text": "Price and quantity fall"], in: boardSpace()))
        #expect(texts.count == 1)
        let textBounds = texts[0].bounds
        #expect(textBounds.maxX <= board.maxX - DottieTeaching.boardTextPadding + 0.5)
        #expect(textBounds.minX >= board.minX + DottieTeaching.boardTextPadding - 0.5)
    }

    @Test func aLineTooWideForTheBoardWrapsOntoMoreLinesAtTheSameSize() {
        let longSentence = "The demand curve shifts to the left because buyers want less at every single price on the board"
        let drawnStep = drawn(["kind": "text", "points": ["0,500"], "text": longSentence, "size": "large"], in: boardSpace())
        let texts = textFigures(drawnStep)
        #expect(texts.count > 1)
        #expect(texts.allSatisfy { $0.fontSize == 38 })
        #expect(texts.map(\.text).joined(separator: " ") == longSentence)
        for text in texts {
            #expect(board.contains(text.bounds.insetBy(dx: 0, dy: text.bounds.height * 0.2)), "a wrapped line ran off the board")
        }
        // Each line sits below the one before, and none overlap.
        for lineIndex in 1..<texts.count {
            #expect(texts[lineIndex].origin.y < texts[lineIndex - 1].origin.y)
            let upperRect = texts[lineIndex - 1].bounds.insetBy(dx: 0, dy: texts[lineIndex - 1].bounds.height * 0.2)
            let lowerRect = texts[lineIndex].bounds.insetBy(dx: 0, dy: texts[lineIndex].bounds.height * 0.2)
            #expect(!upperRect.intersects(lowerRect))
        }
        // The lines are written one after another, in the text's own time.
        let figures = drawnStep?.figures ?? []
        for lineIndex in 1..<figures.count {
            #expect(figures[lineIndex].delay > figures[lineIndex - 1].delay)
        }
        // The pen follows every line.
        #expect(drawnStep?.penPath.count == texts.count * 2)
    }

    @Test func wrappedTextAtTheBottomStartsHigherSoItStaysOnTheBoard() {
        let longSentence = "Light bends toward the normal when it slows down entering glass from air at an angle"
        let texts = textFigures(drawn(["kind": "text", "points": ["0,1000"], "text": longSentence], in: boardSpace()))
        #expect(texts.count > 1)
        for text in texts {
            #expect(text.origin.y - text.fontSize * 0.6 >= board.minY + DottieTeaching.boardTextPadding - 0.5)
        }
    }

    @Test func wrappingBreaksAtSpacesButNeverInsideAMarking() {
        let markedText = "Total internal reflection happens when {red:the angle is past critical} and **light stays inside** the glass"
        let lines = DottieTeaching.wrappedLines(markedText, fontSize: 26, maxWidth: 260)
        #expect(lines.count > 1)
        #expect(lines.joined(separator: " ") == markedText)
        for line in lines {
            #expect(line.filter { $0 == "{" }.count == line.filter { $0 == "}" }.count, "\(line) cuts a color marking")
            #expect(line.components(separatedBy: "**").count % 2 == 1, "\(line) cuts a bold marking")
        }
    }

    @Test func shortTextAndOneLongWordAreNotSplit() {
        #expect(DottieTeaching.wrappedLines("Snell's law", fontSize: 26, maxWidth: 400) == ["Snell's law"])
        let longWord = "pneumonoultramicroscopicsilicovolcanoconiosis"
        #expect(DottieTeaching.wrappedLines(longWord, fontSize: 26, maxWidth: 200) == [longWord])
        #expect(DottieTeaching.wrappedLines("", fontSize: 26, maxWidth: 200) == [""])
    }

    @Test func aWordTooWideForTheBoardIsWrittenSmallerOnItsOwnLine() {
        let longWord = "pneumonoultramicroscopicsilicovolcanoconiosis"
        let texts = textFigures(drawn(["kind": "text", "points": ["0,500"], "text": longWord, "size": "large"], in: boardSpace()))
        #expect(texts.count == 1)
        #expect(texts[0].fontSize < 38)
        #expect(texts[0].fontSize >= 12)
    }

    @Test func textAtTheTopOrBottomEdgeStaysInside() {
        for edgePoint in ["500,0", "500,1000"] {
            let texts = textFigures(drawn(["kind": "text", "points": [edgePoint], "text": "Edge"], in: boardSpace()))
            #expect(texts.count == 1)
            let halfHeight = texts[0].fontSize * 0.6
            #expect(texts[0].origin.y - halfHeight >= board.minY + DottieTeaching.boardTextPadding - 0.5)
            #expect(texts[0].origin.y + halfHeight <= board.maxY - DottieTeaching.boardTextPadding + 0.5)
        }
    }

    @Test func aCurvesLabelPastTheEdgeComesBackInsideButTheCurveStays() {
        let drawnStep = drawn(["kind": "curve", "points": ["100,800", "500,400", "1000,100"], "text": "Demand"], in: boardSpace())
        let texts = textFigures(drawnStep)
        #expect(texts.count == 1)
        #expect(texts[0].bounds.maxX <= board.maxX)
        let strokeSegments = DottieTeaching.strokeSegments(of: drawnStep?.figures ?? [])
        #expect(strokeSegments.contains { $0.end.x == board.maxX })
    }

    @Test func textInsideTheBoardIsLeftExactlyWhereItWas() {
        let texts = textFigures(drawn(["kind": "text", "points": ["100,500"], "text": "Short"], in: boardSpace()))
        let expectedOrigin = boardSpace().numericPoint(100, 500)
        #expect(texts.first?.origin == expectedOrigin)
        #expect(texts.first?.fontSize == 26)
    }

    @Test func textOverTheScreenIsNotMoved() {
        let screenSpace = DottieTeaching.Space(boardRect: nil, anchorFrames: [:], screenPoint: { normalizedX, normalizedY in
            CGPoint(x: normalizedX, y: normalizedY)
        })
        let texts = textFigures(drawn(["kind": "text", "points": ["995,500"], "text": "A long line near the right edge"], in: screenSpace))
        #expect(texts.first?.origin == CGPoint(x: 995, y: 500))
    }

    @Test func aTextStepsPenFollowsItsMovedLine() {
        let drawnStep = drawn(["kind": "text", "points": ["950,500"], "text": "Equilibrium point"], in: boardSpace())
        #expect(drawnStep?.penPath.allSatisfy { $0.x <= board.maxX } == true)
    }

    // MARK: Writing tied to the screen goes on an open board

    @Test func onlyWrittenTextMovesToTheBoardMarksStayOnTheScreen() {
        let plan = DottieTeaching.Plan(arguments: [
            "anchors": [["name": "prism", "describe": "the prism diagram"]],
            "steps": [
                ["kind": "text", "points": ["prism.left"], "text": "White light splits"],
                ["kind": "circle", "points": ["prism"]],
                ["kind": "arrow", "points": ["500,500", "prism.left"]]
            ]
        ])!
        #expect(!DottieTeaching.drawsOnScreenWhileBoardIsOpen(plan.steps[0]))
        #expect(DottieTeaching.drawsOnScreenWhileBoardIsOpen(plan.steps[1]))
        #expect(DottieTeaching.drawsOnScreenWhileBoardIsOpen(plan.steps[2]))
    }

    @Test func textMovedToAnEmptyBoardStartsNearTheTopLeft() {
        #expect(DottieTeaching.boardPointBelowWrittenText(boardRect: board, writtenTextRects: []) == "60,80")
        // Text elsewhere on the screen doesn't count.
        let textOnTheScreen = CGRect(x: 0, y: 0, width: 100, height: 30)
        #expect(DottieTeaching.boardPointBelowWrittenText(boardRect: board, writtenTextRects: [textOnTheScreen]) == "60,80")
    }

    @Test func textMovedToTheBoardGoesBelowWhatIsWritten() {
        // A line whose bottom is 300 points below the board's top.
        let writtenLine = CGRect(x: 850, y: board.maxY - 300, width: 200, height: 30)
        let point = DottieTeaching.boardPointBelowWrittenText(boardRect: board, writtenTextRects: [writtenLine])
        let expectedY = Int(((300 + 40) / board.height * 1000).rounded())
        #expect(point == "60,\(expectedY)")
        // A step placed there draws on the board, below the line.
        let plan = DottieTeaching.Plan(arguments: ["steps": [["kind": "text", "points": [point], "text": "Next line"]]])!
        let texts = textFigures(DottieTeaching.draw(plan.steps[0], in: boardSpace()))
        #expect(texts.first.map { $0.origin.y < writtenLine.minY } == true)
        #expect(texts.first.map { board.contains($0.origin) } == true)
    }

    @Test func aBoardFullOfTextStillPlacesTheNextLineOnIt() {
        let lineAtTheBottom = CGRect(x: 850, y: board.minY + 2, width: 200, height: 30)
        #expect(DottieTeaching.boardPointBelowWrittenText(boardRect: board, writtenTextRects: [lineAtTheBottom]) == "60,950")
    }

    // MARK: Labels keep off lines

    @Test func aSegmentThroughARectCrossesItAndOneBesideItDoesNot() {
        let rect = CGRect(x: 100, y: 100, width: 50, height: 20)
        #expect(DottieTeaching.segment(from: CGPoint(x: 0, y: 110), to: CGPoint(x: 300, y: 110), crosses: rect))
        #expect(!DottieTeaching.segment(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 300, y: 200), crosses: rect))
        #expect(DottieTeaching.segment(from: CGPoint(x: 120, y: 110), to: CGPoint(x: 120, y: 110), crosses: rect))
    }

    @Test func strokeSegmentsIncludeAClosedShapesLastSide() {
        let triangle = DottieFigure(shape: .stroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)],
                                                   closed: true, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false))
        let openLine = DottieFigure(shape: .stroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)],
                                                   closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false))
        let label = DottieFigure(shape: .text("x", origin: .zero, fontSize: 20))
        #expect(DottieTeaching.strokeSegments(of: [triangle]).count == 3)
        #expect(DottieTeaching.strokeSegments(of: [openLine, label]).count == 1)
    }

    @Test func aLabelOnALineMovesOffIt() {
        var drawnStep = DottieTeaching.DrawnStep()
        drawnStep.addText("Supply", origin: CGPoint(x: 1000, y: 400), fontSize: 26, ink: .white)
        let curveThroughLabel: [(start: CGPoint, end: CGPoint)] = [(start: CGPoint(x: 900, y: 400), end: CGPoint(x: 1200, y: 400))]
        let nudged = DottieTeaching.nudgedClearOfText(drawnStep, occupiedTextRects: [], occupiedStrokeSegments: curveThroughLabel, boardRect: board)
        let nudgedRects = DottieTeaching.textRects(of: nudged.figures)
        #expect(nudgedRects.count == 1)
        #expect(!DottieTeaching.segment(from: curveThroughLabel[0].start, to: curveThroughLabel[0].end, crosses: nudgedRects[0]))
        #expect(board.contains(nudgedRects[0]))
    }

    @Test func aLabelAtTheBoardsBottomMovesUpNotOffTheBoard() {
        var drawnStep = DottieTeaching.DrawnStep()
        drawnStep.addText("Quantity", origin: CGPoint(x: 1000, y: board.minY + 30), fontSize: 26, ink: .white)
        let occupied = DottieTeaching.textRects(of: drawnStep.figures)
        let nudged = DottieTeaching.nudgedClearOfText(drawnStep, occupiedTextRects: occupied, boardRect: board)
        guard case .text(_, let origin, _) = nudged.figures[0].shape else {
            Issue.record("text stays text")
            return
        }
        #expect(origin.y > board.minY + 30)
        #expect(board.contains(DottieTeaching.textRects(of: nudged.figures)[0]))
    }

    @Test func aLabelWithNoFreeSpotIsLeftWhereItWas() {
        var drawnStep = DottieTeaching.DrawnStep()
        drawnStep.addText("Crowded", origin: CGPoint(x: 1000, y: 400), fontSize: 26, ink: .white)
        let wholeBoardTaken = [board]
        let nudged = DottieTeaching.nudgedClearOfText(drawnStep, occupiedTextRects: wholeBoardTaken, boardRect: board)
        guard case .text(_, let origin, _) = nudged.figures[0].shape else { return }
        #expect(origin == CGPoint(x: 1000, y: 400))
    }

    @Test func movingALabelLeavesItsLineWhereItWas() {
        var drawnStep = DottieTeaching.DrawnStep()
        let arrowPoints = [CGPoint(x: 900, y: 300), CGPoint(x: 1100, y: 300)]
        drawnStep.add(.stroke(points: arrowPoints, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: true),
                      ink: .red, pen: arrowPoints)
        drawnStep.addText("falls", origin: CGPoint(x: 980, y: 300), fontSize: 22, ink: .red)
        let nudged = DottieTeaching.nudgedClearOfText(drawnStep, occupiedTextRects: [], boardRect: board)
        guard case .stroke(let movedPoints, _, _, _, _, _) = nudged.figures[0].shape,
              case .text(_, let labelOrigin, _) = nudged.figures[1].shape else {
            Issue.record("the arrow and its label are both still there")
            return
        }
        #expect(movedPoints == arrowPoints)
        #expect(labelOrigin.y != 300)
        // The pen still traces the arrow as drawn.
        #expect(nudged.penPath.first == arrowPoints[0])
    }

    @Test func onlySingleLabelStepsAreMovedOffLines() {
        for movableKind in [DottieTeaching.Kind.text, .line, .curve, .arrow, .circle, .box, .angle, .measure, .brace, .point] {
            #expect(DottieTeaching.movesLabelsClearOfLines(movableKind))
        }
        for graphKind in [DottieTeaching.Kind.axes, .grid, .plot, .chart, .ticks, .sketch] {
            #expect(!DottieTeaching.movesLabelsClearOfLines(graphKind))
        }
    }

    // MARK: Moving the board takes its drawing along

    @Test func aLongStrokeMostlyOnTheBoardMovesWithIt() {
        // Its middle is off the board (the arrow bends far out), but most
        // of its points are on it.
        let mostlyOnBoard = DottieFigure(shape: .stroke(points: [CGPoint(x: 850, y: 200), CGPoint(x: 900, y: 250), CGPoint(x: 950, y: 300), CGPoint(x: 3000, y: 300)],
                                                        closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: true))
        #expect(DottieDrawingOverlayManager.belongsToBoard(mostlyOnBoard, board))
    }

    @Test func aMarkOnTheScreenStaysWhenTheBoardMoves() {
        let screenCircle = DottieFigure(shape: .stroke(points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 150, y: 200)],
                                                       closed: true, smooth: true, dashed: false, arrowAtStart: false, arrowAtEnd: false))
        let screenLabel = DottieFigure(shape: .text("here", origin: CGPoint(x: 100, y: 400), fontSize: 20))
        #expect(!DottieDrawingOverlayManager.belongsToBoard(screenCircle, board))
        #expect(!DottieDrawingOverlayManager.belongsToBoard(screenLabel, board))
    }

    @Test func textAndBoardsOnTheBoardMoveWithIt() {
        let boardLabel = DottieFigure(shape: .text("Demand", origin: CGPoint(x: 900, y: 400), fontSize: 20))
        #expect(DottieDrawingOverlayManager.belongsToBoard(boardLabel, board))
        #expect(DottieDrawingOverlayManager.belongsToBoard(DottieFigure(shape: .board(rect: board)), board))
    }
}
