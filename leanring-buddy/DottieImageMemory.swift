//
//  DottieImageMemory.swift
//  leanring-buddy
//
//  Pictures the user adds in Home → Conversation ("this is the golden
//  sword in my game"). Each one is saved with a short name and a
//  description of how it looks. Voice Dottie gets the list in every later
//  session, and screen jobs and pointing get the picture itself, so "go
//  grab that sword" finds the thing in the picture on screen.
//

import AppKit
import Combine
import Foundation

@MainActor
final class DottieImageMemory: ObservableObject {
    struct Item: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var description: String
        let fileName: String
        let createdAt: Date
        /// Dottie saved it herself from the screen (save_picture).
        var savedByDottie: Bool?
    }

    @Published private(set) var items: [Item] = []

    /// Older pictures are forgotten past this.
    private static let maximumItems = 200
    /// Big enough to show detail, small enough to send along every step.
    private static let maximumImageDimension: CGFloat = 1024
    private static let describingModel = "gemini-3.5-flash-lite"

    let folderURL: URL
    private var indexURL: URL { folderURL.appendingPathComponent("index.json") }

    init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = applicationSupportURL.appendingPathComponent("Dottie/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Adding

    /// Saves the picture, asks Gemini for a name and description (using the
    /// user's own words for it when they gave some), and returns the item.
    func add(imageData: Data, userText: String) async -> Item? {
        guard let jpegData = Self.downscaledJPEG(from: imageData) else { return nil }
        let itemID = UUID()
        let fileName = "\(itemID.uuidString).jpg"
        do {
            try jpegData.write(to: folderURL.appendingPathComponent(fileName), options: .atomic)
        } catch {
            print("⚠️ Couldn't save picture: \(error.localizedDescription)")
            return nil
        }

        let described = await describe(jpegData: jpegData, userText: userText)
        let fallbackName = "picture \(items.count + 1)"
        let item = Item(
            id: itemID,
            name: uniqueName(described?.name ?? fallbackName),
            description: described?.description ?? "",
            fileName: fileName,
            createdAt: Date()
        )
        items.append(item)
        trimToMaximum()
        saveIndex()
        return item
    }

    private func trimToMaximum() {
        while items.count > Self.maximumItems {
            let oldestItem = items.removeFirst()
            try? FileManager.default.removeItem(at: fileURL(for: oldestItem))
        }
    }

    /// Saves a picture with a name and description already known (one
    /// Dottie took of the screen, or one added in Home → Pictures with its
    /// own words). No Gemini call.
    func add(imageData: Data, name: String, description: String, savedByDottie: Bool) -> Item? {
        guard let jpegData = Self.downscaledJPEG(from: imageData) else { return nil }
        let itemID = UUID()
        let fileName = "\(itemID.uuidString).jpg"
        do {
            try jpegData.write(to: folderURL.appendingPathComponent(fileName), options: .atomic)
        } catch {
            print("⚠️ Couldn't save picture: \(error.localizedDescription)")
            return nil
        }
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let item = Item(
            id: itemID,
            name: uniqueName(trimmedName.isEmpty ? "picture \(items.count + 1)" : trimmedName),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            fileName: fileName,
            createdAt: Date(),
            savedByDottie: savedByDottie
        )
        items.append(item)
        trimToMaximum()
        saveIndex()
        return item
    }

    func updateDescription(_ item: Item, to newDescription: String) {
        guard let itemIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[itemIndex].description = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        saveIndex()
    }

    func rename(_ item: Item, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let itemIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[itemIndex].name = trimmedName
        saveIndex()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: fileURL(for: item))
        saveIndex()
    }

    // MARK: - Finding

    func fileURL(for item: Item) -> URL {
        folderURL.appendingPathComponent(item.fileName)
    }

    func jpegData(for item: Item) -> Data? {
        try? Data(contentsOf: fileURL(for: item))
    }

    /// Saved pictures named by `names` (as voice Dottie passes them), best
    /// match first. An exact name wins; otherwise every word of the name
    /// must appear in the request.
    func items(matching names: [String]) -> [Item] {
        var matchedItems: [Item] = []
        for name in names {
            let wantedName = Self.normalized(name)
            guard !wantedName.isEmpty else { continue }
            let match = items.last(where: { Self.normalized($0.name) == wantedName })
                ?? items.last(where: { item in
                    let itemWords = Self.normalized(item.name).split(separator: " ")
                    return !itemWords.isEmpty && itemWords.allSatisfy { " \(wantedName) ".contains(" \($0) ") }
                })
            if let match, !matchedItems.contains(match) {
                matchedItems.append(match)
            }
        }
        return matchedItems
    }

    /// Pictures whose name is mentioned in a request ("go pick up the
    /// guardian core"), so a job gets them even when voice Dottie didn't
    /// pass them.
    func items(mentionedIn text: String) -> [Item] {
        let requestText = " \(Self.normalized(text)) "
        let mentionedItems = items.filter { item in
            let itemName = Self.normalized(item.name)
            return !itemName.isEmpty && requestText.contains(" \(itemName) ")
        }
        return Array(mentionedItems.suffix(4))
    }

    /// find_pictures: pictures sharing words with the query in their name
    /// or description (where they're from, what they look like).
    func search(_ query: String) -> [Item] {
        let queryWords: Set<String> = Set(Self.normalized(query).split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !queryWords.isEmpty else { return Array(items.suffix(10).reversed()) }
        var scoredItems: [(item: Item, score: Int)] = []
        for item in items {
            let itemText = Self.normalized(item.name + " " + item.description)
            let itemWords: Set<String> = Set(itemText.split(separator: " ").map(String.init))
            let score = itemWords.intersection(queryWords).count
            if score > 0 { scoredItems.append((item, score)) }
        }
        scoredItems.sort { first, second in
            if first.score != second.score { return first.score > second.score }
            return first.item.createdAt > second.item.createdAt
        }
        return scoredItems.prefix(10).map { $0.item }
    }

    /// One line per picture, newest first, for voice Dottie's prompt.
    var promptSummary: String {
        items.suffix(40).reversed().map { item in
            "- \(item.name)" + (item.description.isEmpty ? "" : ": \(item.description)")
        }.joined(separator: "\n")
    }

    // MARK: - Private

    private struct Description: Decodable {
        let name: String
        let description: String
    }

    private func describe(jpegData: Data, userText: String) async -> (name: String, description: String)? {
        let prompt = """
        The user shared this picture with their assistant\(userText.isEmpty ? "" : " and said: \"\(userText)\""). Name the main thing in it so they can refer to it later.
        Reply only with JSON: {"name": "1-4 words; use the user's own name for it if they gave one, like \\"golden sword\\"", "description": "one sentence on how it looks (shape, colors, any text or icon) so it can be spotted on a screen"}
        """
        let requestBody: [String: Any] = [
            "model": Self.describingModel,
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": ["responseMimeType": "application/json", "maxOutputTokens": 512]
        ]
        guard let answerText = await DottieChat.send(requestBody, timeout: 30),
              let jsonStart = answerText.firstIndex(of: "{"),
              let jsonEnd = answerText.lastIndex(of: "}"),
              let described = try? JSONDecoder().decode(Description.self, from: Data(answerText[jsonStart...jsonEnd].utf8)) else {
            return nil
        }
        let name = described.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return (String(name.prefix(40)), described.description.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "golden sword", then "golden sword 2" for a second one.
    private func uniqueName(_ name: String) -> String {
        let existingNames = Set(items.map { Self.normalized($0.name) })
        guard existingNames.contains(Self.normalized(name)) else { return name }
        var number = 2
        while existingNames.contains(Self.normalized("\(name) \(number)")) { number += 1 }
        return "\(name) \(number)"
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func downscaledJPEG(from imageData: Data) -> Data? {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maximumImageDimension / CGFloat(max(cgImage.width, cgImage.height)))
        let width = max(1, Int(CGFloat(cgImage.width) * scale))
        let height = max(1, Int(CGFloat(cgImage.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // Transparent pictures (game item icons often are) go on white.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaledImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaledImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private func loadIndex() {
        guard let indexData = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([Item].self, from: indexData)) ?? []
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let indexData = try? encoder.encode(items) else { return }
        try? indexData.write(to: indexURL, options: .atomic)
    }
}
