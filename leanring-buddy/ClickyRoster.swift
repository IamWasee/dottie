//
//  ClickyRoster.swift
//  leanring-buddy
//
//  Background agents ("Clickys"). Shipped Clicky lets you spin up named
//  agents that work on a task in their own folder while you keep going, and
//  report back in the notch when they finish (ClickyAgentsRuntime,
//  CodexAgentSession). The clone runs each turn through Gemini CLI
//  (GeminiCLIAgentRuntime); this file owns the list of agents, their
//  workspaces on disk and their transcripts.
//
//  On disk, under ~/Library/Application Support/ClickyClone/Clickys/:
//    roster.json                 every agent
//    <slug>/AGENTS.md            the agent's instructions (Gemini CLI reads it)
//    <slug>/.gemini/settings.json
//    <slug>/output/              where finished work goes
//    <slug>/transcript.json      what the Home window shows
//

import AppKit
import Combine
import Foundation

struct ClickyAgent: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var purpose: String
    let createdAt: Date
    /// Gemini CLI session, so each turn resumes the same conversation.
    let sessionID: UUID
    let workspaceFolderName: String
    var model: String
    var hasStartedSession: Bool
    var lastActivityAt: Date
}

struct ClickyAgentTranscriptItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case user
        case assistant
        case tool
        case status
        case error
        /// The agent asked to click and type on the Mac (see ClickyComputerUse).
        case computerUseRequest
    }

    let id: UUID
    let kind: Kind
    var text: String
    let createdAt: Date
    /// For tool items: Gemini CLI's tool ID, used to mark it finished.
    var toolID: String?
    var toolSucceeded: Bool?
}

@MainActor
final class ClickyRoster: ObservableObject {
    @Published private(set) var agents: [ClickyAgent] = []
    @Published private(set) var transcriptsByAgentID: [UUID: [ClickyAgentTranscriptItem]] = [:]
    @Published private(set) var runningAgentIDs: Set<UUID> = []

    /// Called when a turn ends, with the agent, its final reply, whether it
    /// succeeded, and what it asked to do on screen if it needs permission.
    /// The companion shows this in the notch.
    var onAgentTurnFinished: ((_ agent: ClickyAgent, _ finalReply: String, _ succeeded: Bool, _ computerUseRequest: String?) -> Void)?

    private let runtime = GeminiCLIAgentRuntime()
    private var lastTurnSucceededByAgentID: [UUID: Bool] = [:]
    private let rosterDirectoryURL: URL
    private var rosterFileURL: URL { rosterDirectoryURL.appendingPathComponent("roster.json") }
    /// Gemini CLI's home for all agents (settings and saved sessions).
    private var cliHomeURL: URL { rosterDirectoryURL.appendingPathComponent(".cli-home", isDirectory: true) }

    init() {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        rosterDirectoryURL = applicationSupportDirectory
            .appendingPathComponent("ClickyClone", isDirectory: true)
            .appendingPathComponent("Clickys", isDirectory: true)
        try? FileManager.default.createDirectory(at: rosterDirectoryURL, withIntermediateDirectories: true)
        GeminiCLIAgentRuntime.prepareCLIHome(at: cliHomeURL)
        loadRoster()
    }

    // MARK: - Agents

    func workspaceURL(for agent: ClickyAgent) -> URL {
        rosterDirectoryURL.appendingPathComponent(agent.workspaceFolderName, isDirectory: true)
    }

    func agent(withID agentID: UUID) -> ClickyAgent? {
        agents.first { $0.id == agentID }
    }

