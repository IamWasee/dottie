//
//  DottieInstantLane.swift
//  leanring-buddy
//
//  The fast lane in front of Gemini. What the user says (heard on the Mac
//  by Apple's speech recognizer while they hold the talk shortcut) or
//  types is checked here first, and when it's something Dottie already
//  knows how to do, she does it at once with no AI:
//
//    1. Instant commands (DottieInstantCommands): open or quit an app,
//       move a window, music, volume, a Google or YouTube search.
//    2. Learned shortcuts: an ask Gemini got done with direct actions
//       (open_url, press_keys, run_shortcut, run_applescript,
//       control_device, instant commands) is saved with exactly those
//       actions. The same words later replay them without Gemini.
//    3. Named shortcuts: "when I say focus mode, quit Slack and open
//       Notes". Saved straight away when the steps are instant commands;
//       otherwise Gemini does the steps once and they're saved under the
//       name.
//    4. Replay phrases the user set for a saved screen job (DottieReplays),
//       which start that job directly.
//
//  Ideas from Atticus (github.com/saarthurr/atticus-mac, MIT). Learned
//  shortcuts are kept in Application Support/Dottie/LearnedShortcuts.json
//  and are never sent to Gemini, so they cost nothing as they grow.
//

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - What's saved

struct DottieLearnedShortcut: Codable, Identifiable, Equatable {
    struct Step: Codable, Equatable {
        var functionName: String
        /// The tool's arguments as a JSON object.
        var argumentsJSON: String

        var arguments: [String: Any] {
            guard let argumentsData = argumentsJSON.data(using: .utf8),
                  let parsedArguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else { return [:] }
            return parsedArguments
        }

        init(functionName: String, arguments: [String: Any]) {
            self.functionName = functionName
            let argumentsData = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data("{}".utf8)
            self.argumentsJSON = String(decoding: argumentsData, as: UTF8.self)
        }

        /// What the step does, for Settings and the voice tool.
        var summary: String {
            let stepArguments = arguments
            switch functionName {
            case DottieInstantCommand.savedStepFunctionName: return stepArguments.dottieString("text") ?? "instant command"
            case "open_url": return "open " + (stepArguments.dottieString("url") ?? "a page")
            case "press_keys": return "press " + (stepArguments.dottieString("keys") ?? "keys")
            case "run_shortcut": return "run the shortcut " + (stepArguments.dottieString("name") ?? "")
            case "run_applescript": return stepArguments.dottieString("purpose") ?? "run a script"
            case "control_device": return "control " + (stepArguments.dottieString("device") ?? stepArguments.dottieString("name") ?? "a device")
            default: return functionName
            }
        }
    }

    var id = UUID()
    /// The words that start it, normalized (DottieInstantText.normalized).
    var phrase: String
    /// Other wordings heard for the same ask (Gemini's own transcript).
    var otherPhrases: [String] = []
    var steps: [Step]
    /// What Dottie said the first time, shown when it's replayed.
    var reply: String
    /// Made with "when I say …": kept until the user removes it.
    var isNamedByUser: Bool
    var createdAt = Date()
    var lastUsedAt: Date?
    var useCount = 0
}

@MainActor
final class DottieLearnedShortcutStore: ObservableObject {
    static let shared = DottieLearnedShortcutStore()

    @Published private(set) var shortcuts: [DottieLearnedShortcut] = []

