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
            self.sendTypedMessage(messageText)
        }
        DottieEveryday.shared.attach(to: self)
        notchPresenter.onOpenHome = { [weak self] in
            self?.openHomeWindow()
        }
        notchPresenter.onStopSpeaking = { [weak self] in
            guard let self else { return }
            self.stopAllSpeechPlayback()
            if self.voiceState == .responding { self.voiceState = .idle }
        }
        notchPresenter.onStopScreenTask = { [weak self] in
            // The same stop button serves jobs and guides.
            self?.stopScreenTask(reason: .stopButton)
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

        sendTranscriptToGeminiWithScreenshot(transcript: turnText ?? trimmedMessageText, inputKind: .typed)
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
        NSSound(named: "Pop")?.play()
        notchPresenter.showFinishedResponse(doneText)
        fireLiveTurnFinishedHandler()
        scheduleTransientHideIfNeeded()
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

        notchPresenter.updateLiveCaption(line)
        // The same voice as every answer: Kokoro, or the Mac's voice only
        // while Kokoro is still loading.
        let speakingStartedAt = Date()
        try? await speakClassicAnswer(line)
        while isAnySpeechPlaying, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // A line Kokoro skipped (nothing speakable) still gets a moment on
        // screen before the next step.
        let minimumSeconds = 1.0
        let remainingSeconds = minimumSeconds - Date().timeIntervalSince(speakingStartedAt)
        if remainingSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remainingSeconds * 1_000_000_000))
        }
        voiceState = .idle
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
        stopAllSpeechPlayback()
        clearDetectedElementLocation()
        screenAnnotationManager.clear()
        stopScreenTask(reason: .escape)
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
