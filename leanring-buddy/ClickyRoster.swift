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
//  On disk, under ~/Library/Application Support/Dottie/Dots/:
//    roster.json                 every agent
//    <slug>/AGENTS.md            the agent's instructions (Gemini CLI reads it)
//    <slug>/.gemini/settings.json
//    <slug>/output/              where finished work goes
//    <slug>/transcript.json      what the Home window shows
//    routines.json               scheduled re-runs (ClickyRoutines)
//  Skills live next door in Dottie/Skills (ClickySkillLibrary).
//

import AppKit
import Combine
import Foundation
import Network

struct ClickyAgent: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var purpose: String
    let createdAt: Date
    /// Gemini CLI session, so each turn resumes the same conversation.
    /// Replaced with a fresh one when the CLI has lost the old session.
    var sessionID: UUID
    let workspaceFolderName: String
    var model: String
    var hasStartedSession: Bool
    var lastActivityAt: Date
    /// Library skills linked into this agent's workspace. Optional so
    /// rosters saved before skills existed still load.
    var enabledSkillNames: [String]?
    /// A turn finished and the user hasn't looked at its chat since. The
    /// notch counts these.
    var hasUnreadReply: Bool?
    /// Dottie's second brain (see DottieBrain): one per Mac, with the
    /// user's chosen folders and the memory folder.
    var isBrain: Bool?
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
        /// Marks the start of a scheduled routine run (see ClickyRoutines).
        case routineRun
    }

    let id: UUID
    let kind: Kind
    var text: String
    let createdAt: Date
    /// For tool items: Gemini CLI's tool ID, used to mark it finished.
    var toolID: String?
    var toolSucceeded: Bool?
}

/// How a turn ended, for the notch.
struct ClickyAgentTurnResult {
    let agent: ClickyAgent
    let finalReply: String
    let succeeded: Bool
    /// What the agent asked to do on screen, if it needs permission.
    let computerUseRequest: String?
    /// Set when the turn was a scheduled routine run.
    let routineTitle: String?
}

@MainActor
final class ClickyRoster: ObservableObject {
    @Published private(set) var agents: [ClickyAgent] = []
    @Published private(set) var transcriptsByAgentID: [UUID: [ClickyAgentTranscriptItem]] = [:]
    @Published private(set) var runningAgentIDs: Set<UUID> = []
    /// Set when something (the notch) asks Home to show a Dot's chat; Home
    /// clears it once it has.
    @Published private(set) var agentIDRequestedInHome: UUID?
    /// Helpers the user deleted since launch, so Dottie can say so instead
    /// of looking for them.
    private(set) var recentlyDeletedAgentNames: [String] = []

    /// Folders the Brain agent may work in, from DottieBrain.
    var brainFolderURLsProvider: (@MainActor () -> [URL])?

    /// Called when a turn ends. The companion shows it in the notch.
    var onAgentTurnFinished: ((ClickyAgentTurnResult) -> Void)?

    let skillLibrary: ClickySkillLibrary
    let routineStore: ClickyRoutineStore

    private let runtime = GeminiCLIAgentRuntime()
    /// Tasks sent to a Dot while it was busy, oldest first. The next one
    /// starts when its turn ends.
    @Published private(set) var queuedMessagesByAgentID: [UUID: [String]] = [:]
    private var lastTurnSucceededByAgentID: [UUID: Bool] = [:]
    /// The routine a running turn belongs to, if it's a scheduled run.
    private var routineIDByRunningAgentID: [UUID: UUID] = [:]
    /// Library folders before each running turn, to spot skills it saved.
    private var skillFolderNamesBeforeTurnByAgentID: [UUID: Set<String>] = [:]
    private var routineSchedulerTimer: Timer?
    private let networkPathMonitor = NWPathMonitor()
    private var isNetworkAvailable = true
    private let rosterDirectoryURL: URL
    private var rosterFileURL: URL { rosterDirectoryURL.appendingPathComponent("roster.json") }
    /// Gemini CLI's home for all agents (settings and saved sessions).
    private var cliHomeURL: URL { rosterDirectoryURL.appendingPathComponent(".cli-home", isDirectory: true) }

