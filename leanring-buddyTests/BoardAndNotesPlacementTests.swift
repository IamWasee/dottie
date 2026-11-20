//
//  BoardAndNotesPlacementTests.swift
//  leanring-buddyTests
//
//  Moving the teaching board (by Dottie, or by the user's drag on its
//  grip) and moving or folding the notes board, plus the prompt lines that
//  send teaching asks to the board, the screen or the notes.
//

import CoreGraphics
import Testing
@testable import Dottie

@MainActor
struct BoardAndNotesPlacementTests {
    private let laptopScreen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let boardOnTheRight = CGRect(x: 800, y: 100, width: 600, height: 600)

    // MARK: - Dottie moving the teaching board

    @Test func movingTheBoardLeftKeepsItsSizeAndPutsItAtTheLeftEdge() throws {
        let movedBoard = try #require(DottieTeaching.movedBoard(boardOnTheRight, to: .board_left, on: laptopScreen))
        #expect(movedBoard.size == boardOnTheRight.size)
        #expect(movedBoard.minX == laptopScreen.minX + 24)
    }

    @Test func movingTheBoardRightPutsItAtTheRightEdge() throws {
        let leftBoard = CGRect(x: 24, y: 100, width: 500, height: 500)
        let movedBoard = try #require(DottieTeaching.movedBoard(leftBoard, to: .board_right, on: laptopScreen))
        #expect(movedBoard.maxX == laptopScreen.maxX - 24)
        #expect(movedBoard.width == 500)
    }

    @Test func movingTheBoardDownPutsItAtTheBottom() throws {
        let movedBoard = try #require(DottieTeaching.movedBoard(CGRect(x: 0, y: 300, width: 400, height: 400), to: .board_bottom, on: laptopScreen))
        #expect(movedBoard.minY == laptopScreen.minY + 24)
        #expect(abs(movedBoard.midX - laptopScreen.midX) < 0.5)
    }

    @Test func movingTheBoardToTheCenterCentersIt() throws {
        let movedBoard = try #require(DottieTeaching.movedBoard(boardOnTheRight, to: .board_center, on: laptopScreen))
        #expect(abs(movedBoard.midX - laptopScreen.midX) < 0.5)
        #expect(abs(movedBoard.midY - laptopScreen.midY) < 0.5)
    }

    @Test func theScreenIsNoPlaceForABoard() {
        #expect(DottieTeaching.movedBoard(boardOnTheRight, to: .screen, on: laptopScreen) == nil)
    }

    @Test func aBoardTooBigForASmallerScreenShrinksToFitIt() throws {
        let smallScreen = CGRect(x: 0, y: 0, width: 800, height: 500)
        let movedBoard = try #require(DottieTeaching.movedBoard(CGRect(x: 0, y: 0, width: 900, height: 900), to: .board_left, on: smallScreen))
        #expect(movedBoard.height <= smallScreen.height - 48)
        #expect(smallScreen.contains(movedBoard))
    }

    @Test func aMoveWithNoStepsIsAPlanWhenAddingToTheLastDrawing() throws {
        let plan = try #require(DottieTeaching.Plan(arguments: ["add_to_last": true, "surface": "board_left"]))
        #expect(plan.steps.isEmpty)
        #expect(plan.surface == .board_left)
        #expect(plan.surfaceWasGiven)
    }

    @Test func noStepsAndNoBoardToMoveIsNoPlan() {
        #expect(DottieTeaching.Plan(arguments: ["add_to_last": true, "surface": "screen"]) == nil)
        #expect(DottieTeaching.Plan(arguments: ["surface": "board_left"]) == nil)
    }

    // MARK: - The user dragging the board's grip

    @Test func theGripSitsInsideTheBoardsTopLeftCorner() {
        let gripFrame = DottieDrawingOverlayManager.boardHandleFrame(for: boardOnTheRight)
        #expect(boardOnTheRight.contains(gripFrame))
        #expect(gripFrame.minX == boardOnTheRight.minX + 8)
        #expect(gripFrame.maxY == boardOnTheRight.maxY - 8)
    }

    @Test func aDragMovesTheBoardByTheSameDistance() {
        let movedBoard = DottieDrawingOverlayManager.boardMovedByDrag(boardOnTheRight, dragDistance: CGSize(width: -300, height: 40))
        #expect(movedBoard == CGRect(x: 500, y: 140, width: 600, height: 600))
    }

    @Test func theGripFollowsTheMovedBoard() {
        let movedBoard = DottieDrawingOverlayManager.boardMovedByDrag(boardOnTheRight, dragDistance: CGSize(width: 10, height: -10))
        let gripBefore = DottieDrawingOverlayManager.boardHandleFrame(for: boardOnTheRight)
        let gripAfter = DottieDrawingOverlayManager.boardHandleFrame(for: movedBoard)
        #expect(gripAfter.origin == CGPoint(x: gripBefore.minX + 10, y: gripBefore.minY - 10))
    }

