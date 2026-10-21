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
    /// The user's task broken into parts ("go to the packager", "pick up
    /// the boxes", "find the sell area", "sell them"), when it gave them.
    var taskParts: [String]
    /// Which of `taskParts` it's on, counted from 1.
    var currentTaskPartNumber: Int?

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
        taskParts = (jsonObject["task_parts"] as? [String] ?? []).filter { !$0.isEmpty }
        currentTaskPartNumber = (jsonObject["task_part_now"] as? NSNumber)?.intValue
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
    /// The plan for the user's task from earlier looks, as lines like
    /// "2. find the sell area  <- now".
    var taskPlanText: String = ""
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
    /// Why the last look got no plan, for the play log.
    private(set) var lastProblem: String?

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
        // A timed-out or busy Gemini model gets one more try on another
        // model before the look counts as failed.
        var triedGeminiModels: Set<String> = []
        for _ in 0..<2 {
            guard !Task.isCancelled else { return nil }
            let geminiModel = DottieModelPicker.shared.pick(.normal, avoiding: triedGeminiModels)
            triedGeminiModels.insert(geminiModel)
            guard let geminiReply = await thinkWithGemini(messageText: messageText, frameJPEGs: request.frameJPEGs, referencePictures: request.referencePictures, model: geminiModel) else {
                lastProblem = "\(mayUseClaude ? "Claude (MausBot) wasn't open or didn't answer, then " : "")\(geminiModel) timed out or failed"
                continue
            }
            lastEngineName = "gemini"
            guard let plan = DottieGamePlan.parse(fromReply: geminiReply) else {
                lastProblem = "\(geminiModel) answered without a plan"
                continue
            }
            lastProblem = nil
            return plan
        }
        return nil
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

    private func thinkWithGemini(messageText: String, frameJPEGs: [Data], referencePictures: [DottieGameBrainRequest.ReferencePicture], model: String) async -> String? {
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
            "model": model,
            "systemInstruction": ["parts": [["text": Self.gamerInstructions]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "thinkingConfig": ["thinkingLevel": "low"]
            ]
        ]
        return await DottieChat.send(requestBody, timeout: 30)
    }

    // MARK: - Prompts

    static func messageText(for request: DottieGameBrainRequest) -> String {
        var sections = ["Task from the user: \(request.taskText)", "Why you're asked now: \(request.event)"]
        sections.append(request.taskPlanText.isEmpty
            ? "Your plan for the task: none yet. Break the task into its parts in `task_parts`."
            : "Your plan for the task (keep it, move on when a part is done, change it when you learn better):\n" + request.taskPlanText)
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
    You play video games on the user's Mac for Dottie, their companion, like a person who just picked the game up. Dottie's hands press the keys and move the mouse; you decide what to do. You're asked now and then (on events, or every 20 seconds or so), and between your decisions Dottie carries out your steps.

    Your job is to play the game: do what the game asks of you. Follow its quests, prompts, arrows, tutorials, NPCs and objectives, the way a player would, and the user's task when they gave one. You don't invent goals. Each time you're asked, pick the next small step the game is asking for right now ("talk to the glowing NPC", "follow the arrow to the forge", "collect the stones next to you").

    A game you haven't played before (your notebook is empty or has no controls): before anything else, go through these in order, one or two each time you're asked.
    1. Read "About this game" in your notebook if it's there: it's what the game is, its goal and controls, looked up online. Use it.
    2. Learn the controls with `learn_controls`. Dottie tries the default controls first (W A S D to move, space to jump, shift+W to sprint, C to crouch), then turning the camera by holding the right mouse button and moving the mouse, then the pause menu and other common keys, and tells you what each did. Write what works into `controls`. Most games use these defaults, but any of them can be changed, so trust what you saw over the defaults.
    3. Look around with `look_around`: what's near, where the game wants you to go, what can be used.
    4. Explore close by: walk to the things that stand out (signs, NPCs, glowing things, doors, shops), read what they say, and name the places in `place`.
    5. Then play: do what the game asks, step by step.

    The user's task often has several parts ("take the boxes from the packager and sell them" = go to the packager, pick up the boxes, find the sell area, go there, sell). Write the parts in `task_parts` the first time and say which one you're on in `task_part_now`; your plan comes back to you every time. When a part is done, move to the next one yourself: don't wait to be told, and don't stop until every part is done.

    Finding things that aren't on screen (the sell area, a shop, an NPC):
    1. Check your 3D map's named places: if it's there, `go_to_place`.
    2. Otherwise `look_around`: you get the views to the right (+90°), behind (180°) and left (-90°). If you see it in one, `turn` by that many degrees, then `go_to` it on your next look.
    3. Not in any view: read signs, arrows, the minimap and quest text for where it is, and check "About this game" in your notebook. Then explore: walk to open paths, roads and signs, `look_around` again at each new spot, and name every place you pass in `place` so the map remembers it.
    4. Still lost: `search_wiki` where it is, then `ask_user`.
    When something you want is on screen but not straight ahead, `turn_to` its box turns the camera to face it exactly; guessing degrees for a plain `turn` loses things off the edge of the screen.

    While playing:
    - Look at everything: what moved between the pictures, the HUD (health, money, prompts like "Press E"), quest text, arrows and markers, the minimap. When lost, open the map (`open_map`) or read the minimap.
    - Remember what you learn in `learned` ("E opens doors", "selling gives coins"), keep ideas you haven't checked in `guesses` and move them to `tested` once checked, and say what killed you in `died_because`.
    - When something doesn't work, try something different (another key, another path, back up, jump, turn around) before trying the same thing again. If truly stuck, `search_wiki` the game, then `ask_user`.
    - Name places: whenever you're at or right next to something you could name (a sign, a shop, a machine, a portal, an NPC, a sell or collect area), and above all when your thought mentions it, put it in `place` with directions by landmarks ("past the fountain, left at the red house"). This is the only way your map learns where things are; a place you don't name can't be walked back to with `go_to_place` later. Dottie puts it on her 3D map of the game; a `go_to` with a `name` puts its target on the map once reached. When the user names where you are ("this is the shop, remember it"), put that in `place` right away.
    - To get to a place already on the map, use `go_to_place`: Dottie walks the route from the map without stopping to look, jumping over low things and going around anything in the way. Use `go_to` for things not on the map yet.
    - Set `hard` to true when the next decision is beyond quick play (a puzzle, a tricky fight, being stuck): a stronger model then takes the next look.
    - Never spend real money or in-game premium currency, and never chat with other players.
    - Now and then, put one short spoken line in `say` (what you're doing, or a reaction), like a friend playing next to the user. Leave it out most of the time.

    Boxes are [ymin, xmin, ymax, xmax] on a 0-1000 scale of the newest picture.

    Reply with one JSON object and nothing else:
    {
      "thought": "one sentence: what you see and what the game is asking of you now",
      "goal": "the small step you're taking now, shown to the user",
      "steps": [
        {"do": "go_to", "target_box": [..], "player_box": [..] (top_down only), "view": "behind" | "top_down", "sprint": false, "name": "the shop" (optional)},
        {"do": "go_to_place", "name": "the shop", "sprint": true},
        {"do": "hold", "keys": "w+space", "seconds": 0.6},
        {"do": "press", "keys": "e"},
        {"do": "click", "target_box": [..]},
        {"do": "turn", "degrees": -90},
        {"do": "turn_to", "target_box": [..]},
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
      "task_parts": ["go to the packager", "pick up the boxes", "find the sell area", "sell the boxes"], "task_part_now": 1,
      "say": null, "ask_user": null, "hard": false,
      "done": false, "answer": "what to tell the user when done"
    }
    Use one to three steps. `go_to` walks toward the thing in `target_box` and keeps it centered while moving; prefer it to counted key holds for getting somewhere. Set `done` only when the user's task is finished or they asked you to stop; playing the game has no end of its own.
    """
}

/// Gathers a streamed reply.
@MainActor
final class DottieGameReplyCollector {
    var text = ""
}
