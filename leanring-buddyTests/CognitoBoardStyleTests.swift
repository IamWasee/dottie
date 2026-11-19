//
//  CognitoBoardStyleTests.swift
//  leanring-buddyTests
//
//  Tests for the teaching board's Cognito look: white paper, muted colors
//  that read on white, grey as the plain pen, accents that relax back to
//  grey once the next step is drawn, and marks over the screen left in
//  their bright colors.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Dottie

@MainActor
struct CognitoBoardStyleTests {
    private let board = CGRect(x: 0, y: 0, width: 600, height: 600)

    private func line(at center: CGPoint, ink: DottieInk) -> DottieFigure {
        DottieFigure(shape: .stroke(points: [CGPoint(x: center.x - 20, y: center.y), CGPoint(x: center.x + 20, y: center.y)],
                                    closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                     ink: ink)
    }

    private func label(at origin: CGPoint, ink: DottieInk) -> DottieFigure {
        DottieFigure(shape: .text("AMPLITUDE", origin: origin, fontSize: 20), ink: ink)
    }

    private func luminance(ofHex hex: Int) -> Double {
        func channel(_ value: Int) -> Double {
            let fraction = Double(value) / 255
            return fraction <= 0.03928 ? fraction / 12.92 : pow((fraction + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    // MARK: - Colors on paper

    @Test func thePlainPensAreCognitosTwoGreys() {
        #expect(DottieInk.white.paperHex == 0x585858)
        #expect(DottieInk.grey.paperHex == 0x9F9F9F)
    }

    @Test func redIsCognitosMaroonForActingOnSomething() {
        #expect(DottieInk.red.paperHex == 0x92375D)
    }

    @Test func everyInkHasItsOwnPaperColor() {
        let paperColors = DottieInk.allCases.map(\.paperHex)
        #expect(Set(paperColors).count == paperColors.count)
    }

    @Test func everyPaperColorShowsOnWhite() {
        for ink in DottieInk.allCases {
            let contrast = 1.05 / (luminance(ofHex: ink.paperHex) + 0.05)
            #expect(contrast >= 1.6, "\(ink.rawValue) is too pale on the white board (contrast \(contrast))")
        }
    }

    @Test func onlyWhiteAndGreyArePlainPens() {
        #expect(!DottieInk.white.isAccent)
        #expect(!DottieInk.grey.isAccent)
        for ink in DottieInk.allCases where ink != .white && ink != .grey {
            #expect(ink.isAccent, "\(ink.rawValue) should count as an accent")
        }
    }

    @Test func overTheScreenTheBrightColorsStay() {
        for ink in DottieInk.allCases {
            #expect(ink.color(onPaper: false) == ink.color)
        }
        #expect(DottieInk.red.color(onPaper: true) == DottieInk.color(hex: 0x92375D))
        #expect(DottieInk.red.color(onPaper: true) != DottieInk.red.color)
    }

    @Test func hexColorsAreReadExactly() {
        #expect(DottieInk.color(hex: 0xFFFFFF) == Color(red: 1, green: 1, blue: 1))
        #expect(DottieInk.color(hex: 0x000000) == Color(red: 0, green: 0, blue: 0))
        #expect(DottieInk.color(hex: 0xFF0000) == Color(red: 1, green: 0, blue: 0))
    }

    @Test func markedWordsUseThePaperColorsOnTheBoard() {
        let onPaper = DottieInkText.attributedString("{red:minus}", onPaper: true)
        let overScreen = DottieInkText.attributedString("{red:minus}")
        #expect(onPaper.runs.first?.swiftUI.foregroundColor == DottieInk.red.color(onPaper: true))
        #expect(overScreen.runs.first?.swiftUI.foregroundColor == DottieInk.red.color)
    }

    @Test func greyCanBeAskedForByName() {
        #expect(DottieInk(rawValue: "grey") == .grey)
        #expect(DottieInkText.plainText("{grey:old step}") == "old step")
    }

    // MARK: - Which figures are on paper

    @Test func aFigureInsideTheBoardIsOnPaper() {
        #expect(DottieFigure.isOnPaper(line(at: CGPoint(x: 300, y: 300), ink: .blue), boardRects: [board]))
    }

    @Test func aFigureOutsideTheBoardIsNot() {
        #expect(!DottieFigure.isOnPaper(line(at: CGPoint(x: 900, y: 300), ink: .blue), boardRects: [board]))
    }

    @Test func withNoBoardNothingIsOnPaper() {
        #expect(!DottieFigure.isOnPaper(line(at: CGPoint(x: 300, y: 300), ink: .blue), boardRects: []))
    }

    @Test func theBoardItselfIsNotDrawnAsInk() {
        #expect(!DottieFigure.isOnPaper(DottieFigure(shape: .board(rect: board)), boardRects: [board]))
    }

    @Test func boardRectsAreFoundAmongTheFigures() {
        let figures = [DottieFigure(shape: .board(rect: board)), line(at: CGPoint(x: 10, y: 10), ink: .gold)]
        #expect(DottieFigure.boardRects(in: figures) == [board])
        #expect(DottieFigure.boardRects(in: [line(at: .zero, ink: .gold)]).isEmpty)
    }

    // MARK: - Highlight, then relax

    @Test func aRelaxedLineGoesToTheLineGrey() {
        let relaxedLine = line(at: CGPoint(x: 300, y: 300), ink: .orange).relaxed()
        #expect(relaxedLine.isRelaxed)
        #expect(relaxedLine.shownInk == .grey)
        #expect(relaxedLine.ink == .orange)
    }

    @Test func relaxedWritingGoesToTheWorkingGrey() {
        #expect(label(at: CGPoint(x: 100, y: 100), ink: .green).relaxed().shownInk == .white)
    }

    @Test func plainPensAndTheBoardNeverChange() {
        let plainLine = line(at: CGPoint(x: 300, y: 300), ink: .white)
        #expect(plainLine.relaxed() == plainLine)
        let boardFigure = DottieFigure(shape: .board(rect: board))
        #expect(boardFigure.relaxed() == boardFigure)
    }

    @Test func aNewAccentShowsInItsColor() {
        #expect(line(at: CGPoint(x: 300, y: 300), ink: .blue).shownInk == .blue)
    }

    @Test func relaxingKeepsEachFiguresIdentity() {
        let accentLine = line(at: CGPoint(x: 300, y: 300), ink: .blue)
        #expect(accentLine.relaxed().id == accentLine.id)
    }

    @Test func aResizedBoardKeepsRelaxedFiguresGrey() {
        let relaxedLine = line(at: CGPoint(x: 300, y: 300), ink: .blue).relaxed()
        let refitted = relaxedLine.refitted(from: board, to: CGRect(x: 0, y: 0, width: 900, height: 900))
        #expect(refitted.isRelaxed)
        #expect(refitted.shownInk == .grey)
    }

    @Test func onlyAccentsOnABoardRelax() {
        let figures = [
            DottieFigure(shape: .board(rect: board)),
            line(at: CGPoint(x: 300, y: 300), ink: .blue),
            line(at: CGPoint(x: 1200, y: 300), ink: .blue)
        ]
        let relaxedFigures = DottieDrawingOverlayManager.relaxingAccentsOnBoards(figures)
        #expect(relaxedFigures[1].isRelaxed, "the accent on the board relaxes")
        #expect(!relaxedFigures[2].isRelaxed, "a mark over the screen keeps its color")
        #expect(relaxedFigures[0] == figures[0])
    }

    @Test func withNoBoardNothingRelaxes() {
        let figures = [line(at: CGPoint(x: 300, y: 300), ink: .blue)]
        #expect(DottieDrawingOverlayManager.relaxingAccentsOnBoards(figures) == figures)
    }

    @Test func linesOnPaperAreAQuarterThinner() {
        #expect(DottieFigure.paperLineWidthScale == 0.75)
    }

    // MARK: - Integration: a plan drawn on the board

    @Test func axesAndGridsUseTheLineGreyAndTextTheWorkingGrey() throws {
        let plan = try #require(DottieTeaching.Plan(arguments: ["steps": [
            ["kind": "axes", "points": ["100,900", "900,100"], "text": "x,y"],
            ["kind": "text", "points": ["100,100"], "text": "Waves"]
        ]]))
        let space = DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { _, _ in nil })
        let axes = try #require(DottieTeaching.draw(plan.steps[0], in: space))
        #expect(!axes.figures.isEmpty)
        #expect(axes.figures.allSatisfy { $0.ink == .grey })
        let writing = try #require(DottieTeaching.draw(plan.steps[1], in: space))
        #expect(writing.figures.first?.ink == .white)
    }

