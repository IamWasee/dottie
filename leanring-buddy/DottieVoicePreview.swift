//
//  DottieVoicePreview.swift
//  leanring-buddy
//
//  Lets the user hear each of Dottie's voices before choosing one
//  (Settings → Voice, and the panel). A sample comes from Gemini's
//  text-to-speech in that voice, or, if that model is busy or out of
//  free quota, from a one-line Live session with the voice. Each sample is
//  saved, so a voice costs one Gemini call ever.
//

import Combine
import Foundation

@MainActor
final class DottieVoicePreview: ObservableObject {
    static let shared = DottieVoicePreview()

    struct Voice: Identifiable {
        let name: String
        /// Google's one-word description of the voice.
        let sound: String
        var id: String { name }
    }

    /// The voices Gemini Live speaks in, with how they sound.
    static let voices: [Voice] = [
        Voice(name: "Kore", sound: "Firm"),
        Voice(name: "Puck", sound: "Upbeat"),
        Voice(name: "Aoede", sound: "Breezy"),
        Voice(name: "Charon", sound: "Informative"),
        Voice(name: "Fenrir", sound: "Excitable"),
        Voice(name: "Leda", sound: "Youthful"),
        Voice(name: "Orus", sound: "Firm"),
        Voice(name: "Zephyr", sound: "Bright")
    ]

    static func sound(of voiceName: String) -> String {
        voices.first { $0.name == voiceName }?.sound ?? ""
    }

    /// The voice whose sample is playing, or being fetched.
    @Published private(set) var playingVoiceName: String?
    @Published private(set) var loadingVoiceName: String?
    /// Shown under the voices when a sample couldn't be made.
    @Published private(set) var problem: String?

    private static let sampleLine = "Hey, I'm Dottie! Hold your shortcut, ask me anything, and I'll show you right on your screen."
    private static let speechModels = ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"]
    private static let sampleRate = 24_000

    private let player = GeminiLivePCMPlayer()
    private var previewTask: Task<Void, Never>?

    /// Plays `voiceName`'s sample, or stops it if it's the one playing.
    func toggle(_ voiceName: String) {
        if playingVoiceName == voiceName || loadingVoiceName == voiceName {
            stop()
        } else {
            play(voiceName)
        }
    }

    func play(_ voiceName: String) {
        stop()
        problem = nil
        previewTask = Task { [weak self] in
            guard let self else { return }
            var audio = Self.savedSample(for: voiceName)
            if audio == nil {
                self.loadingVoiceName = voiceName
                audio = await Self.makeSample(voiceName: voiceName)
                if self.loadingVoiceName == voiceName { self.loadingVoiceName = nil }
                if let audio { Self.saveSample(audio, for: voiceName) }
            }
            guard !Task.isCancelled else { return }
            guard let audio, !audio.isEmpty else {
                self.problem = "Couldn't get a sample of \(voiceName) right now (Gemini is busy). Try again in a minute."
                return
            }
            self.playingVoiceName = voiceName
            self.player.enqueuePCM16Audio(audio)
            // Clear the "playing" mark when the sample ends.
            let sampleSeconds = Double(audio.count / 2) / Double(Self.sampleRate)
            try? await Task.sleep(nanoseconds: UInt64((sampleSeconds + 0.3) * 1_000_000_000))
            while !Task.isCancelled, self.player.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if !Task.isCancelled, self.playingVoiceName == voiceName { self.playingVoiceName = nil }
        }
    }

    func stop() {
        previewTask?.cancel()
        previewTask = nil
        player.stopImmediately()
        playingVoiceName = nil
        loadingVoiceName = nil
    }

    // MARK: - Saved samples

    private static var samplesFolder: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("Dottie/VoiceSamples", isDirectory: true)
    }

    private static func sampleFile(for voiceName: String) -> URL {
        samplesFolder.appendingPathComponent("\(voiceName).pcm")
    }

    private static func savedSample(for voiceName: String) -> Data? {
        guard let data = try? Data(contentsOf: sampleFile(for: voiceName)), !data.isEmpty else { return nil }
        return data
    }

    private static func saveSample(_ audio: Data, for voiceName: String) {
        try? FileManager.default.createDirectory(at: samplesFolder, withIntermediateDirectories: true)
        try? audio.write(to: sampleFile(for: voiceName), options: .atomic)
    }

    // MARK: - Making a sample

    private static func makeSample(voiceName: String) async -> Data? {
        for model in speechModels {
            if Task.isCancelled { return nil }
            if let audio = await speechSample(voiceName: voiceName, model: model) { return audio }
        }
        if Task.isCancelled { return nil }
        return await liveSample(voiceName: voiceName)
    }

    /// Gemini text-to-speech through the Worker's Gemini passthrough, which
    /// adds the key. Returns 24kHz 16-bit mono PCM.
    private static func speechSample(voiceName: String, model: String) async -> Data? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/gemini/v1beta/models/\(model):generateContent"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let body: [String: Any] = [
            "contents": [["parts": [["text": "Say in a warm, friendly way: \(sampleLine)"]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]]]
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any],
              let candidates = payload["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            print("🔈 Voice preview: \(model) gave no sample for \(voiceName)")
            return nil
        }
        for part in parts {
            if let inlineData = part["inlineData"] as? [String: Any],
               let base64Audio = inlineData["data"] as? String,
               let audio = Data(base64Encoded: base64Audio), !audio.isEmpty {
                return audio
            }
        }
        return nil
    }

    /// A one-line Live session in the voice: the same voice Dottie talks
    /// with, so the sample is exactly what the user will hear.
    private static func liveSample(voiceName: String) async -> Data? {
        var tokenRequest = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/live-token"))
        tokenRequest.httpMethod = "POST"
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &tokenRequest)
        guard let tokenReply = try? await URLSession.shared.data(for: tokenRequest),
              (tokenReply.1 as? HTTPURLResponse)?.statusCode == 200,
              let tokenPayload = try? JSONSerialization.jsonObject(with: tokenReply.0) as? [String: Any],
              let token = tokenPayload["token"] as? String else {
            print("🔈 Voice preview: no Live token")
            return nil
        }
        let liveModel = (tokenPayload["model"] as? String) ?? "gemini-3.8-live"

        var urlComponents = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained")!
        urlComponents.queryItems = [URLQueryItem(name: "access_token", value: token)]
        let socket = URLSession.shared.webSocketTask(with: urlComponents.url!)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        func send(_ message: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: message)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }
        func receive() async throws -> [String: Any] {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: data = Data()
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        // Give up after 25 seconds whatever happens.
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }

        var audio = Data()
        do {
            try await send(["setup": [
                "model": "models/\(liveModel)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]]]
                ],
                "systemInstruction": ["parts": [["text": "You read lines aloud exactly as written, in a warm, friendly way. Say nothing else."]]]
            ]])
            while try await receive()["setupComplete"] == nil {}
            try await send(["realtimeInput": ["text": sampleLine]])
            while !Task.isCancelled {
                let message = try await receive()
                guard let serverContent = message["serverContent"] as? [String: Any] else { continue }
                let parts = (serverContent["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let base64Audio = inlineData["data"] as? String,
                       let chunk = Data(base64Encoded: base64Audio) {
                        audio.append(chunk)
                    }
                }
                if (serverContent["turnComplete"] as? Bool) == true { break }
            }
        } catch {
            print("🔈 Voice preview: Live sample for \(voiceName) failed: \(error.localizedDescription)")
        }
        // Anything under a second is a broken sample, not worth saving.
        return audio.count >= sampleRate * 2 ? audio : nil
    }
}
