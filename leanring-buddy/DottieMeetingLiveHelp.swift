//
//  DottieMeetingLiveHelp.swift
//  leanring-buddy
//
//  Live help during a meeting. While meeting mode runs, Apple's speech
//  recognizer writes down both sides of the call as they talk, kept apart
//  ("You" is the mic, "Them" is the Mac's own audio). When the other side
//  finishes a question, Dottie asks the AI what the user could say and
//  shows two or three short lines in the notch, without being asked and
//  without saying anything out loud. Every 30 seconds it also refreshes a
//  one-line note of what's being discussed. ⌘⇧Return (or "help me" on the
//  notch) asks right away.
//
//  Answers come from Groq first (very fast; the Worker's "provider": "groq")
//  and from Gemini when Groq isn't set up or is busy. A screenshot goes
//  along only when the screen changed since the last one sent (a new
//  slide, a shared doc). Nothing here is saved: the audio is only heard,
//  and the saved notes still come from DottieMeetingRecorder.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class DottieMeetingLiveHelp: ObservableObject {
    static let isEnabledDefaultsKey = "dottieMeetingLiveHelpOn"
    static let prepNotesDefaultsKey = "dottieMeetingPrepNotes"

    /// On unless the user turned it off in Home → Meetings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledDefaultsKey) as? Bool ?? true
    }

    /// What the user wrote for Dottie before the meeting (agenda, who
    /// they're meeting, things to push for).
    static var prepNotes: String {
        UserDefaults.standard.string(forKey: prepNotesDefaultsKey) ?? ""
    }

    struct LiveLine: Identifiable, Equatable {
        let id = UUID()
        let speakerName: String
        let text: String
        let spokenAt: Date
    }

    struct Suggestion: Equatable {
        /// What the other side asked, when a question set it off.
        let questionText: String?
        let suggestedLines: [String]
        let answeredAt: Date
    }

    @Published private(set) var isRunning = false
    @Published private(set) var liveLines: [LiveLine] = []
    @Published private(set) var latestSuggestion: Suggestion?
    @Published private(set) var talkingPointsText: String?
    @Published private(set) var isThinking = false
    @Published private(set) var statusNote: String?

    /// Called whenever there's something new to show in the notch.
    var onDisplayChanged: (() -> Void)?

    /// What's being said right now on each side, before the pause that
    /// ends it.
    var microphonePartialText: String { microphoneSide.partialText }
    var computerPartialText: String { computerSide.partialText }

    private static let youSpeakerName = "You"
    private static let themSpeakerName = "Them"
    /// Quiet this long after someone speaks ends what they said.
    private static let pauseSecondsEndingSpeech: TimeInterval = 0.7
    /// How much of the call goes with each ask.
    private static let transcriptWindowSeconds: TimeInterval = 120
    private static let maximumTranscriptCharacters = 4000
    private static let talkingPointsIntervalSeconds: TimeInterval = 30
    /// Asks a minute, all kinds together. Groq's free plan allows about
    /// 30 requests and 8,000 tokens a minute per model; an ask is about
    /// 1,500 tokens, more with a picture.
    private static let maximumAsksPerMinute = 8
    private static let minimumSecondsBetweenAsks: TimeInterval = 2.5
    /// Gemini answers when Groq isn't set up or is busy.
    private static let geminiBackupModel = "gemini-3.5-flash-lite"
    private static let askTimeoutSeconds: TimeInterval = 20
    /// Return, for ⌘⇧Return.
    private static let helpShortcutKeyCode: UInt16 = 36

    private let microphoneSide = MeetingLiveSpeechSide(speakerName: DottieMeetingLiveHelp.youSpeakerName)
    private let computerSide = MeetingLiveSpeechSide(speakerName: DottieMeetingLiveHelp.themSpeakerName)
    private var pauseCheckTimer: Timer?
    private var talkingPointsTimer: Timer?
    private var askTimesInLastMinute: [Date] = []
    private var askInFlight: Task<Void, Never>?
    /// A question that came in while another ask was running.
    private var waitingQuestionText: String?
    private var lineCountAtLastTalkingPoints = 0
    private var lastSentScreenFingerprint: [UInt8]?
    private var globalShortcutMonitor: Any?
    private var localShortcutMonitor: Any?

    // MARK: - Start and stop

    func start(audioMixer: MeetingAudioMixer) {
        stop(audioMixer: audioMixer)
        liveLines = []
        latestSuggestion = nil
        talkingPointsText = nil
        statusNote = nil
        lastSentScreenFingerprint = nil
        lineCountAtLastTalkingPoints = 0
        isRunning = true

        installHelpShortcut()
        startTimers()
        onDisplayChanged?()

        Task { [weak self] in
            guard let self else { return }
            guard await Self.speechRecognitionIsAllowed() else {
                self.statusNote = "Live help needs Speech Recognition: allow Dottie in System Settings → Privacy & Security → Speech Recognition. Notes are still being taken."
                self.onDisplayChanged?()
                return
            }
            guard self.isRunning else { return }
            self.microphoneSide.onSpeechEnded = { [weak self] spokenText in
                self?.handleFinishedSpeech(spokenText, speakerName: Self.youSpeakerName)
            }
            self.computerSide.onSpeechEnded = { [weak self] spokenText in
                self?.handleFinishedSpeech(spokenText, speakerName: Self.themSpeakerName)
            }
            self.microphoneSide.start()
            self.computerSide.start()
            let microphoneForwarder = self.microphoneSide.audioForwarder
            let computerForwarder = self.computerSide.audioForwarder
            audioMixer.setLiveListeners(
                // Sendable so they aren't tied to the main actor: they run
                // on the audio threads.
                microphone: { @Sendable samples in microphoneForwarder.send(samples) },
                computer: { @Sendable samples in computerForwarder.send(samples) }
            )
        }
    }

    func stop(audioMixer: MeetingAudioMixer) {
        audioMixer.setLiveListeners(microphone: nil, computer: nil)
        microphoneSide.stop()
        computerSide.stop()
        pauseCheckTimer?.invalidate()
        pauseCheckTimer = nil
        talkingPointsTimer?.invalidate()
        talkingPointsTimer = nil
        askInFlight?.cancel()
        askInFlight = nil
        waitingQuestionText = nil
        isThinking = false
        removeHelpShortcut()
        guard isRunning else { return }
        isRunning = false
        onDisplayChanged?()
    }

    /// ⌘⇧Return or the notch's "help me": answer the last thing said, or
    /// suggest what to say next.
    func askNow() {
        guard isRunning else { return }
        // Whatever is still being said counts as finished.
        microphoneSide.finishCurrentSpeech()
        computerSide.finishCurrentSpeech()
        ask(questionText: nil, isUserAsking: true)
    }

    // MARK: - Hearing

    private func startTimers() {
        let pauseTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.microphoneSide.finishSpeechIfPaused(pauseSeconds: Self.pauseSecondsEndingSpeech)
                self.computerSide.finishSpeechIfPaused(pauseSeconds: Self.pauseSecondsEndingSpeech)
            }
        }
        RunLoop.main.add(pauseTimer, forMode: .common)
        pauseCheckTimer = pauseTimer

        let pointsTimer = Timer(timeInterval: Self.talkingPointsIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTalkingPointsIfSomethingNew()
            }
        }
        RunLoop.main.add(pointsTimer, forMode: .common)
        talkingPointsTimer = pointsTimer
    }

    private func handleFinishedSpeech(_ spokenText: String, speakerName: String) {
        let trimmedText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !trimmedText.isEmpty else { return }
        liveLines.append(LiveLine(speakerName: speakerName, text: trimmedText, spokenAt: Date()))
        // Only the last few minutes are ever sent.
        let oldestKeptDate = Date().addingTimeInterval(-Self.transcriptWindowSeconds * 3)
        liveLines.removeAll { $0.spokenAt < oldestKeptDate }

        if speakerName == Self.themSpeakerName, Self.soundsLikeQuestion(trimmedText) {
            ask(questionText: trimmedText, isUserAsking: false)
        }
    }

    /// True when what the other side said ends in a question to the user.
    /// Apple's recognizer adds question marks; the opening words catch the
    /// questions it writes without one.
    static func soundsLikeQuestion(_ spokenText: String) -> Bool {
        let lowercasedText = spokenText.lowercased()
        let sentences = lowercasedText
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let lastSentence = sentences.last else { return false }
        let lastSentenceWordCount = lastSentence.split(separator: " ").count
        if lowercasedText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            return lastSentenceWordCount >= 2
        }
        guard lastSentenceWordCount >= 3 else { return false }
        let questionOpenings = [
            "what", "how", "why", "when", "where", "who", "which",
            "can you", "could you", "would you", "will you", "do you", "did you", "are you", "have you",
            "is there", "is it", "should we", "shall we", "tell me", "walk me through", "talk me through",
            "any thoughts", "thoughts on", "what about you", "how about you",
        ]
        let questionEndings = ["right", "yeah", "correct", "does that work", "make sense", "sound good", "you think"]
        return questionOpenings.contains { lastSentence.hasPrefix($0 + " ") || lastSentence == $0 }
            || questionEndings.contains { lastSentence.hasSuffix($0) }
    }

    // MARK: - Asking

    private func ask(questionText: String?, isUserAsking: Bool) {
        if askInFlight != nil {
            // The newest question wins; it runs once this ask is done.
            if let questionText { waitingQuestionText = questionText }
            return
        }
        let now = Date()
        askTimesInLastMinute.removeAll { now.timeIntervalSince($0) > 60 }
        if let lastAskTime = askTimesInLastMinute.last, now.timeIntervalSince(lastAskTime) < Self.minimumSecondsBetweenAsks, !isUserAsking {
            waitingQuestionText = questionText
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.minimumSecondsBetweenAsks * 1_000_000_000))
                self?.runWaitingQuestion()
            }
            return
        }
        guard isUserAsking || askTimesInLastMinute.count < Self.maximumAsksPerMinute else {
            print("🎧 Live help: skipped a question, \(askTimesInLastMinute.count) asks in the last minute already")
            return
        }
        askTimesInLastMinute.append(now)

        isThinking = true
        onDisplayChanged?()
        askInFlight = Task { [weak self] in
            guard let self else { return }
            let suggestedLines = await self.suggestAnswer(questionText: questionText)
            guard !Task.isCancelled, self.isRunning else { return }
            self.askInFlight = nil
            self.isThinking = false
            if let suggestedLines, !suggestedLines.isEmpty {
                self.latestSuggestion = Suggestion(questionText: questionText, suggestedLines: suggestedLines, answeredAt: Date())
            } else if isUserAsking {
                self.latestSuggestion = Suggestion(questionText: nil, suggestedLines: ["couldn't get a suggestion just now. try again in a moment."], answeredAt: Date())
            }
            self.onDisplayChanged?()
            self.runWaitingQuestion()
        }
    }

    private func runWaitingQuestion() {
        guard isRunning, askInFlight == nil, let waitingQuestionText else { return }
        self.waitingQuestionText = nil
        ask(questionText: waitingQuestionText, isUserAsking: false)
    }

    /// The last two minutes of the call as "You: …" / "Them: …" lines,
    /// with what's still being said at the end.
    private func recentTranscript() -> String {
        let oldestDate = Date().addingTimeInterval(-Self.transcriptWindowSeconds)
        var transcriptLines = liveLines
            .filter { $0.spokenAt >= oldestDate }
            .map { "\($0.speakerName): \($0.text)" }
        if !computerSide.partialText.isEmpty {
            transcriptLines.append("\(Self.themSpeakerName): \(computerSide.partialText)")
        }
        if !microphoneSide.partialText.isEmpty {
            transcriptLines.append("\(Self.youSpeakerName): \(microphoneSide.partialText)")
        }
        let transcript = transcriptLines.joined(separator: "\n")
        return transcript.count > Self.maximumTranscriptCharacters
            ? String(transcript.suffix(Self.maximumTranscriptCharacters))
            : transcript
    }

    private static let suggestionSystemInstruction = """
    you help the user during a live meeting or call. "You" is the user, "Them" is everyone else (the transcript comes from speech recognition, so expect small mistakes). when asked, suggest what the user could say next.
    reply with two or three lines, each starting with "- ", each under 15 words:
    the first line is the answer itself, in the user's voice, ready to say.
    the next lines are a supporting fact or number, or a good question back.
    use the user's prep notes and what's on their screen when they help. never invent facts about the user, numbers or promises; when you don't know, suggest how to answer honestly or what to ask. no intro, no labels.
    """

    private func suggestAnswer(questionText: String?) async -> [String]? {
        let transcript = recentTranscript()
        let prepNotes = Self.prepNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        var promptText = ""
        if !prepNotes.isEmpty {
            promptText += "the user's prep notes for this meeting:\n\(prepNotes.prefix(1500))\n\n"
        }
        promptText += "the last two minutes of the call:\n\(transcript.isEmpty ? "(nothing heard yet)" : transcript)\n\n"
        if let questionText {
            promptText += "they just asked: \"\(questionText)\". suggest the user's answer."
        } else {
            promptText += "the user asked for help right now: answer the last thing they were asked, or suggest what to say next."
        }

        var parts: [[String: Any]] = []
        if let screenJPEGData = await screenshotIfChanged() {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": screenJPEGData.base64EncodedString()]])
            promptText += " the picture is the user's screen right now."
        }
        parts.append(["text": promptText])

        guard let answerText = await Self.askFast(parts: parts, systemInstruction: Self.suggestionSystemInstruction, maximumAnswerTokens: 600) else {
            return nil
        }
        let suggestedLines = answerText
            .split(separator: "\n")
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-•*– "))
            }
            .filter { !$0.isEmpty }
        return Array(suggestedLines.prefix(3))
    }

    private func refreshTalkingPointsIfSomethingNew() {
        guard isRunning, askInFlight == nil, liveLines.count > lineCountAtLastTalkingPoints else { return }
        let now = Date()
        askTimesInLastMinute.removeAll { now.timeIntervalSince($0) > 60 }
        // Questions come first; a busy minute skips this round.
        guard askTimesInLastMinute.count < Self.maximumAsksPerMinute - 2 else { return }
        if let lastAskTime = askTimesInLastMinute.last, now.timeIntervalSince(lastAskTime) < 10 { return }
        askTimesInLastMinute.append(now)
        lineCountAtLastTalkingPoints = liveLines.count

        let transcript = recentTranscript()
        let promptText = """
        the last two minutes of a call the user is in ("You" is the user, "Them" is everyone else):
        \(transcript)

        in one line under 20 words: what's being discussed right now, and anything the user promised or still owes an answer on. no intro.
        """
        Task { [weak self] in
            guard let answerText = await Self.askFast(parts: [["text": promptText]], systemInstruction: nil, maximumAnswerTokens: 300) else { return }
            guard let self, self.isRunning else { return }
            let firstLine = answerText.split(separator: "\n").first.map(String.init) ?? answerText
            self.talkingPointsText = firstLine.trimmingCharacters(in: .whitespaces)
            self.onDisplayChanged?()
        }
    }

    /// One request through the Worker's /chat, Groq first.
    private static func askFast(parts: [[String: Any]], systemInstruction: String?, maximumAnswerTokens: Int) async -> String? {
        var requestBody: [String: Any] = [
            "provider": "groq",
            "model": geminiBackupModel,
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": maximumAnswerTokens, "temperature": 0.4]
        ]
        if let systemInstruction {
            requestBody["systemInstruction"] = ["parts": [["text": systemInstruction]]]
        }
        let answerText = await DottieChat.send(requestBody, timeout: askTimeoutSeconds)
        guard let answerText, !answerText.isEmpty else { return nil }
        return answerText
    }

    // MARK: - Screen

    /// A small screenshot when the screen looks different from the last one
    /// sent, else nil (the words alone are faster and cheaper).
    private func screenshotIfChanged() async -> Data? {
        guard let screenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1024) else { return nil }
        let fingerprint = Self.fingerprint(of: screenshot.image)
        if let lastSentScreenFingerprint, let fingerprint,
           Self.averageDifference(between: lastSentScreenFingerprint, and: fingerprint) < 6 {
            return nil
        }
        lastSentScreenFingerprint = fingerprint
        return screenshot.jpegData
    }

    /// The screen shrunk to 32×18 grey pixels: enough to notice a new slide,
    /// not a blinking cursor.
    private static func fingerprint(of image: CGImage) -> [UInt8]? {
        let fingerprintWidth = 32
        let fingerprintHeight = 18
        var pixels = [UInt8](repeating: 0, count: fingerprintWidth * fingerprintHeight)
        let didDraw = pixels.withUnsafeMutableBytes { pixelBytes -> Bool in
            guard let context = CGContext(
                data: pixelBytes.baseAddress,
                width: fingerprintWidth,
                height: fingerprintHeight,
                bitsPerComponent: 8,
                bytesPerRow: fingerprintWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: fingerprintWidth, height: fingerprintHeight))
            return true
        }
        return didDraw ? pixels : nil
    }

    private static func averageDifference(between firstFingerprint: [UInt8], and secondFingerprint: [UInt8]) -> Double {
        guard firstFingerprint.count == secondFingerprint.count, !firstFingerprint.isEmpty else { return 255 }
        var totalDifference = 0
        for index in firstFingerprint.indices {
            totalDifference += abs(Int(firstFingerprint[index]) - Int(secondFingerprint[index]))
        }
        return Double(totalDifference) / Double(firstFingerprint.count)
    }

    // MARK: - Shortcut

    /// ⌘⇧Return asks right away. Only watched while live help runs; the
    /// key still reaches the app in front.
    private func installHelpShortcut() {
        removeHelpShortcut()
        let isHelpShortcut: (NSEvent) -> Bool = { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            return event.keyCode == Self.helpShortcutKeyCode && modifiers == [.command, .shift] && !event.isARepeat
        }
        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isHelpShortcut(event) else { return }
            Task { @MainActor in self?.askNow() }
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isHelpShortcut(event) else { return event }
            Task { @MainActor in self?.askNow() }
            return nil
        }
    }

    private func removeHelpShortcut() {
        if let globalShortcutMonitor { NSEvent.removeMonitor(globalShortcutMonitor) }
        if let localShortcutMonitor { NSEvent.removeMonitor(localShortcutMonitor) }
        globalShortcutMonitor = nil
        localShortcutMonitor = nil
    }

    // MARK: - Permission

    private static func speechRecognitionIsAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            // The user just started meeting mode, so asking now makes sense.
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }
}

