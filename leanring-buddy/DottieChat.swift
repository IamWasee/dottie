//
//  DottieChat.swift
//  leanring-buddy
//
//  One plain request through the Worker's /chat route, for the features
//  that just need text back (meeting notes, phone replies). Text-only asks
//  go to Groq first (fast; the Worker falls back to Gemini when Groq isn't
//  set up, is busy, or the ask is too big for its free plan). Asks with
//  pictures or audio stay on Gemini first.
//

import Foundation

enum DottieChat {
    /// Sends a Gemini generateContent body and returns the answer text, or
    /// nil when the request failed.
    static func send(_ requestBody: [String: Any], timeout: TimeInterval = 90, callerFile: String = #fileID) async -> String? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        guard var requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        let carriesPicturesOrAudio = String(decoding: requestBodyData, as: UTF8.self).contains("\"inlineData\"")
        if requestBody["provider"] == nil && !carriesPicturesOrAudio {
            var groqFirstRequestBody = requestBody
            groqFirstRequestBody["provider"] = "groq"
            if let groqFirstRequestBodyData = try? JSONSerialization.data(withJSONObject: groqFirstRequestBody) {
                requestBodyData = groqFirstRequestBodyData
            }
        }
        request.httpBody = requestBodyData

        guard let (responseData, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            print("⚠️ DottieChat request failed: \(String(decoding: responseData.prefix(300), as: UTF8.self))")
            return nil
        }
        // /chat streams server-sent events.
        let answerText = GeminiServerSentEvents.text(from: responseData, callerFile: callerFile)
        return answerText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A text-only request with an optional system prompt.
    static func ask(_ prompt: String, system: String? = nil, model: String, thinkingLevel: String? = nil, maxOutputTokens: Int? = nil, callerFile: String = #fileID) async -> String? {
        var requestBody: [String: Any] = [
            "model": model,
            "contents": [["role": "user", "parts": [["text": prompt]]]]
        ]
        if let system {
            requestBody["systemInstruction"] = ["parts": [["text": system]]]
        }
        var generationConfig: [String: Any] = [:]
        if let thinkingLevel {
            generationConfig["thinkingConfig"] = ["thinkingLevel": thinkingLevel]
        }
        if let maxOutputTokens {
            generationConfig["maxOutputTokens"] = maxOutputTokens
        }
        if !generationConfig.isEmpty {
            requestBody["generationConfig"] = generationConfig
        }
        return await send(requestBody, callerFile: callerFile)
    }
}
