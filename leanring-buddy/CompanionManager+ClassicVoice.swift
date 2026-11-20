//
//  CompanionManager+ClassicVoice.swift
//  leanring-buddy
//
//  Classic voice mode (Apple Speech, then Groq talking with Claude Haiku
//  doing requests, then Kokoro),
//  handing a question to the higher model, and reading [POINT:] tags out
//  of an answer. Part of CompanionManager, split out by topic.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

extension CompanionManager {
    // MARK: - Higher Model Hand-off

    /// System prompt for the stronger model that answers send_to_higher_model.
    /// Its text goes back to Gemini Live, which says it out loud.
    private static let higherModelSystemPrompt = """
    you're the careful, thorough brain behind dottie, a voice companion on the user's mac. the fast voice model handed you a question it wanted a closer look at. you get full screenshots of every screen. your answer goes back to the voice model, which will say it out loud to the user.

    rules:
    - answer the question directly and correctly. read small text, code and dense ui carefully.
    - write for the ear: plain sentences, no markdown, no lists, no code blocks. describe code changes in words.
    - be as short as the question allows: usually one to three sentences in plain, friendly words. give precise steps only when steps are needed.
    - if what they want isn't on these screenshots, don't say it's not there or give up: it's usually a click or two away (another tab, a menu, further down, another page of the site or app). say where it most likely is and the first thing to click to get there, and point at that. if you can't tell from the screen, say so and suggest searching the web for it; never make up what isn't visible.

    pointing: if pointing at one ui element would help, append a tag at the very end: [POINT:x,y:label] with integer pixel coordinates in that screenshot's coordinate space (top-left is 0,0; images are labeled with their dimensions), and :screenN if it isn't on the cursor screen. otherwise append [POINT:none].
    """

    /// Answers a hand-off from Gemini Live with a stronger model and fresh
    /// screenshots. Points the cursor if the answer says to, and returns the
    /// text for Live to speak. Errors come back as instructions for Live to
    /// relay, so the user always hears something.
    /// Answered the box and text probes in about 2s when the default models
    /// stalled (checked on a Mac runner, Oct 2026).
    nonisolated private static let quickBackupModel = "gemini-3.5-flash"

