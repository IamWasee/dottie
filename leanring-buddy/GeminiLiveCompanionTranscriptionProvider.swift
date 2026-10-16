//
//  GeminiLiveCompanionTranscriptionProvider.swift
//  leanring-buddy
//
//  Plugs Gemini Live into v0's push-to-talk machinery. BuddyDictationManager
//  already owns the microphone, permissions, waveform levels and the
//  press/release lifecycle; it just expects a "transcription provider" to feed
//  audio into. This provider forwards that audio to the Live session instead
//  of to a speech-to-text service, so the mic code stays untouched.
//
//  "Final transcript" here is only informational (Gemini's transcription of
//  what the user said). The spoken answer comes back through the Live client
//  on its own, not through the dictation callbacks.
//

import AVFoundation
import Foundation

final class GeminiLiveCompanionTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Gemini Live"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { ClickyWorkerConfiguration.isWorkerConfigured }
    var unavailableExplanation: String? {
        isConfigured ? nil : "add the server address in Settings → Connection."
    }

    private let liveVoiceClient: GeminiLiveVoiceClient
    /// Called when a push-to-talk session opens. CompanionManager uses it to
    /// grab a screenshot and call liveVoiceClient.beginUserTurn.
    private let beginLiveTurn: @MainActor () async -> Void

    init(liveVoiceClient: GeminiLiveVoiceClient, beginLiveTurn: @escaping @MainActor () async -> Void) {
        self.liveVoiceClient = liveVoiceClient
        self.beginLiveTurn = beginLiveTurn
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw NSError(domain: "GeminiLive", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: unavailableExplanation ?? "worker not configured"])
        }

        await beginLiveTurn()

        let session = GeminiLiveCompanionStreamingSession(
            liveVoiceClient: liveVoiceClient,
            onFinalTranscriptReady: onFinalTranscriptReady
        )

        await MainActor.run {
            liveVoiceClient.onUserTranscriptUpdate = { userTranscriptSoFar in
                onTranscriptUpdate(userTranscriptSoFar)
                session.latestUserTranscript = userTranscriptSoFar
            }
        }

        return session
    }
}

private final class GeminiLiveCompanionStreamingSession: BuddyStreamingTranscriptionSession {
    /// Gemini's transcript of the user can lag the audio, and we don't need to
    /// wait for it: the answer is already on its way. Keep this short so the
    /// dictation UI hands back to the companion quickly.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 0.4

    /// Gemini Live wants 16kHz mono PCM16. Mic buffers arrive as ~20ms chunks;
    /// batching to ~100ms keeps the WebSocket from drowning in tiny messages.
    private static let liveInputSampleRate: Double = 16_000
    private static let minimumBytesPerSend = 3_200

    private let liveVoiceClient: GeminiLiveVoiceClient
    private let onFinalTranscriptReady: (String) -> Void
    private let pcm16AudioConverter = BuddyPCM16AudioConverter(targetSampleRate: liveInputSampleRate)

    private let stateLock = NSLock()
    private var pendingPCM16AudioData = Data()
    private var isForwardingAudio = true
    var latestUserTranscript = ""

    init(liveVoiceClient: GeminiLiveVoiceClient, onFinalTranscriptReady: @escaping (String) -> Void) {
        self.liveVoiceClient = liveVoiceClient
        self.onFinalTranscriptReady = onFinalTranscriptReady
    }

    /// Runs on the audio render thread.
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let pcm16AudioData = pcm16AudioConverter.convertToPCM16Data(from: audioBuffer) else { return }

        stateLock.lock()
        guard isForwardingAudio else {
            stateLock.unlock()
            return
        }
        pendingPCM16AudioData.append(pcm16AudioData)
        let shouldSend = pendingPCM16AudioData.count >= Self.minimumBytesPerSend
        let audioToSend = shouldSend ? pendingPCM16AudioData : Data()
        if shouldSend {
            pendingPCM16AudioData.removeAll(keepingCapacity: true)
        }
        stateLock.unlock()

        if shouldSend {
            liveVoiceClient.sendMicrophoneAudio(pcm16AudioData: audioToSend)
        }
    }

    /// Hotkey released: flush the tail of the audio and close the user's turn.
    func requestFinalTranscript() {
        let remainingAudio = stopForwardingAndTakeRemainingAudio()
        if !remainingAudio.isEmpty {
            liveVoiceClient.sendMicrophoneAudio(pcm16AudioData: remainingAudio)
        }

        Task { @MainActor in
            self.liveVoiceClient.endUserTurn()
            self.onFinalTranscriptReady(self.latestUserTranscript)
        }
    }

    /// Called both when the session finishes normally and when it's aborted.
    /// Either way the user's turn must be closed so the server isn't left
    /// waiting for activityEnd; endUserTurn ignores a second call.
    func cancel() {
        _ = stopForwardingAndTakeRemainingAudio()
        Task { @MainActor in
            self.liveVoiceClient.endUserTurn()
        }
    }

    private func stopForwardingAndTakeRemainingAudio() -> Data {
        stateLock.lock()
        defer { stateLock.unlock() }
        isForwardingAudio = false
        let remainingAudio = pendingPCM16AudioData
        pendingPCM16AudioData.removeAll()
        return remainingAudio
    }
}
