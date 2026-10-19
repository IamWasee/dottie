//
//  NotchPresenter.swift
//  leanring-buddy
//
//  What the notch is showing right now. Shipped Clicky's main surface lives
//  around the MacBook notch (NotchPresenter / NotchRootView); this is the
//  clone's version of that state. CompanionManager pushes voice state and
//  transcripts in; NotchRootView renders it; NotchWindowManager resizes the
//  window to fit.
//

import Combine
import CoreGraphics
import Foundation

/// One Dot as the notch shows it when you hover.
struct NotchDotSummary: Identifiable, Equatable {
    enum Status: Equatable {
        case working
        case hasNew
        case idle
    }

    let id: UUID
    let name: String
    let status: Status
    /// The last thing it said or did, on one line.
    let lastLine: String
}

/// A file a Dot made, shown in the hover peek so it can be opened or
/// dragged straight into another app.
struct NotchPeekFile: Identifiable, Equatable {
    let url: URL
    let agentID: UUID
    let agentName: String
    let modifiedAt: Date

    var id: String { url.path }
}

/// Something running in the background (a watch, focus mode), listed in
/// the hover peek with a stop button.
struct NotchStatusLine: Identifiable, Equatable {
    let id: String
    let symbolName: String
    let text: String
}

@MainActor
final class NotchPresenter: ObservableObject {
    enum Surface: Equatable {
        /// Just the notch (with Clicky's eyes peeking out on hover).
        case compact
        /// User is holding the hotkey and talking.
        case listening
        /// User let go; waiting for the answer to start.
        case thinking
        /// Clicky is speaking. Shows the live caption.
        case speaking
        /// A text box for typing to Clicky instead of talking.
        case textInput
        /// The last answer as text, auto-dismissing.
        case textResponse
        /// Dottie is doing a multi-step job on the screen; shows the
        /// current step and a stop button.
        case screenTask
    }

    /// How the island shows the current surface, like the Dynamic Island:
    /// hidden behind the notch, grown sideways into the menu bar with a
    /// little status on each side of the notch, or dropped down into a card.
    enum IslandPresentation: Equatable {
        case closed
        case wings
        case expanded
    }

    private static let textResponseAutoDismissSeconds: TimeInterval = 8
    static let defaultListeningLabel = "listening"
    static let defaultThinkingLabel = "thinking"

    @Published private(set) var surface: Surface = .compact
    @Published var isHovering = false
    /// Size of the black shape. NotchWindowManager sets it for each surface;
    /// NotchRootView animates to it.
    @Published var shapeSize: CGSize = .zero
    @Published var audioPowerLevel: CGFloat = 0
    /// Word next to the eyes while listening or thinking ("dictating" while
    /// hold-to-dictate is recording).
    @Published private(set) var activityLabel = "listening"
    /// What Clicky is saying, as it says it.
    @Published private(set) var liveCaptionText = ""
    /// The last finished answer, shown on the text response surface.
    @Published private(set) var lastResponseText = ""
    /// Who the card is from when it isn't Clicky itself (a background
    /// Clicky reporting back). Nil for normal answers.
    @Published private(set) var lastResponseTitle: String?
    /// Set when the card is a background Clicky asking to use the Mac; the
    /// card then shows Allow / Always / Not now.
    @Published private(set) var computerUseRequestAgentID: UUID?
    /// Set when the card says dictation learned a word; the card then
    /// offers to remove it again.
    @Published private(set) var learnedDictionaryWord: String?
    @Published var draftText = ""
    /// What the running screen task is doing right now ("clicking Sign in").
    @Published private(set) var screenTaskStepText = ""
    /// Small heading over the step: "on it" for a job, "showing you" for a guide.
    @Published private(set) var screenTaskTitle = "on it"
    /// True while a screen task runs; the notch comes back to it after a
    /// voice turn or a card.
    private(set) var isScreenTaskRunning = false
    /// A long screen job's plan and the step it's on (DottieTaskGoal).
    @Published private(set) var screenTaskPlanSteps: [String] = []
    @Published private(set) var screenTaskPlanStepIndex = 0
    /// 1 → 0 over the auto-dismiss window; drives the countdown ring.
    @Published private(set) var autoDismissProgress: Double = 1
    @Published private(set) var isAutoDismissPaused = false
    /// The Dots, most relevant first (working, then something new, then
    /// most recent). CompanionManager keeps this current.
    @Published var dotSummaries: [NotchDotSummary] = []

