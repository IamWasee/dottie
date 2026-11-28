//
//  AppNotesTests.swift
//  leanring-buddyTests
//
//  Teaching Dottie by typing in Home → Admin: every app and site she knows
//  listed once from app memory, tasks, how-tos and notes; a typed name
//  turned into a place; the teaching call's prompt and answer; taught tasks
//  merged into the ones she has; the user's words reaching a job; and
//  forgetting one app or site everywhere.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct AppNotesTests {
    private typealias Plan = DottieAppNotesPlan

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ name: String, places: [String], appName: String = "OpenEMR", lastUsed: Date? = nil) -> DottieAppTask {
        DottieAppTask(id: UUID(), name: name, purpose: "", doneWhen: "", tips: [], appName: appName, places: places,
                      exampleRequests: [name], steps: [], stepsRecordedFor: name, finalPageTitle: nil, timesRun: 1,
                      timesSucceeded: 1, problems: [], createdAt: now, lastUsed: lastUsed ?? now, isNamed: true)
    }

    private func note(_ text: String, placeKey: String = "localhost", minutesAgo: Double = 0) -> DottieAppNote {
        DottieAppNote(id: UUID(), placeKey: placeKey, appName: "OpenEMR", text: text, writtenAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func page(_ key: String, lastSeen: Date) -> DottieAppPage {
        DottieAppPage(key: key, title: "Page", elements: [], clicks: [], lastSeen: lastSeen, screenshotFileName: nil)
    }

    // MARK: The list of places

    @Test func aBrowsersPagesAreSplitBySite() {
        let pages = [
            page("com.google.chrome|localhost|patient finder", lastSeen: now),
            page("com.google.chrome|localhost|calendar", lastSeen: now.addingTimeInterval(-60)),
            page("com.google.chrome|www.youtube.com|youtube", lastSeen: now),
            page("com.google.chrome||new tab", lastSeen: now)
        ]
        let places = Plan.memoryPlaces(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome", pages: pages)
        let byKey = Dictionary(uniqueKeysWithValues: places.map { ($0.placeKey, $0) })
        #expect(byKey["localhost"]?.pagesSeen == 2)
        #expect(byKey["localhost"]?.lastSeen == now)
        #expect(byKey["youtube.com"]?.pagesSeen == 1)
        #expect(byKey["com.google.chrome"]?.appName == "Google Chrome")
    }

    @Test func everythingDottieKnowsIsListedOncePerPlace() {
        let memory = [Plan.MemoryPlace(placeKey: "localhost", appName: "localhost", pagesSeen: 12, lastSeen: now.addingTimeInterval(-3600))]
        let tasks = [task("Add a patient", places: ["localhost"]), task("Book an appointment", places: ["localhost"]),
                     task("Play a video", places: ["youtube.com"], appName: "youtube.com", lastUsed: now.addingTimeInterval(-7200))]
        let howTo = DottieWatchedHowTo(learnedAt: now, name: "OpenEMR tour", appName: "OpenEMR", summary: "", goal: "", method: [],
                                       interfaceNotes: [], worksFor: "", kind: "tour", places: ["localhost"])
        let places = Plan.knownPlaces(tasks: tasks, howTos: [howTo], memoryPlaces: memory,
                                      notes: [note("left menu has Patient")], cardPlaceKeys: ["localhost"])
        #expect(places.count == 2)
        let openEMR = places[0]
        #expect(openEMR.placeKey == "localhost")
        #expect(openEMR.pagesSeen == 12)
        #expect(openEMR.taskCount == 2)
        #expect(openEMR.howToCount == 1)
        #expect(openEMR.noteCount == 1)
        #expect(openEMR.hasCard)
        #expect(places[1].placeKey == "youtube.com")
        #expect(!places[1].hasCard)
    }

    @Test func aTaskWithNoPlaceIsListedUnderItsApp() {
        let places = Plan.knownPlaces(tasks: [task("Rename a column", places: [], appName: "Numbers")], howTos: [],
                                      memoryPlaces: [], notes: [], cardPlaceKeys: [])
        #expect(places.map(\.placeKey) == ["numbers"])
    }

    @Test func nothingKnownListsNothing() {
        #expect(Plan.knownPlaces(tasks: [], howTos: [], memoryPlaces: [], notes: [], cardPlaceKeys: ["x"]).isEmpty)
    }

    // MARK: Typed names

    @Test func aTypedNameFindsAKnownPlaceOrAWebAddress() {
        let known = [DottieKnownPlace(placeKey: "localhost", appName: "OpenEMR", pagesSeen: 1, taskCount: 0, howToCount: 0,
                                      noteCount: 0, hasCard: false, lastSeen: nil)]
        #expect(Plan.placeKey(forTypedName: "openemr", knownPlaces: known)?.placeKey == "localhost")
        #expect(Plan.placeKey(forTypedName: " localhost ", knownPlaces: known)?.appName == "OpenEMR")
        #expect(Plan.placeKey(forTypedName: "https://www.Notion.so/my-page", knownPlaces: [])?.placeKey == "notion.so")
        #expect(Plan.placeKey(forTypedName: "localhost:8300/openemr", knownPlaces: [])?.placeKey == "localhost")
        #expect(Plan.placeKey(forTypedName: "mail.google.com", knownPlaces: [])?.placeKey == "mail.google.com")
        #expect(Plan.placeKey(forTypedName: "Final Cut Pro", knownPlaces: []) == nil)
        #expect(Plan.placeKey(forTypedName: "   ", knownPlaces: known) == nil)
    }

    // MARK: The teaching call

    @Test func thePromptCarriesTheNotesTheCardAndKnownTasks() {
        let prompt = Plan.teachingPrompt(appName: "OpenEMR", noteText: "Patient → New/Search opens the new patient form",
                                         existingCard: "OpenEMR keeps patient records.", knownTaskNames: ["Add a patient"])
        #expect(prompt.contains("Patient → New/Search"))
        #expect(prompt.contains("OpenEMR keeps patient records."))
        #expect(prompt.contains("Add a patient"))
        #expect(prompt.contains("never invent"))
        #expect(prompt.contains("passwords"))
        let fresh = Plan.teachingPrompt(appName: "Notion", noteText: "x", existingCard: nil, knownTaskNames: [])
        #expect(fresh.contains("no card on it yet"))
        #expect(fresh.contains("No tasks known"))
    }

    @Test func aLongNoteIsCutInThePrompt() {
        let prompt = Plan.teachingPrompt(appName: "OpenEMR", noteText: String(repeating: "a", count: 10_000), existingCard: nil, knownTaskNames: [])
        #expect(prompt.count < Plan.maximumNoteCharacters + 2000)
    }

    @Test func theAnswerBecomesACardAndTasks() throws {
        let answer = """
        Here you go: {"card":"OpenEMR: left menu has Patient, Calendar, Fees.","tasks":[{"name":"Add a patient","purpose":"make a new patient record",\
        "done_when":"the patient's dashboard shows","steps":["Click Patient","Click New/Search","Fill First and Last name","Click Create New Patient"],\
        "requests":["add a patient named Sam Lee"]},{"name":"","steps":["x"]}],"summary":"Learned the menu and adding a patient"}
        """
        let teaching = try #require(Plan.teaching(fromAnswer: answer))
        #expect(teaching.card.hasPrefix("OpenEMR: left menu"))
        #expect(teaching.tasks.count == 1)
        #expect(teaching.tasks[0].steps.count == 4)
        #expect(teaching.tasks[0].doneWhen == "the patient's dashboard shows")
        #expect(teaching.tasks[0].requests == ["add a patient named Sam Lee"])
        #expect(teaching.summary == "Learned the menu and adding a patient")
    }

    @Test func aBrokenOrEmptyAnswerIsNotUsed() {
        #expect(Plan.teaching(fromAnswer: "sorry, I can't") == nil)
        #expect(Plan.teaching(fromAnswer: "{\"card\":\"\",\"tasks\":[]}") == nil)
        #expect(Plan.teaching(fromAnswer: "{not json}") == nil)
    }

    @Test func tooManyTasksOrStepsAreCut() throws {
        let manySteps = (0..<30).map { "\"step \($0)\"" }.joined(separator: ",")
        let manyTasks = (0..<20).map { "{\"name\":\"Task \($0)\",\"steps\":[\(manySteps)]}" }.joined(separator: ",")
        let teaching = try #require(Plan.teaching(fromAnswer: "{\"card\":\"c\",\"tasks\":[\(manyTasks)]}"))
        #expect(teaching.tasks.count == Plan.maximumTasksFromNotes)
        #expect(teaching.tasks.allSatisfy { $0.steps.count == Plan.maximumStepsPerTaughtTask })
    }

    // MARK: Taught tasks

    @Test func aTaughtTaskIsTipsNotStepsToReplay() {
        let taught = Plan.task(from: .init(name: "Add a patient", purpose: "new record", doneWhen: "dashboard shows",
                                           steps: ["Click Patient", "Click New/Search"], requests: []),
                               placeKey: "localhost", appName: "OpenEMR", now: now)
        #expect(taught.steps.isEmpty)
        #expect(taught.learnedFromNotes == true)
        #expect(taught.tips.first?.contains("1. Click Patient 2. Click New/Search") == true)
        #expect(taught.exampleRequests == ["Add a patient"])
        #expect(!DottieAppTaskPlan.isWorthReplaying(taught))
        let knowledge = DottieAppTaskPlan.knowledgeText(for: taught)
        #expect(knowledge.contains("The user explained how to do this task"))
        #expect(!knowledge.contains("worked 0 of 0"))
        #expect(knowledge.contains("Done when: dashboard shows"))
    }

    @Test func aTaughtTaskIsFoundForAMatchingRequest() {
        let taught = Plan.task(from: .init(name: "Add a patient", purpose: "", doneWhen: "", steps: [], requests: ["add a new patient to OpenEMR"]),
                               placeKey: "localhost", appName: "OpenEMR", now: now)
        #expect(DottieAppTaskPlan.bestTask(forRequest: "add a new patient", placeKeys: ["localhost"], among: [taught])?.id == taught.id)
    }

    @Test func teachingASameNamedTaskKeepsItsRecordedSteps() throws {
        var recorded = task("Add a patient", places: ["localhost"])
        recorded.steps = [DottieAppTaskStep(kind: .click, label: "Patient", role: nil, centerX: 10, centerY: 10, text: nil,
                                            textCameFromRequest: false, pressesReturn: false, pageTitle: "OpenEMR")]
        recorded.tips = ["The user's steps: 1. old", "Wait for the form"]
        let taught = Plan.task(from: .init(name: "add a patient", purpose: "make a record", doneWhen: "dashboard", steps: ["Click Patient"],
                                           requests: ["add patient Ana"]), placeKey: "localhost", appName: "OpenEMR", now: now)
        let elsewhere = Plan.task(from: .init(name: "Add a patient", purpose: "", doneWhen: "", steps: [], requests: []),
                                  placeKey: "other.example", appName: "Other", now: now)
        let merged = Plan.tasksAfterTeaching([recorded], adding: [taught, elsewhere])
        #expect(merged.count == 2)
        let kept = try #require(merged.first { $0.id == recorded.id })
        #expect(kept.steps.count == 1)
        #expect(kept.purpose == "make a record")
        #expect(kept.tips == ["Wait for the form", "The user's steps: 1. Click Patient"])
        #expect(kept.exampleRequests.contains("add patient Ana"))
    }

    // MARK: Reaching a job

    @Test func theUsersWordsReachAJobNewestLast() {
        let text = Plan.knowledgeText(appName: "OpenEMR", notes: [note("second", minutesAgo: 1), note("first", minutesAgo: 10)])
        #expect(text.hasPrefix("What the user told Dottie about OpenEMR:"))
        #expect(text.range(of: "first")!.lowerBound < text.range(of: "second")!.lowerBound)
        #expect(Plan.knowledgeText(appName: "OpenEMR", notes: []) == "")
    }

    @Test func longNotesKeepTheirNewestEnd() {
        let text = Plan.knowledgeText(appName: "OpenEMR", notes: [note(String(repeating: "old ", count: 600), minutesAgo: 5), note("NEWEST TIP")])
        #expect(text.hasSuffix("NEWEST TIP"))
        #expect(text.count < Plan.maximumNotesKnowledgeCharacters + 100)
    }

    @Test func aRegeneratedCardKeepsTheUsersNotes() {
        let prompt = DottieAppTaskPlan.cardPrompt(appName: "OpenEMR", memoryLines: [], tasks: [],
                                                  userNotes: "What the user told Dottie about OpenEMR:\nFees is under the top menu")
        #expect(prompt.contains("Fees is under the top menu"))
        #expect(!DottieAppTaskPlan.cardPrompt(appName: "OpenEMR", memoryLines: [], tasks: []).contains("Keep what the user said"))
    }

    // MARK: Forgetting a place

    @Test func forgettingAPlaceDropsItsOwnTasksAndKeepsSharedOnes() {
        let onlyHere = task("Add a patient", places: ["localhost"])
        let shared = task("Search", places: ["localhost", "youtube.com"])
        let elsewhere = task("Play a video", places: ["youtube.com"])
        let noPlace = task("Rename a column", places: [], appName: "Numbers")
        let kept = Plan.tasksAfterForgetting([onlyHere, shared, elsewhere, noPlace], placeKey: "LOCALHOST")
        #expect(kept.map(\.id) == [shared.id, elsewhere.id, noPlace.id])
        #expect(kept[0].places == ["youtube.com"])
        #expect(Plan.tasksAfterForgetting([noPlace], placeKey: "numbers").isEmpty)
    }

    @Test func forgettingAPlaceDropsHowTosWatchedOnlyThere() {
        func howTo(_ name: String, places: [String]?) -> DottieWatchedHowTo {
            DottieWatchedHowTo(learnedAt: now, name: name, appName: "OpenEMR", summary: "", goal: "", method: [],
                               interfaceNotes: [], worksFor: "", places: places)
        }
        let tour = howTo("Tour", places: ["localhost"])
        let both = howTo("Both", places: ["localhost", "notion.so"])
        let old = howTo("Old", places: nil)
        let kept = Plan.howTosAfterForgetting([tour, both, old], placeKey: "localhost")
        #expect(kept.map(\.name) == ["Both", "Old"])
        #expect(kept[0].places == ["notion.so"])
    }

    @Test func forgettingASiteKeepsTheBrowsersOtherPages() {
        let pages = [
            "com.google.chrome|localhost|patient finder": page("com.google.chrome|localhost|patient finder", lastSeen: now),
            "com.google.chrome|www.youtube.com|youtube": page("com.google.chrome|www.youtube.com|youtube", lastSeen: now),
            "com.google.chrome||new tab": page("com.google.chrome||new tab", lastSeen: now)
        ]
        let withoutSite = Plan.pagesAfterForgetting(pages, bundleIdentifier: "com.google.Chrome", placeKey: "localhost")
        #expect(Set(withoutSite.keys) == ["com.google.chrome|www.youtube.com|youtube", "com.google.chrome||new tab"])
        let withoutYouTube = Plan.pagesAfterForgetting(pages, bundleIdentifier: "com.google.Chrome", placeKey: "youtube.com")
        #expect(withoutYouTube.count == 2)
        let withoutApp = Plan.pagesAfterForgetting(pages, bundleIdentifier: "com.google.Chrome", placeKey: "com.google.chrome")
        #expect(withoutApp.count == 2)
        #expect(Plan.pagesAfterForgetting(pages, bundleIdentifier: "com.google.Chrome", placeKey: "notion.so").count == 3)
    }

    @Test func forgettingAPlaceDropsItsNotesOnly() {
        let kept = Plan.notesAfterForgetting([note("a"), note("b", placeKey: "notion.so")], placeKey: "Localhost")
        #expect(kept.map(\.text) == ["b"])
    }

    @Test func aForgottenPlaceLeavesTheList() {
        let tasks = [task("Add a patient", places: ["localhost"]), task("Play", places: ["youtube.com"], appName: "youtube.com")]
        let notes = [note("left menu")]
        let memory = [Plan.MemoryPlace(placeKey: "localhost", appName: "localhost", pagesSeen: 3, lastSeen: now)]
        let before = Plan.knownPlaces(tasks: tasks, howTos: [], memoryPlaces: memory, notes: notes, cardPlaceKeys: ["localhost"])
        #expect(before.map(\.placeKey).contains("localhost"))
        let after = Plan.knownPlaces(tasks: Plan.tasksAfterForgetting(tasks, placeKey: "localhost"), howTos: [], memoryPlaces: [],
                                     notes: Plan.notesAfterForgetting(notes, placeKey: "localhost"), cardPlaceKeys: [])
        #expect(after.map(\.placeKey) == ["youtube.com"])
    }

    @Test func forgettingIsQuick() {
        let tasks = (0..<300).map { task("Task \($0)", places: ["site\($0 % 40).example", "shared.example"]) }
        let startedAt = Date()
        for index in 0..<40 {
            _ = Plan.tasksAfterForgetting(tasks, placeKey: "site\(index).example")
        }
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }

    @Test func listingPlacesIsQuick() {
        let tasks = (0..<300).map { task("Task \($0)", places: ["site\($0 % 40).example"]) }
        let notes = (0..<300).map { note("note \($0)", placeKey: "site\($0 % 40).example") }
        let startedAt = Date()
        for _ in 0..<20 {
            _ = Plan.knownPlaces(tasks: tasks, howTos: [], memoryPlaces: [], notes: notes, cardPlaceKeys: [])
        }
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
