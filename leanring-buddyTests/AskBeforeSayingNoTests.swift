//
//  AskBeforeSayingNoTests.swift
//  leanring-buddyTests
//
//  Tests for the rule that Dottie offers to do an ask on the user's screen,
//  and asks first, instead of saying she can't when no connected app or key
//  covers it ("check my emails" with no Google connection). Covers the rule
//  itself, that it reaches the voice prompt with every personality, that
//  helpers get the same rule, and how fast the voice prompt is built.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct AskBeforeSayingNoTests {
    private let rule = DottieWorkRoutes.voiceAskBeforeSayingNo

    @Test func theRuleOffersTheScreenAndAsksFirst() {
        #expect(rule.contains("offer the screen in one short question"))
        #expect(rule.contains("want me to open it on your screen"))
        #expect(rule.contains("when they say yes, call do_task_on_screen"))
    }

    @Test func theRuleCoversEveryKindOfAskNotOnlyEmail() {
        #expect(rule.contains("every kind of ask, not only email"))
        #expect(rule.contains("calendar"))
        #expect(rule.contains("a site or account"))
    }

    @Test func theRuleStillRefusesHarmAndKeepsTheConfirmationsForRiskySteps() {
        #expect(rule.contains("refuse only what's harmful or illegal"))
        #expect(rule.contains("paying, sending, posting or deleting still waits for their yes"))
    }

    @Test func theRuleOnlyAdmitsFailureAfterTheScreenJobReallyFailed() {
        #expect(rule.contains("only after the screen job really failed"))
        #expect(rule.contains("say what it tried"))
    }

    @Test func everyPersonalitysVoicePromptCarriesTheRule() {
        for personality in DottiePersonality.allCases {
            let prompt = CompanionManager.liveVoiceSystemPrompt(personality: personality)
            #expect(prompt.contains(rule), "\(personality.rawValue) should carry the ask-first rule")
        }
    }

    @Test func theRuleComesAfterTheToolLinesSoItIsReadAsTheLastWordOnSayingNo() throws {
        let prompt = CompanionManager.liveVoiceSystemPrompt(personality: .cheekyFriend)
        let toolsLineRange = try #require(prompt.range(of: "more tools: find_tool"))
        let ruleRange = try #require(prompt.range(of: rule))
        #expect(toolsLineRange.lowerBound < ruleRange.lowerBound)
    }

    @Test func helpersAreToldAMissingKeyIsNeverTheEnd() {
        let helperInstructions = DottieWorkRoutes.helperInstructions
        #expect(helperInstructions.contains("A missing key, sign-in or connected app is never the end"))
        #expect(helperInstructions.contains("Never answer that you can't before trying them"))
        #expect(helperInstructions.contains("only harmful or illegal asks are refused"))
    }

    @Test func helpersStillAskBeforePayingSendingOrDeleting() {
        #expect(DottieWorkRoutes.helperInstructions.contains("Before anything that pays, sends or posts for the user"))
    }

    @Test func buildingTheVoicePromptStaysQuick() {
        let startedAt = Date()
        for _ in 0..<50 {
            _ = CompanionManager.liveVoiceSystemPrompt(personality: .patientTutor)
        }
        let averageSeconds = Date().timeIntervalSince(startedAt) / 50
        #expect(averageSeconds < 0.05, "building the voice prompt took \(averageSeconds) s")
    }
}