    private let fileURL: URL
    private static let maximumShortcutCount = 200
    /// Learned (not named) shortcuts nobody used for this long are dropped.
    private static let unusedLearnedShortcutLifetime: TimeInterval = 60 * 24 * 60 * 60

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dottieFolderURL = applicationSupportURL.appendingPathComponent("Dottie", isDirectory: true)
        try? FileManager.default.createDirectory(at: dottieFolderURL, withIntermediateDirectories: true)
        fileURL = dottieFolderURL.appendingPathComponent("LearnedShortcuts.json")
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let savedData = try? Data(contentsOf: fileURL),
              let savedShortcuts = try? decoder.decode([DottieLearnedShortcut].self, from: savedData) else { return }
        let oldestKeptDate = Date().addingTimeInterval(-Self.unusedLearnedShortcutLifetime)
        shortcuts = savedShortcuts.filter { shortcut in
            shortcut.isNamedByUser
                || ((shortcut.lastUsedAt ?? shortcut.createdAt) > oldestKeptDate && !Self.opensGoogleForAnUnnamedSearch(shortcut))
        }
    }

    /// Needle used to learn "search for the weather" as opening a Google
    /// page, so Dottie never answered it again. Those are dropped so the
    /// ask goes back to Gemini, which looks it up and says the answer.
    private static func opensGoogleForAnUnnamedSearch(_ shortcut: DottieLearnedShortcut) -> Bool {
        let phraseWords = Set(shortcut.phrase.split(separator: " ").map(String.init))
        guard !phraseWords.contains("google"), !phraseWords.contains("googling") else { return false }
        return shortcut.steps.contains { step in
            step.functionName == DottieInstantCommand.savedStepFunctionName
                && (step.arguments.dottieString("text") ?? "").hasPrefix("google ")
        }
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let shortcutsData = try? encoder.encode(shortcuts) else { return }
        // Atomic, so a crash mid-write can't wipe what was learned before.
        try? shortcutsData.write(to: fileURL, options: .atomic)
    }

    func shortcut(matching normalizedRequest: String) -> DottieLearnedShortcut? {
        guard !normalizedRequest.isEmpty else { return nil }
        if let exactMatch = shortcuts.first(where: { $0.phrase == normalizedRequest || $0.otherPhrases.contains(normalizedRequest) }) {
            return exactMatch
        }
        // "notes on the left please" and "on the left notes" are the same ask.
        let requestWordsKey = DottieInstantText.sortedWordsKey(normalizedRequest)
        return shortcuts.first { shortcut in
            ([shortcut.phrase] + shortcut.otherPhrases).contains { DottieInstantText.sortedWordsKey($0) == requestWordsKey }
        }
    }

    /// Saves the steps under the phrase, replacing an older version of it.
    /// Returns true when the phrase is new.
    @discardableResult
    func save(phrase: String, otherPhrases: [String], steps: [DottieLearnedShortcut.Step], reply: String, isNamedByUser: Bool) -> Bool {
        let otherDistinctPhrases = Array(Set(otherPhrases.filter { !$0.isEmpty && $0 != phrase }))
        if let existingIndex = shortcuts.firstIndex(where: { $0.phrase == phrase || $0.otherPhrases.contains(phrase) }) {
            // A learned version never replaces one the user named.
            if shortcuts[existingIndex].isNamedByUser && !isNamedByUser { return false }
            shortcuts[existingIndex].steps = steps
            shortcuts[existingIndex].reply = reply
            shortcuts[existingIndex].isNamedByUser = isNamedByUser
            shortcuts[existingIndex].otherPhrases = Array(Set(shortcuts[existingIndex].otherPhrases + otherDistinctPhrases))
            write()
            return false
        }
        shortcuts.append(DottieLearnedShortcut(phrase: phrase, otherPhrases: otherDistinctPhrases, steps: steps, reply: reply, isNamedByUser: isNamedByUser))
        if shortcuts.count > Self.maximumShortcutCount,
           let leastUsedLearnedIndex = shortcuts.indices.filter({ !shortcuts[$0].isNamedByUser })
            .min(by: { (shortcuts[$0].lastUsedAt ?? shortcuts[$0].createdAt) < (shortcuts[$1].lastUsedAt ?? shortcuts[$1].createdAt) }) {
            shortcuts.remove(at: leastUsedLearnedIndex)
        }
        write()
        return true
    }

    func noteUsed(_ shortcutID: UUID) {
        guard let shortcutIndex = shortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
        shortcuts[shortcutIndex].lastUsedAt = Date()
        shortcuts[shortcutIndex].useCount += 1
        write()
    }

    func forget(_ shortcutID: UUID) {
        shortcuts.removeAll { $0.id == shortcutID }
        write()
    }

    func forgetAll() {
        shortcuts = []
        write()
    }
}

