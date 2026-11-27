//
//  FormFillTests.swift
//  leanring-buddyTests
//
//  A form's boxes filled in one go: "BOX label = value" lines read from the
//  writing call (never password or code boxes, never typed whole as text),
//  matched to the text boxes on screen, only when two or more match, in
//  reading order, skipping boxes already filled, and it stays quick.
//

import Foundation
import Testing
@testable import Dottie

struct FormFillTests {
    typealias Plan = DottieFormFillPlan

    private let patientAnswer = """
    Jane Doe
    BOX First Name = Jane
    BOX Last Name = Doe
    BOX DOB = 01/01/1990
    BOX Password = hunter2
    """

    private func textBox(_ label: String, _ centerX: Double, _ centerY: Double) -> DottieJevDriverPlan.ScreenControl {
        DottieJevDriverPlan.ScreenControl(label: label, kind: "text box", centerX: centerX, centerY: centerY)
    }

    // MARK: Reading the boxes

    @Test func boxLinesBecomeBoxesAndPasswordsAreLeftOut() {
        let boxes = Plan.formBoxes(fromAnswer: patientAnswer)
        #expect(boxes == [Plan.FormBox(label: "First Name", value: "Jane"),
                          Plan.FormBox(label: "Last Name", value: "Doe"),
                          Plan.FormBox(label: "DOB", value: "01/01/1990")])
    }

    @Test func oddBoxLinesAreSkipped() {
        let answer = "BOX = Jane\nBOX Phone =\nBOX Email = \"jane@example.com\"\nbox email = other@example.com\nBOX Card Number = 4111"
        #expect(Plan.formBoxes(fromAnswer: answer) == [Plan.FormBox(label: "Email", value: "jane@example.com")])
    }

    @Test func boxesAreCapped() {
        let answer = (1...30).map { "BOX Field \($0) = value \($0)" }.joined(separator: "\n")
        #expect(Plan.formBoxes(fromAnswer: answer).count == Plan.maximumBoxes)
    }

    @Test func privateBoxNamesAreRecognised() {
        #expect(Plan.isPrivateBox("Password"))
        #expect(Plan.isPrivateBox("Security code"))
        #expect(Plan.isPrivateBox("PIN"))
        #expect(!Plan.isPrivateBox("Shipping address"))
        #expect(!Plan.isPrivateBox("First Name"))
    }

    @Test func boxLinesAreNotTypedWholeAsText() {
        #expect(DottieJevTextPieces.pieces(fromAnswer: patientAnswer) == ["Jane Doe"])
    }

    @Test func theWritingPromptAsksForBoxes() {
        let prompt = DottieJevTextPieces.prompt(forTask: "add a new patient Jane Doe born 01/01/1990")
        #expect(prompt.contains("BOX First Name = Jane"))
        #expect(DottieJevTextPieces.jobNeedsTyping("add three new patients: (1) Jane Doe (2) John Smith (3) Mary Lee"))
    }

    // MARK: Matching boxes on screen

    @Test func boxesMatchTextBoxesInReadingOrder() {
        let controls = [
            textBox("DOB", 300, 260), textBox("Last Name", 500, 200), textBox("First Name", 300, 200),
            DottieJevDriverPlan.ScreenControl(label: "First Name", kind: "button", centerX: 10, centerY: 10)
        ]
        let toFill = Plan.boxesToFill(formBoxes: Plan.formBoxes(fromAnswer: patientAnswer), screenControls: controls, alreadyFilledLabels: [])
        #expect(toFill.map(\.control.label) == ["First Name", "Last Name", "DOB"])
        #expect(toFill.map(\.box.value) == ["Jane", "Doe", "01/01/1990"])
    }

    @Test func oneMatchIsLeftToJev() {
        let toFill = Plan.boxesToFill(formBoxes: Plan.formBoxes(fromAnswer: patientAnswer),
                                      screenControls: [textBox("First Name", 300, 200), textBox("Notes", 300, 400)], alreadyFilledLabels: [])
        #expect(toFill.isEmpty)
    }

    @Test func filledBoxesAreNotFilledAgain() {
        let controls = [textBox("First Name", 300, 200), textBox("Last Name", 500, 200), textBox("DOB", 300, 260)]
        let toFill = Plan.boxesToFill(formBoxes: Plan.formBoxes(fromAnswer: patientAnswer), screenControls: controls,
                                      alreadyFilledLabels: ["first name", "last name"])
        #expect(toFill.isEmpty)
    }

    @Test func aPasswordBoxOnScreenIsNeverFilled() {
        let boxes = [Plan.FormBox(label: "Username", value: "jane"), Plan.FormBox(label: "Password field", value: "x")]
        let controls = [textBox("Username", 300, 200), textBox("Password field", 300, 260)]
        #expect(Plan.boxesToFill(formBoxes: boxes, screenControls: controls, alreadyFilledLabels: []).isEmpty)
    }

    @Test func eachTextBoxIsUsedOnce() {
        let boxes = [Plan.FormBox(label: "Name", value: "Jane"), Plan.FormBox(label: "Name", value: "Doe"),
                     Plan.FormBox(label: "City", value: "Leeds")]
        let controls = [textBox("Name", 300, 200), textBox("City", 300, 260)]
        let toFill = Plan.boxesToFill(formBoxes: boxes, screenControls: controls, alreadyFilledLabels: [])
        #expect(toFill.count == 2)
        #expect(Set(toFill.map(\.control.label)) == ["Name", "City"])
    }

    // MARK: With round replay

    @Test func filledBoxesBecomeStepsLaterRoundsReplayWithTheirOwnDetails() {
        let request = "add two new patients: (1) Jane Doe, 01/01/1990 (2) John Smith, 02/03/1985"
        let toFill = Plan.boxesToFill(formBoxes: Plan.formBoxes(fromAnswer: patientAnswer),
                                      screenControls: [textBox("First Name", 300, 200), textBox("Last Name", 500, 200), textBox("DOB", 300, 260)],
                                      alreadyFilledLabels: [])
        let roundOneSteps = toFill.compactMap { boxToFill in
            DottieAppTaskPlan.step(from: .typeIntoField(fieldLabel: boxToFill.control.label, centerX: boxToFill.control.centerX,
                                                        centerY: boxToFill.control.centerY, text: boxToFill.box.value, pressesReturn: false),
                                   pageTitle: "OpenEMR", requestText: request)
        }
        let roundTwo = DottieRoundReplayPlan.roundTask(roundOneSteps: roundOneSteps, round: 2, totalRounds: 2, taskText: request,
                                                       appName: "OpenEMR", places: ["localhost"], now: Date())
        #expect(roundTwo?.steps.map(\.text) == ["John", "Smith", "02/03/1985"])
    }

    // MARK: Speed

    @Test func matchingIsQuick() {
        let boxes = (1...12).map { Plan.FormBox(label: "Field number \($0)", value: "value \($0)") }
        let controls = (1...60).map { textBox("Field number \($0)", Double($0 % 3) * 300, Double($0) * 15) }
        let started = Date()
        for _ in 0..<100 { _ = Plan.boxesToFill(formBoxes: boxes, screenControls: controls, alreadyFilledLabels: []) }
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
