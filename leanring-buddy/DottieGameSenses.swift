//
//  DottieGameSenses.swift
//  leanring-buddy
//
//  What the game player notices without asking any model, the way a person
//  glances at a screen and listens while playing:
//
//  - Reading: on-device text recognition of the HUD, prompts ("Press E"),
//    dialogue and menus, so the brain often gets text instead of needing
//    to look closely.
//  - Change: a tiny grayscale thumbnail per frame tells how much of the
//    picture changed, so a menu opening, a new area or a hit flash is an
//    event, and a picture that stops changing while walking means stuck.
//  - Motion: the last few frames, about a third of a second apart, so the
//    brain sees which way things move instead of one still.
//  - Sound: the game's own audio, for loud moments (an alert, a hit) and
//    spoken dialogue, transcribed on the Mac.
//

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech
import Vision

// MARK: - Reading and change

enum DottieGameVision {
    /// Text on screen, top to bottom, short lines dropped. Runs on the Mac.
    nonisolated static func readText(in image: CGImage) -> [String] {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        try? requestHandler.perform([textRequest])
        let observations = (textRequest.results ?? [])
            .filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.4 }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        return observations
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .prefix(40)
            .map { $0 }
    }

    /// 64×36 grayscale brightness values, for comparing frames.
    nonisolated static func thumbnail(of image: CGImage) -> [UInt8]? {
        let thumbnailWidth = 64
        let thumbnailHeight = 36
        var pixels = [UInt8](repeating: 0, count: thumbnailWidth * thumbnailHeight)
        let didDraw = pixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let context = CGContext(
                data: pixelBuffer.baseAddress,
                width: thumbnailWidth,
                height: thumbnailHeight,
                bitsPerComponent: 8,
                bytesPerRow: thumbnailWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailWidth, height: thumbnailHeight))
            return true
        }
        return didDraw ? pixels : nil
    }

    /// Share of the picture (0…1) that changed noticeably between two
    /// thumbnails.
    nonisolated static func changedShare(from previousThumbnail: [UInt8], to currentThumbnail: [UInt8]) -> Double {
        guard previousThumbnail.count == currentThumbnail.count, !currentThumbnail.isEmpty else { return 1 }
        var changedPixelCount = 0
        for pixelIndex in currentThumbnail.indices
        where abs(Int(currentThumbnail[pixelIndex]) - Int(previousThumbnail[pixelIndex])) > 18 {
            changedPixelCount += 1
        }
        return Double(changedPixelCount) / Double(currentThumbnail.count)
    }

    /// Average brightness 0…255, to notice flashes and fades.
    nonisolated static func averageBrightness(of thumbnail: [UInt8]) -> Double {
        guard !thumbnail.isEmpty else { return 0 }
        return Double(thumbnail.reduce(0) { $0 + Int($1) }) / Double(thumbnail.count)
    }

    /// A small JPEG of a frame, for the brain's pictures and the notebook.
    nonisolated static func jpegData(of image: CGImage, quality: Double = 0.7) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// A crop of `image` by a 0-1000 box [ymin, xmin, ymax, xmax].
    nonisolated static func crop(_ image: CGImage, box: [Double]) -> CGImage? {
        guard box.count == 4 else { return nil }
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let cropRect = CGRect(
            x: box[1] / 1000 * imageWidth,
            y: box[0] / 1000 * imageHeight,
            width: max(8, (box[3] - box[1]) / 1000 * imageWidth),
            height: max(8, (box[2] - box[0]) / 1000 * imageHeight)
        ).integral
        return image.cropping(to: cropRect)
    }
}

// MARK: - Sound

/// Listens to the game's sound while a game is played: how loud it is
/// right now (for alerts and hits) and what voices said lately.
@MainActor
final class DottieGameHearing {
    private var captureStream: SCStream?
    private var streamOutput: DottieGameAudioOutput?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Lines of dialogue heard lately, newest last.
    private(set) var recentDialogue: [String] = []
    private var lastPartialTranscript = ""

    /// Loudness 0…1 of the last moment of game sound.
    var currentLoudness: Double { streamOutput?.currentLoudness ?? 0 }

    func start() async {
        guard captureStream == nil else { return }
        let output = DottieGameAudioOutput()
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           let recognizer = SFSpeechRecognizer(), recognizer.isAvailable {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Never send the game's sound off the Mac.
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            speechRecognizer = recognizer
            recognitionRequest = request
            output.recognitionRequest = request
            // Sendable: Speech calls this on its own queue, not the main actor.
            recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, _ in
                guard let transcript = result?.bestTranscription.formattedString else { return }
                let isFinal = result?.isFinal ?? false
                Task { @MainActor in
                    self?.noteTranscript(transcript, isFinal: isFinal)
                }
            }
        }
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = shareableContent.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 16_000
            configuration.channelCount = 1
            // Video is required but unused: keep it tiny and rare.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "dottie.game.audio"))
            try await stream.startCapture()
            captureStream = stream
            streamOutput = output
        } catch {
            print("⚠️ Game: couldn't listen to the game's sound: \(error)")
        }
    }

    func stop() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        if let captureStream {
            Task { try? await captureStream.stopCapture() }
        }
        captureStream = nil
        streamOutput = nil
    }

    /// Dialogue heard since the last call, for the brain.
    func takeRecentDialogue() -> [String] {
        var dialogue = recentDialogue
        if !lastPartialTranscript.isEmpty {
            dialogue.append(lastPartialTranscript)
        }
        recentDialogue = []
        return dialogue
    }

    private func noteTranscript(_ transcript: String, isFinal: Bool) {
        let trimmedTranscript = String(transcript.suffix(300))
        if isFinal {
            recentDialogue.append(trimmedTranscript)
            recentDialogue = Array(recentDialogue.suffix(6))
            lastPartialTranscript = ""
        } else {
            lastPartialTranscript = trimmedTranscript
        }
    }
}

/// Receives the game's audio from ScreenCaptureKit on its own queue.
final class DottieGameAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var latestLoudness = 0.0
    nonisolated(unsafe) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    nonisolated var currentLoudness: Double {
        lock.lock()
        defer { lock.unlock() }
        return latestLoudness
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let firstBuffer = audioBufferList.first, let rawData = firstBuffer.mData else { return }
            let sampleCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }
            let samples = UnsafeBufferPointer(start: rawData.bindMemory(to: Float.self, capacity: sampleCount), count: sampleCount)
            var sumOfSquares: Float = 0
            for sample in samples {
                sumOfSquares += sample * sample
            }
            let rootMeanSquare = Double((sumOfSquares / Float(sampleCount)).squareRoot())
            lock.lock()
            latestLoudness = min(1, rootMeanSquare * 4)
            lock.unlock()
        }
    }
}
