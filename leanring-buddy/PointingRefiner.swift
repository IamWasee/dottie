//
//  PointingRefiner.swift
//  leanring-buddy
//
//  Gemini Live points from a small, downscaled frame of every screen, so its
//  guess is often near the right spot but not on it (a little to the left of
//  "Sign in"), and for tiny toolbar icons sometimes somewhere else entirely.
//  Before the cursor flies, the guess gets a second look:
//
//    1. Accessibility: search the window under the guess (and the frontmost
//       window) for an element whose name matches the label Live gave, like
//       "Sign in" or "Downloads", and use its exact frame. Instant and exact
//       for native apps, browser toolbars, and web pages that expose their
//       accessibility tree.
//    2. Vision: otherwise, a fresh, sharper screenshot of that display goes
//       to Gemini Flash, which is trained to return bounding boxes, with the
//       label and Live's guess as a hint.
//
//  If neither finds it, the cursor goes to Live's guess as before.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum PointingRefiner {
    /// The whole second look must finish within this, or Live's guess is used.
    static let refinementTimeoutSeconds: TimeInterval = 5
    /// Fast enough to answer within the timeout (about 2.5s); the default
    /// chat model often took 8s, so the cursor fell back to Live's guess.
    static let visionModel = "gemini-3.6-flash"

    /// Chromium and Electron apps only build their web content's
    /// accessibility tree when asked, and the first ask can take a moment,
    /// so this is called as soon as a turn starts.
    static func prepareFrontmostApplicationForSearch() {
        guard AXIsProcessTrusted(), let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Returns a better global AppKit point (bottom-left origin) for the
    /// element, or nil to keep the rough one.
    static func refine(
        elementLabel: String?,
        userQuestion: String,
        roughPoint: CGPoint,
        displayFrame: CGRect
    ) async -> CGPoint? {
        let elementFrame = await refineFrame(
            elementLabel: elementLabel,
            userQuestion: userQuestion,
            roughPoint: roughPoint,
            displayFrame: displayFrame
        )
        return elementFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// The element's whole frame in global AppKit coordinates, for marks
    /// that should hug it (a circle around it, a box), or nil if it
    /// couldn't be found.
    static func refineFrame(
        elementLabel: String?,
        userQuestion: String,
        roughPoint: CGPoint,
        displayFrame: CGRect
    ) async -> CGRect? {
        let labelWords = significantWords(in: elementLabel ?? "")

        if !labelWords.isEmpty, let accessibilityFrame = AccessibilityElementSearch.bestMatch(
            forLabelWords: labelWords,
            near: roughPoint
        ) {
            print("🎯 Pointing refined by Accessibility: \(Int(roughPoint.x)),\(Int(roughPoint.y)) → \(Int(accessibilityFrame.midX)),\(Int(accessibilityFrame.midY))")
            return accessibilityFrame
        }

        guard let elementLabel, !elementLabel.isEmpty else { return nil }
        let visionFrame = await withTimeout(seconds: refinementTimeoutSeconds) {
            await VisionElementLocator.locate(
                elementLabel: elementLabel,
                userQuestion: userQuestion,
                roughPoint: roughPoint,
                displayFrame: displayFrame
            )
        }
        if let visionFrame {
            print("🎯 Pointing refined by vision: \(Int(roughPoint.x)),\(Int(roughPoint.y)) → \(Int(visionFrame.midX)),\(Int(visionFrame.midY))")
        }
        return visionFrame
    }

    /// Lowercased words that name the thing, without filler like "the" or
    /// "button" that every element would match.
    static func significantWords(in label: String) -> [String] {
        let genericWords: Set<String> = [
            "the", "a", "an", "of", "in", "on", "to", "for", "and", "your", "my", "this", "that",
            "button", "icon", "link", "tab", "menu", "item", "field", "bar", "box", "area", "text",
            "label", "option", "toggle", "checkbox", "control", "element", "section", "panel",
            // How people describe browser things that aren't in their names:
            // "the pinterest bookmark" is a tile named "pinterest.com".
            "bookmark", "bookmarks", "tile", "shortcut", "thumbnail", "website", "site", "card", "logo",
            "com", "www", "org", "net", "io", "https", "http"
        ]
        return label.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !genericWords.contains($0) }
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let firstResult = await group.next() ?? nil
            group.cancelAll()
            return firstResult
        }
    }
}

