//
//  LiveHistoryCarryTests.swift
//  leanring-buddyTests
//
//  Unit tests for the earlier conversation a new Gemini Live session is
//  given: it says the conversation is over, so a "hello" after reopening
//  Dottie isn't answered with the request before it.
//

import Testing
@testable import Dottie

struct LiveHistoryCarryTests {
    @Test func noHistoryAddsNothing() {
        #expect(GeminiLiveVoiceClient.carriedHistoryText(for: []) == nil)
    }

    @Test func theHistoryIsMarkedOverAndCutOffAnswersAreLabeled() throws {
        let historyText = try #require(GeminiLiveVoiceClient.carriedHistoryText(for: [
            (userTranscript: "my name is celly", modelTranscript: "nice to meet you, celly"),
            (userTranscript: "move my dentist event to tomorrow", modelTranscript: "")
        ]))
        #expect(historyText.contains("user: my name is celly\nyou: nice to meet you, celly"))
        #expect(historyText.contains("you: (no answer, it was cut off)"))
        #expect(historyText.contains("that conversation is over"))
        #expect(historyText.contains("a greeting gets a greeting"))
    }

    @Test func onlyTheLastEightExchangesAreCarried() throws {
        let history = (1...10).map { exchangeNumber in
            (userTranscript: "question \(exchangeNumber)", modelTranscript: "answer \(exchangeNumber)")
        }
        let historyText = try #require(GeminiLiveVoiceClient.carriedHistoryText(for: history))
        #expect(historyText.contains("question 2\n") == false)
        #expect(historyText.contains("question 3\n"))
        #expect(historyText.contains("question 10\n"))
    }
}
