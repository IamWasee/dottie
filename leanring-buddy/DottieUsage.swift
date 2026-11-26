//
//  DottieUsage.swift
//  leanring-buddy
//
//  Counts the tokens Dottie spends, per area, so changes that are meant to
//  save tokens can be judged on real numbers instead of estimates. Gemini
//  reports usage on each answer (usageMetadata, and Gemini CLI's result
//  stats); Claude helper turns are counted as turns and time, since
//  MausBot doesn't report tokens. Also keeps how long voice answers take
//  to start, so saving tokens never quietly makes Dottie slower.
//
//  Kept per day in UserDefaults, last 14 days. Shown in Settings → Usage.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class DottieUsage: ObservableObject {
    static let shared = DottieUsage()

    enum Area: String, CaseIterable, Codable, Sendable {
        case voice = "Voice"
        case screenTasks = "Screen tasks and games"
        case pointing = "Pointing and teaching"
        case memory = "Memory"
        case geminiHelpers = "Helpers on GLM"
        case claudeHelpers = "Helpers on Claude"
        case otherGemini = "Other model calls"
    }

    struct AreaTotals: Codable, Equatable {
        var inputTokens = 0
        var outputTokens = 0
        var requests = 0
        var seconds = 0.0
    }

    /// One provider's answers in a day ("claude", "glm", "groq", "jev").
    struct ProviderTotals: Codable, Equatable {
        var answers = 0
        var inputTokens = 0
        var outputTokens = 0
        var seconds = 0.0
        /// Dollars for the answers whose price was known.
        var dollars = 0.0
        /// Answers the Worker had no price for, so `dollars` leaves them out.
        var answersWithoutPrice = 0
    }

    struct DayTotals: Codable, Equatable {
        var areas: [String: AreaTotals] = [:]
        /// Optional so days saved before per-provider totals still load.
        var providers: [String: ProviderTotals]? = nil
        var voiceAnswerStartSecondsTotal = 0.0
        var voiceAnswerStartCount = 0
    }

    @Published private(set) var days: [String: DayTotals] = [:]
    /// The newest Claude calls one by one, for the call meter.
    @Published private(set) var meteredCalls: [DottieMeteredCall] = []

    private static let defaultsKey = "dottieUsageByDay"
    private static let meteredCallsDefaultsKey = "dottieMeteredClaudeCalls"
    private static let daysKept = 14
    private var pendingSaveTask: Task<Void, Never>?

    private init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let savedDays = try? JSONDecoder().decode([String: DayTotals].self, from: savedData) {
            days = savedDays
        }
        if let savedCallsData = UserDefaults.standard.data(forKey: Self.meteredCallsDefaultsKey),
           let savedCalls = try? JSONDecoder().decode([DottieMeteredCall].self, from: savedCallsData) {
            meteredCalls = savedCalls
        }
    }

    // MARK: - Recording

    func record(area: Area, inputTokens: Int, outputTokens: Int, seconds: Double = 0) {
        let todayKey = Self.dayKey(for: Date())
        var today = days[todayKey] ?? DayTotals()
        var areaTotals = today.areas[area.rawValue] ?? AreaTotals()
        areaTotals.inputTokens += max(inputTokens, 0)
        areaTotals.outputTokens += max(outputTokens, 0)
        areaTotals.requests += 1
        areaTotals.seconds += max(seconds, 0)
        today.areas[area.rawValue] = areaTotals
        days[todayKey] = today
        scheduleSave()
    }

    /// Records Gemini's usageMetadata object (generateContent, streaming or Live).
    func record(area: Area, usageMetadata: [String: Any]) {
        let inputTokens = (usageMetadata["promptTokenCount"] as? Int) ?? 0
        // Live calls the answer "responseTokenCount", generateContent
        // "candidatesTokenCount"; thinking is billed as output too.
        let answerTokens = (usageMetadata["candidatesTokenCount"] as? Int)
            ?? (usageMetadata["responseTokenCount"] as? Int)
            ?? 0
        let thinkingTokens = (usageMetadata["thoughtsTokenCount"] as? Int) ?? 0
        guard inputTokens + answerTokens + thinkingTokens > 0 else { return }
        record(area: area, inputTokens: inputTokens, outputTokens: answerTokens + thinkingTokens)
    }

    /// For code that isn't on the main actor (streaming readers): reads the
    /// counts here and records them on the main actor.
    nonisolated static func recordFromAnyThread(area: Area, usageMetadata: [String: Any]) {
        let inputTokens = (usageMetadata["promptTokenCount"] as? Int) ?? 0
        let answerTokens = (usageMetadata["candidatesTokenCount"] as? Int)
            ?? (usageMetadata["responseTokenCount"] as? Int)
            ?? 0
        let thinkingTokens = (usageMetadata["thoughtsTokenCount"] as? Int) ?? 0
        guard inputTokens + answerTokens + thinkingTokens > 0 else { return }
        Task { @MainActor in
            DottieUsage.shared.record(area: area, inputTokens: inputTokens, outputTokens: answerTokens + thinkingTokens)
        }
    }

    /// One model answer's provider, tokens, time and cost (DottieAskUsage).
    /// `purpose` (the cost category or area) labels Claude calls on the meter.
    func recordProviderAnswer(_ usage: DottieAskUsage, purpose: String = "") {
        if usage.provider == DottieSpendMeter.meteredProvider {
            meteredCalls = DottieSpendMeter.adding(DottieMeteredCall(
                date: Date(), area: purpose, model: usage.model, inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens, seconds: usage.seconds, dollars: usage.estimatedDollars
            ), to: meteredCalls)
        }
        let todayKey = Self.dayKey(for: Date())
        var today = days[todayKey] ?? DayTotals()
        var providers = today.providers ?? [:]
        providers[usage.provider] = Self.adding(usage, to: providers[usage.provider] ?? ProviderTotals())
        today.providers = providers
        days[todayKey] = today
        scheduleSave()
    }

    nonisolated static func adding(_ usage: DottieAskUsage, to providerTotals: ProviderTotals) -> ProviderTotals {
        var updatedTotals = providerTotals
        updatedTotals.answers += 1
        updatedTotals.inputTokens += usage.inputTokens
        updatedTotals.outputTokens += usage.outputTokens
        updatedTotals.seconds += usage.seconds
        if let estimatedDollars = usage.estimatedDollars {
            updatedTotals.dollars += estimatedDollars
        } else {
            updatedTotals.answersWithoutPrice += 1
        }
        return updatedTotals
    }

    /// Each provider's totals over the last few days.
    func providerTotals(forDaysBack numberOfDays: Int) -> [String: ProviderTotals] {
        var combinedProviders: [String: ProviderTotals] = [:]
        for dayOffset in 0..<max(numberOfDays, 1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()),
                  let day = days[Self.dayKey(for: date)] else { continue }
            for (providerName, dayProviderTotals) in day.providers ?? [:] {
                combinedProviders[providerName] = Self.combined(combinedProviders[providerName] ?? ProviderTotals(), dayProviderTotals)
            }
        }
        return combinedProviders
    }

    nonisolated static func combined(_ first: ProviderTotals, _ second: ProviderTotals) -> ProviderTotals {
        ProviderTotals(
            answers: first.answers + second.answers,
            inputTokens: first.inputTokens + second.inputTokens,
            outputTokens: first.outputTokens + second.outputTokens,
            seconds: first.seconds + second.seconds,
            dollars: first.dollars + second.dollars,
            answersWithoutPrice: first.answersWithoutPrice + second.answersWithoutPrice
        )
    }

    /// "$0.0123 · 42 answers", with how many had no price.
    nonisolated static func providerDetailText(_ providerTotals: ProviderTotals) -> String {
        var detail = "\(DottieAskUsage.dollarsText(providerTotals.dollars)) · \(providerTotals.answers) answer\(providerTotals.answers == 1 ? "" : "s")"
        if providerTotals.answersWithoutPrice > 0 {
            detail += " (\(providerTotals.answersWithoutPrice) without a price)"
        }
        return detail
    }

    /// Time from releasing the talk shortcut to Dottie's first spoken word.
    func recordVoiceAnswerStart(seconds: Double) {
        guard seconds > 0, seconds < 60 else { return }
        let todayKey = Self.dayKey(for: Date())
        var today = days[todayKey] ?? DayTotals()
        today.voiceAnswerStartSecondsTotal += seconds
        today.voiceAnswerStartCount += 1
        days[todayKey] = today
        scheduleSave()
    }

    /// Which area a Gemini request belongs to, from the file that made it.
    nonisolated static func area(forCallerFile callerFile: String) -> Area {
        let fileName = (callerFile as NSString).lastPathComponent
        switch fileName {
        case "DottieScreenTaskRunner.swift", "DottieTVTaskRunner.swift", "DottieGuide.swift", "DottieGames.swift":
            return .screenTasks
        case "PointingRefiner.swift", "DottieTeaching.swift":
            return .pointing
        case "DottieEpisodicMemory.swift", "DottieBrain.swift":
            return .memory
        default:
            return .otherGemini
        }
    }

    // MARK: - Reading

    func totals(forDaysBack numberOfDays: Int) -> (areas: [Area: AreaTotals], averageVoiceAnswerStartSeconds: Double?) {
        var combinedAreas: [Area: AreaTotals] = [:]
        var voiceAnswerStartSecondsTotal = 0.0
        var voiceAnswerStartCount = 0
        for dayOffset in 0..<max(numberOfDays, 1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()),
                  let day = days[Self.dayKey(for: date)] else { continue }
            for (areaName, areaTotals) in day.areas {
                guard let area = Area(rawValue: areaName) else { continue }
                var combined = combinedAreas[area] ?? AreaTotals()
                combined.inputTokens += areaTotals.inputTokens
                combined.outputTokens += areaTotals.outputTokens
                combined.requests += areaTotals.requests
                combined.seconds += areaTotals.seconds
                combinedAreas[area] = combined
            }
            voiceAnswerStartSecondsTotal += day.voiceAnswerStartSecondsTotal
            voiceAnswerStartCount += day.voiceAnswerStartCount
        }
        let averageVoiceAnswerStartSeconds = voiceAnswerStartCount > 0
            ? voiceAnswerStartSecondsTotal / Double(voiceAnswerStartCount)
            : nil
        return (combinedAreas, averageVoiceAnswerStartSeconds)
    }

    /// Each of the last few days' spend, newest first, days with no answers left out.
    func daySpends(forDaysBack numberOfDays: Int) -> [DottieDaySpend] {
        (0..<max(numberOfDays, 1)).compactMap { dayOffset in
            guard let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) else { return nil }
            let dayKey = Self.dayKey(for: date)
            guard let providers = days[dayKey]?.providers, !providers.isEmpty else { return nil }
            return DottieSpendMeter.daySpend(dayKey: dayKey, providers: providers)
        }
    }

    func reset() {
        days = [:]
        meteredCalls = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.meteredCallsDefaultsKey)
    }

    // MARK: - Saving

    /// Answers can arrive many times a second, so writes are batched.
    private func scheduleSave() {
        guard pendingSaveTask == nil else { return }
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            self.pendingSaveTask = nil
            self.pruneOldDays()
            if let encodedDays = try? JSONEncoder().encode(self.days) {
                UserDefaults.standard.set(encodedDays, forKey: Self.defaultsKey)
            }
            if let encodedCalls = try? JSONEncoder().encode(self.meteredCalls) {
                UserDefaults.standard.set(encodedCalls, forKey: Self.meteredCallsDefaultsKey)
            }
        }
    }

    private func pruneOldDays() {
        guard let oldestKeptDate = Calendar.current.date(byAdding: .day, value: -(Self.daysKept - 1), to: Date()) else { return }
        let oldestKeptKey = Self.dayKey(for: oldestKeptDate)
        days = days.filter { $0.key >= oldestKeptKey }
    }

    private static func dayKey(for date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: date)
    }
}

