//
//  SpendMeterTests.swift
//  leanring-buddyTests
//
//  The Claude call meter (newest calls kept one by one, average, most
//  expensive) and the per-day totals in Settings → Usage.
//

import Foundation
import Testing
@testable import Dottie

struct SpendMeterTests {
    private typealias Meter = DottieSpendMeter

    private func call(dollars: Double?, input: Int = 3_000, output: Int = 150, area: String = "voice") -> DottieMeteredCall {
        DottieMeteredCall(date: Date(timeIntervalSince1970: 1_800_000_000), area: area, model: "claude-haiku-5-5",
                          inputTokens: input, outputTokens: output, seconds: 1.2, dollars: dollars)
    }

    private func providerTotals(answers: Int, dollars: Double, withoutPrice: Int = 0) -> DottieUsage.ProviderTotals {
        DottieUsage.ProviderTotals(answers: answers, inputTokens: 0, outputTokens: 0, seconds: 0, dollars: dollars, answersWithoutPrice: withoutPrice)
    }

    // MARK: Keeping calls

    @Test func addingKeepsTheNewestLast() {
        let calls = Meter.adding(call(dollars: 0.002), to: [call(dollars: 0.001)])
        #expect(calls.map(\.dollars) == [0.001, 0.002])
    }

    @Test func addingDropsTheOldestPastTheLimit() {
        var calls: [DottieMeteredCall] = []
        for index in 0..<(Meter.maximumCallsKept + 5) {
            calls = Meter.adding(call(dollars: Double(index)), to: calls)
        }
        #expect(calls.count == Meter.maximumCallsKept)
        #expect(calls.first?.dollars == 5)
        #expect(calls.last?.dollars == Double(Meter.maximumCallsKept + 4))
    }

    @Test func meteredProviderIsClaude() {
        #expect(Meter.meteredProvider == "claude")
    }

    // MARK: Average and most expensive

    @Test func averageSkipsCallsWithoutAPrice() {
        let calls = [call(dollars: 0.001), call(dollars: nil), call(dollars: 0.003)]
        #expect(abs((Meter.averageDollarsPerCall(calls) ?? 0) - 0.002) < 0.0000001)
    }

    @Test func averageIsNilWithNoPricedCalls() {
        #expect(Meter.averageDollarsPerCall([]) == nil)
        #expect(Meter.averageDollarsPerCall([call(dollars: nil)]) == nil)
    }

    @Test func mostExpensiveCallIsFound() {
        let calls = [call(dollars: 0.001, area: "voice"), call(dollars: 0.009, area: "memory"), call(dollars: nil, area: "other")]
        #expect(Meter.highestDollarCall(calls)?.area == "memory")
    }

    @Test func mostExpensiveIsNilWithoutPrices() {
        #expect(Meter.highestDollarCall([call(dollars: nil)]) == nil)
    }

    @Test func averageTokensAreRounded() {
        let calls = [call(dollars: 0.001, input: 1_000, output: 100), call(dollars: 0.001, input: 2_001, output: 201)]
        let averageTokens = Meter.averageTokens(calls)
        #expect(averageTokens?.input == 1_501)
        #expect(averageTokens?.output == 151)
        #expect(Meter.averageTokens([]) == nil)
    }

    @Test func callDetailShowsTokensAndDollars() {
        #expect(Meter.callDetailText(call(dollars: 0.00042, input: 3_500, output: 150)) == "3,500 in · 150 out · $0.00042")
        #expect(Meter.callDetailText(call(dollars: nil, input: 10, output: 2)) == "10 in · 2 out · $?")
    }

    // MARK: Per day

    @Test func dayTotalAddsEveryProvider() {
        let daySpend = Meter.daySpend(dayKey: "2026-11-26", providers: [
            "claude": providerTotals(answers: 10, dollars: 0.05),
            "glm": providerTotals(answers: 4, dollars: 0.01, withoutPrice: 1),
            "groq": providerTotals(answers: 7, dollars: 0, withoutPrice: 7)
        ])
        #expect(abs(daySpend.dollars - 0.06) < 0.000001)
        #expect(daySpend.answers == 21)
        #expect(daySpend.answersWithoutPrice == 8)
        #expect(daySpend.dollarsByProvider.first?.provider == "claude")
    }

    @Test func breakdownLeavesOutProvidersThatSpentNothing() {
        let daySpend = Meter.daySpend(dayKey: "2026-11-26", providers: [
            "claude": providerTotals(answers: 10, dollars: 0.05),
            "jev": providerTotals(answers: 30, dollars: 0.003),
            "groq": providerTotals(answers: 7, dollars: 0, withoutPrice: 7)
        ])
        #expect(Meter.providerBreakdownText(daySpend) == "Claude $0.05, Jev $0.00300")
    }

    @Test func emptyDayHasNothing() {
        let daySpend = Meter.daySpend(dayKey: "2026-11-26", providers: [:])
        #expect(daySpend.dollars == 0)
        #expect(daySpend.answers == 0)
        #expect(Meter.providerBreakdownText(daySpend).isEmpty)
    }

    @Test func providersWithTheSameSpendSortByName() {
        let daySpend = Meter.daySpend(dayKey: "2026-11-26", providers: [
            "glm": providerTotals(answers: 1, dollars: 0.01),
            "claude": providerTotals(answers: 1, dollars: 0.01)
        ])
        #expect(daySpend.dollarsByProvider.map(\.provider) == ["claude", "glm"])
    }

    // MARK: Journey: a day of asks reaches the meter and the day total

    @Test func dayOfAsksJourney() {
        var calls: [DottieMeteredCall] = []
        var claudeTotals = DottieUsage.ProviderTotals()
        for _ in 0..<12 {
            let usage = DottieAskUsage(provider: "claude", model: "claude-haiku-5-5", inputTokens: 3_500, outputTokens: 150,
                                       seconds: 1.4, estimatedDollars: 0.000425)
            calls = Meter.adding(call(dollars: usage.estimatedDollars, input: usage.inputTokens, output: usage.outputTokens), to: calls)
            claudeTotals = DottieUsage.adding(usage, to: claudeTotals)
        }
        let jevTotals = (0..<40).reduce(DottieUsage.ProviderTotals()) { totals, _ in
            DottieUsage.adding(.jevAnswer(seconds: 0.4), to: totals)
        }
        #expect(abs((Meter.averageDollarsPerCall(calls) ?? 0) - 0.000425) < 0.0000001)
        let daySpend = Meter.daySpend(dayKey: "2026-11-27", providers: ["claude": claudeTotals, "jev": jevTotals])
        #expect(abs(daySpend.dollars - (12 * 0.000425 + 40 * 0.0001)) < 0.0000001)
        #expect(daySpend.answers == 52)
    }

    // MARK: Speed

    @Test func meterMathIsQuick() {
        let calls = (0..<Meter.maximumCallsKept).map { call(dollars: Double($0) / 10_000) }
        let startedAt = Date()
        for _ in 0..<2_000 {
            _ = Meter.adding(call(dollars: 0.001), to: calls)
            _ = Meter.averageDollarsPerCall(calls)
            _ = Meter.highestDollarCall(calls)
            _ = Meter.averageTokens(calls)
        }
        // The Usage page redraws with these: thousands a second is plenty.
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
