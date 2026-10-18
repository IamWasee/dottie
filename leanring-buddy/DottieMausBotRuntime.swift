//
//  DottieMausBotRuntime.swift
//  leanring-buddy
//
//  Runs a helper's turn on Claude through OpenMausBot (see DottieMausBot).
//  Each Dottie helper is a MausBot bot in a "Dottie" team, made and kept up
//  to date with `team apply` (name, role, standing instructions, its folder,
//  skills). A turn is:
//
//    openmausbot run --bot <id> --task current --message-file <file>
//                    --wait job --on-input exit --json
//
//  which continues the bot's own conversation, so it remembers earlier
//  tasks. While it runs, one shared `openmausbot events` stream delivers the
//  bot's messages as they're written: replies become transcript text and
//  tool calls become steps ("Searching the web…"), which the notch and Home
//  show as the live status line. Nothing polls: the CLI's wait is held by
//  the server until the job changes.
//
//  run's exit code says how it ended: done, failed (a Claude limit or
//  sign-in problem sends the turn to the Gemini backup), needs the user (an
//  approval card in MausBot), or still running. In the last two cases Dottie
//  keeps listening with `openmausbot wait` and adds the answer when it comes.
//

import CryptoKit
import Foundation

/// What a helper's bot should look like in MausBot.
struct DottieMausBotSpec {
    let helperName: String
    let title: String
    let instructions: String
    let workspacePath: String
    /// Every library skill's SKILL.md, and whether this helper uses it.
    let skillFiles: [(path: String, isEnabled: Bool)]
    /// "low" for the Brain, whose answers Dottie reads out right away.
    let effort: String?
    let knownBotID: String?
    let knownBotName: String?
    let knownSpecHash: String?
}

/// The bot a helper runs as.
struct DottieMausBotIdentity {
    let botID: String
    let botName: String
    let specHash: String
}

/// How a Claude turn ended.
enum DottieMausBotTurnOutcome {
    case finished(succeeded: Bool, errorText: String?)
    /// Waiting on an approval card or a question in MausBot.
    case needsInput(question: String, threadID: String, since: Double)
    /// The wait ran out; the work keeps going in MausBot.
    case stillRunning(threadID: String, since: Double)
    case stopped
    /// The bot id Dottie had is gone (deleted in MausBot).
    case botMissing
    case fallback(DottieClaudeFallbackReason)
}

/// What came of a turn Dottie kept listening to after it paused.
struct DottieMausBotFollowUpResult {
    let replyText: String?
    let needsInputQuestion: String?
    let succeeded: Bool
    let errorText: String?
}

@MainActor
final class DottieMausBotRuntime {
    /// MausBot team every helper bot belongs to.
    static let teamName = "Dottie"
    /// MausBot's limit for a bot's standing instructions.
    private static let maximumInstructionBytes = 23_500

    private let eventStream = DottieMausBotEventStream()
    private var runningProcessByAgentID: [UUID: Process] = [:]
    private var botIDByRunningAgentID: [UUID: String] = [:]
    private var stopRequestedAgentIDs: Set<UUID> = []
    private var followUpTaskByAgentID: [UUID: Task<Void, Never>] = [:]
    private var followUpProcessByAgentID: [UUID: Process] = [:]

    // MARK: - Bots

