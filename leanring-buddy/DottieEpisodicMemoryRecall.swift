//
//  DottieEpisodicMemoryRecall.swift
//  leanring-buddy
//
//  Finding episodes again: word matching (titles and places count most),
//  how recent and how important each one is, and plain time phrases like
//  "yesterday", "this morning", "last week" or "tuesday". When words find
//  little, Gemini embeddings (through the Worker) look for the same
//  meaning instead, if they answer quickly; otherwise words alone.
//

import AppKit
import Foundation

// MARK: - Recall

extension DottieEpisodicMemory {
    struct RecallResult {
        let episodes: [DottieEpisode]
        let window: DottieMemoryTimeWindow?
        /// True when nothing fit the time asked about, so these are the
        /// closest from any time.
        let isOutsideWindow: Bool
    }

    /// The best episodes for a question, newest first. Word search, plus
    /// meaning search when words find little and embeddings answer fast.
    func recall(query: String, when: String? = nil, limit: Int = 6, usesMeaningSearch: Bool = true) async -> RecallResult {
        let request = RecallRequest(query: query, when: when)
        var scored = score(request.candidates(in: episodes), queryWords: request.queryWords, hints: request.hints)
        if usesMeaningSearch, !request.queryWords.isEmpty, scored.filter({ $0.score >= 0.5 }).count < 2,
           let meaningMatches = await embeddings.closest(to: request.searchText, among: request.candidates(in: episodes), limit: limit) {
            let alreadyFound = Set(scored.map(\.episode.id))
            for match in meaningMatches where !alreadyFound.contains(match.episode.id) {
                scored.append((episode: match.episode, score: (match.similarity - 0.5) * 2 + recencyBonus(match.episode)))
            }
        }
        return finishRecall(scored, request: request, limit: limit)
    }

    /// Word search only, right away (for recall_memory, which can't wait).
    func recallNow(query: String, when: String? = nil, limit: Int = 6) -> RecallResult {
        let request = RecallRequest(query: query, when: when)
        let scored = score(request.candidates(in: episodes), queryWords: request.queryWords, hints: request.hints)
        return finishRecall(scored, request: request, limit: limit)
    }

    private struct RecallRequest {
        let searchText: String
        let window: DottieMemoryTimeWindow?
        let hints: DottieEpisodeSearch.Hints
        let queryWords: [String]

        init(query: String, when: String?) {
            var window: DottieMemoryTimeWindow?
            if let when, !when.trimmingCharacters(in: .whitespaces).isEmpty {
                window = DottieMemoryTimeWindow.find(in: when).window
            }
            let foundInQuery = DottieMemoryTimeWindow.find(in: query)
            searchText = foundInQuery.remainingText
            self.window = window ?? foundInQuery.window
            hints = DottieEpisodeSearch.Hints(text: searchText)
            queryWords = DottieEpisodeSearch.queryWords(in: searchText)
        }

        func candidates(in episodes: [DottieEpisode]) -> [DottieEpisode] {
            guard let window else { return episodes }
            return episodes.filter { window.contains($0) }
        }
    }

    private func finishRecall(_ scoredEpisodes: [(episode: DottieEpisode, score: Double)], request: RecallRequest, limit: Int) -> RecallResult {
        var scored = scoredEpisodes
        var isOutsideWindow = false
        if scored.isEmpty, request.window != nil, !request.queryWords.isEmpty || request.hints.isActive {
            // Nothing then: the closest from any time.
            scored = score(episodes, queryWords: request.queryWords, hints: request.hints)
            isOutsideWindow = !scored.isEmpty
        }
        let bestEpisodes = scored.sorted { $0.score > $1.score }.prefix(limit).map(\.episode)
            .sorted { $0.startedAt > $1.startedAt }
        return RecallResult(episodes: bestEpisodes, window: request.window, isOutsideWindow: isOutsideWindow)
    }

    /// recall as text for a voice or helper tool.
    func recallText(query: String, when: String? = nil, limit: Int = 6) async -> String {
        describe(await recall(query: query, when: when, limit: limit))
    }

