//
//  DottieGameNotebook.swift
//  leanring-buddy
//
//  What Dottie has learned about one game, kept between sessions so she
//  gets better at it like a person does: the controls (learned from the
//  controls screen or by trying keys), facts ("E opens doors", "red barrels
//  explode"), guesses still to test, what killed her, lessons from watching
//  the user play, the game's genre, and places she knows by sight.
//
//  Places are remembered as a small picture plus directions in landmarks
//  ("past the fountain, left at the red house") instead of coordinates, and
//  recognized again by comparing pictures on the Mac (Vision feature
//  prints), so she knows when she's back somewhere.
//
//  Saved in ~/Library/Application Support/Dottie/Games/<game>/.
//

import Foundation
import ImageIO
import Vision

@MainActor
final class DottieGameNotebook {
    struct Place: Codable {
        var name: String
        var directions: String
        var pictureFileName: String
        var notedAt: Date
    }

    struct Contents: Codable {
        var gameName: String
        var genre: String?
        /// Key or button → what it does in this game.
        var controls: [String: String] = [:]
        var hasLearnedControls = false
        var facts: [String] = []
        var guessesToTest: [String] = []
        var deaths: [String] = []
        var lessonsFromWatching: [String] = []
        var places: [Place] = []
        var sessionCount = 0
    }

    private(set) var contents: Contents
    let folderURL: URL
    private var placePrints: [String: VNFeaturePrintObservation] = [:]

    private static let maximumFacts = 40
    private static let maximumGuesses = 15
    private static let maximumDeaths = 15
    private static let maximumLessons = 20
    private static let maximumPlaces = 40

