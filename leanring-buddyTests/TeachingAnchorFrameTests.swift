//
//  TeachingAnchorFrameTests.swift
//  leanring-buddyTests
//
//  Where drawings land: the model's anchor boxes become frames on the
//  screen.
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
}
