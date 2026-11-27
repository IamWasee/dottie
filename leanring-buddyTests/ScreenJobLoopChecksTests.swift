//
//  ScreenJobLoopChecksTests.swift
//  leanring-buddyTests
//
//  Unit tests for the small checks a screen job leans on while it works:
//  did the last action do anything, is the job going in circles, did a step
//  really happen (so it may be saved for a replay), and which screenshots
//  stay in the conversation. A mistake here makes Dottie repeat a click
//  forever, or save a step that never worked.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct ScreenJobResultTests {

    @Test func actionsThatHappenedCountAsDone() {
        #expect(DottieScreenTaskRunner.resultLooksDone("clicked Sign in"))
        #expect(DottieScreenTaskRunner.resultLooksDone("typed it and pressed return"))
        #expect(DottieScreenTaskRunner.resultLooksDone("opened https://example.com"))
        #expect(DottieScreenTaskRunner.resultLooksDone("zoomed in; the close-up comes with the next screenshot."))
    }

    @Test func errorsRefusalsAndStopsDoNot() {
        #expect(!DottieScreenTaskRunner.resultLooksDone("error: no text"))
        #expect(!DottieScreenTaskRunner.resultLooksDone("Error: no text"))
        #expect(!DottieScreenTaskRunner.resultLooksDone("couldn't find an app called Notes"))
        #expect(!DottieScreenTaskRunner.resultLooksDone("unknown key q; use names like cmd+l"))
        #expect(!DottieScreenTaskRunner.resultLooksDone("refused: that's a password box"))
        #expect(!DottieScreenTaskRunner.resultLooksDone("not clicked: you've already clicked this 3 times."))
        #expect(!DottieScreenTaskRunner.resultLooksDone("stopped"))
    }
}

@MainActor
struct ScreenJobSameScreenTests {

    /// A fingerprint the size the runner makes (64 by 40), all one shade.
    private func fingerprint(changedPixelCount: Int, changedBy difference: UInt8) -> (before: [UInt8], after: [UInt8]) {
        let before = [UInt8](repeating: 100, count: 64 * 40)
        var after = before
        for pixelIndex in 0..<changedPixelCount {
            after[pixelIndex] = 100 + difference
        }
        return (before, after)
    }

    @Test func identicalScreensAreTheSame() {
        let screens = fingerprint(changedPixelCount: 0, changedBy: 0)
        #expect(DottieScreenTaskRunner.isSameScreen(screens.before, screens.after))
    }

    @Test func aBlinkingCaretStillCountsAsTheSame() {
        // 7 of 2560 pixels is under the 0.3% that counts as a change.
        let screens = fingerprint(changedPixelCount: 7, changedBy: 80)
        #expect(DottieScreenTaskRunner.isSameScreen(screens.before, screens.after))
    }

    @Test func oneMorePixelThanThatIsAChange() {
        let screens = fingerprint(changedPixelCount: 8, changedBy: 80)
        #expect(!DottieScreenTaskRunner.isSameScreen(screens.before, screens.after))
    }

    @Test func aFaintShiftInShadeIsNotAChange() {
        // Every pixel moved, but by 12 or less, which is noise.
        let screens = fingerprint(changedPixelCount: 64 * 40, changedBy: 12)
        #expect(DottieScreenTaskRunner.isSameScreen(screens.before, screens.after))
    }

    @Test func emptyOrMismatchedFingerprintsAreNeverTheSame() {
        #expect(!DottieScreenTaskRunner.isSameScreen([], []))
        #expect(!DottieScreenTaskRunner.isSameScreen([1, 2, 3], [1, 2]))
    }
}

@MainActor
struct ScreenJobRepeatedActionTests {

    @Test func signatureNamesTheActionAndWhatItWasOn() {
        let clickArguments: [String: Any] = ["label": "Sign in", "box_2d": [1, 2, 3, 4]]
        #expect(DottieScreenTaskRunner.signature(functionName: "click", arguments: clickArguments) == "click \"Sign in\"")

        let scrollArguments: [String: Any] = ["direction": "down"]
        #expect(DottieScreenTaskRunner.signature(functionName: "scroll", arguments: scrollArguments) == "scroll \"down\"")
    }

    @Test func signatureWithNothingToNameIsJustTheAction() {
        let noArguments: [String: Any] = [:]
        #expect(DottieScreenTaskRunner.signature(functionName: "wait", arguments: noArguments) == "wait")
    }

    @Test func signatureKeepsOnlyTheStartOfLongText() {
        let longText = String(repeating: "a", count: 200)
        let typeArguments: [String: Any] = ["text": longText]
        let expectedSignature = "type_text \"" + String(repeating: "a", count: 60) + "\""
        #expect(DottieScreenTaskRunner.signature(functionName: "type_text", arguments: typeArguments) == expectedSignature)
    }

    @Test func nothingDoneYetIsNotARepeat() {
        #expect(DottieScreenTaskRunner.repeatedAction(in: []) == nil)
    }

