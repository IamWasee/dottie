//
//  MausBotIdlePauseTests.swift
//  leanring-buddyTests
//
//  Which of Dottie's MausBot bots get paused so MausBot's nightly memory
//  run skips them (about $0.11 a night for six idle helpers), and that a
//  paused bot is woken before its next turn.
//

import Foundation
import Testing
@testable import Dottie

struct MausBotIdlePauseTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    @Test func aBotIdleTwentyHoursIsPausedAndOneUsedTodayIsNot() {
        var record = DottieMausBotIdleRecord()
        record.noteTurnStarted(botID: "organizer", at: hoursAgo(30))
        record.noteTurnStarted(botID: "screen-jobs", at: hoursAgo(2))
        record.noteTurnStarted(botID: "guide", at: hoursAgo(20))
        #expect(record.botIDsToPause(now: now) == ["guide", "organizer"])
    }

    @Test func aBotIsPausedOnlyOnce() {
        var record = DottieMausBotIdleRecord()
        record.noteTurnStarted(botID: "jarvis", at: hoursAgo(48))
        record.notePaused(botID: "jarvis")
        #expect(record.botIDsToPause(now: now).isEmpty)
    }

    @Test func aPausedBotIsWokenBeforeItsTurnAndCountsAsUsed() {
        var record = DottieMausBotIdleRecord()
        record.noteTurnStarted(botID: "gamer", at: hoursAgo(40))
        record.notePaused(botID: "gamer")
        #expect(record.needsResumeBeforeTurn(botID: "gamer"))
        record.noteTurnStarted(botID: "gamer", at: now)
        #expect(!record.needsResumeBeforeTurn(botID: "gamer"))
        #expect(record.botIDsToPause(now: now).isEmpty)
        // Idle again a day later: paused again.
        #expect(record.botIDsToPause(now: now.addingTimeInterval(21 * 3600)) == ["gamer"])
    }

    @Test func botsDottieNeverPausedAreNeverResumed() {
        let record = DottieMausBotIdleRecord()
        // A bot the user paused in MausBot isn't in Dottie's record.
        #expect(!record.needsResumeBeforeTurn(botID: "users-own-bot"))
        #expect(record.botIDsToPause(now: now).isEmpty)
    }

    @Test func theRecordSurvivesSavingAndLoading() throws {
        var record = DottieMausBotIdleRecord()
        record.noteTurnStarted(botID: "programmer", at: hoursAgo(25))
        record.notePaused(botID: "programmer")
        let loaded = try JSONDecoder().decode(DottieMausBotIdleRecord.self, from: JSONEncoder().encode(record))
        #expect(loaded == record)
    }
}
