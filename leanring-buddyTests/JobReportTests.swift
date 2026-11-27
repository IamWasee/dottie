//
//  JobReportTests.swift
//  leanring-buddyTests
//
//  The per-job report line and the memory trial: on, off and random, what
//  memory did in a few words, memory on against memory off over finished
//  jobs, the 40% bar, and keeping only the newest reports.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct JobReportTests {
    private typealias Trial = DottieAppMemoryTrial

    private func report(arm: String, seconds: Double, outcome: String = "finished", dollars: Double = 0.002) -> DottieJobReport {
        var report = DottieJobReport()
        report.memoryArm = arm
        report.seconds = seconds
        report.outcome = outcome
        report.dollars = dollars
        return report
    }

    @Test func theTrialModeDecidesWhetherMemoryIsUsed() {
        #expect(Trial.usesMemory(mode: .on, coinFlip: false))
        #expect(!Trial.usesMemory(mode: .off, coinFlip: true))
        #expect(Trial.usesMemory(mode: .random, coinFlip: true))
        #expect(!Trial.usesMemory(mode: .random, coinFlip: false))
    }

    @Test func whatMemoryDidIsSaidInAFewWords() {
        var savedTaskReport = report(arm: "on", seconds: 4)
        savedTaskReport.savedTaskSteps = 6
        savedTaskReport.replayedSteps = 5
        #expect(Trial.memoryUseText(savedTaskReport) == "saved task, 5 of 6 steps from memory")
        var clickReport = report(arm: "on", seconds: 4)
        clickReport.memoryClicks = 1
        #expect(Trial.memoryUseText(clickReport) == "1 remembered click")
        #expect(Trial.memoryUseText(report(arm: "off", seconds: 4)) == "off")
        #expect(Trial.memoryUseText(report(arm: "on", seconds: 4)) == "nothing")
    }

    @Test func theLogLineHasEverythingAndNoTaskNames() {
        var jobReport = report(arm: "on", seconds: 12.34, dollars: 0.0031)
        jobReport.appName = "youtube.com"
        jobReport.jevMoves = 7
        jobReport.jevCalls = 5
        jobReport.advisorCalls = 1
        jobReport.stepModelSteps = 2
        let line = Trial.logLine(jobReport)
        #expect(line.hasPrefix("📊 job report: app youtube.com, memory on"))
        #expect(line.contains("9 moves, 5 Jev, 1 advisor, 2 step-model, 12.3 s, finished"))
        #expect(line.contains("$"))
    }

    @Test func armsAreComparedOverFinishedJobsAndStoppedOnesAreLeftOut() {
        let reports = [
            report(arm: "on", seconds: 5), report(arm: "on", seconds: 7), report(arm: "on", seconds: 1, outcome: "stopped"),
            report(arm: "off", seconds: 10), report(arm: "off", seconds: 2, outcome: "failed")
        ]
        let summaries = Trial.summaries(of: reports)
        #expect(summaries.count == 2)
        #expect(summaries[0] == Trial.ArmSummary(arm: "on", jobs: 2, finished: 2, averageSecondsWhenFinished: 6, averageDollars: 0.002))
        #expect(summaries[1].jobs == 2 && summaries[1].finished == 1 && summaries[1].averageSecondsWhenFinished == 10)
        let text = Trial.comparisonText(summaries)
        #expect(text.contains("Memory on is 40% faster, and finishes as often: it passes the bar."))
    }

    @Test func slowerOrLessReliableMemoryDoesNotPass() {
        let slower = Trial.comparisonText(Trial.summaries(of: [report(arm: "on", seconds: 12), report(arm: "off", seconds: 10)]))
        #expect(slower.contains("20% slower"))
        #expect(slower.contains("The bar is 40% faster"))
        let lessReliable = Trial.comparisonText(Trial.summaries(of: [
            report(arm: "on", seconds: 2), report(arm: "on", seconds: 2, outcome: "failed"), report(arm: "off", seconds: 10)
        ]))
        #expect(!lessReliable.contains("passes the bar"))
    }

    @Test func nothingReportedYetSaysSo() {
        #expect(Trial.comparisonText([]) == "No screen jobs reported yet.")
        #expect(Trial.summaries(of: [report(arm: "on", seconds: 3, outcome: "stopped")]).isEmpty)
    }

    @Test func onlyTheNewestReportsAreKept() {
        var reports: [DottieJobReport] = []
        for number in 0..<(Trial.maximumReportsKept + 10) {
            reports = Trial.keptReports(reports, adding: report(arm: "on", seconds: Double(number)))
        }
        #expect(reports.count == Trial.maximumReportsKept)
        #expect(reports.last?.seconds == Double(Trial.maximumReportsKept + 9))
    }

    @Test func aJevRunsNumbersGoIntoTheReport() {
        var jobReport = DottieJobReport()
        jobReport.addJevRun(DottieJevRunStats(savedTaskSteps: 4, replayedSteps: 3, memoryClicks: 1, moves: 6, jevCalls: 2, advisorCalls: 1))
        #expect(jobReport.savedTaskSteps == 4 && jobReport.replayedSteps == 3 && jobReport.memoryClicks == 1)
        #expect(jobReport.jevMoves == 6 && jobReport.jevCalls == 2 && jobReport.advisorCalls == 1)
    }
}
