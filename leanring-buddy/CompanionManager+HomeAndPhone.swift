//
//  CompanionManager+HomeAndPhone.swift
//  leanring-buddy
//
//  The voice tools for the smart home, meeting mode, the speed pack
//  (replays and the self-check) and texting Dottie from the phone. Part of
//  CompanionManager, split out by topic.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

extension CompanionManager {
    // MARK: - Smart home (DottieSmartHome)

    func performSmartHomeTool(functionName: String, arguments: [String: Any]) async -> String {
        switch functionName {
        case "home_devices":
            return await smartHome.listForVoice()
        case "control_device":
            return await smartHome.control(arguments: arguments)
        case "tv_task":
            return startTVTask(task: (arguments["task"] as? String) ?? "", tvName: arguments["tv"] as? String)
        default:
            return "unknown home tool."
        }
    }

    private func startTVTask(task: String, tvName: String?) -> String {
        guard !task.isEmpty else { return "what should I do on the TV?" }
        guard let tv = smartHome.tv(named: tvName) else {
            return smartHome.setup.tvs.isEmpty
                ? "no TV is set up yet. tell the user to add it in your Home window, under Smart Home."
                : "which TV? the user has: \(smartHome.setup.tvs.map(\.name).joined(separator: ", "))."
        }
        guard smartHome.canSee(tv) else {
            return "you can't see \(tv.name)'s screen (it needs a capture card), so do it with control_device presses instead."
        }
        let runner = smartHome.tvTaskRunner
        runner.stop()
        let showsInNotch = !screenTaskRunner.isRunning
        runner.onProgress = { [weak self] stepText in
            guard showsInNotch else { return }
            self?.notchPresenter.showScreenTaskStep(stepText, title: "on the TV")
        }
        if showsInNotch { notchPresenter.showScreenTaskStep("looking at the TV", title: "on the TV") }
        DottieLog.notice("📺 TV task on \(tv.name): \(task)")
        runner.start(task: task, controls: smartHome.tvControls(for: tv)) { [weak self] outcome in
            guard let self else { return }
            if showsInNotch && !self.screenTaskRunner.isRunning { self.notchPresenter.endScreenTask() }
            let resultText: String
            switch outcome {
            case .finished(let answer): resultText = answer
            case .failed(let reason): resultText = "it couldn't be finished: \(reason)"
            case .stopped: return
            }
            DottieLog.notice("📺 TV task result: \(resultText)")
            self.brain.record(.screenJob, "did on the TV (\(tv.name)): \(task). result: \(resultText)")
            Task { [weak self] in
                for _ in 0..<60 {
                    guard let self else { return }
                    let isBusy = self.isLiveTurnInFlight || self.voiceState != .idle
                        || self.buddyDictationManager.isDictationInProgress || self.notchPresenter.surface == .textInput
                    if !isBusy { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                self?.speakScreenTaskResult(taskText: "on the TV: \(task)", resultText: resultText)
            }
        }
        return "started on \(tv.name). say you're on it in a few words, then stop; the result comes back in a later message."
    }

    private func configureCursorPet() {
        // The pet comes to the mouse while the user talks to Dottie, while
        // she points, and during guides and screen jobs.
        cursorPet.shouldPause = { [weak self] in
            guard let self else { return true }
            return self.voiceState != .idle
                || self.detectedElementScreenLocation != nil
                || self.screenTaskRunner.isRunning
                || self.guide.isActive
        }
        cursorPet.start()
        // A pet out roaming has to be seen even with the cursor set to hide.
        cursorPetCancellable = cursorPet.$costume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] costume in
                guard let self, costume?.roams == true, !self.isOverlayVisible, self.hasCompletedOnboarding else { return }
                self.overlayWindowManager.hasShownOverlayBefore = true
                self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                self.isOverlayVisible = true
            }
    }

    func performCursorTool(arguments: [String: Any]) -> String {
        cursorPet.perform(arguments: arguments)
    }

