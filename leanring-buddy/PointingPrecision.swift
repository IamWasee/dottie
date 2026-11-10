//
//  PointingPrecision.swift
//  leanring-buddy
//
//  Two helpers that make pointing and clicking land exactly:
//
//  - ScreenTextFinder reads the text on screen with Apple's on-device text
//    recognition and finds the words Dottie means ("Export", "Add track"),
//    so even apps that draw their own UI (Figma, FL Studio, games) get an
//    exact box with no AI call.
//  - AccessibilitySnap takes any point and returns the frame of the real
//    button, link, field or menu item under it, so a guess a few pixels off
//    still lands in the middle of the thing.
//

import AppKit
import ApplicationServices
import Foundation
import Vision

// MARK: - On-screen text

@MainActor
enum ScreenTextFinder {
    /// Sharp enough for 11pt menu text on a Retina screen.
    private static let maximumScreenshotDimension = 3200
    /// The area read around Live's guess, in points.
    private static let searchAreaSize = CGSize(width: 1100, height: 700)

    /// The frame (global AppKit points) of on-screen text matching the
    /// label, nearest Live's guess, or nil.
    static func frameOfText(matching label: String, near roughPoint: CGPoint, displayFrame: CGRect) async -> CGRect? {
        let wantedText = normalized(label)
        let labelWords = PointingRefiner.significantWords(in: label)
        guard !wantedText.isEmpty, !labelWords.isEmpty else { return nil }
        guard let screenshot = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: maximumScreenshotDimension) else {
            return nil
        }
        // Read only the area around Live's guess: quicker, and that's
        // nearly always where the thing is. A miss falls through to vision.
        let searchRect = CGRect(
            x: roughPoint.x - searchAreaSize.width / 2,
            y: roughPoint.y - searchAreaSize.height / 2,
            width: searchAreaSize.width,
            height: searchAreaSize.height
        ).intersection(displayFrame)
        guard !searchRect.isNull, searchRect.width > 20, searchRect.height > 20 else { return nil }
        let pixelsPerPoint = CGFloat(screenshot.width) / displayFrame.width
        let cropRectInPixels = CGRect(
            x: (searchRect.minX - displayFrame.minX) * pixelsPerPoint,
            y: (displayFrame.maxY - searchRect.maxY) * pixelsPerPoint,
            width: searchRect.width * pixelsPerPoint,
            height: searchRect.height * pixelsPerPoint
        ).integral
        guard let searchImage = screenshot.cropping(to: cropRectInPixels) else { return nil }
        let recognizedLines = await recognizeText(in: searchImage)

        var bestFrame: CGRect?
        var bestScore = 0.0
        for line in recognizedLines {
            let lineText = normalized(line.text)
            guard !lineText.isEmpty else { continue }
            let matchQuality: Double
            var normalizedBox = line.boundingBox
            if lineText == wantedText {
                matchQuality = 1.0
            } else if let wordBox = line.boxOfSubstring(label), " \(lineText) ".contains(" \(wantedText) ") {
                // The label is one part of a longer line, like "Export" in
                // "File Edit Export View": point at just that part.
                matchQuality = 0.9
                normalizedBox = wordBox
            } else {
                let lineWords = Set(PointingRefiner.significantWords(in: line.text))
                let matchedCount = labelWords.filter { lineWords.contains($0) }.count
                guard matchedCount == labelWords.count, lineWords.count <= labelWords.count + 3 else { continue }
                matchQuality = 0.7
            }
            // Vision's boxes are 0-1 across the searched area with a
            // bottom-left origin, the same way up as AppKit.
            let frame = CGRect(
                x: searchRect.minX + normalizedBox.minX * searchRect.width,
                y: searchRect.minY + normalizedBox.minY * searchRect.height,
                width: normalizedBox.width * searchRect.width,
                height: normalizedBox.height * searchRect.height
            )
            let distanceFromGuess = hypot(frame.midX - roughPoint.x, frame.midY - roughPoint.y)
            let score = matchQuality - distanceFromGuess / 4000
            if score > bestScore {
                bestScore = score
                bestFrame = frame
            }
        }
        return bestFrame
    }

    private struct RecognizedLine: @unchecked Sendable {
        let text: String
        let boundingBox: CGRect
        let observation: VNRecognizedText

        func boxOfSubstring(_ substring: String) -> CGRect? {
            guard let range = text.range(of: substring, options: [.caseInsensitive, .diacriticInsensitive]),
                  let box = try? observation.boundingBox(for: range) else { return nil }
            return box.boundingBox
        }
    }

    private static func recognizeText(in image: CGImage) async -> [RecognizedLine] {
        await Task.detached(priority: .userInitiated) { () -> [RecognizedLine] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.01
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { observation -> RecognizedLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedLine(text: candidate.string, boundingBox: observation.boundingBox, observation: candidate)
            }
        }.value
    }

    /// Lowercase letters and digits with single spaces.
    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Accessibility snap

