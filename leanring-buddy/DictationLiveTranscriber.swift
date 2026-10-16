//
//  DictationLiveTranscriber.swift
//  leanring-buddy
//
//  Shows your words in the notch while you're still dictating. Shipped
//  Clicky streams the recording to Deepgram and shows its interim results
//  (DictationStreamedTranscript); the clone has no Deepgram key, so it opens
//  a listen-only Gemini Live session next to the recording and shows Live's
//  running transcript of the microphone.
//
//  The session only listens: voice detection is off and the user's turn is
//  opened with activityStart but never closed, so Gemini never answers. The
//  socket is dropped when dictation ends. The text that gets typed still
//  comes from the Worker's /dictate cleanup, so a slow or failed live
//  session only means no preview.
//

import Foundation

@MainActor
final class DictationLiveTranscriber {
    static let enabledDefaultsKey = "clickyDictationShowsLiveText"

    /// On unless the user turned it off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The transcript so far, each time it grows.
    var onPartialText: ((String) -> Void)?

    private static let liveWebSocketBaseURL =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
    private static let fallbackLiveModel = "gemini-3.8-live"

    private let urlSession = URLSession(configuration: .default)
    /// Takes microphone chunks from the audio thread.
    nonisolated let audioForwarder = DictationLiveAudioForwarder()
    private var connectionTask: Task<Void, Never>?
    private var webSocketTask: URLSessionWebSocketTask?
    private var partialText = ""

    // MARK: - Session

    func start() {
        stop()
        partialText = ""
        audioForwarder.reset()
        connectionTask = Task { [weak self] in
            do {
                try await self?.openSession()
            } catch {
                // A stopped session ends here too; only a real failure is news.
                guard !Task.isCancelled else { return }
                // No preview this time; the dictation itself is unaffected.
                print("⚠️ Dictation live text: \(error.localizedDescription)")
                self?.stop()
            }
        }
    }

    /// Drops the session without letting Gemini answer.
    func stop() {
        connectionTask?.cancel()
        connectionTask = nil
        audioForwarder.close()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    /// A chunk of the recording (16kHz mono PCM16). Safe from the audio thread.
    nonisolated func sendAudio(_ pcm16AudioData: Data) {
        audioForwarder.send(pcm16AudioData)
    }

    private func openSession() async throws {
        let (ephemeralToken, liveModel) = try await fetchEphemeralToken()
        try Task.checkCancellation()

        var urlComponents = URLComponents(string: Self.liveWebSocketBaseURL)!
        urlComponents.queryItems = [URLQueryItem(name: "access_token", value: ephemeralToken)]
        let newWebSocketTask = urlSession.webSocketTask(with: urlComponents.url!)
        webSocketTask = newWebSocketTask
        newWebSocketTask.resume()

        let setupMessage: [String: Any] = [
            "setup": [
                "model": "models/\(liveModel)",
                "generationConfig": ["responseModalities": ["AUDIO"]],
                "systemInstruction": ["parts": [["text": "Only listen. Never reply."]]],
                // The turn is opened by hand and never closed, so nothing is answered.
                "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
                "inputAudioTranscription": [String: Any]()
            ]
        ]
        let setupMessageData = try JSONSerialization.data(withJSONObject: setupMessage)
        try await newWebSocketTask.send(.string(String(decoding: setupMessageData, as: UTF8.self)))

        while !Task.isCancelled {
            let message = try await newWebSocketTask.receive()
            guard webSocketTask === newWebSocketTask else { return }
            let messageData: Data
            switch message {
            case .string(let messageText):
                messageData = Data(messageText.utf8)
            case .data(let binaryData):
                messageData = binaryData
            @unknown default:
                continue
            }
            guard let serverMessage = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else { continue }

            if serverMessage["setupComplete"] != nil {
                audioForwarder.markReady(newWebSocketTask)
            }
            if let serverContent = serverMessage["serverContent"] as? [String: Any],
               let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let transcriptChunk = inputTranscription["text"] as? String,
               !transcriptChunk.isEmpty {
                partialText += transcriptChunk
                onPartialText?(partialText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func fetchEphemeralToken() async throws -> (token: String, model: String) {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/live-token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
              let tokenPayload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let ephemeralToken = tokenPayload["token"] as? String else {
            throw NSError(domain: "DictationLiveTranscriber", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "couldn't get a live token"])
        }
        return (ephemeralToken, (tokenPayload["model"] as? String) ?? Self.fallbackLiveModel)
    }
}

/// Holds microphone chunks until the live session is ready, then sends
/// them in order after opening the user's turn. Called from the audio
/// thread and the main actor, so it guards itself with a lock.
final class DictationLiveAudioForwarder: @unchecked Sendable {
    /// About 10 seconds of audio; older chunks are dropped if setup is slow.
    private static let maximumPendingChunks = 300

    private let lock = NSLock()
    private var readyWebSocketTask: URLSessionWebSocketTask?
    private var pendingChunks: [Data] = []
    private var isClosed = false

    func reset() {
        lock.lock()
        readyWebSocketTask = nil
        pendingChunks = []
        isClosed = false
        lock.unlock()
    }

    func close() {
        lock.lock()
        readyWebSocketTask = nil
        pendingChunks = []
        isClosed = true
        lock.unlock()
    }

    func send(_ pcm16AudioData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        if let readyWebSocketTask {
            Self.sendAudioMessage(pcm16AudioData, over: readyWebSocketTask)
        } else {
            pendingChunks.append(pcm16AudioData)
            if pendingChunks.count > Self.maximumPendingChunks {
                pendingChunks.removeFirst(pendingChunks.count - Self.maximumPendingChunks)
            }
        }
    }

    /// Setup finished: open the user's turn, then send what was recorded so far.
    func markReady(_ webSocketTask: URLSessionWebSocketTask) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        Self.sendJSON(["realtimeInput": ["activityStart": [String: Any]()]], over: webSocketTask)
        for pendingChunk in pendingChunks {
            Self.sendAudioMessage(pendingChunk, over: webSocketTask)
        }
        pendingChunks = []
        readyWebSocketTask = webSocketTask
    }

    private static func sendAudioMessage(_ pcm16AudioData: Data, over webSocketTask: URLSessionWebSocketTask) {
        sendJSON([
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": pcm16AudioData.base64EncodedString()
                ]
            ]
        ], over: webSocketTask)
    }

    private static func sendJSON(_ message: [String: Any], over webSocketTask: URLSessionWebSocketTask) {
        guard let messageData = try? JSONSerialization.data(withJSONObject: message) else { return }
        webSocketTask.send(.string(String(decoding: messageData, as: UTF8.self))) { _ in }
    }
}
