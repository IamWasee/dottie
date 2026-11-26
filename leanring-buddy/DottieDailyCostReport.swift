//
//  DottieDailyCostReport.swift
//  leanring-buddy
//
//  The daily cost report. Wasee (27 Nov) wanted the total cost of each day
//  to show up by itself every day, with the usage numbers behind it: once
//  a day, the first time Dottie is running after midnight, a notification
//  gives yesterday's total, answers, tokens and the dollars per provider and
//  per feature, and Settings → Usage keeps the full report. The report math
//  is Foundation only, so it can be unit tested.
//

import Foundation

struct DottieDailyCostReport: Equatable {
    /// One provider's or one feature's share of the day.
    struct Line: Equatable {
        let name: String
        let answers: Int
        let inputTokens: Int
        let outputTokens: Int
        let dollars: Double
    }

    let dayKey: String
    let totalDollars: Double
    let answers: Int
    let answersWithoutPrice: Int
    let inputTokens: Int
    let outputTokens: Int
    /// Biggest spend first.
    let providers: [Line]
    /// Biggest spend first; empty for days saved before features were counted.
    let features: [Line]

    /// The report for one day, or nil when nothing answered that day.
    static func report(dayKey: String, providers providerTotals: [String: DottieUsage.ProviderTotals],
                       features featureTotals: [String: DottieUsage.ProviderTotals]) -> DottieDailyCostReport? {
        let providerLines = sortedLines(from: providerTotals)
        let answers = providerLines.reduce(0) { $0 + $1.answers }
        guard answers > 0 else { return nil }
        var answersWithoutPrice = 0
        for totals in providerTotals.values { answersWithoutPrice += totals.answersWithoutPrice }
        return DottieDailyCostReport(
            dayKey: dayKey,
            totalDollars: providerLines.reduce(0) { $0 + $1.dollars },
            answers: answers,
            answersWithoutPrice: answersWithoutPrice,
            inputTokens: providerLines.reduce(0) { $0 + $1.inputTokens },
            outputTokens: providerLines.reduce(0) { $0 + $1.outputTokens },
            providers: providerLines,
            features: sortedLines(from: featureTotals)
        )
    }

    private static func sortedLines(from totalsByName: [String: DottieUsage.ProviderTotals]) -> [Line] {
        var lines: [Line] = []
        for (name, totals) in totalsByName where totals.answers > 0 {
            lines.append(Line(name: name, answers: totals.answers, inputTokens: totals.inputTokens,
                              outputTokens: totals.outputTokens, dollars: totals.dollars))
        }
        lines.sort { first, second in
            if first.dollars != second.dollars { return first.dollars > second.dollars }
            return first.name < second.name
        }
        return lines
    }

    // MARK: Words

    /// "Dottie spent $0.0421 yesterday"
    var notificationTitle: String {
        "Dottie spent \(DottieAskUsage.dollarsText(totalDollars)) yesterday"
    }

    /// One short paragraph: answers and tokens, then providers, then the top features.
    var notificationBody: String {
        var sentences = ["\(answers.formatted()) answers · \(Self.tokensText(inputTokens)) tokens in, \(Self.tokensText(outputTokens)) out."]
        let spendingProviders = providers.filter { $0.dollars > 0 }
        if !spendingProviders.isEmpty {
            sentences.append(spendingProviders.map { "\($0.name.capitalized) \(DottieAskUsage.dollarsText($0.dollars))" }.joined(separator: ", ") + ".")
        }
        let topFeatures = features.filter { $0.dollars > 0 }.prefix(3)
        if !topFeatures.isEmpty {
            sentences.append("Most went to " + topFeatures.map { "\(Self.featureName($0.name)) \(DottieAskUsage.dollarsText($0.dollars))" }
                .joined(separator: ", ") + ".")
        }
        if answersWithoutPrice > 0 {
            sentences.append("\(answersWithoutPrice) answers had no price.")
        }
        return sentences.joined(separator: " ")
    }

    /// "4 answers · 12.3K in · 450 out · $0.0012" for one line of the full report.
    static func lineDetail(_ line: Line) -> String {
        "\(line.answers.formatted()) answers · \(tokensText(line.inputTokens)) in · \(tokensText(line.outputTokens)) out · \(DottieAskUsage.dollarsText(line.dollars))"
    }

    /// 950 → "950", 12_345 → "12.3K", 3_400_000 → "3.4M".
    static func tokensText(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(max(tokens, 0))"
    }

    /// "screen_job_steps" → "screen job steps"; area names stay as they are.
    static func featureName(_ category: String) -> String {
        category.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: When

    /// The report shows once per day: for yesterday, unless already shown.
    static func shouldShow(reportDayKey: String, lastShownDayKey: String?) -> Bool {
        reportDayKey != lastShownDayKey
    }
}

/// Shows yesterday's report once a day: checked when Dottie starts and every
/// half hour, so a Mac left on overnight gets it soon after midnight.
@MainActor
enum DottieDailyCostReporter {
    static let lastShownDayDefaultsKey = "DottieDailyCostReportLastShownDay"
    private static var checkTimer: Timer?

    static func start(notifications: ClickyNotifications) {
        guard checkTimer == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            showYesterdayIfDue(notifications: notifications)
        }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in showYesterdayIfDue(notifications: notifications) }
        }
    }

    static func showYesterdayIfDue(notifications: ClickyNotifications) {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return }
        let yesterdayKey = DottieUsage.dayKey(for: yesterday)
        let lastShownDayKey = UserDefaults.standard.string(forKey: lastShownDayDefaultsKey)
        guard DottieDailyCostReport.shouldShow(reportDayKey: yesterdayKey, lastShownDayKey: lastShownDayKey) else { return }
        UserDefaults.standard.set(yesterdayKey, forKey: lastShownDayDefaultsKey)
        guard let report = DottieUsage.shared.dailyCostReport(forDayKey: yesterdayKey) else { return }
        DottieLog.notice("💵 Daily cost report for \(public: yesterdayKey): \(public: DottieAskUsage.dollarsText(report.totalDollars)) over \(public: report.answers) answers")
        notifications.notifyDailyCostReport(title: report.notificationTitle, body: report.notificationBody)
    }
}
