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
    static func parts(from responseData: Data) -> [[String: Any]] {
        var allParts: [[String: Any]] = []
        let responseText = String(decoding: responseData, as: UTF8.self)
        for line in responseText.components(separatedBy: .newlines) where line.hasPrefix("data:") {
            guard let eventData = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let candidates = event["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            allParts.append(contentsOf: parts)
        }
        return allParts
    }

    /// The answer's text, without thinking parts.
    static func text(from responseData: Data) -> String {
        parts(from: responseData)
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
    }
}
