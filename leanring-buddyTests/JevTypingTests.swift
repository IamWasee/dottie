//
//  JevTypingTests.swift
//  leanring-buddyTests
//
//  Jev typing: which jobs get text written for them, reading the written
//  pieces, merging them with the request's own words, and the "click this
//  text box and type" moves.
//

import Foundation
import Testing
@testable import Dottie

struct JevTypingTests {
    private typealias Plan = DottieJevDriverPlan

    @Test func jobsThatTypeGetTextWritten() {
        #expect(DottieJevTextPieces.jobNeedsTyping("reply to Sam saying I'm running late"))
        #expect(DottieJevTextPieces.jobNeedsTyping("search YouTube for lofi"))
        #expect(DottieJevTextPieces.jobNeedsTyping("fill in my name on this form"))
    }

    @Test func jobsThatOnlyClickDont() {
        #expect(!DottieJevTextPieces.jobNeedsTyping("open my downloads folder"))
        #expect(!DottieJevTextPieces.jobNeedsTyping("click the blue button"))
    }

    @Test func thePromptCarriesTheJobAndForbidsPasswords() {
        let prompt = DottieJevTextPieces.prompt(forTask: "email Sam the report")
        #expect(prompt.contains("email Sam the report"))
        #expect(prompt.contains("Never write a password"))
        #expect(prompt.contains("NONE"))
    }

    @Test func piecesAreReadOnePerLineWithoutMarksOrQuotes() {
        let answer = "1. lofi beats\n- \"Hey Sam, running about 10 minutes late!\"\n\n• Sam Lee\nlofi beats"
        #expect(DottieJevTextPieces.pieces(fromAnswer: answer) == ["lofi beats", "Hey Sam, running about 10 minutes late!", "Sam Lee"])
    }

    @Test func noneMeansNothingToType() {
        #expect(DottieJevTextPieces.pieces(fromAnswer: " NONE ").isEmpty)
        #expect(DottieJevTextPieces.pieces(fromAnswer: "").isEmpty)
    }

    @Test func piecesAreCappedAndTooLongOnesDropped() {
        let answer = (1...9).map { "piece \($0)" }.joined(separator: "\n") + "\n" + String(repeating: "x", count: 400)
        let pieces = DottieJevTextPieces.pieces(fromAnswer: answer)
        #expect(pieces.count == DottieJevTextPieces.maximumPieces)
        #expect(!pieces.contains { $0.count > DottieJevTextPieces.maximumPieceLength })
    }

    @Test func theRequestsOwnWordsComeFirstAndRepeatsGo() {
        #expect(DottieJevTextPieces.merged(["cats"], ["Cats", "funny cats"]) == ["cats", "funny cats"])
    }

    @Test func textBoxesGetClickAndTypeMovesWithAndWithoutReturn() {
        let controls = [Plan.ScreenControl(label: "Search", kind: "text box", centerX: 500, centerY: 80),
                        Plan.ScreenControl(label: "Settings", kind: "button", centerX: 900, centerY: 20)]
        let moves = Plan.typeIntoFieldMoves(screenControls: controls, textPieces: ["cats"])
        #expect(moves == [
            .typeIntoField(fieldLabel: "Search", centerX: 500, centerY: 80, text: "cats", pressesReturn: true),
            .typeIntoField(fieldLabel: "Search", centerX: 500, centerY: 80, text: "cats", pressesReturn: false)
        ])
    }

    @Test func clickAndTypeMovesAreCapped() {
        let controls = (0..<10).map { Plan.ScreenControl(label: "Field \($0)", kind: "text box", centerX: 1, centerY: Double($0)) }
        let moves = Plan.typeIntoFieldMoves(screenControls: controls, textPieces: ["a", "b", "c", "d", "e"])
        #expect(moves.count == Plan.maximumTypingFields * Plan.maximumPiecesPerField * 2)
    }

    @Test func noPiecesOrNoBoxesMeansNoClickAndType() {
        let controls = [Plan.ScreenControl(label: "Search", kind: "text box", centerX: 1, centerY: 1)]
        #expect(Plan.typeIntoFieldMoves(screenControls: controls, textPieces: []).isEmpty)
        #expect(Plan.typeIntoFieldMoves(screenControls: [], textPieces: ["cats"]).isEmpty)
    }

    @Test func clickAndTypeReadsClearlyAndWaitsForAPageAfterReturn() {
        let move = Plan.Move.typeIntoField(fieldLabel: "To", centerX: 0, centerY: 0, text: "sam@example.com", pressesReturn: false)
        #expect(move.description == "Click the text box \"To\" and type \"sam@example.com\"")
        #expect(move.summary == "typed \"sam@example.com\" into To")
        #expect(!move.opensSomethingNew)
        #expect(Plan.Move.typeIntoField(fieldLabel: "Search", centerX: 0, centerY: 0, text: "x", pressesReturn: true).opensSomethingNew)
    }

    @Test func aReplyJobOffersTheWrittenMessageInTheMessageBox() throws {
        let controls = [Plan.ScreenControl(label: "Message", kind: "text box", centerX: 500, centerY: 900)]
        let written = DottieJevTextPieces.pieces(fromAnswer: "Hey Sam, running about 10 minutes late!")
        let options = Plan.options(screenTexts: [], textPieces: DottieJevTextPieces.merged([], written), siteAddresses: [], appNames: [],
                                   alreadyTriedSignatures: [], screenControls: controls, taskText: "reply to Sam saying I'm running late")
        let wanted = Plan.Move.typeIntoField(fieldLabel: "Message", centerX: 500, centerY: 900, text: "Hey Sam, running about 10 minutes late!", pressesReturn: true)
        #expect(options.map(\.move).contains(wanted))
        #expect(options.count <= Plan.maximumOptions)
    }
}
