//
//  ClickyNotifications.swift
//  leanring-buddy
//
//  macOS notifications for Dots. Shipped Clicky posts one when a background
//  agent finishes or needs the user (its CompanionManager notifications
//  extension); the clone does the same with UserNotifications, so a Dot's
//  reply still reaches you when you're in another app and the notch card
//  has folded away.
//
//  Each Dot has at most one notification at a time (its identifier is the
//  Dot's id), so a new reply replaces the old one, and opening the Dot's
//  chat clears it. Clicking a notification opens the Dot in Home. A request
//  to use the Mac gets Allow and Don't Allow buttons.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class ClickyNotifications: NSObject {
    nonisolated static let enabledDefaultsKey = "clickyDotNotificationsEnabled"

    /// On unless the user turned it off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Clicked a notification (or its body): show this Dot.
    var onOpenDot: ((UUID) -> Void)?
    /// Answered a computer-use request from the notification's buttons.
    var onAnswerComputerUseRequest: ((_ agentID: UUID, _ isAllowed: Bool) -> Void)?

    nonisolated private static let computerUseCategoryID = "DOT_COMPUTER_USE"
    nonisolated private static let allowActionID = "ALLOW"
    nonisolated private static let declineActionID = "DECLINE"
    nonisolated private static let agentIDUserInfoKey = "agentID"

    private let notificationCenter = UNUserNotificationCenter.current()
    /// Dots with a notification showing, so it can be cleared once read.
    private var notifiedAgentIDs: Set<UUID> = []

    /// Sets the delegate and the Allow / Don't Allow buttons. Call once at
    /// launch so clicks on notifications delivered earlier still arrive.
    func configure() {
        notificationCenter.delegate = self
        let allowAction = UNNotificationAction(identifier: Self.allowActionID, title: "Allow", options: [])
        let declineAction = UNNotificationAction(identifier: Self.declineActionID, title: "Don't Allow", options: [])
        let computerUseCategory = UNNotificationCategory(
            identifier: Self.computerUseCategoryID,
            actions: [allowAction, declineAction],
            intentIdentifiers: [],
            options: []
        )
        notificationCenter.setNotificationCategories([computerUseCategory])
    }

    // MARK: - Posting

    /// A Dot finished a turn. Skipped while Dottie's own window is in front,
    /// since the reply is already on screen.
    func notifyDotFinished(agentID: UUID, title: String, text: String) {
        post(agentID: agentID, title: title, body: text, isComputerUseRequest: false)
    }

    /// A Dot wants to click and type. Posted even while Dottie is in front,
    /// because the Dot is stuck until someone answers.
    func notifyComputerUseRequest(agentID: UUID, title: String, text: String) {
        post(agentID: agentID, title: title, body: text, isComputerUseRequest: true)
    }

    private func post(agentID: UUID, title: String, body: String, isComputerUseRequest: Bool) {
        guard Self.isEnabled else { return }
        if !isComputerUseRequest && NSApp.isActive { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = Self.shortened(body)
        content.sound = isComputerUseRequest ? .default : nil
        content.threadIdentifier = agentID.uuidString
        content.userInfo = [Self.agentIDUserInfoKey: agentID.uuidString]
        if isComputerUseRequest {
            content.categoryIdentifier = Self.computerUseCategoryID
        }
        let request = UNNotificationRequest(identifier: agentID.uuidString, content: content, trigger: nil)

        // Asks the first time a notification would be shown; after that the
        // system remembers the answer and this returns at once.
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] isGranted, _ in
            guard isGranted else { return }
            Task { @MainActor in
                guard let self else { return }
                self.notifiedAgentIDs.insert(agentID)
                self.notificationCenter.add(request)
            }
        }
    }

    /// Notification bodies wrap at a few lines anyway; keep them readable.
    private static func shortened(_ text: String) -> String {
        let oneLineText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLineText.count > 240 else { return oneLineText }
        return String(oneLineText.prefix(240)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Clearing

    func removeNotification(forAgentID agentID: UUID) {
        guard notifiedAgentIDs.remove(agentID) != nil else { return }
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [agentID.uuidString])
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [agentID.uuidString])
    }

    /// Clears notifications for Dots whose replies have been read and for
    /// Dots that no longer exist.
    func removeNotifications(keepingAgentIDs unreadAgentIDs: Set<UUID>) {
        for agentID in notifiedAgentIDs.subtracting(unreadAgentIDs) {
            removeNotification(forAgentID: agentID)
        }
    }

    var hasNotificationsShowing: Bool { !notifiedAgentIDs.isEmpty }

    // MARK: - Handling clicks

    private func handleResponse(actionIdentifier: String, agentIDString: String?) {
        guard let agentIDString, let agentID = UUID(uuidString: agentIDString) else { return }
        notifiedAgentIDs.remove(agentID)
        switch actionIdentifier {
        case Self.allowActionID:
            onAnswerComputerUseRequest?(agentID, true)
        case Self.declineActionID:
            onAnswerComputerUseRequest?(agentID, false)
        case UNNotificationDefaultActionIdentifier:
            onOpenDot?(agentID)
        default:
            break
        }
    }
}

extension ClickyNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let agentIDString = response.notification.request.content.userInfo[Self.agentIDUserInfoKey] as? String
        Task { @MainActor in
            self.handleResponse(actionIdentifier: actionIdentifier, agentIDString: agentIDString)
        }
        completionHandler()
    }

    /// Shows a notification even while Dottie is the active app (only the
    /// computer-use questions are posted then).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
