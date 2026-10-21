//
//  DottieGameWorldMap.swift
//  leanring-buddy
//
//  Dottie's 3D map of one game, built from screenshots while she plays and
//  kept between sessions, so she never maps the same place twice:
//
//  - Pose: where she stands on the ground and which way the camera faces,
//    moved along by the keys she holds and the camera turns she makes
//    (DottieGameMovement turns seconds of holding W into distance).
//  - Voxels: a coarse 3D grid of what's around her (half-unit cubes),
//    filled from each mapped frame's depth (DottieGameDepth), skipping the
//    HUD strips and the player's own character.
//  - Keyframes: a small picture and the pose it was taken from, each time
//    she stands somewhere the map doesn't cover yet. A frame is only
//    mapped when no keyframe sits within 2 units and 35° of her pose.
//  - Relocalizing: every mapped-or-not frame is compared with the
//    keyframes (Vision feature prints). A match snaps the pose to the
//    saved one, which also teaches the movement model how fast she walks.
//  - Places: named spots (the shop, the spawn) with their position.
//
//  The map loads into RAM when a game starts and is saved in
//  Application Support/Dottie/Games/<game>/map/ when play stops and every
//  two minutes. Distances are in map units; a unit is roughly a step, and
//  the walking speed per unit is learned.
//
//  Depth from one picture is relative, so each frame's depth is spread
//  over a fixed range: the map is coarse, good for "where's the shop and
//  how do I get there", not for exact geometry.
//

import AppKit
import Foundation
import Vision

@MainActor
final class DottieGameWorldMap {
    struct Pose {
        var x: Double
        var y: Double
        /// Degrees clockwise from the first session's starting direction.
        var headingDegrees: Double
    }

    struct Keyframe: Codable {
        let id: Int
        let x: Double
        let y: Double
        let headingDegrees: Double
        let createdAt: Date
    }

    struct Place: Codable {
        var name: String
        var x: Double
        var y: Double
        var notedAt: Date
    }

    private struct SavedSummary: Codable {
        var keyframes: [Keyframe]
        var places: [Place]
        var nextKeyframeID: Int
        var sessionCount: Int
    }

    let gameName: String
    let movement: DottieGameMovement
    private(set) var pose = Pose(x: 0, y: 0, headingDegrees: 0)
    private(set) var keyframes: [Keyframe] = []
    private(set) var places: [Place] = []
    /// Voxel key (see voxelKey) → how many frames saw a surface there.
    private(set) var voxelHits: [Int64: UInt16] = [:]
    private var keyframePrints: [Int: VNFeaturePrintObservation] = [:]
    private var nextKeyframeID = 0
    private(set) var sessionCount = 0

    /// True once Dottie knows where she is on a saved map (or the map was
    /// empty). Until then nothing new is mapped, so a second session can't
    /// lay a copy of the start area over the first.
    private(set) var isLocalized: Bool
    /// The map was already there when this session started.
    let isFamiliar: Bool
    /// Top-down games get keyframes and places but no 3D points.
    var isTopDownView = false

    private let mapFolderURL: URL
    private let sessionStartedAt = Date()
    private var lastSavedAt = Date()
    private var isConsideringFrame = false
    private var lastConsideredAt: Date?
    /// The last pose that was known for sure (a keyframe match) and how
    /// long Dottie has walked since, to learn her real walking speed.
    private var lastConfirmedPose: Pose?
    private var walkedSecondsSinceConfirmedPose = 0.0

    static let voxelSize = 0.5
    private static let maximumVoxelCount = 600_000
    private static let maximumKeyframeCount = 1_500
    private static let newKeyframeDistance = 2.0
    private static let newKeyframeHeadingDegrees = 35.0
    private static let cameraHeight = 1.6
    /// How long to look for a known place before mapping on anyway.
    private static let secondsToWaitForRelocalizing = 30.0
    private static let secondsBetweenConsideredFrames = 0.8
    private static let secondsBetweenSaves = 120.0

