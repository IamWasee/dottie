//
//  DottieGameMovement.swift
//  leanring-buddy
//
//  How the character moves in one game, learned while Dottie plays, so a
//  route on the 3D map turns into exact controls ("turn 35°, hold W for
//  2.3 s") she can run without looking:
//
//  - Camera turning: degrees per mouse point, measured on small turns by
//    lining up the frames before and after the turn.
//  - Field of view: how wide the camera sees, for turning screen positions
//    into directions.
//  - Walking: map units covered per second of holding W, and how much
//    faster sprinting is. Corrected every time Dottie recognizes a place
//    she has mapped: the gap between where she thought she was and where
//    she really is shows how fast she actually walked.
//
//  Saved per game in Application Support/Dottie/Games/<game>/movement.json.
//

import CoreGraphics
import Foundation

@MainActor
final class DottieGameMovement {
    struct Contents: Codable {
        var degreesPerMousePoint = 0.25
        var horizontalFieldOfViewDegrees = 70.0
        /// Map units per second of walking. The map's units come from the
        /// depth scale, so this starts at 1 and is learned.
        var walkUnitsPerSecond = 1.0
        var sprintSpeedFactor = 1.6
        /// How many times the walk speed was corrected; more means trusted.
        var walkSpeedCorrectionCount = 0
        var cameraTurnMeasurementCount = 0
    }

    private(set) var contents: Contents
    private let saveURL: URL

    init(gameFolderURL: URL) {
        saveURL = gameFolderURL.appendingPathComponent("movement.json")
        if let savedData = try? Data(contentsOf: saveURL),
           let savedContents = try? JSONDecoder().decode(Contents.self, from: savedData) {
            contents = savedContents
        } else {
            contents = Contents()
        }
    }

    var degreesPerMousePoint: Double { contents.degreesPerMousePoint }
    var horizontalFieldOfViewDegrees: Double { contents.horizontalFieldOfViewDegrees }

    func mousePoints(forDegrees degrees: Double) -> CGFloat {
        CGFloat(degrees / max(contents.degreesPerMousePoint, 0.01))
    }

    func walkUnitsPerSecond(isSprinting: Bool) -> Double {
        contents.walkUnitsPerSecond * (isSprinting ? contents.sprintSpeedFactor : 1)
    }

    /// Seconds of holding W (and shift when sprinting) to cover a distance.
    func secondsToWalk(distance: Double, isSprinting: Bool) -> Double {
        distance / max(walkUnitsPerSecond(isSprinting: isSprinting), 0.05)
    }

    // MARK: - Learning

    /// Lines up the frames before and after a small camera turn to measure
    /// how many degrees one mouse point turns this game's camera.
    func learnCameraTurn(before beforeFrame: CGImage, after afterFrame: CGImage, turnedMousePoints: CGFloat) {
        guard abs(turnedMousePoints) > 20,
              let shiftFraction = Self.horizontalShiftFraction(from: beforeFrame, to: afterFrame) else { return }
        // Turning right slides the scene left.
        let measuredDegrees = -shiftFraction * contents.horizontalFieldOfViewDegrees
        let measuredDegreesPerPoint = measuredDegrees / Double(turnedMousePoints)
        guard measuredDegreesPerPoint > 0.01, measuredDegreesPerPoint < 3 else { return }
        contents.degreesPerMousePoint = contents.degreesPerMousePoint * 0.4 + measuredDegreesPerPoint * 0.6
        contents.cameraTurnMeasurementCount += 1
        save()
    }

    /// Dottie walked for `walkedSeconds` expecting to cover
    /// `expectedDistance`, then recognized a mapped place showing she really
    /// covered `actualDistance`. Nudges the walk speed toward the truth.
    func learnWalkSpeed(expectedDistance: Double, actualDistance: Double, walkedSeconds: Double) {
        guard walkedSeconds > 1, expectedDistance > 0.5, actualDistance > 0.2 else { return }
        // Dead reckoning moved her at the current speed, so the true speed
        // is the current one scaled by how far she really went. This also
        // holds when part of the walk was sprinting.
        let measuredUnitsPerSecond = contents.walkUnitsPerSecond * actualDistance / expectedDistance
        guard measuredUnitsPerSecond.isFinite, measuredUnitsPerSecond > 0.05, measuredUnitsPerSecond < 50 else { return }
        // Early corrections move a lot; later ones only fine-tune.
        let learningRate = contents.walkSpeedCorrectionCount < 5 ? 0.5 : 0.2
        contents.walkUnitsPerSecond = contents.walkUnitsPerSecond * (1 - learningRate) + measuredUnitsPerSecond * learningRate
        contents.walkSpeedCorrectionCount += 1
        save()
    }

    // MARK: - Frame alignment

    /// How far (as a share of the width, + is right) the scene moved
    /// sideways between two frames, or nil when they don't line up clearly.
    nonisolated static func horizontalShiftFraction(from beforeFrame: CGImage, to afterFrame: CGImage) -> Double? {
        let width = 160
        let height = 40
        guard let beforePixels = grayscalePixels(beforeFrame, width: width, height: height),
              let afterPixels = grayscalePixels(afterFrame, width: width, height: height) else { return nil }
        // The middle band: the horizon, not the sky or the character's feet.
        let bandRows = 10..<30
        let maximumShift = 56
        var errorsByShift: [(shift: Int, error: Double)] = []
        for shift in -maximumShift...maximumShift {
            var totalDifference = 0.0
            var comparedCount = 0
            for row in bandRows {
                for column in max(0, -shift)..<min(width, width - shift) {
                    let beforeValue = Double(beforePixels[row * width + column])
                    let afterValue = Double(afterPixels[row * width + column + shift])
                    totalDifference += abs(beforeValue - afterValue)
                    comparedCount += 1
                }
            }
            guard comparedCount > width * bandRows.count / 3 else { continue }
            errorsByShift.append((shift, totalDifference / Double(comparedCount)))
        }
        guard let bestShift = errorsByShift.min(by: { $0.error < $1.error }) else { return nil }
        let averageError = errorsByShift.map(\.error).reduce(0, +) / Double(errorsByShift.count)
        // A clear match stands out; a blurry or changing scene doesn't.
        guard averageError > 0, bestShift.error < averageError * 0.7 else { return nil }
        return Double(bestShift.shift) / Double(width)
    }

    nonisolated private static func grayscalePixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let context = CGContext(
                data: pixelBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? pixels : nil
    }

    private func save() {
        guard let contentsData = try? JSONEncoder().encode(contents) else { return }
        try? contentsData.write(to: saveURL, options: .atomic)
    }
}
