//
//  RoutineMatchingTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieKeepWorking.routineMatches: "stop the bitcoin
//  routine" finds a helper's routine by a word of its title or its
//  helper's name, and doesn't stop unrelated ones.
//

import Foundation
import Testing
@testable import Dottie

struct RoutineMatchingTests {
    @Test func aMeaningfulWordFindsTheRoutine() {
        #expect(DottieKeepWorking.routineMatches(title: "Bitcoin price check", helperName: "TestSonnet", spokenName: "the bitcoin routine"))
        #expect(DottieKeepWorking.routineMatches(title: "BTC 2% watch", helperName: "TestSonnet", spokenName: "TestSonnet"))
        #expect(DottieKeepWorking.routineMatches(title: "Hourly Bitcoin Alert", helperName: "Jarvis", spokenName: "bitcoin"))
    }

    @Test func genericWordsAloneDontMatchEverything() {
        #expect(!DottieKeepWorking.routineMatches(title: "Weather check", helperName: "Jarvis", spokenName: "the bitcoin routine"))
        #expect(!DottieKeepWorking.routineMatches(title: "Weather check", helperName: "Jarvis", spokenName: "the routine"))
        #expect(!DottieKeepWorking.routineMatches(title: "Weather check", helperName: "Jarvis", spokenName: ""))
    }

    @Test func routineListTellsHelpersHowToStopDottiesRoutines() {
        let bitcoinRoutine = ClickyRoutine(
            id: UUID(), agentID: UUID(), title: "Bitcoin Price Alert", task: "check the price",
            everyMinutes: 15, isPaused: false, createdAt: Date(), lastRunStartedAt: Date(),
            runCount: 17, failedRunsInARow: 0
        )
        let context = ClickyRoutinePrompts.currentRoutinesContext(for: [bitcoinRoutine])
        #expect(context.contains("\"Bitcoin Price Alert\""))
        #expect(context.contains("not MausBot triggers"))
        #expect(context.contains("<ROUTINE>{\"action\":\"delete\""))
        #expect(ClickyRoutinePrompts.currentRoutinesContext(for: []) == "[Your current routines: none.]")
    }
}
