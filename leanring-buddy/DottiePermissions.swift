//
//  DottiePermissions.swift
//  leanring-buddy
//
//  Every macOS permission Dottie can use, in one place (Settings →
//  Permissions), with one button that asks for all of them in a row, so
//  the user allows them once instead of being asked here and there later.
//

import AppKit
import AVFoundation
import Combine
import Contacts
import CoreServices
import EventKit
import Network
import Speech
import UserNotifications

@MainActor
final class DottiePermissions: ObservableObject {
    static let shared = DottiePermissions()

    enum Kind: String, CaseIterable, Identifiable {
        case accessibility, screenRecording, microphone, speechRecognition, inputMonitoring
        case notifications, calendars, reminders, contacts, camera, automation, localNetwork

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech Recognition"
            case .inputMonitoring: return "Input Monitoring"
            case .notifications: return "Notifications"
            case .calendars: return "Calendars"
            case .reminders: return "Reminders"
            case .contacts: return "Contacts"
            case .camera: return "Camera"
            case .automation: return "Controlling apps"
            case .localNetwork: return "Local Network"
            }
        }

        var reason: String {
            switch self {
            case .accessibility: return "Pointing, clicking and typing for you, and your shortcut"
            case .screenRecording: return "Seeing your screen"
            case .microphone: return "Hearing you"
            case .speechRecognition: return "Live dictation text"
            case .inputMonitoring: return "Your push-to-talk shortcut in every app"
            case .notifications: return "Telling you when Dots finish"
            case .calendars: return "Reading and adding events"
            case .reminders: return "Reading and adding reminders"
            case .contacts: return "Finding people you mention"
            case .camera: return "TV capture cards"
            case .automation: return "Your browser, Finder and System Events"
            case .localNetwork: return "Smart home lights and TVs"
            }
        }

        /// Opens this permission's page in System Settings.
        var settingsURL: URL? {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .screenRecording: anchor = "Privacy_ScreenCapture"
            case .microphone: anchor = "Privacy_Microphone"
            case .speechRecognition: anchor = "Privacy_SpeechRecognition"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            case .notifications: return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
            case .calendars: anchor = "Privacy_Calendars"
            case .reminders: anchor = "Privacy_Reminders"
            case .contacts: anchor = "Privacy_Contacts"
            case .camera: anchor = "Privacy_Camera"
            case .automation: anchor = "Privacy_Automation"
            case .localNetwork: anchor = "Privacy_LocalNetwork"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
    }

    enum Status {
        case allowed, notAsked, denied, unknown
    }

    @Published private(set) var statuses: [Kind: Status] = [:]
    @Published private(set) var isAskingForAll = false
    /// Which one is being asked for right now, while asking for all.
    @Published private(set) var currentlyAsking: Kind?

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private var localNetworkBrowser: NWBrowser?

    var allowedCount: Int { statuses.values.filter { $0 == .allowed }.count }

    func refresh() async {
        var newStatuses: [Kind: Status] = [:]
        for kind in Kind.allCases {
            newStatuses[kind] = await status(of: kind)
        }
        statuses = newStatuses
    }

    // MARK: - Status

    private func status(of kind: Kind) async -> Status {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .allowed : .notAsked
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .allowed : .notAsked
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .allowed : .notAsked
        case .microphone:
            return Self.status(of: AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            return Self.status(of: AVCaptureDevice.authorizationStatus(for: .video))
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .allowed
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional: return .allowed
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .calendars:
            return Self.status(of: EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.status(of: EKEventStore.authorizationStatus(for: .reminder))
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .allowed
            case .notDetermined: return .notAsked
            case .denied, .restricted: return .denied
            default: return .allowed // .limited on macOS 15
            }
        case .automation:
            let results = await automationTargets().asyncMap { await Self.automationPermission(bundleIdentifier: $0, askIfNeeded: false) }
            if results.isEmpty { return .unknown }
            if results.contains(OSStatus(errAEEventNotPermitted)) { return .denied }
            if results.contains(OSStatus(errAEEventWouldRequireUserConsent)) { return .notAsked }
            return results.allSatisfy { $0 == 0 } ? .allowed : .unknown
        case .localNetwork:
            // macOS doesn't tell apps; remember that it was asked.
            return UserDefaults.standard.bool(forKey: "dottieAskedLocalNetwork") ? .unknown : .notAsked
        }
    }

    private static func status(of avStatus: AVAuthorizationStatus) -> Status {
        switch avStatus {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    private static func status(of ekStatus: EKAuthorizationStatus) -> Status {
        switch ekStatus {
        case .fullAccess, .authorized: return .allowed
        case .notDetermined, .writeOnly: return .notAsked
        default: return .denied
        }
    }

    // MARK: - Asking

    /// Asks for every permission that hasn't been asked yet, one after
    /// another: the quick yes/no dialogs first, then the ones macOS sends to
    /// System Settings (Accessibility, Screen Recording, Input Monitoring).
    func askForAll() async {
        guard !isAskingForAll else { return }
        isAskingForAll = true
        defer {
            isAskingForAll = false
            currentlyAsking = nil
        }
        await refresh()
        let dialogKinds: [Kind] = [.microphone, .speechRecognition, .notifications, .calendars, .reminders,
                                   .contacts, .camera, .automation, .localNetwork]
        let settingsKinds: [Kind] = [.accessibility, .screenRecording, .inputMonitoring]
        for kind in dialogKinds + settingsKinds where statuses[kind] != .allowed {
            currentlyAsking = kind
            await ask(for: kind)
            statuses[kind] = await status(of: kind)
        }
        await refresh()
    }

    func ask(for kind: Kind) async {
        if statuses[kind] == .denied {
            // macOS only asks once; after a no, the switch is in Settings.
            openSettings(for: kind)
            return
        }
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .speechRecognition:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .calendars:
            _ = try? await eventStore.requestFullAccessToEvents()
        case .reminders:
            _ = try? await eventStore.requestFullAccessToReminders()
        case .contacts:
            _ = try? await contactStore.requestAccess(for: .contacts)
        case .automation:
            for bundleIdentifier in await automationTargets() {
                _ = await Self.automationPermission(bundleIdentifier: bundleIdentifier, askIfNeeded: true)
            }
        case .localNetwork:
            askForLocalNetwork()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        case .accessibility:
            WindowPositionManager.requestAccessibilityPermission()
            await waitUntilAllowed(kind, seconds: 60)
        case .screenRecording:
            WindowPositionManager.requestScreenRecordingPermission()
            await waitUntilAllowed(kind, seconds: 60)
        case .inputMonitoring:
            if !CGRequestListenEventAccess() {
                await waitUntilAllowed(kind, seconds: 60)
            }
        }
    }

    func openSettings(for kind: Kind) {
        if let settingsURL = kind.settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// For the permissions switched on in System Settings: give the user a
    /// minute to flip the switch before moving on to the next one.
    private func waitUntilAllowed(_ kind: Kind, seconds: Int) async {
        for _ in 0..<(seconds * 2) {
            if await status(of: kind) == .allowed { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Starting a Bonjour search makes macOS ask about the local network.
    private func askForLocalNetwork() {
        UserDefaults.standard.set(true, forKey: "dottieAskedLocalNetwork")
        let browser = NWBrowser(for: .bonjour(type: "_hue._tcp", domain: nil), using: .tcp)
        browser.start(queue: .main)
        localNetworkBrowser = browser
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.localNetworkBrowser?.cancel()
            self?.localNetworkBrowser = nil
        }
    }

    // MARK: - Controlling apps

    /// Apps Dottie and her Dots script: System Events (keys and windows),
    /// Finder, and the browsers that are open. Apps that aren't running are
    /// skipped rather than launched just to ask.
    private func automationTargets() async -> [String] {
        await Self.launchSystemEventsIfNeeded()
        var targets = ["com.apple.systemevents", "com.apple.finder"]
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for runningID in runningIDs.sorted() where DottieBrowser.isBrowser(bundleIdentifier: runningID) {
            targets.append(runningID)
        }
        return targets.filter { runningIDs.contains($0) }
    }

    private static func launchSystemEventsIfNeeded() async {
        let systemEventsID = "com.apple.systemevents"
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == systemEventsID }),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEventsID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    /// noErr when allowed, errAEEventWouldRequireUserConsent when not asked
    /// yet, errAEEventNotPermitted when the user said no. Asking blocks
    /// until the user answers, so it runs off the main thread.
    nonisolated private static func automationPermission(bundleIdentifier: String, askIfNeeded: Bool) async -> OSStatus {
        await Task.detached {
            var target = AEAddressDesc()
            let utf8Identifier = Array(bundleIdentifier.utf8)
            let createStatus = utf8Identifier.withUnsafeBytes { bytes in
                AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, bytes.count, &target)
            }
            guard createStatus == 0 else { return OSStatus(createStatus) }
            defer { _ = AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), askIfNeeded)
        }.value
    }
}

private extension Array {
    func asyncMap<Transformed>(_ transform: (Element) async -> Transformed) async -> [Transformed] {
        var results: [Transformed] = []
        for element in self { results.append(await transform(element)) }
        return results
    }
}
