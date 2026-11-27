//
//  JevStepCheckTests.swift
//  leanring-buddyTests
//
//  Jev checks every step on the user's screen: each Jev call also asks
//  whether the last move worked, a move it says failed is struck off for
//  the round, open moves (a site, a search, an app) are offered once per
//  round, and a page on a site this job already opened replaces that tab.
//  On Wasee's Mac "open youtube, search mr beast, click the first video"
//  opened YouTube, a search tab, clicked a video, then opened the same
//  search in another tab and clicked again.
//

import Foundation
import Testing
@testable import Dottie

struct JevStepCheckTests {
    private typealias Plan = DottieJevDriverPlan

    private func jevAnswer(key: String, probability: Double = 0.9, done: Double = 0.1, lastMoveWorked: Double?) -> Data {
        var answers: [String: Any] = [
            Plan.choiceQuestionName: ["type": "choice", "choice": key, "confidence": 0.8, "probabilities": [key: probability]],
            Plan.doneQuestionName: ["type": "noul", "noul": done]
        ]
        if let lastMoveWorked {
            answers[Plan.stepCheckQuestionName] = ["type": "noul", "noul": lastMoveWorked]
        }
        return (try? JSONSerialization.data(withJSONObject: ["answers": answers])) ?? Data()
    }

    // MARK: The step check question

    @Test func theFirstStepHasNoStepCheck() throws {
        let body = Plan.requestBody(goal: "open youtube", movesSoFar: [], knownHowTo: "", options: [])
        let questions = try #require(body["questions"] as? [String: Any])
        #expect(questions[Plan.stepCheckQuestionName] == nil)
        #expect(questions[Plan.choiceQuestionName] != nil)
        #expect(questions[Plan.doneQuestionName] != nil)
    }

    @Test func laterStepsAskJevWhetherTheLastMoveWorked() throws {
        let lastMove = Plan.Move.openSite(address: "youtube.com/results?search_query=mr%20beast")
        let body = Plan.requestBody(goal: "search mr beast on youtube", movesSoFar: [lastMove.summary], knownHowTo: "", options: [],
                                    lastMoveSummary: lastMove.summary)
        #expect(JSONSerialization.isValidJSONObject(body))
        let questions = try #require(body["questions"] as? [String: Any])
        let check = try #require(questions[Plan.stepCheckQuestionName] as? [String: Any])
        #expect(check["type"] as? String == "noul")
        let instructions = try #require(check["instructions"] as? String)
        #expect(instructions.contains(lastMove.summary))
        #expect(instructions.contains("opened twice"))
    }

    @Test func anEmptyLastMoveAddsNoCheck() throws {
        let body = Plan.requestBody(goal: "x", movesSoFar: [], knownHowTo: "", options: [], lastMoveSummary: "")
        let questions = try #require(body["questions"] as? [String: Any])
        #expect(questions[Plan.stepCheckQuestionName] == nil)
    }

    @Test func theChoiceSaysNotToRedoAStepThatWorked() throws {
        let body = Plan.requestBody(goal: "x", movesSoFar: [], knownHowTo: "", options: [])
        let questions = try #require(body["questions"] as? [String: Any])
        let choice = try #require(questions[Plan.choiceQuestionName] as? [String: Any])
        #expect((choice["instructions"] as? String)?.contains("Never redo a step that already worked") == true)
    }

    // MARK: Reading the check

    @Test func theCheckIsReadFromJevsAnswer() throws {
        let options = [Plan.Option(key: "o1", move: .scrollDown)]
        let parsed = try #require(Plan.answer(fromAnswer: jevAnswer(key: "o1", lastMoveWorked: 0.12), options: options))
        #expect(parsed.lastMoveWorkedProbability == 0.12)
        #expect(Plan.lastMoveFailed(parsed))
    }

    @Test func aPassingCheckIsNotAFailure() throws {
        let options = [Plan.Option(key: "o1", move: .scrollDown)]
        let parsed = try #require(Plan.answer(fromAnswer: jevAnswer(key: "o1", lastMoveWorked: 0.85), options: options))
        #expect(!Plan.lastMoveFailed(parsed))
    }

    @Test func noCheckAnswerIsNotAFailure() throws {
        let options = [Plan.Option(key: "o1", move: .scrollDown)]
        let parsed = try #require(Plan.answer(fromAnswer: jevAnswer(key: "o1", lastMoveWorked: nil), options: options))
        #expect(parsed.lastMoveWorkedProbability == nil)
        #expect(!Plan.lastMoveFailed(parsed))
    }

