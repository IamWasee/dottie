//
//  ScreenJobHintTests.swift
//  leanring-buddyTests
//
//  Guiding a running screen job: which words are a hint (not a stop or a
//  new question), how a hint is judged by what its moves did, what Jev
//  and the step model read, keys named in a hint, and the lesson kept.
//

import Foundation
import Testing
@testable import Dottie

struct ScreenJobHintTests {
    private typealias HintPlan = DottieScreenJobHintPlan

    @Test func correctionsAndWaysAreHints() {
        #expect(HintPlan.isGuidance("no, use the search bar, it's faster"))
        #expect(HintPlan.isGuidance("try pressing command K instead"))
        #expect(HintPlan.isGuidance("it's under the File menu"))
        #expect(HintPlan.isGuidance("click the blue one on the left"))
        #expect(HintPlan.isGuidance("you can just press return"))
        #expect(HintPlan.isGuidance("wait, use the other one"))
        #expect(HintPlan.isGuidance("there's a shortcut for that"))
    }

    @Test func stoppingIsNotAHint() {
        #expect(!HintPlan.isGuidance("stop"))
        #expect(!HintPlan.isGuidance("stop, use the search bar instead"))
        #expect(!HintPlan.isGuidance("cancel that"))
        #expect(!HintPlan.isGuidance("never mind"))
        #expect(!HintPlan.isGuidance("wait"))
        #expect(!HintPlan.isGuidance("hold on a sec"))
    }

    @Test func otherAsksAreNotHints() {
        #expect(!HintPlan.isGuidance("what's the weather tomorrow?"))
        #expect(!HintPlan.isGuidance("play some music"))
        #expect(!HintPlan.isGuidance("ok"))
        #expect(!HintPlan.isGuidance(String(repeating: "no ", count: 200)))
    }

    @Test func aHintThatChangesTheScreenWorked() {
        let hint = HintPlan.Hint(text: "use the search bar").updated(afterMoveChangedScreen: true)
        #expect(hint.status == .worked)
        // Once it worked, later moves don't undo that.
        #expect(hint.updated(afterMoveChangedScreen: false).status == .worked)
    }

    @Test func aHintThatChangesNothingForThreeMovesIsDropped() {
        var hint = HintPlan.Hint(text: "press command k")
        hint = hint.updated(afterMoveChangedScreen: false)
        hint = hint.updated(afterMoveChangedScreen: false)
        #expect(hint.status == .trying)
        hint = hint.updated(afterMoveChangedScreen: false)
        #expect(hint.status == .didntHelp)
    }

    @Test func theNewestHintIsTriedFirstAndWorkingOnesKept() {
        let worked = HintPlan.Hint(text: "use the sidebar", status: .worked)
        let trying = HintPlan.Hint(text: "press command k")
        let dropped = HintPlan.Hint(text: "scroll down", status: .didntHelp)
        let state = HintPlan.stateText(hints: [worked, dropped, trying])
        #expect(state.contains("\"press command k\". Do it their way now"))
        #expect(state.contains("keep doing it like that: \"use the sidebar\""))
        #expect(!state.contains("scroll down"))
        #expect(HintPlan.stateText(hints: []).isEmpty)
    }

    @Test func keysInAHintArePressable() {
        #expect(HintPlan.keyCombination(in: "try command k instead") == "cmd+k")
        #expect(HintPlan.keyCombination(in: "use cmd+shift+n, it's faster") == "cmd+shift+n")
        #expect(HintPlan.keyCombination(in: "no, use the search bar") == nil)
    }

    @Test func theLessonIsTheUsersWay() {
        let lesson = HintPlan.lessonText(for: HintPlan.Hint(text: "use the search bar"))
        #expect(lesson.contains("\"use the search bar\""))
    }

    @Test func jevReadsTheHintInItsState() throws {
        let hintsText = HintPlan.stateText(hints: [HintPlan.Hint(text: "press command k")])
        let body = DottieJevDriverPlan.requestBody(goal: "find the file", movesSoFar: [], knownHowTo: "", options: [], hintsText: hintsText)
        let state = try #require(body["state"] as? String)
        #expect(state.contains("press command k"))
    }

    @Test func aHintsKeysAreOfferedFirst() throws {
        let hintMove = DottieJevDriverPlan.Move.pressKeys(keys: "cmd+k", meaning: "the user said to")
        let options = DottieJevDriverPlan.options(screenTexts: [], textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [],
                                                  extraLeadingMoves: [hintMove])
        #expect(options.first?.move == hintMove)
    }

    @Test func theRunningJobsHintsAreHandedOutOnce() {
        let hints = DottieScreenJobHints()
        hints.add("use the search bar")
        #expect(hints.takeNew().map(\.text) == ["use the search bar"])
        #expect(hints.takeNew().isEmpty)
        hints.add("  ")
        #expect(hints.takeNew().isEmpty)
        hints.noteMove(changedScreen: true)
        #expect(hints.hints.first?.status == .worked)
        hints.reset()
        #expect(!hints.hasHints)
    }
}
