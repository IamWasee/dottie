//
//  DottieSpendMeter.swift
//  leanring-buddy
//
//  The Claude call meter and the per-day totals in Settings → Usage. Wasee
//  (27 Nov) wanted to see whether each Claude Haiku call really costs about
//  what the price list says, and what Dottie spends each day: the newest
//  Claude calls are kept one by one (when, what for, tokens, dollars), and
//  every day's answers add up to one total across providers. Foundation
//  only, so it can be unit tested.
//

import Foundation

/// One model call, kept for the meter.
nonisolated struct DottieMeteredCall: Codable, Equatable, Sendable {
    let date: Date
    /// What it was for: the usage area ("Voice", "Screen tasks and games").
    let area: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let seconds: Double
    /// nil when the Worker had no price for the model.
    let dollars: Double?
}

/// One day's spend across every provider.
nonisolated struct DottieDaySpend: Equatable, Sendable {
    let dayKey: String
    let dollars: Double
    let answers: Int
    /// Answers whose model had no price, so `dollars` leaves them out.
    let answersWithoutPrice: Int
    /// Each provider's dollars that day, biggest first.
    let dollarsByProvider: [(provider: String, dollars: Double)]

    static func == (first: DottieDaySpend, second: DottieDaySpend) -> Bool {
        first.dayKey == second.dayKey && first.dollars == second.dollars && first.answers == second.answers
            && first.answersWithoutPrice == second.answersWithoutPrice
            && first.dollarsByProvider.map(\.provider) == second.dollarsByProvider.map(\.provider)
            && first.dollarsByProvider.map(\.dollars) == second.dollarsByProvider.map(\.dollars)
    }
}

nonisolated enum DottieSpendMeter {
    /// The provider name the Worker reports for Claude.
    static let meteredProvider = "claude"
    /// How many of the newest Claude calls the meter keeps.
    static let maximumCallsKept = 30

    /// The calls with the newest one added, oldest dropped past the limit.
    static func adding(_ call: DottieMeteredCall, to calls: [DottieMeteredCall]) -> [DottieMeteredCall] {
        var updatedCalls = calls
        updatedCalls.append(call)
        if updatedCalls.count > maximumCallsKept {
            updatedCalls.removeFirst(updatedCalls.count - maximumCallsKept)
        }
        return updatedCalls
    }

    /// Average dollars per call over the calls that had a price; nil when none did.
    static func averageDollarsPerCall(_ calls: [DottieMeteredCall]) -> Double? {
        let pricedDollars = calls.compactMap(\.dollars)
        guard !pricedDollars.isEmpty else { return nil }
        return pricedDollars.reduce(0, +) / Double(pricedDollars.count)
    }

    static func highestDollarCall(_ calls: [DottieMeteredCall]) -> DottieMeteredCall? {
        calls.filter { $0.dollars != nil }.max { ($0.dollars ?? 0) < ($1.dollars ?? 0) }
    }

    /// Average tokens in and out per call, rounded.
    static func averageTokens(_ calls: [DottieMeteredCall]) -> (input: Int, output: Int)? {
        guard !calls.isEmpty else { return nil }
        var inputTotal = 0
        var outputTotal = 0
        for call in calls {
            inputTotal += call.inputTokens
            outputTotal += call.outputTokens
        }
        let callCount = Double(calls.count)
        let averageInput = Int((Double(inputTotal) / callCount).rounded())
        let averageOutput = Int((Double(outputTotal) / callCount).rounded())
        return (averageInput, averageOutput)
    }

    /// One day's total from each provider's totals that day.
    static func daySpend(dayKey: String, providers: [String: DottieUsage.ProviderTotals]) -> DottieDaySpend {
        let dollarsByProvider = providers
            .map { (provider: $0.key, dollars: $0.value.dollars) }
            .sorted { $0.dollars == $1.dollars ? $0.provider < $1.provider : $0.dollars > $1.dollars }
        var totalDollars = 0.0
        var totalAnswers = 0
        var totalAnswersWithoutPrice = 0
        for providerTotals in providers.values {
            totalDollars += providerTotals.dollars
            totalAnswers += providerTotals.answers
            totalAnswersWithoutPrice += providerTotals.answersWithoutPrice
        }
        return DottieDaySpend(
            dayKey: dayKey,
            dollars: totalDollars,
            answers: totalAnswers,
            answersWithoutPrice: totalAnswersWithoutPrice,
            dollarsByProvider: dollarsByProvider
        )
    }

    /// "Claude $0.05, Glm $0.01" for a day row, providers that spent nothing left out.
    static func providerBreakdownText(_ daySpend: DottieDaySpend) -> String {
        daySpend.dollarsByProvider
            .filter { $0.dollars > 0 }
            .map { "\($0.provider.capitalized) \(DottieAskUsage.dollarsText($0.dollars))" }
            .joined(separator: ", ")
    }

    /// "1,834 in · 120 out · $0.00024" for one call.
    static func callDetailText(_ call: DottieMeteredCall) -> String {
        let dollarsText = call.dollars.map(DottieAskUsage.dollarsText) ?? "$?"
        return "\(call.inputTokens.formatted()) in · \(call.outputTokens.formatted()) out · \(dollarsText)"
    }
}