    @Test func theThresholdItselfCountsAsWorking() {
        let atThreshold = Plan.Answer(move: .scrollDown, probability: 1, confidence: 1, doneProbability: nil,
                                      lastMoveWorkedProbability: Plan.lastMoveWorkedThreshold)
        #expect(!Plan.lastMoveFailed(atThreshold))
        let justBelow = Plan.Answer(move: .scrollDown, probability: 1, confidence: 1, doneProbability: nil,
                                    lastMoveWorkedProbability: Plan.lastMoveWorkedThreshold - 0.01)
        #expect(Plan.lastMoveFailed(justBelow))
    }

    @Test func aMoveThatChangedTheScreenFailsOnlyWhenJevIsSure() {
        // Wasee's Mac, 27 Nov: nine "didn't work" checks in a row after moves that opened pages.
        let unsure = Plan.Answer(move: .scrollDown, probability: 1, confidence: 1, doneProbability: nil, lastMoveWorkedProbability: 0.2)
        #expect(Plan.lastMoveFailed(unsure))
        #expect(!Plan.lastMoveFailed(unsure, screenChangedAfterMove: true))
        let sure = Plan.Answer(move: .scrollDown, probability: 1, confidence: 1, doneProbability: nil, lastMoveWorkedProbability: 0.05)
        #expect(Plan.lastMoveFailed(sure, screenChangedAfterMove: true))
        let atThreshold = Plan.Answer(move: .scrollDown, probability: 1, confidence: 1, doneProbability: nil,
                                      lastMoveWorkedProbability: Plan.lastMoveWorkedThresholdWhenScreenChanged)
        #expect(!Plan.lastMoveFailed(atThreshold, screenChangedAfterMove: true))
    }

    // MARK: Open moves once per round

    @Test func openingMovesAreTheOnesOfferedOnce() {
        #expect(Plan.opensOnlyOnce(.openSite(address: "youtube.com")))
        #expect(Plan.opensOnlyOnce(.searchWeb("mr beast")))
        #expect(Plan.opensOnlyOnce(.openApp(name: "Opera")))
        #expect(!Plan.opensOnlyOnce(.scrollDown))
        #expect(!Plan.opensOnlyOnce(.click(label: "MrBeast", centerX: 1, centerY: 1)))
        #expect(!Plan.opensOnlyOnce(.pressReturn))
    }

    @Test func anOpenedSearchIsNotOfferedAgainOnTheNextScreen() {
        let taskText = "open youtube, search up mr beast and click on the first video"
        let searchMove = Plan.Move.openSite(address: "youtube.com/results?search_query=mr%20beast")
        let firstStep = Plan.options(screenTexts: [], textPieces: Plan.textPieces(from: taskText),
                                     siteAddresses: Plan.siteAddresses(from: taskText), appNames: [], alreadyTriedSignatures: [])
        #expect(firstStep.map(\.move).contains(searchMove))
        // The driver adds the opened move to what's struck off, whatever the screen.
        let afterTheVideoWasClicked = Plan.options(
            screenTexts: [Plan.ScreenText(text: "MrBeast", centerX: 300, centerY: 200)],
            textPieces: Plan.textPieces(from: taskText), siteAddresses: Plan.siteAddresses(from: taskText), appNames: [],
            alreadyTriedSignatures: [searchMove.signature], frontSiteHost: "www.youtube.com", taskText: taskText
        )
        #expect(!afterTheVideoWasClicked.map(\.move).contains(searchMove))
        #expect(!afterTheVideoWasClicked.map(\.move).contains(.openSite(address: "youtube.com")))
    }

    // MARK: Same tab

    @Test func theSameSiteInFrontReplacesThatTab() {
        #expect(Plan.opensInSameTab(address: "youtube.com/results?search_query=mr%20beast", frontSiteHost: "www.youtube.com", hostsOpenedByThisJob: []))
    }

    @Test func aPageThisJobOpenedIsReplaced() {
        #expect(Plan.opensInSameTab(address: "https://www.google.com/search?q=mr%20beast", frontSiteHost: "www.youtube.com", hostsOpenedByThisJob: ["youtube.com"]))
    }

