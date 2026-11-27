//
//  RoundReplayTests.swift
//  leanring-buddyTests
//
//  Rounds 2 to N of a repeated job done from round 1's steps: the request
//  split into one piece of details per round, round k's words put where
//  round 1's were typed or clicked, words that can't be placed left to
//  Jev, a whole round replayed against a screen, and it stays quick.
//

import Foundation
import Testing
@testable import Dottie

struct RoundReplayTests {
    typealias Plan = DottieRoundReplayPlan

    private let patientsRequest = "add three new patients in OpenEMR: (1) Jane Doe, 01/01/1990, female (2) John Smith, 02/03/1985, male (3) Mary Ann Lee, 03/04/1970, female"

    // MARK: Splitting the request

    @Test func aNumberedListGivesOneItemPerRound() {
        let roundItems = Plan.roundItems(in: patientsRequest, totalRounds: 3)
        #expect(roundItems?.items == ["Jane Doe, 01/01/1990, female", "John Smith, 02/03/1985, male", "Mary Ann Lee, 03/04/1970, female"])
        #expect(roundItems?.sharedText == "add three new patients in OpenEMR:")
    }

    @Test func aListAfterAColonIsSplitByLinesSemicolonsOrCommas() {
        #expect(Plan.roundItems(in: "add these patients:\nJane Doe, 1990\nJohn Smith, 1985", totalRounds: 2)?.items
                == ["Jane Doe, 1990", "John Smith, 1985"])
        #expect(Plan.roundItems(in: "add 3 new patients: Jane Doe, 1990; John Smith, 1985; Mary Lee, 1970", totalRounds: 3)?.items
                == ["Jane Doe, 1990", "John Smith, 1985", "Mary Lee, 1970"])
        #expect(Plan.roundItems(in: "add 3 new patients: Jane Doe, John Smith and Mary Lee", totalRounds: 3)?.items
                == ["Jane Doe", "John Smith", "Mary Lee"])
    }

    @Test func noListOrTheWrongCountGivesNothing() {
        #expect(Plan.roundItems(in: "like the next post 3 times", totalRounds: 3) == nil)
        #expect(Plan.roundItems(in: "add 3 new patients: Jane Doe, John Smith", totalRounds: 3) == nil)
        #expect(Plan.roundItems(in: patientsRequest, totalRounds: 1) == nil)
    }

    @Test func aDanglingAndIsTakenOff() {
        let roundItems = Plan.roundItems(in: "add two patients (1) Jane Doe and (2) John Smith", totalRounds: 2)
        #expect(roundItems?.items == ["Jane Doe", "John Smith"])
    }

    @Test func aStrayNumberIsNotARound() {
        let roundItems = Plan.roundItems(in: "add two patients (1) Jane Doe, room (5) north (2) John Smith", totalRounds: 2)
        #expect(roundItems?.items.count == 2)
        #expect(roundItems?.items.last == "John Smith")
    }

    // MARK: Round k's words

    @Test func roundKsWordsGoWhereRoundOnesWere() {
        let roundOne = "Jane Doe, 01/01/1990, female"
        let roundTwo = "John Smith, 02/03/1985, male"
        #expect(Plan.valueForRound("Jane", roundOneItem: roundOne, roundItem: roundTwo) == "John")
        #expect(Plan.valueForRound("Doe", roundOneItem: roundOne, roundItem: roundTwo) == "Smith")
        #expect(Plan.valueForRound("Jane Doe", roundOneItem: roundOne, roundItem: roundTwo) == "John Smith")
        #expect(Plan.valueForRound("01/01/1990", roundOneItem: roundOne, roundItem: roundTwo) == "02/03/1985")
        #expect(Plan.valueForRound("female", roundOneItem: roundOne, roundItem: roundTwo) == "male")
    }

    @Test func aLongerNameKeepsItsFirstAndLastWord() {
        let roundOne = "Jane Doe, 01/01/1990"
        let roundThree = "Mary Ann Lee, 03/04/1970"
        #expect(Plan.valueForRound("Jane", roundOneItem: roundOne, roundItem: roundThree) == "Mary")
        #expect(Plan.valueForRound("Doe", roundOneItem: roundOne, roundItem: roundThree) == "Lee")
        #expect(Plan.valueForRound("Jane Doe", roundOneItem: roundOne, roundItem: roundThree) == "Mary Ann Lee")
    }

    @Test func sharedLabelsStayPut() {
        #expect(Plan.valueForRound("01/01/1990", roundOneItem: "Jane, DOB 01/01/1990", roundItem: "John, DOB 2 March 1985") == "2 March 1985")
        #expect(Plan.valueForRound("555-1234", roundOneItem: "Jane, 555-1234 mobile", roundItem: "John, 555 9876 mobile") == "555 9876")
    }

    @Test func aMiddleWordWithNoPlaceInRoundKCantBePlaced() {
        #expect(Plan.valueForRound("Quinn", roundOneItem: "Jane Quinn Doe", roundItem: "John Smith") == nil)
    }

    @Test func wordsNotInRoundOnesDetailsCantBePlaced() {
        #expect(Plan.valueForRound("Bob", roundOneItem: "Jane Doe", roundItem: "John Smith") == nil)
    }

    @Test func placementKeepsSharedWordsAndHandsUnknownTypingToJev() {
        let roundItems = Plan.roundItems(in: patientsRequest, totalRounds: 3)
        #expect(Plan.placement(of: "OpenEMR", round: 2, roundItems: roundItems, isTyped: true) == .same)
        #expect(Plan.placement(of: "Jane", round: 2, roundItems: roundItems, isTyped: true) == .value("John"))
        #expect(Plan.placement(of: "female", round: 3, roundItems: roundItems, isTyped: false) == .same)
        // A model wrote it for round 1: round k's can't be trusted.
        #expect(Plan.placement(of: "1990-01-01", round: 2, roundItems: roundItems, isTyped: true) == .unknown)
        // A button's own words are the same every round.
        #expect(Plan.placement(of: "Save", round: 2, roundItems: roundItems, isTyped: false) == .same)
        // No list: every round types the same ("search cats 3 times").
        #expect(Plan.placement(of: "cats", round: 2, roundItems: nil, isTyped: true) == .same)
    }

    // MARK: Round k's steps

    private func roundOneSteps() -> [DottieAppTaskStep] {
        let moves: [DottieJevDriverPlan.Move] = [
            .openSite(address: "localhost/openemr"),
            .clickControl(label: "Patient", kind: "menu button", centerX: 120, centerY: 40),
            .click(label: "New/Search", centerX: 140, centerY: 80),
            .typeIntoField(fieldLabel: "First Name", centerX: 300, centerY: 200, text: "Jane", pressesReturn: false),
            .typeIntoField(fieldLabel: "Last Name", centerX: 500, centerY: 200, text: "Doe", pressesReturn: false),
            .typeIntoField(fieldLabel: "DOB", centerX: 300, centerY: 260, text: "01/01/1990", pressesReturn: false),
            .click(label: "Female", centerX: 520, centerY: 260),
            .clickControl(label: "Create New Patient", kind: "button", centerX: 400, centerY: 600)
        ]
        return moves.compactMap { DottieAppTaskPlan.step(from: $0, pageTitle: "OpenEMR", requestText: patientsRequest) }
    }

    @Test func roundTwosStepsTypeAndClickRoundTwosDetails() {
        let roundItems = Plan.roundItems(in: patientsRequest, totalRounds: 3)
        let roundTwoSteps = Plan.steps(roundOneSteps(), forRound: 2, roundItems: roundItems)
        #expect(Array(roundTwoSteps.map(\.text)[3...5]) == ["John", "Smith", "02/03/1985"])
        #expect(roundTwoSteps[6].label == "male")
        #expect(roundTwoSteps[7].label == "Create New Patient")
        #expect(roundTwoSteps[1].label == "Patient")
        #expect(!roundTwoSteps.contains(where: \.textCameFromRequest))
    }

    @Test func aClickOnRoundOnesDetailsThatCantBePlacedIsJevs() {
        let step = DottieAppTaskPlan.step(from: .click(label: "Quinn", centerX: 300, centerY: 300), pageTitle: "Patients", requestText: "x")!
        let roundItems = Plan.RoundItems(sharedText: "open these patients", items: ["Jane Quinn Doe", "John Smith"])
        let roundTwoStep = Plan.steps([step], forRound: 2, roundItems: roundItems)[0]
        #expect(roundTwoStep.label.isEmpty)
        let replayStep = DottieAppTaskPlan.replayStep(
            roundTwoStep, recordedForRequest: "x", newRequest: "x",
            screenTexts: [DottieJevDriverPlan.ScreenText(text: "Quinn", centerX: 300, centerY: 300)],
            screenControls: [], frontSiteHost: nil, frontAppName: nil
        )
        #expect(replayStep == .jevTakesIt)
    }

    @Test func shortOrNumberLabelsAreNeverSwapped() {
        let step = DottieAppTaskPlan.step(from: .click(label: "1", centerX: 10, centerY: 10), pageTitle: "", requestText: "x")!
        let roundItems = Plan.RoundItems(sharedText: "x", items: ["room 1", "room 2"])
        #expect(Plan.steps([step], forRound: 2, roundItems: roundItems)[0].label == "1")
    }

    @Test func roundOneNeedsEnoughStepsAndALaterRound() {
        let steps = roundOneSteps()
        #expect(Plan.roundTask(roundOneSteps: Array(steps.prefix(1)), round: 2, totalRounds: 3, taskText: patientsRequest,
                               appName: "OpenEMR", places: ["localhost"], now: Date()) == nil)
        #expect(Plan.roundTask(roundOneSteps: steps, round: 1, totalRounds: 3, taskText: patientsRequest,
                               appName: "OpenEMR", places: ["localhost"], now: Date()) == nil)
        #expect(Plan.roundTask(roundOneSteps: steps, round: 4, totalRounds: 3, taskText: patientsRequest,
                               appName: "OpenEMR", places: ["localhost"], now: Date()) == nil)
        let roundTask = Plan.roundTask(roundOneSteps: steps, round: 3, totalRounds: 3, taskText: patientsRequest,
                                       appName: "OpenEMR", places: ["localhost"], now: Date())
        #expect(roundTask?.name == "round 3 of 3")
        #expect(roundTask?.steps.count == steps.count)
    }

    @Test func emptyBoxAfterTypingMeansItWentNowhere() {
        #expect(Plan.typingWentNowhere(focusedFieldValue: "  "))
        #expect(!Plan.typingWentNowhere(focusedFieldValue: "John"))
        // No box selected or it doesn't say: nothing to go on.
        #expect(!Plan.typingWentNowhere(focusedFieldValue: nil))
    }

    // MARK: A whole round against a screen

    @Test func roundThreeReplaysWithoutJevOnTheFormScreen() {
        let roundTask = Plan.roundTask(roundOneSteps: roundOneSteps(), round: 3, totalRounds: 3, taskText: patientsRequest,
                                       appName: "OpenEMR", places: ["localhost"], now: Date())!
        let controls = [
            DottieJevDriverPlan.ScreenControl(label: "Patient", kind: "menu button", centerX: 121, centerY: 41),
            DottieJevDriverPlan.ScreenControl(label: "First Name", kind: "text box", centerX: 300, centerY: 200),
            DottieJevDriverPlan.ScreenControl(label: "Last Name", kind: "text box", centerX: 500, centerY: 200),
            DottieJevDriverPlan.ScreenControl(label: "DOB", kind: "text box", centerX: 300, centerY: 260),
            DottieJevDriverPlan.ScreenControl(label: "Create New Patient", kind: "button", centerX: 400, centerY: 600)
        ]
        let texts = [
            DottieJevDriverPlan.ScreenText(text: "New/Search", centerX: 140, centerY: 80),
            DottieJevDriverPlan.ScreenText(text: "Female", centerX: 520, centerY: 260),
            DottieJevDriverPlan.ScreenText(text: "Male", centerX: 600, centerY: 260)
        ]
        var replay = DottieAppTaskPathReplay(task: roundTask)
        var moves: [DottieAppTaskPlan.ReplayStep] = []
        while let step = replay.currentStep {
            moves.append(DottieAppTaskPlan.replayStep(step, recordedForRequest: roundTask.stepsRecordedFor, newRequest: patientsRequest,
                                                      screenTexts: texts, screenControls: controls,
                                                      frontSiteHost: "localhost", frontAppName: "Safari"))
            replay.advance()
        }
        #expect(moves.allSatisfy { $0 != .jevTakesIt && $0 != .notOnScreen })
        #expect(moves.contains(.move(.typeIntoField(fieldLabel: "First Name", centerX: 300, centerY: 200, text: "Mary", pressesReturn: false))))
        #expect(moves.contains(.move(.typeIntoField(fieldLabel: "Last Name", centerX: 500, centerY: 200, text: "Lee", pressesReturn: false))))
        #expect(moves.contains(.move(.typeIntoField(fieldLabel: "DOB", centerX: 300, centerY: 260, text: "03/04/1970", pressesReturn: false))))
        #expect(moves.contains(.move(.click(label: "Female", centerX: 520, centerY: 260))))
    }

    // MARK: Speed

    @Test func buildingSixtyRoundsStaysQuick() {
        let items = (1...60).map { "(\($0)) Person\($0) Family\($0), 01/01/19\($0 % 90 + 10)" }
        let request = "add 60 new patients: " + items.joined(separator: " ")
        #expect(Plan.roundItems(in: request, totalRounds: 60)?.items.count == 60)
        let moves: [DottieJevDriverPlan.Move] = [
            .click(label: "New/Search", centerX: 140, centerY: 80),
            .typeIntoField(fieldLabel: "First Name", centerX: 300, centerY: 200, text: "Person1", pressesReturn: false),
            .typeIntoField(fieldLabel: "Last Name", centerX: 500, centerY: 200, text: "Family1", pressesReturn: false),
            .typeIntoField(fieldLabel: "First Name", centerX: 300, centerY: 200, text: "Person1", pressesReturn: false)
        ]
        let steps = moves.compactMap { DottieAppTaskPlan.step(from: $0, pageTitle: "OpenEMR", requestText: request) }
        let started = Date()
        for round in 2...60 {
            let roundTask = Plan.roundTask(roundOneSteps: steps, round: round, totalRounds: 60, taskText: request,
                                           appName: "OpenEMR", places: ["localhost"], now: Date())
            #expect(roundTask?.steps[3].text == "Person\(round)")
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