// MARK: - Accessibility

@MainActor
private enum AccessibilityElementSearch {
    private static let maximumVisitedElements = 3000
    private static let searchTimeBudgetSeconds: TimeInterval = 0.25
    /// Elements bigger than this are containers, not the thing to point at.
    private static let maximumElementSize = CGSize(width: 700, height: 250)

    private struct Candidate {
        let frame: CGRect
        let score: Double
    }

    /// The best-matching element's frame in global AppKit coordinates.
    static func bestMatch(forLabelWords labelWords: [String], near roughPoint: CGPoint) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let roughPointInAXSpace = axPoint(fromAppKit: roughPoint)

        var windowsToSearch: [AXUIElement] = []
        let systemWideElement = AXUIElementCreateSystemWide()
        var elementAtRoughPoint: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWideElement, Float(roughPointInAXSpace.x), Float(roughPointInAXSpace.y), &elementAtRoughPoint) == .success,
           let elementAtRoughPoint,
           let window = enclosingWindow(of: elementAtRoughPoint) {
            windowsToSearch.append(window)
        }
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
            // Chromium and Electron apps only build their web content's
            // accessibility tree when asked to.
            AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, of: applicationElement),
               !windowsToSearch.contains(where: { CFEqual($0, focusedWindow) }) {
                windowsToSearch.append(focusedWindow)
            }
        }

        let searchDeadline = Date().addingTimeInterval(searchTimeBudgetSeconds)
        var bestCandidate: Candidate?
        var visitedElementCount = 0

        for window in windowsToSearch {
            var elementsToVisit: [AXUIElement] = [window]
            while let element = elementsToVisit.popLast() {
                visitedElementCount += 1
                if visitedElementCount > maximumVisitedElements || Date() > searchDeadline { break }

                if let candidate = scoreElement(element, labelWords: labelWords, roughPointInAXSpace: roughPointInAXSpace),
                   candidate.score > (bestCandidate?.score ?? 0) {
                    bestCandidate = candidate
                }
                elementsToVisit.append(contentsOf: children(of: element))
            }
        }

        guard let bestCandidate else { return nil }
        let axFrame = bestCandidate.frame
        let bottomLeft = appKitPoint(fromAX: CGPoint(x: axFrame.minX, y: axFrame.maxY))
        return CGRect(x: bottomLeft.x, y: bottomLeft.y, width: axFrame.width, height: axFrame.height)
    }

    /// How well an element's name matches the label, nudged toward
    /// elements near Live's guess. Nil when it doesn't match well enough.
    private static func scoreElement(_ element: AXUIElement, labelWords: [String], roughPointInAXSpace: CGPoint) -> Candidate? {
        let nameTexts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute, "AXLabel"]
            .compactMap { stringAttribute($0, of: element) }
            .filter { !$0.isEmpty && $0.count <= 120 }
        guard !nameTexts.isEmpty else { return nil }

        let elementWords = Set(PointingRefiner.significantWords(in: nameTexts.joined(separator: " ")))
        guard !elementWords.isEmpty else { return nil }
        let matchedLabelWordCount = labelWords.filter { labelWord in
            elementWords.contains { elementWord in
                elementWord == labelWord
                    || (labelWord.count >= 4 && elementWord.hasPrefix(labelWord))
                    || (elementWord.count >= 4 && labelWord.hasPrefix(elementWord))
            }
        }.count
        let matchFraction = Double(matchedLabelWordCount) / Double(labelWords.count)
        guard matchFraction >= 0.99 || (labelWords.count >= 3 && matchFraction >= 0.66) else { return nil }

        guard let frame = frame(of: element),
              frame.width >= 4, frame.height >= 4,
              frame.width <= maximumElementSize.width, frame.height <= maximumElementSize.height else { return nil }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let distanceFromGuess = hypot(center.x - roughPointInAXSpace.x, center.y - roughPointInAXSpace.y)
        // Tight names beat names that only contain the words.
        let extraWordPenalty = Double(max(0, elementWords.count - labelWords.count)) * 0.03
        let score = matchFraction - extraWordPenalty - distanceFromGuess / 3000
        return Candidate(frame: frame, score: max(score, 0.0001))
    }

    private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var currentElement: AXUIElement? = element
        for _ in 0..<60 {
            guard let checkedElement = currentElement else { return nil }
            if stringAttribute(kAXRoleAttribute, of: checkedElement) == kAXWindowRole as String {
                return checkedElement
            }
            currentElement = elementAttribute(kAXParentAttribute, of: checkedElement)
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let childElements = childrenValue as? [AXUIElement] else { return [] }
        return childElements
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return nil }
        return attributeValue as? String
    }

    private static func elementAttribute(_ attributeName: String, of element: AXUIElement) -> AXUIElement? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else { return nil }
        return (attributeValue as! AXUIElement)
    }

    /// Accessibility uses a top-left origin on the primary display; AppKit
    /// uses bottom-left.
    private static var primaryDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private static func axPoint(fromAppKit appKitPoint: CGPoint) -> CGPoint {
        CGPoint(x: appKitPoint.x, y: primaryDisplayHeight - appKitPoint.y)
    }

    private static func appKitPoint(fromAX axPoint: CGPoint) -> CGPoint {
        CGPoint(x: axPoint.x, y: primaryDisplayHeight - axPoint.y)
    }
}

