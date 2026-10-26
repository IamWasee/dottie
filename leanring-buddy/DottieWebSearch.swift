//
//  DottieWebSearch.swift
//  leanring-buddy
//
//  Web search for the voice companion. Gemini's own Google Search tool
//  closes Live sessions with "You exceeded your current quota" on a
//  free-tier key, so the voice model calls search_web instead, which asks
//  the Worker's /search route (Bing and DuckDuckGo, Wikipedia as a
//  fallback, plus the top page's text) and hands the results back as
//  plain text.
//
//  Search engines treat Cloudflare's addresses as robots: Bing often
//  searches for one word of the question and DuckDuckGo answers with a
//  challenge page. When the Worker's results don't cover the question,
//  the Mac asks DuckDuckGo itself, from the user's own connection, which
//  the engines answer like any browser.
//

import Foundation

enum DottieWebSearch {
    /// Below this share of the question's words in the Worker's first
    /// results, the Mac searches on its own too.
    private static let goodWorkerCoverage = 0.6

    /// Results as text the voice model can answer from, or a short note
    /// saying the search didn't work so it can tell the user.
    static func search(_ query: String) async -> String {
        let workerPayload = await searchThroughWorker(query)
        let workerResults = workerPayload?["results"] as? [[String: Any]] ?? []
        let workerCoverage = questionWordCoverage(query: query, results: workerResults)

        if workerCoverage < goodWorkerCoverage {
            async let duckDuckGoResults = searchDuckDuckGoFromThisMac(query)
            async let bingResults = searchBingFromThisMac(query)
            let macAnswers = [(engineName: "DuckDuckGo", results: await duckDuckGoResults), (engineName: "Bing", results: await bingResults)]
            if let bestMacAnswer = macAnswers
                .map({ (engineName: $0.engineName, results: $0.results, coverage: questionWordCoverage(query: query, results: $0.results)) })
                .filter({ !$0.results.isEmpty && $0.coverage > workerCoverage })
                .max(by: { $0.coverage < $1.coverage }) {
                print("🔎 Web search: the Worker's results missed \"\(query)\", used \(bestMacAnswer.engineName) from this Mac")
                return formatResults(["results": bestMacAnswer.results])
            }
        }

        guard let workerPayload else {
            return "the search didn't work. tell the user you couldn't look it up right now."
        }
        guard workerCoverage >= weakResultsCoverage || workerResults.isEmpty else {
            // Dictionary pages for "won" shouldn't be read out as the answer.
            return "these results barely match the question, so the search engine probably misread it. if they don't answer it, say the search didn't find it and answer from what you know, saying it may be out of date.\n\n"
                + formatResults(workerPayload)
        }
        return formatResults(workerPayload)
    }

    /// Below this, the results are flagged to the model as probably off.
    private static let weakResultsCoverage = 0.34

