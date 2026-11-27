//
//  JevAdvisorTests.swift
//  leanring-buddyTests
//
//  Jev's advisor: the brief read once per job, the moments it steps in
//  (checkpoints on screen, a time left, a user hint, a stuck job), the
//  advice it gives (pick one of Jev's options, wait, a note), how long a
//  round may wait, the call budget, a whole job with a judging step, and
//  how quick the checks Dottie runs every step are.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct JevAdvisorTests {
    private typealias Advisor = DottieJevAdvisorPlan
    private typealias Plan = DottieJevDriverPlan

    // MARK: The brief

    @Test func briefReadsStepsAndCheckpoints() throws {
        let answer = """
        Here you go:
        ```json
        {"steps":["Open youtube.com","Search for lofi","Open the most viewed video"],
         "checkpoints":[{"watch":["views"],"kind":"judge","advice":"pick the result with the most views"},
                        {"watch":["Exporting"],"kind":"WAIT","advice":"wait for the export"}]}
        ```
        """
        let brief = try #require(Advisor.brief(fromAnswer: answer))
        #expect(brief.steps == ["Open youtube.com", "Search for lofi", "Open the most viewed video"])
        #expect(brief.checkpoints.count == 2)
        #expect(brief.checkpoints[0] == Advisor.Checkpoint(watchWords: ["views"], kind: .judge, advice: "pick the result with the most views"))
        #expect(brief.checkpoints[1].kind == .wait)
    }

    @Test func briefDropsBadCheckpointsAndKeepsItShort() throws {
        let steps = (1...20).map { "\"step \($0)\"" }.joined(separator: ",")
        let answer = """
        {"steps":[\(steps)],"checkpoints":[{"watch":["a"],"kind":"dance","advice":"x"},{"watch":["b"],"kind":"judge","advice":""},
        {"watch":["one","two","three","four"],"kind":"reason","advice":"add it up"}]}
        """
        let brief = try #require(Advisor.brief(fromAnswer: answer))
        #expect(brief.steps.count == Advisor.maximumSteps)
        #expect(brief.checkpoints.count == 1)
        #expect(brief.checkpoints[0].watchWords == ["one", "two", "three"])
    }

    @Test func briefIsNilWithoutJSON() {
        #expect(Advisor.brief(fromAnswer: "I can't help with that") == nil)
        #expect(Advisor.brief(fromAnswer: "") == nil)
    }

    @Test func briefPromptNamesTheJobAndTheJSON() {
        let prompt = Advisor.briefPrompt(taskText: "open the newest email from Sam")
        #expect(prompt.contains("open the newest email from Sam"))
        #expect(prompt.contains("\"checkpoints\""))
    }

    // MARK: When it steps in

    @Test func checkpointFiresWhenItsWordsAreOnScreen() throws {
        let brief = Advisor.Brief(steps: [], checkpoints: [
            Advisor.Checkpoint(watchWords: ["views", "Filters"], kind: .judge, advice: "most views"),
            Advisor.Checkpoint(watchWords: ["Inbox"], kind: .judge, advice: "newest")
        ])
        #expect(Advisor.firedCheckpoint(in: brief, screenTexts: ["1.2M views", "lofi beats"], alreadyFired: []) == nil)
        let fired = try #require(Advisor.firedCheckpoint(in: brief, screenTexts: ["1.2M views", "Filters"], alreadyFired: []))
        #expect(fired.index == 0)
        #expect(Advisor.firedCheckpoint(in: brief, screenTexts: ["1.2M views", "Filters"], alreadyFired: [0]) == nil)
        #expect(Advisor.firedCheckpoint(in: brief, screenTexts: ["INBOX (3)"], alreadyFired: [])?.index == 1)
    }

    @Test func checkpointMatchesWholeWordsOnly() {
        let brief = Advisor.Brief(steps: [], checkpoints: [Advisor.Checkpoint(watchWords: ["view"], kind: .judge, advice: "x")])
        #expect(Advisor.firedCheckpoint(in: brief, screenTexts: ["preview"], alreadyFired: []) == nil)
        let noWords = Advisor.Brief(steps: [], checkpoints: [Advisor.Checkpoint(watchWords: [], kind: .judge, advice: "x")])
        #expect(Advisor.firedCheckpoint(in: noWords, screenTexts: ["anything"], alreadyFired: []) == nil)
    }

    @Test func stuckComesFirstThenHintThenTimeThenCheckpoint() {
        let checkpoint = Advisor.Checkpoint(watchWords: ["views"], kind: .judge, advice: "most views")
        #expect(Advisor.triggerBeforeJev(isStuck: true, newHintTexts: ["use search"], secondsShownOnScreen: 30,
                                         timeTriggerArmed: true, firedCheckpoint: checkpoint) == .moveFailed)
        #expect(Advisor.triggerBeforeJev(isStuck: false, newHintTexts: ["  ", "use search"], secondsShownOnScreen: 30,
                                         timeTriggerArmed: true, firedCheckpoint: checkpoint) == .userHint("use search"))
        #expect(Advisor.triggerBeforeJev(isStuck: false, newHintTexts: [], secondsShownOnScreen: 30,
                                         timeTriggerArmed: true, firedCheckpoint: checkpoint) == .timeShown(seconds: 30))
        #expect(Advisor.triggerBeforeJev(isStuck: false, newHintTexts: [], secondsShownOnScreen: 30,
                                         timeTriggerArmed: false, firedCheckpoint: checkpoint) == .checkpoint(checkpoint))
        #expect(Advisor.triggerBeforeJev(isStuck: false, newHintTexts: [], secondsShownOnScreen: nil,
                                         timeTriggerArmed: true, firedCheckpoint: nil) == nil)
    }

    @Test func everyTriggerSaysWhy() {
        let triggers: [Advisor.Trigger] = [
            .checkpoint(Advisor.Checkpoint(watchWords: ["a"], kind: .wait, advice: "wait for it")),
            .jevUnsure, .moveFailed, .userHint("faster please"), .timeShown(seconds: 45)
        ]
        for trigger in triggers { #expect(!trigger.reasonText.isEmpty) }
        #expect(Advisor.Trigger.userHint("faster please").reasonText.contains("faster please"))
    }

    // MARK: Advice

    @Test func adviceIsReadInEveryShape() {
        #expect(Advisor.advice(fromAnswer: #"{"do":"pick","option":3,"note":"most views"}"#, optionCount: 5) == .pick(optionNumber: 3, note: "most views"))
        #expect(Advisor.advice(fromAnswer: #"{"do":"pick","option":2}"#, optionCount: 5) == .pick(optionNumber: 2, note: nil))
        #expect(Advisor.advice(fromAnswer: #"{"do":"wait","seconds":90}"#, optionCount: 5) == .wait(seconds: 90))
        #expect(Advisor.advice(fromAnswer: #"{"do":"wait"}"#, optionCount: 5) == .wait(seconds: Advisor.defaultWaitSeconds))
        #expect(Advisor.advice(fromAnswer: #"{"do":"note","note":"use the search bar"}"#, optionCount: 5) == .note("use the search bar"))
        #expect(Advisor.advice(fromAnswer: #"{"do":"none"}"#, optionCount: 5) == Advisor.Advice.none)
    }

    @Test func badAdviceIsDropped() {
        #expect(Advisor.advice(fromAnswer: #"{"do":"pick","option":9}"#, optionCount: 5) == nil)
        #expect(Advisor.advice(fromAnswer: #"{"do":"pick","option":0}"#, optionCount: 5) == nil)
        #expect(Advisor.advice(fromAnswer: #"{"do":"note","note":"  "}"#, optionCount: 5) == nil)
        #expect(Advisor.advice(fromAnswer: #"{"do":"dance"}"#, optionCount: 5) == nil)
        #expect(Advisor.advice(fromAnswer: "no idea", optionCount: 5) == nil)
        #expect(Advisor.advice(fromAnswer: #"{"do":"wait","seconds":99999}"#, optionCount: 5) == .wait(seconds: Advisor.maximumSingleWaitSeconds))
    }

    @Test func advicePromptShowsTheScreenTopToBottomAndNumbersTheOptions() {
        let prompt = Advisor.advicePrompt(
            taskText: "open the most viewed video",
            trigger: .jevUnsure,
            screenLines: [(text: "second", centerX: 0.5, centerY: 0.6), (text: "first", centerX: 0.2, centerY: 0.1)],
            optionDescriptions: ["click \"first\"", "scroll down"],
            jobStateText: "Nothing has been done yet."
        )
        let firstIndex = prompt.range(of: "(20,10) first")?.lowerBound
        let secondIndex = prompt.range(of: "(50,60) second")?.lowerBound
        #expect(firstIndex != nil && secondIndex != nil)
        if let firstIndex, let secondIndex { #expect(firstIndex < secondIndex) }
        #expect(prompt.contains("1. click \"first\""))
        #expect(prompt.contains("2. scroll down"))
        #expect(prompt.contains("Jev isn't sure"))
    }

    @Test func advicePromptStaysShortOnABusyScreen() {
        let screenLines = (0..<500).map { (text: "line \($0)", centerX: 0.5, centerY: Double($0) / 500) }
        let options = (0..<250).map { "option \($0)" }
        let prompt = Advisor.advicePrompt(taskText: "x", trigger: .moveFailed, screenLines: screenLines, optionDescriptions: options, jobStateText: "")
        #expect(!prompt.contains("line 60\n"))
        #expect(!prompt.contains("\(Advisor.maximumOptionsShown + 1). option"))
        #expect(prompt.count < 6_000)
    }

    @Test func advisedFinishingMovesEndTheRoundOrTheJob() {
        #expect(Advisor.decision(forAdvisedMove: .scrollDown, hasRoundsLeft: false, roundHasMoves: true) == .act(.scrollDown))
        #expect(Advisor.decision(forAdvisedMove: .noneFits, hasRoundsLeft: false, roundHasMoves: true) == nil)
        #expect(Advisor.decision(forAdvisedMove: .finished, hasRoundsLeft: false, roundHasMoves: false) == .finished)
        #expect(Advisor.decision(forAdvisedMove: .finished, hasRoundsLeft: true, roundHasMoves: true) == .roundDone)
        #expect(Advisor.decision(forAdvisedMove: .finished, hasRoundsLeft: true, roundHasMoves: false) == nil)
        #expect(Advisor.decision(forAdvisedMove: .finishedRound, hasRoundsLeft: true, roundHasMoves: true) == .roundDone)
        #expect(Advisor.decision(forAdvisedMove: .finishedRound, hasRoundsLeft: true, roundHasMoves: false) == nil)
    }

    // MARK: Waiting

    @Test func timesOnScreenAreRead() {
        #expect(Advisor.secondsShown(in: ["2 min left"]) == 120)
        #expect(Advisor.secondsShown(in: ["About 45 seconds remaining"]) == 45)
        #expect(Advisor.secondsShown(in: ["1:30 remaining"]) == 90)
        #expect(Advisor.secondsShown(in: ["ETA 00:05:00"]) == 300)
        #expect(Advisor.secondsShown(in: ["Exporting... 12 seconds to go"]) == 12)
        #expect(Advisor.secondsShown(in: ["Remaining: 2 minutes"]) == 120)
        #expect(Advisor.secondsShown(in: ["Uploading 3 hrs left"]) == 10_800)
        #expect(Advisor.secondsShown(in: ["10 s left", "4 min left"]) == 240)
    }

    @Test func timesThatArentAWaitAreIgnored() {
        #expect(Advisor.secondsShown(in: ["5 min read"]) == nil)
        #expect(Advisor.secondsShown(in: ["Posted 3 hours ago"]) == nil)
        #expect(Advisor.secondsShown(in: ["1:30 / 4:00"]) == nil)
        #expect(Advisor.secondsShown(in: ["Done", ""]) == nil)
    }

    @Test func waitsUseTheScreensTimeOrAMinute() {
        #expect(Advisor.waitSeconds(shownSeconds: nil) == 60)
        #expect(Advisor.waitSeconds(shownSeconds: 90) == 90)
        #expect(Advisor.waitSeconds(shownSeconds: 1) == 5)
        #expect(Advisor.waitSeconds(shownSeconds: 10_800) == Advisor.maximumSingleWaitSeconds)
    }

    @Test func aRoundWaitsHalfAnHourAtMost() {
        #expect(Advisor.waitAllowance(requestedSeconds: 60, secondsWaitedThisRound: 0) == 60)
        #expect(Advisor.waitAllowance(requestedSeconds: 600, secondsWaitedThisRound: 1_500) == 300)
        #expect(Advisor.waitAllowance(requestedSeconds: 60, secondsWaitedThisRound: 1_800) == 0)
    }

    @Test func waitTextIsShort() {
        #expect(Advisor.waitText(seconds: 45) == "45 s")
        #expect(Advisor.waitText(seconds: 120) == "2 min")
    }

    // MARK: Notes and budget

    @Test func onlyTheNewestNotesAreKept() {
        var notes: [String] = []
        notes = Advisor.keptNotes(notes, adding: "use the search bar")
        notes = Advisor.keptNotes(notes, adding: "sort by upload date")
        notes = Advisor.keptNotes(notes, adding: "open the first result")
        #expect(notes == ["sort by upload date", "open the first result"])
        #expect(Advisor.keptNotes(notes, adding: "  ") == notes)
        #expect(Advisor.keptNotes(notes, adding: "sort by upload date") == ["open the first result", "sort by upload date"])
    }

    @Test func howToPutsThePlanAndNotesTogether() {
        let brief = Advisor.Brief(steps: ["Open Gmail", "Open the newest email"], checkpoints: [])
        let howTo = Advisor.howToText(brief: brief, notes: ["the newest is at the top"])
        #expect(howTo.contains("1. Open Gmail 2. Open the newest email"))
        #expect(howTo.contains("The advisor says now: the newest is at the top"))
        #expect(Advisor.howToText(brief: nil, notes: []).isEmpty)
    }

    @Test func adviceCallsGrowWithRoundsButAreCapped() {
        #expect(Advisor.adviceCallBudget(rounds: 1) == Advisor.baseAdviceCallsPerJob + 1)
        #expect(Advisor.adviceCallBudget(rounds: 0) == Advisor.baseAdviceCallsPerJob + 1)
        #expect(Advisor.adviceCallBudget(rounds: 100) == Advisor.baseAdviceCallsPerJob + 100)
        #expect(Advisor.adviceCallBudget(rounds: 1_000) == Advisor.maximumAdviceCallsPerJob)
    }

    // MARK: The session (no Worker calls)

    @Test func sessionFiresATimeOnceUntilItsGone() {
        let session = DottieJevAdvisorSession(taskText: "export the video", rounds: 1, asksForBrief: false)
        #expect(session.triggerBeforeJev(screenTexts: ["2 min left"], newHintTexts: [], isStuck: false) == .timeShown(seconds: 120))
        #expect(session.triggerBeforeJev(screenTexts: ["1 min left"], newHintTexts: [], isStuck: false) == nil)
        #expect(session.triggerBeforeJev(screenTexts: ["Export done"], newHintTexts: [], isStuck: false) == nil)
        #expect(session.triggerBeforeJev(screenTexts: ["3 min left"], newHintTexts: [], isStuck: false) == .timeShown(seconds: 180))
    }

    @Test func sessionWaitsAreCappedPerRound() {
        let session = DottieJevAdvisorSession(taskText: "x", rounds: 2, asksForBrief: false)
        session.noteWaited(1_700)
        #expect(session.allowedWait(600) == 100)
        session.startRound()
        #expect(session.allowedWait(600) == 600)
        #expect(session.adviceCallsLeft == Advisor.adviceCallBudget(rounds: 2))
    }

    @Test func sessionKeepsOnlyTheNewestNotesAfterAPage() {
        let session = DottieJevAdvisorSession(taskText: "x", rounds: 1, asksForBrief: false)
        session.restoreNotes(["a", "b", "c"])
        #expect(session.notes == ["b", "c"])
        session.startRound()
        #expect(session.notes.isEmpty)
    }

    // MARK: Journey: a judging step

    /// "Open the most viewed lofi video": the brief says to watch for "views";
    /// on the results page the checkpoint fires once, the advisor picks the
    /// click on the most viewed one, and Dottie does it instead of asking Jev.
    @Test func mostViewedVideoJourney() throws {
        let taskText = "open the most viewed lofi video on youtube"
        let brief = try #require(Advisor.brief(fromAnswer: #"""
        {"steps":["Search youtube for lofi","Open the most viewed video"],
         "checkpoints":[{"watch":["views"],"kind":"judge","advice":"compare the view counts and open the highest"}]}
        """#))
        let screenTexts = [
            Plan.ScreenText(text: "lofi beats to study", centerX: 400, centerY: 300),
            Plan.ScreenText(text: "120K views", centerX: 400, centerY: 330),
            Plan.ScreenText(text: "lofi hip hop radio", centerX: 400, centerY: 500),
            Plan.ScreenText(text: "48M views", centerX: 400, centerY: 530)
        ]
        let fired = try #require(Advisor.firedCheckpoint(in: brief, screenTexts: screenTexts.map(\.text), alreadyFired: []))
        let trigger = try #require(Advisor.triggerBeforeJev(isStuck: false, newHintTexts: [], secondsShownOnScreen: nil,
                                                            timeTriggerArmed: true, firedCheckpoint: fired.checkpoint))
        let options = Plan.options(screenTexts: screenTexts, textPieces: [], siteAddresses: [], appNames: [],
                                   alreadyTriedSignatures: [], taskText: taskText)
        let prompt = Advisor.advicePrompt(taskText: taskText, trigger: trigger,
                                          screenLines: screenTexts.map { (text: $0.text, centerX: $0.centerX / 1000, centerY: $0.centerY / 1000) },
                                          optionDescriptions: options.map(\.move.description), jobStateText: "Nothing has been done yet.")
        #expect(prompt.contains("48M views"))
        #expect(prompt.contains("compare the view counts"))
        let radioOptionNumber = try #require(options.firstIndex { $0.move == .click(label: "lofi hip hop radio", centerX: 400, centerY: 500) }) + 1
        let advice = try #require(Advisor.advice(fromAnswer: "{\"do\":\"pick\",\"option\":\(radioOptionNumber),\"note\":\"48M is the most\"}",
                                                 optionCount: options.count))
        guard case .pick(let optionNumber, _) = advice else { Issue.record("expected a pick"); return }
        let decision = Advisor.decision(forAdvisedMove: options[optionNumber - 1].move, hasRoundsLeft: false, roundHasMoves: true)
        #expect(decision == .act(.click(label: "lofi hip hop radio", centerX: 400, centerY: 500)))
        #expect(Advisor.firedCheckpoint(in: brief, screenTexts: screenTexts.map(\.text), alreadyFired: [fired.index]) == nil)
    }

    // MARK: Speed

    @Test func everyStepChecksAreQuick() {
        let brief = Advisor.Brief(steps: [], checkpoints: (0..<6).map {
            Advisor.Checkpoint(watchWords: ["word\($0)", "other\($0)"], kind: .judge, advice: "x")
        })
        let screenTexts = (0..<200).map { "some text on the screen number \($0) with 12 views" }
        let startedAt = Date()
        for _ in 0..<200 {
            _ = Advisor.firedCheckpoint(in: brief, screenTexts: screenTexts, alreadyFired: [])
            _ = Advisor.secondsShown(in: screenTexts)
        }
        // Runs once per Jev step, which takes about a second: 200 in a few seconds at most.
        #expect(Date().timeIntervalSince(startedAt) < 4.0)
    }

    // MARK: What Dottie knows about the app (looked up once at job start)

    @Test func theBriefAndAdviceGetWhatDottieKnowsAboutTheApp() {
        let knowledge = "How Sheets works (Dottie's card): columns are renamed from the header menu."
        #expect(Advisor.briefPrompt(taskText: "rename the column", appKnowledge: knowledge).contains("What Dottie knows about this app and task:\n" + knowledge))
        let prompt = Advisor.advicePrompt(taskText: "x", trigger: .jevUnsure, screenLines: [], optionDescriptions: [], jobStateText: "",
                                          appKnowledge: knowledge)
        #expect(prompt.contains(knowledge))
        #expect(!Advisor.briefPrompt(taskText: "x").contains("What Dottie knows"))
        #expect(Advisor.appKnowledgeLines(String(repeating: "a", count: 5000)).count < 2100)
    }
}

/// Claude thinks alongside Jev instead of holding it up, and says when a
/// job Jev can't judge is done (Wasee, 27 Nov).
@MainActor
struct JevAdvisorAlongsideTests {
    private typealias Advisor = DottieJevAdvisorPlan
    private typealias Plan = DottieJevDriverPlan

    private let clickVideo = Plan.Move.click(label: "Hunger Games In Real Life", centerX: 400, centerY: 300)

    @Test func onlyAJobAboutToHandOverWaitsForTheAdvisor() {
        #expect(Advisor.mustWaitForAdvice(.moveFailed))
        #expect(Advisor.mustWaitForAdvice(.jevUnsure))
        #expect(!Advisor.mustWaitForAdvice(.userHint("use the search bar")))
        #expect(!Advisor.mustWaitForAdvice(.timeShown(seconds: 30)))
        #expect(!Advisor.mustWaitForAdvice(.checkpoint(.init(watchWords: ["views"], kind: .judge, advice: "most views"))))
    }

    @Test func theAdvisorCanSayTheJobIsDone() {
        #expect(Advisor.advice(fromAnswer: #"{"do":"done"}"#, optionCount: 3) == .done)
        #expect(Advisor.advice(fromAnswer: #"Sure: {"do":"DONE","note":"captions and speed are set"}"#, optionCount: 3) == .done)
    }

    @Test func thePromptOffersDone() {
        let prompt = Advisor.advicePrompt(taskText: "turn on captions", trigger: .jevUnsure, screenLines: [], optionDescriptions: ["click CC"], jobStateText: "")
        #expect(prompt.contains(#"{"do":"done"}"#))
    }

    @Test func aPickThatCameBackLaterIsMadeWhileItsMoveIsStillOffered() {
        let movedVideo = Plan.Move.click(label: "Hunger Games In Real Life", centerX: 410, centerY: 320)
        let currentOptions = [Plan.Option(key: "o1", move: .scrollDown), Plan.Option(key: "o2", move: movedVideo)]
        let use = Advisor.use(of: .decision(.act(clickVideo)), askedOnSameScreen: false, currentOptions: currentOptions)
        // Same move by its words, made where it is now.
        if case .decision(.act(let move)) = use {
            #expect(move.signature == clickVideo.signature)
        } else {
            Issue.record("expected the advisor's pick to be used")
        }
    }

    @Test func aPickWhoseMoveIsGoneIsDropped() {
        let use = Advisor.use(of: .decision(.act(clickVideo)), askedOnSameScreen: true, currentOptions: [Plan.Option(key: "o1", move: .scrollDown)])
        #expect(use == .nothing)
    }

    @Test func doneAndWaitsOnlyCountOnTheScreenTheyWereAskedAbout() {
        #expect(Advisor.use(of: .decision(.finished), askedOnSameScreen: true, currentOptions: []) == .decision(.finished))
        #expect(Advisor.use(of: .decision(.finished), askedOnSameScreen: false, currentOptions: []) == .nothing)
        #expect(Advisor.use(of: .wait(seconds: 30), askedOnSameScreen: true, currentOptions: []) == .wait(seconds: 30))
        #expect(Advisor.use(of: .wait(seconds: 30), askedOnSameScreen: false, currentOptions: []) == .nothing)
    }

    @Test func notesAndNoHelpChangeNothingAtTheStep() {
        #expect(Advisor.use(of: .noted, askedOnSameScreen: true, currentOptions: []) == .nothing)
        #expect(Advisor.use(of: .noHelp, askedOnSameScreen: true, currentOptions: []) == .nothing)
        #expect(Advisor.use(of: .decision(.unsure), askedOnSameScreen: true, currentOptions: []) == .nothing)
    }

    // MARK: The advisor says where to click (the OpenEMR DOB box, 27 Nov)

    @Test func theAdvisorCanNameASpotThatIsNotAnOption() {
        let advice = Advisor.advice(fromAnswer: #"{"do":"click","thing":"the empty text box to the right of DOB","type":"1990-05-12"}"#, optionCount: 4)
        #expect(advice == .clickThing(description: "the empty text box to the right of DOB", typeText: "1990-05-12"))
        let clickOnly = Advisor.advice(fromAnswer: #"{"do":"click","thing":"the box right of Last Name"}"#, optionCount: 4)
        #expect(clickOnly == .clickThing(description: "the box right of Last Name", typeText: nil))
        let emptyType = Advisor.advice(fromAnswer: #"{"do":"click","thing":"the box right of DOB","type":"  "}"#, optionCount: 4)
        #expect(emptyType == .clickThing(description: "the box right of DOB", typeText: nil))
    }

    @Test func aClickWithNothingDescribedIsNoAdvice() {
        #expect(Advisor.advice(fromAnswer: #"{"do":"click"}"#, optionCount: 4) == nil)
        #expect(Advisor.advice(fromAnswer: #"{"do":"click","thing":"   "}"#, optionCount: 4) == nil)
    }

    @Test func longClickAdviceIsCut() throws {
        let longThing = String(repeating: "box ", count: 200)
        let longText = String(repeating: "a", count: 1000)
        let advice = Advisor.advice(fromAnswer: #"{"do":"click","thing":"\#(longThing)","type":"\#(longText)"}"#, optionCount: 1)
        guard case .clickThing(let description, let typeText) = try #require(advice) else { Issue.record("expected a click"); return }
        #expect(description.count <= Advisor.maximumNoteCharacters)
        #expect((typeText ?? "").count == Advisor.maximumTypedCharacters)
    }

    @Test func thePromptTellsTheAdvisorItCanSayWhereToClick() {
        let prompt = Advisor.advicePrompt(taskText: "add a patient", trigger: .moveFailed, screenLines: [(text: "DOB", centerX: 0.3, centerY: 0.4)],
                                          optionDescriptions: ["click DOB"], jobStateText: "")
        #expect(prompt.contains(#""do":"click""#))
        #expect(prompt.contains("right of DOB"))
    }

    @Test func aStuckJevGetsAMoveNotANote() {
        let stuckPrompt = Advisor.advicePrompt(taskText: "add a patient", trigger: .jevUnsure, screenLines: [], optionDescriptions: [], jobStateText: "")
        #expect(stuckPrompt.contains("can't act on a note"))
        let failedPrompt = Advisor.advicePrompt(taskText: "add a patient", trigger: .moveFailed, screenLines: [], optionDescriptions: [], jobStateText: "")
        #expect(failedPrompt.contains("can't act on a note"))
        let hintPrompt = Advisor.advicePrompt(taskText: "add a patient", trigger: .userHint("use the menu"), screenLines: [], optionDescriptions: [], jobStateText: "")
        #expect(!hintPrompt.contains("can't act on a note"))
    }

    @Test func aSpotPointedAtWhileJevWentOnCountsOnlyOnTheSameScreen() {
        let pointed = DottieJevAdvisorSession.Help.clickThing(description: "the box right of DOB", typeText: "1990-05-12")
        #expect(Advisor.use(of: pointed, askedOnSameScreen: true, currentOptions: []) == .clickThing(description: "the box right of DOB", typeText: "1990-05-12"))
        #expect(Advisor.use(of: pointed, askedOnSameScreen: false, currentOptions: []) == .nothing)
    }

    @Test func thePointedMoveIsKeptInTheJobsMoves() {
        #expect(Advisor.summaryOfPointedMove(description: "the box right of DOB", typeText: "1990-05-12", wasFound: true)
                == #"clicked the box right of DOB and typed "1990-05-12" (the advisor's pick)"#)
        #expect(Advisor.summaryOfPointedMove(description: "the box right of DOB", typeText: nil, wasFound: true) == "clicked the box right of DOB (the advisor's pick)")
        #expect(Advisor.summaryOfPointedMove(description: "the box right of DOB", typeText: "x", wasFound: false).hasPrefix("couldn't find"))
    }

    @Test func checkingAdviceThatCameBackIsQuick() {
        let options = (0..<200).map { Plan.Option(key: "o\($0)", move: .click(label: "item \($0)", centerX: 10, centerY: Double($0))) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<1000 { _ = Advisor.use(of: .decision(.act(clickVideo)), askedOnSameScreen: true, currentOptions: options) }
        }
        #expect(elapsed < .seconds(1))
    }
}