    // MARK: - Journey: two steps on the board

    @Test func theFirstStepsColorRelaxesWhenTheSecondIsDrawn() throws {
        let plan = try #require(DottieTeaching.Plan(arguments: ["steps": [
            ["kind": "line", "points": ["100,500", "900,500"], "color": "orange", "text": "amplitude"],
            ["kind": "line", "points": ["100,300", "900,300"], "color": "green", "text": "wavelength"]
        ]]))
        let space = DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { _, _ in nil })
        let firstStep = try #require(DottieTeaching.draw(plan.steps[0], in: space))
        let secondStep = try #require(DottieTeaching.draw(plan.steps[1], in: space))

        // What the overlay holds as the lesson goes: the board, then each
        // step added with earlier accents relaxed.
        var onScreen = [DottieFigure(shape: .board(rect: board))]
        onScreen = DottieDrawingOverlayManager.relaxingAccentsOnBoards(onScreen) + firstStep.figures
        #expect(onScreen.dropFirst().allSatisfy { $0.shownInk == .orange }, "the newest step is in its color")
        onScreen = DottieDrawingOverlayManager.relaxingAccentsOnBoards(onScreen) + secondStep.figures

        let firstStepFigures = onScreen.filter { figure in firstStep.figures.contains { $0.id == figure.id } }
        let secondStepFigures = onScreen.filter { figure in secondStep.figures.contains { $0.id == figure.id } }
        #expect(!firstStepFigures.isEmpty)
        #expect(firstStepFigures.allSatisfy { $0.isRelaxed && !$0.shownInk.isAccent }, "the first step went back to grey")
        #expect(secondStepFigures.allSatisfy { $0.shownInk == .green }, "the second step stands out")
    }

    // MARK: - Speed

    @Test func relaxingABusyBoardIsQuick() {
        var figures = [DottieFigure(shape: .board(rect: board))]
        for index in 0..<5_000 {
            figures.append(line(at: CGPoint(x: CGFloat(index % 600), y: CGFloat(index % 500)), ink: index.isMultiple(of: 2) ? .blue : .white))
        }
        let startedAt = Date()
        let relaxedFigures = DottieDrawingOverlayManager.relaxingAccentsOnBoards(figures)
        #expect(relaxedFigures.count == figures.count)
        #expect(Date().timeIntervalSince(startedAt) < 0.2)
    }
}
