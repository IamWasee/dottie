//
//  JevZoomTests.swift
//  leanring-buddyTests
//
//  Zoom and refine: which Jev boxes get a close-up, where the close-up is
//  cut, mapping the close-up's box back, and throwing away a close-up that
//  found something else.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

struct JevZoomTests {
    private func box(top: Double, bottom: Double, left: Double, right: Double) -> DottieJevBox {
        DottieJevBox(top: top, bottom: bottom, left: left, right: right, confidence: 0.9)
    }

    @Test func smallBoxesGetACloseUpAndBigOnesDont() {
        #expect(DottieJevZoom.needsCloseUp(box(top: 0.1, bottom: 0.12, left: 0.5, right: 0.52)))
        #expect(!DottieJevZoom.needsCloseUp(box(top: 0.1, bottom: 0.4, left: 0.1, right: 0.6)))
    }

    @Test func theCloseUpIsCenteredOnTheBox() throws {
        let rect = try #require(DottieJevZoom.closeUpRect(around: box(top: 0.49, bottom: 0.51, left: 0.49, right: 0.51), imageWidth: 3000, imageHeight: 2000))
        #expect(rect.width == 480)
        #expect(rect.height == 480)
        #expect(abs(rect.midX - 1500) <= 1)
        #expect(abs(rect.midY - 1000) <= 1)
    }

    @Test func theCloseUpStaysInsideThePictureAtTheEdges() throws {
        let rect = try #require(DottieJevZoom.closeUpRect(around: box(top: 0, bottom: 0.01, left: 0.99, right: 1), imageWidth: 3000, imageHeight: 2000))
        #expect(rect.minY == 0)
        #expect(rect.maxX == 3000)
    }

    @Test func aBiggerBoxGetsABiggerCloseUp() throws {
        let rect = try #require(DottieJevZoom.closeUpRect(around: box(top: 0.5, bottom: 0.55, left: 0.5, right: 0.55), imageWidth: 3000, imageHeight: 2000))
        // 5 times the box's longer side (0.05 × 3000 = 150 pixels).
        #expect(rect.width == 750)
    }

    @Test func aTinyPictureHasNoCloseUp() {
        #expect(DottieJevZoom.closeUpRect(around: box(top: 0.5, bottom: 0.51, left: 0.5, right: 0.51), imageWidth: 200, imageHeight: 200) == nil)
    }

    @Test func theCloseUpsBoxMapsBackOntoTheWholePicture() {
        let closeUp = CGRect(x: 1000, y: 500, width: 500, height: 500)
        let mapped = DottieJevZoom.wholePictureBox(fromCloseUpBox: box(top: 0.4, bottom: 0.6, left: 0.2, right: 0.4), closeUpRect: closeUp, imageWidth: 2000, imageHeight: 1000)
        #expect(abs(mapped.left - 0.55) < 0.0001)
        #expect(abs(mapped.right - 0.6) < 0.0001)
        #expect(abs(mapped.top - 0.7) < 0.0001)
        #expect(abs(mapped.bottom - 0.8) < 0.0001)
    }

    @Test func aCloseUpNearTheFirstBoxIsTheSameTarget() {
        let first = box(top: 0.5, bottom: 0.52, left: 0.5, right: 0.52)
        #expect(DottieJevZoom.isSameTarget(refinedBox: box(top: 0.505, bottom: 0.515, left: 0.525, right: 0.535), firstBox: first))
    }

    @Test func aCloseUpFarFromTheFirstBoxIsSomethingElse() {
        let first = box(top: 0.5, bottom: 0.52, left: 0.5, right: 0.52)
        #expect(!DottieJevZoom.isSameTarget(refinedBox: box(top: 0.5, bottom: 0.52, left: 0.7, right: 0.72), firstBox: first))
    }
}