    init(gameName: String, gameFolderURL: URL) {
        self.gameName = gameName
        movement = DottieGameMovement(gameFolderURL: gameFolderURL)
        let loadedMapFolderURL = gameFolderURL.appendingPathComponent("map", isDirectory: true)
        mapFolderURL = loadedMapFolderURL
        try? FileManager.default.createDirectory(at: loadedMapFolderURL.appendingPathComponent("keyframes"), withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loadedKeyframes: [Keyframe] = []
        var loadedPlaces: [Place] = []
        var loadedNextKeyframeID = 0
        var loadedSessionCount = 0
        if let summaryData = try? Data(contentsOf: loadedMapFolderURL.appendingPathComponent("map.json")),
           let savedSummary = try? decoder.decode(SavedSummary.self, from: summaryData) {
            loadedKeyframes = savedSummary.keyframes
            loadedPlaces = savedSummary.places
            loadedNextKeyframeID = savedSummary.nextKeyframeID
            loadedSessionCount = savedSummary.sessionCount
        }
        var loadedPrints: [Int: VNFeaturePrintObservation] = [:]
        for keyframe in loadedKeyframes {
            let printURL = loadedMapFolderURL.appendingPathComponent("keyframes/\(keyframe.id).print")
            if let printData = try? Data(contentsOf: printURL),
               let featurePrint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: printData) {
                loadedPrints[keyframe.id] = featurePrint
            }
        }
        keyframes = loadedKeyframes
        places = loadedPlaces
        nextKeyframeID = loadedNextKeyframeID
        sessionCount = loadedSessionCount + 1
        keyframePrints = loadedPrints
        voxelHits = Self.loadVoxels(from: loadedMapFolderURL.appendingPathComponent("voxels.bin"))
        isFamiliar = !loadedKeyframes.isEmpty
        isLocalized = loadedKeyframes.isEmpty
        // Most games start where they started last time, so the first
        // keyframe (the spawn) is the best guess until a view matches.
        if let firstKeyframe = loadedKeyframes.first {
            pose = Pose(x: firstKeyframe.x, y: firstKeyframe.y, headingDegrees: firstKeyframe.headingDegrees)
        }
        DottieGameDepth.shared.prepare()
    }

