//
//  DottieAskUsage.swift
//  leanring-buddy
//
//  Which model answered each ask, its tokens, how long it took and what it
//  cost. The Worker puts a `dottieUsage` object on every answer (provider,
//  model, tokens, seconds, estimated dollars, or null when the model has no
//  price set); Jev answers are counted here at its flat price. Each one
//  becomes one log line whose numbers and model names always show (they
//  aren't personal), tagged with the number of the user's ask, so a tester
//  can read per test which models ran and what they cost. Totals per
//  provider go to DottieUsage for Settings → Usage. Foundation only, so it
//  can be unit tested.
//

import Foundation

/// One model answer's usage, as the Worker reported it.
nonisolated struct DottieAskUsage: Equatable, Sendable {
    let provider: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let seconds: Double
    /// nil when the Worker has no price for the model.
    let estimatedDollars: Double?

    /// Jev (TypeSafe's System One) costs $1 per 10,000 decisions.
    static let jevDollarsPerAnswer = 0.0001

    /// Reads `dottieUsage` from one answer event; nil when there's none or
    /// it doesn't name a provider and model.
    static func fromAnswerEvent(_ event: [String: Any]) -> DottieAskUsage? {
        guard let usageObject = event["dottieUsage"] as? [String: Any],
              let provider = usageObject["provider"] as? String, !provider.isEmpty,
              let model = usageObject["model"] as? String, !model.isEmpty else { return nil }
        func integer(_ key: String) -> Int {
            max((usageObject[key] as? NSNumber)?.intValue ?? 0, 0)
        }
        let seconds = max((usageObject["seconds"] as? NSNumber)?.doubleValue ?? 0, 0)
        let dollars = (usageObject["estimatedDollars"] as? NSNumber)?.doubleValue
        return DottieAskUsage(
            provider: provider,
            model: model,
            inputTokens: integer("inputTokens"),
            outputTokens: integer("outputTokens"),
            seconds: seconds,
            estimatedDollars: dollars.map { max($0, 0) }
        )
    }

    /// The `dottieUsage` of the last event in a server-sent-events answer.
    static func fromServerSentEvents(_ responseText: String) -> DottieAskUsage? {
        var lastUsage: DottieAskUsage?
        for line in responseText.components(separatedBy: .newlines) where line.hasPrefix("data:") {
            guard let eventData = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let usage = fromAnswerEvent(event) else { continue }
            lastUsage = usage
        }
        return lastUsage
    }

    static func jevAnswer(seconds: Double) -> DottieAskUsage {
        DottieAskUsage(provider: "jev", model: "jev", inputTokens: 0, outputTokens: 0, seconds: max(seconds, 0), estimatedDollars: jevDollarsPerAnswer)
    }

    /// "$0.00021", or "$?" when the price isn't known.
    var dollarsText: String {
        guard let estimatedDollars else { return "$?" }
        return Self.dollarsText(estimatedDollars)
    }

    static func dollarsText(_ dollars: Double) -> String {
        if dollars == 0 { return "$0" }
        if dollars < 0.01 { return String(format: "$%.5f", dollars) }
        return String(format: "$%.2f", dollars)
    }

    /// The log line for this answer. Everything in it is public on purpose.
    /// `costCategory` (DottieCostCategory) says which feature it was for.
    func logText(askNumber: Int, area: String, costCategory: String? = nil) -> String {
        let areaText = costCategory.map { "\(area) [\($0)]" } ?? area
        return "💵 usage ask \(askNumber) · \(areaText) · \(provider)/\(model) · \(inputTokens) in / \(outputTokens) out · "
            + String(format: "%.2f s", seconds) + " · \(dollarsText)"
    }
}

/// Numbers the user's asks, so every model call can be tied to the ask it
/// served. Thread safe: answers are read on any thread.
nonisolated enum DottieAskCounter {
    private static let lock = NSLock()
    private static var askNumber = 0

    /// A new spoken or typed turn started.
    @discardableResult
    static func startNewAsk() -> Int {
        lock.lock()
        defer { lock.unlock() }
        askNumber += 1
        return askNumber
    }

    static var currentAskNumber: Int {
        lock.lock()
        defer { lock.unlock() }
        return askNumber
    }
}

nonisolated enum DottieAskUsageLog {
    /// Logs one answer's usage and adds it to the day's totals.
    static func note(_ usage: DottieAskUsage, area: DottieUsage.Area, costCategory: String? = nil) {
        DottieLog.notice("\(public: usage.logText(askNumber: DottieAskCounter.currentAskNumber, area: area.rawValue, costCategory: costCategory))")
        Task { @MainActor in
            DottieUsage.shared.recordProviderAnswer(usage)
        }
    }
}
