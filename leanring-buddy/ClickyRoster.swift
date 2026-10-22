//
//  ClickyRoster.swift
//  leanring-buddy
//
//  Background agents ("Clickys"). Shipped Clicky lets you spin up named
//  agents that work on a task in their own folder while you keep going, and
//  report back in the notch when they finish (ClickyAgentsRuntime,
//  CodexAgentSession). The clone runs each turn on Claude through
//  OpenMausBot when it's set up (DottieMausBotRuntime, each helper is a
//  MausBot bot), and on Gemini CLI (GeminiCLIAgentRuntime) otherwise or
//  when Claude's plan runs out. This file owns the list of agents, their
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
    /// The helper's bot in OpenMausBot, when it runs on Claude.
    var mausBotID: String?
    var mausBotName: String?
    /// Fingerprint of what the bot was last given (instructions, skills,
    /// folder), so it's only updated when something changed.
    var mausBotSpecHash: String?
    /// "claude", "gemini", or "gemini-backup" (Claude was meant to take the
    /// turn and couldn't): the engine its latest turn ran on.
    var lastHelperEngine: String?
    /// The chat with the user starts a fresh conversation, with a short
    /// handover, after a long break or many turns, so each turn doesn't
    /// re-read a long history (see ClickyRoster.mainChatConversation).
    var mainSessionTurnCount: Int?
    var mainSessionLastTurnAt: Date?
    /// The MausBot thread of the chat with the user, once known.
    var claudeMainThreadID: String?
}

/// Which conversation a helper turn continues, on each engine.
struct ClickyTurnConversation {
    var geminiSessionID: UUID
    var isFirstGeminiTurn: Bool
    /// Gemini didn't hear the recent chat (a fresh session, or Claude ran
    /// the last turns), so the turn starts with it.
    var geminiNeedsHandover: Bool
    /// MausBot's --task: "current", "new" or a thread ID.
    var claudeConversation: String
    var claudeNeedsHandover: Bool
    /// Set for a routine run, which keeps its own conversation.
    var routineID: UUID?
    /// Easy work (routine checks) stays on Gemini.
    var mayUseClaude: Bool
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
        /// A Claude helper stopped for an approval or a question in MausBot.
        case needsApproval
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
    /// A routine run that found nothing new: no card or notification.
    var foundNothingNew = false
}

/// Another feature (episodic memory) listens for this after every helper
/// turn, whichever engine ran it.
private let helperFinishedNotificationName = Notification.Name("dottie.helperFinished")

