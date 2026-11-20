//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//
//  Two voice modes (Info.plist key CompanionVoiceMode):
//    classic (default) Apple Speech → Groq talks, Claude Haiku does requests
//            with voice Dottie's tools (DottieTalker) → Kokoro, pointing via
//            [POINT:] tags. No Gemini.
//    live    Gemini Live: mic audio + one screenshot frame stream in,
//            spoken audio streams back, pointing arrives as a tool call.
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
            .flatMap { CompanionVoiceMode(rawValue: $0.lowercased()) } ?? .classic
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published var lastTranscript: String?
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
    var onboardingVideoEndObserver: NSObjectProtocol?
    var onboardingDemoTimeObserver: Any?

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
                onDeviceTranscriber: liveTurnOnDeviceTranscriber,
                whistleRecorder: liveTurnWhistleRecorder,
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
    var meetingCancellable: AnyCancellable?
    /// Hold right Option to dictate into any app.
    let dictationController = ClickyDictationController()
    private var dictationCancellables: Set<AnyCancellable> = []
    var clickyRosterCancellable: AnyCancellable?
    var notchHoverCancellable: AnyCancellable?
    var peekFilesRefreshTask: Task<Void, Never>?
    /// State of the notch surface (listening, speaking, typed input, …).
    let notchPresenter = NotchPresenter()
    /// macOS notifications when a Dot finishes or needs an answer.
    let dotNotifications = ClickyNotifications()
    lazy var notchWindowManager = NotchWindowManager(notchPresenter: notchPresenter)
    private lazy var homeWindowManager = HomeWindowManager(
        companionManager: self,
        conversationStore: conversationStore,
        clickyRoster: clickyRoster
    )
    /// Text the user typed for the current live turn, if it was typed rather
    /// than spoken. Live only transcribes audio, so we remember it ourselves.
    var currentLiveTurnTypedText: String?
    /// Apple's speech recognizer hearing each push-to-talk turn on the Mac,
    /// for the instant lane (DottieInstantLane).
    let liveTurnOnDeviceTranscriber = DictationLiveTranscriber()
    /// Keeps a short push-to-talk turn's audio for Whistle when Apple's
    /// speech recognizer can't run (DottieNeedleRouter).
    let liveTurnWhistleRecorder = DottieWhistleTurnRecorder()
    /// What the Mac heard for the current voice turn, once released.
    var currentLiveTurnOnDeviceText: String?
    /// Tool calls Gemini made in the current Live turn, with their results,
    /// so a turn that worked can become a learned shortcut.
    var currentLiveTurnFinishedToolCalls: [DottieInstantLane.FinishedToolCall] = []
    /// "when I say X, …" in the current turn: what Gemini does is saved as X.
    var currentLiveTurnNamedShortcutName: String?
    /// The Mac did the current voice turn itself, so Live's (silenced)
    /// answer to it is ignored when it finishes.
    var currentLiveTurnWasHandledInstantly = false
    /// Counts talk-shortcut presses, so a slow instant-lane check can't act
    /// on a newer turn.
    var liveVoicePressCount = 0
    /// Saved pictures sent with the current typed turn, for its conversation
    /// entry.
    var currentTurnImageFileNames: [String] = []
    /// The second look at where Live pointed; replaced by the next point request.
    private var livePointingRefinementTask: Task<Void, Never>?
    /// What voice Dottie draws on screen when asked.
    private let drawingOverlayManager = DottieDrawingOverlayManager()
    /// Multi-step jobs on the screen ("open opera, find my kaggle rank").
    let screenTaskRunner = DottieScreenTaskRunner()
    /// Teaching the app on screen, step by step or as a tour.
    let guide = DottieGuide()
    /// While a guide waits for the user to click its target, the cursor
    /// keeps pointing at it instead of flying back after a few seconds.
    private(set) var keepsPointingUntilCleared = false
    /// The question Dottie handed the Brain, so she says its answer.
    var pendingSpokenBrainQuestion: String?
    private var currentGuideGoal: String?
    var brainCancellables = Set<AnyCancellable>()
    var cursorPetCancellable: AnyCancellable?
    /// Counts narrated lines so a stale safety timeout can't end a newer one.
    var narrationCount = 0
    /// Called once when the current Live turn has finished speaking (or
    /// failed), for narration that waits on it.
    var liveTurnFinishedHandler: (() -> Void)?
    /// The current Live turn only speaks a guide line; it isn't saved to the
    /// conversation and doesn't leave an answer card.
    var currentLiveTurnIsNarration = false
    var notchVoiceStateCancellable: AnyCancellable?
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Gemini Flash vision chat via the Worker. Used by the onboarding demo
    /// and by classic mode.
    lazy var geminiAPI: GeminiAPI = {
        return GeminiAPI(proxyURL: ClickyWorkerConfiguration.url(forRoute: "/chat"))
    }()

    /// Classic mode only. Live mode speaks through the Live session itself.
    lazy var geminiTTSClient: GeminiTTSClient = {
        return GeminiTTSClient(proxyURL: ClickyWorkerConfiguration.url(forRoute: "/tts"))
    }()

    /// Conversation history so the companion remembers prior exchanges within
    /// a session. Each entry is the user's transcript and the spoken reply.
    var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []
    /// Exchanges carried into each new conversation, including across relaunches.
    static let rememberedExchangeCount = 20

    /// The screenshot frame sent with the current live turn. Pointing tool
    /// calls are in this frame's coordinate space.
    private var currentLiveTurnScreenFrame: CompanionCompositeScreenFrame?
    private var currentLiveTurnScreenFrameCapturedAt: Date?

    /// Circle to ask: the cursor trail while the talk shortcut is held.
    let screenAnnotationManager = ScreenAnnotationManager()
    /// What the user circled during the latest voice turn, if anything.
    var currentTurnAnnotation: ScreenAnnotation?

    /// True from push-to-talk press until the live answer has finished
    /// playing. Keeps the dictation state observer from flipping the cursor
    /// back to idle in the gap between "user stopped talking" and "Gemini
    /// started talking".
    var isLiveTurnInFlight = false
    var liveTurnPlaybackDrainTask: Task<Void, Never>?
    var currentClassicTurnInputKind: ConversationEntry.InputKind = .voice

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var escapeKeyCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published var isOverlayVisible: Bool = false

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

    /// Marks the email step done and passes the email to analytics when
    /// PostHog is configured. The email itself isn't kept on the Mac.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        ClickyAnalytics.identifyUser(email: trimmedEmail)
    }

    func start() {
        DottieSelfKnowledge.companionManager = self
        loadScreenJobsCutOffByQuit()
        DottieBrowser.startTrackingBrowserUse()
        // Classic mode speaks with Kokoro: load it now so the first answer isn't slow.
        if voiceMode == .classic {
            DottieKokoroSpeaker.shared.prepare()
        }
        refreshAllPermissions()
        DottieLog.notice("🔑 Dottie start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindDictation()
        configureLiveVoiceClient()
        // Needle answers its first ask in about a second; later ones take
        // a tenth of that. Pay the first one now, off to the side.
        DottieNeedleRouter.shared.warmUp()
        // Eagerly touch the Gemini API so its TLS warmup handshake completes
        // well before the onboarding demo fires.
        _ = geminiAPI

        if !ClickyWorkerConfiguration.isWorkerConfigured {
            DottieLog.warning("⚠️ Dottie: no server address (Info.plist ClickyWorkerBaseURL or Settings → Connection) — voice won't work until one is set.")
        }

        // Get Dots ready in the background (a one-time download), so the
        // first Dot doesn't wait for it. Skipped when Gemini CLI is already
        // on this Mac.
        Task.detached(priority: .background) {
            guard GeminiCLIAgentRuntime.locateGeminiCLIExecutable() == nil else { return }
            do {
                try await DotsRuntimeInstaller.shared.installIfNeeded()
            } catch {
                DottieLog.warning("⚠️ Dottie: couldn't set up the Dots runtime yet: \(error.localizedDescription)")
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
            DottieLog.warning("⚠️ Dottie: ff.mp3 not found in bundle")
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
            DottieLog.warning("⚠️ Dottie: Failed to play onboarding music: \(error)")
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
        let accessibilityPermissionChanged = currentlyHasAccessibility != hasAccessibilityPermission
        // Each published value is only set when it changed. Setting it to
        // the same value still told every window watching CompanionManager
        // to redraw, every 1.5 seconds for as long as Dottie runs.
        if accessibilityPermissionChanged {
            hasAccessibilityPermission = currentlyHasAccessibility
        }

        // Push-to-talk works without Accessibility: the monitor then only
        // listens (it can't swallow a key shortcut's key). When the
        // permission changes, the tap is rebuilt so it switches between
        // listening and active. start() does nothing while a tap runs.
        if accessibilityPermissionChanged {
            globalPushToTalkShortcutMonitor.stop()
        }
        globalPushToTalkShortcutMonitor.start()

        let currentlyHasScreenRecording = WindowPositionManager.hasScreenRecordingPermission()
        if hasScreenRecordingPermission != currentlyHasScreenRecording {
            hasScreenRecordingPermission = currentlyHasScreenRecording
        }

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let currentlyHasMicrophone = micAuthStatus == .authorized
        if hasMicrophonePermission != currentlyHasMicrophone {
            hasMicrophonePermission = currentlyHasMicrophone
        }

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            DottieLog.notice("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
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
        if !hasScreenContentPermission, UserDefaults.standard.bool(forKey: "hasScreenContentPermission") {
            hasScreenContentPermission = true
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
                DottieLog.notice("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
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
                DottieLog.warning("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Each check is a round trip to macOS's permission service
                // (two every 1.5 s showed in round 1's logs). Once everything
                // is allowed nothing is waiting on a change, so look every
                // 15 s instead; while something's missing, stay quick so the
                // UI updates the moment it's switched on.
                self.permissionPollTickCount += 1
                if self.allPermissionsGranted && self.permissionPollTickCount % 10 != 0 { return }
                self.refreshAllPermissions()
            }
        }
    }

    private var permissionPollTickCount = 0

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

            // Someone pressing the talk shortcut is at the Mac, so away mode
            // ends and the notch shows what happened meanwhile.
            if DottieAwayMode.shared.isAway {
                DottieAwayMode.shared.setAway(false, from: "the talk shortcut")
            }
            // Connected apps start while the user speaks, not when Dottie
            // first needs one.
            DottieToolsStore.shared.warmUpConnectedServers()

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            showOverlayTransientlyIfNeeded()

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            // A spoken turn is always answered out loud.
            liveVoiceClient.isAudioOutputMuted = false

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
                liveVoicePressCount += 1
                currentLiveTurnOnDeviceText = nil
                currentLiveTurnNamedShortcutName = nil
                currentLiveTurnWasHandledInstantly = false
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
                        DottieLog.notice("🗣️ Companion received transcript: \(finalTranscript)")
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
            if let currentTurnAnnotation {
                rememberCircledArea(currentTurnAnnotation.boundingRect)
            }
            if voiceMode == .live, let currentTurnAnnotation {
                sendAnnotationToLiveTurn(currentTurnAnnotation)
            }
            let couldBeInstant = voiceMode == .live && liveVoiceTurnCouldBeInstant()
            if couldBeInstant {
                // Before the turn closes, so none of Live's answer plays
                // while the Mac checks what was said.
                liveVoiceClient.isHoldingModelAnswer = true
            }
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            if voiceMode == .live {
                clearLiveTurnIfItNeverStarted()
                checkInstantLaneAfterLiveVoiceRelease(holdsLiveAnswer: couldBeInstant)
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
    static func classicVoiceSystemPrompt(personality: DottiePersonality) -> String {
        personality.promptSection + "\n\n" + companionVoiceResponseSystemPrompt
    }

    static func liveVoiceSystemPrompt(personality: DottiePersonality) -> String {
        let featureSections = DottieToolRegistry.voicePromptSections
        // The rarer tools aren't declared to Live (GeminiLiveToolCatalog);
        // this line is how the model knows they exist and to find them.
        let hiddenToolsLine = "more tools: find_tool finds the rest by what the user wants and use_tool runs one (call use_tool straight away when you know the name and arguments). never say you can't do something before checking find_tool. they cover " + GeminiLiveToolCatalog.hiddenToolAreasSummary + "."
        return personality.promptSection + "\n\n" + companionLiveVoiceSystemPrompt
            + "\n\n" + hiddenToolsLine
            + "\n\n" + DottieWorkRoutes.voiceAskBeforeSayingNo
            + (featureSections.isEmpty ? "" : "\n\n" + featureSections)
    }

    /// The Live prompt with what the second brain knows about the user.
    /// Long lists (pictures, projects, memories, devices) are a count and a
    /// pointer to the tool that returns them, since every character here is
    /// read again at the start of each session.
    func currentLiveSystemPrompt() -> String {
        var prompt = Self.liveVoiceSystemPrompt(personality: selectedPersonality)
        let profile = brain.profileForPrompt
        if !profile.isEmpty {
            prompt += "\n\nwhat your second brain knows about the user (use it naturally, don't recite it):\n" + profile
        }
        let brainAnswers = brain.brainAnswersForPrompt
        if !brainAnswers.isEmpty {
            prompt += "\n\nthings your second brain already found out. use lasting facts here (names, accounts, which repo or folder is which) instead of asking it again; things that change (open pull requests, a file's contents) need a fresh look:\n" + brainAnswers
        }
        let threeDaysInSeconds: TimeInterval = 3 * 86_400
        let recentEpisodeCount = DottieEpisodicMemory.shared.episodes.filter { episode in
            Date().timeIntervalSince(episode.endedAt) < threeDaysInSeconds
        }.count
        if recentEpisodeCount > 0 {
            prompt += "\n\nyou remember \(recentEpisodeCount) thing\(recentEpisodeCount == 1 ? "" : "s") from the last few days; use_tool memories {\"action\": \"recent\"} lists them and recall_memory searches everything. bring them up only if relevant."
        }
        if let routinesLine = DottieHabits.shared.voicePromptLine {
            prompt += "\n\n" + routinesLine + " use_tool memories {\"action\": \"routines\"} lists them with ids; when the user tells you a routine of theirs, save it with add_routine."
        }
        let savedPictureCount = imageMemory.items.count
        if savedPictureCount > 0 {
            prompt += "\n\npictures: \(savedPictureCount) saved picture\(savedPictureCount == 1 ? "" : "s") (the user's and yours). use_tool find_pictures {\"query\": \"…\"} gives their names and where they're from. when the user means one (\"grab that sword\", \"where's the thing i showed you\"), pass its exact name in do_task_on_screen's reference_images or as point_at_element's label, so the picture itself is matched on screen. save_picture saves a new one."
        } else {
            prompt += "\n\npictures: save_picture (use_tool) saves something's look or place on screen to find again by name."
        }
        let projectCount = projects.projects.count
        if projectCount > 0 {
            prompt += "\n\nthe user has \(projectCount) project\(projectCount == 1 ? "" : "s"); use_tool list_projects {} names them. pass a name as start_helper's project to keep working on one."
        }
        let homeSummary = smartHome.promptSummary.replacingOccurrences(of: "\n", with: "; ")
        prompt += "\n\nsmart home: you're the user's home controller. control_device does one thing right away; use_tool home_devices lists devices and their state; tv_task does multi-step jobs on a tv; apple home goes through their shortcuts or the home app on screen."
            + (homeSummary.isEmpty ? " nothing is set up yet; they add devices in your Home window under Smart Home." : " set up: " + homeSummary)
        return prompt
    }

    // MARK: - Live Voice Pipeline (Gemini Live)

    /// Live mode's system prompt. Pointing is a tool call instead of a text
    /// tag, because the model's output is audio.
    /// Lines that only explain a rarely used tool live in that tool's
    /// description instead, which find_tool returns when it's needed.
    private static let companionLiveVoiceSystemPrompt = """
    how this works: you're always on. the user talks to you with push-to-talk, each turn comes with one frame of their screen(s), and you answer out loud. it's an ongoing conversation; you remember what they've said.

    rules:
    - short, simple and fun: one sentence, two at most, in plain everyday words. say the one thing they need and stop: no background, no recap, no "here's how it works". go longer only when they ask you to explain more or go deeper.
    - stay in character (above) in every answer, but never at the cost of the answer. speak naturally, no lists or reading out formatting.
    - don't read code out verbatim; say what it does or what needs to change.
    - if the question is about their screen, mention specific things you see; if the screen isn't relevant, just answer.
    - you can help with anything: coding, writing, general knowledge, brainstorming. for fresh or specific facts (news, prices, scores, weather, dates, recent versions), call search_web instead of guessing.
    - never say "simply" or "just".
    - don't end with questions like "want me to explain more?" and don't tack on extra tips. ending right after the answer is perfect.
    - with several screens side by side, the one marked as the cursor screen is the main focus. a bright blue hand-drawn ring is something the user circled while talking; that's what they're asking about.

    pointing: point_at_element flies your little cursor to something on screen (x and y from 0 to 1000 across the whole frame, 0,0 top-left, plus a short label). use it to show a thing you can clearly read on the screen right now (they ask what something is, or where a thing they named is and its name is visible). never point at, or name, a button, menu or panel you can't actually read in the frame: your frame is small, so don't guess. not for general knowledge or something obvious they're already looking at. call it once, then talk as if gesturing: "see that button up here? click it."

    when it's not on this screen: never say something isn't there or can't be found from one look. it's usually a click or two away: another tab, a menu, a sidebar, further down, another page (a github project's downloads are under code, then releases on the right; an app's settings are in its menu bar). work out where it lives (search_web if unsure, like "where do i download releases on github"), then point at the first thing to click and say where it leads, or call guide_user to walk them there; if they asked you to do it, do_task_on_screen. keep trying other ways; only say you couldn't after really trying, and then say what you tried and what they could try next.

    going deeper: you're the fast voice. for careful reading of small text, code or a long document, precise steps or real reasoning, say a few words ("let me take a closer look"), call send_to_higher_model, then speak its answer in your own voice. it points the cursor itself, so don't point again for the same thing.

    doing things on screen: only when the user asks you to do it for them ("click sign in", "open youtube", "go back"), never on your own initiative or just because it would help; pointing is for showing, these are for doing. one quick step: click_on_screen (label exactly as on screen), press_keys (prefer a shortcut whenever one exists), open_url; typing and scrolling are in your other tools; drawing is explain_on_screen (see teaching). then say it's done in a few words, if that one step was the whole request. for anything risky or permanent (sending, buying, deleting, posting), say what you'll do and ask first. never type passwords.

    another way when one fails: if a script, link or app tool fails, or its result shows the goal didn't happen (a search page instead of the song playing, an error, an empty answer), don't say it's done and don't repeat the same thing: switch routes once, script or link → do_task_on_screen with the user's whole goal (the screen job sees and clicks like they would). say something is done, playing or drawn only when a tool result shows it; until then say you're trying.
    asked again: when the user asks for something you already did ("make a note called test" twice, "search lofi" again), they want it done again: do it again with your tools. never answer "that's already done".
    you can always work the user's screen: anything they could do with their own mouse and keyboard in any app or website (move an event or task to another day or list, drag something between boards, plans or folders, change a setting, fill a form) you can do with do_task_on_screen. never say you don't have access, can't use that app, or that they should do it themselves; never hand screen work to a helper or ask_brain (they have no screen). only after a screen job really failed, say what it tried.
    these all work, so never say you can't or ask the user to do them: you see their screen (a fresh picture comes with every turn); open any web page with open_url (search first when you don't know the exact address, then open the real page, like a model's hugging face page); click with click_on_screen, and "click around" or anything with several steps is do_task_on_screen; write or type for them into the field in front with type_text ("write it for me" means type it); copy anything with copy_to_clipboard. when they ask for commands or code, write each on the notes board as a code block (write_notes, kind code, exactly as typed), copy it with copy_to_clipboard, and say only what it does; never read code aloud as words or describe it instead of giving it.
        multi-step jobs: when something on screen takes more than one step ("open opera, search kaggle, go to my competitions and tell me my rank"), call do_task_on_screen once with the whole request, every step in order; don't do the steps yourself. say you're on it in a few words and stop; the result comes in a later message, which you tell in one short sentence. a job asked while another runs waits its turn: call do_task_on_screen for it too. separate jobs in one breath are separate calls in the user's order; inside one task keep their order and words, never reorder. stop_screen_task: current skips to the next job, all stops everything (stop, cancel, never mind), list says what's running and waiting. a job the user stopped (stop button, escape, or asking) is gone: if they ask again, call do_task_on_screen again, never say you're still on it. inside a video game ("grab that sword", "play this level for me", "map this game for me" while they play, "for this commercial: walk slowly to the shop, then face the camera"), set game true and keep the game's name and the user's exact words in the task. while a game job runs, whatever the user says about the game ("jump", "this is the shop, remember it", "in this game F opens the shop") goes to game_command, not to screenshots, notes or memory.

    teaching: helping people learn their apps matters most, and being right matters more than being fast. never answer how to do something in an app, or where a feature lives, from your own memory: apps change and you'll guess wrong. any "how do i..." or "where do i..." in an app ("how do i isolate the audio in capcut", "where do i extract it", "walk me through exporting") goes to guide_user with mode steps: it checks the app's real help pages and the screen, points at each step, waits for their click, then shows the next. say only a few words like "let me show you". if the ask could mean two different features, ask one short question first (isolate audio: "split the sound onto its own track, or keep just the voice and remove the background?"). for a rundown or tour of the app or screen, mode tour. when the user corrects you about how an app works, call use_tool save_app_lesson with the right way, then say thanks in a few words. during a guide, next / done / got it is guide_next; stop is stop_guide. lines that start with [dottie guide] are steps already drawn on screen: say just that line.
    worked math, step-by-step solutions, formulas and study notes go on the notes board with write_notes (headings, lists, equations, pictures; place right to continue the same working on one line), always in real symbols (¹⁄₁₆x⁴, ×, √, H₂O), never math spelled out in words; color the part that matters with {red:…} or {highlight:…}. Make it easy for someone who doesn't think in symbols: the rule first in plain words, one small change per line with a short "why" beside it, matching colors for parts that go together, and the answer highlighted at the end; say the explanation out loud in everyday words. when you write numbers (notes, the screen, typed answers), use digits for math, measurements, money, times, dates, scores and anything 10 or more, and words for small everyday counts in a sentence ("two ways", "the first step"); if the user says which they want, keep to it.
    whenever you explain something visual or mathematical (geometry, a graph, an equation, a diagram, a chess position), draw it with explain_on_screen without waiting to be asked. any ask to draw, sketch, graph, chart or mark something goes to explain_on_screen too, whether or not they say "on my screen": a grid, a graph with a downward trend, an arrow at something. when they ask to add to or change what you drew, call it again with add_to_last true and only the new steps; for a bigger, smaller or full-screen board, add_to_last true with board_size. when they circled something (a problem, a question, a table) and ask you to solve it, do an example or graph it on screen, draw onto or beside it with the anchor circled; for a graph of a table or numbers, use a chart step (text circled graphs exactly what they circled), never lines placed by guessing.

    second brain: it remembers everything you and the helpers did with the user, and can dig through their files, command-line tools and connected apps.
    - about the past ("what was i working on yesterday", "what was that site"): recall_memory with a few keywords, and answer from it.
    - "remember this": remember, written so it stands on its own.
    - their files, folders, tools or real digging ("find my resume and tighten it", "check my git repos for uncommitted work"): ask_brain. say a few words, then stop; its answer comes back to you to say.

    helpers (also called dots): background workers on the mac with a shell, files, node and the web, who report back in the notch. they research, write documents, organize files, write code and build whole websites or apps.
    - for work that takes more than an answer, "have a helper / a named helper do it", "can one of my helpers…", or talking to a helper by name ("Jarvis, look up…"), call start_helper with a task that stands on its own (helper_name if they named one), then say it's started in a few words. don't do the task yourself, and never say you can't start a helper. never say a helper is on something unless you called start_helper for it in this same answer.
    - more work on something a helper just did ("open it", "change that file", "add a column"): the [recent helper work] note says which helper did it; give it to that same helper (open_helper_result or start_helper with its helper_name), never ask_brain.
    - helpers change without you, so never answer about them from memory: call list_helpers or check_helper first and give the gist in a sentence or two. if one isn't there anymore, it was deleted.
    - anything being built or come back to lives in a project: pass project to start_helper (an existing name to keep working on it, a short new name for something new; a different new thing gets its own project). a big job with separate parts, or "a team", goes to start_team.

    your mac powers, only when asked (quicker and surer than clicking): run_applescript for apps and settings (music or spotify play/pause/next, finder, notes, mail drafts, volume, dark mode, opening or quitting apps, arranging windows); a particular song, artist, album or playlist ("play louise on spotify") can't be picked by script or link (they only open a search), so call do_task_on_screen right away with "in spotify, search <it> and play the top result"; get_schedule ("what's my day look like", "am i free friday"); add_reminder ("remind me to call mom at 5"). answer in a sentence, like "three things today, first is standup at ten". anything that sends, deletes or buys asks the user in a dialog first, so go ahead when they ask; if they say no, drop it.
    the user can text you from their phone (home → phone): a helper called Phone does the job and texts back.
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

        connectLiveTurnCallbacks()
        connectLiveToolCallbacks()
    }

    /// What the Live client reports about a turn: speech starting, captions,
    /// pointing, the turn ending, finished tool calls and errors.
    private func connectLiveTurnCallbacks() {
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

        liveVoiceClient.onModelTurnComplete = { [weak self] userTranscript, modelTranscript, isFollowUp in
            self?.finishLiveTurn(userTranscript: userTranscript, modelTranscript: modelTranscript, isFollowUpAfterTools: isFollowUp)
        }

        liveVoiceClient.onLateTranscriptOfPreviousAnswer = { [weak self] lateTranscript in
            guard let self else { return }
            self.conversationStore.extendEntry(withID: self.lastLiveTurnConversationEntryID, clickyText: lateTranscript)
        }

        liveVoiceClient.helperNamesForHandOffCheck = { [weak self] in
            guard let self else { return (allHelperNames: [], busyHelperNames: []) }
            let helpers = self.clickyRoster.agents.filter { $0.isBrain != true }
            return (
                allHelperNames: helpers.map(\.name),
                busyHelperNames: helpers.filter { self.clickyRoster.isRunning($0) }.map(\.name)
            )
        }

        liveVoiceClient.onFunctionCallFinished = { [weak self] functionName, arguments, result in
            self?.currentLiveTurnFinishedToolCalls.append(
                DottieInstantLane.FinishedToolCall(functionName: functionName, arguments: arguments, result: result)
            )
        }

        liveVoiceClient.onTurnError = { [weak self] error in
            guard let self else { return }
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            DottieLog.warning("⚠️ Gemini Live turn error: \(error)")
            self.isLiveTurnInFlight = false
            self.currentLiveTurnIsNarration = false
            self.liveVoiceClient.isAudioOutputMuted = false
            self.fireLiveTurnFinishedHandler()
            let failedRequestText = self.currentLiveTurnTypedText ?? self.currentLiveTurnOnDeviceText ?? ""
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
            self.doOnMacOrSpeakConnectionError(
                requestText: failedRequestText,
                inputKind: self.currentLiveTurnTypedText == nil ? .voice : .typed
            )
        }
    }

    /// The tools Live can call, each handed to the part of the companion
    /// that does it.
    private func connectLiveToolCallbacks() {
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
    }

    /// Called by the live transcription provider when push-to-talk opens.
    /// Grabs the screen frame and opens the user's turn on the Live session.
    func beginLiveTurnWithScreenFrame(includesScreenFrame: Bool = true) async {
        currentLiveTurnFinishedToolCalls = []
        // So a web page's elements can be found by name if Dottie points.
        PointingRefiner.prepareFrontmostApplicationForSearch()
        var compositeScreenFrame: CompanionCompositeScreenFrame?
        if includesScreenFrame {
            do {
                compositeScreenFrame = try await CompanionScreenCaptureUtility.captureCompositeFrameForLive()
            } catch {
                DottieLog.warning("⚠️ Gemini Live: screen capture failed, sending voice only: \(error)")
            }
        }

        currentLiveTurnScreenFrame = compositeScreenFrame
        currentLiveTurnScreenFrameCapturedAt = compositeScreenFrame == nil ? nil : Date()
        DottieEpisodicMemory.shared.noteConversationScreenshot(compositeScreenFrame?.jpegData)
        liveVoiceClient.beginUserTurn(
            screenFrameJPEGData: compositeScreenFrame?.jpegData,
            screenFrameFingerprint: compositeScreenFrame.flatMap { ScreenFrameFingerprint.make(fromJPEGData: $0.jpegData) }
        )

        if let compositeScreenFrame, compositeScreenFrame.regions.count > 1 {
            liveVoiceClient.sendTurnContextText(compositeScreenFrame.layoutDescription)
        }
        // Not on a guide line, which must be said word for word.
        if includesScreenFrame && !notesForNextLiveTurn.isEmpty {
            liveVoiceClient.sendTurnContextText(notesForNextLiveTurn.joined(separator: "\n"))
            notesForNextLiveTurn = []
        }
        // What the helpers did lately and which files they touched, so
        // "open that file" or "change it again" goes back to the helper
        // that did it. Live's own history only has what was said aloud,
        // not which helper did the work.
        if includesScreenFrame, let recentWorkNote = DottieRecentWorkNote.noteText(entries: clickyRoster.recentHelperWork()) {
            liveVoiceClient.sendTurnContextText(recentWorkNote)
        }
    }

    /// Things that changed outside the conversation (the user stopped a job
    /// with the notch button or Escape), told to Live with the next turn.
    /// Without this, Live still thinks a stopped job is running and answers
    /// "I'm on it" when the user asks for it again.
    private var notesForNextLiveTurn: [String] = []

    func noteStoppedJob(_ description: String) {
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
    func labeledScreenImages(
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
    func performScreenAction(_ screenAction: DottieScreenAction) async -> String {
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
            // "sign in with this account": the click only starts the goal,
            // so a screen job finishes it (DottieTaskGoal).
            let userRequest = currentLiveTurnTypedText ?? liveVoiceClient.userTranscriptSoFar
            if DottieTaskGoals.clickLeavesGoalUnfinished(request: userRequest), !screenTaskRunner.isRunning {
                let jobText = "\(userRequest.trimmingCharacters(in: .whitespacesAndNewlines)) (Dottie already clicked \"\(label ?? "it")\" for this; carry on from there)"
                _ = startScreenTask(ScreenJob(text: jobText))
                return "clicked \(label ?? "it"), and the rest of their goal is already under way as an on-screen job. say you're on it in a few words. don't call do_task_on_screen for it."
            }
            return "clicked \(label ?? "it"). if that click was all the user asked for, just say it's done. if their goal needs more (signing in, sending, finishing a form), it isn't done: call do_task_on_screen now with the whole goal."

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
                // A word found by reading the screen ("Like") grows to take
                // in the icon beside it, so the mark sits on the whole button.
                markedRect = await MarkTargetExtender.frameIncludingIconBeside(elementFrame, displayFrame: target.displayFrame)
            } else {
                var width: CGFloat = 70
                if let normalizedSize {
                    width = CGFloat(max(16, min(1000, normalizedSize)) / 1000) * target.frameWidthInPoints
                }
                let height: CGFloat = max(22, min(width * 0.4, 120))
                markedRect = CGRect(x: target.point.x - width / 2, y: target.point.y - height / 2, width: width, height: height)
            }
            DottieLog.notice("✏️ draw_on_screen \(shape.rawValue) \"\(label ?? "")\": found \(target.elementFrame == nil ? "nothing, rough box" : "the element") at \(Int(markedRect.midX)),\(Int(markedRect.midY)) size \(Int(markedRect.width))×\(Int(markedRect.height))")
            drawingOverlayManager.add(DottieDrawing(shape: shape, targetRect: markedRect, note: note))
            return "drew a \(shape.rawValue) on screen."

        case .clearDrawings:
            stopTeaching(clearingDrawing: true)
            drawingOverlayManager.clear()
            lastTeachingBoardRect = nil
            lastTeachingDisplayFrame = nil
            return "cleared the drawings."
        }
    }

    // MARK: - Teaching with drawings

    var teachingTask: Task<Void, Never>?
    /// The step line being said, so a stopped explanation doesn't keep
    /// talking after the user does.
    private var teachingNarrationTask: Task<Void, Never>?

    /// explain_on_screen: draws the explanation step by step with the
    /// cursor as the pen. Returns at once so Live can say "okay, watch";
    /// each step's line is spoken as it's drawn.
    private func startTeaching(arguments: [String: Any]) -> String {
        guard let givenPlan = DottieTeaching.Plan(arguments: arguments) else {
            return "error: give steps, each with a kind and points."
        }
        // Checked before anything is drawn or cleared: a step that can't be
        // drawn used to be skipped quietly while Live said it was drawn.
        // Steps that can be drawn still are; refusing the whole drawing for
        // one bad step had Live retrying in a loop with nothing on screen.
        let stepProblems = givenPlan.problems
        let plan = givenPlan.keepingOnlyDrawableSteps()
        var skippedStepsNote = ""
        if !stepProblems.isEmpty {
            DottieLog.notice("✏️ Teaching steps refused: \(stepProblems.joined(separator: "; "))")
            DottieTeaching.recordRefusedDrawing(problems: stepProblems, arguments: arguments, drewOtherSteps: !plan.steps.isEmpty)
            if plan.steps.isEmpty {
                return "error: nothing was drawn. fix these and call explain_on_screen again with all the steps: "
                    + stepProblems.joined(separator: "; ")
                    + ". don't tell the user anything was drawn until it is."
            }
            skippedStepsNote = " these steps were left out and not drawn: " + stepProblems.joined(separator: "; ")
                + ". don't say they were drawn; explain those parts in words, or add them later with add_to_last true."
        }
        // Adding to a drawing that's still up keeps it, and its board, so
        // "now show a downward trend on it" lands on the same grid. Every
        // call used to wipe the screen and start over.
        let isAddingToDrawingOnScreen = plan.addsToLastDrawing && !drawingOverlayManager.figures.isEmpty
        let earlierTeachingTask = isAddingToDrawingOnScreen ? teachingTask : nil
        if !isAddingToDrawingOnScreen {
            stopTeaching(clearingDrawing: true)
            drawingOverlayManager.clear()
            lastTeachingBoardRect = nil
            lastTeachingDisplayFrame = nil
        }
        stopGuide()
        let mouseLocation = NSEvent.mouseLocation
        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return "couldn't find the screen."
        }
        let reusesEarlierBoard = isAddingToDrawingOnScreen && lastTeachingBoardRect != nil
            && (!plan.surfaceWasGiven || plan.surface != .screen)
        // Adding to a drawing made over the screen stays on the screen
        // unless a board was asked for.
        let staysOnScreenDrawing = isAddingToDrawingOnScreen && lastTeachingBoardRect == nil && !plan.surfaceWasGiven
        var plannedBoardRect: CGRect?
        if reusesEarlierBoard {
            plannedBoardRect = lastTeachingBoardRect
        } else if !staysOnScreenDrawing {
            plannedBoardRect = plan.surface.boardRect(on: cursorScreen.visibleFrame, sizeScale: plan.boardSize?.scaleFromUsualSize ?? 1)
        }
        // "make the board bigger": the board that's up and its drawing
        // move and scale together.
        if reusesEarlierBoard, let boardSize = plan.boardSize, let currentBoard = lastTeachingBoardRect {
            let boardScreen = NSScreen.screens.first(where: { $0.frame.intersects(currentBoard) }) ?? cursorScreen
            let usualBoardSide = DottieTeaching.Surface.board_right.boardRect(on: boardScreen.visibleFrame)?.width ?? currentBoard.width
            let resizedBoard = boardSize.resized(currentBoard, usualBoardSide: usualBoardSide, on: boardScreen.visibleFrame)
            drawingOverlayManager.refitBoardFigures(from: currentBoard, to: resizedBoard)
            plannedBoardRect = resizedBoard
            DottieLog.notice("✏️ Board resized to \(boardSize.rawValue)")
        }
        if plan.steps.isEmpty {
            guard reusesEarlierBoard else {
                return "there's no board up to resize. to draw on a bigger board, call explain_on_screen with board_size and the steps."
            }
            lastTeachingBoardRect = plannedBoardRect
            return "resized the board; everything on it moved with it. say it in a few words."
        }
        let boardRect = plannedBoardRect
        let drawsNewBoard = boardRect != nil && !reusesEarlierBoard
        let teachingDisplayFrame = reusesEarlierBoard ? (lastTeachingDisplayFrame ?? cursorScreen.frame) : cursorScreen.frame
        lastTeachingBoardRect = boardRect
        lastTeachingDisplayFrame = teachingDisplayFrame
        let screenFrame = currentLiveTurnScreenFrame
        let userQuestion = currentLiveTurnTypedText ?? lastTranscript ?? ""
        let hasSpokenLines = plan.steps.contains { $0.say != nil }
        let circledArea = recentCircledArea
        let circledRowsTask = circledArea == nil ? nil : lastCircledAreaRowsTask
        DottieLog.notice("✏️ Teaching: \(plan.steps.count) steps on \(plan.surface.rawValue), \(plan.anchors.count) anchors")
        transientHideTask?.cancel()
        transientHideTask = nil
        showOverlayTransientlyIfNeeded()
        teachingGeneration += 1
        let generationOfThisTeaching = teachingGeneration
        teachingTask = Task { [weak self] in
            // Steps added while the last ones are still drawing go after
            // them; stopping this stops those too.
            await withTaskCancellationHandler {
                await earlierTeachingTask?.value
            } onCancel: {
                earlierTeachingTask?.cancel()
            }
            guard !Task.isCancelled else { return }
            await self?.runTeaching(plan: plan, screenFrame: screenFrame, displayFrame: teachingDisplayFrame,
                                    boardRect: boardRect, drawsBoard: drawsNewBoard, userQuestion: userQuestion,
                                    speaksLines: hasSpokenLines, generation: generationOfThisTeaching,
                                    circledArea: circledArea, circledRowsTask: circledRowsTask)
        }
        let continuingNote = isAddingToDrawingOnScreen
            ? "adding to the drawing that's up. "
            : (plan.addsToLastDrawing ? "nothing was up any more, so this starts a new drawing. " : "")
        let laterNote = " it stays up; to add to it later, call explain_on_screen again with add_to_last true and the same positions."
        var circledNote = ""
        if circledArea != nil, let circledRows = lastCircledAreaRows, !circledRows.isEmpty {
            let circledText = String(circledRows.joined(separator: " / ").prefix(1500))
            circledNote = " the circled area reads (exactly, from the Mac): \(circledText)"
        }
        return continuingNote + (hasSpokenLines
            ? "drawing it now. say only two or three words like 'okay, watch'; each step's line comes to you to say while it's drawn."
            : "drawing it now, step by step. explain it in the same order, briefly, while it draws.") + laterNote + circledNote + skippedStepsNote
    }

    /// The last area the user circled while talking, so a drawing can sit
    /// on or beside it (the "circled" anchor) and a chart can graph the
    /// table in it. Its text is read on the Mac right away, so it's
    /// usually ready by the time Live asks to draw.
    private var lastCircledArea: CGRect?
    private var lastCircledAreaCircledAt: Date?
    private var lastCircledAreaRowsTask: Task<[String], Never>?
    private var lastCircledAreaRows: [String]?
    /// A circle older than this isn't what a new drawing is about.
    private static let circledAreaSecondsToKeep: TimeInterval = 15 * 60

    private func rememberCircledArea(_ circledRect: CGRect) {
        guard circledRect.width > 8, circledRect.height > 8 else { return }
        lastCircledArea = circledRect
        lastCircledAreaCircledAt = Date()
        lastCircledAreaRows = nil
        lastCircledAreaRowsTask?.cancel()
        lastCircledAreaRowsTask = Task { [weak self] in
            // Once the ring has faded off the screen, so it isn't read too.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return [] }
            let rows = await DottieChartData.readRows(inGlobalRect: circledRect)
            if !Task.isCancelled, self?.lastCircledArea == circledRect {
                self?.lastCircledAreaRows = rows
            }
            return rows
        }
    }

    /// The circled area while it's recent enough to be what the user means.
    private var recentCircledArea: CGRect? {
        guard let lastCircledArea, let lastCircledAreaCircledAt,
              Date().timeIntervalSince(lastCircledAreaCircledAt) < Self.circledAreaSecondsToKeep else { return nil }
        return lastCircledArea
    }

    /// The board the last explanation drew on and its display, so steps
    /// added later (add_to_last) land on the same board.
    private var lastTeachingBoardRect: CGRect?
    private var lastTeachingDisplayFrame: CGRect?
    /// Counts explanations, so one that finishes before steps added to it
    /// doesn't forget the newer task.
    private var teachingGeneration = 0

    private func runTeaching(
        plan: DottieTeaching.Plan,
        screenFrame: CompanionCompositeScreenFrame?,
        displayFrame: CGRect,
        boardRect: CGRect?,
        drawsBoard: Bool,
        userQuestion: String,
        speaksLines: Bool,
        generation: Int,
        circledArea: CGRect?,
        circledRowsTask: Task<[String], Never>?
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

        if drawsBoard, let boardRect {
            drawingOverlayManager.addFigures([DottieFigure(shape: .board(rect: boardRect), drawDuration: 0.35)])
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        // Start with Live's "okay, watch" out of the way, so drawing and
        // speaking stay together.
        if speaksLines {
            await waitUntilLiveIsQuiet()
        }

        // "circled" is always an anchor: the area the user circled.
        let builtInAnchorFrames: [String: CGRect] = circledArea.map { ["circled": $0] } ?? [:]
        var missedSteps = 0
        // Text already written, so a new label doesn't land on top of one.
        var occupiedTextRects = DottieTeaching.textRects(of: drawingOverlayManager.figures)
        for plannedStep in plan.steps {
            if Task.isCancelled { break }
            var step = plannedStep
            // A chart of what the user circled gets its numbers read on the
            // Mac, exactly, instead of from Live's small frame.
            if step.kind == .chart, let chartText = step.text, chartText.lowercased().contains("circled") {
                let circledRows = await circledRowsTask?.value ?? []
                let circledChartText = DottieChartData.chartText(fromRows: circledRows)
                DottieLog.notice("✏️ Circled table: \(circledRows.count) rows → \(circledChartText.prefix(200))")
                if Task.isCancelled { break }
                step = step.replacingText(circledChartText)
            }
            // A free drawing ("a horse") is planned as pen strokes first.
            if step.kind == .sketch {
                let sketchDescription = step.text ?? step.caption ?? "a simple drawing"
                notchPresenter.showScreenTaskStep("sketching \(sketchDescription)", title: "drawing")
                guard let plannedStrokesText = await DottieSketchArtist.plannedStrokesText(for: sketchDescription) else {
                    notchPresenter.endScreenTask()
                    DottieLog.notice("✏️ Sketch: couldn't plan \"\(sketchDescription)\"")
                    missedSteps += 1
                    // Said "drawing it now" already, so the miss is shown
                    // instead of nothing appearing.
                    notchPresenter.showCard(title: "drawing", text: "I couldn't draw \(sketchDescription) this time. Ask me again and I'll retry.")
                    notesForNextLiveTurn.append("[note] the drawing of \(sketchDescription) failed and nothing was drawn. if the user asks about it, say so; never say it was drawn.")
                    continue
                }
                notchPresenter.endScreenTask()
                if Task.isCancelled { break }
                step = step.replacingText(plannedStrokesText)
            }
            let usesPlanAnchors = step.points.contains { reference in
                let name = reference.lowercased()
                return anchorNames.contains(name) || anchorNames.contains(where: { name.hasPrefix($0 + ".") })
            }
            let usesCircledArea = step.points.contains { reference in
                let name = reference.lowercased()
                return builtInAnchorFrames[name] != nil || builtInAnchorFrames.keys.contains(where: { name.hasPrefix($0 + ".") })
            }
            let usesAnchors = usesPlanAnchors || usesCircledArea
            if usesPlanAnchors && anchorFrames == nil {
                notchPresenter.showScreenTaskStep("finding it on your screen", title: "drawing")
                anchorFrames = await anchorLookup?.value ?? [:]
                notchPresenter.endScreenTask()
                if Task.isCancelled { break }
            }
            let space = Self.teachingSpace(
                // Anchored steps point at the screen even with a board open.
                boardRect: usesAnchors ? nil : boardRect,
                anchorFrames: (anchorFrames ?? [:]).merging(builtInAnchorFrames) { foundFrame, _ in foundFrame },
                screenFrame: screenFrame,
                displayFrame: displayFrame
            )
            var narration: Task<Void, Never>?
            if let line = step.say {
                narration = Task { [weak self] in await self?.narrate(line) }
                teachingNarrationTask = narration
            }
            if var drawn = DottieTeaching.draw(step, in: space) {
                if step.kind == .text {
                    drawn = DottieTeaching.nudgedClearOfText(drawn, occupiedTextRects: occupiedTextRects)
                }
                occupiedTextRects += DottieTeaching.textRects(of: drawn.figures)
                let leadInSeconds = 0.4
                penTrace = DottiePenTrace(points: drawn.penPath, leadInSeconds: leadInSeconds, drawSeconds: drawn.duration,
                                          caption: step.caption.map(DottieMathText.prettyPlainText), displayFrame: displayFrame)
                try? await Task.sleep(nanoseconds: UInt64(leadInSeconds * 1_000_000_000))
                if Task.isCancelled { break }
                drawingOverlayManager.addFigures(drawn.figures, relaxingEarlierAccents: true)
                // Time to see it and read the caption before the next one.
                let captionSeconds = step.caption.map { min(2.0, 0.6 + Double($0.count) * 0.04) } ?? 0.3
                try? await Task.sleep(nanoseconds: UInt64((drawn.duration + captionSeconds) * 1_000_000_000))
            } else {
                missedSteps += 1
                DottieLog.notice("✏️ Couldn't draw a \(step.kind.rawValue) step: \(step.points)")
            }
            await narration?.value
        }

        // A stopped explanation was already tidied up, maybe with a new one
        // under way.
        guard !Task.isCancelled else { return }
        tidyUpAfterTeaching(plan: plan, generation: generation, missedSteps: missedSteps)
    }

    /// Where a teaching step's 0-1000 numbers land: on the turn's screen
    /// frame, or with no frame this turn (a typed ask) on the display being
    /// drawn on, instead of drawing nothing.
    private static func teachingSpace(
        boardRect: CGRect?,
        anchorFrames: [String: CGRect],
        screenFrame: CompanionCompositeScreenFrame?,
        displayFrame: CGRect
    ) -> DottieTeaching.Space {
        DottieTeaching.Space(boardRect: boardRect, anchorFrames: anchorFrames, screenPoint: { normalizedX, normalizedY in
            guard let resolved = screenFrame?.resolveNormalizedPoint(normalizedX: normalizedX, normalizedY: normalizedY) else {
                let clampedX = min(max(normalizedX, 0), 1000), clampedY = min(max(normalizedY, 0), 1000)
                return CGPoint(x: displayFrame.minX + clampedX / 1000 * displayFrame.width,
                               y: displayFrame.maxY - clampedY / 1000 * displayFrame.height)
            }
            return CompanionManager.globalScreenLocation(forScreenshotPixel: resolved.pointInScreenshotPixels, in: resolved.screenCapture)
        })
    }

    /// Waits (up to 8 seconds) for Live to finish what it is saying, so an
    /// explanation's drawing and speaking start together.
    private func waitUntilLiveIsQuiet() async {
        for _ in 0..<40 {
            if !(isLiveTurnInFlight || voiceState != .idle) || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// An explanation ran to its end: the pen goes away and the drawing
    /// fades (later when the plan asked to keep it up).
    private func tidyUpAfterTeaching(plan: DottieTeaching.Plan, generation: Int, missedSteps: Int) {
        penTrace = nil
        if generation == teachingGeneration {
            teachingTask = nil
            teachingNarrationTask = nil
        }
        if missedSteps > 0 {
            DottieLog.notice("✏️ \(missedSteps) of \(plan.steps.count) steps couldn't be drawn")
            // Live already said "watch", so the user hears the truth next
            // instead of being told it's all there.
            notesForNextLiveTurn.append("[note] \(missedSteps) of the \(plan.steps.count) steps of your last drawing couldn't be drawn (a thing to mark wasn't found on screen, or a point was off it). never say those parts were drawn; if they matter, draw them again on a board with numbers.")
            if missedSteps == plan.steps.count {
                notchPresenter.showCard(title: "drawing", text: "I couldn't draw that one. Ask me again and I'll put it on a board.")
            }
        }
        drawingOverlayManager.fadeFigures(after: plan.keepsDrawing ? 600 : 60)
        scheduleTransientHideIfNeeded()
    }

    /// Stops drawing an explanation. The drawing itself can stay up.
    func stopTeaching(clearingDrawing: Bool) {
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
    struct ScreenJob {
        let text: String
        var isGame = false
        var referenceImageNames: [String] = []
        /// Asked for by text: the result is texted back, not spoken.
        var repliesToPhone = false
        /// The user already said yes to starting over a matching job.
        var restart = true
        /// A saved replay the user asked for by name, run when the job starts.
        var replayID: UUID?
        /// A smart replay's closing line, said word for word when it finishes.
        var closingMessage: String?
        /// A commercial smart replay is being filmed: the cursor moves at a
        /// calm pace the viewer can follow.
        var isCommercial = false
        /// A helper asked for these on-screen steps (<SCREEN_JOB>): the
        /// result goes back to it instead of being said out loud.
        var returnsToHelperAgentID: UUID?
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
    func repeatedHelperTaskQuestion(for taskText: String) -> String? {
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
    func startScreenTask(_ job: ScreenJob) -> String {
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
        if DottieScreenLock.shared.isLocked {
            // macOS doesn't let anything see or click the screen while it's
            // locked; the job starts by itself on unlock.
            queuedScreenTasks.append(job)
            DottieFunPack.shared.noteScreenJobWaitingForUnlock(job.text)
            return "the mac's screen is locked, so this waits in line and starts by itself as soon as the user unlocks. say that in a few words."
        }
        if screenTaskRunner.isRunning {
            queuedScreenTasks.append(job)
            DottieLog.notice("🧭 Screen task queued (\(queuedScreenTasks.count) waiting): \(job.text)")
            refreshScreenTaskTitle()
            let position = queuedScreenTasks.count
            let runningJobText = currentScreenTaskText.map { "\"\($0.prefix(80))\"" } ?? "the current job"
            return "not started yet: it's waiting in line behind \(runningJobText)\(position > 1 ? " and \(position - 1) more" : ""). tell the user it's queued, not running, and ask in a few words if they want \(runningJobText) stopped so this one starts now (if yes, call stop_screen_task with current). each result comes to you as it finishes."
        }
        runScreenTask(job)
        return "started. say you're on it in a few words; you'll get the result to tell the user when it's done."
    }

    private func runScreenTask(_ job: ScreenJob) {
        let taskText = job.text
        stopGuide()
        DottieLog.notice("🧭 Screen task\(job.isGame ? " (game)" : ""): \(taskText)")
        showOverlayTransientlyIfNeeded()

        screenTaskRunner.onProgress = { [weak self] stepNumber, stepDescription in
            DottieLog.notice("🧭 Step \(stepNumber): \(stepDescription)")
            self?.lastScreenJobProgressAt = Date()
            self?.notchPresenter.showScreenTaskStep(stepDescription)
        }
        screenTaskRunner.onPlanChanged = { [weak self] steps, currentStepIndex in
            self?.notchPresenter.showScreenTaskPlan(steps, currentStepIndex: currentStepIndex)
        }
        screenTaskRunner.onAskUser = { [weak self] question, kind in
            self?.askUserForScreenJob(question, kind: kind, repliesToPhone: job.repliesToPhone)
        }
        screenTaskRunner.onThinkAloud = { [weak self] line in
            guard !job.repliesToPhone else { return }
            self?.speakWhenFree(
                recordedUserText: "(playing the game, thinking aloud)",
                instructionText: "you're playing a game for the user. say this in one short line, in your own voice, as if thinking out loud next to them: \"\(line)\". then stop talking. don't call any tool."
            )
        }
        screenTaskRunner.onSavePicture = { [weak self] imageData, name, description in
            guard let self,
                  let item = self.imageMemory.add(imageData: imageData, name: name, description: description, savedByDottie: true) else {
                return "couldn't save the picture."
            }
            return "saved as \"\(item.name)\" in the picture library."
        }
        screenTaskRunner.onWillClick = { [weak self] point, displayFrame in
            await DottieScreenLock.shared.waitUntilUnlocked()
            guard let self else { return }
            // Fly there first so the user sees what's about to be clicked.
            self.livePointingRefinementTask?.cancel()
            self.detectedElementScreenLocation = point
            self.detectedElementDisplayFrame = displayFrame
            // A replay already knows its target, so the flight is quicker.
            // A commercial run is filmed, so it lingers long enough to see.
            let pauseNanoseconds: UInt64 = job.isCommercial ? 1_200_000_000 : (self.screenTaskRunner.isReplaying ? 400_000_000 : 750_000_000)
            try? await Task.sleep(nanoseconds: pauseNanoseconds)
        }
        currentScreenTaskText = taskText
        currentScreenJob = job
        if let replayID = job.replayID {
            screenTaskRunner.requestedReplay = (id: replayID, taskText: taskText)
        }
        watchForStuckScreenJob(taskText: taskText)
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
            self?.finishScreenTask(taskText: taskText, outcome: outcome, repliesToPhone: job.repliesToPhone, closingMessage: job.closingMessage, returnsToHelperAgentID: job.returnsToHelperAgentID)
        }
    }

    /// A running job needs one thing from the user: Dottie asks it out
    /// loud (or by text for a job from the phone). The answer comes back
    /// through answer_screen_job, or the user's next turn (finishLiveTurn).
    /// Marks a job's second try in away mode, so it isn't retried again.
    private static let awayRetryMarker = "(second try while the user is away:"

    private func askUserForScreenJob(_ question: String, kind: String = "missing_info", repliesToPhone: Bool) {
        if repliesToPhone || DottieAwayMode.shared.questionsGoToPhone {
            // Passwords never go over Telegram: the job waits for the user
            // at the Mac instead, and the phone just hears why.
            if kind == "password" || kind == "do_it_yourself" {
                Task { await phoneBridge.send("A job needs you at the Mac for this, so it's waiting: \(question)") }
                DottieAwayMode.shared.record(.asked, title: "Waiting for you at the Mac", detail: question)
                return
            }
            Task {
                let answer = await DottieAwayMode.shared.askOnPhone(question, choices: kind == "confirm" ? ["Allow", "Deny"] : [])
                if let answer {
                    DottieScreenJobQuestions.shared.answer(answer)
                }
            }
            return
        }
        speakWhenFree(
            recordedUserText: "(job asks: \(question))",
            instructionText: "the on-screen job you're doing needs one thing from the user before it can carry on. ask them this in one short line, in your own voice: \"\(question)\". then stop talking. when they answer, call answer_screen_job with their answer, word for word. don't start a new job."
        )
    }

    private var currentScreenTaskText: String? {
        didSet { saveOpenScreenJobs() }
    }
    /// The running job, to put back in line if the screen locks.
    private var currentScreenJob: ScreenJob?

    // MARK: - Locked screen (DottieScreenLock)

    /// The screen locked mid-job: the job stops and goes back to the front
    /// of the line with a note to carry on from where it got to, and starts
    /// again on unlock. Returns the job's text, or nil if none was running.
    func pauseScreenJobForLock() -> String? {
        guard screenTaskRunner.isRunning, let runningText = currentScreenTaskText else { return nil }
        let runningJob = currentScreenJob ?? ScreenJob(text: runningText)
        screenTaskRunner.stop()
        currentScreenTaskText = nil
        currentScreenJob = nil
        notchPresenter.endScreenTask()
        clearDetectedElementLocation()
        let resumeNote = "\n\n(this job was paused partway when the screen locked. look at the screen first and carry on from where it got to; don't redo steps that are already done.)"
        let resumedText = runningJob.text.contains("paused partway when the screen locked") ? runningJob.text : runningJob.text + resumeNote
        queuedScreenTasks.insert(ScreenJob(
            text: resumedText,
            isGame: runningJob.isGame,
            referenceImageNames: runningJob.referenceImageNames,
            repliesToPhone: runningJob.repliesToPhone,
            restart: true
        ), at: 0)
        DottieLog.notice("🔒 Paused the screen job until unlock: \(runningText)")
        return runningText
    }

    /// The screen unlocked: waiting jobs start again.
    func resumeScreenJobsAfterUnlock() {
        startNextQueuedScreenTask()
    }

    /// Has Dottie say something on her own once she's free (games use it).
    func speakOnHerOwn(recordedUserText: String, instructionText: String) {
        speakWhenFree(recordedUserText: recordedUserText, instructionText: instructionText)
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
        guard !screenTaskRunner.isRunning, !queuedScreenTasks.isEmpty, !DottieScreenLock.shared.isLocked else { return }
        let nextJob = queuedScreenTasks.removeFirst()
        DottieLog.notice("🧭 Next queued screen task: \(nextJob.text)")
        runScreenTask(nextJob)
    }

    /// Stops the running job and drops every waiting one. Returns true if
    /// anything was running or waiting.
    @discardableResult
    func stopScreenTask() -> Bool {
        let hadQueuedTasks = !queuedScreenTasks.isEmpty
        for queuedTask in queuedScreenTasks {
            noteStoppedJob("the waiting on-screen job \"\(queuedTask.text)\"")
        }
        queuedScreenTasks.removeAll()
        let stoppedTaskText = currentScreenTaskText
        guard screenTaskRunner.stop() else { return hadQueuedTasks }
        currentScreenTaskText = nil
        noteStoppedJob("the on-screen job \"\(stoppedTaskText ?? "you started")\"")
        DottieLog.notice("🧭 Screen task stopped")
        notchPresenter.endScreenTask()
        clearDetectedElementLocation()
        scheduleTransientHideIfNeeded()
        return true
    }

    /// When the running job last showed a step, for the stuck-job watchdog.
    private var lastScreenJobProgressAt = Date()
    private var stuckScreenJobWatchdogTask: Task<Void, Never>?
    /// A job with no step for this long is stuck (a step that never comes
    /// back), so it's stopped and the line moves on.
    private static let secondsBeforeScreenJobCountsAsStuck: Double = 240

    private func watchForStuckScreenJob(taskText: String) {
        lastScreenJobProgressAt = Date()
        stuckScreenJobWatchdogTask?.cancel()
        stuckScreenJobWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.screenTaskRunner.isRunning, self.currentScreenTaskText == taskText else { return }
                // Waiting for the user's answer isn't being stuck.
                if DottieScreenJobQuestions.shared.isWaitingForAnswer {
                    self.lastScreenJobProgressAt = Date()
                    continue
                }
                guard Date().timeIntervalSince(self.lastScreenJobProgressAt) > Self.secondsBeforeScreenJobCountsAsStuck else { continue }
                DottieLog.notice("🧭 Screen task stuck with no step for \(Int(Self.secondsBeforeScreenJobCountsAsStuck)) s, stopping it: \(taskText)")
                self.noteStoppedJob("the on-screen job \"\(taskText)\" (it got stuck)")
                self.screenTaskRunner.stop()
                self.currentScreenTaskText = nil
                self.notchPresenter.endScreenTask()
                self.clearDetectedElementLocation()
                self.speakWhenFree(
                    recordedUserText: "(screen job stuck)",
                    instructionText: "the on-screen job \"\(taskText.prefix(120))\" got stuck with nothing happening for four minutes, so you stopped it\(self.queuedScreenTasks.isEmpty ? "" : " and started the next one in line"). tell the user that in one short sentence. don't call any tool."
                )
                if self.queuedScreenTasks.isEmpty {
                    self.scheduleTransientHideIfNeeded()
                } else {
                    self.startNextQueuedScreenTask()
                }
                return
            }
        }
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
    func screenTaskQueueSummary() -> String {
        var lines: [String] = []
        if screenTaskRunner.isRunning, let currentScreenTaskText {
            lines.append("doing now: \(currentScreenTaskText) (\(notchPresenter.screenTaskStepText))")
        }
        for (index, queuedTask) in queuedScreenTasks.enumerated() {
            lines.append("\(index + 1). next: \(queuedTask.text)")
        }
        return lines.isEmpty ? "no jobs running or waiting." : lines.joined(separator: "\n")
    }

    private func finishScreenTask(taskText: String, outcome: DottieScreenTaskRunner.Outcome, repliesToPhone: Bool = false, closingMessage: String? = nil, returnsToHelperAgentID: UUID? = nil) {
        currentScreenTaskText = nil
        notchPresenter.endScreenTask()
        clearDetectedElementLocation()
        let resultText: String
        switch outcome {
        case .finished(let answer):
            DottieLog.notice("🧭 Screen task finished: \(answer)")
            resultText = answer
            DottieLevels.shared.award(.screenJob)
            // "⚡ done from memory in 2.1s"
            if let replayReport = screenTaskRunner.lastReplayReport {
                notchPresenter.showAgentUpdate(title: replayReport, text: answer)
            }
        case .failed(let reason):
            DottieLog.notice("🧭 Screen task failed: \(reason)")
            // Away, nobody is there to say "try again", so a job that
            // failed gets one more go, told what went wrong, before the
            // failure is reported.
            if DottieAwayMode.shared.isAway, !taskText.contains(Self.awayRetryMarker) {
                let failedJob = (currentScreenJob?.text == taskText ? currentScreenJob : nil) ?? ScreenJob(text: taskText, repliesToPhone: repliesToPhone)
                let retryJob = ScreenJob(
                    text: taskText + "\n\n" + Self.awayRetryMarker + " the last try stopped because: \(reason). look at the screen first, keep what's already done, and take a different route this time (another menu, a keyboard shortcut, the app's search, a direct link, or closing whatever popup is in the way).",
                    isGame: failedJob.isGame,
                    referenceImageNames: failedJob.referenceImageNames,
                    repliesToPhone: failedJob.repliesToPhone,
                    restart: true,
                    closingMessage: failedJob.closingMessage,
                    returnsToHelperAgentID: failedJob.returnsToHelperAgentID
                )
                DottieAwayMode.shared.record(.note, title: "Trying again", detail: "\(taskText.prefix(200)) (stopped because: \(reason))")
                queuedScreenTasks.insert(retryJob, at: 0)
                startNextQueuedScreenTask()
                return
            }
            resultText = "it couldn't be finished: \(reason)"
        case .stopped:
            scheduleTransientHideIfNeeded()
            return
        }
        brain.record(.screenJob, "did on screen: \(taskText). result: \(resultText)")
        var jobSucceeded = false
        if case .finished = outcome { jobSucceeded = true }
        if DottieAwayMode.shared.isAway {
            let jobTitle = "On screen: " + String(taskText.components(separatedBy: Self.awayRetryMarker)[0].prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
            let succeeded = jobSucceeded
            Task {
                // A picture of where it got stuck says more than the reason.
                let failureScreenshot = succeeded ? nil : await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1280)?.jpegData
                DottieAwayMode.shared.noteResult(title: jobTitle, detail: resultText, succeeded: succeeded, screenshotJPEG: failureScreenshot, alreadyTextedToPhone: repliesToPhone)
            }
        }
        DottieEpisodicMemory.shared.recordScreenJob(taskText: taskText, resultText: resultText, succeeded: jobSucceeded)
        // The on-screen part a helper asked for: the helper gets the result
        // and finishes the task (its own reply comes back as usual).
        if let returnsToHelperAgentID, let requestingHelper = clickyRoster.agent(withID: returnsToHelperAgentID) {
            startNextQueuedScreenTask()
            scheduleTransientHideIfNeeded()
            let handBackText = jobSucceeded
                ? "Dottie did the on-screen part you asked for (\(taskText.prefix(300))). Result: \(resultText)\nCarry on and finish the task."
                : "Dottie tried the on-screen part you asked for (\(taskText.prefix(300))) and \(resultText). Try another route if there is one, otherwise finish with what you have and say what's missing."
            _ = clickyRoster.sendOrQueueMessage(handBackText, to: requestingHelper)
            return
        }
        // A smart replay's closing line only follows a run that worked.
        let closingMessageToSay = jobSucceeded ? closingMessage : nil
        if repliesToPhone {
            startNextQueuedScreenTask()
            scheduleTransientHideIfNeeded()
            let phoneText = closingMessageToSay.map { "\(resultText)\n\($0)" } ?? resultText
            Task { await phoneBridge.send(phoneText) }
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
            self?.speakScreenTaskResult(taskText: taskText, resultText: resultText, waitingCount: waitingCount, closingMessage: closingMessageToSay)
        }
    }

    /// Dottie says how the job went, as a turn of its own, so it reads like
    /// her answer and lands in the conversation history.
    func speakScreenTaskResult(taskText: String, resultText: String, waitingCount: Int = 0, closingMessage: String? = nil) {
        let nextLine = waitingCount == 0 ? "" : " you've already started the next job on the list (\(waitingCount) were waiting); you can mention you're moving on to it."
        var instructionText = "the on-screen job you started is finished. job: \"\(taskText)\". result: \(resultText)\n"
            + "tell the user the result now in one short, fun sentence. don't start the job again." + nextLine
        // The user typed this line for the end of every run of a smart
        // replay, so it's said exactly, in place of the usual result.
        if let closingMessage {
            instructionText = "the smart replay you were running is finished. say exactly this, word for word, and nothing else: \"\(closingMessage)\". don't start the job again." + nextLine
        }
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

    /// A walkthrough of Dottie's own app (DottieSelfKnowledge): its steps
    /// are known ahead, so there are no screenshots or model calls.
    func startSelfWalkthrough(goal: String, nextStep: @escaping @MainActor (Int) async -> DottieGuide.Step?) -> String {
        startGuide(goal: goal, modeName: DottieGuide.Mode.steps.rawValue, scriptedNextStep: nextStep)
    }

    private func startGuide(
        goal: String,
        modeName: String,
        scriptedNextStep: (@MainActor (Int) async -> DottieGuide.Step?)? = nil
    ) -> String {
        stopScreenTask()
        let mode = DottieGuide.Mode(rawValue: modeName.lowercased()) ?? .steps
        currentGuideGoal = goal
        DottieLog.notice("🧑‍🏫 Guide (\(mode.rawValue)): \(goal)")
        transientHideTask?.cancel()
        transientHideTask = nil
        showOverlayTransientlyIfNeeded()

        guide.onProgress = { [weak self] progressText in
            self?.notchPresenter.showScreenTaskStep(progressText, title: "showing you")
        }
        guide.presentStep = { [weak self] step in
            await self?.presentGuideStep(step)
        }
        guide.onStepTargetMissed = { [weak self] in
            guard let self else { return }
            self.guideGestureDemoTask?.cancel()
            self.guideGestureDemoTask = nil
            self.keepsPointingUntilCleared = false
            self.clearDetectedElementLocation()
            self.drawingOverlayManager.clear()
        }
        guide.onEnd = { [weak self] spokenGoodbye in
            self?.guideDidEnd(spokenGoodbye: spokenGoodbye)
        }
        notchPresenter.showScreenTaskStep("looking at your screen", title: "showing you")
        if let scriptedNextStep {
            guide.startScripted(goal: goal, nextStep: scriptedNextStep)
        } else {
            guide.start(goal: goal, mode: mode)
        }
        return mode == .tour
            ? "started the tour. say only a few words like 'okay, let me show you around'; each part's line comes to you next."
            : "started. say only a few words like 'let me show you'; each step's line comes to you next."
    }

    @discardableResult
    func stopGuide() -> Bool {
        let stoppedGoal = currentGuideGoal
        let didStop = guide.stop()
        if didStop {
            noteStoppedJob("the guide for \"\(stoppedGoal ?? "what you were showing")\"")
        }
        return didStop
    }

    /// Moves Dottie's cursor back and forth for a drag step, like a hand
    /// showing where to move something. Cancelled at every new step.
    private var guideGestureDemoTask: Task<Void, Never>?

    /// Draws the step's marks, points at its target, and says it.
    private func presentGuideStep(_ step: DottieGuide.Step) async {
        guideGestureDemoTask?.cancel()
        guideGestureDemoTask = nil
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
        if let caption = step.caption, step.targetRect != nil {
            detectedElementBubbleText = caption
        }
        if let gesture = step.gesture {
            presentGuideGesture(gesture, caption: step.caption, displayFrame: step.displayFrame)
        }
        notchPresenter.showScreenTaskStep(step.say, title: "showing you")
        await narrate(step.say)
    }

    /// Shows a step's motion the way a person's hand would: a drag gets a
    /// dashed arrow from the thing to where it goes and the cursor moving
    /// along it again and again; a scroll gets an arrow in its direction;
    /// a shortcut is written as key caps; typing shows the words by the field.
    private func presentGuideGesture(_ gesture: DottieGuide.Gesture, caption: String?, displayFrame: CGRect?) {
        let screenFrame = displayFrame
            ?? NSScreen.screens.first(where: { screen in
                (gesture.fromRect ?? gesture.toRect).map { screen.frame.intersects($0) } ?? false
            })?.frame
            ?? NSScreen.main?.frame
            ?? .zero
        detectedElementDisplayFrame = screenFrame
        switch gesture.kind {
        case .drag:
            guard let fromRect = gesture.fromRect, let toRect = gesture.toRect else { return }
            let startPoint = CGPoint(x: fromRect.midX, y: fromRect.midY)
            let endPoint = CGPoint(x: toRect.midX, y: toRect.midY)
            if !drawingOverlayManager.drawings.contains(where: { $0.targetRect.intersects(fromRect) }) {
                drawingOverlayManager.add(DottieDrawing(shape: .circle, targetRect: fromRect, note: nil), fadesOut: false)
            }
            drawingOverlayManager.add(DottieDrawing(shape: .box, targetRect: toRect, note: nil), fadesOut: false)
            // A gentle bow upward, so the arrow reads as a motion rather
            // than a line under the text.
            let distance = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
            let bowHeight = min(max(distance * 0.18, 30), 140)
            let middlePoint = CGPoint(x: (startPoint.x + endPoint.x) / 2, y: (startPoint.y + endPoint.y) / 2 + bowHeight)
            drawingOverlayManager.addFigures([
                DottieFigure(
                    shape: .stroke(points: [startPoint, middlePoint, endPoint], closed: false, smooth: true, dashed: true, arrowAtStart: false, arrowAtEnd: true),
                    ink: .gold, lineWidth: 4, delay: 0.2, drawDuration: 0.8
                )
            ])
            keepsPointingUntilCleared = true
            livePointingRefinementTask?.cancel()
            let grabText = caption ?? "drag this"
            guideGestureDemoTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.detectedElementBubbleText = grabText
                    self.detectedElementScreenLocation = startPoint
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    guard !Task.isCancelled else { return }
                    self.detectedElementBubbleText = "drop here"
                    self.detectedElementScreenLocation = endPoint
                    try? await Task.sleep(nanoseconds: 1_900_000_000)
                }
            }
        case .scroll:
            let areaRect = gesture.fromRect ?? screenFrame.insetBy(dx: screenFrame.width * 0.3, dy: screenFrame.height * 0.3)
            let centerPoint = CGPoint(x: areaRect.midX, y: areaRect.midY)
            let arrowHalfLength: CGFloat = 70
            // AppKit's y grows upward, so scrolling down points to lower y.
            let (startPoint, endPoint): (CGPoint, CGPoint) = {
                switch gesture.direction {
                case .down: return (CGPoint(x: centerPoint.x, y: centerPoint.y + arrowHalfLength), CGPoint(x: centerPoint.x, y: centerPoint.y - arrowHalfLength))
                case .up: return (CGPoint(x: centerPoint.x, y: centerPoint.y - arrowHalfLength), CGPoint(x: centerPoint.x, y: centerPoint.y + arrowHalfLength))
                case .left: return (CGPoint(x: centerPoint.x + arrowHalfLength, y: centerPoint.y), CGPoint(x: centerPoint.x - arrowHalfLength, y: centerPoint.y))
                case .right: return (CGPoint(x: centerPoint.x - arrowHalfLength, y: centerPoint.y), CGPoint(x: centerPoint.x + arrowHalfLength, y: centerPoint.y))
                }
            }()
            drawingOverlayManager.addFigures([
                DottieFigure(
                    shape: .stroke(points: [startPoint, endPoint], closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: true),
                    ink: .gold, lineWidth: 5, delay: 0.1, drawDuration: 0.5
                )
            ])
            keepsPointingUntilCleared = true
            livePointingRefinementTask?.cancel()
            detectedElementBubbleText = caption ?? "scroll \(gesture.direction.rawValue)"
            detectedElementScreenLocation = startPoint
        case .keys:
            guard let keysText = gesture.keys, !keysText.isEmpty else { return }
            let keyCapsText = Self.guideKeyCapsText(for: keysText)
            let fontSize: CGFloat = 64
            let estimatedTextWidth = CGFloat(keyCapsText.count) * fontSize * 0.55
            let textOrigin = CGPoint(x: screenFrame.midX - estimatedTextWidth / 2, y: screenFrame.minY + screenFrame.height * 0.22)
            drawingOverlayManager.addFigures([
                DottieFigure(shape: .text(keyCapsText, origin: textOrigin, fontSize: fontSize), ink: .gold, lineWidth: 3, delay: 0.1, drawDuration: 0.6)
            ])
            if let caption {
                drawingOverlayManager.addFigures([
                    DottieFigure(shape: .text(caption, origin: CGPoint(x: textOrigin.x, y: textOrigin.y - 56), fontSize: 30), ink: .white, lineWidth: 2, delay: 0.5, drawDuration: 0.5)
                ])
            }
        case .type:
            guard let typedText = gesture.text, !typedText.isEmpty else { return }
            if let fieldRect = gesture.fromRect {
                drawingOverlayManager.add(DottieDrawing(shape: .box, targetRect: fieldRect, note: nil), fadesOut: false)
                drawingOverlayManager.addFigures([
                    DottieFigure(
                        shape: .text("type \u{201C}\(typedText)\u{201D}", origin: CGPoint(x: fieldRect.maxX + 18, y: fieldRect.midY), fontSize: 28),
                        ink: .gold, lineWidth: 2, delay: 0.3, drawDuration: 0.6
                    )
                ])
                keepsPointingUntilCleared = true
                livePointingRefinementTask?.cancel()
                detectedElementBubbleText = caption ?? "type here"
                detectedElementScreenLocation = CGPoint(x: fieldRect.midX, y: fieldRect.midY)
            }
        }
    }

    /// "cmd+shift+N" → "⌘ ⇧ N", the way key caps are printed.
    private static func guideKeyCapsText(for keysText: String) -> String {
        let keySymbolsByName: [String: String] = [
            "cmd": "⌘", "command": "⌘", "shift": "⇧", "option": "⌥", "opt": "⌥", "alt": "⌥",
            "ctrl": "⌃", "control": "⌃", "return": "↩", "enter": "↩", "tab": "⇥", "esc": "esc",
            "escape": "esc", "delete": "⌫", "backspace": "⌫", "space": "space",
            "up": "↑", "down": "↓", "left": "←", "right": "→"
        ]
        let keyNames = keysText
            .split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" })
            .map { String($0) }
            .filter { !$0.isEmpty }
        return keyNames.map { keyName in
            keySymbolsByName[keyName.lowercased()] ?? keyName.uppercased()
        }.joined(separator: " ")
    }

    private func guideDidEnd(spokenGoodbye: String?) {
        DottieLog.notice("🧑‍🏫 Guide ended")
        guideGestureDemoTask?.cancel()
        guideGestureDemoTask = nil
        if let guideGoal = currentGuideGoal {
            brain.record(.guide, "showed the user how to: \(guideGoal)")
            currentGuideGoal = nil
            if spokenGoodbye != nil { DottieLevels.shared.award(.guide) }
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
    func refinedScreenLocation(
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
            DottieLog.notice("🎯 Live pointing ignored: no frame for this turn")
            return
        }

        let roughScreenLocation = Self.globalScreenLocation(
            forScreenshotPixel: resolvedPoint.pointInScreenshotPixels,
            in: resolvedPoint.screenCapture
        )
        let displayFrame = resolvedPoint.screenCapture.displayFrame
        ClickyAnalytics.trackElementPointed(elementLabel: pointRequest.elementLabel)
        DottieLog.notice("🎯 Live pointing: (\(Int(pointRequest.normalizedX)), \(Int(pointRequest.normalizedY)))/1000 → \"\(pointRequest.elementLabel ?? "element")\"")

        // Live's guess comes from a small frame; take a second, sharper look
        // before the cursor flies, so it lands on the thing itself.
        livePointingRefinementTask?.cancel()
        // What the Mac heard is the best description of what's wanted (Live's
        // own transcript only comes after its answer).
        let userQuestion = currentLiveTurnTypedText ?? currentLiveTurnOnDeviceText ?? ""
        let referenceImageJPEG = savedPictureJPEG(named: pointRequest.elementLabel)
        livePointingRefinementTask = Task { [weak self] in
            // When the sharper look is slow (a busy day for the free models),
            // the cursor doesn't wait any longer than usual: it flies to Live's
            // guess, and hops over to the real spot if that's found while it's
            // still pointing.
            let roughGuessFlight = Task { [weak self] () -> Bool in
                try? await Task.sleep(nanoseconds: UInt64(PointingRefiner.refinementTimeoutSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return false }
                self.detectedElementScreenLocation = roughScreenLocation
                self.detectedElementDisplayFrame = displayFrame
                return true
            }
            // A newer point request cancels this one, and its flight with it.
            let refinedScreenLocation = await withTaskCancellationHandler {
                await PointingRefiner.refine(
                    elementLabel: pointRequest.elementLabel,
                    userQuestion: userQuestion,
                    roughPoint: roughScreenLocation,
                    displayFrame: displayFrame,
                    referenceImageJPEG: referenceImageJPEG,
                    timeoutSeconds: Self.livePointingLateRefinementSeconds
                )
            } onCancel: {
                roughGuessFlight.cancel()
            }
            roughGuessFlight.cancel()
            let didFlyToRoughGuess = await roughGuessFlight.value
            guard let self, !Task.isCancelled else { return }
            // Still on the display the guess was on, or the guess wins.
            let foundScreenLocation = refinedScreenLocation.flatMap { displayFrame.insetBy(dx: -1, dy: -1).contains($0) ? $0 : nil }
            guard didFlyToRoughGuess else {
                self.detectedElementScreenLocation = foundScreenLocation ?? roughScreenLocation
                self.detectedElementDisplayFrame = displayFrame
                return
            }
            // Only while the cursor is still pointing at the guess (flying
            // back clears it), and only for a real correction.
            guard self.detectedElementScreenLocation == roughScreenLocation,
                  let foundScreenLocation,
                  hypot(foundScreenLocation.x - roughScreenLocation.x, foundScreenLocation.y - roughScreenLocation.y) > Self.livePointingSmallestCorrection else { return }
            DottieLog.notice("🎯 Pointing corrected after the rough guess: \(Int(roughScreenLocation.x)),\(Int(roughScreenLocation.y)) → \(Int(foundScreenLocation.x)),\(Int(foundScreenLocation.y))")
            self.detectedElementScreenLocation = foundScreenLocation
        }
    }

    /// How long a sharper look at a pointing target may run in all. The
    /// cursor flies to Live's guess after the usual wait
    /// (PointingRefiner.refinementTimeoutSeconds) and is still pointing
    /// there until about this long after the ask.
    private static let livePointingLateRefinementSeconds: TimeInterval = 9
    /// A late find closer than this to Live's guess isn't worth a hop.
    private static let livePointingSmallestCorrection: CGFloat = 24

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

    /// The Home → Conversation entry and words of the newest Live question,
    /// so its answer after a tool call lands on it and not on whatever was
    /// logged in between.
    private var lastLiveTurnConversationEntryID: UUID?
    private var lastLiveTurnUserTranscript = ""

    /// Records the exchange, then waits for the last of the audio to play
    /// before returning the cursor to idle.
    /// `isFollowUpAfterTools`: Live answered a tool result for a question
    /// already recorded; its words join that exchange instead of logging
    /// the question again.
    private func finishLiveTurn(userTranscript: String, modelTranscript: String, isFollowUpAfterTools: Bool = false) {
        liveVoiceClient.isAudioOutputMuted = false
        // The Mac already did this one and showed it; Live's answer was
        // silenced.
        if currentLiveTurnWasHandledInstantly {
            currentLiveTurnWasHandledInstantly = false
            currentLiveTurnTypedText = nil
            currentLiveTurnIsNarration = false
            return
        }
        let typedTextForThisTurn = currentLiveTurnTypedText
        currentLiveTurnTypedText = nil
        let isNarrationTurn = currentLiveTurnIsNarration
        currentLiveTurnIsNarration = false
        // A typed turn has no audio, so Live's input transcript is empty.
        let userTranscript = typedTextForThisTurn ?? userTranscript
        // A screen job asked something and Live didn't pass the reply on.
        if userTranscript.hasPrefix("(job asks:") {
            DottieScreenJobQuestions.shared.noteAskedAloud()
        } else if !isNarrationTurn, !userTranscript.isEmpty, !userTranscript.hasPrefix("("),
                  DottieScreenJobQuestions.shared.wasAskedAloud {
            DottieScreenJobQuestions.shared.answer(userTranscript)
        }

        // The secret phrase opens Home → Admin and stays out of history.
        let isSecretPhraseTurn = !isNarrationTurn
            && DottieAdminMode.shared.handleSecretPhraseIfSaid(userTranscript, companionManager: self)

        if isFollowUpAfterTools && !isNarrationTurn && !isSecretPhraseTurn {
            if !modelTranscript.isEmpty {
                brain.record(.chat, "dottie: \(modelTranscript)")
                conversationStore.extendEntry(withID: lastLiveTurnConversationEntryID, clickyText: modelTranscript)
                // The exchange this answer belongs to, even if an instant
                // command was logged after it while Live was still working.
                let exchangeIndex = conversationHistory.lastIndex(where: { $0.userTranscript == lastLiveTurnUserTranscript })
                    ?? (conversationHistory.isEmpty ? nil : conversationHistory.count - 1)
                if let exchangeIndex {
                    let exchangeToExtend = conversationHistory[exchangeIndex]
                    let combinedResponse = [exchangeToExtend.assistantResponse, modelTranscript].filter { !$0.isEmpty }.joined(separator: " ")
                    conversationHistory[exchangeIndex] = (userTranscript: exchangeToExtend.userTranscript, assistantResponse: combinedResponse)
                    liveVoiceClient.recentConversationHistory = conversationHistory.map { exchange in
                        (userTranscript: exchange.userTranscript, modelTranscript: exchange.assistantResponse)
                    }
                }
            }
        } else if !isNarrationTurn && !isSecretPhraseTurn && (!userTranscript.isEmpty || !modelTranscript.isEmpty) {
            brain.record(.chat, "user: \(userTranscript)\ndottie: \(modelTranscript)")
            lastLiveTurnConversationEntryID = conversationStore.append(
                userText: userTranscript,
                clickyText: modelTranscript,
                inputKind: typedTextForThisTurn == nil ? .voice : .typed,
                imageFileNames: typedTextForThisTurn == nil ? [] : currentTurnImageFileNames
            )
            lastLiveTurnUserTranscript = userTranscript
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

        let savedShortcutNote = (isNarrationTurn || isSecretPhraseTurn) ? nil : learnShortcutFromFinishedLiveTurn(
            userTranscript: userTranscript,
            typedText: typedTextForThisTurn,
            modelTranscript: modelTranscript
        )
        currentLiveTurnFinishedToolCalls = []
        currentLiveTurnNamedShortcutName = nil
        currentLiveTurnOnDeviceText = nil

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
                    self.notchPresenter.showFinishedResponse(
                        savedShortcutNote.map { modelTranscript + "\n\n" + $0 } ?? modelTranscript
                    )
                }
                self.scheduleTransientHideIfNeeded()
            }
            self.fireLiveTurnFinishedHandler()
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

    var isAnySpeechPlaying: Bool {
        switch voiceMode {
        case .live:
            return liveVoiceClient.isModelAudioPlaying
        case .classic:
            return DottieKokoroSpeaker.shared.isPlaying || geminiTTSClient.isPlaying || systemSpeechSynthesizer.isSpeaking
        }
    }

    func stopAllSpeechPlayback() {
        liveVoiceClient.interruptModelSpeech()
        if voiceMode == .classic {
            geminiTTSClient.stopPlayback()
        }
        DottieKokoroSpeaker.shared.stop()
        systemSpeechSynthesizer.stopSpeaking()
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for speech and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
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

    func speakWithSystemVoice(_ text: String) {
        systemSpeechSynthesizer.startSpeaking(text)
        voiceState = .responding
    }

    /// Gemini couldn't answer. When the ask was a Mac action (open an app,
    /// music, a reminder…), Needle does it anyway and says so; otherwise
    /// the usual "try again" line.
    func doOnMacOrSpeakConnectionError(requestText: String, inputKind: ConversationEntry.InputKind) {
        let trimmedRequestText = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequestText.isEmpty, isInstantLaneAllowedNow, DottieInstantLane.areInstantCommandsEnabled else {
            speakConnectionErrorFallback()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard let doneText = await DottieNeedleRouter.shared.doWhileGeminiIsDown(trimmedRequestText) else {
                self.speakConnectionErrorFallback()
                return
            }
            self.speakWithSystemVoice("Gemini isn't answering, but I did that on the Mac. " + doneText)
            self.finishInstantLaneTurn(userText: trimmedRequestText, doneText: doneText, inputKind: inputKind)
        }
    }

    private func speakConnectionErrorFallback() {
        let utterance = ClickyWorkerConfiguration.isWorkerConfigured
            ? "Gemini's swamped right now. Give it a second and try me again."
            : "I'm not connected yet. Open Settings, add the server address under Connection, and try again."
        speakWithSystemVoice(utterance)
    }
}
