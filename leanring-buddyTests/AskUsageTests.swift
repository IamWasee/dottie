//
//  AskUsageTests.swift
//  leanring-buddyTests
//
//  Per-ask usage: reading the Worker's dottieUsage, the public log line
//  (model names and numbers always show, so a tester's log has them),
//  numbering asks, and the per-provider dollars for Settings → Usage.
//

import Foundation
import Testing
@testable import Dottie

struct AskUsageTests {
    private let claudeEvent: [String: Any] = [
        "candidates": [],
        "dottieUsage": ["provider": "claude", "model": "claude-haiku-5-5", "inputTokens": 2000, "outputTokens": 20, "seconds": 1.25, "estimatedDollars": 0.00021]
    ]

    @Test func readsTheWorkersUsage() throws {
        let usage = try #require(DottieAskUsage.fromAnswerEvent(claudeEvent))
        #expect(usage == DottieAskUsage(provider: "claude", model: "claude-haiku-5-5", inputTokens: 2000, outputTokens: 20, seconds: 1.25, estimatedDollars: 0.00021))
    }

    @Test func aMissingPriceIsUnknownNotZero() throws {
        let event: [String: Any] = ["dottieUsage": ["provider": "glm", "model": "glm-5.3-flash", "inputTokens": 10, "outputTokens": 5, "seconds": 0.8, "estimatedDollars": NSNull()]]
        let usage = try #require(DottieAskUsage.fromAnswerEvent(event))
        #expect(usage.estimatedDollars == nil)
        #expect(usage.dollarsText == "$?")
    }

    @Test func noUsageOrNoNameIsNil() {
        #expect(DottieAskUsage.fromAnswerEvent([:]) == nil)
        #expect(DottieAskUsage.fromAnswerEvent(["dottieUsage": "text"]) == nil)
        #expect(DottieAskUsage.fromAnswerEvent(["dottieUsage": ["model": "x"]]) == nil)
        #expect(DottieAskUsage.fromAnswerEvent(["dottieUsage": ["provider": "", "model": "x"]]) == nil)
        #expect(DottieAskUsage.fromAnswerEvent(["dottieUsage": ["provider": "glm"]]) == nil)
    }

    @Test func badNumbersBecomeZeroNotNegative() throws {
        let event: [String: Any] = ["dottieUsage": ["provider": "groq", "model": "gpt", "inputTokens": -4, "seconds": -1, "estimatedDollars": -2]]
        let usage = try #require(DottieAskUsage.fromAnswerEvent(event))
        #expect(usage.inputTokens == 0)
        #expect(usage.outputTokens == 0)
        #expect(usage.seconds == 0)
        #expect(usage.estimatedDollars == 0)
    }

    @Test func readsTheLastEventOfAStreamedAnswer() throws {
        let streamedAnswer = """
        data: {"candidates":[]}\r
        \r
        data: {"candidates":[],"dottieUsage":{"provider":"glm","model":"glm-5.3-flash","inputTokens":1,"outputTokens":2,"seconds":3}}\r
        : ping
        data: not json
        """
        let usage = try #require(DottieAskUsage.fromServerSentEvents(streamedAnswer))
        #expect(usage.provider == "glm")
        #expect(usage.outputTokens == 2)
        #expect(DottieAskUsage.fromServerSentEvents("data: {\"candidates\":[]}") == nil)
        #expect(DottieAskUsage.fromServerSentEvents("") == nil)
    }

    @Test func jevIsCountedAtItsFlatPrice() {
        let usage = DottieAskUsage.jevAnswer(seconds: 0.7)
        #expect(usage.provider == "jev")
        #expect(usage.estimatedDollars == DottieAskUsage.jevDollarsPerAnswer)
        #expect(DottieAskUsage.jevAnswer(seconds: -1).seconds == 0)
    }

    @Test func dollarsAreWrittenReadably() {
        #expect(DottieAskUsage.dollarsText(0) == "$0")
        #expect(DottieAskUsage.dollarsText(0.00021) == "$0.00021")
        #expect(DottieAskUsage.dollarsText(1.5) == "$1.50")
        #expect(DottieAskUsage.dollarsText(0.01) == "$0.01")
    }

    @Test func theLogLineNamesTheAskTheModelAndTheCost() throws {
        let usage = try #require(DottieAskUsage.fromAnswerEvent(claudeEvent))
        let logText = usage.logText(askNumber: 7, area: "Voice")
        #expect(logText == "💵 usage ask 7 · Voice · claude/claude-haiku-5-5 · 2000 in / 20 out · 1.25 s · $0.00021")
    }

