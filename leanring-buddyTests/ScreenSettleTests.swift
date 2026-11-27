//
//  ScreenSettleTests.swift
//  leanring-buddyTests
//
//  Jev waiting for pages: the browser's own "loaded" counts, two matching
//  looks are needed, loading pages get extra time, and a click whose spot
//  changed before it was made is dropped (at most twice in a row).
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

struct ScreenSettleTests {
    private typealias Settle = DottieScreenSettle
    private typealias Move = DottieJevDriverPlan.Move

    // MARK: Page load from Accessibility

    @Test func loadedAttributeTrueMeansLoaded() {
        #expect(Settle.pageLoad(loadedAttribute: true, loadingProgress: nil) == .loaded)
    }

    @Test func loadedAttributeFalseMeansLoading() {
        #expect(Settle.pageLoad(loadedAttribute: false, loadingProgress: nil) == .loading)
    }

    @Test func progressUnderOneMeansLoadingEvenWhenLoadedSaysTrue() {
        #expect(Settle.pageLoad(loadedAttribute: true, loadingProgress: 0.4) == .loading)
    }

    @Test func fullProgressAloneMeansLoaded() {
        #expect(Settle.pageLoad(loadedAttribute: nil, loadingProgress: 1.0) == .loaded)
    }

    @Test func nothingSaidMeansUnknown() {
        #expect(Settle.pageLoad(loadedAttribute: nil, loadingProgress: nil) == .unknown)
    }

    // MARK: Settled

    @Test func oneMatchingLookIsNotEnough() {
        #expect(!Settle.isSettled(matchingLooksInARow: 1, pageLoad: .loaded))
    }

    @Test func twoMatchingLooksOnALoadedPageSettle() {
        #expect(Settle.isSettled(matchingLooksInARow: 2, pageLoad: .loaded))
    }

    @Test func twoMatchingLooksWithNoBrowserSettle() {
        #expect(Settle.isSettled(matchingLooksInARow: 2, pageLoad: .unknown))
    }

    @Test func aStillPageThatIsLoadingDoesNotSettle() {
        // A blank page that hasn't started drawing looks the same twice.
        #expect(!Settle.isSettled(matchingLooksInARow: 5, pageLoad: .loading))
    }

    // MARK: Time limits

    @Test func ordinaryMovesWaitUpToTwoSeconds() {
        #expect(Settle.maximumWaitSeconds(opensSomethingNew: false, pageLoad: .loaded) == 2)
    }

    @Test func movesThatOpenSomethingWaitUpToFiveSeconds() {
        #expect(Settle.maximumWaitSeconds(opensSomethingNew: true, pageLoad: .unknown) == 5)
    }

    @Test func aLoadingPageGetsExtraTime() {
        #expect(Settle.maximumWaitSeconds(opensSomethingNew: true, pageLoad: .loading) == 5 + Settle.extraSecondsWhilePageLoads)
        #expect(Settle.maximumWaitSeconds(opensSomethingNew: false, pageLoad: .loading) == 2 + Settle.extraSecondsWhilePageLoads)
    }

    // MARK: Target region

    @Test func targetRegionIsCenteredOnTheTarget() {
        let region = Settle.targetRegion(centerX: 0.5, centerY: 0.5, imageWidth: 1000, imageHeight: 600)
        #expect(region.width == 80)
        #expect(region.midX == 500)
        #expect(region.midY == 300)
    }

    @Test func targetRegionStaysInsideTheImageAtTheEdges() {
        let topLeft = Settle.targetRegion(centerX: 0, centerY: 0, imageWidth: 1000, imageHeight: 600)
        #expect(topLeft.minX == 0 && topLeft.minY == 0)
        let bottomRight = Settle.targetRegion(centerX: 1, centerY: 1, imageWidth: 1000, imageHeight: 600)
        #expect(bottomRight.maxX == 1000 && bottomRight.maxY == 600)
    }

    @Test func targetRegionOfAnEmptyImageIsEmpty() {
        #expect(Settle.targetRegion(centerX: 0.5, centerY: 0.5, imageWidth: 0, imageHeight: 0) == .zero)
    }

    @Test func targetRegionHasAMinimumSizeOnTinyImages() {
        let region = Settle.targetRegion(centerX: 0.5, centerY: 0.5, imageWidth: 50, imageHeight: 50)
        #expect(region.width == 8)
    }

    // MARK: Changed under the click

    @Test func samePictureIsUnchanged() {
        let picture = [UInt8](repeating: 120, count: 256)
        #expect(!Settle.targetRegionChanged(pickedOn: picture, now: picture))
    }

    @Test func aSmallFlickerIsUnchanged() {
        let picked = [UInt8](repeating: 120, count: 256)
        let now = [UInt8](repeating: 128, count: 256)
        #expect(!Settle.targetRegionChanged(pickedOn: picked, now: now))
    }