    /// Runs primary; if it hasn't answered after backupAfterSeconds, starts
    /// backup too and returns whichever answers first.
    nonisolated private static func firstAnswer<Answer: Sendable>(
        backupAfterSeconds: Double,
        primary: @escaping @Sendable () async throws -> Answer,
        backup: @escaping @Sendable () async throws -> Answer
    ) async throws -> Answer {
        try await withThrowingTaskGroup(of: Answer.self) { group in
            group.addTask { try await primary() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(backupAfterSeconds * 1_000_000_000))
                return try await backup()
            }
            var firstError: Error?
            while !group.isEmpty {
                do {
                    let nextAnswer = try await group.next()
                    if let nextAnswer {
                        group.cancelAll()
                        return nextAnswer
                    }
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            throw firstError ?? CancellationError()
        }
    }

    func answerWithHigherModel(question: String) async -> String {
        DottieLog.notice("🧠 Higher model hand-off: \(question)")
        ClickyAnalytics.trackHigherModelHandoff()

        do {
            // Sharp enough to read small print and exponents: at 1280 px a
            // Retina screen's superscripts are a few pixels tall (3 read as 2).
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(maximumDimension: 2560)
            let labeledImages = labeledScreenImages(from: screenCaptures, annotation: currentTurnAnnotation)
            // The last few exchanges are enough context for one hard
            // question, and every screen image already rides along.
            let historyForAPI = conversationHistory.suffix(6).map { entry in
                (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
            }

            // The smart model sometimes sits in Google's queue for a minute
            // or more; if it hasn't answered in 20s, a quick model races it.
            let geminiAPI = self.geminiAPI
            let higherModelSystemPrompt = Self.higherModelSystemPrompt
            let askModel: @Sendable (String) async throws -> (text: String, duration: TimeInterval) = { modelName in
                try await geminiAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: higherModelSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: question,
                    modelOverride: modelName,
                    maxOutputTokens: 2048,
                    onTextChunk: { _ in }
                )
            }
            // The fastest model that's good enough and not busy right now.
            let primaryModel = DottieModelPicker.shared.pick(await DottieModelPicker.tier(forQuestion: question))
            let backupModel = DottieModelPicker.shared.isCoolingDown(Self.quickBackupModel)
                ? DottieModelPicker.shared.pick(.normal, avoiding: [primaryModel])
                : Self.quickBackupModel
            let (fullResponseText, responseDuration) = try await Self.firstAnswer(
                backupAfterSeconds: 20,
                primary: { try await askModel(primaryModel) },
                backup: { try await askModel(backupModel) }
            )
            DottieLog.notice("🧠 Higher model answered in \(Int(responseDuration * 1000))ms")

            let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
            let targetScreenCapture: CompanionScreenCapture? = {
                if let screenNumber = parseResult.screenNumber,
                   screenNumber >= 1 && screenNumber <= screenCaptures.count {
                    return screenCaptures[screenNumber - 1]
                }
                return screenCaptures.first(where: { $0.isCursorScreen })
            }()
            if let pointCoordinate = parseResult.coordinate, let targetScreenCapture, isLiveTurnInFlight {
                detectedElementScreenLocation = Self.globalScreenLocation(
                    forScreenshotPixel: pointCoordinate,
                    in: targetScreenCapture
                )
                detectedElementDisplayFrame = targetScreenCapture.displayFrame
                ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
            }

            let answerText = parseResult.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            return answerText.isEmpty
                ? "the deeper look came back empty. tell the user briefly and answer as best you can from what you see."
                : answerText
        } catch {
            DottieLog.warning("⚠️ Higher model hand-off failed: \(error)")
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            return "the deeper look failed (\(error.localizedDescription)). tell the user in one short line, then answer as best you can from what you see."
        }
    }

    // MARK: - Classic Voice Pipeline (Apple Speech → Groq / Claude → Kokoro)

    /// Captures a screenshot, sends it along with the transcript to Gemini,
    /// and plays the response aloud via Gemini TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// The response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    func sendTranscriptToGeminiWithScreenshot(
        transcript: String,
        inputKind: ConversationEntry.InputKind = .voice,
        checksInstantLane: Bool = true
    ) {
        // Typed turns were already checked in sendTypedMessage.
        if inputKind == .voice && DottieAdminMode.shared.handleSecretPhraseIfSaid(transcript, companionManager: self) {
            voiceState = .idle
            return
        }
        if inputKind == .voice, checksInstantLane, isInstantLaneAllowedNow,
           DottieInstantLane.shared.plan(for: transcript) != nil || DottieNeedleRouter.shared.isAvailable {
            tryInstantLaneBeforeClassicTurn(transcript: transcript)
            return
        }
        currentClassicTurnInputKind = inputKind
        notchPresenter.updateLiveCaption("")
        currentResponseTask?.cancel()
        stopAllSpeechPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Groq talks: small talk it answers itself; anything else
                // goes to Claude, with the screen only when Groq says so.
                // A turn where the user circled something is about the screen.
                let turnAnnotation = inputKind == .voice ? currentTurnAnnotation : nil
                let personalityLine = selectedPersonality.promptSection
                let talkDecision: DottieTalkDecision = turnAnnotation != nil
                    ? .request(needsScreen: true)
                    : await DottieTalker.decide(transcript: transcript, exchanges: conversationHistory, personalityLine: personalityLine)

                guard !Task.isCancelled else { return }

                var screenCaptures: [CompanionScreenCapture] = []
                let fullResponseText: String
                switch talkDecision {
                case .say(let talkerAnswer):
                    fullResponseText = talkerAnswer
                case .request(let needsScreen):
                    var labeledImages: [(data: Data, label: String)] = []
                    if needsScreen {
                        screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                        labeledImages = labeledScreenImages(from: screenCaptures, annotation: turnAnnotation)
                    }
                    let promptForModel = turnAnnotation == nil
                        ? transcript
                        : "\(transcript)\n\n(\(ScreenAnnotation.modelContextText))"
                    let requestToolDeclarations = DottieTalkerProtocol.requestToolDeclarations(
                        from: GeminiLiveVoiceClient.everyFunctionDeclaration,
                        findAndUseDeclarations: [GeminiLiveToolCatalog.findToolFunctionDeclaration, GeminiLiveToolCatalog.useToolFunctionDeclaration]
                    )
                    let liveToolRunner = liveVoiceClient
                    fullResponseText = try await DottieTalker.answerRequest(
                        transcript: promptForModel,
                        exchanges: conversationHistory,
                        labeledImages: labeledImages,
                        systemPrompt: DottieTalkerProtocol.requestSystemPrompt(personalityLine: personalityLine, profile: brain.profileForPrompt),
                        toolDeclarations: requestToolDeclarations,
                        runTool: { functionName, functionArguments in
                            await liveToolRunner.runToolForTextBrain(functionName: functionName, arguments: functionArguments)
                        }
                    )
                }

                guard !Task.isCancelled else { return }

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. The spinner
                // hides the triangle otherwise.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                pointAtElement(from: parseResult, screenCaptures: screenCaptures)

                // Save the exchange with the point tag stripped so it doesn't
                // confuse future context.
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))
                if conversationHistory.count > Self.rememberedExchangeCount {
                    conversationHistory.removeFirst(conversationHistory.count - Self.rememberedExchangeCount)
                }

                DottieLog.notice("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                brain.record(.chat, "user: \(transcript)\ndottie: \(spokenText)")
                conversationStore.append(
                    userText: transcript,
                    clickyText: spokenText,
                    inputKind: currentClassicTurnInputKind
                )
                notchPresenter.updateLiveCaption(spokenText)

                // Keep the spinner until audio actually starts playing.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Kokoro on the Mac (no AI service), then macOS's own voice.
                    // While Kokoro is still downloading or loading, the Mac's
                    // voice answers right away instead of leaving silence.
                    if !DottieKokoroSpeaker.shared.isReady {
                        DottieLog.notice("🗣️ Kokoro isn't loaded yet, using the system voice")
                        DottieKokoroSpeaker.shared.prepare()
                        speakWithSystemVoice(spokenText)
                    } else {
                        do {
                            try await DottieKokoroSpeaker.shared.speak(spokenText)
                            voiceState = .responding
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                            DottieLog.warning("⚠️ Kokoro couldn't speak, using the system voice: \(error.localizedDescription)")
                            speakWithSystemVoice(spokenText)
                        }
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                DottieLog.warning("⚠️ Companion response error: \(error)")
                doOnMacOrSpeakConnectionError(requestText: transcript, inputKind: currentClassicTurnInputKind)
            }

            if !Task.isCancelled {
                voiceState = .idle
                notchPresenter.showFinishedResponse(notchPresenter.liveCaptionText)
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// A spoken classic turn that might be instant: the instant lane (and
    /// Needle) get the first try, and the turn only goes to Gemini when
    /// they have nothing for it.
    private func tryInstantLaneBeforeClassicTurn(transcript: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let instantPlan = await DottieInstantLane.shared.planIncludingNeedle(for: transcript) else {
                self.sendTranscriptToGeminiWithScreenshot(transcript: transcript, inputKind: .voice, checksInstantLane: false)
                return
            }
            switch await DottieInstantLane.shared.run(instantPlan) {
            case .done(let doneText):
                self.finishInstantLaneTurn(userText: transcript, doneText: doneText, inputKind: .voice)
            case .askGemini:
                self.sendTranscriptToGeminiWithScreenshot(transcript: transcript, inputKind: .voice, checksInstantLane: false)
            }
        }
    }

    /// Flies the cursor to the element the model's [POINT:] tag names, on
    /// the screen the tag says (or the one the cursor is on).
    private func pointAtElement(from parseResult: PointingParseResult, screenCaptures: [CompanionScreenCapture]) {
        // Pick the screen capture matching the screen number,
        // falling back to the cursor screen if not specified.
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = parseResult.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        if let pointCoordinate = parseResult.coordinate,
           let targetScreenCapture {
            detectedElementScreenLocation = Self.globalScreenLocation(
                forScreenshotPixel: pointCoordinate,
                in: targetScreenCapture
            )
            detectedElementDisplayFrame = targetScreenCapture.displayFrame
            ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
            DottieLog.notice("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
        } else {
            DottieLog.notice("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from the model's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if the model said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of the model's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }
}
