//
//  DottieNeedleRouter.swift
//  leanring-buddy
//
//  Everything Dottie does with Needle (DottieNeedleEngine), on top of the
//  strict instant lane:
//
//    1. Loose wording: "pop safari open", "crank it up", "throw this on my
//       other monitor" become instant commands without Gemini, when Needle
//       is sure enough. Its call is turned into plain command words and
//       parsed strictly, so the app still has to be real.
//    2. Learned shortcuts by meaning: "check my email" replays the shortcut
//       saved as "open my mail". The new wording is then remembered on the
//       shortcut, so next time it matches word for word.
//    3. Remembering: an ask Needle worked out once is saved as a learned
//       shortcut, so the same words skip Needle too.
//    4. Reminders and calendar: "remind me tomorrow at 7 to call mom" goes
//       straight to Dottie's own add_reminder / add_calendar_event, with
//       the time read by Apple's date detector.
//    5. When Gemini is down or busy: the same, with a slightly lower bar,
//       so Mac actions still work.
//    6. Finding hidden tools by meaning for Live's find_tool.
//    7. Sorting asks (simple or complex job, quick or careful question)
//       on Macs without Apple's on-device model.
//    8. Whistle: hearing a short push-to-talk turn on the Mac when Speech
//       Recognition isn't allowed, so the instant lane still works.
//
//  Everything returns nil quickly when Needle is off or not in the build,
//  and callers carry on exactly as before.
//

import AppKit
import Foundation

@MainActor
final class DottieNeedleRouter {
    static let shared = DottieNeedleRouter()

    private let engine = DottieNeedleEngine.shared

    /// Needle's own calibrated confidence needed to act without asking.
    static let actConfidence = 0.8
    /// When Gemini can't answer at all, a little less is enough: the
    /// alternative is doing nothing.
    static let geminiDownActConfidence = 0.6
    /// How close in meaning a new ask must be to a saved phrase, and how
    /// far ahead of the next-best shortcut, to replay it.
    static let shortcutMeaningSimilarity: Float = 0.9
    static let shortcutMeaningMargin: Float = 0.03
    /// Longer asks are rarely a single Mac action.
    private static let longestRoutedWordCount = 16
    /// Past this, Gemini's answer is better than waiting for Needle.
    private static let deadlineSeconds = 0.6

    /// Vectors for saved phrases and tool descriptions, by their text. A
    /// new ask's own vector isn't kept, so this only grows with what's saved.
    private var vectorsByText: [String: [Float]] = [:]

    private init() {}

    var isAvailable: Bool {
        DottieNeedleEngine.isEnabled && engine.isBundled && DottieInstantLane.areInstantCommandsEnabled
    }

    /// Loads the engine and the saved phrases' vectors in the background,
    /// so the first ask doesn't pay for it.
    func warmUp() {
        guard isAvailable else { return }
        Task {
            _ = await engine.prepare()
            for phrase in savedPhrases().map(\.phrase) {
                _ = await vector(for: phrase)
            }
        }
    }

    // MARK: - Planning (1 to 5)

    /// What to do with an ask the strict lane didn't recognize, or nil
    /// to ask Gemini. Never waits longer than deadlineSeconds.
    func plan(for requestText: String, minimumConfidence: Double = actConfidence) async -> DottieInstantLane.Plan? {
        guard isAvailable else { return nil }
        let normalizedRequest = DottieInstantText.normalized(requestText)
        let requestWordCount = normalizedRequest.split(separator: " ").count
        guard (1...Self.longestRoutedWordCount).contains(requestWordCount),
              DottieInstantLane.shared.namedShortcutRequest(in: requestText) == nil else { return nil }

        return await withDeadline(seconds: Self.deadlineSeconds) {
            if let learnedShortcut = await self.learnedShortcut(matchingMeaningOf: normalizedRequest) {
                return .learnedShortcut(learnedShortcut)
            }
            return await self.toolCallPlan(for: normalizedRequest, minimumConfidence: minimumConfidence)
        }
    }

    private func toolCallPlan(for normalizedRequest: String, minimumConfidence: Double) async -> DottieInstantLane.Plan? {
        let toolset = DottieNeedleToolset.toolset(forNormalizedRequest: normalizedRequest)
        guard let answer = await engine.toolCalls(
            for: normalizedRequest,
            toolsJSON: toolset.toolsJSON,
            facts: DottieNeedleToolset.systemFacts()
        ), !answer.toolCalls.isEmpty,
              let confidence = answer.confidence, confidence >= minimumConfidence else { return nil }

        switch toolset {
        case .mac, .search:
            var commandTexts: [String] = []
            var instantCommands: [DottieInstantCommand] = []
            for toolCall in answer.toolCalls {
                guard let commandWords = DottieNeedleToolset.instantCommandWords(for: toolCall),
                      let parsedCommands = DottieInstantCommands.parseAll(commandWords) else { return nil }
                commandTexts.append(commandWords)
                instantCommands.append(contentsOf: parsedCommands)
            }
            rememberWorkedOutAsk(normalizedRequest, commandTexts: commandTexts)
            return .instantCommands(instantCommands)

        case .organizer:
            // One reminder or event at a time; anything more is Gemini's.
            guard answer.toolCalls.count == 1,
                  let organizerStep = DottieNeedleToolset.organizerStep(for: answer.toolCalls[0], fullRequest: normalizedRequest) else { return nil }
            return .toolSteps([DottieLearnedShortcut.Step(functionName: organizerStep.functionName, arguments: organizerStep.arguments)])
        }
    }

