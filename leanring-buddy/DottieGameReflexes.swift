//
//  DottieGameReflexes.swift
//  leanring-buddy
//
//  The fast half of the game player: it carries out the brain's steps
//  frame by frame, the way hands play while the head thinks.
//
//  - Steering: `go_to` tracks the target on the Mac (Vision object
//    tracking) about eight times a second and keeps it centered while
//    walking, instead of turning once and walking a counted number of
//    seconds.
//  - Natural input: curved, eased camera turns; walking and turning at
//    once; hold times that vary; a human pause of about a quarter second
//    before reacting.
//  - Noticing: a big change on screen (new area, menu, cutscene), the
//    screen going dark, a loud sound, losing sight of the target, or the
//    picture not changing while walking (stuck) ends the step early so the
//    brain can look. Stuck first tries a jump and a step back on its own.
//  - The user's quick calls ("stop", "jump", "run", "go left") act at once.
//  - The 3D map (DottieGameWorldMap): every key held and camera turn moves
//    Dottie's position on it, frames are handed to it to map new places,
//    and `go_to_place` walks a planned route there blind, with a free
//    glance about twice a second instead of a model call.
//
//  A local model (a quick game-playing network on the Mac) can take over
//  the moment-to-moment moves through DottieGameReflexModel; until one is
//  set, the steering above does it.
//

import AppKit
import Foundation
import Vision

/// One moment of play from a local model.
struct DottieGameMove {
    var heldKeys: Set<String>
    var cameraTurnMousePoints: CGFloat
    var tappedKeys: [String]
    /// The model thinks the step's goal is reached.
    var isStepFinished: Bool
}

/// A quick local model that plays between the brain's decisions. Return
/// nil to let Dottie's own steering handle this moment.
@MainActor
protocol DottieGameReflexModel: AnyObject {
    func nextMove(frame: CGImage, goal: String, step: DottieGamePlan.Step) async -> DottieGameMove?
    /// While Dottie walks a route from the 3D map without looking
    /// (`go_to_place`): the leg being walked and how far into it she is by
    /// the map. Return nil to keep following the planned keys and jumps.
    func nextBlindMove(frame: CGImage, placeName: String, leg: DottieGameNavigator.Leg, distanceWalkedInLeg: Double) async -> DottieGameMove?
}

extension DottieGameReflexModel {
    /// A model that only plays the brain's steps leaves blind walks to the map.
    func nextBlindMove(frame: CGImage, placeName: String, leg: DottieGameNavigator.Leg, distanceWalkedInLeg: Double) async -> DottieGameMove? {
        nil
    }
}

@MainActor
final class DottieGameReflexes {
    /// How a step ended.
    struct StepResult {
        /// True when the step ended early because something needs the
        /// brain's eyes.
        var isEvent: Bool
        var note: String
        /// Extra views to show the brain (look_around).
        var extraFrameJPEGs: [Data] = []
    }

    var reflexModel: DottieGameReflexModel?
    /// A short line for the notch while a step runs.
    var onProgressLine: (@MainActor (String) -> Void)?
    /// The user's quick calls, read every frame.
    var takeUserCommand: (@MainActor () -> String?)?
    /// Loudness 0…1 of the game's sound right now.
    var currentLoudness: (@MainActor () -> Double)?

    let displayFrame: CGRect
    /// The mouse button held to turn the camera ("right" for Roblox and
    /// many third-person games, "none" when the mouse turns it freely).
    /// Learning the controls finds out which one works.
    private var cameraButton: String
    private let worldMap: DottieGameWorldMap
    private var heldKeys: Set<String> = []
    /// Recent frames, newest last, for the brain's motion pictures.
    private(set) var recentFrames: [(capturedAt: Date, image: CGImage)] = []
    private var previousThumbnail: [UInt8]?
    private var previousBrightness: Double?

    static let frameDimension = 768
    private static let framesPerSecond = 8.0

    init(displayFrame: CGRect, cameraButton: String, worldMap: DottieGameWorldMap) {
        self.displayFrame = displayFrame
        self.cameraButton = cameraButton
        self.worldMap = worldMap
    }

    /// Hands a frame to the 3D map without waiting for it: the map skips
    /// frames while it's busy and only maps spots it doesn't cover yet.
    func letMapSee(_ frame: CGImage) {
        let gameWorldMap = worldMap
        Task { @MainActor in
            await gameWorldMap.considerFrame(frame)
        }
    }

    // MARK: - Frames

