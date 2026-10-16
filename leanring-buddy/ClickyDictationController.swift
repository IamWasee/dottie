//
//  ClickyDictationController.swift
//  leanring-buddy
//
//  Hold-to-dictate into any app. Shipped Clicky streams to Deepgram, runs an
//  LLM cleanup pass, then types the result into the focused field
//  (ClickyDictationController, DictationInsertion, DictationFocusContext).
//  The clone keeps one free key, so the Worker's /dictate route has Gemini
//  hear the recording and clean it up in a single call.
//
//  Flow: hold right Option → remember which field has focus and record →
//  let go → send the WAV to /dictate → paste the text into that field, or
//  copy it to the clipboard when the field can't take it.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import AVFoundation
import Combine
import Foundation

/// The field the user was in when they started dictating.
struct DictationFocusContext {
    /// The focused field itself, so the correction learner can watch it.
    let element: AXUIElement?
    let processIdentifier: pid_t
    let appName: String
    let role: String?
    let isEditable: Bool
    /// Up to 300 characters before the cursor, so the cleanup can continue
    /// the sentence with the right casing and spacing.
    let textBeforeCursor: String

    /// Reads the focused element through Accessibility. Returns the
    /// frontmost app with no editable field when nothing is focused.
    static func captureCurrent() -> DictationFocusContext? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = frontmostApplication.localizedName ?? "the current app"

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return DictationFocusContext(
                element: nil,
                processIdentifier: frontmostApplication.processIdentifier,
                appName: appName,
                role: nil,
                isEditable: false,
                textBeforeCursor: ""
            )
        }
        let focusedElement = focusedElementValue as! AXUIElement

        var elementProcessIdentifier: pid_t = frontmostApplication.processIdentifier
        AXUIElementGetPid(focusedElement, &elementProcessIdentifier)

        let role = stringAttribute(kAXRoleAttribute, of: focusedElement)
        let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var isValueSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &isValueSettable)
        let isEditable = editableRoles.contains(role ?? "") || isValueSettable.boolValue

        return DictationFocusContext(
            element: focusedElement,
            processIdentifier: elementProcessIdentifier,
            appName: NSRunningApplication(processIdentifier: elementProcessIdentifier)?.localizedName ?? appName,
            role: role,
            isEditable: isEditable,
            textBeforeCursor: isEditable ? textBeforeCursor(in: focusedElement) : ""
        )
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return nil }
        return attributeValue as? String
    }

    private static func textBeforeCursor(in element: AXUIElement) -> String {
        guard let fullText = stringAttribute(kAXValueAttribute, of: element), !fullText.isEmpty else { return "" }

        var selectedRangeValue: CFTypeRef?
        var cursorLocation = fullText.utf16.count
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue) == .success,
           let selectedRangeValue,
           CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() {
            var selectedRange = CFRange()
            if AXValueGetValue(selectedRangeValue as! AXValue, .cfRange, &selectedRange) {
                cursorLocation = min(max(0, selectedRange.location), fullText.utf16.count)
            }
        }

        let utf16Text = fullText.utf16
        let cursorIndex = utf16Text.index(utf16Text.startIndex, offsetBy: cursorLocation)
        let textUpToCursor = String(utf16Text[utf16Text.startIndex..<cursorIndex]) ?? ""
        return String(textUpToCursor.suffix(300))
    }
}

/// Records the microphone as 16kHz mono PCM16. Runs on the audio thread,
/// so it lives outside the main actor and guards its buffer with a lock.
private final class DictationAudioRecorder: @unchecked Sendable {
    static let sampleRate = 16_000
    /// Inline audio to Gemini is capped well under its request limit.
    private static let maximumRecordingBytes = sampleRate * 2 * 300

    private let audioEngine = AVAudioEngine()
    private let pcmConverter = BuddyPCM16AudioConverter(targetSampleRate: Double(sampleRate))
    private let bufferLock = NSLock()
    private var recordedPCMData = Data()
    var onAudioPowerLevel: (@Sendable (CGFloat) -> Void)?

