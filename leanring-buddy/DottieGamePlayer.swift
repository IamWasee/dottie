//
//  DottieGamePlayer.swift
//  leanring-buddy
//
//  Plays a video game for (or with) the user like a person: think, then
//  play on autopilot. The brain (DottieGameBrain, Claude with Gemini as
//  backup) looks at a few frames, the text on screen and what the game
//  said, and sets a short goal with one to three steps. The reflexes
//  (DottieGameReflexes) carry the steps out frame by frame and come back
//  early when something happens. Everything learned goes in the game's
//  notebook (DottieGameNotebook), read at the start of every decision, so
//  the next session starts smarter.
//
//  Every game also gets a 3D map (DottieGameWorldMap), loaded when play
//  starts: a familiar game picks up where its map left off, a new one is
//  mapped automatically as Dottie plays, and places on it can be walked to
//  blind (`go_to_place`). Haiku thinks; Sonnet takes the next look only
//  when Haiku asks for it (`hard`) or keeps running into trouble.
//
//  Dottie works out which game it is from what the user asked and, before
//  the first session (and every two weeks after), looks it up online
//  (DottieGameResearch) while she starts playing, so the brain soon knows
//  what the game is about. A lookup that found nothing waits a day.
//
//  "Watch me play" records the user's keys and a few frames for a minute
//  and turns them into lessons in the notebook instead of playing.
//  "Map this game for me" maps while the user plays: their keys and mouse
//  move Dottie's place on the 3D map, and gameplay recording runs too.
//
//  Started by DottieScreenTaskRunner for game jobs; stops when the job is
//  stopped (the task is cancelled).
//

import AppKit
import Foundation

@MainActor
final class DottieGamePlayer {
    /// The game being played, so the user's quick calls reach it.
    static weak var current: DottieGamePlayer?

    /// A short line for the notch (the current goal).
    var onProgress: (@MainActor (String) -> Void)?
    /// Something to say out loud now and then, like a friend playing.
    var onThinkAloud: (@MainActor (String) -> Void)?
    /// A question only the user can answer.
    var onAskUser: (@MainActor (String) -> Void)?
    /// Where a local quick model can plug in (see DottieGameReflexModel).
    var reflexModel: DottieGameReflexModel?

    private var pendingUserCommands: [String] = []
    /// Keys the user taught by voice ("in this game F opens the shop"),
    /// tried at the next look before the brain is asked.
    private var pendingTaughtControls: [(keys: String, meaning: String)] = []
    /// The reflexes and notebook of the game being played, so Stop and
    /// taught keys reach them.
    private var currentReflexes: DottieGameReflexes?
    private var currentNotebook: DottieGameNotebook?
    /// While mapping as the user plays, taught keys are saved without
    /// trying them, since the user has the keyboard.
    private var isMappingWhileUserPlays = false
    /// Set by Stop, so every loop ends even if a step doesn't notice the
    /// task being cancelled.
    private(set) var isStopped = false
    /// The game being played, once it's been named.
    private(set) var currentGameName: String?
    private var brain: DottieGameBrain?
    /// The map of the game being played, so the user can name places by voice.
    private var currentWorldMap: DottieGameWorldMap?
    private var hearing: DottieGameHearing?
    private var lastThoughtAloudAt: Date?

    private static let maximumBrainCalls = 120
    /// A dropped network or a busy model shouldn't end play at once.
    private static let maximumFailedBrainCallsInARow = 5
    /// How often Dottie turns all the way around on her own, so the 3D map
    /// covers every direction and not just the way she walks.
    private static let secondsBetweenMappingSweeps: Double = 60
    /// The brain looks again at least this often, even with nothing new.
    private static let secondsBetweenRoutineLooks: Double = 20
    private static let secondsBetweenThinkingAloud: Double = 25
    private static let watchSeconds: Double = 60
    /// "Map this game for me" stops on its own after this long.
    private static let mapWhileUserPlaysSeconds: Double = 30 * 60

