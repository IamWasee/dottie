//
//  DictationLiveTranscriber.swift
//  leanring-buddy
//
//  Shows your words in the notch while you're still dictating. Shipped
//  Clicky streams the recording to Deepgram and shows its interim results
//  (DictationStreamedTranscript); the clone has no Deepgram key, so it runs
//  Apple's speech recognizer on the Mac (on-device when available) next to
//  the recording and shows its partial results.
//
//  This used to be a listen-only Gemini Live session, but Live now only
//  transcribes the microphone after each pause and refuses sessions with
//  voice detection turned off, so the words never showed while talking.
//  The text that gets typed still comes from the Worker's /dictate cleanup,
//  so this is only ever a preview: if speech recognition isn't allowed or
//  available, dictation works the same without it.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class DictationLiveTranscriber {
    static let enabledDefaultsKey = "clickyDictationShowsLiveText"

    /// On unless the user turned it off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The transcript so far, each time it changes.
    var onPartialText: ((String) -> Void)?

    /// Takes microphone chunks from the audio thread.
    nonisolated let audioForwarder = DictationLiveAudioForwarder()
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Results from a session that has since been stopped are ignored.
    private var currentSessionID = UUID()

    // MARK: - Session

    func start() {
        stop()

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            // Ask once; the preview shows from the next dictation on.
            SFSpeechRecognizer.requestAuthorization { _ in }
            return
        default:
            // Not allowed: no preview, dictation is unaffected.
            return
        }

        guard let speechRecognizer = Self.makeSpeechRecognizer(), speechRecognizer.isAvailable else { return }

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        let sessionID = UUID()
        currentSessionID = sessionID
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, _ in
            guard let partialText = result?.bestTranscription.formattedString, !partialText.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.currentSessionID == sessionID else { return }
                    self.onPartialText?(partialText)
                }
            }
        }
        audioForwarder.attach(recognitionRequest)
    }

    /// Ends the preview; nothing more is reported for this dictation.
    func stop() {
        currentSessionID = UUID()
        audioForwarder.detach()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    /// A chunk of the recording (16kHz mono PCM16). Safe from the audio thread.
    nonisolated func sendAudio(_ pcm16AudioData: Data) {
        audioForwarder.send(pcm16AudioData)
    }

    /// The pinned dictation language when there is one, else the Mac's own.
    private static func makeSpeechRecognizer() -> SFSpeechRecognizer? {
        var preferredLocales: [Locale] = []
        if let pinnedLanguage = DictationLanguageCatalog.pinnedLanguage {
            preferredLocales.append(Locale(identifier: pinnedLanguage.code))
        }
        preferredLocales.append(Locale.autoupdatingCurrent)
        preferredLocales.append(Locale(identifier: "en-US"))

        for preferredLocale in preferredLocales {
            if let speechRecognizer = SFSpeechRecognizer(locale: preferredLocale) {
                return speechRecognizer
            }
        }
        return SFSpeechRecognizer()
    }
}

/// Converts microphone chunks into buffers for the recognizer. Called from
/// the audio thread and the main actor, so it guards itself with a lock.
final class DictationLiveAudioForwarder: @unchecked Sendable {
    private static let recognizerAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let lock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    func attach(_ recognitionRequest: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        self.recognitionRequest = recognitionRequest
        lock.unlock()
    }

    func detach() {
        lock.lock()
        let detachedRequest = recognitionRequest
        recognitionRequest = nil
        lock.unlock()
        detachedRequest?.endAudio()
    }

    func send(_ pcm16AudioData: Data) {
        lock.lock()
        let activeRequest = recognitionRequest
        lock.unlock()
        guard let activeRequest else { return }

        let sampleCount = pcm16AudioData.count / 2
        guard sampleCount > 0,
              let audioBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.recognizerAudioFormat,
                frameCapacity: AVAudioFrameCount(sampleCount)
              ),
              let floatSamples = audioBuffer.floatChannelData?[0] else { return }

        audioBuffer.frameLength = AVAudioFrameCount(sampleCount)
        pcm16AudioData.withUnsafeBytes { rawBytes in
            for sampleIndex in 0..<sampleCount {
                let sample = Int16(littleEndian: rawBytes.loadUnaligned(fromByteOffset: sampleIndex * 2, as: Int16.self))
                floatSamples[sampleIndex] = Float(sample) / 32_768
            }
        }
        activeRequest.append(audioBuffer)
    }
}
