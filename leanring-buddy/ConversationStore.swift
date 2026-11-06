//
//  ConversationStore.swift
//  leanring-buddy
//
//  Keeps the companion's conversation so the Home window can show it and it
//  survives relaunches, stored as a small JSON file in Application
//  Support.
//

import Combine
import Foundation

struct ConversationEntry: Codable, Identifiable, Equatable {
    enum InputKind: String, Codable {
        case voice
        case typed
    }

    let id: UUID
    let createdAt: Date
    let inputKind: InputKind
    let userText: String
    let clickyText: String
    /// Pictures the user added with this message, in image memory's folder.
    var imageFileNames: [String]?
}

@MainActor
final class ConversationStore: ObservableObject {
    private static let maximumStoredEntries = 200

    @Published private(set) var entries: [ConversationEntry] = []

    private let storageFileURL: URL

    init() {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let clickyDirectory = applicationSupportDirectory.appendingPathComponent("Dottie", isDirectory: true)
        try? FileManager.default.createDirectory(at: clickyDirectory, withIntermediateDirectories: true)
        self.storageFileURL = clickyDirectory.appendingPathComponent("conversation.json")
        loadEntriesFromDisk()
    }

    /// Returns the new entry's id, so a later part of the same answer can be
    /// added to it even after other exchanges were logged.
    @discardableResult
    func append(userText: String, clickyText: String, inputKind: ConversationEntry.InputKind, imageFileNames: [String] = []) -> UUID? {
        let trimmedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClickyText = clickyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserText.isEmpty || !trimmedClickyText.isEmpty else { return nil }

        let newEntryID = UUID()
        entries.append(ConversationEntry(
            id: newEntryID,
            createdAt: Date(),
            inputKind: inputKind,
            userText: trimmedUserText,
            clickyText: trimmedClickyText,
            imageFileNames: imageFileNames.isEmpty ? nil : imageFileNames
        ))
        if entries.count > Self.maximumStoredEntries {
            entries.removeFirst(entries.count - Self.maximumStoredEntries)
        }
        saveEntriesToDisk()
        // Becomes episodes once the conversation goes quiet.
        DottieEpisodicMemory.shared.noteExchange(userText: trimmedUserText, dottieText: trimmedClickyText)
        return newEntryID
    }

    /// Adds more of Dottie's answer to the newest exchange: after a tool
    /// call, Live keeps answering the same question in a new model turn.
    /// `entryID` names the exchange the answer belongs to; without it (or when
    /// it's gone) the newest exchange is extended. An instant command logged
    /// while Live was still answering must not get that late answer.
    func extendEntry(withID entryID: UUID?, clickyText: String) {
        let trimmedClickyText = clickyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClickyText.isEmpty, !entries.isEmpty else { return }
        let entryIndex = entryID.flatMap { wantedEntryID in entries.lastIndex(where: { $0.id == wantedEntryID }) } ?? (entries.count - 1)
        let entryToExtend = entries[entryIndex]
        let combinedClickyText = [entryToExtend.clickyText, trimmedClickyText].filter { !$0.isEmpty }.joined(separator: " ")
        entries[entryIndex] = ConversationEntry(
            id: entryToExtend.id,
            createdAt: entryToExtend.createdAt,
            inputKind: entryToExtend.inputKind,
            userText: entryToExtend.userText,
            clickyText: combinedClickyText,
            imageFileNames: entryToExtend.imageFileNames
        )
        saveEntriesToDisk()
    }

    func delete(entryID: UUID) {
        entries.removeAll { $0.id == entryID }
        saveEntriesToDisk()
    }

    func clearAll() {
        entries.removeAll()
        saveEntriesToDisk()
    }

    private func loadEntriesFromDisk() {
        guard let storedData = try? Data(contentsOf: storageFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([ConversationEntry].self, from: storedData)) ?? []
    }

    private func saveEntriesToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encodedData = try? encoder.encode(entries) else { return }
        try? encodedData.write(to: storageFileURL, options: .atomic)
    }
}
