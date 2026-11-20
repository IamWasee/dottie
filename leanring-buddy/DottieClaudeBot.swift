//
//  DottieClaudeBot.swift
//  leanring-buddy
//
//  One of Dottie's own Claude bots in MausBot, running on the user's Claude
//  plan: screen jobs ("Dottie Screen Jobs"), step guessing ("Dottie
//  Planner") and watch-and-learn ("Dottie Watcher"). Each keeps its bot id
//  in UserDefaults, is made or updated with `team apply` only when its
//  instructions change, and answers one message at a time with a time
//  limit. Callers fall back to Gemini when `send` returns nil (MausBot not
//  set up, Claude out of its limit, too slow), and after a failure the bot
//  is skipped for two minutes so every step doesn't wait on it again.
//
//  The guide brain (DottieGuideBrain) does the same with its own copy of
//  this code, from before this was shared.
//

import Foundation

@MainActor
final class DottieClaudeBot {
    let helperName: String
    private let title: String
    private let instructions: String
    /// "sonnet" or "haiku": the newest Claude model with that in its name.
    private let modelKeyword: String
    private let effort: String
    let workspaceURL: URL
    private let agentID: UUID
    private let defaultsKeyPrefix: String

    private let mausBotRuntime = DottieMausBotRuntime()
    private var skippedUntil: Date?

    init(helperName: String, title: String, instructions: String, folderName: String, agentID: UUID, modelKeyword: String = "sonnet", effort: String = "low") {
        self.helperName = helperName
        self.title = title
        self.instructions = instructions
        self.modelKeyword = modelKeyword
        self.effort = effort
        self.agentID = agentID
        self.defaultsKeyPrefix = "dottieClaudeBot." + folderName
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folderURL = applicationSupportURL.appendingPathComponent("Dottie/\(folderName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        self.workspaceURL = folderURL
    }

    /// False right after a failure, so callers go straight to Gemini.
    var isWorthTrying: Bool {
        guard let skippedUntil else { return true }
        return skippedUntil <= Date()
    }

    func stop() {
        mausBotRuntime.stopTurn(agentID: agentID)
    }

    /// Sends one message and returns Claude's whole reply, or nil when
    /// Claude isn't there, failed, or took longer than timeoutSeconds.
    /// newConversation starts fresh; otherwise the bot's open conversation
    /// continues, so it remembers the earlier messages of the same job.
    func send(_ message: String, newConversation: Bool, timeoutSeconds: Double) async -> String? {
        guard isWorthTrying else { return nil }
        let readiness = await DottieMausBot.shared.readinessForHelperTurn()
        guard case .ready(let launcher) = readiness else {
            // Every screen job fell back to Gemini on celly's Mac with no
            // word of why; the reason now shows in the log.
            DottieLog.warning("⚠️ \(helperName): Claude not used: \(Self.whyNotReady(readiness))")
            return nil
        }

        let modelSelection = await DottieMausBot.shared.modelSelection(matching: modelKeyword, launcher: launcher)
        let defaults = UserDefaults.standard
        let botIDKey = defaultsKeyPrefix + ".botID"
        let botNameKey = defaultsKeyPrefix + ".botName"
        let specHashKey = defaultsKeyPrefix + ".specHash"
        let spec = DottieMausBotSpec(
            helperName: helperName,
            title: title,
            instructions: instructions,
            workspacePath: workspaceURL.path,
            skillFiles: [],
            effort: effort,
            knownBotID: defaults.string(forKey: botIDKey),
            knownBotName: defaults.string(forKey: botNameKey),
            knownSpecHash: defaults.string(forKey: specHashKey),
            model: modelSelection
        )
        let identity: DottieMausBotIdentity
        switch await mausBotRuntime.ensureBot(for: spec, launcher: launcher) {
        case .failure(let reason):
            DottieLog.warning("⚠️ \(helperName): Claude bot not ready (\(reason))")
            skipForAWhile()
            return nil
        case .success(let readyIdentity):
            identity = readyIdentity
        }
        defaults.set(identity.botID, forKey: botIDKey)
        defaults.set(identity.botName, forKey: botNameKey)
        defaults.set(identity.specHash, forKey: specHashKey)

        let replyCollector = DottieGameReplyCollector()
        let runtime = mausBotRuntime
        let stoppedAgentID = agentID
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            runtime.stopTurn(agentID: stoppedAgentID)
        }
        let startedAt = Date()
        let outcome = await mausBotRuntime.runTurn(
            agentID: agentID,
            botID: identity.botID,
            message: message,
            conversation: newConversation ? "new" : "current",
            launcher: launcher,
            onConversationStarted: { _ in }
        ) { event in
            if case .assistantTextDelta(let textDelta) = event {
                replyCollector.text += textDelta
            }
        }
        timeoutTask.cancel()
        DottieUsage.shared.record(area: .claudeHelpers, inputTokens: 0, outputTokens: 0, seconds: Date().timeIntervalSince(startedAt))

        switch outcome {
        case .finished(let succeeded, _) where succeeded && !replyCollector.text.isEmpty:
            return replyCollector.text
        case .stopped:
            DottieLog.warning("⚠️ \(helperName): Claude took over \(Int(timeoutSeconds)) s")
            return nil
        default:
            DottieLog.warning("⚠️ \(helperName): Claude's turn didn't give an answer: \(Self.whyTurnFailed(outcome, replyWasEmpty: replyCollector.text.isEmpty))")
            skipForAWhile()
            return nil
        }
    }

    /// Plain words for the log on why Claude wasn't asked.
    static func whyNotReady(_ readiness: DottieClaudeReadiness) -> String {
        switch readiness {
        case .ready: return "ready"
        case .skip: return "helpers aren't set to Claude, MausBot isn't found, or Claude is paused after an earlier problem"
        case .fallback(let reason):
            switch reason {
            case .usageLimit: return "the Claude plan's usage limit ran out"
            case .busy: return "Claude is busy or rate limited"
            case .notSignedIn: return "Claude Code isn't signed in"
            case .notReachable: return "MausBot's workspace didn't answer"
            case .engineProblem(let detail): return "engine problem: \(detail)"
            }
        }
    }

    /// Plain words for the log on why a turn gave no answer.
    static func whyTurnFailed(_ outcome: DottieMausBotTurnOutcome, replyWasEmpty: Bool) -> String {
        switch outcome {
        case .finished(let succeeded, let errorText):
            if !succeeded { return "it failed (\(errorText ?? "no error text"))" }
            return replyWasEmpty ? "it finished with an empty reply" : "it finished"
        case .needsInput: return "it's waiting on an approval or a question in MausBot"
        case .stillRunning: return "it's still running in MausBot"
        case .stopped: return "it was stopped"
        case .botMissing: return "the bot is missing in MausBot"
        case .fallback(let reason): return whyNotReady(.fallback(reason))
        }
    }

    private func skipForAWhile() {
        skippedUntil = Date().addingTimeInterval(120)
    }

    /// The JSON object in a reply that may have words or a code fence
    /// around it.
    static func jsonObject(in replyText: String) -> [String: Any]? {
        guard let jsonStart = replyText.firstIndex(of: "{"), let jsonEnd = replyText.lastIndex(of: "}"), jsonStart < jsonEnd,
              let jsonData = String(replyText[jsonStart...jsonEnd]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    }
}
