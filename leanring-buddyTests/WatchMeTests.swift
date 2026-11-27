//
//  WatchMeTests.swift
//  leanring-buddyTests
//
//  Watch me after the review (27 Nov): how long a watch runs and what's said
//  when an ask is cut, typed notes told apart from form typing, private
//  values kept off the model's page, frames kept and picked, a long tour cut
//  into at most six parts, the model's answer read and merged, how-tos found
//  again on the same site, hovers before a click, and whole journeys from a
//  watched tour to a task Dottie does again with new names.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct WatchMeTests {
    private typealias Plan = DottieWatchPlan

    private func action(_ kind: DottieWatchedAction.Kind, _ label: String = "", role: String? = nil, text: String? = nil,
                        field: String? = nil, hidden: Bool = false, page: String = "OpenEMR", place: String = "localhost",
                        seconds: Double = 0) -> DottieWatchedAction {
        DottieWatchedAction(kind: kind, label: label, role: role, centerX: 500, centerY: 300, text: text, fieldLabel: field,
                            isHiddenBecausePrivate: hidden, pageTitle: page, placeKey: place, placeName: place, secondsIntoWatch: seconds)
    }

    /// A watched "add a patient": the menu hovered, the form filled (the SSN
    /// hidden), saved, and a click into the notes window the tour typed in.
    private var addPatientActions: [DottieWatchedAction] {
        [
            action(.place, "Google Chrome: localhost"),
            action(.hover, "Patient", role: "menu item"),
            action(.click, "New/Search", role: "link"),
            action(.typed, "First Name", text: "Jane", field: "First Name"),
            action(.pressed, "tab"),
            action(.typed, "Last Name", text: "Doe", field: "Last Name"),
            action(.typed, "SSN", text: nil, field: "SSN", hidden: true),
            action(.click, "Create New Patient", role: "button"),
            action(.click, "", role: "text area", page: "Notes", place: "com.apple.textedit"),
            action(.narration, text: "this form adds a patient", page: "Notes", place: "com.apple.textedit")
        ]
    }

    private var addPatientUnderstanding: Plan.Understanding {
        Plan.Understanding(
            name: "OpenEMR tour", app: "OpenEMR", summary: "They showed the patient menu and added a patient.", goal: "Learn OpenEMR",
            method: ["Open Patient, then New/Search"], interfaceNotes: ["Patient menu at the top"], worksFor: "patient records",
            pages: [DottieWatchedHowToPage(name: "New patient", whatItIs: "the demographics form", howToGetThere: "Patient > New/Search", keyControls: ["Create New Patient"])],
            tasks: [Plan.WatchedTask(name: "Add a patient", purpose: "Creates a new patient record", doneWhen: "the patient's chart opens",
                                     exampleRequest: "add a patient named Jane Doe", actionNumbers: [2, 3, 4, 5, 6, 7, 8, 9, 10])]
        )
    }

    // MARK: How long, and what's said

    @Test func aLongAskIsCutTo15MinutesAndTheUserIsTold() {
        let length = Plan.watchLength(requestedSeconds: 1200, isTour: false)
        #expect(length.seconds == 900)
        #expect(length.wasCut)
        let line = Plan.startLine(length: length, isTour: false, onlyFramesReason: nil, looksMedical: false)
        #expect(line.hasPrefix("watching for 15 minutes."))
        let shown = DottieLearningPhrase.startWatching(seconds: 1200).doneText(forToolResult: line)
        #expect(shown == "Watching for 15 minutes. You asked for 20 minutes; the longest watch is 15 minutes. Go ahead and do it the way you normally would.")
    }

    @Test func aTourWatchesUntilDoneAndAJobForThirtySeconds() {
        #expect(Plan.watchLength(requestedSeconds: nil, isTour: true).seconds == 900)
        #expect(Plan.watchLength(requestedSeconds: nil, isTour: false).seconds == 30)
        #expect(Plan.watchLength(requestedSeconds: 2, isTour: false).seconds == 5)
        #expect(!Plan.watchLength(requestedSeconds: 600, isTour: false).wasCut)
        #expect(Plan.spokenDuration(90) == "90 seconds")
        #expect(Plan.spokenDuration(60) == "1 minute")
    }

    @Test func onlyFramesAndDemoDataAreSaidOutLoud() {
        let length = Plan.watchLength(requestedSeconds: nil, isTour: true)
        let line = Plan.startLine(length: length, isTour: true, onlyFramesReason: "a smart replay is being recorded", looksMedical: true)
        let shown = DottieLearningPhrase.startWatching(seconds: nil, isTour: true).doneText(forToolResult: line)
        #expect(shown.contains("Only the screen is being watched, not clicks or typing: a smart replay is being recorded."))
        #expect(shown.contains("Use demo data only"))
        #expect(shown.contains("NOTE:"))
        #expect(Plan.looksMedical(["OpenEMR", ""]))
        #expect(Plan.looksMedical(["add a patient"]))
        #expect(!Plan.looksMedical(["Google Sheets", "budget"]))
    }

    // MARK: What was typed

    @Test func notesAreToldApartFromFormTyping() {
        #expect(Plan.isNarration("NOTE: this is the calendar, it shows the day's appointments", isTour: false))
        #expect(Plan.isNarration("note - the fees menu holds billing", isTour: false))
        #expect(Plan.isNarration("This is the patient finder where you search by name or date", isTour: true))
        #expect(!Plan.isNarration("This is the patient finder where you search by name or date", isTour: false))
        #expect(!Plan.isNarration("Jane", isTour: true))
        #expect(!Plan.isNarration("john smith 123 main street springfield illinois usa", isTour: true))
        #expect(Plan.narrationText("NOTE:  this is the calendar ") == "this is the calendar")
    }

    @Test func privateValuesAreSpottedByTheirFieldOrShape() {
        #expect(Plan.looksPrivate(fieldLabel: "SSN", value: "abc"))
        #expect(Plan.looksPrivate(fieldLabel: "Date of Birth", value: "1980-01-02"))
        #expect(Plan.looksPrivate(fieldLabel: "DOB", value: "01/02/1980"))
        #expect(Plan.looksPrivate(fieldLabel: "Home Phone", value: "555"))
        #expect(Plan.looksPrivate(fieldLabel: "Medical Record Number", value: "x"))
        #expect(Plan.looksPrivate(fieldLabel: nil, value: "123-45-6789"))
        #expect(Plan.looksPrivate(fieldLabel: nil, value: "(555) 123-4567"))
        #expect(!Plan.looksPrivate(fieldLabel: "First Name", value: "Jane"))
        #expect(!Plan.looksPrivate(fieldLabel: nil, value: "follow-up visit"))
    }

    @Test func linesForTheModelHidePrivateAndOptionallyAllTypedText() {
        let hidden = action(.typed, "SSN", field: "SSN", hidden: true)
        #expect(hidden.line(sendsTypedText: true) == "typed private details into \"SSN\" (not shown)")
        let name = action(.typed, "First Name", text: "Jane", field: "First Name")
        #expect(name.line(sendsTypedText: true) == "typed \"Jane\" into \"First Name\"")
        #expect(name.line(sendsTypedText: false) == "typed text into \"First Name\" (not shown)")
        #expect(action(.narration, text: "this is the calendar").line(sendsTypedText: true).hasPrefix("NOTE from the person showing you"))
        #expect(action(.hover, "Patient", role: "menu item").line(sendsTypedText: true).hasPrefix("pointed the mouse at the menu item \"Patient\""))
        #expect(action(.click, role: "button").line(sendsTypedText: true) == "clicked an unnamed button about 50% across and 30% down the screen")
    }

    // MARK: Frames

    @Test func framesAreSpreadEvenlyAndPickedPerPart() {
        #expect(Plan.evenlySpacedIndices(count: 5, keeping: 10) == [0, 1, 2, 3, 4])
        #expect(Plan.evenlySpacedIndices(count: 450, keeping: 10).first == 0)
        #expect(Plan.evenlySpacedIndices(count: 450, keeping: 10).last == 449)
        #expect(Plan.evenlySpacedIndices(count: 450, keeping: 10).count == 10)
        #expect(Plan.evenlySpacedIndices(count: 4, keeping: 1) == [3])
        #expect(Plan.evenlySpacedIndices(count: 0, keeping: 3).isEmpty)
        let frameSeconds = stride(from: 0.0, to: 100.0, by: 2.0).map { $0 }
        let picked = Plan.frameIndices(frameSeconds: frameSeconds, from: 20, to: 40, picking: 3)
        #expect(picked.count == 3)
        #expect(picked.allSatisfy { frameSeconds[$0] >= 19.5 && frameSeconds[$0] <= 42.5 })
        #expect(Plan.frameIndices(frameSeconds: [0, 2], from: 50, to: 60, picking: 3) == [1])
    }

    @Test func aNewLineOfSmallTextKeepsItsFrameButACursorBlinkDoesNot() {
        let width = Plan.fingerprintWidth, height = Plan.fingerprintHeight
        let blank = [UInt8](repeating: 30, count: width * height)
        var typedLine = blank
        for column in 10..<20 { typedLine[12 * width + column] = 200 }
        #expect(!Plan.isSameScreen(blank, typedLine))
        var cursorBlink = blank
        cursorBlink[12 * width + 40] = 200
        #expect(Plan.isSameScreen(blank, cursorBlink))
        // Eight specks in eight different blocks: more than a block needs, none filling one.
        var scatteredSpecks = blank
        for speckNumber in 0..<8 { scatteredSpecks[(speckNumber * 8 + 2) * width + speckNumber * 9] = 200 }
        #expect(Plan.isSameScreen(blank, scatteredSpecks))
        // Five changed pixels in one block stay one short of a change; the sixth makes it.
        var almostABlock = blank
        for column in 0..<5 { almostABlock[3 * width + column] = 200 }
        #expect(Plan.isSameScreen(blank, almostABlock))
        almostABlock[4 * width + 0] = 200
        #expect(!Plan.isSameScreen(blank, almostABlock))
        #expect(!Plan.isSameScreen(blank, [UInt8](repeating: 220, count: width * height)))
        #expect(!Plan.isSameScreen(blank, [1, 2, 3]))
    }

    // MARK: Tour parts

    @Test func aLongTourBecomesAtMostSixPartsCoveringEveryAction() {
        var actions: [DottieWatchedAction] = []
        for index in 0..<300 {
            let page = "Page \(index / 25)"
            actions.append(index % 10 == 0
                ? action(.narration, text: "this is \(page)", page: page, seconds: Double(index))
                : action(.click, "Item \(index)", page: page, seconds: Double(index)))
        }
        let parts = Plan.tourParts(of: actions)
        #expect(parts.count <= Plan.maximumCalls)
        #expect(parts.count >= 2)
        #expect(parts.first?.actionRange.lowerBound == 0)
        #expect(parts.last?.actionRange.upperBound == actions.count)
        for (earlier, later) in zip(parts, parts.dropFirst()) {
            #expect(earlier.actionRange.upperBound == later.actionRange.lowerBound)
            #expect(earlier.endSeconds <= later.startSeconds)
        }
        #expect(Plan.tourParts(of: []).isEmpty)
        #expect(Plan.tourParts(of: Array(actions.prefix(2))).count == 1)
    }

    @Test func eachPartsMessageNumbersItsActionsAndSaysWhichPartItIs() {
        let actions = addPatientActions
        let part = Plan.WatchPart(actionRange: 1..<4, startSeconds: 0, endSeconds: 10)
        let prompt = Plan.partPrompt(actions: actions, part: part, partNumber: 2, partCount: 3, screenTexts: ["Patient", "Fees"],
                                     note: "a tour of openemr", sendsTypedText: true, droppedActionCount: 0)
        #expect(prompt.contains("2. pointed the mouse at the menu item \"Patient\""))
        #expect(prompt.contains("4. typed \"Jane\" into \"First Name\""))
        #expect(prompt.contains("part 2 of 3"))
        #expect(prompt.contains("Patient | Fees"))
        #expect(prompt.contains("The user said this is: a tour of openemr"))
        let lastPart = Plan.partPrompt(actions: actions, part: part, partNumber: 3, partCount: 3, screenTexts: [], note: "",
                                       sendsTypedText: true, droppedActionCount: 12)
        #expect(lastPart.contains("12 more actions"))
    }

    // MARK: The model's answer

    @Test func theAnswerIsReadAndPartsAreMerged() {
        let answer: [String: Any] = [
            "name": "OpenEMR tour", "app": "OpenEMR", "summary": "The patient pages.", "goal": "Learn it",
            "method": ["Open Patient"], "interface_notes": ["Menus at the top"], "works_for": "records",
            "pages": [["name": "Calendar", "what_it_is": "appointments", "how_to_get_there": "top menu", "key_controls": ["Add"]],
                      ["what_it_is": "no name"]] as [[String: Any]],
            "tasks": [["name": "Add a patient", "example_request": "add Jane Doe", "actions": [3, "4", 5] as [Any]],
                      ["name": "No actions", "actions": [] as [Any]]] as [[String: Any]]
        ]
        let first = Plan.understanding(from: answer)
        #expect(first?.pages.map(\.name) == ["Calendar"])
        #expect(first?.tasks.first?.actionNumbers == [3, 4, 5])
        #expect(first?.tasks.count == 1)
        #expect(Plan.understanding(from: ["summary": "no name"]) == nil)
        var second = first!
        second.name = "Part two"
        second.summary = "Fees too."
        second.pages = [DottieWatchedHowToPage(name: "calendar", whatItIs: "", howToGetThere: "", keyControls: []),
                        DottieWatchedHowToPage(name: "Fees", whatItIs: "billing", howToGetThere: "Fees menu", keyControls: [])]
        let merged = Plan.mergedUnderstanding([first!, second])
        #expect(merged?.name == "OpenEMR tour")
        #expect(merged?.summary == "The patient pages. Fees too.")
        #expect(merged?.pages.map(\.name) == ["Calendar", "Fees"])
        #expect(merged?.tasks.count == 2)
        #expect(Plan.mergedUnderstanding([]) == nil)
    }

    // MARK: Finding a how-to again

    private func howTo(name: String, kind: String?, places: [String]?, goal: String = "") -> DottieWatchedHowTo {
        DottieWatchedHowTo(learnedAt: Date(), name: name, appName: "OpenEMR", summary: String(repeating: "A long summary. ", count: 80),
                           goal: goal, method: ["Open Patient"], interfaceNotes: [], worksFor: "", skillName: nil, kind: kind, places: places,
                           pages: addPatientUnderstanding.pages + [DottieWatchedHowToPage(name: "Calendar", whatItIs: "appointments", howToGetThere: "", keyControls: [])],
                           exampleRequests: nil)
    }

    @Test func aTourIsFoundForAnyJobOnItsSiteButNotElsewhere() {
        let tour = howTo(name: "OpenEMR tour", kind: "tour", places: ["localhost"])
        #expect(Plan.howToFits(tour, taskText: "add 10 patients", frontmostAppName: "Google Chrome", frontPlaceKey: "localhost"))
        #expect(!Plan.howToFits(tour, taskText: "add 10 patients", frontmostAppName: "Google Chrome", frontPlaceKey: "youtube.com"))
        // Before, being in the browser counted for nothing and the tour shared no word with the job.
        #expect(!DottieTaskMatching.howToFits(taskText: "add 10 patients", frontmostAppName: "Google Chrome",
                                              howToName: tour.name, howToGoal: tour.goal, howToAppName: tour.appName))
    }

    @Test func aJobHowToOnItsSiteNeedsASharedWord() {
        let job = howTo(name: "Add a patient", kind: nil, places: ["localhost"])
        #expect(Plan.howToFits(job, taskText: "add three patients", frontmostAppName: "Google Chrome", frontPlaceKey: "localhost"))
        #expect(!Plan.howToFits(job, taskText: "print the report", frontmostAppName: "Google Chrome", frontPlaceKey: "localhost"))
        let oldHowTo = howTo(name: "Add a patient", kind: nil, places: nil)
        #expect(!Plan.howToFits(oldHowTo, taskText: "print the report", frontmostAppName: "Google Chrome", frontPlaceKey: "localhost"))
    }

    @Test func aTourSendsOnlyThePagesThatMatterAndStaysShort() {
        let tour = howTo(name: "OpenEMR tour", kind: "tour", places: ["localhost"])
        let calendarText = Plan.promptText(for: tour, taskText: "book an appointment on the calendar", frontPageTitle: nil)
        #expect(calendarText.count <= Plan.maximumHowToCharacters)
        let shortTour = DottieWatchedHowTo(learnedAt: Date(), name: "OpenEMR tour", appName: "OpenEMR", summary: "Short.", goal: "",
                                           method: [], interfaceNotes: [], worksFor: "", skillName: nil, kind: "tour", places: ["localhost"],
                                           pages: tour.pages, exampleRequests: nil)
        let matching = Plan.promptText(for: shortTour, taskText: "book an appointment on the calendar", frontPageTitle: nil)
        #expect(matching.contains("Pages that matter here: Calendar: appointments"))
        #expect(!matching.contains("demographics"))
        let none = Plan.promptText(for: shortTour, taskText: "print a report", frontPageTitle: nil)
        #expect(none.contains("Pages it showed: New patient, Calendar"))
    }

    @Test func oldSavedHowTosStillLoad() throws {
        let oldJSON = """
        [{"id":"\(UUID().uuidString)","learnedAt":"2026-11-01T10:00:00Z","name":"Move a note","appName":"Notes","summary":"s","goal":"g","method":[],"interfaceNotes":[],"worksFor":""}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let howTos = try decoder.decode([DottieWatchedHowTo].self, from: Data(oldJSON.utf8))
        #expect(howTos.first?.isTour == false)
        #expect(howTos.first?.places == nil)
    }

    // MARK: Tasks from a watch

    @Test func aWatchedTaskBecomesStepsWithPrivateValuesLeftForJev() throws {
        let tasks = Plan.appTasks(from: addPatientUnderstanding, actions: addPatientActions, now: Date())
        let task = try #require(tasks.first)
        #expect(task.places == ["localhost"])
        #expect(task.learnedByWatching == true)
        #expect(task.isNamed)
        #expect(task.steps.map(\.kind) == [.hover, .click, .typeIntoField, .pressKeys, .typeIntoField, .typeIntoField, .click])
        #expect(task.steps[2].text == "Jane")
        #expect(task.steps[2].textCameFromRequest)
        #expect(task.steps[5].label == "SSN")
        #expect(task.steps[5].text == nil)
        #expect(!task.steps.contains { $0.label.contains("text area") })
        #expect(DottieAppTaskPlan.isWorthReplaying(task))
    }

    @Test func returnAfterTypingJoinsTheTypingStep() {
        let steps = Plan.steps(from: [action(.typed, "Search", text: "Jane", field: "Search"), action(.pressed, "return"), action(.pressed, "cmd+s")],
                               exampleRequest: "find Jane")
        #expect(steps.count == 2)
        #expect(steps[0].pressesReturn)
        #expect(steps[1].kind == .pressKeys)
        #expect(steps[1].label == "cmd+s")
        #expect(Plan.steps(from: [action(.pressed, "return")], exampleRequest: "x").map(\.kind) == [.pressReturn])
        #expect(Plan.steps(from: [action(.click, role: "button")], exampleRequest: "x").map(\.kind) == [.jevPicks])
    }

    @Test func aWatchedTaskGetsOneTryBeforeItHasWorked() {
        var task = Plan.appTasks(from: addPatientUnderstanding, actions: addPatientActions, now: Date())[0]
        task.timesRun = 1
        #expect(!DottieAppTaskPlan.isWorthReplaying(task))
        task.timesSucceeded = 1
        #expect(DottieAppTaskPlan.isWorthReplaying(task))
    }

    @Test func watchingAgainUpdatesATaskThatHasNotWorkedYetAndKeepsOneThatHas() {
        let watched = Plan.appTasks(from: addPatientUnderstanding, actions: addPatientActions, now: Date())
        let neverWorked = DottieAppTask(id: UUID(), name: "add a patient", purpose: "", doneWhen: "", tips: [], appName: "OpenEMR", places: ["localhost"],
                                    exampleRequests: ["add a patient"], steps: [], stepsRecordedFor: "add a patient", finalPageTitle: nil,
                                    timesRun: 0, timesSucceeded: 0, problems: [], createdAt: Date(), lastUsed: Date(), isNamed: true)
        let updated = Plan.tasksAfterWatching([neverWorked], adding: watched)
        #expect(updated.count == 1)
        #expect(updated[0].steps.count == 7)
        #expect(updated[0].exampleRequests.contains("add a patient named Jane Doe"))
        #expect(updated[0].purpose == "Creates a new patient record")
        var worked = neverWorked
        worked.timesSucceeded = 2
        worked.timesRun = 2
        let kept = Plan.tasksAfterWatching([worked], adding: watched)
        #expect(kept[0].steps.isEmpty)
        let elsewhere = Plan.tasksAfterWatching([DottieAppTask(id: UUID(), name: "Add a patient", purpose: "", doneWhen: "", tips: [], appName: "x",
                                                               places: ["other.example"], exampleRequests: [], steps: [], stepsRecordedFor: "",
                                                               finalPageTitle: nil, timesRun: 0, timesSucceeded: 0, problems: [],
                                                               createdAt: Date(), lastUsed: Date(), isNamed: true)], adding: watched)
        #expect(elsewhere.count == 2)
    }

    @Test func twoTypedNamesGoToTheirOwnBoxes() {
        #expect(DottieAppTaskPlan.sameSpotWords(oldRequest: "add a patient named Jane Doe", oldText: "Doe", newRequest: "add a patient named John Smith") == "Smith")
        #expect(DottieAppTaskPlan.sameSpotWords(oldRequest: "add a patient named Jane Doe", oldText: "Jane", newRequest: "add a patient named John Smith") == "John")
        #expect(DottieAppTaskPlan.sameSpotWords(oldRequest: "add a patient named Jane Doe", oldText: "Jane", newRequest: "print the daily report for me please") == nil)
        #expect(DottieAppTaskPlan.sameSpotWords(oldRequest: "add Jane", oldText: "Jane", newRequest: "add a patient named John") == nil)
    }

    // MARK: Hovers

    @Test func aRestBeforeAClickElsewhereIsAHover() {
        var tracker = DottieWatchHoverTracker()
        #expect(tracker.notePointer(pointX: 0, pointY: 0, at: 0) == nil)
        #expect(tracker.notePointer(pointX: 1, pointY: 1, at: 0.3) == nil)
        let rest = tracker.notePointer(pointX: 1, pointY: 1, at: 0.6)
        #expect(rest == DottieWatchHoverTracker.Rest(pointX: 0, pointY: 0, startedAt: 0))
        #expect(tracker.notePointer(pointX: 1, pointY: 1, at: 0.9) == nil)
        #expect(tracker.restBeforeClick(pointX: 100, pointY: 0, at: 1.5) == rest)
        #expect(tracker.restBeforeClick(pointX: 100, pointY: 0, at: 1.6) == nil)
    }

    @Test func aClickOnTheRestingSpotOrMuchLaterIsNotAHover() {
        var tracker = DottieWatchHoverTracker()
        _ = tracker.notePointer(pointX: 0, pointY: 0, at: 0)
        _ = tracker.notePointer(pointX: 0, pointY: 0, at: 0.5)
        #expect(tracker.restBeforeClick(pointX: 5, pointY: 5, at: 1) == nil)
        _ = tracker.notePointer(pointX: 300, pointY: 300, at: 2)
        _ = tracker.notePointer(pointX: 300, pointY: 300, at: 2.5)
        #expect(tracker.restBeforeClick(pointX: 0, pointY: 0, at: 20) == nil)
    }

    // MARK: Journeys

    /// A tour showed "add a patient"; the next request with new names is
    /// found, done from memory step by step with the new names typed, and
    /// the private box left for Jev.
    @Test func journeyFromAWatchedTourToAddingAnotherPatient() throws {
        let watchedTasks = Plan.appTasks(from: addPatientUnderstanding, actions: addPatientActions, now: Date())
        let allTasks = Plan.tasksAfterWatching([], adding: watchedTasks)
        let request = "add a patient named John Smith"
        let found = try #require(DottieAppTaskPlan.bestTask(forRequest: request, placeKeys: ["localhost"], among: allTasks))
        #expect(DottieAppTaskPlan.isWorthReplaying(found))
        let controls = [
            DottieJevDriverPlan.ScreenControl(label: "Patient", kind: "menu item", centerX: 500, centerY: 300),
            DottieJevDriverPlan.ScreenControl(label: "First Name", kind: "text box", centerX: 400, centerY: 300),
            DottieJevDriverPlan.ScreenControl(label: "Last Name", kind: "text box", centerX: 600, centerY: 300),
            DottieJevDriverPlan.ScreenControl(label: "SSN", kind: "text box", centerX: 500, centerY: 320)
        ]
        func replay(_ step: DottieAppTaskStep) -> DottieAppTaskPlan.ReplayStep {
            DottieAppTaskPlan.replayStep(step, recordedForRequest: found.stepsRecordedFor, newRequest: request, screenTexts: [],
                                         screenControls: controls, frontSiteHost: "localhost", frontAppName: "Google Chrome")
        }
        #expect(replay(found.steps[0]) == .move(.hover(label: "Patient", centerX: 500, centerY: 300)))
        #expect(replay(found.steps[2]) == .move(.typeIntoField(fieldLabel: "First Name", centerX: 400, centerY: 300, text: "John", pressesReturn: false)))
        #expect(replay(found.steps[4]) == .move(.typeIntoField(fieldLabel: "Last Name", centerX: 600, centerY: 300, text: "Smith", pressesReturn: false)))
        #expect(replay(found.steps[5]) == .jevTakesIt)
        // On another site nothing is found.
        #expect(DottieAppTaskPlan.bestTask(forRequest: request, placeKeys: ["youtube.com"], among: allTasks) == nil)
    }

    /// A long tour with notes: cut into parts, each part's message built,
    /// the answers merged into one tour how-to with its pages, found again
    /// for a job on the same site.
    @Test func journeyFromALongNarratedTourToAJobsNotes() {
        var actions: [DottieWatchedAction] = [action(.place, "Google Chrome: localhost")]
        for pageIndex in 0..<12 {
            actions.append(action(.narration, text: "this is page \(pageIndex)", page: "Page \(pageIndex)", seconds: Double(pageIndex * 30)))
            for clickIndex in 0..<6 {
                actions.append(action(.click, "Control \(clickIndex)", page: "Page \(pageIndex)", seconds: Double(pageIndex * 30 + clickIndex)))
            }
        }
        let parts = Plan.tourParts(of: actions)
        #expect(parts.count <= 6)
        let prompts = parts.enumerated().map { index, part in
            Plan.partPrompt(actions: actions, part: part, partNumber: index + 1, partCount: parts.count, screenTexts: [], note: "",
                            sendsTypedText: true, droppedActionCount: 0)
        }
        #expect(prompts.allSatisfy { $0.contains("NOTE from the person showing you") })
        let answers = parts.indices.map { index in
            Plan.Understanding(name: index == 0 ? "OpenEMR tour" : "Part", app: "OpenEMR", summary: "Part \(index).", goal: "", method: [],
                               interfaceNotes: [], worksFor: "", pages: [DottieWatchedHowToPage(name: "Page \(index)", whatItIs: "page \(index)", howToGetThere: "", keyControls: [])],
                               tasks: [])
        }
        let merged = Plan.mergedUnderstanding(answers)
        #expect(merged?.pages.count == parts.count)
        let tour = DottieWatchedHowTo(learnedAt: Date(), name: merged!.name, appName: "OpenEMR", summary: merged!.summary, goal: "", method: [],
                                      interfaceNotes: [], worksFor: "", skillName: nil, kind: "tour", places: ["localhost"], pages: merged!.pages,
                                      exampleRequests: nil)
        #expect(Plan.howToFits(tour, taskText: "book an appointment", frontmostAppName: "Google Chrome", frontPlaceKey: "localhost"))
    }
}