// MARK: - The lane

@MainActor
final class DottieInstantLane {
    static let shared = DottieInstantLane()

    nonisolated static let instantCommandsEnabledDefaultsKey = "dottieInstantCommandsEnabled"
    nonisolated static let shortcutLearningEnabledDefaultsKey = "dottieLearnsShortcuts"

    nonisolated static var areInstantCommandsEnabled: Bool {
        UserDefaults.standard.object(forKey: instantCommandsEnabledDefaultsKey) as? Bool ?? true
    }

    nonisolated static var isShortcutLearningEnabled: Bool {
        UserDefaults.standard.object(forKey: shortcutLearningEnabledDefaultsKey) as? Bool ?? true
    }

    /// Runs a saved tool step the same way Gemini's call would have run it.
    /// Set by CompanionManager.
    var runSavedToolStep: ((_ functionName: String, _ arguments: [String: Any]) async -> String)?

    enum Plan {
        case instantCommands([DottieInstantCommand])
        case learnedShortcut(DottieLearnedShortcut)
        case replayPhrase(DottieReplay)
        case saveNamedShortcut(name: String, commandTexts: [String])
        /// Dottie's own tools, worked out by Needle (a reminder, an event).
        case toolSteps([DottieLearnedShortcut.Step])
    }

    enum Outcome {
        /// Done with no AI; the text is shown in the notch.
        case done(String)
        /// Not something to do on the Mac after all: ask Gemini.
        case askGemini
    }

    /// A tool call Gemini made in a turn, with what it returned.
    struct FinishedToolCall {
        let functionName: String
        let arguments: [String: Any]
        let result: String
    }

    /// Tools whose saved calls can be run again later and do the same thing.
    private static let replayableFunctionNames: Set<String> = [
        "open_url", "press_keys", "run_shortcut", "run_applescript", "control_device",
        DottieInstantCommand.savedStepFunctionName
    ]

    /// Tools that only look something up on the way; a learned shortcut
    /// keeps just the actions.
    private static let lookingFunctionNames: Set<String> = [
        "search_web", "recall_memory", "list_shortcuts", "home_devices", "find_tool", "about_me"
    ]

    private static let failureMarkers = [
        "couldn't", "could not", "failed", "error", "said no", "blocked", "not found", "there's no", "can't",
        "cannot", "unknown", "wasn't", "didn't", "not allowed", "needs you to", "isn't available", "unable"
    ]

    private static let replyAdmitsFailureMarkers = [
        "couldn't", "can't", "cannot", "unable", "failed", "didn't work", "not able", "no luck", "sorry", "doesn't seem"
    ]

    /// Longer asks rarely come back word for word, so they aren't learned.
    private static let longestLearnedPhraseWordCount = 12

    // MARK: Planning

    /// What to do with a request without Gemini, or nil to ask Gemini.
    func plan(for requestText: String) -> Plan? {
        guard Self.areInstantCommandsEnabled else { return nil }
        let normalizedRequest = DottieInstantText.normalized(requestText)
        guard !normalizedRequest.isEmpty else { return nil }

        if let namedShortcutRequest = namedShortcutRequest(in: requestText),
           let namedShortcutCommands = DottieInstantCommands.parseAllWithWords(namedShortcutRequest.task) {
            return .saveNamedShortcut(name: namedShortcutRequest.name, commandTexts: namedShortcutCommands.map(\.words))
        }
        if let learnedShortcut = DottieLearnedShortcutStore.shared.shortcut(matching: normalizedRequest) {
            return .learnedShortcut(learnedShortcut)
        }
        if let replayWithPhrase = DottieReplayStore.shared.replays.first(where: { replay in
            (replay.voiceShortcuts ?? []).contains { DottieInstantText.normalized($0) == normalizedRequest }
        }) {
            return .replayPhrase(replayWithPhrase)
        }
        if let instantCommands = DottieInstantCommands.parseAll(normalizedRequest) {
            return .instantCommands(instantCommands)
        }
        return nil
    }

