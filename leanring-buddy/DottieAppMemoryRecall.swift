//
//  DottieAppMemoryRecall.swift
//  leanring-buddy
//
//  What app memory gives Jev and the step model, only when they ask for it
//  (Jev's "look up what Dottie remembers" option, the step model's
//  app_memory tool), so it costs nothing on jobs that don't need it:
//  - the page in front: every text and control with where it sits (0-1000),
//    and what clicking things there did before;
//  - flows: what the user did in this app, step after step (clicked X on
//    page A, which opened B, typed into "To", pressed cmd+return), so
//    "how to do what" comes from watching them;
//  - a smart reading of the page: once per page, a smarter model (Claude
//    through the Worker) looks at its screenshot and writes what every
//    control does (icons too) and which of Dottie's moves uses it. Kept
//    with the page, so it's never asked twice.
//  The text building is pure, so it can be unit tested.
//

import Foundation

/// One thing the user did in an app.
struct DottieAppFlowStep: Codable, Equatable {
    enum Action: String, Codable {
        case click
        /// Typed into a field (the words are never kept, only the field's name).
        case typeInto
        case pressKeys
    }

    let action: Action
    /// The page it happened on.
    let pageTitle: String
    /// What was clicked or typed into, or the keys pressed.
    let label: String
    let centerX: Double?
    let centerY: Double?
    /// The page a click opened, when it opened one.
    var resultPageTitle: String?
}

/// Steps the user took in one app without a long pause, in order.
struct DottieAppFlow: Codable, Equatable {
    let startedAt: Date
    var steps: [DottieAppFlowStep]
}

enum DottieAppMemoryRecallPlan {
    /// A pause this long, or leaving the app, ends a flow.
    static let secondsOfQuietThatEndAFlow: TimeInterval = 45
    static let maximumStepsPerFlow = 40
    static let maximumFlowsPerApp = 60
    /// What the summary may take up, so it never crowds Jev's or GLM's request.
    static let maximumSummaryCharacters = 3000

    /// The step added to a flow: a typing burst into the same field is one step.
    static func flow(_ flow: DottieAppFlow, adding step: DottieAppFlowStep) -> DottieAppFlow {
        var updatedFlow = flow
        if step.action == .typeInto, let lastStep = updatedFlow.steps.last,
           lastStep.action == .typeInto, lastStep.label == step.label, lastStep.pageTitle == step.pageTitle {
            return updatedFlow
        }
        guard updatedFlow.steps.count < maximumStepsPerFlow else { return updatedFlow }
        updatedFlow.steps.append(step)
        return updatedFlow
    }

    /// Flows worth keeping (two steps or more), newest last, capped.
    static func keptFlows(_ flows: [DottieAppFlow]) -> [DottieAppFlow] {
        Array(flows.filter { $0.steps.count >= 2 }.suffix(maximumFlowsPerApp))
    }

    /// One line for a step, the way Jev and the step model read it.
    static func stepLine(_ step: DottieAppFlowStep) -> String {
        let place = step.centerX.flatMap { centerX in step.centerY.map { " at (\(Int(centerX.rounded())), \(Int($0.rounded())))" } } ?? ""
        switch step.action {
        case .click:
            let result = step.resultPageTitle.map { " → opened \"\($0)\"" } ?? ""
            return "on \"\(step.pageTitle)\" clicked \"\(step.label)\"\(place)\(result)"
        case .typeInto:
            return "on \"\(step.pageTitle)\" typed into \"\(step.label)\"\(place)"
        case .pressKeys:
            return "on \"\(step.pageTitle)\" pressed \(step.label)"
        }
    }

