import AppKit
import Foundation
import ScreenCaptureKit

enum ClickyWorkerConfiguration {
    static func url(forRoute routePath: String) -> URL {
        URL(string: (ProcessInfo.processInfo.environment["W"] ?? "https://dottie.vidershub.workers.dev") + routePath)!
    }
    static func applyAuthenticationHeaders(to request: inout URLRequest) {
        request.setValue("Dottie/1.0", forHTTPHeaderField: "User-Agent")
    }
}

@MainActor
enum DottieDisplayCapture {
    static func captureImage(displayFrame: CGRect, maximumDimension: Int) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let matchingScreen = NSScreen.screens.first(where: { $0.frame == displayFrame })
        let displayID = matchingScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let pointsToPixels = matchingScreen?.backingScaleFactor ?? 2
        let nativeWidth = CGFloat(display.width) * pointsToPixels
        let nativeHeight = CGFloat(display.height) * pointsToPixels
        let downscale = min(1, CGFloat(maximumDimension) / max(nativeWidth, nativeHeight))
        configuration.width = Int(nativeWidth * downscale)
        configuration.height = Int(nativeHeight * downscale)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
