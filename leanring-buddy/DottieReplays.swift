//
//  DottieReplays.swift
//  leanring-buddy
//
//  Instant replays: a screen job that worked is saved with every step it
//  took, so the next time the user asks for the same thing in the same app
//  or site, Dottie does it again straight away, without asking Gemini.
//
//  Each click is saved with several ways to find its target again, best
//  first:
//    1. Accessibility: the element's role, title, description and
//       identifier, and the roles on the way down from its window.
//    2. The visible text on or next to it, found again with Apple's
//       on-device text recognition (ScreenTextFinder).
//    3. A tiny picture of the spot, compared with what's there now.
//  The raw coordinate is never used on its own: a step whose target can't
//  be found is handed to the normal Gemini loop from that step on
//  (DottieReplayPlayer).
//
//  Saved in ~/Library/Application Support/Dottie/Replays, one JSON file per
//  replay.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import Vision

// MARK: - What's saved

struct DottieReplay: Codable, Identifiable, Equatable {
    struct Target: Codable, Equatable {
        var role: String?
        var subrole: String?
        var title: String?
        var descriptionText: String?
        var identifier: String?
        /// Roles from the window down to the element.
        var rolePath: [String] = []
        /// Where it sat in its window, 0-1 from the window's top-left.
        var relativeX: Double?
        var relativeY: Double?
        var windowTitle: String?
        /// Text read on or right next to it, and where the click was from
        /// that text's middle, in points.
        var nearbyText: String?
        var textOffsetX: Double?
        var textOffsetY: Double?
        /// The model's own name for it ("Search box").
        var label: String?
        /// Global AppKit point of the click, for the record.
        var pointX: Double
        var pointY: Double
        /// 16x16 grayscale picture of the 48-point square around the click.
        var patch: [UInt8]?

        var hasAccessibilityName: Bool {
            [title, descriptionText, identifier].contains { !($0 ?? "").isEmpty }
        }
    }

    struct Step: Codable, Equatable {
        /// open_app, open_url, click, type_text, press_keys, scroll, wait,
        /// wait_for_video_end.
        var action: String
        var arguments: [String: String]
        var target: Target?

        var summary: String {
            let detail = arguments["name"] ?? arguments["url"] ?? arguments["text"].map { "\"\($0.prefix(40))\"" }
                ?? arguments["keys"] ?? arguments["direction"] ?? target?.label ?? target?.title ?? target?.nearbyText ?? ""
            return detail.isEmpty ? action : "\(action) \(detail)"
        }
    }

    var id: UUID
    var name: String
    var taskText: String
    var appBundleIdentifier: String?
    var appName: String?
    var siteHost: String?
    /// Starts by opening an app or page, so it works from anywhere.
    var startsOnItsOwn: Bool
    var steps: [Step]
    var answer: String
    /// The job reads something off the screen, so the answer has to be
    /// read fresh each time (one Gemini look at the end).
    var needsFreshAnswer: Bool
    var finalWindowTitle: String?
    var createdAt: Date
    var lastUsedAt: Date
    var useCount: Int
    var lastReplaySeconds: Double?

    var whereText: String {
        siteHost ?? appName ?? "any app"
    }
}

// MARK: - The store

@MainActor
final class DottieReplayStore: ObservableObject {
    static let shared = DottieReplayStore()

