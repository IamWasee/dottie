//
//  GeminiLiveVoiceClient.swift
//  leanring-buddy
//
//  The voice companion's brain: one Gemini Live WebSocket session that takes
//  the user's voice and a screenshot in, and streams spoken audio back. This
//  is the clone's stand-in for shipped Clicky's OpenAI Realtime client
//  (RealtimeVoiceClient), and it replaces v0's three-hop chain of
//  AssemblyAI speech-to-text → Claude → ElevenLabs text-to-speech.
//
//  How a push-to-talk turn flows:
//    1. Hotkey pressed → beginUserTurn(): connect if needed, then send one
//       screenshot frame as realtimeInput.video.
//    2. While held → sendMicrophoneAudio(): 16kHz PCM16 chunks.
//    3. Released → endUserTurn(): send any turn text, then a burst of
//       silence and audioStreamEnd. Gemini's voice detection hears the
//       silence as the end of speech and starts answering right away.
//
//  Gemini now rejects sessions that turn voice detection off ("Precondition
//  check failed"), so the turn can't be opened and closed with
//  activityStart/activityEnd any more; the silence burst stands in for it.
//  If a session drops before Gemini has answered anything, the turn is
//  replayed on a fresh session (on a backup Live model) instead of failing.
//    4. Server streams 24kHz PCM16 audio (played by GeminiLivePCMPlayer),
//       transcripts of both sides, and optional point_at_element tool calls
//       that make the blue cursor fly to something on screen.
//
//  Auth: the Gemini key never ships in the app. The Worker's /live-token
//  route mints a short-lived, single-use ephemeral token per connection.
//
//  Sessions with video input are capped at about two minutes, so we connect
//  on demand, drop the socket after a short idle period, and carry recent
//  conversation into the next session's system instruction.
//

import AVFoundation
import Foundation

/// A pointing request from the model, in the 0–1000 normalized coordinate
/// space of the composite screenshot frame it was sent.
struct GeminiLivePointRequest {
    let normalizedX: Double
    let normalizedY: Double
    let elementLabel: String?
}

@MainActor
final class GeminiLiveVoiceClient {
    enum ConnectionState {
        case disconnected
        case connecting
        case ready
    }

    private static let liveWebSocketBaseURL =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
    private static let fallbackLiveModel = "gemini-3.8-live"
    /// Used to replay a turn when a session on the main model drops before
    /// answering (gemini-3.8-live sometimes closes with "Internal error").
    private static let backupLiveModel = "gemini-3.1-flash-live-preview"
    /// Silence sent at the end of a turn so voice detection ends it now.
    /// Longer than silenceDurationMs below.
    private static let endOfTurnSilenceMilliseconds = 2500
    /// A pause this long while the key is still held also ends the turn.
    private static let voiceDetectionSilenceMilliseconds = 2000
    private static let maximumTurnReplays = 2
    private static let idleDisconnectDelaySeconds: TimeInterval = 45

    // MARK: - Callbacks (all delivered on the main actor)

    /// First audio chunk of a model turn arrived and is about to play.
    var onModelSpeechStarted: (@MainActor () -> Void)?
    /// The model finished its turn. Audio may still be draining from the player.
    var onModelTurnComplete: (@MainActor (_ userTranscript: String, _ modelTranscript: String) -> Void)?
    /// The model asked to point at something on screen.
    var onPointRequest: (@MainActor (GeminiLivePointRequest) -> Void)?
    /// Live partial transcript of what the model is saying (for captions).
    var onModelTranscriptUpdate: (@MainActor (String) -> Void)?
    /// Live partial transcript of what the user is saying.
    var onUserTranscriptUpdate: (@MainActor (String) -> Void)?
    /// Something went wrong mid-turn (network, auth, server closed).
    var onTurnError: (@MainActor (Error) -> Void)?
    /// The model handed a question to a stronger model (send_to_higher_model).
    /// Returns the text Live should speak. Runs while Live waits.
    var onHigherModelRequest: (@MainActor (_ question: String) async -> String)?
    /// The model handed a task to a background Clicky (start_clicky_task).
    /// Returns a short status for Live to relay; the work runs on its own.
    var onStartClickyTask: (@MainActor (_ clickyName: String?, _ task: String) -> String)?
    /// The model asked to click, type, press keys, scroll, open a page or
    /// draw on screen. Returns what happened, for the model to relay.
    var onScreenAction: (@MainActor (DottieScreenAction) async -> String)?
    /// The model handed a multi-step job on the screen to the task runner
    /// (do_task_on_screen). Returns a short status; the result is spoken
    /// in a later turn when the job finishes.
    var onStartScreenTask: (@MainActor (_ task: String) -> String)?
    /// The user asked to stop the running screen task (stop_screen_task).
    var onStopScreenTask: (@MainActor () -> String)?