    /// The flows that fit the job best (sharing its words), newest first
    /// among equals; the newest flows when nothing fits.
    static func flowsFitting(taskText: String, in flows: [DottieAppFlow], limit: Int = 3) -> [DottieAppFlow] {
        let taskWords = DottieTaskMatching.contentWords(taskText)
        let scoredFlows = flows.enumerated().map { index, flow -> (flow: DottieAppFlow, score: Int, index: Int) in
            let flowText = flow.steps.map { "\($0.label) \($0.pageTitle) \($0.resultPageTitle ?? "")" }.joined(separator: " ")
            return (flow, taskWords.intersection(DottieTaskMatching.contentWords(flowText)).count, index)
        }
        let fittingFlows = scoredFlows.filter { $0.score > 0 }
        let chosenFlows = fittingFlows.isEmpty ? scoredFlows : fittingFlows
        return chosenFlows.sorted { ($0.score, $0.index) > ($1.score, $1.index) }.prefix(limit).map(\.flow)
    }

    /// Everything app memory knows that helps this job, as text for Jev's
    /// state or the step model's tool result, or "" when it knows nothing.
    static func summary(appName: String, page: DottieAppPage?, flows: [DottieAppFlow], taskText: String) -> String {
        var sections: [String] = []
        if let page {
            var pageLines = ["Dottie's memory of \(appName), page \"\(page.title)\" (positions are 0-1000 across and down the screen):"]
            if let smartDescription = page.smartDescription, !smartDescription.isEmpty {
                pageLines.append("How this page works: " + smartDescription)
            }
            let rememberedClicks = page.clicks.sorted { $0.timesSeen > $1.timesSeen }.prefix(12)
            if !rememberedClicks.isEmpty {
                pageLines.append("Clicks that worked here before: " + rememberedClicks.map {
                    "\"\($0.label)\" at (\(Int($0.centerX.rounded())), \(Int($0.centerY.rounded()))) → \"\($0.resultPageTitle)\""
                }.joined(separator: "; "))
            }
            let missLines = DottieAppMemoryPlan.missLines(on: page, now: Date())
            if !missLines.isEmpty {
                pageLines.append("Mistakes here before: " + missLines.joined(separator: " "))
            }
            let controls = page.controls ?? []
            if !controls.isEmpty {
                pageLines.append("Controls: " + controls.prefix(40).map {
                    "\($0.kind) \"\($0.label)\" (\(Int($0.centerX.rounded())), \(Int($0.centerY.rounded())))"
                }.joined(separator: "; "))
            }
            if !page.elements.isEmpty {
                pageLines.append("Text on the page: " + page.elements.prefix(40).map {
                    "\"\($0.label)\" (\(Int($0.centerX.rounded())), \(Int($0.centerY.rounded())))"
                }.joined(separator: "; "))
            }
            sections.append(pageLines.joined(separator: "\n"))
        }
        let fittingFlows = flowsFitting(taskText: taskText, in: flows)
        if !fittingFlows.isEmpty {
            let flowLines = fittingFlows.enumerated().map { index, flow in
                "Flow \(index + 1): " + flow.steps.map(stepLine).joined(separator: "; then ")
            }
            sections.append("What the user did in \(appName) before, step by step:\n" + flowLines.joined(separator: "\n"))
        }
        let summaryText = sections.joined(separator: "\n")
        return summaryText.count > maximumSummaryCharacters ? String(summaryText.prefix(maximumSummaryCharacters)) + "…" : summaryText
    }

    /// The smarter model's instructions for reading one page's screenshot,
    /// in terms of the moves Dottie can actually make.
    static func pageReadingPrompt(appName: String, pageTitle: String) -> String {
        """
        This is a screenshot of \(appName), on the page "\(pageTitle)". Dottie, a Mac assistant, works this app with these moves only: \
        click, double-click, right-click, type into a field, drag one thing onto another, press keys (shortcuts), scroll or swipe, go back. \
        List every control a person can use on this page, icons without words included: what it looks like or says, its middle as (x, y) \
        from 0 to 1000 across and down the screenshot, what it does, and the move that uses it. Then give the steps for the 3 things people \
        most often do on this page, using those moves. Plain lines, no more than 250 words, nothing else.
        """
    }
}
