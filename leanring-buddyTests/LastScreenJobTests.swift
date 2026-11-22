//
//  LastScreenJobTests.swift
//  leanring-buddyTests
//
//  What the last screen job did, handed to the next turns: the talker's
//  line, the request brain's record, when it's too old, and a finish that
//  says the job isn't done being sent back to carry on.
//

import Foundation
import Testing
@testable import Dottie

struct LastScreenJobTests {
    /// celly's job on 22 Nov: one of three tasks moved, then it stopped.
    private let celsJobEnd = Date(timeIntervalSince1970: 1_800_000_000)
    private var celsJob: DottieLastScreenJob {
        DottieLastScreenJob(
            taskText: "move the first three tasks from 22 November into 23 November",
            resultText: "I haven't finished this yet. Only the first move (S1 · 5. Correlation and regression) appears to have gone through; S1 · 6 and 4B are still on Sun 22 Nov, so I stopped before moving them.",
            succeeded: true,
            moveSummaries: ["drag:S1 · 5. Correlation and regression->Mon 23 Nov", "scroll:down"],
            endedAt: celsJobEnd
        )
    }

    @Test func theTalkerHandsQuestionsAboutTheJobToClaude() {
        let line = celsJob.talkerLine(now: celsJobEnd.addingTimeInterval(60))
        #expect(line.contains("move the first three tasks"))
        #expect(line.contains("only the first move") || line.contains("Only the first move"))
        #expect(line.contains("goes to claude"))
        #expect(line.contains("hand_to_claude"))
    }

    @Test func theRequestBrainGetsEveryMoveAndIsToldNotToGuess() {
        let section = celsJob.requestPromptSection(now: celsJobEnd.addingTimeInterval(120))
        #expect(section.contains("asked: \"move the first three tasks"))
        #expect(section.contains("drag:S1 · 5. Correlation and regression->Mon 23 Nov; scroll:down"))
        #expect(section.contains("never make up a reason"))
        #expect(section.contains("say you don't know why"))
        #expect(section.contains("do_task_on_screen with only the part that isn't done"))
    }

    @Test func aJobThatWorkedSaysSo() {
        let doneJob = DottieLastScreenJob(taskText: "open my inbox", resultText: "Your inbox is open.", succeeded: true, moveSummaries: [], endedAt: celsJobEnd)
        let section = doneJob.requestPromptSection(now: celsJobEnd)
        #expect(section.contains("ended as done"))
        #expect(section.contains("moves in order: none recorded"))
        let failedJob = DottieLastScreenJob(taskText: "x", resultText: "it couldn't be finished: no button", succeeded: false, moveSummaries: [], endedAt: celsJobEnd)
        #expect(failedJob.requestPromptSection(now: celsJobEnd).contains("ended not done"))
    }

    @Test func anOldJobIsLeftOut() {
        let halfHourLater = celsJobEnd.addingTimeInterval(DottieLastScreenJob.rememberedForSeconds)
        #expect(!celsJob.talkerLine(now: halfHourLater).isEmpty)
        let tooLate = halfHourLater.addingTimeInterval(1)
        #expect(celsJob.talkerLine(now: tooLate).isEmpty)
        #expect(celsJob.requestPromptSection(now: tooLate).isEmpty)
        // A clock that went backwards doesn't count it as recent.
        #expect(celsJob.talkerLine(now: celsJobEnd.addingTimeInterval(-10)).isEmpty)
    }

    @Test func longJobsAreKeptShort() {
        let longJob = DottieLastScreenJob(taskText: String(repeating: "a", count: 1000), resultText: String(repeating: "b", count: 2000),
                                          succeeded: false, moveSummaries: (1...60).map { "move \($0)" }, endedAt: celsJobEnd)
        let section = longJob.requestPromptSection(now: celsJobEnd)
        #expect(!section.contains(String(repeating: "a", count: DottieLastScreenJob.maximumTaskCharacters + 1)))
        #expect(!section.contains(String(repeating: "b", count: DottieLastScreenJob.maximumResultCharacters + 1)))
        #expect(section.contains("more"))
        #expect(section.contains("move 60"))
        #expect(!section.contains("move 30;"))
        #expect(section.count < 1500)
        #expect(longJob.talkerLine(now: celsJobEnd).count < 800)
    }

