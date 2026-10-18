//
//  DottieFocus.swift
//  leanring-buddy
//
//  Focus mode: for a set time, distracting apps and websites are blocked.
//  Switching to a blocked app hides it and brings back the app you came
//  from; opening a blocked site closes the tab. Each time, the notch shows
//  a cheeky line in Dottie's personality (written ahead of time, so no
//  model call) and how long is left. At the end: "45 min focused, you
//  tried YouTube 3 times."
//
//  The page you're on is read from the browser's window title first (free)
//  and, for browsers Dottie can script, from the tab's address.
//

import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation

@MainActor
final class DottieFocus: ObservableObject {
    enum EndReason {
        case timeUp
        case stoppedByUser
    }

    nonisolated static let statusLineID = "focus"
    nonisolated static let blockedAppsDefaultsKey = "dottieFocusBlockedApps"
    nonisolated static let blockedSitesDefaultsKey = "dottieFocusBlockedSites"
    nonisolated static let blocksGamesDefaultsKey = "dottieFocusBlocksGames"
    nonisolated static let defaultMinutesDefaultsKey = "dottieFocusDefaultMinutes"
    private static let sessionDefaultsKey = "dottieFocusSession"

    static let defaultBlockedApps = "Steam, Epic Games Launcher, Battle.net, Roblox, Minecraft, League of Legends, TikTok"
    static let defaultBlockedSites = "youtube.com, tiktok.com, instagram.com, facebook.com, x.com, twitter.com, reddit.com, netflix.com, twitch.tv"

    /// Names people say, and the sites they mean.
    private static let knownSites: [String: String] = [
        "youtube": "youtube.com", "tiktok": "tiktok.com", "instagram": "instagram.com", "insta": "instagram.com",
        "facebook": "facebook.com", "twitter": "x.com", "x": "x.com", "reddit": "reddit.com", "netflix": "netflix.com",
        "twitch": "twitch.tv", "discord": "discord.com", "pinterest": "pinterest.com", "linkedin": "linkedin.com",
        "snapchat": "snapchat.com", "hacker news": "news.ycombinator.com", "amazon": "amazon.com", "9gag": "9gag.com"
    ]

    /// Browsers whose current tab address can be read with AppleScript.
    private static let scriptableBrowsers: [String: (appName: String, isSafari: Bool)] = [
        "com.apple.Safari": ("Safari", true),
        "com.google.Chrome": ("Google Chrome", false),
        "com.brave.Browser": ("Brave Browser", false),
        "com.microsoft.edgemac": ("Microsoft Edge", false),
        "com.vivaldi.Vivaldi": ("Vivaldi", false),
        "company.thebrowser.Browser": ("Arc", false)
    ]

    @Published private(set) var isActive = false
    @Published private(set) var endsAt: Date?
    private var startedAt: Date?
    private var blockedApps: [String] = []
    private var blockedSites: [String] = []
    private var blocksGames = true
    /// How many times each blocked thing was tried, by its display name.
    private var attempts: [String: Int] = [:]
    private var lastBlockedAt: [String: Date] = [:]
    private var previousAllowedApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var tickTimer: Timer?
    private var isCheckingBrowser = false
    private var roastIndex = Int.random(in: 0..<100)

    /// The notch's status line and badge need refreshing.
    var onChange: (() -> Void)?

    static var defaultMinutes: Int {
        let saved = UserDefaults.standard.integer(forKey: defaultMinutesDefaultsKey)
        return saved > 0 ? saved : 25
    }

    var minutesLeft: Int {
        guard let endsAt else { return 0 }
        return max(0, Int((endsAt.timeIntervalSinceNow / 60).rounded(.up)))
    }

    var statusLine: NotchStatusLine? {
        guard isActive else { return nil }
        let triedCount = attempts.values.reduce(0, +)
        let triedText = triedCount == 0 ? "" : " · blocked \(triedCount)×"
        return NotchStatusLine(id: Self.statusLineID, symbolName: "moon.fill", text: "focus: \(minutesLeft) min left\(triedText)")
    }

    var compactBadgeText: String? {
        isActive ? "\(minutesLeft)m" : nil
    }

    // MARK: - Starting and stopping

