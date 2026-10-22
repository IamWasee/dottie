//
//  DottieGameNotebook.swift
//  leanring-buddy
//
//  What Dottie has learned about one game, kept between sessions so she
//  gets better at it like a person does: the controls (learned from the
//  controls screen or by trying keys), facts ("E opens doors", "red barrels
//  explode"), guesses still to test, what killed her, lessons from watching
//  the user play, the game's genre, places she knows by sight, and a
//  guide to the game looked up on the web (DottieGameResearch).
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
        /// What the game is and how to play it, from the web.
        var guide: String?
        var guideWrittenAt: Date?
        /// When looking the game up last found nothing, so it isn't
        /// searched again at every start.
        var guideLookupFailedAt: Date?
        /// Which version of the controls routine last ran for this game
        /// (2: default controls first, then the right-click camera; 3: only
        /// counts once it actually learned something).
        var controlsRoutineVersion: Int?
    }

    static let currentControlsRoutineVersion = 3
    private static let secondsBeforeFailedLookupIsTriedAgain = 24.0 * 60 * 60

    /// True until the current controls routine has run for this game, so a
    /// game learned the old way (no shift, C or camera) is learned again.
    var needsControlsLearned: Bool {
        (contents.controlsRoutineVersion ?? 0) < Self.currentControlsRoutineVersion
    }

    /// Called only when trying the keys learned at least one control, so a
    /// run that saw nothing (the game wasn't focused, a menu was open) is
    /// tried again next time.
    func markControlsRoutineDone() {
        contents.controlsRoutineVersion = Self.currentControlsRoutineVersion
        contents.hasLearnedControls = true
        save()
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

    static var gamesFolderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dottie/Games", isDirectory: true)
    }

    // MARK: - Play log

    /// Appends a timestamped line to the game's play-log.txt, so what
    /// Dottie saw, decided and did can be read back after a session (her
    /// print() lines don't reach the Mac's own log). Kept under about 2 MB.
    static func appendToPlayLog(_ line: String, gameFolderURL: URL) {
        let logURL = gameFolderURL.appendingPathComponent("play-log.txt")
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let logLine = "\(timestampFormatter.string(from: Date()))  \(line.replacingOccurrences(of: "\n", with: " / "))\n"
        guard let logLineData = logLine.data(using: .utf8) else { return }
        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        if currentSize > 2_000_000 {
            let oldLogURL = gameFolderURL.appendingPathComponent("play-log-old.txt")
            try? FileManager.default.removeItem(at: oldLogURL)
            try? FileManager.default.moveItem(at: logURL, to: oldLogURL)
        }
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            logHandle.write(logLineData)
            try? logHandle.close()
        } else {
            try? logLineData.write(to: logURL)
        }
    }

    func log(_ line: String) {
        Self.appendToPlayLog(line, gameFolderURL: folderURL)
    }

    /// The names of every game with a notebook, so the same game is always
    /// named the same way.
    static func savedGameNames() -> [String] {
        struct SavedName: Decodable {
            let gameName: String
        }
        let gameFolderURLs = (try? FileManager.default.contentsOfDirectory(at: gamesFolderURL, includingPropertiesForKeys: nil)) ?? []
        return gameFolderURLs.compactMap { gameFolderURL in
            guard let notebookData = try? Data(contentsOf: gameFolderURL.appendingPathComponent("notebook.json")) else { return nil }
            return (try? JSONDecoder().decode(SavedName.self, from: notebookData))?.gameName
        }
    }

    /// The saved game whose notebook changed last among those whose name
    /// ends with this, like "(Roblox)", or nil.
    static func mostRecentlyPlayedGameName(endingWith nameEnding: String) -> String? {
        struct SavedName: Decodable {
            let gameName: String
        }
        let gameFolderURLs = (try? FileManager.default.contentsOfDirectory(at: gamesFolderURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var newestGame: (name: String, changedAt: Date)?
        for gameFolderURL in gameFolderURLs {
            let notebookURL = gameFolderURL.appendingPathComponent("notebook.json")
            guard let notebookData = try? Data(contentsOf: notebookURL),
                  let gameName = (try? JSONDecoder().decode(SavedName.self, from: notebookData))?.gameName,
                  gameName.lowercased().hasSuffix(nameEnding.lowercased()) else { continue }
            let changedAt = (try? notebookURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if changedAt > (newestGame?.changedAt ?? .distantPast) {
                newestGame = (gameName, changedAt)
            }
        }
        return newestGame?.name
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
        if let guide = contents.guide {
            sections.append("About this game (looked up online):\n" + guide)
        }
        if let genre = contents.genre {
            sections.append("Genre: \(genre). \(DottieGameGenres.starter(for: genre, gameName: contents.gameName))")
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

    /// True when the game has no guide yet, or it's old enough that the
    /// game may have changed.
    var needsGuide: Bool {
        if let guideLookupFailedAt = contents.guideLookupFailedAt,
           Date().timeIntervalSince(guideLookupFailedAt) < Self.secondsBeforeFailedLookupIsTriedAgain {
            return false
        }
        guard contents.guide != nil, let guideWrittenAt = contents.guideWrittenAt else { return true }
        return Date().timeIntervalSince(guideWrittenAt) > DottieGameResearch.secondsBeforeGuideIsLookedUpAgain
    }

    func setGuide(_ guide: String) {
        contents.guide = guide
        contents.guideWrittenAt = Date()
        contents.guideLookupFailedAt = nil
        save()
    }

    func noteGuideLookupFailed() {
        contents.guideLookupFailedAt = Date()
        save()
    }

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

    static func starter(for genre: String, gameName: String) -> String {
        // Roblox games share Roblox's own controls whatever their genre, so
        // a Roblox "sandbox" doesn't get Minecraft's.
        if gameName.lowercased().contains("roblox"), !genre.lowercased().contains("obby") {
            return "Roblox defaults: WASD to move, space to jump, hold right click and move the mouse to turn the camera, shift sprints in some games (or toggles shift-lock), C crouches in some, E or the key shown on screen to interact, and many actions are buttons on screen to click (shops, upgrades, menus). Escape opens Roblox's own menu. Follow the game's arrows, prompts and quest text."
        }
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
            return "Try the defaults: WASD to move, space to jump, shift to sprint, C to crouch, hold right click and move the mouse to turn the camera, E or F to interact, escape for the menu."
        }
    }
}