    /// Word-search recall as text, right away.
    func recallTextNow(query: String, limit: Int = 5) -> String {
        describe(recallNow(query: query, limit: limit))
    }

    private func describe(_ result: RecallResult) -> String {
        let windowName = result.window?.phrase ?? ""
        guard !result.episodes.isEmpty else {
            if episodes.isEmpty { return "no episodes remembered yet." }
            return windowName.isEmpty ? "no episodes match that." : "nothing remembered from \(windowName) that matches."
        }
        var header = "episodes, newest first"
        if result.isOutsideWindow {
            header = "nothing from \(windowName) matches; the closest from other times"
        } else if !windowName.isEmpty {
            header += " (\(windowName))"
        }
        return header + ":\n" + result.episodes.map(Self.lineForModel).joined(separator: "\n")
    }

    /// Recent episodes, newest first.
    func recentText(when: String?, count: Int) -> String {
        let window = when.flatMap { DottieMemoryTimeWindow.find(in: $0).window }
        let chosen = episodes.filter { window?.contains($0) ?? true }.suffix(max(1, min(count, 20))).reversed()
        guard !chosen.isEmpty else {
            return window == nil ? "no episodes remembered yet." : "nothing remembered from \(window?.phrase ?? "then")."
        }
        return "recent episodes, newest first:\n" + chosen.map(Self.lineForModel).joined(separator: "\n")
    }

