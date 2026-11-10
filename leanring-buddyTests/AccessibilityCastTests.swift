//
//  AccessibilityCastTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieAccessibilityCast: a value an app hands back
//  through Accessibility becomes the expected type, and anything else
//  becomes nil instead of crashing Dottie.
//

import ApplicationServices
import Foundation
import Testing
@testable import Dottie

struct AccessibilityCastTests {

    @Test func missingValueIsNeitherAnElementNorAValue() {
        #expect(DottieAccessibilityCast.element(nil) == nil)
        #expect(DottieAccessibilityCast.axValue(nil) == nil)
    }

    @Test func realElementComesBackAsAnElement() {
        let systemWideElement = AXUIElementCreateSystemWide()

        #expect(DottieAccessibilityCast.element(systemWideElement) != nil)
        #expect(DottieAccessibilityCast.axValue(systemWideElement) == nil)
    }

    @Test func realPositionComesBackAsAValueWithTheSamePoint() {
        var originalPoint = CGPoint(x: 12, y: 34)
        let positionValue = AXValueCreate(.cgPoint, &originalPoint)

        let positionAXValue = DottieAccessibilityCast.axValue(positionValue)

        var readBackPoint = CGPoint.zero
        var couldReadPointBack = false
        if let positionAXValue {
            couldReadPointBack = AXValueGetValue(positionAXValue, .cgPoint, &readBackPoint)
        }
        #expect(couldReadPointBack)
        #expect(readBackPoint == CGPoint(x: 12, y: 34))
        #expect(DottieAccessibilityCast.element(positionValue) == nil)
    }

    @Test func textAndNumbersAreNeitherAnElementNorAValue() {
        let textValue = "Untitled" as CFString
        let numberValue = NSNumber(value: 7)

        #expect(DottieAccessibilityCast.element(textValue) == nil)
        #expect(DottieAccessibilityCast.axValue(textValue) == nil)
        #expect(DottieAccessibilityCast.element(numberValue) == nil)
        #expect(DottieAccessibilityCast.axValue(numberValue) == nil)
    }
}