    @Test func theUsersOwnTabOnAnotherSiteIsLeftAlone() {
        #expect(!Plan.opensInSameTab(address: "youtube.com", frontSiteHost: "mail.google.com", hostsOpenedByThisJob: []))
    }

    @Test func noBrowserInFrontOpensANewTab() {
        #expect(!Plan.opensInSameTab(address: "youtube.com", frontSiteHost: nil, hostsOpenedByThisJob: ["youtube.com"]))
        #expect(!Plan.opensInSameTab(address: "youtube.com", frontSiteHost: "", hostsOpenedByThisJob: ["youtube.com"]))
    }

    @Test func openedHostsAreReadFromOpenMoves() {
        #expect(Plan.openedHost(of: .openSite(address: "youtube.com/results?search_query=x")) == "youtube.com")
        #expect(Plan.openedHost(of: .openSite(address: "https://www.kaggle.com/competitions")) == "www.kaggle.com")
        #expect(Plan.openedHost(of: .searchWeb("mr beast")) == "www.google.com")
        #expect(Plan.openedHost(of: .scrollDown) == nil)
        #expect(Plan.host(ofAddress: "youtube.com") == "youtube.com")
    }

    // MARK: Journey

    /// The run from Wasee's Mac, step by step as the driver sees it: the
    /// search opened, the video was clicked, and the next look neither
    /// offers the search again nor opens a new tab for it.
    @Test func theMrBeastJobNoLongerOpensTheSearchTwice() throws {
        let taskText = "open youtube, search up mr beast and click on the first video"
        var openedSignatures = Set<String>()
        var hostsOpened = Set<String>()

        let step1 = Plan.options(screenTexts: [], textPieces: Plan.textPieces(from: taskText),
                                 siteAddresses: Plan.siteAddresses(from: taskText), appNames: [], alreadyTriedSignatures: [], taskText: taskText)
        let searchMove = Plan.Move.openSite(address: "youtube.com/results?search_query=mr%20beast")
        let searchKey = try #require(step1.first { $0.move == searchMove }?.key)
        let step1Answer = try #require(Plan.answer(fromAnswer: jevAnswer(key: searchKey, lastMoveWorked: nil), options: step1))
        guard case .act(let firstMove) = Plan.decision(for: step1Answer) else { Issue.record("Jev should act"); return }
        #expect(!Plan.opensInSameTab(address: "youtube.com/results?search_query=mr%20beast", frontSiteHost: "mail.google.com", hostsOpenedByThisJob: hostsOpened))
        if Plan.opensOnlyOnce(firstMove) { openedSignatures.insert(firstMove.signature) }
        if let host = Plan.openedHost(of: firstMove) { hostsOpened.insert(host) }

        let resultsTexts = [Plan.ScreenText(text: "I Survived 100 Days In A Circle", centerX: 520, centerY: 260)]
        let step2 = Plan.options(screenTexts: Plan.clickableTexts(from: resultsTexts, taskText: taskText), textPieces: Plan.textPieces(from: taskText),
                                 siteAddresses: Plan.siteAddresses(from: taskText), appNames: [], alreadyTriedSignatures: openedSignatures,
                                 frontSiteHost: "www.youtube.com", taskText: taskText)
        #expect(!step2.map(\.move).contains(searchMove))
        let videoMove = Plan.Move.click(label: "I Survived 100 Days In A Circle", centerX: 520, centerY: 260)
        let videoKey = try #require(step2.first { $0.move == videoMove }?.key)
        let step2Answer = try #require(Plan.answer(fromAnswer: jevAnswer(key: videoKey, lastMoveWorked: 0.9), options: step2))
        #expect(!Plan.lastMoveFailed(step2Answer))

        // Any later page on YouTube replaces the tab instead of adding one.
        #expect(Plan.opensInSameTab(address: "youtube.com/results?search_query=mr%20beast", frontSiteHost: "www.youtube.com", hostsOpenedByThisJob: hostsOpened))
    }

    @Test func stepCheckHelpersAreQuick() {
        let startedAt = Date()
        for _ in 0..<5000 {
            _ = Plan.opensInSameTab(address: "youtube.com/results?search_query=x", frontSiteHost: "www.youtube.com", hostsOpenedByThisJob: ["youtube.com"])
            _ = Plan.stepCheckInstructions(lastMoveSummary: "opened youtube.com")
        }
        #expect(Date().timeIntervalSince(startedAt) < 0.5)
    }
}
