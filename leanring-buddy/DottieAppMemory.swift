//
//  DottieAppMemory.swift
//  leanring-buddy
//
//  Dottie's memory of the user's apps, for the many apps with no API or
//  MCP server: each page of each app she has seen (a small screenshot and
//  where every piece of text sits when the window fills the screen) and
//  what clicking things there did ("Search" on YouTube's home page → the
//  results page). It fills itself quietly: one look when the front window
//  shows a page it hasn't seen (no model call, text read on the Mac), the
//  user's own clicks, and every screen job's clicks. Screen jobs then click
//  what worked before straight away instead of asking Jev again.
//  Stored per app in Application Support/Dottie/AppMemory/.
//

import AppKit
import ApplicationServices
import Carbon
import CryptoKit
import Foundation
import Vision

/// One page of one app, and what's on it. Foundation only, so the
/// matching is unit tested.
struct DottieAppPage: Codable, Equatable {
    struct Element: Codable, Equatable {
        /// The text as read on screen.
        let label: String
        /// Its middle, 0-1000 across and down the display.
        let centerX: Double
        let centerY: Double
    }

    struct Click: Codable, Equatable {
        let label: String
        let centerX: Double
        let centerY: Double
        /// The page the click opened, or this page's own key when it
        /// changed something without leaving the page.
        var resultPageKey: String
        var resultPageTitle: String
        var timesSeen: Int
        var lastSeen: Date
    }

    let key: String
    var title: String
    var elements: [Element]
    var clicks: [Click]
    var lastSeen: Date
    /// The screenshot's file name in the app's folder, when one was kept.
    var screenshotFileName: String?
}

/// What Dottie knows about one app.
struct DottieAppMemoryFile: Codable, Equatable {
    var appName: String
    var pages: [String: DottieAppPage]
}

/// The pure parts: page keys, matching labels, picking a remembered click.
enum DottieAppMemoryPlan {
    static let maximumPagesPerApp = 200
    static let maximumElementsPerPage = 120
    static let maximumClicksPerPage = 40
    /// A window covering this much of its display is "in full view", the
    /// only time positions are worth keeping (a smaller window moves).
    static let fullViewShare = 0.85
    /// Words that say what to do rather than where (see rememberedClick).
    static let actionWords: Set<String> = [
        "search", "open", "click", "go", "type", "find", "play", "watch", "show", "press", "tap",
        "enter", "submit", "ok", "next", "continue", "send", "the", "a", "on", "to", "my"
    ]

    /// One page's name: the app, the site for browsers, and the window
    /// title without counts ("(3) YouTube" and "(5) YouTube" are one page).
    static func pageKey(bundleIdentifier: String, siteHost: String?, windowTitle: String?) -> String {
        let cleanedTitle = cleanedTitle(windowTitle ?? "")
        return [bundleIdentifier.lowercased(), (siteHost ?? "").lowercased(), cleanedTitle].joined(separator: "|")
    }