/// One side of the call (the mic or the Mac's audio) through Apple's speech
/// recognizer. What someone says ends at a pause: it's reported, and a new
/// recognition starts so the next thing they say begins fresh.
@MainActor
final class MeetingLiveSpeechSide {
    let speakerName: String
    nonisolated let audioForwarder = MeetingLiveAudioForwarder()

    /// What someone finished saying, at the pause after it.
    var onSpeechEnded: ((String) -> Void)?
    private(set) var partialText = ""

    /// Apple stops a recognition after about a minute, so a long speech is
    /// cut into pieces before that.
    private static let longestRecognitionSeconds: TimeInterval = 50

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionStartedAt = Date()
    private var partialTextChangedAt = Date()
    /// Results from a recognition that has since been replaced are ignored.
    private var currentRecognitionID = UUID()
    private var isStarted = false

    init(speakerName: String) {
        self.speakerName = speakerName
    }

    func start() {
        isStarted = true
        speechRecognizer = Self.makeSpeechRecognizer()
        startRecognition()
    }

    func stop() {
        isStarted = false
        currentRecognitionID = UUID()
        audioForwarder.detach()
        recognitionTask?.cancel()
        recognitionTask = nil
        partialText = ""
    }

    /// Reports what's been said so far when the speaker has been quiet for
    /// pauseSeconds (or has talked for nearly a minute straight).
    func finishSpeechIfPaused(pauseSeconds: TimeInterval) {
        guard isStarted else { return }
        let now = Date()
        if !partialText.isEmpty && now.timeIntervalSince(partialTextChangedAt) >= pauseSeconds {
            finishCurrentSpeech()
        } else if now.timeIntervalSince(recognitionStartedAt) >= Self.longestRecognitionSeconds {
            finishCurrentSpeech()
        }
    }