    // MARK: - Configuration

    /// System prompt for every session. CompanionManager sets this once.
    var baseSystemInstruction: String = ""
    /// Recent (user, model) exchanges, appended to the system instruction of
    /// each new session so memory survives reconnects and relaunches.
    var recentConversationHistory: [(userTranscript: String, modelTranscript: String)] = []
    /// Prebuilt Gemini voice name (e.g. "Kore", "Puck"). Persisted by the panel.
    var voiceName: String = UserDefaults.standard.string(forKey: "selectedGeminiLiveVoice") ?? "Kore"

    // MARK: - State

    private(set) var connectionState: ConnectionState = .disconnected
    let audioPlayer = GeminiLivePCMPlayer()

    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Error>?
    private var idleDisconnectTask: Task<Void, Never>?
    private var responseWatchdogTask: Task<Void, Never>?
    private var lastServerMessageReceivedAt = Date.distantPast
    private static let responseTimeoutSeconds: TimeInterval = 20
    private var sessionResumptionHandle: String?

    /// Messages sent before setupComplete arrives are queued here so the user
    /// can start talking immediately on the first press, while the socket is
    /// still connecting. Guarded by the lock because mic audio arrives on the
    /// audio render thread.
    private let outgoingMessageLock = NSLock()
    private nonisolated(unsafe) var pendingOutgoingMessages: [String] = []
    private nonisolated(unsafe) var isSocketReadyForSending = false
    private nonisolated(unsafe) var activeWebSocketTaskForSending: URLSessionWebSocketTask?
    /// Everything sent during the current turn, kept so the turn can be
    /// replayed on a new session if this one drops before answering.
    /// Guarded by outgoingMessageLock.
    private nonisolated(unsafe) var currentTurnSentMessages: [String] = []
    private nonisolated(unsafe) var isRecordingCurrentTurnMessages = false
    private nonisolated static let maximumReplayableTurnMessages = 1500

