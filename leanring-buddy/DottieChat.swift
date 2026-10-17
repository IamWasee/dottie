//
//  DottieChat.swift
//  leanring-buddy
//
//  One plain request to Gemini through the Worker's /chat route, for the
//  features that just need text back (meeting notes, phone replies).
//

import Foundation

enum DottieChat {
    /// Sends a Gemini generateContent body and returns the answer text, or
    /// nil when the request failed.
    static func send(_ requestBody: [String: Any], timeout: TimeInterval = 90) async -> String? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        request.httpBody = requestBodyData

        guard let (responseData, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            print("⚠️ DottieChat request failed: \(String(decoding: responseData.prefix(300), as: UTF8.self))")
            return nil
        }
        // /chat streams server-sent events.
        let answerText = GeminiServerSentEvents.text(from: responseData)
        return answerText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A text-only request with an optional system prompt.
    static func ask(_ prompt: String, system: String? = nil, model: String, thinkingLevel: String? = nil) async -> String? {
        var requestBody: [String: Any] = [
            "model": model,
            "contents": [["role": "user", "parts": [["text": prompt]]]]
        ]
        if let system {
            requestBody["systemInstruction"] = ["parts": [["text": system]]]
        }
        if let thinkingLevel {
            requestBody["generationConfig"] = ["thinkingConfig": ["thinkingLevel": thinkingLevel]]
        }
        return await send(requestBody)
    }
}
