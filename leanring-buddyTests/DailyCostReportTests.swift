//
//  DailyCostReportTests.swift
//  leanring-buddyTests
//
//  The daily cost report: totals across providers, the lines per provider
//  and per feature, the notification's words, token counts written short,
//  showing once a day, a day-of-use journey and a speed check.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct DailyCostReportTests {
    private typealias Report = DottieDailyCostReport

    private func totals(answers: Int, inputTokens: Int = 0, outputTokens: Int = 0, dollars: Double, withoutPrice: Int = 0) -> DottieUsage.ProviderTotals {
        DottieUsage.ProviderTotals(answers: answers, inputTokens: inputTokens, outputTokens: outputTokens, seconds: 0,
                                   dollars: dollars, answersWithoutPrice: withoutPrice)
    }

    @Test func reportAddsUpEveryProvider() throws {
        let report = try #require(Report.report(dayKey: "2026-11-26", providers: [
            "claude": totals(answers: 12, inputTokens: 40_000, outputTokens: 1_800, dollars: 0.005),
            "jev": totals(answers: 40, dollars: 0.004),
            "groq": totals(answers: 9, inputTokens: 9_000, outputTokens: 400, dollars: 0, withoutPrice: 9)
        ], features: [
            "voice": totals(answers: 20, dollars: 0.004),
            "jev": totals(answers: 40, dollars: 0.004),
            "jev_advisor": totals(answers: 2, dollars: 0.001)
        ]))
        #expect(abs(report.totalDollars - 0.009) < 0.0000001)
        #expect(report.answers == 61)
        #expect(report.answersWithoutPrice == 9)
        #expect(report.inputTokens == 49_000)
        #expect(report.outputTokens == 2_200)
        #expect(report.providers.map(\.name) == ["claude", "jev", "groq"])
        #expect(report.features.map(\.name) == ["jev", "voice", "jev_advisor"])
    }

    @Test func aDayWithNoAnswersHasNoReport() {
        #expect(Report.report(dayKey: "2026-11-26", providers: [:], features: [:]) == nil)
        #expect(Report.report(dayKey: "2026-11-26", providers: ["claude": totals(answers: 0, dollars: 0)], features: [:]) == nil)
    }

    @Test func notificationSaysTheTotalProvidersAndTopFeatures() throws {
        let report = try #require(Report.report(dayKey: "2026-11-26", providers: [
            "claude": totals(answers: 12, inputTokens: 1_260_000, outputTokens: 18_000, dollars: 0.13),
            "groq": totals(answers: 3, dollars: 0, withoutPrice: 3)
        ], features: [
            "voice": totals(answers: 10, dollars: 0.1),
            "screen_job_plan": totals(answers: 1, dollars: 0.02),
            "memory": totals(answers: 1, dollars: 0.006),
            "phone": totals(answers: 1, dollars: 0.004)
        ]))
        #expect(report.notificationTitle == "Dottie spent $0.13 yesterday")
        let body = report.notificationBody
        #expect(body.contains("15 answers · 1.3M tokens in, 18.0K out."))
        #expect(body.contains("Claude $0.13."))
        #expect(!body.contains("Groq $"))
        #expect(body.contains("Most went to voice $0.10, screen job plan $0.02, memory $0.00600."))
        #expect(!body.contains("phone"))
        #expect(body.contains("3 answers had no price."))
    }

    @Test func tokensAreWrittenShort() {
        #expect(Report.tokensText(950) == "950")
        #expect(Report.tokensText(12_345) == "12.3K")
        #expect(Report.tokensText(3_400_000) == "3.4M")
        #expect(Report.tokensText(-5) == "0")
    }

    @Test func lineDetailHasEveryNumber() {
        let line = Report.Line(name: "claude", answers: 4, inputTokens: 12_300, outputTokens: 450, dollars: 0.0012)
        #expect(Report.lineDetail(line) == "4 answers · 12.3K in · 450 out · $0.00120")
    }

    @Test func featureNamesReadAsWords() {
        #expect(Report.featureName("screen_job_steps") == "screen job steps")
        #expect(Report.featureName("Voice") == "Voice")
    }

    @Test func itShowsOnceADay() {
        #expect(Report.shouldShow(reportDayKey: "2026-11-26", lastShownDayKey: nil))
        #expect(Report.shouldShow(reportDayKey: "2026-11-26", lastShownDayKey: "2026-11-25"))
        #expect(!Report.shouldShow(reportDayKey: "2026-11-26", lastShownDayKey: "2026-11-26"))
    }

    @Test func dayKeysAreDates() {
        let date = DateComponents(calendar: Calendar.current, year: 2026, month: 11, day: 27, hour: 2).date ?? Date()
        #expect(DottieUsage.dayKey(for: date) == "2026-11-27")
    }

    /// A day of use: voice asks on Claude, Jev steps, two advisor calls and
    /// a Groq chat with no price, added the way DottieUsage adds them; the
    /// next morning's report has every number.
    @Test func dayOfUseJourney() throws {
        var providers: [String: DottieUsage.ProviderTotals] = [:]
        var features: [String: DottieUsage.ProviderTotals] = [:]
        func record(_ usage: DottieAskUsage, feature: String) {
            providers[usage.provider] = DottieUsage.adding(usage, to: providers[usage.provider] ?? DottieUsage.ProviderTotals())
            features[feature] = DottieUsage.adding(usage, to: features[feature] ?? DottieUsage.ProviderTotals())
        }
        for _ in 0..<8 {
            record(DottieAskUsage(provider: "claude", model: "claude-haiku-5-5", inputTokens: 3_500, outputTokens: 150,
                                  seconds: 1.4, estimatedDollars: 0.000425), feature: "voice")
        }
        for _ in 0..<30 { record(.jevAnswer(seconds: 0.5), feature: "jev") }
        for _ in 0..<2 {
            record(DottieAskUsage(provider: "claude", model: "claude-haiku-5-5", inputTokens: 2_300, outputTokens: 60,
                                  seconds: 0.9, estimatedDollars: 0.00026), feature: "jev_advisor")
        }
        record(DottieAskUsage(provider: "groq", model: "gpt-oss-20b", inputTokens: 800, outputTokens: 40,
                              seconds: 0.3, estimatedDollars: nil), feature: "voice")
        let report = try #require(Report.report(dayKey: "2026-11-26", providers: providers, features: features))
        #expect(report.answers == 41)
        #expect(abs(report.totalDollars - (8 * 0.000425 + 30 * 0.0001 + 2 * 0.00026)) < 0.0000001)
        #expect(report.answersWithoutPrice == 1)
        #expect(report.features.first?.name == "voice")
        #expect(report.features.contains { $0.name == "jev_advisor" && $0.answers == 2 })
        #expect(report.notificationBody.contains("Most went to voice"))
    }

    @Test func buildingTheReportIsQuick() {
        let providers = Dictionary(uniqueKeysWithValues: (0..<10).map { ("provider\($0)", totals(answers: 100, inputTokens: 10_000, dollars: 0.01)) })
        let features = Dictionary(uniqueKeysWithValues: (0..<40).map { ("feature\($0)", totals(answers: 25, dollars: 0.0025)) })
        let startedAt = Date()
        for _ in 0..<1_000 {
            _ = Report.report(dayKey: "2026-11-26", providers: providers, features: features)?.notificationBody
        }
        // Settings → Usage redraws with this: a thousand in under a second is plenty.
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