    /// Makes the helper's bot, or updates it when its instructions changed.
    /// Cheap when nothing changed: no command runs at all.
    func ensureBot(for spec: DottieMausBotSpec, launcher: DottieMausBotLauncher) async -> Result<DottieMausBotIdentity, DottieClaudeFallbackReason> {
        let modelSelection = await DottieMausBot.shared.helperModelSelection(launcher: launcher)
        let instructions = Self.trimmedToByteLimit(spec.instructions, maximumBytes: Self.maximumInstructionBytes)
        let specHash = Self.fingerprint([
            spec.helperName, spec.title, instructions, spec.workspacePath, modelSelection ?? "", spec.effort ?? "",
            spec.skillFiles.map { "\($0.path)=\($0.isEnabled)" }.joined(separator: ",")
        ])
        if let knownBotID = spec.knownBotID, let knownBotName = spec.knownBotName, spec.knownSpecHash == specHash {
            return .success(DottieMausBotIdentity(botID: knownBotID, botName: knownBotName, specHash: specHash))
        }

        let botsResult = await DottieMausBotCLI.run(["bots", "--json"], launcher: launcher, timeout: 30)
        guard botsResult.exitCode == DottieMausBotCLI.exitDone,
              let currentBots = botsResult.jsonObject?["bots"] as? [[String: Any]] else {
            return .failure(botsResult.exitCode == DottieMausBotCLI.exitUnreachable
                ? .notReachable
                : .engineProblem(botsResult.errorText))
        }
        let existingBot = spec.knownBotID.flatMap { knownBotID in
            currentBots.first { ($0["id"] as? String) == knownBotID }
        }
        // Keep a name the user gave the bot in MausBot; never take over a
        // bot of theirs that happens to share the helper's name.
        let botName: String
        if let existingBot, let existingName = existingBot["name"] as? String {
            botName = existingName
        } else {
            let takenNames = Set(currentBots.compactMap { ($0["name"] as? String)?.lowercased() })
            botName = Self.freeBotName(preferredName: spec.helperName, takenNames: takenNames)
        }

        var botFields: [String: Any] = [
            "name": botName,
            "team": Self.teamName,
            "title": Self.singleLine(spec.title, maximumLength: 190),
            "description": "One of Dottie's helpers.",
            "soul": instructions,
            // Like Gemini CLI's yolo mode: shell and file edits without cards.
            "approval": "full",
            // MausBot's own computer tools; it asks in the app before clicking.
            "computer": "local",
            "cwd": spec.workspacePath
        ]
        if let modelSelection { botFields["model"] = modelSelection }
        if let effort = spec.effort { botFields["effort"] = effort }
        if !spec.skillFiles.isEmpty {
            botFields["skills"] = spec.skillFiles.map { ["file": $0.path, "enabled": $0.isEnabled] as [String: Any] }
        }
        let teamFile: [String: Any] = [
            "version": 1,
            "teams": [["name": Self.teamName]],
            "bots": [botFields]
        ]
        DottieMausBotPaths.ensureFoldersExist()
        let teamFileURL = DottieMausBotPaths.teamFilesFolderURL.appendingPathComponent("\(UUID().uuidString).json")
        guard let teamFileData = try? JSONSerialization.data(withJSONObject: teamFile, options: [.prettyPrinted]),
              (try? teamFileData.write(to: teamFileURL, options: .atomic)) != nil else {
            return .failure(.engineProblem("couldn't write the team file"))
        }
        let applyResult = await DottieMausBotCLI.run(
            ["team", "apply", teamFileURL.path, "--wait-idle", "15s", "--json"],
            launcher: launcher,
            timeout: 90
        )
        try? FileManager.default.removeItem(at: teamFileURL)

        if let existingBot, let existingBotID = existingBot["id"] as? String {
            // An update that didn't land (the bot was busy) isn't worth
            // failing the task over: run it with the old instructions.
            let savedHash = applyResult.exitCode == DottieMausBotCLI.exitDone ? specHash : (spec.knownSpecHash ?? "")
            return .success(DottieMausBotIdentity(botID: existingBotID, botName: botName, specHash: savedHash))
        }
        guard applyResult.exitCode == DottieMausBotCLI.exitDone else {
            return .failure(applyResult.exitCode == DottieMausBotCLI.exitUnreachable
                ? .notReachable
                : .engineProblem(applyResult.errorText))
        }
        let refreshedBotsResult = await DottieMausBotCLI.run(["bots", "--json"], launcher: launcher, timeout: 30)
        let refreshedBots = refreshedBotsResult.jsonObject?["bots"] as? [[String: Any]] ?? []
        guard let createdBot = refreshedBots.first(where: { ($0["name"] as? String)?.lowercased() == botName.lowercased() }),
              let createdBotID = createdBot["id"] as? String else {
            return .failure(.engineProblem("the new bot didn't show up"))
        }
        return .success(DottieMausBotIdentity(botID: createdBotID, botName: botName, specHash: specHash))
    }

