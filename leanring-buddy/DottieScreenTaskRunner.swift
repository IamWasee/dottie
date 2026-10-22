//
//  DottieScreenTaskRunner.swift
//  leanring-buddy
//
//  Multi-step jobs on the screen, done in one go: "open Opera, search
//  kaggle, go to my competitions, open the RSNA knee one and tell me my
//  rank". Voice Dottie hands the whole request here (do_task_on_screen) and
//  this runs the classic look-act loop until it's done:
//
//    1. Screenshot the display the user is working on (without Dottie's own
//       windows) and send it to Gemini Flash with the task, the steps so far
//       and a small set of actions as function declarations.
//    2. Gemini answers with the next action: open an app or page, click a
//       box on the screenshot, type, press keys, scroll, wait, or finish
//       with what to tell the user.
//    3. Do it (Dottie's cursor flies to every click first), wait for the
//       screen to settle, and go again.
//
//  Gemini Flash returns exact boxes for what it sees (verified 2026-10-16 on
//  the free tier: box_2d within a few pixels on a 1440px screenshot), so
//  clicks land on the thing itself. The loop stops on finish, after
//  maximumSteps, or when the user stops it (Escape, the notch, or by voice).
//
//  Long jobs work toward the user's real goal (DottieTaskGoal): "sign in
//  with this account" is done when the account shows as signed in, not when
//  its tile is clicked. The job gets a goal, a "done when" check and a short
//  plan (from common goals, a plan that worked before, or written by the
//  model with its first step, so no extra call), shown in the notch and
//  revised as screens change. A finish is checked against "done when" on a
//  fresh screen before it counts. When only the user can help (which
//  account, a code, okay to pay), the job asks once and carries on. Quick
//  asks ("scroll down") skip all of this and stay instant.
//

import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

@MainActor
final class DottieScreenTaskRunner {
    enum Outcome {
        /// Done; the answer is what to tell the user.
        case finished(answer: String)
        /// The user stopped it.
        case stopped
        /// Gave up: Gemini unreachable, too many steps, no screen access.
        case failed(reason: String)
    }

    static let maximumSteps = 30
    /// Games take many small moves.
    static let maximumGameSteps = 150
    /// Fast and on the free tier; the Worker falls back to other Flash
    /// models when it's busy.
    private static let taskModel = "gemini-3.6-flash"
    /// Older screenshots are dropped from the conversation to keep requests
    /// small; the action log still says what happened.
    private static let keptScreenshotCount = 2
    private static let maximumScreenshotDimension = 1440
    /// Games favor speed: a smaller frame and the quickest model (a box
    /// lookup takes about a second on it, Oct 2026).
    private static let gameScreenshotDimension = 1024
    private static let gameModel = "gemini-3.5-flash-lite"
    /// The longest one step's answer may take before it's asked again on
    /// another model.
    private static let stepAnswerDeadlineSeconds: Double = 22

    /// A picture the user saved in Home → Conversation that the job needs
    /// ("grab the golden sword").
    struct ReferenceImage {
        let name: String
        let description: String
        let jpegData: Data
    }

    /// Progress for the notch: step number and what's happening.
    var onProgress: (@MainActor (_ stepNumber: Int, _ description: String) -> Void)?
    /// Saves a picture of something on screen to the picture library
    /// (save_picture): image data, name, description. Returns the result.
    var onSavePicture: (@MainActor (_ imageData: Data, _ name: String, _ description: String) -> String)?
    /// Called before each click with the global point and its display, so
    /// Dottie's cursor can fly there first.
    var onWillClick: (@MainActor (_ point: CGPoint, _ displayFrame: CGRect) async -> Void)?

    private(set) var currentTaskText: String?
    private var runTask: Task<Void, Never>?
    private var isGameMode = false
    /// How far the character moves per second of a held key, in screen
    /// points, learned from each walk_to (games differ a lot).
    private var walkSpeedPointsPerSecond: CGFloat = 220
    /// Where the last top-down walk started and how far it meant to go,
    /// to learn the real speed from where the character ended up.
    private var lastWalk: (start: CGPoint, plannedDistance: CGFloat, plannedDirection: CGVector)?
    /// Free-tier models allow about 15 requests a minute, so a game's
    /// quick loop is spaced out a little to avoid hitting the limit.
    private static let minimumGameRequestSpacingSeconds: TimeInterval = 2.5
    private var lastRequestStartedAt: Date?
    /// Sent at the start of every request, so the pictures are never
    /// dropped with old screenshots.
    private var referenceImageParts: [[String: Any]] = []
    /// Extra pictures for the next turn: zoomed crops, look-around views.
    private var pendingExtraImageParts: [[String: Any]] = []
    /// The windows on screen just before the last click, to notice a link
    /// that opened a new tab or window, maybe in an app behind this one.
    private var windowsBeforeLastClick: WindowSnapshot?
    /// The model for this job's steps (DottieModelPicker), and how hard
    /// the job looked: simple jobs use the quickest model.
    private var jobModel: String?
    private var jobTier: DottieModelPicker.Tier = .normal
    /// "⚡ done from memory in 2.1s" when the last job used a replay.
    private(set) var lastReplayReport: String?
    /// True while a replay plays (no Gemini calls, quicker cursor).
    private(set) var isReplaying = false
    /// A replay the user asked for by name, for the job with this wording.
    var requestedReplay: (id: UUID, taskText: String)?

    /// The plan was made or moved on: its steps and the one being done, for
    /// the notch.
    var onPlanChanged: (@MainActor (_ steps: [String], _ currentStepIndex: Int) -> Void)?
    /// The job needs something only the user knows (which account, a code,
    /// okay to pay). Says and shows the question; the answer comes back
    /// through DottieScreenJobQuestions.
    var onAskUser: (@MainActor (_ question: String) -> Void)?
    /// The job's goal, "done when" and plan. Nil for quick jobs.
    private(set) var currentGoal: DottieTaskGoal?
    /// A long job gets a plan and a done check before it may finish.
    private var isLongJob = false
    /// How many times a finish was sent back because it wasn't done yet.
    private var finishRejectionCount = 0
    private static let maximumFinishRejections = 2
    /// Passwords and codes the user gave during this job, by placeholder
    /// ("{{code}}"). The model types the placeholder and Dottie fills in the
    /// real thing, so it's never sent to Gemini or saved in a replay.
    private var userSecrets: [String: String] = [:]
    /// The last type_text went into a password box (the user gave it), so
    /// the step isn't saved.
    private var lastTypedIntoSecureField = false
    /// How long a question waits for the user before the job stops.
    private static let answerWaitSeconds: Double = 180

    var isRunning: Bool { runTask != nil }
    /// Game jobs play through DottieGamePlayer (think, then play).
    private var gamePlayer: DottieGamePlayer?
    /// A game job says something out loud now and then.
    var onThinkAloud: (@MainActor (_ line: String) -> Void)?

    func start(
        task taskText: String,
        isGameMode: Bool = false,
        referenceImages: [ReferenceImage] = [],
        completion: @escaping @MainActor (Outcome) -> Void
    ) {
        stop()
        currentTaskText = taskText
        self.isGameMode = isGameMode
        walkSpeedPointsPerSecond = 220
        lastWalk = nil
        lastRequestStartedAt = nil
        jobModel = nil
        jobTier = .normal
        lastReplayReport = nil
        currentGoal = nil
        isLongJob = false
        finishRejectionCount = 0
        userSecrets = [:]
        lastTypedIntoSecureField = false
        pendingExtraImageParts = []
        referenceImageParts = referenceImages.enumerated().flatMap { index, referenceImage -> [[String: Any]] in
            [
                ["text": "Reference picture \(index + 1), \"\(referenceImage.name)\", which the user shared earlier"
                    + (referenceImage.description.isEmpty ? "" : " (\(referenceImage.description))")
                    + ". When the task mentions it, it means the thing in this picture: find it on the screen by its look."],
                ["inlineData": ["mimeType": "image/jpeg", "data": referenceImage.jpegData.base64EncodedString()]]
            ]
        }
        if isGameMode {
            let player = DottieGamePlayer()
            player.onProgress = { [weak self] progressLine in
                self?.onProgress?(0, progressLine)
            }
            player.onThinkAloud = { [weak self] line in
                self?.onThinkAloud?(line)
            }
            player.onAskUser = { [weak self] question in
                self?.onAskUser?(question)
            }
            gamePlayer = player
            let windowGameName = Self.currentGameName()
            runTask = Task { [weak self] in
                let outcome = await player.play(taskText: taskText, windowGameName: windowGameName, referenceImages: referenceImages)
                guard let self, !Task.isCancelled else { return }
                self.runTask = nil
                self.currentTaskText = nil
                self.gamePlayer = nil
                completion(outcome)
            }
            return
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(taskText: taskText)
            guard !Task.isCancelled else { return }
            self.runTask = nil
            self.currentTaskText = nil
            completion(outcome)
        }
    }

    /// Stops after the current action. Returns true if a task was running.
    @discardableResult
    func stop() -> Bool {
        // Stop also ends a gameplay recording being played back.
        let stoppedPlayback = DottieGameplayPlayback.shared.stop()
        guard let runTask else { return stoppedPlayback }
        DottieScreenJobQuestions.shared.resolve(with: nil)
        gamePlayer?.stop()
        gamePlayer = nil
        runTask.cancel()
        self.runTask = nil
        currentTaskText = nil
        return true
    }

    // MARK: - The loop

