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
//  "Watch me play" records the user's keys and a few frames for a minute
//  and turns them into lessons in the notebook instead of playing.
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
    private var brain: DottieGameBrain?
    private var hearing: DottieGameHearing?
    private var lastThoughtAloudAt: Date?

    private static let maximumBrainCalls = 120
    /// The brain looks again at least this often, even with nothing new.
    private static let secondsBetweenRoutineLooks: Double = 20
    private static let secondsBetweenThinkingAloud: Double = 25
    private static let watchSeconds: Double = 60

    /// The user said something to the game mid-play ("go left", "grab
    /// that"). Quick calls act at once; the rest reach the brain.
    func receiveUserCommand(_ commandText: String) {
        let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }
        pendingUserCommands.append(trimmedCommand)
    }

    func play(taskText: String, gameName: String, referenceImages: [DottieScreenTaskRunner.ReferenceImage] = []) async -> DottieScreenTaskRunner.Outcome {
        guard DottieScreenActionPerformer.canPostEvents else {
            return .failed(reason: "Dottie needs Accessibility access to press keys in games.")
        }
        guard let firstScreenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: DottieGameReflexes.frameDimension) else {
            return .failed(reason: "Dottie can't see the screen. Check Screen Recording access.")
        }
        Self.current = self
        let notebook = DottieGameNotebook(gameName: gameName)
        let gameMap = DottieGameMap(gameName: gameName)
        let cameraButton = gameName.lowercased().contains("roblox") ? "right" : "none"
        let reflexes = DottieGameReflexes(displayFrame: firstScreenshot.displayFrame, cameraButton: cameraButton, gameMap: gameMap)
        reflexes.reflexModel = reflexModel
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
            gameHearing.stop()
            gameBrain.stop()
            if Self.current === self {
                Self.current = nil
            }
        }

        if Self.isWatchRequest(taskText) {
            return await watchUserPlay(taskText: taskText, notebook: notebook, reflexes: reflexes, brain: gameBrain)
        }

        var recentHistory: [String] = []
        var nextEvent = notebook.contents.hasLearnedControls
            ? "Starting to play (session \(notebook.contents.sessionCount) of this game)."
            : "This game is new to you: learn its controls first (`learn_controls`, or open its controls screen), then start on the task."
        var extraNotes: [String] = []
        var extraFrameJPEGs: [Data] = []
        var failedBrainCallsInARow = 0
        let referencePictures = referenceImages.map { referenceImage in
            DottieGameBrainRequest.ReferencePicture(
                name: referenceImage.name,
                description: referenceImage.description,
                jpegData: referenceImage.jpegData
            )
        }

        for brainCallIndex in 0..<Self.maximumBrainCalls {
            guard !Task.isCancelled else { return .stopped }

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

            let request = DottieGameBrainRequest(
                taskText: taskText,
                event: nextEvent,
                frameJPEGs: frameJPEGs,
                screenText: screenText,
                dialogue: gameHearing.takeRecentDialogue(),
                notebookText: notebook.promptText(),
                recentHistory: Array(recentHistory.suffix(8)),
                recognizedPlace: recognizedPlace.map { "\($0.name) (\($0.directions))" },
                userCommands: userCommands,
                extraNotes: extraNotes,
                isWatchingUser: false,
                // The user's pictures matter most while finding the thing.
                referencePictures: brainCallIndex < 3 ? referencePictures : []
            )
            extraNotes = []
            extraFrameJPEGs = []

            guard let plan = await gameBrain.think(request) else {
                guard !Task.isCancelled else { return .stopped }
                failedBrainCallsInARow += 1
                if failedBrainCallsInARow >= 3 {
                    return .failed(reason: "Neither Claude nor Gemini answered, so Dottie stopped playing.")
                }
                nextEvent = "Your last answer didn't come through; look again."
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }
            failedBrainCallsInARow = 0
            learn(from: plan, notebook: notebook, newestFrame: newestFrame)
            if let thought = plan.thought {
                recentHistory.append("You thought: \(thought.prefix(200))")
            }
            if !plan.goal.isEmpty {
                onProgress?("🎮 \(plan.goal)")
            }
            thinkAloudIfItsBeenAWhile(plan.say)

            if plan.isDone {
                return .finished(answer: plan.answer ?? plan.goal)
            }
            if let question = plan.askUser, !question.isEmpty {
                onAskUser?(question)
                let answer = await DottieScreenJobQuestions.shared.waitForAnswer(to: question, timeoutSeconds: 180)
                guard !Task.isCancelled else { return .stopped }
                nextEvent = answer.map { "The user answered: \"\($0)\"." } ?? "The user didn't answer; carry on with your best guess."
                continue
            }

            // Play: carry out the steps until they're done or something
            // happens that the brain should see.
            nextEvent = "Your steps are done; what next?"
            let playStartedAt = Date()
            for step in plan.steps.prefix(3) {
                guard !Task.isCancelled else { return .stopped }
                let stepResult = await reflexes.perform(step, goal: plan.goal)
                recentHistory.append("\(step.kind): \(stepResult.note.prefix(200))")
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
        }
        return .finished(answer: "I played for a good while and stopped there. Say the word if you want me to keep going.")
    }

    func stop() {
        brain?.stop()
        hearing?.stop()
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

    // MARK: - Watching the user play

    static func isWatchRequest(_ taskText: String) -> Bool {
        let lowercasedTask = taskText.lowercased()
        return ["watch me", "learn from me", "watch how i", "see how i play", "learn how i play"]
            .contains { lowercasedTask.contains($0) }
    }

    /// Records the user's keys and a few frames for a minute, then has the
    /// brain write down what they did and why as lessons.
    private func watchUserPlay(taskText: String, notebook: DottieGameNotebook, reflexes: DottieGameReflexes, brain gameBrain: DottieGameBrain) async -> DottieScreenTaskRunner.Outcome {
        onProgress?("🎮 Watching you play")
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
        while Date().timeIntervalSince(watchStartedAt) < Self.watchSeconds, !Task.isCancelled {
            if let frame = await reflexes.captureFrame(), let frameJPEG = DottieGameVision.jpegData(of: frame, quality: 0.6) {
                watchedFrameJPEGs.append(frameJPEG)
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
        guard !Task.isCancelled else { return .stopped }

        let request = DottieGameBrainRequest(
            taskText: taskText,
            event: "You just watched the user play for a minute. The pictures are every few seconds, oldest first. Write down what they did and why, as lessons you can use when you play this game yourself.",
            frameJPEGs: Array(watchedFrameJPEGs.suffix(8)),
            screenText: [],
            dialogue: [],
            notebookText: notebook.promptText(),
            recentHistory: [],
            recognizedPlace: nil,
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