// MARK: - Vision

@MainActor
private enum VisionElementLocator {
    private static let maximumScreenshotDimension = 1920

    static func locate(
        elementLabel: String,
        userQuestion: String,
        roughPoint: CGPoint,
        displayFrame: CGRect
    ) async -> CGRect? {
        guard let screenshot = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: maximumScreenshotDimension),
              let jpegData = NSBitmapImageRep(cgImage: screenshot)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }

        // Live's guess as a hint, in the same 0-1000 space as the answer.
        let hintX = Int(((roughPoint.x - displayFrame.minX) / displayFrame.width * 1000).rounded())
        let hintY = Int(((displayFrame.maxY - roughPoint.y) / displayFrame.height * 1000).rounded())

        let prompt = """
        This is a screenshot of the user's screen. Find this on-screen element: "\(elementLabel)".
        The user asked: "\(userQuestion)".
        Someone guessed it is near x=\(hintX), y=\(hintY) (0-1000 across the image), but the guess may be off.
        Reply with only JSON: {"box_2d": [ymin, xmin, ymax, xmax]} with coordinates normalized 0-1000, for the element itself. If it is not visible, reply {"box_2d": null}.
        """

        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = PointingRefiner.refinementTimeoutSeconds + 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let requestBody: [String: Any] = [
            "model": PointingRefiner.visionModel,
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "responseMimeType": "application/json"
            ]
        ]
        guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        request.httpBody = requestBodyData

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let answerText = textFromServerSentEvents(responseData)
        guard let box = parseBox(from: answerText) else { return nil }

        return CGRect(
            x: displayFrame.minX + box.xmin / 1000 * displayFrame.width,
            y: displayFrame.maxY - box.ymax / 1000 * displayFrame.height,
            width: (box.xmax - box.xmin) / 1000 * displayFrame.width,
            height: (box.ymax - box.ymin) / 1000 * displayFrame.height
        )
    }

    /// /chat streams Gemini's answer as server-sent events.
    private static func textFromServerSentEvents(_ responseData: Data) -> String {
        let responseText = String(decoding: responseData, as: UTF8.self)
        var answerText = ""
        for line in responseText.split(separator: "\n") where line.hasPrefix("data: ") {
            guard let eventData = line.dropFirst(6).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let candidates = event["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            for part in parts where (part["thought"] as? Bool) != true {
                answerText += part["text"] as? String ?? ""
            }
        }
        return answerText
    }

    private static func parseBox(from answerText: String) -> (ymin: Double, xmin: Double, ymax: Double, xmax: Double)? {
        guard let boxRange = answerText.range(of: #"\[\s*-?[\d.]+\s*,\s*-?[\d.]+\s*,\s*-?[\d.]+\s*,\s*-?[\d.]+\s*\]"#, options: .regularExpression) else {
            return nil
        }
        let numbers = answerText[boxRange]
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4 else { return nil }
        let (ymin, xmin, ymax, xmax) = (numbers[0], numbers[1], numbers[2], numbers[3])
        guard (0...1000).contains(ymin), (0...1000).contains(xmin), (0...1000).contains(ymax), (0...1000).contains(xmax),
              ymax > ymin, xmax > xmin else { return nil }
        return (ymin, xmin, ymax, xmax)
    }
}
