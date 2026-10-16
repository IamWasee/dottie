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
    /// What Clicky is saying, as it says it.
    @Published private(set) var liveCaptionText = ""
    /// The last finished answer, shown on the text response surface.
    @Published private(set) var lastResponseText = ""
    @Published var draftText = ""
    /// 1 → 0 over the auto-dismiss window; drives the countdown ring.
    @Published private(set) var autoDismissProgress: Double = 1
    @Published private(set) var isAutoDismissPaused = false

    /// Set by CompanionManager.
    var onSubmitTypedMessage: ((String) -> Void)?
    var onOpenHome: (() -> Void)?

    private var autoDismissTask: Task<Void, Never>?

    // MARK: - Inputs from the companion

    func showListening() {
        cancelAutoDismiss()
        liveCaptionText = ""
        surface = .listening
    }

    func showThinking() {
        guard surface != .textInput else { return }
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
        surface = .textResponse
        startAutoDismiss()
    }

    func collapse() {
        cancelAutoDismiss()
        surface = .compact
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
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }
}