    private static func freeBotName(preferredName: String, takenNames: Set<String>) -> String {
        let baseName = singleLine(preferredName, maximumLength: 80)
        if !takenNames.contains(baseName.lowercased()) { return baseName }
        let dottieName = "\(baseName) (Dottie)"
        if !takenNames.contains(dottieName.lowercased()) { return dottieName }
        var suffixNumber = 2
        while takenNames.contains("\(baseName) (Dottie \(suffixNumber))".lowercased()) {
            suffixNumber += 1
        }
        return "\(baseName) (Dottie \(suffixNumber))"
    }

    // MARK: - Turns

    func isTurnRunning(agentID: UUID) -> Bool {
        botIDByRunningAgentID[agentID] != nil
    }

    /// Runs one turn and streams its messages to `onEvent` (on the main
    /// actor, in order). Returns how it ended.
    func runTurn(
        agentID: UUID,
        botID: String,
        message: String,
        launcher: DottieMausBotLauncher,
        onEvent: @escaping @MainActor (GeminiCLIAgentEvent) -> Void
    ) async -> DottieMausBotTurnOutcome {
        cancelFollowUp(agentID: agentID)
        stopRequestedAgentIDs.remove(agentID)
        botIDByRunningAgentID[agentID] = botID
        DottieMausBot.shared.claudeTurnStarted()
        defer {
            DottieMausBot.shared.claudeTurnEnded()
        }

        let translator = DottieMausBotTurnTranslator(onEvent: onEvent)
        await eventStream.startIfNeeded(launcher: launcher)
        eventStream.subscribe(agentID: agentID) { frame in
            translator.consume(frame)
        }

        DottieMausBotPaths.ensureFoldersExist()
        let messageFileURL = DottieMausBotPaths.messageFilesFolderURL.appendingPathComponent("\(UUID().uuidString).md")
        try? message.write(to: messageFileURL, atomically: true, encoding: .utf8)

        let eventStream = self.eventStream
        let result = await DottieMausBotCLI.run(
            [
                "run", "--bot", botID,
                "--task", "current",
                "--message-file", messageFileURL.path,
                "--wait", "job",
                "--on-input", "exit",
                "--timeout", "90m",
                "--json"
            ],
            launcher: launcher,
            timeout: nil,
            onProgressLine: { progress in
                // The first line names the conversation and when the job
                // began; from then on its messages are this turn's.
                guard (progress["event"] as? String) == "started",
                      let threadID = progress["threadId"] as? String else { return }
                let since = (progress["since"] as? NSNumber)?.doubleValue ?? 0
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        translator.since = since
                        eventStream.setThread(threadID, forAgentID: agentID)
                    }
                }
            },
            onLaunch: { [weak self] process in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.runningProcessByAgentID[agentID] = process
                    }
                }
            }
        )
        try? FileManager.default.removeItem(at: messageFileURL)

        // Messages written just before the job settled may still be on
        // their way through the event stream.
        try? await Task.sleep(nanoseconds: 300_000_000)
        eventStream.unsubscribe(agentID: agentID)
        runningProcessByAgentID[agentID] = nil
        botIDByRunningAgentID[agentID] = nil

        let resultObject = result.jsonObject ?? [:]
        let jobObject = resultObject["job"] as? [String: Any] ?? [:]
        let threadID = (resultObject["threadId"] as? String) ?? (jobObject["threadId"] as? String) ?? ""
        if let resultSince = (resultObject["since"] as? NSNumber)?.doubleValue, translator.since == 0 {
            translator.since = resultSince
        }
        // Any reply the stream missed, from the run's own record.
        translator.addMissedReplies(from: resultObject["messages"] as? [[String: Any]] ?? [])

        if stopRequestedAgentIDs.remove(agentID) != nil {
            return .stopped
        }

        switch result.exitCode {
        case DottieMausBotCLI.exitDone:
            return .finished(succeeded: true, errorText: nil)
        case DottieMausBotCLI.exitNeedsInput:
            let needsInputItems = jobObject["needsInput"] as? [[String: Any]] ?? []
            let question = needsInputItems.compactMap { $0["question"] as? String }.first
                ?? translator.lastQuestion
                ?? "It's waiting for your OK."
            return .needsInput(question: Self.singleLine(question, maximumLength: 300), threadID: threadID, since: translator.since)
        case DottieMausBotCLI.exitTimedOut:
            return .stillRunning(threadID: threadID, since: translator.since)
        case DottieMausBotCLI.exitUnreachable, DottieMausBotCLI.exitCouldNotLaunch:
            return .fallback(.notReachable)
        case DottieMausBotCLI.exitBadArguments:
            return result.errorText.lowercased().contains("no such bot") ? .botMissing : .fallback(.engineProblem(result.errorText))
        default:
            let failureText = Self.failureText(resultObject: resultObject, jobObject: jobObject, translator: translator, result: result)
            if let fallbackReason = DottieClaudeFallbackReason.classify(failureText) {
                return .fallback(fallbackReason)
            }
            if !translator.didEmitText && failureText.contains("provider_error") {
                return .fallback(.engineProblem(failureText))
            }
            let reason = (jobObject["reason"] as? String) ?? (resultObject["reason"] as? String) ?? result.errorText
            return .finished(succeeded: false, errorText: "Claude couldn't finish this one: \(Self.singleLine(reason, maximumLength: 240))")
        }
    }

    /// Everything the run said about why it failed, for classify().
    private static func failureText(
        resultObject: [String: Any],
        jobObject: [String: Any],
        translator: DottieMausBotTurnTranslator,
        result: DottieMausBotCommandResult
    ) -> String {
        var parts: [String] = translator.errorTexts
        parts.append(result.errorText)
        for key in ["error", "reason", "hint"] {
            if let value = resultObject[key] as? String { parts.append(value) }
        }
        if let jobReason = jobObject["reason"] as? String { parts.append(jobReason) }
        for node in jobObject["nodes"] as? [[String: Any]] ?? [] {
            if let nodeResult = node["result"] as? String { parts.append(nodeResult) }
            if let outcome = node["outcome"] as? String { parts.append(outcome) }
        }
        return parts.joined(separator: "\n")
    }

    /// Presses Stop in MausBot for this helper's job and every teammate on it.
    func stopTurn(agentID: UUID) {
        cancelFollowUp(agentID: agentID)
        guard let botID = botIDByRunningAgentID[agentID] else { return }
        stopRequestedAgentIDs.insert(agentID)
        let runningProcess = runningProcessByAgentID[agentID]
        Task {
            if let launcher = await DottieMausBot.shared.currentLauncher() {
                _ = await DottieMausBotCLI.run(["interrupt", "--bot", botID, "--tree", "--json"], launcher: launcher, timeout: 20)
            }
            // run ends by itself once the job stops; make sure it does.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if let runningProcess, runningProcess.isRunning {
                runningProcess.terminate()
            }
        }
    }

    // MARK: - After a pause

    /// Keeps listening to a turn that stopped for the user's OK (or ran past
    /// the wait) and hands over what it finally says.
    func followUp(
        agentID: UUID,
        botID: String,
        threadID: String,
        since: Double,
        launcher: DottieMausBotLauncher,
        onFinish: @escaping @MainActor (DottieMausBotFollowUpResult) -> Void
    ) {
        cancelFollowUp(agentID: agentID)
        guard !threadID.isEmpty else { return }
        followUpTaskByAgentID[agentID] = Task { [weak self] in
            let result = await DottieMausBotCLI.run(
                [
                    "wait", "--bot", botID,
                    "--task", threadID,
                    "--since", String(Int(since)),
                    "--on-input", "wait",
                    "--timeout", "2h",
                    "--json"
                ],
                launcher: launcher,
                timeout: nil,
                onLaunch: { process in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.followUpProcessByAgentID[agentID] = process
                        }
                    }
                }
            )
            guard !Task.isCancelled, let self else { return }
            self.followUpTaskByAgentID[agentID] = nil
            self.followUpProcessByAgentID[agentID] = nil
            // Still waiting after two hours, or stopped: nothing to add.
            guard result.exitCode == DottieMausBotCLI.exitDone || result.exitCode == DottieMausBotCLI.exitFailed else { return }
            let resultObject = result.jsonObject ?? [:]
            let replies = (resultObject["messages"] as? [[String: Any]] ?? []).filter { message in
                (message["role"] as? String) == "bot"
                    && (message["kind"] as? String) == "text"
                    && ((message["at"] as? NSNumber)?.doubleValue ?? 0) >= since
            }
            let replyText = replies.compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let jobObject = resultObject["job"] as? [String: Any] ?? [:]
            onFinish(DottieMausBotFollowUpResult(
                replyText: replyText.isEmpty ? nil : replyText,
                needsInputQuestion: nil,
                succeeded: result.exitCode == DottieMausBotCLI.exitDone,
                errorText: (jobObject["reason"] as? String).map { "Claude couldn't finish this one: \($0)" }
            ))
        }
    }

    func cancelFollowUp(agentID: UUID) {
        followUpTaskByAgentID.removeValue(forKey: agentID)?.cancel()
        if let followUpProcess = followUpProcessByAgentID.removeValue(forKey: agentID), followUpProcess.isRunning {
            followUpProcess.terminate()
        }
    }

    func isFollowingUp(agentID: UUID) -> Bool {
        followUpTaskByAgentID[agentID] != nil
    }

    // MARK: - Helpers

    private static func fingerprint(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func trimmedToByteLimit(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var trimmedText = text
        while trimmedText.utf8.count > maximumBytes {
            trimmedText.removeLast(min(500, trimmedText.count))
        }
        return trimmedText
    }

    static func singleLine(_ text: String, maximumLength: Int) -> String {
        let collapsedText = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsedText.count > maximumLength ? String(collapsedText.prefix(maximumLength - 1)) + "…" : collapsedText
    }
}

