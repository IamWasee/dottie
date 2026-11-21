//
//  AppMemoryTests.swift
//  leanring-buddyTests
//
//  Dottie's memory of the user's apps: page keys, full-view windows, the
//  text nearest a click, counting a click again, picking a remembered
//  click for a task (and refusing unsafe ones), trimming old pages, and a
//  page surviving a save and load.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

struct AppMemoryTests {
    private typealias Plan = DottieAppMemoryPlan

    private func click(_ label: String, to resultPageKey: String, timesSeen: Int = 1, lastSeen: Date = Date()) -> DottieAppPage.Click {
        DottieAppPage.Click(label: label, centerX: 100, centerY: 200, resultPageKey: resultPageKey,
                            resultPageTitle: resultPageKey, timesSeen: timesSeen, lastSeen: lastSeen)
    }

    private func page(_ key: String, clicks: [DottieAppPage.Click] = [], lastSeen: Date = Date()) -> DottieAppPage {
        DottieAppPage(key: key, title: key, elements: [], clicks: clicks, lastSeen: lastSeen, screenshotFileName: nil)
    }

    // MARK: Page keys

    @Test func pageKeyIgnoresUnreadCounts() {
        let firstKey = Plan.pageKey(bundleIdentifier: "com.google.Chrome", siteHost: "youtube.com", windowTitle: "(3) YouTube")
        let secondKey = Plan.pageKey(bundleIdentifier: "com.google.Chrome", siteHost: "youtube.com", windowTitle: "(12) YouTube")
        #expect(firstKey == secondKey)
    }

    @Test func pageKeySeparatesSitesAndApps() {
        let youTube = Plan.pageKey(bundleIdentifier: "com.google.Chrome", siteHost: "youtube.com", windowTitle: "Home")
        let gitHub = Plan.pageKey(bundleIdentifier: "com.google.Chrome", siteHost: "github.com", windowTitle: "Home")
        let safari = Plan.pageKey(bundleIdentifier: "com.apple.Safari", siteHost: "youtube.com", windowTitle: "Home")
        #expect(youTube != gitHub)
        #expect(youTube != safari)
    }

    @Test func pageKeyWithNoTitleOrSiteStillWorks() {
        #expect(Plan.pageKey(bundleIdentifier: "Com.Apple.Finder", siteHost: nil, windowTitle: nil) == "com.apple.finder||")
    }

    @Test func cleanedTitleKeepsEightWordsLowercased() {
        #expect(Plan.cleanedTitle("One Two Three Four Five Six Seven Eight Nine") == "one two three four five six seven eight")
        #expect(Plan.cleanedTitle("Inbox (42) — Mail") == "inbox mail")
    }

    // MARK: Full view

