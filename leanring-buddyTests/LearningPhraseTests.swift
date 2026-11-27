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

    @Test func watchMeWithTheJobPassesItOnAsTheNote() {
        #expect(phrase("watch me add a patient") == .startWatching(seconds: nil, note: "add a patient"))
        #expect(phrase("watch me book an appointment for 2 minutes") == .startWatching(seconds: 120, note: "book an appointment"))
        #expect(phrase("let me show you how to book an appointment") == .startWatching(seconds: nil, note: "how to book an appointment"))
        #expect(phrase("I'm going to show you how I do my timesheet") == .startWatching(seconds: nil, note: "how i do my timesheet"))
        #expect(phrase("start watching") == .startWatching(seconds: nil))
        #expect(phrase("start watching me for ten minutes") == .startWatching(seconds: 600))
    }

    @Test func aTourOfAWholeAppIsATour() {
        #expect(phrase("let me show you around OpenEMR") == .startWatching(seconds: nil, note: "around openemr", isTour: true))
        #expect(phrase("watch me give you a tour of openemr") == .startWatching(seconds: nil, note: "give you a tour of openemr", isTour: true))
        #expect(phrase("I'll show you everything in this app") == .startWatching(seconds: nil, note: "everything in this app", isTour: true))
        let tourArguments = DottieLearningPhrase.startWatching(seconds: nil, note: "around openemr", isTour: true).toolArguments
        #expect(tourArguments["mode"] as? String == "tour")
        #expect(tourArguments["note"] as? String == "around openemr")
        #expect(DottieLearningPhrase.startWatching(seconds: 30).toolArguments["mode"] == nil)
    }

    @Test func spokenNumbersUpToTwentyAndHoursAreUnderstood() {
        #expect(phrase("watch me for five minutes") == .startWatching(seconds: 300))
        #expect(phrase("watch me for fifteen minutes") == .startWatching(seconds: 900))
        #expect(phrase("watch me for ninety seconds") == .startWatching(seconds: 90))
        #expect(phrase("watch me for half an hour") == .startWatching(seconds: 1800))
        #expect(phrase("watch me for a couple of minutes") == .startWatching(seconds: 120))
    }

    @Test func moreWaysToSayTheTourIsOver() {
        for text in ["that's all", "stop", "end of the tour", "the tour is over", "we're done"] {
            #expect(phrase(text, watching: true) == .stopWatching, "\(text)")
            #expect(phrase(text) == nil, "\(text)")
        }
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
        for text in ["watch youtube", "what should I watch tonight", "open youtube and play mr beast", "watch the download and tell me when it finishes",
                     "replay the last video", "let me show you something funny", "I'll show you later", "watch my screen and tell me when it changes"] {
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