    func start(minutes requestedMinutes: Double?, block blockList: [String]) -> String {
        let minutes = min(600, max(1, requestedMinutes ?? Double(Self.defaultMinutes)))
        if blockList.isEmpty {
            blockedApps = Self.list(UserDefaults.standard.string(forKey: Self.blockedAppsDefaultsKey) ?? Self.defaultBlockedApps)
            blockedSites = Self.list(UserDefaults.standard.string(forKey: Self.blockedSitesDefaultsKey) ?? Self.defaultBlockedSites)
            blocksGames = UserDefaults.standard.object(forKey: Self.blocksGamesDefaultsKey) as? Bool ?? true
        } else {
            (blockedApps, blockedSites) = Self.split(blockList)
            blocksGames = blockList.contains { $0.lowercased().contains("game") }
        }
        let wasActive = isActive
        startedAt = wasActive ? (startedAt ?? Date()) : Date()
        endsAt = Date().addingTimeInterval(minutes * 60)
        if !wasActive { attempts = [:] }
        isActive = true
        saveSession()
        startWatching()
        onChange?()
        // Whatever is in front right now might already be blocked.
        checkFrontmostApp()

        let blockedSummary = (blockedSites.prefix(4) + blockedApps.prefix(3)).joined(separator: ", ")
        return "focus mode is on for \(Int(minutes)) minutes, blocking \(blockedSummary)\(blocksGames ? " and games" : ""). the notch shows the countdown. cheer them on in one line."
    }

    @discardableResult
    func stop(reason: EndReason) -> String {
        guard isActive else { return "focus mode isn't on." }
        let focusedMinutes = max(1, Int((Date().timeIntervalSince(startedAt ?? Date()) / 60).rounded()))
        let summary = summaryText(focusedMinutes: focusedMinutes)
        isActive = false
        endsAt = nil
        startedAt = nil
        stopWatching()
        UserDefaults.standard.removeObject(forKey: Self.sessionDefaultsKey)
        onChange?()
        DottieEveryday.shared.tell(
            title: reason == .timeUp ? "Focus done 🎉" : "Focus stopped",
            text: summary,
            sound: reason == .timeUp ? NSSound.Name("Hero") : nil,
            notification: reason == .timeUp
        )
        return "focus mode ended. summary: \(summary) say it in your own words."
    }

    func statusText() -> String {
        guard isActive else { return "focus mode is off." }
        let triedText = attempts.isEmpty ? "nothing tried yet" : attempts.map { "\($0.key) \($0.value)×" }.joined(separator: ", ")
        return "focus mode is on: \(minutesLeft) min left. blocked attempts: \(triedText)."
    }

    private func summaryText(focusedMinutes: Int) -> String {
        guard !attempts.isEmpty else {
            return "\(focusedMinutes) min focused, and you didn't try a single distraction. Nice."
        }
        let tries = attempts.sorted { $0.value > $1.value }.prefix(3).map { name, count in
            "\(name) \(count == 1 ? "once" : "\(count) times")"
        }
        return "\(focusedMinutes) min focused. You tried \(Self.joinedList(tries))."
    }