    @Test func somethingElseUnderTheClickIsChanged() {
        let picked = [UInt8](repeating: 240, count: 256)
        let now = [UInt8](repeating: 30, count: 256)
        #expect(Settle.targetRegionChanged(pickedOn: picked, now: now))
    }

    @Test func missingOrMismatchedPicturesCountAsUnchanged() {
        #expect(!Settle.targetRegionChanged(pickedOn: [], now: []))
        #expect(!Settle.targetRegionChanged(pickedOn: [1, 2, 3], now: [1, 2]))
    }

    @Test func staleMoveIsDroppedAtMostTwiceInARow() {
        #expect(Settle.shouldDropStaleMove(targetRegionChanged: true, staleMovesDroppedInARow: 0))
        #expect(Settle.shouldDropStaleMove(targetRegionChanged: true, staleMovesDroppedInARow: 1))
        // A screen that never stops moving (a playing video) still gets its click.
        #expect(!Settle.shouldDropStaleMove(targetRegionChanged: true, staleMovesDroppedInARow: 2))
    }

    @Test func unchangedMoveIsNeverDropped() {
        #expect(!Settle.shouldDropStaleMove(targetRegionChanged: false, staleMovesDroppedInARow: 0))
    }

    // MARK: Which moves are aimed at a spot

    @Test func clicksAndTypingIntoABoxAreAimed() {
        #expect(Move.click(label: "Sign in", centerX: 0.2, centerY: 0.3).aimedPoint?.centerX == 0.2)
        #expect(Move.clickControl(label: "Search", kind: "text box", centerX: 0.4, centerY: 0.1).aimedPoint?.centerY == 0.1)
        #expect(Move.doubleClick(label: "file", centerX: 0.5, centerY: 0.5).aimedPoint != nil)
        #expect(Move.rightClick(label: "file", centerX: 0.5, centerY: 0.5).aimedPoint != nil)
        #expect(Move.typeIntoField(fieldLabel: "Search", centerX: 0.6, centerY: 0.2, text: "cats", pressesReturn: true).aimedPoint?.centerX == 0.6)
        #expect(Move.holdMouseDown(label: "record", centerX: 0.3, centerY: 0.9).aimedPoint != nil)
        #expect(Move.releaseMouseOn(label: "folder", centerX: 0.7, centerY: 0.7).aimedPoint != nil)
    }

    @Test func aDragIsAimedAtWhereItStarts() {
        let drag = Move.drag(fromLabel: "a", fromX: 0.1, fromY: 0.2, toLabel: "b", toX: 0.8, toY: 0.9)
        #expect(drag.aimedPoint?.centerX == 0.1)
        #expect(drag.aimedPoint?.centerY == 0.2)
    }

    @Test func keysScrollsAndOpeningAreNotAimed() {
        let notAimed: [Move] = [
            .pressKeys(keys: "k", meaning: "play"), .pressReturn, .typeText("cats", pressesReturn: false), .scrollDown, .scrollUp,
            .scrollLeft, .scrollRight, .goBack, .openSite(address: "youtube.com"), .searchWeb("cats"), .openApp(name: "Notes"),
            .quickMacAction("open Notes"), .recallAppMemory, .releaseMouseHere, .clickUnlabeled, .finishedRound, .finished, .noneFits
        ]
        for move in notAimed {
            #expect(move.aimedPoint == nil)
        }
    }

    // MARK: Journey: a page that loads slowly, then a click picked on the old page

    @Test func slowPageJourney() {
        // Looks while YouTube is loading: the same blank twice, browser still loading.
        var matchingLooks = 0
        var pageLoad = Settle.PageLoad.loading
        matchingLooks += 2
        #expect(!Settle.isSettled(matchingLooksInARow: matchingLooks, pageLoad: pageLoad))
        // The page finishes and draws: the next look differs, then two match.
        pageLoad = .loaded
        matchingLooks = 0
        #expect(!Settle.isSettled(matchingLooksInARow: matchingLooks, pageLoad: pageLoad))
        matchingLooks = 2
        #expect(Settle.isSettled(matchingLooksInARow: matchingLooks, pageLoad: pageLoad))
        // Jev picks a click, but a banner pushes the page down before it lands.
        let picked = [UInt8](repeating: 220, count: 256)
        let now = [UInt8](repeating: 60, count: 256)
        let changed = Settle.targetRegionChanged(pickedOn: picked, now: now)
        #expect(Settle.shouldDropStaleMove(targetRegionChanged: changed, staleMovesDroppedInARow: 0))
    }

    // MARK: Speed

    @Test func regionCheckIsQuick() {
        let picked = (0..<256).map { UInt8($0 % 256) }
        let now = picked.reversed().map { $0 }
        let startedAt = Date()
        for _ in 0..<10_000 {
            _ = Settle.targetRegionChanged(pickedOn: picked, now: now)
            _ = Settle.targetRegion(centerX: 0.37, centerY: 0.81, imageWidth: 1568, imageHeight: 980)
        }
        // 10,000 checks well under a second: one per click costs nothing.
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
