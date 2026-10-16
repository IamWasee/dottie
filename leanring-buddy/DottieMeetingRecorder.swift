//
//  DottieMeetingRecorder.swift
//  leanring-buddy
//
//  Meeting mode. Off until the user starts it (Home → Meetings, or asking
//  Dottie). While on, it hears the user's mic and the Mac's own audio (the
//  other people on the call), transcribes it every 45 seconds, and when it
//  stops writes a summary with decisions and action items. Each meeting is
//  saved as a Markdown file and in the second brain. Audio is never kept.
//

import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class DottieMeetingRecorder: ObservableObject {
    struct PastMeeting: Identifiable, Equatable {
        let fileURL: URL
        let title: String
        let date: Date
        var id: URL { fileURL }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isSummarizing = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var transcriptLines: [String] = []
    @Published private(set) var pastMeetings: [PastMeeting] = []
    @Published private(set) var statusNote: String?

    /// Called with the saved meeting once the summary is written.
    var onMeetingSaved: ((_ title: String, _ summary: String, _ fileURL: URL) -> Void)?

    nonisolated static let meetingsFolderURL: URL = {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL.appendingPathComponent("Dottie/Meetings", isDirectory: true)
    }()

    private static let transcriptionModel = "gemini-3.5-flash-lite"
    private static let summaryModel = "gemini-3.6-flash"
    private static let chunkSeconds: TimeInterval = 45
    private static let maximumDuration: TimeInterval = 3 * 3600
    /// Below this loudness a chunk is silence and isn't sent.
    private static let silenceLevel: Float = 0.002

    private let audioMixer = MeetingAudioMixer()
    private var captureStream: SCStream?
    private var streamOutput: MeetingStreamOutput?
    private var audioEngine: AVAudioEngine?
    private var chunkTimer: Timer?
    private var transcriptionChain: Task<Void, Never>?

    init() {
        try? FileManager.default.createDirectory(at: Self.meetingsFolderURL, withIntermediateDirectories: true)
        reloadPastMeetings()
    }

    // MARK: - Start and stop

    /// Starts taking notes. Returns a line for Dottie to say.
    @discardableResult
    func start() async -> String {
        guard !isRecording else { return "meeting notes are already on (\(elapsedText))." }
        guard !isSummarizing else { return "still writing up the last meeting; try again in a moment." }
        audioMixer.reset()
        transcriptLines = []
        statusNote = nil

        let isMicStarted = await startMicrophone()
        let isComputerAudioStarted = await startComputerAudio()
        guard isMicStarted || isComputerAudioStarted else {
            statusNote = "Dottie couldn't hear the mic or the Mac's audio. Check Microphone and Screen Recording in System Settings → Privacy & Security."
            return "couldn't start: Dottie can't hear the microphone or the Mac's audio. tell the user to check Microphone and Screen Recording permissions."
        }
        if !isComputerAudioStarted {
            statusNote = "Only hearing your mic. Allow Screen Recording for Dottie to also hear the other people on the call."
        } else if !isMicStarted {
            statusNote = "Only hearing the Mac's audio, not your mic."
        }

        isRecording = true
        startedAt = Date()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: Self.chunkSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleChunkTimer() }
        }
        return "meeting notes are on. i'll write everything down and summarize when you say stop." + (statusNote.map { " note: \($0)" } ?? "")
    }

    /// Stops, transcribes the last bit and writes the summary. Returns a
    /// line for Dottie to say right away; the summary arrives through
    /// onMeetingSaved.
    @discardableResult
    func stop() -> String {
        guard isRecording else { return "meeting notes weren't on." }
        let meetingStart = startedAt ?? Date()
        stopCapture()
        isRecording = false
        isSummarizing = true
        transcribeChunk(audioMixer.takeChunk())
        let chainToFinish = transcriptionChain
        Task { [weak self] in
            await chainToFinish?.value
            await self?.writeSummary(meetingStart: meetingStart)
        }
        return "stopped. writing up the notes now; i'll tell you when they're ready."
    }

    var elapsedText: String {
        guard let startedAt else { return "0 min" }
        return "\(max(0, Int(Date().timeIntervalSince(startedAt) / 60))) min"
    }

    /// For the voice tool's status.
    func statusSummary() -> String {
        if isRecording {
            let recentLines = transcriptLines.suffix(12).joined(separator: "\n")
            return "meeting notes are on, \(elapsedText) so far.\(recentLines.isEmpty ? " nothing transcribed yet." : " latest:\n\(recentLines)")"
        }
        if isSummarizing { return "the meeting stopped and its notes are being written." }
        return "meeting notes are off."
    }

    /// The newest saved meeting's notes, without the full transcript.
    func latestMeetingNotes() -> String {
        guard let latestMeeting = pastMeetings.first,
              let text = try? String(contentsOf: latestMeeting.fileURL, encoding: .utf8) else {
            return "no meetings saved yet."
        }
        let notes = text.components(separatedBy: "\n## Transcript").first ?? text
        return "latest meeting (\(latestMeeting.date.formatted(date: .abbreviated, time: .shortened))):\n" + DottieMacActions.shortened(notes, to: 4000)
    }

    // MARK: - Capture

    private func startMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return false }
        default:
            return false
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return false }
        audioMixer.installMicrophoneTap(on: inputNode, format: inputFormat)
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            print("⚠️ Meeting: mic failed to start: \(error)")
            return false
        }
        audioEngine = engine
        return true
    }

    private func startComputerAudio() async -> Bool {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = shareableContent.displays.first else { return false }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(MeetingAudioMixer.sampleRate)
            configuration.channelCount = 1
            // Video is required but unused: keep it tiny and rare.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let output = MeetingStreamOutput(mixer: audioMixer)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "dottie.meeting.audio"))
            try await stream.startCapture()
            captureStream = stream
            streamOutput = output
            return true
        } catch {
            print("⚠️ Meeting: computer audio failed to start: \(error)")
            return false
        }
    }

    private func stopCapture() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil
        if let captureStream {
            Task { try? await captureStream.stopCapture() }
        }
        captureStream = nil
        streamOutput = nil
    }

    private func handleChunkTimer() {
        guard isRecording else { return }
        if let startedAt, Date().timeIntervalSince(startedAt) > Self.maximumDuration {
            stop()
            return
        }
        transcribeChunk(audioMixer.takeChunk())
    }

    // MARK: - Transcription

    /// Chunks are transcribed one after another so lines stay in order.
    private func transcribeChunk(_ samples: [Float]) {
        guard !samples.isEmpty, Self.loudness(of: samples) > Self.silenceLevel else { return }
        let wavData = Self.wavData(from: samples)
        let chunkStart = Date().addingTimeInterval(-Double(samples.count) / MeetingAudioMixer.sampleRate)
        let previousChain = transcriptionChain
        transcriptionChain = Task { [weak self] in
            await previousChain?.value
            let transcript = await Self.transcribe(wavData)
            guard let self, let transcript else { return }
            let timeLabel = chunkStart.formatted(date: .omitted, time: .shortened)
            let newLines = transcript.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !newLines.isEmpty else { return }
            self.transcriptLines.append("[\(timeLabel)]")
            self.transcriptLines.append(contentsOf: newLines)
        }
    }

    private static func transcribe(_ wavData: Data) async -> String? {
        let requestBody: [String: Any] = [
            "model": transcriptionModel,
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "audio/wav", "data": wavData.base64EncodedString()]],
                    ["text": """
                    this is the latest \(Int(chunkSeconds)) seconds of a meeting or call the user is in: their microphone mixed with their computer's audio (the other people). transcribe what's said as short lines, one per speaker turn, like "Speaker 1: ...". use a person's name instead when someone says it clearly. leave out filler words and repeats. plain text only. if nothing intelligible is said, reply with exactly NOTHING.
                    """]
                ]
            ]]
        ]
        // One retry: the free tier is sometimes busy for a moment.
        for attempt in 1...2 {
            if let answer = await DottieChat.send(requestBody, timeout: 60) {
                return answer == "NOTHING" ? nil : answer
            }
            if attempt == 1 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        return nil
    }

    // MARK: - Summary

    private func writeSummary(meetingStart: Date) async {
        defer { isSummarizing = false }
        let transcript = transcriptLines.joined(separator: "\n")
        let minutes = max(1, Int(Date().timeIntervalSince(meetingStart) / 60))
        guard !transcriptLines.isEmpty else {
            statusNote = "Nothing was said that Dottie could hear, so no notes were saved."
            onMeetingSaved?("Meeting", "nothing was said that i could hear, so there are no notes.", Self.meetingsFolderURL)
            return
        }

        let prompt = """
        here's the transcript of a \(minutes)-minute meeting the user was in. write their notes in markdown with exactly these parts:
        first line: "# " and a short title for the meeting (a few words).
        ## Summary
        two to four sentences.
        ## Decisions
        bullets, or "None."
        ## Action items
        "- [ ] who: what (by when, if said)" bullets, or "None."
        ## Open questions
        bullets, or "None."
        keep it tight. don't invent anything that isn't in the transcript.

        transcript:
        \(transcript.suffix(120_000))
        """
        let summary = await DottieChat.ask(prompt, model: Self.summaryModel)
            ?? "# Meeting\n## Summary\nDottie couldn't write the summary (the AI was busy), but the full transcript is below."
        let title = summary.split(separator: "\n").first.map { $0.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces) } ?? "Meeting"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH.mm"
        let safeTitle = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(60)
        let fileURL = Self.meetingsFolderURL.appendingPathComponent("\(dateFormatter.string(from: meetingStart)) \(safeTitle).md")
        let header = "_\(meetingStart.formatted(date: .complete, time: .shortened)) · \(minutes) min_\n\n"
        let fileText = summary.replacingOccurrences(of: "\n", with: "\n" + header, options: [], range: summary.range(of: "\n"))
            + "\n\n## Transcript\n" + transcript + "\n"
        try? fileText.write(to: fileURL, atomically: true, encoding: .utf8)
        reloadPastMeetings()
        onMeetingSaved?(title, summary, fileURL)
    }

    func reloadPastMeetings() {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: Self.meetingsFolderURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        pastMeetings = fileURLs
            .filter { $0.pathExtension == "md" }
            .map { fileURL in
                let date = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                // "2026-10-16 14.30 Title.md" → "Title"
                let name = fileURL.deletingPathExtension().lastPathComponent
                let title = name.count > 17 ? String(name.dropFirst(17)) : name
                return PastMeeting(fileURL: fileURL, title: title, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Audio helpers

    private static func loudness(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    private static func wavData(from samples: [Float]) -> Data {
        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcmData.append(contentsOf: $0) }
        }
        return BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcmData, sampleRate: Int(MeetingAudioMixer.sampleRate))
    }
}