    @Test func threeOfTheLastFourIsARepeat() {
        let signatures = ["open_app \"Safari\"", "click \"Next\"", "click \"Next\"", "type_text \"hi\"", "click \"Next\""]
        #expect(DottieScreenTaskRunner.repeatedAction(in: signatures) == "click \"Next\"")
    }

    @Test func twoOfTheLastFourIsNot() {
        let signatures = ["click \"Next\"", "type_text \"hi\"", "press_keys \"enter\"", "click \"Next\""]
        #expect(DottieScreenTaskRunner.repeatedAction(in: signatures) == nil)
    }

    @Test func scrollingUpAndDownIsALoop() {
        // The OpenEMR demo (27 Nov): 18 steps of scroll up, scroll down.
        let signatures = ["click \"Male\"", "scroll \"up\"", "scroll \"down\"", "scroll \"up\"", "scroll \"down\""]
        #expect(DottieScreenTaskRunner.repeatedAction(in: signatures) == nil)
        #expect(DottieScreenTaskRunner.alternatingActions(in: signatures) == "scroll \"up\", then scroll \"down\"")
    }

    @Test func aCircleOfThreeIsALoop() {
        let signatures = ["click \"Finder\"", "click \"Patient\"", "click \"New/Search\"", "click \"Finder\"", "click \"Patient\"", "click \"New/Search\""]
        #expect(DottieScreenTaskRunner.alternatingActions(in: signatures) == "click \"Finder\", then click \"Patient\", then click \"New/Search\"")
    }

    @Test func movesThatGoForwardAreNotALoop() {
        #expect(DottieScreenTaskRunner.alternatingActions(in: []) == nil)
        #expect(DottieScreenTaskRunner.alternatingActions(in: ["scroll \"up\"", "scroll \"down\"", "scroll \"up\""]) == nil)
        #expect(DottieScreenTaskRunner.alternatingActions(in: ["type_text \"Maria\"", "type_text \"Lopez\"", "click \"Sex\"", "click \"Female\""]) == nil)
        // The same move four times is a repeat, not a back-and-forth.
        #expect(DottieScreenTaskRunner.alternatingActions(in: [String](repeating: "click \"Next\"", count: 4)) == nil)
    }

    @Test func spottingALoopIsQuick() {
        let signatures = ["a", "b", "c", "a", "b", "d"]
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<20_000 { _ = DottieScreenTaskRunner.alternatingActions(in: signatures) }
        }
        #expect(elapsed < .seconds(1))
    }

    @Test func scrollingMayRepeatFourTimesButNotFive() {
        let fourScrolls = [String](repeating: "scroll \"down\"", count: 4)
        #expect(DottieScreenTaskRunner.repeatedAction(in: fourScrolls) == nil)

        let fiveScrolls = [String](repeating: "scroll \"down\"", count: 5)
        #expect(DottieScreenTaskRunner.repeatedAction(in: fiveScrolls) == "scroll \"down\"")
    }
}

@MainActor
struct ScreenJobScreenshotTrimmingTests {

    private func screenshotTurn(named screenshotName: String) -> [String: Any] {
        let parts: [[String: Any]] = [
            ["inlineData": ["mimeType": "image/jpeg", "data": screenshotName]],
            ["text": "This is the screen now."]
        ]
        return ["role": "user", "parts": parts]
    }

    private func hasScreenshot(_ content: [String: Any]) -> Bool {
        let parts = content["parts"] as? [[String: Any]] ?? []
        return parts.contains { $0["inlineData"] != nil }
    }

    @Test func onlyTheNewestScreenshotsStay() {
        let keptScreenshotCount = DottieScreenTaskRunner.keptScreenshotCount
        var contents = (0..<(keptScreenshotCount + 2)).map { screenshotTurn(named: "screenshot-\($0)") }

        DottieScreenTaskRunner.dropOldScreenshots(from: &contents)

        let turnsStillHoldingAScreenshot = contents.map(hasScreenshot)
        let expected = [false, false] + [Bool](repeating: true, count: keptScreenshotCount)
        #expect(turnsStillHoldingAScreenshot == expected)
    }

    @Test func aRemovedScreenshotLeavesANoteAndTheWordsStay() {
        var contents = (0..<(DottieScreenTaskRunner.keptScreenshotCount + 1)).map { screenshotTurn(named: "screenshot-\($0)") }

        DottieScreenTaskRunner.dropOldScreenshots(from: &contents)

        let oldestParts = contents[0]["parts"] as? [[String: Any]] ?? []
        #expect(oldestParts.count == 2)
        #expect(oldestParts.first?["text"] as? String == "(older screenshot removed)")
        #expect(oldestParts.last?["text"] as? String == "This is the screen now.")
    }

    @Test func aShortConversationIsLeftAlone() {
        var contents = [screenshotTurn(named: "only-screenshot")]

        DottieScreenTaskRunner.dropOldScreenshots(from: &contents)

        #expect(hasScreenshot(contents[0]))
    }
}