// MARK: - Turning MausBot messages into transcript events

/// Reads one turn's message frames and turns them into the events the
/// roster already understands from Gemini CLI.
@MainActor
final class DottieMausBotTurnTranslator {
    private let onEvent: @MainActor (GeminiCLIAgentEvent) -> Void
    /// Milliseconds since 1970 when the job began; older messages are skipped.
    var since: Double = 0
    private var handledTextMessageIDs: Set<String> = []
    private var startedToolMessageIDs: Set<String> = []
    private var finishedToolMessageIDs: Set<String> = []
    private var handledNoticeMessageIDs: Set<String> = []
    private var lastEmittedWasText = false
    private(set) var didEmitText = false
    private(set) var lastQuestion: String?
    private(set) var errorTexts: [String] = []

    init(onEvent: @escaping @MainActor (GeminiCLIAgentEvent) -> Void) {
        self.onEvent = onEvent
    }

    /// One `message` or `message.patch` frame from the event stream.
    func consume(_ frame: [String: Any]) {
        guard let message = frame["message"] as? [String: Any] else { return }
        handle(message: message)
    }

    /// Replies in the run's own result that the stream didn't deliver.
    func addMissedReplies(from messages: [[String: Any]]) {
        let replies = messages
            .filter { ($0["kind"] as? String) == "text" }
            .sorted { (($0["at"] as? NSNumber)?.doubleValue ?? 0) < (($1["at"] as? NSNumber)?.doubleValue ?? 0) }
        for reply in replies {
            handle(message: reply)
        }
    }

