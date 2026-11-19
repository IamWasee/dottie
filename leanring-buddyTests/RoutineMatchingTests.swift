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
}
