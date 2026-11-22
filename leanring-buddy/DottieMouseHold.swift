//
//  DottieMouseHold.swift
//  leanring-buddy
//
//  Holding the mouse button down and letting go as two separate moves, so
//  Jev, which makes one decision at a time, can press and hold (a "hold to
//  record" button, a long press), drag in steps (press, look, let go where
//  the thing should land) or move a slider. A held button never stays
//  stuck: it's let go when the job ends, stops, hands over or is cancelled,
//  and by itself after 20 seconds. The plan half is pure, so it can be
//  unit tested.
//

import CoreGraphics
import Foundation

enum DottieMouseHoldPlan {
    /// The longest Dottie keeps the button down before letting go by herself.
    static let longestHoldSeconds: Double = 20
    /// Letting go this close (0-1000 of the screen) to where the press was
    /// is a plain release, not a drop somewhere else.
    static let samePlaceDistance = 15.0

    /// Whether letting go at (releaseX, releaseY) drops what's held
    /// somewhere else (so it needs Jev to be clearly sure, like a drag).
    static func releaseMovesTheHeldThing(heldX: Double, heldY: Double, releaseX: Double, releaseY: Double) -> Bool {
        let distance = ((releaseX - heldX) * (releaseX - heldX) + (releaseY - heldY) * (releaseY - heldY)).squareRoot()
        return distance > samePlaceDistance
    }
}

/// The left mouse button while Dottie holds it down.
@MainActor
enum DottieMouseHold {
    /// Where the button was pressed, in global AppKit points, while held.
    private(set) static var heldAt: CGPoint?
    private static var safetyReleaseTask: Task<Void, Never>?

    static var isHolding: Bool { heldAt != nil }

    /// Moves to `point` and presses the left button without letting go.
    static func press(at point: CGPoint) async {
        if isHolding { releaseNow(reason: "pressing somewhere new") }
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let quartzPoint = DottieScreenActionPerformer.quartzPoint(fromAppKit: point)
        CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 80_000_000)
        CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        heldAt = point
        DottieLog.notice("🖱️ Holding the mouse button down")
        safetyReleaseTask?.cancel()
        safetyReleaseTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(DottieMouseHoldPlan.longestHoldSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            releaseNow(reason: "held for \(Int(DottieMouseHoldPlan.longestHoldSeconds)) seconds")
        }
    }

    /// Lets go at `point`, moving there with the button still down first
    /// (a drop), or where it was pressed when `point` is nil.
    static func release(at point: CGPoint?) async {
        guard let heldAt else { return }
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let quartzStart = DottieScreenActionPerformer.quartzPoint(fromAppKit: heldAt)
        let quartzEnd = DottieScreenActionPerformer.quartzPoint(fromAppKit: point ?? heldAt)
        if quartzEnd != quartzStart {
            for pathPoint in DottieScreenActionPerformer.dragPath(from: quartzStart, to: quartzEnd, stepCount: 30) {
                CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: pathPoint, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            // Drop targets highlight on hover; letting go at once can miss them.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: quartzEnd, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        clear()
        DottieLog.notice("🖱️ Let go of the mouse button")
    }

    /// Lets go at once where it was pressed, if the button is held. Safe to
    /// call any time: every way a job ends calls it.
    static func releaseNow(reason: String) {
        guard let heldAt else { return }
        let quartzPoint = DottieScreenActionPerformer.quartzPoint(fromAppKit: heldAt)
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .leftMouseUp, mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        clear()
        DottieLog.notice("🖱️ Let go of the held mouse button (\(reason))")
    }

    private static func clear() {
        heldAt = nil
        safetyReleaseTask?.cancel()
        safetyReleaseTask = nil
    }
}