    private static func searchThroughWorker(_ query: String) async -> [String: Any]? {
        var urlComponents = URLComponents(url: ClickyWorkerConfiguration.url(forRoute: "/search"), resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let searchURL = urlComponents?.url else { return nil }

        var request = URLRequest(url: searchURL)
        request.timeoutInterval = 20
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        } catch {
            print("⚠️ Web search failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static let questionFillerWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "and", "or", "is", "are", "was", "were", "be",
        "what", "whats", "who", "whos", "when", "where", "why", "how", "which", "does", "do", "did", "can",
        "me", "my", "i", "you", "it", "this", "that", "tell", "about", "please", "now", "today", "current", "latest"
    ]

    /// How many of the question's words (0 to 1) show up in the first
    /// three results' titles, snippets and addresses. "who won the 2025
    /// world series" answered with dictionary pages for "won" scores 0.25.
    static func questionWordCoverage(query: String, results: [[String: Any]]) -> Double {
        let allQueryWords = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let meaningfulQueryWords = allQueryWords.filter { !questionFillerWords.contains($0) }
        let queryWords = Set(meaningfulQueryWords.isEmpty ? allQueryWords : meaningfulQueryWords)
        guard !queryWords.isEmpty, !results.isEmpty else { return 0 }

        let resultsText = results.prefix(3).map { result in
            [result["title"], result["snippet"], result["url"]].compactMap { $0 as? String }.joined(separator: " ")
        }.joined(separator: " ").lowercased()
        let mentionedWordCount = queryWords.filter { resultsText.contains($0) }.count
        return Double(mentionedWordCount) / Double(queryWords.count)
    }

    // MARK: Searching from this Mac

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"

    /// DuckDuckGo's plain results page, posted like its own search box.
    /// Empty when it can't be reached or answers with a challenge.
    private static func searchDuckDuckGoFromThisMac(_ query: String) async -> [[String: Any]] {
        guard let duckDuckGoURL = URL(string: "https://html.duckduckgo.com/html/") else { return [] }
        var request = URLRequest(url: duckDuckGoURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var formComponents = URLComponents()
        formComponents.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "us-en")]
        request.httpBody = formComponents.percentEncodedQuery?.data(using: .utf8)

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return duckDuckGoResults(fromResultsPage: String(decoding: responseData, as: UTF8.self))
    }

    /// Bing's results page, asked from this Mac.
    private static func searchBingFromThisMac(_ query: String) async -> [[String: Any]] {
        var urlComponents = URLComponents(string: "https://www.bing.com/search")
        urlComponents?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "setlang", value: "en")]
        guard let bingURL = urlComponents?.url else { return [] }
        var request = URLRequest(url: bingURL)
        request.timeoutInterval = 8
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return bingResults(fromResultsPage: String(decoding: responseData, as: UTF8.self))
    }

    /// Title, address and snippet of each result on Bing's page.
    static func bingResults(fromResultsPage resultsPageHTML: String) -> [[String: Any]] {
        guard let titleLinkPattern = try? NSRegularExpression(pattern: #"<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#),
              let snippetPattern = try? NSRegularExpression(pattern: #"<p[^>]*>([\s\S]*?)</p>"#) else { return [] }

        var results: [[String: Any]] = []
        for resultBlock in resultsPageHTML.components(separatedBy: #"<li class="b_algo""#).dropFirst() {
            let blockRange = NSRange(resultBlock.startIndex..., in: resultBlock)
            guard let titleLinkMatch = titleLinkPattern.firstMatch(in: resultBlock, range: blockRange),
                  let addressRange = Range(titleLinkMatch.range(at: 1), in: resultBlock),
                  let titleRange = Range(titleLinkMatch.range(at: 2), in: resultBlock) else { continue }
            var resultAddress = decodedHTMLEntities(String(resultBlock[addressRange]))
            // Bing wraps links as /ck/a?...&u=a1<base64url of the real address>.
            if let wrappedTarget = URLComponents(string: resultAddress)?.queryItems?.first(where: { $0.name == "u" })?.value,
               wrappedTarget.hasPrefix("a1") {
                var base64Text = String(wrappedTarget.dropFirst(2))
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                base64Text += String(repeating: "=", count: (4 - base64Text.count % 4) % 4)
                guard let decodedData = Data(base64Encoded: base64Text) else { continue }
                resultAddress = String(decoding: decodedData, as: UTF8.self)
            }
            guard resultAddress.hasPrefix("http") else { continue }
            var snippet = ""
            if let snippetMatch = snippetPattern.firstMatch(in: resultBlock, range: blockRange),
               let snippetRange = Range(snippetMatch.range(at: 1), in: resultBlock) {
                snippet = plainText(fromHTML: String(resultBlock[snippetRange]))
            }
            results.append([
                "title": plainText(fromHTML: String(resultBlock[titleRange])),
                "url": resultAddress,
                "snippet": snippet
            ])
            if results.count == 6 { break }
        }
        return results
    }

    /// Title, address and snippet of each result on DuckDuckGo's plain
    /// page, leaving out its ads.
    static func duckDuckGoResults(fromResultsPage resultsPageHTML: String) -> [[String: Any]] {
        guard let resultPattern = try? NSRegularExpression(
            pattern: #"class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>[\s\S]*?class="result__snippet"[^>]*>([\s\S]*?)</a>"#
        ) else { return [] }

        var results: [[String: Any]] = []
        let wholePageRange = NSRange(resultsPageHTML.startIndex..., in: resultsPageHTML)
        for match in resultPattern.matches(in: resultsPageHTML, range: wholePageRange) {
            func capturedText(_ groupIndex: Int) -> String {
                guard let groupRange = Range(match.range(at: groupIndex), in: resultsPageHTML) else { return "" }
                return String(resultsPageHTML[groupRange])
            }
            var resultAddress = decodedHTMLEntities(capturedText(1))
            // Links go through DuckDuckGo's redirect, with the real address in uddg=.
            if let redirectComponents = URLComponents(string: resultAddress.hasPrefix("//") ? "https:" + resultAddress : resultAddress),
               let realAddress = redirectComponents.queryItems?.first(where: { $0.name == "uddg" })?.value {
                resultAddress = realAddress
            }
            if resultAddress.hasPrefix("//") { resultAddress = "https:" + resultAddress }
            guard resultAddress.hasPrefix("http"), !resultAddress.contains("duckduckgo.com/y.js") else { continue }
            results.append([
                "title": plainText(fromHTML: capturedText(2)),
                "url": resultAddress,
                "snippet": plainText(fromHTML: capturedText(3))
            ])
            if results.count == 6 { break }
        }
        return results
    }

    private static func plainText(fromHTML html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodedHTMLEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodedHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Text for the model

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
