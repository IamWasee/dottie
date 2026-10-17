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
    /// While Dottie draws an explanation, the stroke her cursor traces with
    /// its caption; BlueCursorView follows it like a pen.
    @Published var penTrace: DottiePenTrace?

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
    /// Memory, the Brain agent's settings and the screen journal.
    let brain = DottieBrain()
    /// Pictures the user added in Home → Conversation, remembered by name.
    let imageMemory = DottieImageMemory()
    /// One folder per thing the user is making (see DottieProjects).
    let projects = DottieProjects()
    /// The cursor's shape ("turn into a cat") and its roaming pet mode.
    let cursorPet = DottieCursorPet()
    /// TVs, lights and everything else smart in the house.
    let smartHome = DottieSmartHome()
    /// Meeting mode: off until the user starts it.
    let meetingRecorder = DottieMeetingRecorder()
    /// Shortcuts, AppleScript, Calendar, Reminders, Contacts, the browser
    /// and meeting notes, as voice tools.
    private(set) lazy var macTools = DottieMacTools(meetingRecorder: meetingRecorder)
    /// Texting Dottie from a phone through the user's own Telegram bot.
    let phoneBridge = DottiePhoneBridge()
    /// Finds, sends and uploads files asked for by text.
    let phoneFiles = DottiePhoneFiles()
    private var meetingCancellable: AnyCancellable?
    /// Hold right Option to dictate into any app.
    let dictationController = ClickyDictationController()
    private var dictationCancellables: Set<AnyCancellable> = []
    private var clickyRosterCancellable: AnyCancellable?
    private var notchHoverCancellable: AnyCancellable?
    private var peekFilesRefreshTask: Task<Void, Never>?
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
    /// Saved pictures sent with the current typed turn, for its conversation
    /// entry.
    private var currentTurnImageFileNames: [String] = []
    /// The second look at where Live pointed; replaced by the next point request.
    private var livePointingRefinementTask: Task<Void, Never>?
    /// What voice Dottie draws on screen when asked.
    private let drawingOverlayManager = DottieDrawingOverlayManager()
    /// Multi-step jobs on the screen ("open opera, find my kaggle rank").
    private let screenTaskRunner = DottieScreenTaskRunner()
    /// Teaching the app on screen, step by step or as a tour.
    private let guide = DottieGuide()
    /// While a guide waits for the user to click its target, the cursor
    /// keeps pointing at it instead of flying back after a few seconds.
    private(set) var keepsPointingUntilCleared = false
    /// The question Dottie handed the Brain, so she says its answer.
    private var pendingSpokenBrainQuestion: String?
    private var currentGuideGoal: String?
    private var brainCancellables = Set<AnyCancellable>()
    private var cursorPetCancellable: AnyCancellable?
    /// Counts narrated lines so a stale safety timeout can't end a newer one.
    private var narrationCount = 0
    /// Called once when the current Live turn has finished speaking (or
    /// failed), for narration that waits on it.
    private var liveTurnFinishedHandler: (() -> Void)?
    /// The current Live turn only speaks a guide line; it isn't saved to the
    /// conversation and doesn't leave an answer card.
    private var currentLiveTurnIsNarration = false
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
    /// Exchanges carried into each new conversation, including across relaunches.
    private static let rememberedExchangeCount = 20

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
    /// UserDefaults. Takes effect from her next answer.
    @Published var selectedVoiceName: String = UserDefaults.standard.string(forKey: "selectedGeminiLiveVoice") ?? "Kore"

    /// How Dottie talks (Settings → Voice). Takes effect on the next Live
    /// connection, like the voice.
    @Published private(set) var selectedPersonality: DottiePersonality = DottiePersonality.saved

    func setSelectedPersonality(_ personality: DottiePersonality) {
        selectedPersonality = personality
        UserDefaults.standard.set(personality.rawValue, forKey: DottiePersonality.defaultsKey)
        liveVoiceClient.baseSystemInstruction = currentLiveSystemPrompt()
        liveVoiceClient.startFreshSessionSoon()
    }

    func setSelectedVoiceName(_ voiceName: String) {
        selectedVoiceName = voiceName
        UserDefaults.standard.set(voiceName, forKey: "selectedGeminiLiveVoice")
        // Starts a fresh session for her next answer (or right after the
        // one she's giving), so the new voice is heard straight away.
        liveVoiceClient.voiceName = voiceName
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
        loadScreenJobsCutOffByQuit()
        DottieBrowser.startTrackingBrowserUse()
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
            print("⚠️ Dottie: no server address (Info.plist ClickyWorkerBaseURL or Settings → Connection) — voice won't work until one is set.")
        }

        // Get Dots ready in the background (a one-time download), so the
        // first Dot doesn't wait for it. Skipped when Gemini CLI is already
        // on this Mac.
        Task.detached(priority: .background) {
            guard GeminiCLIAgentRuntime.locateGeminiCLIExecutable() == nil else { return }
            do {
                try await DotsRuntimeInstaller.shared.installIfNeeded()
            } catch {
                print("⚠️ Dottie: couldn't set up the Dots runtime yet: \(error.localizedDescription)")
            }
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

        dictationController.$liveText
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] liveText in
                guard let self, self.dictationController.state == .recording else { return }
                self.notchPresenter.updateLiveCaption(liveText)
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
            guard let self else { return }
            switch outcome {
            case .inserted:
                break
            case .copiedToClipboard:
                self.notchPresenter.showAgentUpdate(title: "Copied to your clipboard", text: dictatedText)
            case .copiedInsteadOfTypingPassword:
                // Don't show what was said; it may be the password itself.
                self.notchPresenter.showAgentUpdate(
                    title: "Password field",
                    text: "I don't type into password boxes, so it's on your clipboard. Paste it yourself if it's right."
                )
            }
        }

        dictationController.onError = { [weak self] errorMessage in
            self?.notchPresenter.showAgentUpdate(title: "Dictation", text: errorMessage)
        }

        dictationController.correctionLearner.onLearnedCorrection = { [weak self] learnedCorrection in
            self?.notchPresenter.showLearnedDictionaryWord(learnedCorrection.corrected, replacing: learnedCorrection.original)
        }
        notchPresenter.onRemoveLearnedDictionaryWord = { learnedWord in
            DictationDictionary.shared.remove(word: learnedWord)
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
            // The user is talking over the explanation: stop drawing, but
            // leave what's drawn so they can ask about it.
            stopTeaching(clearingDrawing: false)
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
    how this works: you're always on, and the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - keep it short, simple and fun: usually one sentence, two at most, in plain everyday words. only go longer when they ask you to explain more or go deeper.
    - all lowercase, casual, in character (who you are and how you talk, above). no emojis.
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
    you have your own little cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

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

    /// The personality goes first, so it frames everything after it.
    private static func classicVoiceSystemPrompt(personality: DottiePersonality) -> String {
        personality.promptSection + "\n\n" + companionVoiceResponseSystemPrompt
    }

    private static func liveVoiceSystemPrompt(personality: DottiePersonality) -> String {
        personality.promptSection + "\n\n" + companionLiveVoiceSystemPrompt
    }

    /// The Live prompt with what the second brain knows about the user.
    private func currentLiveSystemPrompt() -> String {
        var prompt = Self.liveVoiceSystemPrompt(personality: selectedPersonality)
        let profile = brain.profileForPrompt
        if !profile.isEmpty {
            prompt += "\n\nwhat your second brain knows about the user (use it naturally, don't recite it):\n" + profile
        }
        let pictureList = imageMemory.promptSummary
        if !pictureList.isEmpty {
            prompt += "\n\npictures the user showed you, and ones you saved yourself (you know them by these names and descriptions; the description says where each is from):\n" + pictureList
                + "\nwhen the user means one of these (\"grab that sword\", \"pick up the guardian core\", \"where's the thing i showed you\"), pass its exact name in do_task_on_screen's reference_images, or use the exact name as the point_at_element label, so the picture itself is matched on screen. use what the description says (the game it's from, what it's for) as context. find_pictures searches them; save_picture saves a new one from the screen."
        } else {
            prompt += "\n\npictures: you can save a picture of something on screen with save_picture to remember its look or place, and find it again later by name."
        }
        let projectList = projects.promptSummary
        if !projectList.isEmpty {
            prompt += "\n\nthe user's projects (pass the name to start_helper or start_team to keep working on one):\n" + projectList
        }
        let homeSummary = smartHome.promptSummary
        prompt += "\n\nsmart home: you're the user's home controller. home_devices lists their TVs, lights, plugs, blinds, locks, thermostats, vacuums, speakers, scenes and cameras; control_device does one thing right away (lights on, dim to 30, TV volume up, open youtube on the tv, look at the front door camera); tv_task does a multi-step job on a TV while watching its screen (put on the next episode of bluey). for apple home devices, use the user's shortcuts or the home app on screen."
            + (homeSummary.isEmpty ? " nothing is set up yet; if they ask, they add devices in your Home window under Smart Home." : "\n" + homeSummary)
        return prompt
    }

    // MARK: - Live Voice Pipeline (Gemini Live)

    /// Live mode's system prompt. Same personality as v0's, but pointing is a
    /// tool call instead of a text tag, because the model's output is audio.
    private static let companionLiveVoiceSystemPrompt = """
    how this works: you're always on, and the user talks to you with push-to-talk, and with each turn you get one frame showing their screen(s). you answer out loud. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - keep it short, simple and fun. most answers are one sentence, two at most, in plain everyday words. say the one thing they need and stop: no background, no recap, no "here's how it works". only go longer when they ask you to explain more or go deeper.
    - stay in character (who you are and how you talk, above) in every answer, but never at the cost of the answer. speak naturally, no lists or reading out formatting.
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screen doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming. when you need fresh or specific facts (news, prices, scores, weather, dates, recent versions), call search_web instead of guessing.
    - never say "simply" or "just".
    - don't end with questions like "want me to explain more?" and don't tack on extra tips. ending right after the answer is perfect.
    - if the frame shows several screens side by side, the one marked as the cursor screen is the primary focus.
    - the user can circle things with their cursor while talking. if a frame shows a bright blue hand-drawn ring, that's what they marked and are asking about.

    pointing:
    you have your own little cursor that can fly to and point at things on screen, using the point_at_element tool. use it whenever pointing would genuinely help — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app. err on the side of pointing, because it makes your help way more concrete. don't point for general knowledge questions or at something obvious they're already looking at.
    the tool takes x and y from 0 to 1000 across the whole frame (0,0 is the top-left corner, 1000,1000 the bottom-right) and a short label. call it once, then keep talking as if you're gesturing at it, e.g. "see that button up here? click it."

    when it's not on this screen:
    never tell the user something isn't there, or that you can't find it, from one look. it's usually a click or two away: another tab, a menu, a sidebar, further down the page, or another page of the app or site (a github project's downloads are under the code tab, then releases on the right; an app's settings are in its menu bar). work out where it usually lives, call search_web when you're not sure ("where do i download releases on github"), then point at the first thing to click and say where it leads, or call guide_user to walk them all the way there. if they asked you to do it for them, use do_task_on_screen. keep trying other ways when one doesn't work. only say you couldn't after you've really tried, and then say what you tried and what they could try next.

    going deeper:
    you're the fast voice. for questions that need careful reading of small text, code, a long document, precise steps, or real reasoning, call send_to_higher_model with the question. say a few words first ("let me take a closer look"), then speak the answer it returns in your own voice. it can point the cursor too, so don't point again for the same thing.

    doing things on screen:
    only when the user asks you to do something for them ("click sign in", "open youtube", "type hello", "scroll down", "go back", "circle the error"), you can do it yourself with click_on_screen, type_text, press_keys, scroll_screen, open_url and draw_on_screen. never click or type on your own initiative, and never just because it would be helpful; pointing is for showing, these are for doing. one quick step at a time: do it, then say it's done in a few words. prefer keyboard shortcuts over clicking whenever one exists, they never miss: close a tab cmd+w, new tab cmd+t, reopen a closed tab cmd+shift+t, next tab ctrl+tab, previous tab ctrl+shift+tab, address bar cmd+l, reload cmd+r, back cmd+[, forward cmd+], find on page cmd+f, close a window cmd+shift+w, switch apps by opening them, zoom cmd+= and cmd+-. when you do click, pass the label exactly as it appears on screen, so the click lands on the right thing. if the request is risky or can't be undone (sending a message, buying, deleting, posting), say what you're about to do and ask first. never type passwords.

    explaining with drawings:
    you're a tutor with a marker. whenever you explain something visual or mathematical (a geometry or algebra problem in a video, a graph, an equation, a diagram, a chart, a physics setup, a chess position), don't just talk: call explain_on_screen and draw it, without waiting to be asked. mark what's on screen (circle the point, draw the radius, put a right-angle mark where the tangent meets it, arrow from the slope to where it's used) and work the math out step by step on a board (surface board_right or board_left, whichever covers less of what matters): each line of working is a text step, top to bottom, like "m = (8−2)/(5−3) = 3", then "m⊥ = −1/3". give every step a short caption for your cursor ("right angle", "slope = 3") and a say line; they're spoken one by one while it draws, so after calling, say only "okay, watch" or similar. name things already on screen as anchors with a clear description (what it looks like and where) instead of guessing their coordinates; only say you marked something if you anchored it. use plot to draw a function's real graph, measure for lengths, angle with the size, ticks for equal sides. if the user says stop or clear, call clear_drawings.

    teaching:
    clicky was made to help people learn their apps, so this matters most. when the user wants to learn how to do something themselves ("how do i add a sound effect in premiere", "where do i go for effects", "walk me through exporting") call guide_user with mode steps: the app points and draws each step, waits for their click, then shows the next. when they want a rundown or tour of the app or screen ("tell me how to use this app", "give me a complete rundown"), call guide_user with mode tour. for a single "where is x" that's visible right now, just point at it. during a guide, when they say next, done or got it, call guide_next; when they say stop, call stop_guide. lines that start with [dottie guide] are steps already drawn on screen: say just that line.

    multi-step jobs:
    when the user asks for something on screen that takes more than one step ("open opera, search kaggle, go to my competitions and tell me my rank", "find the cheapest flight on this site", "go to my github and open the latest issue"), call do_task_on_screen once with the whole request, every step in order. don't do the steps yourself one by one. say you're on it in a few words, then stop talking; your cursor does the job and you'll get the result in a later message, which you tell the user in one short sentence.
    jobs line up: if they ask for another job while one is running ("also open my email", "after that, check the weather"), call do_task_on_screen for it too; it waits its turn and starts when the current one finishes. several separate jobs in one breath ("check my rank, then reply to sam, then open spotify") are separate do_task_on_screen calls, in the order the user said them. inside one task, keep the user's order and words ("merge PR 36, then PR 37"), never reorder. stop_screen_task with scope "current" skips the running job and moves to the next, "all" stops everything and clears the list (stop, cancel, never mind), and "list" tells you what's running and waiting. a job the user stopped (with the stop button, escape or by asking) is gone: if they ask for it again, call do_task_on_screen again instead of saying you're on it.
    your look: you can shapeshift. when the user says "turn into a cat", "be a ghost", "change your cursor" or "go walk around", call change_cursor with the shape and its emoji; animals wander around the screen on their own like a pet, other shapes follow the mouse unless the user wants them to roam. "turn back" or "be normal" is shape normal.
    games: when the user asks you to do something inside a game ("go grab that sword", "walk over to the shop", "play this level for me"), call do_task_on_screen with game true: it moves with the keyboard, turns the camera and clicks, in quick steps. if they mean a picture they showed you, pass its name in reference_images.

    second brain:
    you have a second brain that remembers everything you and the helpers have done with the user, and can dig through their files, command-line tools and connected apps.
    - when the user asks about the past ("what was i working on yesterday", "what did we talk about last week", "what was that site"), call recall_memory with a few keywords, and answer from it.
    - when they say to remember something, call remember with it, written so it stands on its own.
    - when a question needs their files, folders, tools or real digging ("find my resume and tighten it", "what's in my downloads", "check my git repos for uncommitted work"), call ask_brain with the question. say a few words, then stop; its answer comes back to you and you say it.

    helpers:
    the user can have background helpers (also called dots) that work on their own on the mac with a shell, files, node and the web, and report back in the notch when done. they can do real work: research, write documents, organize files, write code, and build whole websites or small apps, which they save in their own folder.
    - when the user asks for work that takes more than an answer, or says to have a helper or a named helper do something, call start_helper with a task that stands on its own and helper_name if they named one. then say it's started in a few words. don't do the task yourself, and never say you can't start a helper: call start_helper.
    - helpers change all the time and the user can create, use or delete them in the app without you. never answer about helpers from memory or from earlier in the conversation. whenever the user asks about helpers (what are they doing, is it done, what did it say, did it work, which ones exist), call list_helpers or check_helper first and answer from what it returns. if a helper isn't there anymore, say it was deleted.
    - check_helper gives a helper's latest task, steps, reply and files; tell the user the gist in a sentence or two, not the whole reply.
    - stop_helper stops one that's working. open_helper_result opens what it made (a website in the browser, a file, or its folder).
    - projects: anything the user is building or will come back to (a website, an app, a document set, a game guide) lives in a project, its own folder. pass project to start_helper: an existing name from the projects list to keep working on it ("let's work on the coffee store site again"), or a short new name for something new. a different new thing gets a different project. list_projects shows them all.
    - teams: for a big job with clearly separate parts, or when the user asks for a team, call start_team: each part goes to its own helper (research, design, html, javascript, marketing...) and they work at the same time in the project folder. tell the user who's on what in a few words.

    your mac powers:
    only when the user asks, you can act on their mac directly. these are quicker and surer than clicking, so prefer them:
    - apps and settings: run_applescript (music or spotify, finder, notes, mail drafts, volume, dark mode, opening or quitting apps, arranging windows). run_shortcut runs one of their apple shortcuts by name; list_shortcuts lists them.
    - calendar and reminders: get_schedule for "what's my day look like" or "am i free friday", add_calendar_event, get_reminders, add_reminder ("remind me to call mom at 5"), complete_reminder. answer in a sentence, like "three things today, first is standup at ten".
    - contacts: find_contact for someone's number, email or birthday.
    - screenshots: take_screenshot when they ask for a screenshot or screen grab (saved like command-shift-3, usually on the desktop). window for just the app in front, pick to let them drag over a part, save_to clipboard when they want to paste it. you never say you can't take screenshots.
    - the browser: browser reads the page they're on (read_page), lists, opens, switches and closes tabs, fills in form fields and clicks buttons by their text. use it for anything inside a web page instead of clicking on the screen. if it says page access is off, call it with enable_page_access.
    - anything that sends, deletes or buys pops up a dialog asking the user first, so go ahead when they ask; if they say no, drop it.
    - meeting mode: when the user says to take notes or start meeting mode, call meeting_notes with start; when they say the meeting's over, stop. never start it on your own. the notes come back to you later and are saved in home → meetings. status tells you what's been said so far; latest reads their last meeting's notes.
    - the user can text you from their phone (home → phone): a helper called Phone does the job and texts back.
    """

    /// Deletes one exchange from Home → Conversation, and from what Dottie
    /// remembers, so it's gone from her next answer on.
    func forgetConversationEntry(_ entryID: UUID) {
        conversationStore.delete(entryID: entryID)
        reloadRememberedConversation()
    }

    func forgetWholeConversation() {
        conversationStore.clearAll()
        reloadRememberedConversation()
    }

    private func reloadRememberedConversation() {
        conversationHistory = conversationStore.entries
            .suffix(Self.rememberedExchangeCount)
            .map { (userTranscript: $0.userText, assistantResponse: $0.clickyText) }
        liveVoiceClient.recentConversationHistory = conversationHistory.map { exchange in
            (userTranscript: exchange.userTranscript, modelTranscript: exchange.assistantResponse)
        }
        liveVoiceClient.startFreshSessionSoon()
    }

    /// Hooks the Live client's callbacks into the companion's state.
    private func configureLiveVoiceClient() {
        liveVoiceClient.baseSystemInstruction = currentLiveSystemPrompt()
        liveVoiceClient.voiceName = selectedVoiceName

        // Pick up where the last run left off: the saved conversation seeds
        // memory, so Dottie still knows the user's name after a relaunch.
        conversationHistory = conversationStore.entries
            .suffix(Self.rememberedExchangeCount)
            .map { (userTranscript: $0.userText, assistantResponse: $0.clickyText) }
        liveVoiceClient.recentConversationHistory = conversationHistory.map { exchange in
            (userTranscript: exchange.userTranscript, modelTranscript: exchange.assistantResponse)
        }

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

        liveVoiceClient.onScreenAction = { [weak self] screenAction in
            guard let self else { return "couldn't do that right now." }
            return await self.performScreenAction(screenAction)
        }

        liveVoiceClient.onStartScreenTask = { [weak self] taskText, isGame, referenceImageNames, restart in
            guard let self else { return "couldn't start it right now." }
            return self.startScreenTask(ScreenJob(text: taskText, isGame: isGame, referenceImageNames: referenceImageNames, restart: restart))
        }

        liveVoiceClient.onStopScreenTask = { [weak self] scope in
            guard let self else { return "nothing is running." }
            switch scope {
            case "current":
                return self.skipCurrentScreenTask()
            case "list":
                return self.screenTaskQueueSummary()
            default:
                let didStopTV = self.smartHome.tvTaskRunner.stop()
                return self.stopScreenTask() || didStopTV ? "stopped everything; the list is clear." : "nothing was running."
            }
        }

        liveVoiceClient.onStartGuide = { [weak self] goal, modeName in
            guard let self else { return "couldn't start it right now." }
            return self.startGuide(goal: goal, modeName: modeName)
        }

        liveVoiceClient.onGuideNext = { [weak self] in
            guard let self, self.guide.userSaidNext() else { return "no guide is running." }
            return "okay, moving on. say nothing more; the next step is coming."
        }

        liveVoiceClient.onStopGuide = { [weak self] in
            guard let self else { return "no guide is running." }
            return self.stopGuide() ? "stopped the guide." : "no guide was running."
        }

        liveVoiceClient.onStartClickyTask = { [weak self] clickyName, taskText, projectName, restart in
            guard let self else { return "couldn't start it right now." }
            return self.startClickyTask(clickyName: clickyName, taskText: taskText, projectName: projectName, restart: restart)
        }

        liveVoiceClient.onBrainTool = { [weak self] functionName, text in
            guard let self else { return "the brain isn't available right now." }
            switch functionName {
            case "recall_memory":
                return self.brain.recall(text)
            case "remember":
                self.brain.record(.remembered, text)
                return "saved to memory."
            default:
                return self.askBrain(question: text)
            }
        }

        liveVoiceClient.onHelperTool = { [weak self] functionName, helperName in
            guard let self else { return "helpers aren't available right now." }
            return self.answerHelperTool(functionName: functionName, helperName: helperName)
        }

        liveVoiceClient.onMacTool = { [weak self] functionName, arguments in
            guard let self else { return "couldn't do that right now." }
            if DottieWorkTools.functionNames.contains(functionName) {
                return await self.performWorkTool(functionName: functionName, arguments: arguments)
            }
            if functionName == DottieCursorPet.functionName {
                return self.performCursorTool(arguments: arguments)
            }
            if functionName == DottieTeaching.functionName {
                return self.startTeaching(arguments: arguments)
            }
            if DottieSmartHome.functionNames.contains(functionName) {
                return await self.performSmartHomeTool(functionName: functionName, arguments: arguments)
            }
            return await self.macTools.perform(functionName: functionName, arguments: arguments)
        }

        liveVoiceClient.onTurnError = { [weak self] error in
            guard let self else { return }
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            print("⚠️ Gemini Live turn error: \(error)")
            self.isLiveTurnInFlight = false
            self.currentLiveTurnIsNarration = false
            self.fireLiveTurnFinishedHandler()
            self.speakConnectionErrorFallback()
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Called by the live transcription provider when push-to-talk opens.
    /// Grabs the screen frame and opens the user's turn on the Live session.
    private func beginLiveTurnWithScreenFrame(includesScreenFrame: Bool = true) async {
        // So a web page's elements can be found by name if Dottie points.
        PointingRefiner.prepareFrontmostApplicationForSearch()
        var compositeScreenFrame: CompanionCompositeScreenFrame?
        if includesScreenFrame {
            do {
                compositeScreenFrame = try await CompanionScreenCaptureUtility.captureCompositeFrameForLive()
            } catch {
                print("⚠️ Gemini Live: screen capture failed, sending voice only: \(error)")
            }
        }

        currentLiveTurnScreenFrame = compositeScreenFrame
        currentLiveTurnScreenFrameCapturedAt = compositeScreenFrame == nil ? nil : Date()
        liveVoiceClient.beginUserTurn(screenFrameJPEGData: compositeScreenFrame?.jpegData)

        if let compositeScreenFrame, compositeScreenFrame.regions.count > 1 {
            liveVoiceClient.sendTurnContextText(compositeScreenFrame.layoutDescription)
        }
        // Not on a guide line, which must be said word for word.
        if includesScreenFrame && !notesForNextLiveTurn.isEmpty {
            liveVoiceClient.sendTurnContextText(notesForNextLiveTurn.joined(separator: "\n"))
            notesForNextLiveTurn = []
        }
    }

    /// Things that changed outside the conversation (the user stopped a job
    /// with the notch button or Escape), told to Live with the next turn.
    /// Without this, Live still thinks a stopped job is running and answers
    /// "I'm on it" when the user asks for it again.
    private var notesForNextLiveTurn: [String] = []

    private func noteStoppedJob(_ description: String) {
        notesForNextLiveTurn.append("[note] \(description) was stopped and is not running anymore. if the user asks for it again, start it again with the tool; never say you're still working on it.")
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

    // MARK: - Doing things on screen

    /// Carries out a click, typing, keys, scroll, page or drawing the user
    /// asked voice Dottie for, and says what happened for Live to relay.
    private func performScreenAction(_ screenAction: DottieScreenAction) async -> String {
        let needsEventPermission: Bool
        switch screenAction {
        case .click, .typeText, .pressKeys, .scroll: needsEventPermission = true
        case .openURL, .draw, .clearDrawings: needsEventPermission = false
        }
        if needsEventPermission && !DottieScreenActionPerformer.canPostEvents {
            return "I can't control the mouse and keyboard yet: Dottie needs Accessibility permission in System Settings → Privacy & Security."
        }

        switch screenAction {
        case .click(let normalizedX, let normalizedY, let label, let clickCount, let isRightClick):
            guard let target = await refinedScreenLocation(normalizedX: normalizedX, normalizedY: normalizedY, label: label) else {
                return "couldn't tell where that is on screen."
            }
            // Fly there first so the user sees what's about to be clicked.
            livePointingRefinementTask?.cancel()
            detectedElementScreenLocation = target.point
            detectedElementDisplayFrame = target.displayFrame
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            DottieScreenActionPerformer.click(at: target.point, clickCount: clickCount, isRightClick: isRightClick)
            return "clicked \(label ?? "it"). keep it short: just say it's done."

        case .typeText(let text, let pressEnterAfter):
            if DottieScreenActionPerformer.isFocusedFieldSecure {
                return "that's a password box, so I didn't type anything. tell the user to type passwords themselves."
            }
            await DottieScreenActionPerformer.type(text)
            if pressEnterAfter {
                DottieScreenActionPerformer.press(keyCombination: "enter")
            }
            return pressEnterAfter ? "typed it and pressed return." : "typed it."

        case .pressKeys(let keyCombination):
            return DottieScreenActionPerformer.press(keyCombination: keyCombination)
                ? "pressed \(keyCombination)."
                : "don't know the key \(keyCombination). use names like cmd+t, enter, escape, tab, up, down."

        case .scroll(let direction, let amount):
            DottieScreenActionPerformer.scroll(direction: direction, amount: amount)
            return "scrolled \(direction.rawValue)."

        case .openURL(let url):
            return await DottieBrowser.openInUsersBrowser(url) ? "opened \(url.host ?? url.absoluteString)." : "couldn't open that page."

        case .draw(let shape, let normalizedX, let normalizedY, let normalizedSize, let label, let note):
            guard let target = await refinedScreenLocation(normalizedX: normalizedX, normalizedY: normalizedY, label: label) else {
                return "couldn't tell where that is on screen."
            }
            // Hug the element's real frame when it was found; otherwise a
            // guess from Live's rough size, kept modest.
            let markedRect: CGRect
            if let elementFrame = target.elementFrame {
                markedRect = elementFrame
            } else {
                var width: CGFloat = 70
                if let normalizedSize {
                    width = CGFloat(max(16, min(1000, normalizedSize)) / 1000) * target.frameWidthInPoints
                }
                let height: CGFloat = max(22, min(width * 0.4, 120))
                markedRect = CGRect(x: target.point.x - width / 2, y: target.point.y - height / 2, width: width, height: height)
            }
            drawingOverlayManager.add(DottieDrawing(shape: shape, targetRect: markedRect, note: note))
            return "drew a \(shape.rawValue) on screen."

        case .clearDrawings:
            stopTeaching(clearingDrawing: true)
            drawingOverlayManager.clear()
            return "cleared the drawings."
        }
    }

    // MARK: - Teaching with drawings

    private var teachingTask: Task<Void, Never>?
    /// The step line being said, so a stopped explanation doesn't keep
    /// talking after the user does.
    private var teachingNarrationTask: Task<Void, Never>?

    /// explain_on_screen: draws the explanation step by step with the
    /// cursor as the pen. Returns at once so Live can say "okay, watch";
    /// each step's line is spoken as it's drawn.
    private func startTeaching(arguments: [String: Any]) -> String {
        guard let plan = DottieTeaching.Plan(arguments: arguments) else {
            return "error: give steps, each with a kind and points."
        }
        stopTeaching(clearingDrawing: true)
        stopGuide()
        drawingOverlayManager.clear()
        let mouseLocation = NSEvent.mouseLocation
        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return "couldn't find the screen."
        }
        let boardRect = plan.surface.boardRect(on: cursorScreen.visibleFrame)
        let screenFrame = currentLiveTurnScreenFrame
        let userQuestion = currentLiveTurnTypedText ?? lastTranscript ?? ""
        let hasSpokenLines = plan.steps.contains { $0.say != nil }
        print("✏️ Teaching: \(plan.steps.count) steps on \(plan.surface.rawValue), \(plan.anchors.count) anchors")
        transientHideTask?.cancel()
        transientHideTask = nil
        showOverlayTransientlyIfNeeded()
        teachingTask = Task { [weak self] in
            await self?.runTeaching(plan: plan, screenFrame: screenFrame, displayFrame: cursorScreen.frame,
                                    boardRect: boardRect, userQuestion: userQuestion, speaksLines: hasSpokenLines)
        }
        return hasSpokenLines
            ? "drawing it now. say only two or three words like 'okay, watch'; each step's line comes to you to say while it's drawn."
            : "drawing it now, step by step. explain it in the same order, briefly, while it draws."
    }

    private func runTeaching(
        plan: DottieTeaching.Plan,
        screenFrame: CompanionCompositeScreenFrame?,
        displayFrame: CGRect,
        boardRect: CGRect?,
        userQuestion: String,
        speaksLines: Bool
    ) async {
        // Finding the anchors starts now and only holds up the first step
        // that needs them.
        let anchorNames = plan.anchorNames
        var anchorLookup: Task<[String: CGRect], Never>?
        if !plan.anchors.isEmpty {
            let anchors = plan.anchors
            anchorLookup = Task {
                await DottieTeaching.locateAnchors(anchors, displayFrame: displayFrame, userQuestion: userQuestion)
            }
        }
        var anchorFrames: [String: CGRect]?

        if let boardRect {
            drawingOverlayManager.addFigures([DottieFigure(shape: .board(rect: boardRect), drawDuration: 0.35)])
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        // Start with Live's "okay, watch" out of the way, so drawing and
        // speaking stay together.
        if speaksLines {
            for _ in 0..<40 {
                if !(isLiveTurnInFlight || voiceState != .idle) || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        var missedSteps = 0
        for step in plan.steps {
            if Task.isCancelled { break }
            let usesAnchors = step.points.contains { reference in
                let name = reference.lowercased()
                return anchorNames.contains(name) || anchorNames.contains(where: { name.hasPrefix($0 + ".") })
            }
            if usesAnchors && anchorFrames == nil {
                notchPresenter.showScreenTaskStep("finding it on your screen", title: "drawing")
                anchorFrames = await anchorLookup?.value ?? [:]
                notchPresenter.endScreenTask()
                if Task.isCancelled { break }
            }
            let space = DottieTeaching.Space(
                // Anchored steps point at the screen even with a board open.
                boardRect: usesAnchors ? nil : boardRect,
                anchorFrames: anchorFrames ?? [:],
                screenPoint: { normalizedX, normalizedY in
                    guard let resolved = screenFrame?.resolveNormalizedPoint(normalizedX: normalizedX, normalizedY: normalizedY) else { return nil }
                    return CompanionManager.globalScreenLocation(forScreenshotPixel: resolved.pointInScreenshotPixels, in: resolved.screenCapture)
                }
            )
            var narration: Task<Void, Never>?
            if let line = step.say {
                narration = Task { [weak self] in await self?.narrate(line) }
                teachingNarrationTask = narration
            }
            if let drawn = DottieTeaching.draw(step, in: space) {
                let leadInSeconds = 0.4
                penTrace = DottiePenTrace(points: drawn.penPath, leadInSeconds: leadInSeconds, drawSeconds: drawn.duration,
                                          caption: step.caption.map(DottieMathText.pretty), displayFrame: displayFrame)
                try? await Task.sleep(nanoseconds: UInt64(leadInSeconds * 1_000_000_000))
                if Task.isCancelled { break }
                drawingOverlayManager.addFigures(drawn.figures)
                // Time to see it and read the caption before the next one.
                let captionSeconds = step.caption.map { min(2.0, 0.6 + Double($0.count) * 0.04) } ?? 0.3
                try? await Task.sleep(nanoseconds: UInt64((drawn.duration + captionSeconds) * 1_000_000_000))
            } else {
                missedSteps += 1
                print("✏️ Couldn't draw a \(step.kind.rawValue) step: \(step.points)")
            }
            await narration?.value
        }

        // A stopped explanation was already tidied up, maybe with a new one
        // under way.
        guard !Task.isCancelled else { return }
        penTrace = nil
        teachingTask = nil
        teachingNarrationTask = nil
        if missedSteps > 0 {
            print("✏️ \(missedSteps) of \(plan.steps.count) steps couldn't be drawn")
        }
        drawingOverlayManager.fadeFigures(after: plan.keepsDrawing ? 600 : 60)
        scheduleTransientHideIfNeeded()
    }

    /// Stops drawing an explanation. The drawing itself can stay up.
    private func stopTeaching(clearingDrawing: Bool) {
        teachingTask?.cancel()
        teachingTask = nil
        teachingNarrationTask?.cancel()
        teachingNarrationTask = nil
        penTrace = nil
        if clearingDrawing {
            drawingOverlayManager.clearFigures()
        }
    }

    // MARK: - Multi-step screen tasks

    /// A job for the screen task runner: what to do, whether it's a game,
    /// and which saved pictures it's about.
    private struct ScreenJob {
        let text: String
        var isGame = false
        var referenceImageNames: [String] = []
        /// Asked for by text: the result is texted back, not spoken.
        var repliesToPhone = false
        /// The user already said yes to starting over a matching job.
        var restart = true
    }

    /// Jobs asked for while another was running, oldest first. Each starts
    /// when the one before it finishes.
    private var queuedScreenTasks: [ScreenJob] = [] {
        didSet { saveOpenScreenJobs() }
    }

    // MARK: Asking before repeating a job

    private static let openScreenJobsDefaultsKey = "dottieOpenScreenJobs"
    /// Jobs that were running or waiting when Dottie last quit, so asking
    /// for one again gets "start it over?" instead of a silent duplicate.
    private var screenJobsCutOffByQuit: [String] = []

    /// Saved on every change, so whatever is open when Dottie quits (or
    /// crashes) is known at the next launch.
    private func saveOpenScreenJobs() {
        let openJobs = [currentScreenTaskText].compactMap { $0 } + queuedScreenTasks.map(\.text)
        UserDefaults.standard.set(openJobs, forKey: Self.openScreenJobsDefaultsKey)
    }

    private func loadScreenJobsCutOffByQuit() {
        screenJobsCutOffByQuit = UserDefaults.standard.stringArray(forKey: Self.openScreenJobsDefaultsKey) ?? []
        UserDefaults.standard.removeObject(forKey: Self.openScreenJobsDefaultsKey)
    }

    /// Two requests are the same job when nearly all the words of the
    /// shorter one (numbers included, so "PR 36" isn't "PR 37") are in both.
    private static func isSameJob(_ firstText: String, _ secondText: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 || $0.contains(where: \.isNumber) })
        }
        let firstWords = words(firstText)
        let secondWords = words(secondText)
        guard !firstWords.isEmpty, !secondWords.isEmpty else { return false }
        let sharedFraction = Double(firstWords.intersection(secondWords).count) / Double(min(firstWords.count, secondWords.count))
        return sharedFraction >= 0.75
    }

    /// What Live should ask before starting a job that matches one that's
    /// running, waiting, or was cut off by a quit. nil when it's new.
    private func repeatedScreenJobQuestion(for job: ScreenJob) -> String? {
        let howToRestart = "if they want it started over, call do_task_on_screen again with the same task and restart true. if not, leave it."
        if screenTaskRunner.isRunning, let currentScreenTaskText, Self.isSameJob(currentScreenTaskText, job.text) {
            return "that's the same job that's running right now (\"\(currentScreenTaskText)\"). don't start anything yet: ask the user in a few words, like \"you already asked me for that and I'm on it, want me to cancel it and start over?\". \(howToRestart)"
        }
        if let waitingJob = queuedScreenTasks.first(where: { Self.isSameJob($0.text, job.text) }) {
            return "that job is already waiting in the list (\"\(waitingJob.text)\"). ask the user in a few words if they want it started over now instead. \(howToRestart)"
        }
        if let cutOffJob = screenJobsCutOffByQuit.first(where: { Self.isSameJob($0, job.text) }) {
            return "you were doing this same job when Dottie was closed, and it stopped partway (\"\(cutOffJob)\"). ask the user in a few words, like \"you asked me that before I closed, want me to cancel that one and start it again?\". \(howToRestart)"
        }
        return nil
    }

    /// The same check for helpers: a helper doing the same task, or one
    /// whose last task got no answer because Dottie quit.
    private func repeatedHelperTaskQuestion(for taskText: String) -> String? {
        for agent in clickyRoster.agents where agent.isBrain != true {
            let transcript = clickyRoster.transcriptsByAgentID[agent.id] ?? []
            guard let lastUserMessage = transcript.last(where: { $0.kind == .user }),
                  Self.isSameJob(lastUserMessage.text, taskText) else { continue }
            let gotAnswer = transcript.last.map { $0.kind == .assistant } ?? false
            if clickyRoster.isRunning(agent) {
                return "\(agent.name) is already doing that task. don't start another: ask the user in a few words if they want \(agent.name) to stop and start it over. if yes, call stop_helper for \(agent.name), then start_helper again with restart true."
            }
            if !gotAnswer {
                return "\(agent.name) was doing that same task when Dottie was closed, and it stopped before finishing. ask the user in a few words, like \"you asked \(agent.name) for that before I closed, want me to start it again?\". if yes, call start_helper again with helper_name \(agent.name) and restart true."
            }
        }
        return nil
    }

    /// Starts a multi-step job, or lines it up behind the running one.
    /// Returns a short status for Live to relay.
    private func startScreenTask(_ job: ScreenJob) -> String {
        guard DottieScreenActionPerformer.canPostEvents else {
            return "I can't control the mouse and keyboard yet: Dottie needs Accessibility permission in System Settings → Privacy & Security."
        }
        if !job.restart, let question = repeatedScreenJobQuestion(for: job) {
            return question
        }
        screenJobsCutOffByQuit.removeAll { Self.isSameJob($0, job.text) }
        queuedScreenTasks.removeAll { Self.isSameJob($0.text, job.text) }
        if job.restart, screenTaskRunner.isRunning, let currentScreenTaskText, Self.isSameJob(currentScreenTaskText, job.text) {
            // Starting over: the old run goes, the new one takes its place.
            screenTaskRunner.stop()
            self.currentScreenTaskText = nil
            notchPresenter.endScreenTask()
            clearDetectedElementLocation()
            runScreenTask(job)
            return "stopped the old one and started it again from the beginning. say so in a few words."
        }
        if screenTaskRunner.isRunning {
            queuedScreenTasks.append(job)
            print("🧭 Screen task queued (\(queuedScreenTasks.count) waiting): \(job.text)")
            refreshScreenTaskTitle()
            let position = queuedScreenTasks.count
            return "added to the list: it starts after the current job\(position > 1 ? " and \(position - 1) more" : ""). say that in a few words; each result comes to you as it finishes."
        }
        runScreenTask(job)
        return "started. say you're on it in a few words; you'll get the result to tell the user when it's done."
    }

    private func runScreenTask(_ job: ScreenJob) {
        let taskText = job.text
        stopGuide()
        print("🧭 Screen task\(job.isGame ? " (game)" : ""): \(taskText)")
        showOverlayTransientlyIfNeeded()

        screenTaskRunner.onProgress = { [weak self] stepNumber, stepDescription in
            print("🧭 Step \(stepNumber): \(stepDescription)")
            self?.notchPresenter.showScreenTaskStep(stepDescription)
        }
        screenTaskRunner.onSavePicture = { [weak self] imageData, name, description in
            guard let self,
                  let item = self.imageMemory.add(imageData: imageData, name: name, description: description, savedByDottie: true) else {
                return "couldn't save the picture."
            }
            return "saved as \"\(item.name)\" in the picture library."
        }
        screenTaskRunner.onWillClick = { [weak self] point, displayFrame in
            guard let self else { return }
            // Fly there first so the user sees what's about to be clicked.
            self.livePointingRefinementTask?.cancel()
            self.detectedElementScreenLocation = point
            self.detectedElementDisplayFrame = displayFrame
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        currentScreenTaskText = taskText
        notchPresenter.showScreenTaskStep("starting", title: screenTaskTitle)
        // Pictures named in the job count even when Live didn't pass them.
        let referenceItems = job.referenceImageNames.isEmpty
            ? imageMemory.items(mentionedIn: taskText)
            : imageMemory.items(matching: job.referenceImageNames)
        let referenceImages = referenceItems.compactMap { item in
            imageMemory.jpegData(for: item).map {
                DottieScreenTaskRunner.ReferenceImage(name: item.name, description: item.description, jpegData: $0)
            }
        }
        screenTaskRunner.start(task: taskText, isGameMode: job.isGame, referenceImages: referenceImages) { [weak self] outcome in
            self?.finishScreenTask(taskText: taskText, outcome: outcome, repliesToPhone: job.repliesToPhone)
        }
    }

    private var currentScreenTaskText: String? {
        didSet { saveOpenScreenJobs() }
    }

    /// "on it", plus how many jobs are waiting.
    private var screenTaskTitle: String {
        queuedScreenTasks.isEmpty ? "on it" : "on it · \(queuedScreenTasks.count) more next"
    }

    private func refreshScreenTaskTitle() {
        guard screenTaskRunner.isRunning else { return }
        notchPresenter.showScreenTaskStep(notchPresenter.screenTaskStepText, title: screenTaskTitle)
    }

    /// Starts the next waiting job, if there is one.
    private func startNextQueuedScreenTask() {
        guard !screenTaskRunner.isRunning, !queuedScreenTasks.isEmpty else { return }
        let nextJob = queuedScreenTasks.removeFirst()
        print("🧭 Next queued screen task: \(nextJob.text)")
        runScreenTask(nextJob)
    }

    /// Stops the running job and drops every waiting one. Returns true if
    /// anything was running or waiting.
    @discardableResult
    private func stopScreenTask() -> Bool {
        let hadQueuedTasks = !queuedScreenTasks.isEmpty
        for queuedTask in queuedScreenTasks {
            noteStoppedJob("the waiting on-screen job \"\(queuedTask.text)\"")
        }
        queuedScreenTasks.removeAll()
        let stoppedTaskText = currentScreenTaskText
        guard screenTaskRunner.stop() else { return hadQueuedTasks }
        currentScreenTaskText = nil
        noteStoppedJob("the on-screen job \"\(stoppedTaskText ?? "you started")\"")
        print("🧭 Screen task stopped")
        notchPresenter.endScreenTask()
        clearDetectedElementLocation()
        scheduleTransientHideIfNeeded()
        return true
    }

    /// Stops only the running job; the next waiting one starts.
    private func skipCurrentScreenTask() -> String {
        guard screenTaskRunner.isRunning else {
            return queuedScreenTasks.isEmpty ? "nothing is running." : "nothing is running right now."
        }
        noteStoppedJob("the on-screen job \"\(currentScreenTaskText ?? "you started")\"")
        screenTaskRunner.stop()
        currentScreenTaskText = nil
        notchPresenter.endScreenTask()
        clearDetectedElementLocation()
        if queuedScreenTasks.isEmpty {
            scheduleTransientHideIfNeeded()
            return "stopped it. nothing else was waiting."
        }
        startNextQueuedScreenTask()
        return "skipped it and started the next job: \(currentScreenTaskText ?? "")."
    }

    /// What's running and waiting, for list_screen_jobs.
    private func screenTaskQueueSummary() -> String {
        var lines: [String] = []
        if screenTaskRunner.isRunning, let currentScreenTaskText {
            lines.append("doing now: \(currentScreenTaskText) (\(notchPresenter.screenTaskStepText))")
        }
        for (index, queuedTask) in queuedScreenTasks.enumerated() {
            lines.append("\(index + 1). next: \(queuedTask.text)")
        }
        return lines.isEmpty ? "no jobs running or waiting." : lines.joined(separator: "\n")
    }

    private func finishScreenTask(taskText: String, outcome: DottieScreenTaskRunner.Outcome, repliesToPhone: Bool = false) {
        currentScreenTaskText = nil
        notchPresenter.endScreenTask()
        clearDetectedElementLocation()
        let resultText: String
        switch outcome {
        case .finished(let answer):
            print("🧭 Screen task finished: \(answer)")
            resultText = answer
        case .failed(let reason):
            print("🧭 Screen task failed: \(reason)")
            resultText = "it couldn't be finished: \(reason)"
        case .stopped:
            scheduleTransientHideIfNeeded()
            return
        }
        brain.record(.screenJob, "did on screen: \(taskText). result: \(resultText)")
        if repliesToPhone {
            startNextQueuedScreenTask()
            scheduleTransientHideIfNeeded()
            Task { await phoneBridge.send(resultText) }
            return
        }
        let waitingCount = queuedScreenTasks.count
        // The next job starts right away; Dottie tells this result while
        // her cursor gets going on it.
        startNextQueuedScreenTask()

        // Say it as soon as Dottie isn't in the middle of another turn.
        Task { [weak self] in
            for _ in 0..<60 {
                guard let self else { return }
                let isBusy = self.isLiveTurnInFlight || self.voiceState != .idle
                    || self.buddyDictationManager.isDictationInProgress || self.notchPresenter.surface == .textInput
                if !isBusy { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.speakScreenTaskResult(taskText: taskText, resultText: resultText, waitingCount: waitingCount)
        }
    }

    /// Dottie says how the job went, as a turn of its own, so it reads like
    /// her answer and lands in the conversation history.
    private func speakScreenTaskResult(taskText: String, resultText: String, waitingCount: Int = 0) {
        let nextLine = waitingCount == 0 ? "" : " you've already started the next job on the list (\(waitingCount) were waiting); you can mention you're moving on to it."
        let instructionText = "the on-screen job you started is finished. job: \"\(taskText)\". result: \(resultText)\n"
            + "tell the user the result now in one short, fun sentence. don't start the job again." + nextLine
        transientHideTask?.cancel()
        transientHideTask = nil
        showOverlayTransientlyIfNeeded()
        switch voiceMode {
        case .classic:
            sendTranscriptToGeminiWithScreenshot(transcript: instructionText, inputKind: .typed)
        case .live:
            startLiveTextTurn(recordedUserText: "(done: \(taskText))", turnText: instructionText)
        }
    }

    // MARK: - Guides (teaching the app on screen)

    private func startGuide(goal: String, modeName: String) -> String {
        stopScreenTask()
        let mode = DottieGuide.Mode(rawValue: modeName.lowercased()) ?? .steps
        currentGuideGoal = goal
        print("🧑‍🏫 Guide (\(mode.rawValue)): \(goal)")
        transientHideTask?.cancel()
        transientHideTask = nil
        showOverlayTransientlyIfNeeded()

        guide.onProgress = { [weak self] progressText in
            self?.notchPresenter.showScreenTaskStep(progressText, title: "showing you")
        }
        guide.presentStep = { [weak self] step in
            await self?.presentGuideStep(step)
        }
        guide.onEnd = { [weak self] spokenGoodbye in
            self?.guideDidEnd(spokenGoodbye: spokenGoodbye)
        }
        notchPresenter.showScreenTaskStep("looking at your screen", title: "showing you")
        guide.start(goal: goal, mode: mode)
        return mode == .tour
            ? "started the tour. say only a few words like 'okay, let me show you around'; each part's line comes to you next."
            : "started. say only a few words like 'let me show you'; each step's line comes to you next."
    }

    @discardableResult
    private func stopGuide() -> Bool {
        let stoppedGoal = currentGuideGoal
        let didStop = guide.stop()
        if didStop {
            noteStoppedJob("the guide for \"\(stoppedGoal ?? "what you were showing")\"")
        }
        return didStop
    }

    /// Draws the step's marks, points at its target, and says it.
    private func presentGuideStep(_ step: DottieGuide.Step) async {
        drawingOverlayManager.clear()
        for mark in step.marks {
            drawingOverlayManager.add(DottieDrawing(shape: mark.shape, targetRect: mark.rect, note: mark.note), fadesOut: false)
        }
        if let targetRect = step.targetRect {
            // Circle the thing to click unless a mark already covers it.
            if !step.marks.contains(where: { $0.rect.intersects(targetRect) }) {
                drawingOverlayManager.add(DottieDrawing(shape: .circle, targetRect: targetRect, note: nil), fadesOut: false)
            }
            keepsPointingUntilCleared = step.kind == .click
            livePointingRefinementTask?.cancel()
            detectedElementBubbleText = step.kind == .click ? "click here" : nil
            detectedElementDisplayFrame = step.displayFrame
            detectedElementScreenLocation = CGPoint(x: targetRect.midX, y: targetRect.midY)
        } else {
            keepsPointingUntilCleared = false
        }
        notchPresenter.showScreenTaskStep(step.say, title: "showing you")
        await narrate(step.say)
    }

    private func guideDidEnd(spokenGoodbye: String?) {
        print("🧑‍🏫 Guide ended")
        if let guideGoal = currentGuideGoal {
            brain.record(.guide, "showed the user how to: \(guideGoal)")
            currentGuideGoal = nil
        }
        keepsPointingUntilCleared = false
        clearDetectedElementLocation()
        drawingOverlayManager.clear()
        notchPresenter.endScreenTask()
        if let spokenGoodbye {
            Task { [weak self] in
                await self?.narrate(spokenGoodbye)
            }
        }
        scheduleTransientHideIfNeeded()
    }

    /// The saved picture whose name is this pointing label, if any.
    private func savedPictureJPEG(named label: String?) -> Data? {
        guard let label, let item = imageMemory.items(matching: [label]).first else { return nil }
        return imageMemory.jpegData(for: item)
    }

    /// Where a 0-1000 point in this turn's frame is on screen, after the
    /// same second look pointing gets.
    private func refinedScreenLocation(
        normalizedX: Double,
        normalizedY: Double,
        label: String?
    ) async -> (point: CGPoint, elementFrame: CGRect?, displayFrame: CGRect, frameWidthInPoints: CGFloat)? {
        guard let currentLiveTurnScreenFrame,
              let resolvedPoint = currentLiveTurnScreenFrame.resolveNormalizedPoint(normalizedX: normalizedX, normalizedY: normalizedY) else {
            return nil
        }
        let roughScreenLocation = Self.globalScreenLocation(
            forScreenshotPixel: resolvedPoint.pointInScreenshotPixels,
            in: resolvedPoint.screenCapture
        )
        let displayFrame = resolvedPoint.screenCapture.displayFrame
        let refinedFrame = await PointingRefiner.refineFrame(
            elementLabel: label,
            userQuestion: currentLiveTurnTypedText ?? "",
            roughPoint: roughScreenLocation,
            displayFrame: displayFrame,
            referenceImageJPEG: savedPictureJPEG(named: label)
        ).flatMap { displayFrame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.midX, y: $0.midY)) ? $0 : nil }
        let finalPoint = refinedFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? roughScreenLocation
        // The frame spans every display side by side, so "size" is relative
        // to the whole frame's width.
        let frameWidthInPoints = displayFrame.width * CGFloat(currentLiveTurnScreenFrame.compositeWidthInPixels)
            / CGFloat(max(1, resolvedPoint.screenCapture.screenshotWidthInPixels))
        return (finalPoint, refinedFrame, displayFrame, frameWidthInPoints)
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

        let roughScreenLocation = Self.globalScreenLocation(
            forScreenshotPixel: resolvedPoint.pointInScreenshotPixels,
            in: resolvedPoint.screenCapture
        )
        let displayFrame = resolvedPoint.screenCapture.displayFrame
        ClickyAnalytics.trackElementPointed(elementLabel: pointRequest.elementLabel)
        print("🎯 Live pointing: (\(Int(pointRequest.normalizedX)), \(Int(pointRequest.normalizedY)))/1000 → \"\(pointRequest.elementLabel ?? "element")\"")

        // Live's guess comes from a small frame; take a second, sharper look
        // before the cursor flies, so it lands on the thing itself.
        livePointingRefinementTask?.cancel()
        let userQuestion = currentLiveTurnTypedText ?? ""
        let referenceImageJPEG = savedPictureJPEG(named: pointRequest.elementLabel)
        livePointingRefinementTask = Task { [weak self] in
            let refinedScreenLocation = await PointingRefiner.refine(
                elementLabel: pointRequest.elementLabel,
                userQuestion: userQuestion,
                roughPoint: roughScreenLocation,
                displayFrame: displayFrame,
                referenceImageJPEG: referenceImageJPEG
            )
            guard let self, !Task.isCancelled else { return }
            // Still on the display the guess was on, or the guess wins.
            let finalScreenLocation = refinedScreenLocation.flatMap { displayFrame.insetBy(dx: -1, dy: -1).contains($0) ? $0 : nil }
                ?? roughScreenLocation
            self.detectedElementScreenLocation = finalScreenLocation
            self.detectedElementDisplayFrame = displayFrame
        }
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
        let isNarrationTurn = currentLiveTurnIsNarration
        currentLiveTurnIsNarration = false
        // A typed turn has no audio, so Live's input transcript is empty.
        let userTranscript = typedTextForThisTurn ?? userTranscript

        if !isNarrationTurn && (!userTranscript.isEmpty || !modelTranscript.isEmpty) {
            brain.record(.chat, "user: \(userTranscript)\ndottie: \(modelTranscript)")
            conversationStore.append(
                userText: userTranscript,
                clickyText: modelTranscript,
                inputKind: typedTextForThisTurn == nil ? .voice : .typed,
                imageFileNames: typedTextForThisTurn == nil ? [] : currentTurnImageFileNames
            )
            currentTurnImageFileNames = []
            conversationHistory.append((userTranscript: userTranscript, assistantResponse: modelTranscript))
            if conversationHistory.count > Self.rememberedExchangeCount {
                conversationHistory.removeFirst(conversationHistory.count - Self.rememberedExchangeCount)
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
                if isNarrationTurn {
                    // The guide's step stays in the notch instead.
                    self.notchPresenter.collapse()
                } else {
                    self.notchPresenter.showFinishedResponse(modelTranscript)
                }
                self.scheduleTransientHideIfNeeded()
            }
            self.fireLiveTurnFinishedHandler()
        }
    }

    // MARK: - Clickys (background agents)

    /// Starts a background task from voice. Uses the named Clicky (creating
    /// it if it doesn't exist yet), or a general "Helper" Clicky.
    /// Returns a short status for the voice model to relay.
    func startClickyTask(clickyName: String?, taskText: String, projectName: String? = nil, restart: Bool = true) -> String {
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            return "helpers can't run yet: Dottie isn't connected to its server. tell the user to check Settings → Connection."
        }
        if !restart, let question = repeatedHelperTaskQuestion(for: taskText) {
            return question
        }
        var notes: [String] = []
        var messageForHelper = taskText
        var projectForTask: DottieProjects.Project?
        if let projectName, !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let (project, isNew) = projects.findOrCreate(named: projectName, summary: String(taskText.prefix(140)))
            projectForTask = project
            messageForHelper = projects.taskPreamble(for: project, isNew: isNew) + taskText
            notes.append(isNew ? "made a new project, \"\(project.name)\"." : "this continues the project \"\(project.name)\".")
            if isNew { liveVoiceClient.baseSystemInstruction = currentLiveSystemPrompt() }
        }
        // Back on a project: the Dot that last worked on it remembers it.
        let projectHelper = projectForTask?.helperNames.last.flatMap { helperName in
            clickyRoster.agents.first { $0.name == helperName && !clickyRoster.isRunning($0) }
        }
        let targetAgent: ClickyAgent
        if clickyName == nil, let projectHelper {
            targetAgent = projectHelper
        } else if let clickyName, let existingAgent = clickyRoster.agent(matchingName: clickyName) {
            targetAgent = existingAgent
        } else if let clickyName {
            let wasDeleted = clickyRoster.recentlyDeletedAgentNames.contains { $0.caseInsensitiveCompare(clickyName) == .orderedSame }
            targetAgent = clickyRoster.createAgent(name: clickyName, purpose: "")
            notes.append(wasDeleted
                ? "the old \(clickyName) was deleted, so this is a new helper with that name."
                : "there was no helper called \(clickyName), so a new one was made.")
        } else if let idleHelper = clickyRoster.agents.first(where: { $0.isBrain != true && !clickyRoster.isRunning($0) && clickyRoster.pendingComputerUseRequest(for: $0) == nil }) {
            // The most recently made idle helper, usually the one the user
            // just set up in the app.
            targetAgent = idleHelper
        } else {
            let helperCount = clickyRoster.agents.filter { $0.name.hasPrefix("Helper") }.count
            targetAgent = clickyRoster.createAgent(
                name: helperCount == 0 ? "Helper" : "Helper \(helperCount + 1)",
                purpose: "General background tasks the user hands off by voice."
            )
            if !clickyRoster.agents.dropFirst().isEmpty {
                notes.append("the other helpers were busy, so a new one was made.")
            }
        }

        if let projectForTask {
            projects.noteWork(on: projectForTask.id, by: targetAgent.name)
        }
        // A busy helper the user named takes the task next, in order.
        let tasksAhead = clickyRoster.sendOrQueueMessage(messageForHelper, to: targetAgent)
        if tasksAhead > 0 {
            return "\(targetAgent.name) is busy, so this is lined up: it starts after \(tasksAhead == 1 ? "its current task" : "\(tasksAhead - 1) more tasks after its current one"). say that in a few words."
        }
        guard clickyRoster.isRunning(targetAgent) else {
            return "couldn't start \(targetAgent.name). tell the user to try again from the Home window."
        }
        ClickyAnalytics.trackClickyTaskStarted()
        if !DotsRuntimeInstaller.isInstalled {
            notes.append("this is the first helper task on this mac, so it's setting up first (a one-time download), which takes a minute.")
        }
        notes.append("check_helper shows how it's going.")
        return "started. \(targetAgent.name) is working on it and will report back in the notch. " + notes.joined(separator: " ")
    }

    // MARK: - Projects, teams and pictures (DottieWorkTools)

    private func performWorkTool(functionName: String, arguments: [String: Any]) async -> String {
        func text(_ key: String) -> String? {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == true ? nil : value
        }
        switch functionName {
        case "list_projects":
            return projects.listForVoice()
        case "start_team":
            let parts = ((arguments["parts"] as? [Any]) ?? []).compactMap { rawPart -> (helper: String, task: String)? in
                guard let part = rawPart as? [String: Any],
                      let helper = (part["helper"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !helper.isEmpty,
                      let task = (part["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else { return nil }
                return (helper, task)
            }
            return startTeam(goal: text("goal") ?? "", projectName: text("project"), parts: parts)
        case "save_picture":
            guard let name = text("name") else { return "give the picture a name." }
            return await savePictureFromScreen(
                name: name,
                description: text("description") ?? "",
                normalizedX: (arguments["x"] as? NSNumber)?.doubleValue,
                normalizedY: (arguments["y"] as? NSNumber)?.doubleValue,
                label: text("label")
            )
        case "find_pictures":
            let matches = imageMemory.search(text("query") ?? "")
            guard !matches.isEmpty else { return "no saved pictures match that." }
            return matches.map { item in
                "- \(item.name)\(item.savedByDottie == true ? " (you saved it)" : "")" + (item.description.isEmpty ? "" : ": \(item.description)")
            }.joined(separator: "\n")
        default:
            return "unknown tool."
        }
    }

    /// Hands each part of a big job to its own Dot, all in one project
    /// folder, with every Dot told who else is doing what.
    private func startTeam(goal: String, projectName: String?, parts: [(helper: String, task: String)]) -> String {
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            return "helpers can't run yet: Dottie isn't connected to its server. tell the user to check Settings → Connection."
        }
        let teamParts = Array(parts.prefix(5))
        guard teamParts.count >= 2 else {
            return teamParts.first.map { startClickyTask(clickyName: $0.helper, taskText: $0.task, projectName: projectName) }
                ?? "give the team at least two parts."
        }
        let fallbackProjectName = goal.split(separator: " ").prefix(4).joined(separator: " ")
        let (project, isNew) = projects.findOrCreate(named: projectName ?? fallbackProjectName, summary: String(goal.prefix(140)))
        if isNew { liveVoiceClient.baseSystemInstruction = currentLiveSystemPrompt() }

        let roster = teamParts.map { "- \($0.helper): \($0.task)" }.joined(separator: "\n")
        var startedLines: [String] = []
        for part in teamParts {
            let memberName = part.helper
            let member = clickyRoster.agents.first { $0.isBrain != true && $0.name.caseInsensitiveCompare(memberName) == .orderedSame }
                ?? clickyRoster.createAgent(name: memberName, purpose: "Team member: \(memberName).")
            let teamNote = """
            You're the \(member.name) part of a team working on this together, all at the same time, in the same project folder. The whole job: \(goal)
            The team:
            \(roster)
            Only do your own part. Don't delete or rewrite files that belong to another part; if your part depends on theirs (a file name, a class name, an API), agree on it by writing it in TEAM-NOTES.md in the project folder, and read that file before you start and before you finish.
            """
            let message = projects.taskPreamble(for: project, isNew: isNew, teamNote: teamNote) + part.task
            projects.noteWork(on: project.id, by: member.name)
            let tasksAhead = clickyRoster.sendOrQueueMessage(message, to: member)
            startedLines.append(tasksAhead > 0 ? "\(member.name) (after its current task)" : member.name)
        }
        ClickyAnalytics.trackClickyTaskStarted()
        return "started a team on \"\(project.name)\"\(isNew ? " (new project)" : ""): \(startedLines.joined(separator: ", ")). each reports back in the notch when its part is done. say who's on what in a few words."
    }

    /// Crops the thing at (x, y) on this turn's screen, or saves the whole
    /// screen, into the picture library under the given name.
    private func savePictureFromScreen(name: String, description: String, normalizedX: Double?, normalizedY: Double?, label: String?) async -> String {
        var cropFrame: CGRect?
        var displayFrame: CGRect?
        if let normalizedX, let normalizedY,
           let location = await refinedScreenLocation(normalizedX: normalizedX, normalizedY: normalizedY, label: label ?? name) {
            displayFrame = location.displayFrame
            // The thing's outline when it was found, else a square around
            // the point, with some surroundings so it can be recognized.
            let thingFrame = location.elementFrame ?? CGRect(x: location.point.x - 90, y: location.point.y - 90, width: 180, height: 180)
            let padding = max(24, max(thingFrame.width, thingFrame.height) * 0.25)
            cropFrame = thingFrame.insetBy(dx: -padding, dy: -padding).intersection(location.displayFrame)
        }
        let captureFrame = displayFrame
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame
            ?? NSScreen.main?.frame
        guard let captureFrame,
              let screenImage = await DottieDisplayCapture.captureImage(displayFrame: captureFrame, maximumDimension: 2880) else {
            return "couldn't see the screen to save it."
        }
        var savedImage = screenImage
        if let cropFrame, !cropFrame.isEmpty {
            let pixelsPerPoint = CGFloat(screenImage.width) / captureFrame.width
            let pixelRect = CGRect(
                x: (cropFrame.minX - captureFrame.minX) * pixelsPerPoint,
                y: (captureFrame.maxY - cropFrame.maxY) * pixelsPerPoint,
                width: cropFrame.width * pixelsPerPoint,
                height: cropFrame.height * pixelsPerPoint
            ).integral
            if let croppedImage = screenImage.cropping(to: pixelRect) {
                savedImage = croppedImage
            }
        }
        guard let pngData = NSBitmapImageRep(cgImage: savedImage).representation(using: .png, properties: [:]),
              let item = imageMemory.add(imageData: pngData, name: name, description: description, savedByDottie: true) else {
            return "couldn't save the picture."
        }
        liveVoiceClient.baseSystemInstruction = currentLiveSystemPrompt()
        return "saved as \"\(item.name)\"\(cropFrame == nil ? " (the whole screen)" : ""). it's in Home → Pictures, and you can find it by that name later. say so in a few words."
    }

    /// list_helpers, check_helper, stop_helper and open_helper_result.
    private func answerHelperTool(functionName: String, helperName: String?) -> String {
        if functionName == "list_helpers" {
            return clickyRoster.helperListSummary()
        }
        let requestedAgent: ClickyAgent?
        if let helperName, !helperName.isEmpty {
            requestedAgent = clickyRoster.agent(matchingName: helperName)
        } else {
            // No name: the helper the user most likely means is the one
            // that did something most recently.
            requestedAgent = clickyRoster.agents.max { $0.lastActivityAt < $1.lastActivityAt }
        }
        guard let agent = requestedAgent else {
            if let helperName, clickyRoster.recentlyDeletedAgentNames.contains(where: { $0.caseInsensitiveCompare(helperName) == .orderedSame }) {
                return "\(helperName) was deleted by the user. helpers now:\n\(clickyRoster.helperListSummary())"
            }
            return "no helper by that name. helpers now:\n\(clickyRoster.helperListSummary())"
        }
        switch functionName {
        case "stop_helper":
            let droppedCount = clickyRoster.queuedMessages(for: agent).count
            clickyRoster.clearQueuedMessages(for: agent)
            guard clickyRoster.isRunning(agent) else {
                return droppedCount > 0
                    ? "cleared \(agent.name)'s \(droppedCount) waiting tasks."
                    : "\(agent.name) isn't working on anything: \(clickyRoster.statusLine(for: agent))."
            }
            clickyRoster.stopAgent(agent)
            return "stopped \(agent.name)\(droppedCount > 0 ? " and cleared its \(droppedCount) waiting tasks" : "")."
        case "open_helper_result":
            return clickyRoster.openHelperResult(for: agent)
        default:
            return clickyRoster.helperDetail(for: agent)
        }
    }

    // MARK: - Smart home (DottieSmartHome)

    private func performSmartHomeTool(functionName: String, arguments: [String: Any]) async -> String {
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
        print("📺 TV task on \(tv.name): \(task)")
        runner.start(task: task, controls: smartHome.tvControls(for: tv)) { [weak self] outcome in
            guard let self else { return }
            if showsInNotch && !self.screenTaskRunner.isRunning { self.notchPresenter.endScreenTask() }
            let resultText: String
            switch outcome {
            case .finished(let answer): resultText = answer
            case .failed(let reason): resultText = "it couldn't be finished: \(reason)"
            case .stopped: return
            }
            print("📺 TV task result: \(resultText)")
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

    private func performCursorTool(arguments: [String: Any]) -> String {
        cursorPet.perform(arguments: arguments)
    }

    private func configureBrain() {
        clickyRoster.brainFolderURLsProvider = { [weak self] in
            self?.brain.folderURLs ?? []
        }
        clickyRoster.sharedFolderURLs = [projects.rootFolderURL]
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
    }

    /// Hands a question to the Brain agent; Dottie says the answer when it
    /// comes back.
    private func askBrain(question: String) -> String {
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            return "the brain can't run yet: Dottie isn't connected to its server."
        }
        let brainAgent = clickyRoster.brainAgent()
        guard !clickyRoster.isRunning(brainAgent) else {
            return "the brain is still working on the last question: \(clickyRoster.statusLine(for: brainAgent)). tell the user it'll answer that first."
        }
        let recentChat = conversationHistory.suffix(4)
            .map { "user: \($0.userTranscript)\ndottie: \($0.assistantResponse)" }
            .joined(separator: "\n")
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let messageForBrain = """
        Dottie's question for you: \(question)

        (context: the user is in \(frontmostApp). recent conversation with Dottie:
        \(recentChat.isEmpty ? "none" : recentChat))
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
    private func speakWhenFree(recordedUserText: String, instructionText: String) {
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
            switch self.voiceMode {
            case .classic:
                self.sendTranscriptToGeminiWithScreenshot(transcript: instructionText, inputKind: .typed)
            case .live:
                self.startLiveTextTurn(recordedUserText: recordedUserText, turnText: instructionText)
            }
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

    // MARK: - Phone

    private static let phoneHelperName = "Phone"

    private func configurePhoneBridge() {
        phoneBridge.onMessage = { [weak self] text in
            self?.handlePhoneMessage(text)
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

    private func configureClickyRoster() {
        configureBrain()
        configureCursorPet()
        configureMeetingMode()
        configurePhoneBridge()
        clickyRoster.onAgentTurnFinished = { [weak self] turnResult in
            guard let self else { return }
            let updateTitle = turnResult.routineTitle.map { "\(turnResult.agent.name) · \($0)" } ?? turnResult.agent.name
            let isPhoneHelper = turnResult.agent.name == Self.phoneHelperName && self.phoneBridge.pairedChatID != nil
            if let computerUseRequest = turnResult.computerUseRequest {
                if isPhoneHelper {
                    Task { await self.phoneBridge.send("I need to use your Mac's screen for this: \(computerUseRequest)\nReply allow or deny.") }
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
            let finishedTask = self.clickyRoster.transcriptsByAgentID[turnResult.agent.id]?.last { $0.kind == .user }?.text ?? ""
            self.brain.record(.helper, "\(updateTitle) was asked: \(finishedTask.prefix(400))\nreplied: \(updateText.prefix(1200))")
            if turnResult.agent.isBrain == true, let brainQuestion = self.pendingSpokenBrainQuestion {
                self.pendingSpokenBrainQuestion = nil
                self.speakBrainAnswer(question: brainQuestion, answer: updateText)
                self.notchPresenter.showAgentUpdate(title: updateTitle, text: updateText)
                return
            }
            self.notchPresenter.showAgentUpdate(title: updateTitle, text: updateText)
            self.refreshNotchPeekFiles()
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

    /// Reads the newest files in the Dots' output folders off the main
    /// thread and hands them to the notch.
    private func refreshNotchPeekFiles() {
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

    // MARK: - Notch and Typed Messages

    private func configureNotch() {
        configureClickyRoster()
        notchPresenter.onSubmitTypedMessage = { [weak self] messageText in
            self?.sendTypedMessage(messageText)
        }
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
        if turnText == nil { currentTurnImageFileNames = [] }

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

    /// A Live turn from text instead of the mic, with a fresh screen frame.
    /// `recordedUserText` is what the conversation history keeps.
    private func startLiveTextTurn(recordedUserText: String, turnText: String, isNarration: Bool = false) {
        liveTurnPlaybackDrainTask?.cancel()
        isLiveTurnInFlight = true
        currentLiveTurnTypedText = recordedUserText
        currentLiveTurnIsNarration = isNarration
        voiceState = .processing
        Task { [weak self] in
            guard let self else { return }
            // A guide line needs no new look at the screen.
            await self.beginLiveTurnWithScreenFrame(includesScreenFrame: !isNarration)
            self.liveVoiceClient.sendTurnContextText(turnText)
            self.liveVoiceClient.endUserTurn()
        }
    }

    private func fireLiveTurnFinishedHandler() {
        let handler = liveTurnFinishedHandler
        liveTurnFinishedHandler = nil
        handler?()
    }

    /// Says one line in Dottie's voice and returns once it has been said.
    /// Waits for any turn in progress to finish first.
    private func narrate(_ line: String) async {
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
        let isCompanionBusy = voiceState != .idle || isLiveTurnInFlight || isAnySpeechPlaying || screenTaskRunner.isRunning || guide.isActive
            || teachingTask != nil
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

    // MARK: - Higher Model Hand-off

    /// System prompt for the stronger model that answers send_to_higher_model.
    /// Its text goes back to Gemini Live, which says it out loud.
    private static let higherModelSystemPrompt = """
    you're the careful, thorough brain behind dottie, a voice companion on the user's mac. the fast voice model handed you a question it wanted a closer look at. you get full screenshots of every screen. your answer goes back to the voice model, which will say it out loud to the user.

    rules:
    - answer the question directly and correctly. read small text, code and dense ui carefully.
    - write for the ear: plain sentences, no markdown, no lists, no code blocks. describe code changes in words.
    - be as short as the question allows: usually one to three sentences in plain, friendly words. give precise steps only when steps are needed.
    - if what they want isn't on these screenshots, don't say it's not there or give up: it's usually a click or two away (another tab, a menu, further down, another page of the site or app). say where it most likely is and the first thing to click to get there, and point at that. if you can't tell from the screen, say so and suggest searching the web for it; never make up what isn't visible.

    pointing: if pointing at one ui element would help, append a tag at the very end: [POINT:x,y:label] with integer pixel coordinates in that screenshot's coordinate space (top-left is 0,0; images are labeled with their dimensions), and :screenN if it isn't on the cursor screen. otherwise append [POINT:none].
    """

    /// Answers a hand-off from Gemini Live with a stronger model and fresh
    /// screenshots. Points the cursor if the answer says to, and returns the
    /// text for Live to speak. Errors come back as instructions for Live to
    /// relay, so the user always hears something.
    /// Answered the box and text probes in about 2s when the default models
    /// stalled (checked on a Mac runner, Oct 2026).
    nonisolated private static let quickBackupModel = "gemini-3.5-flash"

    /// Runs primary; if it hasn't answered after backupAfterSeconds, starts
    /// backup too and returns whichever answers first.
    nonisolated private static func firstAnswer<Answer: Sendable>(
        backupAfterSeconds: Double,
        primary: @escaping @Sendable () async throws -> Answer,
        backup: @escaping @Sendable () async throws -> Answer
    ) async throws -> Answer {
        try await withThrowingTaskGroup(of: Answer.self) { group in
            group.addTask { try await primary() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(backupAfterSeconds * 1_000_000_000))
                return try await backup()
            }
            var firstError: Error?
            while !group.isEmpty {
                do {
                    let nextAnswer = try await group.next()
                    if let nextAnswer {
                        group.cancelAll()
                        return nextAnswer
                    }
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            throw firstError ?? CancellationError()
        }
    }

    private func answerWithHigherModel(question: String) async -> String {
        print("🧠 Higher model hand-off: \(question)")
        ClickyAnalytics.trackHigherModelHandoff()

        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            let labeledImages = labeledScreenImages(from: screenCaptures, annotation: currentTurnAnnotation)
            let historyForAPI = conversationHistory.map { entry in
                (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
            }

            // The smart model sometimes sits in Google's queue for a minute
            // or more; if it hasn't answered in 20s, a quick model races it.
            let geminiAPI = self.geminiAPI
            let higherModelSystemPrompt = Self.higherModelSystemPrompt
            let askModel: @Sendable (String) async throws -> (text: String, duration: TimeInterval) = { modelName in
                try await geminiAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: higherModelSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: question,
                    modelOverride: modelName,
                    maxOutputTokens: 2048,
                    onTextChunk: { _ in }
                )
            }
            let (fullResponseText, responseDuration) = try await Self.firstAnswer(
                backupAfterSeconds: 20,
                primary: { try await askModel("higher") },
                backup: { try await askModel(Self.quickBackupModel) }
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
                    systemPrompt: Self.classicVoiceSystemPrompt(personality: selectedPersonality)
                        + (brain.profileForPrompt.isEmpty ? "" : "\n\nwhat your second brain knows about the user:\n" + brain.profileForPrompt),
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
                if conversationHistory.count > Self.rememberedExchangeCount {
                    conversationHistory.removeFirst(conversationHistory.count - Self.rememberedExchangeCount)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                brain.record(.chat, "user: \(transcript)\ndottie: \(spokenText)")
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
        // A roaming pet keeps the overlay up.
        if cursorPet.costume?.roams == true { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while isAnySpeechPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor), and for a screen
            // task, whose clicks the cursor shows.
            while detectedElementScreenLocation != nil || screenTaskRunner.isRunning || guide.isActive {
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
            ? "Gemini's swamped right now. Give it a second and try me again."
            : "I'm not connected yet. Open Settings, add the server address under Connection, and try again."
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
