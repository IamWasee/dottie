//
//  GameMovementTests.swift
//  leanring-buddyTests
//
//  Unit tests for what Dottie learns about how a game's character moves
//  (DottieGameMovement): turning degrees into mouse points, distance into
//  seconds of holding W, correcting the walk speed when she recognizes a
//  mapped place, and learning how high and far a jump goes. A mistake here
//  makes every blind walk on the 3D map stop short or overshoot.
//

import Foundation
import Testing
@testable import Dottie

/// Each test gets its own empty game folder, so nothing is read from or
/// written to the user's real games.
@MainActor
private func makeMovementInEmptyGameFolder() throws -> (movement: DottieGameMovement, gameFolderURL: URL) {
    let gameFolderURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dottie-game-movement-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: gameFolderURL, withIntermediateDirectories: true)
    return (DottieGameMovement(gameFolderURL: gameFolderURL), gameFolderURL)
}

/// Learned numbers are averages of doubles, so they're compared with a
/// little slack instead of exactly.
private func isNearly(_ firstValue: Double, _ secondValue: Double) -> Bool {
    abs(firstValue - secondValue) < 0.000_001
}

@MainActor
struct GameMovementControlsTests {

    @Test func aNewGameStartsWithTheDefaultGuesses() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        #expect(isNearly(movement.degreesPerMousePoint, 0.25))
        #expect(isNearly(movement.horizontalFieldOfViewDegrees, 70))
        #expect(isNearly(movement.jumpHeightUnits, 1))
        #expect(isNearly(movement.jumpDistanceUnits, 2))
        #expect(movement.cameraControl == nil)
    }

    @Test func degreesBecomeMousePoints() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        // A quarter of a degree per point: a right angle is 360 points.
        #expect(isNearly(Double(movement.mousePoints(forDegrees: 90)), 360))
        #expect(isNearly(Double(movement.mousePoints(forDegrees: -45)), -180))
    }

    @Test func distanceBecomesSecondsOfWalking() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        #expect(isNearly(movement.secondsToWalk(distance: 10, isSprinting: false), 10))
        // Sprinting starts at 1.6 times the walk speed.
        #expect(isNearly(movement.secondsToWalk(distance: 10, isSprinting: true), 6.25))
    }
}

@MainActor
struct GameMovementWalkSpeedTests {

    @Test func coveringTwiceTheExpectedDistanceRaisesTheWalkSpeed() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnWalkSpeed(expectedDistance: 10, actualDistance: 20, walkedSeconds: 5)

        // Measured 2 units a second; an early correction goes halfway there.
        #expect(isNearly(movement.walkUnitsPerSecond(isSprinting: false), 1.5))
        #expect(movement.contents.walkSpeedCorrectionCount == 1)
    }

    @Test func laterCorrectionsOnlyFineTune() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        // Five walks that went exactly as expected leave the speed alone.
        for _ in 0..<5 {
            movement.learnWalkSpeed(expectedDistance: 10, actualDistance: 10, walkedSeconds: 5)
        }
        #expect(isNearly(movement.walkUnitsPerSecond(isSprinting: false), 1))

        movement.learnWalkSpeed(expectedDistance: 10, actualDistance: 20, walkedSeconds: 5)

        // The sixth correction moves a fifth of the way, not half.
        #expect(isNearly(movement.walkUnitsPerSecond(isSprinting: false), 1.2))
        #expect(movement.contents.walkSpeedCorrectionCount == 6)
    }

    @Test func walksTooShortToMeasureAreIgnored() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnWalkSpeed(expectedDistance: 10, actualDistance: 20, walkedSeconds: 0.5)
        movement.learnWalkSpeed(expectedDistance: 0.4, actualDistance: 20, walkedSeconds: 5)
        movement.learnWalkSpeed(expectedDistance: 10, actualDistance: 0.1, walkedSeconds: 5)

        #expect(isNearly(movement.walkUnitsPerSecond(isSprinting: false), 1))
        #expect(movement.contents.walkSpeedCorrectionCount == 0)
    }

    @Test func anImpossibleSpeedIsIgnored() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        // A hundred times the expected distance would mean 100 units a second.
        movement.learnWalkSpeed(expectedDistance: 1, actualDistance: 100, walkedSeconds: 5)

        #expect(isNearly(movement.walkUnitsPerSecond(isSprinting: false), 1))
        #expect(movement.contents.walkSpeedCorrectionCount == 0)
    }
}

