//
//  TaskGoalUnfinishedPlanTests.swift
//  leanring-buddyTests
//
//  "Scroll down, find the free days and spread the 115 tasks over them"
//  finished after the scroll in 1.0.76: the model called it done with the
//  moving still ahead. A finish is now sent back while the job's own plan
//  has steps left.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct TaskGoalUnfinishedPlanTests {
    private func goal(steps: [String], currentStepIndex: Int) -> DottieTaskGoal {
        DottieTaskGoal(
            goal: "Spread the 115 tasks evenly over the free days",
            doneWhen: "every day has about the same number of tasks",
            steps: steps,
            currentStepIndex: currentStepIndex,
            source: .model
        )
    }

    private let studyJournalSteps = [
        "Scroll down to see every day",
        "Count the free days",
        "Move tasks from Friday to each free day",
        "Check every day has about the same count"
    ]

    @Test func finishingAfterTheScrollIsSentBack() throws {
        let problem = try #require(goal(steps: studyJournalSteps, currentStepIndex: 0).unfinishedPlanProblem)
        #expect(problem.contains("step 1 of 4"))
        #expect(problem.contains("2. Count the free days"))
        #expect(problem.contains("3. Move tasks from Friday to each free day"))
        #expect(problem.contains("4. Check every day has about the same count"))
        #expect(problem.contains("current_step 4"))
    }

    @Test func aMiddleStepListsOnlyTheStepsAfterIt() throws {
        let problem = try #require(goal(steps: studyJournalSteps, currentStepIndex: 2).unfinishedPlanProblem)
        #expect(problem.contains("step 3 of 4"))
        #expect(!problem.contains("Count the free days"))
        #expect(!problem.contains("Move tasks from Friday"))
        #expect(problem.contains("4. Check every day"))
    }

    @Test func theLastStepCanFinish() {
        #expect(goal(steps: studyJournalSteps, currentStepIndex: 3).unfinishedPlanProblem == nil)
    }

    @Test func noPlanOrAOneStepPlanCanFinish() {
        #expect(goal(steps: [], currentStepIndex: 0).unfinishedPlanProblem == nil)
        #expect(goal(steps: ["Open Notion"], currentStepIndex: 0).unfinishedPlanProblem == nil)
    }

    @Test func anIndexPastTheEndCanFinish() {
        #expect(goal(steps: studyJournalSteps, currentStepIndex: 9).unfinishedPlanProblem == nil)
    }

    /// The plan tool's current_step moves the index the same way the runner
    /// does, so a model that really finished can say so and then finish.
    @Test func movingToTheLastStepClearsTheProblem() {
        var studyGoal = goal(steps: studyJournalSteps, currentStepIndex: 0)
        #expect(studyGoal.unfinishedPlanProblem != nil)
        studyGoal.currentStepIndex = studyGoal.steps.count - 1
        #expect(studyGoal.unfinishedPlanProblem == nil)
    }

    @Test func checkingIsQuick() {
        let longPlan = (1...8).map { "step number \($0) of a long job on the screen" }
        let startedAt = Date()
        var problemCount = 0
        for index in 0..<20_000 where goal(steps: longPlan, currentStepIndex: index % 8).unfinishedPlanProblem != nil {
            problemCount += 1
        }
        #expect(problemCount == 17_500)
        #expect(Date().timeIntervalSince(startedAt) < 2.0)
    }
}
