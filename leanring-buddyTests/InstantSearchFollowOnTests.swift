//
//  InstantSearchFollowOnTests.swift
//  leanring-buddyTests
//
//  The instant lane's YouTube and Google searches only take a search.
//  "search youtube for mrbeast and click on the first video" put the whole
//  sentence into YouTube's search box on Wasee's Mac; a search that goes on
//  to another step ("and click…", "then play…") now goes to a screen job.
//  Also: Jev rests one minute after a failure, and a step model that stops
//  answering tells the user when to try again.
//

import Foundation
import Testing
@testable import Dottie

struct InstantSearchFollowOnWordTests {
    @Test func aClickAfterAndIsAFollowOnStep() {
        #expect(DottieInstantText.hasFollowOnInstruction("mrbeast and click on the first video you see"))
        #expect(DottieInstantText.hasFollowOnInstruction("a video about ai and click on the most popular"))
    }

    @Test func thenAndAndThenCount() {
        #expect(DottieInstantText.hasFollowOnInstruction("cats then play the second one"))
        #expect(DottieInstantText.hasFollowOnInstruction("lofi music and then play it"))
    }

    @Test func otherActionsCountToo() {
        for followOn in ["open", "watch", "subscribe", "tell", "pick", "select", "scroll"] {
            #expect(DottieInstantText.hasFollowOnInstruction("mr beast and \(followOn) something"))
        }
    }

    @Test func plainSearchesWithAndAreNotFollowOnSteps() {
        #expect(!DottieInstantText.hasFollowOnInstruction("salt and pepper"))
        #expect(!DottieInstantText.hasFollowOnInstruction("tom and jerry"))
        #expect(!DottieInstantText.hasFollowOnInstruction("mr beast"))
        #expect(!DottieInstantText.hasFollowOnInstruction(""))
    }

    @Test func anActionWordWithoutAndIsNotAFollowOnStep() {
        #expect(!DottieInstantText.hasFollowOnInstruction("how to play guitar"))
        #expect(!DottieInstantText.hasFollowOnInstruction("click sound effect"))
    }

    @Test func aTrailingAndIsNotAFollowOnStep() {
        #expect(!DottieInstantText.hasFollowOnInstruction("mr beast and"))
        #expect(!DottieInstantText.hasFollowOnInstruction("mr beast and then"))
    }

    @Test func punctuationAndCapitalsDontHideIt() {
        #expect(DottieInstantText.hasFollowOnInstruction("MrBeast, and CLICK the first video"))
    }

    @Test func checkingIsQuick() {
        let startedAt = Date()
        for _ in 0..<5000 {
            _ = DottieInstantText.hasFollowOnInstruction("a video about ai and click on the most popular one please")
        }
        #expect(Date().timeIntervalSince(startedAt) < 0.5)
    }
}

@MainActor
struct InstantSearchFollowOnCommandTests {
    @Test func aSearchWithAFollowOnStepIsNotInstant() {
        #expect(DottieInstantCommands.parseAll("search youtube for mrbeast and click on the first video you see") == nil)
        #expect(DottieInstantCommands.parseAll("open youtube and search up a video about ai and click on the most popular") == nil)
        #expect(DottieInstantCommands.parseAll("google best pizza near me and open the first result") == nil)
    }

    @Test func aPlainSearchStaysInstant() throws {
        let commands = try #require(DottieInstantCommands.parseAll("search youtube for mr beast"))
        guard case .openSearch(let url, _) = try #require(commands.first) else { Issue.record("expected a search"); return }
        #expect(url.absoluteString.contains("search_query=mr%20beast"))
        #expect(!url.absoluteString.contains("click"))
    }

    @Test func aSearchForThingsJoinedByAndStaysOneSearch() throws {
        let commands = try #require(DottieInstantCommands.parseAll("google salt and pepper"))
        #expect(commands.count == 1)
        guard case .openSearch(let url, _) = try #require(commands.first) else { Issue.record("expected a search"); return }
        #expect(url.absoluteString.contains("salt"))
        #expect(url.absoluteString.contains("pepper"))
    }
}

@MainActor
struct JevRecoveryTimeTests {
    @Test func jevIsLeftAloneForOneMinuteAfterAFailure() {
        #expect(DottieJev.pauseAfterFailureSeconds == 60)
    }
}

@MainActor
struct StepModelFailureMessageTests {
    @Test func aBusyModelTellsTheUserToWaitAMinute() {
        let reason = DottieScreenTaskRunner.stepModelFailureReason(statusCode: 503, wasBusy: true)
        #expect(reason.contains("too busy"))
        #expect(reason.contains("Wait about a minute"))
        #expect(reason.contains("ask me again"))
    }

    @Test func anEmptyAnswerSaysSoAndToTryAgain() {
        let reason = DottieScreenTaskRunner.stepModelFailureReason(statusCode: -2, wasBusy: false)
        #expect(reason.contains("an empty answer"))
        #expect(reason.contains("try again"))
    }

    @Test func anotherErrorNamesItsCodeAndToTryAgain() {
        let reason = DottieScreenTaskRunner.stepModelFailureReason(statusCode: 400, wasBusy: false)
        #expect(reason.contains("error 400"))
        #expect(reason.contains("Wait a few seconds"))
    }
}
