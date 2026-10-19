//
//  DottieWatches.swift
//  leanring-buddy
//
//  "Tell me when this download finishes / when this page changes / when it
//  says Done / when my game loads." Each watch looks at a window, an app
//  or the whole screen every couple of seconds as a tiny grayscale
//  thumbnail (ScreenCaptureKit) and compares it with the last one, all on
//  the Mac. Text conditions are read with Apple's on-device text
//  recognition, only when the picture changed. Gemini is asked (one small
//  picture, at most every 20 seconds) only for visual conditions words
//  can't catch, and only after a real change. Downloads are watched in the
//  Downloads folder itself, without looking at the screen at all.
//
//  When a watch fires: a card in the notch, a sound, a macOS notification
//  and a Telegram message if a phone is paired. Watches run on their own,
//  after the voice session ends, until they fire or hit their time limit.
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

@MainActor
final class DottieWatches {
    enum Kind: String, CaseIterable {
        case changes
        case textAppears = "text_appears"
        case textDisappears = "text_disappears"
        case stopsChanging = "stops_changing"
        case downloadFinishes = "download_finishes"
        case looksLike = "looks_like"
    }

    private enum Target {
        case window(CGWindowID)
        case app(pid_t)
        case screen(CGDirectDisplayID)
        case downloadsFolder
    }

    @MainActor
    private final class Watch {
        let id = UUID()
        let what: String
        let kind: Kind
        let text: String?
        let target: Target
        let targetName: String
        let startedAt = Date()
        let endsAt: Date
        var baselineThumbnail: DottieWatchThumbnail?
        var previousThumbnail: DottieWatchThumbnail?
        var lastChangeAt = Date()
        var hasSeenMovement = false
        var consecutiveChangedChecks = 0
        var lastReadThumbnail: DottieWatchThumbnail?
        var lastReadAt = Date.distantPast
        var hasSeenText = false
        var lastModelThumbnail: DottieWatchThumbnail?
        var lastModelCheckAt = Date.distantPast
        var missedCaptureCount = 0
        var isChecking = false
        var downloadsSeenInProgress: Set<String> = []

        init(what: String, kind: Kind, text: String?, target: Target, targetName: String, minutes: Double) {
            self.what = what
            self.kind = kind
            self.text = text
            self.target = target
            self.targetName = targetName
            self.endsAt = Date().addingTimeInterval(minutes * 60)
        }
    }

    private static let maximumWatchCount = 6
    private static let checkIntervalSeconds: Double = 2
    /// DottieWatchThumbnail pixels that moved this much count as changed.
    private static let movedPixelFraction = 0.004
    private static let meaningfulChangeFraction = 0.02
    private static let modelCheckMinimumSeconds: TimeInterval = 20
    /// Across every watch, so several never add up to a burst of calls.
    private static let modelCallSpacingSeconds: TimeInterval = 8
    private static let model = "gemini-3.5-flash-lite"
    private static let inProgressDownloadExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    private var watches: [Watch] = []
    private var loopTask: Task<Void, Never>?
    private var lastModelCallAt = Date.distantPast

    /// The notch's status lines need refreshing.
    var onChange: (() -> Void)?

    var statusLines: [NotchStatusLine] {
        watches.map { watch in
            NotchStatusLine(id: "watch:\(watch.id.uuidString)", symbolName: "eye.fill", text: "watching: \(watch.what)")
        }
    }

    // MARK: - Starting and stopping

