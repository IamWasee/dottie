//
//  CompanionManager+TypedAndInstant.swift
//  leanring-buddy
//
//  Typed messages from the notch and Home, the instant lane that answers
//  without AI, and stopping everything with Escape. Part of
//  CompanionManager, split out by topic.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

extension CompanionManager {
    // MARK: - Notch and Typed Messages

    func configureNotch() {
        configureClickyRoster()
        notchPresenter.onSubmitTypedMessage = { [weak self] messageText in
            guard let self else { return }
            // Typed in the notch: the answer shows as text unless the user
            // wants it read out (DottieTypeBar).
            DottieEveryday.shared.typeBar.remember(messageText)
            self.liveVoiceClient.isAudioOutputMuted = !DottieTypeBar.speaksAnswers
            self.sendTypedMessage(messageText)
        }
        DottieEveryday.shared.attach(to: self)
        notchPresenter.onOpenHome = { [weak self] in
            self?.openHomeWindow()
        }
        notchPresenter.onStopScreenTask = { [weak self] in
            // The same stop button serves jobs and guides.
            self?.stopScreenTask()
            self?.stopGuide()
            if self?.smartHome.tvTaskRunner.stop() == true {
                self?.noteStoppedJob("the TV job")
            }
        }
        notchPresenter.onOpenPeekFile = { [weak self] peekFile in
            self?.notchPresenter.isHovering = false
            NSWorkspace.shared.open(peekFile.url)
        }
        notchPresenter.onRevealPeekFile = { [weak self] peekFile in
            self?.notchPresenter.isHovering = false
            NSWorkspace.shared.activateFileViewerSelecting([peekFile.url])
        }

        // The files row is ready before the first hover, and checked again
        // each time the peek opens in case a Dot wrote something since.
        refreshNotchPeekFiles()
        notchHoverCancellable = notchPresenter.$isHovering
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.refreshNotchPeekFiles()
            }