    /// How many Dots the hover peek lists.
    static let maximumPeekDotCount = 4

    var peekDotSummaries: [NotchDotSummary] {
        Array(dotSummaries.prefix(Self.maximumPeekDotCount))
    }

    /// The newest files the Dots made, newest first. CompanionManager
    /// refreshes this when the hover peek opens.
    @Published var peekFiles: [NotchPeekFile] = []
    nonisolated static let maximumPeekFileCount = 5

    var islandPresentation: IslandPresentation {
        switch surface {
        case .compact:
            if isHovering { return .expanded }
            return showsCompactDotIndicators ? .wings : .closed
        case .listening:
            // Dictation shows the words as they come, which needs the card.
            return liveCaptionText.isEmpty ? .wings : .expanded
        case .thinking:
            // A plain "thinking" fits beside the notch; a label like
            // "looking at your picture" needs the card to be read.
            return activityLabel == Self.defaultThinkingLabel ? .wings : .expanded
        case .speaking, .textInput, .textResponse, .screenTask:
            return .expanded
        }
    }

    /// Hold-to-dictate is recording rather than a voice turn.
    var isDictating: Bool {
        surface == .listening && activityLabel != Self.defaultListeningLabel
    }

    var unreadDotCount: Int {
        dotSummaries.filter { $0.status == .hasNew }.count
    }

    var isAnyDotWorking: Bool {
        dotSummaries.contains { $0.status == .working }
    }

    /// The closed notch grows a little on each side to show a working
    /// light and the count of Dots with something new.
    var showsCompactDotIndicators: Bool {
        unreadDotCount > 0 || isAnyDotWorking || isScreenJournalOn || isMeetingRecording || isKeepWorkingOn
            || !statusLines.isEmpty || compactBadgeText != nil
    }

    /// A 24/7 job is on (DottieKeepWorking): the closed notch shows a moon.
    @Published var isKeepWorkingOn = false
    /// Watches and focus mode, shown in the hover peek.
    @Published var statusLines: [NotchStatusLine] = []
    /// A few characters next to the closed notch, like focus mode's
    /// minutes left ("24m").
    @Published var compactBadgeText: String?
    /// The button on the current card (Undo, Stop…), if it has one.
    @Published private(set) var cardActionLabel: String?
    private var cardAction: (() -> Void)?

    /// Meeting mode is listening: the closed notch shows a red light.
    @Published var isMeetingRecording = false

    /// The brain's screen journal is on: the closed notch shows a small
    /// light so the user always knows.
    @Published var isScreenJournalOn = false

    /// Set by CompanionManager.
    var onSubmitTypedMessage: ((String) -> Void)?
    var onOpenHome: (() -> Void)?
    var onOpenDot: ((UUID) -> Void)?
    var onOpenPeekFile: ((NotchPeekFile) -> Void)?
    var onRevealPeekFile: ((NotchPeekFile) -> Void)?
    var onAnswerComputerUseRequest: ((_ agentID: UUID, _ isAllowed: Bool, _ alwaysAllow: Bool) -> Void)?
    var onRemoveLearnedDictionaryWord: ((String) -> Void)?
    var onStopScreenTask: (() -> Void)?
    var onStopStatusLine: ((String) -> Void)?

    private var autoDismissTask: Task<Void, Never>?
    /// Agent reports that arrived while the notch was busy with a voice turn.
    private var pendingAgentUpdates: [(title: String, text: String, computerUseRequestAgentID: UUID?, learnedDictionaryWord: String?, action: (label: String, run: () -> Void)?)] = []

