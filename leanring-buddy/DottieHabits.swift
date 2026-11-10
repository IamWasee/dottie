//
//  DottieHabits.swift
//  leanring-buddy
//
//  Dottie remembering the user's routines: what they do around the same
//  time on most days ("around 9:10 on weekdays: opens Slack", "most
//  evenings around 8: kaggle.com"), plus routines they tell her ("I go to
//  the gym Mondays at 6"). Noticed on this Mac with no model calls: which
//  app is in front and for how long (app names only, no screenshots), and
//  the web pages in her episodic memory. Voice Dottie gets the list in
//  every session; the memories tool lists, adds and forgets them, and
//  Home → Brain shows them with a switch to stop noticing.
//
//  On disk, in ~/Library/Application Support/Dottie/Memory/:
//    app-use.jsonl   one line per app used for a minute or more (45 days)
//    habits.json     the routines, noticed and told, and forgotten ones
//

import AppKit
import Combine
import Foundation

struct DottieHabit: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        /// Found in what the user did.
        case noticed
        /// The user said it.
        case told
    }

    let id: UUID
    /// "opens Slack", "on kaggle.com", or the user's own words.
    var title: String
    /// What it's about, so a noticed routine keeps its id when found again
    /// ("app:com.tinyspeck.slackmacgap", "site:kaggle.com").
    var key: String
    /// "weekdays", "every day", "most days", "on Mondays", or the user's words.
    var daysText: String
    /// Minutes after midnight it usually starts.
    var minuteOfDay: Int?
    /// On how many of the days looked at it happened.
    var seenDayCount: Int
    var lastSeen: Date
    var source: Source

    var shortID: String { String(id.uuidString.prefix(6)).lowercased() }

    /// "around 9:10 on weekdays: opens Slack"
    var sentence: String {
        var whenText = daysText
        if let minuteOfDay {
            whenText = "around \(DottieHabits.clockText(minuteOfDay: minuteOfDay))" + (daysText.isEmpty ? "" : " \(daysText)")
        }
        return whenText.isEmpty ? title : "\(whenText): \(title)"
    }
}

@MainActor
final class DottieHabits: ObservableObject {
    static let shared = DottieHabits()

