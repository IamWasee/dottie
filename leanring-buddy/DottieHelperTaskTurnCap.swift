//
//  DottieHelperTaskTurnCap.swift
//  leanring-buddy
//
//  How many turns one helper task may take. A task starts with the user's
//  message; Dottie then sends the helper follow-ups by herself (the result
//  of a <SCREEN_JOB> it asked for, a tool it asked to have installed), and
//  each of those is another full turn on the helper's model. A helper that
//  keeps asking for screen jobs could go on for as long as the jobs came
//  back, so a task stops after 8 turns and the user decides whether it
//  carries on. Foundation only, so it can be unit tested.
//

import Foundation

nonisolated struct DottieHelperTaskTurnCap: Equatable {
    /// Turns one task may take, the first one included.
    static let maximumTurnsPerTask = 8

    /// Turns taken by each helper's current task.
    private(set) var turnsByAgentID: [UUID: Int] = [:]

    /// The user gave the helper something (a new task or "carry on"):
    /// its count starts over at this one turn.
    mutating func noteTaskStarted(agentID: UUID) {
        turnsByAgentID[agentID] = 1
    }

    /// Whether Dottie may send the helper another follow-up turn on its
    /// own, counting it when she may.
    mutating func allowFollowUp(agentID: UUID) -> Bool {
        let turnsSoFar = turnsByAgentID[agentID] ?? 1
        guard turnsSoFar < Self.maximumTurnsPerTask else { return false }
        turnsByAgentID[agentID] = turnsSoFar + 1
        return true
    }

    /// What the helper's chat says when a follow-up was held back.
    static func stoppedNote(heldBackMessage: String) -> String {
        "Stopped after \(maximumTurnsPerTask) turns on this task to keep it from running up cost. "
            + "What came back last: \(heldBackMessage.prefix(400)). Say \"carry on\" to keep going."
    }
}
