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
}