    /// 3. The next time these exact words come, the strict lane replays it
    /// without Needle. Asks that depend on the moment ("put this on the
    /// left") are left to Needle each time.
    private func rememberWorkedOutAsk(_ normalizedRequest: String, commandTexts: [String]) {
        guard DottieInstantLane.isShortcutLearningEnabled,
              !DottieInstantText.containsMomentWord(normalizedRequest),
              (2...12).contains(normalizedRequest.split(separator: " ").count),
              DottieInstantCommands.parseAll(normalizedRequest) == nil else { return }
        let savedSteps = commandTexts.map { commandText in
            DottieLearnedShortcut.Step(functionName: DottieInstantCommand.savedStepFunctionName, arguments: ["text": commandText])
        }
        DottieLearnedShortcutStore.shared.save(
            phrase: normalizedRequest,
            otherPhrases: [],
            steps: savedSteps,
            reply: "Done.",
            isNamedByUser: false
        )
    }

    /// Words that often start or carry a Mac action Needle can do. A
    /// partial transcript with one of them makes the lane hold Live's
    /// answer a moment while Needle checks; anything else isn't held, so
    /// questions and chat never wait.
    private static let actionWords: Set<String> = [
        "open", "launch", "start", "fire", "pop", "bring", "pull", "show", "get", "quit", "close", "kill", "shut",
        "exit", "put", "move", "snap", "throw", "send", "make", "center", "centre", "maximize", "full", "fullscreen",
        "left", "right", "monitor", "screen", "display", "window", "play", "pause", "stop", "skip", "next", "previous",
        "song", "track", "music", "volume", "louder", "quieter", "softer", "mute", "unmute", "sound", "crank", "turn",
        "google", "search", "youtube", "look", "remind", "reminder", "calendar", "schedule"
    ]

    func mightHandle(normalizedPartialText: String) -> Bool {
        guard isAvailable else { return false }
        let partialWords = normalizedPartialText.split(separator: " ").map(String.init)
        guard (1...Self.longestRoutedWordCount).contains(partialWords.count) else { return false }
        return partialWords.contains { Self.actionWords.contains($0) }
    }

    // MARK: - Learned shortcuts by meaning (2)

    private func savedPhrases() -> [(phrase: String, shortcut: DottieLearnedShortcut)] {
        DottieLearnedShortcutStore.shared.shortcuts.flatMap { shortcut in
            ([shortcut.phrase] + shortcut.otherPhrases).map { (phrase: $0, shortcut: shortcut) }
        }
    }

    private func learnedShortcut(matchingMeaningOf normalizedRequest: String) async -> DottieLearnedShortcut? {
        let phrasesWithShortcuts = savedPhrases()
        guard !phrasesWithShortcuts.isEmpty,
              !DottieInstantText.containsMomentWord(normalizedRequest),
              let requestVector = await engine.embedding(for: normalizedRequest) else { return nil }

        var bestSimilarityByShortcutID: [UUID: (similarity: Float, shortcut: DottieLearnedShortcut)] = [:]
        for (phrase, shortcut) in phrasesWithShortcuts {
            guard let phraseVector = await vector(for: phrase) else { continue }
            let similarity = DottieNeedleEngine.similarity(requestVector, phraseVector)
            if similarity > (bestSimilarityByShortcutID[shortcut.id]?.similarity ?? -1) {
                bestSimilarityByShortcutID[shortcut.id] = (similarity, shortcut)
            }
        }
        let rankedMatches = bestSimilarityByShortcutID.values.sorted { $0.similarity > $1.similarity }
        guard let bestMatch = rankedMatches.first, bestMatch.similarity >= Self.shortcutMeaningSimilarity else { return nil }
        // Two shortcuts that both fit ("open my mail" and "open my mail
        // app on the left") is a guess, so Gemini decides.
        if rankedMatches.count > 1, bestMatch.similarity - rankedMatches[1].similarity < Self.shortcutMeaningMargin {
            return nil
        }
        DottieLearnedShortcutStore.shared.addOtherPhrase(normalizedRequest, toShortcutWithID: bestMatch.shortcut.id)
        return bestMatch.shortcut
    }

