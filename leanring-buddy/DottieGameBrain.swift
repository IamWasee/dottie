//
//  DottieGameBrain.swift
//  leanring-buddy
//
//  The slow half of the game player: it looks at the game, decides what to
//  do next and why, and writes down what it learns. It runs only on events
//  (a new area, dialogue, a death, being stuck, a goal reached, the user
//  saying something) or every so often, and the fast half
//  (DottieGameReflexes) plays toward its goal in between, so the brain is
//  asked a handful of times a minute instead of every frame.
//
//  It thinks with Claude through a MausBot bot of its own ("Dottie Gamer",
//  on the newest Haiku at medium effort). MausBot takes text, so the frames
//  are saved as pictures in the bot's folder and the bot opens them. When
//  Claude isn't set up or doesn't answer in time, Gemini thinks instead,
//  with the pictures inline.
//

import Foundation

/// What the brain decided.
struct DottieGamePlan {
    struct Step {
        /// go_to, hold, press, click, turn, look_around, wait, open_map,
        /// search_wiki, learn_controls, type.
        var kind: String
        var targetBox: [Double]?
        var playerBox: [Double]?
        /// "behind" (third or first person) or "top_down".
        var view: String?
        var keys: String?
        var seconds: Double?
        var degrees: Double?
        var text: String?
        var sprint: Bool
    }

    var thought: String?
    var say: String?
    var goal: String
    var steps: [Step]
    var genre: String?
    var controls: [String: String]
    var controlsComplete: Bool
    var facts: [String]
    var guesses: [String]
    var testedGuesses: [String]
    var death: String?
    var placeName: String?
    var placeDirections: String?
    var askUser: String?
    var isDone: Bool
    var answer: String?
    var lessons: [String]
    /// The brain says the next decision needs the stronger model.
    var isHard: Bool