// MARK: - Settings → Usage

struct HomeUsageSettings: View {
    @ObservedObject private var usage = DottieUsage.shared
    @State private var showsWeek = false

    var body: some View {
        let totals = usage.totals(forDaysBack: showsWeek ? 7 : 1)
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $showsWeek) {
                Text("Today").tag(false)
                Text("Last 7 days").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            if totals.areas.isEmpty {
                Text("Nothing used yet.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            ForEach(DottieUsage.Area.allCases, id: \.self) { area in
                if let areaTotals = totals.areas[area] {
                    row(area: area, areaTotals: areaTotals)
                }
            }
            let providerTotals = usage.providerTotals(forDaysBack: showsWeek ? 7 : 1)
            if !providerTotals.isEmpty {
                Text("By model provider")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.top, 4)
                ForEach(providerTotals.keys.sorted(), id: \.self) { providerName in
                    HStack {
                        Text(providerName.capitalized)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        Text(DottieUsage.providerDetailText(providerTotals[providerName] ?? DottieUsage.ProviderTotals()))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                Text("Estimated from the tokens each model reported and the prices set on the Worker. Models without a price set count as answers only.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            claudeCallMeter
            dayTotals
            if let averageVoiceAnswerStartSeconds = totals.averageVoiceAnswerStartSeconds {
                HStack {
                    Text("Voice answers start after")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text(String(format: "%.1fs on average", averageVoiceAnswerStartSeconds))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            Text("Tokens the models reported for each area. Claude helpers are counted in turns, since MausBot doesn't report tokens.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Each Claude call's tokens and cost, to check them against the price list.
    @ViewBuilder private var claudeCallMeter: some View {
        let calls = usage.meteredCalls
        if !calls.isEmpty {
            Text("Claude call meter")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.top, 4)
            if let averageDollars = DottieSpendMeter.averageDollarsPerCall(calls) {
                meterRow("Average per call", DottieAskUsage.dollarsText(averageDollars))
            }
            if let averageTokens = DottieSpendMeter.averageTokens(calls) {
                meterRow("Average tokens", "\(averageTokens.input.formatted()) in · \(averageTokens.output.formatted()) out")
            }
            if let highestCall = DottieSpendMeter.highestDollarCall(calls) {
                meterRow("Most expensive (\(highestCall.area))", DottieSpendMeter.callDetailText(highestCall))
            }
            ForEach(Array(calls.suffix(8).reversed().enumerated()), id: \.offset) { _, call in
                meterRow("\(call.date.formatted(date: .omitted, time: .shortened)) · \(call.area)", DottieSpendMeter.callDetailText(call))
            }
            Text("The newest \(calls.count) Claude calls from this Mac. Compare the tokens with the Claude Console; it also counts calls from the release checks.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What Dottie spent each day, all providers together.
    @ViewBuilder private var dayTotals: some View {
        let daySpends = usage.daySpends(forDaysBack: 7)
        if !daySpends.isEmpty {
            Text("Spent per day")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.top, 4)
            ForEach(daySpends, id: \.dayKey) { daySpend in
                VStack(alignment: .leading, spacing: 1) {
                    meterRow(daySpend.dayKey, "\(DottieAskUsage.dollarsText(daySpend.dollars)) · \(daySpend.answers) answers")
                    let breakdown = DottieSpendMeter.providerBreakdownText(daySpend)
                    if !breakdown.isEmpty {
                        Text(breakdown)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }
        }
    }

    private func meterRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(value)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private func row(area: DottieUsage.Area, areaTotals: DottieUsage.AreaTotals) -> some View {
        HStack {
            Text(area.rawValue)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Text(detailText(area: area, areaTotals: areaTotals))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private func detailText(area: DottieUsage.Area, areaTotals: DottieUsage.AreaTotals) -> String {
        if area == .claudeHelpers {
            let minutes = Int((areaTotals.seconds / 60).rounded())
            return "\(areaTotals.requests) turn\(areaTotals.requests == 1 ? "" : "s"), \(minutes) min"
        }
        return "\(Self.compactCount(areaTotals.inputTokens)) in, \(Self.compactCount(areaTotals.outputTokens)) out"
    }

    private static func compactCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}
