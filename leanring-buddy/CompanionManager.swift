//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//
//  Two voice modes (Info.plist key CompanionVoiceMode):
//    live    (default) Gemini Live: mic audio + one screenshot frame stream in,
//            spoken audio streams back, pointing arrives as a tool call.
//    classic v0's original chain with Gemini swapped in: Apple Speech →
//            Gemini Flash vision → Gemini TTS, pointing via [POINT:] tags.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum CompanionVoiceMode: String {
    case live
    case classic

    static var configuredMode: CompanionVoiceMode {
        AppBundleConfiguration.stringValue(forKey: "CompanionVoiceMode")
            .flatMap { CompanionVoiceMode(rawValue: $0.lowercased()) } ?? .live
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the model's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let voiceMode = CompanionVoiceMode.configuredMode

    /// The Gemini Live session used in live mode. Idle (no socket) until the
    /// first push-to-talk.
    let liveVoiceClient = GeminiLiveVoiceClient()

    /// In live mode the mic audio goes to Gemini Live through a bridge
    /// provider; in classic mode it goes to Apple Speech. Lazy because the
    /// live provider's turn-start closure needs `self`.
    private(set) lazy var buddyDictationManager: BuddyDictationManager = {
        switch voiceMode {
        case .live:
            let liveProvider = GeminiLiveCompanionTranscriptionProvider(
                liveVoiceClient: liveVoiceClient,
                beginLiveTurn: { [weak self] in
                    await self?.beginLiveTurnWithScreenFrame()
                }
            )
            return BuddyDictationManager(transcriptionProvider: liveProvider)
        case .classic:
            return BuddyDictationManager()
        }
    }()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// The conversation shown on Home, persisted across launches.
    let conversationStore = ConversationStore()
    /// Background agents ("Clickys") that run on Gemini CLI.
    let clickyRoster = ClickyRoster()
    /// Hold right Option to dictate into any app.
    let dictationController = ClickyDictationController()
    private var dictationCancellables: Set<AnyCancellable> = []
    private var clickyRosterCancellable: AnyCancellable?
    /// State of the notch surface (listening, speaking, typed input, …).
    let notchPresenter = NotchPresenter()
    /// macOS notifications when a Dot finishes or needs an answer.
    let dotNotifications = ClickyNotifications()
    private lazy var notchWindowManager = NotchWindowManager(notchPresenter: notchPresenter)
    private lazy var homeWindowManager = HomeWindowManager(
        companionManager: self,
        conversationStore: conversationStore,
        clickyRoster: clickyRoster
    )
    /// Text the user typed for the current live turn, if it was typed rather
    /// than spoken. Live only transcribes audio, so we remember it ourselves.
    private var currentLiveTurnTypedText: String?
    private var notchVoiceStateCancellable: AnyCancellable?
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Gemini Flash vision chat via the Worker. Used by the onboarding demo
    /// and by classic mode.
    private lazy var geminiAPI: GeminiAPI = {
        return GeminiAPI(proxyURL: ClickyWorkerConfiguration.url(forRoute: "/chat"))
    }()

    /// Classic mode only. Live mode speaks through the Live session itself.
    private lazy var geminiTTSClient: GeminiTTSClient = {
        return GeminiTTSClient(proxyURL: ClickyWorkerConfiguration.url(forRoute: "/tts"))
    }()

    /// Conversation history so the companion remembers prior exchanges within
    /// a session. Each entry is the user's transcript and the spoken reply.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The screenshot frame sent with the current live turn. Pointing tool
    /// calls are in this frame's coordinate space.
    private var currentLiveTurnScreenFrame: CompanionCompositeScreenFrame?
    private var currentLiveTurnScreenFrameCapturedAt: Date?

    /// Circle to ask: the cursor trail while the talk shortcut is held.
    let screenAnnotationManager = ScreenAnnotationManager()
    /// What the user circled during the latest voice turn, if anything.
    private var currentTurnAnnotation: ScreenAnnotation?

    /// True from push-to-talk press until the live answer has finished
    /// playing. Keeps the dictation state observer from flipping the cursor
    /// back to idle in the gap between "user stopped talking" and "Gemini
    /// started talking".
    private var isLiveTurnInFlight = false
    private var liveTurnPlaybackDrainTask: Task<Void, Never>?
    private var currentClassicTurnInputKind: ConversationEntry.InputKind = .voice

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var escapeKeyCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Gemini Live voice the companion speaks with. Persisted to
    /// UserDefaults. Takes effect on the next Live connection.
    @Published var selectedVoiceName: String = UserDefaults.standard.string(forKey: "selectedGeminiLiveVoice") ?? "Kore"

    func setSelectedVoiceName(_ voiceName: String) {
        selectedVoiceName = voiceName
        UserDefaults.standard.set(voiceName, forKey: "selectedGeminiLiveVoice")
        liveVoiceClient.voiceName = voiceName
        // Reconnect with the new voice on the next press, unless mid-answer.
        if !liveVoiceClient.isModelTurnInProgress {
            liveVoiceClient.disconnect()
        }
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether Clicky's notch surface is shown. Persisted; on by default.
    @Published private(set) var isNotchEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyNotchEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyNotchEnabled")

    func setNotchEnabled(_ enabled: Bool) {
        isNotchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyNotchEnabled")
        if enabled && hasCompletedOnboarding {
            notchWindowManager.show()
        } else {
            notchWindowManager.hide()
        }
    }

    func openHomeWindow() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        homeWindowManager.showHomeWindow()
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Records the user's email locally (and in analytics, if configured).
    /// v0 also posted it to Farza's FormSpark form; the clone doesn't.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
        UserDefaults.standard.set(trimmedEmail, forKey: "submittedEmail")

        ClickyAnalytics.identifyUser(email: trimmedEmail)
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Dottie start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindDictation()
        configureLiveVoiceClient()
        // Eagerly touch the Gemini API so its TLS warmup handshake completes
        // well before the onboarding demo fires.
        _ = geminiAPI

        if !ClickyWorkerConfiguration.isWorkerConfigured {
            print("⚠️ Dottie: ClickyWorkerBaseURL is not set in Info.plist — voice won't work until it points at your worker.")
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        configureNotch()
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true
        if isNotchEnabled {
            notchWindowManager.show()
        }

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Dottie: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Dottie: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        liveVoiceClient.disconnect()
        notchWindowManager.hide()
        notchVoiceStateCancellable?.cancel()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        escapeKeyCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
                self?.notchPresenter.audioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                // In live mode, once the user lets go the answer is already
                // on its way; show the spinner until Gemini starts talking.
                if self.isLiveTurnInFlight && !isRecording {
                    self.voiceState = .processing
                    return
                }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleEscapeInterrupt()
            }

        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    // MARK: - Dictation

    private func bindDictation() {
        let shortcutMonitor = globalPushToTalkShortcutMonitor

        shortcutMonitor.dictationShortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                guard let self else { return }
                switch transition {
                case .pressed:
                    // The companion and dictation share the microphone.
                    guard self.hasCompletedOnboarding,
                          !self.showOnboardingVideo,
                          !self.buddyDictationManager.isDictationInProgress,
                          !self.isLiveTurnInFlight else { return }
                    self.dictationController.beginDictation()
                case .released:
                    self.dictationController.finishDictation()
                case .none:
                    break
                }
            }
            .store(in: &dictationCancellables)

        // Right Option plus a key is a special character, not dictation.
        shortcutMonitor.keyPressedDuringDictationPublisher
            .merge(with: shortcutMonitor.escapeKeyPressedPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.dictationController.state != .idle else { return }
                self.dictationController.cancelDictation()
            }
            .store(in: &dictationCancellables)

        dictationController.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dictationState in
                guard let self, self.isNotchEnabled else { return }
                switch dictationState {
                case .recording:
                    self.notchPresenter.showListening(label: "dictating")
                case .transcribing:
                    self.notchPresenter.showThinking(label: "writing")
                case .idle:
                    let isNotchShowingDictation = self.notchPresenter.surface == .listening || self.notchPresenter.surface == .thinking
                    if isNotchShowingDictation && self.voiceState == .idle && !self.isLiveTurnInFlight {
                        self.notchPresenter.collapse()
                    }
                }
            }
            .store(in: &dictationCancellables)

        dictationController.$audioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                guard let self, self.dictationController.state == .recording else { return }
                self.notchPresenter.audioPowerLevel = powerLevel
            }
            .store(in: &dictationCancellables)

        dictationController.onFinished = { [weak self] outcome, dictatedText in
            guard let self, outcome == .copiedToClipboard else { return }
            self.notchPresenter.showAgentUpdate(title: "Copied to your clipboard", text: dictatedText)
        }

        dictationController.onError = { [weak self] errorMessage in
            self?.notchPresenter.showAgentUpdate(title: "Dictation", text: errorMessage)
        }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard dictationController.state == .idle else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            showOverlayTransientlyIfNeeded()

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and speech from a previous utterance
            currentResponseTask?.cancel()
            stopAllSpeechPlayback()
            clearDetectedElementLocation()
            currentTurnAnnotation = nil
            screenAnnotationManager.startTracking()
            if voiceMode == .live {
                liveTurnPlaybackDrainTask?.cancel()
                isLiveTurnInFlight = true
                voiceState = .idle
            }

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        // In live mode Gemini already heard the audio and is
                        // answering; the transcript is just for display/history.
                        if self.voiceMode == .classic {
                            self.sendTranscriptToGeminiWithScreenshot(transcript: finalTranscript)
                        }
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            // Before the turn closes, so Live gets the marked frame inside it.
            currentTurnAnnotation = screenAnnotationManager.finishTracking()
            if voiceMode == .live, let currentTurnAnnotation {
                sendAnnotationToLiveTurn(currentTurnAnnotation)
            }
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            if voiceMode == .live {
                clearLiveTurnIfItNeverStarted()
            }
        case .none:
            break
        }
    }

    // MARK: - Classic Mode Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're dottie, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.
    - if a screen image has a bright blue hand-drawn ring on it, the user circled that with their cursor while talking. it's what they're asking about.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - Live Voice Pipeline (Gemini Live)

    /// Live mode's system prompt. Same personality as v0's, but pointing is a
    /// tool call instead of a text tag, because the model's output is audio.
    private static let companionLiveVoiceSystemPrompt = """
    you're dottie, a friendly always-on companion that lives in the user's menu bar. the user talks to you with push-to-talk, and with each turn you get one frame showing their screen(s). you answer out loud. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - casual and warm, like a smart friend sitting next to them. speak naturally, no lists or reading out formatting.
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screen doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming. use google search when you need fresh facts.
    - never say "simply" or "just".
    - don't end with dead-end yes/no questions like "want me to explain more?". instead, when it fits naturally, plant a seed — mention something bigger they could try, or a next-level technique that builds on what you explained. it's okay to end without anything extra.
    - if the frame shows several screens side by side, the one marked as the cursor screen is the primary focus.
    - the user can circle things with their cursor while talking. if a frame shows a bright blue hand-drawn ring, that's what they marked and are asking about.

    pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen, using the point_at_element tool. use it whenever pointing would genuinely help — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app. err on the side of pointing, because it makes your help way more concrete. don't point for general knowledge questions or at something obvious they're already looking at.
    the tool takes x and y from 0 to 1000 across the whole frame (0,0 is the top-left corner, 1000,1000 the bottom-right) and a short label. call it once, then keep talking as if you're gesturing at it, e.g. "see that button up here? click it."

    going deeper:
    you're the fast voice. for questions that need careful reading of small text, code, a long document, precise steps, or real reasoning, call send_to_higher_model with the question. say a few words first ("let me take a closer look"), then speak the answer it returns in your own voice. it can point the cursor too, so don't point again for the same thing.

    dots:
    the user can have background helpers called dots that work on their own, with a shell, files and the web, and report back in the notch when done. when they ask for real work that takes more than an answer (research something, write or edit files, organize a folder, build something, or do something in an app like adding a reminder or filling in a form) or mention a dot by name, call start_clicky_task with a task that stands on its own. then just say it's started, in a few words. don't do the task yourself.
    """

    /// Hooks the Live client's callbacks into the companion's state.
    private func configureLiveVoiceClient() {
        liveVoiceClient.baseSystemInstruction = Self.companionLiveVoiceSystemPrompt
        liveVoiceClient.voiceName = selectedVoiceName

        liveVoiceClient.onModelSpeechStarted = { [weak self] in
            guard let self, self.isLiveTurnInFlight else { return }
            self.voiceState = .responding
        }

        liveVoiceClient.onModelTranscriptUpdate = { [weak self] modelTranscriptSoFar in
            self?.notchPresenter.updateLiveCaption(modelTranscriptSoFar)
        }

        liveVoiceClient.onPointRequest = { [weak self] pointRequest in
            self?.pointAtLiveElement(pointRequest)
        }

        liveVoiceClient.onModelTurnComplete = { [weak self] userTranscript, modelTranscript in
            self?.finishLiveTurn(userTranscript: userTranscript, modelTranscript: modelTranscript)
        }

        liveVoiceClient.onHigherModelRequest = { [weak self] question in
            guard let self else { return "the deeper model isn't available right now. answer as best you can." }
            return await self.answerWithHigherModel(question: question)
        }

        liveVoiceClient.onStartClickyTask = { [weak self] clickyName, taskText in
            guard let self else { return "couldn't start it right now." }
            return self.startClickyTask(clickyName: clickyName, taskText: taskText)
        }

        liveVoiceClient.onTurnError = { [weak self] error in
            guard let self else { return }
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            print("⚠️ Gemini Live turn error: \(error)")
            self.isLiveTurnInFlight = false
            self.speakConnectionErrorFallback()
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Called by the live transcription provider when push-to-talk opens.
    /// Grabs the screen frame and opens the user's turn on the Live session.
    private func beginLiveTurnWithScreenFrame() async {
        let compositeScreenFrame: CompanionCompositeScreenFrame?
        do {
            compositeScreenFrame = try await CompanionScreenCaptureUtility.captureCompositeFrameForLive()
        } catch {
            print("⚠️ Gemini Live: screen capture failed, sending voice only: \(error)")
            compositeScreenFrame = nil
        }

        currentLiveTurnScreenFrame = compositeScreenFrame
        currentLiveTurnScreenFrameCapturedAt = compositeScreenFrame == nil ? nil : Date()
        liveVoiceClient.beginUserTurn(screenFrameJPEGData: compositeScreenFrame?.jpegData)

        if let compositeScreenFrame, compositeScreenFrame.regions.count > 1 {
            liveVoiceClient.sendTurnContextText(compositeScreenFrame.layoutDescription)
        }
    }

    /// Sends the turn's frame again with the circled area marked, plus a
    /// note saying what the ring means. Only when this turn's frame has
    /// been captured, which also means its Live turn is open.
    private func sendAnnotationToLiveTurn(_ annotation: ScreenAnnotation) {
        guard let currentLiveTurnScreenFrame,
              let frameCapturedAt = currentLiveTurnScreenFrameCapturedAt,
              let trackingStartedAt = screenAnnotationManager.trackingStartedAt,
              frameCapturedAt >= trackingStartedAt,
              let annotatedFrameJPEGData = annotation.drawRing(on: currentLiveTurnScreenFrame) else { return }
        liveVoiceClient.sendScreenFrame(jpegData: annotatedFrameJPEGData)
        liveVoiceClient.sendTurnContextText(ScreenAnnotation.modelContextText)
    }

    /// Screenshot images for the classic and higher models, with the turn's
    /// circled area drawn on the screen it's on.
    private func labeledScreenImages(
        from screenCaptures: [CompanionScreenCapture],
        annotation: ScreenAnnotation?
    ) -> [(data: Data, label: String)] {
        screenCaptures.map { capture in
            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
            if let annotation, let annotatedImageData = annotation.drawRing(on: capture) {
                return (data: annotatedImageData, label: capture.label + dimensionInfo + " — the blue ring is what the user circled")
            }
            return (data: capture.imageData, label: capture.label + dimensionInfo)
        }
    }

    private func pointAtLiveElement(_ pointRequest: GeminiLivePointRequest) {
        guard let currentLiveTurnScreenFrame,
              let resolvedPoint = currentLiveTurnScreenFrame.resolveNormalizedPoint(
                normalizedX: pointRequest.normalizedX,
                normalizedY: pointRequest.normalizedY
              ) else {
            print("🎯 Live pointing ignored: no frame for this turn")
            return
        }

        detectedElementScreenLocation = Self.globalScreenLocation(
            forScreenshotPixel: resolvedPoint.pointInScreenshotPixels,
            in: resolvedPoint.screenCapture
        )
        detectedElementDisplayFrame = resolvedPoint.screenCapture.displayFrame
        ClickyAnalytics.trackElementPointed(elementLabel: pointRequest.elementLabel)
        print("🎯 Live pointing: (\(Int(pointRequest.normalizedX)), \(Int(pointRequest.normalizedY)))/1000 → \"\(pointRequest.elementLabel ?? "element")\"")
    }

    /// A press released before the mic session opened never reaches Gemini,
    /// so no answer will come to clear the spinner. Check shortly after
    /// release and fall back to idle in that case.
    private func clearLiveTurnIfItNeverStarted() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.isLiveTurnInFlight else { return }
            guard !self.liveVoiceClient.isModelTurnInProgress,
                  !self.buddyDictationManager.isDictationInProgress else { return }
            self.isLiveTurnInFlight = false
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Records the exchange, then waits for the last of the audio to play
    /// before returning the cursor to idle.
    private func finishLiveTurn(userTranscript: String, modelTranscript: String) {
        let typedTextForThisTurn = currentLiveTurnTypedText
        currentLiveTurnTypedText = nil
        // A typed turn has no audio, so Live's input transcript is empty.
        let userTranscript = typedTextForThisTurn ?? userTranscript

        if !userTranscript.isEmpty || !modelTranscript.isEmpty {
            conversationStore.append(
                userText: userTranscript,
                clickyText: modelTranscript,
                inputKind: typedTextForThisTurn == nil ? .voice : .typed
            )
            conversationHistory.append((userTranscript: userTranscript, assistantResponse: modelTranscript))
            if conversationHistory.count > 10 {
                conversationHistory.removeFirst(conversationHistory.count - 10)
            }
            liveVoiceClient.recentConversationHistory = conversationHistory.map { exchange in
                (userTranscript: exchange.userTranscript, modelTranscript: exchange.assistantResponse)
            }
            ClickyAnalytics.trackAIResponseReceived(response: modelTranscript)
        }

        liveTurnPlaybackDrainTask?.cancel()
        liveTurnPlaybackDrainTask = Task { [weak self] in
            while self?.liveVoiceClient.isModelAudioPlaying == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.isLiveTurnInFlight = false
            // Only drop to idle if the user hasn't started a new turn.
            if !self.buddyDictationManager.isDictationInProgress {
                self.voiceState = .idle
                self.notchPresenter.showFinishedResponse(modelTranscript)
                self.scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Clickys (background agents)

    /// Starts a background task from voice. Uses the named Clicky (creating
    /// it if it doesn't exist yet), or a general "Helper" Clicky.
    /// Returns a short status for the voice model to relay.
    func startClickyTask(clickyName: String?, taskText: String) -> String {
        guard GeminiCLIAgentRuntime.locateGeminiCLIExecutable() != nil else {
            return "background dots need gemini cli installed on this mac, and it isn't yet. tell the user to install it with npm install -g @google/gemini-cli."
        }

        let targetAgent: ClickyAgent
        if let clickyName, let existingAgent = clickyRoster.agent(matchingName: clickyName) {
            targetAgent = existingAgent
        } else if let clickyName {
            targetAgent = clickyRoster.createAgent(name: clickyName, purpose: "")
        } else if let helperAgent = clickyRoster.agent(matchingName: "Helper"), !clickyRoster.isRunning(helperAgent) {
            targetAgent = helperAgent
        } else {
            let idleAgentCount = clickyRoster.agents.filter { $0.name.hasPrefix("Helper") }.count
            targetAgent = clickyRoster.createAgent(
                name: idleAgentCount == 0 ? "Helper" : "Helper \(idleAgentCount + 1)",
                purpose: "General background tasks the user hands off by voice."
            )
        }

        guard !clickyRoster.isRunning(targetAgent) else {
            return "\(targetAgent.name) is still busy with another task. tell the user it'll need to finish first."
        }
        clickyRoster.sendMessage(taskText, to: targetAgent)
        ClickyAnalytics.trackClickyTaskStarted()
        return "started. \(targetAgent.name) is working on it and will report back in the notch."
    }

    private func configureClickyRoster() {
        clickyRoster.onAgentTurnFinished = { [weak self] turnResult in
            guard let self else { return }
            let updateTitle = turnResult.routineTitle.map { "\(turnResult.agent.name) · \($0)" } ?? turnResult.agent.name
            if let computerUseRequest = turnResult.computerUseRequest {
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
            self.notchPresenter.showAgentUpdate(title: updateTitle, text: updateText)
            self.dotNotifications.notifyDotFinished(agentID: turnResult.agent.id, title: updateTitle, text: updateText)
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

    // MARK: - Notch and Typed Messages

    private func configureNotch() {
        configureClickyRoster()
        notchPresenter.onSubmitTypedMessage = { [weak self] messageText in
            self?.sendTypedMessage(messageText)
        }
        notchPresenter.onOpenHome = { [weak self] in
            self?.openHomeWindow()
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
    func sendTypedMessage(_ messageText: String) {
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessageText.isEmpty else { return }
        guard !buddyDictationManager.isDictationInProgress else { return }

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
            sendTranscriptToGeminiWithScreenshot(transcript: trimmedMessageText, inputKind: .typed)
        case .live:
            liveTurnPlaybackDrainTask?.cancel()
            isLiveTurnInFlight = true
            currentLiveTurnTypedText = trimmedMessageText
            voiceState = .processing
            Task { [weak self] in
                guard let self else { return }
                await self.beginLiveTurnWithScreenFrame()
                self.liveVoiceClient.sendTurnContextText(trimmedMessageText)
                self.liveVoiceClient.endUserTurn()
            }
        }
    }

    /// With "Show Clicky" off, the cursor overlay appears only for the
    /// length of an interaction, so pointing is still visible.
    private func showOverlayTransientlyIfNeeded() {
        guard !isClickyCursorEnabled && !isOverlayVisible else { return }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    // MARK: - Escape Interrupt

    /// Escape cuts the companion off: stops speech, abandons the answer in
    /// flight, and drops a recording without sending it. Does nothing while
    /// the companion is idle, so Escape keeps working normally elsewhere.
    private func handleEscapeInterrupt() {
        let isCompanionBusy = voiceState != .idle || isLiveTurnInFlight || isAnySpeechPlaying
        guard isCompanionBusy else { return }

        print("⎋ Escape interrupt")
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

        isLiveTurnInFlight = false
        currentLiveTurnTypedText = nil
        voiceState = .idle
        notchPresenter.collapse()
        scheduleTransientHideIfNeeded()
    }

    // MARK: - Higher Model Hand-off

    /// System prompt for the stronger model that answers send_to_higher_model.
    /// Its text goes back to Gemini Live, which says it out loud.
    private static let higherModelSystemPrompt = """
    you're the careful, thorough brain behind dottie, a voice companion on the user's mac. the fast voice model handed you a question it wanted a closer look at. you get full screenshots of every screen. your answer goes back to the voice model, which will say it out loud to the user.

    rules:
    - answer the question directly and correctly. read small text, code and dense ui carefully.
    - write for the ear: plain sentences, no markdown, no lists, no code blocks. describe code changes in words.
    - be as short as the question allows: usually two to five sentences. give precise steps when steps are needed.
    - if the screenshots don't contain what's needed, say what you'd need instead of guessing.

    pointing: if pointing at one ui element would help, append a tag at the very end: [POINT:x,y:label] with integer pixel coordinates in that screenshot's coordinate space (top-left is 0,0; images are labeled with their dimensions), and :screenN if it isn't on the cursor screen. otherwise append [POINT:none].
    """

    /// Answers a hand-off from Gemini Live with a stronger model and fresh
    /// screenshots. Points the cursor if the answer says to, and returns the
    /// text for Live to speak. Errors come back as instructions for Live to
    /// relay, so the user always hears something.
    private func answerWithHigherModel(question: String) async -> String {
        print("🧠 Higher model hand-off: \(question)")
        ClickyAnalytics.trackHigherModelHandoff()

        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            let labeledImages = labeledScreenImages(from: screenCaptures, annotation: currentTurnAnnotation)
            let historyForAPI = conversationHistory.map { entry in
                (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
            }

            let (fullResponseText, responseDuration) = try await geminiAPI.analyzeImageStreaming(
                images: labeledImages,
                systemPrompt: Self.higherModelSystemPrompt,
                conversationHistory: historyForAPI,
                userPrompt: question,
                modelOverride: "higher",
                maxOutputTokens: 2048,
                onTextChunk: { _ in }
            )
            print("🧠 Higher model answered in \(Int(responseDuration * 1000))ms")

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
            print("⚠️ Higher model hand-off failed: \(error)")
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            return "the deeper look failed (\(error.localizedDescription)). tell the user in one short line, then answer as best you can from what you see."
        }
    }

    // MARK: - Classic Voice Pipeline (Apple Speech → Gemini Flash → Gemini TTS)

    /// Captures a screenshot, sends it along with the transcript to Gemini,
    /// and plays the response aloud via Gemini TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// The response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToGeminiWithScreenshot(
        transcript: String,
        inputKind: ConversationEntry.InputKind = .voice
    ) {
        currentClassicTurnInputKind = inputKind
        notchPresenter.updateLiveCaption("")
        currentResponseTask?.cancel()
        stopAllSpeechPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Label each image with its pixel dimensions so the model's
                // coordinate space matches the image it sees. A voice turn
                // where the user circled something gets the ring drawn in.
                let turnAnnotation = inputKind == .voice ? currentTurnAnnotation : nil
                let labeledImages = labeledScreenImages(from: screenCaptures, annotation: turnAnnotation)
                let promptForModel = turnAnnotation == nil
                    ? transcript
                    : "\(transcript)\n\n(\(ScreenAnnotation.modelContextText))"

                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await geminiAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: promptForModel,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

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
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save the exchange with the point tag stripped so it doesn't
                // confuse future context.
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                conversationStore.append(
                    userText: transcript,
                    clickyText: spokenText,
                    inputKind: currentClassicTurnInputKind
                )
                notchPresenter.updateLiveCaption(spokenText)

                // Keep the spinner until audio actually starts playing.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await geminiTTSClient.speakText(spokenText)
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ Gemini TTS error, falling back to system voice: \(error)")
                        speakWithSystemVoice(spokenText)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakConnectionErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                notchPresenter.showFinishedResponse(notchPresenter.liveCaptionText)
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Shared Helpers

    /// Converts a pixel position in a screenshot (top-left origin) to a global
    /// AppKit screen location (bottom-left origin) on that screenshot's display.
    static func globalScreenLocation(
        forScreenshotPixel screenshotPixel: CGPoint,
        in screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame

        let clampedX = max(0, min(screenshotPixel.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPixel.y, screenshotHeight))

        // Scale from screenshot pixels to display points
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Flip from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    private var isAnySpeechPlaying: Bool {
        switch voiceMode {
        case .live:
            return liveVoiceClient.isModelAudioPlaying
        case .classic:
            return geminiTTSClient.isPlaying || systemSpeechSynthesizer.isSpeaking
        }
    }

    private func stopAllSpeechPlayback() {
        liveVoiceClient.interruptModelSpeech()
        if voiceMode == .classic {
            geminiTTSClient.stopPlayback()
        }
        systemSpeechSynthesizer.stopSpeaking()
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for speech and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while isAnySpeechPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// macOS's built-in voice, used when Gemini can't be reached so the user
    /// still hears what went wrong.
    private let systemSpeechSynthesizer = NSSpeechSynthesizer()

    private func speakWithSystemVoice(_ text: String) {
        systemSpeechSynthesizer.startSpeaking(text)
        voiceState = .responding
    }

    private func speakConnectionErrorFallback() {
        let utterance = ClickyWorkerConfiguration.isWorkerConfigured
            ? "I couldn't reach Gemini. Check that your worker is deployed and your API key is set, then try again."
            : "I'm not set up yet. Put your worker's address in the app's Info.plist and try again."
        speakWithSystemVoice(utterance)
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

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    ///
    /// v0 streamed Farza's own intro video from Mux. The clone reads the URL
    /// from Info.plist (OnboardingVideoURL); with none set, it skips the video
    /// and runs the pointing demo and the "try talking" prompt straight away.
    func setupOnboardingVideo() {
        guard let videoURLString = AppBundleConfiguration.stringValue(forKey: "OnboardingVideoURL"),
              let videoURL = URL(string: videoURLString) else {
            runOnboardingWithoutVideo()
            return
        }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    private func runOnboardingWithoutVideo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
            self?.startOnboardingPromptStream()
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press \(globalPushToTalkShortcutMonitor.talkHotkey.displayText) and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're dottie, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Gemini to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so the model can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await geminiAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let globalLocation = Self.globalScreenLocation(
                    forScreenshotPixel: pointCoordinate,
                    in: cursorScreenCapture
                )
                let displayFrame = cursorScreenCapture.displayFrame

                // Set custom bubble text so the pointing animation uses the model's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
