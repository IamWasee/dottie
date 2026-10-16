//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// One display's raw capture plus where it sits in AppKit space.
    private struct CapturedDisplayImage {
        let cgImage: CGImage
        let label: String
        let isCursorScreen: Bool
        let displayFrame: CGRect
    }

    /// Captures every display (cursor screen first) at up to 1280px on the
    /// long edge, excluding this app's own windows.
    private static func captureAllDisplayImages() async throws -> [CapturedDisplayImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedDisplayImages: [CapturedDisplayImage] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedDisplayImages.append(CapturedDisplayImage(
                cgImage: cgImage,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayFrame: displayFrame
            ))
        }

        guard !capturedDisplayImages.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedDisplayImages
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let capturedDisplayImages = try await captureAllDisplayImages()

        var capturedScreens: [CompanionScreenCapture] = []
        for capturedDisplayImage in capturedDisplayImages {
            guard let jpegData = jpegData(from: capturedDisplayImage.cgImage) else { continue }
            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: capturedDisplayImage.label,
                isCursorScreen: capturedDisplayImage.isCursorScreen,
                displayWidthInPoints: Int(capturedDisplayImage.displayFrame.width),
                displayHeightInPoints: Int(capturedDisplayImage.displayFrame.height),
                displayFrame: capturedDisplayImage.displayFrame,
                screenshotWidthInPixels: capturedDisplayImage.cgImage.width,
                screenshotHeightInPixels: capturedDisplayImage.cgImage.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Gemini Live takes one frame at a time, so for the voice companion every
    /// display is drawn side by side into a single image. Each region keeps a
    /// CompanionScreenCapture whose "screenshot" size is the region's size in
    /// the composite, so the usual pixel → screen conversion still applies.
    static func captureCompositeFrameForLive() async throws -> CompanionCompositeScreenFrame {
        let capturedDisplayImages = try await captureAllDisplayImages()

        // Keep the composite within a size Gemini handles well. A single
        // screen passes through at its captured size.
        let maximumCompositeWidth: CGFloat = 2048
        let gapBetweenScreens: CGFloat = 16
        let tallestDisplayHeight = capturedDisplayImages.map { CGFloat($0.cgImage.height) }.max() ?? 0
        let naturalCompositeWidth = capturedDisplayImages.map { CGFloat($0.cgImage.width) }.reduce(0, +)
            + gapBetweenScreens * CGFloat(max(0, capturedDisplayImages.count - 1))
        let compositeScale = min(1, maximumCompositeWidth / naturalCompositeWidth)

        let compositeWidth = Int((naturalCompositeWidth * compositeScale).rounded())
        let compositeHeight = Int((tallestDisplayHeight * compositeScale).rounded())

        guard let compositeContext = CGContext(
            data: nil,
            width: compositeWidth,
            height: compositeHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create composite image"])
        }
        compositeContext.setFillColor(CGColor(gray: 0, alpha: 1))
        compositeContext.fill(CGRect(x: 0, y: 0, width: compositeWidth, height: compositeHeight))
        compositeContext.interpolationQuality = .high

        var regions: [CompanionCompositeScreenFrame.Region] = []
        var nextRegionLeftEdge: CGFloat = 0

        for capturedDisplayImage in capturedDisplayImages {
            let regionWidth = CGFloat(capturedDisplayImage.cgImage.width) * compositeScale
            let regionHeight = CGFloat(capturedDisplayImage.cgImage.height) * compositeScale
            // Regions are top-aligned. CGContext's origin is bottom-left, so
            // the draw rect's y is measured up from the bottom.
            let drawRect = CGRect(
                x: nextRegionLeftEdge,
                y: CGFloat(compositeHeight) - regionHeight,
                width: regionWidth,
                height: regionHeight
            )
            compositeContext.draw(capturedDisplayImage.cgImage, in: drawRect)

            let regionRectInTopLeftPixels = CGRect(x: nextRegionLeftEdge, y: 0, width: regionWidth, height: regionHeight)
            regions.append(CompanionCompositeScreenFrame.Region(
                rectInCompositePixels: regionRectInTopLeftPixels,
                screenCapture: CompanionScreenCapture(
                    imageData: Data(),
                    label: capturedDisplayImage.label,
                    isCursorScreen: capturedDisplayImage.isCursorScreen,
                    displayWidthInPoints: Int(capturedDisplayImage.displayFrame.width),
                    displayHeightInPoints: Int(capturedDisplayImage.displayFrame.height),
                    displayFrame: capturedDisplayImage.displayFrame,
                    screenshotWidthInPixels: Int(regionWidth.rounded()),
                    screenshotHeightInPixels: Int(regionHeight.rounded())
                )
            ))

            nextRegionLeftEdge += regionWidth + gapBetweenScreens * compositeScale
        }

        guard let compositeImage = compositeContext.makeImage(),
              let compositeJPEGData = jpegData(from: compositeImage) else {
            throw NSError(domain: "CompanionScreenCapture", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode composite image"])
        }

        return CompanionCompositeScreenFrame(
            jpegData: compositeJPEGData,
            compositeWidthInPixels: compositeWidth,
            compositeHeightInPixels: compositeHeight,
            regions: regions
        )
    }

    private static func jpegData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// A single image holding every display side by side (left to right, cursor
/// screen first), plus where each display landed inside it.
struct CompanionCompositeScreenFrame {
    struct Region {
        /// Region bounds in composite pixels, top-left origin.
        let rectInCompositePixels: CGRect
        let screenCapture: CompanionScreenCapture
    }

    let jpegData: Data
    let compositeWidthInPixels: Int
    let compositeHeightInPixels: Int
    let regions: [Region]

    /// Short description for the model of how the frame is laid out.
    var layoutDescription: String {
        guard regions.count > 1 else {
            return "the frame shows the user's single screen."
        }
        let regionDescriptions = regions.enumerated().map { regionIndex, region in
            let leftPercent = Int((region.rectInCompositePixels.minX / CGFloat(compositeWidthInPixels) * 100).rounded())
            let rightPercent = Int((region.rectInCompositePixels.maxX / CGFloat(compositeWidthInPixels) * 100).rounded())
            return "screen \(regionIndex + 1) spans \(leftPercent)%–\(rightPercent)% of the width\(region.screenCapture.isCursorScreen ? " (cursor is here, primary focus)" : "")"
        }
        return "the frame shows \(regions.count) screens side by side, left to right: " + regionDescriptions.joined(separator: "; ") + "."
    }

    /// Maps a 0–1000 normalized point on the composite to the display it
    /// falls on and the pixel position inside that display's region. Points
    /// in a gap snap to the nearest region.
    func resolveNormalizedPoint(normalizedX: Double, normalizedY: Double)
        -> (screenCapture: CompanionScreenCapture, pointInScreenshotPixels: CGPoint)? {
        guard !regions.isEmpty else { return nil }

        let compositePoint = CGPoint(
            x: max(0, min(1000, normalizedX)) / 1000 * Double(compositeWidthInPixels),
            y: max(0, min(1000, normalizedY)) / 1000 * Double(compositeHeightInPixels)
        )

        let closestRegion = regions.min { regionA, regionB in
            let distanceToRegionA = horizontalDistance(from: compositePoint, to: regionA.rectInCompositePixels)
            let distanceToRegionB = horizontalDistance(from: compositePoint, to: regionB.rectInCompositePixels)
            return distanceToRegionA < distanceToRegionB
        }!

        let regionRect = closestRegion.rectInCompositePixels
        let pointInRegion = CGPoint(
            x: max(0, min(regionRect.width, compositePoint.x - regionRect.minX)),
            y: max(0, min(regionRect.height, compositePoint.y - regionRect.minY))
        )
        return (closestRegion.screenCapture, pointInRegion)
    }

    private func horizontalDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        if point.x < rect.minX { return rect.minX - point.x }
        if point.x > rect.maxX { return point.x - rect.maxX }
        return 0
    }
}
