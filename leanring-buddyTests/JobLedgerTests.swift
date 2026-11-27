//
//  JobLedgerTests.swift
//  leanring-buddyTests
//
//  Long screen jobs: the job memory keeps only what still matters (round
//  1's recipe, the last few rounds, this round) however long the job runs,
//  the state text always shows where the job is, and every 100 moves the
//  memory goes to a page (DottieJobLedger) and comes back from it with
//  nothing else. Includes a 1,000-round journey and speed checks.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct JobLedgerTests {
    private typealias Ledger = DottieJobLedger

    private func memoryAfter(rounds finishedRounds: Int, totalRounds: Int, movesPerRound: Int = 3) -> DottieJobMemory {
        var memory = DottieJobMemory(totalRounds: totalRounds)
        for round in 1...finishedRounds {
            for moveNumber in 1...movesPerRound { memory.noteMove("round \(round) move \(moveNumber)") }
            memory.finishRound()
        }
        return memory
    }

    // MARK: What the memory keeps

    @Test func oldRoundsBecomeACount() {
        let memory = memoryAfter(rounds: 10, totalRounds: 20)
        #expect(memory.currentRound == 11)
        #expect(memory.recipe == ["round 1 move 1", "round 1 move 2", "round 1 move 3"])
        #expect(memory.recentRounds.count == DottieJobMemory.recentRoundsKept)
        #expect(memory.recentRounds.last?.first == "round 10 move 1")
        #expect(memory.roundsForgotten == 6)
        #expect(memory.movesInForgottenRounds == 18)
        #expect(memory.totalMovesNoted == 30)
        #expect(!memory.allMoves.contains("round 5 move 1"))
    }

    @Test func aLongRoundKeepsHowItStartedAndTheNewestMoves() {
        var memory = DottieJobMemory(totalRounds: 1)
        for moveNumber in 1...500 { memory.noteMove("move \(moveNumber)") }
        #expect(memory.movesThisRound.count == DottieJobMemory.firstMovesKeptPerRound + DottieJobMemory.newestMovesKeptPerRound)
        #expect(memory.movesThisRound.first == "move 1")
        #expect(memory.movesThisRound.last == "move 500")
        #expect(memory.movesDroppedThisRound == 500 - memory.movesThisRound.count)
        let state = memory.stateText()
        #expect(state.contains("500 moves"))
        #expect(state.contains("move 1;"))
        #expect(state.contains("move 500"))
        #expect(state.contains("486 more"))
    }

    @Test func theStateAlwaysShowsThisRoundOnLongJobs() {
        var memory = DottieJobMemory(totalRounds: 1_000)
        let longMove = String(repeating: "clicked a very long button name ", count: 8)
        for _ in 1...40 { memory.noteMove(longMove) }
        memory.finishRound()
        for round in 2...600 {
            memory.noteMove("round \(round) did a thing")
            memory.finishRound()
        }
        memory.noteMove("clicked Send for this round")
        let state = memory.stateText()
        #expect(state.count <= DottieJobMemory.maximumStateCharacters + 1)
        #expect(state.contains("round 601 of 1000"))
        #expect(state.contains("This round so far: clicked Send for this round"))
        #expect(state.contains("start round 602"))
        #expect(state.contains("Rounds 2 to 600 are done too (about 1 moves each)"))
        // The old list of every round's move count is gone.
        #expect(!state.contains("1, 1, 1"))
    }

    // MARK: Pages

    @Test func aPageIsDueEveryHundredMoves() {
        #expect(!Ledger.isPageDue(totalMoves: 99, movesAtLastPage: 0))
        #expect(Ledger.isPageDue(totalMoves: 100, movesAtLastPage: 0))
        #expect(!Ledger.isPageDue(totalMoves: 150, movesAtLastPage: 100))
        #expect(Ledger.isPageDue(totalMoves: 200, movesAtLastPage: 100))
    }

    @Test func slotsGoRound() {
        #expect(Ledger.nextSlot(after: nil) == 0)
        #expect(Ledger.nextSlot(after: 3) == 4)
        #expect(Ledger.nextSlot(after: Ledger.slotCount - 1) == 0)
        #expect(Ledger.fileName(forSlot: 4) == "job-04.json")
        #expect(Ledger.fileName(forSlot: 12) == "job-12.json")
    }

    @Test func onlyTheRecentMovesStayInTheDriversList() {
        let moves = (1...250).map { "move \($0)" }
        let kept = Ledger.keptRecentMoves(moves)
        #expect(kept.count == Ledger.recentMovesKept)
        #expect(kept.last == "move 250")
    }

    @Test func aPageRoundTripsThroughJSON() throws {
        let memory = memoryAfter(rounds: 8, totalRounds: 50)
        let page = Ledger.page(goal: "like 50 posts", pageNumber: 2, jobMemory: memory, advisorNotes: ["scroll first"],
                               savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try #require(Ledger.encoded(page))
        let readBack = try #require(Ledger.decoded(data))
        #expect(readBack == page)
        #expect(Ledger.decoded(Data("not json".utf8)) == nil)
    }

    @Test func memoryRebuiltFromAPageIsTheSameJob() throws {
        var memory = memoryAfter(rounds: 8, totalRounds: 50)
        memory.noteMove("clicked Like")
        let page = Ledger.page(goal: "like 50 posts", pageNumber: 1, jobMemory: memory, advisorNotes: [])
        let rebuilt = DottieJobMemory(ledgerPage: page)
        #expect(rebuilt == memory)
        #expect(rebuilt.stateText() == memory.stateText())
    }

    @Test func aPageCantGiveBackMoreThanItKeeps() {
        let page = Ledger.Page(goal: "x", pageNumber: 1, savedAt: Date(), totalMoves: 10, totalRounds: 5, currentRound: 99,
                               recipe: ["a"], recentRounds: [["b"], ["c"], ["d"], ["e"], ["f"]], roundsForgotten: 0,
                               movesInForgottenRounds: 0, movesThisRound: [], movesDroppedThisRound: 0, advisorNotes: [])
        let rebuilt = DottieJobMemory(ledgerPage: page)
        #expect(rebuilt.currentRound == 5)
        #expect(rebuilt.recentRounds.count == DottieJobMemory.recentRoundsKept)
    }

    // MARK: Journey: a thousand rounds

    /// A job done 1,000 times with 4 moves a round: a page every 100 moves,
    /// the memory rebuilt from each page alone, and the state Jev reads stays
    /// the same size from round 30 to round 1,000.
    @Test func aThousandRoundJobStaysLight() throws {
        var memory = DottieJobMemory(totalRounds: 1_000)
        var movesAtLastPage = 0
        var pageCount = 0
        var stateSizes: [Int] = []
        for round in 1...1_000 {
            for moveNumber in 1...4 {
                if Ledger.isPageDue(totalMoves: memory.totalMovesNoted, movesAtLastPage: movesAtLastPage) {
                    pageCount += 1
                    let page = Ledger.page(goal: "send the invoice", pageNumber: pageCount, jobMemory: memory, advisorNotes: [])
                    let pageData = try #require(Ledger.encoded(page))
                    let readBack = try #require(Ledger.decoded(pageData))
                    memory = DottieJobMemory(ledgerPage: readBack)
                    movesAtLastPage = memory.totalMovesNoted
                }
                memory.noteMove("round \(round) move \(moveNumber)")
            }
            if round == 30 || round == 999 { stateSizes.append(memory.stateText().count) }
            memory.finishRound()
        }
        #expect(memory.currentRound == 1_000)
        #expect(memory.totalMovesNoted == 4_000)
        #expect(pageCount == 39)
        #expect(memory.recipe.first == "round 1 move 1")
        #expect(memory.allMoves.count <= 4 * (DottieJobMemory.recentRoundsKept + 1) + 4)
        let growth = (stateSizes.last ?? 0) - (stateSizes.first ?? 0)
        #expect(growth < 40, "the state grew by \(growth) characters over 970 rounds")
        #expect(memory.stateText().contains("This is the last round"))
    }

    // MARK: Speed

    @Test func noteMoveAndStateStayQuickOnLongJobs() {
        var memory = DottieJobMemory(totalRounds: 1_000)
        let startedAt = Date()
        for round in 1...1_000 {
            for moveNumber in 1...5 { memory.noteMove("round \(round) move \(moveNumber)") }
            _ = memory.stateText()
            memory.finishRound()
        }
        // 5,000 moves and 1,000 state texts: far more than any real job does per second.
        #expect(Date().timeIntervalSince(startedAt) < 2.0)
    }
}
