//
//  DottieFunPack.swift
//  leanring-buddy
//
//  Wires the fun pack and 24/7 mode into the companion with as few hooks in
//  CompanionManager as possible: levels (DottieLevels), games (DottieGames),
//  24/7 jobs (DottieKeepWorking) and the locked screen (DottieScreenLock).
//  CompanionManager calls attach(to:) once at launch and reports each
//  finished helper turn here.
//

import Combine
import Foundation

@MainActor
final class DottieFunPack {
    static let shared = DottieFunPack()

    /// The companion, for the tool modules (they're static).
    private(set) weak var companion: CompanionManager?
    private var celebrationCancellable: AnyCancellable?

    private init() {}

    func attach(to companion: CompanionManager) {
        guard self.companion == nil else { return }
        self.companion = companion
        DottieKeepWorking.shared.attach(to: companion)

        // Level-ups get a card (with confetti) in the notch.
        celebrationCancellable = DottieLevels.shared.$celebration
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak companion] celebration in
                guard let companion else { return }
                var text = celebration.line
                if !celebration.unlocked.isEmpty {
                    text += "\nUnlocked: " + celebration.unlocked.joined(separator: ", ") + ". See Home → Profile."
                }
                companion.notchPresenter.showAgentUpdate(title: "Level up! " + celebration.title, text: text)
            }

        DottieScreenLock.shared.onChange = { [weak companion] isLocked in
            guard let companion else { return }
            if isLocked {
                if let pausedJob = companion.pauseScreenJobForLock() {
                    Self.sendToPhone(companion, "Your screen locked, so I paused \"\(Self.shortJobName(pausedJob))\". I'll finish it as soon as you unlock.")
                }
            } else {
                companion.resumeScreenJobsAfterUnlock()
            }
        }
    }

    /// Every finished helper turn (from CompanionManager).
    func helperTurnFinished(agentID: UUID, reply: String, succeeded: Bool, routineTitle: String?) {
        DottieLevels.shared.noteHelperFinished(agentID: agentID, succeeded: succeeded)
        DottieKeepWorking.shared.helperTurnFinished(agentID: agentID, reply: reply, succeeded: succeeded, routineTitle: routineTitle)
    }

    /// A screen job came in while the screen is locked; it waits in line.
    func noteScreenJobWaitingForUnlock(_ jobText: String) {
        guard let companion else { return }
        Self.sendToPhone(companion, "I'll do \"\(Self.shortJobName(jobText))\" as soon as you unlock your Mac.")
    }

    private static func sendToPhone(_ companion: CompanionManager, _ text: String) {
        guard companion.phoneBridge.pairedChatID != nil else { return }
        let phoneBridge = companion.phoneBridge
        Task { await phoneBridge.send(text) }
    }

    /// A job's text, short enough for a text message.
    static func shortJobName(_ jobText: String) -> String {
        let firstLine = jobText.components(separatedBy: .newlines).first ?? jobText
        return firstLine.count > 80 ? String(firstLine.prefix(77)) + "…" : firstLine
    }
}
