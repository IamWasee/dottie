//
//  PointingMatchScoreTests.swift
//  leanring-buddyTests
//
//  Unit tests for how pointing weighs a found element against Live's
//  guess. "Click my first email" (an email from GitHub) used to land on
//  the browser's GitHub tab: its short exact name beat the long email row
//  Live had pointed at. Being under the guess, or on its row, now counts
//  for more than a tight name a few rows away.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

@MainActor
struct PointingMatchScoreTests {
    private let maximumDistance: CGFloat = 350

    private func score(quality: Double = 1, extraWords: Int = 0, distance: CGFloat, underGuess: Bool = false) -> Double? {
        PointingMatchScore.score(matchQuality: quality, extraWordCount: extraWords, distanceFromGuess: distance,
                                 containsGuess: underGuess, maximumDistanceFromGuess: maximumDistance)
    }

    // MARK: - The bug

    @Test func theEmailRowUnderTheGuessBeatsTheTabWithTheSameName() {
        // The tab "GitHub" sits 250 points above the guess.
        let tabDistance = PointingMatchScore.distance(horizontal: -40, vertical: 250)
        let tabScore = score(distance: tabDistance)
        // The row "GitHub · [repo] New issue … preview" is under the guess.
        let rowDistance = PointingMatchScore.distance(horizontal: 120, vertical: 4)
        let rowScore = score(extraWords: 15, distance: rowDistance, underGuess: true)
        #expect(rowScore != nil)
        #expect(tabScore == nil || tabScore! < rowScore!)
    }

    @Test func aMatchAFewRowsAboveIsTooFarEvenWhenItsNameIsExact() {
        let tabDistance = PointingMatchScore.distance(horizontal: 0, vertical: 250)
        #expect(tabDistance > maximumDistance)
        #expect(score(distance: tabDistance) == nil)
    }

    @Test func onScreenTextOnTheGuesssRowWinsOverTheSameWordOnATabAbove() {
        let textLimit = PointingMatchScore.textSearchMaximumDistance
        let senderWord = PointingMatchScore.score(matchQuality: 0.9, extraWordCount: 0,
                                                  distanceFromGuess: PointingMatchScore.distance(horizontal: -300, vertical: 0),
                                                  containsGuess: false, maximumDistanceFromGuess: textLimit)
        let tabWord = PointingMatchScore.score(matchQuality: 1, extraWordCount: 0,
                                               distanceFromGuess: PointingMatchScore.distance(horizontal: -300, vertical: 250),
                                               containsGuess: false, maximumDistanceFromGuess: textLimit)
        #expect(senderWord != nil)
        #expect(tabWord == nil || tabWord! < senderWord!)
    }

    // MARK: - Distance

    @Test func upAndDownCountMoreThanSideways() {
        #expect(PointingMatchScore.distance(horizontal: 0, vertical: 100) > PointingMatchScore.distance(horizontal: 100, vertical: 0))
        #expect(PointingMatchScore.distance(horizontal: 100, vertical: 0) == 100)
        #expect(abs(PointingMatchScore.distance(horizontal: 0, vertical: 100) - 250) < 0.001)
        #expect(PointingMatchScore.distance(horizontal: 0, vertical: 0) == 0)
        #expect(PointingMatchScore.distance(horizontal: -30, vertical: -40) == PointingMatchScore.distance(horizontal: 30, vertical: 40))
    }

    @Test func nearerScoresHigherWithEverythingElseEqual() {
        let near = score(distance: 20)!
        let middle = score(distance: 150)!
        let far = score(distance: 340)!
        #expect(near > middle)
        #expect(middle > far)
    }

    @Test func exactlyAtTheLimitStillCountsAndJustPastItDoesNot() {
        #expect(score(distance: maximumDistance) != nil)
        #expect(score(distance: maximumDistance + 0.5) == nil)
    }

    @Test func anElementUnderTheGuessCountsHoweverFarItsCenterIs() {
        // A wide row whose center is far from the guess but which holds it.
        #expect(score(distance: 900, underGuess: true) != nil)
    }

    // MARK: - Name

    @Test func aTighterNameBeatsALongerOneAtTheSameSpot() {
        #expect(score(extraWords: 0, distance: 50)! > score(extraWords: 4, distance: 50)!)
    }

    @Test func extraWordsStopCostingMoreAfterTheCap() {
        let tenExtra = score(extraWords: 10, distance: 50)!
        let fortyExtra = score(extraWords: 40, distance: 50)!
        #expect(abs(tenExtra - fortyExtra) < 0.0001)
    }

    @Test func aNegativeExtraWordCountIsTreatedAsNone() {
        #expect(score(extraWords: -3, distance: 50) == score(extraWords: 0, distance: 50))
    }

    @Test func aFullNameMatchBeatsAPartialOneAtTheSameSpot() {
        #expect(score(quality: 1, distance: 80)! > score(quality: 0.7, distance: 80)!)
    }

    @Test func theScoreIsAlwaysAboveZeroWhenItCounts() {
        let weakest = score(quality: 0, extraWords: 50, distance: maximumDistance)
        #expect(weakest != nil)
        #expect(weakest! > 0)
    }

    @Test func aZeroLimitDoesNotDivideByZero() {
        let result = PointingMatchScore.score(matchQuality: 1, extraWordCount: 0, distanceFromGuess: 0,
                                              containsGuess: false, maximumDistanceFromGuess: 0)
        #expect(result != nil)
        #expect(result!.isFinite)
    }

    // MARK: - Speed

    @Test func scoringThousandsOfElementsIsQuick() {
        let startedAt = Date()
        var total = 0.0
        for index in 0..<20_000 {
            let distance = PointingMatchScore.distance(horizontal: CGFloat(index % 400), vertical: CGFloat(index % 90))
            total += score(extraWords: index % 12, distance: distance, underGuess: index % 7 == 0) ?? 0
        }
        #expect(total > 0)
        #expect(Date().timeIntervalSince(startedAt) < 0.5)
    }
}