        // Mirror the voice state onto the notch.
        notchVoiceStateCancellable = $voiceState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVoiceState in
                guard let self else { return }
                switch newVoiceState {
                case .listening:
                    self.notchPresenter.showListening()
                case .processing:
                    self.notchPresenter.showThinking()
                case .responding:
                    self.notchPresenter.showSpeaking()
                case .idle:
                    // The finished-answer card is shown by the pipelines
                    // themselves; an idle with no answer (e.g. a tap with
                    // nothing said) just folds the notch back up.
                    // Classic mode goes responding → idle in one go, and this
                    // sink runs a moment later, so "speaking" can land after
                    // the finished card and never leave. Turn it into the
                    // finished card, which dismisses itself.
                    if self.notchPresenter.surface == .speaking {
                        self.notchPresenter.showFinishedResponse(self.notchPresenter.liveCaptionText)
                    }
                    if self.notchPresenter.surface == .listening || self.notchPresenter.surface == .thinking {
                        if !self.isLiveTurnInFlight && self.currentResponseTask == nil {
                            self.notchPresenter.collapse()
                        }
                    }
                }
            }

        if hasCompletedOnboarding && isNotchEnabled {
            notchWindowManager.show()
        }
    }

    /// Sends a typed message (from the notch or Home) as a turn, with a
    /// screenshot like a spoken one. Clicky answers out loud as usual.
    /// A typed message with pictures: each is saved to image memory (named
    /// and described by Gemini) first, then the message tells Live what was
    /// saved, so "go grab that sword" works now and in later sessions.
    func sendTypedMessage(_ messageText: String, imageDataList: [Data]) {
        guard !imageDataList.isEmpty else {
            sendTypedMessage(messageText)
            return
        }
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        notchPresenter.showThinking(label: "looking at your picture")
        Task { [weak self] in
            guard let self else { return }
            var savedItems: [DottieImageMemory.Item] = []
            for imageData in imageDataList {
                if let savedItem = await self.imageMemory.add(imageData: imageData, userText: trimmedMessageText) {
                    savedItems.append(savedItem)
                }
            }
            guard !savedItems.isEmpty else {
                self.notchPresenter.collapse()
                if !trimmedMessageText.isEmpty { self.sendTypedMessage(trimmedMessageText) }
                return
            }
            self.liveVoiceClient.baseSystemInstruction = self.currentLiveSystemPrompt()
            let pictureNotes = savedItems.map { item in
                "\"\(item.name)\"" + (item.description.isEmpty ? "" : " (\(item.description))")
            }.joined(separator: ", ")
            let turnText = "[the user added \(savedItems.count == 1 ? "a picture" : "pictures"), now saved as \(pictureNotes). "
                + "when they ask about it or to find, point at or grab it, pass its name to do_task_on_screen's reference_images, or use it as the label when pointing.] "
                + (trimmedMessageText.isEmpty ? "say in a few words that you've saved it and what it is." : trimmedMessageText)
            let recordedText = trimmedMessageText.isEmpty ? "(picture)" : trimmedMessageText
            self.currentTurnImageFileNames = savedItems.map(\.fileName)
            self.sendTypedMessage(recordedText, turnText: turnText)
        }
    }

    func sendTypedMessage(_ messageText: String, turnText: String? = nil) {
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessageText.isEmpty else { return }
        guard !buddyDictationManager.isDictationInProgress else { return }
        // A typed secret phrase opens Home → Admin without ever reaching Gemini.
        if turnText == nil && DottieAdminMode.shared.handleSecretPhraseIfSaid(trimmedMessageText, companionManager: self) {
            return
        }
        if turnText == nil { currentTurnImageFileNames = [] }
        // Open an app, move a window, a learned shortcut: done on the Mac,
        // with Gemini only if it turns out not to fit.
        if turnText == nil, let instantPlan = instantLanePlanIfAllowed(for: trimmedMessageText) {
            runTypedInstantPlan(instantPlan, messageText: trimmedMessageText)
            return
        }
        // Wording the strict lane doesn't know: Needle has a quick look
        // (a fraction of a second) before Gemini.
        if turnText == nil, isInstantLaneAllowedNow, DottieNeedleRouter.shared.isAvailable {
            Task { [weak self] in
                guard let self else { return }
                if let needlePlan = await DottieNeedleRouter.shared.plan(for: trimmedMessageText) {
                    self.runTypedInstantPlan(needlePlan, messageText: trimmedMessageText)
                    return
                }
                self.currentLiveTurnNamedShortcutName = DottieInstantLane.shared.namedShortcutRequest(in: trimmedMessageText)?.name
                self.sendTypedMessageToGemini(trimmedMessageText, turnText: nil)
            }
            return
        }
        if turnText == nil { currentLiveTurnNamedShortcutName = DottieInstantLane.shared.namedShortcutRequest(in: trimmedMessageText)?.name }
        sendTypedMessageToGemini(trimmedMessageText, turnText: turnText)
    }

    private func runTypedInstantPlan(_ instantPlan: DottieInstantLane.Plan, messageText: String) {
        Task { [weak self] in
            guard let self else { return }
            switch await DottieInstantLane.shared.run(instantPlan) {
            case .done(let doneText):
                self.finishInstantLaneTurn(userText: messageText, doneText: doneText, inputKind: .typed)
            case .askGemini:
                self.sendTypedMessageToGemini(messageText, turnText: nil)
            }
        }
    }

    private func sendTypedMessageToGemini(_ trimmedMessageText: String, turnText: String?) {
        transientHideTask?.cancel()
        transientHideTask = nil
        showOverlayTransientlyIfNeeded()
        currentResponseTask?.cancel()
        stopAllSpeechPlayback()
        clearDetectedElementLocation()
        lastTranscript = trimmedMessageText
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedMessageText)

        switch voiceMode {
        case .classic:
            sendTranscriptToGeminiWithScreenshot(transcript: turnText ?? trimmedMessageText, inputKind: .typed)
        case .live:
            startLiveTextTurn(recordedUserText: trimmedMessageText, turnText: turnText ?? trimmedMessageText)
        }
    }

    // MARK: - Instant lane (no AI)

    /// Not while a screen job, guide or drawing lesson is listening for
    /// the user's words ("next", "pause" mean something else there).
    var isInstantLaneAllowedNow: Bool {
        hasCompletedOnboarding
            && !screenTaskRunner.isRunning
            && !guide.isActive
            && teachingTask == nil
            && !DottieScreenJobQuestions.shared.wasAskedAloud
    }

    private func instantLanePlanIfAllowed(for requestText: String) -> DottieInstantLane.Plan? {
        guard isInstantLaneAllowedNow else { return nil }
        return DottieInstantLane.shared.plan(for: requestText)
    }

    /// At release: whether what the Mac heard so far might be something it
    /// does itself, so Live's answer is held back while it checks.
    func liveVoiceTurnCouldBeInstant() -> Bool {
        guard isInstantLaneAllowedNow else { return false }
        // Heard by Whistle: there are no words yet, so a short turn is
        // held (instant asks are short) and a long one never waits.
        if !liveTurnOnDeviceTranscriber.isRunning {
            return liveTurnWhistleRecorder.isRecording
                && liveTurnWhistleRecorder.recordedSeconds <= DottieWhistleTurnRecorder.longestHeldTurnSeconds
        }
        return DottieInstantLane.shared.couldBecomeInstant(partialText: liveTurnOnDeviceTranscriber.latestText)
    }

    /// After a voice turn is released: waits a moment for the Mac's
    /// transcript of it. When it's an instant command or a learned
    /// shortcut, Live's answer is silenced and the Mac does it; otherwise
    /// Live's held answer plays as usual.
    func checkInstantLaneAfterLiveVoiceRelease(holdsLiveAnswer: Bool) {
        let whistleAudio = liveTurnWhistleRecorder.takeRecording()
        guard liveTurnOnDeviceTranscriber.isRunning || whistleAudio != nil else {
            liveVoiceClient.isHoldingModelAnswer = false
            return
        }
        let pressNumber = liveVoicePressCount
        Task { [weak self] in
            guard let self else { return }
            let heardText: String
            if let whistleAudio {
                // No Apple speech recognition: Whistle hears the short
                // turn on the Mac (tens of milliseconds).
                heardText = await DottieNeedleRouter.shared.hear(pcm16AudioData: whistleAudio)
            } else {
                // Short while Live's answer waits; longer otherwise, since then
                // nothing is held up and the text is only for learning.
                heardText = await self.liveTurnOnDeviceTranscriber.finishAndWaitForFinalText(
                    timeoutSeconds: holdsLiveAnswer ? 0.6 : 1.5
                )
            }
            guard self.liveVoicePressCount == pressNumber else { return }
            self.currentLiveTurnOnDeviceText = heardText.isEmpty ? nil : heardText

            var instantPlanOrNil = self.instantLanePlanIfAllowed(for: heardText)
            // Needle only while Live's answer is held: otherwise it's
            // already playing and the Mac shouldn't do something else too.
            if instantPlanOrNil == nil, holdsLiveAnswer, self.isInstantLaneAllowedNow {
                instantPlanOrNil = await DottieNeedleRouter.shared.plan(for: heardText)
                guard self.liveVoicePressCount == pressNumber else { return }
            }
            guard let instantPlan = instantPlanOrNil else {
                self.currentLiveTurnNamedShortcutName = DottieInstantLane.shared.namedShortcutRequest(in: heardText)?.name
                self.liveVoiceClient.isHoldingModelAnswer = false
                return
            }

            // Only a turn still running on the server will finish later;
            // its (silenced) end must then be ignored.
            self.currentLiveTurnWasHandledInstantly = self.liveVoiceClient.isModelTurnInProgress
            self.liveVoiceClient.cancelCurrentModelResponse()
            self.liveTurnPlaybackDrainTask?.cancel()
            self.voiceState = .processing
            switch await DottieInstantLane.shared.run(instantPlan) {
            case .done(let doneText):
                self.finishInstantLaneTurn(userText: heardText, doneText: doneText, inputKind: .voice)
            case .askGemini:
                guard self.liveVoicePressCount == pressNumber else { return }
                self.currentLiveTurnWasHandledInstantly = false
                self.startLiveTextTurn(recordedUserText: heardText, turnText: heardText)
            }
        }
    }

    /// "Tell me when the tests finish, then open the report": the watch
    /// fired, so do the "then" part, on the Mac when it's instant, else
    /// through Gemini.
    func runWatchFollowUp(_ followUpText: String, firedText: String) {
        Task { [weak self] in
            guard let self else { return }
            // Don't talk over the user: wait (up to a minute) for a turn in
            // progress to end.
            for _ in 0..<120 {
                let isBusy = self.isLiveTurnInFlight || self.voiceState != .idle || self.buddyDictationManager.isDictationInProgress
                if !isBusy { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if self.isInstantLaneAllowedNow,
               let instantPlan = await DottieInstantLane.shared.planIncludingNeedle(for: followUpText),
               case .done(let doneText) = await DottieInstantLane.shared.run(instantPlan) {
                self.finishInstantLaneTurn(userText: "(after \(firedText)) \(followUpText)", doneText: doneText, inputKind: .typed)
                return
            }
            self.sendTypedMessage(
                "(watch fired) \(followUpText)",
                turnText: "[a watch the user set just fired: \(firedText). they asked you to do this once it did, so do it now with your tools and tell them in a few words:] \(followUpText)"
            )
        }
    }

    /// Shows and remembers an ask the Mac did itself, like any other turn.
    func finishInstantLaneTurn(userText: String, doneText: String, inputKind: ConversationEntry.InputKind) {
        isLiveTurnInFlight = false
        voiceState = .idle
        lastTranscript = userText
        brain.record(.chat, "user: \(userText)\ndottie: \(doneText)")
        conversationStore.append(userText: userText, clickyText: doneText, inputKind: inputKind)
        conversationHistory.append((userTranscript: userText, assistantResponse: doneText))
        if conversationHistory.count > Self.rememberedExchangeCount {
            conversationHistory.removeFirst(conversationHistory.count - Self.rememberedExchangeCount)
        }
        liveVoiceClient.recentConversationHistory = conversationHistory.map { exchange in
            (userTranscript: exchange.userTranscript, modelTranscript: exchange.assistantResponse)
        }
        NSSound(named: "Pop")?.play()
        notchPresenter.showFinishedResponse(doneText)
        fireLiveTurnFinishedHandler()
        scheduleTransientHideIfNeeded()
    }

    /// Saves what Gemini did this turn as a shortcut when it can be done
    /// again the same way. Returns a line for the answer card when the
    /// user named the shortcut.
    func learnShortcutFromFinishedLiveTurn(userTranscript: String, typedText: String?, modelTranscript: String) -> String? {
        guard !currentLiveTurnFinishedToolCalls.isEmpty, !userTranscript.hasPrefix("(") else { return nil }
        var requestTexts: [String] = []
        // The Mac's own transcript first: it's what future asks are
        // matched against.
        for candidateText in [typedText, currentLiveTurnOnDeviceText, userTranscript] {
            let trimmedCandidate = (candidateText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCandidate.isEmpty && !requestTexts.contains(trimmedCandidate) {
                requestTexts.append(trimmedCandidate)
            }
        }
        let namedShortcutName = currentLiveTurnNamedShortcutName
        guard let savedPhrase = DottieInstantLane.shared.learnFromFinishedTurn(
            requestTexts: requestTexts,
            finishedToolCalls: currentLiveTurnFinishedToolCalls,
            modelReply: modelTranscript,
            namedShortcutName: namedShortcutName
        ), namedShortcutName != nil else { return nil }
        return "Saved: say “\(savedPhrase)” any time."
    }

    /// A Live turn from text instead of the mic, with a fresh screen frame.
    /// `recordedUserText` is what the conversation history keeps.
    func startLiveTextTurn(recordedUserText: String, turnText: String, isNarration: Bool = false) {
        liveTurnPlaybackDrainTask?.cancel()
        isLiveTurnInFlight = true
        currentLiveTurnTypedText = recordedUserText
        currentLiveTurnIsNarration = isNarration
        voiceState = .processing
        Task { [weak self] in
            guard let self else { return }
            // A guide line needs no new look at the screen.
            await self.beginLiveTurnWithScreenFrame(includesScreenFrame: !isNarration)
            // Turns Dottie makes herself ("(done: …)", "(job asks: …)", a
            // guide line) aren't the user asking for anything.
            let isTurnMadeByDottie = isNarration || recordedUserText.isEmpty || recordedUserText.hasPrefix("(")
            if isTurnMadeByDottie {
                self.liveVoiceClient.skipHelperHandOffCheckForCurrentTurn()
            } else {
                self.liveVoiceClient.noteTypedQuestionForHelperHandOffCheck(recordedUserText)
            }
            self.liveVoiceClient.sendTurnContextText(turnText)
            self.liveVoiceClient.endUserTurn()
        }
    }

    func fireLiveTurnFinishedHandler() {
        let handler = liveTurnFinishedHandler
        liveTurnFinishedHandler = nil
        handler?()
    }

    /// Says one line in Dottie's voice and returns once it has been said.
    /// Waits for any turn in progress to finish first.
    func narrate(_ line: String) async {
        for _ in 0..<80 {
            let isBusy = isLiveTurnInFlight || voiceState != .idle || buddyDictationManager.isDictationInProgress
            if !isBusy { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if Task.isCancelled { return }

        switch voiceMode {
        case .classic:
            notchPresenter.updateLiveCaption(line)
            speakWithSystemVoice(line)
            let wordCount = line.split(separator: " ").count
            try? await Task.sleep(nanoseconds: UInt64(max(1.5, Double(wordCount) * 0.38) * 1_000_000_000))
            voiceState = .idle
        case .live:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var hasResumed = false
                let resumeOnce = {
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume()
                }
                fireLiveTurnFinishedHandler()
                liveTurnFinishedHandler = resumeOnce
                narrationCount += 1
                let thisNarration = narrationCount
                // Never hang the guide on a turn that goes quiet.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    guard let self, self.narrationCount == thisNarration else { return }
                    if self.liveTurnFinishedHandler != nil {
                        self.fireLiveTurnFinishedHandler()
                    }
                }
                startLiveTextTurn(
                    recordedUserText: "",
                    turnText: "[dottie guide] this step is already drawn on the screen. say exactly this line out loud, in your own warm voice, and nothing else. no tools.\n\"\(line)\"",
                    isNarration: true
                )
            }
        }
    }

    /// With "Show Clicky" off, the cursor overlay appears only for the
    /// length of an interaction, so pointing is still visible.
    func showOverlayTransientlyIfNeeded() {
        guard !isClickyCursorEnabled && !isOverlayVisible else { return }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    // MARK: - Escape Interrupt

    /// Escape cuts the companion off: stops speech, abandons the answer in
    /// flight, and drops a recording without sending it. Does nothing while
    /// the companion is idle, so Escape keeps working normally elsewhere.
    func handleEscapeInterrupt() {
        let isCompanionBusy = voiceState != .idle || isLiveTurnInFlight || isAnySpeechPlaying || screenTaskRunner.isRunning || guide.isActive
            || teachingTask != nil
        guard isCompanionBusy else { return }

        DottieLog.notice("⎋ Escape interrupt")
        ClickyAnalytics.trackEscapeInterrupt()

        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        if buddyDictationManager.isDictationInProgress {
            buddyDictationManager.cancelCurrentDictation()
        }

        currentResponseTask?.cancel()
        currentResponseTask = nil
        liveTurnPlaybackDrainTask?.cancel()
        liveVoiceClient.cancelCurrentModelResponse()
        stopAllSpeechPlayback()
        clearDetectedElementLocation()
        screenAnnotationManager.clear()
        stopScreenTask()
        stopGuide()
        stopTeaching(clearingDrawing: true)
        fireLiveTurnFinishedHandler()

        isLiveTurnInFlight = false
        currentLiveTurnTypedText = nil
        voiceState = .idle
        notchPresenter.collapse()
        scheduleTransientHideIfNeeded()
    }
}