    /// The user said something to the game mid-play ("go left", "grab
    /// that"). Quick calls act at once; the rest reach the brain.
    func receiveUserCommand(_ commandText: String) {
        let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }
        // "This is the sell area": the spot she's on gets that name on the
        // map at once, without waiting for the brain to copy it over.
        if let spokenPlaceName = Self.placeName(namedIn: trimmedCommand), let currentWorldMap {
            currentWorldMap.notePlace(name: spokenPlaceName)
        }
        // "In this game F opens the egg shop": she tries F and says what
        // happened, or just writes it down while the user has the keyboard.
        if let taughtControl = Self.taughtControl(in: trimmedCommand) {
            if isMappingWhileUserPlays || currentReflexes == nil {
                currentNotebook?.teachControl(keys: taughtControl.keys, meaning: taughtControl.meaning)
                currentNotebook?.log("The user taught: \(taughtControl.keys) = \(taughtControl.meaning) (saved without trying).")
                onThinkAloud?("Got it, \(taughtControl.keys.uppercased()) \(taughtControl.meaning).")
            } else {
                pendingTaughtControls.append(taughtControl)
            }
            return
        }
        pendingUserCommands.append(trimmedCommand)
    }

    /// A key (or modifiers plus a key) as people say it.
    private static let spokenKeyPattern = #"((?:(?:shift|control|ctrl|option|alt|command|cmd)\s*(?:\+|plus|and)?\s*)*(?:f1[0-2]|f[1-9]|space\s?bar|space|tab|enter|return|escape|esc|backspace|(?:up|down|left|right)(?: arrow)?|[a-z0-9]))"#

    /// The key and what it does when a remark teaches a control, like
    /// ("f", "opens the egg shop") from "in this game F opens the egg shop"
    /// or ("shift+e", "sell everything") from "press shift E to sell
    /// everything", or nil.
    static func taughtControl(in remark: String) -> (keys: String, meaning: String)? {
        let keyPattern = spokenKeyPattern
        // The verb stays in the meaning when it says what the key does
        // ("opens the shop") and is dropped when it only links ("is for").
        let patterns: [String] = [
            #"(?i)\b(?:press|hit|use|hold|tap)\s+(?:the\s+)?"# + keyPattern + #"(?:\s+key|\s+button)?\s+(?:to|for)\s+(.+)"#,
            #"(?i)(?:^|in this game,?\s+|and\s+|also\s+|so\s+|okay,?\s+|ok,?\s+)(?:the\s+)?"# + keyPattern + #"(?:\s+key|\s+button)?\s+(?:also\s+|too\s+)?(?:is for|is to|is|does|means|=|:)\s+(.+)"#,
            #"(?i)(?:^|in this game,?\s+|and\s+|also\s+|so\s+|okay,?\s+|ok,?\s+)(?:the\s+)?"# + keyPattern + #"(?:\s+key|\s+button)?\s+(?:also\s+|too\s+)?((?:opens|open|closes|sells|buys|jumps|crouches|sprints|runs|attacks|picks|drops|throws|toggles|shows|uses|equips|interacts|lets you|makes you|will)\b.+)"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: remark, range: NSRange(remark.startIndex..., in: remark)),
                  let keyRange = Range(match.range(at: 1), in: remark),
                  let meaningRange = Range(match.range(at: 2), in: remark) else { continue }
            var meaning = String(remark[meaningRange])
            for separator in [",", ".", "!", "?", " too", " as well", " try it", " remember"] {
                if let separatorRange = meaning.range(of: separator, options: .caseInsensitive) {
                    meaning = String(meaning[..<separatorRange.lowerBound])
                }
            }
            meaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !meaning.isEmpty, meaning.count <= 80 else { continue }
            return (keys: normalizedKeys(String(remark[keyRange])), meaning: meaning)
        }
        return nil
    }

    /// "Shift E", "ctrl plus 1", "space bar" → "shift+e", "control+1", "space".
    private static func normalizedKeys(_ spokenKeys: String) -> String {
        let spellings = ["ctrl": "control", "cmd": "command", "alt": "option", "esc": "escape", "spacebar": "space", "return": "enter"]
        var keyNames = spokenKeys.lowercased()
            .replacingOccurrences(of: "space bar", with: "spacebar")
            .replacingOccurrences(of: " arrow", with: "")
            .replacingOccurrences(of: "+", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { $0 != "plus" && $0 != "and" }
        keyNames = keyNames.map { spellings[$0] ?? $0 }
        return keyNames.joined(separator: "+")
    }

    /// The place a remark names, like "the sell area" from "this is the
    /// sell area, remember it" or "remember this as the shop", or nil.
    static func placeName(namedIn remark: String) -> String? {
        let patterns = [
            #"(?i)\bremember (?:this|here)(?: place| spot)? as (.+)"#,
            #"(?i)\b(?:call|name) (?:this|here)(?: place| spot)? (.+)"#,
            #"(?i)\b(?:this|here) is called (.+)"#,
            // Only with an article, so "this is taking forever" isn't a name.
            #"(?i)\b(?:this|here) is ((?:the|a|an|my|our) .+)"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: remark, range: NSRange(remark.startIndex..., in: remark)),
                  let nameRange = Range(match.range(at: 1), in: remark) else { continue }
            var placeName = String(remark[nameRange])
            // Drop what comes after the name ("..., remember it", "so go there").
            for separator in [",", ".", "!", " remember", " so ", " and "] {
                if let separatorRange = placeName.range(of: separator, options: .caseInsensitive) {
                    placeName = String(placeName[..<separatorRange.lowerBound])
                }
            }
            placeName = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = placeName.split(separator: " ").count
            guard wordCount >= 1, wordCount <= 5 else { continue }
            return placeName
        }
        return nil
    }

    func play(taskText: String, windowGameName: String, referenceImages: [DottieScreenTaskRunner.ReferenceImage] = []) async -> DottieScreenTaskRunner.Outcome {
        guard DottieScreenActionPerformer.canPostEvents else {
            return .failed(reason: "Dottie needs Accessibility access to press keys in games.")
        }
        guard let firstScreenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: DottieGameReflexes.frameDimension) else {
            return .failed(reason: "Dottie can't see the screen. Check Screen Recording access.")
        }
        Self.current = self
        onProgress?("Working out which game this is")
        let firstScreenText = await DottieGameReflexes.readTextOffMain(firstScreenshot.image)
        let gameName = await DottieGameResearch.identifyGame(taskText: taskText, windowGameName: windowGameName, screenText: firstScreenText)
        guard !(Task.isCancelled || isStopped) else { return .stopped }
        currentGameName = gameName
        let notebook = DottieGameNotebook(gameName: gameName)
        let worldMap = DottieGameWorldMap(gameName: gameName, gameFolderURL: notebook.folderURL)
        currentWorldMap = worldMap
        currentNotebook = notebook
        notebook.createUserControlsFileIfMissing()
        let cameraButton = gameName.lowercased().contains("roblox") ? "right" : "none"
        let reflexes = DottieGameReflexes(displayFrame: firstScreenshot.displayFrame, cameraButton: cameraButton, worldMap: worldMap)
        reflexes.reflexModel = reflexModel
        currentReflexes = reflexes
        if isStopped {
            reflexes.stopEverything()
        }
        reflexes.onProgressLine = { [weak self] progressLine in
            self?.onProgress?(progressLine)
        }
        reflexes.takeUserCommand = { [weak self] in
            guard let self, !self.pendingUserCommands.isEmpty else { return nil }
            return self.pendingUserCommands.removeFirst()
        }
        let gameBrain = DottieGameBrain(notebookFolderURL: notebook.folderURL)
        brain = gameBrain
        let gameHearing = DottieGameHearing()
        hearing = gameHearing
        await gameHearing.start()
        reflexes.currentLoudness = { gameHearing.currentLoudness }
        defer {
            reflexes.releaseAllKeys()
            worldMap.save()
            gameHearing.stop()
            gameBrain.stop()
            currentWorldMap = nil
            currentReflexes = nil
            currentNotebook = nil
            if Self.current === self {
                Self.current = nil
            }
        }

        notebook.log("Session \(notebook.contents.sessionCount) started. Asked: \"\(taskText)\". Window: \(windowGameName). Game: \(gameName). Map: \(worldMap.keyframes.count) spots, \(worldMap.voxelHits.count) 3D points. Depth model: \(DottieGameDepth.shared.statusText).")
        if Self.isWatchRequest(taskText) {
            return await watchUserPlay(taskText: taskText, notebook: notebook, reflexes: reflexes, brain: gameBrain)
        }
        if Self.isMapRequest(taskText) {
            return await mapWhileUserPlays(worldMap: worldMap, reflexes: reflexes, cameraButton: cameraButton)
        }

        // The lookup runs beside play instead of before it, so the first
        // move isn't held up; the guide reaches the brain once it's written.
        var guideLookupTask: Task<Void, Never>?
        if notebook.needsGuide, !DottieGameResearch.isBarePlatformName(gameName) {
            onProgress?("Looking up \(gameName)")
            thinkAloudIfItsBeenAWhile("Let me look up \(gameName) while I start.")
            guideLookupTask = Task { @MainActor in
                let guideResult = await DottieGameResearch.writeGuide(gameName: gameName)
                guard !Task.isCancelled else { return }
                if let guide = guideResult.guide {
                    notebook.setGuide(guide)
                    notebook.log("Looked the game up online and wrote a guide (\(guide.count) characters).")
                } else {
                    notebook.noteGuideLookupFailed()
                    notebook.log("Looked the game up online but \(guideResult.problem). Trying again tomorrow.")
                }
            }
        }
        defer { guideLookupTask?.cancel() }

        var recentHistory: [String] = []
        var nextEvent = !notebook.needsControlsLearned
            ? "Starting to play (session \(notebook.contents.sessionCount) of this game)."
            : "This game is new to you: follow the steps for a new game (read what's known about it, learn_controls, look_around, explore close by), then play what the game asks."
        if worldMap.isFamiliar {
            nextEvent += " Dottie knows this game: her map has \(worldMap.keyframes.count) spots and \(worldMap.places.count) named places, so she won't map them again."
            thinkAloudIfItsBeenAWhile("I know this one, I've got it mapped.")
        } else {
            nextEvent += " Dottie hasn't mapped this game before; she maps it automatically as you play."
            thinkAloudIfItsBeenAWhile("New game for me, I'll map it as I go.")
        }
        // Haiku thinks unless it asked for help or keeps hitting trouble.
        var needsStrongerModel = false
        var troubleInARow = 0
        var extraNotes: [String] = []
        var extraFrameJPEGs: [Data] = []
        var failedBrainCallsInARow = 0
        // The brain's plan for the user's task, kept between looks so a
        // task with several parts carries on to the next part on its own.
        var taskParts: [String] = []
        var currentTaskPartNumber = 1
        let referencePictures = referenceImages.map { referenceImage in
            DottieGameBrainRequest.ReferencePicture(
                name: referenceImage.name,
                description: referenceImage.description,
                jpegData: referenceImage.jpegData
            )
        }

        // The first look around is right away: at spawn it saves what spawn
        // looks like, and on a known map it finds where she is.
        var lastMappingSweepAt = Date.distantPast
        for brainCallIndex in 0..<Self.maximumBrainCalls {
            guard !(Task.isCancelled || isStopped) else { return .stopped }

            if !worldMap.isTopDownView, Date().timeIntervalSince(lastMappingSweepAt) > Self.secondsBetweenMappingSweeps {
                lastMappingSweepAt = Date()
                onProgress?("Looking around to map this spot")
                let sweepResult = await reflexes.perform(DottieGamePlan.Step(kind: "look_around", sprint: false), goal: "")
                extraFrameJPEGs += sweepResult.extraFrameJPEGs
                extraNotes.append("Dottie just looked all the way around to map this spot: the extra pictures are the views to the right, behind and to the left.")
                notebook.log("Looked all the way around for the map (\(worldMap.keyframes.count) spots now).")
            }

            // Look: frames over about a second, the text on screen, what
            // the game said, and whether this place is a known one.
            let motionFrames = await reflexes.motionFrames()
            guard let newestFrame = motionFrames.last else {
                return .failed(reason: "Dottie lost sight of the screen.")
            }
            let screenText = await DottieGameReflexes.readTextOffMain(newestFrame)
            let recognizedPlace = notebook.recognizePlace(in: newestFrame)
            let frameJPEGs = motionFrames.compactMap { DottieGameVision.jpegData(of: $0) } + extraFrameJPEGs
            var userCommands: [String] = []
            while !pendingUserCommands.isEmpty {
                userCommands.append(pendingUserCommands.removeFirst())
            }
            while !pendingTaughtControls.isEmpty, !isStopped {
                let taughtControl = pendingTaughtControls.removeFirst()
                extraNotes.append(await tryTaughtControl(taughtControl, notebook: notebook, reflexes: reflexes))
            }

            let request = DottieGameBrainRequest(
                taskText: taskText,
                event: nextEvent,
                frameJPEGs: frameJPEGs,
                screenText: screenText,
                dialogue: gameHearing.takeRecentDialogue(),
                notebookText: notebook.promptText(),
                recentHistory: Array(recentHistory.suffix(8)),
                recognizedPlace: recognizedPlace.map { "\($0.name) (\($0.directions))" },
                mapText: worldMap.summaryText(),
                userCommands: userCommands,
                extraNotes: extraNotes,
                isWatchingUser: false,
                // The user's pictures matter most while finding the thing.
                referencePictures: brainCallIndex < 3 ? referencePictures : [],
                taskPlanText: Self.taskPlanText(parts: taskParts, currentPartNumber: currentTaskPartNumber)
            )
            extraNotes = []
            extraFrameJPEGs = []

            guard !(Task.isCancelled || isStopped) else { return .stopped }
            onProgress?("Thinking about what to do next")
            notebook.log("Asked the brain\(needsStrongerModel ? " (stronger model)" : ""): \(nextEvent)")
            guard let plan = await gameBrain.think(request, needsStrongerModel: needsStrongerModel) else {
                guard !(Task.isCancelled || isStopped) else { return .stopped }
                failedBrainCallsInARow += 1
                notebook.log("The brain didn't answer (\(failedBrainCallsInARow) in a row\(gameBrain.lastProblem.map { ": \($0)" } ?? "")).")
                if failedBrainCallsInARow >= Self.maximumFailedBrainCallsInARow {
                    return .failed(reason: "Neither Claude nor Gemini answered, so Dottie stopped playing.")
                }
                onProgress?("Waiting for my brain to answer")
                nextEvent = "Your last answer didn't come through; look again."
                // A slow or busy network gets a little longer each time.
                try? await Task.sleep(nanoseconds: UInt64(failedBrainCallsInARow) * 2_000_000_000)
                continue
            }
            failedBrainCallsInARow = 0
            notebook.log("Brain: thought \"\(plan.thought ?? "")\"; doing \"\(plan.goal)\"; steps: \(plan.steps.map(\.kind).joined(separator: ", "))\(plan.isDone ? "; says it's done" : "")")
            learn(from: plan, notebook: notebook, newestFrame: newestFrame)
            if !plan.taskParts.isEmpty {
                taskParts = Array(plan.taskParts.prefix(10))
            }
            if let partNumber = plan.currentTaskPartNumber, !taskParts.isEmpty {
                if partNumber != currentTaskPartNumber {
                    notebook.log("Task part \(min(max(partNumber, 1), taskParts.count)) of \(taskParts.count) now: \(taskParts[min(max(partNumber, 1), taskParts.count) - 1])")
                }
                currentTaskPartNumber = min(max(partNumber, 1), taskParts.count)
            }
            if let placeName = plan.placeName, !placeName.isEmpty {
                worldMap.notePlace(name: placeName)
            }
            if let thought = plan.thought {
                recentHistory.append("You thought: \(thought.prefix(200))")
            }
            if !plan.goal.isEmpty {
                onProgress?(plan.goal)
            }
            thinkAloudIfItsBeenAWhile(plan.say)

            if plan.isDone {
                return .finished(answer: plan.answer ?? plan.goal)
            }
            if let question = plan.askUser, !question.isEmpty {
                onAskUser?(question)
                let answer = await DottieScreenJobQuestions.shared.waitForAnswer(to: question, timeoutSeconds: 180)
                guard !(Task.isCancelled || isStopped) else { return .stopped }
                nextEvent = answer.map { "The user answered: \"\($0)\"." } ?? "The user didn't answer; carry on with your best guess."
                continue
            }

            // Play: carry out the steps until they're done or something
            // happens that the brain should see.
            nextEvent = "Your steps are done; what next?"
            let playStartedAt = Date()
            var hadTroubleThisRound = false
            for step in plan.steps.prefix(3) {
                guard !(Task.isCancelled || isStopped) else { return .stopped }
                let stepResult = await reflexes.perform(step, goal: plan.goal)
                if step.kind == "learn_controls" {
                    // Written straight into the notebook, so the controls
                    // don't depend on the brain copying them over.
                    if !stepResult.learnedControls.isEmpty {
                        notebook.learnControls(stepResult.learnedControls, isComplete: false)
                        notebook.markControlsRoutineDone()
                    }
                    notebook.log("  learn_controls: learned \(stepResult.learnedControls.count) controls. \(stepResult.note)")
                } else {
                    notebook.log("  \(step.kind)\(stepResult.isEvent ? " (ended for a look)" : ""): \(stepResult.note.prefix(400))")
                }
                recentHistory.append("\(step.kind): \(stepResult.note.prefix(200))")
                if Self.isTrouble(stepResult.note) {
                    hadTroubleThisRound = true
                }
                extraFrameJPEGs += stepResult.extraFrameJPEGs
                if stepResult.isEvent {
                    nextEvent = stepResult.note
                    if stepResult.note.count > 200 {
                        extraNotes.append(stepResult.note)
                    }
                    break
                }
                if Date().timeIntervalSince(playStartedAt) > Self.secondsBetweenRoutineLooks {
                    nextEvent = "A routine look: \(Int(Self.secondsBetweenRoutineLooks)) seconds since you last looked."
                    break
                }
            }
            if plan.steps.isEmpty {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            troubleInARow = hadTroubleThisRound ? troubleInARow + 1 : 0
            // Sonnet for the next look when Haiku asked, or after trouble
            // twice in a row; back to Haiku once a round goes fine.
            needsStrongerModel = plan.isHard || troubleInARow >= 2
        }
        return .finished(answer: "I played for a good while and stopped there. Say the word if you want me to keep going.")
    }

    func stop() {
        isStopped = true
        currentReflexes?.stopEverything()
        brain?.stop()
        hearing?.stop()
    }

    /// Presses a key the user taught, says out loud what happened, and
    /// saves it to the game's my-controls.txt. Returns a note for the brain.
    private func tryTaughtControl(_ taughtControl: (keys: String, meaning: String), notebook: DottieGameNotebook, reflexes: DottieGameReflexes) async -> String {
        onProgress?("Trying \(taughtControl.keys.uppercased()) like you said")
        let whatHappened = await reflexes.tryTaughtKey(taughtControl.keys)
        // What the user says is kept whatever the screen showed: a key can
        // need the right spot (a shop counter) to do anything.
        notebook.teachControl(keys: taughtControl.keys, meaning: taughtControl.meaning)
        notebook.log("The user taught: \(taughtControl.keys) = \(taughtControl.meaning). Tried it: \(whatHappened).")
        let spokenKeys = taughtControl.keys.uppercased()
        if whatHappened.hasPrefix("it opened") || whatHappened.hasPrefix("something changed") {
            onThinkAloud?("Okay, got it. \(spokenKeys) \(taughtControl.meaning).")
        } else {
            onThinkAloud?("I pressed \(spokenKeys) and nothing happened here, but I've saved it. I'll use it when it fits.")
        }
        lastThoughtAloudAt = Date()
        return "The user taught you a control: \(taughtControl.keys) = \(taughtControl.meaning). Dottie pressed it once to check: \(whatHappened). It's saved in the notebook; use it when it fits."
    }

    /// The task's parts as numbered lines, marking done ones and the one
    /// being worked on, for the brain.
    private static func taskPlanText(parts taskParts: [String], currentPartNumber: Int) -> String {
        taskParts.enumerated().map { partIndex, partText in
            let partNumber = partIndex + 1
            let partState = partNumber < currentPartNumber ? " (done)" : partNumber == currentPartNumber ? "  <- now" : ""
            return "\(partNumber). \(partText)\(partState)"
        }.joined(separator: "\n")
    }

    /// A step result that means the plan isn't working.
    private static func isTrouble(_ stepNote: String) -> Bool {
        let lowercasedNote = stepNote.lowercased()
        return ["stuck", "lost sight", "didn't reach", "no way to", "couldn't"].contains { lowercasedNote.contains($0) }
    }

    // MARK: - Learning

    private func learn(from plan: DottieGamePlan, notebook: DottieGameNotebook, newestFrame: CGImage?) {
        if let genre = plan.genre {
            notebook.setGenre(genre)
        }
        if !plan.controls.isEmpty || plan.controlsComplete {
            notebook.learnControls(plan.controls, isComplete: plan.controlsComplete)
        }
        if !plan.facts.isEmpty || !plan.guesses.isEmpty || !plan.testedGuesses.isEmpty || plan.death != nil {
            notebook.add(facts: plan.facts, guesses: plan.guesses, testedGuesses: plan.testedGuesses, death: plan.death)
        }
        if let placeName = plan.placeName, !placeName.isEmpty, let newestFrame {
            notebook.notePlace(name: placeName, directions: plan.placeDirections ?? "", view: newestFrame)
        }
    }

    private func thinkAloudIfItsBeenAWhile(_ line: String?) {
        guard let line, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let lastThoughtAloudAt, Date().timeIntervalSince(lastThoughtAloudAt) < Self.secondsBetweenThinkingAloud {
            return
        }
        lastThoughtAloudAt = Date()
        onThinkAloud?(line)
    }

    // MARK: - Mapping while the user plays

    static func isMapRequest(_ taskText: String) -> Bool {
        let lowercasedTask = taskText.lowercased()
        return ["map this", "map the game", "map it", "map my game", "map while i play", "map as i play", "make a map", "build a map"]
            .contains { lowercasedTask.contains($0) }
    }

    /// The user plays; Dottie follows along on the 3D map with their keys
    /// and mouse and maps every new spot. Gameplay recording runs too
    /// (unless it already was). Ends when the user says they're done
    /// ("done", "stop mapping"), stops the job, or after half an hour.
    private func mapWhileUserPlays(worldMap: DottieGameWorldMap, reflexes: DottieGameReflexes, cameraButton: String) async -> DottieScreenTaskRunner.Outcome {
        onProgress?("Mapping while you play")
        isMappingWhileUserPlays = true
        defer { isMappingWhileUserPlays = false }
        thinkAloudIfItsBeenAWhile(worldMap.isFamiliar ? "Go ahead, I'll add to my map as you play." : "Go ahead and play, I'll map as you go.")
        let gameplayRecorder = DottieGameplayRecorder.shared
        let didStartRecording = !gameplayRecorder.isRecording
        if didStartRecording {
            await gameplayRecorder.startRecording()
        }
        let inputWatcher = DottieGameMapInputWatcher(cameraButton: cameraButton)
        defer {
            inputWatcher.stop()
            if didStartRecording, gameplayRecorder.isRecording {
                gameplayRecorder.stopRecording()
            }
        }

        // Frames go to the map below, after the turn they show is noted.
        let wasMapFeedingPaused = reflexes.isMapFeedingPaused
        reflexes.isMapFeedingPaused = true
        defer { reflexes.isMapFeedingPaused = wasMapFeedingPaused }

        let spotsBefore = worldMap.keyframes.count
        let mappingStartedAt = Date()
        var lastMovementNotedAt = mappingStartedAt
        var lastProgressShownAt = Date.distantPast
        var finishedByUser = false
        var previousFrame: CGImage?
        var turnsSeenOnlyInThePicture = 0
        var turnsFromTheMouse = 0
        while !(Task.isCancelled || isStopped), Date().timeIntervalSince(mappingStartedAt) < Self.mapWhileUserPlaysSeconds {
            try? await Task.sleep(nanoseconds: 250_000_000)
            // The user's own input moves Dottie's place on the map.
            let userInput = inputWatcher.takeInput()
            if abs(userInput.cameraMousePoints) >= 1 {
                worldMap.noteCameraTurn(degrees: userInput.cameraMousePoints * worldMap.movement.degreesPerMousePoint)
                turnsFromTheMouse += 1
            }
            worldMap.noteMovement(heldKeys: userInput.heldKeys, seconds: Date().timeIntervalSince(lastMovementNotedAt))
            lastMovementNotedAt = Date()
            guard let frame = await reflexes.captureFrame() else { continue }
            // Some games (Roblox while right-click turns the camera) hide
            // the mouse's movement from Dottie, so a turn the mouse didn't
            // report is read from the picture: the horizon sliding sideways.
            // Not while strafing, which slides the picture too.
            let isStrafing = userInput.heldKeys.contains("a") || userInput.heldKeys.contains("d")
            if abs(userInput.cameraMousePoints) < 1, !isStrafing, let previousFrame {
                let shiftFraction = DottieGameMovement.horizontalShiftFraction(from: previousFrame, to: frame)
                if let shiftFraction, abs(shiftFraction) > 0.02 {
                    // Turning right slides the scene left.
                    worldMap.noteCameraTurn(degrees: -shiftFraction * worldMap.movement.horizontalFieldOfViewDegrees)
                    turnsSeenOnlyInThePicture += 1
                }
            }
            previousFrame = frame
            reflexes.letMapSee(frame)
            if pendingUserCommands.contains(where: { command in
                let lowercasedCommand = command.lowercased()
                return ["done", "stop", "finish", "that's it", "thats it", "enough"].contains { lowercasedCommand.contains($0) }
            }) {
                pendingUserCommands.removeAll()
                finishedByUser = true
                break
            }
            pendingUserCommands.removeAll()
            if Date().timeIntervalSince(lastProgressShownAt) > 3 {
                onProgress?("Mapping while you play: \(worldMap.keyframes.count - spotsBefore) new spots")
                lastProgressShownAt = Date()
            }
        }
        guard finishedByUser || !(Task.isCancelled || isStopped) else { return .stopped }
        DottieGameNotebook.appendToPlayLog("Mapping while the user played: \(turnsFromTheMouse) camera turns from the mouse, \(turnsSeenOnlyInThePicture) seen only in the picture.", gameFolderURL: worldMap.mapFolderURL.deletingLastPathComponent())
        worldMap.save()
        let newSpotCount = worldMap.keyframes.count - spotsBefore
        return .finished(answer: "I mapped \(newSpotCount) new spots of \(worldMap.gameName) while you played (\(worldMap.keyframes.count) in all). The picture of the map is in the Game maps folder.")
    }

    // MARK: - Watching the user play

    static func isWatchRequest(_ taskText: String) -> Bool {
        let lowercasedTask = taskText.lowercased()
        return ["watch me", "learn from me", "watch how i", "see how i play", "learn how i play"]
            .contains { lowercasedTask.contains($0) }
    }

    /// Records the user's keys and a few frames for a minute, then has the
    /// brain write down what they did and why as lessons.
    private func watchUserPlay(taskText: String, notebook: DottieGameNotebook, reflexes: DottieGameReflexes, brain gameBrain: DottieGameBrain) async -> DottieScreenTaskRunner.Outcome {
        onProgress?("Watching you play")
        // The user's moves aren't tracked here, so the map would place
        // these views wrongly.
        reflexes.isMapFeedingPaused = true
        let watchStartedAt = Date()
        var keyLog: [String] = []
        var keyDownTimes: [String: Date] = [:]
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { event in
            let secondsIn = String(format: "%.1f", Date().timeIntervalSince(watchStartedAt))
            switch event.type {
            case .keyDown where !event.isARepeat:
                let keyName = event.charactersIgnoringModifiers?.lowercased() ?? "key \(event.keyCode)"
                keyDownTimes[keyName] = Date()
            case .keyUp:
                let keyName = event.charactersIgnoringModifiers?.lowercased() ?? "key \(event.keyCode)"
                if let downAt = keyDownTimes.removeValue(forKey: keyName) {
                    keyLog.append("\(secondsIn)s: held \(keyName == " " ? "space" : keyName) for \(String(format: "%.1f", Date().timeIntervalSince(downAt)))s")
                }
            case .leftMouseDown:
                keyLog.append("\(secondsIn)s: left click")
            case .rightMouseDown:
                keyLog.append("\(secondsIn)s: right click")
            default:
                break
            }
        }
        defer {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }

        var watchedFrameJPEGs: [Data] = []
        while Date().timeIntervalSince(watchStartedAt) < Self.watchSeconds, !(Task.isCancelled || isStopped) {
            if let frame = await reflexes.captureFrame(), let frameJPEG = DottieGameVision.jpegData(of: frame, quality: 0.6) {
                watchedFrameJPEGs.append(frameJPEG)
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
        guard !(Task.isCancelled || isStopped) else { return .stopped }

        let request = DottieGameBrainRequest(
            taskText: taskText,
            event: "You just watched the user play for a minute. The pictures are every few seconds, oldest first. Write down what they did and why, as lessons you can use when you play this game yourself.",
            frameJPEGs: Array(watchedFrameJPEGs.suffix(8)),
            screenText: [],
            dialogue: [],
            notebookText: notebook.promptText(),
            recentHistory: [],
            recognizedPlace: nil,
            mapText: "",
            userCommands: [],
            extraNotes: ["Their keys and clicks:\n" + keyLog.suffix(120).joined(separator: "\n")],
            isWatchingUser: true,
            referencePictures: []
        )
        guard let plan = await gameBrain.think(request) else {
            return .failed(reason: "I watched, but couldn't write down what I learned.")
        }
        learn(from: plan, notebook: notebook, newestFrame: reflexes.recentFrames.last?.image)
        notebook.addLessonsFromWatching(plan.lessons)
        let lessonSummary = plan.lessons.prefix(3).joined(separator: "; ")
        return .finished(answer: lessonSummary.isEmpty ? "I watched you play and took notes." : "I watched you play and learned: \(lessonSummary).")
    }
}

/// While the user plays and Dottie maps ("map this game for me"): the keys
/// they hold and how far they turned the camera with the mouse.
@MainActor
final class DottieGameMapInputWatcher {
    private var heldKeys: Set<String> = []
    private var cameraMousePointsSinceLastTake = 0.0
    private var eventMonitor: Any?
    /// "right" when the camera only turns while the right button is held
    /// (Roblox); otherwise every mouse movement turns it.
    private let cameraButton: String

    init(cameraButton: String) {
        self.cameraButton = cameraButton
        let watchedEventTypes: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Global monitors call back on the main thread.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: watchedEventTypes) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    func takeInput() -> (heldKeys: Set<String>, cameraMousePoints: Double) {
        let takenMousePoints = cameraMousePointsSinceLastTake
        cameraMousePointsSinceLastTake = 0
        return (heldKeys, takenMousePoints)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard !event.isARepeat else { return }
            heldKeys.insert(Self.keyName(for: event))
        case .keyUp:
            heldKeys.remove(Self.keyName(for: event))
        case .flagsChanged:
            if event.modifierFlags.contains(.shift) {
                heldKeys.insert("shift")
            } else {
                heldKeys.remove("shift")
            }
        case .rightMouseDragged:
            cameraMousePointsSinceLastTake += Double(event.deltaX)
        case .mouseMoved, .leftMouseDragged, .otherMouseDragged:
            if cameraButton != "right" {
                cameraMousePointsSinceLastTake += Double(event.deltaX)
            }
        default:
            break
        }
    }

    /// The names DottieGameWorldMap.noteMovement reads (w/a/s/d, arrows).
    private static func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return event.charactersIgnoringModifiers?.lowercased() ?? "key \(event.keyCode)"
        }
    }
}