    // MARK: - Inputs from the companion

    func showListening(label: String = defaultListeningLabel) {
        cancelAutoDismiss()
        liveCaptionText = ""
        activityLabel = label
        surface = .listening
    }

    func showThinking(label: String = defaultThinkingLabel) {
        guard surface != .textInput else { return }
        activityLabel = label
        surface = .thinking
    }

    func showSpeaking() {
        guard surface != .textInput else { return }
        surface = .speaking
    }

    func updateLiveCaption(_ captionText: String) {
        liveCaptionText = captionText
    }

    /// The answer finished. Leave it on screen briefly as text, then fold
    /// back into the notch.
    func showFinishedResponse(_ responseText: String) {
        guard surface != .textInput else { return }
        let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponseText.isEmpty else {
            collapse()
            return
        }
        lastResponseText = trimmedResponseText
        lastResponseTitle = nil
        computerUseRequestAgentID = nil
        learnedDictionaryWord = nil
        cardActionLabel = nil
        cardAction = nil
        surface = .textResponse
        startAutoDismiss()
    }

    func collapse() {
        cancelAutoDismiss()
        surface = .compact
        showNextPendingAgentUpdateIfIdle()
        if surface == .compact && isScreenTaskRunning {
            surface = .screenTask
        }
    }

    /// A screen task started or moved on to its next step. Doesn't cover a
    /// voice turn or a card that's showing; the step shows once they close.
    func showScreenTaskStep(_ stepText: String, title: String = "on it") {
        isScreenTaskRunning = true
        screenTaskStepText = stepText
        screenTaskTitle = title
        if surface == .compact {
            surface = .screenTask
        }
    }

    /// A long screen job made or moved on in its plan.
    func showScreenTaskPlan(_ steps: [String], currentStepIndex: Int) {
        screenTaskPlanSteps = steps
        screenTaskPlanStepIndex = min(max(currentStepIndex, 0), max(steps.count - 1, 0))
    }

    /// "step 2 of 4" while a long job has a plan, else nil.
    var screenTaskPlanProgressText: String? {
        guard screenTaskPlanSteps.count > 1 else { return nil }
        return "step \(screenTaskPlanStepIndex + 1) of \(screenTaskPlanSteps.count)"
    }

    /// The whole plan, one step per line, for the notch's tooltip.
    var screenTaskPlanSummary: String {
        screenTaskPlanSteps.enumerated().map { index, step in
            (index < screenTaskPlanStepIndex ? "✓ " : (index == screenTaskPlanStepIndex ? "→ " : "   ")) + step
        }.joined(separator: "\n")
    }

    func endScreenTask() {
        isScreenTaskRunning = false
        screenTaskStepText = ""
        screenTaskPlanSteps = []
        screenTaskPlanStepIndex = 0
        if surface == .screenTask {
            collapse()
        }
    }

    func stopScreenTask() {
        onStopScreenTask?()
    }

