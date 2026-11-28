//
//  DottieJobReport.swift
//  leanring-buddy
//
//  One report per screen job, and the hidden memory trial. The app memory
//  review (27 Nov) found nothing ever recorded whether app memory saved a
//  step, so every job now ends with one public log line: the app, whether
//  memory was on, what it did (a saved task's steps done from memory,
//  remembered clicks), the moves, Jev, advisor and step-model calls, the
//  seconds, how it ended and what it cost. The last 300 are kept, and Home →
//  Admin can run jobs with memory on, off or at random and compare the two
//  (the bar to keep it: at least 40% faster, finishing at least as often).
//  The pure parts are Foundation only, so they're unit tested.
//

import Combine
import Foundation

/// What one screen job did and cost.
struct DottieJobReport: Codable, Equatable {
    var appName = "unknown"
    /// "on" or "off": whether app memory was used for this job.
    var memoryArm = "on"
    var savedTaskSteps = 0
    var replayedSteps = 0
    var memoryClicks = 0
    var jevMoves = 0
    var jevCalls = 0
    var advisorCalls = 0
    var stepModelSteps = 0
    var seconds = 0.0
    /// "finished", "failed" or "stopped".
    var outcome = "stopped"
    var dollars = 0.0
    var finishedAt = Date()

    /// Adds what the Jev part of the job did.
    mutating func addJevRun(_ jevRun: DottieJevRunStats) {
        savedTaskSteps = jevRun.savedTaskSteps
        replayedSteps = jevRun.replayedSteps
        memoryClicks = jevRun.memoryClicks
        jevMoves = jevRun.moves
        jevCalls = jevRun.jevCalls
        advisorCalls = jevRun.advisorCalls
    }
}

/// What the Jev part of one job did, read by the job report.
struct DottieJevRunStats: Equatable {
    var savedTaskSteps = 0
    var replayedSteps = 0
    var memoryClicks = 0
    var moves = 0
    var jevCalls = 0
    var advisorCalls = 0
    /// Form boxes typed at once without asking Jev (DottieFormFillPlan).
    var formBoxesFilled = 0
}

enum DottieAppMemoryTrial {
    enum Mode: String, CaseIterable, Identifiable {
        case on, off, random
        var id: String { rawValue }
        var title: String {
            switch self {
            case .on: return "Memory on"
            case .off: return "Memory off"
            case .random: return "Random (A/B)"
            }
        }
    }

    static let modeDefaultsKey = "dottieAppMemoryTrialMode"
    static let maximumReportsKept = 300

    static var currentMode: Mode {
        UserDefaults.standard.string(forKey: modeDefaultsKey).flatMap(Mode.init(rawValue:)) ?? .on
    }

    static func usesMemory(mode: Mode, coinFlip: Bool) -> Bool {
        switch mode {
        case .on: return true
        case .off: return false
        case .random: return coinFlip
        }
    }

    /// Whether this job uses app memory, by the trial's setting.
    static func usesMemoryThisJob() -> Bool {
        usesMemory(mode: currentMode, coinFlip: Bool.random())
    }

    /// What memory did for a job, in a few words (no task names: the log
    /// line is public).
    static func memoryUseText(_ report: DottieJobReport) -> String {
        if report.memoryArm == "off" { return "off" }
        if report.savedTaskSteps > 0 { return "saved task, \(report.replayedSteps) of \(report.savedTaskSteps) steps from memory" }
        if report.memoryClicks > 0 { return "\(report.memoryClicks) remembered click\(report.memoryClicks == 1 ? "" : "s")" }
        return "nothing"
    }

    static func logLine(_ report: DottieJobReport) -> String {
        "📊 job report: app \(report.appName), memory \(report.memoryArm) (\(memoryUseText(report))), "
            + "\(report.jevMoves + report.stepModelSteps) moves, \(report.jevCalls) Jev, \(report.advisorCalls) advisor, "
            + "\(report.stepModelSteps) step-model, \(String(format: "%.1f", report.seconds)) s, \(report.outcome), "
            + DottieAskUsage.dollarsText(report.dollars)
    }