    /// Forgets by id, by words, or everything in a time. Returns what went.
    func forgetText(id: String?, query: String?, when: String?) async -> String {
        var doomed: [DottieEpisode] = []
        if let id = id?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# ")), !id.isEmpty {
            doomed = episodes.filter { $0.shortID == id || $0.id.uuidString.lowercased() == id }
        } else if let query, !DottieEpisodeSearch.queryWords(in: DottieMemoryTimeWindow.find(in: query).remainingText).isEmpty {
            let result = await recall(query: query, when: when, limit: 3, usesMeaningSearch: false)
            doomed = result.isOutsideWindow ? [] : result.episodes
        } else if let window = (when ?? query).flatMap({ DottieMemoryTimeWindow.find(in: $0).window }) {
            doomed = episodes.filter { window.contains($0) }
        } else {
            return "say which one to forget: an id from memories, a few words, or a time like yesterday."
        }
        guard !doomed.isEmpty else { return "found nothing like that to forget." }
        delete(Set(doomed.map(\.id)))
        let titles = doomed.prefix(5).map { "\"\($0.title)\"" }.joined(separator: ", ")
        return "forgot \(doomed.count) episode\(doomed.count == 1 ? "" : "s"): \(titles)\(doomed.count > 5 ? " and more" : "")."
    }

    /// A few lines for the start of every voice conversation: the most
    /// relevant recent episodes, about 400 characters.
    func promptContext(frontmostAppName: String?) -> String {
        let now = Date()
        var recentEpisodes = episodes.filter { now.timeIntervalSince($0.endedAt) < 3 * 86_400 }
        if recentEpisodes.isEmpty {
            recentEpisodes = episodes.filter { now.timeIntervalSince($0.endedAt) < 14 * 86_400 }
        }
        guard !recentEpisodes.isEmpty else { return "" }
        let appName = frontmostAppName?.lowercased()
        let chosen = recentEpisodes.map { episode -> (episode: DottieEpisode, score: Double) in
            let ageInHours = max(now.timeIntervalSince(episode.endedAt) / 3600, 0)
            var score = episode.importance * 0.6 + exp(-ageInHours / 18)
            if let appName, episode.appName?.lowercased() == appName { score += 0.4 }
            if episode.source == .screen { score -= 0.15 }
            return (episode: episode, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(3)
        .map(\.episode)
        .sorted { $0.startedAt < $1.startedAt }

        var lines: [String] = []
        var totalLength = 0
        for episode in chosen {
            let firstSentence = DottieEpisodeSearch.firstSentence(of: episode.summary)
            var line = "- \(DottieEpisodeSearch.relativeTime(episode.startedAt)): \(episode.title)"
            if !firstSentence.isEmpty { line += " — " + firstSentence }
            line = String(line.prefix(150))
            guard totalLength + line.count <= 420 else { break }
            totalLength += line.count
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func lineForModel(_ episode: DottieEpisode) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM, h:mm a"
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "h:mm a"
        var timeText = dateFormatter.string(from: episode.startedAt)
        if episode.endedAt.timeIntervalSince(episode.startedAt) > 120 {
            timeText += "–" + endFormatter.string(from: episode.endedAt)
        }
        var line = "- [\(timeText) · \(episode.source.label) · #\(episode.shortID)] \(episode.title): \(episode.summary.prefix(360))"
        let whereText = episode.whereText
        if !whereText.isEmpty { line += " where: \(whereText.prefix(200))." }
        if !episode.people.isEmpty { line += " involved: \(episode.people.prefix(5).joined(separator: ", "))." }
        if let outcome = episode.outcome, !outcome.isEmpty { line += " outcome: \(outcome.prefix(160))" }
        return line
    }

    // MARK: Scoring

    private func score(_ candidates: [DottieEpisode], queryWords: [String], hints: DottieEpisodeSearch.Hints) -> [(episode: DottieEpisode, score: Double)] {
        // How rare each query word is, so "kaggle" beats "work".
        var documentFrequency: [String: Int] = [:]
        if !queryWords.isEmpty {
            for episode in candidates {
                let words = searchWords(for: episode)
                for queryWord in queryWords where words.matches(queryWord) != nil {
                    documentFrequency[queryWord, default: 0] += 1
                }
            }
        }
        let candidateCount = Double(max(candidates.count, 1))
        let inverseFrequency = Dictionary(uniqueKeysWithValues: queryWords.map { word in
            (word, log(1 + candidateCount / Double(1 + documentFrequency[word, default: 0])))
        })
        let bestPossible = queryWords.reduce(0.0) { $0 + 3 * (inverseFrequency[$1] ?? 1) }

        return candidates.compactMap { episode -> (episode: DottieEpisode, score: Double)? in
            var wordScore = 0.0
            if !queryWords.isEmpty {
                let words = searchWords(for: episode)
                for queryWord in queryWords {
                    if let fieldWeight = words.matches(queryWord) {
                        wordScore += fieldWeight * (inverseFrequency[queryWord] ?? 1)
                    }
                }
                wordScore = bestPossible > 0 ? wordScore / bestPossible : 0
            }
            let hintScore = hints.score(for: episode)
            if !queryWords.isEmpty {
                guard wordScore >= 0.1 else { return nil }
            } else if hints.isActive {
                guard hintScore > 0 else { return nil }
            }
            let total = wordScore * 1.5 + hintScore + recencyBonus(episode) + episode.importance * 0.15
            return (episode: episode, score: total)
        }
    }

    private func recencyBonus(_ episode: DottieEpisode) -> Double {
        let ageInDays = max(Date().timeIntervalSince(episode.endedAt) / 86_400, 0)
        return 0.25 * exp(-ageInDays / 10)
    }

    private func searchWords(for episode: DottieEpisode) -> DottieEpisodeSearch.Words {
        if let cached = cachedSearchWords[episode.id] { return cached }
        let words = DottieEpisodeSearch.Words(episode: episode)
        cachedSearchWords[episode.id] = words
        return words
    }
}

// MARK: - Time phrases

/// A stretch of time named in plain words ("yesterday", "last week").
struct DottieMemoryTimeWindow {
    let interval: DateInterval
    /// The words it came from, to say back ("yesterday").
    let phrase: String

    func contains(_ episode: DottieEpisode) -> Bool {
        episode.endedAt >= interval.start && episode.startedAt <= interval.end
    }

    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "a couple of": 2, "a couple": 2, "couple of": 2, "a few": 3, "few": 3
    ]

    /// Finds the first time phrase in the text and returns it with the
    /// text minus the phrase.
    static func find(in text: String, now: Date = Date(), calendar: Calendar = .current) -> (window: DottieMemoryTimeWindow?, remainingText: String) {
        let lowercasedText = text.lowercased()
        let startOfToday = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday }
        func hours(_ dayStart: Date, _ fromHour: Int, _ toHour: Int) -> DateInterval {
            let start = dayStart.addingTimeInterval(TimeInterval(fromHour) * 3600)
            let end = dayStart.addingTimeInterval(TimeInterval(toHour) * 3600)
            return DateInterval(start: start, end: max(end, start))
        }
        func partOfDay(_ name: String?, on dayStart: Date) -> DateInterval {
            switch name {
            case "morning": return hours(dayStart, 4, 12)
            case "afternoon": return hours(dayStart, 12, 17)
            case "evening": return hours(dayStart, 17, 24)
            case "night": return hours(dayStart, 18, 28)
            default: return hours(dayStart, 0, 24)
            }
        }
        let weekdayPattern = weekdayNames.joined(separator: "|")
        let numberPattern = "\\d+|a couple of|a couple|couple of|a few|few|an|a|one|two|three|four|five|six|seven"

        // Longest phrases first.
        let patterns: [(String, ([String?]) -> DateInterval?)] = [
            ("(?:the )?day before yesterday", { _ in DateInterval(start: day(-2), end: day(-1)) }),
            ("yesterday (morning|afternoon|evening|night)", { groups in partOfDay(groups[0], on: day(-1)) }),
            ("last night", { _ in hours(day(-1), 18, 28) }),
            ("this (morning|afternoon|evening)", { groups in partOfDay(groups[0], on: startOfToday) }),
            ("tonight", { _ in partOfDay("evening", on: startOfToday) }),
            ("earlier today|today", { _ in DateInterval(start: startOfToday, end: now) }),
            ("yesterday", { _ in DateInterval(start: day(-1), end: startOfToday) }),
            ("(\(numberPattern)) (day|week|month)s? ago", { groups in
                let amount = Int(groups[0] ?? "") ?? numberWords[groups[0] ?? ""] ?? 1
                switch groups[1] {
                case "week":
                    let start = calendar.date(byAdding: .day, value: -7 * amount - 3, to: startOfToday) ?? startOfToday
                    return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start) ?? now)
                case "month":
                    let start = calendar.date(byAdding: .month, value: -amount, to: startOfToday) ?? startOfToday
                    return DateInterval(start: calendar.date(byAdding: .day, value: -10, to: start) ?? start,
                                        end: calendar.date(byAdding: .day, value: 10, to: start) ?? now)
                default:
                    return amount >= 3 && groups[0]?.contains("few") == true
                        ? DateInterval(start: day(-6), end: day(-1))
                        : DateInterval(start: day(-amount), end: day(-amount + 1))
                }
            }),
            ("(?:the )?(?:past|last) (?:few|couple of|couple) days", { _ in DateInterval(start: day(-4), end: now) }),
            ("(last|this|past) weekend", { groups in
                let weekday = calendar.component(.weekday, from: now)
                let daysSinceSaturday = weekday % 7
                var saturday = day(-daysSinceSaturday)
                if groups[0] == "last", daysSinceSaturday <= 1 { saturday = calendar.date(byAdding: .day, value: -7, to: saturday) ?? saturday }
                return DateInterval(start: saturday, end: min(calendar.date(byAdding: .day, value: 2, to: saturday) ?? now, now))
            }),
            ("(last|this|past) (week|month)", { groups in
                let component: Calendar.Component = groups[1] == "week" ? .weekOfYear : .month
                guard let current = calendar.dateInterval(of: component, for: now) else { return nil }
                if groups[0] == "this" { return DateInterval(start: current.start, end: now) }
                if groups[0] == "past" {
                    let start = calendar.date(byAdding: component, value: -1, to: now) ?? current.start
                    return DateInterval(start: start, end: now)
                }
                let previousStart = calendar.date(byAdding: component, value: -1, to: current.start) ?? current.start
                return DateInterval(start: previousStart, end: current.start)
            }),
            ("recently|lately", { _ in DateInterval(start: day(-3), end: now) }),
            ("earlier", { _ in DateInterval(start: startOfToday, end: now) }),
            ("(?:(last|this|on|on last) )?(\(weekdayPattern))(?: (morning|afternoon|evening|night))?", { groups in
                guard let weekdayName = groups[1], let targetIndex = weekdayNames.firstIndex(of: weekdayName) else { return nil }
                let todayIndex = calendar.component(.weekday, from: now) - 1
                var daysBack = (todayIndex - targetIndex + 7) % 7
                if daysBack == 0, groups[0]?.contains("last") == true { daysBack = 7 }
                return partOfDay(groups[2], on: day(-daysBack))
            }),
            ("(\\d{4})-(\\d{2})-(\\d{2})", { groups in
                var components = DateComponents()
                components.year = Int(groups[0] ?? "")
                components.month = Int(groups[1] ?? "")
                components.day = Int(groups[2] ?? "")
                guard let date = calendar.date(from: components) else { return nil }
                return DateInterval(start: date, end: calendar.date(byAdding: .day, value: 1, to: date) ?? date)
            })
        ]

        for (pattern, makeInterval) in patterns {
            guard let expression = try? NSRegularExpression(pattern: "\\b(?:" + pattern + ")\\b"),
                  let match = expression.firstMatch(in: lowercasedText, range: NSRange(lowercasedText.startIndex..., in: lowercasedText)) else { continue }
            let groups: [String?] = (1..<max(match.numberOfRanges, 1)).map { groupIndex in
                let groupRange = match.range(at: groupIndex)
                guard groupRange.location != NSNotFound, let range = Range(groupRange, in: lowercasedText) else { return nil }
                return String(lowercasedText[range])
            }
            guard let interval = makeInterval(groups + [nil, nil, nil]),
                  let fullRange = Range(match.range, in: lowercasedText) else { continue }
            let phrase = String(lowercasedText[fullRange])
            var remainingText = lowercasedText
            remainingText.removeSubrange(fullRange)
            return (DottieMemoryTimeWindow(interval: interval, phrase: phrase), remainingText)
        }
        return (nil, text)
    }
}