@MainActor
enum AccessibilitySnap {
    /// Roles worth pointing at or clicking, nearest first.
    private static let targetRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXSlider", "AXDisclosureTriangle", "AXIncrementor", "AXTab", "AXDockItem", "AXCell"
    ]
    /// Used only when nothing above is found around the point.
    private static let fallbackRoles: Set<String> = ["AXStaticText", "AXImage", "AXHeading"]
    private static let maximumSize = CGSize(width: 600, height: 200)
    private static let minimumSize: CGFloat = 6

    /// The frame (global AppKit points) of the control under the point, or
    /// nil when there's nothing small and clickable there.
    static func controlFrame(at point: CGPoint) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let axPoint = CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &hitElement) == .success,
              let hitElement else { return nil }
        // Dottie's own windows (the cursor, drawings) don't count.
        var hitProcessID: pid_t = 0
        AXUIElementGetPid(hitElement, &hitProcessID)
        guard hitProcessID != ProcessInfo.processInfo.processIdentifier else { return nil }

        var fallbackFrame: CGRect?
        var currentElement: AXUIElement? = hitElement
        for _ in 0..<8 {
            guard let element = currentElement else { break }
            if let role = stringAttribute(kAXRoleAttribute, of: element),
               let axFrame = frame(of: element),
               axFrame.width >= minimumSize, axFrame.height >= minimumSize,
               axFrame.width <= maximumSize.width, axFrame.height <= maximumSize.height,
               axFrame.insetBy(dx: -2, dy: -2).contains(axPoint) {
                if targetRoles.contains(role) {
                    return appKitFrame(fromAX: axFrame, primaryDisplayHeight: primaryDisplayHeight)
                }
                if fallbackFrame == nil, fallbackRoles.contains(role) {
                    fallbackFrame = appKitFrame(fromAX: axFrame, primaryDisplayHeight: primaryDisplayHeight)
                }
            }
            currentElement = parent(of: element)
        }
        return fallbackFrame
    }

    /// A found frame swapped for the control under its middle, when that
    /// control's own middle is close by. A tiny icon inside a wide table
    /// row keeps its own frame instead of jumping to the row's middle.
    static func refinedFrame(_ frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let controlFrame = controlFrame(at: center) else { return frame }
        let tolerance = frame.insetBy(dx: -max(8, frame.width * 0.5), dy: -max(8, frame.height * 0.5))
        guard tolerance.contains(CGPoint(x: controlFrame.midX, y: controlFrame.midY)) else { return frame }
        return controlFrame
    }

    private static func appKitFrame(fromAX axFrame: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: axFrame.minX, y: primaryDisplayHeight - axFrame.maxY, width: axFrame.width, height: axFrame.height)
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var attributeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return nil }
        return attributeValue as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
              let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
        return DottieAccessibilityCast.element(parentValue)
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
        guard let positionAXValue = DottieAccessibilityCast.axValue(positionValue), AXValueGetValue(positionAXValue, .cgPoint, &position),
              let sizeAXValue = DottieAccessibilityCast.axValue(sizeValue), AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}

// MARK: - Marking a button by its word

