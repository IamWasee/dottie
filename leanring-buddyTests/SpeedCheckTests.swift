//
//  SpeedCheckTests.swift
//  leanring-buddyTests
//
//  Speed checks for the code that runs on every spoken or typed turn before
//  any AI is asked: cleaning up the words, the AppleScript safety check,
//  reading a streamed answer, reading a helper's routine blocks and turning
//  typed math into symbols. Each check runs the work many times and compares
//  the middle (median) time with a budget many times what a Mac needs, so a
//  slow CI machine passes but a change that makes a turn noticeably slower
//  fails.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

@MainActor
struct SpeedCheckTests {

    /// The middle time of `runCount` runs, after a few warm-up runs that aren't counted.
    private func medianMilliseconds(runCount: Int = 25, work: () -> Void) -> Double {
        for _ in 0..<3 {
            work()
        }
        var durationsInMilliseconds: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<runCount {
            let duration = clock.measure(work)
            let seconds = Double(duration.components.seconds)
            let attoseconds = Double(duration.components.attoseconds)
            durationsInMilliseconds.append(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
        }
        durationsInMilliseconds.sort()
        return durationsInMilliseconds[durationsInMilliseconds.count / 2]
    }

    @Test func cleaningUpAThousandSpokenRequestsStaysQuick() {
        let spokenRequests = (0..<1_000).map { requestNumber in
            "Hey Dottie, can you open Safari and then play music number \(requestNumber) please?"
        }

        let median = medianMilliseconds {
            for spokenRequest in spokenRequests {
                let normalizedRequest = DottieInstantText.normalized(spokenRequest)
                _ = DottieInstantText.splitIntoParts(normalizedRequest)
            }
        }

        #expect(median < 1_500, "1,000 requests took \(median) ms")
    }

    @Test func checkingALongAppleScriptStaysQuick() {
        let harmlessLine = "tell application \"Music\" to set sound volume to 40\n"
        let longScript = String(repeating: harmlessLine, count: 2_000)

        let median = medianMilliseconds {
            _ = DottieMacActions.isRisky(longScript)
        }

        #expect(median < 500, "a 2,000-line script took \(median) ms")
    }

    @Test func readingAStreamedAnswerOfAThousandPiecesStaysQuick() {
        let oneEvent = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"word \"}]}}]}\r\n\r\n"
        let responseData = Data(String(repeating: oneEvent, count: 1_000).utf8)

        var answerLength = 0
        let median = medianMilliseconds {
            answerLength = GeminiServerSentEvents.text(from: responseData).count
        }

        #expect(answerLength == 5_000)
        #expect(median < 1_000, "1,000 events took \(median) ms")
    }

    @Test func readingRoutineBlocksOutOfALongReplyStaysQuick() {
        let longReport = String(repeating: "Nothing unusual in this part of the report. ", count: 2_000)
        let routineBlock = "<ROUTINE>{\"action\":\"create\",\"every_minutes\":60,\"title\":\"Prices\",\"task\":\"Check the price\"}</ROUTINE>"
        let replyText = longReport + routineBlock

        var routineActionCount = 0
        let median = medianMilliseconds {
            routineActionCount = ClickyRoutinePrompts.extractRoutineActions(from: replyText).routineActions.count
        }

        #expect(routineActionCount == 1)
        #expect(median < 500, "a 90,000-character reply took \(median) ms")
    }

    @Test func turningAPageOfTypedMathIntoSymbolsStaysQuick() {
        let oneLine = "x^2 + sqrt(y) >= \\theta and H2O -> 2H2 + O2\n"
        let pageOfMath = String(repeating: oneLine, count: 200)

        let median = medianMilliseconds {
            _ = DottieMathText.pretty(pageOfMath)
        }

        #expect(median < 2_000, "200 lines of math took \(median) ms")
    }

    @Test func tellingCodeFromMathForAWholeNotesPageStaysQuick() {
        let lines = (0..<500).map { lineNumber in
            lineNumber.isMultiple(of: 2)
                ? "output_\(lineNumber) = model.generate(**inputs, max_new_tokens=50)"
                : "x_\(lineNumber)^2 + y^2 = r^2 and v_max = 9.8 m/s^2"
        }

        var codeLineCount = 0
        let median = medianMilliseconds {
            codeLineCount = lines.filter(DottieMathText.looksLikeCode).count
        }

        #expect(codeLineCount == 250)
        #expect(median < 1_000, "500 lines took \(median) ms")
    }

    @Test func findingCodeInALongAnswerStaysQuick() {
        let paragraph = "Here is how it works, step by step, with `npm run dev` to start it. "
        let answer = String(repeating: paragraph, count: 300) + "```\npip install transformers\n```"

        var snippetCount = 0
        let median = medianMilliseconds {
            snippetCount = DottieMathText.codeSnippets(in: answer).count
        }

        #expect(snippetCount == 2)
        #expect(median < 500, "a 20,000-character answer took \(median) ms")
    }

    @Test func checkingAndDrawingAFullTeachingPlanStaysQuick() {
        let steps: [[String: Any]] = (0..<40).map { stepNumber in
            switch stepNumber % 4 {
            case 0: return ["kind": "plot", "points": ["100,100", "900,900"], "text": "x^2 - 3"]
            case 1: return ["kind": "chart", "points": ["100,100", "900,900"], "text": "Mon: 12; Tue: 9; Wed: 15; Thu: 4"]
            case 2: return ["kind": "grid", "points": ["100,100", "900,900"], "text": "20x20"]
            default: return ["kind": "text", "points": ["100,\(stepNumber * 20)"], "text": "Step \(stepNumber): x² + 1"]
            }
        }
        let board = CGRect(x: 800, y: 100, width: 600, height: 600)
        let space = DottieTeaching.Space(boardRect: board, anchorFrames: [:], screenPoint: { _, _ in nil })

        var drawnStepCount = 0
        let median = medianMilliseconds(runCount: 15) {
            guard let plan = DottieTeaching.Plan(arguments: ["steps": steps]), plan.problems.isEmpty else { return }
            var occupiedTextRects: [CGRect] = []
            drawnStepCount = 0
            for step in plan.steps {
                guard var drawn = DottieTeaching.draw(step, in: space) else { continue }
                if step.kind == .text {
                    drawn = DottieTeaching.nudgedClearOfText(drawn, occupiedTextRects: occupiedTextRects)
                }
                for figure in drawn.figures {
                    if case .text = figure.shape { occupiedTextRects.append(figure.bounds) }
                }
                drawnStepCount += 1
            }
        }

        #expect(drawnStepCount == 40)
        #expect(median < 1_500, "a 40-step plan took \(median) ms")
    }

    @Test func pickingTheOnMacVoiceForAThousandAnswersStaysQuick() {
        let median = medianMilliseconds {
            for answerNumber in 0..<1_000 {
                _ = DottieKokoroVoices.voice(named: answerNumber.isMultiple(of: 2) ? " jarvis " : "unknown")
                _ = DottieKokoroVoices.speakableText("  Here is answer \(answerNumber).  ")
            }
        }

        #expect(median < 200, "1,000 voice picks took \(median) ms")
    }

    @Test func readingAThousandJevBoxesStaysQuick() throws {
        let answerData = try JSONSerialization.data(withJSONObject: ["answers": ["target": ["box": ["top": 0.1, "bottom": 0.2, "left": 0.3, "right": 0.5], "confidence": 0.9]]])
        let median = medianMilliseconds {
            for _ in 0..<1_000 {
                _ = DottieJevProtocol.box(fromAnswer: answerData)
            }
        }

        #expect(median < 300, "1,000 Jev answers took \(median) ms")
    }

    /// Every Jev step builds options from a full screen of text and a
    /// request; that must stay far below Jev's own answer time.
    @Test func buildingAJevStepFromAFullScreenStaysQuick() {
        let screenTexts = (0..<400).map { DottieJevDriverPlan.ScreenText(text: "Item number \($0)", centerX: Double($0 % 1000), centerY: Double($0)) }
        let taskText = "open youtube and search for \"lofi beats\" then play the first one"
        let median = medianMilliseconds {
            for _ in 0..<20 {
                let options = DottieJevDriverPlan.options(
                    screenTexts: DottieJevDriverPlan.clickableTexts(from: screenTexts, taskText: taskText),
                    textPieces: DottieJevDriverPlan.textPieces(from: taskText),
                    siteAddresses: DottieJevDriverPlan.siteAddresses(from: taskText),
                    appNames: ["Safari"],
                    alreadyTriedSignatures: []
                )
                _ = DottieJevDriverPlan.requestBody(goal: taskText, movesSoFar: ["opened youtube.com"], knownHowTo: "", options: options)
            }
        }

        #expect(median < 200, "20 Jev steps took \(median) ms to build")
    }

    /// Every screen-job step checks the app memory before asking Jev; a
    /// full page (40 clicks, 400 texts on screen) must cost next to nothing.
    @Test func checkingTheAppMemoryEveryStepStaysQuick() {
        let clicks = (0..<DottieAppMemoryPlan.maximumClicksPerPage).map {
            DottieAppPage.Click(label: "Button number \($0)", centerX: 10, centerY: Double($0), resultPageKey: "page \($0)",
                                resultPageTitle: "Page", timesSeen: $0, lastSeen: Date())
        }
        let memoryPage = DottieAppPage(key: "home", title: "Home", elements: [], clicks: clicks, lastSeen: Date(), screenshotFileName: nil)
        let visibleLabels = (0..<400).map { "Button number \($0)" }
        let median = medianMilliseconds {
            for _ in 0..<100 {
                _ = DottieAppMemoryPlan.rememberedClick(on: memoryPage, forTask: "open button number 7 please",
                                                        visibleLabels: visibleLabels, alreadyClickedLabels: [])
            }
        }

        #expect(median < 200, "100 app memory checks took \(median) ms")
    }

    @Test func movingTheBoardAndNotesAThousandTimesStaysQuick() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let median = medianMilliseconds {
            var board = CGRect(x: 800, y: 100, width: 600, height: 600)
            var notesFrame = CGRect(x: 700, y: 100, width: 600, height: 700)
            for moveNumber in 0..<1_000 {
                let surface: DottieTeaching.Surface = moveNumber.isMultiple(of: 2) ? .board_left : .board_right
                board = DottieTeaching.movedBoard(board, to: surface, on: screenFrame) ?? board
                _ = DottieDrawingOverlayManager.boardHandleFrame(for: board)
                let position = DottieNotesBoard.Position.allCases[moveNumber % DottieNotesBoard.Position.allCases.count]
                notesFrame = DottieNotesBoard.frame(of: notesFrame, movedTo: position, on: screenFrame)
            }
        }

        #expect(median < 100, "1,000 board and notes moves took \(median) ms")
    }

