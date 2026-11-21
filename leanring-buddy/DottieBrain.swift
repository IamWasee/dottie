//
//  DottieBrain.swift
//  leanring-buddy
//
//  Dottie's second brain: a memory of everything she and the helpers do,
//  kept on the Mac, plus the settings for the Brain agent (folders it may
//  read, MCP servers it may use) and the optional screen journal.
//
//  On disk, under ~/Library/Application Support/Dottie/Brain/:
//    journal.jsonl     one memory per line: chats, helper results, guides,
//                      screen jobs, things the user asked to remember, and
//                      (if turned on) what the user was doing on screen
//    profile.md        "what I know about you": a short note Gemini keeps
//                      up to date from the journal; the user can edit it
//    folders.json      folders the Brain agent may read and work in
//    mcp.json          MCP servers for the Brain and the helpers, in the
//                      same {"mcpServers": {...}} shape Claude and Gemini
//                      CLI use
//
//  Voice Dottie reads the profile in every conversation, searches the
//  journal with recall_memory, and hands real work to the Brain agent
//  (see ClickyRoster.brainAgent()) with ask_brain.
//
//  The screen journal switch now drives "Remember what's on my screen" in
//  the episodic memory (DottieEpisodicMemoryScreen.swift): notes made on
//  this Mac instead of a screenshot sent to Gemini every two minutes.
//  recall_memory searches those episodes too.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class DottieBrain: ObservableObject {
    struct Memory: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case chat
            case helper
            case screenJob
            case guide
            case remembered
            case screen
            case meeting
            case phone
        }

        let id: UUID
        let date: Date
        let kind: Kind
        let text: String
    }

    static let screenJournalDefaultsKey = "brainScreenJournalEnabled"
    private static let profileModel = DottieModelPicker.normalModelName
    private static let maximumProfileLength = 3000
    /// New memories before the profile is brought up to date. Every voice
    /// exchange is a memory, so a low number rewrites the whole profile
    /// every few minutes of talking.
    private static let memoriesPerProfileUpdate = 30

    @Published private(set) var recentMemories: [Memory] = []
    @Published private(set) var profileText: String = ""
    @Published private(set) var folderPaths: [String] = []
    @Published private(set) var mcpServersJSON: String = ""
    @Published private(set) var isScreenJournalEnabled: Bool
    @Published private(set) var isUpdatingProfile = false

    /// Called when the profile changes, so the voice prompt picks it up.
    var onProfileChanged: ((String) -> Void)?

    let brainFolderURL: URL
    private var journalFileURL: URL { brainFolderURL.appendingPathComponent("journal.jsonl") }
    private var profileFileURL: URL { brainFolderURL.appendingPathComponent("profile.md") }
    private var foldersFileURL: URL { brainFolderURL.appendingPathComponent("folders.json") }
    nonisolated static var mcpFileURL: URL { defaultBrainFolderURL.appendingPathComponent("mcp.json") }

    private var memoriesSinceProfileUpdate = 0
    private var memoriesSinceJournalTrim = 0
    /// The journal keeps this many newest memories, like the episodic
    /// memory. Uncapped, every "do you remember…" read a file that only
    /// ever grew.
    private static let maximumJournalMemoryCount = 3_000

    nonisolated static var defaultBrainFolderURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupportDirectory
            .appendingPathComponent("Dottie", isDirectory: true)
            .appendingPathComponent("Brain", isDirectory: true)
    }

    init() {
        brainFolderURL = Self.defaultBrainFolderURL
        try? FileManager.default.createDirectory(at: brainFolderURL, withIntermediateDirectories: true)
        // Off until the user turns it on.
        isScreenJournalEnabled = UserDefaults.standard.bool(forKey: Self.screenJournalDefaultsKey)
        profileText = (try? String(contentsOf: profileFileURL, encoding: .utf8)) ?? ""
        loadBrainAnswers()
        folderPaths = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: foldersFileURL))) ?? []
        mcpServersJSON = (try? String(contentsOf: Self.mcpFileURL, encoding: .utf8)) ?? ""
        let journalMemories = loadJournal()
        recentMemories = Array(journalMemories.suffix(200))
        trimJournalIfNeeded(journalMemories)
    }

    // MARK: - The Brain's answers

    /// One question voice Dottie handed to the Brain agent, and its answer.
    struct BrainAnswer: Codable {
        let question: String
        let answer: String
        let date: Date
    }

    /// Answers the Brain already gave. Voice Dottie sees them in every
    /// session and the same question is answered from here, so a fact like
    /// the user's GitHub account is asked once, not on every message.
    private(set) var brainAnswers: [BrainAnswer] = []
    private var brainAnswersFileURL: URL { brainFolderURL.appendingPathComponent("brain-answers.json") }
    private static let maximumBrainAnswerCount = 20
    /// Answers older than this are asked again (files and repos change).
    private static let brainAnswerLifetime: TimeInterval = 14 * 86_400

    private func loadBrainAnswers() {
        let savedAnswers = (try? JSONDecoder().decode([BrainAnswer].self, from: Data(contentsOf: brainAnswersFileURL))) ?? []
        brainAnswers = savedAnswers.filter { Date().timeIntervalSince($0.date) < Self.brainAnswerLifetime }
    }

    func saveBrainAnswer(question: String, answer: String) {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return }
        let questionWords = Self.searchWords(in: question)
        // A newer answer to the same question replaces the old one.
        brainAnswers.removeAll { Self.isSameQuestion(Self.searchWords(in: $0.question), questionWords) }
        brainAnswers.append(BrainAnswer(question: String(question.prefix(300)), answer: String(trimmedAnswer.prefix(600)), date: Date()))
        if brainAnswers.count > Self.maximumBrainAnswerCount {
            brainAnswers.removeFirst(brainAnswers.count - Self.maximumBrainAnswerCount)
        }
        if let answersData = try? JSONEncoder().encode(brainAnswers) {
            DottieFileSaver.save(answersData, to: brainAnswersFileURL)
        }
        onProfileChanged?(profileText)
    }

    /// The saved answer to this question, when it was asked in the last
    /// few hours. Older ones stay in the voice prompt as facts, but a
    /// repeated question then gets a fresh look (open pull requests change).
    func savedBrainAnswer(for question: String) -> BrainAnswer? {
        let questionWords = Self.searchWords(in: question)
        return brainAnswers.last { savedAnswer in
            Date().timeIntervalSince(savedAnswer.date) < 6 * 3_600
                && Self.isSameQuestion(Self.searchWords(in: savedAnswer.question), questionWords)
        }
    }

    /// Most of the words of each question are in the other.
    private static func isSameQuestion(_ firstWords: Set<String>, _ secondWords: Set<String>) -> Bool {
        guard !firstWords.isEmpty, !secondWords.isEmpty else { return false }
        let sharedWordCount = Double(firstWords.intersection(secondWords).count)
        return sharedWordCount / Double(firstWords.count) >= 0.7 && sharedWordCount / Double(secondWords.count) >= 0.7
    }

    /// The newest answers, one short line each, for the voice prompt.
    var brainAnswersForPrompt: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMM"
        return brainAnswers.suffix(10).map { savedAnswer in
            let shortAnswer = savedAnswer.answer.replacingOccurrences(of: "\n", with: " ").prefix(220)
            return "- (\(dateFormatter.string(from: savedAnswer.date))) \(savedAnswer.question.prefix(120)) → \(shortAnswer)"
        }.joined(separator: "\n")
    }

    // MARK: - Remembering

    func record(_ kind: Memory.Kind, _ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let memory = Memory(id: UUID(), date: Date(), kind: kind, text: String(trimmedText.prefix(2000)))
        recentMemories.append(memory)
        if recentMemories.count > 200 {
            recentMemories.removeFirst(recentMemories.count - 200)
        }
        appendToJournal(memory)
        memoriesSinceJournalTrim += 1
        if memoriesSinceJournalTrim >= 100 {
            memoriesSinceJournalTrim = 0
            trimJournalIfNeeded(loadJournal())
        }

        memoriesSinceProfileUpdate += 1
        // Something the user asked to remember goes in right away.
        if kind == .remembered || memoriesSinceProfileUpdate >= Self.memoriesPerProfileUpdate {
            Task { await updateProfile() }
        }
    }

    /// The best matches for a question, newest first among equals, plus
    /// the profile. What recall_memory returns.
    func recall(_ query: String) -> String {
        let queryWords = Self.searchWords(in: query)
        let memories = loadJournal()
        // What happened, from the episodic memory, comes first.
        let episodicMemory = DottieEpisodicMemory.shared
        let episodesText = episodicMemory.episodes.isEmpty ? "" : episodicMemory.recallTextNow(query: query) + "\n\n"
        guard !memories.isEmpty else {
            return episodesText + (profileText.isEmpty ? "nothing else remembered yet." : "notes about the user:\n\(profileText)\n\nno other memories yet.")
        }
        let scored: [(memory: Memory, score: Int)] = memories.enumerated().compactMap { (index: Int, memory: Memory) -> (memory: Memory, score: Int)? in
            let memoryWords = Self.searchWords(in: memory.text)
            let overlap = queryWords.isEmpty ? 0 : queryWords.filter { memoryWords.contains($0) }.count
            guard queryWords.isEmpty || overlap > 0 else { return nil }
            // Ties go to the newer memory.
            return (memory: memory, score: overlap * 10_000 + index)
        }
        let bestMatches = scored.sorted { $0.score > $1.score }.prefix(15).map(\.memory)
            .sorted { $0.date > $1.date }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM, HH:mm"
        let lines = bestMatches.map { "[\(dateFormatter.string(from: $0.date)) · \($0.kind.rawValue)] \($0.text.prefix(400))" }
        var answer = episodesText + (lines.isEmpty ? "no journal lines match that." : "journal, newest first:\n" + lines.joined(separator: "\n"))
        if !profileText.isEmpty {
            answer += "\n\nnotes about the user:\n\(profileText)"
        }
        return answer
    }

    /// What the voice prompt carries every conversation.
    var profileForPrompt: String {
        String(profileText.prefix(Self.maximumProfileLength))
    }

    func saveProfile(_ newProfileText: String) {
        profileText = newProfileText.trimmingCharacters(in: .whitespacesAndNewlines)
        DottieFileSaver.save(text: profileText, to: profileFileURL)
        onProfileChanged?(profileText)
    }

    func forgetEverything() {
        try? FileManager.default.removeItem(at: journalFileURL)
        DottieEpisodicMemory.shared.forgetEverything()
        recentMemories = []
        memoriesSinceProfileUpdate = 0
        saveProfile("")
    }

    /// Rewrites the profile from the current one plus the newest memories.
    func updateProfile() async {
        guard !isUpdatingProfile else { return }
        isUpdatingProfile = true
        defer { isUpdatingProfile = false }
        let newMemories = recentMemories.suffix(max(memoriesSinceProfileUpdate, 1) + 5)
        memoriesSinceProfileUpdate = 0
        let memoryLines = newMemories.map { "[\($0.kind.rawValue)] \($0.text.prefix(600))" }.joined(separator: "\n")
        let instruction = """
        You keep a short note about one person for their desktop companion, Dottie. Update the note with anything new and lasting from the latest memories: their name, what they do, their projects and files, apps and tools they use, people they mention, preferences (how they like answers, likes and dislikes), and ongoing tasks or goals. Drop things that are finished or no longer true. Keep every fact the current note has unless a memory contradicts it. Never store passwords, keys, card or bank numbers, ID or passport numbers, codes or other secrets. Plain short bullet lines grouped under a few headings, under \(Self.maximumProfileLength - 500) characters. Reply with the note only.

        Current note:
        \(profileText.isEmpty ? "(empty)" : profileText)

        Latest memories:
        \(memoryLines)
        """
        let requestBody: [String: Any] = [
            "model": Self.profileModel,
            "contents": [["role": "user", "parts": [["text": instruction]]]]
        ]
        guard let updatedProfile = await Self.postToChat(requestBody)?.trimmingCharacters(in: .whitespacesAndNewlines),
              updatedProfile.count > 20 else { return }
        saveProfile(String(updatedProfile.prefix(Self.maximumProfileLength)))
    }

    // MARK: - Folders and MCP servers for the Brain agent

    func addFolder(_ folderURL: URL) {
        let folderPath = folderURL.standardizedFileURL.path
        guard !folderPaths.contains(folderPath) else { return }
        folderPaths.append(folderPath)
        saveFolders()
    }

    func removeFolder(_ folderPath: String) {
        folderPaths.removeAll { $0 == folderPath }
        saveFolders()
    }

    var folderURLs: [URL] {
        folderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Saves the MCP servers if the text is valid JSON. Returns an error to
    /// show, or nil.
    func saveMCPServersJSON(_ newJSON: String) -> String? {
        let trimmedJSON = newJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedJSON.isEmpty {
            guard let jsonData = trimmedJSON.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return "That isn't valid JSON."
            }
            let servers = (jsonObject["mcpServers"] as? [String: Any]) ?? jsonObject
            guard servers.values.allSatisfy({ $0 is [String: Any] }) else {
                return "Use {\"mcpServers\": {\"name\": {\"command\": \"…\", \"args\": […]}}}."
            }
        }
        mcpServersJSON = trimmedJSON
        DottieFileSaver.save(text: trimmedJSON, to: Self.mcpFileURL)
        // Claude helpers read their servers from Claude Code's own list, so
        // the Tools store copies these there too.
        DottieToolsStore.shared.scheduleHelperSync(delay: 1.5)
        return nil
    }

    /// The user's MCP servers, for Gemini CLI's settings. Read from disk so
    /// the runtime can call it from anywhere.
    nonisolated static func userMCPServers() -> [String: Any] {
        guard let jsonData = try? Data(contentsOf: mcpFileURL),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return [:] }
        let servers = (jsonObject["mcpServers"] as? [String: Any]) ?? jsonObject
        var serversWithoutSecretsInArguments: [String: Any] = [:]
        for (serverName, serverValue) in servers {
            guard var serverSettings = serverValue as? [String: Any] else { continue }
            // An mcp-remote header token moves from the command line (seen
            // by `ps`) into the server's environment.
            if let arguments = serverSettings["args"] as? [String] {
                let argumentsWithoutSecrets = DottieMCPStdioTransport.movingMCPRemoteHeaderValuesIntoEnvironment(
                    arguments: arguments,
                    environment: (serverSettings["env"] as? [String: String]) ?? [:]
                )
                serverSettings["args"] = argumentsWithoutSecrets.arguments
                if !argumentsWithoutSecrets.environment.isEmpty {
                    serverSettings["env"] = argumentsWithoutSecrets.environment
                }
            }
            serversWithoutSecretsInArguments[serverName] = serverSettings
        }
        return serversWithoutSecretsInArguments
    }

    private func saveFolders() {
        if let foldersData = try? JSONEncoder().encode(folderPaths) {
            DottieFileSaver.save(foldersData, to: foldersFileURL)
        }
    }

    // MARK: - Screen journal

    /// "Remember what's on my screen", kept by the episodic memory. The
    /// notch's green light follows this.
    func setScreenJournalEnabled(_ isEnabled: Bool) {
        isScreenJournalEnabled = isEnabled
        DottieEpisodicMemory.shared.screenMemory.setEnabled(isEnabled)
    }

    // MARK: - Storage

    private func appendToJournal(_ memory: Memory) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var lineData = try? encoder.encode(memory) else { return }
        lineData.append(UInt8(ascii: "\n"))
        if let fileHandle = try? FileHandle(forWritingTo: journalFileURL) {
            defer { try? fileHandle.close() }
            _ = try? fileHandle.seekToEnd()
            try? fileHandle.write(contentsOf: lineData)
        } else {
            DottieFileSaver.save(lineData, to: journalFileURL)
        }
    }

    /// Rewrites the journal with only its newest memories when it holds
    /// more than `maximumJournalMemoryCount`.
    private func trimJournalIfNeeded(_ journalMemories: [Memory]) {
        guard journalMemories.count > Self.maximumJournalMemoryCount else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var trimmedJournalData = Data()
        for memory in journalMemories.suffix(Self.maximumJournalMemoryCount) {
            guard let lineData = try? encoder.encode(memory) else { continue }
            trimmedJournalData.append(lineData)
            trimmedJournalData.append(UInt8(ascii: "\n"))
        }
        DottieFileSaver.save(trimmedJournalData, to: journalFileURL)
    }

    private func loadJournal() -> [Memory] {
        guard let journalData = try? Data(contentsOf: journalFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return journalData.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Memory.self, from: Data($0)) }
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "is", "it", "my", "me", "i", "you", "what",
        "did", "do", "was", "we", "that", "this", "with", "about", "when", "where", "how", "which", "who", "have",
        "has", "had", "be", "at", "from", "your", "our", "are", "were", "there", "then", "so", "can", "could"
    ]

    private static func searchWords(in text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0.count > 1 && !stopWords.contains($0) })
    }

    private static func postToChat(_ requestBody: [String: Any]) async -> String? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        request.httpBody = requestBodyData

        guard let (responseData, response) = await DottieLoggedRequest.send(request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // /chat streams server-sent events.
        let answerText = GeminiServerSentEvents.text(from: responseData)
        return answerText.isEmpty ? nil : answerText
    }
}
