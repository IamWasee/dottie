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
//  Stored per app in Application Support/Dottie/AppMemory/. Runs only while
//  both the Brain ("Remember what's on my screen") and app memory are on.
//  The user's steps are kept as flows (what came after what) in each app's
//  flows.json; Jev and the step model read it all only when they ask
//  (DottieAppMemoryRecall).
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

    /// A button, link, field or icon the app names through Accessibility.
    struct Control: Codable, Equatable {
        let label: String
        let kind: String
        let centerX: Double
        let centerY: Double
    }

    let key: String
    var title: String
    var elements: [Element]
    var clicks: [Click]
    var lastSeen: Date
    /// The screenshot's file name in the app's folder, when one was kept.
    var screenshotFileName: String?
    /// Named controls (icons included), when Accessibility gave them.
    var controls: [Control]? = nil
    /// A smarter model's reading of the page (what each control does and
    /// which move uses it), made once, only when asked for.
    var smartDescription: String? = nil
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
        // Read the same first (cheap); then alike enough (counts, numbers
        // and dates left out, DottieLooseLabels).
        let visibleComparableLabels = Set(visibleLabels.map(comparableWords))
        func isVisible(_ clickLabel: String) -> Bool {
            visibleComparableLabels.contains(comparableWords(clickLabel))
                || visibleLabels.contains { DottieLooseLabels.similarity($0, clickLabel) >= DottieLooseLabels.sameControlScore }
        }
        return page.clicks
            .filter { click in
                let labelWords = comparableWords(click.label).split(separator: " ").map(String.init)
                return !labelWords.isEmpty
                    && labelWords.allSatisfy { taskWords.contains($0) }
                    && labelWords.contains { !actionWords.contains($0) }
                    && click.resultPageKey != page.key
                    && isVisible(click.label)
                    && !alreadyClickedLabels.contains(comparableWords(click.label))
            }
            .max { ($0.timesSeen, $0.lastSeen) < ($1.timesSeen, $1.lastSeen) }
    }

    /// Jev's click options on a remembered page, each noting what clicking
    /// it did before ("it opened \"Edit column\""): the remembered controls
    /// in Jev's own list instead of a page of text it can't use.
    static func optionsNotingRememberedClicks(_ options: [DottieJevDriverPlan.Option], on page: DottieAppPage) -> [DottieJevDriverPlan.Option] {
        let leadingClicks = page.clicks.filter { $0.resultPageKey != page.key }
            .map { (click: $0, words: Set(DottieLooseLabels.coreWords($0.label))) }
        guard !leadingClicks.isEmpty else { return options }
        return options.map { option -> DottieJevDriverPlan.Option in
            let clickedLabel: String?
            switch option.move {
            case .click(let label, _, _), .clickControl(let label, _, _, _), .doubleClick(let label, _, _): clickedLabel = label
            default: clickedLabel = nil
            }
            guard let clickedLabel else { return option }
            let clickedWords = Set(DottieLooseLabels.coreWords(clickedLabel))
            guard let rememberedClick = leadingClicks
                      .filter({ DottieLooseLabels.similarity($0.click.label, $0.words, clickedLabel, clickedWords) >= DottieLooseLabels.sameControlScore })
                      .max(by: { $0.click.timesSeen < $1.click.timesSeen })?.click else { return option }
            var notedOption = option
            notedOption.memoryNote = "Dottie clicked this here before and it opened \"\(rememberedClick.resultPageTitle)\""
            return notedOption
        }
    }

    /// Short lines on one app's or site's pages for its card: each page's
    /// title, the clicks that led on from it and a few of its controls.
    static func cardLines(pages: [DottieAppPage], siteHost: String?) -> [String] {
        let wantedHost = (siteHost ?? "").lowercased()
        let pagesOfPlace = pages.filter { page -> Bool in
            let keyParts = page.key.components(separatedBy: "|")
            return keyParts.count >= 2 && keyParts[1] == wantedHost
        }
        return pagesOfPlace.sorted { $0.lastSeen > $1.lastSeen }.prefix(12).map { page -> String in
            var line = "Page \"\(page.title)\""
            let leadingClicks = page.clicks.filter { $0.resultPageKey != page.key }.prefix(5)
            if !leadingClicks.isEmpty {
                line += "; clicking " + leadingClicks.map { "\"\($0.label)\" opens \"\($0.resultPageTitle)\"" }.joined(separator: ", ")
            }
            let controlNames = (page.controls ?? []).prefix(8).map { "\($0.kind) \"\($0.label)\"" }
            if !controlNames.isEmpty { line += "; controls: " + controlNames.joined(separator: ", ") }
            return line
        }
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

    /// App memory's own switch: on unless the user turned it off.
    var isSwitchedOn: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    /// Watching happens only while the Brain's "Remember what's on my
    /// screen" is on too (celly's rule); everything stays on this Mac.
    var isEnabled: Bool {
        isSwitchedOn && UserDefaults.standard.bool(forKey: DottieBrain.screenJournalDefaultsKey)
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
    private var keyMonitor: Any?
    /// The flow being recorded now, and its app.
    private var currentFlow: (bundleIdentifier: String, flow: DottieAppFlow, lastStepAt: Date)?
    private var flowsByBundleIdentifier: [String: [DottieAppFlow]] = [:]

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
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let shortcutText = DottieAppMemory.shortcutText(for: event)
            Task { @MainActor in DottieAppMemory.shared.noteUserKey(shortcutText: shortcutText) }
        }
    }

    /// "cmd+shift+t" for a key pressed with command, control or option,
    /// nil for plain typing (whose letters are never kept).
    nonisolated private static func shortcutText(for event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !modifiers.intersection([.command, .control, .option]).isEmpty,
              let keyCharacters = event.charactersIgnoringModifiers?.lowercased(), !keyCharacters.isEmpty else {
            return event.keyCode == 36 ? "return" : nil
        }
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(event.keyCode == 36 ? "return" : keyCharacters)
        return parts.joined(separator: "+")
    }

    /// The window in front, as a page of an app.
    struct FrontPage {
        let bundleIdentifier: String
        let appName: String
        let key: String
        let title: String
        let isFullView: Bool
        let displayFrame: CGRect
    }

    /// The front window as a page, or nil when Dottie shouldn't look. A
    /// screen job passes the step's own read of the front app (`context`),
    /// so a browser's window isn't walked again for its address.
    private func frontPage(context givenContext: DottieReplayContext? = nil) -> FrontPage? {
        guard isEnabled, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let frontApplication = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontApplication.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let appName = frontApplication.localizedName ?? bundleIdentifier
        let excludedApps = UserDefaults.standard.stringArray(forKey: DottieScreenMemory.excludedAppsDefaultsKey) ?? DottieScreenMemory.defaultExcludedApps
        guard !excludedApps.contains(where: { $0.caseInsensitiveCompare(appName) == .orderedSame }) else { return nil }
        let context = givenContext ?? DottieReplayContext.current()
        let applicationElement = AXUIElementCreateApplication(frontApplication.processIdentifier)
        guard let window = DottieAX.element(applicationElement, kAXFocusedWindowAttribute),
              let windowFrame = Self.globalFrame(of: window),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) else { return nil }
        let title = context.windowTitle ?? ""
        let key = DottieAppMemoryPlan.pageKey(bundleIdentifier: bundleIdentifier, siteHost: context.siteHost, windowTitle: title)
        let isFullView = DottieAppMemoryPlan.isFullView(windowFrame: windowFrame, displayFrame: screen.frame)
        return FrontPage(bundleIdentifier: bundleIdentifier, appName: appName, key: key, title: title,
                         isFullView: isFullView, displayFrame: screen.frame)
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
            if var recordingFlow = currentFlow, recordingFlow.bundleIdentifier == page.bundleIdentifier,
               let lastIndex = recordingFlow.flow.steps.indices.last, recordingFlow.flow.steps[lastIndex].action == .click {
                recordingFlow.flow.steps[lastIndex].resultPageTitle = page.title
                currentFlow = recordingFlow
            }
        }
        endFlowIfQuiet()
        guard pageChanged, page.isFullView else { return }
        let knownPage = file(for: page.bundleIdentifier, appName: page.appName).pages[page.key]
        if let knownPage, Date().timeIntervalSince(knownPage.lastSeen) < Self.pageRefreshInterval { return }
        isLooking = true
        defer { isLooking = false }
        guard let screenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1280) else { return }
        let elements = await Self.readElements(on: screenshot.image)
        let controls = DottieJevDriver.readControls(onDisplay: screenshot.displayFrame).map {
            DottieAppPage.Control(label: $0.label, kind: $0.kind, centerX: $0.centerX, centerY: $0.centerY)
        }
        // No screenshot is kept: only a close reading of the page uses one,
        // and it takes a fresh one then (most pages are never read closely).
        notePage(bundleIdentifier: page.bundleIdentifier, appName: page.appName, key: page.key, title: page.title,
                 elements: elements, controls: controls, screenshotJPEG: nil)
    }

    private func noteUserClick(at globalPoint: CGPoint) {
        guard let page = frontPage(), page.isFullView else { return }
        let display = page.displayFrame
        let centerX = Double((globalPoint.x - display.minX) / display.width) * 1000
        let centerY = Double((display.maxY - globalPoint.y) / display.height) * 1000
        pendingUserClick = (page.key, page.bundleIdentifier, centerX, centerY, Date())
        let knownPage = file(for: page.bundleIdentifier, appName: page.appName).pages[page.key]
        let nearestControl = (knownPage?.controls ?? []).first {
            abs($0.centerX - centerX) <= 25 && abs($0.centerY - centerY) <= 25
        }
        let nearestLabel = nearestControl?.label
            ?? knownPage.flatMap { DottieAppMemoryPlan.element(nearestTo: centerX, centerY, in: $0.elements)?.label }
        guard let nearestLabel else { return }
        noteFlowStep(DottieAppFlowStep(action: .click, pageTitle: page.title, label: nearestLabel, centerX: centerX, centerY: centerY),
                     bundleIdentifier: page.bundleIdentifier)
    }

    /// A shortcut is kept as it is; plain typing only as "typed into" the
    /// focused field's name. Never in password boxes (frontPage checks).
    private func noteUserKey(shortcutText: String?) {
        guard let page = frontPage() else { return }
        if let shortcutText {
            noteFlowStep(DottieAppFlowStep(action: .pressKeys, pageTitle: page.title, label: shortcutText, centerX: nil, centerY: nil),
                         bundleIdentifier: page.bundleIdentifier)
            return
        }
        guard let focusedFieldName = Self.focusedFieldName() else { return }
        noteFlowStep(DottieAppFlowStep(action: .typeInto, pageTitle: page.title, label: focusedFieldName, centerX: nil, centerY: nil),
                     bundleIdentifier: page.bundleIdentifier)
    }

    private static func focusedFieldName() -> String? {
        let systemElement = AXUIElementCreateSystemWide()
        guard let focusedElement = DottieAX.element(systemElement, kAXFocusedUIElementAttribute) else { return nil }
        for attributeName in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
            var attributeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedElement, attributeName as CFString, &attributeValue) == .success,
               let name = attributeValue as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(name.prefix(60))
            }
        }
        return "the text box"
    }

    // MARK: - Flows (what the user did, step after step)

    private func noteFlowStep(_ step: DottieAppFlowStep, bundleIdentifier: String) {
        guard isEnabled else { return }
        endFlowIfQuiet()
        if let recordingFlow = currentFlow, recordingFlow.bundleIdentifier != bundleIdentifier {
            endCurrentFlow()
        }
        let flow = currentFlow?.flow ?? DottieAppFlow(startedAt: Date(), steps: [])
        currentFlow = (bundleIdentifier, DottieAppMemoryRecallPlan.flow(flow, adding: step), Date())
    }

    private func endFlowIfQuiet() {
        if let recordingFlow = currentFlow,
           Date().timeIntervalSince(recordingFlow.lastStepAt) > DottieAppMemoryRecallPlan.secondsOfQuietThatEndAFlow {
            endCurrentFlow()
        }
    }

    private func endCurrentFlow() {
        guard let recordingFlow = currentFlow else { return }
        currentFlow = nil
        guard recordingFlow.flow.steps.count >= 2 else { return }
        let keptFlowList = DottieAppMemoryRecallPlan.keptFlows(flows(for: recordingFlow.bundleIdentifier) + [recordingFlow.flow])
        flowsByBundleIdentifier[recordingFlow.bundleIdentifier] = keptFlowList
        try? FileManager.default.createDirectory(at: appFolderURL(recordingFlow.bundleIdentifier), withIntermediateDirectories: true)
        guard let flowsData = try? JSONEncoder().encode(keptFlowList) else { return }
        _ = DottieFileSaver.save(flowsData, to: appFolderURL(recordingFlow.bundleIdentifier).appendingPathComponent("flows.json"))
    }

    private func flows(for bundleIdentifier: String) -> [DottieAppFlow] {
        if let loadedFlows = flowsByBundleIdentifier[bundleIdentifier] { return loadedFlows }
        let loadedFlows = DottieFileLoader.load([DottieAppFlow].self, from: appFolderURL(bundleIdentifier).appendingPathComponent("flows.json")) ?? []
        flowsByBundleIdentifier[bundleIdentifier] = loadedFlows
        return loadedFlows
    }

    // MARK: - Recall (only when Jev or the step model asks)

    /// Whether there's anything remembered about the app in front.
    func hasMemoryOfFrontApp() -> Bool {
        guard isSwitchedOn, let page = frontPage() else { return false }
        return !file(for: page.bundleIdentifier, appName: page.appName).pages.isEmpty || !flows(for: page.bundleIdentifier).isEmpty
    }

    /// What app memory knows that helps this job, read when asked. With
    /// `readsPageClosely`, a page never read before gets its one smart
    /// reading first (a smarter model looks at its screenshot).
    func recall(forTask taskText: String, readsPageClosely: Bool) async -> String {
        guard isSwitchedOn, let page = frontPage() else { return "" }
        if readsPageClosely { await readPageClosely(bundleIdentifier: page.bundleIdentifier, appName: page.appName, pageKey: page.key) }
        let appFile = file(for: page.bundleIdentifier, appName: page.appName)
        DottieLog.notice("🗂️ App memory recalled for a screen job")
        return DottieAppMemoryRecallPlan.summary(appName: page.appName, page: appFile.pages[page.key],
                                                 flows: flows(for: page.bundleIdentifier), taskText: taskText)
    }

    private func readPageClosely(bundleIdentifier: String, appName: String, pageKey: String) async {
        var appFile = file(for: bundleIdentifier, appName: appName)
        guard var page = appFile.pages[pageKey], page.smartDescription == nil else { return }
        let screenshotData: Data
        if let screenshotFileName = page.screenshotFileName,
           let savedData = try? Data(contentsOf: appFolderURL(bundleIdentifier).appendingPathComponent(screenshotFileName)) {
            screenshotData = savedData
        } else if let screenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1280) {
            screenshotData = screenshot.jpegData
        } else {
            return
        }
        guard let description = await Self.askSmarterModel(screenshotJPEG: screenshotData,
                                                           prompt: DottieAppMemoryRecallPlan.pageReadingPrompt(appName: appName, pageTitle: page.title)) else { return }
        appFile = file(for: bundleIdentifier, appName: appName)
        page = appFile.pages[pageKey] ?? page
        page.smartDescription = String(description.prefix(2500))
        appFile.pages[pageKey] = page
        save(appFile, bundleIdentifier: bundleIdentifier)
        DottieLog.notice("🗂️ A smarter model read a page of an app for app memory")
    }

    /// One picture and a question to Claude through the Worker (the
    /// "request" role), text back, or nil.
    private static func askSmarterModel(screenshotJPEG: Data, prompt: String) async -> String? {
        let requestBody: [String: Any] = [
            "provider": "request",
            "contents": [["role": "user", "parts": [
                ["inlineData": ["mimeType": "image/jpeg", "data": screenshotJPEG.base64EncodedString()]],
                ["text": prompt]
            ]]],
            "generationConfig": ["maxOutputTokens": 700]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        request.httpBody = bodyData
        do {
            let (answerData, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                DottieLog.warning("App memory's page reading wasn't answered")
                return nil
            }
            let answerText = GeminiServerSentEvents.text(from: answerData)
            return answerText.isEmpty ? nil : answerText
        } catch {
            DottieLog.warning("App memory's page reading failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - What screen jobs use

    /// The page in front right now, when Dottie knows it.
    func knownFrontPage() -> DottieAppPage? {
        frontPage().flatMap(knownPage(for:))
    }

    /// The front window as a page, read once per screen-job step from the
    /// step's own read of the front app (it used to be read up to four
    /// times a step, the app memory review found).
    func frontPageForScreenJob(context: DottieReplayContext) -> FrontPage? {
        frontPage(context: context)
    }

    /// What Dottie remembers about a page, when she's seen it.
    func knownPage(for frontPage: FrontPage) -> DottieAppPage? {
        file(for: frontPage.bundleIdentifier, appName: frontPage.appName).pages[frontPage.key]
    }

    /// The front page's key and title, for noting a screen job's click.
    func frontPageIdentity() -> (bundleIdentifier: String, appName: String, key: String, title: String, isFullView: Bool)? {
        frontPage().map { ($0.bundleIdentifier, $0.appName, $0.key, $0.title, $0.isFullView) }
    }

    /// A screen job saw this page: keeps where its text sits (full view only).
    func notePageFromScreenJob(on page: FrontPage, elements: [DottieAppPage.Element], controls: [DottieAppPage.Control] = []) {
        guard page.isFullView else { return }
        // Seen this minute already: skip the save, a screen job looks every step.
        if let knownPage = file(for: page.bundleIdentifier, appName: page.appName).pages[page.key],
           Date().timeIntervalSince(knownPage.lastSeen) < 60 { return }
        notePage(bundleIdentifier: page.bundleIdentifier, appName: page.appName, key: page.key, title: page.title,
                 elements: elements, controls: controls, screenshotJPEG: nil)
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

    /// What app memory saw in one app or site, as short lines for the
    /// card on how it works (DottieAppTasks).
    func cardMaterial(bundleIdentifier: String, siteHost: String?) -> [String] {
        let appFile = file(for: bundleIdentifier, appName: bundleIdentifier)
        return DottieAppMemoryPlan.cardLines(pages: Array(appFile.pages.values), siteHost: siteHost)
    }

    // MARK: - Storage

    private func notePage(bundleIdentifier: String, appName: String, key: String, title: String,
                          elements: [DottieAppPage.Element], controls: [DottieAppPage.Control], screenshotJPEG: Data?) {
        var appFile = file(for: bundleIdentifier, appName: appName)
        appFile.appName = appName
        var page = appFile.pages[key] ?? DottieAppPage(key: key, title: title, elements: [], clicks: [], lastSeen: Date(), screenshotFileName: nil)
        page.title = title
        page.elements = Array(elements.prefix(DottieAppMemoryPlan.maximumElementsPerPage))
        if !controls.isEmpty {
            page.controls = Array(controls.prefix(DottieAppMemoryPlan.maximumElementsPerPage))
        }
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
