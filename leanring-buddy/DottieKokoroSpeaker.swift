//
//  DottieKokoroSpeaker.swift
//  leanring-buddy
//
//  Dottie speaking on the Mac with Kokoro (82M, Apache-2.0) through
//  FluidAudio's Core ML build, so her spoken answers need no AI service.
//  The models download from Hugging Face the first time she speaks (then
//  load in about two seconds); until then, and if anything fails, the
//  caller falls back to the old voice. Used by classic mode and the voice
//  preview in Settings → Voice.
//

import AVFoundation
import Combine
import FluidAudio
import Foundation

@MainActor
final class DottieKokoroSpeaker: ObservableObject {
    static let shared = DottieKokoroSpeaker()

    /// The Kokoro voice that's speaking or loading, for Settings' play buttons.
    @Published private(set) var playingVoiceName: String?
    @Published private(set) var loadingVoiceName: String?

    private var kokoroManager: KokoroAneManager?
    private var managerReadyTask: Task<KokoroAneManager, Error>?
    /// Kept alive so playback finishes even if the caller drops its reference.
    private var audioPlayer: AVAudioPlayer?

    var isPlaying: Bool { audioPlayer?.isPlaying ?? false }

    /// Loads Kokoro once (downloading it the first time); later calls share it.
    private func readyManager() async throws -> KokoroAneManager {
        if let kokoroManager { return kokoroManager }
        if let managerReadyTask { return try await managerReadyTask.value }
        let loadingTask = Task<KokoroAneManager, Error> {
            // The newer, faster pipeline needs macOS 15; 14 gets the original one.
            let pipelineVersion: KokoroAneVersion
            if #available(macOS 15, *) {
                pipelineVersion = .v3
            } else {
                pipelineVersion = .legacy
            }
            let manager = KokoroAneManager(variant: .english, version: pipelineVersion)
            let loadStartedAt = Date()
            try await manager.initialize()
            DottieLog.notice("🗣️ Kokoro ready in \(String(format: "%.1f", Date().timeIntervalSince(loadStartedAt))) s")
            return manager
        }
        managerReadyTask = loadingTask
        do {
            let manager = try await loadingTask.value
            kokoroManager = manager
            return manager
        } catch {
            // A failed download is tried again next time, not remembered.
            managerReadyTask = nil
            throw error
        }
    }

    /// Starts loading Kokoro in the background, so the first answer isn't slow.
    func prepare() {
        Task { _ = try? await readyManager() }
    }

    /// Speaks `text` in the chosen (or given) voice. Throws when Kokoro
    /// can't, so the caller can use another voice.
    func speak(_ text: String, voice: DottieKokoroVoice = DottieKokoroVoices.chosenVoice()) async throws {
        guard let speakableText = DottieKokoroVoices.speakableText(text) else { return }
        loadingVoiceName = voice.name
        defer { if loadingVoiceName == voice.name { loadingVoiceName = nil } }
        let manager = try await readyManager()
        let synthesisStartedAt = Date()
        let wavAudioData = try await manager.synthesize(text: speakableText, voice: voice.kokoroVoiceID, speed: voice.speed)
        try Task.checkCancellation()
        DottieLog.notice("🗣️ Kokoro spoke \(speakableText.count) characters in \(String(format: "%.2f", Date().timeIntervalSince(synthesisStartedAt))) s")
        stop()
        let player = try AVAudioPlayer(data: wavAudioData)
        audioPlayer = player
        playingVoiceName = voice.name
        player.play()
        clearPlayingNameWhenDone(player: player)
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingVoiceName = nil
    }

    private func clearPlayingNameWhenDone(player: AVAudioPlayer) {
        Task { @MainActor [weak self] in
            while player.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self, self.audioPlayer === player else { return }
            self.playingVoiceName = nil
        }
    }

    /// Plays a short sample, or stops the one playing.
    func togglePreview(_ voice: DottieKokoroVoice) {
        if playingVoiceName == voice.name {
            stop()
            return
        }
        Task {
            do {
                try await speak("Hi, I'm Dottie. This is how I sound.", voice: voice)
            } catch {
                DottieLog.warning("⚠️ Kokoro preview failed: \(error.localizedDescription)")
            }
        }
    }
}