    /// Case-insensitive match on name, for voice ("ask the research clicky…").
    func agent(matchingName spokenName: String) -> ClickyAgent? {
        let normalizedSpokenName = spokenName.lowercased()
            .replacingOccurrences(of: "clicky", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSpokenName.isEmpty else { return nil }
        return agents.first { $0.name.lowercased() == normalizedSpokenName }
            ?? agents.first { $0.name.lowercased().contains(normalizedSpokenName) || normalizedSpokenName.contains($0.name.lowercased()) }
    }

    @discardableResult
    func createAgent(name: String, purpose: String) -> ClickyAgent {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentName = trimmedName.isEmpty ? "Clicky \(agents.count + 1)" : trimmedName
        let newAgent = ClickyAgent(
            id: UUID(),
            name: agentName,
            purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            sessionID: UUID(),
            workspaceFolderName: uniqueWorkspaceFolderName(for: agentName),
            model: AppBundleConfiguration.stringValue(forKey: "GeminiAgentModel") ?? GeminiCLIAgentRuntime.defaultAgentModel,
            hasStartedSession: false,
            lastActivityAt: Date()
        )
        prepareWorkspace(for: newAgent)
        agents.insert(newAgent, at: 0)
        transcriptsByAgentID[newAgent.id] = []
        saveRoster()
        return newAgent
    }

    func deleteAgent(_ agent: ClickyAgent) {
        stopAgent(agent)
        agents.removeAll { $0.id == agent.id }
        transcriptsByAgentID[agent.id] = nil
        saveRoster()
        // Move the folder to the Trash rather than deleting the agent's work.
        try? FileManager.default.trashItem(at: workspaceURL(for: agent), resultingItemURL: nil)
    }

    func revealWorkspaceInFinder(for agent: ClickyAgent) {
        NSWorkspace.shared.activateFileViewerSelecting([workspaceURL(for: agent).appendingPathComponent("output", isDirectory: true)])
    }

    // MARK: - Turns

    func isRunning(_ agent: ClickyAgent) -> Bool {
        runningAgentIDs.contains(agent.id)
    }

    /// Sends a message to an agent and runs its turn in the background.
    /// `isComputerUseApproved` lets this turn click and type on the Mac;
    /// "Always allow" in settings does the same for every turn.
    func sendMessage(_ messageText: String, to requestedAgent: ClickyAgent, isComputerUseApproved: Bool = false) {
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Re-read the agent so hasStartedSession is current.
        guard !trimmedMessageText.isEmpty,
              let agent = agent(withID: requestedAgent.id),
              !isRunning(agent) else { return }

        appendTranscriptItem(.user, text: trimmedMessageText, to: agent.id)
        runningAgentIDs.insert(agent.id)
        touchAgent(agent.id)

        let isFirstTurn = !agent.hasStartedSession
        let agentWorkspaceURL = workspaceURL(for: agent)
        let agentID = agent.id
        let isTurnApprovedForComputerUse = isComputerUseApproved || ClickyComputerUse.isAlwaysAllowed
        let messageForAgent = isTurnApprovedForComputerUse
            ? "\(ClickyComputerUse.approvedTurnPrefix)\n\n\(trimmedMessageText)"
            : trimmedMessageText
        // Picks up a cua-driver installed since launch.
        GeminiCLIAgentRuntime.prepareCLIHome(at: cliHomeURL)

        lastTurnSucceededByAgentID[agentID] = false

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runtime.runTurn(
                    agentID: agentID,
                    sessionID: agent.sessionID,
                    isFirstTurn: isFirstTurn,
                    message: messageForAgent,
                    workspaceURL: agentWorkspaceURL,
                    cliHomeURL: self.cliHomeURL,
                    model: agent.model,
                    isComputerUseApproved: isTurnApprovedForComputerUse
                ) { [weak self] event in
                    // The main queue is FIFO, so events land in order and
                    // before finishTurn below.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.handleRuntimeEvent(event, agentID: agentID)
                        }
                    }
                }
            } catch {
                self.appendTranscriptItem(.error, text: error.localizedDescription, to: agentID)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishTurn(agentID: agentID)
                }
            }
        }
    }

    func stopAgent(_ agent: ClickyAgent) {
        guard isRunning(agent) else { return }
        runtime.stopTurn(agentID: agent.id)
        appendTranscriptItem(.status, text: "Stopped", to: agent.id)
    }

    private func handleRuntimeEvent(_ event: GeminiCLIAgentEvent, agentID: UUID) {
        switch event {
        case .sessionStarted:
            // The CLI created the session; later turns must resume it.
            if let agentIndex = agents.firstIndex(where: { $0.id == agentID }), !agents[agentIndex].hasStartedSession {
                agents[agentIndex].hasStartedSession = true
                saveRoster()
            }
        case .assistantTextDelta(let textDelta):
            var transcript = transcriptsByAgentID[agentID] ?? []
            if let lastItem = transcript.last, lastItem.kind == .assistant {
                transcript[transcript.count - 1].text += textDelta
                transcriptsByAgentID[agentID] = transcript
            } else {
                appendTranscriptItem(.assistant, text: textDelta, to: agentID, persist: false)
            }
        case .toolStarted(let toolID, let toolName, let parametersSummary):
            let toolLine = parametersSummary.isEmpty ? toolName : "\(toolName) · \(parametersSummary)"
            appendTranscriptItem(.tool, text: toolLine, to: agentID, toolID: toolID, persist: false)
        case .toolFinished(let toolID, let succeeded):
            guard var transcript = transcriptsByAgentID[agentID],
                  let toolItemIndex = transcript.lastIndex(where: { $0.toolID == toolID }) else { return }
            transcript[toolItemIndex].toolSucceeded = succeeded
            transcriptsByAgentID[agentID] = transcript
        case .warning(let warningMessage):
            appendTranscriptItem(.error, text: warningMessage, to: agentID, persist: false)
        case .finished(let succeeded, _, _):
            lastTurnSucceededByAgentID[agentID] = succeeded
        }
    }

    private func finishTurn(agentID: UUID) {
        let succeeded = lastTurnSucceededByAgentID[agentID] ?? false
        runningAgentIDs.remove(agentID)
        touchAgent(agentID)
        saveTranscript(for: agentID)

        guard let finishedAgent = agent(withID: agentID) else { return }
        let computerUseRequest = moveComputerUseRequestOutOfLastReply(agentID: agentID)
        let finalReply = transcriptsByAgentID[agentID]?
            .last { $0.kind == .assistant || $0.kind == .error }?
            .text ?? ""
        onAgentTurnFinished?(finishedAgent, finalReply, succeeded, computerUseRequest)
    }

    /// If the agent's last reply ends with a <COMPUTER_USE_REQUEST> block,
    /// strips it from the reply and adds it as its own transcript item.
    private func moveComputerUseRequestOutOfLastReply(agentID: UUID) -> String? {
        guard var transcript = transcriptsByAgentID[agentID],
              let lastReplyIndex = transcript.lastIndex(where: { $0.kind == .assistant }) else { return nil }
        let (replyWithoutRequest, requestDescription) = ClickyComputerUse.extractComputerUseRequest(from: transcript[lastReplyIndex].text)
        guard let requestDescription else { return nil }

        if replyWithoutRequest.isEmpty {
            transcript.remove(at: lastReplyIndex)
        } else {
            transcript[lastReplyIndex].text = replyWithoutRequest
        }
        transcriptsByAgentID[agentID] = transcript
        appendTranscriptItem(.computerUseRequest, text: requestDescription, to: agentID)
        return requestDescription
    }

    // MARK: - Computer use permission

    /// What the agent is waiting to do on screen, if its last transcript
    /// item is an unanswered request.
    func pendingComputerUseRequest(for agent: ClickyAgent) -> String? {
        guard !isRunning(agent),
              let lastItem = transcriptsByAgentID[agent.id]?.last,
              lastItem.kind == .computerUseRequest else { return nil }
        return lastItem.text
    }

    /// The user tapped Allow (or Always allow): run a turn that may click
    /// and type.
    func approveComputerUse(for agent: ClickyAgent, alwaysAllow: Bool) {
        guard pendingComputerUseRequest(for: agent) != nil else { return }
        if alwaysAllow {
            ClickyComputerUse.isAlwaysAllowed = true
        }
        appendTranscriptItem(.status, text: alwaysAllow ? "Always allowed to use your Mac" : "Allowed to use your Mac this time", to: agent.id)
        sendMessage("Go ahead with what you asked to do on screen.", to: agent, isComputerUseApproved: true)
    }

    func declineComputerUse(for agent: ClickyAgent) {
        guard pendingComputerUseRequest(for: agent) != nil else { return }
        appendTranscriptItem(.status, text: "Not allowed to use your Mac this time", to: agent.id)
    }

    // MARK: - Transcript helpers

    private func appendTranscriptItem(
        _ kind: ClickyAgentTranscriptItem.Kind,
        text: String,
        to agentID: UUID,
        toolID: String? = nil,
        persist: Bool = true
    ) {
        var transcript = transcriptsByAgentID[agentID] ?? []
        transcript.append(ClickyAgentTranscriptItem(
            id: UUID(),
            kind: kind,
            text: text,
            createdAt: Date(),
            toolID: toolID,
            toolSucceeded: nil
        ))
        transcriptsByAgentID[agentID] = transcript
        if persist {
            saveTranscript(for: agentID)
        }
    }

    private func touchAgent(_ agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[agentIndex].lastActivityAt = Date()
        saveRoster()
    }

    // MARK: - Workspace

    private func uniqueWorkspaceFolderName(for agentName: String) -> String {
        let slugCharacters = agentName.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let baseSlug = String(slugCharacters)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let safeBaseSlug = baseSlug.isEmpty ? "clicky" : String(baseSlug.prefix(40))

        var candidateSlug = safeBaseSlug
        var suffixNumber = 2
        while FileManager.default.fileExists(atPath: rosterDirectoryURL.appendingPathComponent(candidateSlug).path) {
            candidateSlug = "\(safeBaseSlug)-\(suffixNumber)"
            suffixNumber += 1
        }
        return candidateSlug
    }

    private func prepareWorkspace(for agent: ClickyAgent) {
        let agentWorkspaceURL = workspaceURL(for: agent)
        let fileManager = FileManager.default
        for subfolderName in ["output", "tmp", ".gemini"] {
            try? fileManager.createDirectory(
                at: agentWorkspaceURL.appendingPathComponent(subfolderName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try? Self.agentInstructions(for: agent)
            .write(to: agentWorkspaceURL.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        // Auth lives in the shared CLI home; this pins the context file and
        // model for this agent.
        let geminiSettings: [String: Any] = [
            "context": ["fileName": "AGENTS.md"],
            "model": ["name": agent.model]
        ]
        if let settingsData = try? JSONSerialization.data(withJSONObject: geminiSettings, options: [.prettyPrinted, .sortedKeys]) {
            try? settingsData.write(to: agentWorkspaceURL.appendingPathComponent(".gemini/settings.json"))
        }
    }

    /// The standing instructions every agent gets. Written for the clone;
    /// the shape (identity, how to work, where output goes) follows what
    /// shipped Clicky gives its agents.
    private static func agentInstructions(for agent: ClickyAgent) -> String {
        let purposeLine = agent.purpose.isEmpty ? "Whatever the user asks." : agent.purpose
        return """
        # \(agent.name)

        You are \(agent.name), one of the user's Clickys: a background helper that works on its own while the user gets on with their day. The user talks to you from the Clicky app on their Mac. They usually aren't watching while you work, so finish the job before you reply.

        Your purpose: \(purposeLine)

        ## How you work

        - This folder is your workspace. Put anything you make for the user in `output/` and scratch files in `tmp/`.
        - Do the work rather than describing how it could be done. Use the shell, files and web tools you have.
        - Ask a question only when you truly can't go on without the answer. Otherwise pick a sensible default and say which one you picked.
        - Don't delete or overwrite the user's files outside this folder, send messages, buy things or change accounts unless the user clearly asked for exactly that.
        - When you finish, reply in a few plain sentences: what you did, where the result is (a path in `output/`), and anything the user needs to decide. Your reply may be read aloud, so skip markdown tables and long lists.

        ## Notes

        Keep short notes below about the user's preferences and what you've learned, so you remember them next time.

        """
    }

    // MARK: - Persistence

    private func loadRoster() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rosterData = try? Data(contentsOf: rosterFileURL),
              let savedAgents = try? decoder.decode([ClickyAgent].self, from: rosterData) else { return }
        agents = savedAgents
        for savedAgent in savedAgents {
            let transcriptURL = workspaceURL(for: savedAgent).appendingPathComponent("transcript.json")
            if let transcriptData = try? Data(contentsOf: transcriptURL),
               let savedTranscript = try? decoder.decode([ClickyAgentTranscriptItem].self, from: transcriptData) {
                transcriptsByAgentID[savedAgent.id] = savedTranscript
            }
        }
    }

    private func saveRoster() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let rosterData = try? encoder.encode(agents) else { return }
        try? rosterData.write(to: rosterFileURL, options: .atomic)
    }

    private func saveTranscript(for agentID: UUID) {
        guard let agent = agent(withID: agentID) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Keep the last 500 items so the file stays small.
        let transcriptToSave = Array((transcriptsByAgentID[agentID] ?? []).suffix(500))
        guard let transcriptData = try? encoder.encode(transcriptToSave) else { return }
        try? transcriptData.write(to: workspaceURL(for: agent).appendingPathComponent("transcript.json"), options: .atomic)
    }
}
