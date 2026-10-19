//
//  ConversationStore.swift
//  leanring-buddy
//
//  Keeps the companion's conversation so the Home window can show it and it
//  survives relaunches. Shipped Clicky keeps a conversation transcript on
//  Home; this is the clone's equivalent, stored as a small JSON file in
//  Application Support.
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

    func append(userText: String, clickyText: String, inputKind: ConversationEntry.InputKind, imageFileNames: [String] = []) {
        let trimmedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClickyText = clickyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserText.isEmpty || !trimmedClickyText.isEmpty else { return }

        entries.append(ConversationEntry(
            id: UUID(),
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
