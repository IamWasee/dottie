//
//  JevDriverArmsTests.swift
//  leanring-buddyTests
//
//  Jev's arms: every control it can pick (named controls and icons,
//  double and right clicks, drags, sideways scrolls, shortcuts, quick Mac
//  actions, app memory), staying under its option limit, and needing a
//  clear pick for moves that are hard to take back.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

struct JevDriverArmsTests {
    private typealias Plan = DottieJevDriverPlan

    @Test func everyKindOfArmIsOffered() {
        let screenTexts = [Plan.ScreenText(text: "invoice.pdf", centerX: 200, centerY: 300), Plan.ScreenText(text: "Archive", centerX: 600, centerY: 300)]
        let controls = [Plan.ScreenControl(label: "Compose", kind: "button", centerX: 50, centerY: 100)]
        let moves = Plan.options(screenTexts: screenTexts, textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [],
                                 screenControls: controls, taskText: "drag invoice.pdf onto Archive", offersAppMemory: true).map(\.move)
        #expect(moves.contains(.clickControl(label: "Compose", kind: "button", centerX: 50, centerY: 100)))
        #expect(moves.contains(.clickUnlabeled))
        #expect(moves.contains(.doubleClick(label: "invoice.pdf", centerX: 200, centerY: 300)))
        #expect(moves.contains(.rightClick(label: "invoice.pdf", centerX: 200, centerY: 300)))
        #expect(moves.contains(.drag(fromLabel: "invoice.pdf", fromX: 200, fromY: 300, toLabel: "Archive", toX: 600, toY: 300)))
        #expect(moves.contains(.scrollLeft))
        #expect(moves.contains(.scrollRight))
        #expect(moves.contains(.pressKeys(keys: "cmd+l", meaning: "go to the browser's address bar")))
        #expect(moves.contains(.quickMacAction("drag invoice.pdf onto Archive")))
        #expect(moves.first == .recallAppMemory)
    }

    @Test func appMemoryIsOfferedOnlyWhenAsked() {
        let moves = Plan.options(screenTexts: [], textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: []).map(\.move)
        #expect(!moves.contains(.recallAppMemory))
    }

    @Test func optionsStayUnderJevsLimitWithAPackedScreen() {
        let screenTexts = (0..<300).map { Plan.ScreenText(text: "Row \($0)", centerX: 10, centerY: Double($0)) }
        let controls = (0..<100).map { Plan.ScreenControl(label: "Tool \($0)", kind: "button", centerX: 900, centerY: Double($0)) }
        let options = Plan.options(screenTexts: screenTexts, textPieces: ["a", "b"], siteAddresses: ["youtube.com"], appNames: ["Safari"],
                                   alreadyTriedSignatures: [], screenControls: controls, taskText: "open row 5", offersAppMemory: true)
        #expect(options.count <= Plan.maximumOptions)
        #expect(options.map(\.move).contains(.finished))
        #expect(options.map(\.move).contains(.noneFits))
        #expect(Set(options.map(\.key)).count == options.count)
    }

    @Test func aControlAlreadyReadAsTextIsOfferedOnce() {
        let screenTexts = [Plan.ScreenText(text: "Search", centerX: 500, centerY: 80)]
        let controls = [Plan.ScreenControl(label: "Search", kind: "text box", centerX: 500, centerY: 80),
                        Plan.ScreenControl(label: "Settings", kind: "button", centerX: 980, centerY: 20)]
        let kept = Plan.controlsWorthOffering(controls, screenTexts: screenTexts, taskText: "x")
        #expect(kept.map(\.label) == ["Settings"])
    }

    @Test func riskyControlsAreLeftOutUnlessAskedFor() {
        let controls = [Plan.ScreenControl(label: "Delete", kind: "button", centerX: 1, centerY: 1)]
        #expect(Plan.controlsWorthOffering(controls, screenTexts: [], taskText: "open my mail").isEmpty)
        #expect(Plan.controlsWorthOffering(controls, screenTexts: [], taskText: "delete this email").count == 1)
    }

    @Test func aControlAndTheSameTextAreOneMoveWhenStruckOff() {
        #expect(Plan.Move.clickControl(label: "Search", kind: "button", centerX: 1, centerY: 1).signature == Plan.Move.click(label: "Search", centerX: 9, centerY: 9).signature)
    }