/// Transcript tool ID of the "Getting started…" step every turn shows at once.
private let gettingStartedToolID = "dottie-getting-started"

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
    /// Folders every Dot may work in besides its own (the projects folder).
    var sharedFolderURLs: [URL] = []

    /// Called when a turn ends. The companion shows it in the notch.
    var onAgentTurnFinished: ((ClickyAgentTurnResult) -> Void)?

    let skillLibrary: ClickySkillLibrary
    let routineStore: ClickyRoutineStore

    private let runtime = GeminiCLIAgentRuntime()
    /// Claude turns through OpenMausBot (see DottieMausBot).
    private let mausBotRuntime = DottieMausBotRuntime()
    /// Tasks sent to a Dot while it was busy, oldest first. The next one
    /// starts when its turn ends.
    @Published private(set) var queuedMessagesByAgentID: [UUID: [String]] = [:]
    private var lastTurnSucceededByAgentID: [UUID: Bool] = [:]
    /// The routine a running turn belongs to, if it's a scheduled run.
    private var routineIDByRunningAgentID: [UUID: UUID] = [:]
    /// Routines whose watched page is being read before a run.
    private var routineIDsCheckingWatchedPage: Set<UUID> = []
    /// A watched page's new fingerprint, saved once the run it started
    /// succeeds (so a failed run is tried again on the next check).
    private var pendingWatchedTextHashByRoutineID: [UUID: String] = [:]
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
        DottieMausBot.shared.warmUpAfterLaunch()
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
        mausBotRuntime.cancelFollowUp(agentID: agent.id)
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

        let routineReports = routineReportsSinceLastUserMessage(forAgentID: agent.id)
        appendTranscriptItem(.user, text: trimmedMessageText, to: agent.id)
        // The agent only learns which routines it has from this list.
        let routinesContext = ClickyRoutinePrompts.currentRoutinesContext(for: routineStore.routines(for: agent.id))
        startTurn(
            for: agent,
            messageForAgent: "\(routinesContext)\n\n\(routineReports)\(trimmedMessageText)",
            isComputerUseApproved: isComputerUseApproved,
            conversation: mainChatConversation(
                for: agent,
                messageText: trimmedMessageText,
                isComputerUseApproved: isComputerUseApproved
            )
        )
    }

    /// The chat with the user starts over after this long without a turn…
    static let mainSessionIdleSecondsBeforeFreshStart: TimeInterval = 45 * 60
    /// …or after this many turns, carrying over the last few messages.
    static let mainSessionTurnsBeforeFreshStart = 12

    /// The conversation a turn in the chat with the user continues, after
    /// counting the turn. Starts a fresh one when the current one has gone
    /// quiet or long: a resumed session re-reads its whole history on every
    /// request, so a short handover is far cheaper and loses little.
    private func mainChatConversation(for agent: ClickyAgent, messageText: String, isComputerUseApproved: Bool) -> ClickyTurnConversation {
        let lastMainTurnAt = agent.mainSessionLastTurnAt ?? agent.lastActivityAt
        let hasConversation = agent.hasStartedSession || agent.claudeMainThreadID != nil || agent.lastHelperEngine == "claude"
        let isQuietOrLong = Date().timeIntervalSince(lastMainTurnAt) > Self.mainSessionIdleSecondsBeforeFreshStart
            || (agent.mainSessionTurnCount ?? 0) >= Self.mainSessionTurnsBeforeFreshStart
        let startsFresh = hasConversation && isQuietOrLong

        guard let agentIndex = agents.firstIndex(where: { $0.id == agent.id }) else {
            return ClickyTurnConversation(
                geminiSessionID: agent.sessionID, isFirstGeminiTurn: !agent.hasStartedSession, geminiNeedsHandover: false,
                claudeConversation: "current", claudeNeedsHandover: false, routineID: nil, mayUseClaude: true
            )
        }
        if startsFresh {
            agents[agentIndex].sessionID = UUID()
            agents[agentIndex].hasStartedSession = false
            agents[agentIndex].claudeMainThreadID = nil
            agents[agentIndex].mainSessionTurnCount = 0
        }
        agents[agentIndex].mainSessionTurnCount = (agents[agentIndex].mainSessionTurnCount ?? 0) + 1
        agents[agentIndex].mainSessionLastTurnAt = Date()
        saveRoster()
        let currentAgent = agents[agentIndex]

        let claudeConversation: String
        if startsFresh {
            claudeConversation = "new"
        } else if let claudeMainThreadID = currentAgent.claudeMainThreadID {
            claudeConversation = claudeMainThreadID
        } else if routineStore.routines(for: agent.id).contains(where: { $0.claudeThreadID != nil }) {
            // A routine's thread may be the bot's open one by now.
            claudeConversation = "new"
        } else {
            claudeConversation = "current"
        }
        let previousEngine = currentAgent.lastHelperEngine
        let isContinuingClaudeWork = !startsFresh && previousEngine == "claude"
        return ClickyTurnConversation(
            geminiSessionID: currentAgent.sessionID,
            isFirstGeminiTurn: !currentAgent.hasStartedSession,
            geminiNeedsHandover: startsFresh || previousEngine == "claude",
            claudeConversation: claudeConversation,
            claudeNeedsHandover: claudeConversation == "new"
                || previousEngine?.hasPrefix("gemini") == true
                || (previousEngine == nil && currentAgent.hasStartedSession),
            routineID: nil,
            mayUseClaude: isContinuingClaudeWork || !Self.isEasyWorkForGemini(
                agent: currentAgent,
                messageText: messageText,
                isComputerUseApproved: isComputerUseApproved
            )
        )
    }

    /// Words that mean real building or multi-step work, which goes to
    /// Claude when it's set up.
    private static let buildingWords = [
        "build", "make", "create", "write", "code", "app", "website", "site", "script",
        "fix", "debug", "refactor", "project", "research", "analy", "plan", "design",
        "report", "deploy", "automate", "organize", "organise", "set up", "setup"
    ]

    /// Easy work stays on Gemini to save the Claude subscription: the
    /// Brain's quick answers, turns that click on screen (Claude helpers
    /// can't), and short asks that aren't building anything. A follow-up in
    /// a chat Claude is already working in stays with Claude.
    private static func isEasyWorkForGemini(agent: ClickyAgent, messageText: String, isComputerUseApproved: Bool) -> Bool {
        if agent.isBrain == true || isComputerUseApproved {
            return true
        }
        let lowercasedMessage = messageText.lowercased()
        let mentionsBuilding = buildingWords.contains { lowercasedMessage.contains($0) }
        return messageText.count <= 160 && !mentionsBuilding
    }

    /// Routine runs keep their own conversations, so the chat with the user
    /// hears what they reported since the user last wrote.
    private func routineReportsSinceLastUserMessage(forAgentID agentID: UUID) -> String {
        let transcript = transcriptsByAgentID[agentID] ?? []
        let firstIndexAfterLastUserMessage = (transcript.lastIndex { $0.kind == .user }).map { $0 + 1 } ?? 0
        guard firstIndexAfterLastUserMessage < transcript.count else { return "" }
        var reportLines: [String] = []
        var currentRunTitle: String?
        for item in transcript[firstIndexAfterLastUserMessage...] {
            if item.kind == .routineRun {
                currentRunTitle = item.text
            } else if item.kind == .assistant, let runTitle = currentRunTitle {
                reportLines.append("- \(runTitle): \(item.text.prefix(600))")
                currentRunTitle = nil
            }
        }
        guard !reportLines.isEmpty else { return "" }
        return "[Your routines reported this since the user last wrote:\n" + reportLines.suffix(3).joined(separator: "\n") + "]\n\n"
    }

    /// Runs one turn. The transcript item for it is already added.
    private func startTurn(for agent: ClickyAgent, messageForAgent: String, isComputerUseApproved: Bool, conversation: ClickyTurnConversation) {
        runningAgentIDs.insert(agent.id)
        touchAgent(agent.id)

        let routineID = conversation.routineID
        let isFirstTurn = conversation.isFirstGeminiTurn
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
        // Something on screen right away, whichever engine picks it up.
        appendTranscriptItem(.tool, text: "Getting started…", to: agentID, toolID: gettingStartedToolID, persist: false)

        let additionalDirectoryURLs = [skillLibrary.libraryURL] + sharedFolderURLs
            + (agent.isBrain == true
                ? [DottieBrain.defaultBrainFolderURL] + (brainFolderURLsProvider?() ?? [])
                : [])
        let claudeSpec = mausBotSpec(for: agent, extraFolderURLs: additionalDirectoryURLs)
        // What was said before, for an engine that didn't hear it.
        let conversationContext = recentConversationContext(forAgentID: agentID)

        Task { [weak self] in
            guard let self else { return }
            if conversation.mayUseClaude, await self.runTurnOnClaudeIfPossible(
                agent: agent,
                spec: claudeSpec,
                message: fullMessageForAgent,
                conversation: conversation,
                conversationContext: conversationContext
            ) {
                self.finishTurn(agentID: agentID)
                return
            }
            // A routine run doesn't change which engine the chat is on.
            // "gemini-backup" only when Claude was meant to take this turn
            // and couldn't, so the badge doesn't call planned Gemini work a
            // backup.
            if routineID == nil {
                let claudeWasWanted = conversation.mayUseClaude && DottieMausBot.shared.preference == .claudeWithBackup
                self.setLastHelperEngine(claudeWasWanted ? "gemini-backup" : "gemini", forAgentID: agentID)
            }
            let geminiMessage = conversation.geminiNeedsHandover ? conversationContext + fullMessageForAgent : fullMessageForAgent
            do {
                do {
                    try await self.runAgentProcess(
                        agent: agent,
                        sessionID: conversation.geminiSessionID,
                        isFirstTurn: isFirstTurn,
                        message: geminiMessage,
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
                    let freshSessionID: UUID
                    let handover: String
                    if let routineID {
                        freshSessionID = self.routineStore.beginFreshSession(routineID: routineID)
                        handover = self.routineStore.routine(withID: routineID)
                            .map { ClickyRoutinePrompts.lastReportHandover(for: $0) + "\n\n" } ?? ""
                    } else {
                        freshSessionID = self.replaceSession(forAgentID: agentID)
                        handover = self.recentConversationContext(forAgentID: agentID)
                    }
                    try await self.runAgentProcess(
                        agent: agent,
                        sessionID: freshSessionID,
                        isFirstTurn: true,
                        message: handover + fullMessageForAgent,
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
                        sessionID: conversation.geminiSessionID,
                        isFirstTurn: false,
                        message: geminiMessage,
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
            .suffix(6)
            .map { ($0.kind == .user ? "User: " : "You: ") + String($0.text.prefix(600)) }
        guard !recentLines.isEmpty else { return "" }
        return "Earlier in this chat (for context):\n" + recentLines.joined(separator: "\n") + "\n\n"
    }

    func stopAgent(_ agent: ClickyAgent) {
        guard isRunning(agent) else { return }
        runtime.stopTurn(agentID: agent.id)
        mausBotRuntime.stopTurn(agentID: agent.id)
        appendTranscriptItem(.status, text: "Stopped", to: agent.id)
    }

    private func handleRuntimeEvent(_ event: GeminiCLIAgentEvent, agentID: UUID) {
        markGettingStartedDone(agentID: agentID)
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
        case .finished(let succeeded, let totalTokens, let durationMilliseconds):
            lastTurnSucceededByAgentID[agentID] = succeeded
            // Gemini CLI reports one total; it's nearly all input (the
            // instructions, tools and resumed session it reads each turn).
            DottieUsage.shared.record(
                area: .geminiHelpers,
                inputTokens: totalTokens ?? 0,
                outputTokens: 0,
                seconds: Double(durationMilliseconds ?? 0) / 1000
            )
            // The CLI saved the session; later turns resume it.
            guard succeeded else { break }
            if let routineID = routineIDByRunningAgentID[agentID] {
                routineStore.recordGeminiSessionStarted(routineID: routineID)
            } else if let agentIndex = agents.firstIndex(where: { $0.id == agentID }), !agents[agentIndex].hasStartedSession {
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
        markGettingStartedDone(agentID: agentID)
        // A turn that ended with no answer and no error used to look like the
        // Dot just stopped. Say so instead.
        if !succeeded, let lastItem = transcriptsByAgentID[agentID]?.last,
           lastItem.kind != .assistant, lastItem.kind != .error, lastItem.kind != .needsApproval, lastItem.text != "Stopped" {
            let engineName = agent(withID: agentID)?.lastHelperEngine == "claude" ? "Claude" : "Gemini"
            appendTranscriptItem(.error, text: "Couldn't finish this one: \(engineName) was too busy to answer. Try sending it again.", to: agentID)
        }
        saveTranscript(for: agentID)

        guard agent(withID: agentID) != nil else { return }
        applyRoutineBlocksInLastReply(agentID: agentID)
        enableSkillsSavedDuringTurn(agentID: agentID, skillFolderNamesBeforeTurn: skillFolderNamesBeforeTurn)

        var routineTitle: String?
        var foundNothingNew = false
        if let routineID, let routine = routineStore.routine(withID: routineID) {
            routineTitle = routine.title
            ClickyAnalytics.trackRoutineRun(succeeded: succeeded)
            if routineStore.markRunFinished(routineID: routineID, succeeded: succeeded) {
                appendTranscriptItem(.status, text: "Paused routine “\(routine.title)” after \(ClickyRoutineStore.maximumFailedRunsInARow) failed runs in a row", to: agentID)
            }
            let pendingWatchedTextHash = pendingWatchedTextHashByRoutineID.removeValue(forKey: routineID)
            if succeeded {
                if let pendingWatchedTextHash {
                    routineStore.recordWatchedTextHash(pendingWatchedTextHash, routineID: routineID)
                }
                foundNothingNew = recordRoutineRunReport(routineID: routineID, agentID: agentID)
            }
        }

        let computerUseRequest = moveComputerUseRequestOutOfLastReply(agentID: agentID)
        passInstallToolRequestFromLastReply(agentID: agentID)
        // Home clears this right away if the chat is on screen.
        if !foundNothingNew, let agentIndex = agents.firstIndex(where: { $0.id == agentID }) {
            agents[agentIndex].hasUnreadReply = true
            saveRoster()
        }
        guard let finishedAgent = agent(withID: agentID) else { return }
        // A quiet run's reply is gone; an older one mustn't stand in for it.
        let finalItem = foundNothingNew ? nil : transcriptsByAgentID[agentID]?
            .last { $0.kind == .assistant || $0.kind == .error || $0.kind == .needsApproval }
        let finalReply = finalItem.map { item in
            item.kind == .needsApproval ? "Needs your OK in MausBot: \(item.text)" : item.text
        } ?? ""
        onAgentTurnFinished?(ClickyAgentTurnResult(
            agent: finishedAgent,
            finalReply: finalReply,
            succeeded: succeeded,
            computerUseRequest: computerUseRequest,
            routineTitle: routineTitle,
            foundNothingNew: foundNothingNew
        ))
        if finalItem?.kind != .needsApproval && computerUseRequest == nil && !foundNothingNew {
            postHelperFinished(agent: finishedAgent, result: finalReply, succeeded: succeeded)
        }
        // Next task in line, unless the Dot is waiting on the user to allow
        // computer use (the allowed turn runs first, then the line resumes).
        if computerUseRequest == nil, var queuedMessages = queuedMessagesByAgentID[agentID], !queuedMessages.isEmpty {
            let nextMessage = queuedMessages.removeFirst()
            queuedMessagesByAgentID[agentID] = queuedMessages.isEmpty ? nil : queuedMessages
            sendMessage(nextMessage, to: finishedAgent)
        }
    }

    /// Saves what a routine run reported (for its next fresh conversation)
    /// and whether it found anything. A "nothing new" reply becomes a
    /// quiet status line. Returns true when nothing was new.
    private func recordRoutineRunReport(routineID: UUID, agentID: UUID) -> Bool {
        guard var transcript = transcriptsByAgentID[agentID],
              let runStartIndex = transcript.lastIndex(where: { $0.kind == .routineRun }),
              let replyIndex = transcript.lastIndex(where: { $0.kind == .assistant }),
              replyIndex > runStartIndex else { return false }
        let replyText = transcript[replyIndex].text
        let foundNothingNew = ClickyRoutinePrompts.isNothingNewReply(replyText)
        routineStore.recordRunReport(routineID: routineID, reportText: replyText, foundNothingNew: foundNothingNew)
        if foundNothingNew {
            transcript.remove(at: replyIndex)
            transcriptsByAgentID[agentID] = transcript
            appendTranscriptItem(.status, text: "Nothing new", to: agentID)
        }
        return foundNothingNew
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

    /// If the agent's last reply ends with an <INSTALL_TOOL> block, strips
    /// it and hands it to DottieToolInstaller, which asks the user and
    /// messages the agent once the tool is installed (or not).
    private func passInstallToolRequestFromLastReply(agentID: UUID) {
        guard var transcript = transcriptsByAgentID[agentID],
              let lastReplyIndex = transcript.lastIndex(where: { $0.kind == .assistant }),
              let requestingAgent = agent(withID: agentID) else { return }
        let (replyWithoutRequest, requestedTool) = DottieToolInstaller.extractInstallRequest(from: transcript[lastReplyIndex].text)
        guard let requestedTool else { return }
        if replyWithoutRequest.isEmpty {
            transcript.remove(at: lastReplyIndex)
        } else {
            transcript[lastReplyIndex].text = replyWithoutRequest
        }
        transcriptsByAgentID[agentID] = transcript
        appendTranscriptItem(.status, text: "Asked you to install \(requestedTool)", to: agentID)
        DottieToolInstaller.shared.handleHelperRequest(requestedTool, helperName: requestingAgent.name) { [weak self] followUpMessage in
            guard let self, let agentToMessage = self.agent(withID: agentID) else { return }
            self.sendOrQueueMessage(followUpMessage, to: agentToMessage)
        }
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
            runRoutine(dueRoutine, checksWatchedPageFirst: true)
        }
    }

    /// Runs a routine now, unless its Clicky is busy (the scheduler tries
    /// again on its next check). A scheduled run of a routine with a
    /// watched page reads the page first and skips the run, without asking
    /// any model, when its text hasn't changed.
    func runRoutine(_ requestedRoutine: ClickyRoutine, checksWatchedPageFirst: Bool = false) {
        guard let routine = routineStore.routine(withID: requestedRoutine.id),
              let agent = agent(withID: routine.agentID),
              !isRunning(agent),
              !routineIDsCheckingWatchedPage.contains(routine.id) else { return }
        guard checksWatchedPageFirst,
              let watchURLString = routine.watchURL,
              let watchURL = URL(string: watchURLString) else {
            startRoutineRun(routineID: routine.id)
            return
        }
        let routineID = routine.id
        routineIDsCheckingWatchedPage.insert(routineID)
        Task { [weak self] in
            let watchedTextHash = await ClickyRoutineWatchedPage.textHash(of: watchURL)
            guard let self else { return }
            self.routineIDsCheckingWatchedPage.remove(routineID)
            if let watchedTextHash,
               watchedTextHash == self.routineStore.routine(withID: routineID)?.lastWatchedTextHash {
                self.routineStore.recordSkippedUnchangedRun(routineID: routineID)
                return
            }
            if let watchedTextHash {
                self.pendingWatchedTextHashByRoutineID[routineID] = watchedTextHash
            }
            self.startRoutineRun(routineID: routineID)
        }
    }

    /// Starts a routine run in the routine's own conversation, on Gemini
    /// (24/7 jobs, which build things, may run on Claude).
    private func startRoutineRun(routineID: UUID) {
        guard let routine = routineStore.routine(withID: routineID),
              let agent = agent(withID: routine.agentID),
              !isRunning(agent) else {
            pendingWatchedTextHashByRoutineID[routineID] = nil
            return
        }
        let previousRunStartedAt = routine.lastRunStartedAt
        let previousRunFailed = routine.failedRunsInARow > 0
        let isFreshSession = routineStore.startsFreshSession(routineID: routineID)
        let geminiSessionID = isFreshSession || routine.geminiSessionID == nil
            ? routineStore.beginFreshSession(routineID: routineID)
            : routine.geminiSessionID ?? UUID()
        guard let currentRoutine = routineStore.routine(withID: routineID),
              let runNumber = routineStore.markRunStarted(routineID: routineID) else { return }

        appendTranscriptItem(.routineRun, text: "Routine “\(currentRoutine.title)” · run \(runNumber)", to: agent.id)
        startTurn(
            for: agent,
            messageForAgent: ClickyRoutinePrompts.runMessage(
                for: currentRoutine,
                runNumber: runNumber,
                previousRunStartedAt: previousRunStartedAt,
                previousRunFailed: previousRunFailed,
                isFreshSession: isFreshSession
            ),
            isComputerUseApproved: false,
            conversation: ClickyTurnConversation(
                geminiSessionID: geminiSessionID,
                isFirstGeminiTurn: currentRoutine.hasStartedGeminiSession != true,
                geminiNeedsHandover: false,
                claudeConversation: currentRoutine.claudeThreadID ?? "new",
                claudeNeedsHandover: false,
                routineID: routineID,
                mayUseClaude: currentRoutine.keepWorking != nil
            )
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

    /// Deletes one message from a Dot's chat (Home → Dots).
    func deleteTranscriptItem(_ itemID: UUID, fromAgentID agentID: UUID) {
        transcriptsByAgentID[agentID]?.removeAll { $0.id == itemID }
        saveTranscript(for: agentID)
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

// MARK: - Claude through OpenMausBot

extension ClickyRoster {
    /// Runs the turn on Claude when MausBot is ready and Claude is chosen.
    /// Returns true when the turn was handled there (finished, stopped, or
    /// waiting for the user in MausBot); false sends it to Gemini CLI, after
    /// a note in the chat when Claude was expected and couldn't take it.
    fileprivate func runTurnOnClaudeIfPossible(
        agent: ClickyAgent,
        spec: DottieMausBotSpec,
        message: String,
        conversation: ClickyTurnConversation,
        conversationContext: String
    ) async -> Bool {
        let agentID = agent.id
        let launcher: DottieMausBotLauncher
        switch await DottieMausBot.shared.readinessForHelperTurn() {
        case .skip:
            return false
        case .fallback(let reason):
            noteClaudeFallback(reason, agentID: agentID)
            return false
        case .ready(let readyLauncher):
            launcher = readyLauncher
        }

        var currentSpec = spec
        for attempt in 0..<2 {
            let identity: DottieMausBotIdentity
            switch await mausBotRuntime.ensureBot(for: currentSpec, launcher: launcher) {
            case .failure(let reason):
                noteClaudeFallback(reason, agentID: agentID)
                return false
            case .success(let readyIdentity):
                identity = readyIdentity
            }
            rememberMausBot(identity, forAgentID: agentID)

            // A fresh bot (second attempt) starts a new thread too.
            let claudeMessage = conversation.claudeNeedsHandover || attempt > 0
                ? conversationContext + message
                : message
            let routineID = conversation.routineID
            if routineID == nil {
                setLastHelperEngine("claude", forAgentID: agentID)
            }

            let claudeTurnStartedAt = Date()
            let outcome = await mausBotRuntime.runTurn(
                agentID: agentID,
                botID: identity.botID,
                message: claudeMessage,
                conversation: attempt == 0 ? conversation.claudeConversation : "new",
                launcher: launcher,
                onConversationStarted: { [weak self] threadID in
                    self?.rememberClaudeThread(threadID, agentID: agentID, routineID: routineID)
                }
            ) { [weak self] event in
                self?.handleClaudeEvent(event, agentID: agentID)
            }
            DottieUsage.shared.record(
                area: .claudeHelpers,
                inputTokens: 0,
                outputTokens: 0,
                seconds: Date().timeIntervalSince(claudeTurnStartedAt)
            )

            switch outcome {
            case .finished(let succeeded, let errorText):
                lastTurnSucceededByAgentID[agentID] = succeeded
                if !succeeded, let errorText {
                    appendTranscriptItem(.error, text: errorText, to: agentID)
                }
                return true
            case .stopped:
                return true
            case .needsInput(let question, let threadID, let since):
                lastTurnSucceededByAgentID[agentID] = true
                appendTranscriptItem(.needsApproval, text: question, to: agentID)
                startClaudeFollowUp(agentID: agentID, botID: identity.botID, threadID: threadID, since: since, launcher: launcher)
                return true
            case .stillRunning(let threadID, let since):
                lastTurnSucceededByAgentID[agentID] = true
                appendTranscriptItem(.status, text: "Still working on it in MausBot. The answer will show up here.", to: agentID)
                startClaudeFollowUp(agentID: agentID, botID: identity.botID, threadID: threadID, since: since, launcher: launcher)
                return true
            case .botMissing where attempt == 0:
                // Deleted in MausBot: make a fresh bot and try once more.
                forgetMausBot(forAgentID: agentID)
                currentSpec = mausBotSpec(for: self.agent(withID: agentID) ?? agent, extraFolderURLs: [])
                continue
            case .botMissing:
                noteClaudeFallback(.engineProblem("the bot is missing"), agentID: agentID)
                return false
            case .fallback(let reason):
                noteClaudeFallback(reason, agentID: agentID)
                return false
            }
        }
        return false
    }

    /// Claude's events go to the same transcript handling as Gemini's,
    /// except the end of the turn, which runTurnOnClaudeIfPossible reads
    /// from MausBot's own verdict (and which mustn't mark a Gemini session
    /// as started).
    private func handleClaudeEvent(_ event: GeminiCLIAgentEvent, agentID: UUID) {
        switch event {
        case .finished, .sessionStarted:
            markGettingStartedDone(agentID: agentID)
        default:
            handleRuntimeEvent(event, agentID: agentID)
        }
    }

    private func noteClaudeFallback(_ reason: DottieClaudeFallbackReason, agentID: UUID) {
        DottieMausBot.shared.pauseClaude(for: reason)
        appendTranscriptItem(.status, text: reason.noteForTranscript, to: agentID, persist: false)
        if case .engineProblem(let detail) = reason {
            print("⚠️ Claude helper turn moved to Gemini: \(detail)")
        }
    }

    /// Keeps listening after the turn paused in MausBot, and adds what it
    /// finally says as if the turn had just finished.
    private func startClaudeFollowUp(agentID: UUID, botID: String, threadID: String, since: Double, launcher: DottieMausBotLauncher) {
        mausBotRuntime.followUp(agentID: agentID, botID: botID, threadID: threadID, since: since, launcher: launcher) { [weak self] result in
            self?.finishClaudeFollowUp(agentID: agentID, result: result)
        }
    }

    private func finishClaudeFollowUp(agentID: UUID, result: DottieMausBotFollowUpResult) {
        guard let followedAgent = agent(withID: agentID), !isRunning(followedAgent) else { return }
        if let replyText = result.replyText {
            appendTranscriptItem(.assistant, text: replyText, to: agentID)
        } else if !result.succeeded, let errorText = result.errorText {
            appendTranscriptItem(.error, text: errorText, to: agentID)
        } else {
            return
        }
        applyRoutineBlocksInLastReply(agentID: agentID)
        let computerUseRequest = moveComputerUseRequestOutOfLastReply(agentID: agentID)
        passInstallToolRequestFromLastReply(agentID: agentID)
        if let agentIndex = agents.firstIndex(where: { $0.id == agentID }) {
            agents[agentIndex].hasUnreadReply = true
            agents[agentIndex].lastActivityAt = Date()
            saveRoster()
        }
        saveTranscript(for: agentID)
        guard let finishedAgent = agent(withID: agentID) else { return }
        let finalReply = transcriptsByAgentID[agentID]?.last { $0.kind == .assistant || $0.kind == .error }?.text ?? ""
        onAgentTurnFinished?(ClickyAgentTurnResult(
            agent: finishedAgent,
            finalReply: finalReply,
            succeeded: result.succeeded,
            computerUseRequest: computerUseRequest,
            routineTitle: nil
        ))
        postHelperFinished(agent: finishedAgent, result: finalReply, succeeded: result.succeeded)
    }

    /// Tells listeners (episodic memory, XP) a helper task is done, once
    /// per finished task, whichever engine ran it.
    fileprivate func postHelperFinished(agent finishedAgent: ClickyAgent, result: String, succeeded: Bool) {
        let taskText = transcriptsByAgentID[finishedAgent.id]?
            .last { $0.kind == .user || $0.kind == .routineRun }?
            .text ?? ""
        NotificationCenter.default.post(
            name: helperFinishedNotificationName,
            object: nil,
            userInfo: [
                "agentID": finishedAgent.id.uuidString,
                "helper": finishedAgent.name,
                "title": finishedAgent.name,
                "task": taskText,
                "result": result,
                "summary": String(result.prefix(400)),
                "succeeded": succeeded,
                "engine": finishedAgent.lastHelperEngine ?? "gemini"
            ]
        )
    }

    /// Ticks off the "Getting started…" step once real work shows up.
    fileprivate func markGettingStartedDone(agentID: UUID) {
        guard var transcript = transcriptsByAgentID[agentID],
              let stepIndex = transcript.lastIndex(where: { $0.toolID == gettingStartedToolID }),
              transcript[stepIndex].toolSucceeded == nil else { return }
        transcript[stepIndex].toolSucceeded = true
        transcriptsByAgentID[agentID] = transcript
    }

    fileprivate func setLastHelperEngine(_ engineName: String, forAgentID agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }),
              agents[agentIndex].lastHelperEngine != engineName else { return }
        agents[agentIndex].lastHelperEngine = engineName
        saveRoster()
    }

    /// The thread a Claude turn ran in, so the next turn continues it.
    fileprivate func rememberClaudeThread(_ threadID: String, agentID: UUID, routineID: UUID?) {
        if let routineID {
            routineStore.recordClaudeThread(threadID, routineID: routineID)
            return
        }
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }),
              agents[agentIndex].claudeMainThreadID != threadID else { return }
        agents[agentIndex].claudeMainThreadID = threadID
        saveRoster()
    }

    private func rememberMausBot(_ identity: DottieMausBotIdentity, forAgentID agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let currentAgent = agents[agentIndex]
        guard currentAgent.mausBotID != identity.botID
                || currentAgent.mausBotName != identity.botName
                || currentAgent.mausBotSpecHash != identity.specHash else { return }
        agents[agentIndex].mausBotID = identity.botID
        agents[agentIndex].mausBotName = identity.botName
        agents[agentIndex].mausBotSpecHash = identity.specHash
        saveRoster()
    }

    private func forgetMausBot(forAgentID agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[agentIndex].mausBotID = nil
        agents[agentIndex].mausBotName = nil
        agents[agentIndex].mausBotSpecHash = nil
        saveRoster()
    }

    // MARK: Bot instructions

    /// What the helper's bot is given: the same standing instructions Gemini
    /// CLI reads from AGENTS.md, minus what MausBot does its own way (web
    /// search, computer use), plus the folders it may use.
    fileprivate func mausBotSpec(for agent: ClickyAgent, extraFolderURLs: [URL]) -> DottieMausBotSpec {
        let agentWorkspaceURL = workspaceURL(for: agent)
        var folderURLs = extraFolderURLs
        if folderURLs.isEmpty {
            folderURLs = [skillLibrary.libraryURL] + sharedFolderURLs
                + (agent.isBrain == true ? [DottieBrain.defaultBrainFolderURL] + (brainFolderURLsProvider?() ?? []) : [])
        }
        let folderLines = folderURLs.map { "- `\($0.path)`" }.joined(separator: "\n")
        let helperToolSection = DottieToolRegistry.helperPromptSections
        let instructionSections = [
            Self.agentInstructions(for: agent),
            """
            ## Your folder and notes

            Your folder is `\(agentWorkspaceURL.path)` (you start there). `AGENTS.md` in it starts with the same instructions you already have here, then your standing notes under its `## Notes` heading. When you start a task, read just the notes (`sed -n '/^## Notes/,$p' AGENTS.md`), not the whole file, and add short notes there about the user's preferences and what you learned, so you remember them next time.

            Other folders you may use:
            \(folderLines)

            """,
            """
            # Using the Mac

            You don't click or type on the screen yourself; Dottie does that. When a task needs an app or a website rather than files, use the command-line ways below (AppleScript, Shortcuts, `open`, fetching pages). If it truly needs clicking on screen, finish everything else and say exactly which on-screen steps are left, so Dottie can do them.

            """,
            ClickySkillLibrary.globalAgentInstructions(libraryURL: skillLibrary.libraryURL),
            ClickyRoutinePrompts.globalAgentInstructions,
            DottieBrowser.agentInstructions,
            helperToolSection
        ]
        let instructions = instructionSections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let enabledSkillNames = Set(agent.enabledSkillNames ?? [])
        // Building and Mac-app instructions, read only when a task needs them.
        let builtInSkillFileURLs = DottieBuiltInSkills.write(
            DottieBuiltInSkills.skills(includesComputerUse: false),
            into: cliHomeURL.appendingPathComponent("claude-helper-skills", isDirectory: true)
        )
        let skillFiles = skillLibrary.skills
            .filter { FileManager.default.fileExists(atPath: $0.skillFileURL.path) }
            .map { (path: $0.skillFileURL.path, isEnabled: enabledSkillNames.contains($0.name)) }
            + builtInSkillFileURLs.map { (path: $0.path, isEnabled: true) }
        let title = agent.isBrain == true
            ? "Dottie's second brain"
            : (agent.purpose.isEmpty ? "One of Dottie's helpers" : agent.purpose)
        return DottieMausBotSpec(
            helperName: agent.name,
            title: title,
            instructions: instructions,
            workspacePath: agentWorkspaceURL.path,
            skillFiles: skillFiles,
            // The Brain's answers are read out loud right away: keep it quick.
            effort: agent.isBrain == true ? "low" : nil,
            knownBotID: agent.mausBotID,
            knownBotName: agent.mausBotName,
            knownSpecHash: agent.mausBotSpecHash
        )
    }

    // MARK: For Home

    /// What the helper is waiting for the user to OK in MausBot, if anything.
    func pendingMausBotApproval(for agent: ClickyAgent) -> String? {
        guard !isRunning(agent),
              let lastItem = transcriptsByAgentID[agent.id]?.last(where: { $0.kind != .tool && $0.kind != .status }),
              lastItem.kind == .needsApproval else { return nil }
        return lastItem.text
    }

    /// The line a helper card shows: the step it's on while working, else
    /// the start of its latest message.
    func liveStatusLine(for agent: ClickyAgent) -> String {
        let transcript = transcriptsByAgentID[agent.id] ?? []
        if isRunning(agent) {
            return transcript.last { $0.kind == .tool }?.text ?? "Getting started…"
        }
        if let approval = pendingMausBotApproval(for: agent) {
            return "Needs your OK: \(approval)"
        }
        if pendingComputerUseRequest(for: agent) != nil {
            return "Wants to use your Mac"
        }
        guard let latestItem = transcript.last(where: { $0.kind == .assistant || $0.kind == .error || $0.kind == .user }) else {
            return agent.purpose.isEmpty ? "Ready for a task" : agent.purpose
        }
        let firstLine = latestItem.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return latestItem.kind == .user ? "You: \(firstLine)" : firstLine
    }

    /// Teams: projects two or more helpers worked on, newest first. Read
    /// from the projects folder's index (DottieProjects writes it).
    func helperTeams() -> [(name: String, helperNames: [String])] {
        guard let projectsFolderURL = sharedFolderURLs.first,
              let indexData = try? Data(contentsOf: projectsFolderURL.appendingPathComponent("projects.json")) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let projects = try? decoder.decode([DottieProjects.Project].self, from: indexData) else { return [] }
        let helperNamesHere = Set(agents.map { $0.name.lowercased() })
        return projects
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { project -> (name: String, helperNames: [String])? in
                var uniqueNames: [String] = []
                for helperName in project.helperNames where helperNamesHere.contains(helperName.lowercased())
                    && !uniqueNames.contains(where: { $0.caseInsensitiveCompare(helperName) == .orderedSame }) {
                    uniqueNames.append(helperName)
                }
                return uniqueNames.count >= 2 ? (project.name, uniqueNames) : nil
            }
    }
}
