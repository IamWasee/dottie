//
//  JobMemoryTests.swift
//  leanring-buddyTests
//
//  A screen job's running memory: reading how many times a job repeats,
//  rounds and what each did, the short text Jev and the step model get,
//  and a whole job done 3 times through Jev's options and decisions.
//

import Foundation
import Testing
@testable import Dottie

struct JobMemoryTests {
    private typealias Plan = DottieJevDriverPlan

    @Test func roundsAreReadFromTheRequest() {
        #expect(DottieJobMemory.roundCount(in: "send a thumbs up to Sam 3 times") == 3)
        #expect(DottieJobMemory.roundCount(in: "like the next five posts, do it five times") == 5)
        #expect(DottieJobMemory.roundCount(in: "refresh the page twice") == 2)
        #expect(DottieJobMemory.roundCount(in: "add a row x4") == 4)
        #expect(DottieJobMemory.roundCount(in: "do it 2 more times") == 2)
    }

    @Test func aJobDoneOnceHasOneRound() {
        #expect(DottieJobMemory.roundCount(in: "open my downloads folder") == 1)
        #expect(DottieJobMemory.roundCount(in: "do it 1 times") == 1)
        #expect(DottieJobMemory.roundCount(in: "what times are the trains") == 1)
        #expect(DottieJobMemory.roundCount(in: "play this video at 2x speed") == 1)
    }

    @Test func roundsAreCapped() {
        #expect(DottieJobMemory.roundCount(in: "click it 99 times") == DottieJobMemory.maximumRounds)
        #expect(DottieJobMemory(totalRounds: 0).totalRounds == 1)
    }

    @Test func aRoundOnlyEndsAfterItDidSomething() {
        var memory = DottieJobMemory(totalRounds: 3)
        let didFinishRound1 = memory.finishRound()
        #expect(!didFinishRound1)
        memory.noteMove("clicked Like")
        let didFinishRound2 = memory.finishRound()
        #expect(didFinishRound2)
        #expect(memory.currentRound == 2)
        #expect(memory.movesThisRound.isEmpty)
        let didFinishRound3 = memory.finishRound()
        #expect(!didFinishRound3)
    }

    @Test func theLastRoundCantBeFinishedAsARound() {
        var memory = DottieJobMemory(totalRounds: 2)
        memory.noteMove("a")
        memory.finishRound()
        memory.noteMove("b")
        #expect(!memory.hasRoundsLeft)
        let didFinishRound4 = memory.finishRound()
        #expect(!didFinishRound4)
        #expect(memory.allMoves == ["a", "b"])
    }

    @Test func theStateSaysTheRoundAndRoundOnesRecipe() {
        var memory = DottieJobMemory(totalRounds: 3)
        memory.noteMove("clicked Compose")
        memory.noteMove("typed \"hi\" and pressed Return")
        memory.finishRound()
        memory.noteMove("clicked Compose")
        let state = memory.stateText()
        #expect(state.contains("same task 3 times"))
        #expect(state.contains("round 2 of 3"))
        #expect(state.contains("Round 1 is done and worked (2 moves): clicked Compose; typed \"hi\" and pressed Return"))
        #expect(state.contains("This round so far: clicked Compose"))
        #expect(state.contains("start round 3"))
    }

    @Test func theLastRoundSaysTheJobEndsAfterIt() {
        var memory = DottieJobMemory(totalRounds: 2)
        memory.noteMove("a")
        memory.finishRound()
        #expect(memory.stateText().contains("This is the last round"))
    }

    @Test func laterRoundsAreCountedNotListed() {
        var memory = DottieJobMemory(totalRounds: 4)
        for round in 1...3 {
            memory.noteMove("move of round \(round)")
            memory.finishRound()
        }
        let state = memory.stateText()
        #expect(state.contains("Rounds 2 to 3 are done too"))
        #expect(!state.contains("move of round 2"))
    }

    @Test func aJobDoneOnceListsEveryMoveShort() {
        var memory = DottieJobMemory(totalRounds: 1)
        #expect(memory.stateText() == "Nothing has been done yet.")
        for index in 1...40 { memory.noteMove("move \(index)") }
        let state = memory.stateText()
        #expect(state.contains("40 moves"))
        #expect(state.contains("move 1;"))
        #expect(state.contains("move 40"))
        #expect(state.contains("26 more"))
        #expect(!state.contains("move 20;"))
    }

    @Test func theStateNeverGetsLong() {
        var memory = DottieJobMemory(totalRounds: 1)
        for index in 1...200 { memory.noteMove(String(repeating: "long move \(index) ", count: 20)) }
        #expect(memory.stateText().count <= DottieJobMemory.maximumStateCharacters + 1)
    }

    @Test func jevGetsTheRoundInItsStateAndDoneQuestion() throws {
        var memory = DottieJobMemory(totalRounds: 3)
        memory.noteMove("clicked Like")
        let body = Plan.requestBody(goal: "like it 3 times", movesSoFar: ["clicked Like"], knownHowTo: "", options: [], jobMemory: memory)
        let state = try #require(body["state"] as? String)
        #expect(state.contains("round 1 of 3"))
        let questions = try #require(body["questions"] as? [String: Any])
        let doneQuestion = try #require(questions[Plan.doneQuestionName] as? [String: Any])
        #expect((doneQuestion["instructions"] as? String)?.contains("round 1") == true)
    }

