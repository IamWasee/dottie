//
//  JevDriverTests.swift
//  leanring-buddyTests
//
//  Jev driving screen jobs: pieces of the request (typed words, sites,
//  app names), the move options and what's struck off after a try, the
//  choice request Jev gets, reading its answer, when it acts, finishes or
//  hands over, risky buttons, and a whole "open youtube and search cats"
//  run against Jev's answers.
//

import Foundation
import Testing
@testable import Dottie

struct JevDriverTests {
    private typealias Plan = DottieJevDriverPlan

    private func answer(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func choiceAnswer(key: String, probability: Double, confidence: Double, done: Double) -> Data {
        answer(["answers": [
            Plan.choiceQuestionName: ["type": "choice", "choice": key, "confidence": confidence, "probabilities": [key: probability]],
            Plan.doneQuestionName: ["type": "noul", "noul": done]
        ]])
    }

    // MARK: Pieces of the request

    @Test func searchWordsBecomeAPieceToType() {
        #expect(Plan.textPieces(from: "open youtube and search for cats on the home page") == ["cats"])
        #expect(Plan.textPieces(from: "search lofi beats") == ["lofi beats"])
        #expect(Plan.textPieces(from: "type hello there, then press enter") == ["hello there"])
    }

    @Test func quotedTextIsTypedAsGiven() {
        let pieces = Plan.textPieces(from: "make a folder called \"Taxes 2026\"")
        #expect(pieces.first == "Taxes 2026")
        #expect(pieces.count == 1)
    }

    @Test func contractionsArentReadAsQuotes() {
        #expect(Plan.textPieces(from: "tell me what's my rank on kaggle's page").isEmpty)
    }

    @Test func requestWithNothingToTypeHasNoPieces() {
        #expect(Plan.textPieces(from: "open youtube").isEmpty)
    }

    @Test func sitesSaidByNameAndTypedAddressesAreFound() {
        #expect(Plan.siteAddresses(from: "open youtube") == ["youtube.com"])
        #expect(Plan.siteAddresses(from: "Open YouTube.") == ["youtube.com"])
        #expect(Plan.siteAddresses(from: "go to kaggle.com/competitions") == ["kaggle.com/competitions", "kaggle.com"])
        #expect(Plan.siteAddresses(from: "open google docs") == ["docs.google.com"])
        #expect(Plan.siteAddresses(from: "move this window left").isEmpty)
    }

    @Test func longerDomainIsntCutAtAShorterEnding() {
        #expect(Plan.siteAddresses(from: "open example.community").isEmpty)
    }

    @Test func wordGroupsSkipCommonWords() {
        let groups = Plan.wordGroups(of: "open google chrome")
        #expect(groups.contains("google chrome"))
        #expect(groups.contains("chrome"))
        #expect(!groups.contains("open"))
    }

    @Test func questionsNeedTheStepModelToSayTheAnswer() {
        #expect(Plan.asksForInformation("tell me my rank on kaggle"))
        #expect(Plan.asksForInformation("how many unread emails do I have"))
        #expect(!Plan.asksForInformation("open youtube and search cats"))
    }

    @Test func riskyButtonsNeedTheUsersOwnWord() {
        #expect(Plan.isRiskyLabel("Buy now", forTask: "open the amazon page for airpods"))
        #expect(!Plan.isRiskyLabel("Buy now", forTask: "buy the airpods"))
        #expect(Plan.isRiskyLabel("Delete", forTask: "open my notes"))
        #expect(!Plan.isRiskyLabel("Search", forTask: "open youtube"))
    }

    // MARK: Options

    @Test func screenTextsAreCleanedDedupedAndOrdered() {
        let texts = [
            Plan.ScreenText(text: "Sign in", centerX: 900, centerY: 50),
            Plan.ScreenText(text: "Home", centerX: 100, centerY: 50),
            Plan.ScreenText(text: "sign in", centerX: 500, centerY: 600),
            Plan.ScreenText(text: "12", centerX: 10, centerY: 10),
            Plan.ScreenText(text: "Delete account", centerX: 10, centerY: 900),
            Plan.ScreenText(text: String(repeating: "long text ", count: 10), centerX: 10, centerY: 300)
        ]
        let kept = Plan.clickableTexts(from: texts, taskText: "sign in to youtube")
        #expect(kept.map(\.text) == ["Home", "Sign in"])
    }

    @Test func screenTextOptionsAreCapped() {
        let texts = (0..<400).map { Plan.ScreenText(text: "Item \($0)", centerX: 10, centerY: Double($0)) }
        #expect(Plan.clickableTexts(from: texts, taskText: "x").count == Plan.maximumScreenTextOptions)
    }

    @Test func optionsCoverEveryKindOfMoveWithUniqueKeys() {
        let options = Plan.options(
            screenTexts: [Plan.ScreenText(text: "Search", centerX: 500, centerY: 80)],
            textPieces: ["cats"],
            siteAddresses: ["youtube.com"],
            appNames: ["Safari"],
            alreadyTriedSignatures: []
        )
        let moves = options.map(\.move)
        #expect(moves.contains(.typeText("cats", pressesReturn: true)))
        #expect(moves.contains(.openSite(address: "youtube.com")))
        #expect(moves.contains(.openApp(name: "Safari")))
        #expect(moves.contains(.searchWeb("cats")))
        #expect(moves.contains(.click(label: "Search", centerX: 500, centerY: 80)))
        #expect(moves.contains(.finished))
        #expect(moves.contains(.noneFits))
        #expect(moves.contains(.goBack))
        #expect(Set(options.map(\.key)).count == options.count)
        #expect(options.count < 255)
    }

    @Test func movesTriedOnThisScreenAreStruckOff() {
        let tried: Set<String> = [Plan.Move.click(label: "Search", centerX: 0, centerY: 0).signature, Plan.Move.scrollDown.signature]
        let options = Plan.options(
            screenTexts: [Plan.ScreenText(text: "Search", centerX: 510, centerY: 82)],
            textPieces: [], siteAddresses: [], appNames: [],
            alreadyTriedSignatures: tried
        )
        #expect(!options.contains { if case .click = $0.move { return true } else { return false } })
        #expect(!options.map(\.move).contains(.scrollDown))
        #expect(options.map(\.move).contains(.scrollUp))
    }

    // MARK: Jev's request and answer

    @Test func requestHasTheGoalTheMovesAChoiceAndADoneQuestion() throws {
        let options = Plan.options(screenTexts: [], textPieces: ["cats"], siteAddresses: ["youtube.com"], appNames: [], alreadyTriedSignatures: [])
        let body = Plan.requestBody(goal: "open youtube and search cats", movesSoFar: ["opened youtube.com"], knownHowTo: "Click the search box first.", options: options)
        #expect(JSONSerialization.isValidJSONObject(body))
        let state = try #require(body["state"] as? String)
        #expect(state.contains("open youtube and search cats"))
        #expect(state.contains("opened youtube.com"))
        #expect(state.contains("Click the search box first."))
        let questions = try #require(body["questions"] as? [String: Any])
        let choice = try #require(questions[Plan.choiceQuestionName] as? [String: Any])
        #expect(choice["type"] as? String == "choice")
        let criteria = try #require(choice["criteria"] as? [String: String])
        #expect(criteria.count == options.count)
        #expect(criteria["o1"]?.contains("cats") == true)
        let done = try #require(questions[Plan.doneQuestionName] as? [String: Any])
        #expect(done["type"] as? String == "noul")
        #expect(body["assets"] == nil)
    }

    @Test func freshJobSaysNothingWasDoneAndKeepsHowToShort() throws {
        let body = Plan.requestBody(goal: "x", movesSoFar: [], knownHowTo: String(repeating: "a", count: 5000), options: [])
        let state = try #require(body["state"] as? String)
        #expect(state.contains("Nothing has been done yet."))
        #expect(state.count < 1800)
    }

    @Test func answerIsReadBackToTheMove() throws {
        let options = Plan.options(screenTexts: [], textPieces: [], siteAddresses: ["youtube.com"], appNames: [], alreadyTriedSignatures: [])
        let siteKey = try #require(options.first { $0.move == .openSite(address: "youtube.com") }?.key)
        let parsed = try #require(Plan.answer(fromAnswer: choiceAnswer(key: siteKey, probability: 0.9, confidence: 0.8, done: 0.05), options: options))
        #expect(parsed.move == .openSite(address: "youtube.com"))
        #expect(parsed.probability == 0.9)
        #expect(parsed.confidence == 0.8)
        #expect(parsed.doneProbability == 0.05)
    }

    @Test func unknownOrBrokenAnswersAreNil() {
        let options = Plan.options(screenTexts: [], textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [])
        #expect(Plan.answer(fromAnswer: choiceAnswer(key: "o999", probability: 1, confidence: 1, done: 0), options: options) == nil)
        #expect(Plan.answer(fromAnswer: Data("nope".utf8), options: options) == nil)
        #expect(Plan.answer(fromAnswer: answer(["answers": [:]]), options: options) == nil)
    }

    // MARK: Deciding

    @Test func confidentPickIsActedOn() {
        let pick = Plan.Answer(move: .scrollDown, probability: 0.6, confidence: 0.4, doneProbability: 0.1)
        #expect(Plan.decision(for: pick) == .act(.scrollDown))
    }

    @Test func lowPickStillExploresWhenJevIsntLost() {
        let pick = Plan.Answer(move: .click(label: "Menu", centerX: 1, centerY: 1), probability: 0.3, confidence: 0.1, doneProbability: nil)
        #expect(Plan.decision(for: pick) == .act(.click(label: "Menu", centerX: 1, centerY: 1)))
    }

    @Test func spreadOutGuessHandsOver() {
        let pick = Plan.Answer(move: .scrollDown, probability: 0.05, confidence: 0.05, doneProbability: 0.1)
        #expect(Plan.decision(for: pick) == .unsure)
    }

    @Test func doneYesFinishesWhateverTheChoice() {
        let pick = Plan.Answer(move: .scrollDown, probability: 0.9, confidence: 0.9, doneProbability: 0.92)
        #expect(Plan.decision(for: pick) == .finished)
    }

    @Test func pickingDoneAgainstItsOwnNoIsUnsure() {
        #expect(Plan.decision(for: Plan.Answer(move: .finished, probability: 0.7, confidence: 0.5, doneProbability: 0.2)) == .unsure)
        #expect(Plan.decision(for: Plan.Answer(move: .finished, probability: 0.7, confidence: 0.5, doneProbability: 0.6)) == .finished)
    }

    @Test func noneFitsHandsOver() {
        #expect(Plan.decision(for: Plan.Answer(move: .noneFits, probability: 0.9, confidence: 0.9, doneProbability: 0)) == .unsure)
    }

    @Test func handOverNoteListsTheStepsOrIsEmpty() {
        #expect(Plan.handOverNote(movesSoFar: [], reason: "x").isEmpty)
        let note = Plan.handOverNote(movesSoFar: ["opened youtube.com", "clicked Search"], reason: "Jev wasn't sure.")
        #expect(note.contains("opened youtube.com; clicked Search"))
        #expect(note.contains("Jev wasn't sure."))
    }

    @Test func visionBoxBecomesTopLeftMiddle() {
        let text = Plan.screenText("OK", visionBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1))
        #expect(abs(text.centerX - 200) < 0.001)
        #expect(abs(text.centerY - 250) < 0.001)
    }