    @Test func theLogLineShowsEvenWithDetailsHidden() throws {
        let usage = try #require(DottieAskUsage.fromAnswerEvent(claudeEvent))
        let message: DottieLogMessage = "\(public: usage.logText(askNumber: 3, area: "Voice"))"
        #expect(message.textWithoutDetails == message.textWithDetails)
        #expect(message.textWithoutDetails.contains("claude-haiku-5-5"))
        #expect(!message.textWithoutDetails.contains(DottieLogMessage.hiddenValueMarker))
    }

    @Test func publicAndHiddenValuesMixInOneLine() {
        let modelName = "glm-5.3-flash"
        let spokenWords = "open notes"
        let message: DottieLogMessage = "\(public: modelName) answered \(spokenWords)"
        #expect(message.textWithoutDetails == "glm-5.3-flash answered ‹…›")
        #expect(message.textWithDetails == "glm-5.3-flash answered open notes")
    }

    @Test func eachNewAskGetsTheNextNumber() {
        let firstNumber = DottieAskCounter.startNewAsk()
        #expect(DottieAskCounter.currentAskNumber >= firstNumber)
        let secondNumber = DottieAskCounter.startNewAsk()
        #expect(secondNumber > firstNumber)
    }

    @Test func providerTotalsAddDollarsAndCountAnswersWithoutAPrice() {
        var totals = DottieUsage.ProviderTotals()
        totals = DottieUsage.adding(DottieAskUsage(provider: "glm", model: "glm", inputTokens: 100, outputTokens: 10, seconds: 2, estimatedDollars: 0.001), to: totals)
        totals = DottieUsage.adding(DottieAskUsage(provider: "glm", model: "glm", inputTokens: 50, outputTokens: 5, seconds: 1, estimatedDollars: nil), to: totals)
        #expect(totals.answers == 2)
        #expect(totals.inputTokens == 150)
        #expect(totals.outputTokens == 15)
        #expect(totals.seconds == 3)
        #expect(abs(totals.dollars - 0.001) < 1e-12)
        #expect(totals.answersWithoutPrice == 1)
        #expect(DottieUsage.providerDetailText(totals) == "$0.00100 · 2 answers (1 without a price)")
    }

    @Test func providerTotalsOfTwoDaysCombine() {
        let first = DottieUsage.ProviderTotals(answers: 1, inputTokens: 1, outputTokens: 2, seconds: 1, dollars: 0.5, answersWithoutPrice: 0)
        let second = DottieUsage.ProviderTotals(answers: 2, inputTokens: 3, outputTokens: 4, seconds: 2, dollars: 0.25, answersWithoutPrice: 1)
        let combined = DottieUsage.combined(first, second)
        #expect(combined == DottieUsage.ProviderTotals(answers: 3, inputTokens: 4, outputTokens: 6, seconds: 3, dollars: 0.75, answersWithoutPrice: 1))
        #expect(DottieUsage.providerDetailText(DottieUsage.ProviderTotals(answers: 1, dollars: 2)) == "$2.00 · 1 answer")
    }

    @Test func daysSavedBeforeProviderTotalsStillLoad() throws {
        let oldSavedDay = #"{"areas":{"Voice":{"inputTokens":5,"outputTokens":6,"requests":1,"seconds":0}},"voiceAnswerStartSecondsTotal":0,"voiceAnswerStartCount":0}"#
        let decodedDay = try JSONDecoder().decode(DottieUsage.DayTotals.self, from: Data(oldSavedDay.utf8))
        #expect(decodedDay.providers == nil)
        #expect(decodedDay.areas["Voice"]?.inputTokens == 5)
    }

    @Test func readingManyAnswersIsQuick() {
        let streamedAnswer = (0..<200).map { index in
            "data: {\"candidates\":[],\"dottieUsage\":{\"provider\":\"glm\",\"model\":\"glm\",\"inputTokens\":\(index),\"outputTokens\":1,\"seconds\":0.1}}"
        }.joined(separator: "\r\n")
        let startTime = Date()
        for _ in 0..<20 {
            _ = DottieAskUsage.fromServerSentEvents(streamedAnswer)
        }
        #expect(Date().timeIntervalSince(startTime) < 2.0)
    }
}
