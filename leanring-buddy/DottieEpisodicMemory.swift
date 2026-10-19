//
//  DottieEpisodicMemory.swift
//  leanring-buddy
//
//  Dottie's episodic memory: short stories of what happened ("checked the
//  Kaggle rank in Opera, 312th"), with when, where (app, window, web
//  page), who and what was involved, and how it ended. Filled on its own:
//
//    - conversations: once the user stops talking for a bit, ONE quick
//      Gemini call turns the whole conversation (plus the app, window and
//      page they were in, and the last screenshot) into 0-3 episodes.
//      Small talk is skipped.
//    - helpers: every finished helper task becomes an episode (no call).
//    - screen jobs: every finished do_task_on_screen job (no call).
//    - the screen, if the user turns on "Remember what's on my screen"
//      (off by default): light notes made on this Mac, folded into
//      episodes now and then (see DottieEpisodicMemoryScreen.swift).
//
//  Voice Dottie gets the few most relevant recent episodes in every
//  conversation, and searches the rest with the memories tool (and
//  recall_memory / ask_brain, which include them).
//
//  On disk, under ~/Library/Application Support/Dottie/Memory/:
//    episodes.jsonl    one episode per line, oldest first
//    index.json        a light day-by-day list of titles (for helpers)
//    pending.json      the conversation not yet turned into episodes
//    moments.jsonl     screen notes not yet folded into episodes
//    embeddings.json   optional meaning vectors for smarter search
//    Thumbnails/       small pictures for some episodes
//

import AppKit
import Combine
import Foundation

struct DottieEpisode: Codable, Identifiable, Equatable {
    enum Source: String, Codable, CaseIterable {
        case conversation
        case helper
        case screenJob
        case screen

        var label: String {
            switch self {
            case .conversation: return "talk"
            case .helper: return "helper"
            case .screenJob: return "screen job"
            case .screen: return "on screen"
            }
        }

        var symbolName: String {
            switch self {
            case .conversation: return "bubble.left.and.bubble.right.fill"
            case .helper: return "person.crop.circle.badge.checkmark"
            case .screenJob: return "cursorarrow.click.2"
            case .screen: return "eye.fill"
            }
        }
    }

    let id: UUID
    var startedAt: Date
    var endedAt: Date
    var title: String
    /// What happened, in 2-4 sentences.
    var summary: String
    var appName: String?
    var bundleIdentifier: String?
    var windowTitle: String?
    var url: String?
    var people: [String]
    var outcome: String?
    var tags: [String]
    var source: Source
    /// 0...1: how likely the user is to ask about it again.
    var importance: Double
    var thumbnailFileName: String?

    /// What the user says to point at one ("forget #a1b2c3").
    var shortID: String { String(id.uuidString.prefix(6)).lowercased() }

    /// "Safari — Kaggle (kaggle.com/competitions)"
    var whereText: String {
        var parts: [String] = []
        if let appName, !appName.isEmpty { parts.append(appName) }
        if let windowTitle, !windowTitle.isEmpty, windowTitle != appName { parts.append("\u{201C}\(windowTitle)\u{201D}") }
        var text = parts.joined(separator: " — ")
        if let url, !url.isEmpty { text += text.isEmpty ? url : " (\(url))" }
        return text
    }
}

/// The app, window and page the user is in.
struct DottieScreenContext: Codable, Equatable {
    var appName: String?
    var bundleIdentifier: String?
    var windowTitle: String?
    var url: String?
    /// A private browser window or a password box is in front.
    var isPrivate: Bool = false
    /// The front window, in Accessibility's top-left screen coordinates.
    var windowFrame: CGRect?

    var lineForModel: String {
        var parts: [String] = []
        if let appName { parts.append(appName) }
        if let windowTitle, !windowTitle.isEmpty { parts.append("window \u{201C}\(windowTitle.prefix(120))\u{201D}") }
        if let url, !url.isEmpty { parts.append("page \(url.prefix(160))") }
        return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")
    }
}

@MainActor
final class DottieEpisodicMemory: ObservableObject {
    static let shared = DottieEpisodicMemory()

