//
//  ScreenJobDragTests.swift
//  leanring-buddyTests
//
//  Screen jobs had no drag and drop: asked to move 115 tasks from Friday
//  onto free days in a study planner, the job could only click, and it
//  ticked a task's checkbox instead. The drag tool presses, moves like a
//  hand and drops.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

@MainActor
struct ScreenJobDragTests {
    // MARK: - The path a drag takes

    @Test func theDragEndsExactlyOnTheDropSpot() {
        let path = DottieScreenActionPerformer.dragPath(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 420), stepCount: 30)
        #expect(path.last == CGPoint(x: 700, y: 420))
    }

    @Test func theFirstMoveIsASmallNudgeSoListsNoticeTheDrag() throws {
        let start = CGPoint(x: 100, y: 100)
        let path = DottieScreenActionPerformer.dragPath(from: start, to: CGPoint(x: 700, y: 100), stepCount: 30)
        let firstPoint = try #require(path.first)
        let nudgeLength = hypot(firstPoint.x - start.x, firstPoint.y - start.y)
        #expect(nudgeLength > 0 && nudgeLength <= 8.001)
    }

    @Test func thePathMovesSteadilyTowardTheDrop() {
        let path = DottieScreenActionPerformer.dragPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 600, y: 0), stepCount: 30)
        for (earlierPoint, laterPoint) in zip(path, path.dropFirst()) {
            #expect(laterPoint.x >= earlierPoint.x)
        }
    }

    @Test func itStartsAndEndsSlowly() {
        let path = DottieScreenActionPerformer.dragPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1000, y: 0), stepCount: 40)
        let firstStep = path[2].x - path[1].x
        let middleStep = path[21].x - path[20].x
        let lastStep = path[path.count - 1].x - path[path.count - 2].x
        #expect(middleStep > firstStep)
        #expect(middleStep > lastStep)
    }

    @Test func tooFewStepsStillMakeASmoothDrag() {
        let path = DottieScreenActionPerformer.dragPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100), stepCount: 1)
        #expect(path.count == 5, "the nudge plus at least four steps")
    }

    @Test func aDragOntoTheSameSpotStaysPut() {
        let spot = CGPoint(x: 300, y: 300)
        let path = DottieScreenActionPerformer.dragPath(from: spot, to: spot, stepCount: 10)
        #expect(path.allSatisfy { $0 == spot })
    }

    @Test func aShortDragGetsAShortNudge() throws {
        let start = CGPoint(x: 0, y: 0)
        let path = DottieScreenActionPerformer.dragPath(from: start, to: CGPoint(x: 12, y: 0), stepCount: 10)
        let firstPoint = try #require(path.first)
        #expect(firstPoint.x <= 3.001, "never more than a quarter of the way")
    }

    // MARK: - Reading the boxes

    @Test func aBoxCenterIsTheMiddle() throws {
        let center = try #require(DottieScreenTaskRunner.normalizedBoxCenter([100, 200, 300, 600]))
        #expect(center.x == 400)
        #expect(center.y == 200)
    }

    @Test func badBoxesAreRefused() {
        #expect(DottieScreenTaskRunner.normalizedBoxCenter(nil) == nil)
        #expect(DottieScreenTaskRunner.normalizedBoxCenter([100, 200, 300]) == nil)
        #expect(DottieScreenTaskRunner.normalizedBoxCenter([300, 200, 100, 600]) == nil, "ymax above ymin")
        #expect(DottieScreenTaskRunner.normalizedBoxCenter("100,200,300,400") == nil)
    }

    // MARK: - The tool

    @Test func screenJobsCanDrag() throws {
        let declaration = try #require(DottieScreenTaskRunner.functionDeclarations.first { ($0["name"] as? String) == "drag" })
        let parameters = try #require(declaration["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["box_2d", "to_box_2d"])
        let description = declaration["description"] as? String ?? ""
        #expect(description.contains("checkbox"), "tells the model never to tick a box to move something")
    }

    /// Claude's pixel boxes become the drag's 0-1000 boxes, drop spot included.
    @Test func claudesPixelBoxesBecomeTheDragsBoxes() throws {
        let converted = DottieScreenJobClaudeBrain.argumentsWithGeminiBoxes(
            ["box_px": [100, 50, 200, 100], "to_box_px": [500, 300, 700, 400], "label": "Read 4A to Saturday"],
            screenshotPixelSize: CGSize(width: 1000, height: 1000)
        )
        let toBox = try #require(converted["to_box_2d"] as? [Double])
        #expect(toBox == [300, 500, 400, 700])
        #expect(converted["box_2d"] != nil)
        #expect(converted["label"] as? String == "Read 4A to Saturday")
    }

    @Test func workingOutAPathIsQuick() {
        let startedAt = Date()
        var pointCount = 0
        for index in 0..<5_000 {
            pointCount += DottieScreenActionPerformer.dragPath(from: CGPoint(x: index, y: 0), to: CGPoint(x: 900, y: index % 700), stepCount: 30).count
        }
        #expect(pointCount == 5_000 * 31)
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
