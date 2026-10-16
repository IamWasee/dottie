//
//  GeminiTTSClient.swift
//  leanring-buddy
//
//  Text-to-speech for the classic (non-Live) voice mode. Replaces v0's
//  ElevenLabsTTSClient with the same surface (speakText / isPlaying /
//  stopPlayback). The Worker's /tts route returns raw 24kHz PCM, which we
//  wrap in a WAV header so AVAudioPlayer can play it.
//

import AVFoundation
import Foundation

@MainActor
final class GeminiTTSClient {
    private static let geminiTTSSampleRate = 24_000

    private let proxyURL: URL
    private let session: URLSession

    /// Kept alive so playback finishes even if the caller drops its reference.
    private var audioPlayer: AVAudioPlayer?

    init(proxyURL: URL) {
        self.proxyURL = proxyURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func speakText(_ text: String) async throws {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (pcmAudioData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: pcmAudioData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GeminiTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: pcmAudioData,
            sampleRate: Self.geminiTTSSampleRate
        )
        let player = try AVAudioPlayer(data: wavAudioData)
        self.audioPlayer = player
        player.play()
        print("🔊 Gemini TTS: playing \(pcmAudioData.count / 1024)KB audio")
    }

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