    @Published private(set) var replays: [DottieReplay] = []
    private static let maximumReplays = 60
    private let folderURL: URL

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = applicationSupportURL.appendingPathComponent("Dottie/Replays", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        load()
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func load() {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        replays = fileURLs.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(DottieReplay.self, from: Data(contentsOf: $0)) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private func fileURL(for replay: DottieReplay) -> URL {
        folderURL.appendingPathComponent("\(replay.id.uuidString).json")
    }

    private func write(_ replay: DottieReplay) {
        guard let data = try? Self.encoder.encode(replay) else { return }
        try? data.write(to: fileURL(for: replay), options: .atomic)
    }

    /// Saves a job that worked, replacing an older replay of the same job.
    func save(_ replay: DottieReplay) {
        var newReplay = replay
        if let existingIndex = replays.firstIndex(where: { $0.id == replay.id || Self.isSameReplay($0, replay) }) {
            let existing = replays[existingIndex]
            newReplay.id = existing.id
            newReplay.createdAt = existing.createdAt
            newReplay.useCount = max(existing.useCount, replay.useCount)
            replays.remove(at: existingIndex)
        }
        replays.insert(newReplay, at: 0)
        write(newReplay)
        while replays.count > Self.maximumReplays, let oldest = replays.min(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            forget(oldest.id)
        }
        print("⚡ Saved replay \"\(newReplay.name)\" (\(newReplay.steps.count) steps)")
    }

    func noteUsed(_ replayID: UUID, seconds: Double) {
        guard let index = replays.firstIndex(where: { $0.id == replayID }) else { return }
        replays[index].useCount += 1
        replays[index].lastUsedAt = Date()
        replays[index].lastReplaySeconds = seconds
        write(replays[index])
    }

    func forget(_ replayID: UUID) {
        guard let index = replays.firstIndex(where: { $0.id == replayID }) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: replays[index]))
        replays.remove(at: index)
    }

    func forgetAll() {
        for replay in replays { try? FileManager.default.removeItem(at: fileURL(for: replay)) }
        replays.removeAll()
    }

    func replay(withID replayID: UUID) -> DottieReplay? {
        replays.first { $0.id == replayID }
    }

    /// A replay by (part of) its name or wording, for the voice tool.
    func replay(named name: String) -> DottieReplay? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let exact = replays.first(where: { $0.name.lowercased() == wanted || $0.taskText.lowercased() == wanted }) { return exact }
        if let contained = replays.first(where: { $0.name.lowercased().contains(wanted) || $0.taskText.lowercased().contains(wanted) }) { return contained }
        return replays
            .map { ($0, Self.wordOverlap(wanted, $0.taskText)) }
            .filter { $0.1 >= 0.6 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func isSameReplay(_ first: DottieReplay, _ second: DottieReplay) -> Bool {
        first.appBundleIdentifier == second.appBundleIdentifier && first.siteHost == second.siteHost
            && normalizedWords(first.taskText) == normalizedWords(second.taskText)
    }

    // MARK: - Matching a new job

    /// Words that don't change what a job does.
    private static let fillerWords: Set<String> = [
        "the", "and", "please", "can", "you", "could", "would", "for", "with", "into", "from", "that", "this",
        "dottie", "hey", "now", "just", "again", "for me", "want", "need", "let", "lets", "let's", "then",
        "me", "my", "a", "an", "to", "in", "on", "of", "it", "go", "do", "get", "some", "quickly"
    ]

    /// Like CompanionManager's isSameJob: words longer than two letters,
    /// and every number.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 || $0.contains(where: \.isNumber) })
    }

    private static func normalizedWords(_ text: String) -> Set<String> {
        words(text).subtracting(fillerWords)
    }

    /// The share of the shorter wording's words found in both.
    static func wordOverlap(_ firstText: String, _ secondText: String) -> Double {
        let firstWords = words(firstText), secondWords = words(secondText)
        guard !firstWords.isEmpty, !secondWords.isEmpty else { return 0 }
        return Double(firstWords.intersection(secondWords).count) / Double(min(firstWords.count, secondWords.count))
    }

    /// The saved replay for a new request, if one fits: nearly the same
    /// words (as for repeated jobs), and no differing word that the steps
    /// depend on ("search cats" never replays "search dogs"), in the same
    /// app or site unless the replay opens its own.
    func bestMatch(for taskText: String, context: DottieReplayContext) -> DottieReplay? {
        let candidates = replays.compactMap { replay -> (DottieReplay, Double)? in
            let overlap = Self.wordOverlap(taskText, replay.taskText)
            guard overlap >= 0.75, Self.differingWordsAreHarmless(taskText, replay) else { return nil }
            if !replay.startsOnItsOwn {
                guard replay.appBundleIdentifier == context.appBundleIdentifier else { return nil }
                if let siteHost = replay.siteHost, siteHost != context.siteHost { return nil }
            }
            return (replay, overlap)
        }
        return candidates.max { first, second in
            first.1 == second.1 ? first.0.lastUsedAt < second.0.lastUsedAt : first.1 < second.1
        }?.0
    }

