//
//  DottieDisplayCapture.swift
//  leanring-buddy
//
//  One display captured without Dottie's own windows (cursor, notch,
//  drawings), with what's needed to map 0-1000 positions back to the
//  screen. Used by screen jobs, guides and pointing.
//

import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

/// One display captured without Dottie's own windows (cursor, notch,
/// drawings), with what's needed to map 0-1000 positions back to the screen.
@MainActor
enum DottieDisplayCapture {
    struct Screenshot {
        let image: CGImage
        let jpegData: Data
        /// The display's frame in global AppKit coordinates.
        let displayFrame: CGRect

        /// A 0-1000 position on the screenshot, in global AppKit points.
        func globalPoint(normalizedX: Double, normalizedY: Double) -> CGPoint {
            let clampedX = min(max(normalizedX, 0), 1000) / 1000
            let clampedY = min(max(normalizedY, 0), 1000) / 1000
            return CGPoint(
                x: displayFrame.minX + CGFloat(clampedX) * displayFrame.width,
                y: displayFrame.maxY - CGFloat(clampedY) * displayFrame.height
            )
        }
    }

    /// The display with the frontmost app's window, else the one with the
    /// pointer.
    static func captureActiveDisplay(maximumDimension: Int) async -> Screenshot? {
        let displayFrame = frontmostWindowDisplayFrame()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame
            ?? NSScreen.main?.frame
        guard let displayFrame else { return nil }
        return await capture(displayFrame: displayFrame, maximumDimension: maximumDimension)
    }

    static func capture(displayFrame: CGRect, maximumDimension: Int) async -> Screenshot? {
        guard let image = await captureImage(displayFrame: displayFrame, maximumDimension: maximumDimension),
              let jpegData = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        return Screenshot(image: image, jpegData: jpegData, displayFrame: displayFrame)
    }

    /// What to capture for one display, kept for a moment. Asking macOS
    /// for every window and display (SCShareableContent) is slow, and
    /// games capture many frames a second, so frames in quick succession
    /// reuse the same filter. Kept only briefly, so a window Dottie opens
    /// (a drawing, a card) is still left out of the next captures.
    private struct ReusableCaptureSetup {
        let displayFrame: CGRect
        let maximumDimension: Int
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let madeAt: Date
    }
    private static var reusableCaptureSetup: ReusableCaptureSetup?
    private static let secondsToReuseCaptureSetup: TimeInterval = 1.0

    static func captureImage(displayFrame: CGRect, maximumDimension: Int) async -> CGImage? {
        if let reusableCaptureSetup,
           reusableCaptureSetup.displayFrame == displayFrame,
           reusableCaptureSetup.maximumDimension == maximumDimension,
           Date().timeIntervalSince(reusableCaptureSetup.madeAt) < secondsToReuseCaptureSetup {
            return try? await SCScreenshotManager.captureImage(contentFilter: reusableCaptureSetup.filter, configuration: reusableCaptureSetup.configuration)
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }

        let matchingScreen = NSScreen.screens.first(where: { $0.frame == displayFrame })
        let displayID = matchingScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        let pointsToPixels = matchingScreen?.backingScaleFactor ?? 2
        let nativeWidth = CGFloat(display.width) * pointsToPixels
        let nativeHeight = CGFloat(display.height) * pointsToPixels
        let downscale = min(1, CGFloat(maximumDimension) / max(nativeWidth, nativeHeight))
        configuration.width = Int(nativeWidth * downscale)
        configuration.height = Int(nativeHeight * downscale)
        configuration.showsCursor = false

        reusableCaptureSetup = ReusableCaptureSetup(
            displayFrame: displayFrame,
            maximumDimension: maximumDimension,
            filter: filter,
            configuration: configuration,
            madeAt: Date()
        )
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func frontmostWindowDisplayFrame() -> CGRect? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindow = DottieAccessibilityCast.element(focusedWindowValue) else { return nil }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionAXValue = DottieAccessibilityCast.axValue(positionValue), AXValueGetValue(positionAXValue, .cgPoint, &position),
              let sizeAXValue = DottieAccessibilityCast.axValue(sizeValue), AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        // Accessibility is top-left origin on the primary display.
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let windowCenter = CGPoint(x: position.x + size.width / 2, y: primaryDisplayHeight - (position.y + size.height / 2))
        return NSScreen.screens.first(where: { $0.frame.contains(windowCenter) })?.frame
    }
}