    private func handle(message: [String: Any]) {
        guard let messageID = message["id"] as? String,
              (message["role"] as? String) == "bot" else { return }
        let writtenAt = (message["at"] as? NSNumber)?.doubleValue ?? 0
        guard since > 0, writtenAt >= since else { return }

        switch message["kind"] as? String {
        case "text":
            guard !handledTextMessageIDs.contains(messageID) else { return }
            handledTextMessageIDs.insert(messageID)
            let replyText = (message["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replyText.isEmpty else { return }
            onEvent(.assistantTextDelta(lastEmittedWasText ? "\n\n" + replyText : replyText))
            lastEmittedWasText = true
            didEmitText = true
        case "activity":
            guard let tool = message["tool"] as? [String: Any] else { return }
            handleActivity(messageID: messageID, tool: tool)
        case "options":
            let card = message["card"] as? [String: Any] ?? [:]
            let question = (card["subtitle"] as? String) ?? (card["title"] as? String)
            if let question, !question.isEmpty {
                lastQuestion = question
            }
        default:
            break
        }
    }

    private func handleActivity(messageID: String, tool: [String: Any]) {
        let toolName = (tool["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if toolName.lowercased().hasPrefix("error:") {
            if !handledNoticeMessageIDs.contains(messageID) {
                handledNoticeMessageIDs.insert(messageID)
                errorTexts.append(String(toolName.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            }
            return
        }
        // Real tool calls carry an item id or their input; other activity
        // rows are notices ("Resuming after a restart").
        let isToolCall = tool["itemId"] != nil || tool["input"] != nil || tool["summary"] != nil
        guard isToolCall else { return }
        if !startedToolMessageIDs.contains(messageID) {
            startedToolMessageIDs.insert(messageID)
            onEvent(.toolStarted(
                toolID: messageID,
                toolName: Self.friendlyStepName(toolName: toolName, spokenName: tool["spoken"] as? String),
                parametersSummary: Self.summary(of: tool)
            ))
            lastEmittedWasText = false
        }
        if let succeeded = tool["ok"] as? Bool, !finishedToolMessageIDs.contains(messageID) {
            finishedToolMessageIDs.insert(messageID)
            onEvent(.toolFinished(toolID: messageID, succeeded: succeeded))
        }
    }

    /// A plain step for the status line, e.g. "Searching the web…".
    static func friendlyStepName(toolName: String, spokenName: String?) -> String {
        let bareName = toolName.replacingOccurrences(of: "^mcp__[^_]+__", with: "", options: .regularExpression)
        let firstWord = bareName.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        switch firstWord {
        case "bash", "shell", "terminal", "run_command", "execute", "computer_exec":
            return "Running a command…"
        case "read", "read_file", "view", "notebookread":
            return "Reading a file…"
        case "write", "create_file":
            return "Writing a file…"
        case "edit", "multiedit", "apply_patch", "str_replace", "notebookedit":
            return "Editing files…"
        case "glob", "grep", "ls", "search", "find":
            return "Searching files…"
        case "websearch", "web_search":
            return "Searching the web…"
        case "webfetch", "web_fetch", "fetch":
            return "Reading a web page…"
        case "task", "agent":
            return "Handing part of it off…"
        case "todowrite", "todo":
            return "Planning the steps…"
        case "screenshot":
            return "Looking at the screen…"
        case "click", "type_text", "press_key", "scroll", "computer_batch":
            return "Using your Mac…"
        case "open_url":
            return "Opening a page…"
        case "ask_bot", "list_bots":
            return "Asking a teammate…"
        case "skill":
            return "Using a skill…"
        default:
            if let spokenName, !spokenName.isEmpty {
                return String(spokenName.prefix(1)).uppercased() + String(spokenName.dropFirst()) + "…"
            }
            return bareName.isEmpty ? "Working…" : "Working: \(DottieMausBotRuntime.singleLine(bareName, maximumLength: 40))…"
        }
    }

    /// One short line about what the step works on.
    private static func summary(of tool: [String: Any]) -> String {
        if let summaryText = tool["summary"] as? String, !summaryText.isEmpty {
            return DottieMausBotRuntime.singleLine(summaryText, maximumLength: 120)
        }
        guard let input = tool["input"] as? [String: Any] else { return "" }
        for preferredKey in ["description", "command", "file_path", "path", "query", "url", "pattern", "prompt"] {
            if let value = input[preferredKey] as? String, !value.isEmpty {
                return DottieMausBotRuntime.singleLine(value, maximumLength: 120)
            }
        }
        return ""
    }
}

// MARK: - The live event stream

/// One `openmausbot events --kind message,message.patch` process shared by
/// every running Claude turn. It keeps the last few hundred frames so a
/// turn that learns its conversation a moment after sending still sees its
/// first messages. It stops a few minutes after the last turn ends.
@MainActor
final class DottieMausBotEventStream {
    private struct Subscriber {
        var threadID: String?
        let handler: @MainActor ([String: Any]) -> Void
    }

    private var process: Process?
    private var isConnected = false
    private var recentFrames: [[String: Any]] = []
    private var subscriberByAgentID: [UUID: Subscriber] = [:]
    private var idleStopTask: Task<Void, Never>?
    private let maximumRecentFrames = 400

    /// Starts the stream if it isn't running and waits (briefly) until the
    /// server has said hello, so the turn's first messages aren't missed.
    func startIfNeeded(launcher: DottieMausBotLauncher) async {
        idleStopTask?.cancel()
        idleStopTask = nil
        if process?.isRunning != true {
            start(launcher: launcher)
        }
        var waitedSteps = 0
        while !isConnected && process != nil && waitedSteps < 30 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waitedSteps += 1
        }
    }

    private func start(launcher: DottieMausBotLauncher) {
        let streamProcess = Process()
        streamProcess.executableURL = launcher.executableURL
        streamProcess.arguments = launcher.leadingArguments + ["events", "--kind", "message,message.patch"]
        var environment = DottieMausBotLocator.childEnvironment()
        environment.merge(launcher.extraEnvironment) { _, launcherValue in launcherValue }
        streamProcess.environment = environment
        streamProcess.currentDirectoryURL = DottieMausBotPaths.folderURL
        streamProcess.standardInput = FileHandle.nullDevice
        streamProcess.standardError = FileHandle.nullDevice
        let outputPipe = Pipe()
        streamProcess.standardOutput = outputPipe

        let lineSplitter = DottieJSONLineSplitter { [weak self] frame in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(frame: frame)
                }
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let availableData = fileHandle.availableData
            guard !availableData.isEmpty else { return }
            lineSplitter.consume(availableData)
        }
        streamProcess.terminationHandler = { [weak self] _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === streamProcess else { return }
                    self.process = nil
                    self.isConnected = false
                }
            }
        }
        isConnected = false
        do {
            try streamProcess.run()
            process = streamProcess
        } catch {
            process = nil
        }
    }

    private func handle(frame: [String: Any]) {
        let frameKind = frame["kind"] as? String
        if frameKind == "hello" {
            isConnected = true
            return
        }
        guard frameKind == "message" || frameKind == "message.patch",
              let threadID = frame["threadId"] as? String else { return }
        recentFrames.append(frame)
        if recentFrames.count > maximumRecentFrames {
            recentFrames.removeFirst(recentFrames.count - maximumRecentFrames)
        }
        for subscriber in subscriberByAgentID.values where subscriber.threadID == threadID {
            subscriber.handler(frame)
        }
    }

    func subscribe(agentID: UUID, handler: @escaping @MainActor ([String: Any]) -> Void) {
        subscriberByAgentID[agentID] = Subscriber(threadID: nil, handler: handler)
    }

    /// Points a turn at its conversation and replays what already arrived.
    func setThread(_ threadID: String, forAgentID agentID: UUID) {
        guard var subscriber = subscriberByAgentID[agentID] else { return }
        subscriber.threadID = threadID
        subscriberByAgentID[agentID] = subscriber
        for frame in recentFrames where (frame["threadId"] as? String) == threadID {
            subscriber.handler(frame)
        }
    }

    func unsubscribe(agentID: UUID) {
        subscriberByAgentID[agentID] = nil
        guard subscriberByAgentID.isEmpty else { return }
        idleStopTask?.cancel()
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self, self.subscriberByAgentID.isEmpty else { return }
            self.stop()
        }
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        isConnected = false
        recentFrames.removeAll()
    }
}

/// Splits a byte stream into lines on the newline byte and parses each as
/// a JSON object. Lines that aren't JSON are skipped.
private final class DottieJSONLineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLineData = Data()
    private let onObject: @Sendable ([String: Any]) -> Void

    init(onObject: @escaping @Sendable ([String: Any]) -> Void) {
        self.onObject = onObject
    }

    func consume(_ newData: Data) {
        lock.lock()
        pendingLineData.append(newData)
        var completeLines: [Data] = []
        while let newlineIndex = pendingLineData.firstIndex(of: UInt8(ascii: "\n")) {
            completeLines.append(Data(pendingLineData[pendingLineData.startIndex..<newlineIndex]))
            pendingLineData.removeSubrange(pendingLineData.startIndex...newlineIndex)
        }
        lock.unlock()
        for completeLine in completeLines where !completeLine.isEmpty {
            if let lineObject = try? JSONSerialization.jsonObject(with: completeLine) as? [String: Any] {
                onObject(lineObject)
            }
        }
    }
}
