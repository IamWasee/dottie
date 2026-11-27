//
//  DottieJobLedger.swift
//  leanring-buddy
//
//  A long screen job's memory, kept outside the step. Wasee (27 Nov): Jev
//  will run jobs of thousands of moves on enterprise plans, so every 100
//  moves the job's state is written to a file (Application Support/Dottie/
//  JobLedgers/job-NN.json, 20 slots written over in turn, so nothing piles
//  up) and the next step starts again from that file alone: the goal, round
//  1's recipe, how many rounds are done, the last few rounds, this round
//  and the advisor's current notes. Whatever isn't on the page (old rounds
//  move by move, screens struck off long ago, old notes) is dropped, so the
//  state Jev and the advisor read never fills up with old details. The page
//  math is Foundation only, so it can be unit tested.
//

import Foundation

nonisolated enum DottieJobLedger {
    /// A page is written after this many moves since the last one.
    static let movesPerPage = 100
    /// The driver's own list of moves (hand-over note, typing context)
    /// keeps only this many after a page.
    static let recentMovesKept = 30
    static let slotCount = 20

    nonisolated struct Page: Codable, Equatable, Sendable {
        let goal: String
        let pageNumber: Int
        let savedAt: Date
        let totalMoves: Int
        let totalRounds: Int
        let currentRound: Int
        let recipe: [String]
        let recentRounds: [[String]]
        let roundsForgotten: Int
        let movesInForgottenRounds: Int
        let movesThisRound: [String]
        let movesDroppedThisRound: Int
        let advisorNotes: [String]
    }

    static func isPageDue(totalMoves: Int, movesAtLastPage: Int) -> Bool {
        totalMoves - movesAtLastPage >= movesPerPage
    }

    static func keptRecentMoves(_ moves: [String]) -> [String] {
        Array(moves.suffix(recentMovesKept))
    }

    /// The slot after `lastSlot`, going round after `slotCount`.
    static func nextSlot(after lastSlot: Int?) -> Int {
        guard let lastSlot, lastSlot >= 0 else { return 0 }
        return (lastSlot + 1) % slotCount
    }

    static func fileName(forSlot slot: Int) -> String {
        slot < 10 ? "job-0\(slot).json" : "job-\(slot).json"
    }

    static func encoded(_ page: Page) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(page)
    }

    static func decoded(_ data: Data) -> Page? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Page.self, from: data)
    }
}

@MainActor
extension DottieJobLedger {
    private static let lastSlotDefaultsKey = "DottieJobLedgerLastSlot"

    static func page(goal: String, pageNumber: Int, jobMemory: DottieJobMemory, advisorNotes: [String], savedAt: Date = Date()) -> Page {
        Page(
            goal: goal, pageNumber: pageNumber, savedAt: savedAt, totalMoves: jobMemory.totalMovesNoted,
            totalRounds: jobMemory.totalRounds, currentRound: jobMemory.currentRound, recipe: jobMemory.recipe,
            recentRounds: jobMemory.recentRounds, roundsForgotten: jobMemory.roundsForgotten,
            movesInForgottenRounds: jobMemory.movesInForgottenRounds, movesThisRound: jobMemory.movesThisRound,
            movesDroppedThisRound: jobMemory.movesDroppedThisRound, advisorNotes: advisorNotes
        )
    }

    /// The slot a new long job writes its pages to.
    static func takeSlotForNewJob() -> Int {
        let defaults = UserDefaults.standard
        let lastSlot = defaults.object(forKey: lastSlotDefaultsKey) as? Int
        let slot = nextSlot(after: lastSlot)
        defaults.set(slot, forKey: lastSlotDefaultsKey)
        return slot
    }

    /// Writes the page and reads it back: the job goes on from what the
    /// file holds. Nil when either fails; the job then goes on from the
    /// page in memory.
    static func saveAndReload(_ page: Page, slot: Int) -> Page? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dottie/JobLedgers", isDirectory: true) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            DottieLog.warning("Couldn't make the job ledgers folder: \(error.localizedDescription)")
            return nil
        }
        let fileURL = folder.appendingPathComponent(fileName(forSlot: slot))
        guard let data = encoded(page), DottieFileSaver.save(data, to: fileURL) else { return nil }
        guard let savedData = try? Data(contentsOf: fileURL) else { return nil }
        return decoded(savedData)
    }
}