    /// plan(for:), then Needle (DottieNeedleRouter) for wording the strict
    /// lane doesn't know, reminders and events.
    func planIncludingNeedle(for requestText: String) async -> Plan? {
        if let strictPlan = plan(for: requestText) { return strictPlan }
        guard Self.areInstantCommandsEnabled else { return nil }
        return await DottieNeedleRouter.shared.plan(for: requestText)
    }

    /// First words of the instant commands. A transcript that starts with
    /// one of these (or a saved phrase's first word) may still turn into
    /// an instant command once its last words come in.
    private static let instantCommandFirstWords: Set<String> = [
        "open", "launch", "start", "go", "pull", "bring", "switch", "quit", "close", "exit", "shut",
        "put", "move", "snap", "send", "throw", "place", "drag", "make", "show", "maximize", "maximise", "center", "centre",
        "play", "pause", "resume", "unpause", "keep", "stop", "next", "skip", "previous", "last", "back",
        "volume", "turn", "louder", "quieter", "lower", "raise", "increase", "decrease", "mute", "unmute", "set",
        "google", "search", "look", "find", "when", "whenever", "from"
    ]

    /// Window moves can start with the app's name ("terminal on the left").
    private static let windowPlacementLastWords: Set<String> = [
        "left", "right", "screen", "monitor", "display", "laptop", "middle", "center", "fullscreen", "maximized", "half", "side", "big", "bigger"
    ]

    /// Whether a partial transcript might be something the lane does, so
    /// Gemini's answer is worth holding back for a moment. Empty (nothing
    /// recognized yet) counts as maybe.
    func couldBecomeInstant(partialText: String) -> Bool {
        guard Self.areInstantCommandsEnabled else { return false }
        let normalizedPartial = DottieInstantText.normalized(partialText)
        let partialWords = normalizedPartial.split(separator: " ").map(String.init)
        guard let firstWord = partialWords.first, let lastWord = partialWords.last else { return true }
        if plan(for: partialText) != nil { return true }
        if Self.instantCommandFirstWords.contains(firstWord) || Self.windowPlacementLastWords.contains(lastWord) { return true }
        let savedPhraseFirstWords = Set(
            DottieLearnedShortcutStore.shared.shortcuts.flatMap { [$0.phrase] + $0.otherPhrases }
                .compactMap { $0.split(separator: " ").first.map(String.init) }
        )
        if savedPhraseFirstWords.contains(firstWord) { return true }
        return DottieNeedleRouter.shared.mightHandle(normalizedPartialText: normalizedPartial)
    }

    func run(_ plan: Plan) async -> Outcome {
        switch plan {
        case .instantCommands(let instantCommands):
            return await runInstantCommands(instantCommands)

        case .learnedShortcut(let learnedShortcut):
            return await replay(learnedShortcut)

        case .replayPhrase(let replayWithPhrase):
            guard let startReplayJob = DottieSpeedTools.startReplayJob else { return .askGemini }
            _ = startReplayJob(replayWithPhrase)
            return .done("On it: \(replayWithPhrase.name).")

        case .saveNamedShortcut(let shortcutName, let commandTexts):
            let parsedCommands = commandTexts.map { DottieInstantCommands.parseAll($0) }
            guard parsedCommands.allSatisfy({ $0 != nil }) else { return .askGemini }
            let instantCommands = parsedCommands.compactMap { $0 }.flatMap { $0 }
            let savedSteps = commandTexts.map { commandText in
                DottieLearnedShortcut.Step(functionName: DottieInstantCommand.savedStepFunctionName, arguments: ["text": commandText])
            }
            let outcome = await runInstantCommands(instantCommands)
            let doneText: String
            if case .done(let commandsDoneText) = outcome { doneText = commandsDoneText } else { doneText = "" }
            DottieLearnedShortcutStore.shared.save(
                phrase: DottieInstantText.normalized(shortcutName),
                otherPhrases: [],
                steps: savedSteps,
                reply: doneText.isEmpty ? "Done." : doneText,
                isNamedByUser: true
            )
            return .done("Saved: say “\(shortcutName)” any time. " + doneText)

        case .toolSteps(let toolSteps):
            guard let runSavedToolStep else { return .askGemini }
            var resultLines: [String] = []
            for (stepIndex, toolStep) in toolSteps.enumerated() {
                let stepResult = await runSavedToolStep(toolStep.functionName, toolStep.arguments)
                // Nothing done yet: Gemini can still try it its own way.
                if stepIndex == 0 && Self.looksLikeFailure(stepResult) {
                    return .askGemini
                }
                resultLines.append(Self.firstSentence(of: stepResult))
            }
            let doneText = resultLines.joined(separator: " ")
            return .done(doneText.prefix(1).uppercased() + doneText.dropFirst())
        }
    }

