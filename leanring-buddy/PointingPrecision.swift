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
        return (parentValue as! AXUIElement)
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
}