    struct ArmSummary: Equatable {
        let arm: String
        let jobs: Int
        let finished: Int
        /// Over finished jobs only, so a quick failure doesn't look fast.
        let averageSecondsWhenFinished: Double?
        let averageDollars: Double
    }

    /// Memory on and memory off side by side, over stopped jobs left out.
    static func summaries(of reports: [DottieJobReport]) -> [ArmSummary] {
        ["on", "off"].compactMap { arm -> ArmSummary? in
            let armReports = reports.filter { $0.memoryArm == arm && $0.outcome != "stopped" }
            guard !armReports.isEmpty else { return nil }
            let finishedReports = armReports.filter { $0.outcome == "finished" }
            let averageSeconds = finishedReports.isEmpty ? nil : finishedReports.map(\.seconds).reduce(0, +) / Double(finishedReports.count)
            return ArmSummary(arm: arm, jobs: armReports.count, finished: finishedReports.count,
                              averageSecondsWhenFinished: averageSeconds,
                              averageDollars: armReports.map(\.dollars).reduce(0, +) / Double(armReports.count))
        }
    }

    /// The comparison for Home → Admin.
    static func comparisonText(_ summaries: [ArmSummary]) -> String {
        guard !summaries.isEmpty else { return "No screen jobs reported yet." }
        var lines = summaries.map { summary -> String in
            let secondsText = summary.averageSecondsWhenFinished.map { String(format: "%.1f s", $0) } ?? "no finished jobs"
            return "Memory \(summary.arm): \(summary.jobs) jobs, \(summary.finished) finished, \(secondsText) when finished, "
                + DottieAskUsage.dollarsText(summary.averageDollars) + " each"
        }
        if let onSummary = summaries.first(where: { $0.arm == "on" }), let offSummary = summaries.first(where: { $0.arm == "off" }),
           let onSeconds = onSummary.averageSecondsWhenFinished, let offSeconds = offSummary.averageSecondsWhenFinished, offSeconds > 0 {
            let fasterShare = (offSeconds - onSeconds) / offSeconds
            let onFinishShare = Double(onSummary.finished) / Double(onSummary.jobs)
            let offFinishShare = Double(offSummary.finished) / Double(offSummary.jobs)
            let passes = fasterShare >= 0.4 && onFinishShare >= offFinishShare
            lines.append("Memory on is \(Int((abs(fasterShare) * 100).rounded()))% \(fasterShare >= 0 ? "faster" : "slower")"
                + (passes ? ", and finishes as often: it passes the bar." : ". The bar is 40% faster and finishing as often."))
        }
        return lines.joined(separator: "\n")
    }

    static func keptReports(_ reports: [DottieJobReport], adding report: DottieJobReport) -> [DottieJobReport] {
        Array((reports + [report]).suffix(maximumReportsKept))
    }
}

/// The kept reports, in Application Support/Dottie/AppTasks/job-reports.json.
@MainActor
final class DottieJobReports: ObservableObject {
    static let shared = DottieJobReports()

    @Published private(set) var reports: [DottieJobReport] = []
    private let fileURL: URL

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = applicationSupportURL.appendingPathComponent("Dottie/AppTasks/job-reports.json")
        reports = DottieFileLoader.load([DottieJobReport].self, from: fileURL) ?? []
    }

    func add(_ report: DottieJobReport) {
        DottieLog.notice("\(public: DottieAppMemoryTrial.logLine(report))")
        reports = DottieAppMemoryTrial.keptReports(reports, adding: report)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let reportsData = try? JSONEncoder().encode(reports) else { return }
        _ = DottieFileSaver.save(reportsData, to: fileURL)
    }

    func forgetAll() {
        reports = []
        guard let reportsData = try? JSONEncoder().encode(reports) else { return }
        _ = DottieFileSaver.save(reportsData, to: fileURL)
    }
}