    @Test func placingAThousandDrawingAnchorsStaysQuick() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let median = medianMilliseconds {
            var anchorFrames: [String: CGRect] = [:]
            for anchorNumber in 0..<1_000 {
                anchorFrames["anchor \(anchorNumber)"] = DottieTeaching.appKitFrame(normalizedBox: [100, 200, 300, 400], displayFrame: displayFrame)
            }
            _ = anchorFrames
        }

        #expect(median < 200, "1,000 drawing anchors took \(median) ms")
    }

    @Test func readingAThousandTalkerAnswersStaysQuick() {
        let median = medianMilliseconds {
            for answerNumber in 0..<1_000 {
                _ = DottieTalkerProtocol.decision(fromTalkerAnswer: answerNumber.isMultiple(of: 2) ? "REQUEST SCREEN" : "hey, doing great")
            }
        }

        #expect(median < 200, "1,000 talker answers took \(median) ms")
    }

    /// Every Jev step builds its options from a packed screen: 300 texts,
    /// 100 named controls, shortcuts, drags and clicks.
    @Test func buildingJevsOptionsForAPackedScreenStaysQuick() {
        let screenTexts = (0..<300).map { DottieJevDriverPlan.ScreenText(text: "Row \($0) report", centerX: 10, centerY: Double($0)) }
        let screenControls = (0..<100).map { DottieJevDriverPlan.ScreenControl(label: "Tool \($0)", kind: "button", centerX: 900, centerY: Double($0)) }
        let median = medianMilliseconds {
            let clickable = DottieJevDriverPlan.clickableTexts(from: screenTexts, taskText: "drag row 5 report onto row 9 report")
            let options = DottieJevDriverPlan.options(screenTexts: clickable, textPieces: ["report"], siteAddresses: ["youtube.com"], appNames: ["Safari"],
                                                      alreadyTriedSignatures: [], screenControls: screenControls,
                                                      taskText: "drag row 5 report onto row 9 report", offersAppMemory: true)
            _ = DottieJevDriverPlan.requestBody(goal: "drag row 5 report onto row 9 report", movesSoFar: [], knownHowTo: "", options: options)
        }
        #expect(median < 50, "one packed Jev step took \(median) ms")
    }

    /// App memory's text for Jev or the step model, from a big page and 60 flows.
    @Test func buildingAppMemorysSummaryStaysQuick() {
        let elements = (0..<120).map { DottieAppPage.Element(label: "Item \($0)", centerX: 1, centerY: Double($0)) }
        var page = DottieAppPage(key: "k", title: "Inbox", elements: elements, clicks: [], lastSeen: Date(), screenshotFileName: nil)
        page.controls = (0..<120).map { DottieAppPage.Control(label: "Button \($0)", kind: "button", centerX: 2, centerY: Double($0)) }
        let step = DottieAppFlowStep(action: .click, pageTitle: "Inbox", label: "Compose", centerX: 1, centerY: 1, resultPageTitle: "New Message")
        let flows = (0..<60).map { _ in DottieAppFlow(startedAt: Date(), steps: Array(repeating: step, count: 40)) }
        let median = medianMilliseconds {
            _ = DottieAppMemoryRecallPlan.summary(appName: "Mail", page: page, flows: flows, taskText: "write a new message to Sam")
        }
        #expect(median < 50, "app memory's summary took \(median) ms")
    }

    @Test func jobMemoryHintsAndHeldMouseOptionsStayQuick() {
        var memory = DottieJobMemory(totalRounds: 5)
        for round in 1...4 {
            for move in 1...25 { memory.noteMove("clicked button \(move) of round \(round)") }
            memory.finishRound()
        }
        let manyTexts = (0..<400).map { DottieJevDriverPlan.ScreenText(text: "Item \($0)", centerX: 100, centerY: Double($0)) }
        let median = medianMilliseconds {
            _ = memory.stateText()
            _ = DottieScreenJobHintPlan.isGuidance("no, use the search bar at the top, it's faster")
            _ = DottieJevDriverPlan.optionsWhileHoldingMouse(heldLabel: "Item 3", screenTexts: manyTexts, screenControls: [], alreadyTriedSignatures: [])
        }
        #expect(median < 50, "job memory, hints and held-mouse options took \(median) ms")
    }

    @Test func theLastJobsRecordStaysQuick() {
        let record = DottieLastScreenJob(taskText: String(repeating: "move the first three tasks ", count: 20),
                                         resultText: String(repeating: "only the first one moved ", count: 40), succeeded: false,
                                         moveSummaries: (1...200).map { "drag:task \($0)" }, endedAt: Date())
        let now = Date()
        let median = medianMilliseconds {
            _ = record.talkerLine(now: now)
            _ = record.requestPromptSection(now: now)
            _ = DottieLastScreenJob.finishShouldCarryOn(answer: "I haven't finished this yet. Only the first move appears to have gone through")
        }
        #expect(median < 5, "the last job's record took \(median) ms")
    }

    /// Every screen-job step may do a saved task's step and note remembered
    /// clicks on Jev's options; on a busy screen (400 texts, 255 options,
    /// 40 remembered clicks) both must cost next to nothing.
    @Test func savedStepsAndRememberedClickNotesStayQuick() {
        let screenTexts = (0..<400).map { DottieJevDriverPlan.ScreenText(text: "Row \($0) of the sheet (\($0) items)", centerX: 500, centerY: Double($0) * 2) }
        let savedStep = DottieAppTaskPlan.step(from: .click(label: "Row 399 of the sheet (3 items)", centerX: 500, centerY: 798),
                                               pageTitle: "Sheet", requestText: "open row")!
        let options = (0..<255).map { DottieJevDriverPlan.Option(key: "o\($0)", move: .click(label: "Button number \($0)", centerX: 1, centerY: 1)) }
        let clicks = (0..<DottieAppMemoryPlan.maximumClicksPerPage).map {
            DottieAppPage.Click(label: "Button number \($0)", centerX: 10, centerY: Double($0), resultPageKey: "page \($0)",
                                resultPageTitle: "Page", timesSeen: $0, lastSeen: Date())
        }
        let memoryPage = DottieAppPage(key: "home", title: "Home", elements: [], clicks: clicks, lastSeen: Date(), screenshotFileName: nil)
        let median = medianMilliseconds {
            for _ in 0..<5 {
                _ = DottieAppTaskPlan.replayStep(savedStep, recordedForRequest: "open row", newRequest: "open row",
                                                 screenTexts: screenTexts, screenControls: [], frontSiteHost: nil, frontAppName: nil)
                _ = DottieAppMemoryPlan.optionsNotingRememberedClicks(options, on: memoryPage)
            }
        }

        #expect(median < 300, "5 steps of saved-task checks and option notes took \(median) ms")
    }

    /// Jev's hover moves on a packed screen that talks about menus, and the
    /// pointer's glide, as each step builds them.
    @Test func hoverMovesAndPointerGlidesStayQuick() {
        let screenTexts = (0..<300).map { DottieJevDriverPlan.ScreenText(text: "Menu \($0)", centerX: Double($0 % 30) * 30, centerY: Double($0)) }
        let screenControls = (0..<100).map { DottieJevDriverPlan.ScreenControl(label: "Tool \($0)", kind: "menu", centerX: 900, centerY: Double($0)) }
        let median = medianMilliseconds {
            for _ in 0..<20 {
                _ = DottieJevDriverPlan.hoverMoves(screenTexts: screenTexts, screenControls: screenControls, taskText: "open the file menu and pick export")
                _ = DottieScreenJobPointerPlan.glidePath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 2000, y: 1200))
            }
        }
        #expect(median < 50, "20 steps of hover moves and glides took \(median) ms")
    }

    /// Watch me compares every frame with the last (every 2 s) and cuts a
    /// long tour into parts once, both on the Mac.
    @Test func watchMeFrameChecksAndTourPartsStayQuick() {
        let pixelCount = DottieWatchPlan.fingerprintWidth * DottieWatchPlan.fingerprintHeight
        let firstFrame = (0..<pixelCount).map { UInt8($0 % 200) }
        var secondFrame = firstFrame
        secondFrame[pixelCount / 2] = 255
        let actions = (0..<1000).map { index in
            DottieWatchedAction(kind: index % 12 == 0 ? .narration : .click, label: "Item \(index)", text: "note",
                                pageTitle: "Page \(index / 40)", placeKey: "localhost", secondsIntoWatch: Double(index))
        }
        let median = medianMilliseconds {
            for _ in 0..<20 {
                _ = DottieWatchPlan.isSameScreen(firstFrame, secondFrame)
            }
            _ = DottieWatchPlan.tourParts(of: actions)
            _ = DottieWatchPlan.steps(from: actions, exampleRequest: "add a patient named Jane Doe")
        }
        #expect(median < 60, "20 frame checks and a 1,000-action tour took \(median) ms")
    }
}