    private func runInstantCommands(_ instantCommands: [DottieInstantCommand]) async -> Outcome {
        var doneLines: [String] = []
        for instantCommand in instantCommands {
            switch await DottieInstantCommands.run(instantCommand) {
            case .done(let doneLine):
                doneLines.append(doneLine)
            case .failed(let failureLine):
                doneLines.append(failureLine)
            case .notHandled:
                // Only the first one can still go to Gemini untouched.
                if doneLines.isEmpty { return .askGemini }
            }
            // Give a just-opened app a moment before the next step uses it.
            if instantCommands.count > 1 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return .done(doneLines.joined(separator: " "))
    }

    private func replay(_ learnedShortcut: DottieLearnedShortcut) async -> Outcome {
        for (stepIndex, savedStep) in learnedShortcut.steps.enumerated() {
            let stepResult: String
            if savedStep.functionName == DottieInstantCommand.savedStepFunctionName {
                guard let commandText = savedStep.arguments.dottieString("text"),
                      let instantCommands = DottieInstantCommands.parseAll(commandText) else {
                    stepResult = "couldn't do \(savedStep.summary)"
                    return handleFailedReplay(learnedShortcut, stepIndex: stepIndex, stepResult: stepResult)
                }
                switch await runInstantCommands(instantCommands) {
                case .done(let doneText): stepResult = doneText
                case .askGemini: stepResult = "couldn't do \(savedStep.summary)"
                }
            } else {
                guard let runSavedToolStep else { return .askGemini }
                stepResult = await runSavedToolStep(savedStep.functionName, savedStep.arguments)
            }
            if Self.looksLikeFailure(stepResult) {
                return handleFailedReplay(learnedShortcut, stepIndex: stepIndex, stepResult: stepResult)
            }
        }
        DottieLearnedShortcutStore.shared.noteUsed(learnedShortcut.id)
        return .done(Self.firstSentence(of: learnedShortcut.reply))
    }

    /// A learned shortcut that stopped working is forgotten and the ask
    /// goes to Gemini, which works it out again (and can re-learn it). One
    /// the user named is kept, and the failure is shown instead.
    private func handleFailedReplay(_ learnedShortcut: DottieLearnedShortcut, stepIndex: Int, stepResult: String) -> Outcome {
        if learnedShortcut.isNamedByUser {
            return .done("“\(learnedShortcut.phrase)” didn't work this time: \(stepResult)")
        }
        // Only safe to hand to Gemini when nothing was done yet.
        DottieLearnedShortcutStore.shared.forget(learnedShortcut.id)
        return stepIndex == 0 ? .askGemini : .done("That only half worked, so I forgot that shortcut: \(stepResult)")
    }

    // MARK: Named shortcuts

    /// "when I say focus mode, quit slack and open notes" → ("focus mode",
    /// "quit slack and open notes"), or nil when it isn't one.
    func namedShortcutRequest(in requestText: String) -> (name: String, task: String)? {
        let lowercasedRequest = requestText.lowercased()
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let leadPattern = #"^(?:(?:hey|ok|okay|so|dottie)[,\s]+)*(?:from now on[,\s]+)?when(?:ever)? i say\s+"#
        guard let leadRange = lowercasedRequest.range(of: leadPattern, options: .regularExpression) else { return nil }
        let afterLead = String(lowercasedRequest[leadRange.upperBound...])

        var shortcutName = ""
        var taskText = ""
        if afterLead.hasPrefix("\""), let closingQuoteIndex = afterLead.dropFirst().firstIndex(of: "\"") {
            shortcutName = String(afterLead[afterLead.index(after: afterLead.startIndex)..<closingQuoteIndex])
            taskText = String(afterLead[afterLead.index(after: closingQuoteIndex)...])
        } else if let separatorRange = afterLead.range(of: #"\s*[,:;]\s*|\s+(?:then|you should|i want you to|i mean|it means|that means|do)\s+"#, options: .regularExpression) {
            shortcutName = String(afterLead[..<separatorRange.lowerBound])
            taskText = String(afterLead[separatorRange.upperBound...])
        } else {
            // No comma heard: the shortest name (one to four words) after
            // which everything else is instant commands.
            let afterLeadWords = afterLead.split(separator: " ").map(String.init)
            for nameWordCount in 1...min(4, max(afterLeadWords.count - 1, 1)) where afterLeadWords.count > nameWordCount {
                let candidateTask = afterLeadWords.dropFirst(nameWordCount).joined(separator: " ")
                if DottieInstantCommands.parseAll(candidateTask) != nil {
                    shortcutName = afterLeadWords.prefix(nameWordCount).joined(separator: " ")
                    taskText = candidateTask
                    break
                }
            }
        }
        shortcutName = shortcutName.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\"'"))
        taskText = taskText.replacingOccurrences(of: #"^[\s,:;]*(?:then|please|you should|do|can you)?\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\"'"))
        guard (2...40).contains(shortcutName.count), !taskText.isEmpty else { return nil }
        return (shortcutName, taskText)
    }

