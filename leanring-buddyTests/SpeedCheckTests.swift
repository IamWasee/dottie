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
}