    static func cleanedTitle(_ windowTitle: String) -> String {
        let withoutCounts = windowTitle.replacingOccurrences(of: "\\(\\d+\\)|\\d+", with: " ", options: .regularExpression)
        return withoutCounts.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: " ")
    }

    static func isFullView(windowFrame: CGRect, displayFrame: CGRect) -> Bool {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return false }
        let coveredArea = windowFrame.intersection(displayFrame)
        guard !coveredArea.isNull else { return false }
        return Double(coveredArea.width * coveredArea.height) / Double(displayFrame.width * displayFrame.height) >= fullViewShare
    }

    static func comparableWords(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The page's text nearest to where the user clicked, within reach.
    static func element(nearestTo centerX: Double, _ centerY: Double, in elements: [DottieAppPage.Element], within reach: Double = 40) -> DottieAppPage.Element? {
        elements
            .map { element in (element, hypot(element.centerX - centerX, element.centerY - centerY)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    /// Notes a click on a page: the same label again counts up and moves
    /// to where it was seen last; newest clicks are kept.
    static func page(_ page: DottieAppPage, noting click: DottieAppPage.Click) -> DottieAppPage {
        var updatedPage = page
        if let existingIndex = updatedPage.clicks.firstIndex(where: { comparableWords($0.label) == comparableWords(click.label) && $0.resultPageKey == click.resultPageKey }) {
            var existingClick = updatedPage.clicks[existingIndex]
            existingClick.timesSeen += 1
            existingClick.lastSeen = click.lastSeen
            existingClick.resultPageTitle = click.resultPageTitle
            updatedPage.clicks[existingIndex] = DottieAppPage.Click(
                label: click.label, centerX: click.centerX, centerY: click.centerY,
                resultPageKey: existingClick.resultPageKey, resultPageTitle: existingClick.resultPageTitle,
                timesSeen: existingClick.timesSeen, lastSeen: existingClick.lastSeen
            )
        } else {
            updatedPage.clicks.append(click)
        }
        updatedPage.clicks = Array(updatedPage.clicks.sorted { $0.lastSeen > $1.lastSeen }.prefix(maximumClicksPerPage))
        return updatedPage
    }

    /// A click that worked here before (it opened another page) and that
    /// the task names: its label's words are all in the task, and it's on
    /// the screen right now. Picked without asking a model.
    static func rememberedClick(
        on page: DottieAppPage,
        forTask taskText: String,
        visibleLabels: [String],
        alreadyClickedLabels: Set<String>
    ) -> DottieAppPage.Click? {
        let taskWords = Set(comparableWords(taskText).split(separator: " ").map(String.init))
        // A label made only of the task's action words ("Search", "Open")
        // isn't safe to click from memory: on YouTube's home page "Search"
        // led to results last time, but this time the words aren't typed yet.
        let visibleComparableLabels = Set(visibleLabels.map(comparableWords))
        return page.clicks
            .filter { click in
                let labelWords = comparableWords(click.label).split(separator: " ").map(String.init)
                return !labelWords.isEmpty
                    && labelWords.allSatisfy { taskWords.contains($0) }
                    && labelWords.contains { !actionWords.contains($0) }
                    && click.resultPageKey != page.key
                    && visibleComparableLabels.contains(comparableWords(click.label))
                    && !alreadyClickedLabels.contains(comparableWords(click.label))
            }
            .max { ($0.timesSeen, $0.lastSeen) < ($1.timesSeen, $1.lastSeen) }
    }

    /// A short name for a page's screenshot that stays the same between
    /// launches (Swift's hashValue changes every launch).
    static func stableFileStem(for pageKey: String) -> String {
        SHA256.hash(data: Data(pageKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the most recently seen pages when an app has too many.
    static func trimmed(_ pages: [String: DottieAppPage]) -> [String: DottieAppPage] {
        guard pages.count > maximumPagesPerApp else { return pages }
        let keptPages = pages.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(maximumPagesPerApp)
        return Dictionary(uniqueKeysWithValues: keptPages.map { ($0.key, $0) })
    }
}

/// The store and the quiet watcher.
@MainActor
final class DottieAppMemory {
    static let shared = DottieAppMemory()
    static let enabledDefaultsKey = "dottieAppMemoryEnabled"
    /// A page already seen gets a fresh look only after this long.
    private static let pageRefreshInterval: TimeInterval = 3 * 24 * 60 * 60
    private static let checkInterval: TimeInterval = 3

    /// On unless the user turned it off; everything stays on this Mac.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    private let folderURL: URL
    private var filesByBundleIdentifier: [String: DottieAppMemoryFile] = [:]
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var isLooking = false
    private var lastPageKey: String?
    /// The user's last click: where, on which page, and when, waiting to
    /// see which page it opens.
    private var pendingUserClick: (pageKey: String, bundleIdentifier: String, centerX: Double, centerY: Double, at: Date)?

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = applicationSupportURL.appendingPathComponent("Dottie/AppMemory", isDirectory: true)
    }

    // MARK: - Watching quietly

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in await DottieAppMemory.shared.lookAtFrontPage() }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            Task { @MainActor in DottieAppMemory.shared.noteUserClick(at: NSEvent.mouseLocation) }
        }
    }

    /// The front window as a page, or nil when Dottie shouldn't look.
    private func frontPage() -> (bundleIdentifier: String, appName: String, key: String, title: String, isFullView: Bool, displayFrame: CGRect)? {
        guard isEnabled, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let frontApplication = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontApplication.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let appName = frontApplication.localizedName ?? bundleIdentifier
        let excludedApps = UserDefaults.standard.stringArray(forKey: DottieScreenMemory.excludedAppsDefaultsKey) ?? DottieScreenMemory.defaultExcludedApps
        guard !excludedApps.contains(where: { $0.caseInsensitiveCompare(appName) == .orderedSame }) else { return nil }
        let context = DottieReplayContext.current()
        let applicationElement = AXUIElementCreateApplication(frontApplication.processIdentifier)
        guard let window = DottieAX.element(applicationElement, kAXFocusedWindowAttribute),
              let windowFrame = Self.globalFrame(of: window),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) else { return nil }
        let title = context.windowTitle ?? ""
        let key = DottieAppMemoryPlan.pageKey(bundleIdentifier: bundleIdentifier, siteHost: context.siteHost, windowTitle: title)
        let isFullView = DottieAppMemoryPlan.isFullView(windowFrame: windowFrame, displayFrame: screen.frame)
        return (bundleIdentifier, appName, key, title, isFullView, screen.frame)
    }

    private func lookAtFrontPage() async {
        guard !isLooking, let page = frontPage() else { return }
        let pageChanged = page.key != lastPageKey
        lastPageKey = page.key
        if pageChanged, let pendingUserClick, Date().timeIntervalSince(pendingUserClick.at) < 4 {
            noteClick(bundleIdentifier: pendingUserClick.bundleIdentifier, fromPageKey: pendingUserClick.pageKey,
                      centerX: pendingUserClick.centerX, centerY: pendingUserClick.centerY,
                      label: nil, toPageKey: page.key, toPageTitle: page.title)
            self.pendingUserClick = nil
        }
        guard pageChanged, page.isFullView else { return }
        let knownPage = file(for: page.bundleIdentifier, appName: page.appName).pages[page.key]
        if let knownPage, Date().timeIntervalSince(knownPage.lastSeen) < Self.pageRefreshInterval { return }
        isLooking = true
        defer { isLooking = false }
        guard let screenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1280) else { return }
        let elements = await Self.readElements(on: screenshot.image)
        notePage(bundleIdentifier: page.bundleIdentifier, appName: page.appName, key: page.key, title: page.title,
                 elements: elements, screenshotJPEG: screenshot.jpegData)
    }

    private func noteUserClick(at globalPoint: CGPoint) {
        guard let page = frontPage(), page.isFullView else { return }
        let display = page.displayFrame
        let centerX = Double((globalPoint.x - display.minX) / display.width) * 1000
        let centerY = Double((display.maxY - globalPoint.y) / display.height) * 1000
        pendingUserClick = (page.key, page.bundleIdentifier, centerX, centerY, Date())
    }

    // MARK: - What screen jobs use

    /// The page in front right now, when Dottie knows it.
    func knownFrontPage() -> DottieAppPage? {
        guard let page = frontPage() else { return nil }
        return file(for: page.bundleIdentifier, appName: page.appName).pages[page.key]
    }

    /// The front page's key and title, for noting a screen job's click.
    func frontPageIdentity() -> (bundleIdentifier: String, appName: String, key: String, title: String, isFullView: Bool)? {
        frontPage().map { ($0.bundleIdentifier, $0.appName, $0.key, $0.title, $0.isFullView) }
    }

    /// A screen job saw this page: keeps where its text sits (full view only).
    func notePageFromScreenJob(elements: [DottieAppPage.Element]) {
        guard let page = frontPage(), page.isFullView else { return }
        // Seen this minute already: skip the save, a screen job looks every step.
        if let knownPage = file(for: page.bundleIdentifier, appName: page.appName).pages[page.key],
           Date().timeIntervalSince(knownPage.lastSeen) < 60 { return }
        notePage(bundleIdentifier: page.bundleIdentifier, appName: page.appName, key: page.key, title: page.title,
                 elements: elements, screenshotJPEG: nil)
    }

    /// A click (the user's or a screen job's) and the page it led to.
    func noteClick(bundleIdentifier: String, fromPageKey: String, centerX: Double, centerY: Double,
                   label givenLabel: String?, toPageKey: String, toPageTitle: String) {
        guard isEnabled else { return }
        var appFile = file(for: bundleIdentifier, appName: bundleIdentifier)
        guard var page = appFile.pages[fromPageKey] else { return }
        let label = givenLabel ?? DottieAppMemoryPlan.element(nearestTo: centerX, centerY, in: page.elements)?.label
        guard let label, !label.isEmpty else { return }
        page = DottieAppMemoryPlan.page(page, noting: DottieAppPage.Click(
            label: label, centerX: centerX, centerY: centerY,
            resultPageKey: toPageKey, resultPageTitle: toPageTitle, timesSeen: 1, lastSeen: Date()
        ))
        appFile.pages[fromPageKey] = page
        save(appFile, bundleIdentifier: bundleIdentifier)
    }

    // MARK: - Storage

    private func notePage(bundleIdentifier: String, appName: String, key: String, title: String,
                          elements: [DottieAppPage.Element], screenshotJPEG: Data?) {
        var appFile = file(for: bundleIdentifier, appName: appName)
        appFile.appName = appName
        var page = appFile.pages[key] ?? DottieAppPage(key: key, title: title, elements: [], clicks: [], lastSeen: Date(), screenshotFileName: nil)
        page.title = title
        page.elements = Array(elements.prefix(DottieAppMemoryPlan.maximumElementsPerPage))
        page.lastSeen = Date()
        if let screenshotJPEG {
            let screenshotFileName = "page-\(DottieAppMemoryPlan.stableFileStem(for: key)).jpg"
            if DottieFileSaver.save(screenshotJPEG, to: appFolderURL(bundleIdentifier).appendingPathComponent(screenshotFileName)) {
                page.screenshotFileName = screenshotFileName
            }
        }
        appFile.pages[key] = page
        appFile.pages = DottieAppMemoryPlan.trimmed(appFile.pages)
        save(appFile, bundleIdentifier: bundleIdentifier)
    }

    private func file(for bundleIdentifier: String, appName: String) -> DottieAppMemoryFile {
        if let loadedFile = filesByBundleIdentifier[bundleIdentifier] { return loadedFile }
        let loadedFile = DottieFileLoader.load(DottieAppMemoryFile.self, from: fileURL(bundleIdentifier))
            ?? DottieAppMemoryFile(appName: appName, pages: [:])
        filesByBundleIdentifier[bundleIdentifier] = loadedFile
        return loadedFile
    }

    private func save(_ appFile: DottieAppMemoryFile, bundleIdentifier: String) {
        filesByBundleIdentifier[bundleIdentifier] = appFile
        try? FileManager.default.createDirectory(at: appFolderURL(bundleIdentifier), withIntermediateDirectories: true)
        guard let fileData = try? JSONEncoder().encode(appFile) else { return }
        _ = DottieFileSaver.save(fileData, to: fileURL(bundleIdentifier))
    }

    private func appFolderURL(_ bundleIdentifier: String) -> URL {
        folderURL.appendingPathComponent(bundleIdentifier.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private func fileURL(_ bundleIdentifier: String) -> URL {
        appFolderURL(bundleIdentifier).appendingPathComponent("pages.json")
    }

    // MARK: - Reading the screen on the Mac

    /// Every line of text on a screenshot with its middle in 0-1000.
    static func readElements(on image: CGImage) async -> [DottieAppPage.Element] {
        await Task.detached(priority: .utility) { () -> [DottieAppPage.Element] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                      (2...60).contains(text.count) else { return nil }
                let box = observation.boundingBox
                return DottieAppPage.Element(label: text, centerX: Double(box.midX) * 1000, centerY: Double(1 - box.midY) * 1000)
            }
        }.value
    }

    /// A window's frame in global AppKit coordinates (Accessibility gives
    /// top-left origin).
    private static func globalFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAXValue = DottieAccessibilityCast.axValue(positionValue),
              let sizeAXValue = DottieAccessibilityCast.axValue(sizeValue) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionAXValue, .cgPoint, &position)
        AXValueGetValue(sizeAXValue, .cgSize, &size)
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: position.x, y: mainScreenHeight - position.y - size.height, width: size.width, height: size.height)
    }
}