    // MARK: Learning

    /// After Gemini finished a turn: when everything it did can be done
    /// again the same way, save it under the user's words. Returns the
    /// saved phrase when it was new (or named), for a "Saved" card.
    @discardableResult
    func learnFromFinishedTurn(
        requestTexts: [String],
        finishedToolCalls: [FinishedToolCall],
        modelReply: String,
        namedShortcutName: String?
    ) -> String? {
        guard Self.isShortcutLearningEnabled || namedShortcutName != nil else { return nil }
        let actionToolCalls = finishedToolCalls.filter { !Self.lookingFunctionNames.contains($0.functionName) }
        guard !actionToolCalls.isEmpty,
              actionToolCalls.count <= 6,
              actionToolCalls.allSatisfy({ isReplayable($0) }),
              !Self.replyAdmitsFailure(modelReply) else { return nil }

        let normalizedRequests = requestTexts.map(DottieInstantText.normalized).filter { !$0.isEmpty }
        let primaryPhrase: String
        if let namedShortcutName {
            primaryPhrase = DottieInstantText.normalized(namedShortcutName)
        } else {
            // "close this" depends on the moment, and instant commands are
            // already instant.
            guard let firstRequest = normalizedRequests.first,
                  normalizedRequests.allSatisfy({ !DottieInstantText.containsMomentWord($0) }),
                  (2...Self.longestLearnedPhraseWordCount).contains(firstRequest.split(separator: " ").count),
                  DottieInstantCommands.parseAll(firstRequest) == nil else { return nil }
            primaryPhrase = firstRequest
        }
        guard !primaryPhrase.isEmpty else { return nil }

        let savedSteps = actionToolCalls.map { DottieLearnedShortcut.Step(functionName: $0.functionName, arguments: $0.arguments) }
        let isNewPhrase = DottieLearnedShortcutStore.shared.save(
            phrase: primaryPhrase,
            otherPhrases: namedShortcutName == nil ? Array(normalizedRequests.dropFirst()) : [],
            steps: savedSteps,
            reply: modelReply.isEmpty ? "Done." : modelReply,
            isNamedByUser: namedShortcutName != nil
        )
        return (isNewPhrase || namedShortcutName != nil) ? primaryPhrase : nil
    }