    /// Captures the game now and notes it in the recent frames.
    func captureFrame() async -> CGImage? {
        guard let image = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: Self.frameDimension) else {
            return nil
        }
        recentFrames.append((Date(), image))
        let oldestKeptDate = Date().addingTimeInterval(-1.5)
        recentFrames.removeAll { $0.capturedAt < oldestKeptDate }
        return image
    }

    /// Three frames about a third of a second apart, ending now, for the
    /// brain. Uses frames already captured while playing when they're fresh.
    func motionFrames() async -> [CGImage] {
        if let newestFrame = recentFrames.last, Date().timeIntervalSince(newestFrame.capturedAt) < 0.3, recentFrames.count >= 3 {
            let newestDate = newestFrame.capturedAt
            var pickedFrames: [CGImage] = []
            for secondsBack in [0.66, 0.33] {
                let wantedDate = newestDate.addingTimeInterval(-secondsBack)
                if let closestFrame = recentFrames.min(by: { abs($0.capturedAt.timeIntervalSince(wantedDate)) < abs($1.capturedAt.timeIntervalSince(wantedDate)) }) {
                    pickedFrames.append(closestFrame.image)
                }
            }
            return pickedFrames + [newestFrame.image]
        }
        var capturedFrames: [CGImage] = []
        for frameIndex in 0..<3 {
            if frameIndex > 0 {
                try? await Task.sleep(nanoseconds: 330_000_000)
            }
            if let frame = await captureFrame() {
                capturedFrames.append(frame)
            }
        }
        return capturedFrames
    }

    // MARK: - Keys

    private func pressKeyDown(_ keyName: String) {
        guard !heldKeys.contains(keyName) else { return }
        if DottieScreenActionPerformer.setKey(keyName, isDown: true) {
            heldKeys.insert(keyName)
        }
    }

    private func releaseKey(_ keyName: String) {
        guard heldKeys.contains(keyName) else { return }
        _ = DottieScreenActionPerformer.setKey(keyName, isDown: false)
        heldKeys.remove(keyName)
    }

    /// Holds exactly these keys, letting go of the rest.
    private func holdOnly(_ wantedKeys: Set<String>) {
        for keyName in heldKeys.subtracting(wantedKeys) {
            releaseKey(keyName)
        }
        for keyName in wantedKeys.subtracting(heldKeys) {
            pressKeyDown(keyName)
        }
    }

    func releaseAllKeys() {
        for keyName in heldKeys {
            _ = DottieScreenActionPerformer.setKey(keyName, isDown: false)
        }
        heldKeys = []
    }

    /// About a quarter second, like a person reacting.
    private func humanPause() async {
        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.2...0.3) * 1_000_000_000))
    }

    private func turnCamera(degrees: Double) async {
        let mousePoints = worldMap.movement.mousePoints(forDegrees: degrees)
        let turnSeconds = 0.18 + min(abs(degrees), 180) / 180 * 0.35
        await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: mousePoints, deltaY: 0, button: cameraButton, seconds: turnSeconds)
        worldMap.noteCameraTurn(degrees: degrees)
    }

    // MARK: - Steps

    func perform(_ step: DottieGamePlan.Step, goal: String) async -> StepResult {
        await humanPause()
        defer { releaseAllKeys() }
        switch step.kind {
        case "go_to":
            guard let targetBox = step.targetBox else {
                return StepResult(isEvent: true, note: "go_to needs target_box.")
            }
            if step.view == "top_down" {
                worldMap.isTopDownView = true
                return await goToTopDown(targetBox: targetBox, playerBox: step.playerBox, step: step, goal: goal)
            }
            let goToResult = await goToBehind(targetBox: targetBox, sprint: step.sprint, step: step, goal: goal)
            // A named target becomes a place on the map once reached.
            if !goToResult.isEvent, let targetName = step.text, !targetName.isEmpty {
                worldMap.notePlace(name: targetName)
            }
            return goToResult
        case "go_to_place":
            guard let placeName = step.text, !placeName.isEmpty else {
                return StepResult(isEvent: true, note: "go_to_place needs the place's name.")
            }
            return await goToPlace(named: placeName, sprint: step.sprint)
        case "hold":
            return await hold(keys: step.keys ?? "w", seconds: step.seconds ?? 0.6)
        case "press":
            let keyCombination = step.keys ?? "e"
            let didPress = DottieScreenActionPerformer.press(keyCombination: keyCombination)
            try? await Task.sleep(nanoseconds: 350_000_000)
            return StepResult(isEvent: false, note: didPress ? "Pressed \(keyCombination)." : "Couldn't press \(keyCombination): unknown key.")
        case "click":
            guard let targetBox = step.targetBox else {
                return StepResult(isEvent: true, note: "click needs target_box.")
            }
            let clickPoint = CGPoint(
                x: displayFrame.minX + (targetBox[1] + targetBox[3]) / 2000 * displayFrame.width,
                y: displayFrame.maxY - (targetBox[0] + targetBox[2]) / 2000 * displayFrame.height
            )
            DottieScreenActionPerformer.click(at: clickPoint, clickCount: 1, isRightClick: false)
            try? await Task.sleep(nanoseconds: 400_000_000)
            return StepResult(isEvent: false, note: "Clicked.")
        case "turn":
            let turnDegrees = step.degrees ?? 90
            // A small turn also measures how far one mouse point turns this
            // game's camera, so later turns land where they should.
            var beforeTurnFrame: CGImage?
            if abs(turnDegrees) <= 20 {
                beforeTurnFrame = await captureFrame()
            }
            await turnCamera(degrees: turnDegrees)
            if let beforeTurnFrame {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let afterTurnFrame = await captureFrame() {
                    let turnedMousePoints = worldMap.movement.mousePoints(forDegrees: turnDegrees)
                    worldMap.movement.learnCameraTurn(before: beforeTurnFrame, after: afterTurnFrame, turnedMousePoints: turnedMousePoints)
                }
            }
            return StepResult(isEvent: false, note: "Turned \(Int(turnDegrees))°.")
        case "look_around":
            return await lookAround()
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64(min(max(step.seconds ?? 1, 0.2), 10) * 1_000_000_000))
            return StepResult(isEvent: false, note: "Waited.")
        case "open_map":
            let mapKey = step.keys ?? "m"
            _ = DottieScreenActionPerformer.press(keyCombination: mapKey)
            try? await Task.sleep(nanoseconds: 700_000_000)
            return StepResult(isEvent: true, note: "Opened the map with \(mapKey): read it, then close it (same key or escape).")
        case "search_wiki":
            let searchQuery = step.text ?? goal
            let searchResult = await DottieWebSearch.search(searchQuery)
            return StepResult(isEvent: true, note: "Wiki search for \"\(searchQuery)\":\n\(searchResult.prefix(1500))")
        case "learn_controls":
            return await learnControlsByTrying()
        case "type":
            await DottieScreenActionPerformer.type(step.text ?? "")
            return StepResult(isEvent: false, note: "Typed.")
        default:
            return StepResult(isEvent: true, note: "Unknown step \"\(step.kind)\".")
        }
    }

    private func hold(keys keyCombination: String, seconds: Double) async -> StepResult {
        let keyNames = Set(keyCombination.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init))
        holdOnly(keyNames)
        // People never hold for exactly the same time twice.
        let heldSeconds = min(max(seconds, 0.05), 5) * Double.random(in: 0.88...1.12)
        try? await Task.sleep(nanoseconds: UInt64(heldSeconds * 1_000_000_000))
        worldMap.noteMovement(heldKeys: heldKeys, seconds: heldSeconds)
        releaseAllKeys()
        return StepResult(isEvent: false, note: "Held \(keyCombination) for \(String(format: "%.1f", heldSeconds))s.")
    }

    // MARK: - Steering

    /// Vision tracking wants a normalized box with its origin at the
    /// bottom left; the brain's boxes are 0-1000 [ymin, xmin, ymax, xmax]
    /// from the top left.
    private static func visionRect(fromBox box: [Double]) -> CGRect {
        CGRect(x: box[1] / 1000, y: 1 - box[2] / 1000, width: max(0.01, (box[3] - box[1]) / 1000), height: max(0.01, (box[2] - box[0]) / 1000))
    }

    /// Walks toward the target in a behind-the-player view, keeping it
    /// centered with small camera turns while walking.
    private func goToBehind(targetBox: [Double], sprint: Bool, step: DottieGamePlan.Step, goal: String) async -> StepResult {
        let trackingRequest = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: Self.visionRect(fromBox: targetBox)))
        trackingRequest.trackingLevel = .fast
        let sequenceHandler = VNSequenceRequestHandler()
        let startedAt = Date()
        var stillSince: Date?
        var hasTriedUnsticking = false
        var walkingKeys: Set<String> = sprint ? ["w", "shift"] : ["w"]
        var lastMovementNotedAt = Date()

        while !Task.isCancelled {
            guard Date().timeIntervalSince(startedAt) < 14 else {
                return StepResult(isEvent: true, note: "Didn't reach the target in 14 seconds.")
            }
            // Whatever was held since the last frame moved her on the map.
            worldMap.noteMovement(heldKeys: heldKeys, seconds: Date().timeIntervalSince(lastMovementNotedAt))
            lastMovementNotedAt = Date()
            guard let frame = await captureFrame() else {
                return StepResult(isEvent: true, note: "Couldn't see the screen.")
            }
            if let eventNote = noticeEvent(in: frame, isTurning: false) {
                return StepResult(isEvent: true, note: eventNote)
            }
            letMapSee(frame)
            if let commandResult = await handleUserCommand(walkingKeys: &walkingKeys) {
                return commandResult
            }
            if let reflexModel, let move = await reflexModel.nextMove(frame: frame, goal: goal, step: step) {
                holdOnly(move.heldKeys)
                for tappedKey in move.tappedKeys {
                    _ = DottieScreenActionPerformer.press(keyCombination: tappedKey)
                }
                if move.cameraTurnMousePoints != 0 {
                    await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: move.cameraTurnMousePoints, deltaY: 0, button: cameraButton, seconds: 0.1)
                    worldMap.noteCameraTurn(degrees: Double(move.cameraTurnMousePoints) * worldMap.movement.degreesPerMousePoint)
                }
                if move.isStepFinished {
                    return StepResult(isEvent: false, note: "Reached the target.")
                }
                continue
            }

            try? sequenceHandler.perform([trackingRequest], on: frame)
            guard let trackedObservation = trackingRequest.results?.first as? VNDetectedObjectObservation,
                  trackedObservation.confidence > 0.3 else {
                return StepResult(isEvent: true, note: "Lost sight of the target while walking.")
            }
            trackingRequest.inputObservation = trackedObservation
            let trackedBox = trackedObservation.boundingBox
            if trackedBox.height > 0.22 || trackedBox.width > 0.35 {
                return StepResult(isEvent: false, note: "Reached the target.")
            }

            // Steer: turn part of the way toward the target each frame, so
            // the path curves smoothly instead of zig-zagging.
            let horizontalOffset = Double(trackedBox.midX) - 0.5
            holdOnly(walkingKeys)
            if abs(horizontalOffset) > 0.04 {
                let turnDegrees = horizontalOffset * worldMap.movement.horizontalFieldOfViewDegrees * 0.6
                let mousePoints = worldMap.movement.mousePoints(forDegrees: turnDegrees)
                await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: mousePoints, deltaY: 0, button: cameraButton, seconds: 0.1)
                worldMap.noteCameraTurn(degrees: turnDegrees)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(1 / Self.framesPerSecond * 1_000_000_000))
            }

            // Stuck: walking, but the picture isn't changing.
            if lastChangedShare < 0.01 {
                stillSince = stillSince ?? Date()
            } else {
                stillSince = nil
            }
            if let stillSince, Date().timeIntervalSince(stillSince) > 2 {
                guard !hasTriedUnsticking else {
                    return StepResult(isEvent: true, note: "Stuck: walking but nothing moves, even after jumping and backing up.")
                }
                hasTriedUnsticking = true
                await tryToUnstick()
                trackingRequest.inputObservation = VNDetectedObjectObservation(boundingBox: trackedBox)
            }
        }
        return StepResult(isEvent: true, note: "Stopped.")
    }

    /// Walks toward the target in a top-down view, steering with the
    /// movement keys toward it every frame.
    private func goToTopDown(targetBox: [Double], playerBox: [Double]?, step: DottieGamePlan.Step, goal: String) async -> StepResult {
        let targetTracking = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: Self.visionRect(fromBox: targetBox)))
        let playerTracking = playerBox.map {
            VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: Self.visionRect(fromBox: $0)))
        }
        targetTracking.trackingLevel = .fast
        playerTracking?.trackingLevel = .fast
        let sequenceHandler = VNSequenceRequestHandler()
        let startedAt = Date()
        var walkingKeys: Set<String> = []

        while !Task.isCancelled {
            guard Date().timeIntervalSince(startedAt) < 14 else {
                return StepResult(isEvent: true, note: "Didn't reach the target in 14 seconds.")
            }
            guard let frame = await captureFrame() else {
                return StepResult(isEvent: true, note: "Couldn't see the screen.")
            }
            if let eventNote = noticeEvent(in: frame, isTurning: false) {
                return StepResult(isEvent: true, note: eventNote)
            }
            if let commandResult = await handleUserCommand(walkingKeys: &walkingKeys) {
                return commandResult
            }
            var requests: [VNRequest] = [targetTracking]
            if let playerTracking {
                requests.append(playerTracking)
            }
            try? sequenceHandler.perform(requests, on: frame)
            guard let targetObservation = targetTracking.results?.first as? VNDetectedObjectObservation,
                  targetObservation.confidence > 0.3 else {
                return StepResult(isEvent: true, note: "Lost sight of the target.")
            }
            targetTracking.inputObservation = targetObservation
            var playerCenter = CGPoint(x: 0.5, y: 0.5)
            if let playerTracking,
               let playerObservation = playerTracking.results?.first as? VNDetectedObjectObservation,
               playerObservation.confidence > 0.3 {
                playerTracking.inputObservation = playerObservation
                playerCenter = CGPoint(x: playerObservation.boundingBox.midX, y: playerObservation.boundingBox.midY)
            }
            let horizontalDistance = targetObservation.boundingBox.midX - playerCenter.x
            // Vision's y grows upward, like the screen's "up" key.
            let verticalDistance = targetObservation.boundingBox.midY - playerCenter.y
            if abs(horizontalDistance) < 0.04 && abs(verticalDistance) < 0.05 {
                return StepResult(isEvent: false, note: "Reached the target.")
            }
            walkingKeys = []
            if horizontalDistance > 0.03 { walkingKeys.insert("d") }
            if horizontalDistance < -0.03 { walkingKeys.insert("a") }
            if verticalDistance > 0.03 { walkingKeys.insert("w") }
            if verticalDistance < -0.03 { walkingKeys.insert("s") }
            if step.sprint { walkingKeys.insert("shift") }
            holdOnly(walkingKeys)
            try? await Task.sleep(nanoseconds: UInt64(1 / Self.framesPerSecond * 1_000_000_000))
        }
        return StepResult(isEvent: true, note: "Stopped.")
    }

    // MARK: - Walking by the map

    private enum LegWalkEnding {
        case arrived
        /// Stuck against something the map didn't show, even after trying
        /// to get unstuck.
        case blocked
        case stopped(StepResult)
    }

    /// How many times a blind walk finds another way around something in
    /// the way before handing back to the brain.
    private static let maximumReplansPerWalk = 2

    /// Walks a route planned on the 3D map to a named place, without
    /// asking a model on the way: turn, hold W for the planned time, jump
    /// where the route crosses something low, and glance about twice a
    /// second (free, on the Mac) for anything that should stop the walk.
    /// Something in the way the map didn't show is put on the map as a
    /// blocker and the route is planned again around it.
    private func goToPlace(named placeName: String, sprint: Bool) async -> StepResult {
        guard let place = worldMap.place(named: placeName) else {
            return StepResult(isEvent: true, note: "\(placeName) isn't on the map yet. Find it by looking, go_to it, and name it in `place` once you're there.")
        }
        guard worldMap.isLocalized else {
            return StepResult(isEvent: true, note: "Dottie doesn't know where you are on the map yet, so she can't walk to \(place.name) blind. Look around a spot you know first.")
        }
        onProgressLine?("Walking to \(place.name) by the map")
        let walkStartedAt = Date()
        var replanCount = 0
        var walkedLegCount = 0
        while true {
            if worldMap.bearing(toX: place.x, y: place.y).distance < 1 {
                if walkedLegCount == 0 {
                    return StepResult(isEvent: false, note: "Already at \(place.name).")
                }
                break
            }
            guard let legs = DottieGameNavigator.legs(on: worldMap, toX: place.x, y: place.y, sprint: sprint), !legs.isEmpty else {
                if replanCount > 0 {
                    return StepResult(isEvent: true, note: "Something is in the way to \(place.name) and the map shows no other way round; look and find one (go_to).")
                }
                return StepResult(isEvent: true, note: "No way to \(place.name) on the map; walk there by looking (go_to).")
            }
            let walkEnding = await walk(legs, toPlaceNamed: place.name, walkStartedAt: walkStartedAt)
            walkedLegCount += legs.count
            switch walkEnding {
            case .arrived:
                break
            case .stopped(let stopResult):
                return stopResult
            case .blocked:
                // Whatever stopped her is about a step ahead.
                worldMap.noteBlocker(distanceAhead: 1)
                replanCount += 1
                guard replanCount <= Self.maximumReplansPerWalk else {
                    return StepResult(isEvent: true, note: "Stuck on the way to \(place.name) \(replanCount) times: something the map doesn't show keeps getting in the way.")
                }
                onProgressLine?("Something's in the way, finding another way to \(place.name)")
                continue
            }
            break
        }
        let distanceLeft = worldMap.bearing(toX: place.x, y: place.y).distance
        let replanNote = replanCount > 0 ? ", going around \(replanCount) thing(s) in the way," : ""
        return StepResult(isEvent: false, note: "Walked to \(place.name) by the map\(replanNote) without stopping to look; by the map it's about \(Int(distanceLeft.rounded())) units away now. Check it's there.")
    }

    /// Runs planned legs: turn, hold the walking keys for the leg's time,
    /// press jump at the leg's jump spots and learn from how each jump went.
    private func walk(_ legs: [DottieGameNavigator.Leg], toPlaceNamed placeName: String, walkStartedAt: Date) async -> LegWalkEnding {
        for leg in legs {
            guard !Task.isCancelled else { return .stopped(StepResult(isEvent: true, note: "Stopped.")) }
            guard Date().timeIntervalSince(walkStartedAt) < 90 else {
                return .stopped(StepResult(isEvent: true, note: "Walking to \(placeName) took far longer than planned; look where you are."))
            }
            if abs(leg.turnDegrees) > 3 {
                await turnCamera(degrees: leg.turnDegrees)
            }
            var walkingKeys: Set<String> = leg.isSprinting ? ["w", "shift"] : ["w"]
            holdOnly(walkingKeys)
            let legWalkUnitsPerSecond = worldMap.movement.walkUnitsPerSecond(isSprinting: leg.isSprinting)
            let legStartedAt = Date()
            var lastMovementNotedAt = legStartedAt
            var stillSince: Date?
            var hasTriedUnsticking = false
            var nextJumpIndex = 0
            /// The last jump pressed, until it's known whether it cleared.
            var jumpInTheAir: (jump: DottieGameNavigator.Jump, pressedAt: Date)?
            while Date().timeIntervalSince(legStartedAt) < leg.holdSeconds, !Task.isCancelled {
                let secondsIntoLeg = Date().timeIntervalSince(legStartedAt)
                var secondsToSleep = max(0.05, min(0.5, leg.holdSeconds - secondsIntoLeg))
                // Wake up in time for the next jump.
                if nextJumpIndex < leg.jumps.count {
                    let secondsUntilJump = leg.jumps[nextJumpIndex].takeOffDistance / legWalkUnitsPerSecond - secondsIntoLeg
                    secondsToSleep = max(0.02, min(secondsToSleep, secondsUntilJump))
                }
                try? await Task.sleep(nanoseconds: UInt64(secondsToSleep * 1_000_000_000))
                worldMap.noteMovement(heldKeys: heldKeys, seconds: Date().timeIntervalSince(lastMovementNotedAt))
                lastMovementNotedAt = Date()
                let distanceWalkedInLeg = Date().timeIntervalSince(legStartedAt) * legWalkUnitsPerSecond
                if nextJumpIndex < leg.jumps.count, distanceWalkedInLeg >= leg.jumps[nextJumpIndex].takeOffDistance {
                    _ = DottieScreenActionPerformer.press(keyCombination: "space")
                    jumpInTheAir = (leg.jumps[nextJumpIndex], Date())
                    nextJumpIndex += 1
                }
                guard let frame = await captureFrame() else {
                    return .stopped(StepResult(isEvent: true, note: "Couldn't see the screen."))
                }
                if let eventNote = noticeEvent(in: frame, isTurning: false) {
                    return .stopped(StepResult(isEvent: true, note: "On the way to \(placeName): \(eventNote)"))
                }
                if let commandResult = await handleUserCommand(walkingKeys: &walkingKeys) {
                    return .stopped(commandResult)
                }
                if let reflexModel, let move = await reflexModel.nextBlindMove(frame: frame, placeName: placeName, leg: leg, distanceWalkedInLeg: distanceWalkedInLeg) {
                    holdOnly(move.heldKeys)
                    for tappedKey in move.tappedKeys {
                        _ = DottieScreenActionPerformer.press(keyCombination: tappedKey)
                    }
                    if move.cameraTurnMousePoints != 0 {
                        await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: move.cameraTurnMousePoints, deltaY: 0, button: cameraButton, seconds: 0.1)
                        worldMap.noteCameraTurn(degrees: Double(move.cameraTurnMousePoints) * worldMap.movement.degreesPerMousePoint)
                    }
                    if move.isStepFinished {
                        break
                    }
                } else {
                    holdOnly(walkingKeys)
                }
                letMapSee(frame)
                if lastChangedShare < 0.01 {
                    stillSince = stillSince ?? Date()
                } else {
                    stillSince = nil
                }
                if let currentJump = jumpInTheAir {
                    if stillSince != nil {
                        // Stopped right at the low thing: the jump fell short.
                        worldMap.movement.learnJump(obstacleHeight: currentJump.jump.obstacleHeight, obstacleLength: currentJump.jump.obstacleLength, didClear: false)
                        jumpInTheAir = nil
                    } else if Date().timeIntervalSince(currentJump.pressedAt) > 1.5 {
                        // Still moving well after the jump: it cleared.
                        worldMap.movement.learnJump(obstacleHeight: currentJump.jump.obstacleHeight, obstacleLength: currentJump.jump.obstacleLength, didClear: true)
                        jumpInTheAir = nil
                    }
                }
                if let stillSince, Date().timeIntervalSince(stillSince) > 1.5 {
                    guard !hasTriedUnsticking else {
                        releaseAllKeys()
                        return .blocked
                    }
                    hasTriedUnsticking = true
                    await tryToUnstick()
                    holdOnly(walkingKeys)
                }
            }
            releaseAllKeys()
        }
        return .arrived
    }

    /// A jump forward, then a step back and a turn, before asking for help.
    private func tryToUnstick() async {
        releaseAllKeys()
        holdOnly(["w", "space"])
        try? await Task.sleep(nanoseconds: 450_000_000)
        worldMap.noteMovement(heldKeys: ["w"], seconds: 0.45)
        releaseAllKeys()
        holdOnly(["s"])
        try? await Task.sleep(nanoseconds: 500_000_000)
        worldMap.noteMovement(heldKeys: ["s"], seconds: 0.5)
        releaseAllKeys()
        await turnCamera(degrees: Bool.random() ? 35 : -35)
    }

    /// Four quarter turns, a picture of each view, ending where it began.
    private func lookAround() async -> StepResult {
        var viewJPEGs: [Data] = []
        for _ in 0..<4 {
            await turnCamera(degrees: 90)
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let viewFrame = await captureFrame(), let viewJPEG = DottieGameVision.jpegData(of: viewFrame, quality: 0.6) {
                viewJPEGs.append(viewJPEG)
            }
        }
        return StepResult(
            isEvent: true,
            note: "Looked around: the extra pictures are the views to the right, behind, to the left, and ahead again.",
            extraFrameJPEGs: Array(viewJPEGs.prefix(3))
        )
    }

    // MARK: - Learning the controls

    /// The controls almost every game starts with, tried first and in this
    /// order: (keys, seconds held, what they usually do).
    private static let defaultControlsToTry: [(keys: String, seconds: Double, usualAction: String)] = [
        ("w", 0.7, "walk forward"),
        ("s", 0.7, "walk back"),
        ("a", 0.7, "walk left"),
        ("d", 0.7, "walk right"),
        ("space", 0.15, "jump"),
        ("w+shift", 1.0, "sprint"),
        ("c", 0.4, "crouch")
    ]
    /// Other keys games often use, tried after the defaults.
    private static let otherKeysToTry = ["e", "f", "q", "r", "tab", "i", "m", "1"]

    /// Learns the controls like a person picking up a new game: the
    /// default controls first (WASD, space, shift to sprint, C), then
    /// turning the camera by holding the right mouse button (and without
    /// it), then the pause menu, then other common keys. Notes what each
    /// did for the brain to write down as controls.
    private func learnControlsByTrying() async -> StepResult {
        var findings: [String] = []
        guard let startFrame = await captureFrame() else {
            return StepResult(isEvent: true, note: "Couldn't see the screen.")
        }
        var previousTextLines = Set(await Self.readTextOffMain(startFrame))

        // 1. The default controls.
        onProgressLine?("Trying the default controls")
        for defaultControl in Self.defaultControlsToTry {
            guard !Task.isCancelled else { break }
            if let finding = await tryKeys(defaultControl.keys, seconds: defaultControl.seconds, previousTextLines: &previousTextLines) {
                findings.append("\(finding) (usually: \(defaultControl.usualAction))")
            }
        }

        // 2. Turning the camera: holding the right mouse button, then not.
        onProgressLine?("Trying the camera")
        var cameraFindings: [String] = []
        var cameraButtonsThatTurn: [String] = []
        for buttonToTry in ["right", "none"] {
            guard !Task.isCancelled else { break }
            guard let beforeFrame = await captureFrame() else { continue }
            let turnedMousePoints: CGFloat = 220
            await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: turnedMousePoints, deltaY: 0, button: buttonToTry, seconds: 0.5)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let afterFrame = await captureFrame() else { continue }
            let shiftFraction = DottieGameMovement.horizontalShiftFraction(from: beforeFrame, to: afterFrame)
            let didTurn = (shiftFraction.map { abs($0) > 0.03 } ?? false)
            let buttonDescription = buttonToTry == "right" ? "holding the right mouse button and moving the mouse" : "moving the mouse without a button"
            if didTurn {
                cameraButtonsThatTurn.append(buttonToTry)
                worldMap.movement.learnCameraTurn(before: beforeFrame, after: afterFrame, turnedMousePoints: turnedMousePoints)
                cameraFindings.append("\(buttonDescription): turns the camera")
                // Turn back, so the view is where it started.
                await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: -turnedMousePoints, deltaY: 0, button: buttonToTry, seconds: 0.5)
            } else {
                cameraFindings.append("\(buttonDescription): the camera didn't turn")
            }
        }
        if cameraButtonsThatTurn.contains("none") {
            cameraButton = "none"
        } else if cameraButtonsThatTurn.contains("right") {
            cameraButton = "right"
        }
        findings += cameraFindings

        // 3. The pause menu often lists the controls.
        _ = DottieScreenActionPerformer.press(keyCombination: "escape")
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let menuFrame = await captureFrame() {
            let menuText = await Self.readTextOffMain(menuFrame)
            if !menuText.isEmpty {
                findings.append("Escape menu shows: " + menuText.prefix(20).joined(separator: " | "))
            }
        }
        _ = DottieScreenActionPerformer.press(keyCombination: "escape")
        try? await Task.sleep(nanoseconds: 600_000_000)

        // 4. Other common keys.
        onProgressLine?("Trying other keys")
        for keyName in Self.otherKeysToTry {
            guard !Task.isCancelled else { break }
            if let finding = await tryKeys(keyName, seconds: 0.15, previousTextLines: &previousTextLines) {
                findings.append(finding)
            }
        }
        return StepResult(isEvent: true, note: "Tried the default controls, the camera, the menu and other common keys. What each did:\n" + findings.joined(separator: "\n") + "\nWrite what you can tell into `controls`.")
    }

    /// Holds keys for a moment and says what changed on screen.
    private func tryKeys(_ keyCombination: String, seconds: Double, previousTextLines: inout Set<String>) async -> String? {
        guard let beforeFrame = await captureFrame(), let beforeThumbnail = DottieGameVision.thumbnail(of: beforeFrame) else { return nil }
        _ = await hold(keys: keyCombination, seconds: seconds)
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let afterFrame = await captureFrame(), let afterThumbnail = DottieGameVision.thumbnail(of: afterFrame) else { return nil }
        let changedShare = DottieGameVision.changedShare(from: beforeThumbnail, to: afterThumbnail)
        let afterTextLines = await Self.readTextOffMain(afterFrame)
        let newTextLines = afterTextLines.filter { !previousTextLines.contains($0) }
        previousTextLines = Set(afterTextLines)
        var finding = "\(keyCombination): "
        if changedShare > 0.4 {
            finding += "big change (a menu or screen opened)"
            // Close whatever opened so the next key is tried in play.
            _ = DottieScreenActionPerformer.press(keyCombination: keyCombination)
            try? await Task.sleep(nanoseconds: 400_000_000)
        } else if changedShare > 0.05 {
            finding += "the view moved or changed"
        } else {
            finding += "nothing visible"
        }
        if !newTextLines.isEmpty {
            finding += ", new text: " + newTextLines.prefix(5).joined(separator: " | ")
        }
        return finding
    }

    static func readTextOffMain(_ image: CGImage) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            DottieGameVision.readText(in: image)
        }.value
    }

    // MARK: - Noticing

    private var lastChangedShare = 1.0

    /// Something the brain should look at, or nil.
    private func noticeEvent(in frame: CGImage, isTurning: Bool) -> String? {
        guard let thumbnail = DottieGameVision.thumbnail(of: frame) else { return nil }
        defer { previousThumbnail = thumbnail }
        let brightness = DottieGameVision.averageBrightness(of: thumbnail)
        defer { previousBrightness = brightness }
        guard let previousThumbnail else { return nil }
        lastChangedShare = DottieGameVision.changedShare(from: previousThumbnail, to: thumbnail)
        if let previousBrightness, previousBrightness > 40, brightness < 12 {
            return "The screen went dark (a death, a loading screen or a cutscene?)."
        }
        if !isTurning && lastChangedShare > 0.6 {
            return "The screen changed a lot at once (a new area, a menu or a cutscene?)."
        }
        if let currentLoudness, currentLoudness() > 0.7 {
            return "A loud sound in the game."
        }
        return nil
    }

    /// Acts on the user's quick calls at once. Returns a result when the
    /// step should end (stop, or something the brain should hear).
    private func handleUserCommand(walkingKeys: inout Set<String>) async -> StepResult? {
        guard let userCommand = takeUserCommand?() else { return nil }
        let lowercasedCommand = userCommand.lowercased()
        if lowercasedCommand.contains("stop") || lowercasedCommand.contains("wait") || lowercasedCommand.contains("hold on") {
            releaseAllKeys()
            return StepResult(isEvent: true, note: "The user said \"\(userCommand)\", so you stopped.")
        }
        if lowercasedCommand.contains("jump") {
            _ = DottieScreenActionPerformer.press(keyCombination: "space")
            return nil
        }
        if lowercasedCommand.contains("run") || lowercasedCommand.contains("sprint") || lowercasedCommand.contains("faster") {
            walkingKeys.insert("shift")
            return nil
        }
        if lowercasedCommand.contains("slow") || lowercasedCommand.contains("walk") {
            walkingKeys.remove("shift")
            return nil
        }
        if lowercasedCommand.contains("left") {
            await turnCamera(degrees: -60)
            return StepResult(isEvent: true, note: "The user said \"\(userCommand)\", so you turned left.")
        }
        if lowercasedCommand.contains("right") {
            await turnCamera(degrees: 60)
            return StepResult(isEvent: true, note: "The user said \"\(userCommand)\", so you turned right.")
        }
        if lowercasedCommand.contains("back") {
            releaseAllKeys()
            _ = await hold(keys: "s", seconds: 0.8)
            return StepResult(isEvent: true, note: "The user said \"\(userCommand)\", so you backed up.")
        }
        releaseAllKeys()
        return StepResult(isEvent: true, note: "The user said: \"\(userCommand)\".")
    }
}