// MARK: - Words

enum DottieEpisodeSearch {
    /// An episode's words by where they appear.
    struct Words {
        let title: Set<String>
        let strong: Set<String>
        let body: Set<String>

        init(episode: DottieEpisode) {
            title = DottieEpisodeSearch.wordSet(episode.title)
            var strongText = episode.tags.joined(separator: " ") + " " + episode.people.joined(separator: " ")
            strongText += " " + (episode.appName ?? "") + " " + (episode.windowTitle ?? "") + " " + (episode.url ?? "")
            strong = DottieEpisodeSearch.wordSet(strongText)
            body = DottieEpisodeSearch.wordSet(episode.summary + " " + (episode.outcome ?? ""))
        }

        /// The weight of the best place the word shows up, or nil.
        func matches(_ queryWord: String) -> Double? {
            if Self.contains(title, queryWord) { return 3 }
            if Self.contains(strong, queryWord) { return 2 }
            if Self.contains(body, queryWord) { return 1 }
            return nil
        }

        private static func contains(_ words: Set<String>, _ queryWord: String) -> Bool {
            if words.contains(queryWord) { return true }
            guard queryWord.count >= 4 else { return false }
            return words.contains { $0.count >= 4 && ($0.hasPrefix(queryWord) || queryWord.hasPrefix($0)) }
        }
    }

