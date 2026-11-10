//
//  GeminiLivePCMPlayer.swift
//  leanring-buddy
//
//  Plays Gemini Live's 24kHz mono PCM16 audio as it streams in, so the
//  answer starts before Gemini has finished saying it. Used by
//  GeminiLiveVoiceClient.
//

import AVFoundation
import Foundation

/// Plays Gemini Live's 24kHz mono PCM16 audio as it streams in.
@MainActor
final class GeminiLivePCMPlayer {
    private static let geminiOutputSampleRate: Double = 24_000

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: GeminiLivePCMPlayer.geminiOutputSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Number of buffers scheduled but not yet played. Playback counts as
    /// "playing" while this is above zero.
    private var scheduledBufferCount = 0
    /// Bumped on every stop so completions from flushed buffers are ignored.
    private var playbackGeneration = 0
    private var isEngineConfigured = false

    var isPlaying: Bool {
        scheduledBufferCount > 0
    }

    func enqueuePCM16Audio(_ pcm16AudioData: Data) {
        configureEngineIfNeeded()

        let sampleCount = pcm16AudioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let floatBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let floatChannelData = floatBuffer.floatChannelData?[0] else {
            return
        }
        floatBuffer.frameLength = AVAudioFrameCount(sampleCount)

        pcm16AudioData.withUnsafeBytes { rawBufferPointer in
            let int16Samples = rawBufferPointer.bindMemory(to: Int16.self)
            for sampleIndex in 0..<sampleCount {
                floatChannelData[sampleIndex] = Float(Int16(littleEndian: int16Samples[sampleIndex])) / Float(Int16.max)
            }
        }

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                DottieLog.warning("⚠️ Gemini Live player: engine failed to start: \(error)")
                return
            }
        }

        scheduledBufferCount += 1
        let generationAtSchedule = playbackGeneration
        playerNode.scheduleBuffer(floatBuffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generationAtSchedule else { return }
                self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func stopImmediately() {
        playbackGeneration += 1
        scheduledBufferCount = 0
        if isEngineConfigured {
            playerNode.stop()
        }
    }

    private func configureEngineIfNeeded() {
        guard !isEngineConfigured else { return }
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)
        audioEngine.prepare()
        isEngineConfigured = true
    }
}
