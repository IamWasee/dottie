//
//  DottieKnownPlaces.swift
//  leanring-buddy
//
//  Where things are on this Mac, learned as they're opened, so "open my
//  resume" or "open the coffee site folder" is instant the second time.
//  Whenever a document or a Finder folder comes to the front (opened by
//  the user, by Dottie, by a screen job, anything), its path is noted with
//  its name. When an "open …" ask wasn't recognized and something opens
//  within a minute, the user's own words are kept as another name for it.
//  The instant lane (DottieInstantCommands.parseOpen) opens a known place
//  by name with no AI, and Needle (DottieNeedleRouter) finds one by meaning
//  when the words differ. Kept on the Mac only, in KnownPlaces.json.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class DottieKnownPlaces {
    static let shared = DottieKnownPlaces()

    struct Place: Codable, Equatable {
        var path: String
        var isFolder: Bool
        /// Lowercased names it's asked for by: its file name without the
        /// extension, plus the words the user used for it.
        var spokenNames: [String]
        var lastOpenedAt: Date
        var timesOpened: Int

        var displayName: String { (path as NSString).lastPathComponent }
    }

    private(set) var places: [Place] = []
    private let storeURL: URL
    private static let maximumPlaceCount = 2000

    /// The last "open …" words the strict lane didn't know, waiting for
    /// whatever opens next.
    private var unrecognizedOpenRequest: (spokenTarget: String, askedAt: Date)?
    private static let secondsToLinkWordsToWhatOpened: TimeInterval = 60

    private var appActivationObserver: NSObjectProtocol?
    private var frontWindowCheckTimer: Timer?
    private var lastSeenFrontPath: String?

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        storeURL = applicationSupportURL.appendingPathComponent("Dottie/KnownPlaces.json")
        if let storedData = try? Data(contentsOf: storeURL),
           let storedPlaces = try? JSONDecoder().decode([Place].self, from: storedData) {
            // Older saves could hold one folder twice ("//" in the path) and
            // code-like names; merge and drop those once.
            var cleanedPlaces: [Place] = []
            for var storedPlace in storedPlaces {
                storedPlace.path = Self.standardizedPath(storedPlace.path)
                storedPlace.spokenNames.removeAll { Self.looksLikeMachineName($0) }
                if let existingIndex = cleanedPlaces.firstIndex(where: { $0.path == storedPlace.path }) {
                    for name in storedPlace.spokenNames where !cleanedPlaces[existingIndex].spokenNames.contains(name) {
                        cleanedPlaces[existingIndex].spokenNames.append(name)
                    }
                    cleanedPlaces[existingIndex].timesOpened += storedPlace.timesOpened
                    cleanedPlaces[existingIndex].lastOpenedAt = max(cleanedPlaces[existingIndex].lastOpenedAt, storedPlace.lastOpenedAt)
                } else {
                    cleanedPlaces.append(storedPlace)
                }
            }
            places = cleanedPlaces
        }
    }

    // MARK: - Watching what opens

    func start() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // The window it brings up needs a moment to be in front.
                try? await Task.sleep(nanoseconds: 700_000_000)
                DottieKnownPlaces.shared.noteFrontWindow()
            }
        }
        // A new document or folder in the same app doesn't activate
        // anything, so the front window is looked at every few seconds
        // too: one Accessibility read, no screenshot.
        frontWindowCheckTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in DottieKnownPlaces.shared.noteFrontWindow() }
        }
    }

    private func noteFrontWindow() {
        guard AXIsProcessTrusted(),
              let frontApplication = NSWorkspace.shared.frontmostApplication,
              frontApplication.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        var frontPath: String?
        if frontApplication.bundleIdentifier == "com.apple.finder" {
            frontPath = Self.frontFinderFolderPath(processIdentifier: frontApplication.processIdentifier)
        } else {
            frontPath = Self.focusedDocumentPath(processIdentifier: frontApplication.processIdentifier)
        }
        guard let frontPath, frontPath != lastSeenFrontPath else { return }
        lastSeenFrontPath = frontPath
        remember(path: frontPath)
    }

    /// The file behind the app's front window (AXDocument), if it shows one.
    private static func focusedDocumentPath(processIdentifier: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindow = DottieAccessibilityCast.element(focusedWindowValue) else { return nil }
        var documentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXDocumentAttribute as CFString, &documentValue) == .success,
              let documentAddress = documentValue as? String,
              let documentURL = URL(string: documentAddress), documentURL.isFileURL else { return nil }
        return documentURL.path
    }

    /// Finder windows don't carry AXDocument, so the folder is found from
    /// the window's title among the user's usual folders and the recent
    /// places, without asking Finder through AppleScript (which would pop
    /// an automation prompt on its own).
    private static func frontFinderFolderPath(processIdentifier: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindow = DottieAccessibilityCast.element(focusedWindowValue) else { return nil }
        var documentValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedWindow, kAXDocumentAttribute as CFString, &documentValue) == .success,
           let documentAddress = documentValue as? String, let documentURL = URL(string: documentAddress), documentURL.isFileURL {
            return documentURL.path
        }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
              let windowTitle = titleValue as? String, !windowTitle.isEmpty else { return nil }
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let searchFolders = ["", "Desktop", "Documents", "Downloads", "Documents/Dottie Code"]
            .map { homeURL.appendingPathComponent($0) }
        for searchFolder in searchFolders {
            let candidateURL = searchFolder.lastPathComponent == windowTitle ? searchFolder : searchFolder.appendingPathComponent(windowTitle)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidateURL.path
            }
        }
        return nil
    }

    // MARK: - Remembering

    func remember(path rawPath: String, spokenName: String? = nil) {
        // "/Users/me//Downloads" and "/Users/me/Downloads" are one place.
        let path = Self.standardizedPath(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        let baseName = Self.spokenForm(((path as NSString).lastPathComponent as NSString).deletingPathExtension)

        // A download named like "57000a64-7d85-…" has no name anyone says.
        var namesToAdd = Self.looksLikeMachineName(baseName) ? [] : [baseName]
        if let spokenName { namesToAdd.append(Self.spokenForm(spokenName)) }
        if let unrecognizedOpenRequest,
           Date().timeIntervalSince(unrecognizedOpenRequest.askedAt) < Self.secondsToLinkWordsToWhatOpened {
            // "open my resume" wasn't known; this is what opened next.
            namesToAdd.append(unrecognizedOpenRequest.spokenTarget)
            self.unrecognizedOpenRequest = nil
        }
        namesToAdd = namesToAdd.filter { !$0.isEmpty }

        if let existingIndex = places.firstIndex(where: { $0.path == path }) {
            for name in namesToAdd where !places[existingIndex].spokenNames.contains(name) {
                places[existingIndex].spokenNames.append(name)
            }
            places[existingIndex].lastOpenedAt = Date()
            places[existingIndex].timesOpened += 1
        } else {
            places.append(Place(path: path, isFolder: isDirectory.boolValue, spokenNames: Array(Set(namesToAdd)), lastOpenedAt: Date(), timesOpened: 1))
            if places.count > Self.maximumPlaceCount {
                places.sort { $0.lastOpenedAt > $1.lastOpenedAt }
                places.removeLast(places.count - Self.maximumPlaceCount)
            }
        }
        save()
    }

    /// The strict lane didn't know these "open …" words.
    func noteUnrecognizedOpenRequest(spokenTarget: String) {
        unrecognizedOpenRequest = (Self.spokenForm(spokenTarget), Date())
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Mostly hex digits or numbers (UUIDs, hashes, "IMG 20251103 0412").
    static func looksLikeMachineName(_ spokenName: String) -> Bool {
        let letters = spokenName.filter { !$0.isWhitespace }
        guard letters.count >= 6 else { return false }
        let hexOrDigitCount = letters.filter { $0.isHexDigit }.count
        let digitCount = letters.filter { $0.isNumber }.count
        return Double(hexOrDigitCount) / Double(letters.count) > 0.8 && digitCount >= 3
    }

    func forget(path: String) {
        places.removeAll { $0.path == path }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let encodedPlaces = try? JSONEncoder().encode(places) {
            try? encodedPlaces.write(to: storeURL, options: .atomic)
        }
    }

    // MARK: - Finding

    /// The place these words name: one of its names exactly, else every
    /// word of a name (at least two) in the words. Places that are gone
    /// from disk are dropped.
    func place(matchingSpokenName spokenTarget: String) -> Place? {
        let wantedName = Self.spokenForm(spokenTarget)
        guard !wantedName.isEmpty else { return nil }
        let placesByRecency = places.sorted { $0.lastOpenedAt > $1.lastOpenedAt }

        var matchedPlace = placesByRecency.first { $0.spokenNames.contains(wantedName) }
        if matchedPlace == nil {
            let wantedWords = Set(wantedName.split(separator: " ").map(String.init))
            matchedPlace = placesByRecency.first { place in
                place.spokenNames.contains { name in
                    let nameWords = Set(name.split(separator: " ").map(String.init))
                    return nameWords.count >= 2 && nameWords.isSubset(of: wantedWords)
                }
            }
        }
        guard let matchedPlace else { return nil }
        guard FileManager.default.fileExists(atPath: matchedPlace.path) else {
            forget(path: matchedPlace.path)
            return nil
        }
        return matchedPlace
    }

    /// The most recent places, for Needle's matching by meaning.
    func recentPlaces(limit: Int) -> [Place] {
        Array(places.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(limit))
    }

    /// "Resume_2025-final" → "resume 2025 final", "my Resume" → "resume".
    static func spokenForm(_ text: String) -> String {
        let spacedText = text.lowercased()
            .replacingOccurrences(of: #"[_\-.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: "", options: .regularExpression)
        let withoutLeadingWords = spacedText
            .replacingOccurrences(of: #"^(?:(?:the|my|a|an|up|that|this)\s+)+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:file|folder|document|doc)$"#, with: "", options: .regularExpression)
        return withoutLeadingWords.split(separator: " ").joined(separator: " ")
    }
}
