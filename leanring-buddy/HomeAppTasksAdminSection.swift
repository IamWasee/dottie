//
//  HomeAppTasksAdminSection.swift
//  leanring-buddy
//
//  Home → Admin's app memory part: the hidden memory trial (screen jobs
//  with app memory on, off or at random, and how the two compare from the
//  job reports) and the named tasks Dottie knows in each app, with how often
//  each worked, its problems and a way to forget one.
//

import SwiftUI

struct HomeAppTasksAdminSection: View {
    @ObservedObject private var appTasks = DottieAppTasks.shared
    @ObservedObject private var jobReports = DottieJobReports.shared
    @AppStorage(DottieAppMemoryTrial.modeDefaultsKey) private var trialModeRawValue = DottieAppMemoryTrial.Mode.on.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Beta · App memory trial")
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $trialModeRawValue) {
                    ForEach(DottieAppMemoryTrial.Mode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .pointerCursor()
                hintText("Random runs each screen job with app memory (saved tasks, remembered clicks, app cards) or without it, so the two can be compared on the same jobs.")
                Text(DottieAppMemoryTrial.comparisonText(DottieAppMemoryTrial.summaries(of: jobReports.reports)))
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let lastReport = jobReports.reports.last {
                    hintText("Last job: " + DottieAppMemoryTrial.logLine(lastReport))
                }
                if !jobReports.reports.isEmpty {
                    Button("Clear the job reports") { jobReports.forgetAll() }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                }
            }
            .padding(16)
            .background(cardBackground)

            sectionTitle("Tasks Dottie knows")
            VStack(alignment: .leading, spacing: 12) {
                if appTasks.tasks.isEmpty {
                    hintText("None yet. Every screen job Dottie finishes in an app becomes a task here, named the way the app's own users would say it.")
                }
                ForEach(appTasks.tasks.sorted { $0.lastUsed > $1.lastUsed }) { task in
                    taskRow(task)
                }
            }
            .padding(16)
            .background(cardBackground)
        }
    }

    private func taskRow(_ task: DottieAppTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(task.appName)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer(minLength: 8)
                Text("worked \(task.timesSucceeded) of \(task.timesRun) · \(task.steps.count) steps")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Button("Forget") { appTasks.forget(taskID: task.id) }
                    .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
            }
            if !task.purpose.isEmpty { hintText(task.purpose) }
            hintText(task.steps.prefix(8).enumerated().map { "\($0.offset + 1). \(DottieAppTaskPlan.stepLine($0.element))" }.joined(separator: "  "))
            if let lastProblem = task.problems.last {
                hintText("Last problem: step \(lastProblem.stepNumber), \(lastProblem.whatHappened)" + (lastProblem.fix.map { ". Fixed by: \($0)" } ?? ""))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
            .fill(DS.Colors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}
