//
//  DottieEpisodicMemoryScreen.swift
//  leanring-buddy
//
//  "Remember what's on my screen" (off until the user turns it on). Every
//  few minutes, only while the user is at the Mac and only when the front
//  window really changed, Dottie notes the app, window title, web address
//  and a little of the window's text, read on this Mac with Apple's text
//  recognition. No screenshot is kept and no model is called per note.
//  Every half hour or so the notes are folded into a few episodes.
//
//  Never noted: password boxes, private or incognito browser windows, the
//  lock screen, and apps on the user's "never look" list (password
//  managers and messaging apps to start with).
//
//  Also here: reading which app, window and page are in front, for every
//  kind of episode.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import Vision

struct DottieScreenMoment: Codable {
    let date: Date
    let context: DottieScreenContext
    /// A little of the window's text, with long numbers hidden.
    let text: String
}

@MainActor
final class DottieScreenMemory: ObservableObject {
    static let excludedAppsDefaultsKey = "dottieScreenMemoryExcludedApps"
    static let defaultExcludedApps = [
        "1Password", "Bitwarden", "Dashlane", "LastPass", "KeePassXC", "Keychain Access", "Passwords",
        "Messages", "WhatsApp", "Signal"
    ]
    /// Shared with the brain's old screen journal switch, so a user who had
    /// it on keeps it on.
    static let enabledDefaultsKey = DottieBrain.screenJournalDefaultsKey

    private static let checkInterval: TimeInterval = 180
    /// Same window as last time: note it again only after this long.
    private static let sameWindowInterval: TimeInterval = 15 * 60
    private static let notesPerFold = 12
    private static let maximumNoteAge: TimeInterval = 40 * 60

    @Published private(set) var isEnabled: Bool
    @Published private(set) var excludedApps: [String]
    @Published private(set) var pendingMomentCount = 0

    weak var memory: DottieEpisodicMemory?

    private let momentsFileURL: URL
    private var pendingMoments: [DottieScreenMoment] = []
    private var lastMoment: DottieScreenMoment?
    private var timer: Timer?
    private var isChecking = false
    private var isFolding = false

    init(folderURL: URL) {
        momentsFileURL = folderURL.appendingPathComponent("moments.jsonl")
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        excludedApps = UserDefaults.standard.stringArray(forKey: Self.excludedAppsDefaultsKey) ?? Self.defaultExcludedApps
        pendingMoments = loadMoments()
        pendingMomentCount = pendingMoments.count
        lastMoment = pendingMoments.last
    }

    func start() {
        updateTimer()
    }

    func setEnabled(_ newValue: Bool) {
        isEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
        updateTimer()
        // Whatever was noted becomes episodes now.
        if !newValue { Task { await foldPendingMoments() } }
    }

    func addExcludedApp(_ appName: String) {
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !excludedApps.contains(where: { $0.caseInsensitiveCompare(trimmedName) == .orderedSame }) else { return }
        excludedApps.append(trimmedName)
        UserDefaults.standard.set(excludedApps, forKey: Self.excludedAppsDefaultsKey)
    }

    func removeExcludedApp(_ appName: String) {
        excludedApps.removeAll { $0 == appName }
        UserDefaults.standard.set(excludedApps, forKey: Self.excludedAppsDefaultsKey)
    }

    func forgetPendingMoments() {
        pendingMoments = []
        pendingMomentCount = 0
        lastMoment = nil
        try? FileManager.default.removeItem(at: momentsFileURL)
    }

