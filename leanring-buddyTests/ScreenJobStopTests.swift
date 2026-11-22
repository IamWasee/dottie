//
//  ScreenJobStopTests.swift
//  leanring-buddyTests
//
//  A stopped screen job always says where it got to (round 2 of 1.0.80: a
//  Notes job stopped after 24 steps with no word to the user).
//

import Testing
@testable import Dottie

struct ScreenJobStopTests {
    @Test func stoppedByTheUserSaysHowFarItGot() {
        let summary = ScreenJobStopReason.summary(taskText: "make a note called groceries", lastStepText: "Step 24: typing milk", reason: .stopButton)
        #expect(summary.title == "Stopped: make a note called groceries")
        #expect(summary.text == "You stopped it. It got as far as: Step 24: typing milk")
    }

    @Test func eachReasonHasItsOwnWords() {
        let texts = ScreenJobStopReason.allCases.map { ScreenJobStopReason.summary(taskText: "x", lastStepText: "step 1", reason: $0).text }
        #expect(texts[0].hasPrefix("You stopped it"))
        #expect(texts[1].hasPrefix("You stopped it"))
        #expect(texts[2].hasPrefix("Stopped because you asked"))
        #expect(texts[3].hasPrefix("Stopped so the guide could start"))
    }

    @Test func noStepYetSaysSo() {
        let summary = ScreenJobStopReason.summary(taskText: "open notes", lastStepText: "  ", reason: .escape)
        #expect(summary.text == "You stopped it before its first step.")
    }

    @Test func noTaskTextStillHasATitle() {
        #expect(ScreenJobStopReason.summary(taskText: nil, lastStepText: "", reason: .stopButton).title == "Stopped the screen job")
        #expect(ScreenJobStopReason.summary(taskText: "   ", lastStepText: "", reason: .stopButton).title == "Stopped the screen job")
    }

    @Test func longTextsAreCutShort() {
        let summary = ScreenJobStopReason.summary(taskText: String(repeating: "a", count: 300), lastStepText: String(repeating: "b", count: 400), reason: .askedToStop)
        #expect(summary.title.count <= "Stopped: ".count + 80)
        #expect(summary.title.hasSuffix("…"))
        #expect(summary.text.count < 250)
    }

    @Test func reasonsReadAsWordsInTheLog() {
        #expect(ScreenJobStopReason.stopButton.rawValue == "stop button")
        #expect(ScreenJobStopReason.guideStarted.rawValue == "a guide started")
    }
}
