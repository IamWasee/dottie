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
    /// The user's quick calls, read every frame.
    var takeUserCommand: (@MainActor () -> String?)?
    /// Loudness 0…1 of the game's sound right now.
    var currentLoudness: (@MainActor () -> Double)?

    let displayFrame: CGRect
    private let cameraButton: String
    private let gameMap: DottieGameMap
    private var heldKeys: Set<String> = []
    /// Recent frames, newest last, for the brain's motion pictures.
    private(set) var recentFrames: [(capturedAt: Date, image: CGImage)] = []
    private var previousThumbnail: [UInt8]?
    private var previousBrightness: Double?

    static let frameDimension = 768
    private static let framesPerSecond = 8.0

    init(displayFrame: CGRect, cameraButton: String, gameMap: DottieGameMap) {
        self.displayFrame = displayFrame
        self.cameraButton = cameraButton
        self.gameMap = gameMap
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
        let mousePoints = CGFloat(degrees / max(gameMap.degreesPerMousePoint, 0.01))
        let turnSeconds = 0.18 + min(abs(degrees), 180) / 180 * 0.35
        await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: mousePoints, deltaY: 0, button: cameraButton, seconds: turnSeconds)
        gameMap.noteCameraTurn(mousePoints: mousePoints)
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
                return await goToTopDown(targetBox: targetBox, playerBox: step.playerBox, step: step, goal: goal)
            }
            return await goToBehind(targetBox: targetBox, sprint: step.sprint, step: step, goal: goal)
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
                    let turnedMousePoints = CGFloat(turnDegrees / max(gameMap.degreesPerMousePoint, 0.01))
                    gameMap.calibrate(before: beforeTurnFrame, after: afterTurnFrame, turnedMousePoints: turnedMousePoints)
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
            if let reflexModel, let move = await reflexModel.nextMove(frame: frame, goal: goal, step: step) {
                holdOnly(move.heldKeys)
                for tappedKey in move.tappedKeys {
                    _ = DottieScreenActionPerformer.press(keyCombination: tappedKey)
                }
                if move.cameraTurnMousePoints != 0 {
                    await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: move.cameraTurnMousePoints, deltaY: 0, button: cameraButton, seconds: 0.1)
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
                let turnDegrees = horizontalOffset * DottieGameMap.horizontalFieldOfViewDegrees * 0.6
                let mousePoints = CGFloat(turnDegrees / max(gameMap.degreesPerMousePoint, 0.01))
                await DottieScreenActionPerformer.turnCameraSmoothly(deltaX: mousePoints, deltaY: 0, button: cameraButton, seconds: 0.1)
                gameMap.noteCameraTurn(mousePoints: mousePoints)
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

    /// A jump forward, then a step back and a turn, before asking for help.
    private func tryToUnstick() async {
        releaseAllKeys()
        holdOnly(["w", "space"])
        try? await Task.sleep(nanoseconds: 450_000_000)
        releaseAllKeys()
        holdOnly(["s"])
        try? await Task.sleep(nanoseconds: 500_000_000)
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

    private static let commonKeysToTry = ["e", "f", "q", "r", "space", "shift", "tab", "i", "m", "j", "1"]

    /// Tries the menu and the usual keys one at a time and notes what each
    /// did, for the brain to write down as controls.
    private func learnControlsByTrying() async -> StepResult {
        var findings: [String] = []
        guard let startFrame = await captureFrame() else {
            return StepResult(isEvent: true, note: "Couldn't see the screen.")
        }
        var previousTextLines = Set(await Self.readTextOffMain(startFrame))

        // The pause menu often lists the controls.
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

        for keyName in Self.commonKeysToTry {
            guard !Task.isCancelled else { break }
            guard let beforeFrame = await captureFrame(), let beforeThumbnail = DottieGameVision.thumbnail(of: beforeFrame) else { continue }
            _ = await hold(keys: keyName, seconds: 0.15)
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let afterFrame = await captureFrame(), let afterThumbnail = DottieGameVision.thumbnail(of: afterFrame) else { continue }
            let changedShare = DottieGameVision.changedShare(from: beforeThumbnail, to: afterThumbnail)
            let afterTextLines = await Self.readTextOffMain(afterFrame)
            let newTextLines = afterTextLines.filter { !previousTextLines.contains($0) }
            previousTextLines = Set(afterTextLines)
            var finding = "\(keyName): "
            if changedShare > 0.4 {
                finding += "big change (a menu or screen opened)"
                // Close whatever opened so the next key is tried in play.
                _ = DottieScreenActionPerformer.press(keyCombination: keyName == "escape" ? "escape" : keyName)
                try? await Task.sleep(nanoseconds: 400_000_000)
            } else if changedShare > 0.05 {
                finding += "some change"
            } else {
                finding += "nothing visible"
            }
            if !newTextLines.isEmpty {
                finding += ", new text: " + newTextLines.prefix(5).joined(separator: " | ")
            }
            findings.append(finding)
        }
        return StepResult(isEvent: true, note: "Tried the menu and common keys. What each did:\n" + findings.joined(separator: "\n") + "\nWrite what you can tell into `controls`.")
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