    /// The old flat map (DottieGameMap) kept its files in GameMaps; the 3D
    /// map replaced it, so they're removed once. Gameplay recordings live
    /// in GameData and are never touched.
    static func removeOldFlatMaps() {
        let oldMapsFolderURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dottie/GameMaps", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldMapsFolderURL.path) {
            try? FileManager.default.removeItem(at: oldMapsFolderURL)
        }
    }

    // MARK: - Moving (dead reckoning)

    func noteCameraTurn(degrees: Double) {
        pose.headingDegrees = Self.normalizedAngle(pose.headingDegrees + degrees)
    }

    /// Moves the pose for `seconds` of holding these keys (w/a/s/d, with
    /// shift for sprinting). Other keys don't move her.
    func noteMovement(heldKeys: Set<String>, seconds: Double) {
        guard seconds > 0 else { return }
        var forwardAmount = 0.0
        var rightAmount = 0.0
        if heldKeys.contains("w") || heldKeys.contains("up") { forwardAmount += 1 }
        if heldKeys.contains("s") || heldKeys.contains("down") { forwardAmount -= 1 }
        if heldKeys.contains("d") || heldKeys.contains("right") { rightAmount += 1 }
        if heldKeys.contains("a") || heldKeys.contains("left") { rightAmount -= 1 }
        guard forwardAmount != 0 || rightAmount != 0 else { return }
        let directionLength = hypot(forwardAmount, rightAmount)
        let distance = movement.walkUnitsPerSecond(isSprinting: heldKeys.contains("shift")) * seconds
        let headingRadians = pose.headingDegrees * .pi / 180
        // Heading 0 faces +y; turning right (clockwise) moves toward +x.
        let forwardX = sin(headingRadians)
        let forwardY = cos(headingRadians)
        let rightX = cos(headingRadians)
        let rightY = -sin(headingRadians)
        pose.x += (forwardX * forwardAmount + rightX * rightAmount) / directionLength * distance
        pose.y += (forwardY * forwardAmount + rightY * rightAmount) / directionLength * distance
        walkedSecondsSinceConfirmedPose += seconds
    }

    // MARK: - Mapping

    /// Looks at one frame: recognizes a mapped place (and snaps the pose
    /// to it), or maps it when it shows somewhere the map doesn't cover.
    /// Cheap to call often; it skips frames while one is being worked on.
    func considerFrame(_ frame: CGImage) async {
        guard !isConsideringFrame else { return }
        if let lastConsideredAt, Date().timeIntervalSince(lastConsideredAt) < Self.secondsBetweenConsideredFrames { return }
        lastConsideredAt = Date()
        isConsideringFrame = true
        defer { isConsideringFrame = false }

        let poseAtFrame = pose
        guard let framePrint = await Self.featurePrintOffMain(of: frame) else { return }
        if let matchedKeyframe = bestMatchingKeyframe(for: framePrint, near: poseAtFrame) {
            snapPose(to: matchedKeyframe, poseAtFrame: poseAtFrame)
            return
        }
        if !isLocalized, Date().timeIntervalSince(sessionStartedAt) > Self.secondsToWaitForRelocalizing {
            // Nothing looked familiar for a while: this is a new part of
            // the world (or the game moved her), so map from the best guess.
            isLocalized = true
        }
        guard isLocalized, isNewSpot(poseAtFrame), keyframes.count < Self.maximumKeyframeCount else { return }

        addKeyframe(frame: frame, featurePrint: framePrint, at: poseAtFrame)
        if !isTopDownView, voxelHits.count < Self.maximumVoxelCount,
           let depthMap = await DottieGameDepth.shared.depthMap(of: frame) {
            addPoints(from: depthMap, frameAspectRatio: Double(frame.height) / Double(max(frame.width, 1)), at: poseAtFrame)
        }
        if Date().timeIntervalSince(lastSavedAt) > Self.secondsBetweenSaves {
            save()
        }
    }

    /// No keyframe was taken from about here, facing about this way.
    private func isNewSpot(_ candidatePose: Pose) -> Bool {
        !keyframes.contains { keyframe in
            hypot(keyframe.x - candidatePose.x, keyframe.y - candidatePose.y) < Self.newKeyframeDistance
                && abs(Self.normalizedAngle(keyframe.headingDegrees - candidatePose.headingDegrees)) < Self.newKeyframeHeadingDegrees
        }
    }

    private func bestMatchingKeyframe(for framePrint: VNFeaturePrintObservation, near poseAtFrame: Pose) -> Keyframe? {
        var bestMatch: (keyframe: Keyframe, distance: Float)?
        for keyframe in keyframes {
            guard let keyframePrint = keyframePrints[keyframe.id] else { continue }
            var printDistance: Float = 0
            guard (try? framePrint.computeDistance(&printDistance, to: keyframePrint)) != nil else { continue }
            if printDistance < (bestMatch?.distance ?? .greatestFiniteMagnitude) {
                bestMatch = (keyframe, printDistance)
            }
        }
        guard let bestMatch else { return nil }
        // A very close match counts anywhere; a looser one only near where
        // dead reckoning says she is, so look-alike rooms don't fool it.
        let distanceFromPose = hypot(bestMatch.keyframe.x - poseAtFrame.x, bestMatch.keyframe.y - poseAtFrame.y)
        if bestMatch.distance < 0.35 { return bestMatch.keyframe }
        if bestMatch.distance < 0.45, isLocalized, distanceFromPose < 12 { return bestMatch.keyframe }
        return nil
    }

    private func snapPose(to keyframe: Keyframe, poseAtFrame: Pose) {
        // Movement since the frame was taken is kept on top of the snap.
        let movedSinceFrameX = pose.x - poseAtFrame.x
        let movedSinceFrameY = pose.y - poseAtFrame.y
        let turnedSinceFrameDegrees = Self.normalizedAngle(pose.headingDegrees - poseAtFrame.headingDegrees)
        if isLocalized, let lastConfirmedPose {
            let expectedDistance = hypot(poseAtFrame.x - lastConfirmedPose.x, poseAtFrame.y - lastConfirmedPose.y)
            let actualDistance = hypot(keyframe.x - lastConfirmedPose.x, keyframe.y - lastConfirmedPose.y)
            movement.learnWalkSpeed(expectedDistance: expectedDistance, actualDistance: actualDistance, walkedSeconds: walkedSecondsSinceConfirmedPose)
        }
        pose = Pose(
            x: keyframe.x + movedSinceFrameX,
            y: keyframe.y + movedSinceFrameY,
            headingDegrees: Self.normalizedAngle(keyframe.headingDegrees + turnedSinceFrameDegrees)
        )
        isLocalized = true
        lastConfirmedPose = Pose(x: keyframe.x, y: keyframe.y, headingDegrees: keyframe.headingDegrees)
        walkedSecondsSinceConfirmedPose = 0
    }

    private func addKeyframe(frame: CGImage, featurePrint: VNFeaturePrintObservation, at keyframePose: Pose) {
        let keyframe = Keyframe(id: nextKeyframeID, x: keyframePose.x, y: keyframePose.y, headingDegrees: keyframePose.headingDegrees, createdAt: Date())
        nextKeyframeID += 1
        keyframes.append(keyframe)
        keyframePrints[keyframe.id] = featurePrint
        let keyframesFolderURL = mapFolderURL.appendingPathComponent("keyframes")
        if let printData = try? NSKeyedArchiver.archivedData(withRootObject: featurePrint, requiringSecureCoding: true) {
            try? printData.write(to: keyframesFolderURL.appendingPathComponent("\(keyframe.id).print"))
        }
        if let smallFrame = Self.scaled(frame, maximumDimension: 320),
           let pictureData = DottieGameVision.jpegData(of: smallFrame, quality: 0.6) {
            try? pictureData.write(to: keyframesFolderURL.appendingPathComponent("\(keyframe.id).jpg"))
        }
        if lastConfirmedPose == nil {
            lastConfirmedPose = keyframePose
            walkedSecondsSinceConfirmedPose = 0
        }
    }

    /// Places the frame's depth samples in 3D around the pose. The camera
    /// is taken as level at head height, which holds for most third- and
    /// first-person games while walking.
    private func addPoints(from depthMap: DottieDepthMap, frameAspectRatio: Double, at framePose: Pose) {
        let horizontalHalfTangent = tan(movement.horizontalFieldOfViewDegrees / 2 * .pi / 180)
        let verticalHalfTangent = horizontalHalfTangent * frameAspectRatio
        let headingRadians = framePose.headingDegrees * .pi / 180
        for row in 0..<depthMap.rowCount {
            let rowFraction = (Double(row) + 0.5) / Double(depthMap.rowCount)
            // The HUD usually sits in the top and bottom strips.
            guard rowFraction > 0.1, rowFraction < 0.88 else { continue }
            for column in 0..<depthMap.columnCount {
                let columnFraction = (Double(column) + 0.5) / Double(depthMap.columnCount)
                // The player's own character, in the middle of a
                // behind-the-player view.
                if columnFraction > 0.4, columnFraction < 0.6, rowFraction > 0.4 { continue }
                let nearness = Double(depthMap.nearness(column: column, row: row))
                // The farthest few percent is sky or the far distance.
                guard nearness > 0.08 else { continue }
                // Inverse depth spread over about 1-20 units.
                let forwardDistance = 1.0 / (0.05 + 0.95 * nearness)
                let cameraRight = (columnFraction - 0.5) * 2 * horizontalHalfTangent * forwardDistance
                let cameraUp = (0.5 - rowFraction) * 2 * verticalHalfTangent * forwardDistance
                let worldX = framePose.x + sin(headingRadians) * forwardDistance + cos(headingRadians) * cameraRight
                let worldY = framePose.y + cos(headingRadians) * forwardDistance - sin(headingRadians) * cameraRight
                let worldZ = Self.cameraHeight + cameraUp
                let key = Self.voxelKey(x: worldX, y: worldY, z: worldZ)
                let currentHits = voxelHits[key] ?? 0
                if currentHits < UInt16.max {
                    voxelHits[key] = currentHits + 1
                }
            }
        }
    }

    // MARK: - Places

    /// Names the spot Dottie is standing on (or just reached).
    func notePlace(name: String) {
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmedName.isEmpty, isLocalized else { return }
        places.removeAll { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
        places.append(Place(name: trimmedName, x: pose.x, y: pose.y, notedAt: Date()))
    }

    func place(named name: String) -> Place? {
        let lowercasedName = name.lowercased()
        return places.first { $0.name.lowercased() == lowercasedName }
            ?? places.first { $0.name.lowercased().contains(lowercasedName) || lowercasedName.contains($0.name.lowercased()) }
    }

    /// Which way to turn and how far to go from the current pose.
    func bearing(toX targetX: Double, y targetY: Double) -> (turnDegrees: Double, distance: Double) {
        let deltaX = targetX - pose.x
        let deltaY = targetY - pose.y
        let bearingDegrees = atan2(deltaX, deltaY) * 180 / .pi
        return (Self.normalizedAngle(bearingDegrees - pose.headingDegrees), hypot(deltaX, deltaY))
    }

    // MARK: - For the brain

    func summaryText() -> String {
        guard isFamiliar || !keyframes.isEmpty else {
            return "Map: this game is new to Dottie; she maps it as you play."
        }
        var lines = ["Map: \(keyframes.count) spots mapped over \(sessionCount) session(s)."]
        if !isLocalized {
            lines.append("Dottie hasn't recognized where you are yet; look around a known spot to find out.")
        }
        let nearbyPlaces = places
            .map { place -> (place: Place, turnDegrees: Double, distance: Double) in
                let placeBearing = bearing(toX: place.x, y: place.y)
                return (place, placeBearing.turnDegrees, placeBearing.distance)
            }
            .sorted { $0.distance < $1.distance }
            .prefix(10)
        if !nearbyPlaces.isEmpty {
            let placeLines = nearbyPlaces.map { entry in
                let walkSeconds = movement.secondsToWalk(distance: entry.distance, isSprinting: false)
                return "\(entry.place.name): \(Self.directionText(entry.turnDegrees)), about \(Int(walkSeconds.rounded()))s walk"
            }
            lines.append("Known places (use go_to_place to go there without looking): " + placeLines.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Saving

    func save() {
        lastSavedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let summary = SavedSummary(keyframes: keyframes, places: places, nextKeyframeID: nextKeyframeID, sessionCount: sessionCount)
        if let summaryData = try? encoder.encode(summary) {
            try? summaryData.write(to: mapFolderURL.appendingPathComponent("map.json"), options: .atomic)
        }
        Self.saveVoxels(voxelHits, to: mapFolderURL.appendingPathComponent("voxels.bin"))
    }

    /// 10 bytes a voxel: the key, then how many frames saw it.
    private static func saveVoxels(_ voxelHits: [Int64: UInt16], to fileURL: URL) {
        var voxelData = Data(capacity: voxelHits.count * 10)
        for (key, hits) in voxelHits {
            withUnsafeBytes(of: key.littleEndian) { voxelData.append(contentsOf: $0) }
            withUnsafeBytes(of: hits.littleEndian) { voxelData.append(contentsOf: $0) }
        }
        try? voxelData.write(to: fileURL, options: .atomic)
    }

    private static func loadVoxels(from fileURL: URL) -> [Int64: UInt16] {
        guard let voxelData = try? Data(contentsOf: fileURL) else { return [:] }
        let bytes = [UInt8](voxelData)
        let voxelCount = bytes.count / 10
        var voxelHits: [Int64: UInt16] = [:]
        voxelHits.reserveCapacity(voxelCount)
        for voxelIndex in 0..<voxelCount {
            let offset = voxelIndex * 10
            var key: UInt64 = 0
            for byteIndex in 0..<8 {
                key |= UInt64(bytes[offset + byteIndex]) << (8 * UInt64(byteIndex))
            }
            let hits = UInt16(bytes[offset + 8]) | (UInt16(bytes[offset + 9]) << 8)
            voxelHits[Int64(bitPattern: key)] = hits
        }
        return voxelHits
    }

    // MARK: - Voxel keys

    /// Packs a voxel's grid position into one number: 21 bits per axis.
    static func voxelKey(x: Double, y: Double, z: Double) -> Int64 {
        voxelKey(gridX: Int(floor(x / voxelSize)), gridY: Int(floor(y / voxelSize)), gridZ: Int(floor(z / voxelSize)))
    }

    static func voxelKey(gridX: Int, gridY: Int, gridZ: Int) -> Int64 {
        let axisOffset = 1 << 20
        let packedX = Int64(clamping: gridX + axisOffset) & 0x1F_FFFF
        let packedY = Int64(clamping: gridY + axisOffset) & 0x1F_FFFF
        let packedZ = Int64(clamping: gridZ + axisOffset) & 0x1F_FFFF
        return (packedX << 42) | (packedY << 21) | packedZ
    }

    static func gridPosition(ofVoxelKey key: Int64) -> (gridX: Int, gridY: Int, gridZ: Int) {
        let axisOffset = 1 << 20
        let gridX = Int((key >> 42) & 0x1F_FFFF) - axisOffset
        let gridY = Int((key >> 21) & 0x1F_FFFF) - axisOffset
        let gridZ = Int(key & 0x1F_FFFF) - axisOffset
        return (gridX, gridY, gridZ)
    }

    // MARK: - Helpers

    static func normalizedAngle(_ degrees: Double) -> Double {
        var angle = degrees.truncatingRemainder(dividingBy: 360)
        if angle > 180 { angle -= 360 }
        if angle < -180 { angle += 360 }
        return angle
    }

    static func directionText(_ turnDegrees: Double) -> String {
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

    private static func featurePrintOffMain(of frame: CGImage) async -> VNFeaturePrintObservation? {
        let printData: Data? = await Task.detached(priority: .utility) { () -> Data? in
            let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
            let requestHandler = VNImageRequestHandler(cgImage: frame, options: [:])
            try? requestHandler.perform([featurePrintRequest])
            guard let featurePrint = featurePrintRequest.results?.first else { return nil }
            // Archived to cross back to the main actor as plain data.
            return try? NSKeyedArchiver.archivedData(withRootObject: featurePrint, requiringSecureCoding: true)
        }.value
        guard let printData else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: printData)
    }

    private static func scaled(_ image: CGImage, maximumDimension: Int) -> CGImage? {
        let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