@MainActor
struct GameMovementJumpTests {

    @Test func clearingSomethingHigherRaisesTheJumpHeight() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnJump(obstacleHeight: 2, obstacleLength: 1, didClear: true)

        #expect(isNearly(movement.jumpHeightUnits, 1.5))
        #expect(isNearly(movement.jumpDistanceUnits, 2))
        #expect(movement.contents.jumpAttemptCount == 1)
    }

    @Test func clearingSomethingLowAndLongRaisesTheDistanceAndNudgesTheHeight() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnJump(obstacleHeight: 0.5, obstacleLength: 4, didClear: true)

        #expect(isNearly(movement.jumpHeightUnits, 1.05))
        #expect(isNearly(movement.jumpDistanceUnits, 3))
    }

    @Test func failingOnHeightLowersTheJumpHeight() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnJump(obstacleHeight: 1, obstacleLength: 1, didClear: false)

        #expect(isNearly(movement.jumpHeightUnits, 0.875))
        #expect(isNearly(movement.jumpDistanceUnits, 2))
    }

    @Test func failingOnLengthLowersTheJumpDistance() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnJump(obstacleHeight: 0.5, obstacleLength: 2, didClear: false)

        #expect(isNearly(movement.jumpHeightUnits, 1))
        #expect(isNearly(movement.jumpDistanceUnits, 1.875))
    }

    @Test func failingOnSomethingFarAboveTheGuessTeachesNothingNew() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnJump(obstacleHeight: 3, obstacleLength: 1, didClear: false)

        #expect(isNearly(movement.jumpHeightUnits, 1))
        #expect(isNearly(movement.jumpDistanceUnits, 2))
        #expect(movement.contents.jumpAttemptCount == 1)
    }

    @Test func theJumpGuessesStayInsideSensibleLimits() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnJump(obstacleHeight: 20, obstacleLength: 30, didClear: true)
        #expect(isNearly(movement.jumpHeightUnits, 4))
        #expect(isNearly(movement.jumpDistanceUnits, 8))

        let (secondMovement, secondGameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: secondGameFolderURL) }

        secondMovement.learnJump(obstacleHeight: 0.3, obstacleLength: 0.1, didClear: false)
        secondMovement.learnJump(obstacleHeight: 0.3, obstacleLength: 0.1, didClear: false)
        #expect(isNearly(secondMovement.jumpHeightUnits, 0.5))
    }
}

@MainActor
struct GameMovementSavingTests {

    @Test func whatWasLearnedIsThereTheNextTimeTheGameIsPlayed() throws {
        let (movement, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        movement.learnWalkSpeed(expectedDistance: 10, actualDistance: 20, walkedSeconds: 5)
        movement.rememberCameraControl("arrows")

        let movementOnNextLaunch = DottieGameMovement(gameFolderURL: gameFolderURL)
        #expect(isNearly(movementOnNextLaunch.walkUnitsPerSecond(isSprinting: false), 1.5))
        #expect(movementOnNextLaunch.cameraControl == "arrows")
    }

    @Test func aFileSavedBeforeNewerFieldsExistedStillLoads() throws {
        let (_, gameFolderURL) = try makeMovementInEmptyGameFolder()
        defer { try? FileManager.default.removeItem(at: gameFolderURL) }

        let olderFileText = #"{"walkUnitsPerSecond": 2.5}"#
        try Data(olderFileText.utf8).write(to: gameFolderURL.appendingPathComponent("movement.json"))

        let movement = DottieGameMovement(gameFolderURL: gameFolderURL)
        #expect(isNearly(movement.walkUnitsPerSecond(isSprinting: false), 2.5))
        #expect(isNearly(movement.jumpDistanceUnits, 2))
        #expect(isNearly(movement.arrowKeyDegreesPerSecond, 90))
        #expect(movement.cameraControl == nil)
    }
}