    func start() throws {
        bufferLock.lock()
        recordedPCMData = Data()
        bufferLock.unlock()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] audioBuffer, _ in
            self?.append(audioBuffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Stops recording and returns everything recorded.
    func stop() -> Data {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return recordedPCMData
    }

    private func append(_ audioBuffer: AVAudioPCMBuffer) {
        if let channelSamples = audioBuffer.floatChannelData?[0], audioBuffer.frameLength > 0 {
            var sumOfSquares: Float = 0
            for sampleIndex in 0..<Int(audioBuffer.frameLength) {
                sumOfSquares += channelSamples[sampleIndex] * channelSamples[sampleIndex]
            }
            let rootMeanSquare = sqrt(sumOfSquares / Float(audioBuffer.frameLength))
            onAudioPowerLevel?(CGFloat(min(1, rootMeanSquare * 12)))
        }

        guard let pcmData = pcmConverter.convertToPCM16Data(from: audioBuffer) else { return }
        bufferLock.lock()
        if recordedPCMData.count + pcmData.count <= Self.maximumRecordingBytes {
            recordedPCMData.append(pcmData)
        }
        bufferLock.unlock()
    }
}

@MainActor
final class ClickyDictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    enum Outcome {
        /// Pasted into the field the user started in.
        case inserted
        /// The field couldn't take it (or the user moved on), so it's on
        /// the clipboard instead.
        case copiedToClipboard
    }

    private static let isEnabledDefaultsKey = "clickyDictationEnabled"
    static let customWordsDefaultsKey = "clickyDictationCustomWords"
    /// Shorter holds are accidental taps, not dictation.
    private static let minimumRecordingSeconds: TimeInterval = 0.35

    @Published private(set) var state: State = .idle
    @Published private(set) var audioPowerLevel: CGFloat = 0

    /// Called with what happened and the text, once dictation finishes.
    var onFinished: ((Outcome, String) -> Void)?
    var onError: ((String) -> Void)?