    /// What kind of thing the user is asking about ("that site", "what we
    /// talked about"), for questions with few real words.
    struct Hints {
        let wantsPage: Bool
        let wantsFile: Bool
        let wantsTalk: Bool
        let wantsHelper: Bool
        let wantsScreenJob: Bool

        init(text: String) {
            let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
            wantsPage = !words.isDisjoint(with: ["site", "website", "page", "link", "url", "webpage", "article", "video"])
            wantsFile = !words.isDisjoint(with: ["file", "document", "doc", "pdf", "spreadsheet", "folder"])
            wantsTalk = !words.isDisjoint(with: ["talk", "talked", "said", "say", "told", "chat", "chatted", "conversation", "discuss", "discussed", "asked"])
            wantsHelper = !words.isDisjoint(with: ["helper", "helpers", "dot", "dots"])
            wantsScreenJob = text.lowercased().contains("on screen") || text.lowercased().contains("on my screen")
        }

        var isActive: Bool { wantsPage || wantsFile || wantsTalk || wantsHelper || wantsScreenJob }

        func score(for episode: DottieEpisode) -> Double {
            var score = 0.0
            if wantsPage, episode.url?.isEmpty == false { score += 0.3 }
            if wantsFile, episode.windowTitle?.contains(".") == true { score += 0.2 }
            if wantsTalk, episode.source == .conversation { score += 0.3 }
            if wantsHelper, episode.source == .helper { score += 0.3 }
            if wantsScreenJob, episode.source == .screenJob || episode.source == .screen { score += 0.2 }
            return score
        }
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "is", "it", "my", "me", "i", "you", "what",
        "did", "do", "does", "was", "we", "that", "this", "with", "about", "when", "where", "how", "which", "who",
        "have", "has", "had", "be", "at", "from", "your", "our", "are", "were", "there", "then", "so", "can", "could",
        "us", "remember", "recall", "again", "before", "thing", "things", "stuff", "something", "anything", "some",
        "talk", "talked", "said", "say", "tell", "told", "chat", "conversation", "site", "website", "page", "just",
        "look", "looked", "looking", "saw", "see", "seen", "show", "showed", "find", "found", "doing", "done", "work",
        "working", "time", "ago", "last", "earlier", "back", "into", "onto", "would", "should", "will", "been", "being",
        "its", "him", "her", "she", "he", "they", "them", "those", "these", "any", "all", "one", "get", "got"
    ]

