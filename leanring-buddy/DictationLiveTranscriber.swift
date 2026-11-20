//
//  DictationLiveTranscriber.swift
//  leanring-buddy
//
//  Shows your words in the notch while you're still dictating. It runs
//  Apple's speech recognizer on the Mac (on-device when available) next to
//  the recording and shows its partial results.
//
//  Its final transcript is also what dictation types: dictation runs on
//  the Mac with no AI service. The user's own spellings are given to the
//  recognizer as contextual words.
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
    /// A session is listening (speech recognition is allowed and started).
    var isRunning: Bool { recognitionTask != nil }

    /// The newest transcript of the current session, "" before any.
    private(set) var latestText = ""
    private var hasFinalText = false
    /// Callers of finishAndWaitForFinalText still waiting.
    private var finalTextWaiters: [CheckedContinuation<String, Never>] = []

    // MARK: - Session

    /// asksForPermission false: when speech recognition was never allowed,
    /// quietly does nothing instead of showing macOS's prompt (talking to
    /// Dottie works without it; only the instant lane needs it).
    func start(asksForPermission: Bool = true) {
        stop()

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            // Ask once; the preview shows from the next dictation on.
            if asksForPermission {
                SFSpeechRecognizer.requestAuthorization { _ in }
            }
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
        recognitionRequest.contextualStrings = Array(ClickyDictationController.customWords.prefix(100))
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        let sessionID = UUID()
        currentSessionID = sessionID
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            let partialText = result?.bestTranscription.formattedString ?? ""
            let isFinalResult = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.currentSessionID == sessionID else { return }
                    if !partialText.isEmpty {
                        self.latestText = partialText
                        self.onPartialText?(partialText)
                    }
                    if isFinalResult {
                        self.hasFinalText = true
                        self.resumeFinalTextWaiters()
                    }
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
        resumeFinalTextWaiters()
        latestText = ""
        hasFinalText = false
    }

    /// The recording ended: waits (at most timeoutSeconds) for the
    /// recognizer's last word on it, then stops. Returns the transcript.
    func finishAndWaitForFinalText(timeoutSeconds: Double) async -> String {
        guard recognitionTask != nil else { return latestText }
        // Ending the audio makes the recognizer finish up.
        audioForwarder.detach()
        if !hasFinalText {
            let sessionID = currentSessionID
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                finalTextWaiters.append(continuation)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard let self, self.currentSessionID == sessionID else { return }
                    self.resumeFinalTextWaiters()
                }
            }
        }
        let finalText = latestText
        stop()
        return finalText
    }

    private func resumeFinalTextWaiters() {
        let waitingContinuations = finalTextWaiters
        finalTextWaiters = []
        for waitingContinuation in waitingContinuations {
            waitingContinuation.resume(returning: latestText)
        }
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
