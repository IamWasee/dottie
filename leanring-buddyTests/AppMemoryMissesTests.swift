//
//  AppMemoryMissesTests.swift
//  leanring-buddyTests
//
//  Wrong clicks remembered per page: a click that changed nothing is
//  noted, the click that worked next is kept as its fix, Jev's options
//  say so (or drop a click missed twice, never a text box), a click that
//  works later is forgiven, old pages still load, and it stays quick.
//

import Foundation
import Testing
@testable import Dottie

struct AppMemoryMissesTests {
    typealias Plan = DottieAppMemoryPlan

    private func page(misses: [DottieAppPage.Miss]? = nil) -> DottieAppPage {
        DottieAppPage(key: "openemr|localhost|patient", title: "Patient", elements: [], clicks: [], lastSeen: Date(),
                      screenshotFileName: nil, misses: misses)
    }

    private func miss(_ label: String, times: Int = 1, fix: String? = nil, daysAgo: Double = 0) -> DottieAppPage.Miss {
        DottieAppPage.Miss(label: label, centerX: 10, centerY: 10, timesMissed: times,
                           lastMissed: Date().addingTimeInterval(-daysAgo * 24 * 3600), fixLabel: fix)
    }

    private func clickOption(_ key: String, _ label: String) -> DottieJevDriverPlan.Option {
        DottieJevDriverPlan.Option(key: key, move: .click(label: label, centerX: 1, centerY: 1))
    }

    @Test func aMissIsNotedAndCountsUp() {
        var memoryPage = Plan.page(page(), notingMiss: miss("Add New"))
        memoryPage = Plan.page(memoryPage, notingMiss: miss("add new"))
        #expect(memoryPage.misses?.count == 1)
        #expect(memoryPage.misses?.first?.timesMissed == 2)
    }

    @Test func theClickThatWorkedNextIsKeptAsTheFix() {
        let memoryPage = Plan.page(page(misses: [miss("Add New"), miss("Save")]), notingFix: "New Patient", forMissedLabels: ["Add New"])
        #expect(memoryPage.misses?.first { $0.label == "Add New" }?.fixLabel == "New Patient")
        #expect(memoryPage.misses?.first { $0.label == "Save" }?.fixLabel == nil)
    }

    @Test func aClickIsNeverItsOwnFix() {
        let memoryPage = Plan.page(page(misses: [miss("Save")]), notingFix: "Save", forMissedLabels: ["Save"])
        #expect(memoryPage.misses?.first?.fixLabel == nil)
    }

    @Test func jevsOptionsSayAMissAndItsFix() {
        let memoryPage = page(misses: [miss("Add New", fix: "New Patient")])
        let noted = Plan.optionsNotingMisses([clickOption("o1", "Add New"), clickOption("o2", "New Patient"),
                                              DottieJevDriverPlan.Option(key: "o3", move: .scrollDown)], on: memoryPage, now: Date())
        #expect(noted.count == 3)
        #expect(noted[0].memoryNote?.contains("did nothing") == true)
        #expect(noted[0].memoryNote?.contains("New Patient") == true)
        #expect(noted[1].memoryNote?.contains("worked here") == true)
        #expect(noted[2].memoryNote == nil)
    }

    @Test func aClickMissedTwiceIsNotOffered() {
        let memoryPage = page(misses: [miss("Add New", times: 2)])
        let noted = Plan.optionsNotingMisses([clickOption("o1", "Add New"), clickOption("o2", "Search")], on: memoryPage, now: Date())
        #expect(noted.map(\.key) == ["o2"])
    }

    @Test func oldMissesAreForgotten() {
        let memoryPage = page(misses: [miss("Add New", times: 3, daysAgo: 4)])
        let noted = Plan.optionsNotingMisses([clickOption("o1", "Add New")], on: memoryPage, now: Date())
        #expect(noted.count == 1)
        #expect(noted[0].memoryNote == nil)
        #expect(Plan.missLines(on: memoryPage, now: Date()).isEmpty)
    }

    @Test func aClickThatLeadsOnLaterIsForgiven() {
        let memoryPage = Plan.page(page(misses: [miss("Add New", times: 2)]), noting: DottieAppPage.Click(
            label: "Add New", centerX: 10, centerY: 10, resultPageKey: "openemr|localhost|new patient",
            resultPageTitle: "New Patient", timesSeen: 1, lastSeen: Date()))
        #expect(memoryPage.misses == nil)
    }

    @Test func aClickThatStaysOnThePageIsNotForgiven() {
        let memoryPage = Plan.page(page(misses: [miss("Add New")]), noting: DottieAppPage.Click(
            label: "Add New", centerX: 10, centerY: 10, resultPageKey: "openemr|localhost|patient",
            resultPageTitle: "Patient", timesSeen: 1, lastSeen: Date()))
        #expect(memoryPage.misses?.count == 1)
    }

    @Test func aTextBoxIsNeverStruckOff() {
        let memoryPage = page(misses: [miss("First Name", times: 5)])
        let fieldOption = DottieJevDriverPlan.Option(key: "o1", move: .clickControl(label: "First Name", kind: "text field", centerX: 1, centerY: 1))
        let noted = Plan.optionsNotingMisses([fieldOption], on: memoryPage, now: Date())
        #expect(noted.count == 1)
        #expect(Plan.isTextBox(fieldOption))
        #expect(!Plan.isTextBox(clickOption("o2", "First Name")))
    }

    @Test func aMissIsForgivenWhenTheClickWorksOnItsPage() {
        let memoryPage = Plan.page(page(misses: [miss("Add New"), miss("Save")]), forgivingMissOf: "add new")
        #expect(memoryPage.misses?.map(\.label) == ["Save"])
        #expect(Plan.page(page(), forgivingMissOf: "Save").misses == nil)
    }

    @Test func theStepModelReadsTheMistakes() {
        let lines = Plan.missLines(on: page(misses: [miss("Add New", times: 2, fix: "New Patient")]), now: Date())
        #expect(lines.count == 1)
        #expect(lines[0].contains("Add New"))
        #expect(lines[0].contains("New Patient"))
        let summary = DottieAppMemoryRecallPlan.summary(appName: "OpenEMR", page: page(misses: [miss("Add New")]), flows: [], taskText: "add a patient")
        #expect(summary.contains("Mistakes here before"))
    }

    @Test func pagesSavedBeforeMissesStillLoad() throws {
        let oldPageJSON = #"{"key":"a|b|c","title":"C","elements":[],"clicks":[],"lastSeen":0}"#
        let loadedPage = try JSONDecoder().decode(DottieAppPage.self, from: Data(oldPageJSON.utf8))
        #expect(loadedPage.misses == nil)
    }

    @Test func missesStayFewAndQuick() {
        var memoryPage = page()
        for index in 0..<100 { memoryPage = Plan.page(memoryPage, notingMiss: miss("Button \(index)")) }
        #expect((memoryPage.misses?.count ?? 0) <= Plan.maximumMissesPerPage)
        let options = (0..<255).map { clickOption("o\($0)", "Button \($0)") }
        let started = Date()
        for _ in 0..<20 { _ = Plan.optionsNotingMisses(options, on: memoryPage, now: Date()) }
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
