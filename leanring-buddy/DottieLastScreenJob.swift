//
//  DottieLastScreenJob.swift
//  leanring-buddy
//
//  What the last screen job really did, for the turns after it. On celly's
//  Mac a job moved one of three tasks and stopped; "why?" then went to the
//  talker, which saw only the one result line, and it made up reasons
//  ("a snag with the name format", "a file left in the wrong folder") for
//  six turns until Claude, with the job pushed out of its history, said it
//  couldn't see any task at all. Now both get the job's own record (what
//  was asked, how it ended, every move in order) for half an hour, and are
//  told to answer from it or say they don't know. Also: a finish whose own
//  words say the job isn't done is sent back to carry on. Pure, so it can
//  be unit tested.
//

import Foundation

struct DottieLastScreenJob: Equatable {
    /// How long after a job its record is still handed to the talker and
    /// the request brain.
    static let rememberedForSeconds: TimeInterval = 30 * 60
    static let maximumTaskCharacters = 200
    static let maximumResultCharacters = 400

    let taskText: String
    let resultText: String
    let succeeded: Bool
    /// Every move and tool call the step model made, in order.
    let moveSummaries: [String]
    let endedAt: Date

    func isRecent(now: Date) -> Bool {
        now.timeIntervalSince(endedAt) <= Self.rememberedForSeconds && now >= endedAt
    }

    private var shortTask: String { String(taskText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumTaskCharacters)) }
    private var shortResult: String { String(resultText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumResultCharacters)) }

    /// One line for the talker, so "why?" is known to be about the job and
    /// handed to Claude instead of answered with a guess.
    func talkerLine(now: Date) -> String {
        guard isRecent(now: now) else { return "" }
        return "the last on-screen job was \"\(shortTask)\"; it ended: \(shortResult). any question about it (why, what you did, what went wrong, do the rest) is \(DottieTalkerProtocol.requestWord) \(DottieTalkerProtocol.screenWord)."
    }

    /// The record for the request brain's prompt.
    func requestPromptSection(now: Date) -> String {
        guard isRecent(now: now) else { return "" }
        let movesText = moveSummaries.isEmpty ? "none recorded" : DottieJobMemory.compactList(moveSummaries)
        return """
        the last on-screen job (this is all that's known about it):
        asked: "\(shortTask)"
        ended \(succeeded ? "as done" : "not done"): \(shortResult)
        moves in order: \(movesText)
        answer questions about that job only from this record. if it doesn't say why something happened, say you don't know why; never make up a reason. if they want the rest done, start do_task_on_screen with only the part that isn't done.
        """
    }

    /// Words in a job's finish that say the job isn't actually done.
    private static let unfinishedPhrases = [
        "haven't finished", "have not finished", "not finished", "didn't finish", "did not finish",
        "isn't finished", "is not finished", "not done yet", "isn't done", "is not done",
        "stopped before", "still on", "still there", "only the first", "only one of", "didn't move", "did not move",
        "couldn't finish", "could not finish", "didn't get to", "left the rest"
    ]

    /// Reasons that really need the user, which no amount of carrying on fixes.
    private static let needsTheUserPhrases = [
        "password", "sign in", "log in", "login", "verification", "security code", "a code", "permission", "captcha",
        "two-factor", "2fa", "payment", "your approval", "confirm with you", "need you"
    ]

    /// Whether a finish should be sent back to carry on: its words say the
    /// job isn't done, and nothing in them needs the user.
    static func finishShouldCarryOn(answer: String) -> Bool {
        let lowercasedAnswer = answer.lowercased()
        guard unfinishedPhrases.contains(where: { lowercasedAnswer.contains($0) }) else { return false }
        return !needsTheUserPhrases.contains(where: { lowercasedAnswer.contains($0) })
    }

    /// What the step model hears when its finish is sent back.
    static let carryOnReply = "not finished: your own answer says part of the job isn't done, and nothing in it needs the user. Look at the screen, see what's left, and do it the same way as the part that worked. Only stop if something truly blocks you, and then finish with succeeded false and the real reason you saw on screen."
}