    private static func differingWordsAreHarmless(_ taskText: String, _ replay: DottieReplay) -> Bool {
        let newWords = normalizedWords(taskText), oldWords = normalizedWords(replay.taskText)
        let differingWords = newWords.symmetricDifference(oldWords)
        guard !differingWords.isEmpty else { return true }
        if differingWords.contains(where: { $0.contains(where: \.isNumber) }) { return false }
        // A word the user changed that also shows up in what was typed or
        // clicked means the steps would do the old thing.
        let stepWords = replay.steps.reduce(into: Set<String>()) { result, step in
            for value in step.arguments.values { result.formUnion(words(value)) }
            for value in [step.target?.title, step.target?.descriptionText, step.target?.nearbyText, step.target?.label] {
                result.formUnion(words(value ?? ""))
            }
        }
        if !differingWords.isDisjoint(with: stepWords) { return false }
        // Up to two harmless words may differ ("open" vs "show").
        return differingWords.count <= 2
    }

    /// Jobs that read something off the screen ("what's my rank") need a
    /// fresh answer each time.
    static func needsFreshAnswer(task taskText: String, answer: String) -> Bool {
        let lowercasedTask = " " + taskText.lowercased() + " "
        let questionMarkers = [
            "?", " what", " how many", " how much", " tell me", " check", " find out", " read", " rank", " who ",
            " when ", " where ", " which", " is there", " are there", " did ", " does ", " do i ", " price", " weather",
            " score", " status", " summar", " count", " list ", " show me", " look up", " latest", " new "
        ]
        if questionMarkers.contains(where: { lowercasedTask.contains($0) }) { return true }
        // A number in the answer that the user didn't say is a reading.
        let answerNumbers = words(answer).filter { $0.contains(where: \.isNumber) }
        return !answerNumbers.isSubset(of: words(taskText))
    }
}

// MARK: - Where a job runs

struct DottieReplayContext {
    let appBundleIdentifier: String?
    let appName: String?
    let siteHost: String?
    let windowTitle: String?

    /// The frontmost app (not Dottie), its window title, and the site when
    /// it's a browser.
    @MainActor
    static func current() -> DottieReplayContext {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let applicationElement = frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
        let window = applicationElement.flatMap { DottieAX.element($0, kAXFocusedWindowAttribute) }
        let isBrowser = DottieBrowser.isBrowser(bundleIdentifier: frontmostApplication?.bundleIdentifier)
        return DottieReplayContext(
            appBundleIdentifier: frontmostApplication?.bundleIdentifier,
            appName: frontmostApplication?.localizedName,
            siteHost: isBrowser ? window.flatMap(DottieAX.siteHost(inWindow:)) : nil,
            windowTitle: window.flatMap { DottieAX.string($0, kAXTitleAttribute) }
        )
    }
}

// MARK: - Accessibility helpers

@MainActor
enum DottieAX {
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    /// Frame in Accessibility space (top-left origin).
    static func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static var primaryDisplayHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func axPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    static func appKitPoint(fromAX point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    static func focusedWindow() -> AXUIElement? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return element(applicationElement, kAXFocusedWindowAttribute)
    }

    static func enclosingWindow(of startElement: AXUIElement) -> AXUIElement? {
        var currentElement: AXUIElement? = startElement
        for _ in 0..<60 {
            guard let checkedElement = currentElement else { return nil }
            if string(checkedElement, kAXRoleAttribute) == kAXWindowRole as String { return checkedElement }
            currentElement = element(checkedElement, kAXParentAttribute)
        }
        return nil
    }

