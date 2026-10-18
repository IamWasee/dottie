//
//  DottieHelperStatus.swift
//  leanring-buddy
//
//  What voice Dottie knows about the user's helpers (Dots): who exists, who
//  is working on what, who is stuck or finished, and what they made. The
//  Live tools list_helpers, check_helper, stop_helper and open_helper_result
//  answer from here, so Dottie reports the real state instead of guessing.
//

import AppKit
import Foundation

extension ClickyRoster {
    /// One short line per helper for list_helpers.
    func helperListSummary() -> String {
        guard !agents.isEmpty else {
            var summary = "the user has no helpers right now."
            if !recentlyDeletedAgentNames.isEmpty {
                summary += " deleted earlier: \(recentlyDeletedAgentNames.joined(separator: ", "))."
            }
            return summary
        }
        var lines = agents.map { agent -> String in
            let waitingCount = queuedMessages(for: agent).count
            return "- \(agent.name): \(statusLine(for: agent))\(waitingCount > 0 ? " (+\(waitingCount) tasks waiting)" : "")"
        }
        if !recentlyDeletedAgentNames.isEmpty {
            lines.append("deleted by the user: \(recentlyDeletedAgentNames.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    /// Everything Dottie needs to answer "how's the helper doing?".
    func helperDetail(for agent: ClickyAgent) -> String {
        let transcript = transcriptsByAgentID[agent.id] ?? []
        var lines = ["\(agent.name): \(statusLine(for: agent))"]
        if !agent.purpose.isEmpty {
            lines.append("purpose: \(agent.purpose)")
        }
        if let lastTask = transcript.last(where: { $0.kind == .user }) {
            lines.append("latest task (\(Self.relativeTime(since: lastTask.createdAt))): \(Self.shortened(lastTask.text, to: 300))")
        }
        let queuedTasks = queuedMessages(for: agent)
        if !queuedTasks.isEmpty {
            lines.append("waiting in line (\(queuedTasks.count)): " + queuedTasks.prefix(5).map { Self.shortened($0, to: 120) }.joined(separator: " | "))
        }
        let recentSteps = transcript.suffix(30).filter { $0.kind == .tool }.suffix(6)
        if !recentSteps.isEmpty {
            let stepLines = recentSteps.map { step -> String in
                let outcome = step.toolSucceeded.map { $0 ? "ok" : "failed" } ?? "running"
                return "  \(Self.shortened(step.text, to: 100)) (\(outcome))"
            }
            lines.append("recent steps:\n" + stepLines.joined(separator: "\n"))
        }
        if let lastReply = transcript.last(where: { $0.kind == .assistant }) {
            lines.append("latest reply: \(Self.shortened(lastReply.text, to: 600))")
        }
        let outputFiles = outputFileNames(for: agent)
        if !outputFiles.isEmpty {
            lines.append("files it made: \(outputFiles.prefix(12).joined(separator: ", "))")
        }
        let routines = routineStore.routines(for: agent.id)
        if !routines.isEmpty {
            let routineText = routines.map { "\($0.title) every \($0.everyMinutes) min\($0.isPaused ? " (paused)" : "")" }
            lines.append("routines: \(routineText.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    /// working / waiting for permission / failed / stopped / done / new.
    func statusLine(for agent: ClickyAgent) -> String {
        let transcript = transcriptsByAgentID[agent.id] ?? []
        if isRunning(agent) {
            let startedAt = transcript.last(where: { $0.kind == .user || $0.kind == .routineRun })?.createdAt ?? agent.lastActivityAt
            var line = "working, started \(Self.relativeTime(since: startedAt))"
            if let currentStep = transcript.last(where: { $0.kind == .tool }), currentStep.createdAt >= startedAt {
                line += "; doing: \(Self.shortened(currentStep.text, to: 80))"
            }
            return line
        }
        if let request = pendingComputerUseRequest(for: agent) {
            return "waiting for the user to allow it to use the Mac: \(Self.shortened(request, to: 140))"
        }
        guard let lastItem = transcript.last(where: { $0.kind != .tool }) else {
            return "idle, no tasks yet"
        }
        switch lastItem.kind {
        case .error:
            return "stopped with a problem \(Self.relativeTime(since: lastItem.createdAt)): \(Self.shortened(lastItem.text, to: 160))"
        case .status where lastItem.text == "Stopped":
            return "stopped by the user \(Self.relativeTime(since: lastItem.createdAt))"
        case .assistant:
            return "finished \(Self.relativeTime(since: lastItem.createdAt))\(agent.hasUnreadReply == true ? " (user hasn't read it yet)" : "")"
        default:
            return "idle since \(Self.relativeTime(since: lastItem.createdAt))"
        }
    }

    /// Files in the helper's output folder, newest first.
    func outputFileNames(for agent: ClickyAgent) -> [String] {
        let outputFolderURL = workspaceURL(for: agent).appendingPathComponent("output", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: outputFolderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(path: String, modifiedAt: Date)] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            // Skip what package managers drop in a project folder.
            if fileURL.pathComponents.contains("node_modules") { continue }
            let relativePath = String(fileURL.path.dropFirst(outputFolderURL.path.count + 1))
            files.append((relativePath, values?.contentModificationDate ?? .distantPast))
            if files.count > 400 { break }
        }
        return files.sorted { $0.modifiedAt > $1.modifiedAt }.map(\.path)
    }

    /// Opens what the helper made: a website's index.html in the browser, a
    /// single file in its app, otherwise the output folder in Finder.
    @discardableResult
    func openHelperResult(for agent: ClickyAgent) -> String {
        let outputFolderURL = workspaceURL(for: agent).appendingPathComponent("output", isDirectory: true)
        let outputFiles = outputFileNames(for: agent)
        guard !outputFiles.isEmpty else {
            revealWorkspaceInFinder(for: agent)
            return "\(agent.name) hasn't saved any files yet, so I opened its folder."
        }
        let pageCandidates = outputFiles.filter { ($0 as NSString).lastPathComponent.lowercased() == "index.html" }
        // A built site (dist/index.html) beats its source page.
        let preferredPage = pageCandidates.first { $0.contains("dist/") || $0.contains("build/") }
            ?? pageCandidates.min { $0.count < $1.count }
        if let preferredPage {
            Task { await DottieBrowser.openInUsersBrowser(outputFolderURL.appendingPathComponent(preferredPage)) }
            return "opened \(preferredPage) from \(agent.name) in the browser."
        }
        if outputFiles.count == 1, let onlyFile = outputFiles.first {
            NSWorkspace.shared.open(outputFolderURL.appendingPathComponent(onlyFile))
            return "opened \(onlyFile)."
        }
        revealWorkspaceInFinder(for: agent)
        return "opened \(agent.name)'s output folder in Finder (\(outputFiles.count) files)."
    }

    private static func shortened(_ text: String, to maximumLength: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return singleLine.count > maximumLength ? String(singleLine.prefix(maximumLength - 1)) + "…" : singleLine
    }

    private static func relativeTime(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) days ago"
        }
    }
}