    /// A background Clicky finished. Shown as a card right away if the notch
    /// is free, otherwise after the current voice turn.
    func showAgentUpdate(title: String, text: String, computerUseRequestAgentID: UUID? = nil) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        pendingAgentUpdates.append((title: title, text: trimmedText, computerUseRequestAgentID: computerUseRequestAgentID, learnedDictionaryWord: nil, action: nil))
        showNextPendingAgentUpdateIfIdle()
    }

    /// A card with an optional button (Undo, Stop…). Shown right away if
    /// the notch is free, otherwise after the current voice turn.
    func showCard(title: String, text: String, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let cardButton = actionLabel.flatMap { label in action.map { (label: label, run: $0) } }
        pendingAgentUpdates.append((title: title, text: trimmedText, computerUseRequestAgentID: nil, learnedDictionaryWord: nil, action: cardButton))
        showNextPendingAgentUpdateIfIdle()
    }

    func runCardAction() {
        let action = cardAction
        cardAction = nil
        cardActionLabel = nil
        collapse()
        action?()
    }

    func stopStatusLine(_ statusLineID: String) {
        onStopStatusLine?(statusLineID)
    }

    /// Dictation learned a word from a fix the user made. Shipped Clicky
    /// shows the same "Added to your dictionary" card, with a Remove button.
    func showLearnedDictionaryWord(_ word: String, replacing originalText: String) {
        // A newer word replaces one that hasn't been shown yet.
        pendingAgentUpdates.removeAll { $0.learnedDictionaryWord != nil }
        pendingAgentUpdates.append((
            title: "Added to your dictionary",
            text: "\u{201C}\(word)\u{201D}. Dictation will write it this way instead of \u{201C}\(originalText)\u{201D}.",
            computerUseRequestAgentID: nil,
            learnedDictionaryWord: word,
            action: nil
        ))
        showNextPendingAgentUpdateIfIdle()
    }

    func removeLearnedDictionaryWord() {
        guard let word = learnedDictionaryWord else { return }
        learnedDictionaryWord = nil
        onRemoveLearnedDictionaryWord?(word)
        collapse()
    }

    func answerComputerUseRequest(isAllowed: Bool, alwaysAllow: Bool = false) {
        guard let agentID = computerUseRequestAgentID else { return }
        computerUseRequestAgentID = nil
        onAnswerComputerUseRequest?(agentID, isAllowed, alwaysAllow)
        collapse()
    }

    /// The question was answered somewhere else (a notification button), so
    /// stop asking it here.
    func dropComputerUseRequest(forAgentID agentID: UUID) {
        pendingAgentUpdates.removeAll { $0.computerUseRequestAgentID == agentID }
        guard computerUseRequestAgentID == agentID else { return }
        computerUseRequestAgentID = nil
        collapse()
    }

    private func showNextPendingAgentUpdateIfIdle() {
        guard surface == .compact, !pendingAgentUpdates.isEmpty else { return }
        let nextUpdate = pendingAgentUpdates.removeFirst()
        lastResponseText = nextUpdate.text
        lastResponseTitle = nextUpdate.title
        computerUseRequestAgentID = nextUpdate.computerUseRequestAgentID
        learnedDictionaryWord = nextUpdate.learnedDictionaryWord
        cardActionLabel = nextUpdate.action?.label
        cardAction = nextUpdate.action?.run
        surface = .textResponse
        startAutoDismiss()
        // A permission question waits for an answer instead of timing out.
        if nextUpdate.computerUseRequestAgentID != nil {
            isAutoDismissPaused = true
        }
    }

    // MARK: - User actions

    func openTextInput() {
        cancelAutoDismiss()
        surface = .textInput
    }

    func submitDraft() {
        let messageText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty else { return }
        draftText = ""
        liveCaptionText = ""
        surface = .thinking
        onSubmitTypedMessage?(messageText)
    }

    func cancelTextInput() {
        draftText = ""
        collapse()
    }

    func toggleAutoDismissPause() {
        isAutoDismissPaused.toggle()
    }

    // MARK: - Auto-dismiss

    private func startAutoDismiss() {
        cancelAutoDismiss()
        autoDismissProgress = 1
        isAutoDismissPaused = false

        autoDismissTask = Task { [weak self] in
            let tickSeconds = 0.05
            var elapsedSeconds = 0.0
            while elapsedSeconds < Self.textResponseAutoDismissSeconds {
                try? await Task.sleep(nanoseconds: UInt64(tickSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                // Hovering or pausing holds the card open.
                if self.isAutoDismissPaused || self.isHovering { continue }
                elapsedSeconds += tickSeconds
                self.autoDismissProgress = max(0, 1 - elapsedSeconds / Self.textResponseAutoDismissSeconds)
            }
            guard !Task.isCancelled, let self, self.surface == .textResponse else { return }
            self.surface = .compact
            self.showNextPendingAgentUpdateIfIdle()
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }
}
