//
//  PointingPlaceInListTests.swift
//  leanring-buddyTests
//
//  "Point at my first email" in 1.0.76: Live pointed at the right row,
//  then the vision second look moved the cursor up into the browser's top
//  bar. A label that picks one by its place in a list now keeps Live's
//  guess instead of asking vision.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

@MainActor
struct PointingPlaceInListTests {
    @Test func ordinalWordsAreAPlaceInAList() {
        #expect(PointingRefiner.isPlaceInAList("first email"))
        #expect(PointingRefiner.isPlaceInAList("the second search result"))
        #expect(PointingRefiner.isPlaceInAList("Third video"))
        #expect(PointingRefiner.isPlaceInAList("tenth row"))
    }

    @Test func numberedOrdinalsAreAPlaceInAList() {
        #expect(PointingRefiner.isPlaceInAList("1st email"))
        #expect(PointingRefiner.isPlaceInAList("the 3rd result"))
        #expect(PointingRefiner.isPlaceInAList("10th item"))
    }

    @Test func newestAndLastAreAPlaceInAList() {
        #expect(PointingRefiner.isPlaceInAList("latest message"))
        #expect(PointingRefiner.isPlaceInAList("the last tab"))
        #expect(PointingRefiner.isPlaceInAList("newest notification"))
        #expect(PointingRefiner.isPlaceInAList("next page arrow"))
    }

    @Test func namesOnScreenAreNotAPlaceInAList() {
        #expect(!PointingRefiner.isPlaceInAList("Compose"))
        #expect(!PointingRefiner.isPlaceInAList("Sign in button"))
        #expect(!PointingRefiner.isPlaceInAList("TP-Link email"))
        #expect(!PointingRefiner.isPlaceInAList("top bar"))
        #expect(!PointingRefiner.isPlaceInAList(""))
    }

    @Test func wordsThatOnlyContainAnOrdinalDoNotCount() {
        #expect(!PointingRefiner.isPlaceInAList("firstname field"))
        #expect(!PointingRefiner.isPlaceInAList("Lasting Impressions"))
        #expect(!PointingRefiner.isPlaceInAList("secondhand shop"))
    }

    @Test func aPlaceInAListKeepsLiveGuess() async {
        let displayFrame = CGRect(x: 0, y: 0, width: 1000, height: 650)
        let refinedFrame = await PointingRefiner.refineFrame(
            elementLabel: "first email",
            userQuestion: "point at my first email",
            roughPoint: CGPoint(x: 600, y: 450),
            displayFrame: displayFrame,
            timeoutSeconds: 1
        )
        #expect(refinedFrame == nil, "Live's guess stands; nothing moves the cursor away from the row")
    }

    @Test func checkingLabelsIsQuick() {
        let startedAt = Date()
        var placeCount = 0
        for index in 0..<20_000 where PointingRefiner.isPlaceInAList(index.isMultiple(of: 2) ? "first email \(index)" : "Compose \(index)") {
            placeCount += 1
        }
        #expect(placeCount == 10_000)
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
