//
//  DottieScreenJobPointer.swift
//  leanring-buddy
//
//  Where the mouse pointer is while a screen job runs. Every click used to
//  put the user's pointer back 0.15 s later, which closed the menus that
//  only open while the mouse is over something (Wasee, 27 Nov: "a bunch of
//  other buttons fall down" on hover). Now the pointer stays wherever the
//  job last put it, so a menu Jev hovered stays open for the next move,
//  and when the job ends it goes back to where the user had it, unless the
//  user moved it themselves meanwhile. Moving from a hover spot to the
//  menu's item glides the pointer there so the menu doesn't close on the way.
//

import AppKit
import CoreGraphics
import Foundation

/// The pure parts, so they can be tested.
enum DottieScreenJobPointerPlan {
    /// The pointer this far from where the job last put it means the user
    /// moved it, so it isn't pulled back when the job ends.
    static let userMovedItDistance: CGFloat = 6
    /// How long a hover rests before the next look: menus open after a beat.
    static let hoverRestSeconds = 0.45
    static let glideSeconds = 0.14

    /// Whether the pointer goes back to where the user had it when the job
    /// ends: only when the job moved it and it's still where the job left it.
    static func shouldPutPointerBack(currentPoint: CGPoint, lastPointPlacedByJob: CGPoint?, homePoint: CGPoint) -> Bool {
        guard let lastPointPlacedByJob else { return false }
        guard hypot(currentPoint.x - homePoint.x, currentPoint.y - homePoint.y) > 0.5 else { return false }
        return hypot(currentPoint.x - lastPointPlacedByJob.x, currentPoint.y - lastPointPlacedByJob.y) <= userMovedItDistance
    }

    /// How many small moves a glide takes: more for longer trips, so the
    /// pointer passes over the menu instead of jumping past its edge.
    static func glideStepCount(from start: CGPoint, to end: CGPoint) -> Int {
        let distance = hypot(end.x - start.x, end.y - start.y)
        return max(4, min(16, Int((distance / 40).rounded(.up))))
    }

    /// The points a glide passes through, eased (slow start and end), always
    /// ending exactly on `end`.
    static func glidePath(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let stepCount = glideStepCount(from: start, to: end)
        var points: [CGPoint] = []
        for stepIndex in 1...stepCount {
            let progress = CGFloat(stepIndex) / CGFloat(stepCount)
            let easedProgress = progress * progress * (3 - 2 * progress)
            points.append(CGPoint(x: start.x + (end.x - start.x) * easedProgress, y: start.y + (end.y - start.y) * easedProgress))
        }
        points[points.count - 1] = end
        return points
    }
}

/// The pointer's state during a screen job. Points are Quartz points
/// (top-left origin), like the events posted.
@MainActor
enum DottieScreenJobPointer {
    private static var homePoint: CGPoint?
    private static var lastPlacedPoint: CGPoint?
    private static var currentJobNumber = 0
    /// The pointer rests on something Jev hovered, so a menu may be open
    /// under it: the next click glides there instead of jumping.
    private(set) static var restsOnHoverSpot = false

    /// True while a job runs: clicks and scrolls leave the pointer where they act.
    static var keepsPointerWhereItActs: Bool { homePoint != nil }

    /// Remembers where the user's pointer is; returns the job's number for `endJob`.
    @discardableResult
    static func beginJob() -> Int {
        currentJobNumber += 1
        homePoint = CGEvent(source: nil)?.location
        lastPlacedPoint = nil
        restsOnHoverSpot = false
        return currentJobNumber
    }

    /// The job moved the pointer here (Quartz point).
    static func notePlaced(_ quartzPoint: CGPoint, isHover: Bool = false) {
        guard keepsPointerWhereItActs else { return }
        lastPlacedPoint = quartzPoint
        restsOnHoverSpot = isHover
    }

    /// Puts the pointer back where the user had it, unless they moved it
    /// meanwhile. A newer job's pointer is left alone.
    static func endJob(_ jobNumber: Int) {
        guard jobNumber == currentJobNumber, let homePoint else { return }
        let placedPoint = lastPlacedPoint
        self.homePoint = nil
        lastPlacedPoint = nil
        restsOnHoverSpot = false
        guard let currentPoint = CGEvent(source: nil)?.location,
              DottieScreenJobPointerPlan.shouldPutPointerBack(currentPoint: currentPoint, lastPointPlacedByJob: placedPoint, homePoint: homePoint) else { return }
        CGWarpMouseCursorPosition(homePoint)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