    private var currentTurnUserTranscript = ""
    private var currentTurnModelTranscript = ""
    private var hasModelStartedSpeakingThisTurn = false
    /// Any audio, transcript or tool call from the model this turn. Until
    /// then a dropped session can be retried without the user noticing.
    private var hasReceivedModelContentThisTurn = false
    private var turnReplayCount = 0
    /// Set for a replay so the next session uses the backup model.
    private var shouldUseBackupLiveModel = false
    /// Text for the current turn, sent when the turn ends. Sent earlier,
    /// voice detection would answer the text before the user has spoken.
    private var pendingTurnContextTexts: [String] = []
    private var isUserTurnOpen = false
    private(set) var isModelTurnInProgress = false
    /// Set when the server sends goAway mid-turn: close as soon as the turn ends.
    private var shouldDisconnectAfterCurrentTurn = false
    /// Set by Escape: drop the rest of this answer's audio until the turn ends.
    private var isDiscardingModelAudioForCurrentTurn = false
    /// Tool calls still being worked on (e.g. a higher-model request). The
    /// response watchdog stays quiet while any are pending.
    private var pendingFunctionCallTasks: [String: Task<Void, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Turn API

    /// Opens a user turn: connects if needed, interrupts any answer still
    /// playing, and sends the screenshot frame for this turn.
    func beginUserTurn(screenFrameJPEGData: Data?) {
        cancelIdleDisconnect()
        audioPlayer.stopImmediately()

        // An answer still streaming would keep arriving until voice detection
        // notices the user talking. Starting a fresh session drops it at
        // once; the resumption handle carries the conversation over.
        if isModelTurnInProgress && connectionState != .disconnected {
            disconnect()
        }

        currentTurnUserTranscript = ""
        currentTurnModelTranscript = ""
        hasModelStartedSpeakingThisTurn = false
        hasReceivedModelContentThisTurn = false
        turnReplayCount = 0
        shouldUseBackupLiveModel = false
        pendingTurnContextTexts = []
        isDiscardingModelAudioForCurrentTurn = false
        cancelPendingFunctionCalls()
        isUserTurnOpen = true
        isModelTurnInProgress = true

        outgoingMessageLock.lock()
        currentTurnSentMessages = []
        isRecordingCurrentTurnMessages = true
        outgoingMessageLock.unlock()

        connectIfNeeded()

        if let screenFrameJPEGData {
            sendScreenFrame(jpegData: screenFrameJPEGData)
        }
    }

    /// Sends a JPEG frame of the screen. Called at turn start; can be called
    /// again mid-turn if the screen changes.
    func sendScreenFrame(jpegData: Data) {
        enqueueOrSend(message: [
            "realtimeInput": [
                "video": [
                    "mimeType": "image/jpeg",
                    "data": jpegData.base64EncodedString()
                ]
            ]
        ])
    }

    /// Extra text for the current turn, e.g. how a multi-screen frame is
    /// laid out, or a typed question. Held until the turn ends so it isn't
    /// answered on its own.
    func sendTurnContextText(_ contextText: String) {
        if isUserTurnOpen {
            pendingTurnContextTexts.append(contextText)
        } else {
            enqueueOrSend(message: ["realtimeInput": ["text": contextText]])
        }
    }

    /// Streams a chunk of 16kHz mono PCM16 mic audio. Safe to call from the
    /// audio thread.
    nonisolated func sendMicrophoneAudio(pcm16AudioData: Data) {
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": pcm16AudioData.base64EncodedString()
                ]
            ]
        ]
        enqueueOrSend(message: message)
    }

    /// Closes the user's turn. Gemini begins answering after this.
    func endUserTurn() {
        guard isUserTurnOpen else { return }
        isUserTurnOpen = false
        if !pendingTurnContextTexts.isEmpty {
            enqueueOrSend(message: ["realtimeInput": ["text": pendingTurnContextTexts.joined(separator: "\n\n")]])
            pendingTurnContextTexts = []
        }
        sendEndOfTurnSilence()
        enqueueOrSend(message: ["realtimeInput": ["audioStreamEnd": true]])
        startResponseWatchdog()
    }

    /// Voice detection ends a turn after a stretch of silence. Sending that
    /// silence all at once on release makes Gemini answer immediately
    /// instead of waiting for more audio that never comes.
    private func sendEndOfTurnSilence() {
        let chunkMilliseconds = 100
        let silentChunk = Data(count: 16 * 2 * chunkMilliseconds) // 16kHz mono PCM16
        for _ in 0..<(Self.endOfTurnSilenceMilliseconds / chunkMilliseconds) {
            sendMicrophoneAudio(pcm16AudioData: silentChunk)
        }
    }

    /// Stops the answer currently playing (e.g. user pressed the hotkey again
    /// or hit escape). beginUserTurn drops the session if it's still
    /// generating.
    func interruptModelSpeech() {
        audioPlayer.stopImmediately()
    }

    /// Escape pressed: silence the current answer and ignore whatever audio
    /// is still in flight for it. The session stays open; the turn finishes
    /// quietly on the server side.
    func cancelCurrentModelResponse() {
        isDiscardingModelAudioForCurrentTurn = true
        cancelPendingFunctionCalls()
        audioPlayer.stopImmediately()
    }

    var isModelAudioPlaying: Bool {
        audioPlayer.isPlaying
    }

    func disconnect() {
        cancelIdleDisconnect()
        cancelPendingFunctionCalls()
        responseWatchdogTask?.cancel()
        connectionTask?.cancel()
        connectionTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
        shouldDisconnectAfterCurrentTurn = false

        outgoingMessageLock.lock()
        isSocketReadyForSending = false
        activeWebSocketTaskForSending = nil
        pendingOutgoingMessages.removeAll()
        isRecordingCurrentTurnMessages = false
        outgoingMessageLock.unlock()
    }

    // MARK: - Connection

    private func connectIfNeeded() {
        guard connectionState == .disconnected else { return }
        connectionState = .connecting

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.openSession()
            } catch {
                print("⚠️ Gemini Live: connection failed: \(error)")
                self.handleConnectionLost(error: error)
            }
        }
    }

    private func openSession() async throws {
        let (ephemeralToken, tokenLiveModel) = try await fetchEphemeralToken()
        try Task.checkCancellation()
        let liveModel = shouldUseBackupLiveModel ? Self.backupLiveModel : tokenLiveModel

        var urlComponents = URLComponents(string: Self.liveWebSocketBaseURL)!
        urlComponents.queryItems = [URLQueryItem(name: "access_token", value: ephemeralToken)]
        let newWebSocketTask = urlSession.webSocketTask(with: urlComponents.url!)
        // Model audio chunks can be large; raise the default 1MB frame limit.
        newWebSocketTask.maximumMessageSize = 16 * 1024 * 1024
        webSocketTask = newWebSocketTask
        newWebSocketTask.resume()

        // The setup message must be the first thing on the wire, so it goes
        // straight to the socket, bypassing the pending queue.
        let setupMessageData = try JSONSerialization.data(withJSONObject: buildSetupMessage(liveModel: liveModel))
        try await newWebSocketTask.send(.string(String(decoding: setupMessageData, as: UTF8.self)))
        print("🔌 Gemini Live: setup sent (model \(liveModel), voice \(voiceName))")

        startReceiveLoop(for: newWebSocketTask)
    }

    private func fetchEphemeralToken() async throws -> (token: String, model: String) {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/live-token"))
        request.httpMethod = "POST"
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "GeminiLive", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "live token request failed: \(errorBody)"])
        }

        guard let tokenPayload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let ephemeralToken = tokenPayload["token"] as? String else {
            throw NSError(domain: "GeminiLive", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "live token response had no token"])
        }
        let liveModel = (tokenPayload["model"] as? String) ?? Self.fallbackLiveModel
        return (ephemeralToken, liveModel)
    }

    private func buildSetupMessage(liveModel: String) -> [String: Any] {
        var setup: [String: Any] = [
            "model": "models/\(liveModel)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]]
                ]
            ],
            "systemInstruction": ["parts": [["text": composeSystemInstruction()]]],
            // No googleSearch tool: on a free-tier key, Live closes the
            // session with "You exceeded your current quota" when it's set.
            // search_web goes through the Worker instead (DottieWebSearch).
            "tools": [
                ["functionDeclarations": Self.coreFunctionDeclarations + DottieScreenAction.functionDeclarations]
            ],
            // Voice detection stays on (Gemini rejects turning it off). A
            // low end sensitivity and a long silence window keep it from
            // cutting the user off mid-thought; endUserTurn's silence burst
            // ends the turn on release.
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                    "silenceDurationMs": Self.voiceDetectionSilenceMilliseconds
                ]
            ],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            // Lets sessions run past the raw context limit by dropping the
            // oldest turns, mostly old screenshot frames.
            "contextWindowCompression": ["slidingWindow": [String: Any]()]
        ]

        var sessionResumptionConfig: [String: Any] = [:]
        if let sessionResumptionHandle {
            sessionResumptionConfig["handle"] = sessionResumptionHandle
        }
        setup["sessionResumption"] = sessionResumptionConfig

        return ["setup": setup]
    }

    private func composeSystemInstruction() -> String {
        guard !recentConversationHistory.isEmpty else { return baseSystemInstruction }

        let historyLines = recentConversationHistory.map { exchange in
            "user: \(exchange.userTranscript)\nyou: \(exchange.modelTranscript)"
        }.joined(separator: "\n")

        return baseSystemInstruction + """


        recent conversation with this user, oldest first (it may be from earlier days; remember what they told you, like their name):
        \(historyLines)
        """
    }

    /// Tool the model calls to make the blue cursor fly to a UI element.
    /// Coordinates are 0–1000 normalized on the frame, which is the space
    /// Gemini's vision models are trained to point in.
    private static let pointAtElementFunctionDeclaration: [String: Any] = [
        "name": "point_at_element",
        "description": "Fly the user's blue companion cursor to a specific UI element visible in the most recent screen frame. Use it whenever pointing at something on screen would help: a button, menu, field, icon, or area the user is asking about. Call it at most once per answer, before or while you speak.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "x": [
                    "type": "INTEGER",
                    "description": "Horizontal position of the element's center, normalized 0 (left edge of the frame) to 1000 (right edge)."
                ],
                "y": [
                    "type": "INTEGER",
                    "description": "Vertical position of the element's center, normalized 0 (top edge of the frame) to 1000 (bottom edge)."
                ],
                "label": [
                    "type": "STRING",
                    "description": "The element's visible text or name, exactly as it appears on screen when it has text (like 'Sign in' or 'Downloads'), else a 1-3 word name like 'download icon'. The app uses it to find the exact spot."
                ]
            ],
            "required": ["x", "y", "label"]
        ]
    ]

    /// Mirrors shipped Clicky's send_to_higher_model: the fast voice model
    /// hands off questions that need careful reading or reasoning.
    private static let sendToHigherModelFunctionDeclaration: [String: Any] = [
        "name": "send_to_higher_model",
        "description": "Hand a question to a slower, smarter model that gets fresh full-resolution screenshots of every screen. Use it when the answer needs careful reading of small text, code, a long document or dense UI, multi-step reasoning, math, or precise step-by-step instructions. Don't use it for casual chat or quick answers you're confident about. Before calling, say a few words like \"let me take a closer look\". The result is the answer: say it to the user in your own voice, keeping its meaning.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "question": [
                    "type": "STRING",
                    "description": "The user's question, restated so it stands on its own, with any context from the conversation that the smarter model needs."
                ]
            ],
            "required": ["question"]
        ]
    ]

    /// Hands longer jobs to a background agent (see ClickyRoster), like
    /// shipped Clicky's voice delegation to its Clickys.
    private static let startClickyTaskFunctionDeclaration: [String: Any] = [
        "name": "start_clicky_task",
        "description": "Start a background task with one of the user's Dots: helpers that work on their own on the user's Mac with a shell, files and the web, and report back when done. Use it when the user asks for something that takes real work beyond answering, like researching a topic, writing or editing files, organizing a folder, building something, or doing something in an app on their Mac (Dots can click and type in apps once the user allows it), or when they name a Dottie. Don't use it for questions you can answer right now. After calling, tell the user briefly that it's started.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "clicky_name": [
                    "type": "STRING",
                    "description": "Name of the Dot the user mentioned, if any. Leave empty to let the app pick or create one."
                ],
                "task": [
                    "type": "STRING",
                    "description": "The task, written so it stands on its own: what to do, any details from the conversation or screen, and what the finished result should be."
                ]
            ],
            "required": ["task"]
        ]
    ]

    private static var coreFunctionDeclarations: [[String: Any]] {
        [
            pointAtElementFunctionDeclaration,
            sendToHigherModelFunctionDeclaration,
            startClickyTaskFunctionDeclaration,
            searchWebFunctionDeclaration,
            doTaskOnScreenFunctionDeclaration,
            stopScreenTaskFunctionDeclaration
        ]
    }

    /// Multi-step jobs on the screen, done by DottieScreenTaskRunner.
    private static let doTaskOnScreenFunctionDeclaration: [String: Any] = [
        "name": "do_task_on_screen",
        "description": "Do a job on the user's screen that takes several steps, all in one go: opening apps, going to sites, searching, clicking through pages, typing, scrolling, and reading what's there. Example: 'open opera, search kaggle, go to my competitions, open the RSNA knee one and tell me my rank'. Pass the whole request, every step. Dottie's cursor does it step by step and you'll get the result in a later message to tell the user. Only when the user asks you to do it. After calling, just say you're on it in a few words.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "task": [
                    "type": "STRING",
                    "description": "The whole job in the user's words, every step in order, plus details from the conversation (names, apps, what to report back)."
                ]
            ],
            "required": ["task"]
        ]
    ]

    private static let stopScreenTaskFunctionDeclaration: [String: Any] = [
        "name": "stop_screen_task",
        "description": "Stop the on-screen job that's running, when the user says stop, cancel or never mind.",
        "parameters": ["type": "OBJECT", "properties": [String: Any]()]
    ]

    private static let searchWebFunctionDeclaration: [String: Any] = [
        "name": "search_web",
        "description": "Search the web for fresh or specific facts you don't know for sure: news, prices, scores, weather, opening hours, release dates, recent versions, or anything that may have changed. Say a few words first, like \"let me look that up\". The result has search results and the text of the top page; answer from it in a sentence or two.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "query": [
                    "type": "STRING",
                    "description": "What to search for, written like a search engine query."
                ]
            ],
            "required": ["query"]
        ]
    ]

    // MARK: - Sending

    private nonisolated func enqueueOrSend(message: [String: Any]) {
        guard let messageData = try? JSONSerialization.data(withJSONObject: message) else { return }
        let messageText = String(decoding: messageData, as: UTF8.self)

        outgoingMessageLock.lock()
        let isReady = isSocketReadyForSending
        let socketTask = activeWebSocketTaskForSending
        if !isReady {
            pendingOutgoingMessages.append(messageText)
        }
        if isRecordingCurrentTurnMessages && message["toolResponse"] == nil {
            if currentTurnSentMessages.count < Self.maximumReplayableTurnMessages {
                currentTurnSentMessages.append(messageText)
            } else {
                // Too long to replay; a drop now is reported as an error.
                isRecordingCurrentTurnMessages = false
                currentTurnSentMessages = []
            }
        }
        outgoingMessageLock.unlock()

        guard isReady, let socketTask else { return }
        socketTask.send(.string(messageText)) { error in
            if let error {
                print("⚠️ Gemini Live: send failed: \(error.localizedDescription)")
            }
        }
    }

    private func markSocketReadyAndFlushPendingMessages(for readyWebSocketTask: URLSessionWebSocketTask) {
        outgoingMessageLock.lock()
        isSocketReadyForSending = true
        activeWebSocketTaskForSending = readyWebSocketTask
        let messagesToFlush = pendingOutgoingMessages
        pendingOutgoingMessages.removeAll()
        outgoingMessageLock.unlock()

        for messageText in messagesToFlush {
            readyWebSocketTask.send(.string(messageText)) { error in
                if let error {
                    print("⚠️ Gemini Live: flush send failed: \(error.localizedDescription)")
                }
            }
        }
        print("🔌 Gemini Live: ready, flushed \(messagesToFlush.count) queued message(s)")
    }

    // MARK: - Receiving

    private func startReceiveLoop(for receivingWebSocketTask: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await receivingWebSocketTask.receive()
                } catch {
                    guard let self, self.webSocketTask === receivingWebSocketTask else { return }
                    print("🔌 Gemini Live: socket closed: \(error.localizedDescription)")
                    self.handleConnectionLost(error: error)
                    return
                }

                guard let self, self.webSocketTask === receivingWebSocketTask else { return }

                // Gemini sends JSON as binary frames; accept either.
                let messageData: Data
                switch message {
                case .string(let messageText):
                    messageData = Data(messageText.utf8)
                case .data(let binaryData):
                    messageData = binaryData
                @unknown default:
                    continue
                }

                guard let serverMessage = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    continue
                }
                self.handleServerMessage(serverMessage, from: receivingWebSocketTask)
            }
        }
    }

    private func handleServerMessage(_ serverMessage: [String: Any], from receivingWebSocketTask: URLSessionWebSocketTask) {
        lastServerMessageReceivedAt = Date()

        if serverMessage["setupComplete"] != nil {
            connectionState = .ready
            markSocketReadyAndFlushPendingMessages(for: receivingWebSocketTask)
        }

        if let serverContent = serverMessage["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
        }

        if let toolCall = serverMessage["toolCall"] as? [String: Any] {
            handleToolCall(toolCall)
        }

        if let toolCallCancellation = serverMessage["toolCallCancellation"] as? [String: Any],
           let cancelledFunctionCallIDs = toolCallCancellation["ids"] as? [String] {
            for cancelledFunctionCallID in cancelledFunctionCallIDs {
                pendingFunctionCallTasks.removeValue(forKey: cancelledFunctionCallID)?.cancel()
            }
        }

        if let sessionResumptionUpdate = serverMessage["sessionResumptionUpdate"] as? [String: Any],
           (sessionResumptionUpdate["resumable"] as? Bool) == true,
           let newHandle = sessionResumptionUpdate["newHandle"] as? String,
           !newHandle.isEmpty {
            sessionResumptionHandle = newHandle
        }

        if serverMessage["goAway"] != nil {
            // The server will close soon. Finish the current turn if one is
            // running, then reconnect fresh on the next press.
            print("🔌 Gemini Live: goAway received, will reconnect on next turn")
            if isModelTurnInProgress {
                shouldDisconnectAfterCurrentTurn = true
            } else {
                disconnect()
            }
        }
    }

    private func handleServerContent(_ serverContent: [String: Any]) {
        if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
           let transcriptChunk = inputTranscription["text"] as? String {
            currentTurnUserTranscript += transcriptChunk
            onUserTranscriptUpdate?(currentTurnUserTranscript)
        }

        if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
           let transcriptChunk = outputTranscription["text"] as? String {
            markModelContentReceived()
            currentTurnModelTranscript += transcriptChunk
            if !isDiscardingModelAudioForCurrentTurn {
                onModelTranscriptUpdate?(currentTurnModelTranscript)
            }
        }

        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inlineData = part["inlineData"] as? [String: Any],
                      let base64AudioData = inlineData["data"] as? String,
                      let pcmAudioData = Data(base64Encoded: base64AudioData) else {
                    continue
                }
                markModelContentReceived()
                guard !isDiscardingModelAudioForCurrentTurn else { continue }
                if !hasModelStartedSpeakingThisTurn {
                    hasModelStartedSpeakingThisTurn = true
                    onModelSpeechStarted?()
                }
                audioPlayer.enqueuePCM16Audio(pcmAudioData)
            }
        }

        if (serverContent["interrupted"] as? Bool) == true {
            audioPlayer.stopImmediately()
        }

        if (serverContent["turnComplete"] as? Bool) == true {
            isModelTurnInProgress = false
            stopRecordingCurrentTurnMessages()
            // An answer cut off with Escape isn't remembered as said.
            let wasCancelledByUser = isDiscardingModelAudioForCurrentTurn
            let finishedUserTranscript = wasCancelledByUser ? "" : currentTurnUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let finishedModelTranscript = wasCancelledByUser ? "" : currentTurnModelTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            onModelTurnComplete?(finishedUserTranscript, finishedModelTranscript)
            if shouldDisconnectAfterCurrentTurn {
                disconnect()
            } else {
                scheduleIdleDisconnect()
            }
        }
    }

    private func handleToolCall(_ toolCall: [String: Any]) {
        guard let functionCalls = toolCall["functionCalls"] as? [[String: Any]] else { return }
        markModelContentReceived()

        for functionCall in functionCalls {
            let functionName = functionCall["name"] as? String ?? ""
            let functionCallID = functionCall["id"] as? String ?? UUID().uuidString
            let functionArguments = functionCall["args"] as? [String: Any] ?? [:]

            switch functionName {
            case "point_at_element":
                handlePointAtElementCall(functionCallID: functionCallID, functionArguments: functionArguments)
            case "send_to_higher_model":
                handleSendToHigherModelCall(functionCallID: functionCallID, functionArguments: functionArguments)
            case "start_clicky_task":
                handleStartClickyTaskCall(functionCallID: functionCallID, functionArguments: functionArguments)
            case "search_web":
                handleSearchWebCall(functionCallID: functionCallID, functionArguments: functionArguments)
            case "do_task_on_screen":
                handleDoTaskOnScreenCall(functionCallID: functionCallID, functionArguments: functionArguments)
            case "stop_screen_task":
                let stopStatus = onStopScreenTask?() ?? "nothing is running."
                sendFunctionResponse(functionCallID: functionCallID, functionName: functionName, response: ["result": stopStatus])
            case _ where DottieScreenAction.functionNames.contains(functionName):
                handleScreenActionCall(functionCallID: functionCallID, functionName: functionName, functionArguments: functionArguments)
            default:
                sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                     response: ["error": "unknown function"])
            }
        }
    }

    private func handlePointAtElementCall(functionCallID: String, functionArguments: [String: Any]) {
        guard let normalizedX = (functionArguments["x"] as? NSNumber)?.doubleValue,
              let normalizedY = (functionArguments["y"] as? NSNumber)?.doubleValue else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: "point_at_element",
                                 response: ["error": "x and y are required"])
            return
        }

        if !isDiscardingModelAudioForCurrentTurn {
            onPointRequest?(GeminiLivePointRequest(
                normalizedX: normalizedX,
                normalizedY: normalizedY,
                elementLabel: functionArguments["label"] as? String
            ))
        }
        // Answer right away so the model carries on speaking.
        sendFunctionResponse(functionCallID: functionCallID, functionName: "point_at_element",
                             response: ["result": "the cursor is now pointing at it. keep talking to the user."])
    }

    /// Hands the question to a stronger model with fresh screenshots. Live
    /// waits for the answer, then speaks it in its own voice.
    private func handleSendToHigherModelCall(functionCallID: String, functionArguments: [String: Any]) {
        let question = (functionArguments["question"] as? String) ?? currentTurnUserTranscript
        guard let onHigherModelRequest else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: "send_to_higher_model",
                                 response: ["error": "the deeper model isn't available. answer as best you can yourself."])
            return
        }

        pendingFunctionCallTasks[functionCallID] = Task { [weak self] in
            let higherModelAnswer = await onHigherModelRequest(question)
            guard let self, !Task.isCancelled else { return }
            self.pendingFunctionCallTasks.removeValue(forKey: functionCallID)
            self.sendFunctionResponse(
                functionCallID: functionCallID,
                functionName: "send_to_higher_model",
                response: ["result": higherModelAnswer]
            )
        }
    }

    /// Live waits for the results, then answers from them.
    private func handleSearchWebCall(functionCallID: String, functionArguments: [String: Any]) {
        let query = ((functionArguments["query"] as? String) ?? currentTurnUserTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: "search_web",
                                 response: ["error": "the query was empty."])
            return
        }

        pendingFunctionCallTasks[functionCallID] = Task { [weak self] in
            let searchResults = await DottieWebSearch.search(query)
            guard let self, !Task.isCancelled else { return }
            self.pendingFunctionCallTasks.removeValue(forKey: functionCallID)
            self.sendFunctionResponse(
                functionCallID: functionCallID,
                functionName: "search_web",
                response: ["result": searchResults]
            )
        }
    }

    /// Clicks, typing, keys, scrolling, pages and drawing. Live waits for
    /// the result so it can say what happened.
    private func handleScreenActionCall(functionCallID: String, functionName: String, functionArguments: [String: Any]) {
        guard !isDiscardingModelAudioForCurrentTurn,
              let onScreenAction,
              let screenAction = DottieScreenAction(functionName: functionName, arguments: functionArguments) else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                 response: ["error": "couldn't do that right now."])
            return
        }

        pendingFunctionCallTasks[functionCallID] = Task { [weak self] in
            let actionResult = await onScreenAction(screenAction)
            guard let self, !Task.isCancelled else { return }
            self.pendingFunctionCallTasks.removeValue(forKey: functionCallID)
            self.sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                      response: ["result": actionResult])
        }
    }

    private func handleDoTaskOnScreenCall(functionCallID: String, functionArguments: [String: Any]) {
        let taskText = (functionArguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !taskText.isEmpty, let onStartScreenTask, !isDiscardingModelAudioForCurrentTurn else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: "do_task_on_screen",
                                 response: ["error": "couldn't start that right now."])
            return
        }
        sendFunctionResponse(functionCallID: functionCallID, functionName: "do_task_on_screen",
                             response: ["result": onStartScreenTask(taskText)])
    }

    private func handleStartClickyTaskCall(functionCallID: String, functionArguments: [String: Any]) {
        let taskText = (functionArguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !taskText.isEmpty, let onStartClickyTask, !isDiscardingModelAudioForCurrentTurn else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: "start_clicky_task",
                                 response: ["error": "couldn't start a background task right now."])
            return
        }
        let requestedClickyName = (functionArguments["clicky_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startStatus = onStartClickyTask(requestedClickyName?.isEmpty == true ? nil : requestedClickyName, taskText)
        sendFunctionResponse(functionCallID: functionCallID, functionName: "start_clicky_task",
                             response: ["result": startStatus])
    }

    private func sendFunctionResponse(functionCallID: String, functionName: String, response: [String: Any]) {
        // Counts as activity for the watchdog: the model may take a moment to
        // start speaking after a slow tool result.
        lastServerMessageReceivedAt = Date()
        enqueueOrSend(message: [
            "toolResponse": [
                "functionResponses": [[
                    "id": functionCallID,
                    "name": functionName,
                    "response": response
                ]]
            ]
        ])
    }

    private func cancelPendingFunctionCalls() {
        for pendingFunctionCallTask in pendingFunctionCallTasks.values {
            pendingFunctionCallTask.cancel()
        }
        pendingFunctionCallTasks.removeAll()
    }

    /// The model has started answering, so this turn can't be replayed any more.
    private func markModelContentReceived() {
        guard !hasReceivedModelContentThisTurn else { return }
        hasReceivedModelContentThisTurn = true
        stopRecordingCurrentTurnMessages()
    }

    private func stopRecordingCurrentTurnMessages() {
        outgoingMessageLock.lock()
        isRecordingCurrentTurnMessages = false
        currentTurnSentMessages = []
        outgoingMessageLock.unlock()
    }

    /// The session dropped before the model said anything this turn: open a
    /// new session on the backup model and send the turn again. Returns
    /// false when the turn can't be replayed.
    private func replayCurrentTurnOnNewSession() -> Bool {
        guard isModelTurnInProgress, !hasReceivedModelContentThisTurn,
              turnReplayCount < Self.maximumTurnReplays else { return false }

        outgoingMessageLock.lock()
        let messagesToReplay = isRecordingCurrentTurnMessages ? currentTurnSentMessages : nil
        outgoingMessageLock.unlock()
        guard let messagesToReplay else { return false }

        turnReplayCount += 1
        shouldUseBackupLiveModel = true
        print("🔁 Gemini Live: session dropped before answering, replaying the turn (\(turnReplayCount)/\(Self.maximumTurnReplays)) on \(Self.backupLiveModel)")

        let wasUserTurnOpen = isUserTurnOpen
        disconnect()
        // A session that errored out can't be resumed; its context comes
        // back through recentConversationHistory instead.
        sessionResumptionHandle = nil

        outgoingMessageLock.lock()
        pendingOutgoingMessages = messagesToReplay
        currentTurnSentMessages = messagesToReplay
        isRecordingCurrentTurnMessages = true
        outgoingMessageLock.unlock()

        isModelTurnInProgress = true
        isUserTurnOpen = wasUserTurnOpen
        connectIfNeeded()
        if !wasUserTurnOpen {
            startResponseWatchdog()
        }
        return true
    }

    private func handleConnectionLost(error: Error) {
        if replayCurrentTurnOnNewSession() { return }
        let wasTurnInProgress = isModelTurnInProgress
        disconnect()
        isModelTurnInProgress = false
        isUserTurnOpen = false
        // A dropped connection can't be resumed with a handle from a session
        // that errored out, so start clean next time.
        sessionResumptionHandle = nil
        if wasTurnInProgress {
            onTurnError?(error)
        }
    }

    // MARK: - Response watchdog

    /// If the server goes silent after the user's turn (stalled socket,
    /// half-open connection), give up instead of spinning forever.
    private func startResponseWatchdog() {
        responseWatchdogTask?.cancel()
        let turnEndedAt = Date()
        responseWatchdogTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.isModelTurnInProgress, !self.isUserTurnOpen else { return }
                guard self.pendingFunctionCallTasks.isEmpty else { continue }
                let lastActivity = max(turnEndedAt, self.lastServerMessageReceivedAt)
                if Date().timeIntervalSince(lastActivity) > Self.responseTimeoutSeconds {
                    print("⚠️ Gemini Live: no response for \(Int(Self.responseTimeoutSeconds))s, dropping connection")
                    self.handleConnectionLost(error: NSError(
                        domain: "GeminiLive", code: -20,
                        userInfo: [NSLocalizedDescriptionKey: "gemini live stopped responding"]
                    ))
                    return
                }
            }
        }
    }

    // MARK: - Idle disconnect

    /// Video sessions are capped at about two minutes, so we don't hold a
    /// socket open between conversations. Reconnecting costs well under a
    /// second and the user's words are queued meanwhile.
    private func scheduleIdleDisconnect() {
        cancelIdleDisconnect()
        idleDisconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleDisconnectDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard !self.isModelTurnInProgress, !self.isUserTurnOpen else { return }
            print("🔌 Gemini Live: idle, closing socket")
            self.sessionResumptionHandle = nil
            self.disconnect()
        }
    }

    private func cancelIdleDisconnect() {
        idleDisconnectTask?.cancel()
        idleDisconnectTask = nil
    }
}

// MARK: - Audio playback

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
                print("⚠️ Gemini Live player: engine failed to start: \(error)")
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
