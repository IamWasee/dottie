//
//  DottieGameMap.swift
//  leanring-buddy
//
//  A map of the game world that a game job builds as it plays, so it can
//  stop turning and looking before every move. Dottie knows exactly how she
//  moved (which keys, for how long, how far the camera turned), so she keeps
//  track of where the character is and which way the camera faces. Whenever
//  Gemini spots something worth remembering (the shop, the golem machine, an
//  item), it notes it with where it is on screen and roughly how far; that
//  becomes a spot on the map. From then on every step comes with "golem
//  machine: 8s ahead-left, roll machines: 20s behind you", and
//  walk_to_landmark turns and walks there in one go, then a fresh look
//  corrects any drift.
//
//  Distances are in seconds of walking (no game tells us its units). Camera
//  turning is measured, not guessed: after a small turn, the before and
//  after screenshots are lined up to see how far the scene slid, which gives
//  degrees per mouse point for this game. That and the things seen are kept
//  per game, so the next job starts knowing them.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class DottieGameMap {
    struct Landmark {
        let name: String
        var description: String
        /// Map position in seconds of walking. Start position is 0, 0 and
        /// the camera's starting direction is +y.
        var x: Double
        var y: Double
        var lastSeenStep: Int
    }

    private struct SavedGame: Codable {
        var degreesPerMousePoint: Double
        var walkSpeedFactor: Double?
        /// Things seen in earlier jobs: name → description.
        var knownThings: [String: String]
    }

    /// Typical third-person camera.
    static let horizontalFieldOfViewDegrees = 70.0

    let gameName: String
    private(set) var landmarks: [Landmark] = []
    private(set) var positionX = 0.0
    private(set) var positionY = 0.0
    /// Camera direction in degrees, clockwise from the starting direction.
    private(set) var headingDegrees = 0.0
    private(set) var degreesPerMousePoint: Double
    private var knownThings: [String: String]
    private let saveURL: URL

    init(gameName: String) {
        self.gameName = gameName
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folderURL = applicationSupportURL.appendingPathComponent("Dottie/GameMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileName = gameName.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        saveURL = folderURL.appendingPathComponent((fileName.isEmpty ? "game" : String(fileName.prefix(60))) + ".json")
        let saved = (try? Data(contentsOf: saveURL)).flatMap { try? JSONDecoder().decode(SavedGame.self, from: $0) }
        // Roblox's right-drag turns roughly a quarter degree per point.
        degreesPerMousePoint = saved?.degreesPerMousePoint ?? 0.25
        knownThings = saved?.knownThings ?? [:]
    }

    // MARK: - Tracking moves

    /// The camera turned by dragging the mouse this many points sideways.
    func noteCameraTurn(mousePoints: CGFloat) {
        headingDegrees = Self.normalizedAngle(headingDegrees + Double(mousePoints) * degreesPerMousePoint)
    }

    /// Movement keys were held for this long (third-person: w goes where the
    /// camera faces).
    func noteMovement(keys: String, seconds: Double) {
        let keyNames = Set(keys.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) })
        let speed = keyNames.contains("shift") ? 1.6 : 1.0
        var forward = 0.0, sideways = 0.0
        if keyNames.contains("w") || keyNames.contains("up") { forward += 1 }
        if keyNames.contains("s") || keyNames.contains("down") { forward -= 1 }
        if keyNames.contains("d") || keyNames.contains("right") { sideways += 1 }
        if keyNames.contains("a") || keyNames.contains("left") { sideways -= 1 }
        guard forward != 0 || sideways != 0 else { return }
        let length = hypot(forward, sideways)
        let distance = seconds * speed
        let headingRadians = headingDegrees * .pi / 180
        // Forward is along the heading, sideways is 90° clockwise of it.
        positionX += (forward * sin(headingRadians) + sideways * cos(headingRadians)) / length * distance
        positionY += (forward * cos(headingRadians) - sideways * sin(headingRadians)) / length * distance
    }

    // MARK: - Landmarks

    /// Something seen at this horizontal spot on screen (0-1000), about this
    /// many seconds of walking away.
    func noteLandmark(name: String, description: String, screenX: Double, distanceSeconds: Double, step: Int, cameraHeadingDegrees: Double? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let offsetDegrees = (min(max(screenX, 0), 1000) - 500) / 500 * Self.horizontalFieldOfViewDegrees / 2
        let bearingRadians = ((cameraHeadingDegrees ?? headingDegrees) + offsetDegrees) * .pi / 180
        let distance = min(max(distanceSeconds, 0.3), 120)
        let landmarkX = positionX + sin(bearingRadians) * distance
        let landmarkY = positionY + cos(bearingRadians) * distance
        if let existingIndex = landmarks.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            // A fresh sighting is more accurate than an old, drifted one.
            landmarks[existingIndex].x = landmarkX
            landmarks[existingIndex].y = landmarkY
            landmarks[existingIndex].lastSeenStep = step
            if !description.isEmpty { landmarks[existingIndex].description = description }
        } else {
            landmarks.append(Landmark(name: trimmedName, description: description, x: landmarkX, y: landmarkY, lastSeenStep: step))
        }
        knownThings[trimmedName] = description.isEmpty ? (knownThings[trimmedName] ?? "") : description
        save()
    }

    /// How to get there: the camera turn (in mouse points, + is right) and
    /// how long to walk.
    func route(toLandmarkNamed name: String) -> (landmark: Landmark, turnDegrees: Double, turnMousePoints: CGFloat, walkSeconds: Double)? {
        let wantedName = name.lowercased()
        guard let landmark = landmarks.first(where: { $0.name.lowercased() == wantedName })
            ?? landmarks.first(where: { $0.name.lowercased().contains(wantedName) || wantedName.contains($0.name.lowercased()) }) else { return nil }
        let (turnDegrees, distance) = relativeBearing(to: landmark)
        let turnMousePoints = CGFloat(turnDegrees / max(degreesPerMousePoint, 0.01))
        return (landmark, turnDegrees, turnMousePoints, distance)
    }

    /// For the model, every step: where everything is from here.
    func summary(currentStep: Int) -> String {
        var lines: [String] = []
        if !landmarks.isEmpty {
            let landmarkLines = landmarks
                .map { landmark -> (String, Double) in
                    let (turnDegrees, distance) = relativeBearing(to: landmark)
                    let staleness = currentStep - landmark.lastSeenStep > 12 ? ", seen a while ago" : ""
                    return ("- \(landmark.name): \(Self.distanceText(distance)) \(Self.directionText(turnDegrees))\(staleness)", distance)
                }
                .sorted { $0.1 < $1.1 }
                .prefix(12)
                .map(\.0)
            lines.append("Your map of this game (from where the character is now, facing where the camera looks):")
            lines.append(contentsOf: landmarkLines)
        }
        let unseenKnownThings = knownThings.filter { name, _ in !landmarks.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        if !unseenKnownThings.isEmpty {
            lines.append("Seen in earlier sessions of this game (positions unknown now): " + unseenKnownThings.keys.sorted().prefix(12).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Calibrating the camera

    /// Lines up the screenshots before and after a small camera turn to
    /// measure how many degrees one mouse point turns in this game.
    func calibrate(before: CGImage, after: CGImage, turnedMousePoints: CGFloat) {
        guard abs(turnedMousePoints) > 20,
              let shiftFraction = Self.horizontalShiftFraction(from: before, to: after) else { return }
        // Turning right slides the scene left.
        let measuredDegrees = -shiftFraction * Self.horizontalFieldOfViewDegrees
        let measuredDegreesPerPoint = measuredDegrees / Double(turnedMousePoints)
        guard measuredDegreesPerPoint > 0.01, measuredDegreesPerPoint < 3 else { return }
        degreesPerMousePoint = degreesPerMousePoint * 0.4 + measuredDegreesPerPoint * 0.6
        save()
    }

    /// How far (as a share of the width, + is right) the scene moved
    /// sideways between two frames, or nil when they don't line up clearly.
    static func horizontalShiftFraction(from before: CGImage, to after: CGImage) -> Double? {
        let width = 160, height = 40
        guard let beforePixels = grayscalePixels(before, width: width, height: height),
              let afterPixels = grayscalePixels(after, width: width, height: height) else { return nil }
        // The middle band: the horizon, not the sky or the character's feet.
        let bandRows = 10..<30
        let maximumShift = 56
        var errors: [(shift: Int, error: Double)] = []
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
            errors.append((shift, totalDifference / Double(comparedCount)))
        }
        guard let best = errors.min(by: { $0.error < $1.error }) else { return nil }
        let averageError = errors.map(\.error).reduce(0, +) / Double(errors.count)
        // A clear match stands out; a blurry or changing scene doesn't.
        guard averageError > 0, best.error < averageError * 0.7 else { return nil }
        return Double(best.shift) / Double(width)
    }

    // MARK: - Private

    private func relativeBearing(to landmark: Landmark) -> (turnDegrees: Double, distance: Double) {
        let deltaX = landmark.x - positionX
        let deltaY = landmark.y - positionY
        let distance = hypot(deltaX, deltaY)
        let bearingDegrees = atan2(deltaX, deltaY) * 180 / .pi
        return (Self.normalizedAngle(bearingDegrees - headingDegrees), distance)
    }

    private static func directionText(_ turnDegrees: Double) -> String {
        let magnitude = abs(turnDegrees)
        let side = turnDegrees > 0 ? "right" : "left"
        switch magnitude {
        case ..<12: return "straight ahead"
        case ..<60: return "ahead-\(side) (\(Int(magnitude))°)"
        case ..<120: return "to your \(side) (\(Int(magnitude))°)"
        case ..<165: return "behind-\(side) (\(Int(magnitude))°)"
        default: return "behind you"
        }
    }

    private static func distanceText(_ distance: Double) -> String {
        distance < 1 ? "right here," : "about \(Int(distance.rounded()))s away,"
    }

    private static func normalizedAngle(_ degrees: Double) -> Double {
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        return angle
    }

    private static func grayscalePixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? pixels : nil
    }

    private func save() {
        let saved = SavedGame(degreesPerMousePoint: degreesPerMousePoint, walkSpeedFactor: nil, knownThings: knownThings)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: saveURL, options: .atomic)
        }
    }
}