/// Collects mic and computer audio at 16 kHz mono from their own threads
/// and mixes them into one chunk on request.
final class MeetingAudioMixer: @unchecked Sendable {
    nonisolated static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var microphoneSamples: [Float] = []
    private var computerSamples: [Float] = []
    private var microphoneConverter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    nonisolated func reset() {
        lock.lock()
        microphoneSamples = []
        computerSamples = []
        lock.unlock()
    }

    nonisolated func takeChunk() -> [Float] {
        lock.lock()
        let microphone = microphoneSamples
        let computer = computerSamples
        microphoneSamples = []
        computerSamples = []
        lock.unlock()
        let length = max(microphone.count, computer.count)
        guard length > 0 else { return [] }
        var mixed = [Float](repeating: 0, count: length)
        for index in 0..<length {
            let microphoneSample = index < microphone.count ? microphone[index] : 0
            let computerSample = index < computer.count ? computer[index] : 0
            mixed[index] = max(-1, min(1, microphoneSample + computerSample))
        }
        return mixed
    }

    nonisolated func installMicrophoneTap(on inputNode: AVAudioInputNode, format inputFormat: AVAudioFormat) {
        microphoneConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.appendMicrophone(buffer)
        }
    }

    private nonisolated func appendMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard let microphoneConverter else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var didProvideInput = false
        var conversionError: NSError?
        microphoneConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channelData = outputBuffer.floatChannelData else { return }
        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
        lock.lock()
        microphoneSamples.append(contentsOf: samples)
        lock.unlock()
    }

    nonisolated func appendComputerAudio(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        if abs(sampleRate - Self.sampleRate) < 1 {
            computerSamples.append(contentsOf: samples)
            return
        }
        // Rarely needed: pick samples to land on 16 kHz.
        let step = sampleRate / Self.sampleRate
        var position = 0.0
        while Int(position) < samples.count {
            computerSamples.append(samples[Int(position)])
            position += step
        }
    }
}

/// Receives the Mac's own audio from ScreenCaptureKit.
final class MeetingStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let mixer: MeetingAudioMixer

    init(mixer: MeetingAudioMixer) {
        self.mixer = mixer
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        var sampleRate = MeetingAudioMixer.sampleRate
        if let formatDescription = sampleBuffer.formatDescription,
           let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
            sampleRate = streamDescription.pointee.mSampleRate
        }
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            // Non-interleaved float: the first buffer is the first channel.
            guard let firstBuffer = audioBufferList.first, let rawData = firstBuffer.mData else { return }
            let sampleCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: rawData.bindMemory(to: Float.self, capacity: sampleCount), count: sampleCount)
            mixer.appendComputerAudio(samples, sampleRate: sampleRate)
        }
    }
}