    /// The cheapest quick model the app already uses.
    static let summarizingModel = "gemini-3.5-flash-lite"
    static let maximumEpisodes = 3000
    /// Quiet time after the last exchange before a conversation is saved.
    private static let conversationIdleSeconds: TimeInterval = 150
    /// Never more than one memory call this often, on the free tier.
    private static let minimumSecondsBetweenModelCalls: TimeInterval = 20
    private static let maximumPendingExchanges = 40
    private static let helperFinishedNotification = Notification.Name("dottie.helperFinished")

    /// Oldest first.
    @Published private(set) var episodes: [DottieEpisode] = []
    @Published private(set) var isSaving = false

    /// Called with new episodes (and after deletes, with none), so the voice
    /// prompt and the brain's journal can pick them up.
    var onEpisodesChanged: (([DottieEpisode]) -> Void)?

    let folderURL: URL
    var thumbnailsFolderURL: URL { folderURL.appendingPathComponent("Thumbnails", isDirectory: true) }
    private var episodesFileURL: URL { folderURL.appendingPathComponent("episodes.jsonl") }
    private var indexFileURL: URL { folderURL.appendingPathComponent("index.json") }
    private var pendingFileURL: URL { folderURL.appendingPathComponent("pending.json") }

    /// The optional "Remember what's on my screen" notes.
    let screenMemory: DottieScreenMemory
    /// Optional meaning search; plain word search works without it.
    let embeddings: DottieEpisodeEmbeddings

    private struct PendingExchange: Codable {
        let id: UUID
        let date: Date
        let userText: String
        let dottieText: String
        var context: DottieScreenContext?
    }

    private var pendingExchanges: [PendingExchange] = []
    /// The last screenshot Dottie saw in the current conversation.
    private var latestConversationScreenshot: Data?
    private var conversationIdleTask: Task<Void, Never>?
    private var nextModelCallSlot = Date.distantPast
    private var busyUntil = Date.distantPast
    private var helperObserver: NSObjectProtocol?
    private var hasStarted = false
    /// Word lists per episode, built on demand for search.
    var cachedSearchWords: [UUID: DottieEpisodeSearch.Words] = [:]

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = applicationSupportURL.appendingPathComponent("Dottie/Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folderURL.appendingPathComponent("Thumbnails", isDirectory: true), withIntermediateDirectories: true)
        screenMemory = DottieScreenMemory(folderURL: folderURL)
        embeddings = DottieEpisodeEmbeddings(fileURL: folderURL.appendingPathComponent("embeddings.json"))
        episodes = loadEpisodes()
        pendingExchanges = loadPending()
        if pruneIfNeeded() { rewriteEpisodesFile() }
    }

