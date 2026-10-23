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
    /// The model handed a task to a background Clicky (start_helper).
    /// Returns a short status for Live to relay; the work runs on its own.
    var onStartClickyTask: (@MainActor (_ clickyName: String?, _ task: String, _ projectName: String?, _ restart: Bool) -> String)?
    /// list_helpers, check_helper, stop_helper, open_helper_result: the
    /// app answers from the helpers' real state.
    var onHelperTool: (@MainActor (_ functionName: String, _ helperName: String?) -> String)?
    /// recall_memory, remember and ask_brain (DottieBrain).
    var onBrainTool: (@MainActor (_ functionName: String, _ text: String) -> String)?
    /// The model asked to click, type, press keys, scroll, open a page or
    /// draw on screen. Returns what happened, for the model to relay.
    var onScreenAction: (@MainActor (DottieScreenAction) async -> String)?
    /// The model handed a multi-step job on the screen to the task runner
    /// (do_task_on_screen). Returns a short status; the result is spoken
    /// in a later turn when the job finishes.
    var onStartScreenTask: (@MainActor (_ task: String, _ isGame: Bool, _ referenceImageNames: [String], _ restart: Bool) -> String)?
    /// The user asked to stop the running screen task (stop_screen_task).
    /// scope: "all" (stop and clear the list), "current" (skip to the next
    /// job) or "list" (what's running and waiting).
    var onStopScreenTask: (@MainActor (_ scope: String) -> String)?
    /// The model started teaching the app on screen (guide_user). Returns a
    /// short status; the steps are shown and spoken as they come.
    var onStartGuide: (@MainActor (_ goal: String, _ mode: String) -> String)?
    /// The user said they did the current guide step (guide_next).
    var onGuideNext: (@MainActor () -> String)?
    /// The user asked to stop the guide (stop_guide).
    var onStopGuide: (@MainActor () -> String)?
    /// Shortcuts, AppleScript, Calendar, Reminders, Contacts, the browser
    /// and meeting notes (DottieMacTools). Live waits for the result.
    var onMacTool: (@MainActor (_ functionName: String, _ arguments: [String: Any]) async -> String)?

    // MARK: - Configuration

    /// System prompt for every session. CompanionManager sets this once.
    var baseSystemInstruction: String = ""
    /// Recent (user, model) exchanges, appended to the system instruction of
    /// each new session so memory survives reconnects and relaunches.
    var recentConversationHistory: [(userTranscript: String, modelTranscript: String)] = []
    /// The voice the user picked (e.g. "Kore", "Puck", or a styled one like
    /// "Butler", which maps to a prebuilt Gemini voice plus a speaking
    /// style; see DottieVoicePreview.voices). Persisted by the panel.
    var voiceName: String = UserDefaults.standard.string(forKey: "selectedGeminiLiveVoice") ?? "Kore" {
        didSet {
            if voiceName != oldValue { startFreshSessionSoon() }
        }
    }

    /// Set for a turn the user typed in the notch: the answer shows as text
    /// (the caption still streams) and its audio isn't played.
    var isAudioOutputMuted = false

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
    /// When the socket was last closed for being idle. A handle kept across
    /// an idle close lets the next press pick the conversation up without
    /// the whole setup being processed again, but only for a while: after
    /// this long a fresh session also picks up new memories and the date.
    private var sessionResumptionHandleKeptAt: Date?
    /// When the user let go of the talk shortcut, to time how long the
    /// answer takes to start (Settings → Usage).
    private var userTurnEndedAt: Date?
    private var openedSessionCount = 0
    private var lastSentScreenFrame: (sessionNumber: Int, fingerprint: [UInt8])?
    /// This turn's frame when it wasn't sent because the session already had
    /// it. A replay on a new session has no earlier picture, so it gets this.
    private var currentTurnSkippedScreenFrameJPEGData: Data?

    private static let idleResumptionWindowSeconds: TimeInterval = 30 * 60

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
    /// What the user has said so far this turn, for tools that need their
    /// own words (a click that only starts their goal).
    var userTranscriptSoFar: String { currentTurnUserTranscript }
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
    /// Calls made through use_tool that haven't been answered yet. Their
    /// response must carry use_tool's name, not the hidden tool's.
    private var useToolResponseNamesByFunctionCallID: [String: String] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Turn API

    /// Opens a user turn: connects if needed, interrupts any answer still
    /// playing, and sends the screenshot frame for this turn.
    func beginUserTurn(screenFrameJPEGData: Data?, screenFrameFingerprint: [UInt8]? = nil) {
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

        currentTurnSkippedScreenFrameJPEGData = nil
        if let screenFrameJPEGData {
            // Each picture costs hundreds of tokens and stays in the
            // session's context. When this session already has a picture of
            // the same screen, say so instead of sending it again.
            if let screenFrameFingerprint,
               let lastSentScreenFrame,
               lastSentScreenFrame.sessionNumber == openedSessionCount,
               ScreenFrameFingerprint.showSameScreen(screenFrameFingerprint, lastSentScreenFrame.fingerprint) {
                pendingTurnContextTexts.append("[note] the screen hasn't changed since the last picture you got in this conversation; use that one.")
                currentTurnSkippedScreenFrameJPEGData = screenFrameJPEGData
            } else {
                sendScreenFrame(jpegData: screenFrameJPEGData)
                if let screenFrameFingerprint {
                    lastSentScreenFrame = (sessionNumber: openedSessionCount, fingerprint: screenFrameFingerprint)
                }
            }
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
        userTurnEndedAt = Date()
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

    /// The voice and system instruction are only read at setup, and a
    /// resumed session keeps the ones it started with. So after a change,
    /// drop the resumption handle (memory comes back through
    /// recentConversationHistory) and reconnect once the current answer ends.
    func startFreshSessionSoon() {
        sessionResumptionHandle = nil
        guard connectionState != .disconnected else { return }
        if isModelTurnInProgress || isUserTurnOpen {
            shouldDisconnectAfterCurrentTurn = true
        } else {
            disconnect()
        }
    }

    // MARK: - Connection

    private func connectIfNeeded() {
        guard connectionState == .disconnected else { return }
        connectionState = .connecting
        openedSessionCount += 1

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
                    "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": DottieVoicePreview.geminiVoiceName(for: voiceName)]]
                ]
            ],
            "systemInstruction": ["parts": [["text": composeSystemInstruction()]]],
            // No googleSearch tool: on a free-tier key, Live closes the
            // session with "You exceeded your current quota" when it's set.
            // search_web goes through the Worker instead (DottieWebSearch).
            "tools": [
                ["functionDeclarations": Self.directFunctionDeclarations]
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
        if let sessionResumptionHandleKeptAt,
           Date().timeIntervalSince(sessionResumptionHandleKeptAt) > Self.idleResumptionWindowSeconds {
            sessionResumptionHandle = nil
        }
        sessionResumptionHandleKeptAt = nil
        if let sessionResumptionHandle {
            sessionResumptionConfig["handle"] = sessionResumptionHandle
        }
        setup["sessionResumption"] = sessionResumptionConfig

        return ["setup": setup]
    }

    private func composeSystemInstruction() -> String {
        // Sessions are short, so the time stays right for calendar and
        // reminder dates.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d yyyy, h:mm a"
        var baseSystemInstruction = self.baseSystemInstruction
        // A styled voice (Butler) says how to speak; read at setup, so a
        // voice change reaches the next session via startFreshSessionSoon.
        if let speakingStyle = DottieVoicePreview.speakingStyle(for: voiceName) {
            baseSystemInstruction += "\n\n" + speakingStyle
        }
        baseSystemInstruction += "\n\nright now it's \(dateFormatter.string(from: Date())) (\(TimeZone.current.identifier))."
        if let replayShortcutsLine = DottieReplayStore.shared.voiceShortcutsPromptLine {
            baseSystemInstruction += "\n\n" + replayShortcutsLine
        }
        if let smartReplaysLine = DottieSmartReplayStore.shared.voicePromptLine {
            baseSystemInstruction += "\n\n" + smartReplaysLine
        }
        guard !recentConversationHistory.isEmpty else { return baseSystemInstruction }

        // Only the last few exchanges, trimmed: older facts about the user
        // live in the profile and memories already in the instruction, and
        // every character here is read again by each new session.
        let carriedExchanges = Array(recentConversationHistory.suffix(Self.carriedHistoryExchangeCount))
        let historyLines = carriedExchanges.enumerated().map { exchangeIndex, exchange in
            let isOneOfTheLatest = exchangeIndex >= carriedExchanges.count - 2
            let maximumCharacters = isOneOfTheLatest ? 800 : 300
            let userText = Self.trimmedForHistory(exchange.userTranscript, maximumCharacters: maximumCharacters)
            let modelText = Self.trimmedForHistory(exchange.modelTranscript, maximumCharacters: maximumCharacters)
            return "user: \(userText)\nyou: \(modelText)"
        }.joined(separator: "\n")

        return baseSystemInstruction + """


        recent conversation with this user, oldest first (it may be from earlier days; remember what they told you, like their name):
        \(historyLines)
        """
    }

    private static let carriedHistoryExchangeCount = 8

    private static func trimmedForHistory(_ text: String, maximumCharacters: Int) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count > maximumCharacters else { return trimmedText }
        return String(trimmedText.prefix(maximumCharacters)) + "…"
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
                    "description": "The element's visible text, exactly as it appears on screen when it has its own text (like 'Sign in' or 'Downloads'). For an icon, a 1-3 word name of what it is, like 'like button', 'comments icon' or 'download icon', never a number or count shown next to it. The app uses it to find the exact spot."
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
        "name": "start_helper",
        "description": "Start a task with one of the user's background helpers (also called Dots). Helpers work on their own on the user's Mac with a shell, files, Node.js and the web, and report back when done. They can research, write documents, organize files, write code, and build complete websites or small apps. Use it whenever the user asks for real work beyond answering, or asks a helper to do something. After calling, say briefly that it's started.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "helper_name": [
                    "type": "STRING",
                    "description": "Name of the helper the user mentioned, if any. Leave empty to use an idle helper or make one."
                ],
                "task": [
                    "type": "STRING",
                    "description": "The task, written so it stands on its own: what to do, any details from the conversation or screen, and what the finished result should be."
                ],
                "project": [
                    "type": "STRING",
                    "description": "The project this belongs to, for anything being built or worked on over time: an existing project's name to continue it, or a short new name (2-4 words) for something new. Leave empty for one-off tasks like a quick lookup."
                ],
                "restart": [
                    "type": "BOOLEAN",
                    "description": "True only after the user said yes to starting over a task that matches one a helper is already doing or that was cut off when Dottie closed. Leave out otherwise."
                ]
            ],
            "required": ["task"]
        ]
    ]

    private static let listHelpersFunctionDeclaration: [String: Any] = [
        "name": "list_helpers",
        "description": "List the user's helpers as they are right now: which exist, which were deleted, and what each is doing (working, finished, stuck, waiting for permission). Always call this before talking about helpers; never rely on memory.",
        "parameters": ["type": "OBJECT", "properties": [String: Any]()]
    ]

    private static func helperFunctionDeclaration(name: String, description: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "helper_name": [
                        "type": "STRING",
                        "description": "The helper's name. Leave empty for the most recently active one."
                    ]
                ]
            ]
        ]
    }

    private static func brainFunctionDeclaration(name: String, description: String, argumentName: String, argumentDescription: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": [
                "type": "OBJECT",
                "properties": [argumentName: ["type": "STRING", "description": argumentDescription]],
                "required": [argumentName]
            ]
        ]
    }

    /// The second brain: memory search, saving a memory, and the Brain agent.
    private static let brainFunctionDeclarations: [[String: Any]] = [
        brainFunctionDeclaration(
            name: "recall_memory",
            description: "Search everything remembered about the user: past conversations, what helpers did, guides, screen jobs, things they asked you to remember, and what they were doing on screen. Use it whenever they ask about the past.",
            argumentName: "query",
            argumentDescription: "A few keywords for what to look for."
        ),
        brainFunctionDeclaration(
            name: "remember",
            description: "Save something the user asked you to remember.",
            argumentName: "fact",
            argumentDescription: "The thing to remember, written so it stands on its own."
        ),
        brainFunctionDeclaration(
            name: "ask_brain",
            description: "Hand a question or job to your second brain, which can search the user's shared folders and memory and use their command-line tools and connected apps. Use it for anything about their files, folders, repos or tools, or that needs real digging. Its answer comes back to you in a later message.",
            argumentName: "question",
            argumentDescription: "The question or job, written so it stands on its own."
        )
    ]

    private static let helperStatusFunctionDeclarations: [[String: Any]] = [
        listHelpersFunctionDeclaration,
        helperFunctionDeclaration(
            name: "check_helper",
            description: "Get one helper's current status, latest task, recent steps, latest reply and the files it made. Use it when the user asks how a helper is doing or what it said."
        ),
        helperFunctionDeclaration(
            name: "stop_helper",
            description: "Stop a helper that is working on something."
        ),
        helperFunctionDeclaration(
            name: "open_helper_result",
            description: "Open what a helper made for the user to see: a website in the browser, a single file in its app, or the helper's output folder."
        )
    ]

    /// Every tool voice Dottie can use: her own, screen actions, Mac tools,
    /// work tools, the cursor's shape, teaching, the smart home and the
    /// registry's voice tools. Only the everyday ones are declared to Live
    /// (see directFunctionDeclarations); the rest are found with find_tool
    /// and run with use_tool, through the same dispatch.
    private static var everyFunctionDeclaration: [[String: Any]] {
        var declarations: [[String: Any]] = coreFunctionDeclarations
        declarations += DottieScreenAction.functionDeclarations
        declarations += DottieMacTools.functionDeclarations
        declarations += DottieWorkTools.functionDeclarations
        declarations.append(DottieCursorPet.functionDeclaration)
        declarations.append(DottieTeaching.functionDeclaration)
        declarations += DottieSmartHome.functionDeclarations
        declarations += DottieToolRegistry.functionDeclarations(for: .voice)
        return declarations
    }

    /// What the session's setup declares: the everyday tools, plus find_tool
    /// and use_tool for the rest. Every declaration is read again at the
    /// start of each session, so the rarely used ones stay out of it.
    private static var directFunctionDeclarations: [[String: Any]] {
        let everydayDeclarations = everyFunctionDeclaration.filter { declaration in
            guard let toolName = declaration["name"] as? String else { return false }
            return GeminiLiveToolCatalog.directFunctionNames.contains(toolName)
        }
        return everydayDeclarations + [
            GeminiLiveToolCatalog.findToolFunctionDeclaration,
            GeminiLiveToolCatalog.useToolFunctionDeclaration
        ]
    }

    /// The tools Live doesn't get declared, which find_tool searches.
    private static var hiddenFunctionDeclarations: [[String: Any]] {
        everyFunctionDeclaration.filter { declaration in
            guard let toolName = declaration["name"] as? String else { return false }
            return !GeminiLiveToolCatalog.directFunctionNames.contains(toolName)
        }
    }

    private static var everyFunctionName: Set<String> {
        Set(everyFunctionDeclaration.compactMap { $0["name"] as? String })
    }

    private static var coreFunctionDeclarations: [[String: Any]] {
        [
            pointAtElementFunctionDeclaration,
            sendToHigherModelFunctionDeclaration,
            startClickyTaskFunctionDeclaration,
            searchWebFunctionDeclaration,
            doTaskOnScreenFunctionDeclaration,
            stopScreenTaskFunctionDeclaration,
            guideUserFunctionDeclaration,
            guideNextFunctionDeclaration,
            stopGuideFunctionDeclaration
        ] + helperStatusFunctionDeclarations + brainFunctionDeclarations
    }

    /// Teaching the app on screen, step by step or as a tour (DottieGuide).
    private static let guideUserFunctionDeclaration: [String: Any] = [
        "name": "guide_user",
        "description": "Teach the user the app on their screen. Use when they want to learn how to do something themselves ('how do I add a sound effect in premiere', 'where do I go to export', 'walk me through making a pivot table') or want a tour or rundown of the app ('show me around', 'give me a rundown of everything here'). steps mode walks them through it one click at a time: the app points and draws on screen, they click, and the next step appears. tour mode marks the main parts of the window one by one and explains each. The app shows every step on screen and you'll get each line to say. After calling, say only a few words like 'let me show you'.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "goal": [
                    "type": "STRING",
                    "description": "What the user wants to learn or do, in their words, with the app's name and any details they gave."
                ],
                "mode": [
                    "type": "STRING",
                    "enum": ["steps", "tour"],
                    "description": "steps to walk them through doing something; tour for a rundown of the app or screen."
                ]
            ],
            "required": ["goal", "mode"]
        ]
    ]

    private static let guideNextFunctionDeclaration: [String: Any] = [
        "name": "guide_next",
        "description": "During a guide, when the user says next, continue, done, got it, or that they did the step, so the guide moves on.",
        "parameters": ["type": "OBJECT", "properties": [String: Any]()]
    ]

    private static let stopGuideFunctionDeclaration: [String: Any] = [
        "name": "stop_guide",
        "description": "Stop the guide that's running, when the user says stop, that's enough, or never mind.",
        "parameters": ["type": "OBJECT", "properties": [String: Any]()]
    ]

    /// Multi-step jobs on the screen, done by DottieScreenTaskRunner.
    private static let doTaskOnScreenFunctionDeclaration: [String: Any] = [
        "name": "do_task_on_screen",
        "description": "Do a job on the user's screen that takes several steps, all in one go. If a job is already running, this one waits in line and starts when it finishes: opening apps, going to sites, searching, clicking through pages, typing, scrolling, and reading what's there, or playing a video game for the user (set game). Example: 'open opera, search kaggle, go to my competitions, open the RSNA knee one and tell me my rank'. Also for a goal that sounds like one click but needs more to be done, like 'sign in with this account' (done when signed in, not when the account is clicked). Pass the whole goal, every step; it works out the steps itself and asks the user only if it must. Dottie's cursor does it step by step and you'll get the result in a later message to tell the user. Only when the user asks you to do it. After calling, just say you're on it in a few words.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "task": [
                    "type": "STRING",
                    "description": "The whole job in the user's words, every step in order, plus details from the conversation (names, apps, what to report back)."
                ],
                "game": [
                    "type": "BOOLEAN",
                    "description": "True when the job is playing or doing something inside a video game (walking somewhere, picking up or using an item, fighting, building), or mapping a game while the user plays it ('map this game for me'), so it runs in quick game mode with movement keys and camera control."
                ],
                "reference_images": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"],
                    "description": "Names of saved pictures the user showed you that this job is about, exactly as find_pictures names them, like ['golden sword']. The job gets the pictures to match on screen."
                ],
                "restart": [
                    "type": "BOOLEAN",
                    "description": "True only after the user said yes to starting over a job that matches one already running, waiting, or cut off when Dottie closed. Leave out otherwise."
                ]
            ],
            "required": ["task"]
        ]
    ]

    private static let stopScreenTaskFunctionDeclaration: [String: Any] = [
        "name": "stop_screen_task",
        "description": "Manage on-screen jobs: stop everything and clear the waiting list (scope all: stop, cancel, never mind), skip only the running job so the next one starts (scope current: skip this one, next), or hear what's running and waiting (scope list).",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "scope": [
                    "type": "STRING",
                    "enum": ["all", "current", "list"],
                    "description": "all, current or list. Defaults to all."
                ]
            ]
        ]
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

        // Live reports each answer's usage once, with the prompt tokens of
        // the whole context it read for that answer.
        if let usageMetadata = serverMessage["usageMetadata"] as? [String: Any] {
            DottieUsage.shared.record(area: .voice, usageMetadata: usageMetadata)
        }

        if let toolCall = serverMessage["toolCall"] as? [String: Any] {
            handleToolCall(toolCall)
        }

        if let toolCallCancellation = serverMessage["toolCallCancellation"] as? [String: Any],
           let cancelledFunctionCallIDs = toolCallCancellation["ids"] as? [String] {
            for cancelledFunctionCallID in cancelledFunctionCallIDs {
                pendingFunctionCallTasks.removeValue(forKey: cancelledFunctionCallID)?.cancel()
                useToolResponseNamesByFunctionCallID.removeValue(forKey: cancelledFunctionCallID)
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
                    if let userTurnEndedAt {
                        DottieUsage.shared.recordVoiceAnswerStart(seconds: Date().timeIntervalSince(userTurnEndedAt))
                        self.userTurnEndedAt = nil
                    }
                    onModelSpeechStarted?()
                }
                if !isAudioOutputMuted {
                    audioPlayer.enqueuePCM16Audio(pcmAudioData)
                }
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
            case GeminiLiveToolCatalog.findToolFunctionName:
                handleFindToolCall(functionCallID: functionCallID, functionArguments: functionArguments)
            case GeminiLiveToolCatalog.useToolFunctionName:
                handleUseToolCall(functionCallID: functionCallID, functionArguments: functionArguments)
            default:
                dispatchFunctionCall(functionName: functionName, functionCallID: functionCallID, functionArguments: functionArguments)
            }
        }
    }

    /// find_tool: the hidden tools that best match what the user wants,
    /// with their descriptions and argument schemas, for use_tool.
    private func handleFindToolCall(functionCallID: String, functionArguments: [String: Any]) {
        let whatTheUserWants = (functionArguments["what"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matchingToolsText = GeminiLiveToolCatalog.matchingToolsText(
            for: whatTheUserWants,
            amongHiddenDeclarations: Self.hiddenFunctionDeclarations
        )
        sendFunctionResponse(functionCallID: functionCallID, functionName: GeminiLiveToolCatalog.findToolFunctionName,
                             response: ["result": matchingToolsText])
    }

    /// use_tool: runs a hidden tool through exactly the dispatch it would
    /// get if Live had called it by name. Its response goes back under
    /// use_tool's name, since that's the call Live is waiting on.
    private func handleUseToolCall(functionCallID: String, functionArguments: [String: Any]) {
        let useToolFunctionName = GeminiLiveToolCatalog.useToolFunctionName
        let requestedToolName = (functionArguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requestedToolName.isEmpty else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: useToolFunctionName,
                                 response: ["error": "name was empty. call find_tool with what the user wants to get a tool's name."])
            return
        }
        guard requestedToolName != GeminiLiveToolCatalog.findToolFunctionName,
              requestedToolName != useToolFunctionName,
              Self.everyFunctionName.contains(requestedToolName) else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: useToolFunctionName,
                                 response: ["error": "there's no tool named \(requestedToolName). call find_tool with what the user wants to get the right name."])
            return
        }
        guard let requestedToolArguments = GeminiLiveToolCatalog.parsedToolArguments(from: functionArguments["arguments_json"]) else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: useToolFunctionName,
                                 response: ["error": "arguments_json must be a JSON object like {\"action\": \"start\"}, or {} for none. call use_tool again with valid JSON."])
            return
        }
        useToolResponseNamesByFunctionCallID[functionCallID] = useToolFunctionName
        dispatchFunctionCall(functionName: requestedToolName, functionCallID: functionCallID, functionArguments: requestedToolArguments)
    }

    /// Runs one tool call by name. Live's own calls and use_tool's both go
    /// through here, so a tool behaves the same whichever way it's called.
    private func dispatchFunctionCall(functionName: String, functionCallID: String, functionArguments: [String: Any]) {
        switch functionName {
        case "point_at_element":
            handlePointAtElementCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "send_to_higher_model":
            handleSendToHigherModelCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "start_helper":
            handleStartClickyTaskCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "recall_memory", "remember", "ask_brain":
            let argumentName = functionName == "recall_memory" ? "query" : (functionName == "remember" ? "fact" : "question")
            let argumentText = (functionArguments[argumentName] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let brainResult: String
            if argumentText.isEmpty && functionName != "recall_memory" {
                brainResult = "nothing to \(functionName == "remember" ? "remember" : "ask")."
            } else {
                brainResult = onBrainTool?(functionName, argumentText) ?? "the brain isn't available right now."
            }
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName, response: ["result": brainResult])
        case "list_helpers", "check_helper", "stop_helper", "open_helper_result":
            let helperName = (functionArguments["helper_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let helperResult = onHelperTool?(functionName, helperName?.isEmpty == true ? nil : helperName)
                ?? "helpers aren't available right now."
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName, response: ["result": helperResult])
        case "search_web":
            handleSearchWebCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "do_task_on_screen":
            handleDoTaskOnScreenCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "guide_user":
            let goal = (functionArguments["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mode = (functionArguments["mode"] as? String) ?? "steps"
            if !goal.isEmpty, !isDiscardingModelAudioForCurrentTurn, let guideStatus = onStartGuide?(goal, mode) {
                sendFunctionResponse(functionCallID: functionCallID, functionName: functionName, response: ["result": guideStatus])
            } else {
                sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                     response: ["error": "couldn't start a guide right now."])
            }
        case "guide_next":
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                 response: ["result": onGuideNext?() ?? "no guide is running."])
        case "stop_guide":
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                 response: ["result": onStopGuide?() ?? "no guide is running."])
        case "stop_screen_task":
            let scope = (functionArguments["scope"] as? String)?.lowercased() ?? "all"
            let stopStatus = onStopScreenTask?(scope) ?? "nothing is running."
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName, response: ["result": stopStatus])
        case _ where DottieScreenAction.functionNames.contains(functionName):
            handleScreenActionCall(functionCallID: functionCallID, functionName: functionName, functionArguments: functionArguments)
        case _ where DottieMacTools.functionNames.contains(functionName) || DottieWorkTools.functionNames.contains(functionName)
            || functionName == DottieCursorPet.functionName || DottieSmartHome.functionNames.contains(functionName)
            || functionName == DottieTeaching.functionName:
            handleMacToolCall(functionCallID: functionCallID, functionName: functionName, functionArguments: functionArguments)
        case _ where DottieToolRegistry.handles(functionName, for: .voice):
            handleRegisteredToolCall(functionCallID: functionCallID, functionName: functionName, functionArguments: functionArguments)
        default:
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                 response: ["error": "unknown function"])
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

    private func handleMacToolCall(functionCallID: String, functionName: String, functionArguments: [String: Any]) {
        guard !isDiscardingModelAudioForCurrentTurn, let onMacTool else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                 response: ["error": "couldn't do that right now."])
            return
        }
        pendingFunctionCallTasks[functionCallID] = Task { [weak self] in
            let toolResult = await onMacTool(functionName, functionArguments)
            guard let self, !Task.isCancelled else { return }
            self.pendingFunctionCallTasks.removeValue(forKey: functionCallID)
            self.sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                      response: ["result": toolResult])
        }
    }

    /// A tool a feature added through DottieToolRegistry.
    private func handleRegisteredToolCall(functionCallID: String, functionName: String, functionArguments: [String: Any]) {
        guard !isDiscardingModelAudioForCurrentTurn else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                 response: ["error": "couldn't do that right now."])
            return
        }
        pendingFunctionCallTasks[functionCallID] = Task { [weak self] in
            let toolResult = await DottieToolRegistry.run(functionName, arguments: functionArguments, for: .voice)
                ?? "couldn't do that right now."
            guard let self, !Task.isCancelled else { return }
            self.pendingFunctionCallTasks.removeValue(forKey: functionCallID)
            self.sendFunctionResponse(functionCallID: functionCallID, functionName: functionName,
                                      response: ["result": toolResult])
        }
    }

    private func handleDoTaskOnScreenCall(functionCallID: String, functionArguments: [String: Any]) {
        let taskText = (functionArguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !taskText.isEmpty, let onStartScreenTask, !isDiscardingModelAudioForCurrentTurn else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: "do_task_on_screen",
                                 response: ["error": "couldn't start that right now."])
            return
        }
        let isGame = (functionArguments["game"] as? Bool) ?? ((functionArguments["game"] as? NSNumber)?.boolValue ?? false)
        let referenceImageNames = (functionArguments["reference_images"] as? [Any])?.compactMap { $0 as? String } ?? []
        let restart = (functionArguments["restart"] as? Bool) ?? ((functionArguments["restart"] as? NSNumber)?.boolValue ?? false)
        sendFunctionResponse(functionCallID: functionCallID, functionName: "do_task_on_screen",
                             response: ["result": onStartScreenTask(taskText, isGame, referenceImageNames, restart)])
    }

    private func handleStartClickyTaskCall(functionCallID: String, functionArguments: [String: Any]) {
        let taskText = (functionArguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !taskText.isEmpty, let onStartClickyTask, !isDiscardingModelAudioForCurrentTurn else {
            sendFunctionResponse(functionCallID: functionCallID, functionName: "start_helper",
                                 response: ["error": "couldn't start a background task right now."])
            return
        }
        let requestedClickyName = (functionArguments["helper_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = (functionArguments["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let restart = (functionArguments["restart"] as? Bool) ?? ((functionArguments["restart"] as? NSNumber)?.boolValue ?? false)
        let startStatus = onStartClickyTask(
            requestedClickyName?.isEmpty == true ? nil : requestedClickyName,
            taskText,
            projectName?.isEmpty == true ? nil : projectName,
            restart
        )
        sendFunctionResponse(functionCallID: functionCallID, functionName: "start_helper",
                             response: ["result": startStatus])
    }

    private func sendFunctionResponse(functionCallID: String, functionName: String, response: [String: Any]) {
        // Counts as activity for the watchdog: the model may take a moment to
        // start speaking after a slow tool result.
        lastServerMessageReceivedAt = Date()
        // A hidden tool run through use_tool answers as use_tool, the call
        // Live actually made, even though its handler names itself.
        let respondingFunctionName = useToolResponseNamesByFunctionCallID.removeValue(forKey: functionCallID) ?? functionName
        enqueueOrSend(message: [
            "toolResponse": [
                "functionResponses": [[
                    "id": functionCallID,
                    "name": respondingFunctionName,
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
        useToolResponseNamesByFunctionCallID.removeAll()
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
        guard var messagesToReplay else { return false }
        if let currentTurnSkippedScreenFrameJPEGData,
           let frameMessageData = try? JSONSerialization.data(withJSONObject: [
               "realtimeInput": ["video": ["mimeType": "image/jpeg", "data": currentTurnSkippedScreenFrameJPEGData.base64EncodedString()]]
           ]) {
            messagesToReplay.insert(String(decoding: frameMessageData, as: UTF8.self), at: 0)
            self.currentTurnSkippedScreenFrameJPEGData = nil
        }

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
            print("🔌 Gemini Live: idle, closing socket (keeping the session to resume)")
            self.sessionResumptionHandleKeptAt = Date()
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

// MARK: - Tool catalog (find_tool and use_tool)

/// Which tools Live gets declared up front and how it reaches the rest.
/// Every declaration (name, description, schema) is read again at the start
/// of each voice session, so only the everyday tools are declared directly.
/// The others are found with find_tool, which returns their description and
/// schema as text, and run with use_tool, which goes through the same
/// dispatch as a direct call (GeminiLiveVoiceClient.dispatchFunctionCall).
@MainActor
enum GeminiLiveToolCatalog {
    static let findToolFunctionName = "find_tool"
    static let useToolFunctionName = "use_tool"

    /// Tools a user reaches for in a normal day, kept direct so they never
    /// cost an extra round trip through find_tool.
    static let directFunctionNames: Set<String> = [
        "point_at_element", "send_to_higher_model", "search_web",
        "do_task_on_screen", "stop_screen_task", "answer_screen_job",
        "guide_user", "guide_next", "stop_guide",
        "start_helper", "list_helpers", "check_helper",
        "recall_memory", "remember", "ask_brain",
        "control_device",
        "click_on_screen", "press_keys", "open_url",
        "run_applescript", "get_schedule", "add_reminder",
        // Co-op mid-game needs to be instant.
        "game_command"
    ]

    /// One line for the voice prompt naming what the hidden tools cover, so
    /// the model knows to look for them. Keep it in step with what isn't in
    /// directFunctionNames.
    static let hiddenToolAreasSummary = "typing and scrolling, drawing or marking the screen and clearing it, explaining with drawings and math (explain_on_screen), your cursor's shape (change_cursor), the browser and its tabs, screenshots, apple shortcuts, adding calendar events, the reminders list and ticking one off, contacts, meeting notes, projects (list_projects) and helper teams, stopping helpers and opening what they made, saved pictures (find_pictures, save_picture), smart home device list (home_devices) and tv jobs, memories by time and forgetting (memories), games, recording gameplay (gameplay_recording), your level, 24/7 jobs, rewriting selected text, watching the screen for something, focus mode, folder cleanup, replays of past screen jobs, smart replays (smart_replays: watch the user do a job once, then redo it by meaning; commercial ones for filming), self-check, about yourself and your settings (about_me), saving the user's corrections about how an app works (save_app_lesson), installing skills for the Dots from a folder (install_skills), installing command-line tools, and the user's connected apps"

    /// Extra words find_tool matches on, for asks that don't share words
    /// with the tool's description ("turn into a cat" → change_cursor).
    private static let extraSearchWordsByToolName: [String: String] = [
        "stop_helper": "stop cancel helper dot",
        "gameplay_recording": "record recording gameplay game me playing capture keys keybinds clip replay play back do what i recorded routine",
        "open_helper_result": "open show result website file folder helper made",
        "type_text": "type write enter text field",
        "scroll_screen": "scroll page down up",
        "draw_on_screen": "draw circle mark highlight arrow box underline annotate",
        "clear_drawings": "clear erase drawings remove marks",
        "run_shortcut": "shortcut shortcuts apple homekit scene run",
        "list_shortcuts": "shortcuts list apple",
        "add_calendar_event": "calendar event meeting appointment add book schedule",
        "get_reminders": "reminders todo list tasks",
        "complete_reminder": "reminder done tick complete check off",
        "find_contact": "contact phone number email birthday address person",
        "browser": "browser tab tabs web page website form fill read safari chrome",
        "meeting_notes": "meeting notes call record transcribe minutes",
        "take_screenshot": "screenshot screen grab capture",
        "list_projects": "projects project folder list",
        "start_team": "team helpers parallel split big job",
        "save_picture": "save picture remember look image",
        "find_pictures": "pictures picture image saved find showed",
        "change_cursor": "cursor pet shape costume turn into cat dog animal emoji walk roam look",
        "explain_on_screen": "explain draw teach math geometry graph equation diagram board plot tutor",
        "home_devices": "smart home devices lights tv list connected",
        "tv_task": "tv television episode youtube netflix show",
        "memories": "memories episodes forget recent yesterday history past happened",
        "game": "game play trivia twenty questions drawing word chain fun",
        "dottie_level": "level xp streak unlock unlocks wear",
        "keep_working": "nonstop night keep working repeat every minutes background",
        "apps_and_tools": "connected apps notion github slack tools integrations",
        "use_app_tool": "connected app run tool notion github slack",
        "fix_text": "fix rewrite selected text grammar spelling translate shorten formal",
        "watch": "watch alert notify tell when download finishes loads",
        "focus": "focus block distractions pomodoro concentrate",
        "clean_folder": "clean tidy organize folder downloads desktop duplicates",
        "replays": "replay replays redo again saved jobs shortcut when i say rename call it first second",
        "install_skills": "install add import skills skill folder set pack dots helpers skill.md",
        "save_app_lesson": "wrong correct correction actually no it is that is not where app lesson remember how app works",
        "smart_replays": "create smart replay commercial replay of me doing this watch me record steps show you how redo closing line say at the end edit filming",
        "self_check": "broken working diagnose check test sound microphone problem",
        "about_me": "dottie yourself settings version features permission help how tour update account",
        "install_tool": "install command line cli homebrew brew npm pip uninstall"
    ]

    private static let maximumToolsPerSearch = 3

    /// Words too common to tell tools apart.
    private static let ignoredSearchWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "what", "want", "wants", "user", "can", "you", "your",
        "my", "me", "to", "a", "an", "of", "in", "on", "it", "is", "do", "be", "at", "or", "some", "something", "please"
    ]

    static let findToolFunctionDeclaration: [String: Any] = [
        "name": findToolFunctionName,
        "description": "Find one of your other tools (listed by area in your instructions) for what the user wants. Returns the best matches with their description and arguments; then run one with use_tool. Skip it when you already know the tool's name and arguments.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "what": [
                    "type": "STRING",
                    "description": "What the user wants, in a few words, like 'take a screenshot' or 'turn into a cat'."
                ]
            ],
            "required": ["what"]
        ]
    ]

    static let useToolFunctionDeclaration: [String: Any] = [
        "name": useToolFunctionName,
        "description": "Run one of your other tools by name (from find_tool or your instructions). Its result comes back like any tool's.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "name": [
                    "type": "STRING",
                    "description": "The tool's exact name, like take_screenshot."
                ],
                "arguments_json": [
                    "type": "STRING",
                    "description": "The tool's arguments as a JSON object, like {\"what\": \"window\"}. {} for none."
                ]
            ],
            "required": ["name", "arguments_json"]
        ]
    ]

    /// use_tool's arguments_json as a dictionary. Empty or missing means no
    /// arguments; nil means it wasn't a JSON object, so use_tool reports it.
    static func parsedToolArguments(from argumentsJSONValue: Any?) -> [String: Any]? {
        // The schema says string, but take an object too if the model sent one.
        if let argumentsDictionary = argumentsJSONValue as? [String: Any] {
            return argumentsDictionary
        }
        let argumentsJSONText = (argumentsJSONValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if argumentsJSONText.isEmpty {
            return [:]
        }
        guard let parsedArguments = try? JSONSerialization.jsonObject(with: Data(argumentsJSONText.utf8)) as? [String: Any] else {
            return nil
        }
        return parsedArguments
    }

    /// find_tool's answer: the best few hidden tools for the ask, each with
    /// its name, description and argument schema. When nothing matches, the
    /// names of every hidden tool, so the model can try again.
    static func matchingToolsText(for whatTheUserWants: String, amongHiddenDeclarations hiddenDeclarations: [[String: Any]]) -> String {
        let queryWords = searchWords(in: whatTheUserWants)
        let normalizedQuery = whatTheUserWants.lowercased().replacingOccurrences(of: " ", with: "_")

        var scoredDeclarations: [(declaration: [String: Any], score: Int)] = []
        for declaration in hiddenDeclarations {
            guard let toolName = declaration["name"] as? String else { continue }
            let toolDescription = declaration["description"] as? String ?? ""
            let nameAndExtraWords = searchWords(in: toolName.replacingOccurrences(of: "_", with: " ") + " " + (extraSearchWordsByToolName[toolName] ?? ""))
            let descriptionWords = searchWords(in: toolDescription)

            var score = 0
            // The model often already knows the name it wants.
            if normalizedQuery.contains(toolName) {
                score += 100
            }
            for queryWord in queryWords {
                if nameAndExtraWords.contains(queryWord) {
                    score += 3
                } else if descriptionWords.contains(queryWord) {
                    score += 1
                }
            }
            if score > 0 {
                scoredDeclarations.append((declaration: declaration, score: score))
            }
        }

        let bestDeclarations = scoredDeclarations
            .sorted { $0.score > $1.score }
            .prefix(maximumToolsPerSearch)
            .map { scoredDeclaration in scoredDeclaration.declaration }

        guard !bestDeclarations.isEmpty else {
            let hiddenToolNames = hiddenDeclarations.compactMap { $0["name"] as? String }.sorted()
            return "no tool matched \"\(whatTheUserWants)\". the tools you can find are: \(hiddenToolNames.joined(separator: ", ")). call find_tool again with other words or one of these names."
        }

        let toolTexts = bestDeclarations.map { declaration -> String in
            let toolName = declaration["name"] as? String ?? ""
            let toolDescription = declaration["description"] as? String ?? ""
            var toolText = "name: \(toolName)\ndescription: \(toolDescription)"
            if let parameters = declaration["parameters"],
               JSONSerialization.isValidJSONObject(parameters),
               let parametersData = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys, .withoutEscapingSlashes]) {
                toolText += "\narguments schema: " + String(decoding: parametersData, as: UTF8.self)
            }
            return toolText
        }
        return toolTexts.joined(separator: "\n\n")
            + "\n\nrun one with use_tool: name, and arguments_json as a JSON object string ({} for none). don't tell the user about this lookup."
    }

    /// Lowercased words of two or more letters (so "tv" counts), without a
    /// plural s, so "reminders" finds "reminder".
    private static func searchWords(in text: String) -> Set<String> {
        let rawWords = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        var words: Set<String> = []
        for rawWord in rawWords where rawWord.count >= 2 && !ignoredSearchWords.contains(rawWord) {
            if rawWord.count > 3 && rawWord.hasSuffix("s") && !rawWord.hasSuffix("ss") {
                words.insert(String(rawWord.dropLast()))
            } else {
                words.insert(rawWord)
            }
        }
        return words
    }
}
