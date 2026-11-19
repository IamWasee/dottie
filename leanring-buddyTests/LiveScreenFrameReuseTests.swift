//
//  LiveScreenFrameReuseTests.swift
//  leanring-buddyTests
//
//  Unit tests for when a voice turn leans on the screen picture Live
//  already has instead of sending the same screen again. Getting this
//  wrong either wastes tokens or leaves Live with an old picture, which is
//  how she ended up saying she couldn't see the user's updated screen.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct LiveScreenFrameReuseTests {
    private let screenFingerprint = [UInt8](repeating: 120, count: 64)
    private let sentAt = Date(timeIntervalSince1970: 1_000_000)

    private func reuses(
        newFingerprint: [UInt8]?,
        lastFingerprint: [UInt8]? = nil,
        lastSession: Int = 3,
        currentSession: Int = 3,
        secondsLater: TimeInterval = 5
    ) -> Bool {
        let lastSentScreenFrame = lastFingerprint.map { (sessionNumber: lastSession, fingerprint: $0, sentAt: sentAt) }
        return GeminiLiveVoiceClient.reusesLastScreenFrame(
            newFingerprint: newFingerprint,
            lastSentScreenFrame: lastSentScreenFrame,
            currentSessionNumber: currentSession,
            now: sentAt.addingTimeInterval(secondsLater)
        )
    }

    @Test func theSameScreenMomentsLaterIsReused() {
        #expect(reuses(newFingerprint: screenFingerprint, lastFingerprint: screenFingerprint))
    }

    @Test func aChangedScreenIsSent() {
        let changedScreen = [UInt8](repeating: 200, count: 64)
        #expect(reuses(newFingerprint: changedScreen, lastFingerprint: screenFingerprint) == false)
    }

    @Test func aFewChangedPixelsLikeTheMousePointerStillCountAsTheSameScreen() {
        var pointerMoved = screenFingerprint
        pointerMoved[0] = 255
        pointerMoved[1] = 255
        #expect(reuses(newFingerprint: pointerMoved, lastFingerprint: screenFingerprint))
    }

    @Test func aPictureFromAnotherSessionIsNeverReused() {
        #expect(reuses(newFingerprint: screenFingerprint, lastFingerprint: screenFingerprint, lastSession: 2, currentSession: 3) == false)
    }

    @Test func afterThirtySecondsAFreshPictureGoesEvenIfItLooksTheSame() {
        #expect(reuses(newFingerprint: screenFingerprint, lastFingerprint: screenFingerprint, secondsLater: 29.9))
        #expect(reuses(newFingerprint: screenFingerprint, lastFingerprint: screenFingerprint, secondsLater: 30) == false)
        #expect(reuses(newFingerprint: screenFingerprint, lastFingerprint: screenFingerprint, secondsLater: 600) == false)
    }

    @Test func withNothingSentYetOrNoFingerprintThePictureIsSent() {
        #expect(reuses(newFingerprint: screenFingerprint, lastFingerprint: nil) == false)
        #expect(reuses(newFingerprint: nil, lastFingerprint: screenFingerprint) == false)
    }

    @Test func fingerprintsOfDifferentSizesAreDifferentScreens() {
        let otherSize = [UInt8](repeating: 120, count: 32)
        #expect(reuses(newFingerprint: otherSize, lastFingerprint: screenFingerprint) == false)
    }
}
