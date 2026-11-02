//
//  DottieNeedleRouter.swift
//  leanring-buddy
//
//  Everything Dottie does with Needle (DottieNeedleEngine), on top of the
//  strict instant lane:
//
//    1. Loose wording: "pop safari open", "kill zoom", "stop the song",
//       "find me cat videos on youtube" become instant commands without
//       Gemini. Needle's call is only used when its confidence is high
//       enough and the user's own words back it up
//       (DottieNeedleToolset.callsToActOn); then it's turned into plain
//       command words and parsed strictly, so the app still has to be real.
//    2. Remembering: an ask Needle worked out once is saved as a learned
//       shortcut, so the same words next time skip Needle as well.
//    3. Reminders and calendar: "remind me tomorrow at 7 pm to call mom"
//       goes straight to Dottie's own add_reminder / add_calendar_event,
//       with the time read from the user's words by Apple's date detector.
//    4. When Gemini is down or busy: the same, with a slightly lower bar,
//       so Mac actions still work.
//    5. find_tool: hidden tools ranked by meaning, as a nudge on top of
//       the word match.
//    6. Whistle: hearing a short push-to-talk turn on the Mac when Speech
//       Recognition isn't allowed, so the instant lane still works.
//
//  Tried and left out (scripts/needle-lab, on a Mac): matching learned
//  shortcuts by meaning ("good morning routine" and "good night routine"
//  came out nearly the same, "open my mail" and "check my email" far
//  apart) and sorting asks into simple/complex (it never committed).
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

    /// Longer asks are rarely a single Mac action.
    private static let longestRoutedWordCount = 16
    /// Past this, Gemini's answer is better than waiting for Needle.
    private static let deadlineSeconds = 0.6

    /// Tool descriptions' vectors, by their text (centered, see
    /// DottieNeedleMeaning). A new ask's own vector isn't kept.
    private var vectorsByText: [String: [Float]] = [:]
    /// The average of DottieNeedleMeaning.referenceSentences' vectors.
    private var meaningCenter: [Float]?

    private init() {}

    var isAvailable: Bool {
        DottieNeedleEngine.isEnabled && engine.isBundled && DottieInstantLane.areInstantCommandsEnabled
    }

    /// Loads the engine and answers one ask in the background, so the
    /// first real ask doesn't pay for it (about a second, once).
    func warmUp() {
        guard isAvailable else { return }
        Task {
            _ = await engine.toolCalls(
                for: "open notes",
                toolsJSON: DottieNeedleToolset.mac.toolsJSON,
                facts: DottieNeedleToolset.systemFacts()
            )
        }
    }

    // MARK: - Planning (1 to 3)

    /// What to do with an ask the strict lane didn't recognize, or nil
    /// to ask Gemini. Never waits longer than deadlineSeconds.
    func plan(for requestText: String, geminiIsDown: Bool = false) async -> DottieInstantLane.Plan? {
        guard isAvailable else { return nil }
        let normalizedRequest = DottieInstantText.normalized(requestText)
        let requestWordCount = normalizedRequest.split(separator: " ").count
        guard (1...Self.longestRoutedWordCount).contains(requestWordCount),
              !DottieNeedleToolset.isQuestion(normalizedRequest),
              DottieInstantLane.shared.namedShortcutRequest(in: requestText) == nil else { return nil }

        return await withDeadline(seconds: Self.deadlineSeconds) {
            await self.toolCallPlan(for: normalizedRequest, geminiIsDown: geminiIsDown)
        }
    }

    private func toolCallPlan(for normalizedRequest: String, geminiIsDown: Bool) async -> DottieInstantLane.Plan? {
        if let knownPlace = await knownPlaceByMeaning(for: normalizedRequest) {
            return .instantCommands([.openPlace(url: URL(fileURLWithPath: knownPlace.path), placeName: knownPlace.displayName)])
        }
        let toolset = DottieNeedleToolset.toolset(forNormalizedRequest: normalizedRequest)
        guard let answer = await engine.toolCalls(
            for: normalizedRequest,
            toolsJSON: toolset.toolsJSON,
            facts: DottieNeedleToolset.systemFacts()
        ), let callsToActOn = DottieNeedleToolset.callsToActOn(
            answer,
            toolset: toolset,
            normalizedRequest: normalizedRequest,
            geminiIsDown: geminiIsDown
        ) else { return nil }

        switch toolset {
        case .mac, .media, .search:
            var commandTexts: [String] = []
            var instantCommands: [DottieInstantCommand] = []
            for toolCall in callsToActOn {
                guard let commandWords = DottieNeedleToolset.instantCommandWords(for: toolCall),
                      let parsedCommands = DottieInstantCommands.parseAll(commandWords) else { return nil }
                commandTexts.append(commandWords)
                instantCommands.append(contentsOf: parsedCommands)
            }
            rememberWorkedOutAsk(normalizedRequest, commandTexts: commandTexts)
            return .instantCommands(instantCommands)

        case .organizer:
            guard let organizerStep = DottieNeedleToolset.organizerStep(for: callsToActOn[0], fullRequest: normalizedRequest) else { return nil }
            return .toolSteps([DottieLearnedShortcut.Step(functionName: organizerStep.functionName, arguments: organizerStep.arguments)])
        }
    }

    /// "open the thing for my coffee shop" when a place was saved as
    /// "coffee store website": the closest known file or folder by meaning,
    /// only when it's clearly closer than the next one. Vectors of the
    /// places' names are kept, so later asks only embed the ask itself.
    private func knownPlaceByMeaning(for normalizedRequest: String) async -> DottieKnownPlaces.Place? {
        let openVerbs = ["open up ", "open ", "pull up ", "bring up ", "show me ", "go to "]
        guard let openVerb = openVerbs.first(where: { normalizedRequest.hasPrefix($0) }) else { return nil }
        let spokenTarget = DottieKnownPlaces.spokenForm(String(normalizedRequest.dropFirst(openVerb.count)))
        guard !spokenTarget.isEmpty, let askVector = await meaningVector(forKeptText: spokenTarget) else { return nil }

        var scoredPlaces: [(place: DottieKnownPlaces.Place, similarity: Float)] = []
        for place in DottieKnownPlaces.shared.recentPlaces(limit: 150) {
            var bestSimilarity: Float = -1
            for spokenName in place.spokenNames.prefix(4) {
                guard let nameVector = await meaningVector(forKeptText: spokenName) else { continue }
                bestSimilarity = max(bestSimilarity, DottieNeedleEngine.similarity(askVector, nameVector))
            }
            scoredPlaces.append((place, bestSimilarity))
        }
        scoredPlaces.sort { $0.similarity > $1.similarity }
        guard let bestMatch = scoredPlaces.first, bestMatch.similarity >= 0.8 else { return nil }
        let secondSimilarity = scoredPlaces.count > 1 ? scoredPlaces[1].similarity : -1
        guard bestMatch.similarity - secondSimilarity >= 0.05,
              FileManager.default.fileExists(atPath: bestMatch.place.path) else { return nil }
        // These words become one of its names, so next time the strict
        // lane opens it without Needle.
        DottieKnownPlaces.shared.remember(path: bestMatch.place.path, spokenName: spokenTarget)
        return bestMatch.place
    }

    /// 2. The next time these exact words come, the strict lane replays it
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
            reply: "Done: " + commandTexts.joined(separator: ", then ") + ".",
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
        "google", "search", "youtube", "look", "remind", "reminder", "calendar", "schedule", "add"
    ]

    func mightHandle(normalizedPartialText: String) -> Bool {
        guard isAvailable else { return false }
        let partialWords = normalizedPartialText.split(separator: " ").map(String.init)
        guard (1...Self.longestRoutedWordCount).contains(partialWords.count) else { return false }
        return partialWords.contains { Self.actionWords.contains($0) }
    }

    /// A centered vector for a tool description, kept.
    private func meaningVector(forKeptText text: String) async -> [Float]? {
        if let cachedVector = vectorsByText[text] { return cachedVector }
        guard let center = await meaningCenterVector(), let rawVector = await engine.embedding(for: text) else { return nil }
        let centeredVector = DottieNeedleMeaning.centered(rawVector, center: center)
        vectorsByText[text] = centeredVector
        return centeredVector
    }

    private func meaningCenterVector() async -> [Float]? {
        if let meaningCenter { return meaningCenter }
        var referenceVectors: [[Float]] = []
        for referenceSentence in DottieNeedleMeaning.referenceSentences {
            if let referenceVector = await engine.embedding(for: referenceSentence) {
                referenceVectors.append(referenceVector)
            }
        }
        meaningCenter = DottieNeedleMeaning.centerVector(of: referenceVectors)
        return meaningCenter
    }

    // MARK: - While Gemini is down (4)

    /// Gemini couldn't answer this ask (no internet, busy, quota). Returns
    /// what was done on the Mac instead, or nil when nothing fit.
    func doWhileGeminiIsDown(_ requestText: String) async -> String? {
        if let strictPlan = DottieInstantLane.shared.plan(for: requestText),
           case .done(let doneText) = await DottieInstantLane.shared.run(strictPlan) {
            return doneText
        }
        guard let needlePlan = await plan(for: requestText, geminiIsDown: true),
              case .done(let doneText) = await DottieInstantLane.shared.run(needlePlan) else { return nil }
        return doneText
    }

    // MARK: - find_tool by meaning (5)

    /// Hidden tool names in order of how close their descriptions are in
    /// meaning to what the user wants, best first, with how close (about
    /// 0.1 to 0.35 for a real match, near 0 for none).
    func hiddenToolsRankedByMeaning(for whatTheUserWants: String, amongHiddenDeclarations hiddenDeclarations: [[String: Any]]) async -> [(name: String, similarity: Float)] {
        guard DottieNeedleEngine.isEnabled, engine.isBundled else { return [] }
        let describingTextsByToolName = Self.describingTexts(of: hiddenDeclarations)
        // The first time, the tools' vectors take a second or so: they're
        // made in the background and this search goes on with words only.
        guard describingTextsByToolName.values.allSatisfy({ vectorsByText[$0] != nil }) else {
            fillToolVectorsInBackground(Array(describingTextsByToolName.values))
            return []
        }
        guard let center = meaningCenter,
              let rawQueryVector = await engine.embedding(for: whatTheUserWants.lowercased()) else { return [] }
        let queryVector = DottieNeedleMeaning.centered(rawQueryVector, center: center)
        var rankedTools: [(name: String, similarity: Float)] = []
        for (toolName, describingText) in describingTextsByToolName {
            guard let toolVector = vectorsByText[describingText] else { continue }
            rankedTools.append((toolName, DottieNeedleEngine.similarity(queryVector, toolVector)))
        }
        return rankedTools.sorted { $0.similarity > $1.similarity }
    }

    private var isFillingToolVectors = false

    private func fillToolVectorsInBackground(_ describingTexts: [String]) {
        guard !isFillingToolVectors else { return }
        isFillingToolVectors = true
        Task {
            for describingText in describingTexts {
                _ = await meaningVector(forKeptText: describingText)
            }
            isFillingToolVectors = false
        }
    }

    /// "take screenshot: Save a screenshot of …" per tool: the name and the
    /// first sentence, which says what the tool is (the rest is how to use it).
    private static func describingTexts(of hiddenDeclarations: [[String: Any]]) -> [String: String] {
        var describingTextsByToolName: [String: String] = [:]
        for declaration in hiddenDeclarations {
            guard let toolName = declaration["name"] as? String else { continue }
            let toolDescription = declaration["description"] as? String ?? ""
            describingTextsByToolName[toolName] = toolName.replacingOccurrences(of: "_", with: " ") + ": " + DottieInstantLane.firstSentence(of: toolDescription)
        }
        return describingTextsByToolName
    }

    // MARK: - Whistle (6)

    var canHearWithWhistle: Bool {
        isAvailable && engine.isWhistleBundled && DottieNeedleEngine.isWhistleEnabled
    }

    /// The words in a short push-to-talk recording (16 kHz mono PCM16),
    /// favoring the names of open apps. "" when nothing was heard.
    func hear(pcm16AudioData: Data) async -> String {
        guard canHearWithWhistle, !pcm16AudioData.isEmpty else { return "" }
        let samples: [Float] = pcm16AudioData.withUnsafeBytes { rawBytes in
            stride(from: 0, to: rawBytes.count - 1, by: 2).map { byteOffset in
                Float(Int16(littleEndian: rawBytes.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self))) / 32768
            }
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

/// One push-to-talk turn's microphone audio (16 kHz mono PCM16), kept
/// for Whistle when Apple's speech recognizer can't run. Only short turns
/// are kept: instant asks are short, and a long turn never waits for it.
final class DottieWhistleTurnRecorder: @unchecked Sendable {
    static let longestHeldTurnSeconds: Double = 6
    private static let bytesPerSecond = 32_000

    private let lock = NSLock()
    private var recordedAudio = Data()
    private var isRecordingTurn = false
    private var turnWasTooLong = false

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRecordingTurn
    }

    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return turnWasTooLong ? .infinity : Double(recordedAudio.count) / Double(Self.bytesPerSecond)
    }

    func start() {
        lock.lock()
        recordedAudio.removeAll(keepingCapacity: true)
        isRecordingTurn = true
        turnWasTooLong = false
        lock.unlock()
    }

    func stop() {
        lock.lock()
        recordedAudio.removeAll()
        isRecordingTurn = false
        lock.unlock()
    }

    /// Runs on the audio thread.
    func append(_ pcm16AudioData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecordingTurn, !turnWasTooLong else { return }
        recordedAudio.append(pcm16AudioData)
        if recordedAudio.count > Int(Self.longestHeldTurnSeconds) * Self.bytesPerSecond {
            turnWasTooLong = true
            recordedAudio.removeAll()
        }
    }

    /// The turn's audio, or nil when nothing was recorded or it ran long.
    /// Stops recording either way.
    func takeRecording() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let wasUsable = isRecordingTurn && !turnWasTooLong && !recordedAudio.isEmpty
        let takenAudio = recordedAudio
        recordedAudio = Data()
        isRecordingTurn = false
        return wasUsable ? takenAudio : nil
    }
}