    private func run(taskText: String) async -> Outcome {
        guard DottieScreenActionPerformer.canPostEvents else {
            return .failed(reason: "I need Accessibility permission to click and type for you: System Settings → Privacy & Security → Accessibility.")
        }

        var contents: [[String: Any]] = []
        var pendingFunctionResponseParts: [[String: Any]] = []
        var consecutiveRequestFailures = 0
        // Spotting a stuck loop: what the screen looked like before the last
        // actions, and the actions themselves.
        var previousScreenFingerprint: [UInt8]?
        var didActSinceLastLook = false
        var recentActionSignatures: [String] = []
        var actionLog: [String] = []
        let lessonSelection = DottieScreenLessons.shared.select(forTask: taskText, frontmostAppName: NSWorkspace.shared.frontmostApplication?.localizedName)
        var lessonsText = lessonSelection.promptText

        // Instant replay: the same job done before in this app or site
        // runs again from memory, and Gemini only steps in where the
        // screen doesn't match.
        let jobContext = DottieReplayContext.current()
        // Understand the goal before acting. Quick asks skip this; long
        // ones get a goal and plan without a model call when one's known.
        let jobSize = isGameMode ? DottieTaskGoals.Size.short : DottieTaskGoals.size(of: taskText)
        if jobSize == .long {
            isLongJob = true
            setUpGoal(taskText: taskText, appName: jobContext.appName)
        }
        var recordedSteps: [DottieReplay.Step] = []
        var unconfirmedStepIndices: [Int] = []
        var replayUsed: DottieReplay?
        var replayedStepCount = 0
        if !isGameMode, referenceImageParts.isEmpty {
            let requestedReplay = self.requestedReplay.flatMap { $0.taskText == taskText ? DottieReplayStore.shared.replay(withID: $0.id) : nil }
            self.requestedReplay = nil
            if let replay = requestedReplay ?? DottieReplayStore.shared.bestMatch(for: taskText, context: jobContext) {
                switch await playReplay(replay) {
                case .stopped:
                    return .stopped
                case .finished(let answer, let playedSteps):
                    if let answer { return .finished(answer: answer) }
                    replayUsed = replay
                    recordedSteps = playedSteps
                    replayedStepCount = playedSteps.count
                    lessonsText += "\nDottie already did every step of this job from memory: \(playedSteps.map(\.summary).joined(separator: "; ")). Check the screen: if the task is done, call finish with the answer, read fresh from the screen. If not, carry on from here."
                case .handedOver(let playedSteps, let note):
                    replayUsed = replay
                    recordedSteps = playedSteps
                    replayedStepCount = playedSteps.count
                    if !playedSteps.isEmpty { lessonsText += "\n" + note }
                }
            }
        }
        // How hard the job is decides the model; asked while the first
        // screenshot is taken.
        let isGameJob = isGameMode
        let tierTask = Task { () -> DottieModelPicker.Tier in
            if isGameJob { return .tiny }
            return await DottieModelPicker.isSimpleScreenJob(taskText) ? .tiny : .normal
        }

        let stepLimit = isGameMode ? Self.maximumGameSteps : Self.maximumSteps
        for stepNumber in 1...stepLimit {
            if Task.isCancelled { return .stopped }

            // Before looking: if the last click opened something in an app
            // behind this one, bring it forward so the screenshot shows it.
            var windowChangeNote: String?
            if let windowsBefore = windowsBeforeLastClick {
                windowsBeforeLastClick = nil
                windowChangeNote = await Self.followWindowChanges(since: windowsBefore)
            }

            let screenshotDimension = isGameMode ? Self.gameScreenshotDimension : Self.maximumScreenshotDimension
            guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: screenshotDimension) else {
                return .failed(reason: "I couldn't see the screen. Dottie needs Screen Recording permission.")
            }
            var screenNote = "Step \(stepNumber). " + Self.describeFrontmostWindow()
            if let windowChangeNote {
                screenNote += "\n" + windowChangeNote
            }
            let screenFingerprint = Self.fingerprint(of: screen.image)
            if !isGameMode, didActSinceLastLook,
               let previousScreenFingerprint, Self.isSameScreen(previousScreenFingerprint, screenFingerprint) {
                screenNote += "\nThe screen looks exactly the same as before your last action, so it probably didn't work (or it was already done). Don't repeat it: look at what's really on screen and try a different way, like pressing return, clicking a different spot or result, closing a popup, scrolling, or waiting."
                // Clicks that changed nothing aren't part of the replay.
                for index in unconfirmedStepIndices.sorted(by: >) where index < recordedSteps.count {
                    recordedSteps.remove(at: index)
                }
                escalateModelIfSimple()
            }
            unconfirmedStepIndices = []
            if let repeatedAction = Self.repeatedAction(in: recentActionSignatures) {
                screenNote += "\nYou've done \(repeatedAction) several times and it isn't getting you further. Stop doing it. Check which steps of the task are already done on this screen and move to the next one, or try a completely different way."
                escalateModelIfSimple()
            }
            previousScreenFingerprint = screenFingerprint
            didActSinceLastLook = false
            // Every function call needs its response in the next user turn,
            // so a failed request puts these back for the retry.
            let functionResponsesForThisTurn = pendingFunctionResponseParts
            var userParts = functionResponsesForThisTurn
            userParts.append(["inlineData": ["mimeType": "image/jpeg", "data": screen.jpegData.base64EncodedString()]])
            userParts.append(contentsOf: pendingExtraImageParts)
            pendingExtraImageParts = []
            if jobModel == nil {
                jobTier = await tierTask.value
                jobModel = DottieModelPicker.shared.pick(jobTier)
                // Words that didn't say, and a job that doesn't look simple.
                if jobSize == .unsure, jobTier == .normal, !isGameMode {
                    isLongJob = true
                }
            }
            let planReminder = isLongJob ? (currentGoal.map { $0.promptText + "\n" } ?? "") : ""
            userParts.append(["text": contents.isEmpty
                ? "Task from the user: \(taskText)\n\(lessonsText)\n\(isLongJob ? longJobBriefing() : "")\(screenNote)\nThis is the screen now. Take the first step."
                : "\(screenNote)\n\(planReminder)This is the screen now. First check it against the task: which steps are already done? Then take the first step that isn't done yet."])
            contents.append(["role": "user", "parts": userParts])
            pendingFunctionResponseParts = []
            Self.dropOldScreenshots(from: &contents)
            let modelParts: [[String: Any]]
            // A slow answer shows in the notch, so waiting on Gemini doesn't
            // look like Dottie being stuck.
            let waitingStartedAt = Date()
            let slowAnswerNotice = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                while !Task.isCancelled {
                    self?.onProgress?(stepNumber, "waiting on Gemini… \(Int(Date().timeIntervalSince(waitingStartedAt))) s")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            do {
                modelParts = try await requestNextActions(contents: contents)
                slowAnswerNotice.cancel()
                consecutiveRequestFailures = 0
            } catch {
                slowAnswerNotice.cancel()
                if Task.isCancelled { return .stopped }
                consecutiveRequestFailures += 1
                print("⚠️ Screen task step \(stepNumber) failed: \(error.localizedDescription)")
                // A game waits out a per-minute limit rather than giving up.
                let isRateLimited = (error as NSError).code == 429
                if consecutiveRequestFailures >= (isGameMode && isRateLimited ? 6 : 3) {
                    let statusCode = (error as NSError).code
                    let wasBusy = [429, 500, 503, 504].contains(statusCode) || (error as? URLError)?.code == .timedOut
                    return .failed(reason: wasBusy
                        ? "Gemini's too busy to keep going right now."
                        : "Gemini stopped giving me steps (\(statusCode == -2 ? "empty answer" : "error \(statusCode)")), so I stopped.")
                }
                // Try the same step again with the same conversation, a
                // little later each time so a per-minute limit can reset.
                contents.removeLast()
                pendingFunctionResponseParts = functionResponsesForThisTurn
                // A busy or slow model is skipped for a while; after two
                // misses in a row the quickest model takes over the steps.
                let failedModel = jobModel ?? ""
                jobModel = DottieModelPicker.shared.pick(consecutiveRequestFailures >= 2 ? .tiny : jobTier, avoiding: [failedModel])
                onProgress?(stepNumber, "Gemini is slow, asking again (\(consecutiveRequestFailures) of 2)")
                let backoffSeconds = UInt64(consecutiveRequestFailures) * (isRateLimited ? 5 : 1)
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                continue
            }
            if Task.isCancelled { return .stopped }

            contents.append(["role": "model", "parts": modelParts])
            let functionCalls = modelParts.compactMap { $0["functionCall"] as? [String: Any] }

            guard !functionCalls.isEmpty else {
                // Plain text instead of an action: treat it as the answer.
                let answerText = modelParts
                    .filter { ($0["thought"] as? Bool) != true }
                    .compactMap { $0["text"] as? String }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .finished(answer: answerText.isEmpty ? "All done." : answerText)
            }

            var actedThisTurn = false
            for functionCall in functionCalls {
                if Task.isCancelled { return .stopped }
                let functionName = functionCall["name"] as? String ?? ""
                let arguments = functionCall["args"] as? [String: Any] ?? [:]
                func respond(_ result: String) {
                    var functionResponse: [String: Any] = ["name": functionName, "response": ["result": result]]
                    if let functionCallID = functionCall["id"] as? String {
                        functionResponse["id"] = functionCallID
                    }
                    pendingFunctionResponseParts.append(["functionResponse": functionResponse])
                }

                // Writing down or moving on in the plan doesn't touch the screen.
                if functionName == "plan" {
                    respond(applyPlan(arguments, taskText: taskText))
                    continue
                }

                if functionName == "ask_user" {
                    guard let reply = await askUser(arguments, stepNumber: stepNumber) else {
                        if Task.isCancelled { return .stopped }
                        let question = arguments.dottieString("question") ?? "one thing"
                        return .failed(reason: "I needed you for one thing (\(question)) and didn't hear back, so I stopped there.")
                    }
                    respond(reply)
                    // The user may have changed the screen meanwhile (typed a
                    // code, used Touch ID), so it's not a stuck screen.
                    previousScreenFingerprint = nil
                    continue
                }

                if functionName == "finish" {
                    let answer = (arguments["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let didSucceed = (arguments["succeeded"] as? Bool) ?? true
                    // Don't finish early: a long job is done only when its
                    // "done when" shows on a fresh screen.
                    if didSucceed, isLongJob, finishRejectionCount < Self.maximumFinishRejections,
                       let problem = await doneCheckProblem(actedThisTurn: actedThisTurn, doneCheck: arguments.dottieString("done_check")) {
                        if Task.isCancelled { return .stopped }
                        finishRejectionCount += 1
                        print("🧭 Not finished yet: \(problem)")
                        onProgress?(stepNumber, "making sure it's really done")
                        respond("not finished: \(problem)")
                        continue
                    }
                    // The reward for the tips (and plan) this job was given.
                    DottieScreenLessons.shared.recordOutcome(lessonIDs: lessonSelection.lessonIDs + learnedPlanLessonIDs, succeeded: didSucceed)
                    // A long job that got done keeps its plan for next time.
                    if didSucceed, isLongJob, let currentGoal, !currentGoal.steps.isEmpty {
                        DottieScreenLessons.shared.addPlan(currentGoal, task: taskText, appName: jobContext.appName)
                    }
                    if let lesson = (arguments["lesson"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !lesson.isEmpty {
                        DottieScreenLessons.shared.add(lesson, task: taskText, appName: NSWorkspace.shared.frontmostApplication?.localizedName, cameFromSuccess: didSucceed)
                    }
                    let finalAnswer = answer.isEmpty ? "All done." : answer
                    if didSucceed, !isGameMode, referenceImageParts.isEmpty, !recordedSteps.isEmpty {
                        saveReplay(taskText: taskText, context: jobContext, steps: recordedSteps, answer: finalAnswer, replacing: replayUsed)
                        if replayedStepCount > 0 {
                            lastReplayReport = "⚡ \(replayedStepCount) of \(recordedSteps.count) steps from memory"
                        }
                    }
                    return .finished(answer: finalAnswer)
                }

                let actionSignature = Self.signature(functionName: functionName, arguments: arguments)
                recentActionSignatures.append(actionSignature)
                if recentActionSignatures.count > 6 { recentActionSignatures.removeFirst() }
                actionLog.append(actionSignature)
                let result: String
                // Clicking the same thing over and over (a link that opens a
                // new tab each time) piles up tabs, so the third click in a
                // row is refused.
                if functionName == "click", !isGameMode,
                   recentActionSignatures.suffix(4).filter({ $0 == actionSignature }).count >= 3 {
                    result = "not clicked: you've already clicked this 3 times. It probably worked and opened somewhere else (a new tab, a new window or another app), or it doesn't do what you think. Look at the window title and the tab bar, switch to the tab or app it opened, or try a different way. Don't click it again."
                } else {
                    // What it takes to do this step again without Gemini.
                    // Passwords and codes the user gave are never saved.
                    let typesUserSecret = functionName == "type_text" && ((arguments["text"] as? String) ?? "").contains("{{")
                    let replayStep = (isGameMode || typesUserSecret) ? nil : await replayStep(functionName: functionName, arguments: arguments, screen: screen)
                    result = await perform(functionName: functionName, arguments: arguments, screen: screen, stepNumber: stepNumber)
                    let typedIntoPasswordBox = functionName == "type_text" && lastTypedIntoSecureField
                    if let replayStep, Self.resultLooksDone(result), !typedIntoPasswordBox {
                        if replayStep.action == "click" || replayStep.action == "scroll" {
                            unconfirmedStepIndices.append(recordedSteps.count)
                        }
                        recordedSteps.append(replayStep)
                    }
                }
                respond(result)
                didActSinceLastLook = true
                actedThisTurn = true
            }

            // Let pages load and animations finish before the next look.
            // Games keep moving, so they get a quick look straight away. A
            // turn that only planned has nothing to wait for.
            if actedThisTurn {
                try? await Task.sleep(nanoseconds: isGameMode ? 200_000_000 : 900_000_000)
            }
        }

        DottieScreenLessons.shared.recordOutcome(lessonIDs: lessonSelection.lessonIDs + learnedPlanLessonIDs, succeeded: false)
        if !isGameMode {
            // Next time, the job starts knowing this path didn't work.
            DottieScreenLessons.shared.add(
                "This didn't finish in \(stepLimit) steps. Ended up repeating: \(actionLog.suffix(4).joined(separator: "; ")). Try a different route next time.",
                task: taskText,
                appName: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }
        return .failed(reason: "That took more than \(stepLimit) steps, so I stopped.")
    }

    // MARK: - Instant replays

    private enum ReplayResult {
        /// All steps done. With an answer the job is finished; without one
        /// (it reads something off the screen) Gemini takes one look.
        case finished(answer: String?, playedSteps: [DottieReplay.Step])
        case handedOver(playedSteps: [DottieReplay.Step], note: String)
        case stopped
    }

    private func playReplay(_ replay: DottieReplay) async -> ReplayResult {
        print("⚡ Replaying \"\(replay.name)\" (\(replay.steps.count) steps)")
        let startedAt = Date()
        let player = DottieReplayPlayer()
        player.onProgress = { [weak self] text in self?.onProgress?(0, text) }
        player.onWillClick = { [weak self] point, displayFrame in await self?.onWillClick?(point, displayFrame) }
        if let planSteps = replay.planSteps, !planSteps.isEmpty {
            onPlanChanged?(planSteps, 0)
        }
        isReplaying = true
        let result = await player.play(replay)
        isReplaying = false
        switch result {
        case .stopped:
            return .stopped
        case .completed(let playedSteps):
            // A sign-in that needs a code this time isn't done, however
            // much the window looks like last time.
            let stillNotDone = await Self.screenShowsNotDoneSign(forTask: replay.taskText)
            if !replay.needsFreshAnswer, !stillNotDone, await Self.screenLooksFinished(like: replay) {
                let seconds = Date().timeIntervalSince(startedAt)
                DottieReplayStore.shared.noteUsed(replay.id, seconds: seconds)
                lastReplayReport = "⚡ done from memory in " + String(format: "%.1fs", seconds)
                print("⚡ Replay done in \(String(format: "%.1f", seconds))s")
                return .finished(answer: replay.answer, playedSteps: playedSteps)
            }
            return .finished(answer: nil, playedSteps: playedSteps)
        case .handedOver(let playedSteps, let stepIndex, let reason):
            let doneText = playedSteps.map(\.summary).joined(separator: "; ")
            let note = "Dottie already did these steps of this job from memory: \(doneText). The next saved step (\(replay.steps[stepIndex].summary)) didn't match the screen (\(reason)). Check the screen and carry on from here."
            return .handedOver(playedSteps: playedSteps, note: note)
        }
    }

    /// The window ends up where the first run ended (by its title), so a
    /// replay that went somewhere else gets a look from Gemini.
    private static func screenLooksFinished(like replay: DottieReplay) async -> Bool {
        guard let finalWindowTitle = replay.finalWindowTitle else {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return true
        }
        let deadline = Date().addingTimeInterval(2.5)
        repeat {
            if let windowTitle = DottieReplayContext.current().windowTitle,
               windowTitle == finalWindowTitle || DottieReplayStore.wordOverlap(windowTitle, finalWindowTitle) >= 0.5 {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        return false
    }

    /// A step as it can be done again: its arguments, and for clicks and
    /// fields, everything that finds the target again.
    private func replayStep(functionName: String, arguments: [String: Any], screen: DottieDisplayCapture.Screenshot) async -> DottieReplay.Step? {
        let replayableActions: Set<String> = ["open_app", "open_url", "click", "type_text", "press_keys", "scroll", "wait", "wait_for_video_end"]
        guard replayableActions.contains(functionName) else { return nil }
        var storedArguments: [String: String] = [:]
        for key in ["double_click", "right_click", "select_all_first", "press_enter"] {
            if let value = (arguments[key] as? Bool) ?? (arguments[key] as? NSNumber)?.boolValue, value {
                storedArguments[key] = "true"
            }
        }
        for key in ["amount", "seconds", "max_seconds"] {
            if let value = (arguments[key] as? NSNumber)?.doubleValue {
                storedArguments[key] = key == "amount" ? String(Int(value)) : String(value)
            }
        }
        for key in ["name", "url", "browser", "text", "keys", "direction"] {
            if let value = arguments[key] as? String, !value.isEmpty {
                storedArguments[key] = key == "direction" ? value.lowercased() : value
            }
        }
        var target: DottieReplay.Target?
        if ["click", "type_text", "scroll"].contains(functionName), let point = Self.clickPoint(arguments: arguments, screen: screen) {
            target = await DottieReplayTargets.capture(at: point, label: arguments["label"] as? String, screen: screen)
        }
        if functionName == "click", target == nil { return nil }
        return DottieReplay.Step(action: functionName, arguments: storedArguments, target: target)
    }

    /// The action did what it said ("clicked", "typed it"), not an error
    /// or a refusal.
    private static func resultLooksDone(_ result: String) -> Bool {
        let lowercasedResult = result.lowercased()
        return !["error", "couldn't", "unknown", "refused", "not clicked", "stopped"].contains { lowercasedResult.hasPrefix($0) }
    }

    private func saveReplay(taskText: String, context: DottieReplayContext, steps: [DottieReplay.Step], answer: String, replacing earlierReplay: DottieReplay?) {
        let firstAction = steps.first?.action ?? ""
        let name = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        DottieReplayStore.shared.save(DottieReplay(
            id: earlierReplay?.id ?? UUID(),
            name: String(name.prefix(1).uppercased() + name.dropFirst().prefix(69)),
            taskText: taskText,
            appBundleIdentifier: context.appBundleIdentifier,
            appName: context.appName,
            siteHost: context.siteHost,
            startsOnItsOwn: firstAction == "open_app" || firstAction == "open_url",
            steps: steps,
            answer: answer,
            needsFreshAnswer: DottieReplayStore.needsFreshAnswer(task: taskText, answer: answer),
            finalWindowTitle: DottieReplayContext.current().windowTitle,
            createdAt: earlierReplay?.createdAt ?? Date(),
            lastUsedAt: Date(),
            useCount: earlierReplay?.useCount ?? 0,
            lastReplaySeconds: earlierReplay?.lastReplaySeconds,
            planSteps: isLongJob ? currentGoal?.steps : nil
        ))
    }

    /// A job that looked simple but isn't going well moves to the normal
    /// model.
    private func escalateModelIfSimple() {
        guard !isGameMode, jobTier == .tiny else { return }
        jobTier = .normal
        jobModel = DottieModelPicker.shared.pick(.normal)
        print("🧭 Screen task: moving to \(jobModel ?? "the normal model")")
    }

    // MARK: - Goals and plans (DottieTaskGoal)

    /// The goal and plan a long job starts with: a plan that worked before
    /// for a similar job, else a common goal's ready plan. Neither costs a
    /// model call. Without either, the model writes one with its first step.
    private func setUpGoal(taskText: String, appName: String?) {
        let commonGoal = DottieTaskGoals.template(for: taskText)
        if var learnedGoal = DottieScreenLessons.shared.learnedPlan(forTask: taskText, appName: appName) {
            learnedGoal.notDoneSigns = commonGoal?.notDoneSigns ?? []
            if learnedGoal.doneWhen.isEmpty { learnedGoal.doneWhen = commonGoal?.doneWhen ?? "" }
            currentGoal = learnedGoal
        } else {
            currentGoal = commonGoal
        }
        if let currentGoal {
            print("🎯 Goal (\(currentGoal.source.rawValue)): \(currentGoal.goal). Done when: \(currentGoal.doneWhen)")
            onPlanChanged?(currentGoal.steps, currentGoal.currentStepIndex)
        }
    }

    /// The lesson a learned plan came from, to score it with the outcome.
    private var learnedPlanLessonIDs: [UUID] {
        currentGoal?.learnedLessonID.map { [$0] } ?? []
    }

    /// What the first request of a long job adds to the task.
    private func longJobBriefing() -> String {
        guard let currentGoal else {
            return "This is a longer job: work out what the user really wants done, not just the first click (\"sign in with this account\" means signed in, not the account clicked). Call plan with the goal, done_when (what the screen shows once it's really done) and 3-6 short steps, together with your first action.\n"
        }
        let planOrigin = currentGoal.source == .learned
            ? "This plan worked before for a job like this; follow it unless the screen says otherwise, and call plan only to change it or move current_step."
            : "Call plan with your own goal, done_when and steps for this screen (keep or fix the ones above), together with your first action."
        return "This is a longer job: keep going until the goal is really done, not just the first click.\n\(currentGoal.promptText)\n\(planOrigin)\n"
    }

    /// Takes the model's plan, or its move to the next step.
    private func applyPlan(_ arguments: [String: Any], taskText: String) -> String {
        var taskGoal = currentGoal ?? DottieTaskGoal(
            goal: taskText,
            doneWhen: "",
            steps: [],
            notDoneSigns: DottieTaskGoals.notDoneSigns(for: taskText),
            source: .model
        )
        if let goalText = arguments.dottieString("goal") { taskGoal.goal = String(goalText.prefix(200)) }
        if let doneWhen = arguments.dottieString("done_when") { taskGoal.doneWhen = String(doneWhen.prefix(300)) }
        let newSteps = ((arguments["steps"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { String($0.prefix(120)) }
        if !newSteps.isEmpty {
            taskGoal.steps = Array(newSteps)
            taskGoal.currentStepIndex = 0
        }
        if let currentStepNumber = arguments.dottieNumber("current_step"), !taskGoal.steps.isEmpty {
            taskGoal.currentStepIndex = min(max(Int(currentStepNumber) - 1, 0), taskGoal.steps.count - 1)
        }
        currentGoal = taskGoal
        // The model saw a job worth planning, so it gets the done check
        // (games keep their quick loop).
        if !isGameMode { isLongJob = true }
        onPlanChanged?(taskGoal.steps, taskGoal.currentStepIndex)
        return "plan noted. keep going; call plan again with current_step as you move on, or with new steps when the screen changes the plan."
    }

    /// Asks the user once and waits for the answer. Returns what to tell
    /// the model, or nil when no answer came (or the job was stopped).
    private func askUser(_ arguments: [String: Any], stepNumber: Int) async -> String? {
        let question = arguments.dottieString("question") ?? "What should I do next?"
        let kind = arguments.dottieString("kind")?.lowercased() ?? "missing_info"
        print("🙋 Screen job asks: \(question)")
        onProgress?(stepNumber, "waiting for you: \(question)")
        onAskUser?(question)
        guard let answer = await DottieScreenJobQuestions.shared.waitForAnswer(to: question, timeoutSeconds: Self.answerWaitSeconds),
              !Task.isCancelled else { return nil }
        onProgress?(stepNumber, "got it, carrying on")
        switch kind {
        case "password", "code":
            let placeholder = "{{\(kind)}}"
            userSecrets[placeholder] = answer
            return "the user gave the \(kind). It isn't shown to you: to type it, call type_text with text exactly \(placeholder) on the right field and Dottie fills in the real one."
        case "do_it_yourself":
            return "the user says: \(answer). Look at the new screenshot and carry on from there."
        default:
            return "the user answered: \(answer). Carry on with that; don't ask again."
        }
    }

    /// Why a finish can't count yet, or nil when it can: the done-when has
    /// to show on a screen taken after the last action. Text recognition on
    /// the Mac catches "still on the password page" without a model call.
    private func doneCheckProblem(actedThisTurn: Bool, doneCheck: String?) async -> String? {
        let doneWhen = (currentGoal?.doneWhen).flatMap { $0.isEmpty ? nil : $0 } ?? "every part of the task is done on screen"
        if let notDoneSigns = currentGoal?.notDoneSigns, !notDoneSigns.isEmpty {
            if actedThisTurn {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if let freshScreen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: Self.maximumScreenshotDimension),
               let visibleSign = await DottieTaskGoals.visibleNotDoneSign(in: freshScreen.image, signs: notDoneSigns) {
                return "the screen still shows \"\(visibleSign)\", so it isn't done (done when: \(doneWhen)). Keep going on the next screenshot: pick the account, use the password the browser offers, or ask_user for what's missing."
            }
        }
        if actedThisTurn {
            return "you acted and finished in the same turn, so you haven't seen the result yet. Look at the next screenshot and finish only if it shows the job is done (done when: \(doneWhen)); otherwise keep going."
        }
        if (doneCheck ?? "").isEmpty {
            return "check the done-when on this screenshot first (done when: \(doneWhen)). If it's met, call finish again with done_check saying what on screen shows it. If not, keep going."
        }
        return nil
    }

    /// True when a common goal's "not done yet" words are on screen now.
    private static func screenShowsNotDoneSign(forTask taskText: String) async -> Bool {
        let notDoneSigns = DottieTaskGoals.notDoneSigns(for: taskText)
        guard !notDoneSigns.isEmpty,
              let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: maximumScreenshotDimension) else { return false }
        return await DottieTaskGoals.visibleNotDoneSign(in: screen.image, signs: notDoneSigns) != nil
    }

    // MARK: - Spotting a stuck loop

    /// A tiny grayscale copy of the screen, to tell whether an action
    /// changed anything.
    private static func fingerprint(of image: CGImage) -> [UInt8] {
        let width = 64, height = 40
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Nearly no pixel moved (a blinking caret or clock doesn't count).
    private static func isSameScreen(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        guard first.count == second.count, !first.isEmpty else { return false }
        let changedPixels = zip(first, second).filter { abs(Int($0) - Int($1)) > 12 }.count
        return Double(changedPixels) / Double(first.count) < 0.003
    }

    private static func signature(functionName: String, arguments: [String: Any]) -> String {
        let label = (arguments["label"] as? String) ?? (arguments["text"] as? String) ?? (arguments["keys"] as? String)
            ?? (arguments["url"] as? String) ?? (arguments["name"] as? String) ?? (arguments["direction"] as? String) ?? ""
        return label.isEmpty ? functionName : "\(functionName) \"\(label.prefix(60))\""
    }

    /// An action done three times in the last four (scrolling and waiting
    /// repeat legitimately, so they need more).
    private static func repeatedAction(in signatures: [String]) -> String? {
        guard let lastSignature = signatures.last else { return nil }
        let isNaturallyRepeated = lastSignature.hasPrefix("scroll") || lastSignature.hasPrefix("wait")
        let repeatCount = signatures.suffix(isNaturallyRepeated ? 6 : 4).filter { $0 == lastSignature }.count
        return repeatCount >= (isNaturallyRepeated ? 5 : 3) ? lastSignature : nil
    }

    // MARK: - Actions

    private func perform(functionName: String, arguments: [String: Any], screen: DottieDisplayCapture.Screenshot, stepNumber: Int) async -> String {
        func text(_ key: String) -> String? {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func flag(_ key: String) -> Bool { (arguments[key] as? Bool) ?? ((arguments[key] as? NSNumber)?.boolValue ?? false) }
        func boxCenter() -> CGPoint? {
            guard let box = arguments["box_2d"] as? [Any] else { return nil }
            let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == 4 else { return nil }
            let (ymin, xmin, ymax, xmax) = (numbers[0], numbers[1], numbers[2], numbers[3])
            guard ymax >= ymin, xmax >= xmin else { return nil }
            return screen.globalPoint(normalizedX: (xmin + xmax) / 2, normalizedY: (ymin + ymax) / 2)
        }
        /// The box's middle, moved to the middle of the real control under
        /// it when there is one, so a box a few pixels off still hits.
        func clickPoint() -> CGPoint? {
            Self.clickPoint(arguments: arguments, screen: screen)
        }

        switch functionName {
        case "open_app":
            guard let appName = text("name") else { return "error: no app name" }
            onProgress?(stepNumber, "opening \(appName)")
            let didOpen = await Self.openApplication(named: appName)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return didOpen ? "opened \(appName); it's in front now" : "couldn't find an app called \(appName)"

        case "open_url":
            guard var address = text("url") else { return "error: no url" }
            if !address.contains("://") { address = "https://" + address }
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return "error: not a web address"
            }
            onProgress?(stepNumber, "opening \(url.host ?? address)")
            let didOpen: Bool
            if let browserName = text("browser") {
                didOpen = await Self.open(url, inApplicationNamed: browserName)
            } else {
                didOpen = await DottieBrowser.openInUsersBrowser(url)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return didOpen ? "opened \(address)" : "couldn't open \(address)"

        case "click":
            guard let point = clickPoint() else { return "error: box_2d must be [ymin, xmin, ymax, xmax] from 0 to 1000" }
            let label = text("label") ?? "it"
            onProgress?(stepNumber, "clicking \(label)")
            // In a game, a pause before every click costs the moment.
            if !isGameMode {
                await onWillClick?(point, screen.displayFrame)
            }
            if Task.isCancelled { return "stopped" }
            if !isGameMode {
                windowsBeforeLastClick = Self.windowSnapshot()
            }
            DottieScreenActionPerformer.click(at: point, clickCount: flag("double_click") ? 2 : 1, isRightClick: flag("right_click"))
            return "clicked \(label)"

        case "type_text":
            guard var typedText = arguments["text"] as? String, !typedText.isEmpty else { return "error: no text" }
            // "{{code}}" is a code or password the user gave (ask_user).
            var isUserSecret = false
            for (placeholder, secret) in userSecrets where typedText.contains(placeholder) {
                typedText = typedText.replacingOccurrences(of: placeholder, with: secret)
                isUserSecret = true
            }
            if typedText.contains("{{") && typedText.contains("}}") {
                return "error: the user hasn't given that yet. ask_user for it first."
            }
            lastTypedIntoSecureField = false
            if let point = clickPoint() {
                await onWillClick?(point, screen.displayFrame)
                if Task.isCancelled { return "stopped" }
                DottieScreenActionPerformer.click(at: point, clickCount: 1, isRightClick: false)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if DottieScreenActionPerformer.isFocusedFieldSecure {
                // Only a password the user gave; never a guess.
                let userGaveIt = isUserSecret || (typedText.count >= 4 && (currentTaskText ?? "").contains(typedText))
                guard userGaveIt else {
                    return "refused: that's a password box and the user hasn't given you this password. If the browser or keychain offers a saved one (a list under the field, a key icon, or the field fills itself), click that. Otherwise ask_user: kind password to get it, or kind do_it_yourself to have them type it."
                }
                lastTypedIntoSecureField = true
            }
            onProgress?(stepNumber, isUserSecret || lastTypedIntoSecureField ? "typing what you gave me" : "typing \"\(typedText.prefix(40))\"")
            if flag("select_all_first") {
                DottieScreenActionPerformer.press(keyCombination: "cmd+a")
            }
            await DottieScreenActionPerformer.type(typedText)
            if flag("press_enter") {
                try? await Task.sleep(nanoseconds: 150_000_000)
                DottieScreenActionPerformer.press(keyCombination: "enter")
            }
            return flag("press_enter") ? "typed it and pressed return" : "typed it"

        case "press_keys":
            guard let keys = text("keys") else { return "error: no keys" }
            onProgress?(stepNumber, "pressing \(keys)")
            return DottieScreenActionPerformer.press(keyCombination: keys)
                ? "pressed \(keys)"
                : "unknown key \(keys); use names like cmd+l, enter, escape, tab, up, down"

        case "scroll":
            guard let direction = text("direction").flatMap({ DottieScreenAction.ScrollDirection(rawValue: $0.lowercased()) }) else {
                return "error: direction must be up, down, left or right"
            }
            onProgress?(stepNumber, "scrolling \(direction.rawValue)")
            let amount = Int((arguments["amount"] as? NSNumber)?.doubleValue ?? 5)
            // Scroll where the content is, not wherever the user's pointer is.
            let scrollPoint = boxCenter() ?? screen.globalPoint(normalizedX: 500, normalizedY: 550)
            DottieScreenActionPerformer.scroll(direction: direction, amount: amount, at: scrollPoint)
            return "scrolled \(direction.rawValue)"

        case "hold_keys":
            guard let keys = text("keys") else { return "error: no keys" }
            let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue ?? 1
            onProgress?(stepNumber, "holding \(keys)")
            guard await DottieScreenActionPerformer.hold(keyCombination: keys, seconds: seconds) else {
                return "unknown key in \(keys); use names like w, a, s, d, space, shift, up, e"
            }
            return "held \(keys) for \(String(format: "%.1f", min(max(seconds, 0.05), 5)))s"

        case "walk_to":
            return await walk(arguments: arguments, screen: screen, stepNumber: stepNumber)

        case "move_mouse":
            let deltaX = CGFloat((arguments["dx"] as? NSNumber)?.doubleValue ?? 0)
            let deltaY = CGFloat((arguments["dy"] as? NSNumber)?.doubleValue ?? 0)
            let button = text("button")?.lowercased() ?? "none"
            onProgress?(stepNumber, "turning the camera")
            // dx and dy are 0-1000 across the screenshot, like boxes.
            let startPoint = boxCenter() ?? screen.globalPoint(normalizedX: 500, normalizedY: 500)
            let deltaXPoints = deltaX / 1000 * screen.displayFrame.width
            await DottieScreenActionPerformer.moveMouse(
                from: startPoint,
                deltaX: deltaXPoints,
                deltaY: -deltaY / 1000 * screen.displayFrame.height,
                button: button,
                seconds: (arguments["seconds"] as? NSNumber)?.doubleValue ?? 0.4
            )
            return "moved the mouse \(Int(deltaX)), \(Int(deltaY)) with \(button == "none" ? "no button" : "the \(button) button") held"

        case "search_web":
            let query = ((arguments["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "error: search_web needs a query" }
            onProgress?(stepNumber, "looking up \(query)")
            let results = await DottieWebSearch.search(query)
            // Keep the conversation small; the start of the page has the answer.
            return String(results.prefix(4000))

        case "wait":
            let seconds = min(max((arguments["seconds"] as? NSNumber)?.doubleValue ?? 2, 0.5), 120)
            onProgress?(stepNumber, seconds > 10 ? "waiting \(Int(seconds)) seconds" : "waiting for it to load")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "waited \(Int(seconds.rounded())) seconds"

        case "zoom":
            guard let box = arguments["box_2d"] as? [Any] else { return "error: zoom needs box_2d" }
            let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1],
                  let sharpImage = await DottieDisplayCapture.captureImage(displayFrame: screen.displayFrame, maximumDimension: 2880) else {
                return "error: box_2d must be [ymin, xmin, ymax, xmax]"
            }
            let imageWidth = Double(sharpImage.width), imageHeight = Double(sharpImage.height)
            let cropRect = CGRect(
                x: numbers[1] / 1000 * imageWidth, y: numbers[0] / 1000 * imageHeight,
                width: (numbers[3] - numbers[1]) / 1000 * imageWidth, height: (numbers[2] - numbers[0]) / 1000 * imageHeight
            ).integral
            guard let croppedImage = sharpImage.cropping(to: cropRect),
                  let croppedJPEG = NSBitmapImageRep(cgImage: croppedImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                return "couldn't zoom there."
            }
            onProgress?(stepNumber, "taking a closer look")
            pendingExtraImageParts.append(["text": "Zoomed-in view of box \(numbers.map { Int($0) }) on the screenshot before this one (sharper; boxes for actions still go on the full screenshot):"])
            pendingExtraImageParts.append(["inlineData": ["mimeType": "image/jpeg", "data": croppedJPEG.base64EncodedString()]])
            return "zoomed in; the close-up comes with the next screenshot."

        case "save_picture":
            let name = text("name") ?? "picture"
            var pictureImage = screen.image
            if let box = arguments["box_2d"] as? [Any] {
                let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
                if numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1] {
                    let imageWidth = Double(screen.image.width), imageHeight = Double(screen.image.height)
                    // A little of the surroundings helps recognize it later.
                    let padding = 0.15
                    let boxWidth = numbers[3] - numbers[1], boxHeight = numbers[2] - numbers[0]
                    let cropRect = CGRect(
                        x: max(0, (numbers[1] - boxWidth * padding) / 1000 * imageWidth),
                        y: max(0, (numbers[0] - boxHeight * padding) / 1000 * imageHeight),
                        width: boxWidth * (1 + 2 * padding) / 1000 * imageWidth,
                        height: boxHeight * (1 + 2 * padding) / 1000 * imageHeight
                    ).integral
                    if let croppedImage = screen.image.cropping(to: cropRect) { pictureImage = croppedImage }
                }
            }
            guard let pngData = NSBitmapImageRep(cgImage: pictureImage).representation(using: .png, properties: [:]) else {
                return "couldn't save the picture."
            }
            onProgress?(stepNumber, "remembering \(name)")
            return onSavePicture?(pngData, name, text("description") ?? "") ?? "pictures can't be saved right now."

        case "wait_for_video_end":
            let maximumSeconds = (arguments["max_seconds"] as? NSNumber)?.doubleValue ?? 600
            onProgress?(stepNumber, "watching the video to the end")
            return await DottieBrowser.waitForVideoToEnd(maximumSeconds: maximumSeconds)

        default:
            return "error: unknown action \(functionName)"
        }
    }

    /// Walks the character toward a target, from both boxes on the
    /// screenshot. Gemini is good at boxes and bad at judging how long to
    /// hold a key, so Dottie works out the keys and times herself, and
    /// learns the game's walking speed as it goes.
    private func walk(arguments: [String: Any], screen: DottieDisplayCapture.Screenshot, stepNumber: Int) async -> String {
        func frame(_ key: String) -> CGRect? {
            guard let numbers = (arguments[key] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), numbers.count == 4,
                  numbers[2] >= numbers[0], numbers[3] >= numbers[1] else { return nil }
            let topLeft = screen.globalPoint(normalizedX: numbers[1], normalizedY: numbers[0])
            let bottomRight = screen.globalPoint(normalizedX: numbers[3], normalizedY: numbers[2])
            return CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
        }
        guard let targetFrame = frame("target_box_2d") else { return "error: target_box_2d must be [ymin, xmin, ymax, xmax]" }
        let target = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let view = (arguments["view"] as? String)?.lowercased() ?? "top_down"
        onProgress?(stepNumber, "walking over")

        if view == "behind" {
            // Third person: turn until the target is ahead, then walk.
            let displayFrame = screen.displayFrame
            let offset = (target.x - displayFrame.midX) / displayFrame.width
            if abs(offset) > 0.08 {
                let turnPoints = offset * displayFrame.width * 0.6
                await DottieScreenActionPerformer.moveMouse(
                    from: CGPoint(x: displayFrame.midX, y: displayFrame.midY),
                    deltaX: turnPoints, deltaY: 0, button: "right", seconds: 0.35
                )
                return "turned \(offset > 0 ? "right" : "left") toward it; look again and walk_to once it's ahead"
            }
            let heightShare = targetFrame.height / displayFrame.height
            if heightShare > 0.22 {
                return "it's right in front of the character: pick it up or use it (press_keys e, or click it)"
            }
            let seconds = min(2.0, max(0.4, 0.12 / max(heightShare, 0.01)))
            _ = await DottieScreenActionPerformer.hold(keyCombination: "w", seconds: seconds)
            return "walked forward for \(String(format: "%.1f", seconds))s; look again"
        }

        guard let playerFrame = frame("player_box_2d") else { return "error: top-down walking needs player_box_2d" }
        let player = CGPoint(x: playerFrame.midX, y: playerFrame.midY)
        // Learn the real speed from where the last walk ended up.
        if let lastWalk, lastWalk.plannedDistance > 30 {
            let moved = CGVector(dx: player.x - lastWalk.start.x, dy: player.y - lastWalk.start.y)
            let movedAlongPlan = moved.dx * lastWalk.plannedDirection.dx + moved.dy * lastWalk.plannedDirection.dy
            let ratio = min(max(movedAlongPlan / lastWalk.plannedDistance, 0.3), 3)
            walkSpeedPointsPerSecond = min(max(walkSpeedPointsPerSecond * ratio, 40), 2000)
        }
        let deltaX = target.x - player.x
        let deltaY = target.y - player.y
        let distance = hypot(deltaX, deltaY)
        let reach = max(16, (playerFrame.width + targetFrame.width) / 2)
        if distance <= reach {
            lastWalk = nil
            return "the character is on it: pick it up or use it now (press_keys e, or click it)"
        }
        // Each axis on its own key, both held at once for the shorter time.
        let horizontalSeconds = min(Double(abs(deltaX) / walkSpeedPointsPerSecond), 2.5)
        let verticalSeconds = min(Double(abs(deltaY) / walkSpeedPointsPerSecond), 2.5)
        let horizontalKey = deltaX > 0 ? "d" : "a"
        let verticalKey = deltaY > 0 ? "w" : "s"
        let bothSeconds = min(horizontalSeconds, verticalSeconds)
        if bothSeconds > 0.05 {
            _ = await DottieScreenActionPerformer.hold(keyCombination: "\(horizontalKey)+\(verticalKey)", seconds: bothSeconds)
        }
        let restSeconds = abs(horizontalSeconds - verticalSeconds)
        if restSeconds > 0.05 {
            _ = await DottieScreenActionPerformer.hold(keyCombination: horizontalSeconds > verticalSeconds ? horizontalKey : verticalKey, seconds: restSeconds)
        }
        let plannedMove = CGVector(
            dx: CGFloat(horizontalSeconds) * walkSpeedPointsPerSecond * (deltaX > 0 ? 1 : -1),
            dy: CGFloat(verticalSeconds) * walkSpeedPointsPerSecond * (deltaY > 0 ? 1 : -1)
        )
        let plannedDistance = hypot(plannedMove.dx, plannedMove.dy)
        lastWalk = plannedDistance > 0
            ? (player, plannedDistance, CGVector(dx: plannedMove.dx / plannedDistance, dy: plannedMove.dy / plannedDistance))
            : nil
        return "walked toward it (\(Int(distance)) points away before moving); look again and walk_to again until you're on it"
    }

    /// The box's middle, moved to the middle of the real control under it
    /// when there is one, so a box a few pixels off still hits.
    private static func clickPoint(arguments: [String: Any], screen: DottieDisplayCapture.Screenshot) -> CGPoint? {
        guard let box = arguments["box_2d"] as? [Any] else { return nil }
        let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard numbers.count == 4, numbers[2] >= numbers[0], numbers[3] >= numbers[1] else { return nil }
        let topLeft = screen.globalPoint(normalizedX: numbers[1], normalizedY: numbers[0])
        let bottomRight = screen.globalPoint(normalizedX: numbers[3], normalizedY: numbers[2])
        let boxFrame = CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
        let snappedFrame = AccessibilitySnap.refinedFrame(boxFrame)
        return CGPoint(x: snappedFrame.midX, y: snappedFrame.midY)
    }

    /// Brings a running app forward, else launches it by name.
    static func openApplication(named appName: String) async -> Bool {
        let wantedName = appName.lowercased().replacingOccurrences(of: ".app", with: "")
        if let runningApplication = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && ($0.localizedName?.lowercased() == wantedName)
        }) {
            runningApplication.unhide()
            return runningApplication.activate(options: [.activateAllWindows])
        }
        guard let applicationURL = applicationURL(named: appName) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)) != nil
    }

    static func open(_ url: URL, inApplicationNamed appName: String) async -> Bool {
        guard let applicationURL = applicationURL(named: appName) else { return NSWorkspace.shared.open(url) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)) != nil
    }

    /// Finds an installed app by name in the usual folders ("opera" finds
    /// Opera GX.app too).
    private static func applicationURL(named appName: String) -> URL? {
        let wantedName = appName.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        let searchFolders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var prefixMatch: URL?
        for folder in searchFolders {
            guard let folderItems = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for itemURL in folderItems where itemURL.pathExtension == "app" {
                let itemName = itemURL.deletingPathExtension().lastPathComponent.lowercased()
                if itemName == wantedName { return itemURL }
                if prefixMatch == nil && itemName.hasPrefix(wantedName) { prefixMatch = itemURL }
            }
        }
        return prefixMatch
    }

    /// "Frontmost app: Opera GX, window: Kaggle - Competitions."
    /// Which game a job is in: the app's name and its window's title.
    static func currentGameName() -> String {
        let applicationName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "game"
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return applicationName }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(focusedWindowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let windowTitle = titleValue as? String, !windowTitle.isEmpty, windowTitle != applicationName else {
            return applicationName
        }
        return "\(applicationName) \(windowTitle)"
    }

    // MARK: - New tabs and windows

    struct WindowSnapshot {
        struct Window {
            let processID: pid_t
            let appName: String
            let title: String
        }
        let frontmostProcessID: pid_t?
        let windows: [CGWindowID: Window]
    }

    /// Every normal window on screen with its title (titles need the
    /// Screen Recording permission Dottie already has).
    static func windowSnapshot() -> WindowSnapshot {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        var windows: [CGWindowID: WindowSnapshot.Window] = [:]
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for windowInfo in windowList {
                guard (windowInfo[kCGWindowLayer as String] as? Int) == 0,
                      let windowNumber = windowInfo[kCGWindowNumber as String] as? Int,
                      let processID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                      processID != ownProcessID else { continue }
                windows[CGWindowID(windowNumber)] = WindowSnapshot.Window(
                    processID: processID,
                    appName: windowInfo[kCGWindowOwnerName as String] as? String ?? "an app",
                    title: windowInfo[kCGWindowName as String] as? String ?? ""
                )
            }
        }
        return WindowSnapshot(frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier, windows: windows)
    }

    /// What the last click opened, for the model. A link opened in an app
    /// behind the front one (a browser getting a link from Mail or Slack)
    /// is brought to the front so the next screenshot shows it.
    private static func followWindowChanges(since before: WindowSnapshot) async -> String? {
        let after = windowSnapshot()
        var changedWindows: [WindowSnapshot.Window] = []
        for (windowID, window) in after.windows {
            let earlierWindow = before.windows[windowID]
            if earlierWindow == nil || (earlierWindow?.title != window.title && !window.title.isEmpty) {
                changedWindows.append(window)
            }
        }
        guard !changedWindows.isEmpty else { return nil }

        let frontmostProcessID = after.frontmostProcessID
        if frontmostProcessID != before.frontmostProcessID {
            let frontWindow = changedWindows.first { $0.processID == frontmostProcessID } ?? changedWindows[0]
            return "Your last click brought \(frontWindow.appName) to the front\(frontWindow.title.isEmpty ? "" : " (\"\(frontWindow.title.prefix(100))\")"). Carry on there."
        }
        // Only a browser: other apps behind (music, chat) retitle their
        // windows on their own all the time.
        if let backgroundWindow = changedWindows.first(where: { window in
            window.processID != frontmostProcessID
                && DottieBrowser.isBrowser(bundleIdentifier: NSRunningApplication(processIdentifier: window.processID)?.bundleIdentifier)
        }) {
            NSRunningApplication(processIdentifier: backgroundWindow.processID)?.activate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            return "Your last click opened \(backgroundWindow.title.isEmpty ? "something" : "\"\(backgroundWindow.title.prefix(100))\"") in \(backgroundWindow.appName) behind the app you were in, so Dottie brought \(backgroundWindow.appName) to the front. It's on this screenshot now. Don't click that link again."
        }
        guard let frontWindow = changedWindows.first(where: { $0.processID == frontmostProcessID }) else { return nil }
        return "Your last click changed the window to \"\(frontWindow.title.prefix(100))\" (a new page or tab). That's what this screenshot shows."
    }

    private static func describeFrontmostWindow() -> String {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return "" }
        var description = "Frontmost app: \(frontmostApplication.localizedName ?? "unknown")"
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
           let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedWindowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String, !title.isEmpty {
                description += ", window: \(title.prefix(120))"
            }
        }
        return description + "."
    }

    // MARK: - Gemini

    private static let systemInstruction = """
    You operate the user's Mac to finish a task they asked for, one or a few actions at a time. Each turn you get a fresh screenshot of the screen they're working on; reply only with function calls.

    How to work:
    - Work toward what the user really wants done, not just the first click. "Sign in with this account" is done when they're signed in (the account's picture or name shows and the sign-in page is gone), not when the account is clicked. "Send it to sam" is done when it shows as sent.
    - For a longer job, call plan (goal, done_when, 3-6 short steps) together with your first action. As you go, call plan again with current_step, or with new steps when the screen changes things. Expect detours and go through them: "choose an account", "continue as", consent and "allow access" screens, "stay signed in?", cookie banners, a code or 2-step check, a saved password the browser or keychain offers (click it).
    - Look at the screenshot carefully before acting. Click things by their box on the screenshot (box_2d: [ymin, xmin, ymax, xmax], 0-1000 across the image).
    - To use an app, call open_app with its name (it comes to the front). To visit a site in a browser that's already open, click its address bar (or press cmd+l), type the address or search and press return. If the user named a browser, use that browser.
    - To type into a field, pass the field's box_2d to type_text so it's clicked first; use press_enter to submit.
    - Prefer keyboard shortcuts when one exists, they never miss: close tab cmd+w, new tab cmd+t, reopen closed tab cmd+shift+t, next/previous tab ctrl+tab / ctrl+shift+tab, address bar cmd+l, reload cmd+r, back cmd+[, find cmd+f, close window cmd+shift+w.
    - After an action that loads something, the next screenshot shows the result; use wait if it's still loading.
    - Scroll to find things that aren't visible. Prefer obvious, direct paths: menus, tabs, search boxes, profile pages.
    - When the task names several things ("merge PR 36 and 37", "reply to sam, then anna"), do them one at a time in exactly the order the user gave, even when a later one is listed first on screen or is easier to reach. Finish one completely before starting the next.
    - Every turn, check the new screenshot against the task before acting: what's already done? If the step you were on already happened (the chat is open, the text is typed, the page loaded), move on to the next step instead of doing it again.
    - To watch a video or reel once (\"watch it, then like it\"), start it, call wait_for_video_end, and go on when it returns.
    - Expect hiccups: popups and cookie banners (close them or press escape), slow pages (wait once, then reload or go another way), search results that don't show (press return, or click the result that's there), things not where you expected (scroll, use the app's search, or its menu bar). If an action didn't change the screen, never repeat it as is: try something else.
    - Don't give up when something isn't where you expected. It's usually a click or two away: another tab, a menu or the menu bar, a sidebar, further down, the site's or app's own search, or another page. When you don't know where something lives or how a site or app does it, call search_web (like "where are releases on a github repo" or "how to turn on subtitles in vlc") and follow what it says. Try at least three different ways before deciding it can't be done.
    - Before finish, check the done_when on the latest screenshot (one taken after your last action) and say what shows it in done_check. If it isn't met, don't finish: keep going.
    - When the task is done, call finish with the answer for the user: one or two short, plain sentences with the actual result (like "you're ranked 312th in the RSNA knee competition"). Also call finish if you truly can't go on (a captcha, or you've tried several ways), saying what you tried and why it stopped.
    - Ask only when you must, with ask_user, once, in one short line: something only the user knows (which account when several fit and the task doesn't say, a password nobody saved, a code sent to their phone), something only they can do (Touch ID, their Mac password), or before a risky step the task didn't clearly ask for (paying, sending, posting, deleting, changing account settings). Then carry on with the answer. Never ask about anything you can see or work out.

    Safety:
    - Signing in is fine when the user asks for it: use the account they named and passwords the browser or keychain fills in (an autofill list, a key icon, a field that's already filled). Never type a password the user hasn't given you, and never type payment details.
    - Don't buy anything, send or post messages, delete things, or change account settings unless the task explicitly asks for exactly that; when it isn't clear, ask_user first.
    - Stay on the task; don't open unrelated things.
    """

    private static let gameInstruction = """

    Game mode: the user asked you to play or do something inside a video game. It's live, so act in short bursts and look again:
    - To get to something, call walk_to with the character's box and the target's box: Dottie works out which keys to hold and for how long, and learns the game's speed. Keep calling walk_to (with fresh boxes each turn) until it says you're on it, then pick up or use the thing (press_keys e, or click it). view is top_down when the camera looks down on the map (w moves up the screen), behind when it's a 3D camera behind the character.
    - Other movement with hold_keys: w forward, s back, a and d sideways, space jump, w+shift to sprint, for 0.2-2 seconds at a time. Single presses (e to pick up or interact, 1-9 for hotbar slots, space to jump) use press_keys.
    - Turn the camera with move_mouse: in Roblox and most third-person games hold the right button (button "right"); in first-person games where the mouse turns the view, use button "none". dx 100 is about a tenth of the screen; positive dx turns right, positive dy looks down.
    - Click on-screen buttons, menus and items with click. If keys seem to do nothing, click the game once to focus it.
    - Reference pictures show the exact items the user means: match them by shape and color, not just by name.
    - One or two actions per turn. If nothing changes after several tries, try another way (jump, go around, turn), and finish saying what blocked you if you can't get there.
    - Never spend real money or in-game currency (Robux, gems), trade, or chat with other players unless the task says exactly that.
    """

    private static var gameFunctionDeclarations: [[String: Any]] {
        let boxProperty: [String: Any] = [
            "type": "array",
            "items": ["type": "integer"],
            "description": "[ymin, xmin, ymax, xmax] on the latest screenshot, each 0-1000."
        ]
        return [
            [
                "name": "walk_to",
                "description": "Walk the player's character to something in the game. Give the character's box and the target's box on the latest screenshot; Dottie holds the right keys for the right time. Call again each turn with fresh boxes until it says you're on it.",
                "parameters": ["type": "object", "properties": [
                    "player_box_2d": boxProperty,
                    "target_box_2d": boxProperty,
                    "view": ["type": "string", "enum": ["top_down", "behind"], "description": "top_down when the camera looks down on the map; behind for a 3D camera behind the character."]
                ], "required": ["target_box_2d", "view"]]
            ],
            [
                "name": "hold_keys",
                "description": "Hold keys down together for a while, to move in a game: 'w' to walk forward, 'w+shift' to sprint, 'a', 'd', 's', 'space'.",
                "parameters": ["type": "object", "properties": [
                    "keys": ["type": "string"],
                    "seconds": ["type": "number", "description": "0.05-5; short bursts of 0.2-2 work best."]
                ], "required": ["keys", "seconds"]]
            ],
            [
                "name": "move_mouse",
                "description": "Move the mouse to turn the camera or aim in a game. dx and dy are 0-1000 across the screenshot (100 is a tenth of the screen); positive dx turns right, positive dy looks down.",
                "parameters": ["type": "object", "properties": [
                    "dx": ["type": "integer"],
                    "dy": ["type": "integer"],
                    "button": ["type": "string", "enum": ["right", "left", "none"], "description": "right for Roblox and most third-person games, none for first-person mouse look."],
                    "seconds": ["type": "number", "description": "How long the move takes, 0.1-3; default 0.4."],
                    "box_2d": [
                        "type": "array",
                        "items": ["type": "integer"],
                        "description": "Where to start the move; leave out for the middle of the screen."
                    ]
                ], "required": ["dx", "dy", "button"]]
            ],
        ]
    }

    private static var functionDeclarations: [[String: Any]] {
        let boxProperty: [String: Any] = [
            "type": "array",
            "items": ["type": "integer"],
            "description": "[ymin, xmin, ymax, xmax] of the element on the latest screenshot, each 0-1000."
        ]
        return [
            [
                "name": "open_app",
                "description": "Open a Mac app by name, or bring it to the front if it's already running.",
                "parameters": ["type": "object", "properties": ["name": ["type": "string", "description": "The app's name, like 'Opera GX', 'Safari', 'Notes'."]], "required": ["name"]]
            ],
            [
                "name": "open_url",
                "description": "Open a web address in a new tab.",
                "parameters": ["type": "object", "properties": [
                    "url": ["type": "string"],
                    "browser": ["type": "string", "description": "Browser app to use if the user named one, like 'Opera GX'. Leave out to use the browser the user is using."]
                ], "required": ["url"]]
            ],
            [
                "name": "click",
                "description": "Click an element on the latest screenshot.",
                "parameters": ["type": "object", "properties": [
                    "box_2d": boxProperty,
                    "label": ["type": "string", "description": "The element's visible text or a short name."],
                    "double_click": ["type": "boolean"],
                    "right_click": ["type": "boolean"]
                ], "required": ["box_2d", "label"]]
            ],
            [
                "name": "type_text",
                "description": "Type text. With box_2d, clicks that field first; otherwise types into whatever is focused.",
                "parameters": ["type": "object", "properties": [
                    "text": ["type": "string"],
                    "box_2d": boxProperty,
                    "select_all_first": ["type": "boolean", "description": "Replace what's already in the field."],
                    "press_enter": ["type": "boolean", "description": "Press return after typing, to submit or search."]
                ], "required": ["text"]]
            ],
            [
                "name": "press_keys",
                "description": "Press a key or shortcut, like 'enter', 'escape', 'tab', 'cmd+l', 'cmd+t', 'cmd+[' (back).",
                "parameters": ["type": "object", "properties": ["keys": ["type": "string"]], "required": ["keys"]]
            ],
            [
                "name": "scroll",
                "description": "Scroll the content under box_2d (or the middle of the screen).",
                "parameters": ["type": "object", "properties": [
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "amount": ["type": "integer", "description": "1-10; about 5 is a screenful."],
                    "box_2d": boxProperty
                ], "required": ["direction"]]
            ],
            [
                "name": "wait",
                "description": "Wait for something to load (a few seconds), or up to 120 seconds when you know how long something takes.",
                "parameters": ["type": "object", "properties": ["seconds": ["type": "number"]], "required": ["seconds"]]
            ],
            [
                "name": "zoom",
                "description": "Take a closer, sharper look at part of the screen (small text, icons, items far away). The close-up comes with the next screenshot.",
                "parameters": ["type": "object", "properties": ["box_2d": boxProperty], "required": ["box_2d"]]
            ],
            [
                "name": "save_picture",
                "description": "Save a picture of something on the screen to remember it by name for later jobs (where a machine is on a game map, what an item looks like). Only when the task asks to remember something, or when it will clearly be needed again.",
                "parameters": ["type": "object", "properties": [
                    "name": ["type": "string", "description": "1-4 words, like 'roll machines'."],
                    "description": ["type": "string", "description": "What it is, where it's from (game or app, which area) and how it looks."],
                    "box_2d": boxProperty
                ], "required": ["name", "description"]]
            ],
            [
                "name": "wait_for_video_end",
                "description": "Wait until the video or reel playing in the browser has played through once (reels loop, so this notices when it starts over), then carry on. Use it when the task says to watch something, play it once, or do something after a video ends.",
                "parameters": ["type": "object", "properties": [
                    "max_seconds": ["type": "number", "description": "Give up after this long; default 600."]
                ]]
            ],
            [
                "name": "search_web",
                "description": "Search the web when you don't know where something is or how to do it in this app or site. Returns the top results and the text of the best page.",
                "parameters": ["type": "object", "properties": [
                    "query": ["type": "string", "description": "What to look up, like 'where is the download button on github releases'."]
                ], "required": ["query"]]
            ],
            [
                "name": "plan",
                "description": "Write down or update the plan for a longer job: the user's real goal, what the screen shows once it's truly done, and 3-6 short steps. Call it with your first action, then again with current_step as you move on, or with new steps when the screen changes the plan. It doesn't touch the screen.",
                "parameters": ["type": "object", "properties": [
                    "goal": ["type": "string", "description": "What the user really wants done, like 'get signed in to YouTube with the work account'."],
                    "done_when": ["type": "string", "description": "What the screen shows once it's really done, like 'the work account's picture shows at the top right and no sign-in page is left'."],
                    "steps": ["type": "array", "items": ["type": "string"], "description": "3-6 short steps, a few words each."],
                    "current_step": ["type": "integer", "description": "The step you're on now, from 1."]
                ]]
            ],
            [
                "name": "ask_user",
                "description": "Ask the user one short question and wait for the answer, only when you can't go on without it: which account, a password nobody saved, a code sent to them, Touch ID or something only they can do, or okay for a risky step the task didn't clearly ask for.",
                "parameters": ["type": "object", "properties": [
                    "question": ["type": "string", "description": "One short, friendly line, like 'Which account, work or personal?'."],
                    "kind": ["type": "string", "enum": ["missing_info", "password", "code", "confirm", "do_it_yourself"], "description": "password or code when they'll tell you one (it stays hidden from you); do_it_yourself when they have to do something on the Mac (Touch ID, type it themselves); confirm for okay to go ahead."]
                ], "required": ["question", "kind"]]
            ],
            [
                "name": "finish",
                "description": "End the task. answer is what Dottie tells the user: the result they asked for, or why it couldn't be done. One or two short sentences.",
                "parameters": ["type": "object", "properties": [
                    "answer": ["type": "string"],
                    "done_check": ["type": "string", "description": "What on the latest screenshot shows the job is really done (its done_when), like 'the work account's picture is at the top right'."],
                    "succeeded": ["type": "boolean", "description": "true if the task got done, false if it couldn't be."],
                    "lesson": ["type": "string", "description": "One short tip for doing this kind of job in this app or site next time: the path that worked, or what to avoid. Leave empty if it was straightforward."]
                ], "required": ["answer"]]
            ]
        ]
    }

    private func requestNextActions(contents: [[String: Any]]) async throws -> [[String: Any]] {
        if isGameMode, let lastRequestStartedAt {
            let waitSeconds = Self.minimumGameRequestSpacingSeconds + lastRequestStartedAt.timeIntervalSinceNow
            if waitSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            }
        }
        lastRequestStartedAt = Date()
        do {
            return try await requestNextActionsOnce(contents: contents)
        } catch let error as NSError where error.code == 400 && error.localizedDescription.localizedCaseInsensitiveContains("signature") {
            // The Worker answers with another model when the first is busy,
            // and Gemini 3 can reject a function call signed by a different
            // model. Google's documented placeholder skips that check.
            print("⚠️ Screen task: retrying without thought signatures")
            return try await requestNextActionsOnce(contents: Self.contentsWithPlaceholderSignatures(contents))
        }
    }

    private static func contentsWithPlaceholderSignatures(_ contents: [[String: Any]]) -> [[String: Any]] {
        contents.map { content in
            guard let parts = content["parts"] as? [[String: Any]] else { return content }
            var updatedContent = content
            updatedContent["parts"] = parts.map { part in
                guard part["thoughtSignature"] != nil else { return part }
                var updatedPart = part
                updatedPart["thoughtSignature"] = "skip_thought_signature_validator"
                return updatedPart
            }
            return updatedContent
        }
    }

    private func requestNextActionsOnce(contents: [[String: Any]]) async throws -> [[String: Any]] {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        // A step normally takes 2-8s. One stuck in Google's queue (seen at
        // 50-90s) is dropped and asked again on another model, which is
        // usually much quicker than waiting it out.
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let requestModel = jobModel ?? (isGameMode ? Self.gameModel : Self.taskModel)
        var requestContents = Self.recentSteps(of: contents)
        if !referenceImageParts.isEmpty, var firstParts = requestContents.first?["parts"] as? [[String: Any]] {
            firstParts.insert(contentsOf: referenceImageParts, at: 0)
            requestContents[0]["parts"] = firstParts
        }
        var requestBody: [String: Any] = [
            "model": requestModel,
            "systemInstruction": ["parts": [["text": Self.systemInstruction + (isGameMode ? Self.gameInstruction : "")]]],
            "contents": requestContents,
            "tools": [["functionDeclarations": Self.functionDeclarations + (isGameMode ? Self.gameFunctionDeclarations : [])]],
            "toolConfig": ["functionCallingConfig": ["mode": "ANY"]]
        ]
        // A step is a quick look-and-act decision; the plan and done check
        // carry the long thinking. Only the full Flash models take a
        // thinking level (Teaching sets it the same way).
        if requestModel.contains("flash") && !requestModel.contains("lite") {
            requestBody["generationConfig"] = ["thinkingConfig": ["thinkingLevel": "low"]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, response) = try await DottieModelPicker.shared.data(for: request, model: requestModel, totalSeconds: Self.stepAnswerDeadlineSeconds)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            throw NSError(domain: "DottieScreenTaskRunner", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Gemini returned \(statusCode): \(String(decoding: responseData.prefix(300), as: UTF8.self))"
            ])
        }

        // /chat streams server-sent events; gather every part, keeping each
        // function call whole with its thought signature (Gemini needs it
        // back on the next turn).
        let modelParts = GeminiServerSentEvents.parts(from: responseData)
        guard !modelParts.isEmpty else {
            throw NSError(domain: "DottieScreenTaskRunner", code: -2, userInfo: [NSLocalizedDescriptionKey: "empty answer"])
        }
        return modelParts
    }

    /// Steps whose results are re-sent with every request. Older ones are
    /// left out (the first turn, with the task, always stays), so a long
    /// job doesn't re-read its whole history at every step.
    private static let keptRecentStepCount = 10

    /// The task turn plus the last few steps. Each step is a model turn and
    /// the user turn answering it, so dropping them in pairs keeps every
    /// function call next to its response.
    private static func recentSteps(of contents: [[String: Any]]) -> [[String: Any]] {
        let keptEntryCount = keptRecentStepCount * 2
        guard contents.count > 1 + keptEntryCount else { return contents }
        let droppedEntryCount = contents.count - 1 - keptEntryCount
        let evenDroppedEntryCount = droppedEntryCount - droppedEntryCount % 2
        guard evenDroppedEntryCount > 0 else { return contents }
        var trimmedContents = [contents[0]] + Array(contents.dropFirst(1 + evenDroppedEntryCount))
        if var firstParts = trimmedContents[0]["parts"] as? [[String: Any]] {
            firstParts.append(["text": "(\(evenDroppedEntryCount / 2) earlier steps are left out; the screen and notes since then show where things stand.)"])
            trimmedContents[0]["parts"] = firstParts
        }
        return trimmedContents
    }

    /// Keeps only the newest screenshots in the conversation.
    private static func dropOldScreenshots(from contents: inout [[String: Any]]) {
        var screenshotsSeen = 0
        for contentIndex in contents.indices.reversed() {
            guard var parts = contents[contentIndex]["parts"] as? [[String: Any]] else { continue }
            var didChange = false
            for partIndex in parts.indices.reversed() where parts[partIndex]["inlineData"] != nil {
                screenshotsSeen += 1
                if screenshotsSeen > keptScreenshotCount {
                    parts[partIndex] = ["text": "(older screenshot removed)"]
                    didChange = true
                }
            }
            if didChange {
                contents[contentIndex]["parts"] = parts
            }
        }
    }
}

// MARK: - Screen capture

/// One display captured without Dottie's own windows (cursor, notch,
/// drawings), with what's needed to map 0-1000 positions back to the screen.
@MainActor
enum DottieDisplayCapture {
    struct Screenshot {
        let image: CGImage
        let jpegData: Data
        /// The display's frame in global AppKit coordinates.
        let displayFrame: CGRect

        /// A 0-1000 position on the screenshot, in global AppKit points.
        func globalPoint(normalizedX: Double, normalizedY: Double) -> CGPoint {
            let clampedX = min(max(normalizedX, 0), 1000) / 1000
            let clampedY = min(max(normalizedY, 0), 1000) / 1000
            return CGPoint(
                x: displayFrame.minX + CGFloat(clampedX) * displayFrame.width,
                y: displayFrame.maxY - CGFloat(clampedY) * displayFrame.height
            )
        }
    }

    /// The display with the frontmost app's window, else the one with the
    /// pointer.
    static func captureActiveDisplay(maximumDimension: Int) async -> Screenshot? {
        let displayFrame = frontmostWindowDisplayFrame()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame
            ?? NSScreen.main?.frame
        guard let displayFrame else { return nil }
        return await capture(displayFrame: displayFrame, maximumDimension: maximumDimension)
    }

    static func capture(displayFrame: CGRect, maximumDimension: Int) async -> Screenshot? {
        guard let image = await captureImage(displayFrame: displayFrame, maximumDimension: maximumDimension),
              let jpegData = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        return Screenshot(image: image, jpegData: jpegData, displayFrame: displayFrame)
    }

    static func captureImage(displayFrame: CGRect, maximumDimension: Int) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }

        let matchingScreen = NSScreen.screens.first(where: { $0.frame == displayFrame })
        let displayID = matchingScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        let pointsToPixels = matchingScreen?.backingScaleFactor ?? 2
        let nativeWidth = CGFloat(display.width) * pointsToPixels
        let nativeHeight = CGFloat(display.height) * pointsToPixels
        let downscale = min(1, CGFloat(maximumDimension) / max(nativeWidth, nativeHeight))
        configuration.width = Int(nativeWidth * downscale)
        configuration.height = Int(nativeHeight * downscale)
        configuration.showsCursor = false

        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func frontmostWindowDisplayFrame() -> CGRect? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return nil }
        let focusedWindow = focusedWindowValue as! AXUIElement
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        // Accessibility is top-left origin on the primary display.
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let windowCenter = CGPoint(x: position.x + size.width / 2, y: primaryDisplayHeight - (position.y + size.height / 2))
        return NSScreen.screens.first(where: { $0.frame.contains(windowCenter) })?.frame
    }
}