    @Test func aWindowFillingTheScreenIsFullView() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(Plan.isFullView(windowFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), displayFrame: display))
    }

    @Test func aHalfScreenWindowIsNotFullView() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(!Plan.isFullView(windowFrame: CGRect(x: 0, y: 0, width: 756, height: 982), displayFrame: display))
    }

    @Test func aWindowOnAnotherDisplayIsNotFullView() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(!Plan.isFullView(windowFrame: CGRect(x: 2000, y: 0, width: 1512, height: 982), displayFrame: display))
        #expect(!Plan.isFullView(windowFrame: display, displayFrame: .zero))
    }

    // MARK: Nearest text

    @Test func nearestTextWithinReachIsFound() {
        let elements = [
            DottieAppPage.Element(label: "Library", centerX: 100, centerY: 300),
            DottieAppPage.Element(label: "Home", centerX: 100, centerY: 200)
        ]
        #expect(Plan.element(nearestTo: 105, 210, in: elements)?.label == "Home")
    }

    @Test func textTooFarFromTheClickIsNotUsed() {
        let elements = [DottieAppPage.Element(label: "Home", centerX: 100, centerY: 200)]
        #expect(Plan.element(nearestTo: 500, 500, in: elements) == nil)
    }

    // MARK: Noting clicks

    @Test func theSameClickCountsUpAndMovesToItsNewSpot() {
        var memoryPage = page("home", clicks: [click("Subscriptions", to: "subs")])
        let movedClick = DottieAppPage.Click(label: "subscriptions", centerX: 120, centerY: 220, resultPageKey: "subs",
                                             resultPageTitle: "Subscriptions", timesSeen: 1, lastSeen: Date())
        memoryPage = Plan.page(memoryPage, noting: movedClick)
        #expect(memoryPage.clicks.count == 1)
        #expect(memoryPage.clicks[0].timesSeen == 2)
        #expect(memoryPage.clicks[0].centerX == 120)
    }

    @Test func aClickLeadingSomewhereElseIsKeptSeparately() {
        let memoryPage = Plan.page(page("home", clicks: [click("Library", to: "library")]), noting: click("Library", to: "history"))
        #expect(memoryPage.clicks.count == 2)
    }

    @Test func onlyTheNewestClicksAreKept() {
        var memoryPage = page("home")
        for clickNumber in 0..<(Plan.maximumClicksPerPage + 10) {
            memoryPage = Plan.page(memoryPage, noting: click("Button \(clickNumber)", to: "page \(clickNumber)",
                                                         lastSeen: Date(timeIntervalSince1970: Double(clickNumber))))
        }
        #expect(memoryPage.clicks.count == Plan.maximumClicksPerPage)
        #expect(memoryPage.clicks.first?.label == "Button \(Plan.maximumClicksPerPage + 9)")
    }

    // MARK: Remembered clicks

    @Test func aRememberedClickTheTaskNamesIsPicked() {
        let memoryPage = page("home", clicks: [click("Subscriptions", to: "subs"), click("Library", to: "library")])
        let picked = Plan.rememberedClick(on: memoryPage, forTask: "open my subscriptions on youtube",
                                          visibleLabels: ["Home", "Subscriptions", "Library"], alreadyClickedLabels: [])
        #expect(picked?.label == "Subscriptions")
    }

    @Test func aRememberedClickNotOnScreenIsSkipped() {
        let memoryPage = page("home", clicks: [click("Subscriptions", to: "subs")])
        let picked = Plan.rememberedClick(on: memoryPage, forTask: "open my subscriptions",
                                          visibleLabels: ["Home"], alreadyClickedLabels: [])
        #expect(picked == nil)
    }

    @Test func aRememberedClickAlreadyMadeIsNotMadeAgain() {
        let memoryPage = page("home", clicks: [click("Subscriptions", to: "subs")])
        let picked = Plan.rememberedClick(on: memoryPage, forTask: "open my subscriptions",
                                          visibleLabels: ["Subscriptions"], alreadyClickedLabels: ["subscriptions"])
        #expect(picked == nil)
    }

    @Test func aClickMadeOnlyOfActionWordsIsNeverMadeFromMemory() {
        // "Search" led to results last time, but this time nothing is typed yet.
        let memoryPage = page("home", clicks: [click("Search", to: "results", timesSeen: 9)])
        let picked = Plan.rememberedClick(on: memoryPage, forTask: "search mr beast on youtube",
                                          visibleLabels: ["Search"], alreadyClickedLabels: [])
        #expect(picked == nil)
    }

    @Test func aClickTheTaskDoesNotNameIsSkipped() {
        let memoryPage = page("home", clicks: [click("Shorts", to: "shorts")])
        let picked = Plan.rememberedClick(on: memoryPage, forTask: "open my subscriptions",
                                          visibleLabels: ["Shorts"], alreadyClickedLabels: [])
        #expect(picked == nil)
    }

    @Test func aClickThatStayedOnTheSamePageIsSkipped() {
        let memoryPage = page("home", clicks: [click("Subscriptions", to: "home")])
        let picked = Plan.rememberedClick(on: memoryPage, forTask: "open my subscriptions",
                                          visibleLabels: ["Subscriptions"], alreadyClickedLabels: [])
        #expect(picked == nil)
    }

    @Test func theMostUsedRememberedClickWins() {
        let memoryPage = page("home", clicks: [
            click("Watch later", to: "later", timesSeen: 1),
            click("Later list", to: "later list", timesSeen: 5)
        ])
        let picked = Plan.rememberedClick(on: memoryPage, forTask: "open my watch later list",
                                          visibleLabels: ["Watch later", "Later list"], alreadyClickedLabels: [])
        #expect(picked?.label == "Later list")
    }

    // MARK: Trimming and storage

    @Test func oldestPagesAreDroppedPastTheLimit() {
        var pages: [String: DottieAppPage] = [:]
        for pageNumber in 0..<(Plan.maximumPagesPerApp + 5) {
            pages["page \(pageNumber)"] = page("page \(pageNumber)", lastSeen: Date(timeIntervalSince1970: Double(pageNumber)))
        }
        let trimmedPages = Plan.trimmed(pages)
        #expect(trimmedPages.count == Plan.maximumPagesPerApp)
        #expect(trimmedPages["page 0"] == nil)
        #expect(trimmedPages["page \(Plan.maximumPagesPerApp + 4)"] != nil)
    }

    @Test func screenshotNamesStayTheSameForAPage() {
        #expect(Plan.stableFileStem(for: "com.google.chrome|youtube.com|youtube") == Plan.stableFileStem(for: "com.google.chrome|youtube.com|youtube"))
        #expect(Plan.stableFileStem(for: "a") != Plan.stableFileStem(for: "b"))
        #expect(Plan.stableFileStem(for: "a").count == 16)
    }

    @Test func anAppsMemorySurvivesSavingAndLoading() throws {
        let memoryFile = DottieAppMemoryFile(appName: "Chrome", pages: [
            "home": DottieAppPage(key: "home", title: "YouTube",
                                  elements: [DottieAppPage.Element(label: "Subscriptions", centerX: 40, centerY: 300)],
                                  clicks: [click("Subscriptions", to: "subs")],
                                  lastSeen: Date(timeIntervalSince1970: 1_000), screenshotFileName: "page-x.jpg")
        ])
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let fileURL = folderURL.appendingPathComponent("pages.json")
        #expect(DottieFileSaver.save(try JSONEncoder().encode(memoryFile), to: fileURL))
        #expect(DottieFileLoader.load(DottieAppMemoryFile.self, from: fileURL) == memoryFile)
    }
}