    private func vector(for text: String) async -> [Float]? {
        if let cachedVector = vectorsByText[text] { return cachedVector }
        guard let newVector = await engine.embedding(for: text) else { return nil }
        vectorsByText[text] = newVector
        return newVector
    }

    // MARK: - While Gemini is down (5)

    /// Gemini couldn't answer this ask (no internet, busy, quota). Returns
    /// what was done on the Mac instead, or nil when nothing fit.
    func doWhileGeminiIsDown(_ requestText: String) async -> String? {
        if let strictPlan = DottieInstantLane.shared.plan(for: requestText),
           case .done(let doneText) = await DottieInstantLane.shared.run(strictPlan) {
            return doneText
        }
        guard let needlePlan = await plan(for: requestText, minimumConfidence: Self.geminiDownActConfidence),
              case .done(let doneText) = await DottieInstantLane.shared.run(needlePlan) else { return nil }
        return doneText
    }

    // MARK: - find_tool by meaning (6)

    /// Hidden tool names in order of how close their descriptions are in
    /// meaning to what the user wants, best first, with how close.
    func hiddenToolsRankedByMeaning(for whatTheUserWants: String, amongHiddenDeclarations hiddenDeclarations: [[String: Any]]) async -> [(name: String, similarity: Float)] {
        guard DottieNeedleEngine.isEnabled, engine.isBundled,
              let queryVector = await engine.embedding(for: whatTheUserWants.lowercased()) else { return [] }
        var rankedTools: [(name: String, similarity: Float)] = []
        for declaration in hiddenDeclarations {
            guard let toolName = declaration["name"] as? String else { continue }
            let toolDescription = declaration["description"] as? String ?? ""
            // The first sentence says what the tool is; the rest is how to use it.
            let describingText = toolName.replacingOccurrences(of: "_", with: " ") + ": " + DottieInstantLane.firstSentence(of: toolDescription)
            guard let toolVector = await vector(for: describingText) else { continue }
            rankedTools.append((toolName, DottieNeedleEngine.similarity(queryVector, toolVector)))
        }
        return rankedTools.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Sorting asks (7)

    /// One of `labels` for the text, or nil when Needle isn't sure.
    func classify(_ text: String, labels: [String], meaning: String) async -> String? {
        guard DottieNeedleEngine.isEnabled, engine.isBundled, labels.count >= 2 else { return nil }
        let labelsJSON = labels.map { "\"\($0)\"" }.joined(separator: ", ")
        let escapedMeaning = meaning.replacingOccurrences(of: "\"", with: "'")
        let sortingToolsJSON = """
        [{"name": "sort_request", "description": "Sort the request.", "parameters": {"type": "object", "properties": {"kind": {"type": "string", "enum": [\(labelsJSON)], "description": "\(escapedMeaning)"}}, "required": ["kind"]}}]
        """
        guard let answer = await withDeadline(seconds: 1.0, operation: {
            await self.engine.toolCalls(for: text, toolsJSON: sortingToolsJSON, facts: "")
        }), let sortedKind = answer.toolCalls.first?.arguments["kind"], labels.contains(sortedKind),
              (answer.confidence ?? 0) >= 0.6 else { return nil }
        return sortedKind
    }

    // MARK: - Whistle (8)

    var canHearWithWhistle: Bool {
        isAvailable && engine.isWhistleBundled && DottieNeedleEngine.isWhistleEnabled
    }

    /// The words in a short push-to-talk recording (16 kHz mono PCM16),
    /// favoring the names of open apps. "" when nothing was heard.
    func hear(pcm16AudioData: Data) async -> String {
        guard canHearWithWhistle, !pcm16AudioData.isEmpty else { return "" }
        let samples: [Float] = pcm16AudioData.withUnsafeBytes { rawBytes in
            rawBytes.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        let openAppNames = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        return await engine.transcribe(samples: samples, keywords: Array(openAppNames.prefix(30)))?.text ?? ""
    }

    // MARK: - Helpers

    /// Runs the operation, but gives up on it (returns nil) after the
    /// deadline. The engine can't be interrupted mid-call, so a late
    /// answer is simply dropped.
    private func withDeadline<Result>(seconds: Double, operation: @escaping @MainActor () async -> Result?) async -> Result? {
        let deadlineGate = DeadlineGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            Task { @MainActor in
                let operationResult = await operation()
                guard deadlineGate.claim() else { return }
                continuation.resume(returning: operationResult)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard deadlineGate.claim() else { return }
                continuation.resume(returning: nil)
            }
        }
    }
}

/// Lets exactly one of two racing tasks finish a continuation.
@MainActor
private final class DeadlineGate {
    private var isClaimed = false

    func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
