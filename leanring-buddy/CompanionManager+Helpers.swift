//
//  CompanionManager+Helpers.swift
//  leanring-buddy
//
//  The voice tools that hand work to the helpers (Dots) and answer about
//  them: starting a helper task, projects, teams of helpers and the
//  picture library. Part of CompanionManager, split out by topic.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

extension CompanionManager {
    // MARK: - Clickys (background agents)

    /// Starts a background task from voice. Uses the named Clicky (creating
    /// it if it doesn't exist yet), or a general "Helper" Clicky.
    /// Returns a short status for the voice model to relay.
    func startClickyTask(clickyName: String?, taskText: String, projectName: String? = nil, restart: Bool = true) -> String {
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            return "helpers can't run yet: Dottie isn't connected to its server. tell the user to check Settings → Connection."
        }
        if !restart, let question = repeatedHelperTaskQuestion(for: taskText) {
            return question
        }
        var notes: [String] = []
        var messageForHelper = taskText
        var projectForTask: DottieProjects.Project?
        if let projectName, !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (project, isNew) = projects.findOrCreate(named: projectName, summary: String(taskText.prefix(140)))
            projectForTask = project
            messageForHelper = projects.taskPreamble(for: project, isNew: isNew) + taskText
            notes.append(isNew ? "made a new project, \"\(project.name)\"." : "this continues the project \"\(project.name)\".")
        }
        // Back on a project: the Dot that last worked on it remembers it.
        let projectHelper = projectForTask?.helperNames.last.flatMap { helperName in
            clickyRoster.agents.first { $0.name == helperName && !clickyRoster.isRunning($0) }
        }
        let targetAgent: ClickyAgent
        if clickyName == nil, let projectHelper {
            targetAgent = projectHelper
        } else if let clickyName, let existingAgent = clickyRoster.agent(matchingName: clickyName) {
            targetAgent = existingAgent
        } else if let clickyName {
            let wasDeleted = clickyRoster.recentlyDeletedAgentNames.contains { $0.caseInsensitiveCompare(clickyName) == .orderedSame }
            targetAgent = clickyRoster.createAgent(name: clickyName, purpose: "")
            notes.append(wasDeleted
                ? "the old \(clickyName) was deleted, so this is a new helper with that name."
                : "there was no helper called \(clickyName), so a new one was made.")
        } else if let idleHelper = clickyRoster.agents.first(where: { $0.isBrain != true && !clickyRoster.isRunning($0) && clickyRoster.pendingComputerUseRequest(for: $0) == nil }) {
            // The most recently made idle helper, usually the one the user
            // just set up in the app.
            targetAgent = idleHelper
        } else {
            let helperCount = clickyRoster.agents.filter { $0.name.hasPrefix("Helper") }.count
            targetAgent = clickyRoster.createAgent(
                name: helperCount == 0 ? "Helper" : "Helper \(helperCount + 1)",
                purpose: "General background tasks the user hands off by voice."
            )
            if !clickyRoster.agents.dropFirst().isEmpty {
                notes.append("the other helpers were busy, so a new one was made.")
            }
        }

        if let projectForTask {
            projects.noteWork(on: projectForTask.id, by: targetAgent.name)
        }
        // A busy helper the user named takes the task next, in order.
        let tasksAhead = clickyRoster.sendOrQueueMessage(messageForHelper, to: targetAgent)
        if tasksAhead > 0 {
            return "\(targetAgent.name) is busy, so this is lined up: it starts after \(tasksAhead == 1 ? "its current task" : "\(tasksAhead - 1) more tasks after its current one"). say that in a few words."
        }
        guard clickyRoster.isRunning(targetAgent) else {
            return "couldn't start \(targetAgent.name). tell the user to try again from the Home window."
        }
        ClickyAnalytics.trackClickyTaskStarted()
        if !DotsRuntimeInstaller.isInstalled {
            notes.append("this is the first helper task on this mac, so it's setting up first (a one-time download), which takes a minute.")
        }
        notes.append("check_helper shows how it's going.")
        return "started. \(targetAgent.name) is working on it and will report back in the notch. " + notes.joined(separator: " ")
    }

    // MARK: - Projects, teams and pictures (DottieWorkTools)

    func performWorkTool(functionName: String, arguments: [String: Any]) async -> String {
        func text(_ key: String) -> String? {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == true ? nil : value
        }
        switch functionName {
        case "list_projects":
            return projects.listForVoice()
        case "start_team":
            let parts = ((arguments["parts"] as? [Any]) ?? []).compactMap { rawPart -> (helper: String, task: String)? in
                guard let part = rawPart as? [String: Any],
                      let helper = (part["helper"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !helper.isEmpty,
                      let task = (part["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else { return nil }
                return (helper, task)
            }
            return startTeam(goal: text("goal") ?? "", projectName: text("project"), parts: parts)
        case "save_picture":
            guard let name = text("name") else { return "give the picture a name." }
            return await savePictureFromScreen(
                name: name,
                description: text("description") ?? "",
                normalizedX: (arguments["x"] as? NSNumber)?.doubleValue,
                normalizedY: (arguments["y"] as? NSNumber)?.doubleValue,
                label: text("label")
            )
        case "find_pictures":
            let matches = imageMemory.search(text("query") ?? "")
            guard !matches.isEmpty else { return "no saved pictures match that." }
            return matches.map { item in
                "- \(item.name)\(item.savedByDottie == true ? " (you saved it)" : "")" + (item.description.isEmpty ? "" : ": \(item.description)")
            }.joined(separator: "\n")
        default:
            return "unknown tool."
        }
    }

    /// Hands each part of a big job to its own Dot, all in one project
    /// folder, with every Dot told who else is doing what.
    private func startTeam(goal: String, projectName: String?, parts: [(helper: String, task: String)]) -> String {
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            return "helpers can't run yet: Dottie isn't connected to its server. tell the user to check Settings → Connection."
        }
        let teamParts = Array(parts.prefix(5))
        guard teamParts.count >= 2 else {
            return teamParts.first.map { startClickyTask(clickyName: $0.helper, taskText: $0.task, projectName: projectName) }
                ?? "give the team at least two parts."
        }
        let fallbackProjectName = goal.split(separator: " ").prefix(4).joined(separator: " ")
        let (project, isNew) = projects.findOrCreate(named: projectName ?? fallbackProjectName, summary: String(goal.prefix(140)))

        let roster = teamParts.map { "- \($0.helper): \($0.task)" }.joined(separator: "\n")
        var startedLines: [String] = []
        for part in teamParts {
            let memberName = part.helper
            let member = clickyRoster.agents.first { $0.isBrain != true && $0.name.caseInsensitiveCompare(memberName) == .orderedSame }
                ?? clickyRoster.createAgent(name: memberName, purpose: "Team member: \(memberName).")
            let teamNote = """
            You're the \(member.name) part of a team working on this together, all at the same time, in the same project folder. The whole job: \(goal)
            The team:
            \(roster)
            Only do your own part. Don't delete or rewrite files that belong to another part; if your part depends on theirs (a file name, a class name, an API), agree on it by writing it in TEAM-NOTES.md in the project folder, and read that file before you start and before you finish.
            """
            let message = projects.taskPreamble(for: project, isNew: isNew, teamNote: teamNote) + part.task
            projects.noteWork(on: project.id, by: member.name)
            let tasksAhead = clickyRoster.sendOrQueueMessage(message, to: member)
            startedLines.append(tasksAhead > 0 ? "\(member.name) (after its current task)" : member.name)
        }
        ClickyAnalytics.trackClickyTaskStarted()
        return "started a team on \"\(project.name)\"\(isNew ? " (new project)" : ""): \(startedLines.joined(separator: ", ")). each reports back in the notch when its part is done. say who's on what in a few words."
    }

    /// Crops the thing at (x, y) on this turn's screen, or saves the whole
    /// screen, into the picture library under the given name.
    private func savePictureFromScreen(name: String, description: String, normalizedX: Double?, normalizedY: Double?, label: String?) async -> String {
        var cropFrame: CGRect?
        var displayFrame: CGRect?
        if let normalizedX, let normalizedY,
           let location = await refinedScreenLocation(normalizedX: normalizedX, normalizedY: normalizedY, label: label ?? name) {
            displayFrame = location.displayFrame
            // The thing's outline when it was found, else a square around
            // the point, with some surroundings so it can be recognized.
            let thingFrame = location.elementFrame ?? CGRect(x: location.point.x - 90, y: location.point.y - 90, width: 180, height: 180)
            let padding = max(24, max(thingFrame.width, thingFrame.height) * 0.25)
            cropFrame = thingFrame.insetBy(dx: -padding, dy: -padding).intersection(location.displayFrame)
        }
        let captureFrame = displayFrame
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame
            ?? NSScreen.main?.frame
        guard let captureFrame,
              let screenImage = await DottieDisplayCapture.captureImage(displayFrame: captureFrame, maximumDimension: 2880) else {
            return "couldn't see the screen to save it."
        }
        var savedImage = screenImage
        if let cropFrame, !cropFrame.isEmpty {
            let pixelsPerPoint = CGFloat(screenImage.width) / captureFrame.width
            let pixelRect = CGRect(
                x: (cropFrame.minX - captureFrame.minX) * pixelsPerPoint,
                y: (captureFrame.maxY - cropFrame.maxY) * pixelsPerPoint,
                width: cropFrame.width * pixelsPerPoint,
                height: cropFrame.height * pixelsPerPoint
            ).integral
            if let croppedImage = screenImage.cropping(to: pixelRect) {
                savedImage = croppedImage
            }
        }
        guard let pngData = NSBitmapImageRep(cgImage: savedImage).representation(using: .png, properties: [:]),
              let item = imageMemory.add(imageData: pngData, name: name, description: description, savedByDottie: true) else {
            return "couldn't save the picture."
        }
        return "saved as \"\(item.name)\"\(cropFrame == nil ? " (the whole screen)" : ""). it's in Home → Pictures, and you can find it by that name later. say so in a few words."
    }

    /// list_helpers, check_helper, stop_helper and open_helper_result.
    func answerHelperTool(functionName: String, helperName: String?) -> String {
        if functionName == "list_helpers" {
            return clickyRoster.helperListSummary()
        }
        let requestedAgent: ClickyAgent?
        if let helperName, !helperName.isEmpty {
            requestedAgent = clickyRoster.agent(matchingName: helperName)
        } else {
            // No name: the helper the user most likely means is the one
            // given a task most recently. The second brain isn't a helper,
            // so "open it" never lands on it unless it's asked for by name.
            let helpers = clickyRoster.agents.filter { $0.isBrain != true }
            requestedAgent = helpers.max { firstHelper, secondHelper in
                latestTaskDate(for: firstHelper) < latestTaskDate(for: secondHelper)
            }
        }
        guard let agent = requestedAgent else {
            if let helperName, clickyRoster.recentlyDeletedAgentNames.contains(where: { $0.caseInsensitiveCompare(helperName) == .orderedSame }) {
                return "\(helperName) was deleted by the user. helpers now:\n\(clickyRoster.helperListSummary())"
            }
            return "no helper by that name. helpers now:\n\(clickyRoster.helperListSummary())"
        }
        switch functionName {
        case "stop_helper":
            let droppedCount = clickyRoster.queuedMessages(for: agent).count
            clickyRoster.clearQueuedMessages(for: agent)
            guard clickyRoster.isRunning(agent) else {
                return droppedCount > 0
                    ? "cleared \(agent.name)'s \(droppedCount) waiting tasks."
                    : "\(agent.name) isn't working on anything: \(clickyRoster.statusLine(for: agent))."
            }
            clickyRoster.stopAgent(agent)
            return "stopped \(agent.name)\(droppedCount > 0 ? " and cleared its \(droppedCount) waiting tasks" : "")."
        case "open_helper_result":
            return clickyRoster.openHelperResult(for: agent)
        default:
            return clickyRoster.helperDetail(for: agent)
        }
    }

    private func latestTaskDate(for agent: ClickyAgent) -> Date {
        clickyRoster.transcriptsByAgentID[agent.id]?.last(where: { $0.kind == .user })?.createdAt ?? agent.lastActivityAt
    }
}