    private func isReplayable(_ finishedToolCall: FinishedToolCall) -> Bool {
        guard Self.replayableFunctionNames.contains(finishedToolCall.functionName),
              !Self.looksLikeFailure(finishedToolCall.result) else { return false }
        if finishedToolCall.functionName == "run_applescript" {
            // Scripts that send, delete or run shell commands ask first
            // every time; they're never replayed by themselves.
            let scriptText = finishedToolCall.arguments.dottieString("script") ?? ""
            return !scriptText.isEmpty && !DottieMacActions.isRisky(scriptText)
        }
        if finishedToolCall.functionName == "control_device" {
            // Unlocking, opening (a garage door is "open" too) and alarms
            // need the user's yes each time, so a call that carried one is
            // never saved. "look" answers a question, which needs a fresh
            // look every time.
            let deviceAction = finishedToolCall.arguments.dottieString("action")?.lowercased() ?? ""
            let neverSavedDeviceActions: Set<String> = ["unlock", "open", "look", "disarm", "alarm_off"]
            return finishedToolCall.arguments.dottieBool("confirmed") != true
                && !neverSavedDeviceActions.contains(deviceAction)
                && !deviceAction.contains("alarm")
        }
        return true
    }

    static func looksLikeFailure(_ resultText: String) -> Bool {
        let lowercasedResult = resultText.lowercased()
        return failureMarkers.contains { lowercasedResult.contains($0) }
    }

    private static func replyAdmitsFailure(_ modelReply: String) -> Bool {
        let lowercasedReply = modelReply.lowercased()
        return replyAdmitsFailureMarkers.contains { lowercasedReply.contains($0) }
    }

    static func firstSentence(of text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "Done." }
        let sentenceEnd = trimmedText.firstIndex { ".!?".contains($0) }
        let firstSentence = sentenceEnd.map { String(trimmedText[...$0]) } ?? trimmedText
        return firstSentence.count > 140 ? String(firstSentence.prefix(139)) + "…" : firstSentence
    }
}

// MARK: - Voice tool

@MainActor
enum DottieInstantLaneTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "learned_shortcuts",
                description: "Shortcuts Dottie does instantly with no AI: asks she already got done once with direct actions (opening pages, keys, Apple shortcuts, scripts, smart home) replay by themselves when the user says the same words again, and ones the user named ('when I say focus mode, …'). list shows them, numbered. forget deletes one by its words or number. forget_all clears them. Use when the user asks what shortcuts you know or to forget one.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["list", "forget", "forget_all"]],
                        "name": ["type": "STRING", "description": "forget: the shortcut's words, or its number in the list."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice],
                run: { arguments in learnedShortcuts(arguments) }
            )
        ]
    }

    static var voicePromptSection: String {
        "when the user says 'when i say X, do Y' (and Y isn't a saved replay), do Y now with your tools; the app saves what you did as the shortcut X by itself, so don't call remember for it."
    }

    private static func learnedShortcuts(_ arguments: [String: Any]) -> String {
        let store = DottieLearnedShortcutStore.shared
        switch arguments.dottieString("action")?.lowercased() ?? "list" {
        case "forget":
            guard let wantedName = arguments.dottieString("name") else { return "say which shortcut." }
            let matchingShortcut: DottieLearnedShortcut?
            if let listNumber = Int(wantedName), store.shortcuts.indices.contains(listNumber - 1) {
                matchingShortcut = store.shortcuts[listNumber - 1]
            } else {
                let normalizedName = DottieInstantText.normalized(wantedName)
                matchingShortcut = store.shortcut(matching: normalizedName)
                    ?? store.shortcuts.first { $0.phrase.contains(normalizedName) }
            }
            guard let matchingShortcut else { return "no shortcut matches that. call learned_shortcuts with action list to see them." }
            store.forget(matchingShortcut.id)
            return "forgot \"\(matchingShortcut.phrase)\"."
        case "forget_all":
            store.forgetAll()
            return "forgot every learned shortcut."
        default:
            guard !store.shortcuts.isEmpty else { return "no learned shortcuts yet. they appear after an ask works with direct actions, or when the user says 'when I say X, do Y'." }
            return store.shortcuts.enumerated().prefix(40).map { index, shortcut in
                "\(index + 1). \"\(shortcut.phrase)\"\(shortcut.isNamedByUser ? " (named)" : ""): " + shortcut.steps.map(\.summary).joined(separator: ", ")
            }.joined(separator: "\n")
        }
    }
}