    @Test func sameScreenAllowsNoiseButNotChange() {
        let screen = [UInt8](repeating: 100, count: 576)
        var noisy = screen
        noisy[3] = 110
        var changed = screen
        for index in 0..<200 { changed[index] = 200 }
        #expect(Plan.isSameScreen(screen, noisy))
        #expect(!Plan.isSameScreen(screen, changed))
        #expect(!Plan.isSameScreen(screen, []))
    }

    // MARK: A whole job

    /// "open youtube and search cats" with Jev's picks played back: open the
    /// site, click the search box, type and press Return, then done.
    @Test func openYoutubeAndSearchCatsRunsFromJevsPicksAlone() throws {
        let taskText = "open youtube and search cats"
        let pieces = Plan.textPieces(from: taskText)
        let sites = Plan.siteAddresses(from: taskText)
        let screens: [[Plan.ScreenText]] = [
            [Plan.ScreenText(text: "Finder", centerX: 50, centerY: 10)],
            [Plan.ScreenText(text: "Search", centerX: 500, centerY: 80), Plan.ScreenText(text: "Home", centerX: 50, centerY: 150)],
            [Plan.ScreenText(text: "Search", centerX: 500, centerY: 80)],
            [Plan.ScreenText(text: "cats - YouTube", centerX: 500, centerY: 20)]
        ]
        let wantedMoves: [Plan.Move] = [
            .openSite(address: "youtube.com"),
            .click(label: "Search", centerX: 500, centerY: 80),
            .typeText("cats", pressesReturn: true),
            .finished
        ]
        var movesSoFar: [String] = []
        var finished = false
        for (screen, wantedMove) in zip(screens, wantedMoves) {
            let options = Plan.options(
                screenTexts: Plan.clickableTexts(from: screen, taskText: taskText),
                textPieces: pieces, siteAddresses: sites, appNames: ["Safari"], alreadyTriedSignatures: []
            )
            let body = Plan.requestBody(goal: taskText, movesSoFar: movesSoFar, knownHowTo: "", options: options)
            #expect(JSONSerialization.isValidJSONObject(body))
            let key = try #require(options.first { $0.move == wantedMove }?.key)
            let done = wantedMove == .finished ? 0.95 : 0.05
            let parsed = try #require(Plan.answer(fromAnswer: choiceAnswer(key: key, probability: 0.8, confidence: 0.7, done: done), options: options))
            switch Plan.decision(for: parsed) {
            case .act(let move):
                movesSoFar.append(move.summary)
            case .finished:
                finished = true
            case .unsure:
                Issue.record("Jev's confident pick shouldn't hand over")
            }
        }
        #expect(finished)
        #expect(movesSoFar == ["opened youtube.com", "clicked Search", "typed \"cats\" and pressed Return"])
    }
}