    func start(what: String, kind: Kind, text: String?, target targetName: String, appName: String?, minutes: Double) async -> String {
        guard watches.count < Self.maximumWatchCount else {
            return "already watching \(watches.count) things. stop one first (watch action stop)."
        }
        let minutes = min(480, max(1, minutes))
        if (kind == .textAppears || kind == .textDisappears || kind == .looksLike) && (text ?? "").isEmpty {
            return "say what to look for in text."
        }

        guard let (target, resolvedName) = resolveTarget(kind: kind, targetName: targetName, appName: appName) else {
            if targetName == "app" {
                return "couldn't find an open app called \(appName ?? "that"). ask them which app."
            }
            return "couldn't find a window to watch. ask them to bring it to the front."
        }

        let watch = Watch(what: what, kind: kind, text: text, target: target, targetName: resolvedName, minutes: minutes)
        var startNote = ""

        if kind == .downloadFinishes {
            let inProgress = Self.inProgressDownloads()
            watch.downloadsSeenInProgress = inProgress
            if inProgress.isEmpty {
                startNote = " no download is running yet; it fires when the next one finishes."
            }
        } else {
            guard let firstImage = await captureImage(of: watch, maximumWidth: 320),
                  let firstThumbnail = DottieWatchThumbnail(image: firstImage) else {
                return "can't see the screen. Dottie needs Screen Recording permission (System Settings → Privacy & Security → Screen Recording)."
            }
            watch.baselineThumbnail = firstThumbnail
            watch.previousThumbnail = firstThumbnail
            watch.lastModelThumbnail = firstThumbnail

            if kind == .textAppears || kind == .textDisappears, let text {
                let isShowingNow = await isShowing(text, in: watch)
                watch.lastReadThumbnail = firstThumbnail
                watch.lastReadAt = Date()
                if kind == .textAppears && isShowingNow {
                    return "\(resolvedName) already shows \"\(text)\" right now, so there's nothing to wait for. tell them."
                }
                if kind == .textDisappears {
                    guard isShowingNow else {
                        return "I don't see \"\(text)\" in \(resolvedName) right now, so there's nothing to wait for. tell them."
                    }
                    watch.hasSeenText = true
                }
            }
        }

        watches.append(watch)
        startLoopIfNeeded()
        onChange?()
        let minutesText = minutes == 1 ? "1 minute" : "\(Int(minutes)) minutes"
        return "watching \(resolvedName) for: \(watch.what). when it happens they get a notch alert, a sound, a notification and a phone message if paired. gives up after \(minutesText).\(startNote) tell them in a few words."
    }

    func stop(id watchID: UUID) {
        watches.removeAll { $0.id == watchID }
        onChange?()
    }

    func stop(matching text: String) -> String {
        let lowered = text.lowercased()
        guard !watches.isEmpty else { return "nothing is being watched." }
        if lowered == "all" || lowered.isEmpty || lowered == "everything" {
            let count = watches.count
            watches.removeAll()
            onChange?()
            return "stopped all \(count) watch\(count == 1 ? "" : "es")."
        }
        let words = lowered.split(separator: " ").filter { $0.count > 2 }
        let matching = watches.filter { watch in
            let haystack = (watch.what + " " + watch.targetName).lowercased()
            return haystack.contains(lowered) || words.contains { haystack.contains($0) }
        }
        guard !matching.isEmpty else { return "no watch matches that. \(listText())" }
        let matchingIDs = Set(matching.map(\.id))
        watches.removeAll { matchingIDs.contains($0.id) }
        onChange?()
        return "stopped watching: " + matching.map(\.what).joined(separator: ", ") + "."
    }

    func listText() -> String {
        guard !watches.isEmpty else { return "nothing is being watched." }
        return watches.enumerated().map { index, watch in
            let minutesLeft = max(0, Int(watch.endsAt.timeIntervalSinceNow / 60))
            return "\(index + 1). \(watch.what) (in \(watch.targetName), \(minutesLeft) min left)"
        }.joined(separator: "\n")
    }

    // MARK: - The loop