    /// After a relaunch, a session that hasn't ended carries on.
    func restoreSessionIfRunning() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.sessionDefaultsKey),
              let endsAtInterval = saved["endsAt"] as? Double else { return }
        let savedEndsAt = Date(timeIntervalSince1970: endsAtInterval)
        guard savedEndsAt > Date() else {
            UserDefaults.standard.removeObject(forKey: Self.sessionDefaultsKey)
            return
        }
        startedAt = (saved["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        endsAt = savedEndsAt
        blockedApps = saved["apps"] as? [String] ?? []
        blockedSites = saved["sites"] as? [String] ?? []
        blocksGames = saved["games"] as? Bool ?? true
        attempts = saved["attempts"] as? [String: Int] ?? [:]
        isActive = true
        startWatching()
        onChange?()
    }

    private func saveSession() {
        guard isActive, let startedAt, let endsAt else { return }
        UserDefaults.standard.set([
            "startedAt": startedAt.timeIntervalSince1970,
            "endsAt": endsAt.timeIntervalSince1970,
            "apps": blockedApps,
            "sites": blockedSites,
            "games": blocksGames,
            "attempts": attempts
        ], forKey: Self.sessionDefaultsKey)
    }

    // MARK: - Watching

    private func startWatching() {
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkFrontmostApp()
                }
            }
        }
        if tickTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
    }

    private func stopWatching() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isActive else { return }
        if let endsAt, Date() >= endsAt {
            stop(reason: .timeUp)
            return
        }
        onChange?()
        checkFrontmostBrowserPage()
    }

    private func checkFrontmostApp() {
        guard isActive, let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        if let blockedName = blockedName(for: application) {
            block(application: application, named: blockedName)
            return
        }
        previousAllowedApp = application
        checkFrontmostBrowserPage()
    }

    private func blockedName(for application: NSRunningApplication) -> String? {
        let appName = application.localizedName ?? ""
        let loweredAppName = appName.lowercased()
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        if blockedApps.contains(where: { blocked in
            let loweredBlocked = blocked.lowercased()
            return loweredBlocked == loweredAppName || loweredBlocked == bundleIdentifier
        }) {
            return appName
        }
        if blocksGames, let bundleURL = application.bundleURL,
           let category = Bundle(url: bundleURL)?.infoDictionary?["LSApplicationCategoryType"] as? String,
           category.lowercased().contains("games") {
            return appName
        }
        return nil
    }

    private func block(application: NSRunningApplication, named name: String) {
        guard registerAttempt(name) else { return }
        application.hide()
        if let previousAllowedApp, !previousAllowedApp.isTerminated, previousAllowedApp != application {
            previousAllowedApp.activate()
        }
        showRoast(about: name)
    }

    /// Counts a try at most once every few seconds, since hiding an app or
    /// closing a tab fires more events.
    private func registerAttempt(_ name: String) -> Bool {
        if let lastTime = lastBlockedAt[name], Date().timeIntervalSince(lastTime) < 4 { return false }
        lastBlockedAt[name] = Date()
        attempts[name, default: 0] += 1
        saveSession()
        onChange?()
        return true
    }

    // MARK: - Browser pages

    private func checkFrontmostBrowserPage() {
        guard isActive, !blockedSites.isEmpty, !isCheckingBrowser,
              let application = NSWorkspace.shared.frontmostApplication,
              DottieBrowser.isBrowser(bundleIdentifier: application.bundleIdentifier) else { return }

        // The window title is free to read and usually names the site.
        if let windowTitle = Self.focusedWindowTitle(of: application), let site = siteMatchingTitle(windowTitle) {
            closeBlockedPage(in: application, site: site)
            return
        }
        guard let bundleIdentifier = application.bundleIdentifier,
              let browser = Self.scriptableBrowsers[bundleIdentifier] else { return }
        isCheckingBrowser = true
        Task { [weak self] in
            let script = browser.isSafari
                ? "tell application \"Safari\" to return URL of current tab of front window"
                : "tell application \"\(browser.appName)\" to return URL of active tab of front window"
            let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 5)
            guard let self else { return }
            self.isCheckingBrowser = false
            guard result.exitCode == 0,
                  let host = URL(string: result.output.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
                  let site = self.blockedSites.first(where: { host == $0 || host.hasSuffix("." + $0) }),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return }
            self.closeBlockedPage(in: application, site: site)
        }
    }

    /// A blocked site whose name is in the window title ("YouTube").
    /// Short names like x.com are left to the address check.
    private func siteMatchingTitle(_ windowTitle: String) -> String? {
        let loweredTitle = windowTitle.lowercased()
        return blockedSites.first { site in
            let siteName = site.split(separator: ".").first.map(String.init) ?? site
            guard siteName.count >= 5 else { return false }
            return loweredTitle.contains(siteName)
        }
    }

    private func closeBlockedPage(in application: NSRunningApplication, site: String) {
        let displayName = Self.displayName(forSite: site)
        guard registerAttempt(displayName) else { return }
        if let bundleIdentifier = application.bundleIdentifier, let browser = Self.scriptableBrowsers[bundleIdentifier] {
            let script: String
            if browser.isSafari {
                script = "tell application \"Safari\" to close current tab of front window"
            } else if browser.appName == "Arc" {
                script = "tell application \"Arc\" to tell front window to tell active tab to close"
            } else {
                script = "tell application \"\(browser.appName)\" to close active tab of front window"
            }
            Task {
                let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 5)
                if result.exitCode != 0 { Self.postCommandW() }
            }
        } else {
            Self.postCommandW()
        }
        showRoast(about: displayName)
    }

    private static func postCommandW() {
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_W)
        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        keyDownEvent?.flags = .maskCommand
        keyUpEvent?.flags = .maskCommand
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }

    private static func focusedWindowTitle(of application: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success else { return nil }
        return titleValue as? String
    }

    // MARK: - Roasts

    private func showRoast(about name: String) {
        let lines = Self.roastLines(for: DottieEveryday.shared.personality)
        roastIndex += 1
        let line = lines[roastIndex % lines.count]
            .replacingOccurrences(of: "{thing}", with: name)
            .replacingOccurrences(of: "{minutes}", with: "\(minutesLeft)")
        DottieEveryday.shared.tell(
            title: "Focus · \(minutesLeft) min left",
            text: line,
            actionLabel: "End focus",
            action: { [weak self] in _ = self?.stop(reason: .stoppedByUser) }
        )
    }

    private static func roastLines(for personality: DottiePersonality) -> [String] {
        switch personality {
        case .cheekyFriend:
            return [
                "{thing}? Bold. Not today, though. {minutes} minutes to go.",
                "Nice try. {thing} will still be there in {minutes} minutes, I promise.",
                "Caught you sneaking off to {thing}. Back to it, you're doing great.",
                "{thing} called. I hung up. {minutes} minutes left.",
                "Oh, we're doing {thing} now? We are not. Eyes front.",
                "I closed {thing} for you. You're welcome. {minutes} more minutes."
            ]
        case .patientTutor:
            return [
                "Let's leave {thing} for later. Only {minutes} minutes to go, you've got this.",
                "That's {thing}, and it can wait. Take a breath and pick up where you were.",
                "Distractions happen. {thing} is closed; back to your work for {minutes} more minutes.",
                "You're doing well. {thing} will be a nice reward when the timer ends."
            ]
        case .hypeBuddy:
            return [
                "Nope! No {thing} right now, you're on a roll! {minutes} minutes left, let's go!",
                "{thing} can wait, champ! Finish strong, {minutes} minutes to glory!",
                "Blocked {thing}! You're crushing this, keep going!",
                "Stay locked in! {thing} is for the victory lap in {minutes} minutes!"
            ]
        case .deadpan:
            return [
                "{thing}. Shocking. Closed. {minutes} minutes left.",
                "Ah yes, {thing}, the famous productivity tool. No.",
                "I see you tried {thing} again. I've made a note of it. {minutes} minutes.",
                "{thing} is not work. I checked."
            ]
        }
    }

    // MARK: - Lists

    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Sorts what the user named into apps and sites. Known names
    /// ("YouTube") become their site; a name with a dot is a site; anything
    /// else is an app (and its site too, when it has a well-known one).
    private static func split(_ names: [String]) -> (apps: [String], sites: [String]) {
        var apps: [String] = []
        var sites: [String] = []
        for name in names {
            let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lowered.isEmpty, lowered != "games", lowered != "all games" else { continue }
            if let knownSite = knownSites[lowered] {
                sites.append(knownSite)
                if lowered == "discord" || lowered == "tiktok" { apps.append(name) }
            } else if lowered.contains(".") && !lowered.contains(" ") {
                sites.append(lowered.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "")
                    .split(separator: "/").first.map(String.init) ?? lowered)
            } else {
                apps.append(name)
            }
        }
        return (apps, sites)
    }

    private static func displayName(forSite site: String) -> String {
        if site == "x.com" || site == "twitter.com" { return "X" }
        if site == "news.ycombinator.com" { return "Hacker News" }
        let name = site.split(separator: ".").first.map(String.init) ?? site
        let specialNames = ["youtube": "YouTube", "tiktok": "TikTok", "linkedin": "LinkedIn"]
        return specialNames[name] ?? name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func joinedList(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }
}