    init() {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cloneDirectoryURL = applicationSupportDirectory.appendingPathComponent("Dottie", isDirectory: true)
        rosterDirectoryURL = cloneDirectoryURL.appendingPathComponent("Dots", isDirectory: true)
        try? FileManager.default.createDirectory(at: rosterDirectoryURL, withIntermediateDirectories: true)
        skillLibrary = ClickySkillLibrary(libraryURL: cloneDirectoryURL.appendingPathComponent("Skills", isDirectory: true))
        routineStore = ClickyRoutineStore(routinesFileURL: rosterDirectoryURL.appendingPathComponent("routines.json"))
        GeminiCLIAgentRuntime.prepareCLIHome(at: cliHomeURL, skillLibraryURL: skillLibrary.libraryURL)
        loadRoster()
        startRoutineScheduler()
    }

    // MARK: - Agents

    func workspaceURL(for agent: ClickyAgent) -> URL {
        rosterDirectoryURL.appendingPathComponent(agent.workspaceFolderName, isDirectory: true)
    }

    func agent(withID agentID: UUID) -> ClickyAgent? {
        agents.first { $0.id == agentID }
    }

    /// Case-insensitive match on name, for voice ("ask the research dot…").
    func agent(matchingName spokenName: String) -> ClickyAgent? {
        let normalizedSpokenName = spokenName.lowercased()
            .replacingOccurrences(of: "\\bdots?\\b", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSpokenName.isEmpty else { return nil }
        return agents.first { $0.name.lowercased() == normalizedSpokenName }
            ?? agents.first { $0.name.lowercased().contains(normalizedSpokenName) || normalizedSpokenName.contains($0.name.lowercased()) }
    }

    /// The Brain agent, made the first time it's needed.
    func brainAgent() -> ClickyAgent {
        if let existingBrain = agents.first(where: { $0.isBrain == true }) {
            return existingBrain
        }
        var brain = createAgent(name: "Brain", purpose: "Dottie's second brain: remembers what the user does, digs through their files and tools, and answers or acts for Dottie.")
        brain.isBrain = true
        if let brainIndex = agents.firstIndex(where: { $0.id == brain.id }) {
            agents[brainIndex] = brain
        }
        prepareWorkspace(for: brain)
        saveRoster()
        return brain
    }

    @discardableResult
    func createAgent(name: String, purpose: String) -> ClickyAgent {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentName = trimmedName.isEmpty ? "Dot \(agents.count + 1)" : trimmedName
        let newAgent = ClickyAgent(
            id: UUID(),
            name: agentName,
            purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            sessionID: UUID(),
            workspaceFolderName: uniqueWorkspaceFolderName(for: agentName),
            model: AppBundleConfiguration.stringValue(forKey: "GeminiAgentModel") ?? GeminiCLIAgentRuntime.defaultAgentModel,
            hasStartedSession: false,
            lastActivityAt: Date(),
            // A new Clicky starts with every skill in the library.
            enabledSkillNames: skillLibrary.skills.map(\.name)
        )
        prepareWorkspace(for: newAgent)
        recentlyDeletedAgentNames.removeAll { $0.caseInsensitiveCompare(agentName) == .orderedSame }
        agents.insert(newAgent, at: 0)
        transcriptsByAgentID[newAgent.id] = []
        saveRoster()
        return newAgent
    }

    func deleteAgent(_ agent: ClickyAgent) {
        queuedMessagesByAgentID[agent.id] = nil
        stopAgent(agent)
        agents.removeAll { $0.id == agent.id }
        transcriptsByAgentID[agent.id] = nil
        recentlyDeletedAgentNames.removeAll { $0.caseInsensitiveCompare(agent.name) == .orderedSame }
        recentlyDeletedAgentNames.append(agent.name)
        routineStore.deleteRoutines(forAgentID: agent.id)
        saveRoster()
        // Move the folder to the Trash rather than deleting the agent's work.
        try? FileManager.default.trashItem(at: workspaceURL(for: agent), resultingItemURL: nil)
    }

    var unreadAgentCount: Int {
        agents.filter { $0.hasUnreadReply == true }.count
    }

    func markRead(agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }),
              agents[agentIndex].hasUnreadReply == true else { return }
        agents[agentIndex].hasUnreadReply = false
        saveRoster()
    }

    /// Asks Home to open this Dot's chat (Home shows it when it next
    /// appears, or right away if it's open).
    func requestShowInHome(agentID: UUID) {
        agentIDRequestedInHome = agentID
    }

    func clearHomeRequest() {
        agentIDRequestedInHome = nil
    }

    func revealWorkspaceInFinder(for agent: ClickyAgent) {
        NSWorkspace.shared.activateFileViewerSelecting([workspaceURL(for: agent).appendingPathComponent("output", isDirectory: true)])
    }

    // MARK: - Turns

    func isRunning(_ agent: ClickyAgent) -> Bool {
        runningAgentIDs.contains(agent.id)
    }

    /// Runs the task now, or lines it up if the Dot is busy. Returns how
    /// many tasks are ahead of it (0 when it started right away).
    @discardableResult
    func sendOrQueueMessage(_ messageText: String, to agent: ClickyAgent) -> Int {
        guard isRunning(agent) else {
            sendMessage(messageText, to: agent)
            return 0
        }
        queuedMessagesByAgentID[agent.id, default: []].append(messageText)
        return queuedMessagesByAgentID[agent.id]?.count ?? 1
    }

    func queuedMessages(for agent: ClickyAgent) -> [String] {
        queuedMessagesByAgentID[agent.id] ?? []
    }

    func clearQueuedMessages(for agent: ClickyAgent) {
        queuedMessagesByAgentID[agent.id] = nil
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
        // The agent only learns which routines it has from this list.
        let routinesContext = ClickyRoutinePrompts.currentRoutinesContext(for: routineStore.routines(for: agent.id))
        startTurn(
            for: agent,
            messageForAgent: "\(routinesContext)\n\n\(trimmedMessageText)",
            isComputerUseApproved: isComputerUseApproved,
            routineID: nil
        )
    }

    /// Runs one turn. The transcript item for it is already added.
    private func startTurn(for agent: ClickyAgent, messageForAgent: String, isComputerUseApproved: Bool, routineID: UUID?) {
        runningAgentIDs.insert(agent.id)
        touchAgent(agent.id)

        let isFirstTurn = !agent.hasStartedSession
        let agentWorkspaceURL = workspaceURL(for: agent)
        let agentID = agent.id
        let isTurnApprovedForComputerUse = isComputerUseApproved || ClickyComputerUse.isAlwaysAllowed
        let fullMessageForAgent = isTurnApprovedForComputerUse
            ? "\(ClickyComputerUse.approvedTurnPrefix)\n\n\(messageForAgent)"
            : messageForAgent
        // Picks up a cua-driver installed since launch.
        GeminiCLIAgentRuntime.prepareCLIHome(at: cliHomeURL, skillLibraryURL: skillLibrary.libraryURL)
        skillLibrary.reload()
        skillLibrary.linkSkills(named: Set(agent.enabledSkillNames ?? []), intoWorkspace: agentWorkspaceURL)
        skillFolderNamesBeforeTurnByAgentID[agentID] = skillLibrary.skillFolderNamesOnDisk()
        routineIDByRunningAgentID[agentID] = routineID

        lastTurnSucceededByAgentID[agentID] = false

        let additionalDirectoryURLs = [skillLibrary.libraryURL]
            + (agent.isBrain == true
                ? [DottieBrain.defaultBrainFolderURL] + (brainFolderURLsProvider?() ?? [])
                : [])

        Task { [weak self] in
            guard let self else { return }
            do {
                do {
                    try await self.runAgentProcess(
                        agent: agent,
                        sessionID: agent.sessionID,
                        isFirstTurn: isFirstTurn,
                        message: fullMessageForAgent,
                        workspaceURL: agentWorkspaceURL,
                        isComputerUseApproved: isTurnApprovedForComputerUse,
                        additionalDirectoryURLs: additionalDirectoryURLs
                    )
                } catch GeminiCLIAgentRuntimeError.processFailed(_, let standardErrorTail)
                            where !isFirstTurn && Self.isLostSessionError(standardErrorTail) {
                    // Gemini CLI lost the saved conversation (for example
                    // the first turn failed before it was written). Start a
                    // fresh session and hand over the recent chat instead,
                    // rather than failing every turn from now on.
                    let freshSessionID = self.replaceSession(forAgentID: agentID)
                    try await self.runAgentProcess(
                        agent: agent,
                        sessionID: freshSessionID,
                        isFirstTurn: true,
                        message: self.recentConversationContext(forAgentID: agentID) + fullMessageForAgent,
                        workspaceURL: agentWorkspaceURL,
                        isComputerUseApproved: isTurnApprovedForComputerUse,
                        additionalDirectoryURLs: additionalDirectoryURLs
                    )
                } catch GeminiCLIAgentRuntimeError.processFailed(_, let standardErrorTail)
                            where isFirstTurn && standardErrorTail.lowercased().contains("already exists") {
                    // An earlier turn did save the session after all
                    // (it failed partway): carry on in it.
                    try await self.runAgentProcess(
                        agent: agent,
                        sessionID: agent.sessionID,
                        isFirstTurn: false,
                        message: fullMessageForAgent,
                        workspaceURL: agentWorkspaceURL,
                        isComputerUseApproved: isTurnApprovedForComputerUse,
                        additionalDirectoryURLs: additionalDirectoryURLs
                    )
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

    /// One Gemini CLI process for this agent's turn, streaming its events
    /// into the transcript.
    private func runAgentProcess(
        agent: ClickyAgent,
        sessionID: UUID,
        isFirstTurn: Bool,
        message: String,
        workspaceURL: URL,
        isComputerUseApproved: Bool,
        additionalDirectoryURLs: [URL]
    ) async throws {
        let agentID = agent.id
        try await self.runtime.runTurn(
            agentID: agentID,
            sessionID: sessionID,
            isFirstTurn: isFirstTurn,
            message: message,
            workspaceURL: workspaceURL,
            cliHomeURL: self.cliHomeURL,
            model: agent.model,
            isComputerUseApproved: isComputerUseApproved,
            // So the agent's file tools can save skills there.
            additionalDirectoryURLs: additionalDirectoryURLs
        ) { [weak self] event in
            // The main queue is FIFO, so events land in order and
            // before finishTurn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleRuntimeEvent(event, agentID: agentID)
                }
            }
        }
    }

    /// Gemini CLI's "Error resuming session: No previous sessions found…".
    private static func isLostSessionError(_ standardErrorTail: String) -> Bool {
        let lowercasedError = standardErrorTail.lowercased()
        return lowercasedError.contains("error resuming session")
            || lowercasedError.contains("no previous sessions found")
            || lowercasedError.contains("session not found")
    }

    /// Gives the agent a new CLI session ID and returns it.
    private func replaceSession(forAgentID agentID: UUID) -> UUID {
        let freshSessionID = UUID()
        if let agentIndex = agents.firstIndex(where: { $0.id == agentID }) {
            agents[agentIndex].sessionID = freshSessionID
            agents[agentIndex].hasStartedSession = false
            saveRoster()
        }
        return freshSessionID
    }

    /// The last few messages of this agent's chat, so a fresh session still
    /// knows what was said.
    private func recentConversationContext(forAgentID agentID: UUID) -> String {
        let recentLines = (transcriptsByAgentID[agentID] ?? [])
            .filter { $0.kind == .user || $0.kind == .assistant }
            .dropLast()   // the message being sent now
            .suffix(10)
            .map { ($0.kind == .user ? "User: " : "You: ") + String($0.text.prefix(1500)) }
        guard !recentLines.isEmpty else { return "" }
        return "Earlier in this chat (for context):\n" + recentLines.joined(separator: "\n") + "\n\n"
    }

    func stopAgent(_ agent: ClickyAgent) {
        guard isRunning(agent) else { return }
        runtime.stopTurn(agentID: agent.id)
        appendTranscriptItem(.status, text: "Stopped", to: agent.id)
    }

    private func handleRuntimeEvent(_ event: GeminiCLIAgentEvent, agentID: UUID) {
        switch event {
        case .sessionStarted:
            // Not saved yet: Gemini CLI only writes the session once a turn
            // gets an answer, so a first turn that fails (busy, quota) leaves
            // nothing to resume. It's marked on a successful finish instead.
            break
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
            // The CLI saved the session; later turns resume it.
            if succeeded, let agentIndex = agents.firstIndex(where: { $0.id == agentID }), !agents[agentIndex].hasStartedSession {
                agents[agentIndex].hasStartedSession = true
                saveRoster()
            }
        }
    }

    private func finishTurn(agentID: UUID) {
        let succeeded = lastTurnSucceededByAgentID[agentID] ?? false
        let routineID = routineIDByRunningAgentID.removeValue(forKey: agentID)
        let skillFolderNamesBeforeTurn = skillFolderNamesBeforeTurnByAgentID.removeValue(forKey: agentID) ?? []
        runningAgentIDs.remove(agentID)
        touchAgent(agentID)
        // A turn that ended with no answer and no error used to look like the
        // Dot just stopped. Say so instead.
        if !succeeded, let lastItem = transcriptsByAgentID[agentID]?.last,
           lastItem.kind != .assistant, lastItem.kind != .error, lastItem.text != "Stopped" {
            appendTranscriptItem(.error, text: "Couldn't finish this one: Gemini was too busy to answer. Try sending it again.", to: agentID)
        }
        saveTranscript(for: agentID)

        guard agent(withID: agentID) != nil else { return }
        applyRoutineBlocksInLastReply(agentID: agentID)
        enableSkillsSavedDuringTurn(agentID: agentID, skillFolderNamesBeforeTurn: skillFolderNamesBeforeTurn)

        var routineTitle: String?
        if let routineID, let routine = routineStore.routine(withID: routineID) {
            routineTitle = routine.title
            ClickyAnalytics.trackRoutineRun(succeeded: succeeded)
            if routineStore.markRunFinished(routineID: routineID, succeeded: succeeded) {
                appendTranscriptItem(.status, text: "Paused routine “\(routine.title)” after \(ClickyRoutineStore.maximumFailedRunsInARow) failed runs in a row", to: agentID)
            }
        }

        let computerUseRequest = moveComputerUseRequestOutOfLastReply(agentID: agentID)
        // Home clears this right away if the chat is on screen.
        if let agentIndex = agents.firstIndex(where: { $0.id == agentID }) {
            agents[agentIndex].hasUnreadReply = true
            saveRoster()
        }
        guard let finishedAgent = agent(withID: agentID) else { return }
        let finalReply = transcriptsByAgentID[agentID]?
            .last { $0.kind == .assistant || $0.kind == .error }?
            .text ?? ""
        onAgentTurnFinished?(ClickyAgentTurnResult(
            agent: finishedAgent,
            finalReply: finalReply,
            succeeded: succeeded,
            computerUseRequest: computerUseRequest,
            routineTitle: routineTitle
        ))
        // Next task in line, unless the Dot is waiting on the user to allow
        // computer use (the allowed turn runs first, then the line resumes).
        if computerUseRequest == nil, var queuedMessages = queuedMessagesByAgentID[agentID], !queuedMessages.isEmpty {
            let nextMessage = queuedMessages.removeFirst()
            queuedMessagesByAgentID[agentID] = queuedMessages.isEmpty ? nil : queuedMessages
            sendMessage(nextMessage, to: finishedAgent)
        }
    }

    /// Strips <ROUTINE> blocks from the agent's last reply, applies them and
    /// notes each change in the transcript.
    private func applyRoutineBlocksInLastReply(agentID: UUID) {
        guard var transcript = transcriptsByAgentID[agentID],
              let lastReplyIndex = transcript.lastIndex(where: { $0.kind == .assistant }),
              transcript[lastReplyIndex].text.contains(ClickyRoutinePrompts.openingTag) else { return }
        let (replyWithoutBlocks, routineActions) = ClickyRoutinePrompts.extractRoutineActions(from: transcript[lastReplyIndex].text)
        if replyWithoutBlocks.isEmpty {
            transcript.remove(at: lastReplyIndex)
        } else {
            transcript[lastReplyIndex].text = replyWithoutBlocks
        }
        transcriptsByAgentID[agentID] = transcript
        for statusLine in routineStore.apply(routineActions, forAgentID: agentID) {
            appendTranscriptItem(.status, text: statusLine, to: agentID, persist: false)
        }
        saveTranscript(for: agentID)
    }

    /// Turns on, for this agent, any skill it saved to the library during
    /// the turn.
    private func enableSkillsSavedDuringTurn(agentID: UUID, skillFolderNamesBeforeTurn: Set<String>) {
        let newSkillFolderNames = skillLibrary.skillFolderNamesOnDisk().subtracting(skillFolderNamesBeforeTurn)
        guard !newSkillFolderNames.isEmpty else { return }
        skillLibrary.reload()
        for newSkillName in newSkillFolderNames.sorted() where skillLibrary.skill(named: newSkillName) != nil {
            setSkill(newSkillName, enabled: true, forAgentID: agentID)
            appendTranscriptItem(.status, text: "Saved a new skill: \(newSkillName)", to: agentID)
            ClickyAnalytics.trackSkillChanged(action: "saved_by_agent")
        }
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

    // MARK: - Skills

    func isSkill(_ skillName: String, enabledFor agent: ClickyAgent) -> Bool {
        (self.agent(withID: agent.id)?.enabledSkillNames ?? []).contains(skillName)
    }

    func setSkill(_ skillName: String, enabled: Bool, forAgentID agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }) else { return }
        var enabledSkillNames = agents[agentIndex].enabledSkillNames ?? []
        enabledSkillNames.removeAll { $0 == skillName }
        if enabled {
            enabledSkillNames.append(skillName)
        }
        agents[agentIndex].enabledSkillNames = enabledSkillNames
        saveRoster()
    }

    /// Turns a skill on for every Clicky, e.g. right after creating it.
    func enableSkillForAllAgents(_ skillName: String) {
        for agent in agents {
            setSkill(skillName, enabled: true, forAgentID: agent.id)
        }
    }

    func deleteSkill(_ skill: ClickySkill) {
        skillLibrary.deleteSkill(skill)
        for agent in agents {
            setSkill(skill.name, enabled: false, forAgentID: agent.id)
        }
        ClickyAnalytics.trackSkillChanged(action: "deleted")
    }

    // MARK: - Routines

    /// Checks for due routines every 30 seconds. Timers don't fire while the
    /// Mac sleeps, so a routine that came due during sleep runs once on wake.
    private func startRoutineScheduler() {
        networkPathMonitor.pathUpdateHandler = { [weak self] networkPath in
            let isSatisfied = networkPath.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isNetworkAvailable = isSatisfied
                }
            }
        }
        networkPathMonitor.start(queue: DispatchQueue(label: "com.dottie.routine-network"))

        routineSchedulerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.runDueRoutines()
                }
            }
        }
    }

    private func runDueRoutines() {
        guard isNetworkAvailable else { return }
        for dueRoutine in routineStore.dueRoutines(at: Date()) {
            runRoutine(dueRoutine)
        }
    }

    /// Runs a routine now, unless its Clicky is busy (the scheduler tries
    /// again on its next check).
    func runRoutine(_ requestedRoutine: ClickyRoutine) {
        guard let routine = routineStore.routine(withID: requestedRoutine.id),
              let agent = agent(withID: routine.agentID),
              !isRunning(agent) else { return }
        let previousRunStartedAt = routine.lastRunStartedAt
        let previousRunFailed = routine.failedRunsInARow > 0
        guard let runNumber = routineStore.markRunStarted(routineID: routine.id) else { return }

        appendTranscriptItem(.routineRun, text: "Routine “\(routine.title)” · run \(runNumber)", to: agent.id)
        startTurn(
            for: agent,
            messageForAgent: ClickyRoutinePrompts.runMessage(
                for: routine,
                runNumber: runNumber,
                previousRunStartedAt: previousRunStartedAt,
                previousRunFailed: previousRunFailed
            ),
            isComputerUseApproved: false,
            routineID: routine.id
        )
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
        let safeBaseSlug = baseSlug.isEmpty ? "dot" : String(baseSlug.prefix(40))

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
        if agent.isBrain == true {
            return brainInstructions
        }
        let purposeLine = agent.purpose.isEmpty ? "Whatever the user asks." : agent.purpose
        return """
        # \(agent.name)

        You are \(agent.name), one of the user's Dots: a background helper that works on its own while the user gets on with their day. The user talks to you from the Dottie app on their Mac. They usually aren't watching while you work, so finish the job before you reply.

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

    /// Standing instructions for the Brain agent.
    private static let brainInstructions = """
    # Brain

    You are Dottie's second brain. Dottie is the user's voice companion on their Mac; when a question needs memory, files or tools, she hands it to you, then says your answer out loud. Your reply goes back to Dottie, not straight to the user.

    ## What you have

    - Memory: the folder `\(DottieBrain.defaultBrainFolderURL.path)` holds `journal.jsonl` (one JSON memory per line: date, kind, text; kinds are chat, helper, screenJob, guide, remembered, and screen for what the user was doing) and `profile.md` (notes about the user). Search them with grep or your file tools whenever the question is about the past ("what was I working on yesterday", "what did we decide").
    - The user's folders: any folder listed in your workspace directories besides this one and the memory folder is a folder the user chose to share with you. Read, search and edit there as asked.
    - A shell with the user's command-line tools (git, node, python, brew and whatever else they have), the web, and any MCP tools that are connected.

    ## How you work

    - Do the work, then answer in two or three plain sentences Dottie can say out loud: the answer or what you did, and where any file is. No markdown tables or long lists.
    - Before anything that can't be undone or that reaches other people (deleting or overwriting the user's files, sending messages or emails, posting, buying, changing accounts or settings), stop and ask instead: describe exactly what you're about to do and end your reply with the question. Do it only after the user says yes in a later message.
    - Never reveal passwords, keys or other secrets you come across.
    - Put things you make in `output/` unless the user named a place.

    ## Notes

    Keep short notes below about what you learn about working with this user.

    """

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