// MARK: - Settings

/// Settings → Instant commands: the two switches and every learned
/// shortcut, each with a delete button.
struct HomeInstantLaneSettings: View {
    @ObservedObject private var store = DottieLearnedShortcutStore.shared
    @AppStorage(DottieInstantLane.instantCommandsEnabledDefaultsKey) private var areInstantCommandsEnabled = true
    @AppStorage(DottieInstantLane.shortcutLearningEnabledDefaultsKey) private var isShortcutLearningEnabled = true
    @AppStorage(DottieNeedleEngine.isEnabledDefaultsKey) private var isNeedleEnabled = true
    @AppStorage(DottieNeedleEngine.isWhistleEnabledDefaultsKey) private var isWhistleEnabled = true
    @State private var needleStatusText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Do simple asks instantly, with no AI")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Toggle("", isOn: $areInstantCommandsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("“Open Spotify”, “quit Slack”, “Terminal on the left”, “Chrome on my other screen”, “maximize Safari”, “next song”, “volume up”, “google …”. Your words are heard on your Mac, and Dottie does these before Gemini answers.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Understand everyday wording with Needle")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Toggle("", isOn: $isNeedleEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!areInstantCommandsEnabled)
            }
            Text("A small model that runs on your Mac (Cactus Needle, no internet, about a tenth of a second) catches other ways of saying these, like “pop Safari open”, “kill Zoom” or “stop the song”, plus “remind me tomorrow at 7 pm to …” and “put lunch with Sam on my calendar Friday at noon”. It only acts when your words back it up; anything else goes to Gemini. When Gemini can't be reached, it still does these on the Mac.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !needleStatusText.isEmpty {
                Text(needleStatusText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            HStack {
                Text("Hear short asks on the Mac with Whistle")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Toggle("", isOn: $isWhistleEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!areInstantCommandsEnabled || !isNeedleEnabled)
            }
            Text("Only used when Speech Recognition isn't allowed for Dottie: a short push-to-talk ask is heard on your Mac (Cactus Whistle, in English) so the instant lane still works.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Learn shortcuts from what works")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Toggle("", isOn: $isShortcutLearningEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("When Dottie gets an ask done with direct actions (a page, keys, an Apple shortcut, a script, a smart home device), saying the same words again redoes it instantly. Say “when I say focus mode, quit Slack and open Notes” to name one yourself.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(store.shortcuts.isEmpty ? "No shortcuts yet" : "\(store.shortcuts.count) saved")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button("Forget all") { store.forgetAll() }
                    .disabled(store.shortcuts.isEmpty)
                    .pointerCursor()
            }
            ForEach(store.shortcuts) { shortcut in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: shortcut.isNamedByUser ? "text.quote" : "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(shortcut.phrase)”")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                        Text(details(for: shortcut))
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(action: { store.forget(shortcut.id) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Forget this shortcut")
                    .pointerCursor()
                }
            }
        }
        .task(id: isNeedleEnabled) {
            needleStatusText = "Needle: " + (await DottieNeedleEngine.shared.statusText())
        }
    }

    private func details(for shortcut: DottieLearnedShortcut) -> String {
        var detailParts = [shortcut.steps.map(\.summary).joined(separator: ", ")]
        if shortcut.useCount > 0 { detailParts.append("used \(shortcut.useCount)×") }
        return detailParts.joined(separator: " · ")
    }
}
