//
//  HelperTaskTurnCapTests.swift
//  leanring-buddyTests
//
//  A helper task stops after 8 turns, counting the follow-ups Dottie sends
//  by herself (screen job results, installed tools), until the user says
//  to carry on.
//

import Foundation
import Testing
@testable import Dottie

struct HelperTaskTurnCapTests {
    private let helperID = UUID()

    @Test func aTaskGetsSevenFollowUpsAfterItsFirstTurn() {
        var cap = DottieHelperTaskTurnCap()
        cap.noteTaskStarted(agentID: helperID)
        let allowed = (1...10).map { _ in cap.allowFollowUp(agentID: helperID) }
        #expect(allowed.filter { $0 }.count == DottieHelperTaskTurnCap.maximumTurnsPerTask - 1)
        #expect(allowed.prefix(7).allSatisfy { $0 })
        #expect(!allowed[7])
        #expect(cap.turnsByAgentID[helperID] == DottieHelperTaskTurnCap.maximumTurnsPerTask)
    }

    @Test func theUsersNextMessageStartsTheCountOver() {
        var cap = DottieHelperTaskTurnCap()
        cap.noteTaskStarted(agentID: helperID)
        for _ in 0..<20 { _ = cap.allowFollowUp(agentID: helperID) }
        #expect(!cap.allowFollowUp(agentID: helperID))
        cap.noteTaskStarted(agentID: helperID)
        #expect(cap.allowFollowUp(agentID: helperID))
        #expect(cap.turnsByAgentID[helperID] == 2)
    }

    @Test func eachHelperHasItsOwnCount() {
        var cap = DottieHelperTaskTurnCap()
        let otherHelperID = UUID()
        cap.noteTaskStarted(agentID: helperID)
        for _ in 0..<20 { _ = cap.allowFollowUp(agentID: helperID) }
        cap.noteTaskStarted(agentID: otherHelperID)
        #expect(cap.allowFollowUp(agentID: otherHelperID))
        #expect(!cap.allowFollowUp(agentID: helperID))
    }

    @Test func aHelperNeverGivenATaskStillHasALimit() {
        // A follow-up for a helper the app restarted under counts from one.
        var cap = DottieHelperTaskTurnCap()
        let allowed = (1...10).map { _ in cap.allowFollowUp(agentID: helperID) }
        #expect(allowed.filter { $0 }.count == 7)
    }

    @Test func theStoppedNoteSaysWhyAndHowToGoOn() {
        let note = DottieHelperTaskTurnCap.stoppedNote(heldBackMessage: String(repeating: "x", count: 2000))
        #expect(note.contains("8 turns"))
        #expect(note.contains("carry on"))
        #expect(note.count < 600)
    }
}
