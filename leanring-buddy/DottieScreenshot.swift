//
//  DottieScreenshot.swift
//  leanring-buddy
//
//  Real screenshots the user keeps ("take a screenshot", "screenshot this
//  window", "copy my screen"): full resolution PNGs saved where macOS saves
//  its own screenshots (the Desktop unless the user changed it), named the
//  way macOS names them, optionally copied to the clipboard. Dottie's own
//  cursor and notch are left out. "pick" lets the user drag over the part
//  they want with macOS's own crosshair.
//

import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum DottieScreenshot {
    /// The newest screenshot Dottie took, so "open it" or "show it" can
    /// find it again.
    private(set) static var lastScreenshotURLs: [URL] = []

    /// area: screen (the one with the cursor), all_screens, window (the
    /// frontmost app's window) or pick. destination: file, clipboard or both.
    static func take(area: String, destination: String) async -> String {
        let wantsFile = destination != "clipboard"
        let wantsClipboard = destination == "clipboard" || destination == "both"

        if area == "pick" {
            return await takePickedArea(wantsFile: wantsFile, wantsClipboard: wantsClipboard)
        }

        let images: [CGImage]
        do {
            switch area {
            case "window":
                images = [try await captureFrontWindow()]
            case "all_screens":
                images = try await captureScreens(onlyCursorScreen: false)
            default:
                images = try await captureScreens(onlyCursorScreen: true)
            }
        } catch {
            return "couldn't take the screenshot: \(error.localizedDescription). Dottie needs Screen Recording in System Settings → Privacy & Security."
        }
        guard !images.isEmpty else { return "couldn't take the screenshot." }

        if wantsClipboard, let firstImage = images.first {
            copyToClipboard(firstImage)
        }
        guard wantsFile else { return "copied a screenshot to the clipboard; paste it with command-V." }

        let baseName = fileBaseName()
        var savedURLs: [URL] = []
        for (imageIndex, image) in images.enumerated() {
            let name = images.count > 1 ? "\(baseName) (\(imageIndex + 1)).png" : "\(baseName).png"
            let fileURL = uniqueURL(in: saveFolder(), named: name)
            if writePNG(image, to: fileURL) { savedURLs.append(fileURL) }
        }
        guard !savedURLs.isEmpty else { return "took the screenshot but couldn't save it to \(saveFolder().path)." }
        lastScreenshotURLs = savedURLs
        NSSound(named: "Grab")?.play()
        return savedMessage(savedURLs, alsoCopied: wantsClipboard)
    }

    /// Opens the newest screenshot in Preview.
    static func openLast() -> String {
        guard let fileURL = lastScreenshotURLs.first, FileManager.default.fileExists(atPath: fileURL.path) else {
            return "I haven't taken a screenshot yet."
        }
        NSWorkspace.shared.open(fileURL)
        return "opened \(fileURL.lastPathComponent)."
    }

    // MARK: - Capturing

    private static func captureScreens(onlyCursorScreen: Bool) async throws -> [CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownWindows = ownAppWindows(in: content)
        let mouseLocation = NSEvent.mouseLocation
        var images: [CGImage] = []
        for display in content.displays {
            let screen = NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }
            if onlyCursorScreen, content.displays.count > 1, let screen, !screen.frame.contains(mouseLocation) { continue }
            let scale = screen?.backingScaleFactor ?? 2
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            images.append(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
        }
        return images
    }

    private static func captureFrontWindow() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let windowID = frontWindowID(),
              let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NSError(domain: "DottieScreenshot", code: -1, userInfo: [NSLocalizedDescriptionKey: "no window is open in front"])
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The topmost normal window of the frontmost app that isn't Dottie.
    /// CGWindowList lists windows front to back.
    private static func frontWindowID() -> CGWindowID? {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let frontProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var firstOtherWindow: CGWindowID?
        for windowInfo in windowList {
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? -1
            let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? Int32 ?? -1
            guard layer == 0, ownerProcessID != ownProcessID,
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? Int else { continue }
            let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width > 50, height > 50 else { continue }
            if ownerProcessID == frontProcessID { return CGWindowID(windowNumber) }
            if firstOtherWindow == nil { firstOtherWindow = CGWindowID(windowNumber) }
        }
        return firstOtherWindow
    }

    private static func ownAppWindows(in content: SCShareableContent) -> [SCWindow] {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        return content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
    }

    /// macOS's own crosshair: the user drags over an area (space switches
    /// to picking a window, escape cancels). Waits up to two minutes.
    private static func takePickedArea(wantsFile: Bool, wantsClipboard: Bool) async -> String {
        let fileURL = uniqueURL(in: wantsFile ? saveFolder() : FileManager.default.temporaryDirectory, named: "\(fileBaseName()).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-o", fileURL.path]
        do {
            try process.run()
        } catch {
            return "couldn't start the screenshot picker: \(error.localizedDescription)"
        }
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if process.isRunning {
            process.terminate()
            return "nobody picked an area, so I stopped the screenshot."
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return "the screenshot was cancelled."
        }
        if wantsClipboard, let image = NSImage(contentsOf: fileURL),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            copyToClipboard(cgImage)
        }
        guard wantsFile else {
            try? FileManager.default.removeItem(at: fileURL)
            return "copied it to the clipboard; paste it with command-V."
        }
        lastScreenshotURLs = [fileURL]
        return savedMessage([fileURL], alsoCopied: wantsClipboard)
    }

    // MARK: - Saving

    /// Where macOS saves screenshots: the user's choice in the Screenshot
    /// app's Options, or the Desktop.
    static func saveFolder() -> URL {
        if let customPath = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let folderURL = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return folderURL
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// "Screenshot 2026-10-17 at 4.55.12 PM", like macOS.
    private static func fileBaseName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return "Screenshot \(formatter.string(from: Date()))"
    }

    private static func uniqueURL(in folder: URL, named fileName: String) -> URL {
        var candidate = folder.appendingPathComponent(fileName)
        let stem = candidate.deletingPathExtension().lastPathComponent
        var copyNumber = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(copyNumber).png")
            copyNumber += 1
        }
        return candidate
    }

    private static func writePNG(_ image: CGImage, to fileURL: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func copyToClipboard(_ image: CGImage) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        if let tiffData = bitmap.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }

    private static func savedMessage(_ fileURLs: [URL], alsoCopied: Bool) -> String {
        let folderName = fileURLs[0].deletingLastPathComponent().lastPathComponent
        let names = fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        let copiedNote = alsoCopied ? " and copied it to the clipboard" : ""
        return "saved \(names) to \(folderName)\(copiedNote)."
    }
}
