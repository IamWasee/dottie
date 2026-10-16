//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Centralized PostHog analytics wrapper. All event names and properties
//  are defined here so instrumentation is consistent and easy to audit.
//

import Foundation
import PostHog

enum ClickyAnalytics {

    // MARK: - Setup

    /// Analytics are off unless you add your own PostHog project key as
    /// PostHogAPIKey in Info.plist (and optionally PostHogHost). v0 shipped
    /// Farza's key here; the clone never sends events to his project.
    private static var isEnabled = false

    static func configure() {
        guard let postHogAPIKey = AppBundleConfiguration.stringValue(forKey: "PostHogAPIKey") else {
            print("📊 Analytics: disabled (no PostHogAPIKey in Info.plist)")
            return
        }
        let postHogHost = AppBundleConfiguration.stringValue(forKey: "PostHogHost") ?? "https://us.i.posthog.com"
        PostHogSDK.shared.setup(PostHogConfig(apiKey: postHogAPIKey, host: postHogHost))
        isEnabled = true
    }

    static func identifyUser(email: String) {
        guard isEnabled else { return }
        PostHogSDK.shared.identify(email, userProperties: ["email": email])
    }

    private static func capture(_ eventName: String, properties: [String: Any]? = nil) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(eventName, properties: properties)
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        capture("app_opened", properties: [
            "app_version": version
        ])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        capture("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        capture("onboarding_replayed")
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        capture("onboarding_video_completed")
    }

    /// The 40s onboarding demo interaction where Clicky points at something.
    static func trackOnboardingDemoTriggered() {
        capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        capture("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        capture("push_to_talk_started")
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        capture("push_to_talk_released")
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
        capture("user_message_sent", properties: [
            "transcript": transcript,
            "character_count": transcript.count
        ])
    }

    /// The model responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        capture("ai_response_received", properties: [
            "response": response,
            "character_count": response.count
        ])
    }

    /// The response included a [POINT:x,y:label] coordinate tag,
    /// so the buddy is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
        capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown"
        ])
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        capture("response_error", properties: [
            "error": error
        ])
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        capture("tts_error", properties: [
            "error": error
        ])
    }

    // MARK: - Clone additions

    /// User pressed Escape to cut the companion off mid-answer.
    static func trackEscapeInterrupt() {
        capture("escape_interrupt")
    }

    /// Gemini Live handed a question to the stronger model.
    static func trackDictation(outcome: String, recordingSeconds: TimeInterval) {
        capture("dictation_finished", properties: [
            "outcome": outcome,
            "recording_seconds": Int(recordingSeconds.rounded())
        ])
    }

    static func trackClickyTaskStarted() {
        capture("clicky_task_started")
    }

    static func trackHigherModelHandoff() {
        capture("send_to_higher_model")
    }
}
