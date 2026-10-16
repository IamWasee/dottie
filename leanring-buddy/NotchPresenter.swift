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
import Foundation

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
    }

    private static let textResponseAutoDismissSeconds: TimeInterval = 8

    @Published private(set) var surface: Surface = .compact
    @Published var isHovering = false
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
    @Published var draftText = ""
    /// 1 → 0 over the auto-dismiss window; drives the countdown ring.
    @Published private(set) var autoDismissProgress: Double = 1
    @Published private(set) var isAutoDismissPaused = false

    /// Set by CompanionManager.
    var onSubmitTypedMessage: ((String) -> Void)?
    var onOpenHome: (() -> Void)?
    var onAnswerComputerUseRequest: ((_ agentID: UUID, _ isAllowed: Bool, _ alwaysAllow: Bool) -> Void)?

    private var autoDismissTask: Task<Void, Never>?
    /// Agent reports that arrived while the notch was busy with a voice turn.
    private var pendingAgentUpdates: [(title: String, text: String, computerUseRequestAgentID: UUID?)] = []

    // MARK: - Inputs from the companion

    func showListening(label: String = "listening") {
        cancelAutoDismiss()
        liveCaptionText = ""
        activityLabel = label
        surface = .listening
    }

    func showThinking(label: String = "thinking") {
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
        surface = .textResponse
        startAutoDismiss()
    }

    func collapse() {
        cancelAutoDismiss()
        surface = .compact
        showNextPendingAgentUpdateIfIdle()
    }

    /// A background Clicky finished. Shown as a card right away if the notch
    /// is free, otherwise after the current voice turn.
    func showAgentUpdate(title: String, text: String, computerUseRequestAgentID: UUID? = nil) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        pendingAgentUpdates.append((title: title, text: trimmedText, computerUseRequestAgentID: computerUseRequestAgentID))
        showNextPendingAgentUpdateIfIdle()
    }

    func answerComputerUseRequest(isAllowed: Bool, alwaysAllow: Bool = false) {
        guard let agentID = computerUseRequestAgentID else { return }
        computerUseRequestAgentID = nil
        onAnswerComputerUseRequest?(agentID, isAllowed, alwaysAllow)
        collapse()
    }

    private func showNextPendingAgentUpdateIfIdle() {
        guard surface == .compact, !pendingAgentUpdates.isEmpty else { return }
        let nextUpdate = pendingAgentUpdates.removeFirst()
        lastResponseText = nextUpdate.text
        lastResponseTitle = nextUpdate.title
        computerUseRequestAgentID = nextUpdate.computerUseRequestAgentID
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
