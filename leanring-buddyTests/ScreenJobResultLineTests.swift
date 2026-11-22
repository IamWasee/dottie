//
//  ScreenJobResultLineTests.swift
//  leanring-buddyTests
//
//  What Dottie says when a screen job ends, now said as it is instead of
//  going back through the talker and Claude ($0.03 to $0.05 a job).
//

import Foundation
import Testing
@testable import Dottie

struct ScreenJobResultLineTests {
    @Test func theJobsAnswerIsSaidAsItIs() {
        #expect(DottieScreenJobResultLine.spokenLine(resultText: "Your rank is 312th.") == "Your rank is 312th.")
    }

    @Test func aLowercaseAnswerGetsACapitalAndAFullStop() {
        #expect(DottieScreenJobResultLine.spokenLine(resultText: "  opened the downloads folder ") == "Opened the downloads folder.")
        #expect(DottieScreenJobResultLine.spokenLine(resultText: "is it the blue one?") == "Is it the blue one?")
    }

    @Test func anEmptyAnswerSaysDone() {
        #expect(DottieScreenJobResultLine.spokenLine(resultText: "") == "Done.")
        #expect(DottieScreenJobResultLine.spokenLine(resultText: "   ") == "Done.")
    }

    @Test func aFailureSaysWhatStoppedIt() {
        let line = DottieScreenJobResultLine.spokenLine(resultText: DottieScreenJobResultLine.failurePrefix + "the sign in button never showed up")
        #expect(line == "I couldn't finish that: the sign in button never showed up.")
        #expect(DottieScreenJobResultLine.spokenLine(resultText: DottieScreenJobResultLine.failurePrefix) == "I couldn't finish that.")
    }

    @Test func aSmartReplaysClosingLineIsSaidWordForWord() {
        let line = DottieScreenJobResultLine.spokenLine(resultText: "Done.", closingMessage: "And that's how you post a reel!")
        #expect(line == "And that's how you post a reel!")
        // A blank closing line falls back to the result.
        #expect(DottieScreenJobResultLine.spokenLine(resultText: "Posted.", closingMessage: "  ") == "Posted.")
    }

    @Test func waitingJobsAreMentioned() {
        #expect(DottieScreenJobResultLine.spokenLine(resultText: "Sent.", waitingCount: 2) == "Sent. On to the next one.")
        #expect(DottieScreenJobResultLine.spokenLine(resultText: "Sent.", waitingCount: 0) == "Sent.")
    }

    @Test func theHistoryLineNamesTheJobButStaysShort() {
        let line = DottieScreenJobResultLine.historyUserLine(taskText: "open kaggle")
        #expect(line.contains("open kaggle"))
        let longLine = DottieScreenJobResultLine.historyUserLine(taskText: String(repeating: "a", count: 1000))
        #expect(longLine.count < 260)
    }
}
