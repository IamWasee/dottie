//
//  DottieReplayPlayer.swift
//  leanring-buddy
//
//  Plays a saved replay (DottieReplays.swift) back on the screen with no
//  Gemini calls. Before every click it finds the target again
//  (Accessibility first, then on-screen text, then a picture of the spot)
//  and waits for it to show up instead of sleeping a fixed time, so a
//  replay runs as fast as the apps can draw. Dottie's cursor still flies
//  to each click. A step whose target can't be found stops the replay, and
//  DottieScreenTaskRunner carries on from there with Gemini.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class DottieReplayPlayer {
    enum Result {
        /// Every step was done.
        case completed(playedSteps: [DottieReplay.Step])
        case stopped
        /// Step `stepIndex` (0-based) couldn't be checked, so Gemini takes over.
        case handedOver(playedSteps: [DottieReplay.Step], stepIndex: Int, reason: String)
    }

    /// The notch line for each step.
    var onProgress: (@MainActor (String) -> Void)?
    /// Flies Dottie's cursor to a click (global point, its display).
    var onWillClick: (@MainActor (CGPoint, CGRect) async -> Void)?

    /// How long to wait for a step's target to appear after the step before
    /// it (a page loading, a menu opening).
    private static let targetWaitSeconds: TimeInterval = 4

    func play(_ replay: DottieReplay) async -> Result {
        var playedSteps: [DottieReplay.Step] = []
        for (stepIndex, step) in replay.steps.enumerated() {
            if Task.isCancelled { return .stopped }
            let outcome = await perform(step, stepNumber: stepIndex + 1, of: replay.steps.count)
            if Task.isCancelled { return .stopped }
            if let failureReason = outcome {
                print("⚡ Replay \"\(replay.name)\" stopped at step \(stepIndex + 1) (\(step.summary)): \(failureReason)")
                return .handedOver(playedSteps: playedSteps, stepIndex: stepIndex, reason: failureReason)
            }
            playedSteps.append(step)
        }
        return .completed(playedSteps: playedSteps)
    }

    /// Does one step. Returns nil when done, or why it couldn't.
    private func perform(_ step: DottieReplay.Step, stepNumber: Int, of stepCount: Int) async -> String? {
        let arguments = step.arguments
        func flag(_ key: String) -> Bool { arguments[key] == "true" }
        let progressPrefix = "⚡ \(stepNumber)/\(stepCount) "

        switch step.action {
        case "open_app":
            guard let appName = arguments["name"] else { return "no app name" }
            onProgress?(progressPrefix + "opening \(appName)")
            guard await DottieScreenTaskRunner.openApplication(named: appName) else { return "couldn't open \(appName)" }
            let wantedName = appName.lowercased().replacingOccurrences(of: ".app", with: "")
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased(),
                   frontmostName == wantedName || frontmostName.hasPrefix(wantedName) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            return nil

        case "open_url":
            guard let address = arguments["url"], let url = URL(string: address.contains("://") ? address : "https://" + address) else {
                return "no address"
            }
            onProgress?(progressPrefix + "opening \(url.host ?? address)")
            let didOpen: Bool
            if let browserName = arguments["browser"] {
                didOpen = await DottieScreenTaskRunner.open(url, inApplicationNamed: browserName)
            } else {
                didOpen = await DottieBrowser.openInUsersBrowser(url)
            }
            guard didOpen else { return "couldn't open \(address)" }
            // The next step waits for its own target, so just a beat here.
            try? await Task.sleep(nanoseconds: 700_000_000)
            return nil

        case "click":
            guard let target = step.target else { return "no saved target" }
            onProgress?(progressPrefix + "clicking \(target.label ?? target.title ?? "it")")
            guard let point = await locate(target) else { return "couldn't find \(target.label ?? target.title ?? "the thing to click")" }
            await flyAndClick(at: point, clickCount: flag("double_click") ? 2 : 1, isRightClick: flag("right_click"))
            return nil

        case "type_text":
            guard let typedText = arguments["text"], !typedText.isEmpty else { return "nothing to type" }
            if let target = step.target {
                guard let point = await locate(target) else { return "couldn't find the field" }
                await flyAndClick(at: point, clickCount: 1, isRightClick: false)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if DottieScreenActionPerformer.isFocusedFieldSecure { return "that's a password field" }
            onProgress?(progressPrefix + "typing \"\(typedText.prefix(40))\"")
            if flag("select_all_first") { DottieScreenActionPerformer.press(keyCombination: "cmd+a") }
            await DottieScreenActionPerformer.type(typedText)
            if flag("press_enter") {
                try? await Task.sleep(nanoseconds: 150_000_000)
                DottieScreenActionPerformer.press(keyCombination: "enter")
            }
            return nil

        case "press_keys":
            guard let keys = arguments["keys"] else { return "no keys" }
            onProgress?(progressPrefix + "pressing \(keys)")
            guard DottieScreenActionPerformer.press(keyCombination: keys) else { return "unknown keys \(keys)" }
            try? await Task.sleep(nanoseconds: 250_000_000)
            return nil

        case "scroll":
            guard let direction = arguments["direction"].flatMap({ DottieScreenAction.ScrollDirection(rawValue: $0) }) else {
                return "no direction"
            }
            onProgress?(progressPrefix + "scrolling \(direction.rawValue)")
            let amount = Int(arguments["amount"] ?? "") ?? 5
            let point = step.target.map { expectedPoint(for: $0) }
            DottieScreenActionPerformer.scroll(direction: direction, amount: amount, at: point)
            try? await Task.sleep(nanoseconds: 400_000_000)
            return nil

        case "wait":
            // The next step waits for its target anyway, so long waits from
            // the first run are cut short.
            let seconds = min(Double(arguments["seconds"] ?? "") ?? 1, 3)
            onProgress?(progressPrefix + "waiting")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil

        case "wait_for_video_end":
            onProgress?(progressPrefix + "watching the video to the end")
            _ = await DottieBrowser.waitForVideoToEnd(maximumSeconds: Double(arguments["max_seconds"] ?? "") ?? 600)
            return nil

        default:
            return "unknown step \(step.action)"
        }
    }

    private func flyAndClick(at point: CGPoint, clickCount: Int, isRightClick: Bool) async {
        let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(point) })?.frame ?? NSScreen.main?.frame ?? .zero
        await onWillClick?(point, displayFrame)
        if Task.isCancelled { return }
        DottieScreenActionPerformer.click(at: point, clickCount: clickCount, isRightClick: isRightClick)
    }

    // MARK: - Finding a target again

    /// Where the target should be: the same spot in its window now, else
    /// where it was.
    private func expectedPoint(for target: DottieReplay.Target) -> CGPoint {
        if let relativeX = target.relativeX, let relativeY = target.relativeY,
           let window = DottieAX.focusedWindow(), let windowFrame = DottieAX.axFrame(window) {
            return DottieAX.appKitPoint(fromAX: CGPoint(
                x: windowFrame.minX + CGFloat(relativeX) * windowFrame.width,
                y: windowFrame.minY + CGFloat(relativeY) * windowFrame.height
            ))
        }
        return CGPoint(x: target.pointX, y: target.pointY)
    }

    /// The point to click, checked against what's on screen now, or nil
    /// when the target doesn't show up in time.
    private func locate(_ target: DottieReplay.Target) async -> CGPoint? {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Self.targetWaitSeconds)
        var attempt = 0
        repeat {
            if Task.isCancelled { return nil }
            attempt += 1
            if target.hasAccessibilityName, let point = accessibilityPoint(for: target) {
                return point
            }
            // Accessibility usually answers at once; reading the screen is
            // slower, so it starts once the page had a moment to load.
            if attempt >= 2 || !target.hasAccessibilityName {
                if let point = await textPoint(for: target) { return point }
                if let point = await picturePoint(for: target) { return point }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        return nil
    }

    private func accessibilityPoint(for target: DottieReplay.Target) -> CGPoint? {
        guard AXIsProcessTrusted(), let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        AXUIElementSetAttributeValue(applicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var roots = DottieAX.children(applicationElement)
        if let focusedWindow = DottieAX.element(applicationElement, kAXFocusedWindowAttribute) {
            roots.removeAll { CFEqual($0, focusedWindow) }
            roots.insert(focusedWindow, at: 0)
        }
        let expectedAXPoint = DottieAX.axPoint(fromAppKit: expectedPoint(for: target))
        let wantedTitle = target.title.map { ScreenTextFinder.normalized($0) }
        let wantedDescription = target.descriptionText.map { ScreenTextFinder.normalized($0) }
        let searchDeadline = Date().addingTimeInterval(0.35)
        var visitedCount = 0
        var best: (frame: CGRect, score: Double)?

        var elementsToVisit = Array(roots.reversed())
        while let element = elementsToVisit.popLast() {
            visitedCount += 1
            if visitedCount > 4000 || Date() > searchDeadline { break }
            elementsToVisit.append(contentsOf: DottieAX.children(element).reversed())

            let role = DottieAX.string(element, kAXRoleAttribute)
            if let wantedRole = target.role, role != wantedRole { continue }
            var score = 0.0
            if let identifier = target.identifier, DottieAX.string(element, kAXIdentifierAttribute) == identifier { score += 3 }
            if let wantedTitle, !wantedTitle.isEmpty {
                var rawTitle = DottieAX.string(element, kAXTitleAttribute)
                if rawTitle == nil, let role, ["AXStaticText", "AXButton", "AXLink"].contains(role) {
                    rawTitle = DottieAX.string(element, kAXValueAttribute)
                }
                let title = rawTitle.map { ScreenTextFinder.normalized($0) }
                if title == wantedTitle { score += 2 } else if score < 3 { continue }
            }
            if let wantedDescription, !wantedDescription.isEmpty {
                let rawDescription = DottieAX.string(element, kAXDescriptionAttribute) ?? DottieAX.string(element, "AXLabel")
                let description = rawDescription.map { ScreenTextFinder.normalized($0) }
                if description == wantedDescription { score += 1.5 } else if score < 2 { continue }
            }
            guard score >= 1.5, let frame = DottieAX.axFrame(element),
                  frame.width >= 2, frame.height >= 2, frame.width <= 1400, frame.height <= 700 else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard NSScreen.screens.contains(where: { $0.frame.contains(DottieAX.appKitPoint(fromAX: center)) }) else { continue }
            if target.subrole != nil, DottieAX.string(element, kAXSubroleAttribute) == target.subrole { score += 0.2 }
            score -= Double(hypot(center.x - expectedAXPoint.x, center.y - expectedAXPoint.y)) / 1000
            if best == nil || score > best!.score {
                best = (frame, score)
            }
        }
        guard let best else { return nil }
        return DottieAX.appKitPoint(fromAX: CGPoint(x: best.frame.midX, y: best.frame.midY))
    }

    private func textPoint(for target: DottieReplay.Target) async -> CGPoint? {
        let usesNearbyText = target.nearbyText != nil
        guard let text = target.nearbyText ?? target.title ?? target.descriptionText,
              !PointingRefiner.significantWords(in: text).isEmpty else { return nil }
        let guess = expectedPoint(for: target)
        guard let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(guess) })?.frame ?? NSScreen.main?.frame,
              let textFrame = await ScreenTextFinder.frameOfText(matching: text, near: guess, displayFrame: displayFrame) else { return nil }
        // Far from where it was: probably the same words somewhere else.
        guard hypot(textFrame.midX - guess.x, textFrame.midY - guess.y) < 500 else { return nil }
        let offsetX = usesNearbyText ? CGFloat(target.textOffsetX ?? 0) : 0
        let offsetY = usesNearbyText ? CGFloat(target.textOffsetY ?? 0) : 0
        return CGPoint(x: textFrame.midX + offsetX, y: textFrame.midY + offsetY)
    }

    /// The saved picture of the spot still matches what's there now. Only
    /// for spots with something on them (a plain background matches
    /// anything).
    private func picturePoint(for target: DottieReplay.Target) async -> CGPoint? {
        guard let savedPatch = target.patch, Self.hasDetail(savedPatch) else { return nil }
        let guess = expectedPoint(for: target)
        guard let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(guess) })?.frame,
              let image = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: 1440),
              let currentPatch = DottieReplayPictures.patch(around: guess, in: image, displayFrame: displayFrame),
              DottieReplayPictures.patchesMatch(savedPatch, currentPatch) else { return nil }
        return guess
    }

    private static func hasDetail(_ patch: [UInt8]) -> Bool {
        let mean = patch.reduce(0.0) { $0 + Double($1) } / Double(max(patch.count, 1))
        let variance = patch.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(max(patch.count, 1))
        return variance.squareRoot() > 14
    }
}
