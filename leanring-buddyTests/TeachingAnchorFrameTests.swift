//
//  TeachingAnchorFrameTests.swift
//  leanring-buddyTests
//
//  Where drawings land: Jev's anchor boxes and the models' boxes become
//  frames on the screen, and Jev's frames win over the models'.
//

import CoreGraphics
import Testing
@testable import Dottie

struct TeachingAnchorFrameTests {

    private let displayFrame = CGRect(x: 0, y: 0, width: 1000, height: 500)

    @Test func aBoxBecomesAFrameWithTheOriginAtTheBottom() {
        let frame = DottieTeaching.appKitFrame(normalizedBox: [100, 200, 300, 400], displayFrame: displayFrame)
        #expect(frame == CGRect(x: 200, y: 350, width: 200, height: 100))
    }

    @Test func aSecondDisplayIsOffsetByItsOrigin() {
        let secondDisplay = CGRect(x: 1000, y: -200, width: 2000, height: 1000)
        let frame = DottieTeaching.appKitFrame(normalizedBox: [0, 0, 1000, 1000], displayFrame: secondDisplay)
        #expect(frame == secondDisplay)
    }

    @Test func aJevBoxLandsTheSameAsTheSameModelBox() {
        let jevBox = DottieJevBox(top: 0.1, bottom: 0.3, left: 0.2, right: 0.4, confidence: 0.9)
        let normalized = jevBox.normalizedBox
        let jevFrame = DottieTeaching.appKitFrame(
            normalizedBox: [normalized.ymin, normalized.xmin, normalized.ymax, normalized.xmax], displayFrame: displayFrame)
        let modelFrame = DottieTeaching.appKitFrame(normalizedBox: [100, 200, 300, 400], displayFrame: displayFrame)
        #expect(abs(jevFrame.minX - modelFrame.minX) < 0.001)
        #expect(abs(jevFrame.minY - modelFrame.minY) < 0.001)
        #expect(abs(jevFrame.width - modelFrame.width) < 0.001)
        #expect(abs(jevFrame.height - modelFrame.height) < 0.001)
    }

    @Test func jevsFramesWinAndTheModelsFillTheRest() {
        let jevFrame = CGRect(x: 1, y: 1, width: 10, height: 10)
        let modelFrameForSameAnchor = CGRect(x: 50, y: 50, width: 10, height: 10)
        let modelFrameForOtherAnchor = CGRect(x: 90, y: 90, width: 5, height: 5)
        let merged = DottieTeaching.mergedAnchorFrames(
            jevFrames: ["peak": jevFrame],
            modelFrames: ["peak": modelFrameForSameAnchor, "origin": modelFrameForOtherAnchor]
        )
        #expect(merged == ["peak": jevFrame, "origin": modelFrameForOtherAnchor])
    }

    @Test func nothingFoundStaysEmpty() {
        #expect(DottieTeaching.mergedAnchorFrames(jevFrames: [:], modelFrames: [:]).isEmpty)
    }

    @Test func onlyTheModelsFoundSomething() {
        let modelFrame = CGRect(x: 3, y: 4, width: 5, height: 6)
        #expect(DottieTeaching.mergedAnchorFrames(jevFrames: [:], modelFrames: ["dot": modelFrame]) == ["dot": modelFrame])
    }
}