    /// The page's host in a browser window, from its web area's address.
    static func siteHost(inWindow window: AXUIElement) -> String? {
        if let document = string(window, kAXDocumentAttribute), let host = URL(string: document)?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        var elementsToVisit = [window]
        var visitedCount = 0
        while !elementsToVisit.isEmpty, visitedCount < 400 {
            let element = elementsToVisit.removeFirst()
            visitedCount += 1
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                if let address = string(element, "AXURL"), let host = URL(string: address)?.host {
                    return host.replacingOccurrences(of: "www.", with: "")
                }
                continue
            }
            elementsToVisit.append(contentsOf: children(element))
        }
        return nil
    }

    /// Roles worth clicking, so a click on a button's label saves the button.
    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTab", "AXRow", "AXCell", "AXDisclosureTriangle",
        "AXMenuButton", "AXSlider", "AXIncrementor", "AXSegmentedControl", "AXImage", "AXStaticText"
    ]

    static let strongClickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTab", "AXMenuButton", "AXRow"
    ]
}

// MARK: - Saving a target

@MainActor
enum DottieReplayTargets {
    /// Everything that helps find the thing at `point` again. Taken just
    /// before the click, from the screenshot the model looked at.
    static func capture(at point: CGPoint, label: String?, screen: DottieDisplayCapture.Screenshot) async -> DottieReplay.Target {
        var target = DottieReplay.Target(label: label, pointX: Double(point.x), pointY: Double(point.y))
        let axPoint = DottieAX.axPoint(fromAppKit: point)
        var hitElement: AXUIElement?
        if AXIsProcessTrusted(),
           AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &hitElement) == .success,
           let hitElement {
            // A label or icon inside a button: save the button.
            var element = hitElement
            var candidate: AXUIElement? = hitElement
            for _ in 0..<4 {
                guard let current = candidate else { break }
                if let role = DottieAX.string(current, kAXRoleAttribute), DottieAX.strongClickableRoles.contains(role) {
                    element = current
                    break
                }
                candidate = DottieAX.element(current, kAXParentAttribute)
            }
            target.role = DottieAX.string(element, kAXRoleAttribute)
            target.subrole = DottieAX.string(element, kAXSubroleAttribute)
            target.title = DottieAX.string(element, kAXTitleAttribute).map { String($0.prefix(120)) }
            target.descriptionText = (DottieAX.string(element, kAXDescriptionAttribute) ?? DottieAX.string(element, "AXLabel")).map { String($0.prefix(120)) }
            target.identifier = DottieAX.string(element, kAXIdentifierAttribute)
            if target.title == nil, target.role == "AXStaticText" || target.role == "AXButton" || target.role == "AXLink" {
                target.title = DottieAX.string(element, kAXValueAttribute).map { String($0.prefix(120)) }
            }
            var rolePath: [String] = []
            var ancestor: AXUIElement? = element
            var window: AXUIElement?
            for _ in 0..<40 {
                guard let current = ancestor else { break }
                let role = DottieAX.string(current, kAXRoleAttribute) ?? "?"
                rolePath.insert(role, at: 0)
                if role == kAXWindowRole as String {
                    window = current
                    break
                }
                ancestor = DottieAX.element(current, kAXParentAttribute)
            }
            target.rolePath = rolePath
            if let window, let windowFrame = DottieAX.axFrame(window), windowFrame.width > 0, windowFrame.height > 0 {
                target.relativeX = Double((axPoint.x - windowFrame.minX) / windowFrame.width)
                target.relativeY = Double((axPoint.y - windowFrame.minY) / windowFrame.height)
                target.windowTitle = DottieAX.string(window, kAXTitleAttribute)
            }
        }
        if target.relativeX == nil, let window = DottieAX.focusedWindow(), let windowFrame = DottieAX.axFrame(window), windowFrame.contains(axPoint) {
            target.relativeX = Double((axPoint.x - windowFrame.minX) / windowFrame.width)
            target.relativeY = Double((axPoint.y - windowFrame.minY) / windowFrame.height)
            target.windowTitle = DottieAX.string(window, kAXTitleAttribute)
        }
        target.patch = DottieReplayPictures.patch(around: point, in: screen.image, displayFrame: screen.displayFrame)
        // Text on the thing, for when Accessibility can't find it again.
        if let nearby = await DottieReplayPictures.textNearest(point, in: screen.image, displayFrame: screen.displayFrame) {
            target.nearbyText = nearby.text
            target.textOffsetX = Double(point.x - nearby.center.x)
            target.textOffsetY = Double(point.y - nearby.center.y)
        }
        return target
    }
}