    static func queryWords(in text: String) -> [String] {
        var seen = Set<String>()
        return words(in: text).filter { !stopWords.contains($0) && seen.insert($0).inserted }
    }

    static func wordSet(_ text: String) -> Set<String> {
        Set(words(in: text))
    }

    /// Lowercase words with simple endings dropped ("sites" → "site").
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { stem(String($0)) }
            .filter { $0.count > 1 }
    }

    private static func stem(_ word: String) -> String {
        if word.count > 5, word.hasSuffix("ing") { return String(word.dropLast(3)) }
        if word.count > 4, word.hasSuffix("ed") { return String(word.dropLast(2)) }
        if word.count > 4, word.hasSuffix("es") { return String(word.dropLast(2)) }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast(1)) }
        return word
    }

    /// The most frequent meaningful words, for tags.
    static func keywords(in text: String, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for word in words(in: text) where word.count > 3 && !stopWords.contains(word) {
            counts[word, default: 0] += 1
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// "find the cheapest flight to lisbon on kayak" → "Find the cheapest flight to lisbon on…"
    static func shortTitle(from text: String) -> String {
        let firstLine = firstSentence(of: text)
        let titleWords = firstLine.split(separator: " ").prefix(7)
        var title = titleWords.joined(separator: " ")
        if firstLine.split(separator: " ").count > 7 { title += "…" }
        guard let first = title.first else { return "Something" }
        return first.uppercased() + title.dropFirst()
    }

    static func firstSentence(of text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmedText.components(separatedBy: .newlines).first ?? trimmedText
        if let sentenceEnd = firstLine.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            return String(firstLine[..<sentenceEnd.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return String(firstLine.prefix(160))
    }

    static func firstLink(in text: String) -> String? {
        guard let range = text.range(of: #"https?://[^\s)\]>"']+"#, options: .regularExpression) else { return nil }
        return String(text[range].prefix(300))
    }

    /// "today 3:05 pm", "yesterday 9 am", "tuesday 4:10 pm", "12 oct"
    static func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let time = timeFormatter.string(from: date).lowercased()
        if calendar.isDateInToday(date) { return "today \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        let dayFormatter = DateFormatter()
        if now.timeIntervalSince(date) < 6 * 86_400 {
            dayFormatter.dateFormat = "EEEE"
            return "\(dayFormatter.string(from: date).lowercased()) \(time)"
        }
        dayFormatter.dateFormat = "d MMM"
        return dayFormatter.string(from: date).lowercased()
    }

    /// Screen notes grouped by app and site, made on this Mac when Gemini
    /// is busy.
    static func groupedOnDevice(_ moments: [DottieScreenMoment]) -> [DottieEpisode] {
        var groups: [[DottieScreenMoment]] = []
        for moment in moments {
            if let lastMoment = groups.last?.last,
               lastMoment.context.appName == moment.context.appName,
               host(of: lastMoment.context.url) == host(of: moment.context.url) {
                groups[groups.count - 1].append(moment)
            } else {
                groups.append([moment])
            }
        }
        // The longest few stretches; single glances are dropped when
        // there's more to say.
        let keptGroups = groups.count > 4
            ? groups.filter { $0.count >= 2 }.sorted { $0.count > $1.count }.prefix(4).sorted { $0[0].date < $1[0].date }
            : groups
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        return keptGroups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let appName = first.context.appName ?? "an app"
            var windowTitles: [String] = []
            for moment in group {
                if let windowTitle = moment.context.windowTitle, !windowTitle.isEmpty, !windowTitles.contains(windowTitle) {
                    windowTitles.append(windowTitle)
                }
            }
            let mainTitle = windowTitles.first.map { String($0.prefix(60)) }
            let siteName = host(of: last.context.url)
            let title = mainTitle.map { "\($0) in \(appName)" } ?? (siteName.map { "\($0) in \(appName)" } ?? "Using \(appName)")
            var summary = "Was in \(appName)\(siteName.map { " on \($0)" } ?? "") from \(timeFormatter.string(from: first.date)) to \(timeFormatter.string(from: last.date))."
            if windowTitles.count > 1 {
                summary += " Windows: " + windowTitles.prefix(4).map { String($0.prefix(60)) }.joined(separator: "; ") + "."
            }
            let textSample = group.map(\.text).first { !$0.isEmpty }
            if let textSample { summary += " On screen: \(textSample.prefix(160))" }
            return DottieEpisode(
                id: UUID(),
                startedAt: first.date,
                endedAt: last.date,
                title: String(title.prefix(80)),
                summary: summary,
                appName: appName,
                bundleIdentifier: last.context.bundleIdentifier,
                windowTitle: last.context.windowTitle,
                url: last.context.url,
                people: [],
                outcome: nil,
                tags: keywords(in: windowTitles.joined(separator: " ") + " " + appName, limit: 4),
                source: .screen,
                importance: min(0.15 + Double(group.count) * 0.03, 0.35),
                thumbnailFileName: nil
            )
        }
    }

    static func host(of urlText: String?) -> String? {
        guard let urlText, !urlText.isEmpty else { return nil }
        let withScheme = urlText.contains("://") ? urlText : "https://" + urlText
        guard let host = URL(string: withScheme)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Meaning search (optional)

/// Gemini embeddings for episodes, used only when word search finds
/// little. Any failure just means word search alone for a while.
@MainActor
final class DottieEpisodeEmbeddings {
    private static let model = "gemini-embedding-001"
    private static let dimensions = 256
    /// Never hold up a voice answer longer than this.
    private static let queryTimeout: TimeInterval = 1.5
    private static let maximumEpisodesPerCall = 50

    private let fileURL: URL
    private var vectors: [String: [Float]] = [:]
    private var pausedUntil = Date.distantPast
    private var isEmbedding = false
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let fileData = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: [Float]].self, from: fileData) {
            vectors = saved
        }
    }

    private var isAvailable: Bool {
        ClickyWorkerConfiguration.isWorkerConfigured && Date() >= pausedUntil
    }

    private func pause() {
        pausedUntil = Date().addingTimeInterval(600)
    }

    /// Embeds episodes that have no vector yet, newest first, in one call.
    func embedMissing(in episodes: [DottieEpisode]) {
        guard isAvailable, !isEmbedding else { return }
        let missing = Array(episodes.reversed().filter { vectors[$0.id.uuidString] == nil }.prefix(Self.maximumEpisodesPerCall))
        guard !missing.isEmpty else { return }
        isEmbedding = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isEmbedding = false }
            let requests: [[String: Any]] = missing.map { episode in
                [
                    "model": "models/\(Self.model)",
                    "content": ["parts": [["text": Self.text(for: episode)]]],
                    "taskType": "RETRIEVAL_DOCUMENT",
                    "outputDimensionality": Self.dimensions
                ]
            }
            guard let reply = await DottieMemoryNetwork.postToGemini(
                path: "/v1beta/models/\(Self.model):batchEmbedContents",
                body: ["requests": requests],
                timeout: 30
            ), let embeddings = reply["embeddings"] as? [[String: Any]], embeddings.count == missing.count else {
                self.pause()
                return
            }
            for (episode, embedding) in zip(missing, embeddings) {
                if let values = embedding["values"] as? [NSNumber] {
                    self.vectors[episode.id.uuidString] = values.map { $0.floatValue }
                }
            }
            self.saveSoon()
        }
    }

    /// Episodes closest in meaning to the question, or nil when embeddings
    /// aren't available or too slow right now.
    func closest(to query: String, among episodes: [DottieEpisode], limit: Int) async -> [(episode: DottieEpisode, similarity: Double)]? {
        guard isAvailable, !vectors.isEmpty else { return nil }
        let body: [String: Any] = [
            "content": ["parts": [["text": query]]],
            "taskType": "RETRIEVAL_QUERY",
            "outputDimensionality": Self.dimensions
        ]
        guard let reply = await DottieMemoryNetwork.postToGemini(
            path: "/v1beta/models/\(Self.model):embedContent", body: body, timeout: Self.queryTimeout
        ), let embedding = reply["embedding"] as? [String: Any],
              let values = embedding["values"] as? [NSNumber] else {
            pause()
            return nil
        }
        let queryVector = values.map { $0.floatValue }
        let matches = episodes.compactMap { episode -> (episode: DottieEpisode, similarity: Double)? in
            guard let vector = vectors[episode.id.uuidString] else { return nil }
            let similarity = Self.cosineSimilarity(queryVector, vector)
            return similarity >= 0.6 ? (episode: episode, similarity: similarity) : nil
        }
        return Array(matches.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    func remove(_ episodeIDs: Set<UUID>) {
        guard !episodeIDs.isEmpty else { return }
        for episodeID in episodeIDs { vectors[episodeID.uuidString] = nil }
        saveSoon()
    }

    func removeAll() {
        vectors = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if let fileData = try? JSONEncoder().encode(self.vectors) {
                try? fileData.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    private static func text(for episode: DottieEpisode) -> String {
        "\(episode.title). \(episode.summary) \(episode.whereText) \(episode.tags.joined(separator: " "))"
    }

    private static func cosineSimilarity(_ first: [Float], _ second: [Float]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var dotProduct: Float = 0
        var firstLength: Float = 0
        var secondLength: Float = 0
        for index in first.indices {
            dotProduct += first[index] * second[index]
            firstLength += first[index] * first[index]
            secondLength += second[index] * second[index]
        }
        guard firstLength > 0, secondLength > 0 else { return 0 }
        return Double(dotProduct / (firstLength.squareRoot() * secondLength.squareRoot()))
    }
}