    func finishCurrentSpeech() {
        guard isStarted else { return }
        let finishedText = partialText
        partialText = ""
        startRecognition()
        if !finishedText.isEmpty {
            onSpeechEnded?(finishedText)
        }
    }

    private func startRecognition() {
        currentRecognitionID = UUID()
        audioForwarder.detach()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionStartedAt = Date()
        guard let speechRecognizer, speechRecognizer.isAvailable else { return }

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        let recognitionID = currentRecognitionID
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            let recognizedText = result?.bestTranscription.formattedString ?? ""
            let hasEnded = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.currentRecognitionID == recognitionID else { return }
                    if !recognizedText.isEmpty && recognizedText != self.partialText {
                        self.partialText = recognizedText
                        self.partialTextChangedAt = Date()
                    }
                    // The recognizer gave up (an error, or its own limit):
                    // keep what it heard and listen again.
                    if hasEnded {
                        // One that ends right away (no speech model yet,
                        // say) waits a moment instead of spinning.
                        if Date().timeIntervalSince(self.recognitionStartedAt) < 1 {
                            Task { @MainActor [weak self] in
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                guard let self, self.currentRecognitionID == recognitionID else { return }
                                self.finishCurrentSpeech()
                            }
                        } else {
                            self.finishCurrentSpeech()
                        }
                    }
                }
            }
        }
        audioForwarder.attach(recognitionRequest)
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

/// Turns 16 kHz samples from the audio threads into buffers for the
/// recognizer. Guards itself with a lock since both threads use it.
final class MeetingLiveAudioForwarder: @unchecked Sendable {
    private static let recognizerAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: MeetingAudioMixer.sampleRate,
        channels: 1,
        interleaved: false
    )!

    private let lock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    nonisolated func attach(_ recognitionRequest: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        self.recognitionRequest = recognitionRequest
        lock.unlock()
    }

    nonisolated func detach() {
        lock.lock()
        let detachedRequest = recognitionRequest
        recognitionRequest = nil
        lock.unlock()
        detachedRequest?.endAudio()
    }

    nonisolated func send(_ samples: [Float]) {
        lock.lock()
        let activeRequest = recognitionRequest
        lock.unlock()
        guard let activeRequest, !samples.isEmpty,
              let audioBuffer = AVAudioPCMBuffer(pcmFormat: Self.recognizerAudioFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = audioBuffer.floatChannelData else { return }
        audioBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { sampleBuffer in
            channelData[0].update(from: sampleBuffer.baseAddress!, count: samples.count)
        }
        activeRequest.append(audioBuffer)
    }
}
