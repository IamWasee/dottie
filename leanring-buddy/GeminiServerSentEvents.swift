//
//  GeminiServerSentEvents.swift
//  leanring-buddy
//
//  The Worker's /chat route streams Gemini's answer as server-sent events,
//  one "data: {...}" line per chunk, separated by CRLF. Swift treats "\r\n"
//  as a single Character, so splitting on "\n" never splits it and every
//  answer looked empty. This reads the events line by line however they
//  end.
//

import Foundation

enum GeminiServerSentEvents {
    /// Every content part of every event, in order, thoughts and function
    /// calls (with their thought signatures) included.
    static func parts(from responseData: Data, callerFile: String = #fileID) -> [[String: Any]] {
        var allParts: [[String: Any]] = []
        var lastUsageMetadata: [String: Any]?
        let responseText = String(decoding: responseData, as: UTF8.self)
        for line in responseText.components(separatedBy: .newlines) where line.hasPrefix("data:") {
            guard let eventData = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else { continue }
            // Each event carries the running total; the last one is final.
            if let usageMetadata = event["usageMetadata"] as? [String: Any] {
                lastUsageMetadata = usageMetadata
            }
            guard let candidates = event["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            allParts.append(contentsOf: parts)
        }
        if let lastUsageMetadata {
            recordUsageOnce(lastUsageMetadata, responseByteCount: responseData.count, callerFile: callerFile)
        }
        return allParts
    }

    /// The answer's text, without thinking parts.
    static func text(from responseData: Data, callerFile: String = #fileID) -> String {
        parts(from: responseData, callerFile: callerFile)
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    // MARK: - Usage

    private static var recentlyRecordedResponseKeys: [String] = []

    /// Some callers read the same response twice (its parts, then its
    /// text), so each response is counted once.
    private static func recordUsageOnce(_ usageMetadata: [String: Any], responseByteCount: Int, callerFile: String) {
        let usageDescription = ["promptTokenCount", "candidatesTokenCount", "thoughtsTokenCount", "totalTokenCount"]
            .map { "\(usageMetadata[$0] as? Int ?? 0)" }
            .joined(separator: "-")
        let responseKey = "\(callerFile)-\(responseByteCount)-\(usageDescription)"
        guard !recentlyRecordedResponseKeys.contains(responseKey) else { return }
        recentlyRecordedResponseKeys.append(responseKey)
        if recentlyRecordedResponseKeys.count > 50 {
            recentlyRecordedResponseKeys.removeFirst()
        }
        DottieUsage.shared.record(area: DottieUsage.area(forCallerFile: callerFile), usageMetadata: usageMetadata)
    }
}
