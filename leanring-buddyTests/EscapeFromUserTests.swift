//
//  EscapeFromUserTests.swift
//  leanring-buddyTests
//
//  Escape stops everything only when the user pressed it. On the OpenEMR
//  demo (27 Nov) a screen job pressed Escape to close a date picker and
//  Dottie's own shortcut stopped that job.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct EscapeFromUserTests {
    private let ownProcessID: Int64 = 4242

    @Test func theKeyboardsEscapeStopsThings() {
        // Keys from the keyboard carry no process id.
        #expect(GlobalPushToTalkShortcutMonitor.isEscapeFromTheUser(sourceProcessID: 0, ownProcessID: ownProcessID))
    }

    @Test func dottiesOwnEscapeDoesNotStopHerJob() {
        #expect(!GlobalPushToTalkShortcutMonitor.isEscapeFromTheUser(sourceProcessID: ownProcessID, ownProcessID: ownProcessID))
    }

    @Test func anotherAppsEscapeStillCounts() {
        // A remote-control or accessibility app pressing Escape for the user.
        #expect(GlobalPushToTalkShortcutMonitor.isEscapeFromTheUser(sourceProcessID: 999, ownProcessID: ownProcessID))
    }

    @Test func checkingIsQuick() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for processID in 0..<100_000 {
                _ = GlobalPushToTalkShortcutMonitor.isEscapeFromTheUser(sourceProcessID: Int64(processID), ownProcessID: ownProcessID)
            }
        }
        #expect(elapsed < .seconds(1))
    }
}