    init?(jsonObject: [String: Any]) {
        let stepObjects = jsonObject["steps"] as? [[String: Any]] ?? []
        steps = stepObjects.compactMap { stepObject in
            guard let kind = (stepObject["do"] as? String) ?? (stepObject["kind"] as? String) else { return nil }
            return Step(
                kind: kind.lowercased(),
                targetBox: Self.box(stepObject["target_box"]),
                playerBox: Self.box(stepObject["player_box"]),
                view: stepObject["view"] as? String,
                keys: stepObject["keys"] as? String,
                seconds: (stepObject["seconds"] as? NSNumber)?.doubleValue,
                degrees: (stepObject["degrees"] as? NSNumber)?.doubleValue,
                text: (stepObject["text"] as? String) ?? (stepObject["query"] as? String) ?? (stepObject["name"] as? String),
                sprint: (stepObject["sprint"] as? Bool) ?? false
            )
        }
        goal = (jsonObject["goal"] as? String) ?? ""
        isDone = (jsonObject["done"] as? Bool) ?? false
        guard !goal.isEmpty || !steps.isEmpty || isDone else { return nil }
        thought = jsonObject["thought"] as? String
        say = jsonObject["say"] as? String
        genre = jsonObject["genre"] as? String
        controls = (jsonObject["controls"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        controlsComplete = (jsonObject["controls_complete"] as? Bool) ?? false
        facts = jsonObject["learned"] as? [String] ?? []
        guesses = jsonObject["guesses"] as? [String] ?? []
        testedGuesses = jsonObject["tested"] as? [String] ?? []
        death = jsonObject["died_because"] as? String
        if let placeObject = jsonObject["place"] as? [String: Any] {
            placeName = placeObject["name"] as? String
            placeDirections = placeObject["directions"] as? String
        }
        askUser = jsonObject["ask_user"] as? String
        answer = jsonObject["answer"] as? String
        lessons = jsonObject["lessons"] as? [String] ?? []
        isHard = (jsonObject["hard"] as? Bool) ?? false
    }

    private static func box(_ value: Any?) -> [Double]? {
        guard let numbers = value as? [NSNumber], numbers.count == 4 else { return nil }
        return numbers.map(\.doubleValue)
    }

    /// The first JSON object in a reply (Claude may wrap it in a code block).
    static func parse(fromReply replyText: String) -> DottieGamePlan? {
        guard let openingBraceIndex = replyText.firstIndex(of: "{"),
              let closingBraceIndex = replyText.lastIndex(of: "}"),
              openingBraceIndex < closingBraceIndex else { return nil }
        let jsonText = String(replyText[openingBraceIndex...closingBraceIndex])
        guard let jsonData = jsonText.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
        return DottieGamePlan(jsonObject: jsonObject)
    }
}

/// Everything the brain gets for one decision.
struct DottieGameBrainRequest {
    let taskText: String
    /// Why it's being asked now ("new area", "stuck", "goal reached", …).
    let event: String
    /// Oldest first; the last one is now. Over about a second, so motion
    /// shows.
    let frameJPEGs: [Data]
    let screenText: [String]
    let dialogue: [String]
    let notebookText: String
    let recentHistory: [String]
    let recognizedPlace: String?
    /// The 3D map's summary: what's mapped, known places and how to get there.
    let mapText: String
    let userCommands: [String]
    let extraNotes: [String]
    let isWatchingUser: Bool
    /// Pictures the user shared ("grab that sword"), by name.
    struct ReferencePicture {
        let name: String
        let description: String
        let jpegData: Data
    }
    let referencePictures: [ReferencePicture]
}

@MainActor
final class DottieGameBrain {
    private let notebookFolderURL: URL
    private let mausBotRuntime = DottieMausBotRuntime()
    /// Haiku plays; Sonnet takes over only when Haiku is stuck. Each has
    /// its own MausBot bot, so switching never rewrites the other.
    private struct ClaudeTier {
        let modelKeyword: String
        let helperName: String
        /// A fixed id for this bot's turns in the MausBot runtime.
        let agentID: UUID
        let defaultsKeySuffix: String
    }
    private static let everydayTier = ClaudeTier(
        modelKeyword: "haiku",
        helperName: "Dottie Gamer",
        agentID: UUID(uuidString: "6A3E9F1C-4B2D-4E8A-9C7F-1D2E3F4A5B6C") ?? UUID(),
        defaultsKeySuffix: ""
    )
    private static let strongerTier = ClaudeTier(
        modelKeyword: "sonnet",
        helperName: "Dottie Gamer (Sonnet)",
        agentID: UUID(uuidString: "7B4F0A2D-5C3E-4F9B-8D1A-2E3F4A5B6C7D") ?? UUID(),
        defaultsKeySuffix: "Sonnet"
    )
    private var claudeThreadIDByAgentID: [UUID: String] = [:]
    private var callsInCurrentThreadByAgentID: [UUID: Int] = [:]
    /// Each call's pictures stay in the thread, so it starts over often.
    private static let callsPerClaudeThread = 4
    private static let claudeAnswerTimeoutSeconds: Double = 45
    /// Claude failed or was too slow: Gemini thinks until this time.
    private var claudeSkippedUntil: Date?
    private(set) var lastEngineName = "claude"

    private static let gamerBotIDDefaultsKey = "dottieGamerBotID"
    private static let gamerBotNameDefaultsKey = "dottieGamerBotName"
    private static let gamerBotSpecHashDefaultsKey = "dottieGamerBotSpecHash"

    init(notebookFolderURL: URL) {
        self.notebookFolderURL = notebookFolderURL
    }

    func stop() {
        mausBotRuntime.stopTurn(agentID: Self.everydayTier.agentID)
        mausBotRuntime.stopTurn(agentID: Self.strongerTier.agentID)
    }

    /// Asks for the next plan. nil when neither engine answered. With
    /// `needsStrongerModel`, Sonnet thinks instead of Haiku.
    func think(_ request: DottieGameBrainRequest, needsStrongerModel: Bool = false) async -> DottieGamePlan? {
        let messageText = Self.messageText(for: request)
        let mayUseClaude = claudeSkippedUntil.map { $0 < Date() } ?? true
        let claudeTier = needsStrongerModel ? Self.strongerTier : Self.everydayTier
        if mayUseClaude, let claudeReply = await thinkWithClaude(messageText: messageText, frameJPEGs: request.frameJPEGs, referencePictures: request.referencePictures, claudeTier: claudeTier) {
            if let plan = DottieGamePlan.parse(fromReply: claudeReply) {
                lastEngineName = "claude \(claudeTier.modelKeyword)"
                return plan
            }
            print("⚠️ Game brain: Claude's reply had no plan: \(claudeReply.prefix(300))")
        }
        guard !Task.isCancelled else { return nil }
        guard let geminiReply = await thinkWithGemini(messageText: messageText, frameJPEGs: request.frameJPEGs, referencePictures: request.referencePictures) else { return nil }
        lastEngineName = "gemini"
        return DottieGamePlan.parse(fromReply: geminiReply)
    }

    // MARK: - Claude

    private func thinkWithClaude(messageText: String, frameJPEGs: [Data], referencePictures: [DottieGameBrainRequest.ReferencePicture], claudeTier: ClaudeTier) async -> String? {
        guard case .ready(let launcher) = await DottieMausBot.shared.readinessForHelperTurn() else { return nil }
        let framesFolderURL = notebookFolderURL.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesFolderURL, withIntermediateDirectories: true)
        var framePaths: [String] = []
        for (frameIndex, frameJPEG) in frameJPEGs.enumerated() {
            let frameName = frameIndex == frameJPEGs.count - 1 ? "now.jpg" : "before-\(frameJPEGs.count - 1 - frameIndex).jpg"
            let frameURL = framesFolderURL.appendingPathComponent(frameName)
            if (try? frameJPEG.write(to: frameURL, options: .atomic)) != nil {
                framePaths.append(frameURL.path)
            }
        }
        var pictureInstruction = framePaths.isEmpty
            ? ""
            : "Open these pictures of the game first (oldest to newest, about a third of a second apart, so you can see what moves): "
                + framePaths.map { "`\($0)`" }.joined(separator: ", ") + ".\n\n"
        for (pictureIndex, referencePicture) in referencePictures.enumerated() {
            let pictureURL = framesFolderURL.appendingPathComponent("reference-\(pictureIndex + 1).jpg")
            guard (try? referencePicture.jpegData.write(to: pictureURL, options: .atomic)) != nil else { continue }
            pictureInstruction += "The user's picture \"\(referencePicture.name)\"\(referencePicture.description.isEmpty ? "" : " (\(referencePicture.description))") is `\(pictureURL.path)`: when the task mentions it, find that thing in the game by its look.\n"
        }
        if !referencePictures.isEmpty {
            pictureInstruction += "\n"
        }

        let gameModelSelection = await DottieMausBot.shared.modelSelection(matching: claudeTier.modelKeyword, launcher: launcher)
        let defaults = UserDefaults.standard
        let botIDDefaultsKey = Self.gamerBotIDDefaultsKey + claudeTier.defaultsKeySuffix
        let botNameDefaultsKey = Self.gamerBotNameDefaultsKey + claudeTier.defaultsKeySuffix
        let specHashDefaultsKey = Self.gamerBotSpecHashDefaultsKey + claudeTier.defaultsKeySuffix
        let spec = DottieMausBotSpec(
            helperName: claudeTier.helperName,
            title: "Plays games with Dottie",
            instructions: Self.gamerInstructions,
            workspacePath: notebookFolderURL.deletingLastPathComponent().path,
            skillFiles: [],
            effort: "medium",
            knownBotID: defaults.string(forKey: botIDDefaultsKey),
            knownBotName: defaults.string(forKey: botNameDefaultsKey),
            knownSpecHash: defaults.string(forKey: specHashDefaultsKey),
            model: gameModelSelection
        )
        let identity: DottieMausBotIdentity
        switch await mausBotRuntime.ensureBot(for: spec, launcher: launcher) {
        case .failure:
            skipClaudeForAWhile()
            return nil
        case .success(let readyIdentity):
            identity = readyIdentity
        }
        defaults.set(identity.botID, forKey: botIDDefaultsKey)
        defaults.set(identity.botName, forKey: botNameDefaultsKey)
        defaults.set(identity.specHash, forKey: specHashDefaultsKey)

        let gamerAgentID = claudeTier.agentID
        if (callsInCurrentThreadByAgentID[gamerAgentID] ?? 0) >= Self.callsPerClaudeThread {
            claudeThreadIDByAgentID[gamerAgentID] = nil
            callsInCurrentThreadByAgentID[gamerAgentID] = 0
        }
        callsInCurrentThreadByAgentID[gamerAgentID, default: 0] += 1

        // A box rather than a captured var: the event handler is a
        // main-actor closure that may count as Sendable.
        let replyCollector = DottieGameReplyCollector()
        let runtime = mausBotRuntime
        // A game can't wait long for a decision; the backup thinks instead.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.claudeAnswerTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            runtime.stopTurn(agentID: gamerAgentID)
        }
        let claudeStartedAt = Date()
        let outcome = await mausBotRuntime.runTurn(
            agentID: gamerAgentID,
            botID: identity.botID,
            message: pictureInstruction + messageText,
            conversation: claudeThreadIDByAgentID[gamerAgentID] ?? "new",
            launcher: launcher,
            onConversationStarted: { [weak self] threadID in
                self?.claudeThreadIDByAgentID[gamerAgentID] = threadID
            }
        ) { event in
            if case .assistantTextDelta(let textDelta) = event {
                replyCollector.text += textDelta
            }
        }
        timeoutTask.cancel()
        let replyText = replyCollector.text
        DottieUsage.shared.record(area: .screenTasks, inputTokens: 0, outputTokens: 0, seconds: Date().timeIntervalSince(claudeStartedAt))

        switch outcome {
        case .finished(let succeeded, _) where succeeded:
            return replyText.isEmpty ? nil : replyText
        case .stopped:
            // Too slow this time; Claude gets another go on the next call.
            claudeThreadIDByAgentID[gamerAgentID] = nil
            return replyText.contains("}") ? replyText : nil
        default:
            skipClaudeForAWhile()
            return nil
        }
    }

