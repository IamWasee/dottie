//
//  DottieWebSearch.swift
//  leanring-buddy
//
//  Web search for the voice companion. Gemini's own Google Search tool
//  closes Live sessions with "You exceeded your current quota" on a
//  free-tier key, so the voice model calls search_web instead, which asks
//  the Worker's /search route (DuckDuckGo, Wikipedia as a fallback, plus
//  the top page's text) and hands the results back as plain text.
//

import Foundation

enum DottieWebSearch {
    /// Results as text the voice model can answer from, or a short note
    /// saying the search didn't work so it can tell the user.
    static func search(_ query: String) async -> String {
        var urlComponents = URLComponents(url: ClickyWorkerConfiguration.url(forRoute: "/search"), resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let searchURL = urlComponents?.url else {
            return "the search didn't work. tell the user you couldn't look it up."
        }

        var request = URLRequest(url: searchURL)
        request.timeoutInterval = 20
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                return "the search didn't work. tell the user you couldn't look it up right now."
            }
            return formatResults(payload)
        } catch {
            print("⚠️ Web search failed: \(error.localizedDescription)")
            return "the search didn't work. tell the user you couldn't look it up right now."
        }
    }

    private static func formatResults(_ payload: [String: Any]) -> String {
        let results = payload["results"] as? [[String: Any]] ?? []
        guard !results.isEmpty else {
            return "the search found nothing. say so, and answer from what you know if you can, saying it may be out of date."
        }

        var lines = ["web results (newest information you have; answer from these and name the source briefly):"]
        for (index, result) in results.enumerated() {
            let title = result["title"] as? String ?? ""
            let url = result["url"] as? String ?? ""
            let snippet = result["snippet"] as? String ?? ""
            lines.append("\(index + 1). \(title) (\(url)): \(snippet)")
        }
        if let topPage = payload["topPage"] as? [String: Any],
           let topPageText = topPage["text"] as? String,
           let topPageURL = topPage["url"] as? String {
            lines.append("")
            lines.append("text of \(topPageURL):")
            lines.append(topPageText)
        }
        return lines.joined(separator: "\n")
    }
}
