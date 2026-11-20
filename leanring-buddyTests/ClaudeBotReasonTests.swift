//
//  ClaudeBotReasonTests.swift
//  leanring-buddyTests
//
//  Every screen job on celly's Mac logged "Claude didn't answer, Gemini
//  carries on" with no reason: the paths where MausBot wasn't ready or a
//  turn failed said nothing. They now log why in plain words.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct ClaudeBotReasonTests {
    @Test func eachFallbackReasonHasItsOwnWords() {
        let reasons: [DottieClaudeFallbackReason] = [.usageLimit, .busy, .notSignedIn, .notReachable, .engineProblem("Claude Code isn't installed")]
        let lines = reasons.map { DottieClaudeBot.whyNotReady(.fallback($0)) }
        #expect(Set(lines).count == reasons.count)
        #expect(lines[2].contains("signed in"))
        #expect(lines[4].contains("Claude Code isn't installed"))
    }

    @Test func skippingSaysWhatCanCauseIt() {
        let line = DottieClaudeBot.whyNotReady(.skip)
        #expect(line.contains("aren't set to Claude"))
        #expect(line.contains("paused"))
    }

    @Test func aFailedTurnCarriesItsErrorText() {
        let line = DottieClaudeBot.whyTurnFailed(.finished(succeeded: false, errorText: "429 rate limit"), replyWasEmpty: true)
        #expect(line.contains("429 rate limit"))
        #expect(DottieClaudeBot.whyTurnFailed(.finished(succeeded: false, errorText: nil), replyWasEmpty: true).contains("no error text"))
    }

    @Test func anEmptyReplyIsSaidAsSuch() {
        #expect(DottieClaudeBot.whyTurnFailed(.finished(succeeded: true, errorText: nil), replyWasEmpty: true).contains("empty reply"))
    }

    @Test func everyOtherOutcomeHasWords() {
        let outcomes: [DottieMausBotTurnOutcome] = [
            .needsInput(question: "Allow?", threadID: "thread", since: 0),
            .stillRunning(threadID: "thread", since: 0),
            .stopped,
            .botMissing,
            .fallback(.usageLimit)
        ]
        let lines = outcomes.map { DottieClaudeBot.whyTurnFailed($0, replyWasEmpty: true) }
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(Set(lines).count == outcomes.count)
        #expect(lines[0].contains("approval"))
        #expect(lines[4].contains("usage limit"))
    }

    @Test func wordingIsQuick() {
        let startedAt = Date()
        var lineCount = 0
        for index in 0..<20_000 {
            lineCount += DottieClaudeBot.whyTurnFailed(.finished(succeeded: false, errorText: "error \(index)"), replyWasEmpty: true).isEmpty ? 0 : 1
        }
        #expect(lineCount == 20_000)
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
