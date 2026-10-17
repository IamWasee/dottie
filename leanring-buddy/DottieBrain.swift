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
    private static let profileModel = "gemini-3.6-flash"
    private static let screenJournalModel = "gemini-3.5-flash-lite"
    private static let screenJournalInterval: TimeInterval = 120
    private static let maximumProfileLength = 3000
    /// New memories before the profile is brought up to date.
    private static let memoriesPerProfileUpdate = 10

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
    private var screenJournalTimer: Timer?
    private var lastScreenJournalLine = ""

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
        folderPaths = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: foldersFileURL))) ?? []
        mcpServersJSON = (try? String(contentsOf: Self.mcpFileURL, encoding: .utf8)) ?? ""
        recentMemories = Array(loadJournal().suffix(200))
        updateScreenJournalTimer()
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
        guard !memories.isEmpty else {
            return profileText.isEmpty ? "nothing remembered yet." : "notes about the user:\n\(profileText)\n\nno other memories yet."
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
        var answer = lines.isEmpty ? "no memories match that." : "memories, newest first:\n" + lines.joined(separator: "\n")
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
        try? profileText.write(to: profileFileURL, atomically: true, encoding: .utf8)
        onProfileChanged?(profileText)
    }

    func forgetEverything() {
        try? FileManager.default.removeItem(at: journalFileURL)
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
        You keep a short note about one person for their desktop companion, Dottie. Update the note with anything new and lasting from the latest memories: their name, what they do, their projects and files, apps and tools they use, people they mention, preferences (how they like answers, likes and dislikes), and ongoing tasks or goals. Drop things that are finished or no longer true. Keep every fact the current note has unless a memory contradicts it. Never store passwords, keys, card numbers or other secrets. Plain short bullet lines grouped under a few headings, under \(Self.maximumProfileLength - 500) characters. Reply with the note only.

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
        try? trimmedJSON.write(to: Self.mcpFileURL, atomically: true, encoding: .utf8)
        return nil
    }

    /// The user's MCP servers, for Gemini CLI's settings. Read from disk so
    /// the runtime can call it from anywhere.
    nonisolated static func userMCPServers() -> [String: Any] {
        guard let jsonData = try? Data(contentsOf: mcpFileURL),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return [:] }
        let servers = (jsonObject["mcpServers"] as? [String: Any]) ?? jsonObject
        return servers.filter { $0.value is [String: Any] }
    }

    private func saveFolders() {
        if let foldersData = try? JSONEncoder().encode(folderPaths) {
            try? foldersData.write(to: foldersFileURL, options: .atomic)
        }
    }

    // MARK: - Screen journal

    func setScreenJournalEnabled(_ isEnabled: Bool) {
        isScreenJournalEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.screenJournalDefaultsKey)
        updateScreenJournalTimer()
    }

    private func updateScreenJournalTimer() {
        screenJournalTimer?.invalidate()
        screenJournalTimer = nil
        guard isScreenJournalEnabled else { return }
        screenJournalTimer = Timer.scheduledTimer(withTimeInterval: Self.screenJournalInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.writeScreenJournalLine() }
                }
            }
        }
    }

    /// One line about what the user is doing. The screenshot isn't kept.
    private func writeScreenJournalLine() async {
        // Only while they're at the Mac, and never on the lock screen.
        let secondsSinceInput = [CGEventType.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
        guard secondsSinceInput < Self.screenJournalInterval, CGPreflightScreenCaptureAccess() else { return }
        guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1024) else { return }
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let requestBody: [String: Any] = [
            "model": Self.screenJournalModel,
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": screen.jpegData.base64EncodedString()]],
                    ["text": "This is the user's screen; the frontmost app is \(frontmostApp). In one short line (under 20 words), say what they're doing: the app and the specific thing (file, project, page or topic). Never include passwords, codes, card numbers, or the contents of private messages or emails; say only who or what it's about. Reply with the line only."]
                ]
            ]]
        ]
        guard let journalLine = await Self.postToChat(requestBody)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " "),
              !journalLine.isEmpty,
              journalLine != lastScreenJournalLine else { return }
        lastScreenJournalLine = journalLine
        record(.screen, journalLine)
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
            try? lineData.write(to: journalFileURL, options: .atomic)
        }
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

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // /chat streams server-sent events.
        var answerText = ""
        for line in String(decoding: responseData, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
            guard let eventData = line.dropFirst(6).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let candidates = event["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            for part in parts where (part["thought"] as? Bool) != true {
                answerText += part["text"] as? String ?? ""
            }
        }
        return answerText.isEmpty ? nil : answerText
    }
}