    @Test func aFinishThatSaysItIsntDoneCarriesOn() {
        #expect(DottieLastScreenJob.finishShouldCarryOn(answer: celsJob.resultText))
        #expect(DottieLastScreenJob.finishShouldCarryOn(answer: "Moved one of them; the other two are still on Sunday."))
        #expect(DottieLastScreenJob.finishShouldCarryOn(answer: "I didn't finish: only one of the files moved."))
    }

    @Test func aRealFinishIsKept() {
        #expect(!DottieLastScreenJob.finishShouldCarryOn(answer: "All three tasks are on Monday now."))
        #expect(!DottieLastScreenJob.finishShouldCarryOn(answer: "Your rank is 312th."))
        #expect(!DottieLastScreenJob.finishShouldCarryOn(answer: ""))
    }

    @Test func aFinishThatNeedsTheUserIsKept() {
        #expect(!DottieLastScreenJob.finishShouldCarryOn(answer: "I haven't finished: it's asking for your password."))
        #expect(!DottieLastScreenJob.finishShouldCarryOn(answer: "Not done yet, it wants a verification code sent to your phone."))
        #expect(!DottieLastScreenJob.finishShouldCarryOn(answer: "Didn't finish, I need you to sign in first."))
    }


    @Test func theTalkersBodyCarriesTheJobLineOnlyWhenThereIsOne() throws {
        let plainBody = DottieTalkerProtocol.talkerRequestBody(transcript: "why?", exchanges: [], personalityLine: "")
        let plainSystem = try #require(((plainBody["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(plainSystem == DottieTalkerProtocol.talkerSystemPrompt(personalityLine: ""))
        let line = celsJob.talkerLine(now: celsJobEnd)
        let jobBody = DottieTalkerProtocol.talkerRequestBody(transcript: "why?", exchanges: [], personalityLine: "", lastScreenJobLine: line)
        let jobSystem = try #require(((jobBody["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(jobSystem.hasSuffix(line))
        #expect(JSONSerialization.isValidJSONObject(jobBody))
    }

    @Test func theRequestPromptCarriesTheRecordOnlyWhenThereIsOne() {
        let plainPrompt = DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "")
        #expect(!plainPrompt.contains("the last on-screen job"))
        let section = celsJob.requestPromptSection(now: celsJobEnd)
        let jobPrompt = DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "name: celly", lastScreenJobSection: section)
        #expect(jobPrompt.hasPrefix(plainPrompt))
        #expect(jobPrompt.contains("name: celly"))
        #expect(jobPrompt.hasSuffix(section))
    }

    /// The whole path: a job's moves go into its memory, it ends half done,
    /// and the next turn's "why?" reaches Claude with the real record.
    @Test func aWhyAfterAHalfDoneJobGetsTheRealRecord() throws {
        var memory = DottieJobMemory(taskText: "move the first three tasks into 23 November")
        memory.noteMove("drag:S1 · 5->Mon 23 Nov")
        memory.noteMove("scroll:down")
        #expect(DottieLastScreenJob.finishShouldCarryOn(answer: "Only the first move went through, so I stopped."))
        let record = DottieLastScreenJob(taskText: "move the first three tasks into 23 November",
                                         resultText: "it couldn't be finished: the second task wouldn't drop on Monday",
                                         succeeded: false, moveSummaries: memory.allMoves, endedAt: celsJobEnd)
        let now = celsJobEnd.addingTimeInterval(90)
        // The talker hands "why?" to Claude, which has the record.
        let handOver = DottieBrainAnswer(text: "", functionCalls: [(name: "hand_to_claude", arguments: ["needs_screen": true])], modelContent: nil)
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: handOver) == .request(needsScreen: true))
        let talkerBody = DottieTalkerProtocol.talkerRequestBody(transcript: "why?", exchanges: [], personalityLine: "",
                                                                lastScreenJobLine: record.talkerLine(now: now))
        let talkerSystem = try #require(((talkerBody["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(talkerSystem.contains("wouldn't drop on Monday"))
        // Claude gets the moves and the real reason.
        let prompt = DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "", lastScreenJobSection: record.requestPromptSection(now: now))
        #expect(prompt.contains("drag:S1 · 5->Mon 23 Nov; scroll:down"))
        #expect(prompt.contains("the second task wouldn't drop on Monday"))
        #expect(prompt.contains("ended not done"))
    }
}
