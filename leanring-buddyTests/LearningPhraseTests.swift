//
//  LearningPhraseTests.swift
//  leanring-buddyTests
//
//  "Watch me for 30 seconds", "create a smart replay of me doing this" and
//  "done" start and stop watching on the Mac, with no model in between.
//

import Foundation
import Testing
@testable import Dottie

struct LearningPhraseTests {
    private func phrase(_ text: String, watching: Bool = false, recording: Bool = false) -> DottieLearningPhrase? {
        DottieLearningPhrase.phrase(in: DottieInstantText.normalized(text), isWatching: watching, isRecordingReplay: recording)
    }

    @Test func watchMeStartsWatchingWithTheTimeSaid() {
        #expect(phrase("watch me for 30 seconds") == .startWatching(seconds: 30))
        #expect(phrase("Hey Dottie, watch me for a minute") == .startWatching(seconds: 60))
        #expect(phrase("can you watch me for two minutes please") == .startWatching(seconds: 120))
        #expect(phrase("watch me do this") == .startWatching(seconds: nil))
        #expect(phrase("watch me and learn") == .startWatching(seconds: nil))
        #expect(phrase("watch how I do this") == .startWatching(seconds: nil))
    }

    @Test func smartReplayPhrasesStartRecording() {
        #expect(phrase("create a smart replay of me doing this") == .startReplay(kind: "smart"))
        #expect(phrase("make a commercial replay of me doing this") == .startReplay(kind: "commercial"))
        #expect(phrase("record a smart replay") == .startReplay(kind: "smart"))
    }

    @Test func doneStopsOnlyWhileSomethingIsWatched() {
        #expect(phrase("done") == nil)
        #expect(phrase("done", watching: true, recording: true) == .stopWatching)
        #expect(phrase("I'm done", recording: true) == .stopReplay)
        #expect(phrase("stop watching", watching: true) == .stopWatching)
    }

    @Test func otherAsksAreLeftAlone() {
        for text in ["watch youtube", "what should I watch tonight", "open youtube and play mr beast", "watch the download and tell me when it finishes", "replay the last video"] {
            #expect(phrase(text) == nil)
        }
    }

    @Test func eachPhraseNamesTheRightToolCall() {
        #expect(DottieLearningPhrase.startWatching(seconds: 30).toolName == "watch_and_learn")
        #expect(DottieLearningPhrase.startWatching(seconds: 30).toolArguments["seconds"] as? Int == 30)
        #expect(DottieLearningPhrase.startWatching(seconds: nil).toolArguments["seconds"] == nil)
        #expect(DottieLearningPhrase.stopReplay.toolName == "smart_replays")
        #expect(DottieLearningPhrase.stopReplay.toolArguments["action"] as? String == "stop")
        #expect(DottieLearningPhrase.startReplay(kind: "commercial").toolArguments["kind"] as? String == "commercial")
    }

    @Test func toolAnswersBecomeShortLinesForThePerson() {
        let started = DottieLearningPhrase.startWatching(seconds: 30).doneText(forToolResult: "watching for 30 seconds. tell the user to go ahead and do it as they normally would; you'll say what you learned after.")
        #expect(started == "Watching for 30 seconds. Go ahead and do it the way you normally would.")
        let learned = DottieLearningPhrase.stopWatching.doneText(forToolResult: "learned it. what you understood: They made a TEST note and moved it into a folder. tell the user in one or two short lines what you understood.")
        #expect(learned == "Learned it: They made a TEST note and moved it into a folder.")
        let noPermission = DottieLearningPhrase.startWatching(seconds: nil).doneText(forToolResult: "Dottie needs Screen Recording permission to watch.")
        #expect(noPermission == "Dottie needs Screen Recording permission to watch.")
        let saved = DottieLearningPhrase.stopReplay.doneText(forToolResult: "saved the smart replay \"Move a note\": 1. Open Notes 2. Drag it. read the steps back in a few words.")
        #expect(saved == "Saved the smart replay \"Move a note\": 1. Open Notes 2. Drag it.")
    }

    @Test func doingItOnTheMacIsNeverAModelsCall() {
        #expect(!DottieQuickMacActionPlanKind.learningPhrase.mayRunFromAModel)
    }
}
