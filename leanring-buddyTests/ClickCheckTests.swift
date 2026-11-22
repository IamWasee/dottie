//
//  ClickCheckTests.swift
//  leanring-buddyTests
//
//  Click checks: where the model pointed vs. where Dottie clicked, mapped
//  onto the screenshot and logged, with the last 30 pictures kept in slots.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

struct ClickCheckTests {
    // A 1440x900 display to the right of the primary one, captured at 1280x800.
    let secondDisplayFrame = CGRect(x: 1512, y: 0, width: 1440, height: 900)

    @Test func theDisplaysCornersLandOnThePicturesCorners() {
        let topLeft = DottieClickCheck.imagePixel(forGlobalPoint: CGPoint(x: 1512, y: 900), displayFrame: secondDisplayFrame, imageWidth: 1280, imageHeight: 800)
        let bottomRight = DottieClickCheck.imagePixel(forGlobalPoint: CGPoint(x: 2952, y: 0), displayFrame: secondDisplayFrame, imageWidth: 1280, imageHeight: 800)
        #expect(topLeft == CGPoint(x: 0, y: 0))
        #expect(bottomRight == CGPoint(x: 1280, y: 800))
    }

    @Test func theMiddleOfTheDisplayIsTheMiddleOfThePicture() {
        let middle = DottieClickCheck.imagePixel(forGlobalPoint: CGPoint(x: 2232, y: 450), displayFrame: secondDisplayFrame, imageWidth: 1280, imageHeight: 800)
        #expect(middle == CGPoint(x: 640, y: 400))
    }

    @Test func aPointNearTheTopIsNearThePicturesTop() {
        // AppKit counts up from the bottom; the picture counts down from the top.
        let nearTop = DottieClickCheck.imagePixel(forGlobalPoint: CGPoint(x: 1512, y: 810), displayFrame: secondDisplayFrame, imageWidth: 1280, imageHeight: 800)
        #expect(abs(nearTop.y - 80) < 0.001)
    }

    @Test func anEmptyDisplayFrameGivesTheCornerInsteadOfDividingByZero() {
        #expect(DottieClickCheck.imagePixel(forGlobalPoint: CGPoint(x: 5, y: 5), displayFrame: .zero, imageWidth: 100, imageHeight: 100) == .zero)
    }

    @Test func theOffsetCountsRightAndDownLikeAPersonReadsTheScreen() {
        let moved = DottieClickCheck.offset(fromModelPoint: CGPoint(x: 100, y: 500), toFinalPoint: CGPoint(x: 103, y: 496))
        #expect(moved.right == 3)
        #expect(moved.down == 4)
        #expect(moved.distance == 5)
    }

    @Test func noMoveIsZero() {
        let moved = DottieClickCheck.offset(fromModelPoint: CGPoint(x: 10, y: 10), toFinalPoint: CGPoint(x: 10, y: 10))
        #expect(moved.distance == 0)
    }

    @Test func theLogLineHasBothPointsTheMoveAndThePicture() {
        let line = DottieClickCheck.logText(stepNumber: 3, label: "Send", modelPoint: CGPoint(x: 100.4, y: 500), finalPoint: CGPoint(x: 130, y: 460), source: .jev, slot: 7)
        #expect(line.contains("step 3"))
        #expect(line.contains("\"Send\""))
        #expect(line.contains("model (100, 500)"))
        #expect(line.contains("clicked (130, 460)"))
        #expect(line.contains("by Jev's box"))
        #expect(line.contains("moved 30 right 40 down (50 pt)"))
        #expect(line.contains("click-check-07.jpg"))
    }

    @Test func aLongLabelIsCutShort() {
        let line = DottieClickCheck.logText(stepNumber: 1, label: String(repeating: "a", count: 200), modelPoint: .zero, finalPoint: .zero, source: .modelBox, slot: 0)
        #expect(!line.contains(String(repeating: "a", count: 61)))
    }

    @Test func slotsStartAtZeroAndGoRoundAfterThirty() {
        #expect(DottieClickCheck.nextSlot(after: nil) == 0)
        #expect(DottieClickCheck.nextSlot(after: -4) == 0)
        #expect(DottieClickCheck.nextSlot(after: 0) == 1)
        #expect(DottieClickCheck.nextSlot(after: 28) == 29)
        #expect(DottieClickCheck.nextSlot(after: 29) == 0)
    }

    @Test func fileNamesHaveTwoDigitsSoTheySortInOrder() {
        #expect(DottieClickCheck.fileName(forSlot: 0) == "click-check-00.jpg")
        #expect(DottieClickCheck.fileName(forSlot: 9) == "click-check-09.jpg")
        #expect(DottieClickCheck.fileName(forSlot: 29) == "click-check-29.jpg")
    }

    @Test func everySlotHasItsOwnFile() {
        let names = Set((0..<DottieClickCheck.slotCount).map { DottieClickCheck.fileName(forSlot: $0) })
        #expect(names.count == 30)
    }
}