    @Published private(set) var habits: [DottieHabit] = []
    @Published var isNoticingEnabled: Bool = UserDefaults.standard.object(forKey: DottieHabits.noticingDefaultsKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isNoticingEnabled, forKey: Self.noticingDefaultsKey)
            if !isNoticingEnabled { closeCurrentAppUse() }
        }
    }

    private static let noticingDefaultsKey = "dottieNoticeRoutines"
    /// An app in front for less than this isn't really "using" it.
    private static let minimumAppUseSeconds: TimeInterval = 60
    private static let daysToKeepAppUse = 45
    /// Routines are looked for in this many recent days.
    private static let daysToLookAt = 21
    /// It has to happen on at least this many of them.
    private static let minimumSeenDays = 4
    /// Most of its days have to start within this many minutes of the usual time.
    private static let usualTimeSlackMinutes = 45
    private static let maximumNoticedHabits = 8
    /// Apps that are always around and say nothing about a routine.
    private static let ignoredBundleIdentifiers: Set<String> = [
        "com.apple.finder", "com.apple.loginwindow", "com.apple.systempreferences",
        "com.apple.SystemPreferences", "com.apple.dock", "com.apple.notificationcenterui",
        "com.apple.ScreenSaver.Engine", "com.apple.UserNotificationCenter"
    ]

    private struct AppUse: Codable {
        let bundleIdentifier: String
        let appName: String
        let startedAt: Date
        let seconds: Double
    }

    private struct SavedHabits: Codable {
        var habits: [DottieHabit]
        /// Noticed routines the user forgot, so they don't come back.
        var forgottenKeys: [String]
    }

    private let folderURL: URL
    private var appUseFileURL: URL { folderURL.appendingPathComponent("app-use.jsonl") }
    private var habitsFileURL: URL { folderURL.appendingPathComponent("habits.json") }
    private var forgottenKeys: Set<String> = []
    private var currentAppUse: (bundleIdentifier: String, appName: String, startedAt: Date)?
    private var activationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var miningTimer: Timer?
    private var hasStarted = false

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = applicationSupportURL.appendingPathComponent("Dottie/Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadHabits()
    }

    /// Starts noticing which app is in front, and looks for routines now and
    /// every few hours. Safe to call more than once.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        activationObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.noteAppCameToFront(application)
            }
        }
        // Asleep isn't using the app in front.
        sleepObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeCurrentAppUse()
            }
        }
        noteAppCameToFront(NSWorkspace.shared.frontmostApplication)
        Task { [weak self] in
            // Give launch a moment before reading the log.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.findRoutines()
        }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.findRoutines()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        miningTimer = timer
    }

    // MARK: - Noticing apps

    private func noteAppCameToFront(_ application: NSRunningApplication?) {
        closeCurrentAppUse()
        guard isNoticingEnabled,
              let application,
              let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier,
              !Self.ignoredBundleIdentifiers.contains(bundleIdentifier) else { return }
        currentAppUse = (bundleIdentifier: bundleIdentifier, appName: application.localizedName ?? bundleIdentifier, startedAt: Date())
    }

    private func closeCurrentAppUse() {
        guard let currentAppUse else { return }
        self.currentAppUse = nil
        let seconds = Date().timeIntervalSince(currentAppUse.startedAt)
        guard seconds >= Self.minimumAppUseSeconds else { return }
        let appUse = AppUse(bundleIdentifier: currentAppUse.bundleIdentifier, appName: currentAppUse.appName,
                            startedAt: currentAppUse.startedAt, seconds: seconds)
        guard let lineData = try? Self.makeEncoder().encode(appUse) else { return }
        let fileURL = appUseFileURL
        Task.detached(priority: .utility) {
            Self.appendLine(lineData, to: fileURL)
        }
    }

    nonisolated private static func appendLine(_ lineData: Data, to fileURL: URL) {
        var line = lineData
        line.append(0x0A)
        if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? fileHandle.close() }
            _ = try? fileHandle.seekToEnd()
            try? fileHandle.write(contentsOf: line)
        } else {
            DottieFileSaver.save(line, to: fileURL)
        }
    }

    // MARK: - Finding routines

    /// One thing that happened at a time on a day: an app used, a page visited.
    private struct DatedSighting {
        let key: String
        let title: String
        let date: Date
    }

    /// Looks for things done on most days at about the same time. All on
    /// this Mac, no model call.
    func findRoutines() {
        let appUses = loadAndTrimAppUses()
        let episodes = DottieEpisodicMemory.shared.episodes
        let calendar = Calendar.current
        let oldestDayToLookAt = calendar.date(byAdding: .day, value: -Self.daysToLookAt, to: calendar.startOfDay(for: Date())) ?? Date.distantPast

        var sightings: [DatedSighting] = []
        if isNoticingEnabled {
            for appUse in appUses where appUse.startedAt >= oldestDayToLookAt {
                sightings.append(DatedSighting(key: "app:" + appUse.bundleIdentifier, title: "uses \(appUse.appName)", date: appUse.startedAt))
            }
        }
        for episode in episodes where episode.startedAt >= oldestDayToLookAt {
            guard let urlText = episode.url, let host = Self.siteName(from: urlText) else { continue }
            sightings.append(DatedSighting(key: "site:" + host, title: "on \(host)", date: episode.startedAt))
        }

        // Days Dottie saw any activity, so "most days" means most days the Mac was used.
        let activeDays = Set(sightings.map { calendar.startOfDay(for: $0.date) })
        var noticed: [(habit: DottieHabit, consistency: Double)] = []
        for (key, keySightings) in Dictionary(grouping: sightings, by: \.key) {
            guard !forgottenKeys.contains(key), let title = keySightings.first?.title else { continue }
            // The first time on each day it happened.
            var firstSightingByDay: [Date: Date] = [:]
            for sighting in keySightings {
                let day = calendar.startOfDay(for: sighting.date)
                if let earlier = firstSightingByDay[day], earlier <= sighting.date { continue }
                firstSightingByDay[day] = sighting.date
            }
            guard firstSightingByDay.count >= Self.minimumSeenDays else { continue }
            let minutesOfDay = firstSightingByDay.values.map { date -> Int in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }.sorted()
            let usualMinute = minutesOfDay[minutesOfDay.count / 2]
            let daysNearUsualTime = minutesOfDay.filter { abs($0 - usualMinute) <= Self.usualTimeSlackMinutes }.count
            let timeConsistency = Double(daysNearUsualTime) / Double(minutesOfDay.count)
            guard timeConsistency >= 0.6, daysNearUsualTime >= Self.minimumSeenDays else { continue }
            guard let daysText = Self.daysText(for: Array(firstSightingByDay.keys), activeDays: activeDays, calendar: calendar) else { continue }
            let existingHabit = habits.first { $0.key == key && $0.source == .noticed }
            let habit = DottieHabit(
                id: existingHabit?.id ?? UUID(),
                title: title,
                key: key,
                daysText: daysText,
                minuteOfDay: (usualMinute / 5) * 5,
                seenDayCount: firstSightingByDay.count,
                lastSeen: firstSightingByDay.values.max() ?? Date(),
                source: .noticed
            )
            let dayShare = Double(firstSightingByDay.count) / Double(max(activeDays.count, 1))
            noticed.append((habit: habit, consistency: timeConsistency * dayShare))
        }
        let bestNoticed = noticed.sorted { $0.consistency > $1.consistency }.prefix(Self.maximumNoticedHabits).map(\.habit)
        let toldHabits = habits.filter { $0.source == .told }
        let newHabits = (toldHabits + bestNoticed).sorted { ($0.minuteOfDay ?? 24 * 60) < ($1.minuteOfDay ?? 24 * 60) }
        if newHabits != habits {
            habits = newHabits
            saveHabits()
        }
    }

    /// "weekdays", "on Mondays", "every day", "most days", or nil when the
    /// days don't make a pattern.
    private static func daysText(for days: [Date], activeDays: Set<Date>, calendar: Calendar) -> String? {
        let weekdayNumbers = days.map { calendar.component(.weekday, from: $0) }
        let weekendCount = weekdayNumbers.filter { $0 == 1 || $0 == 7 }.count
        let activeWeekdayCount = activeDays.filter { !calendar.isDateInWeekend($0) }.count
        if weekendCount == 0 && days.count >= max(4, Int(Double(activeWeekdayCount) * 0.6)) {
            return "on weekdays"
        }
        let dayShare = Double(days.count) / Double(max(activeDays.count, 1))
        if dayShare >= 0.85 { return "every day" }
        if dayShare >= 0.6 { return "most days" }
        // The same day of the week, three weeks or more.
        let countsByWeekday = Dictionary(grouping: weekdayNumbers, by: { $0 }).mapValues(\.count)
        if let (weekdayNumber, count) = countsByWeekday.max(by: { $0.value < $1.value }),
           count >= 3, Double(count) / Double(days.count) >= 0.7 {
            let weekdayName = calendar.weekdaySymbols[weekdayNumber - 1]
            return "on \(weekdayName)s"
        }
        return nil
    }

    private static func siteName(from urlText: String) -> String? {
        let withScheme = urlText.contains("://") ? urlText : "https://" + urlText
        guard let host = URL(string: withScheme)?.host?.lowercased(), host.contains(".") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    nonisolated static func clockText(minuteOfDay: Int) -> String {
        let hour = (minuteOfDay / 60) % 24
        let minute = minuteOfDay % 60
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let periodText = hour < 12 ? "am" : "pm"
        return minute == 0 ? "\(displayHour)\(periodText)" : String(format: "%d:%02d%@", displayHour, minute, periodText)
    }

    // MARK: - Told routines and forgetting

    /// A routine the user told Dottie ("gym on Mondays at 6pm").
    @discardableResult
    func addToldRoutine(_ text: String, when: String?) -> DottieHabit? {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let habit = DottieHabit(
            id: UUID(),
            title: String(title.prefix(200)),
            key: "told:" + title.lowercased(),
            daysText: (when ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            minuteOfDay: nil,
            seenDayCount: 0,
            lastSeen: Date(),
            source: .told
        )
        habits.removeAll { $0.key == habit.key }
        habits.append(habit)
        saveHabits()
        return habit
    }

    /// Forgets one routine. A noticed one stays forgotten even if it keeps happening.
    func forget(_ habit: DottieHabit) {
        habits.removeAll { $0.id == habit.id }
        if habit.source == .noticed { forgottenKeys.insert(habit.key) }
        saveHabits()
    }

    /// Finds a routine by its #id or by words in it.
    func habit(matching reference: String) -> DottieHabit? {
        let lowered = reference.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if let byID = habits.first(where: { $0.shortID == lowered }) { return byID }
        let words = lowered.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard !words.isEmpty else { return nil }
        func matchingWordCount(_ habit: DottieHabit) -> Int {
            let habitText = habit.sentence.lowercased()
            return words.filter { word in habitText.contains(word) }.count
        }
        guard let bestHabit = habits.max(by: { matchingWordCount($0) < matchingWordCount($1) }),
              matchingWordCount(bestHabit) > 0 else { return nil }
        return bestHabit
    }

    // MARK: - For the model

    /// The routines as lines for a tool answer.
    var listText: String {
        guard !habits.isEmpty else {
            return isNoticingEnabled
                ? "no routines yet. dottie notices them after about a week of the same thing at the same time; the user can also tell you one."
                : "no routines, and noticing them is off (Home → Brain)."
        }
        return "the user's routines:\n" + habits.map { habit in
            "- #\(habit.shortID) \(habit.sentence)" + (habit.source == .told ? " (they told you)" : " (noticed on \(habit.seenDayCount) days)")
        }.joined(separator: "\n")
    }

    /// One short line for the voice prompt, or nil.
    var voicePromptLine: String? {
        guard !habits.isEmpty else { return nil }
        let sentences = habits.prefix(6).map(\.sentence).joined(separator: "; ")
        return "the user's routines (from memory; bring them up only when it helps, like offering to open what they usually open): \(sentences)."
    }

    // MARK: - Files

    private func loadAndTrimAppUses() -> [AppUse] {
        guard let fileData = try? Data(contentsOf: appUseFileURL) else { return [] }
        let decoder = Self.makeDecoder()
        let allAppUses = fileData.split(separator: 0x0A).compactMap { lineData in
            try? decoder.decode(AppUse.self, from: Data(lineData))
        }
        let cutoff = Date().addingTimeInterval(-Double(Self.daysToKeepAppUse) * 86_400)
        let keptAppUses = allAppUses.filter { $0.startedAt >= cutoff }
        if keptAppUses.count < allAppUses.count {
            let encoder = Self.makeEncoder()
            var rewrittenData = Data()
            for appUse in keptAppUses {
                guard let lineData = try? encoder.encode(appUse) else { continue }
                rewrittenData.append(lineData)
                rewrittenData.append(0x0A)
            }
            DottieFileSaver.save(rewrittenData, to: appUseFileURL)
        }
        return keptAppUses
    }

    private func loadHabits() {
        guard let saved = DottieFileLoader.load(SavedHabits.self, from: habitsFileURL, decoder: Self.makeDecoder()) else { return }
        habits = saved.habits
        forgottenKeys = Set(saved.forgottenKeys)
    }

    private func saveHabits() {
        let saved = SavedHabits(habits: habits, forgottenKeys: Array(forgottenKeys).sorted())
        guard let fileData = try? Self.makeEncoder().encode(saved) else { return }
        DottieFileSaver.save(fileData, to: habitsFileURL)
    }

    /// Clears every routine and the app log ("forget everything").
    func forgetEverything() {
        habits = []
        forgottenKeys = []
        currentAppUse = nil
        try? FileManager.default.removeItem(at: appUseFileURL)
        try? FileManager.default.removeItem(at: habitsFileURL)
    }

    nonisolated private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