    private func startLoopIfNeeded() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.checkIntervalSeconds * 1_000_000_000))
                guard let self else { return }
                if self.watches.isEmpty {
                    self.loopTask = nil
                    return
                }
                for watch in self.watches where !watch.isChecking {
                    if Date() >= watch.endsAt {
                        self.timeRanOut(watch)
                        continue
                    }
                    watch.isChecking = true
                    Task { [weak self] in
                        await self?.check(watch)
                        watch.isChecking = false
                    }
                }
            }
        }
    }

    private func check(_ watch: Watch) async {
        guard watches.contains(where: { $0.id == watch.id }) else { return }
        if watch.kind == .downloadFinishes {
            checkDownloads(watch)
            return
        }

        guard let image = await captureImage(of: watch, maximumWidth: 320),
              let thumbnail = DottieWatchThumbnail(image: image) else {
            watch.missedCaptureCount += 1
            if watch.missedCaptureCount >= 5 {
                end(watch, title: "Stopped watching", text: "I lost sight of \(watch.targetName) (it closed or hid), so I stopped watching for: \(watch.what).", isAlert: false)
            }
            return
        }
        watch.missedCaptureCount = 0

        let now = Date()
        let changeSinceLastLook = watch.previousThumbnail.map { thumbnail.changedFraction(from: $0) } ?? 0
        if changeSinceLastLook > Self.movedPixelFraction {
            watch.lastChangeAt = now
            watch.hasSeenMovement = true
        }
        watch.previousThumbnail = thumbnail
        let changeSinceStart = watch.baselineThumbnail.map { thumbnail.changedFraction(from: $0) } ?? 0

        switch watch.kind {
        case .changes:
            // Two looks in a row, so a passing tooltip or cursor blink doesn't count.
            watch.consecutiveChangedChecks = changeSinceStart > 0.03 ? watch.consecutiveChangedChecks + 1 : 0
            if watch.consecutiveChangedChecks >= 2 {
                fire(watch, note: "\(watch.targetName) changed.")
            }
        case .stopsChanging:
            if watch.hasSeenMovement && now.timeIntervalSince(watch.lastChangeAt) >= 8 {
                fire(watch, note: "\(watch.targetName) has stopped changing.")
            }
        case .textAppears, .textDisappears:
            guard let text = watch.text else { return }
            let changeSinceLastRead = watch.lastReadThumbnail.map { thumbnail.changedFraction(from: $0) } ?? 1
            let isDueForRead = changeSinceLastRead > Self.movedPixelFraction || now.timeIntervalSince(watch.lastReadAt) > 30
            guard isDueForRead, now.timeIntervalSince(watch.lastReadAt) >= 3 else { return }
            let isShowingNow = await isShowing(text, in: watch)
            watch.lastReadThumbnail = thumbnail
            watch.lastReadAt = Date()
            if watch.kind == .textAppears && isShowingNow {
                fire(watch, note: "it says \"\(text)\" now.")
            } else if watch.kind == .textDisappears {
                if isShowingNow {
                    watch.hasSeenText = true
                } else if watch.hasSeenText {
                    fire(watch, note: "\"\(text)\" is gone now.")
                }
            }
        case .looksLike:
            let changeSinceModelLook = watch.lastModelThumbnail.map { thumbnail.changedFraction(from: $0) } ?? 1
            guard changeSinceModelLook > Self.meaningfulChangeFraction,
                  now.timeIntervalSince(watch.lastModelCheckAt) >= Self.modelCheckMinimumSeconds,
                  now.timeIntervalSince(lastModelCallAt) >= Self.modelCallSpacingSeconds else { return }
            // Wait for the picture to settle, so a half-drawn frame isn't judged.
            guard changeSinceLastLook < Self.meaningfulChangeFraction else { return }
            lastModelCallAt = now
            watch.lastModelCheckAt = now
            watch.lastModelThumbnail = thumbnail
            guard let largerImage = await captureImage(of: watch, maximumWidth: 1024),
                  let answer = await askModel(whether: watch, image: largerImage) else { return }
            if answer.isMet {
                fire(watch, note: answer.note)
            }
        case .downloadFinishes:
            break
        }
    }

    private func fire(_ watch: Watch, note: String) {
        let what = watch.what.prefix(1).uppercased() + watch.what.dropFirst()
        end(watch, title: "Heads up!", text: "\(what): \(note)", isAlert: true)
    }

    private func timeRanOut(_ watch: Watch) {
        let minutes = max(1, Int(watch.endsAt.timeIntervalSince(watch.startedAt) / 60))
        end(watch, title: "Stopped watching", text: "Waited \(minutes) min for: \(watch.what). It didn't happen, so I stopped.", isAlert: false)
    }

    private func end(_ watch: Watch, title: String, text: String, isAlert: Bool) {
        guard watches.contains(where: { $0.id == watch.id }) else { return }
        watches.removeAll { $0.id == watch.id }
        onChange?()
        DottieEveryday.shared.tell(
            title: title,
            text: text,
            sound: isAlert ? NSSound.Name("Glass") : nil,
            notification: true,
            phone: isAlert
        )
    }

    // MARK: - Downloads

    private func checkDownloads(_ watch: Watch) {
        let inProgress = Self.inProgressDownloads()
        if !inProgress.isEmpty {
            watch.downloadsSeenInProgress.formUnion(inProgress)
            return
        }
        guard !watch.downloadsSeenInProgress.isEmpty else { return }
        if let finishedName = Self.newestDownload(since: watch.startedAt.addingTimeInterval(-3600)) {
            fire(watch, note: "finished downloading \(finishedName).")
        } else {
            fire(watch, note: "the download is done.")
        }
    }

    private static var downloadsFolder: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private static func inProgressDownloads() -> Set<String> {
        guard let downloadsFolder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: downloadsFolder.path) else { return [] }
        return Set(names.filter { inProgressDownloadExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
    }

    private static func newestDownload(since date: Date) -> String? {
        guard let downloadsFolder,
              let fileURLs = try? FileManager.default.contentsOfDirectory(
                at: downloadsFolder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }
        return fileURLs
            .filter { !inProgressDownloadExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { fileURL -> (String, Date)? in
                guard let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= date else { return nil }
                return (fileURL.lastPathComponent, modified)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: - What to watch

    private func resolveTarget(kind: Kind, targetName: String, appName: String?) -> (Target, String)? {
        if kind == .downloadFinishes {
            return (.downloadsFolder, "Downloads")
        }
        switch targetName {
        case "app":
            guard let appName, let application = Self.runningApplication(named: appName) else { return nil }
            return (.app(application.processIdentifier), application.localizedName ?? appName)
        case "screen":
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
            let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            return (.screen(displayID), "the screen")
        default:
            guard let frontWindow = Self.frontWindow() else { return nil }
            return (.window(frontWindow.id), frontWindow.name)
        }
    }

    private static func runningApplication(named name: String) -> NSRunningApplication? {
        let loweredName = name.lowercased()
        let candidates = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return candidates.first { $0.localizedName?.lowercased() == loweredName }
            ?? candidates.first { $0.localizedName?.lowercased().contains(loweredName) == true }
            ?? candidates.first { loweredName.contains($0.localizedName?.lowercased() ?? "\u{0}") }
    }

    /// The topmost normal window of the app in front that isn't Dottie.
    private static func frontWindow() -> (id: CGWindowID, name: String)? {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let frontProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var firstOtherWindow: (id: CGWindowID, name: String)?
        for windowInfo in windowList {
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? -1
            let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? Int32 ?? -1
            guard layer == 0, ownerProcessID != ownProcessID,
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? Int else { continue }
            let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width > 50, height > 50 else { continue }
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? "the window"
            let found = (id: CGWindowID(windowNumber), name: "\(ownerName)'s window")
            if ownerProcessID == frontProcessID { return found }
            if firstOtherWindow == nil { firstOtherWindow = found }
        }
        return firstOtherWindow
    }

    // MARK: - Looking

    private func captureImage(of watch: Watch, maximumWidth: CGFloat) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let filter: SCContentFilter
            let sourceSize: CGSize
            switch watch.target {
            case .window(let windowID):
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
                filter = SCContentFilter(desktopIndependentWindow: window)
                sourceSize = window.frame.size
            case .app(let processIdentifier):
                let appWindows = content.windows.filter {
                    $0.owningApplication?.processID == processIdentifier && $0.windowLayer == 0 && $0.isOnScreen
                        && $0.frame.width > 50 && $0.frame.height > 50
                }
                guard let window = appWindows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
                filter = SCContentFilter(desktopIndependentWindow: window)
                sourceSize = window.frame.size
            case .screen(let displayID):
                guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }
                let ownBundleIdentifier = Bundle.main.bundleIdentifier
                let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
                filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                sourceSize = CGSize(width: display.width, height: display.height)
            case .downloadsFolder:
                return nil
            }
            guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
            let scale = min(2, maximumWidth / sourceSize.width)
            let configuration = SCStreamConfiguration()
            configuration.width = max(16, Int(sourceSize.width * scale))
            configuration.height = max(16, Int(sourceSize.height * scale))
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    /// Reads the watched area with on-device text recognition.
    private func isShowing(_ text: String, in watch: Watch) async -> Bool {
        guard let image = await captureImage(of: watch, maximumWidth: 1800) else { return false }
        let wanted = Self.normalized(text)
        guard !wanted.isEmpty else { return false }
        let readText = await Task.detached(priority: .utility) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return "" }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
        return Self.normalized(readText).contains(wanted)
    }

    private func askModel(whether watch: Watch, image: CGImage) async -> (isMet: Bool, note: String)? {
        guard let jpegData = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return nil }
        let prompt = """
        The user asked to be told when this happens: "\(watch.what)". What to look for: "\(watch.text ?? watch.what)".
        This is a screenshot of \(watch.targetName) right now. Has it happened?
        Reply only with JSON: {"met": true or false, "note": "under 12 words on what you see"}
        """
        let requestBody: [String: Any] = [
            "model": Self.model,
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": ["responseMimeType": "application/json", "maxOutputTokens": 256]
        ]
        guard let answerText = await DottieChat.send(requestBody, timeout: 30),
              let jsonStart = answerText.firstIndex(of: "{"),
              let jsonEnd = answerText.lastIndex(of: "}"),
              let answer = try? JSONSerialization.jsonObject(with: Data(answerText[jsonStart...jsonEnd].utf8)) as? [String: Any] else {
            return nil
        }
        let isMet = (answer["met"] as? Bool) ?? ((answer["met"] as? String)?.lowercased() == "true")
        let note = (answer["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (isMet, note.isEmpty ? "it looks like it happened." : note)
    }

    nonisolated private static func normalized(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Thumbnails

/// A tiny grayscale copy of a picture, for cheap "did it change" checks.
struct DottieWatchThumbnail {
    private static let width = 64

    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        let thumbnailWidth = Self.width
        let thumbnailHeight = min(128, max(1, Int(Double(image.height) / Double(image.width) * Double(thumbnailWidth))))
        var thumbnailPixels = [UInt8](repeating: 0, count: thumbnailWidth * thumbnailHeight)
        let didDraw = thumbnailPixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: thumbnailWidth,
                height: thumbnailHeight,
                bitsPerComponent: 8,
                bytesPerRow: thumbnailWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailWidth, height: thumbnailHeight))
            return true
        }
        guard didDraw else { return nil }
        width = thumbnailWidth
        height = thumbnailHeight
        pixels = thumbnailPixels
    }

    /// The share of pixels that differ noticeably, 0 to 1.
    func changedFraction(from other: DottieWatchThumbnail) -> Double {
        guard width == other.width, height == other.height, !pixels.isEmpty else { return 1 }
        var changedCount = 0
        for index in pixels.indices where abs(Int(pixels[index]) - Int(other.pixels[index])) > 24 {
            changedCount += 1
        }
        return Double(changedCount) / Double(pixels.count)
    }
}