/// "Circle the like button" often finds just the word "Like" by reading
/// the screen, and on web pages there's no accessibility frame for the
/// whole button around it. The 👍 sits to the left of the word, so a
/// circle around the word alone ended up right of the button's middle.
/// This looks at the pixels just left of the word and, when an icon is
/// there, grows the frame to take it in. Only for marks, not clicks: a
/// click on the word works fine.
@MainActor
enum MarkTargetExtender {
    /// A word's frame grown to the icon beside it, or the frame unchanged.
    static func frameIncludingIconBeside(_ textFrame: CGRect, displayFrame: CGRect) async -> CGRect {
        let textHeight = textFrame.height
        // Only short labels: a sentence has no icon of its own.
        guard textHeight >= 6, textHeight <= 44, textFrame.width <= 260 else { return textFrame }
        // A real control around the word already gives the whole button.
        if AccessibilitySnap.controlFrame(at: CGPoint(x: textFrame.midX, y: textFrame.midY)) != nil { return textFrame }

        let searchWidthToTheLeft = textHeight * 2.4
        let stripRect = CGRect(
            x: textFrame.minX - searchWidthToTheLeft,
            y: textFrame.minY - textHeight * 0.45,
            width: searchWidthToTheLeft,
            height: textHeight * 1.9
        ).intersection(displayFrame)
        guard !stripRect.isNull, stripRect.width > 4,
              let screenshot = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: 3200) else {
            return textFrame
        }
        let pixelsPerPoint = CGFloat(screenshot.width) / displayFrame.width
        let stripPixelRect = CGRect(
            x: (stripRect.minX - displayFrame.minX) * pixelsPerPoint,
            y: (displayFrame.maxY - stripRect.maxY) * pixelsPerPoint,
            width: stripRect.width * pixelsPerPoint,
            height: stripRect.height * pixelsPerPoint
        ).integral
        guard let stripImage = screenshot.cropping(to: stripPixelRect),
              let inkColumnRange = inkColumns(in: stripImage) else {
            return textFrame
        }
        // The icon has to end close to the word: a gap of more than about
        // one letter height means it belongs to something else.
        let iconRightEdgeInPoints = stripRect.minX + CGFloat(inkColumnRange.upperBound + 1) / pixelsPerPoint
        let iconLeftEdgeInPoints = stripRect.minX + CGFloat(inkColumnRange.lowerBound) / pixelsPerPoint
        let gapToWord = textFrame.minX - iconRightEdgeInPoints
        guard gapToWord <= textHeight * 1.1, textFrame.minX - iconLeftEdgeInPoints <= searchWidthToTheLeft else { return textFrame }
        let grownFrame = CGRect(x: iconLeftEdgeInPoints, y: textFrame.minY, width: textFrame.maxX - iconLeftEdgeInPoints, height: textFrame.height)
        DottieLog.notice("🎯 Mark grown from the word to the icon beside it: \(Int(textFrame.minX)) → \(Int(grownFrame.minX))")
        return grownFrame
    }

    /// The run of columns, nearest the word (the strip's right side),
    /// that hold something other than the background. nil when the strip
    /// is plain background.
    private static func inkColumns(in image: CGImage) -> ClosedRange<Int>? {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func brightness(column: Int, row: Int) -> Int {
            let offset = (row * width + column) * 4
            return (Int(pixels[offset]) * 299 + Int(pixels[offset + 1]) * 587 + Int(pixels[offset + 2]) * 114) / 1000
        }
        // The background is the strip's most common brightness.
        var brightnessCounts = [Int](repeating: 0, count: 256)
        for row in stride(from: 0, to: height, by: 2) {
            for column in stride(from: 0, to: width, by: 2) {
                brightnessCounts[brightness(column: column, row: row)] += 1
            }
        }
        let backgroundBrightness = brightnessCounts.indices.max { brightnessCounts[$0] < brightnessCounts[$1] } ?? 255

        let minimumInkPixelsInColumn = max(2, height / 10)
        var columnHasInk = [Bool](repeating: false, count: width)
        for column in 0..<width {
            var inkPixelCount = 0
            for row in 0..<height where abs(brightness(column: column, row: row) - backgroundBrightness) > 40 {
                inkPixelCount += 1
            }
            columnHasInk[column] = inkPixelCount >= minimumInkPixelsInColumn
        }
        // From the word leftward: skip the gap, then take the icon's
        // columns until the next real gap.
        guard let rightmostInkColumn = columnHasInk.lastIndex(of: true) else { return nil }
        var leftmostInkColumn = rightmostInkColumn
        var emptyRun = 0
        let allowedEmptyRun = max(2, height / 6)
        var column = rightmostInkColumn - 1
        while column >= 0 {
            if columnHasInk[column] {
                leftmostInkColumn = column
                emptyRun = 0
            } else {
                emptyRun += 1
                if emptyRun > allowedEmptyRun { break }
            }
            column -= 1
        }
        // A single thin line (a divider) isn't an icon.
        guard rightmostInkColumn - leftmostInkColumn >= max(3, height / 5) else { return nil }
        return leftmostInkColumn...rightmostInkColumn
    }
}