    @Test func roundsLeftOfferTheNextRoundInsteadOfFinishing() {
        let options = Plan.options(screenTexts: [], textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [], offersNextRound: true)
        let moves = options.map(\.move)
        #expect(moves.contains(.finishedRound))
        #expect(!moves.contains(.finished))
        #expect(moves.contains(.noneFits))
    }

    @Test func doneWithRoundsLeftEndsTheRoundNotTheJob() {
        let sureDone = Plan.Answer(move: .scrollDown, probability: 0.6, confidence: 0.5, doneProbability: 0.95)
        #expect(Plan.decision(for: sureDone, hasRoundsLeft: true, roundHasMoves: true) == .roundDone)
        // A new round starts on the screen the last one left: it looks done.
        #expect(Plan.decision(for: sureDone, hasRoundsLeft: true, roundHasMoves: false) == .act(.scrollDown))
        let pickedFinish = Plan.Answer(move: .finished, probability: 0.9, confidence: 0.8, doneProbability: 0.2)
        #expect(Plan.decision(for: pickedFinish, hasRoundsLeft: true, roundHasMoves: true) == .unsure)
    }

    @Test func roundDonePickedTooEarlyHandsOver() {
        let earlyRoundDone = Plan.Answer(move: .finishedRound, probability: 0.9, confidence: 0.8, doneProbability: 0.1)
        #expect(Plan.decision(for: earlyRoundDone, hasRoundsLeft: true, roundHasMoves: false) == .unsure)
        #expect(Plan.decision(for: earlyRoundDone, hasRoundsLeft: true, roundHasMoves: true) == .roundDone)
    }

    @Test func repeatedJobsGetMoreSteps() {
        #expect(Plan.stepBudget(rounds: 1) == Plan.maximumSteps)
        #expect(Plan.stepBudget(rounds: 3) == Plan.maximumSteps * 3)
        #expect(Plan.stepBudget(rounds: 20) == Plan.maximumStepsForRepeatedJobs)
    }

    /// The same task 3 times: each round clicks Like then Next, the round
    /// ends, and only after round 3 does Jev's "done" end the job. Round 2
    /// and 3 aren't confused by round 1 having clicked the same things.
    @Test func aJobDoneThreeTimesRunsEveryRoundThenFinishes() throws {
        let taskText = "like this post and go to the next one, 3 times"
        let screenTexts = [Plan.ScreenText(text: "Like", centerX: 300, centerY: 700), Plan.ScreenText(text: "Next", centerX: 800, centerY: 500)]
        var memory = DottieJobMemory(taskText: taskText)
        #expect(memory.totalRounds == 3)
        let like = Plan.Move.click(label: "Like", centerX: 300, centerY: 700)
        let next = Plan.Move.click(label: "Next", centerX: 800, centerY: 500)
        // Jev's picks, with how sure it is that the round (or job) is done.
        let picks: [(move: Plan.Move, done: Double)] = [
            (like, 0.05), (next, 0.1), (.finishedRound, 0.9),
            (like, 0.05), (next, 0.1), (.scrollDown, 0.92),
            (like, 0.05), (next, 0.1), (.finished, 0.95)
        ]
        var triedSignatures = Set<String>()
        var roundsEnded = 0
        var finished = false
        for pick in picks {
            let options = Plan.options(screenTexts: screenTexts, textPieces: [], siteAddresses: [], appNames: [],
                                       alreadyTriedSignatures: triedSignatures, taskText: taskText,
                                       offersNextRound: memory.hasRoundsLeft && !memory.movesThisRound.isEmpty)
            let body = Plan.requestBody(goal: taskText, movesSoFar: memory.allMoves, knownHowTo: "", options: options, jobMemory: memory)
            #expect(JSONSerialization.isValidJSONObject(body))
            let key = try #require(options.first { $0.move == pick.move }?.key, "\(pick.move) wasn't offered in round \(memory.currentRound)")
            let answerData = try JSONSerialization.data(withJSONObject: ["answers": [
                Plan.choiceQuestionName: ["choice": key, "probabilities": [key: 0.8], "confidence": 0.7],
                Plan.doneQuestionName: ["noul": pick.done]
            ]])
            let parsed = try #require(Plan.answer(fromAnswer: answerData, options: options))
            switch Plan.decision(for: parsed, hasRoundsLeft: memory.hasRoundsLeft, roundHasMoves: !memory.movesThisRound.isEmpty) {
            case .act(let move):
                memory.noteMove(move.summary)
                triedSignatures.insert(move.signature)
            case .roundDone:
                let didFinishRound5 = memory.finishRound()
                #expect(didFinishRound5)
                roundsEnded += 1
                // Each round starts fresh: nothing struck off from the last.
                triedSignatures = []
            case .finished:
                finished = true
            case .unsure:
                Issue.record("a confident pick in round \(memory.currentRound) shouldn't hand over")
            }
        }
        #expect(roundsEnded == 2)
        #expect(finished)
        #expect(memory.currentRound == 3)
        #expect(memory.movesByRound == [["clicked Like", "clicked Next"], ["clicked Like", "clicked Next"], ["clicked Like", "clicked Next"]])
    }
}