    @Test func aDraggedBoardCarriesItsDrawing() {
        let label = DottieFigure(shape: .text("Demand", origin: CGPoint(x: 900, y: 600), fontSize: 22), ink: .blue,
                                 lineWidth: 3, delay: 0, drawDuration: 0.3)
        let movedBoard = DottieDrawingOverlayManager.boardMovedByDrag(boardOnTheRight, dragDistance: CGSize(width: -200, height: 0))
        let movedLabel = label.refitted(from: boardOnTheRight, to: movedBoard)
        #expect(abs(movedLabel.bounds.minX - (label.bounds.minX - 200)) < 1)
    }

    // MARK: - The notes board

    private let notesFrame = CGRect(x: 700, y: 100, width: 600, height: 700)

    @Test(arguments: DottieNotesBoard.Position.allCases)
    func theNotesStayWholeAndOnScreenWhereverTheyMove(position: DottieNotesBoard.Position) {
        let movedFrame = DottieNotesBoard.frame(of: notesFrame, movedTo: position, on: laptopScreen)
        #expect(movedFrame.size == notesFrame.size)
        #expect(laptopScreen.contains(movedFrame))
    }

    @Test func movingTheNotesLeftPutsThemAtTheLeftEdge() {
        #expect(DottieNotesBoard.frame(of: notesFrame, movedTo: .left, on: laptopScreen).minX == 20)
    }

    @Test func movingTheNotesTopRightPutsThemInThatCorner() {
        let movedFrame = DottieNotesBoard.frame(of: notesFrame, movedTo: .top_right, on: laptopScreen)
        #expect(movedFrame.maxX == laptopScreen.maxX - 20)
        #expect(movedFrame.maxY == laptopScreen.maxY - 20)
    }

    @Test func notesTallerThanTheScreenShrinkToFitIt() {
        let tallNotes = CGRect(x: 0, y: 0, width: 600, height: 2000)
        let movedFrame = DottieNotesBoard.frame(of: tallNotes, movedTo: .center, on: laptopScreen)
        #expect(movedFrame.height == laptopScreen.height - 40)
    }

    @Test func minimizingKeepsTheTopEdgeAndLeavesTheHeader() {
        let foldedFrame = DottieNotesBoard.frame(of: notesFrame, foldedTo: DottieNotesBoard.minimizedHeight)
        #expect(foldedFrame.maxY == notesFrame.maxY)
        #expect(foldedFrame.height == DottieNotesBoard.minimizedHeight)
        #expect(foldedFrame.width == notesFrame.width)
    }

    @Test func unfoldingGoesBackToTheSameFrame() {
        let foldedFrame = DottieNotesBoard.frame(of: notesFrame, foldedTo: DottieNotesBoard.minimizedHeight)
        #expect(DottieNotesBoard.frame(of: foldedFrame, foldedTo: notesFrame.height) == notesFrame)
    }

    @Test func movingTheNotesWithoutAPlaceAsksForOne() async {
        let answer = await DottieToolRegistry.run("write_notes", arguments: ["action": "move"], for: .voice)
        #expect(answer?.hasPrefix("error: give a position") == true)
    }

    @Test func movingTheNotesToAPlaceThatIsNotOneAsksForOne() async {
        let answer = await DottieToolRegistry.run("write_notes", arguments: ["action": "move", "position": "upstairs"], for: .voice)
        #expect(answer?.contains("top_right") == true)
    }

    @Test func theNotesToolOffersMoveMinimizeAndRestore() throws {
        let declaration = try #require(DottieToolRegistry.functionDeclarations(for: .voice).first { $0["name"] as? String == "write_notes" })
        let properties = try #require((declaration["parameters"] as? [String: Any])?["properties"] as? [String: Any])
        let actions = try #require((properties["action"] as? [String: Any])?["enum"] as? [String])
        #expect(Set(["move", "minimize", "restore"]).isSubset(of: Set(actions)))
        #expect(properties["position"] != nil)
    }

    // MARK: - Which teaching asks go where

    @Test func theTalkerHandsPointingAndTeachingOver() {
        let talkerPrompt = DottieTalkerProtocol.talkerSystemPrompt(personalityLine: "")
        #expect(talkerPrompt.contains("pointing at, drawing or explaining something on their screen"))
        #expect(talkerPrompt.contains("teaching them"))
    }

    @Test func claudeKnowsScreenDrawingsBoardsAndNotesApart() {
        let requestPrompt = DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "")
        #expect(requestPrompt.contains("explain_on_screen (surface screen, anchors)"))
        #expect(requestPrompt.contains("draw on a board"))
        #expect(requestPrompt.contains("write_notes"))
        #expect(requestPrompt.contains("[POINT:"))
    }

    @Test func claudeHasRoomForADrawingsToolCall() {
        #expect(DottieTalkerProtocol.requestAnswerTokenLimit >= 2000)
    }
}
