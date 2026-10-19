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

    enum Area: String, CaseIterable, Codable {
        case voice = "Voice"
        case screenTasks = "Screen tasks and games"
        case pointing = "Pointing and teaching"
        case memory = "Memory"
        case geminiHelpers = "Helpers on Gemini"
        case claudeHelpers = "Helpers on Claude"
        case otherGemini = "Other Gemini calls"
    }

    struct AreaTotals: Codable, Equatable {
        var inputTokens = 0
        var outputTokens = 0
        var requests = 0
        var seconds = 0.0
    }

    struct DayTotals: Codable, Equatable {
        var areas: [String: AreaTotals] = [:]
        var voiceAnswerStartSecondsTotal = 0.0
        var voiceAnswerStartCount = 0
    }

    @Published private(set) var days: [String: DayTotals] = [:]

    private static let defaultsKey = "dottieUsageByDay"
    private static let daysKept = 14
    private var pendingSaveTask: Task<Void, Never>?

    private init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let savedDays = try? JSONDecoder().decode([String: DayTotals].self, from: savedData) {
            days = savedDays
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
    static func area(forCallerFile callerFile: String) -> Area {
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

    func reset() {
        days = [:]
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
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
            Text("Tokens Gemini reported for each area. Claude helpers are counted in turns, since MausBot doesn't report tokens.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