    private func configureBrain() {
        clickyRoster.brainFolderURLsProvider = { [weak self] in
            self?.brain.folderURLs ?? []
        }
        // Projects first (ClickyRoster reads the first as the projects
        // folder); then the user's own folders, when they let helpers in.
        clickyRoster.sharedFolderURLs = [projects.rootFolderURL] + DottieWorkRoutes.homeFolderURLs
        // Pictures, projects and smart home devices edited in Home reach
        // voice Dottie on her next connection.
        Publishers.Merge3(
            imageMemory.$items.map { _ in () }.dropFirst(),
            projects.$projects.map { _ in () }.dropFirst(),
            smartHome.$setup.map { _ in () }.dropFirst()
        )
        .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            guard let self else { return }
            self.liveVoiceClient.baseSystemInstruction = self.currentLiveSystemPrompt()
        }
        .store(in: &brainCancellables)
        brain.onProfileChanged = { [weak self] _ in
            guard let self else { return }
            // Takes effect on the next Live connection.
            self.liveVoiceClient.baseSystemInstruction = self.currentLiveSystemPrompt()
        }
        brain.$isScreenJournalEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.notchPresenter.isScreenJournalOn = isEnabled
            }
            .store(in: &brainCancellables)
        // Episodes: screen ones go in the brain's journal too, and the
        // recent ones reach voice Dottie on her next connection.
        DottieEpisodicMemory.shared.onEpisodesChanged = { [weak self] newEpisodes in
            guard let self else { return }
            for episode in newEpisodes where episode.source == .screen {
                self.brain.record(.screen, "\(episode.title): \(episode.summary.prefix(300))")
            }
            self.liveVoiceClient.baseSystemInstruction = self.currentLiveSystemPrompt()
        }
        DottieEpisodicMemory.shared.start()
        DottieHabits.shared.start()
        DottieKnownPlaces.shared.start()
    }

    /// Hands a question to the Brain agent; Dottie says the answer when it
    /// comes back.
    func askBrain(question: String) -> String {
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            return "the brain can't run yet: Dottie isn't connected to its server."
        }
        let brainAgent = clickyRoster.brainAgent()
        guard !clickyRoster.isRunning(brainAgent) else {
            return "the brain is still working on the last question: \(clickyRoster.statusLine(for: brainAgent)). tell the user it'll answer that first."
        }
        // Asked before: the saved answer, at once and with no helper turn.
        if let savedAnswer = brain.savedBrainAnswer(for: question) {
            let minutesAgo = max(1, Int(Date().timeIntervalSince(savedAnswer.date) / 60))
            return "your second brain answered this \(minutesAgo) minutes ago: \(savedAnswer.answer)\ntell the user now in one to three short sentences; don't ask the brain again."
        }
        // Only what the question needs: the last couple of exchanges, cut
        // short, and the two closest memories.
        let recentChat = conversationHistory.suffix(2)
            .map { "user: \($0.userTranscript.prefix(300))\ndottie: \($0.assistantResponse.prefix(300))" }
            .joined(separator: "\n")
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let relatedEpisodes = DottieEpisodicMemory.shared.recallNow(query: question, limit: 2).episodes
        let episodesNote = relatedEpisodes.isEmpty ? "" : "\n\nepisodes from Dottie's memory that may be related:\n"
            + relatedEpisodes.map(DottieEpisodicMemory.lineForModel).joined(separator: "\n")
        let messageForBrain = """
        Dottie's question for you: \(question)

        (context: the user is in \(frontmostApp). recent conversation with Dottie:
        \(recentChat.isEmpty ? "none" : recentChat))\(episodesNote)
        """
        clickyRoster.sendMessage(messageForBrain, to: brainAgent)
        guard clickyRoster.isRunning(brainAgent) else {
            return "couldn't reach the brain right now."
        }
        pendingSpokenBrainQuestion = question
        return "the brain is on it. say only a few words like 'let me think on that'; its answer comes to you in a later message."
    }

    private func speakBrainAnswer(question: String, answer: String) {
        let instructionText = "your second brain answered the user's question \"\(question)\": \(answer)\n"
            + "tell the user now, in your own voice, in one to three short sentences. if it asks the user something, ask it."
        speakWhenFree(recordedUserText: "(brain: \(question))", instructionText: instructionText)
    }

    /// Has Dottie say something on her own once any turn in progress ends.
    func speakWhenFree(recordedUserText: String, instructionText: String) {
        transientHideTask?.cancel()
        transientHideTask = nil
        Task { [weak self] in
            // Wait for any turn in progress to finish first.
            for _ in 0..<60 {
                guard let self else { return }
                if !self.isLiveTurnInFlight && self.voiceState == .idle { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let self else { return }
            self.sendTranscriptToGeminiWithScreenshot(transcript: instructionText, inputKind: .typed)
        }
    }

    // MARK: - Meeting mode

    private func configureMeetingMode() {
        meetingCancellable = meetingRecorder.$isRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.notchPresenter.isMeetingRecording = isRecording
            }
        // Live help shows its suggestions in the notch as they come.
        notchPresenter.onAskMeetingHelp = { [weak self] in
            self?.meetingRecorder.liveHelp.askNow()
        }
        var lastShownSuggestion: DottieMeetingLiveHelp.Suggestion?
        meetingRecorder.liveHelp.onDisplayChanged = { [weak self] in
            guard let self else { return }
            let liveHelp = self.meetingRecorder.liveHelp
            guard liveHelp.isRunning else {
                lastShownSuggestion = nil
                self.notchPresenter.endMeetingHelp()
                return
            }
            let suggestion = liveHelp.latestSuggestion
            let hasNewSuggestion = suggestion != nil && suggestion != lastShownSuggestion
            lastShownSuggestion = suggestion
            var heading = "live help · ⌘⇧↩ to ask"
            if let questionText = suggestion?.questionText {
                heading = "they asked: \(questionText)"
            } else if suggestion != nil {
                heading = "you could say"
            }
            var suggestedLines = suggestion?.suggestedLines ?? []
            if suggestedLines.isEmpty, let statusNote = liveHelp.statusNote {
                suggestedLines = [statusNote]
            }
            self.notchPresenter.showMeetingHelp(
                heading: heading,
                lines: suggestedLines,
                talkingPoints: liveHelp.talkingPointsText,
                isThinking: liveHelp.isThinking,
                hasNewSuggestion: hasNewSuggestion
            )
        }
        meetingRecorder.onMeetingSaved = { [weak self] title, summary, _ in
            guard let self else { return }
            self.brain.record(.meeting, "meeting \"\(title)\":\n\(summary.prefix(3000))")
            self.notchPresenter.showAgentUpdate(title: "Meeting notes · \(title)", text: summary)
            self.speakWhenFree(
                recordedUserText: "(meeting notes ready)",
                instructionText: "the meeting notes are ready and saved in home → meetings:\n\(summary.prefix(2500))\n"
                    + "tell the user in one or two short sentences: the gist, and how many action items there are. don't read it all out."
            )
        }
    }

    // MARK: - Speed pack

    /// Instant replays by voice, and the self-check's Telegram check.
    private func configureSpeedPack() {
        DottieSelfCheck.shared.phoneBridge = phoneBridge
        DottieSpeedTools.startReplayJob = { [weak self] replay in
            guard let self else { return "Dottie isn't ready yet." }
            return self.startScreenTask(ScreenJob(text: replay.taskText, replayID: replay.id))
        }
        // A learned shortcut's steps run exactly as Gemini's calls did.
        DottieInstantLane.shared.runSavedToolStep = { [weak self] functionName, arguments in
            guard let self else { return "couldn't do that right now." }
            if DottieScreenAction.functionNames.contains(functionName) {
                guard let screenAction = DottieScreenAction(functionName: functionName, arguments: arguments) else {
                    return "couldn't do that right now."
                }
                return await self.performScreenAction(screenAction)
            }
            if DottieToolRegistry.handles(functionName, for: .voice) {
                return await DottieToolRegistry.run(functionName, arguments: arguments, for: .voice) ?? "couldn't do that right now."
            }
            guard let onMacTool = self.liveVoiceClient.onMacTool else { return "couldn't do that right now." }
            return await onMacTool(functionName, arguments)
        }
        // Starts listening for Spotify and Music playing or pausing, so
        // "pause" knows whether there's music to pause.
        _ = DottieInstalledApps.shared
        DottieEveryday.shared.watches.onFollowUpDue = { [weak self] followUpText, firedText in
            self?.runWatchFollowUp(followUpText, firedText: firedText)
        }
        DottieSmartReplayTools.startSmartReplayJob = { [weak self] smartReplay, details in
            guard let self else { return "Dottie isn't ready yet." }
            DottieSmartReplayStore.shared.noteRun(smartReplay.id)
            return self.startScreenTask(ScreenJob(
                text: smartReplay.screenJobTaskText(details: details),
                closingMessage: smartReplay.closingMessage,
                isCommercial: smartReplay.kind == .commercial
            ))
        }
    }

    // MARK: - Phone

    private static let phoneHelperName = "Phone"

    private func configurePhoneBridge() {
        phoneBridge.onMessage = { [weak self] text in
            self?.handlePhoneMessage(text)
        }
        DottieAwayMode.shared.phoneBridge = phoneBridge
        DottieAwayMode.shared.onCameBack = { [weak self] reportText in
            self?.notchPresenter.showAgentUpdate(title: "While you were away", text: reportText)
        }
        DottieWatchAndLearn.shared.onStatus = { [weak self] title, text in
            self?.notchPresenter.showAgentUpdate(title: title, text: text)
        }
        phoneBridge.onAwayCommand = { isAway in
            DottieAwayMode.shared.setAway(isAway, from: "phone")
        }
        phoneBridge.reportProvider = {
            DottieAwayMode.shared.report()
        }
        phoneFiles.sendText = { [weak self] text in
            await self?.phoneBridge.send(text)
        }
        phoneFiles.sendFileToPhone = { [weak self] fileURL, caption in
            guard let self else { return "the phone isn't connected." }
            return await self.phoneBridge.sendDocument(fileURL, caption: caption)
        }
        phoneFiles.uploadToDriveOnScreen = { [weak self] fileURL in
            guard let self else { return "can't reach Google Drive." }
            let jobText = "Upload the file \(fileURL.path) to the user's Google Drive: open drive.google.com in the browser, click New, then File upload. "
                + "In the file picker press cmd+shift+g, type the path exactly, press return, then click Open (or Upload). "
                + "Wait until Drive says the upload is complete, then finish."
            let status = self.startScreenTask(ScreenJob(text: jobText, repliesToPhone: true))
            return "Google Drive for desktop isn't installed, so Dottie is uploading it in the browser on the Mac (\(status)). A text follows when it's done."
        }
        phoneBridge.statusProvider = { [weak self] in
            guard let self else { return "" }
            var lines = ["Helpers:", self.clickyRoster.helperListSummary()]
            if self.screenTaskRunner.isRunning {
                lines.append("On screen: " + self.screenTaskQueueSummary())
            }
            if self.meetingRecorder.isRecording {
                lines.append("Meeting notes are on (\(self.meetingRecorder.elapsedText)).")
            }
            return lines.joined(separator: "\n")
        }
        phoneBridge.screenshotProvider = {
            let screenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            return (screenCaptures?.first { $0.isCursorScreen } ?? screenCaptures?.first)?.imageData
        }
        phoneBridge.onPermissionAnswer = { [weak self] isAllowed in
            guard let self,
                  let phoneAgent = self.clickyRoster.agents.first(where: { $0.name == Self.phoneHelperName }),
                  self.clickyRoster.pendingComputerUseRequest(for: phoneAgent) != nil else {
                return "Nothing is waiting for permission."
            }
            self.notchPresenter.dropComputerUseRequest(forAgentID: phoneAgent.id)
            if isAllowed {
                self.clickyRoster.approveComputerUse(for: phoneAgent, alwaysAllow: false)
                return "Allowed. Carrying on."
            }
            self.clickyRoster.declineComputerUse(for: phoneAgent)
            return "Okay, it won't use the Mac."
        }
    }

    /// A text from the user's phone becomes a task for the Phone helper,
    /// whose reply is texted back from onAgentTurnFinished.
    private func handlePhoneMessage(_ text: String) {
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            Task { await phoneBridge.send("Dottie isn't connected to its server, so helpers can't run. Check Settings → Connection on the Mac.") }
            return
        }
        // Files ("find my howto presentation", "put it on my Drive") are
        // answered right here; everything else goes to the Phone helper.
        Task { [weak self] in
            guard let self else { return }
            if await self.phoneFiles.handle(text) {
                self.brain.record(.phone, "texted from phone: \(text)")
                return
            }
            self.handPhoneMessageToHelper(text)
        }
    }

    private func handPhoneMessageToHelper(_ text: String) {
        let phoneAgent = clickyRoster.agents.first { $0.name == Self.phoneHelperName }
            ?? clickyRoster.createAgent(name: Self.phoneHelperName, purpose: "Jobs the user texts from their phone while away from the Mac.")
        brain.record(.phone, "texted from phone: \(text)")
        let taskText = """
        (texted by the user from their phone; they may be away from the Mac.) \(text)

        do it, then end with a short reply that reads well as a text message: a few plain lines, no markdown tables.
        """
        let tasksAhead = clickyRoster.sendOrQueueMessage(taskText, to: phoneAgent)
        let receipt = tasksAhead > 0
            ? "Got it. That's lined up after \(tasksAhead) other task\(tasksAhead == 1 ? "" : "s")."
            : (DotsRuntimeInstaller.isInstalled ? "On it." : "On it. First run on this Mac, so it's setting up first.")
        Task { await phoneBridge.send(receipt) }
    }

    func configureClickyRoster() {
        configureBrain()
        configureCursorPet()
        configureMeetingMode()
        configurePhoneBridge()
        DottieFunPack.shared.attach(to: self)
        configureSpeedPack()
        clickyRoster.onAgentTurnFinished = { [weak self] turnResult in
            self?.handleFinishedHelperTurn(turnResult)
        }

        dotNotifications.configure()
        dotNotifications.onOpenDot = { [weak self] agentID in
            guard let self else { return }
            self.clickyRoster.requestShowInHome(agentID: agentID)
            self.openHomeWindow()
        }
        dotNotifications.onAnswerComputerUseRequest = { [weak self] agentID, isAllowed in
            guard let self, let requestingAgent = self.clickyRoster.agent(withID: agentID) else { return }
            self.notchPresenter.dropComputerUseRequest(forAgentID: agentID)
            if isAllowed {
                self.clickyRoster.approveComputerUse(for: requestingAgent, alwaysAllow: false)
            } else {
                self.clickyRoster.declineComputerUse(for: requestingAgent)
            }
        }

        // objectWillChange fires before the change lands; hopping to the
        // next main-queue turn reads the new values.
        clickyRosterCancellable = clickyRoster.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNotchDotSummaries()
            }
        updateNotchDotSummaries()

        notchPresenter.onOpenDot = { [weak self] agentID in
            guard let self else { return }
            self.clickyRoster.requestShowInHome(agentID: agentID)
            self.notchPresenter.isHovering = false
            self.openHomeWindow()
        }

        notchPresenter.onAnswerComputerUseRequest = { [weak self] agentID, isAllowed, alwaysAllow in
            guard let self, let requestingAgent = self.clickyRoster.agent(withID: agentID) else { return }
            self.dotNotifications.removeNotification(forAgentID: agentID)
            if isAllowed {
                self.clickyRoster.approveComputerUse(for: requestingAgent, alwaysAllow: alwaysAllow)
            } else {
                self.clickyRoster.declineComputerUse(for: requestingAgent)
            }
        }
    }

    /// A helper finished a turn: hands on-screen steps it asked for to a
    /// screen job, asks about using the Mac (in the notch, and on the phone
    /// when the user is away), or shows and remembers its reply.
    private func handleFinishedHelperTurn(_ turnResult: ClickyAgentTurnResult) {
        DottieFunPack.shared.helperTurnFinished(
            agentID: turnResult.agent.id,
            reply: turnResult.finalReply,
            succeeded: turnResult.succeeded,
            routineTitle: turnResult.routineTitle
        )
        // A routine run with nothing new stays out of the notch.
        guard !turnResult.foundNothingNew else { return }
        let updateTitle = turnResult.routineTitle.map { "\(turnResult.agent.name) · \($0)" } ?? turnResult.agent.name
        let isPhoneHelper = turnResult.agent.name == Self.phoneHelperName && self.phoneBridge.pairedChatID != nil
        // The helper did what it could in the background and left the
        // on-screen steps to Dottie (DottieWorkRoutes).
        if turnResult.succeeded, let screenJobRequest = DottieWorkRoutes.screenJobRequest(in: turnResult.finalReply) {
            DottieLog.notice("🧭 \(turnResult.agent.name) asked for on-screen steps: \(screenJobRequest.steps)")
            let status = self.startScreenTask(ScreenJob(text: screenJobRequest.steps, returnsToHelperAgentID: turnResult.agent.id))
            let progressText = screenJobRequest.replyWithoutBlock.isEmpty ? "Doing the on-screen part now." : screenJobRequest.replyWithoutBlock
            self.notchPresenter.showAgentUpdate(title: updateTitle, text: progressText)
            if isPhoneHelper {
                Task { await self.phoneBridge.send("Doing the on-screen part on your Mac now (\(status.prefix(80))).") }
            }
            return
        }
        if let computerUseRequest = turnResult.computerUseRequest {
            // From the phone, or while the user is away: asked on the
            // phone with Allow / Deny buttons, as well as in the notch.
            if isPhoneHelper || DottieAwayMode.shared.questionsGoToPhone {
                let requestingAgent = turnResult.agent
                Task { [weak self] in
                    let isAllowed = await DottieAwayMode.shared.confirmOnPhone(
                        "\(updateTitle) needs to use your Mac's screen for this: \(computerUseRequest)",
                        screenshotJPEG: nil
                    )
                    guard let self, self.clickyRoster.pendingComputerUseRequest(for: requestingAgent) != nil else { return }
                    self.notchPresenter.dropComputerUseRequest(forAgentID: requestingAgent.id)
                    self.dotNotifications.removeNotification(forAgentID: requestingAgent.id)
                    if isAllowed {
                        self.clickyRoster.approveComputerUse(for: requestingAgent, alwaysAllow: false)
                    } else {
                        self.clickyRoster.declineComputerUse(for: requestingAgent)
                    }
                }
            }
            // Ask in the notch and in a notification; the answer comes
            // back through onAnswerComputerUseRequest below.
            self.notchPresenter.showAgentUpdate(
                title: updateTitle,
                text: computerUseRequest,
                computerUseRequestAgentID: turnResult.agent.id
            )
            self.dotNotifications.notifyComputerUseRequest(
                agentID: turnResult.agent.id,
                title: "\(updateTitle) wants to use your Mac",
                text: computerUseRequest
            )
            return
        }
        let updateText = turnResult.finalReply.isEmpty
            ? (turnResult.succeeded ? "Finished." : "Stopped without a reply.")
            : turnResult.finalReply
        if isPhoneHelper {
            Task { await self.phoneBridge.send(updateText) }
        }
        if DottieAwayMode.shared.isAway {
            DottieAwayMode.shared.noteResult(
                title: updateTitle,
                detail: updateText,
                succeeded: turnResult.succeeded,
                alreadyTextedToPhone: isPhoneHelper
            )
        }
        let finishedTask = self.clickyRoster.transcriptsByAgentID[turnResult.agent.id]?.last { $0.kind == .user }?.text ?? ""
        self.brain.record(.helper, "\(updateTitle) was asked: \(finishedTask.prefix(400))\nreplied: \(updateText.prefix(1200))")
        if turnResult.agent.isBrain == true, let brainQuestion = self.pendingSpokenBrainQuestion {
            self.pendingSpokenBrainQuestion = nil
            if turnResult.succeeded {
                self.brain.saveBrainAnswer(question: brainQuestion, answer: updateText)
            }
            self.speakBrainAnswer(question: brainQuestion, answer: updateText)
            self.notchPresenter.showAgentUpdate(title: updateTitle, text: updateText)
            return
        }
        self.notchPresenter.showAgentUpdate(title: updateTitle, text: updateText)
        self.refreshNotchPeekFiles()
        self.dotNotifications.notifyDotFinished(agentID: turnResult.agent.id, title: updateTitle, text: updateText)
    }

    /// What the notch shows about the Dots: working ones first, then ones
    /// with something new, then the most recently active.
    private func updateNotchDotSummaries() {
        let dotSummaries = clickyRoster.agents.map { agent -> NotchDotSummary in
            let status: NotchDotSummary.Status
            if clickyRoster.isRunning(agent) {
                status = .working
            } else if agent.hasUnreadReply == true {
                status = .hasNew
            } else {
                status = .idle
            }
            return NotchDotSummary(
                id: agent.id,
                name: agent.name,
                status: status,
                lastLine: notchLastLine(for: agent, status: status)
            )
        }
        let statusOrder: [NotchDotSummary.Status: Int] = [.working: 0, .hasNew: 1, .idle: 2]
        let lastActivityByAgentID = Dictionary(uniqueKeysWithValues: clickyRoster.agents.map { ($0.id, $0.lastActivityAt) })
        let sortedDotSummaries = dotSummaries.sorted { firstSummary, secondSummary in
            let firstOrder = statusOrder[firstSummary.status] ?? 2
            let secondOrder = statusOrder[secondSummary.status] ?? 2
            if firstOrder != secondOrder { return firstOrder < secondOrder }
            return (lastActivityByAgentID[firstSummary.id] ?? .distantPast) > (lastActivityByAgentID[secondSummary.id] ?? .distantPast)
        }
        if sortedDotSummaries != notchPresenter.dotSummaries {
            notchPresenter.dotSummaries = sortedDotSummaries
        }

        // A Dot's notification goes once its reply is read or it's deleted.
        // Waiting computer-use questions count as unread until answered.
        if dotNotifications.hasNotificationsShowing {
            let agentIDsStillOwed = Set(clickyRoster.agents.filter { agent in
                agent.hasUnreadReply == true || clickyRoster.pendingComputerUseRequest(for: agent) != nil
            }.map(\.id))
            dotNotifications.removeNotifications(keepingAgentIDs: agentIDsStillOwed)
        }
    }

    /// Reads the newest files in the Dots' output folders off the main
    /// thread and hands them to the notch.
    func refreshNotchPeekFiles() {
        let workspaces = clickyRoster.agents.map { agent in
            (agentID: agent.id, agentName: agent.name, workspaceURL: clickyRoster.workspaceURL(for: agent))
        }
        peekFilesRefreshTask?.cancel()
        peekFilesRefreshTask = Task { [weak self] in
            let newestFiles = await Task.detached(priority: .utility) {
                NotchPeekFileIndex.newestFiles(inWorkspaces: workspaces, limit: NotchPresenter.maximumPeekFileCount)
            }.value
            guard !Task.isCancelled, let self else { return }
            if newestFiles != self.notchPresenter.peekFiles {
                self.notchPresenter.peekFiles = newestFiles
            }
        }
    }

    private func notchLastLine(for agent: ClickyAgent, status: NotchDotSummary.Status) -> String {
        let transcript = clickyRoster.transcriptsByAgentID[agent.id] ?? []
        if status == .working {
            // While working, the latest tool it ran says the most.
            if let latestTool = transcript.last(where: { $0.kind == .tool }) {
                return latestTool.text
            }
            return "working…"
        }
        let latestItem = transcript.last { $0.kind == .assistant || $0.kind == .error || $0.kind == .computerUseRequest }
        guard let latestItem else { return agent.purpose.isEmpty ? "no work yet" : agent.purpose }
        let firstLine = latestItem.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return latestItem.kind == .computerUseRequest ? "wants to use your Mac" : firstLine
    }
}
