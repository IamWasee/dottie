//
//  NotchScreenTaskCardTests.swift
//  leanring-buddyTests
//
//  The notch's screen-task card (current step and Stop) shows as soon as
//  a job starts, even mid-turn, and stays instead of the "on it" answer.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct NotchScreenTaskCardTests {
    @Test func jobStartedWhileThinkingShowsItsCardAtOnce() {
        let notchPresenter = NotchPresenter()
        notchPresenter.showThinking()
        notchPresenter.showScreenTaskStep("opening gmail")
        #expect(notchPresenter.surface == .screenTask)
    }

    @Test func theOnItAnswerDoesNotHideARunningJob() {
        let notchPresenter = NotchPresenter()
        notchPresenter.showScreenTaskStep("opening gmail")
        notchPresenter.showSpeaking()
        notchPresenter.showFinishedResponse("on it, opening your first email.")
        #expect(notchPresenter.surface == .screenTask)
    }

    @Test func aStepReplacesAnAnswerCardButNotTypingOrSpeaking() {
        #expect(NotchPresenter.screenTaskTakesOver(from: .compact))
        #expect(NotchPresenter.screenTaskTakesOver(from: .thinking))
        #expect(NotchPresenter.screenTaskTakesOver(from: .textResponse))
        #expect(!NotchPresenter.screenTaskTakesOver(from: .textInput))
        #expect(!NotchPresenter.screenTaskTakesOver(from: .listening))
        #expect(!NotchPresenter.screenTaskTakesOver(from: .speaking))
    }

    @Test func answersShowNormallyOnceTheJobEnds() {
        let notchPresenter = NotchPresenter()
        notchPresenter.showScreenTaskStep("opening gmail")
        notchPresenter.endScreenTask()
        #expect(notchPresenter.surface == .compact)
        notchPresenter.showFinishedResponse("your first email is from google.")
        #expect(notchPresenter.surface == .textResponse)
    }
}
