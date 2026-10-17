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
//       accessibility tree. Only elements near the guess count.
//    2. On-screen text: Apple's on-device text recognition looks for the
//       label's words on the display (ScreenTextFinder). Exact, free and
//       quick, and works in apps that draw their own UI. Skipped for counts
//       like "7M", which sit under an icon rather than on it.
//    3. Vision: otherwise, a fresh, sharper screenshot of that display goes
//       to Gemini Flash, which is trained to return bounding boxes, with the
//       label and Live's guess as a hint. Tiny targets (toolbar icons) get a
//       second, zoomed-in look when there's time.
//
//  Whatever is found is then snapped to the real control under it
//  (AccessibilitySnap), so the cursor lands in the middle of the button.
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
    /// The quickest model that still finds boxes well: about 1-1.5s on a
    /// Mac runner, against 2.5-8s for gemini-3.6-flash (Oct 2026).
    static let visionModel = "gemini-3.5-flash-lite"
    /// Text recognition normally takes well under a second.
    static let textSearchTimeoutSeconds: TimeInterval = 1.2

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
        let refinementStart = Date()
        let labelWords = significantWords(in: elementLabel ?? "")

        if !labelWords.isEmpty, let accessibilityFrame = AccessibilityElementSearch.bestMatch(
            forLabelWords: labelWords,
            near: roughPoint
        ) {
            print("🎯 Pointing refined by Accessibility: \(Int(roughPoint.x)),\(Int(roughPoint.y)) → \(Int(accessibilityFrame.midX)),\(Int(accessibilityFrame.midY))")
            return accessibilityFrame
        }

        guard let elementLabel, !elementLabel.isEmpty else { return nil }

        // On-device text recognition: exact for anything with a visible
        // label, even in apps with no accessibility info, and no AI call.
        // A count like "7M" is the number under an icon, not the icon, so
        // that goes to vision.
        if !isCount(elementLabel), let textFrame = await withTimeout(seconds: textSearchTimeoutSeconds, operation: {
            await ScreenTextFinder.frameOfText(matching: elementLabel, near: roughPoint, displayFrame: displayFrame)
        }) {
            let snappedFrame = AccessibilitySnap.refinedFrame(textFrame)
            print("🎯 Pointing refined by on-screen text: \(Int(roughPoint.x)),\(Int(roughPoint.y)) → \(Int(snappedFrame.midX)),\(Int(snappedFrame.midY))")
            return snappedFrame
        }

        let deadline = refinementStart.addingTimeInterval(refinementTimeoutSeconds)
        let visionFrame = await withTimeout(seconds: max(0.5, deadline.timeIntervalSinceNow)) {
            await VisionElementLocator.locate(
                elementLabel: elementLabel,
                userQuestion: userQuestion,
                roughPoint: roughPoint,
                displayFrame: displayFrame,
                deadline: deadline
            )
        }
        guard let visionFrame else { return nil }
        let snappedFrame = AccessibilitySnap.refinedFrame(visionFrame)
        print("🎯 Pointing refined by vision: \(Int(roughPoint.x)),\(Int(roughPoint.y)) → \(Int(snappedFrame.midX)),\(Int(snappedFrame.midY))")
        return snappedFrame
    }

    /// "7M", "8,429", "1.2K": the number shown under a like or comment
    /// icon.
    static func isCount(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespaces)
            .range(of: #"^[0-9][0-9.,]*\s*[KkMmBb]?$"#, options: .regularExpression) != nil
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
    /// A same-named element farther than this from Live's guess is a
    /// different thing: "Search" on a web page is not Chrome's own tab
    /// search in the corner (seen in testing, Oct 2026). Vision finds the
    /// rest.
    private static let maximumDistanceFromGuess: CGFloat = 350

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
        guard distanceFromGuess <= maximumDistanceFromGuess else { return nil }
        // Tight names beat names that only contain the words.
        let extraWordPenalty = Double(max(0, elementWords.count - labelWords.count)) * 0.03
        let score = matchFraction - extraWordPenalty - distanceFromGuess / 1000
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
    /// Targets smaller than this (in points) get a zoomed-in second look.
    private static let smallTargetSize: CGFloat = 40
    /// The zoomed-in square, in points.
    private static let zoomSide: CGFloat = 320
    /// A zoom pass only starts when at least this much time is left.
    private static let minimumSecondsForZoom: TimeInterval = 2

    private typealias Box = (ymin: Double, xmin: Double, ymax: Double, xmax: Double)

    static func locate(
        elementLabel: String,
        userQuestion: String,
        roughPoint: CGPoint,
        displayFrame: CGRect,
        deadline: Date
    ) async -> CGRect? {
        // One full-resolution capture: downscaled for the first look,
        // cropped for the zoomed one.
        guard let nativeImage = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: 8000),
              let overviewImage = resized(nativeImage, maximumDimension: maximumScreenshotDimension),
              let overviewJPEG = jpegData(overviewImage) else { return nil }

        // Live's guess as a hint, in the same 0-1000 space as the answer.
        let hintX = Int(((roughPoint.x - displayFrame.minX) / displayFrame.width * 1000).rounded())
        let hintY = Int(((displayFrame.maxY - roughPoint.y) / displayFrame.height * 1000).rounded())
        let overviewPrompt = """
        This is a screenshot of the user's screen. Find this on-screen element: "\(elementLabel)".
        The user asked: "\(userQuestion)".
        It may be an icon with no text: a heart or thumbs-up for like, a speech bubble for comments, a curved arrow for share, a bell for notifications, a gear for settings, a magnifying glass for search. If the name is a number, it's the icon that number sits under.
        Someone guessed it is near x=\(hintX), y=\(hintY) (0-1000 across the image), but the guess may be far off, so look at the whole screen.
        Reply with only JSON: {"box_2d": [ymin, xmin, ymax, xmax]} with coordinates normalized 0-1000, tight around the element itself. If it is not visible, reply {"box_2d": null}.
        """
        let overviewFrame = await askForBox(jpegData: overviewJPEG, prompt: overviewPrompt).map { frame(of: $0, in: displayFrame) }

        // Big, clear targets are done. Tiny ones, or a miss, get a closer look.
        if let overviewFrame, min(overviewFrame.width, overviewFrame.height) >= smallTargetSize {
            return overviewFrame
        }
        guard deadline.timeIntervalSinceNow >= minimumSecondsForZoom else { return overviewFrame }
        let zoomCenter = overviewFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? roughPoint
        let zoomRect = CGRect(x: zoomCenter.x - zoomSide / 2, y: zoomCenter.y - zoomSide / 2, width: zoomSide, height: zoomSide)
            .intersection(displayFrame)
        guard !zoomRect.isNull, zoomRect.width > 40, zoomRect.height > 40 else { return overviewFrame }

        let pixelsPerPoint = CGFloat(nativeImage.width) / displayFrame.width
        let cropRectInPixels = CGRect(
            x: (zoomRect.minX - displayFrame.minX) * pixelsPerPoint,
            y: (displayFrame.maxY - zoomRect.maxY) * pixelsPerPoint,
            width: zoomRect.width * pixelsPerPoint,
            height: zoomRect.height * pixelsPerPoint
        ).integral
        guard let zoomedImage = nativeImage.cropping(to: cropRectInPixels),
              let zoomedJPEG = jpegData(zoomedImage) else { return overviewFrame }
        let zoomPrompt = """
        This is a zoomed-in part of the user's screen. Find this element in it: "\(elementLabel)".
        The user asked: "\(userQuestion)".
        It may be an icon with no text (a heart or thumbs-up for like, a speech bubble for comments, a bell for notifications).
        Reply with only JSON: {"box_2d": [ymin, xmin, ymax, xmax]} with coordinates normalized 0-1000 across this zoomed image, for the element itself. If it is not in this image, reply {"box_2d": null}.
        """
        guard let zoomedBox = await askForBox(jpegData: zoomedJPEG, prompt: zoomPrompt) else { return overviewFrame }
        print("🎯 Zoom pass refined the vision guess")
        return frame(of: zoomedBox, in: zoomRect)
    }

    /// A 0-1000 box on an image of `area`, in global AppKit coordinates.
    private static func frame(of box: Box, in area: CGRect) -> CGRect {
        CGRect(
            x: area.minX + box.xmin / 1000 * area.width,
            y: area.maxY - box.ymax / 1000 * area.height,
            width: (box.xmax - box.xmin) / 1000 * area.width,
            height: (box.ymax - box.ymin) / 1000 * area.height
        )
    }

    private static func askForBox(jpegData: Data, prompt: String) async -> Box? {
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
        return parseBox(from: GeminiServerSentEvents.text(from: responseData))
    }

    private static func resized(_ image: CGImage, maximumDimension: Int) -> CGImage? {
        let scale = min(1, CGFloat(maximumDimension) / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func parseBox(from answerText: String) -> Box? {
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