    @Test func accessibilityFramesMapOntoTheScreenshot() throws {
        // Primary display 1440x900; a control at the top-left area of it.
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let control = try #require(Plan.screenControl(label: " Compose ", role: "AXButton", accessibilityFrame: CGRect(x: 134, y: 80, width: 10, height: 10),
                                                       displayFrame: display, primaryDisplayHeight: 900))
        #expect(control.label == "Compose")
        #expect(control.kind == "button")
        #expect(abs(control.centerX - 96.53) < 0.01)
        #expect(abs(control.centerY - 94.44) < 0.01)
    }

    @Test func controlsOnAnotherDisplayOrWithoutANameAreSkipped() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(Plan.screenControl(label: "Far", role: "AXButton", accessibilityFrame: CGRect(x: 2000, y: 10, width: 10, height: 10), displayFrame: display, primaryDisplayHeight: 900) == nil)
        #expect(Plan.screenControl(label: "  ", role: "AXButton", accessibilityFrame: CGRect(x: 10, y: 10, width: 10, height: 10), displayFrame: display, primaryDisplayHeight: 900) == nil)
        #expect(Plan.screenControl(label: "Group", role: "AXGroup", accessibilityFrame: CGRect(x: 10, y: 10, width: 10, height: 10), displayFrame: display, primaryDisplayHeight: 900) == nil)
    }

    @Test func controlsOnASecondDisplayAboveThePrimaryMapToo() throws {
        // A display above the primary one: AppKit y 900...1980.
        let display = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let control = try #require(Plan.screenControl(label: "Play", role: "AXButton", accessibilityFrame: CGRect(x: 955, y: -545, width: 10, height: 10),
                                                       displayFrame: display, primaryDisplayHeight: 900))
        #expect(abs(control.centerX - 500) < 0.01)
        #expect(abs(control.centerY - 500) < 0.01)
    }

    @Test func rolesMapToPlainKinds() {
        #expect(Plan.controlKind(forRole: "AXLink") == "link")
        #expect(Plan.controlKind(forRole: "AXSearchField") == "text box")
        #expect(Plan.controlKind(forRole: "AXPopUpButton") == "menu")
        #expect(Plan.controlKind(forRole: "AXStaticText") == nil)
    }

    @Test func doubleAndRightClicksAreOnlyForTextsTheJobTalksAbout() {
        let screenTexts = [Plan.ScreenText(text: "Budget 2026.xlsx", centerX: 1, centerY: 1), Plan.ScreenText(text: "Photos", centerX: 2, centerY: 2)]
        let targets = Plan.doubleAndRightClickTargets(screenTexts: screenTexts, taskText: "open the budget spreadsheet")
        #expect(targets.map(\.text) == ["Budget 2026.xlsx"])
        #expect(Plan.doubleAndRightClickTargets(screenTexts: screenTexts, taskText: "open it").isEmpty)
    }

    @Test func aDragNeedsBothSidesOnScreen() {
        let screenTexts = [Plan.ScreenText(text: "report.docx", centerX: 100, centerY: 100)]
        #expect(Plan.dragMove(taskText: "move report.docx to the Trash", screenTexts: screenTexts) == nil)
        #expect(Plan.dragMove(taskText: "open report.docx", screenTexts: screenTexts) == nil)
        let withTrash = screenTexts + [Plan.ScreenText(text: "Trash", centerX: 900, centerY: 950)]
        #expect(Plan.dragMove(taskText: "move report.docx to the Trash", screenTexts: withTrash)
                == .drag(fromLabel: "report.docx", fromX: 100, fromY: 100, toLabel: "Trash", toX: 900, toY: 950))
    }

    @Test func hardToUndoMovesNeedAClearPick() {
        let unsureDrag = Plan.Answer(move: .drag(fromLabel: "a", fromX: 0, fromY: 0, toLabel: "b", toX: 1, toY: 1), probability: 0.3, confidence: 0.6, doneProbability: 0.1)
        #expect(Plan.decision(for: unsureDrag) == .unsure)
        let sureDrag = Plan.Answer(move: unsureDrag.move, probability: 0.7, confidence: 0.6, doneProbability: 0.1)
        #expect(Plan.decision(for: sureDrag) == .act(unsureDrag.move))
        let unsureQuit = Plan.Answer(move: .pressKeys(keys: "cmd+q", meaning: "quit"), probability: 0.4, confidence: 0.6, doneProbability: 0.1)
        #expect(Plan.decision(for: unsureQuit) == .unsure)
        let copy = Plan.Answer(move: .pressKeys(keys: "cmd+c", meaning: "copy"), probability: 0.4, confidence: 0.6, doneProbability: 0.1)
        #expect(Plan.decision(for: copy) == .act(copy.move))
    }

    @Test func newMovesReadClearlyForJevAndTheHandOverNote() {
        #expect(Plan.Move.clickControl(label: "Compose", kind: "button", centerX: 0, centerY: 0).description == "Click the button \"Compose\"")
        #expect(Plan.Move.pressKeys(keys: "cmd+f", meaning: "find on this page").description == "Press cmd+f (find on this page)")
        #expect(Plan.Move.doubleClick(label: "a.txt", centerX: 0, centerY: 0).summary == "double-clicked a.txt")
        #expect(Plan.Move.recallAppMemory.summary == "looked up what Dottie remembers about this app")
        #expect(Plan.Move.doubleClick(label: "a", centerX: 0, centerY: 0).opensSomethingNew)
        #expect(!Plan.Move.rightClick(label: "a", centerX: 0, centerY: 0).opensSomethingNew)
    }

    @Test func noOptionNamesTheScreenshotAsset() {
        let moves = Plan.options(screenTexts: [], textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [], taskText: "x", offersAppMemory: true)
        #expect(!moves.contains { $0.move.description.contains(DottieJevProtocol.screenshotAssetName) })
    }

    /// A whole job through Jev's answers: look up app memory, click a named
    /// icon, double-click a file, press a shortcut, then done. Each step's
    /// options are built, Jev's pick read back and acted on.
    @Test func aWholeJobUsesTheNewArmsInOrder() throws {
        let taskText = "open the budget file in Finder"
        let screenTexts = [Plan.ScreenText(text: "budget.xlsx", centerX: 300, centerY: 400)]
        let controls = [Plan.ScreenControl(label: "Downloads", kind: "item", centerX: 60, centerY: 300)]
        let wantedMoves: [Plan.Move] = [
            .recallAppMemory,
            .clickControl(label: "Downloads", kind: "item", centerX: 60, centerY: 300),
            .doubleClick(label: "budget.xlsx", centerX: 300, centerY: 400),
            .pressKeys(keys: "cmd+s", meaning: "save"),
            .finished
        ]
        var movesSoFar: [String] = []
        var hasRecalled = false
        var finished = false
        for wantedMove in wantedMoves {
            let options = Plan.options(screenTexts: screenTexts, textPieces: [], siteAddresses: [], appNames: ["Finder"],
                                       alreadyTriedSignatures: [], screenControls: controls, taskText: taskText, offersAppMemory: !hasRecalled)
            let body = Plan.requestBody(goal: taskText, movesSoFar: movesSoFar, knownHowTo: hasRecalled ? "Downloads is in the sidebar." : "", options: options)
            #expect(JSONSerialization.isValidJSONObject(body))
            let key = try #require(options.first { $0.move == wantedMove }?.key)
            let answerData = try JSONSerialization.data(withJSONObject: ["answers": [
                Plan.choiceQuestionName: ["choice": key, "probabilities": [key: 0.8], "confidence": 0.7],
                Plan.doneQuestionName: ["noul": wantedMove == .finished ? 0.95 : 0.05]
            ]])
            let parsed = try #require(Plan.answer(fromAnswer: answerData, options: options))
            switch Plan.decision(for: parsed) {
            case .act(let move):
                if move == .recallAppMemory { hasRecalled = true }
                movesSoFar.append(move.summary)
            case .finished:
                finished = true
            case .roundDone:
                Issue.record("a job done once has no rounds")
            case .unsure:
                Issue.record("a confident pick shouldn't hand over")
            }
        }
        #expect(finished)
        #expect(movesSoFar == ["looked up what Dottie remembers about this app", "clicked the item Downloads", "double-clicked budget.xlsx", "pressed cmd+s"])
    }
}
