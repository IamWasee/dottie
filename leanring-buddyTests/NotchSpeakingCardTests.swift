//
//  NotchSpeakingCardTests.swift
//  leanring-buddyTests
//
//  The speaking card never gets stuck: it has a close button that stops
//  the voice, and once the voice goes idle it turns into the answer card,
//  which closes by itself. On celly's Mac a screen job's result was said,
//  the card switched to "speaking" and stayed there with no way to close it.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct NotchSpeakingCardTests {
    @Test func closeButtonStopsTheVoiceAndFoldsTheCard() {
        let notchPresenter = NotchPresenter()
        var stopSpeakingCallCount = 0
        notchPresenter.onStopSpeaking = { stopSpeakingCallCount += 1 }
        notchPresenter.updateLiveCaption("i moved one of the three tasks.")
        notchPresenter.showSpeaking()
        #expect(notchPresenter.surface == .speaking)

        notchPresenter.closeSpeakingCard()

        #expect(stopSpeakingCallCount == 1)
        #expect(notchPresenter.surface == .compact)
    }

    @Test func closingWithNoVoiceHookStillFoldsTheCard() {
        let notchPresenter = NotchPresenter()
        notchPresenter.showSpeaking()
        notchPresenter.closeSpeakingCard()
        #expect(notchPresenter.surface == .compact)
    }

    /// The screen-job result path: answer card first, then the voice starts
    /// (speaking card), then the voice goes idle and the idle handler turns
    /// the speaking card back into the answer card with its timer.
    @Test func aJobResultSaidAfterItsCardEndsOnTheAnswerCardAgain() {
        let notchPresenter = NotchPresenter()
        let resultLine = "i moved one of the three tasks; the other two are still in to do."
        notchPresenter.updateLiveCaption(resultLine)
        notchPresenter.showFinishedResponse(resultLine)
        #expect(notchPresenter.surface == .textResponse)

        notchPresenter.showSpeaking()
        #expect(notchPresenter.surface == .speaking)

        // What CompanionManager's idle handler does for a speaking card.
        notchPresenter.showFinishedResponse(notchPresenter.liveCaptionText)
        #expect(notchPresenter.surface == .textResponse)
        #expect(notchPresenter.lastResponseText == resultLine)
    }

    @Test func aRunningJobsCardComesBackAfterTheSpeakingCardCloses() {
        let notchPresenter = NotchPresenter()
        notchPresenter.showScreenTaskStep("moving the second task")
        notchPresenter.showSpeaking()
        notchPresenter.closeSpeakingCard()
        #expect(notchPresenter.surface == .screenTask)
    }

    @Test func closingTheSpeakingCardIsQuick() {
        let notchPresenter = NotchPresenter()
        let startedAt = Date()
        for _ in 0..<1000 {
            notchPresenter.showSpeaking()
            notchPresenter.closeSpeakingCard()
        }
        #expect(Date().timeIntervalSince(startedAt) < 0.5)
    }
}