    private let audioRecorder = DictationAudioRecorder()
    private var focusContext: DictationFocusContext?
    private var recordingStartedAt: Date?
    private var transcriptionTask: Task<Void, Never>?

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: isEnabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: isEnabledDefaultsKey) }
    }

    /// The user's own spellings (names, jargon), typed into Settings. One
    /// per line or comma-separated.
    static var manualCustomWords: [String] {
        (UserDefaults.standard.string(forKey: customWordsDefaultsKey) ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Words from Settings plus the ones learned from fixes.
    static var customWords: [String] {
        var seenWords: Set<String> = []
        let learnedWords = DictationDictionary.shared.learnedCorrections.map(\.corrected)
        return (manualCustomWords + learnedWords).filter { seenWords.insert($0.lowercased()).inserted }
    }

    /// Watches the field after a paste and learns the words the user fixes.
    let correctionLearner = DictationCorrectionLearner()

    init() {
        audioRecorder.onAudioPowerLevel = { [weak self] powerLevel in
            DispatchQueue.main.async {
                self?.audioPowerLevel = powerLevel
            }
        }
    }

    // MARK: - Recording

    func beginDictation() {
        guard Self.isEnabled, state == .idle else { return }
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            onError?("Dottie isn't connected to its server yet. Add the server address in Settings → Connection.")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            onError?("Dottie needs microphone access to dictate. Turn it on in System Settings → Privacy & Security → Microphone.")
            return
        }

        // The previous paste's field is done being watched.
        correctionLearner.stopWatching()
        focusContext = DictationFocusContext.captureCurrent()
        do {
            try audioRecorder.start()
        } catch {
            onError?("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        recordingStartedAt = Date()
        state = .recording
    }

    func finishDictation() {
        guard state == .recording else { return }
        let recordedPCMData = audioRecorder.stop()
        audioPowerLevel = 0

        let recordingSeconds = Date().timeIntervalSince(recordingStartedAt ?? Date())
        guard recordingSeconds >= Self.minimumRecordingSeconds, !recordedPCMData.isEmpty else {
            state = .idle
            return
        }

        state = .transcribing
        let capturedFocusContext = focusContext
        let wavData = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: recordedPCMData, sampleRate: DictationAudioRecorder.sampleRate)

        transcriptionTask = Task { [weak self] in
            do {
                let dictatedText = try await Self.transcribe(wavData: wavData, focusContext: capturedFocusContext)
                guard let self, !Task.isCancelled else { return }
                self.state = .idle
                guard !dictatedText.isEmpty else { return }
                let outcome = DictationInsertion.deliver(dictatedText, into: capturedFocusContext)
                if outcome == .inserted, let capturedFocusContext {
                    self.correctionLearner.watch(insertedText: dictatedText, in: capturedFocusContext)
                }
                ClickyAnalytics.trackDictation(outcome: outcome == .inserted ? "inserted" : "clipboard", recordingSeconds: recordingSeconds)
                self.onFinished?(outcome, dictatedText)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .idle
                self.onError?("Dictation didn't go through: \(error.localizedDescription)")
            }
        }
    }

    /// Throws the recording away (a key was pressed mid-hold, or Escape).
    func cancelDictation() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if state == .recording {
            _ = audioRecorder.stop()
        }
        audioPowerLevel = 0
        state = .idle
    }

    // MARK: - Transcription

    private static func transcribe(wavData: Data, focusContext: DictationFocusContext?) async throws -> String {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/dictate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)

        var requestBody: [String: Any] = [
            "audio": wavData.base64EncodedString(),
            "mimeType": "audio/wav",
            "customWords": customWords,
            // Older Workers ignore this; the corrected words are in customWords too.
            "learnedCorrections": DictationDictionary.shared.learnedCorrections.prefix(100).map {
                ["heard": $0.original, "meant": $0.corrected]
            }
        ]
        if let pinnedLanguage = DictationLanguageCatalog.pinnedLanguage {
            requestBody["language"] = pinnedLanguage.englishName
        }
        if let focusContext {
            requestBody["appName"] = focusContext.appName
            if !focusContext.textBeforeCursor.isEmpty {
                requestBody["textBeforeCursor"] = focusContext.textBeforeCursor
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "ClickyDictation", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: "the worker answered \(statusCode)"
            ])
        }
        let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        return (responseObject?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Puts dictated text where the user was typing. Pastes with a temporary
/// clipboard swap (the most reliable way across native, web and Electron
/// apps) and puts the user's clipboard back afterwards.
enum DictationInsertion {
    @MainActor
    static func deliver(_ dictatedText: String, into focusContext: DictationFocusContext?) -> ClickyDictationController.Outcome {
        guard let focusContext, focusContext.isEditable,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focusContext.processIdentifier,
              // Password fields turn on secure input; never paste into those.
              !IsSecureEventInputEnabled() else {
            copyToClipboard(dictatedText)
            return .copiedToClipboard
        }

        pasteKeepingClipboard(textWithLeadingSpaceIfNeeded(dictatedText, after: focusContext.textBeforeCursor))
        return .inserted
    }

    /// Adds a space when continuing a sentence ("Hello there." + "How are you").
    private static func textWithLeadingSpaceIfNeeded(_ dictatedText: String, after textBeforeCursor: String) -> String {
        guard let lastCharacter = textBeforeCursor.last, !lastCharacter.isWhitespace,
              let firstCharacter = dictatedText.first, !",.;:!?)".contains(firstCharacter) else {
            return dictatedText
        }
        return " " + dictatedText
    }

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    private static func pasteKeepingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterOurWrite = pasteboard.changeCount

        postCommandV()

        // Give the target app time to read the clipboard, then restore the
        // user's own contents unless something else has replaced ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == changeCountAfterOurWrite else { return }
            pasteboard.clearContents()
            let restoredItems = savedItems.map { savedTypes -> NSPasteboardItem in
                let restoredItem = NSPasteboardItem()
                for (type, data) in savedTypes {
                    restoredItem.setData(data, forType: type)
                }
                return restoredItem
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    private static func postCommandV() {
        let vKeyCode: CGKeyCode = 9
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: vKeyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: vKeyCode, keyDown: false)
        keyDownEvent?.flags = .maskCommand
        keyUpEvent?.flags = .maskCommand
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
}
