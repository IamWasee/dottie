//
//  GeminiAPI.swift
//  leanring-buddy
//
//  Gemini vision chat with streaming, via the Worker's /chat route. Replaces
//  v0's ClaudeAPI and keeps its call shape (labeled images + system prompt +
//  history + user prompt) so callers barely change.
//
//  Used by the onboarding demo and by the classic (non-Live) voice mode. The
//  main voice companion talks to Gemini Live instead (GeminiLiveVoiceClient).
//

import Foundation

final class GeminiAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    /// Optional model override. nil means "use the Worker's GEMINI_CHAT_MODEL".
    /// The Worker also understands the alias "higher" (GEMINI_HIGHER_MODEL).
    var model: String?
    private let session: URLSession

    init(proxyURL: URL, model: String? = nil) {
        self.apiURL = proxyURL
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached;
        // large image payloads over a cold handshake fail intermittently.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        return request
    }

    /// Screen captures are JPEG, pasted images are PNG. Gemini needs the right
    /// mimeType on each inlineData part.
    private func detectImageMimeType(for imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if imageData.count >= 4 && [UInt8](imageData.prefix(4)) == pngSignature {
            return "image/png"
        }
        return "image/jpeg"
    }

    /// Pre-establishes and caches a TLS session with the Worker host so the
    /// first real request (carrying a large screenshot) skips a cold handshake.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup,
              var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        guard let warmupURL = warmupURLComponents.url else { return }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in }.resume()
    }

    private func buildRequestBody(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        maxOutputTokens: Int,
        modelOverride: String?
    ) -> [String: Any] {
        // Gemini calls the assistant role "model".
        var contents: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            contents.append(["role": "user", "parts": [["text": userPlaceholder]]])
            contents.append(["role": "model", "parts": [["text": assistantResponse]]])
        }

        var currentTurnParts: [[String: Any]] = []
        for image in images {
            currentTurnParts.append([
                "inlineData": [
                    "mimeType": detectImageMimeType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            currentTurnParts.append(["text": image.label])
        }
        currentTurnParts.append(["text": userPrompt])
        contents.append(["role": "user", "parts": currentTurnParts])

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": maxOutputTokens]
        ]
        if let requestedModel = modelOverride ?? model {
            body["model"] = requestedModel
        }
        return body
    }

    /// Streams a vision response. `onTextChunk` receives the accumulated text
    /// so far each time a new chunk arrives.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        modelOverride: String? = nil,
        maxOutputTokens: Int = 1024,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()
        let body = buildRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            maxOutputTokens: maxOutputTokens,
            modelOverride: modelOverride
        )
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        print("🌐 Gemini streaming request: \(String(format: "%.1f", Double(bodyData.count) / 1_048_576.0))MB, \(images.count) image(s)")

        let requestedModel = modelOverride ?? model ?? "default"
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            DottieModelPicker.shared.record(model: requestedModel, seconds: Date().timeIntervalSince(startTime), statusCode: httpResponse.statusCode)
            var errorBodyLines: [String] = []
            for try await line in byteStream.lines {
                errorBodyLines.append(line)
            }
            throw NSError(
                domain: "GeminiAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBodyLines.joined(separator: "\n"))"]
            )
        }

        // Gemini SSE: each event is "data: {GenerateContentResponse}". Each
        // response carries only the new text, so we accumulate it ourselves.
        var accumulatedResponseText = ""
        var answeringModel: String?
        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if answeringModel == nil {
                answeringModel = DottieModelPicker.answeringModel(inText: jsonString)
            }
            guard let jsonData = jsonString.data(using: .utf8),
                  let responsePayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            let textChunk = Self.extractText(fromGenerateContentResponse: responsePayload)
            guard !textChunk.isEmpty else { continue }
            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        // Teaches the model picker how quick (or busy) this model is.
        DottieModelPicker.shared.record(model: requestedModel, seconds: duration, statusCode: 200, answeredBy: answeringModel)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Joins the text parts of the first candidate, skipping "thought" parts
    /// that thinking models may emit.
    private static func extractText(fromGenerateContentResponse responsePayload: [String: Any]) -> String {
        guard let candidates = responsePayload["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ""
        }
        return parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
    }
}