    private func skipClaudeForAWhile() {
        claudeSkippedUntil = Date().addingTimeInterval(120)
        claudeThreadIDByAgentID = [:]
    }

    // MARK: - Gemini

    private func thinkWithGemini(messageText: String, frameJPEGs: [Data], referencePictures: [DottieGameBrainRequest.ReferencePicture]) async -> String? {
        var parts: [[String: Any]] = []
        for referencePicture in referencePictures {
            parts.append(["text": "The user's picture \"\(referencePicture.name)\"\(referencePicture.description.isEmpty ? "" : " (\(referencePicture.description))"); when the task mentions it, find that thing in the game by its look:"])
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": referencePicture.jpegData.base64EncodedString()]])
        }
        for (frameIndex, frameJPEG) in frameJPEGs.enumerated() {
            let label = frameIndex == frameJPEGs.count - 1 ? "Now:" : "\(frameJPEGs.count - 1 - frameIndex) frame(s) earlier:"
            parts.append(["text": label])
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": frameJPEG.base64EncodedString()]])
        }
        parts.append(["text": messageText])
        let requestBody: [String: Any] = [
            "model": DottieModelPicker.shared.pick(.normal),
            "systemInstruction": ["parts": [["text": Self.gamerInstructions]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]
        return await DottieChat.send(requestBody, timeout: 40)
    }

    // MARK: - Prompts

    static func messageText(for request: DottieGameBrainRequest) -> String {
        var sections = ["Task from the user: \(request.taskText)", "Why you're asked now: \(request.event)"]
        if !request.userCommands.isEmpty {
            sections.append("The user just said: " + request.userCommands.map { "\"\($0)\"" }.joined(separator: ", ") + ". Do what they say.")
        }
        if let recognizedPlace = request.recognizedPlace {
            sections.append("You've been here before: this looks like \(recognizedPlace).")
        }
        if !request.mapText.isEmpty {
            sections.append(request.mapText)
        }
        if !request.screenText.isEmpty {
            sections.append("Text on screen now: " + request.screenText.joined(separator: " | "))
        }
        if !request.dialogue.isEmpty {
            sections.append("Heard in the game: " + request.dialogue.joined(separator: " | "))
        }
        if !request.recentHistory.isEmpty {
            sections.append("What happened lately (oldest first):\n- " + request.recentHistory.joined(separator: "\n- "))
        }
        if !request.extraNotes.isEmpty {
            sections.append(request.extraNotes.joined(separator: "\n\n"))
        }
        sections.append("Your notebook for this game:\n" + request.notebookText)
        sections.append(request.isWatchingUser
            ? "Reply with only the JSON object, with `lessons` filled in and `goal` set to \"watched\"."
            : "Reply with only the JSON object.")
        return sections.joined(separator: "\n\n")
    }

    static let gamerInstructions = """
    You play video games on the user's Mac for Dottie, their companion, like a person who's new to the game but learns fast. Dottie's hands press the keys and move the mouse for you; you decide what to do. You're asked only now and then (on events, or every 20 seconds or so), and between your decisions Dottie keeps playing toward the goal you set, steering toward your target as she moves.

    How to play like a person:
    - Look first: what's on screen, what moved between the pictures, the HUD (health, ammo, prompts like "Press E"), the minimap. When lost, open the map (step `open_map`) or read the minimap.
    - On a new game, learn the controls before anything else: open the controls or settings screen if there is one (step `learn_controls`, or `press` escape and read the menus), then write them down in `controls`. If there's no such screen, try the usual keys once each and watch what happens.
    - Set a short, concrete goal you can see ("walk to the red door on the right", "jump onto the next platform"), not the whole task. Say why in `thought`.
    - Remember what you learn in `learned` ("E opens doors", "red barrels explode"), keep ideas you haven't checked in `guesses`, move them to `tested` once checked, and say what killed you in `died_because`.
    - When stuck, try something different (back up, jump, turn around, another path) before the same thing again. If truly stuck, `search_wiki` the game's wiki, or ask the user with `ask_user`.
    - When you reach a place worth knowing, name it in `place` with directions by landmarks ("past the fountain, left at the red house"). Dottie also puts it on her 3D map of the game, built from what she sees as you play; give a `go_to` a `name` and the target goes on the map once reached.
    - To get to a place already on the map, use `go_to_place`: Dottie walks the route from the map without stopping to look, which is fast and saves your time. Use `go_to` for things the map doesn't have yet.
    - Set `hard` to true when the next decision is beyond quick play (a puzzle, a tricky fight, being stuck): a stronger model then takes the next look.
    - Never spend real money or in-game premium currency, and never chat with other players.
    - Now and then, put one short spoken line in `say` (what you're trying, or a reaction), like a friend playing next to the user. Leave it out most of the time.

    Boxes are [ymin, xmin, ymax, xmax] on a 0-1000 scale of the newest picture.

    Reply with one JSON object and nothing else:
    {
      "thought": "one sentence: what you see and why this goal",
      "goal": "short concrete goal",
      "steps": [
        {"do": "go_to", "target_box": [..], "player_box": [..] (top_down only), "view": "behind" | "top_down", "sprint": false, "name": "the shop" (optional)},
        {"do": "go_to_place", "name": "the shop", "sprint": true},
        {"do": "hold", "keys": "w+space", "seconds": 0.6},
        {"do": "press", "keys": "e"},
        {"do": "click", "target_box": [..]},
        {"do": "turn", "degrees": -90},
        {"do": "look_around"},
        {"do": "wait", "seconds": 2},
        {"do": "open_map", "keys": "m"},
        {"do": "search_wiki", "text": "game name how to get past the drawbridge"},
        {"do": "learn_controls"},
        {"do": "type", "text": "..."}
      ],
      "genre": "shooter | rpg | platformer | roblox obby | racing | puzzle | strategy | sandbox" (first time only),
      "controls": {"e": "interact"}, "controls_complete": false,
      "learned": [], "guesses": [], "tested": [], "died_because": null,
      "place": {"name": "...", "directions": "..."} or null,
      "say": null, "ask_user": null, "hard": false,
      "done": false, "answer": "what to tell the user when done"
    }
    Use one to three steps. `go_to` walks toward the thing in `target_box` and keeps it centered while moving; prefer it to counted key holds for getting somewhere.
    """
}

/// Gathers a streamed reply.
@MainActor
final class DottieGameReplyCollector {
    var text = ""
}
