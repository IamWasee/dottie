//
//  AppTasksFromStepModelTests.swift
//  leanring-buddyTests
//
//  Jobs Claude (the step model) finishes become named tasks too: its
//  actions, as kept for instant replays, turned into task steps (the words
//  on the control, typed request words marked, waits left out), joined to
//  what Jev did first, and done again from memory next time.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct AppTasksFromStepModelTests {
    private typealias Plan = DottieAppTaskPlan
    private typealias ReplayStep = DottieReplay.Step

    private let request = "add a patient named Sam Lee"

    private func target(title: String? = nil, nearbyText: String? = nil, label: String? = nil) -> DottieReplay.Target {
        DottieReplay.Target(title: title, windowTitle: "OpenEMR", nearbyText: nearbyText, label: label, pointX: 100, pointY: 200)
    }

    private var patientSteps: [ReplayStep] {
        [
            ReplayStep(action: "click", arguments: [:], target: target(title: "Patient")),
            ReplayStep(action: "click", arguments: [:], target: target(nearbyText: "New/Search", label: "New patient menu item")),
            ReplayStep(action: "type_text", arguments: ["text": "Sam"], target: target(nearbyText: "First Name")),
            ReplayStep(action: "wait", arguments: ["seconds": "2"], target: nil),
            ReplayStep(action: "type_text", arguments: ["text": "Lee", "press_enter": "true"], target: target(nearbyText: "Last Name")),
            ReplayStep(action: "click", arguments: [:], target: target(title: "Create New Patient"))
        ]
    }

    private func recording(_ steps: [ReplayStep], startingFrom jevRecording: DottieAppTaskRecording = DottieAppTaskRecording()) -> DottieAppTaskRecording {
        var recording = jevRecording
        for replayStep in steps {
            if let step = Plan.step(fromReplayStep: replayStep, requestText: request) {
                recording.note(step, placeKey: "localhost", placeName: "localhost", bundleIdentifier: "com.google.chrome")
            }
        }
        return recording
    }

    // MARK: Turning actions into steps

    @Test func clicksUseTheWordsOnTheControl() throws {
        let step = try #require(Plan.step(fromReplayStep: patientSteps[0], requestText: request))
        #expect(step.kind == .click)
        #expect(step.label == "Patient")
        #expect(step.role == nil)
        #expect(step.pageTitle == "OpenEMR")
        let menuStep = try #require(Plan.step(fromReplayStep: patientSteps[1], requestText: request))
        #expect(menuStep.label == "New/Search")
    }

    @Test func typingIntoABoxKeepsTheBoxAndMarksTheRequestsWords() throws {
        let firstName = try #require(Plan.step(fromReplayStep: patientSteps[2], requestText: request))
        #expect(firstName.kind == .typeIntoField)
        #expect(firstName.label == "First Name")
        #expect(firstName.text == "Sam")
        #expect(firstName.textCameFromRequest)
        #expect(!firstName.pressesReturn)
        let lastName = try #require(Plan.step(fromReplayStep: patientSteps[4], requestText: request))
        #expect(lastName.pressesReturn)
        let typedElsewhere = try #require(Plan.step(fromReplayStep: ReplayStep(action: "type_text", arguments: ["text": "hello"], target: nil), requestText: request))
        #expect(typedElsewhere.kind == .typeText)
        #expect(!typedElsewhere.textCameFromRequest)
    }

    @Test func otherActionsBecomeTheirSteps() {
        func kind(_ action: String, _ arguments: [String: String]) -> DottieAppTaskStep.Kind? {
            Plan.step(fromReplayStep: ReplayStep(action: action, arguments: arguments, target: nil), requestText: request)?.kind
        }
        #expect(kind("press_keys", ["keys": "cmd+s"]) == .pressKeys)
        #expect(kind("press_keys", ["keys": "return"]) == .pressReturn)
        #expect(kind("scroll", ["direction": "up"]) == .scrollUp)
        #expect(kind("scroll", [:]) == .scrollDown)
        #expect(kind("scroll", ["direction": "right"]) == .scrollRight)
        #expect(kind("open_url", ["url": "localhost/openemr"]) == .openSite)
        #expect(kind("open_app", ["name": "Safari"]) == .openApp)
        #expect(kind("click", ["double_click": "true"]) == .jevPicks)
    }

    @Test func doubleAndRightClicksKeepTheirKind() {
        let double = Plan.step(fromReplayStep: ReplayStep(action: "click", arguments: ["double_click": "true"], target: target(title: "Sam Lee")), requestText: request)
        let right = Plan.step(fromReplayStep: ReplayStep(action: "click", arguments: ["right_click": "true"], target: target(title: "Sam Lee")), requestText: request)
        #expect(double?.kind == .doubleClick)
        #expect(right?.kind == .rightClick)
    }

    @Test func waitsAndEmptyActionsAreNotSteps() {
        for replayStep in [
            ReplayStep(action: "wait", arguments: ["seconds": "3"], target: nil),
            ReplayStep(action: "wait_for_video_end", arguments: [:], target: nil),
            ReplayStep(action: "type_text", arguments: [:], target: nil),
            ReplayStep(action: "press_keys", arguments: [:], target: nil),
            ReplayStep(action: "open_url", arguments: [:], target: nil),
            ReplayStep(action: "hover", arguments: [:], target: nil)
        ] {
            #expect(Plan.step(fromReplayStep: replayStep, requestText: request) == nil, "\(replayStep.action)")
        }
    }

    @Test func aClickWithNoWordsIsLeftToJev() throws {
        let step = try #require(Plan.step(fromReplayStep: ReplayStep(action: "click", arguments: [:], target: target()), requestText: request))
        #expect(step.kind == .jevPicks)
    }

    // MARK: Journeys

    @Test func aJobClaudeFinishedBecomesATaskWorthDoingAgain() throws {
        let recorded = recording(patientSteps)
        #expect(recorded.steps.count == 5)
        let task = try #require(Plan.taskAfterSuccess(nil, request: request, recording: recorded, pathProblem: nil, now: Date()))
        #expect(task.places == ["localhost"])
        #expect(Plan.isWorthReplaying(task))
        #expect(Plan.bestTask(forRequest: "add a patient named Ana Cruz", placeKeys: ["localhost"], among: [task])?.id == task.id)
    }

    @Test func jevsMovesComeBeforeClaudes() throws {
        var jevRecording = DottieAppTaskRecording()
        let jevStep = try #require(DottieAppTaskPlan.step(from: .openSite(address: "localhost/openemr"), pageTitle: "", requestText: request))
        jevRecording.note(jevStep, placeKey: "localhost", placeName: "localhost", bundleIdentifier: "com.google.chrome")
        let recorded = recording(patientSteps, startingFrom: jevRecording)
        #expect(recorded.steps.first?.kind == .openSite)
        #expect(recorded.steps.count == 6)
    }

    @Test func theNextRequestsNameGoesWhereTheOldOneWasTyped() throws {
        let task = try #require(Plan.taskAfterSuccess(nil, request: request, recording: recording(patientSteps), pathProblem: nil, now: Date()))
        let firstNameStep = try #require(task.steps.first { $0.label == "First Name" })
        let screenTexts = [DottieJevDriverPlan.ScreenText(text: "First Name", centerX: 300, centerY: 400)]
        let replay = Plan.replayStep(firstNameStep, recordedForRequest: request, newRequest: "add a patient named Ana Cruz",
                                     screenTexts: screenTexts, screenControls: [], frontSiteHost: "localhost", frontAppName: "Chrome")
        guard case .move(.typeIntoField(_, _, _, let typedText, _)) = replay else {
            Issue.record("expected typing into First Name, got \(replay)")
            return
        }
        #expect(typedText == "Ana")
    }

    @Test func aLongFormStillFits() {
        let longForm = (0..<60).map { ReplayStep(action: "click", arguments: [:], target: target(title: "Field \($0)")) }
        #expect(Plan.taskAfterSuccess(nil, request: request, recording: recording(longForm), pathProblem: nil, now: Date()) != nil)
    }

    @Test func convertingIsQuick() {
        let manySteps = Array(repeating: patientSteps, count: 200).flatMap { $0 }
        let startedAt = Date()
        _ = recording(manySteps)
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
