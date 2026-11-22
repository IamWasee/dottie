//
//  ScreenJobStopReason.swift
//  leanring-buddy
//
//  Why a screen job stopped before it finished, and what the notch says
//  about it, so a stopped job always tells the user where it got to.
//  Foundation only, so it can be unit tested.
//

import Foundation

nonisolated enum ScreenJobStopReason: String, Sendable, CaseIterable {
    /// The notch's stop button.
    case stopButton = "stop button"
    /// The Escape key.
    case escape
    /// The user asked Dottie to stop (stop_screen_task).
    case askedToStop = "asked to stop"
    /// A guide started, which takes over the screen.
    case guideStarted = "a guide started"

    /// The notch card for a stopped job: a title and one line on where it got to.
    static func summary(taskText: String?, lastStepText: String, reason: ScreenJobStopReason) -> (title: String, text: String) {
        let jobName = shortened(taskText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", limit: 80)
        let title = jobName.isEmpty ? "Stopped the screen job" : "Stopped: \(jobName)"
        let whyText: String
        switch reason {
        case .stopButton, .escape: whyText = "You stopped it"
        case .askedToStop: whyText = "Stopped because you asked"
        case .guideStarted: whyText = "Stopped so the guide could start"
        }
        let trimmedStepText = lastStepText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmedStepText.isEmpty
            ? "\(whyText) before its first step."
            : "\(whyText). It got as far as: \(shortened(trimmedStepText, limit: 160))"
        return (title, text)
    }

    private static func shortened(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