// MARK: - Pictures and on-screen text

@MainActor
enum DottieReplayPictures {
    static let patchSide = 16
    static let patchPoints: CGFloat = 48

    /// A tiny grayscale picture of the square around a point.
    static func patch(around point: CGPoint, in image: CGImage, displayFrame: CGRect) -> [UInt8]? {
        let pixelsPerPoint = CGFloat(image.width) / displayFrame.width
        let cropRect = CGRect(
            x: (point.x - displayFrame.minX - patchPoints / 2) * pixelsPerPoint,
            y: (displayFrame.maxY - point.y - patchPoints / 2) * pixelsPerPoint,
            width: patchPoints * pixelsPerPoint,
            height: patchPoints * pixelsPerPoint
        ).integral
        guard cropRect.minX >= 0, cropRect.minY >= 0, cropRect.maxX <= CGFloat(image.width), cropRect.maxY <= CGFloat(image.height),
              let cropped = image.cropping(to: cropRect) else { return nil }
        var pixels = [UInt8](repeating: 0, count: patchSide * patchSide)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: patchSide, height: patchSide, bitsPerComponent: 8, bytesPerRow: patchSide,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: patchSide, height: patchSide))
            return true
        }
        return didDraw ? pixels : nil
    }

    /// True when two patches show nearly the same thing.
    static func patchesMatch(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        guard first.count == second.count, !first.isEmpty else { return false }
        let averageDifference = zip(first, second).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(first.count)
        return averageDifference < 14
    }

    /// The text line on or nearest to a point (within a few points), read
    /// from a small area around it.
    static func textNearest(_ point: CGPoint, in image: CGImage, displayFrame: CGRect) async -> (text: String, center: CGPoint)? {
        let areaSize = CGSize(width: 320, height: 90)
        let area = CGRect(x: point.x - areaSize.width / 2, y: point.y - areaSize.height / 2, width: areaSize.width, height: areaSize.height)
            .intersection(displayFrame)
        guard !area.isNull, area.width > 20, area.height > 20 else { return nil }
        let pixelsPerPoint = CGFloat(image.width) / displayFrame.width
        let cropRect = CGRect(
            x: (area.minX - displayFrame.minX) * pixelsPerPoint,
            y: (displayFrame.maxY - area.maxY) * pixelsPerPoint,
            width: area.width * pixelsPerPoint,
            height: area.height * pixelsPerPoint
        ).integral
        guard let cropped = image.cropping(to: cropRect) else { return nil }
        let lines = await Task.detached(priority: .userInitiated) { () -> [(String, CGRect)] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
            }
        }.value
        var best: (text: String, center: CGPoint, distance: CGFloat)?
        for (text, box) in lines {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed.count <= 60 else { continue }
            let frame = CGRect(
                x: area.minX + box.minX * area.width, y: area.minY + box.minY * area.height,
                width: box.width * area.width, height: box.height * area.height
            )
            let distance = frame.insetBy(dx: -4, dy: -4).contains(point) ? 0 : hypot(frame.midX - point.x, frame.midY - point.y)
            guard distance <= 40 else { continue }
            if best == nil || distance < best!.distance {
                best = (trimmed, CGPoint(x: frame.midX, y: frame.midY), distance)
            }
        }
        return best.map { ($0.text, $0.center) }
    }
}
