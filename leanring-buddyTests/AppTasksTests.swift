//
//  AppTasksTests.swift
//  leanring-buddyTests
//
//  Named app tasks: Jev's moves kept as steps (typed request words marked),
//  a saved step done again on a changed screen, the new request's words put
//  where the old one's were typed, matching a request to a task in its app,
//  counting, problems and what fixed them, naming and merging, the texts
//  for the models, and whole journeys from a first job to a stale replay.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct AppTasksTests {
    private typealias Plan = DottieAppTaskPlan
    private typealias Move = DottieJevDriverPlan.Move

    private func recording(_ moves: [Move], request: String, placeKey: String = "youtube.com",
                           placeName: String = "youtube.com", bundleIdentifier: String = "com.google.chrome") -> DottieAppTaskRecording {
        var recording = DottieAppTaskRecording()
        for move in moves {
            if let step = Plan.step(from: move, pageTitle: "YouTube", requestText: request) {
                recording.note(step, placeKey: placeKey, placeName: placeName, bundleIdentifier: bundleIdentifier)
            }
        }
        recording.finalPageTitle = "Results"
        return recording
    }

    private let searchMoves: [Move] = [
        .clickControl(label: "Search", kind: "text box", centerX: 500, centerY: 60),
        .typeIntoField(fieldLabel: "Search", centerX: 500, centerY: 60, text: "cats", pressesReturn: true),
        .click(label: "Filters", centerX: 900, centerY: 150)
    ]

    private func savedTask(request: String = "search youtube for cats") -> DottieAppTask {
        Plan.taskAfterSuccess(nil, request: request, recording: recording(searchMoves, request: request), pathProblem: nil, now: Date())!
    }

    // MARK: Steps from moves

    @Test func movesBecomeStepsAndTypedRequestWordsAreMarked() {
        let steps = recording(searchMoves, request: "search youtube for cats").steps
        #expect(steps.map(\.kind) == [.click, .typeIntoField, .click])
        #expect(steps[0].role == "text box")
        #expect(steps[1].text == "cats")
        #expect(steps[1].textCameFromRequest)
        #expect(steps[1].pressesReturn)
    }

    @Test func typedTextNotInTheRequestIsKeptAsIs() {
        let step = Plan.step(from: .typeText("Quarterly totals", pressesReturn: false), pageTitle: "Sheet", requestText: "rename the column")
        #expect(step?.textCameFromRequest == false)
        #expect(Plan.textToType(for: step!, recordedForRequest: "rename the column", newRequest: "rename another column") == "Quarterly totals")
    }

    @Test func movesThatAreNotStepsAreLeftOut() {
        #expect(Plan.step(from: .finished, pageTitle: "", requestText: "") == nil)
        #expect(Plan.step(from: .recallAppMemory, pageTitle: "", requestText: "") == nil)
        #expect(Plan.step(from: .clickUnlabeled, pageTitle: "", requestText: "")?.kind == .jevPicks)
    }

    // MARK: Doing a step again

    @Test func aSavedClickLandsWhereTheLabelIsNow() {
        let step = Plan.step(from: .click(label: "Inbox (3)", centerX: 100, centerY: 200), pageTitle: "Mail", requestText: "open my inbox")!
        let screenTexts = [DottieJevDriverPlan.ScreenText(text: "Inbox (7)", centerX: 120, centerY: 230)]
        let replayStep = Plan.replayStep(step, recordedForRequest: "open my inbox", newRequest: "open my inbox",
                                         screenTexts: screenTexts, screenControls: [], frontSiteHost: nil, frontAppName: "Mail")
        #expect(replayStep == .move(.click(label: "Inbox (7)", centerX: 120, centerY: 230)))
    }

    @Test func aSavedClickNotOnScreenSaysSo() {
        let step = Plan.step(from: .click(label: "Rename", centerX: 100, centerY: 200), pageTitle: "Sheet", requestText: "rename it")!
        let replayStep = Plan.replayStep(step, recordedForRequest: "rename it", newRequest: "rename it",
                                         screenTexts: [DottieJevDriverPlan.ScreenText(text: "Delete", centerX: 100, centerY: 200)],
                                         screenControls: [], frontSiteHost: nil, frontAppName: nil)
        #expect(replayStep == .notOnScreen)
    }

    @Test func aNamedControlIsClickedAsAControl() {
        let step = Plan.step(from: .clickControl(label: "New query", kind: "button", centerX: 80, centerY: 90), pageTitle: "DB", requestText: "x")!
        let controls = [DottieJevDriverPlan.ScreenControl(label: "New query", kind: "button", centerX: 82, centerY: 95)]
        let replayStep = Plan.replayStep(step, recordedForRequest: "x", newRequest: "x", screenTexts: [], screenControls: controls,
                                         frontSiteHost: nil, frontAppName: nil)
        #expect(replayStep == .move(.clickControl(label: "New query", kind: "button", centerX: 82, centerY: 95)))
    }

    @Test func theNewRequestsWordsGoWhereTheOldOnesWereTyped() {
        #expect(Plan.slotValue(oldRequest: "search youtube for cats", oldText: "cats", newRequest: "search youtube for funny dogs") == "funny dogs")
        #expect(Plan.slotValue(oldRequest: "Rename the column to Totals.", oldText: "Totals", newRequest: "rename the column to Sales") == "Sales")
        #expect(Plan.slotValue(oldRequest: "search youtube for cats", oldText: "cats", newRequest: "play some music") == nil)
    }

    @Test func typingTheRequestsWordsUsesTheNewWordsOrHandsToJev() {
        let typingStep = recording(searchMoves, request: "search youtube for cats").steps[1]
        let controls = [DottieJevDriverPlan.ScreenControl(label: "Search", kind: "text box", centerX: 500, centerY: 60)]
        let sameWording = Plan.replayStep(typingStep, recordedForRequest: "search youtube for cats", newRequest: "search youtube for dogs",
                                          screenTexts: [], screenControls: controls, frontSiteHost: "youtube.com", frontAppName: nil)
        #expect(sameWording == .move(.typeIntoField(fieldLabel: "Search", centerX: 500, centerY: 60, text: "dogs", pressesReturn: true)))
        let otherWording = Plan.replayStep(typingStep, recordedForRequest: "search youtube for cats", newRequest: "find dog videos on youtube",
                                           screenTexts: [], screenControls: controls, frontSiteHost: "youtube.com", frontAppName: nil)
        #expect(otherWording == .jevTakesIt)
    }

    @Test func openingASiteOrAppAlreadyInFrontIsSkipped() {
        let siteStep = Plan.step(from: .openSite(address: "www.youtube.com"), pageTitle: "", requestText: "x")!
        #expect(Plan.replayStep(siteStep, recordedForRequest: "x", newRequest: "x", screenTexts: [], screenControls: [],
                                frontSiteHost: "youtube.com", frontAppName: "Chrome") == .alreadyDone)
        #expect(Plan.replayStep(siteStep, recordedForRequest: "x", newRequest: "x", screenTexts: [], screenControls: [],
                                frontSiteHost: "github.com", frontAppName: "Chrome") == .move(.openSite(address: "www.youtube.com")))
        let appStep = Plan.step(from: .openApp(name: "Notes"), pageTitle: "", requestText: "x")!
        #expect(Plan.replayStep(appStep, recordedForRequest: "x", newRequest: "x", screenTexts: [], screenControls: [],
                                frontSiteHost: nil, frontAppName: "notes") == .alreadyDone)
    }

    @Test func plainStepsAreDoneAsTheyAre() {
        let keysStep = Plan.step(from: .pressKeys(keys: "cmd+s", meaning: "save"), pageTitle: "", requestText: "save it")!
        #expect(Plan.replayStep(keysStep, recordedForRequest: "save it", newRequest: "save it", screenTexts: [], screenControls: [],
                                frontSiteHost: nil, frontAppName: nil) == .move(.pressKeys(keys: "cmd+s", meaning: "save")))
        let scrollStep = Plan.step(from: .scrollDown, pageTitle: "", requestText: "")!
        #expect(Plan.replayStep(scrollStep, recordedForRequest: "", newRequest: "", screenTexts: [], screenControls: [],
                                frontSiteHost: nil, frontAppName: nil) == .move(.scrollDown))
        let iconStep = Plan.step(from: .clickUnlabeled, pageTitle: "", requestText: "")!
        #expect(Plan.replayStep(iconStep, recordedForRequest: "", newRequest: "", screenTexts: [], screenControls: [],
                                frontSiteHost: nil, frontAppName: nil) == .jevTakesIt)
    }

    @Test func riskyStepsAreLeftToJevUnlessTheRequestAsks() {
        let deleteStep = Plan.step(from: .click(label: "Delete rows", centerX: 300, centerY: 300), pageTitle: "Sheet", requestText: "delete the old rows")!
        let screenTexts = [DottieJevDriverPlan.ScreenText(text: "Delete rows", centerX: 300, centerY: 300)]
        #expect(Plan.replayStep(deleteStep, recordedForRequest: "delete the old rows", newRequest: "find the old rows",
                                screenTexts: screenTexts, screenControls: [], frontSiteHost: nil, frontAppName: nil) == .jevTakesIt)
        #expect(Plan.replayStep(deleteStep, recordedForRequest: "delete the old rows", newRequest: "delete the empty rows",
                                screenTexts: screenTexts, screenControls: [], frontSiteHost: nil, frontAppName: nil)
                == .move(.click(label: "Delete rows", centerX: 300, centerY: 300)))
        let quitStep = Plan.step(from: .pressKeys(keys: "cmd+q", meaning: "quit"), pageTitle: "", requestText: "quit it")!
        #expect(Plan.replayStep(quitStep, recordedForRequest: "quit it", newRequest: "quit it", screenTexts: [], screenControls: [],
                                frontSiteHost: nil, frontAppName: nil) == .jevTakesIt)
    }

    // MARK: Matching

    @Test func aRequestForTheSameTaskInItsPlaceFindsIt() {
        let task = savedTask()
        #expect(Plan.bestTask(forRequest: "search youtube for dogs", placeKeys: ["youtube.com"], among: [task])?.id == task.id)
    }

    @Test func aDifferentTaskIsNotMatched() {
        let task = savedTask()
        #expect(Plan.bestTask(forRequest: "rename the sales column", placeKeys: ["youtube.com"], among: [task]) == nil)
    }

    @Test func elsewhereTheRequestMustFitBetter() {
        let task = savedTask()
        #expect(Plan.bestTask(forRequest: "search youtube for dogs", placeKeys: ["com.apple.notes"], among: [task]) == nil)
        #expect(Plan.bestTask(forRequest: "search youtube for cats", placeKeys: ["com.apple.notes"], among: [task])?.id == task.id)
    }

    @Test func theRequestsSitesCountAsItsPlaces() {
        let keys = Plan.placeKeys(frontPlaceKey: "com.apple.finder", requestText: "search youtube.com for cats")
        #expect(keys.contains("youtube.com"))
        #expect(keys.contains("com.apple.finder"))
        #expect(Plan.placeKey(siteHost: "www.YouTube.com", bundleIdentifier: "com.google.Chrome") == "youtube.com")
        #expect(Plan.placeKey(siteHost: nil, bundleIdentifier: "com.apple.Notes") == "com.apple.notes")
    }

    @Test func aTaskThatKeepsFailingIsNotReplayed() {
        var task = savedTask()
        #expect(Plan.isWorthReplaying(task))
        for _ in 0..<3 { task = Plan.taskAfterFailure(task, request: "search youtube for x", problem: nil, now: Date()) }
        #expect(!Plan.isWorthReplaying(task))
    }

    // MARK: Counting and problems

    @Test func aNewTaskStartsWithItsFirstSuccess() {
        let task = savedTask()
        #expect(task.timesRun == 1 && task.timesSucceeded == 1)
        #expect(task.appName == "youtube.com")
        #expect(task.places == ["youtube.com"])
        #expect(task.name == "Search youtube for cats")
        #expect(!task.isNamed)
    }

    @Test func tooLongAJobIsNotKeptAsATask() {
        let manyMoves = (0...Plan.maximumStepsPerTask).map { Move.click(label: "Item \($0)", centerX: 10, centerY: 10) }
        #expect(Plan.taskAfterSuccess(nil, request: "x", recording: recording(manyMoves, request: "x"), pathProblem: nil, now: Date()) == nil)
    }

    @Test func aProblemIsClosedWithWhatWorkedInstead() {
        let task = savedTask()
        let problem = DottieAppTaskProblem(stepNumber: 3, expected: "click \"Filters\"", whatHappened: "it wasn't on the screen", fix: nil, seenAt: Date())
        let newMoves = Array(searchMoves.prefix(2)) + [Move.click(label: "Search filters", centerX: 880, centerY: 160)]
        let updatedTask = Plan.taskAfterSuccess(task, request: "search youtube for dogs", recording: recording(newMoves, request: "search youtube for dogs"),
                                                pathProblem: problem, now: Date())!
        #expect(updatedTask.timesSucceeded == 2)
        #expect(updatedTask.problems.last?.fix == "click \"Search filters\"")
        #expect(updatedTask.steps.last?.label == "Search filters")
        #expect(updatedTask.stepsRecordedFor == "search youtube for dogs")
        #expect(updatedTask.exampleRequests == ["search youtube for cats", "search youtube for dogs"])
    }

    @Test func onlyTheNewestProblemsAndExamplesAreKept() {
        var problems: [DottieAppTaskProblem] = []
        for number in 1...10 {
            problems = Plan.keptProblems(problems, adding: DottieAppTaskProblem(stepNumber: number, expected: "", whatHappened: "", fix: nil, seenAt: Date()))
        }
        #expect(problems.count == Plan.maximumProblemsKept)
        #expect(problems.last?.stepNumber == 10)
        var examples: [String] = []
        for number in 1...9 { examples = Plan.keptExamples(examples, adding: "ask \(number)") }
        #expect(examples.count == Plan.maximumExampleRequests)
        #expect(Plan.keptExamples(examples, adding: "ASK 9").last == "ASK 9")
    }

    // MARK: Naming

    @Test func theNamingAnswerIsRead() {
        let naming = Plan.naming(fromAnswer: "Here: {\"name\":\"Search for videos\",\"purpose\":\"finds videos\",\"done_when\":\"results show\",\"tips\":[\"use the box at the top\",\"\",\"x\",\"y\"]}")
        #expect(naming?.name == "Search for videos")
        #expect(naming?.doneWhen == "results show")
        #expect(naming?.tips == ["use the box at the top", "x"])
        #expect(Plan.naming(fromAnswer: "no json here") == nil)
        #expect(Plan.naming(fromAnswer: "{\"name\":\"  \"}") == nil)
    }

    @Test func namingATaskTheSameAsAnotherMergesThem() {
        var olderTask = savedTask()
        olderTask.name = "Search for videos"
        olderTask.isNamed = true
        let newerTask = savedTask(request: "look up dogs on youtube")
        let naming = Plan.Naming(name: "search for videos", purpose: "finds videos", doneWhen: "", tips: [])
        let merged = Plan.tasksAfterNaming([olderTask, newerTask], namedTaskID: newerTask.id, naming: naming)
        #expect(merged.count == 1)
        #expect(merged[0].id == olderTask.id)
        #expect(merged[0].timesRun == 2)
        #expect(merged[0].exampleRequests.contains("look up dogs on youtube"))
        #expect(merged[0].purpose == "finds videos")
    }

    @Test func namingANewTaskGivesItItsName() {
        let task = savedTask()
        let named = Plan.tasksAfterNaming([task], namedTaskID: task.id,
                                          naming: Plan.Naming(name: "Search for videos", purpose: "p", doneWhen: "d", tips: ["t"]))
        #expect(named[0].name == "Search for videos" && named[0].isNamed && named[0].tips == ["t"])
    }

    @Test func theNamingPromptAsksForTheAppsOwnWords() {
        let task = savedTask()
        let prompt = Plan.namingPrompt(appName: "YouTube", request: task.stepsRecordedFor, steps: task.steps, finalPageTitle: "Results",
                                       knownNames: ["Upload a video"])
        #expect(prompt.contains("the way people who use YouTube say it"))
        #expect(prompt.contains("Upload a video"))
        #expect(prompt.contains("type the request's words (last time \"cats\") into \"Search\" and press Return"))
    }

    // MARK: Texts and cards

    @Test func theKnowledgeTextHasStepsDoneCheckAndProblems() {
        var task = savedTask()
        task.name = "Search for videos"
        task.doneWhen = "the results page shows"
        task.problems = [DottieAppTaskProblem(stepNumber: 3, expected: "click \"Filters\"", whatHappened: "it wasn't there",
                                              fix: "click \"Search filters\"", seenAt: Date())]
        let text = Plan.knowledgeText(for: task)
        #expect(text.contains("\"Search for videos\""))
        #expect(text.contains("It worked 1 of 1 times"))
        #expect(text.contains("1. click the text box \"Search\""))
        #expect(text.contains("Done when: the results page shows"))
        #expect(text.contains("what worked instead: click \"Search filters\""))
        #expect(text.count <= Plan.maximumKnowledgeCharacters + 1)
    }

    @Test func aCardIsWrittenOnceThenAfterAMonthOrThreeNewTasks() {
        let now = Date()
        #expect(Plan.cardIsDue(nil, taskCountNow: 1, now: now))
        #expect(!Plan.cardIsDue(nil, taskCountNow: 0, now: now))
        let card = DottieAppCard(appName: "YouTube", text: "t", madeAt: now, taskCountWhenMade: 1)
        #expect(!Plan.cardIsDue(card, taskCountNow: 3, now: now))
        #expect(Plan.cardIsDue(card, taskCountNow: 4, now: now))
        #expect(Plan.cardIsDue(card, taskCountNow: 1, now: now.addingTimeInterval(Plan.cardRefreshInterval + 1)))
        #expect(Plan.cardKnowledgeText(card).hasPrefix("How YouTube works"))
    }

    @Test func theCardPromptListsWhatWasSeenAndTheTasks() {
        var task = savedTask()
        task.name = "Search for videos"
        let prompt = Plan.cardPrompt(appName: "YouTube", memoryLines: ["Page \"Home\""], tasks: [task])
        #expect(prompt.contains("Page \"Home\""))
        #expect(prompt.contains("- Search for videos"))
        #expect(prompt.contains("At most 120 words"))
    }

    @Test func theRecordingKnowsWhereMostStepsHappened() {
        var recording = DottieAppTaskRecording()
        let step = Plan.step(from: .scrollDown, pageTitle: "", requestText: "")!
        recording.note(step, placeKey: "com.apple.finder", placeName: "Finder", bundleIdentifier: "com.apple.finder")
        recording.note(step, placeKey: "notion.so", placeName: "notion.so", bundleIdentifier: "com.google.chrome")
        recording.note(step, placeKey: "notion.so", placeName: "notion.so", bundleIdentifier: "com.google.chrome")
        #expect(recording.mainPlaceKey == "notion.so")
        #expect(recording.mainPlaceName == "notion.so")
        recording.dropLastStep()
        recording.dropLastStep()
        #expect(recording.mainPlaceKey == "com.apple.finder")
        #expect(recording.places == ["com.apple.finder"])
    }

    // MARK: Following saved steps

    @Test func jevsMoveCountsAsTheSavedStepItWasAskedToTake() {
        let typingStep = recording(searchMoves, request: "search youtube for cats").steps[1]
        #expect(DottieAppTaskPathReplay.jevMoveIsTheStep(.typeText("dogs", pressesReturn: true), step: typingStep, requestText: "dogs"))
        #expect(!DottieAppTaskPathReplay.jevMoveIsTheStep(.scrollDown, step: typingStep, requestText: "dogs"))
        let clickStep = recording(searchMoves, request: "x").steps[2]
        #expect(DottieAppTaskPathReplay.jevMoveIsTheStep(.click(label: "Filters", centerX: 1, centerY: 1), step: clickStep, requestText: "x"))
        #expect(!DottieAppTaskPathReplay.jevMoveIsTheStep(.click(label: "Home", centerX: 1, centerY: 1), step: clickStep, requestText: "x"))
    }

    @Test func thePathReplayCountsStepsAndWritesJevANote() {
        var pathReplay = DottieAppTaskPathReplay(task: savedTask())
        #expect(pathReplay.currentStep?.kind == .click)
        pathReplay.advance()
        #expect(pathReplay.problemWithStepJustDone("it changed nothing", now: Date()).stepNumber == 1)
        #expect(pathReplay.problemWithCurrentStep("missing", now: Date()).stepNumber == 2)
        let note = pathReplay.noteForJev(reason: "its next step wasn't on the screen")
        #expect(note.contains("got to step 2 of 3"))
        #expect(note.contains("click \"Filters\""))
        pathReplay.advance()
        pathReplay.advance()
        #expect(pathReplay.isDone)
        #expect(pathReplay.currentStep == nil)
    }

    // MARK: Journeys

    /// A first job becomes a task; the next request for it replays every
    /// step on a slightly changed screen with its own words; a later
    /// screen without one step hands that step to Jev, and the way Jev
    /// found is kept with the problem.
    @Test func aTaskFromFirstJobToReplayToTroubleshooting() {
        var tasks: [DottieAppTask] = []
        let firstTask = savedTask()
        tasks = [firstTask]

        // Second request: found, every step done from memory.
        let secondRequest = "search youtube for dogs"
        let found = Plan.bestTask(forRequest: secondRequest, placeKeys: ["youtube.com"], among: tasks)!
        let controls = [DottieJevDriverPlan.ScreenControl(label: "Search", kind: "text box", centerX: 505, centerY: 62)]
        let texts = [DottieJevDriverPlan.ScreenText(text: "Filters", centerX: 905, centerY: 152)]
        var pathReplay = DottieAppTaskPathReplay(task: found)
        var doneMoves: [Move] = []
        while let step = pathReplay.currentStep {
            guard case .move(let move) = Plan.replayStep(step, recordedForRequest: found.stepsRecordedFor, newRequest: secondRequest,
                                                        screenTexts: texts, screenControls: controls,
                                                        frontSiteHost: "youtube.com", frontAppName: "Chrome") else {
                Issue.record("a saved step didn't fit the screen")
                return
            }
            doneMoves.append(move)
            pathReplay.advance()
        }
        #expect(doneMoves[1] == .typeIntoField(fieldLabel: "Search", centerX: 505, centerY: 62, text: "dogs", pressesReturn: true))
        let afterSecond = Plan.taskAfterSuccess(found, request: secondRequest, recording: recording(doneMoves, request: secondRequest),
                                                pathProblem: nil, now: Date())!
        #expect(afterSecond.timesSucceeded == 2)

        // Third request: the Filters button is gone; Jev finds another way.
        let thirdRequest = "search youtube for birds"
        var thirdReplay = DottieAppTaskPathReplay(task: afterSecond)
        thirdReplay.advance()
        thirdReplay.advance()
        let missing = Plan.replayStep(thirdReplay.currentStep!, recordedForRequest: afterSecond.stepsRecordedFor, newRequest: thirdRequest,
                                      screenTexts: [DottieJevDriverPlan.ScreenText(text: "Sort by", centerX: 900, centerY: 150)],
                                      screenControls: controls, frontSiteHost: "youtube.com", frontAppName: "Chrome")
        #expect(missing == .notOnScreen)
        let problem = thirdReplay.problemWithCurrentStep("it wasn't on the screen", now: Date())
        let jevMoves = Array(searchMoves.prefix(2)) + [Move.click(label: "Sort by", centerX: 900, centerY: 150)]
        let afterThird = Plan.taskAfterSuccess(afterSecond, request: thirdRequest, recording: recording(jevMoves, request: thirdRequest),
                                               pathProblem: problem, now: Date())!
        #expect(afterThird.timesSucceeded == 3)
        #expect(afterThird.problems.count == 1)
        #expect(afterThird.problems[0].fix == "click \"Sort by\"")
        #expect(Plan.knowledgeText(for: afterThird).contains("Problems before: step 3 (click \"Filters\")"))
    }
}