    init(gameName: String) {
        let gamesFolderURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dottie/Games", isDirectory: true)
        folderURL = gamesFolderURL.appendingPathComponent(Self.folderName(for: gameName), isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL.appendingPathComponent("places"), withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let savedData = try? Data(contentsOf: folderURL.appendingPathComponent("notebook.json")),
           let savedContents = try? decoder.decode(Contents.self, from: savedData) {
            contents = savedContents
        } else {
            contents = Contents(gameName: gameName)
        }
        contents.sessionCount += 1
        save()
    }

    /// "Roblox — Obby Tower" → "roblox-obby-tower".
    static func folderName(for gameName: String) -> String {
        let slug = gameName.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? "game" : String(slug.prefix(60))
    }

    // MARK: - For the brain

    /// The notebook as short text, read at the start of every brain call.
    func promptText() -> String {
        var sections: [String] = []
        if let genre = contents.genre {
            sections.append("Genre: \(genre). \(DottieGameGenres.starter(for: genre))")
        }
        if !contents.controls.isEmpty {
            let controlLines = contents.controls.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            sections.append("Controls: " + controlLines.joined(separator: "; "))
        }
        if !contents.facts.isEmpty {
            sections.append("What you know:\n- " + contents.facts.suffix(25).joined(separator: "\n- "))
        }
        if !contents.guessesToTest.isEmpty {
            sections.append("Guesses to test:\n- " + contents.guessesToTest.suffix(8).joined(separator: "\n- "))
        }
        if !contents.deaths.isEmpty {
            sections.append("What killed you before:\n- " + contents.deaths.suffix(6).joined(separator: "\n- "))
        }
        if !contents.lessonsFromWatching.isEmpty {
            sections.append("From watching the user play:\n- " + contents.lessonsFromWatching.suffix(8).joined(separator: "\n- "))
        }
        if !contents.places.isEmpty {
            let placeLines = contents.places.suffix(15).map { "\($0.name): \($0.directions)" }
            sections.append("Places you know (directions by landmarks):\n- " + placeLines.joined(separator: "\n- "))
        }
        return sections.isEmpty ? "Your notebook for this game is empty: this is your first time playing it." : sections.joined(separator: "\n\n")
    }

    // MARK: - Learning

    func setGenre(_ genre: String) {
        let trimmedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedGenre.isEmpty, contents.genre != trimmedGenre else { return }
        contents.genre = trimmedGenre
        save()
    }

    func learnControls(_ controls: [String: String], isComplete: Bool) {
        for (keyName, meaning) in controls {
            let trimmedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMeaning.isEmpty else { continue }
            contents.controls[keyName.lowercased()] = String(trimmedMeaning.prefix(80))
        }
        if isComplete || contents.controls.count >= 5 {
            contents.hasLearnedControls = true
        }
        save()
    }

    func add(facts: [String], guesses: [String], testedGuesses: [String], death: String?) {
        contents.facts = Self.appendingNew(facts, to: contents.facts, limit: Self.maximumFacts)
        contents.guessesToTest = Self.appendingNew(guesses, to: contents.guessesToTest, limit: Self.maximumGuesses)
        let testedSet = Set(testedGuesses.map { $0.lowercased() })
        contents.guessesToTest.removeAll { testedSet.contains($0.lowercased()) }
        if let death {
            contents.deaths = Self.appendingNew([death], to: contents.deaths, limit: Self.maximumDeaths)
        }
        save()
    }

    func addLessonsFromWatching(_ lessons: [String]) {
        contents.lessonsFromWatching = Self.appendingNew(lessons, to: contents.lessonsFromWatching, limit: Self.maximumLessons)
        save()
    }

    private static func appendingNew(_ newItems: [String], to existingItems: [String], limit: Int) -> [String] {
        var combinedItems = existingItems
        let existingLowercased = Set(existingItems.map { $0.lowercased() })
        for newItem in newItems {
            let trimmedItem = String(newItem.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !trimmedItem.isEmpty, !existingLowercased.contains(trimmedItem.lowercased()) else { continue }
            combinedItems.append(trimmedItem)
        }
        return Array(combinedItems.suffix(limit))
    }

    // MARK: - Places

    /// Remembers where the player is now, by a picture of the view and
    /// directions in landmarks.
    func notePlace(name: String, directions: String, view: CGImage) {
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmedName.isEmpty,
              let jpegData = DottieGameVision.jpegData(of: view, quality: 0.6) else { return }
        let pictureFileName = DottieGameNotebook.folderName(for: trimmedName) + ".jpg"
        try? jpegData.write(to: folderURL.appendingPathComponent("places").appendingPathComponent(pictureFileName))
        contents.places.removeAll { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
        contents.places.append(Place(name: trimmedName, directions: String(directions.prefix(300)), pictureFileName: pictureFileName, notedAt: Date()))
        if contents.places.count > Self.maximumPlaces {
            contents.places.removeFirst(contents.places.count - Self.maximumPlaces)
        }
        placePrints[trimmedName] = Self.featurePrint(of: view)
        save()
    }

    /// The known place this view looks like, if any.
    func recognizePlace(in view: CGImage) -> Place? {
        guard !contents.places.isEmpty, let viewPrint = Self.featurePrint(of: view) else { return nil }
        var bestMatch: (place: Place, distance: Float)?
        for place in contents.places {
            if placePrints[place.name] == nil,
               let placeImage = loadPlacePicture(place) {
                placePrints[place.name] = Self.featurePrint(of: placeImage)
            }
            guard let placePrint = placePrints[place.name] else { continue }
            var distance: Float = 0
            guard (try? viewPrint.computeDistance(&distance, to: placePrint)) != nil else { continue }
            if distance < (bestMatch?.distance ?? .greatestFiniteMagnitude) {
                bestMatch = (place, distance)
            }
        }
        // Feature-print distances under about 0.5 are the same scene seen
        // again; above that they're just similar-looking.
        guard let bestMatch, bestMatch.distance < 0.5 else { return nil }
        return bestMatch.place
    }

    private func loadPlacePicture(_ place: Place) -> CGImage? {
        let pictureURL = folderURL.appendingPathComponent("places").appendingPathComponent(place.pictureFileName)
        guard let imageSource = CGImageSourceCreateWithURL(pictureURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    private static func featurePrint(of image: CGImage) -> VNFeaturePrintObservation? {
        let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        try? requestHandler.perform([featurePrintRequest])
        return featurePrintRequest.results?.first
    }

    // MARK: - Saving

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let contentsData = try? encoder.encode(contents) else { return }
        try? contentsData.write(to: folderURL.appendingPathComponent("notebook.json"), options: .atomic)
    }
}

// MARK: - Game types

/// Usual controls and tactics per kind of game, so a new game doesn't
/// start from nothing.
enum DottieGameGenres {
    static let knownGenres = ["shooter", "rpg", "platformer", "roblox obby", "racing", "puzzle", "strategy", "sandbox"]

    static func starter(for genre: String) -> String {
        switch genre.lowercased() {
        case let name where name.contains("obby"):
            return "Usual: WASD to move, space to jump (hold for longer jumps on some), right-drag turns the camera, shift may sprint. Line up jumps by looking straight at the next platform, start the jump near the edge, and keep holding forward through the air. Falling sends you back to the last checkpoint."
        case let name where name.contains("shooter"):
            return "Usual: WASD to move, mouse aims, left click shoots, right click aims down sights, R reloads, shift sprints, ctrl crouches, space jumps, 1-4 switch weapons. Use cover, reload when safe, check corners."
        case let name where name.contains("rpg"):
            return "Usual: WASD or click to move, E or F to interact and talk, I or tab for inventory, M for the map, J for quests, 1-9 for skills. Talk to people with markers over them, follow the quest marker, heal before fights."
        case let name where name.contains("platformer"):
            return "Usual: arrows or A/D to move, space or W to jump, shift to dash. Watch the timing of moving hazards, jump from the edge, and look for the path upward or to the right."
        case let name where name.contains("racing"):
            return "Usual: W or up to accelerate, S or down to brake, A/D to steer, space handbrake. Brake before corners, not in them; follow the racing line."
        case let name where name.contains("puzzle"):
            return "Look over the whole board before moving, try the simplest move that changes something, and undo when stuck."
        case let name where name.contains("strategy"):
            return "Usual: left click selects, right click moves or attacks, drag to box-select, number keys for groups. Build economy first, scout, then attack."
        case let name where name.contains("sandbox"):
            return "Usual: WASD to move, space to jump, left click to break or use, right click to place, E for inventory. Gather basics first, build shelter before night."
        default:
            return "Try WASD or the arrow keys to move, space to jump, E or F to interact, escape for the menu."
        }
    }
}