    func isExcluded(appName: String?, bundleIdentifier: String?) -> Bool {
        let lowercasedBundleID = bundleIdentifier?.lowercased() ?? ""
        // Always: password managers and the lock screen, whatever the list says.
        let alwaysExcludedFragments = ["password", "keychain", "1password", "bitwarden", "lastpass", "keepass", "loginwindow", "screensaver"]
        if alwaysExcludedFragments.contains(where: { lowercasedBundleID.contains($0) }) { return true }
        if lowercasedBundleID == Bundle.main.bundleIdentifier?.lowercased() { return true }
        guard let appName else { return false }
        return excludedApps.contains { $0.caseInsensitiveCompare(appName) == .orderedSame }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.check() }
                }
            }
        }
    }

    // MARK: - Taking a note

    private func check() async {
        guard isEnabled, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if let moment = await takeNote() {
            pendingMoments.append(moment)
            pendingMomentCount = pendingMoments.count
            lastMoment = moment
            appendToMomentsFile(moment)
        }
        if let oldest = pendingMoments.first,
           pendingMoments.count >= Self.notesPerFold || Date().timeIntervalSince(oldest.date) > Self.maximumNoteAge {
            await foldPendingMoments()
        }
    }

    private func takeNote() async -> DottieScreenMoment? {
        // Only while they're at the Mac, and never on the lock screen.
        let secondsSinceInput = [CGEventType.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
        guard secondsSinceInput < Self.checkInterval, !Self.isScreenLocked, CGPreflightScreenCaptureAccess() else { return nil }

        guard let context = await DottieScreenContextReader.current(),
              !context.isPrivate,
              !isExcluded(appName: context.appName, bundleIdentifier: context.bundleIdentifier) else { return nil }

        // Same window and page as last time: nothing new yet.
        let signature = Self.signature(of: context)
        if let lastMoment, Self.signature(of: lastMoment.context) == signature,
           Date().timeIntervalSince(lastMoment.date) < Self.sameWindowInterval {
            return nil
        }

        let lines = await windowText(for: context)
        // A private window that doesn't say so in its title.
        let joinedLines = lines.joined(separator: " ").lowercased()
        if Self.privateWindowMarkers.contains(where: { joinedLines.contains($0) }) { return nil }
        let text = Self.cleanedSnippet(from: lines)

        if let lastMoment, Self.signature(of: lastMoment.context) == signature,
           Self.similarity(lastMoment.text, text) > 0.7 {
            return nil
        }
        return DottieScreenMoment(date: Date(), context: context, text: text)
    }

    /// Text in the front window, read on this Mac. The picture is dropped.
    private func windowText(for context: DottieScreenContext) async -> [String] {
        guard let screenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1600) else { return [] }
        var image = screenshot.image
        if let windowFrame = context.windowFrame, let cropped = Self.crop(image, to: windowFrame, displayFrame: screenshot.displayFrame) {
            image = cropped
        }
        return await Self.recognizeText(in: image)
    }

    private func foldPendingMoments() async {
        guard !isFolding, !pendingMoments.isEmpty, let memory else { return }
        isFolding = true
        defer { isFolding = false }
        let moments = pendingMoments
        await memory.foldScreenMoments(moments)
        // Notes taken while folding stay for next time.
        pendingMoments.removeFirst(min(moments.count, pendingMoments.count))
        pendingMomentCount = pendingMoments.count
        rewriteMomentsFile()
    }

    // MARK: - Privacy

    nonisolated static let privateWindowMarkers = ["private browsing", "incognito", "inprivate", "private window"]

    private static var isScreenLocked: Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (sessionInfo["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// Up to 400 characters, long numbers and secret-looking lines dropped.
    private static func cleanedSnippet(from lines: [String]) -> String {
        let secretWords = ["password", "passcode", "verification code", "security code", "cvv", "pin:", "one-time", "2fa", "api key", "secret"]
        var keptLines: [String] = []
        var length = 0
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.count >= 4, trimmedLine.filter(\.isLetter).count >= 3 else { continue }
            let lowercasedLine = trimmedLine.lowercased()
            guard !secretWords.contains(where: { lowercasedLine.contains($0) }) else { continue }
            let maskedLine = trimmedLine.replacingOccurrences(of: #"\d[\d \-]{5,}\d"#, with: "•••", options: .regularExpression)
            guard length + maskedLine.count <= 400 else { break }
            keptLines.append(maskedLine)
            length += maskedLine.count + 3
        }
        return keptLines.joined(separator: " · ")
    }

    private static func signature(of context: DottieScreenContext) -> String {
        let page = context.url.map { url in url.components(separatedBy: "?").first ?? url } ?? ""
        return "\(context.bundleIdentifier ?? context.appName ?? "")|\(context.windowTitle ?? "")|\(page)"
    }

    private static func similarity(_ first: String, _ second: String) -> Double {
        let firstWords = Set(first.lowercased().split { !$0.isLetter && !$0.isNumber })
        let secondWords = Set(second.lowercased().split { !$0.isLetter && !$0.isNumber })
        guard !firstWords.isEmpty || !secondWords.isEmpty else { return 1 }
        return Double(firstWords.intersection(secondWords).count) / Double(firstWords.union(secondWords).count)
    }

    // MARK: - Pictures and text

    /// The window's part of the display picture. The window frame is in
    /// Accessibility's top-left coordinates, the display in AppKit's.
    private static func crop(_ image: CGImage, to windowFrame: CGRect, displayFrame: CGRect) -> CGImage? {
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? displayFrame.maxY
        let displayTopInAccessibility = primaryDisplayHeight - displayFrame.maxY
        let scale = CGFloat(image.width) / max(displayFrame.width, 1)
        let cropRect = CGRect(
            x: (windowFrame.minX - displayFrame.minX) * scale,
            y: (windowFrame.minY - displayTopInAccessibility) * scale,
            width: windowFrame.width * scale,
            height: windowFrame.height * scale
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard cropRect.width > 50, cropRect.height > 50 else { return nil }
        return image.cropping(to: cropRect.integral)
    }

    nonisolated private static func recognizeText(in image: CGImage) async -> [String] {
        await Task.detached(priority: .utility) { () -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    // MARK: - Storage

    private func loadMoments() -> [DottieScreenMoment] {
        guard let fileData = try? Data(contentsOf: momentsFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return fileData.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(DottieScreenMoment.self, from: Data($0)) }
    }

    private func appendToMomentsFile(_ moment: DottieScreenMoment) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var lineData = try? encoder.encode(moment) else { return }
        lineData.append(UInt8(ascii: "\n"))
        if let fileHandle = try? FileHandle(forWritingTo: momentsFileURL) {
            defer { try? fileHandle.close() }
            _ = try? fileHandle.seekToEnd()
            try? fileHandle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: momentsFileURL, options: .atomic)
        }
    }

    private func rewriteMomentsFile() {
        guard !pendingMoments.isEmpty else {
            try? FileManager.default.removeItem(at: momentsFileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var fileData = Data()
        for moment in pendingMoments {
            guard let lineData = try? encoder.encode(moment) else { continue }
            fileData.append(lineData)
            fileData.append(UInt8(ascii: "\n"))
        }
        try? fileData.write(to: momentsFileURL, options: .atomic)
    }
}

// MARK: - What's in front

enum DottieScreenContextReader {
    /// The front app, its window title and frame, and the web address or
    /// document when there is one. Nil when Dottie herself is in front.
    @MainActor
    static func current() async -> DottieScreenContext? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let processIdentifier = frontmostApplication.processIdentifier
        let bundleIdentifier = frontmostApplication.bundleIdentifier
        let appName = frontmostApplication.localizedName
        let isBrowser = DottieBrowser.isBrowser(bundleIdentifier: bundleIdentifier)
        guard AXIsProcessTrusted() else {
            return DottieScreenContext(appName: appName, bundleIdentifier: bundleIdentifier)
        }
        let details = await Task.detached(priority: .utility) {
            readAccessibilityDetails(processIdentifier: processIdentifier, looksForWebAddress: isBrowser)
        }.value
        let lowercasedTitle = details.windowTitle?.lowercased() ?? ""
        let isPrivateWindow = isBrowser && DottieScreenMemory.privateWindowMarkers.contains { lowercasedTitle.contains($0) }
        return DottieScreenContext(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: details.windowTitle,
            url: details.webAddress ?? details.documentPath,
            isPrivate: isPrivateWindow || details.isTypingSecret,
            windowFrame: details.windowFrame
        )
    }

    private struct AccessibilityDetails {
        var windowTitle: String?
        var windowFrame: CGRect?
        var webAddress: String?
        var documentPath: String?
        var isTypingSecret = false
    }

    nonisolated private static func readAccessibilityDetails(processIdentifier: pid_t, looksForWebAddress: Bool) -> AccessibilityDetails {
        var details = AccessibilityDetails()
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.4)

        // A password box in focus means nothing on screen is noted.
        let focusedElement = element(applicationElement, kAXFocusedUIElementAttribute)
        if let focusedElement, string(focusedElement, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            details.isTypingSecret = true
        }

        guard let window = element(applicationElement, kAXFocusedWindowAttribute) else { return details }
        details.windowTitle = string(window, kAXTitleAttribute).map { String($0.prefix(200)) }
        details.windowFrame = frame(of: window)
        if let document = string(window, kAXDocumentAttribute), !document.isEmpty {
            if document.hasPrefix("http") {
                details.webAddress = document
            } else if let fileURL = URL(string: document), fileURL.isFileURL {
                details.documentPath = (fileURL.path as NSString).abbreviatingWithTildeInPath
            }
        }
        guard looksForWebAddress, details.webAddress == nil else { return details }

        // The page's web area: up from the focused element first (quick),
        // then a short walk through the window's controls.
        var ancestor = focusedElement
        for _ in 0..<40 {
            guard let current = ancestor else { break }
            if string(current, kAXRoleAttribute) == "AXWebArea", let address = webAddress(of: current) {
                details.webAddress = address
                return details
            }
            ancestor = element(current, kAXParentAttribute)
        }
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visitedCount = 0
        var addressBarText: String?
        while !queue.isEmpty, visitedCount < 500 {
            let (current, depth) = queue.removeFirst()
            visitedCount += 1
            let role = string(current, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let address = webAddress(of: current) {
                    details.webAddress = address
                    return details
                }
                continue
            }
            if role == "AXTextField", addressBarText == nil, let value = string(current, kAXValueAttribute),
               !value.contains(" "), value.contains("."), value.count < 400 {
                addressBarText = value
            }
            guard depth < 14 else { continue }
            for child in children(of: current) {
                queue.append((child, depth + 1))
            }
        }
        details.webAddress = addressBarText
        return details
    }

    nonisolated private static func webAddress(of webArea: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &value) == .success, let value else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            return (value as! URL).absoluteString
        }
        return value as? String
    }

    nonisolated private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    nonisolated private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
