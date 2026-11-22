//
//  AppMemoryRecallTests.swift
//  leanring-buddyTests
//
//  App memory's flows (what the user did, step after step) and the text
//  Jev and the step model get when they ask for it.
//

import Foundation
import Testing
@testable import Dottie

struct AppMemoryRecallTests {
    private typealias Plan = DottieAppMemoryRecallPlan

    private func click(_ label: String, on page: String, opens result: String? = nil) -> DottieAppFlowStep {
        DottieAppFlowStep(action: .click, pageTitle: page, label: label, centerX: 120, centerY: 80, resultPageTitle: result)
    }

    private func typing(into field: String, on page: String) -> DottieAppFlowStep {
        DottieAppFlowStep(action: .typeInto, pageTitle: page, label: field, centerX: nil, centerY: nil)
    }

    @Test func typingIntoTheSameFieldIsOneStep() {
        var flow = DottieAppFlow(startedAt: Date(), steps: [])
        flow = Plan.flow(flow, adding: typing(into: "To", on: "New Message"))
        flow = Plan.flow(flow, adding: typing(into: "To", on: "New Message"))
        flow = Plan.flow(flow, adding: typing(into: "Subject", on: "New Message"))
        #expect(flow.steps.map(\.label) == ["To", "Subject"])
    }

    @Test func aFlowStopsGrowingAtItsCap() {
        var flow = DottieAppFlow(startedAt: Date(), steps: [])
        for index in 0..<(Plan.maximumStepsPerFlow + 10) {
            flow = Plan.flow(flow, adding: click("Item \(index)", on: "List"))
        }
        #expect(flow.steps.count == Plan.maximumStepsPerFlow)
    }

    @Test func oneStepFlowsAreNotKeptAndOldOnesFallOff() {
        let oneStep = DottieAppFlow(startedAt: Date(), steps: [click("A", on: "P")])
        let twoSteps = DottieAppFlow(startedAt: Date(), steps: [click("A", on: "P"), click("B", on: "P")])
        #expect(Plan.keptFlows([oneStep, twoSteps]).count == 1)
        #expect(Plan.keptFlows(Array(repeating: twoSteps, count: Plan.maximumFlowsPerApp + 5)).count == Plan.maximumFlowsPerApp)
    }

    @Test func stepLinesSayWhatHappenedWhereAndWhatItOpened() {
        #expect(Plan.stepLine(click("Compose", on: "Inbox", opens: "New Message")) == "on \"Inbox\" clicked \"Compose\" at (120, 80) → opened \"New Message\"")
        #expect(Plan.stepLine(typing(into: "To", on: "New Message")) == "on \"New Message\" typed into \"To\"")
        #expect(Plan.stepLine(DottieAppFlowStep(action: .pressKeys, pageTitle: "New Message", label: "cmd+return", centerX: nil, centerY: nil)) == "on \"New Message\" pressed cmd+return")
    }

    @Test func theFlowThatSharesTheJobsWordsComesFirst() {
        let emailFlow = DottieAppFlow(startedAt: Date(), steps: [click("Compose", on: "Inbox"), typing(into: "Subject", on: "New Message")])
        let archiveFlow = DottieAppFlow(startedAt: Date(), steps: [click("Archive", on: "Inbox"), click("Undo", on: "Inbox")])
        let fitting = Plan.flowsFitting(taskText: "archive this email", in: [emailFlow, archiveFlow])
        #expect(fitting.first == archiveFlow)
    }

    @Test func withNoFittingFlowTheNewestComeFirst() {
        let older = DottieAppFlow(startedAt: Date(), steps: [click("A", on: "P"), click("B", on: "P")])
        let newer = DottieAppFlow(startedAt: Date(), steps: [click("C", on: "P"), click("D", on: "P")])
        #expect(Plan.flowsFitting(taskText: "zzz", in: [older, newer]).first == newer)
    }

    @Test func theSummaryHasThePageItsControlsClicksAndFlows() {
        var page = DottieAppPage(key: "k", title: "Inbox", elements: [DottieAppPage.Element(label: "Primary", centerX: 300, centerY: 120)],
                                 clicks: [], lastSeen: Date(), screenshotFileName: nil)
        page.controls = [DottieAppPage.Control(label: "Compose", kind: "button", centerX: 60, centerY: 140)]
        page.smartDescription = "The pencil icon top left writes a new email."
        page.clicks = [DottieAppPage.Click(label: "Compose", centerX: 60, centerY: 140, resultPageKey: "k2", resultPageTitle: "New Message", timesSeen: 3, lastSeen: Date())]
        let flow = DottieAppFlow(startedAt: Date(), steps: [click("Compose", on: "Inbox", opens: "New Message"), typing(into: "To", on: "New Message")])
        let summary = Plan.summary(appName: "Mail", page: page, flows: [flow], taskText: "write an email")
        #expect(summary.contains("page \"Inbox\""))
        #expect(summary.contains("The pencil icon top left writes a new email."))
        #expect(summary.contains("button \"Compose\" (60, 140)"))
        #expect(summary.contains("\"Compose\" at (60, 140) → \"New Message\""))
        #expect(summary.contains("\"Primary\" (300, 120)"))
        #expect(summary.contains("Flow 1: on \"Inbox\" clicked \"Compose\""))
    }

    @Test func nothingRememberedIsAnEmptySummary() {
        #expect(Plan.summary(appName: "Mail", page: nil, flows: [], taskText: "x").isEmpty)
    }

    @Test func aHugeMemoryIsCutToFit() {
        let elements = (0..<200).map { DottieAppPage.Element(label: String(repeating: "word ", count: 20) + "\($0)", centerX: 1, centerY: 1) }
        let page = DottieAppPage(key: "k", title: "Big", elements: elements, clicks: [], lastSeen: Date(), screenshotFileName: nil)
        #expect(Plan.summary(appName: "App", page: page, flows: [], taskText: "x").count <= Plan.maximumSummaryCharacters + 1)
    }

    @Test func thePageReadingPromptNamesTheAppThePageAndDottiesMoves() {
        let prompt = Plan.pageReadingPrompt(appName: "Figma", pageTitle: "Untitled")
        #expect(prompt.contains("Figma"))
        #expect(prompt.contains("\"Untitled\""))
        #expect(prompt.contains("double-click"))
        #expect(prompt.contains("drag"))
        #expect(prompt.contains("0 to 1000"))
    }

    @Test func oldMemoryFilesWithoutControlsStillLoad() throws {
        let oldJSON = #"{"key":"k","title":"T","elements":[],"clicks":[],"lastSeen":0}"#
        let page = try JSONDecoder().decode(DottieAppPage.self, from: Data(oldJSON.utf8))
        #expect(page.controls == nil)
        #expect(page.smartDescription == nil)
    }
}
