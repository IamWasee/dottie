//
//  ScreenJobAppOpeningTests.swift
//  leanring-buddyTests
//
//  Which installed app a screen job opens for a name. In round 2 of 1.0.80
//  the quick step guess said "couldn't open that app" for Notes twice; the
//  opening now always goes through Launch Services, and the name matching
//  it relies on is checked here.
//

import Foundation
import Testing
@testable import Dottie

struct ScreenJobAppOpeningTests {
    private let installedNames = ["Notes", "Notion", "Opera GX", "Safari", "Visual Studio Code"]

    @Test func anExactNameWinsOverAnEarlierPrefix() {
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "Notes", among: installedNames) == "Notes")
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "no", among: installedNames) == "Notes")
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "Notes", among: ["Notes Helper", "Notes"]) == "Notes")
    }

    @Test func aNameIsMatchedWhateverItsCaseOrDotApp() {
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "notes", among: installedNames) == "Notes")
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "Notes.app", among: installedNames) == "Notes")
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "  SAFARI ", among: installedNames) == "Safari")
    }

    @Test func aStartOfTheNameFindsTheApp() {
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "opera", among: installedNames) == "Opera GX")
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "visual studio", among: installedNames) == "Visual Studio Code")
    }

    @Test func noFittingAppIsNil() {
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "Photoshop", among: installedNames) == nil)
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "", among: installedNames) == nil)
        #expect(DottieScreenTaskRunner.bestApplicationName(for: ".app", among: installedNames) == nil)
        #expect(DottieScreenTaskRunner.bestApplicationName(for: "Notes", among: []) == nil)
    }

    @Test func comparableNamesDropCaseSpacesAndDotApp() {
        #expect(DottieScreenTaskRunner.comparableApplicationName(" Notes.app ") == "notes")
        #expect(DottieScreenTaskRunner.comparableApplicationName("Opera GX") == "opera gx")
    }

    @Test func matchingAFullApplicationsFolderIsQuick() {
        let manyNames = (0..<400).map { "App Number \($0)" } + ["Notes"]
        let startTime = Date()
        for _ in 0..<200 {
            _ = DottieScreenTaskRunner.bestApplicationName(for: "Notes", among: manyNames)
        }
        #expect(Date().timeIntervalSince(startTime) < 1.0)
    }
}