    /// Starts listening for helpers, the screen notes and any conversation
    /// left over from last time. Safe to call more than once.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        screenMemory.memory = self
        screenMemory.start()
        helperObserver = NotificationCenter.default.addObserver(
            forName: Self.helperFinishedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let userInfo = notification.userInfo ?? [:]
            let helperName = (userInfo["helper"] as? String) ?? "A helper"
            let taskText = (userInfo["task"] as? String) ?? ""
            let resultText = (userInfo["result"] as? String) ?? ""
            MainActor.assumeIsolated {
                self?.recordHelperResult(helperName: helperName, taskText: taskText, resultText: resultText)
            }
        }
        // A conversation cut off by quitting is saved a little after launch.
        if !pendingExchanges.isEmpty {
            scheduleConversationSave(after: 45)
        }
        embeddings.embedMissing(in: episodes)
    }

    // MARK: - Conversations

    /// Called for every exchange saved to the conversation.
    func noteExchange(userText: String, dottieText: String) {
        let exchange = PendingExchange(
            id: UUID(),
            date: Date(),
            userText: String(userText.prefix(1500)),
            dottieText: String(dottieText.prefix(1500)),
            context: nil
        )
        pendingExchanges.append(exchange)
        if pendingExchanges.count > Self.maximumPendingExchanges {
            pendingExchanges.removeFirst(pendingExchanges.count - Self.maximumPendingExchanges)
        }
        savePending()
        // Where the user was, read off the main thread.
        Task { [weak self] in
            guard let context = await DottieScreenContextReader.current() else { return }
            guard let self, let index = self.pendingExchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
            self.pendingExchanges[index].context = context.isPrivate ? nil : context
            self.savePending()
        }
        scheduleConversationSave(after: Self.conversationIdleSeconds)
    }

    /// The frame sent with the latest voice turn. Only kept in memory.
    func noteConversationScreenshot(_ jpegData: Data?) {
        guard let jpegData else { return }
        latestConversationScreenshot = jpegData
    }

    private func scheduleConversationSave(after seconds: TimeInterval) {
        conversationIdleTask?.cancel()
        conversationIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.saveConversation()
        }
    }

    /// Turns the conversation so far into episodes with one model call.
    private func saveConversation() async {
        guard !pendingExchanges.isEmpty, !isSaving else { return }
        let exchanges = pendingExchanges
        let screenshot = latestConversationScreenshot

        // Nothing worth a call: a hello, a thanks, a one-word turn.
        let userLetters = exchanges.map(\.userText).joined().filter(\.isLetter).count
        guard userLetters >= 20 || exchanges.count >= 3 else {
            finishConversation(exchanges)
            return
        }
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            finishConversation(exchanges)
            return
        }

        isSaving = true
        defer { isSaving = false }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "EEE HH:mm"
        let transcript = exchanges.enumerated().map { index, exchange in
            "[\(index + 1)] \(timeFormatter.string(from: exchange.date)), user in: \(exchange.context?.lineForModel ?? "unknown")\nuser: \(exchange.userText)\ndottie: \(exchange.dottieText)"
        }.joined(separator: "\n\n")

        let instruction = """
        You keep the episodic memory of Dottie, a voice companion on the user's Mac, so later she can answer things like "what did we talk about yesterday" or "what was that site I was on". Below is one conversation, numbered by exchange, with the app, window and web page the user was in\(screenshot == nil ? "" : ", and the last screenshot from it").

        Turn it into 0 to 3 episodes, one per separate thing that happened (a question answered, a problem solved, a plan or decision made, something found, a task started). Skip small talk, greetings, thanks and test lines: return [] if nothing is worth remembering.
        For each episode:
        - title: under 8 words, specific ("Kaggle rank check", not "Conversation")
        - summary: 2 to 4 plain sentences: what the user wanted, what was found or done, and the key specifics (names, numbers, sites, files, prices)
        - app, window, url: where it happened, when known
        - people: people and things involved (names, projects, products)
        - outcome: one short line on how it ended
        - tags: 2 to 5 lowercase words
        - importance: 0 to 1 (1 = they'll likely ask about it again: a decision, plan, file, site or fact they cared about)
        - firstExchange, lastExchange: exchange numbers it covers
        Never include passwords, codes, card numbers or other secrets. Reply with JSON only.

        Conversation:
        \(transcript)
        """

        var parts: [[String: Any]] = []
        let smallScreenshot = screenshot.flatMap { DottieEpisodeThumbnails.downscaledJPEG($0, maximumDimension: 768, quality: 0.6) }
        if let smallScreenshot {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": smallScreenshot.base64EncodedString()]])
        }
        parts.append(["text": instruction])

        guard let parsed = await requestEpisodes(parts: parts, rangeKeys: ("firstExchange", "lastExchange")) else {
            // Busy or offline: keep it for the next try.
            scheduleConversationSave(after: 180)
            return
        }

        var newEpisodes: [DottieEpisode] = []
        for (index, draft) in parsed.prefix(3).enumerated() {
            let firstIndex = min(max(draft.firstIndex ?? 1, 1), exchanges.count) - 1
            let lastIndex = min(max(draft.lastIndex ?? exchanges.count, firstIndex + 1), exchanges.count) - 1
            let context = exchanges[firstIndex...lastIndex].last(where: { $0.context != nil })?.context
            var episode = draft.makeEpisode(
                source: .conversation,
                startedAt: exchanges[firstIndex].date,
                endedAt: exchanges[lastIndex].date,
                context: context
            )
            // The screenshot goes with the part of the talk it came from.
            if let screenshot, index == parsed.prefix(3).count - 1 {
                episode.thumbnailFileName = DottieEpisodeThumbnails.save(screenshot, for: episode.id, in: thumbnailsFolderURL)
            }
            newEpisodes.append(episode)
        }
        finishConversation(exchanges)
        add(newEpisodes)
    }

    private func finishConversation(_ savedExchanges: [PendingExchange]) {
        let savedIDs = Set(savedExchanges.map(\.id))
        pendingExchanges.removeAll { savedIDs.contains($0.id) }
        if pendingExchanges.isEmpty { latestConversationScreenshot = nil }
        savePending()
    }

    // MARK: - Helpers and screen jobs (no model call)

    func recordHelperResult(helperName: String, taskText: String, resultText: String) {
        let task = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty || !result.isEmpty else { return }
        // The same task reported twice in a row.
        if let lastEpisode = episodes.last, lastEpisode.source == .helper,
           Date().timeIntervalSince(lastEpisode.endedAt) < 60,
           lastEpisode.summary.contains(String(task.prefix(80))) {
            return
        }
        let summary = "\(helperName) was asked to: \(task.prefix(260)). It replied: \(result.prefix(420))"
        let episode = DottieEpisode(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            title: "\(helperName): \(DottieEpisodeSearch.shortTitle(from: task.isEmpty ? result : task))",
            summary: summary,
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            url: DottieEpisodeSearch.firstLink(in: result),
            people: [helperName],
            outcome: String(DottieEpisodeSearch.firstSentence(of: result).prefix(160)),
            tags: DottieEpisodeSearch.keywords(in: task, limit: 4),
            source: .helper,
            importance: 0.5,
            thumbnailFileName: nil
        )
        add([episode])
    }

    func recordScreenJob(taskText: String, resultText: String, succeeded: Bool) {
        let task = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        Task { [weak self] in
            let context = await DottieScreenContextReader.current()
            guard let self else { return }
            let usableContext = (context?.isPrivate ?? true) ? nil : context
            let episode = DottieEpisode(
                id: UUID(),
                startedAt: Date(),
                endedAt: Date(),
                title: DottieEpisodeSearch.shortTitle(from: task),
                summary: "Dottie did this on screen for the user: \(task.prefix(300)). \(succeeded ? "Result" : "It didn't work out"): \(resultText.prefix(400))",
                appName: usableContext?.appName,
                bundleIdentifier: usableContext?.bundleIdentifier,
                windowTitle: usableContext?.windowTitle,
                url: usableContext?.url,
                people: [],
                outcome: String(DottieEpisodeSearch.firstSentence(of: resultText).prefix(160)),
                tags: DottieEpisodeSearch.keywords(in: task, limit: 4),
                source: .screenJob,
                importance: succeeded ? 0.45 : 0.35,
                thumbnailFileName: nil
            )
            self.add([episode])
        }
    }

    // MARK: - Screen notes

    /// Folds screen notes into a few episodes: one quick call when Gemini
    /// is free, else grouped on this Mac. Always succeeds.
    func foldScreenMoments(_ moments: [DottieScreenMoment]) async {
        guard !moments.isEmpty else { return }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "EEE HH:mm"
        var newEpisodes: [DottieEpisode] = []

        if ClickyWorkerConfiguration.isWorkerConfigured, moments.count >= 2, Date() >= busyUntil {
            let lines = moments.enumerated().map { index, moment in
                "[\(index + 1)] \(timeFormatter.string(from: moment.date)) \(moment.context.lineForModel)\(moment.text.isEmpty ? "" : "\n    text on screen: \(moment.text)")"
            }.joined(separator: "\n")
            let instruction = """
            You keep the episodic memory of Dottie, a companion on the user's Mac. These are notes of what was on the user's screen, taken every few minutes. Turn them into 1 to 4 episodes of what the user was doing: merge related notes (same task or topic across apps), skip idle or meaningless ones.
            For each: title (under 8 words, specific), summary (2 or 3 plain sentences: what they were doing and the specifics like page, file, project or topic), app, window, url (the main one), people (people, projects or products involved), outcome (one short line, or empty), tags (2 to 5 lowercase words), importance (0 to 1; most screen time is 0.2 to 0.4), firstNote and lastNote (note numbers).
            Never include passwords, codes, card numbers, or what private messages or emails say; say only who or what they were about. Reply with JSON only.

            Notes:
            \(lines)
            """
            if let parsed = await requestEpisodes(parts: [["text": instruction]], rangeKeys: ("firstNote", "lastNote"), waitsForSlot: false) {
                for draft in parsed.prefix(4) {
                    let firstIndex = min(max(draft.firstIndex ?? 1, 1), moments.count) - 1
                    let lastIndex = min(max(draft.lastIndex ?? moments.count, firstIndex + 1), moments.count) - 1
                    newEpisodes.append(draft.makeEpisode(
                        source: .screen,
                        startedAt: moments[firstIndex].date,
                        endedAt: moments[lastIndex].date,
                        context: moments[lastIndex].context,
                        maximumImportance: 0.6
                    ))
                }
            }
        }
        if newEpisodes.isEmpty {
            newEpisodes = DottieEpisodeSearch.groupedOnDevice(moments)
        }
        add(newEpisodes)
    }

    // MARK: - The model call

    private struct EpisodeDraft {
        let fields: [String: Any]
        let firstIndex: Int?
        let lastIndex: Int?

        func string(_ key: String) -> String? {
            let text = (fields[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }

        func strings(_ key: String) -> [String] {
            ((fields[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        func makeEpisode(source: DottieEpisode.Source, startedAt: Date, endedAt: Date, context: DottieScreenContext?, maximumImportance: Double = 1) -> DottieEpisode {
            let importance = (fields["importance"] as? NSNumber)?.doubleValue ?? 0.4
            return DottieEpisode(
                id: UUID(),
                startedAt: startedAt,
                endedAt: max(endedAt, startedAt),
                title: String((string("title") ?? "Something we did").prefix(80)),
                summary: String((string("summary") ?? "").prefix(700)),
                appName: string("app") ?? context?.appName,
                bundleIdentifier: context?.bundleIdentifier,
                windowTitle: (string("window") ?? context?.windowTitle).map { String($0.prefix(160)) },
                url: (string("url") ?? context?.url).map { String($0.prefix(300)) },
                people: Array(strings("people").prefix(8)),
                outcome: string("outcome").map { String($0.prefix(200)) },
                tags: Array(strings("tags").map { $0.lowercased() }.prefix(6)),
                source: source,
                importance: min(max(importance, 0), maximumImportance),
                thumbnailFileName: nil
            )
        }
    }

    private static let episodeSchema: [String: Any] = [
        "type": "ARRAY",
        "items": [
            "type": "OBJECT",
            "properties": [
                "title": ["type": "STRING"],
                "summary": ["type": "STRING"],
                "app": ["type": "STRING"],
                "window": ["type": "STRING"],
                "url": ["type": "STRING"],
                "people": ["type": "ARRAY", "items": ["type": "STRING"]],
                "outcome": ["type": "STRING"],
                "tags": ["type": "ARRAY", "items": ["type": "STRING"]],
                "importance": ["type": "NUMBER"],
                "first": ["type": "INTEGER"],
                "last": ["type": "INTEGER"]
            ],
            "required": ["title", "summary"]
        ]
    ]

    /// One paced call that returns episode drafts, or nil when Gemini is
    /// busy or unreachable.
    private func requestEpisodes(parts: [[String: Any]], rangeKeys: (first: String, last: String), waitsForSlot: Bool = true) async -> [EpisodeDraft]? {
        if Date() < busyUntil { return nil }
        let now = Date()
        let slot = max(now, nextModelCallSlot)
        if !waitsForSlot && slot > now { return nil }
        nextModelCallSlot = slot.addingTimeInterval(Self.minimumSecondsBetweenModelCalls)
        if slot > now {
            try? await Task.sleep(nanoseconds: UInt64(slot.timeIntervalSince(now) * 1_000_000_000))
        }

        // The schema names the range fields "first"/"last"; the prompt's
        // own names are accepted too.
        let requestBody: [String: Any] = [
            "model": Self.summarizingModel,
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": Self.episodeSchema
            ]
        ]
        switch await DottieMemoryNetwork.postToChat(requestBody) {
        case .busy:
            busyUntil = Date().addingTimeInterval(90)
            return nil
        case .failed:
            return nil
        case .text(let answerText):
            guard let items = DottieMemoryNetwork.jsonArray(in: answerText) else { return nil }
            return items.compactMap { item in
                guard let fields = item as? [String: Any] else { return nil }
                let first = ((fields["first"] as? NSNumber) ?? (fields[rangeKeys.first] as? NSNumber))?.intValue
                let last = ((fields["last"] as? NSNumber) ?? (fields[rangeKeys.last] as? NSNumber))?.intValue
                let draft = EpisodeDraft(fields: fields, firstIndex: first, lastIndex: last)
                return draft.string("title") == nil && draft.string("summary") == nil ? nil : draft
            }
        }
    }

    // MARK: - Changing the list

    func add(_ newEpisodes: [DottieEpisode]) {
        let usableEpisodes = newEpisodes.filter { !$0.title.isEmpty || !$0.summary.isEmpty }
        guard !usableEpisodes.isEmpty else { return }
        episodes.append(contentsOf: usableEpisodes)
        episodes.sort { $0.startedAt < $1.startedAt }
        if pruneIfNeeded() {
            rewriteEpisodesFile()
        } else {
            appendToEpisodesFile(usableEpisodes)
            writeIndex()
        }
        embeddings.embedMissing(in: usableEpisodes)
        onEpisodesChanged?(usableEpisodes)
    }

    func delete(_ episodeIDs: Set<UUID>) {
        guard !episodeIDs.isEmpty else { return }
        for episode in episodes where episodeIDs.contains(episode.id) {
            removeThumbnail(of: episode)
        }
        episodes.removeAll { episodeIDs.contains($0.id) }
        episodeIDs.forEach { cachedSearchWords[$0] = nil }
        embeddings.remove(episodeIDs)
        rewriteEpisodesFile()
        onEpisodesChanged?([])
    }

    func forgetEverything() {
        conversationIdleTask?.cancel()
        episodes = []
        pendingExchanges = []
        latestConversationScreenshot = nil
        cachedSearchWords = [:]
        try? FileManager.default.removeItem(at: thumbnailsFolderURL)
        try? FileManager.default.createDirectory(at: thumbnailsFolderURL, withIntermediateDirectories: true)
        embeddings.removeAll()
        screenMemory.forgetPendingMoments()
        rewriteEpisodesFile()
        savePending()
        onEpisodesChanged?([])
    }

    /// Keeps the list under its cap: old screen notes go first, then the
    /// least important of the oldest. Returns true when anything went.
    @discardableResult
    private func pruneIfNeeded() -> Bool {
        let now = Date()
        let countBefore = episodes.count
        // Screen notes fade after three months.
        let staleScreenEpisodes = episodes.filter { $0.source == .screen && now.timeIntervalSince($0.startedAt) > 90 * 86_400 }
        if !staleScreenEpisodes.isEmpty {
            staleScreenEpisodes.forEach(removeThumbnail(of:))
            let staleIDs = Set(staleScreenEpisodes.map(\.id))
            episodes.removeAll { staleIDs.contains($0.id) }
        }
        if episodes.count > Self.maximumEpisodes {
            let overflow = episodes.count - Self.maximumEpisodes
            // Lowest keep score goes: importance, with a year of slow fade.
            let ranked = episodes.sorted { keepScore($0, now: now) < keepScore($1, now: now) }
            let removedEpisodes = ranked.prefix(overflow)
            removedEpisodes.forEach(removeThumbnail(of:))
            let removedIDs = Set(removedEpisodes.map(\.id))
            episodes.removeAll { removedIDs.contains($0.id) }
            embeddings.remove(removedIDs)
        }
        return episodes.count != countBefore
    }

    private func keepScore(_ episode: DottieEpisode, now: Date) -> Double {
        let ageInDays = now.timeIntervalSince(episode.startedAt) / 86_400
        let sourceBonus = episode.source == .screen ? -0.2 : 0
        return episode.importance + sourceBonus - min(ageInDays / 365, 1)
    }

    private func removeThumbnail(of episode: DottieEpisode) {
        guard let thumbnailFileName = episode.thumbnailFileName else { return }
        try? FileManager.default.removeItem(at: thumbnailsFolderURL.appendingPathComponent(thumbnailFileName))
    }

    func thumbnailURL(for episode: DottieEpisode) -> URL? {
        guard let thumbnailFileName = episode.thumbnailFileName else { return nil }
        let thumbnailURL = thumbnailsFolderURL.appendingPathComponent(thumbnailFileName)
        return FileManager.default.fileExists(atPath: thumbnailURL.path) ? thumbnailURL : nil
    }

    // MARK: - Storage

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func loadEpisodes() -> [DottieEpisode] {
        guard let fileData = try? Data(contentsOf: episodesFileURL) else { return [] }
        let decoder = Self.makeDecoder()
        return fileData.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(DottieEpisode.self, from: Data($0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func appendToEpisodesFile(_ newEpisodes: [DottieEpisode]) {
        let encoder = Self.makeEncoder()
        var linesData = Data()
        for episode in newEpisodes {
            guard let lineData = try? encoder.encode(episode) else { continue }
            linesData.append(lineData)
            linesData.append(UInt8(ascii: "\n"))
        }
        if let fileHandle = try? FileHandle(forWritingTo: episodesFileURL) {
            defer { try? fileHandle.close() }
            _ = try? fileHandle.seekToEnd()
            try? fileHandle.write(contentsOf: linesData)
        } else {
            try? linesData.write(to: episodesFileURL, options: .atomic)
        }
    }

    private func rewriteEpisodesFile() {
        let encoder = Self.makeEncoder()
        var fileData = Data()
        for episode in episodes {
            guard let lineData = try? encoder.encode(episode) else { continue }
            fileData.append(lineData)
            fileData.append(UInt8(ascii: "\n"))
        }
        try? fileData.write(to: episodesFileURL, options: .atomic)
        writeIndex()
    }

    /// Day → titles, small enough for a helper to read whole.
    private func writeIndex() {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        var days: [String: [String]] = [:]
        for episode in episodes {
            let line = "\(timeFormatter.string(from: episode.startedAt)) [\(episode.source.label)] \(episode.title) #\(episode.shortID)"
            days[dayFormatter.string(from: episode.startedAt), default: []].append(line)
        }
        let index: [String: Any] = ["count": episodes.count, "file": "episodes.jsonl", "days": days]
        if let indexData = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]) {
            try? indexData.write(to: indexFileURL, options: .atomic)
        }
    }

    private func loadPending() -> [PendingExchange] {
        guard let pendingData = try? Data(contentsOf: pendingFileURL) else { return [] }
        return (try? Self.makeDecoder().decode([PendingExchange].self, from: pendingData)) ?? []
    }

    private func savePending() {
        if pendingExchanges.isEmpty {
            try? FileManager.default.removeItem(at: pendingFileURL)
            return
        }
        guard let pendingData = try? Self.makeEncoder().encode(pendingExchanges) else { return }
        try? pendingData.write(to: pendingFileURL, options: .atomic)
    }
}

// MARK: - Network

enum DottieMemoryNetwork {
    enum ChatResult {
        case text(String)
        case busy
        case failed
    }

    /// The Worker's /chat route (Gemini, streamed as server-sent events).
    static func postToChat(_ requestBody: [String: Any], timeout: TimeInterval = 60) async -> ChatResult {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return .failed }
        request.httpBody = requestBodyData
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              let statusCode = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        if [429, 500, 502, 503, 504].contains(statusCode) { return .busy }
        guard statusCode == 200 else { return .failed }
        let answerText = GeminiServerSentEvents.text(from: responseData)
        return answerText.isEmpty ? .failed : .text(answerText)
    }

    /// The Worker's Gemini passthrough, which adds the key. Returns the
    /// JSON reply, or nil.
    static func postToGemini(path: String, body: [String: Any], timeout: TimeInterval) async -> [String: Any]? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/gemini" + path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        // The passthrough checks the shared secret as the API key.
        if let appSharedSecret = ClickyWorkerConfiguration.appSharedSecret {
            request.setValue(appSharedSecret, forHTTPHeaderField: "x-goog-api-key")
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }

    /// The first JSON array in a reply, even when wrapped in a code fence.
    static func jsonArray(in text: String) -> [Any]? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmedText.data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array
        }
        guard let start = trimmedText.firstIndex(of: "["), let end = trimmedText.lastIndex(of: "]"), start < end,
              let data = String(trimmedText[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [Any]
    }
}

// MARK: - Thumbnails

enum DottieEpisodeThumbnails {
    /// Saves a small copy of the picture and returns its file name.
    static func save(_ imageData: Data, for episodeID: UUID, in folderURL: URL) -> String? {
        guard let thumbnailData = downscaledJPEG(imageData, maximumDimension: 320, quality: 0.6) else { return nil }
        let fileName = "\(episodeID.uuidString).jpg"
        do {
            try thumbnailData.write(to: folderURL.appendingPathComponent(fileName), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func downscaledJPEG(_ imageData: Data, maximumDimension: Int, quality: Double) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: thumbnail).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
