//
//  ClickOnScreenTests.swift
//  leanring-buddyTests
//
//  "Click it": Claude clicks one thing with click_on_screen at a spot on
//  the screenshot it was given (0-1000 of that image), the same picture it
//  points on, instead of starting a whole screen job.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

@MainActor
struct ClickOnScreenTests {
    private let retinaLaptopCapture = CompanionScreenCapture(
        imageData: Data(),
        label: "user's screen (cursor is here)",
        isCursorScreen: true,
        displayWidthInPoints: 1512,
        displayHeightInPoints: 982,
        displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        screenshotWidthInPixels: 1280,
        screenshotHeightInPixels: 831
    )

    @Test func theMiddleOfTheScreenshotIsItsMiddlePixel() {
        let pixel = CompanionManager.screenshotPixel(forNormalizedX: 500, normalizedY: 500, in: retinaLaptopCapture)
        #expect(pixel == CGPoint(x: 640, y: 415.5))
    }

    @Test func theCornersMapToTheScreenshotsCorners() {
        #expect(CompanionManager.screenshotPixel(forNormalizedX: 0, normalizedY: 0, in: retinaLaptopCapture) == .zero)
        #expect(CompanionManager.screenshotPixel(forNormalizedX: 1000, normalizedY: 1000, in: retinaLaptopCapture) == CGPoint(x: 1280, y: 831))
    }

    @Test func spotsOffTheScreenshotStayOnIt() {
        let pixel = CompanionManager.screenshotPixel(forNormalizedX: -40, normalizedY: 1300, in: retinaLaptopCapture)
        #expect(pixel == CGPoint(x: 0, y: 831))
    }

    @Test func aClickLandsWhereTheSameSpotWouldBePointedAt() {
        // Pointing turns screenshot pixels into a screen place; a click at
        // the same spot, given as 0-1000, must end up in the same place.
        let pointedPixel = CGPoint(x: 320, y: 200)
        let clickPixel = CompanionManager.screenshotPixel(forNormalizedX: 250, normalizedY: 200.0 / 831 * 1000, in: retinaLaptopCapture)
        let pointedPlace = CompanionManager.globalScreenLocation(forScreenshotPixel: pointedPixel, in: retinaLaptopCapture)
        let clickedPlace = CompanionManager.globalScreenLocation(forScreenshotPixel: clickPixel, in: retinaLaptopCapture)
        #expect(abs(pointedPlace.x - clickedPlace.x) < 0.5)
        #expect(abs(pointedPlace.y - clickedPlace.y) < 0.5)
    }

    @Test func claudeIsGivenTheClickTool() {
        #expect(DottieTalkerProtocol.requestToolNames.contains("click_on_screen"))
        let declarations = DottieTalkerProtocol.requestToolDeclarations(from: DottieVoiceTools.everyFunctionDeclaration, findAndUseDeclarations: [])
        #expect(declarations.contains { $0["name"] as? String == "click_on_screen" })
    }

    @Test func claudeClicksOneThingAndStartsJobsOnlyForLongerWork() {
        let requestPrompt = DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "")
        #expect(requestPrompt.contains("click one thing on the screenshot with click_on_screen"))
        #expect(requestPrompt.contains("do_task_on_screen"))
    }

    @Test func theClickToolSpeaksOfTheScreenshotNotALiveFrame() throws {
        let declaration = try #require(DottieScreenAction.functionDeclarations.first { $0["name"] as? String == "click_on_screen" })
        let description = try #require(declaration["description"] as? String)
        #expect(description.contains("screenshot"))
        #expect(description.contains("do_task_on_screen"))
    }

    @Test func aClickCallIsReadAsAClick() throws {
        let action = try #require(DottieScreenAction(functionName: "click_on_screen", arguments: ["x": 250, "y": 240, "label": "Sign in"]))
        guard case .click(let normalizedX, let normalizedY, let label, let clickCount, let isRightClick) = action else {
            Issue.record("not read as a click")
            return
        }
        #expect(normalizedX == 250 && normalizedY == 240)
        #expect(label == "Sign in" && clickCount == 1 && !isRightClick)
    }

    @Test func aClickWithoutASpotIsRefused() {
        #expect(DottieScreenAction(functionName: "click_on_screen", arguments: ["label": "Sign in"]) == nil)
    }

    @MainActor @Test func aClickThatChangedNothingIsNotReportedAsDone() {
        let result = CompanionManager.clickChangedNothingResult(label: "Search")
        #expect(result.contains("NOT done"))
        #expect(result.contains("do_task_on_screen"))
        #expect(result.contains("Search"))
    }
}
