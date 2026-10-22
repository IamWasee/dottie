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
//  - Blockers: spots where a walk got stuck though the map showed the way
//    clear. The first time, the blocker fades after 45 seconds (likely a
//    moving thing: a player, an enemy, a platform). Stuck at the same spot
//    again once it has faded means something fixed the depth missed, and
//    that spot stays blocked on the saved map.
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
        /// Grid cells (x, y) found blocked by walking into them.
        var learnedBlockedCells: [[Int]]?
    }

    /// A spot on the floor grid (DottieGameNavigator's half-unit cells).
    struct FloorCell: Hashable {
        let gridX: Int
        let gridY: Int
    }

    let gameName: String
    let movement: DottieGameMovement
    private(set) var pose = Pose(x: 0, y: 0, headingDegrees: 0)
    private(set) var keyframes: [Keyframe] = []
    private(set) var places: [Place] = []
    /// Voxel key (see voxelKey) → how many frames saw a surface there.
    private(set) var voxelHits: [Int64: UInt16] = [:]
    /// The fine layer: small blocks (`detailVoxelSize`) from the depth of
    /// every frame she sees while she knows where she is, like light
    /// falling on things in the dark. Over time it outlines shops, walls
    /// and machines. Only for looking at (the 3D model); walking plans use
    /// the coarse `voxelHits`.
    private(set) var detailVoxelHits: [Int64: UInt16] = [:]
    /// Each fine block's color as seen in the game (0xRRGGBB, averaged over
    /// the times it was seen), so the 3D model looks like the place.
    private(set) var detailVoxelColors: [Int64: UInt32] = [:]
    /// The same looks as solid surfaces, for the 3D model that looks like
    /// the game (DottieGameSurfaceMap).
    let surfaceMap: DottieGameSurfaceMap
    /// Feature prints of each spot's view without the HUD strips (see
    /// `recognitionView`), for recognizing it again.
    private var keyframePrints: [Int: VNFeaturePrintObservation] = [:]
    /// Spots saved before prints left out the HUD; their prints are made
    /// again from the spot's picture, a few per frame.
    private var keyframeIDsWithoutViewPrint: [Int] = []
    private var lastRecognitionMissLoggedAt = Date.distantPast
    private var lastDetailFrameAt = Date.distantPast

    /// What spawn looks like, kept in the game's own `spawn` folder beside
    /// the map rather than in it, so a deleted or broken map can be rebuilt
    /// from the same 0,0,0: on an empty map she waits until she sees spawn
    /// and starts the new map there.
    private struct SpawnView: Codable {
        let fileName: String
        let headingDegrees: Double
    }
    private let spawnFolderURL: URL
    private var spawnViews: [SpawnView] = []
    var spawnViewCount: Int { spawnViews.count }
    private var spawnViewPrints: [String: VNFeaturePrintObservation] = [:]
    private static let maximumSpawnViewCount = 8

    /// Named things (the shop, the packager, a portal) remembered like
    /// spawn: how they look from where she named them, and where that is
    /// from spawn. Seeing one tells her where she is without going back to
    /// spawn. Kept in the game's `landmarks` folder beside the map.
    private struct Landmark: Codable {
        let name: String
        let fileName: String
        let x: Double
        let y: Double
        let headingDegrees: Double
    }
    private let landmarksFolderURL: URL
    private var landmarks: [Landmark] = []
    private var landmarkPrints: [String: VNFeaturePrintObservation] = [:]
    private static let maximumViewsPerLandmark = 4
    /// The newest frame's print and the pose it was seen from, for saving
    /// a landmark's look when a place is named.
    private var newestSeenView: (featurePrint: VNFeaturePrintObservation, pose: Pose, seenAt: Date)?
    /// Places named before she knew where she was, with her guessed pose.
    private var placesWaitingForLocalizing: [(name: String, pose: Pose)] = []
    private var nextKeyframeID = 0
    private(set) var sessionCount = 0
    /// Fixed things the depth missed, kept on the saved map.
    private(set) var learnedBlockedCells: Set<FloorCell> = []
    /// Blockers from this session that fade (moving things), with when.
    private var fadingBlockers: [(cell: FloorCell, notedAt: Date)] = []

    /// True once Dottie knows where she is on a saved map (or the map was
    /// empty). Until then nothing new is mapped, so a second session can't
    /// lay a copy of the start area over the first.
    private(set) var isLocalized: Bool
    /// The map was already there when this session started.
    let isFamiliar: Bool
    /// Top-down games get keyframes and places but no 3D points.
    var isTopDownView = false

    let mapFolderURL: URL
    /// For the map's report: what this session added and recognized.
    private(set) var keyframesAddedThisSession = 0
    private(set) var framesWithDepthThisSession = 0
    private(set) var recognitionsThisSession = 0
    /// Since when she's been looking for a spot she knows: the session's
    /// start, or the last teleport.
    private var lookingForKnownSpotSince = Date()
    /// After a teleport (a black loading screen, a portal, respawning), a
    /// place she doesn't recognize is a new zone, laid out away from the
    /// rest of the map instead of on top of where she was.
    private var startsNewZoneIfNothingLooksFamiliar = false
    /// How far apart zones are laid out on the map.
    private static let zoneSpacing = 500.0
    private var lastSavedAt = Date()
    private var isConsideringFrame = false
    private var lastConsideredAt: Date?
    /// The last pose that was known for sure (a keyframe match) and how
    /// long Dottie has walked since, to learn her real walking speed.
    private var lastConfirmedPose: Pose?
    private var walkedSecondsSinceConfirmedPose = 0.0

    static let voxelSize = 0.5
    private static let maximumVoxelCount = 600_000
    static let detailVoxelSize = 0.125
    /// About 40 MB in memory at the most.
    private static let maximumDetailVoxelCount = 1_500_000
    /// Depth for the fine layer at most this often, between new spots.
    private static let secondsBetweenDetailFrames = 1.0
    /// Spots this close to spawn are spawn's views: games start and
    /// respawn there, so they're the first thing she checks.
    private static let spawnRadius = 2.0
    private static let maximumKeyframeCount = 1_500
    private static let newKeyframeDistance = 2.0
    private static let newKeyframeHeadingDegrees = 35.0
    private static let cameraHeight = 1.6
    /// How long to look for a known place before mapping on anyway.
    private static let secondsToWaitForRelocalizing = 30.0
    private static let secondsBetweenConsideredFrames = 0.8
    private static let secondsBetweenSaves = 120.0
    private static let secondsForBlockerToFade = 45.0

    init(gameName: String, gameFolderURL: URL) {
        self.gameName = gameName
        movement = DottieGameMovement(gameFolderURL: gameFolderURL)
        let loadedMapFolderURL = gameFolderURL.appendingPathComponent("map", isDirectory: true)
        mapFolderURL = loadedMapFolderURL
        spawnFolderURL = gameFolderURL.appendingPathComponent("spawn", isDirectory: true)
        landmarksFolderURL = gameFolderURL.appendingPathComponent("landmarks", isDirectory: true)
        surfaceMap = DottieGameSurfaceMap(mapFolderURL: loadedMapFolderURL)
        try? FileManager.default.createDirectory(at: loadedMapFolderURL.appendingPathComponent("keyframes"), withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loadedKeyframes: [Keyframe] = []
        var loadedPlaces: [Place] = []
        var loadedNextKeyframeID = 0
        var loadedSessionCount = 0
        var loadedBlockedCells: Set<FloorCell> = []
        if let summaryData = try? Data(contentsOf: loadedMapFolderURL.appendingPathComponent("map.json")),
           let savedSummary = try? decoder.decode(SavedSummary.self, from: summaryData) {
            loadedKeyframes = savedSummary.keyframes
            loadedPlaces = savedSummary.places
            loadedNextKeyframeID = savedSummary.nextKeyframeID
            loadedSessionCount = savedSummary.sessionCount
            for cellCoordinates in savedSummary.learnedBlockedCells ?? [] where cellCoordinates.count == 2 {
                loadedBlockedCells.insert(FloorCell(gridX: cellCoordinates[0], gridY: cellCoordinates[1]))
            }
        }
        var loadedPrints: [Int: VNFeaturePrintObservation] = [:]
        var loadedKeyframeIDsWithoutViewPrint: [Int] = []
        for keyframe in loadedKeyframes {
            let printURL = loadedMapFolderURL.appendingPathComponent("keyframes/\(keyframe.id).view.print")
            if let printData = try? Data(contentsOf: printURL),
               let featurePrint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: printData) {
                loadedPrints[keyframe.id] = featurePrint
            } else {
                loadedKeyframeIDsWithoutViewPrint.append(keyframe.id)
            }
        }
        keyframeIDsWithoutViewPrint = loadedKeyframeIDsWithoutViewPrint
        keyframes = loadedKeyframes
        places = loadedPlaces
        nextKeyframeID = loadedNextKeyframeID
        sessionCount = loadedSessionCount + 1
        learnedBlockedCells = loadedBlockedCells
        keyframePrints = loadedPrints
        voxelHits = Self.loadVoxels(from: loadedMapFolderURL.appendingPathComponent("voxels.bin"))
        let loadedDetail = Self.loadDetailVoxels(from: loadedMapFolderURL.appendingPathComponent("detail.bin"))
        detailVoxelHits = loadedDetail.hits
        detailVoxelColors = loadedDetail.colors
        isFamiliar = !loadedKeyframes.isEmpty
        if let spawnData = try? Data(contentsOf: spawnFolderURL.appendingPathComponent("views.json")),
           let loadedSpawnViews = try? JSONDecoder().decode([SpawnView].self, from: spawnData) {
            for spawnView in loadedSpawnViews {
                if let printData = try? Data(contentsOf: spawnFolderURL.appendingPathComponent(spawnView.fileName + ".print")),
                   let spawnPrint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: printData) {
                    spawnViews.append(spawnView)
                    spawnViewPrints[spawnView.fileName] = spawnPrint
                }
            }
        }
        if let landmarksData = try? Data(contentsOf: landmarksFolderURL.appendingPathComponent("landmarks.json")),
           let loadedLandmarks = try? JSONDecoder().decode([Landmark].self, from: landmarksData) {
            for landmark in loadedLandmarks {
                if let printData = try? Data(contentsOf: landmarksFolderURL.appendingPathComponent(landmark.fileName + ".print")),
                   let landmarkPrint = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: printData) {
                    landmarks.append(landmark)
                    landmarkPrints[landmark.fileName] = landmarkPrint
                }
            }
        }
        // An empty map with a known spawn (the map was deleted) waits to see
        // spawn, so the new map has the same 0,0,0 as before.
        isLocalized = loadedKeyframes.isEmpty && spawnViews.isEmpty
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

    /// The game moved her without walking (a loading screen, a portal,
    /// respawning): counted steps no longer say where she is, so she looks
    /// for a spot she knows and, failing that, maps a new zone.
    func noteTeleport() {
        guard !keyframes.isEmpty else { return }
        if isLocalized {
            DottieGameNotebook.appendToPlayLog("Map: the game seems to have moved her (teleport, loading screen or respawn), so she's finding where she is again.", gameFolderURL: mapFolderURL.deletingLastPathComponent())
        }
        isLocalized = false
        lookingForKnownSpotSince = Date()
        startsNewZoneIfNothingLooksFamiliar = true
    }

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
    /// Like considerFrame, but this frame is never skipped: waits for the
    /// frame being worked on and ignores the pause between frames. For the
    /// views of a deliberate look around.
    func considerFrameWithoutSkipping(_ frame: CGImage) async {
        let waitStartedAt = Date()
        while isConsideringFrame, Date().timeIntervalSince(waitStartedAt) < 3 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        lastConsideredAt = nil
        await considerFrame(frame)
    }

    func considerFrame(_ frame: CGImage) async {
        guard !isConsideringFrame else { return }
        if let lastConsideredAt, Date().timeIntervalSince(lastConsideredAt) < Self.secondsBetweenConsideredFrames { return }
        lastConsideredAt = Date()
        isConsideringFrame = true
        defer { isConsideringFrame = false }

        let poseAtFrame = pose
        await makeMissingViewPrints()
        if keyframeIDsWithoutViewPrint.isEmpty, spawnViews.isEmpty {
            rememberSpawnViewsFromMapIfNeeded()
        }
        guard let framePrint = await Self.featurePrintOffMain(of: frame) else { return }
        if let matchedKeyframe = bestMatchingKeyframe(for: framePrint, near: poseAtFrame) {
            snapPose(to: matchedKeyframe, poseAtFrame: poseAtFrame)
            return
        }
        newestSeenView = (framePrint, poseAtFrame, Date())
        if !isLocalized, let spawnHeadingDegrees = matchingSpawnHeading(for: framePrint) {
            snapToAnchor(named: "spawn", x: 0, y: 0, facingDegrees: spawnHeadingDegrees, poseAtFrame: poseAtFrame)
            return
        }
        if let matchedLandmark = matchingLandmark(for: framePrint, near: poseAtFrame) {
            snapToAnchor(named: matchedLandmark.name, x: matchedLandmark.x, y: matchedLandmark.y, facingDegrees: matchedLandmark.headingDegrees, poseAtFrame: poseAtFrame)
            return
        }
        if !isLocalized, Date().timeIntervalSince(lookingForKnownSpotSince) > Self.secondsToWaitForRelocalizing {
            // Nothing looked familiar for a while: this is a new part of
            // the world (or the game moved her), so map from the best guess.
            isLocalized = true
            var poseCorrectionX = 0.0
            if startsNewZoneIfNothingLooksFamiliar {
                // East of everything mapped so far, so zones never overlap.
                let farthestMappedX = keyframes.map(\.x).max() ?? pose.x
                let newZoneX = farthestMappedX + Self.zoneSpacing
                poseCorrectionX = newZoneX - pose.x
                pose = Pose(x: newZoneX, y: 0, headingDegrees: 0)
                DottieGameNotebook.appendToPlayLog("Map: nothing looked familiar for 30 seconds after a teleport, so this is a new zone, mapped apart from the others.", gameFolderURL: mapFolderURL.deletingLastPathComponent())
            } else {
                DottieGameNotebook.appendToPlayLog("Map: nothing looked familiar for 30 seconds, so mapping from here as new ground.", gameFolderURL: mapFolderURL.deletingLastPathComponent())
            }
            startsNewZoneIfNothingLooksFamiliar = false
            lastConfirmedPose = nil
            addPlacesWaitingForLocalizing(poseCorrectionX: poseCorrectionX, poseCorrectionY: 0)
        }
        guard isLocalized, !isTopDownView || isNewSpot(poseAtFrame) else { return }
        let isNewSpotToMap = isNewSpot(poseAtFrame) && keyframes.count < Self.maximumKeyframeCount
        if isNewSpotToMap {
            addKeyframe(frame: frame, featurePrint: framePrint, at: poseAtFrame)
        }
        // A new spot adds to both layers; any other frame adds only to the
        // fine layer, about once a second.
        let isDueForDetail = Date().timeIntervalSince(lastDetailFrameAt) > Self.secondsBetweenDetailFrames
        if !isTopDownView, isNewSpotToMap || isDueForDetail,
           let depthMap = await DottieGameDepth.shared.depthMap(of: frame) {
            lastDetailFrameAt = Date()
            addPoints(
                from: depthMap,
                colors: Self.colorGrid(of: frame, columnCount: depthMap.columnCount, rowCount: depthMap.rowCount),
                frameAspectRatio: Double(frame.height) / Double(max(frame.width, 1)),
                at: poseAtFrame,
                addsToWalkingGrid: isNewSpotToMap && voxelHits.count < Self.maximumVoxelCount
            )
            framesWithDepthThisSession += 1
        }
        if Date().timeIntervalSince(lastSavedAt) > Self.secondsBetweenSaves {
            save()
        }
    }

    /// The heading of the spawn view this frame shows, or nil.
    private func matchingSpawnHeading(for framePrint: VNFeaturePrintObservation) -> Double? {
        var bestMatch: (spawnView: SpawnView, distance: Float)?
        for spawnView in spawnViews {
            guard let spawnPrint = spawnViewPrints[spawnView.fileName] else { continue }
            var printDistance: Float = 0
            guard (try? framePrint.computeDistance(&printDistance, to: spawnPrint)) != nil else { continue }
            if printDistance < (bestMatch?.distance ?? .greatestFiniteMagnitude) {
                bestMatch = (spawnView, printDistance)
            }
        }
        guard let bestMatch, bestMatch.distance < 0.5 else { return nil }
        return bestMatch.spawnView.headingDegrees
    }

    /// The landmark this frame shows, if any: any close match while she's
    /// finding herself, and only a very close one near where she thinks she
    /// is otherwise (correcting the drift of counted steps).
    private func matchingLandmark(for framePrint: VNFeaturePrintObservation, near poseAtFrame: Pose) -> Landmark? {
        var bestMatch: (landmark: Landmark, distance: Float)?
        for landmark in landmarks {
            guard let landmarkPrint = landmarkPrints[landmark.fileName] else { continue }
            var printDistance: Float = 0
            guard (try? framePrint.computeDistance(&printDistance, to: landmarkPrint)) != nil else { continue }
            if printDistance < (bestMatch?.distance ?? .greatestFiniteMagnitude) {
                bestMatch = (landmark, printDistance)
            }
        }
        guard let bestMatch else { return nil }
        if !isLocalized {
            return bestMatch.distance < 0.5 ? bestMatch.landmark : nil
        }
        let distanceFromPose = hypot(bestMatch.landmark.x - poseAtFrame.x, bestMatch.landmark.y - poseAtFrame.y)
        return bestMatch.distance < 0.3 && distanceFromPose < 15 ? bestMatch.landmark : nil
    }

    /// She sees spawn or a landmark from where it was remembered: she's at
    /// its position from spawn again, facing that view's way.
    private func snapToAnchor(named anchorName: String, x anchorX: Double, y anchorY: Double, facingDegrees anchorHeadingDegrees: Double, poseAtFrame: Pose) {
        let movedSinceFrameX = pose.x - poseAtFrame.x
        let movedSinceFrameY = pose.y - poseAtFrame.y
        let turnedSinceFrameDegrees = Self.normalizedAngle(pose.headingDegrees - poseAtFrame.headingDegrees)
        let poseCorrectionX = anchorX - poseAtFrame.x
        let poseCorrectionY = anchorY - poseAtFrame.y
        let wasLocalized = isLocalized
        pose = Pose(x: anchorX + movedSinceFrameX, y: anchorY + movedSinceFrameY, headingDegrees: Self.normalizedAngle(anchorHeadingDegrees + turnedSinceFrameDegrees))
        if !wasLocalized || hypot(poseCorrectionX, poseCorrectionY) > 1 {
            let positionText = String(format: "(%.1f, %.1f)", anchorX, anchorY)
            DottieGameNotebook.appendToPlayLog("Map: recognized \(anchorName), so Dottie is at \(positionText) from spawn\(wasLocalized ? String(format: " (she was %.1f off)", hypot(poseCorrectionX, poseCorrectionY)) : "")\(keyframes.isEmpty ? " and starts the map from there" : "").", gameFolderURL: mapFolderURL.deletingLastPathComponent())
        }
        isLocalized = true
        startsNewZoneIfNothingLooksFamiliar = false
        recognitionsThisSession += 1
        lastConfirmedPose = Pose(x: anchorX, y: anchorY, headingDegrees: anchorHeadingDegrees)
        walkedSecondsSinceConfirmedPose = 0
        if !wasLocalized {
            addPlacesWaitingForLocalizing(poseCorrectionX: poseCorrectionX, poseCorrectionY: poseCorrectionY)
        }
    }

    /// Remembers how a named place looks from where she is, as a landmark.
    /// Only with a view from the last few seconds, taken close by.
    private func rememberLandmarkView(named placeName: String, at placePose: Pose) {
        guard let newestSeenView, Date().timeIntervalSince(newestSeenView.seenAt) < 5,
              hypot(newestSeenView.pose.x - placePose.x, newestSeenView.pose.y - placePose.y) < 3 else { return }
        let viewsOfThisPlace = landmarks.filter { $0.name.caseInsensitiveCompare(placeName) == .orderedSame }
        guard viewsOfThisPlace.count < Self.maximumViewsPerLandmark,
              !viewsOfThisPlace.contains(where: { abs(Self.normalizedAngle($0.headingDegrees - newestSeenView.pose.headingDegrees)) < Self.newKeyframeHeadingDegrees }),
              let printData = try? NSKeyedArchiver.archivedData(withRootObject: newestSeenView.featurePrint, requiringSecureCoding: true) else { return }
        try? FileManager.default.createDirectory(at: landmarksFolderURL, withIntermediateDirectories: true)
        let safeName = placeName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let landmark = Landmark(
            name: placeName,
            fileName: "\(String(safeName).prefix(40))-\(Int(Self.normalizedAngle(newestSeenView.pose.headingDegrees).rounded()))",
            x: newestSeenView.pose.x,
            y: newestSeenView.pose.y,
            headingDegrees: newestSeenView.pose.headingDegrees
        )
        try? printData.write(to: landmarksFolderURL.appendingPathComponent(landmark.fileName + ".print"))
        landmarks.append(landmark)
        landmarkPrints[landmark.fileName] = newestSeenView.featurePrint
        if let landmarksData = try? JSONEncoder().encode(landmarks) {
            try? landmarksData.write(to: landmarksFolderURL.appendingPathComponent("landmarks.json"), options: .atomic)
        }
    }

    /// Where each landmark is from spawn and from the others, for the
    /// brain: "Sell is 6 ahead and 3 right of the Packager".
    func landmarkLinesForBrain() -> [String] {
        var firstViewByName: [String: Landmark] = [:]
        for landmark in landmarks where firstViewByName[landmark.name.lowercased()] == nil {
            firstViewByName[landmark.name.lowercased()] = landmark
        }
        let namedLandmarks = Array(firstViewByName.values).sorted { $0.name < $1.name }.prefix(12)
        return namedLandmarks.map { landmark in
            var line = String(format: "%@: %.0f east, %.0f north of spawn", landmark.name, landmark.x, landmark.y)
            if let nearestOther = namedLandmarks.filter({ $0.name != landmark.name }).min(by: { hypot($0.x - landmark.x, $0.y - landmark.y) < hypot($1.x - landmark.x, $1.y - landmark.y) }) {
                line += String(format: "; %.0f from %@", hypot(nearestOther.x - landmark.x, nearestOther.y - landmark.y), nearestOther.name)
            }
            return line
        }
    }

    /// Keeps a view taken at spawn in the spawn folder, one per direction.
    private func rememberSpawnView(frame: CGImage?, featurePrint: VNFeaturePrintObservation, headingDegrees: Double, pictureToCopyURL: URL? = nil) {
        guard spawnViews.count < Self.maximumSpawnViewCount,
              !spawnViews.contains(where: { abs(Self.normalizedAngle($0.headingDegrees - headingDegrees)) < Self.newKeyframeHeadingDegrees }),
              let printData = try? NSKeyedArchiver.archivedData(withRootObject: featurePrint, requiringSecureCoding: true) else { return }
        try? FileManager.default.createDirectory(at: spawnFolderURL, withIntermediateDirectories: true)
        let spawnView = SpawnView(fileName: "view-\(Int(Self.normalizedAngle(headingDegrees).rounded()))", headingDegrees: headingDegrees)
        try? printData.write(to: spawnFolderURL.appendingPathComponent(spawnView.fileName + ".print"))
        let spawnPictureURL = spawnFolderURL.appendingPathComponent(spawnView.fileName + ".jpg")
        if let frame, let smallFrame = Self.scaled(frame, maximumDimension: 320),
           let pictureData = DottieGameVision.jpegData(of: smallFrame, quality: 0.6) {
            try? pictureData.write(to: spawnPictureURL)
        } else if let pictureToCopyURL {
            try? FileManager.default.removeItem(at: spawnPictureURL)
            try? FileManager.default.copyItem(at: pictureToCopyURL, to: spawnPictureURL)
        }
        spawnViews.append(spawnView)
        spawnViewPrints[spawnView.fileName] = featurePrint
        if let spawnData = try? JSONEncoder().encode(spawnViews) {
            try? spawnData.write(to: spawnFolderURL.appendingPathComponent("views.json"), options: .atomic)
        }
    }

    /// A map made before spawn had its own folder: its spots at spawn
    /// become spawn's views, once their prints are ready.
    private func rememberSpawnViewsFromMapIfNeeded() {
        guard spawnViews.count < Self.maximumSpawnViewCount else { return }
        for keyframe in keyframes where isSpawnView(keyframe) {
            guard let keyframePrint = keyframePrints[keyframe.id] else { continue }
            let pictureURL = mapFolderURL.appendingPathComponent("keyframes/\(keyframe.id).jpg")
            rememberSpawnView(frame: nil, featurePrint: keyframePrint, headingDegrees: keyframe.headingDegrees, pictureToCopyURL: pictureURL)
        }
    }

    /// Spawn is (0, 0) at floor height, where she stood the first time she
    /// played; everything on the map is measured from it.
    private func isSpawnView(_ keyframe: Keyframe) -> Bool {
        hypot(keyframe.x, keyframe.y) < Self.spawnRadius
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
        var secondBestDistance: Float = .greatestFiniteMagnitude
        for keyframe in keyframes {
            guard let keyframePrint = keyframePrints[keyframe.id] else { continue }
            var printDistance: Float = 0
            guard (try? framePrint.computeDistance(&printDistance, to: keyframePrint)) != nil else { continue }
            if printDistance < (bestMatch?.distance ?? .greatestFiniteMagnitude) {
                secondBestDistance = bestMatch?.distance ?? secondBestDistance
                bestMatch = (keyframe, printDistance)
            } else if printDistance < secondBestDistance {
                secondBestDistance = printDistance
            }
        }
        guard let bestMatch else { return nil }
        // A very close match counts anywhere; a looser one only near where
        // dead reckoning says she is, so look-alike rooms don't fool it.
        // Before she knows where she is, a loose match also counts when it
        // stands out from every other spot.
        let distanceFromPose = hypot(bestMatch.keyframe.x - poseAtFrame.x, bestMatch.keyframe.y - poseAtFrame.y)
        if bestMatch.distance < 0.35 { return bestMatch.keyframe }
        if bestMatch.distance < 0.5, distanceFromPose < 12 { return bestMatch.keyframe }
        if !isLocalized, bestMatch.distance < 0.6, secondBestDistance - bestMatch.distance > 0.1 { return bestMatch.keyframe }
        // Games start and respawn at spawn, so while she's finding herself a
        // looser match to one of spawn's views counts.
        if !isLocalized, isSpawnView(bestMatch.keyframe), bestMatch.distance < 0.55 { return bestMatch.keyframe }
        if !isLocalized, Date().timeIntervalSince(lastRecognitionMissLoggedAt) > 10 {
            // How close the nearest spot came, to tune these limits from the play log.
            lastRecognitionMissLoggedAt = Date()
            DottieGameNotebook.appendToPlayLog("Map: no spot recognized yet; the closest was spot \(bestMatch.keyframe.id) at \(String(format: "%.2f", bestMatch.distance)) (0.35 or less counts anywhere, 0.5 nearby).", gameFolderURL: mapFolderURL.deletingLastPathComponent())
        }
        return nil
    }

    /// Makes prints for a few spots saved before prints left out the HUD,
    /// from each spot's saved picture.
    private func makeMissingViewPrints() async {
        guard !keyframeIDsWithoutViewPrint.isEmpty else { return }
        let keyframeIDsThisTime = Array(keyframeIDsWithoutViewPrint.prefix(10))
        keyframeIDsWithoutViewPrint.removeFirst(keyframeIDsThisTime.count)
        let keyframesFolderURL = mapFolderURL.appendingPathComponent("keyframes")
        for keyframeID in keyframeIDsThisTime {
            let pictureURL = keyframesFolderURL.appendingPathComponent("\(keyframeID).jpg")
            guard let imageSource = CGImageSourceCreateWithURL(pictureURL as CFURL, nil),
                  let picture = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  let viewPrint = await Self.featurePrintOffMain(of: picture) else { continue }
            keyframePrints[keyframeID] = viewPrint
            if let printData = try? NSKeyedArchiver.archivedData(withRootObject: viewPrint, requiringSecureCoding: true) {
                try? printData.write(to: keyframesFolderURL.appendingPathComponent("\(keyframeID).view.print"))
            }
        }
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
        if !isLocalized {
            DottieGameNotebook.appendToPlayLog("Map: recognized spot \(keyframe.id), so Dottie knows where she is.", gameFolderURL: mapFolderURL.deletingLastPathComponent())
            addPlacesWaitingForLocalizing(poseCorrectionX: pose.x - poseAtFrame.x - movedSinceFrameX, poseCorrectionY: pose.y - poseAtFrame.y - movedSinceFrameY)
        }
        startsNewZoneIfNothingLooksFamiliar = false
        isLocalized = true
        recognitionsThisSession += 1
        lastConfirmedPose = Pose(x: keyframe.x, y: keyframe.y, headingDegrees: keyframe.headingDegrees)
        walkedSecondsSinceConfirmedPose = 0
    }

    private func addKeyframe(frame: CGImage, featurePrint: VNFeaturePrintObservation, at keyframePose: Pose) {
        let keyframe = Keyframe(id: nextKeyframeID, x: keyframePose.x, y: keyframePose.y, headingDegrees: keyframePose.headingDegrees, createdAt: Date())
        nextKeyframeID += 1
        keyframes.append(keyframe)
        keyframesAddedThisSession += 1
        DottieGameNotebook.appendToPlayLog("Map: new spot \(keyframe.id) at (\(String(format: "%.1f", keyframe.x)), \(String(format: "%.1f", keyframe.y))) facing \(Int(keyframe.headingDegrees))°.", gameFolderURL: mapFolderURL.deletingLastPathComponent())
        keyframePrints[keyframe.id] = featurePrint
        if isSpawnView(keyframe) {
            rememberSpawnView(frame: frame, featurePrint: featurePrint, headingDegrees: keyframe.headingDegrees)
        }
        let keyframesFolderURL = mapFolderURL.appendingPathComponent("keyframes")
        if let printData = try? NSKeyedArchiver.archivedData(withRootObject: featurePrint, requiringSecureCoding: true) {
            try? printData.write(to: keyframesFolderURL.appendingPathComponent("\(keyframe.id).view.print"))
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

    /// Places the frame's depth samples in 3D around the pose.
    ///
    /// Game cameras usually look down at the player a little, and the depth
    /// model only gives relative distances. So the floor is found first:
    /// the strip at the bottom of the view, either side of the player, is
    /// taken as ground, and a line through it gives the camera's downward
    /// tilt and its height above the ground. Every sample is then turned
    /// level and scaled so the camera sits `cameraHeight` above the floor,
    /// which puts open ground at height 0 instead of reading it as wall.
    /// When the strip doesn't look like ground, the camera is taken as
    /// level at head height.
    private func addPoints(from depthMap: DottieDepthMap, colors colorGrid: [UInt32]?, frameAspectRatio: Double, at framePose: Pose, addsToWalkingGrid: Bool) {
        let horizontalHalfTangent = tan(movement.horizontalFieldOfViewDegrees / 2 * .pi / 180)
        let verticalHalfTangent = horizontalHalfTangent * frameAspectRatio
        let headingRadians = framePose.headingDegrees * .pi / 180

        // Samples in camera space: right, up and forward along the view.
        var cameraSamples: [(right: Double, up: Double, forward: Double, isGroundStrip: Bool, isWalkingGridSample: Bool, color: UInt32?)] = []
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
                cameraSamples.append((
                    right: (columnFraction - 0.5) * 2 * horizontalHalfTangent * forwardDistance,
                    up: (0.5 - rowFraction) * 2 * verticalHalfTangent * forwardDistance,
                    forward: forwardDistance,
                    isGroundStrip: rowFraction > 0.68 && (columnFraction < 0.3 || columnFraction > 0.7),
                    // The walking grid was tuned on a sample grid half as
                    // dense, so it keeps every other row and column.
                    isWalkingGridSample: row % 2 == 0 && column % 2 == 0,
                    color: colorGrid?[row * depthMap.columnCount + column]
                ))
            }
        }

        let floorFit = Self.fitFloor(through: cameraSamples.filter(\.isGroundStrip).map { ($0.up, $0.forward) })
        var surfaceHits: [(x: Double, y: Double, z: Double, color: UInt32?)] = []
        surfaceHits.reserveCapacity(cameraSamples.count)
        defer {
            surfaceMap.addRays(cameraX: framePose.x, cameraY: framePose.y, cameraHeight: Self.cameraHeight, hits: surfaceHits)
        }
        for cameraSample in cameraSamples {
            var levelForward = cameraSample.forward
            var levelRight = cameraSample.right
            var heightAboveFloor = Self.cameraHeight + cameraSample.up
            if let floorFit {
                // Undo the downward tilt, then scale to the camera's height.
                levelForward = (cameraSample.forward * floorFit.tiltCosine + cameraSample.up * floorFit.tiltSine) * floorFit.scale
                levelRight = cameraSample.right * floorFit.scale
                let heightAboveCamera = (cameraSample.up * floorFit.tiltCosine - cameraSample.forward * floorFit.tiltSine) * floorFit.scale
                heightAboveFloor = Self.cameraHeight + heightAboveCamera
            }
            let worldX = framePose.x + sin(headingRadians) * levelForward + cos(headingRadians) * levelRight
            let worldY = framePose.y + cos(headingRadians) * levelForward - sin(headingRadians) * levelRight
            if addsToWalkingGrid, cameraSample.isWalkingGridSample {
                let key = Self.voxelKey(x: worldX, y: worldY, z: heightAboveFloor)
                let currentHits = voxelHits[key] ?? 0
                if currentHits < UInt16.max {
                    voxelHits[key] = currentHits + 1
                }
            }
            // Far samples are too rough for small blocks.
            guard levelForward < 12 else { continue }
            surfaceHits.append((worldX, worldY, heightAboveFloor, cameraSample.color))
            let detailKey = Self.voxelKey(
                gridX: Int(floor(worldX / Self.detailVoxelSize)),
                gridY: Int(floor(worldY / Self.detailVoxelSize)),
                gridZ: Int(floor(heightAboveFloor / Self.detailVoxelSize))
            )
            if let currentDetailHits = detailVoxelHits[detailKey] {
                if currentDetailHits < UInt16.max {
                    detailVoxelHits[detailKey] = currentDetailHits + 1
                }
                if let sampleColor = cameraSample.color {
                    detailVoxelColors[detailKey] = Self.blendedColor(detailVoxelColors[detailKey] ?? sampleColor, with: sampleColor, earlierSightings: Int(currentDetailHits))
                }
            } else if detailVoxelHits.count < Self.maximumDetailVoxelCount {
                detailVoxelHits[detailKey] = 1
                if let sampleColor = cameraSample.color {
                    detailVoxelColors[detailKey] = sampleColor
                }
            }
        }
    }

    /// The camera's downward tilt and the scale that puts it `cameraHeight`
    /// above the floor, from samples taken to be ground: in camera space a
    /// flat floor is the line up = intercept + slope × forward, where the
    /// slope is the tilt's tangent and the intercept sits a camera height
    /// (over the tilt's cosine) below. nil when they don't fit a floor.
    private static func fitFloor(through groundSamples: [(up: Double, forward: Double)]) -> (tiltSine: Double, tiltCosine: Double, scale: Double)? {
        guard groundSamples.count >= 12 else { return nil }
        let sampleCount = Double(groundSamples.count)
        let meanForward = groundSamples.reduce(0) { $0 + $1.forward } / sampleCount
        let meanUp = groundSamples.reduce(0) { $0 + $1.up } / sampleCount
        var forwardVariance = 0.0
        var forwardUpCovariance = 0.0
        for groundSample in groundSamples {
            forwardVariance += (groundSample.forward - meanForward) * (groundSample.forward - meanForward)
            forwardUpCovariance += (groundSample.forward - meanForward) * (groundSample.up - meanUp)
        }
        guard forwardVariance > 1e-6 else { return nil }
        let slope = forwardUpCovariance / forwardVariance
        let intercept = meanUp - slope * meanForward
        let tiltRadians = atan(slope)
        // Ground is below the camera, and game cameras tilt down by up to
        // about 60°, rarely up.
        guard intercept < 0, tiltRadians > -10 * .pi / 180, tiltRadians < 60 * .pi / 180 else { return nil }
        let cameraHeightInSampleUnits = -intercept * cos(tiltRadians)
        guard cameraHeightInSampleUnits > 0.05 else { return nil }
        return (sin(tiltRadians), cos(tiltRadians), cameraHeight / cameraHeightInSampleUnits)
    }

    // MARK: - Places

    /// Names the spot Dottie is standing on (or just reached).
    /// Before she knows where she is on a saved map, the name waits and is
    /// placed where she stood once she finds out, instead of being lost.
    func notePlace(name: String) {
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmedName.isEmpty else { return }
        guard isLocalized else {
            placesWaitingForLocalizing.append((trimmedName, pose))
            return
        }
        addPlace(named: trimmedName, at: pose)
    }

    private func addPlace(named placeName: String, at placePose: Pose) {
        places.removeAll { $0.name.caseInsensitiveCompare(placeName) == .orderedSame }
        places.append(Place(name: placeName, x: placePose.x, y: placePose.y, notedAt: Date()))
        rememberLandmarkView(named: placeName, at: placePose)
        DottieGameNotebook.appendToPlayLog("Map: named a place \"\(placeName)\" at (\(String(format: "%.1f", placePose.x)), \(String(format: "%.1f", placePose.y))).", gameFolderURL: mapFolderURL.deletingLastPathComponent())
    }

    /// Names noted before she knew where she was, placed now that she does.
    /// The pose correction from the recognized spot is applied to them too.
    private func addPlacesWaitingForLocalizing(poseCorrectionX: Double, poseCorrectionY: Double) {
        for waitingPlace in placesWaitingForLocalizing {
            let correctedPose = Pose(x: waitingPlace.pose.x + poseCorrectionX, y: waitingPlace.pose.y + poseCorrectionY, headingDegrees: waitingPlace.pose.headingDegrees)
            addPlace(named: waitingPlace.name, at: correctedPose)
        }
        placesWaitingForLocalizing = []
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

    // MARK: - Blockers

    /// A walk got stuck against something about `distanceAhead` units in
    /// front of her that the map didn't show.
    func noteBlocker(distanceAhead: Double) {
        let headingRadians = pose.headingDegrees * .pi / 180
        let blockerX = pose.x + sin(headingRadians) * distanceAhead
        let blockerY = pose.y + cos(headingRadians) * distanceAhead
        let blockerCell = FloorCell(gridX: Int(floor(blockerX / Self.voxelSize)), gridY: Int(floor(blockerY / Self.voxelSize)))
        let now = Date()
        // Stuck here before, and that blocker had faded but the thing is
        // still there: it doesn't move.
        let wasBlockedHereBefore = fadingBlockers.contains { earlierBlocker in
            abs(earlierBlocker.cell.gridX - blockerCell.gridX) <= 1
                && abs(earlierBlocker.cell.gridY - blockerCell.gridY) <= 1
                && now.timeIntervalSince(earlierBlocker.notedAt) > Self.secondsForBlockerToFade
        }
        if wasBlockedHereBefore {
            // A body is about two cells wide.
            for offsetX in -1...1 {
                for offsetY in -1...1 {
                    learnedBlockedCells.insert(FloorCell(gridX: blockerCell.gridX + offsetX, gridY: blockerCell.gridY + offsetY))
                }
            }
        }
        fadingBlockers.append((blockerCell, now))
        // Keep only the recent past; older ones can't fade-check anything useful.
        fadingBlockers.removeAll { now.timeIntervalSince($0.notedAt) > 600 }
    }

    /// Cells routes must go around right now: learned fixed blockers and
    /// recent ones that haven't faded, each widened to a body's width.
    func currentBlockedCells() -> Set<FloorCell> {
        var blockedCells = learnedBlockedCells
        let now = Date()
        for fadingBlocker in fadingBlockers where now.timeIntervalSince(fadingBlocker.notedAt) <= Self.secondsForBlockerToFade {
            for offsetX in -1...1 {
                for offsetY in -1...1 {
                    blockedCells.insert(FloorCell(gridX: fadingBlocker.cell.gridX + offsetX, gridY: fadingBlocker.cell.gridY + offsetY))
                }
            }
        }
        return blockedCells
    }

    // MARK: - For the brain

    func summaryText() -> String {
        guard isFamiliar || !keyframes.isEmpty else {
            return "Map: this game is new to Dottie; she maps it as you play."
        }
        var lines = ["Map: \(keyframes.count) spots mapped over \(sessionCount) session(s). Positions are measured from spawn (0, 0), where she first started; she's at (\(String(format: "%.0f", pose.x)), \(String(format: "%.0f", pose.y))) now."]
        if !isLocalized {
            lines.append(spawnViews.isEmpty
                ? "Dottie hasn't recognized where you are yet; look around a known spot to find out."
                : "Dottie doesn't know where you are right now. To find out, look around, or head back to spawn (in many games respawning or a spawn or home button takes you there): the map snaps to 0,0,0 as soon as you see it.")
        }
        let landmarkLines = landmarkLinesForBrain()
        if !landmarkLines.isEmpty {
            lines.append("Landmarks Dottie knows on sight (positions from spawn):\n- " + landmarkLines.joined(separator: "\n- "))
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
        let summary = SavedSummary(
            keyframes: keyframes,
            places: places,
            nextKeyframeID: nextKeyframeID,
            sessionCount: sessionCount,
            learnedBlockedCells: learnedBlockedCells.map { [$0.gridX, $0.gridY] }
        )
        if let summaryData = try? encoder.encode(summary) {
            try? summaryData.write(to: mapFolderURL.appendingPathComponent("map.json"), options: .atomic)
        }
        Self.saveVoxels(voxelHits, to: mapFolderURL.appendingPathComponent("voxels.bin"))
        Self.saveDetailVoxels(hits: detailVoxelHits, colors: detailVoxelColors, to: mapFolderURL.appendingPathComponent("detail.bin"))
        surfaceMap.save()
        // A picture and a report the user can open to see the map working.
        DottieGameMapPicture.write(for: self)
    }

    /// The frame shrunk to the depth grid's size, one 0xRRGGBB color a
    /// sample, row 0 at the top like the depth.
    private static func colorGrid(of frame: CGImage, columnCount: Int, rowCount: Int) -> [UInt32]? {
        var pixelBytes = [UInt8](repeating: 0, count: columnCount * rowCount * 4)
        let didDraw = pixelBytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: columnCount,
                height: rowCount,
                bitsPerComponent: 8,
                bytesPerRow: columnCount * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(frame, in: CGRect(x: 0, y: 0, width: columnCount, height: rowCount))
            return true
        }
        guard didDraw else { return nil }
        // A bitmap context's memory starts at the top row.
        return (0..<(columnCount * rowCount)).map { sampleIndex in
            let byteOffset = sampleIndex * 4
            return UInt32(pixelBytes[byteOffset]) << 16 | UInt32(pixelBytes[byteOffset + 1]) << 8 | UInt32(pixelBytes[byteOffset + 2])
        }
    }

    /// The running average of a block's color.
    private static func blendedColor(_ earlierColor: UInt32, with newColor: UInt32, earlierSightings: Int) -> UInt32 {
        let earlierWeight = Double(min(earlierSightings, 20))
        func blendedChannel(_ shift: UInt32) -> UInt32 {
            let earlierChannel = Double((earlierColor >> shift) & 0xFF)
            let newChannel = Double((newColor >> shift) & 0xFF)
            return UInt32(((earlierChannel * earlierWeight + newChannel) / (earlierWeight + 1)).rounded()) << shift
        }
        return blendedChannel(16) | blendedChannel(8) | blendedChannel(0)
    }

    /// 13 bytes a fine block: the key, how many frames saw it, its color.
    private static func saveDetailVoxels(hits detailHits: [Int64: UInt16], colors detailColors: [Int64: UInt32], to fileURL: URL) {
        var detailData = Data(capacity: detailHits.count * 13)
        for (key, hits) in detailHits {
            withUnsafeBytes(of: key.littleEndian) { detailData.append(contentsOf: $0) }
            withUnsafeBytes(of: hits.littleEndian) { detailData.append(contentsOf: $0) }
            let color = detailColors[key] ?? 0x808080
            detailData.append(contentsOf: [UInt8((color >> 16) & 0xFF), UInt8((color >> 8) & 0xFF), UInt8(color & 0xFF)])
        }
        try? detailData.write(to: fileURL, options: .atomic)
    }

    private static func loadDetailVoxels(from fileURL: URL) -> (hits: [Int64: UInt16], colors: [Int64: UInt32]) {
        guard let detailData = try? Data(contentsOf: fileURL) else { return ([:], [:]) }
        let bytes = [UInt8](detailData)
        let blockCount = bytes.count / 13
        var detailHits: [Int64: UInt16] = [:]
        var detailColors: [Int64: UInt32] = [:]
        detailHits.reserveCapacity(blockCount)
        detailColors.reserveCapacity(blockCount)
        for blockIndex in 0..<blockCount {
            let offset = blockIndex * 13
            var key: UInt64 = 0
            for byteIndex in 0..<8 {
                key |= UInt64(bytes[offset + byteIndex]) << (8 * UInt64(byteIndex))
            }
            let signedKey = Int64(bitPattern: key)
            detailHits[signedKey] = UInt16(bytes[offset + 8]) | (UInt16(bytes[offset + 9]) << 8)
            detailColors[signedKey] = UInt32(bytes[offset + 10]) << 16 | UInt32(bytes[offset + 11]) << 8 | UInt32(bytes[offset + 12])
        }
        return (detailHits, detailColors)
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

    nonisolated static func voxelKey(gridX: Int, gridY: Int, gridZ: Int) -> Int64 {
        let axisOffset = 1 << 20
        let packedX = Int64(clamping: gridX + axisOffset) & 0x1F_FFFF
        let packedY = Int64(clamping: gridY + axisOffset) & 0x1F_FFFF
        let packedZ = Int64(clamping: gridZ + axisOffset) & 0x1F_FFFF
        return (packedX << 42) | (packedY << 21) | packedZ
    }

    nonisolated static func gridPosition(ofVoxelKey key: Int64) -> (gridX: Int, gridY: Int, gridZ: Int) {
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

    /// The print of the frame's recognition view, made off the main thread.
    private static func featurePrintOffMain(of frame: CGImage) async -> VNFeaturePrintObservation? {
        let printData: Data? = await Task.detached(priority: .utility) { () -> Data? in
            guard let viewImage = recognitionView(of: frame) else { return nil }
            let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
            let requestHandler = VNImageRequestHandler(cgImage: viewImage, options: [:])
            try? requestHandler.perform([featurePrintRequest])
            guard let featurePrint = featurePrintRequest.results?.first else { return nil }
            // Archived to cross back to the main actor as plain data.
            return try? NSKeyedArchiver.archivedData(withRootObject: featurePrint, requiringSecureCoding: true)
        }.value
        guard let printData else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: printData)
    }

    /// What's compared to recognize a spot: the view at the size of the
    /// saved spot pictures (320 points wide), without the top and bottom
    /// strips where the HUD (money, chat, buttons) changes between visits.
    /// Live frames and saved pictures go through the same steps, so their
    /// prints compare fairly.
    nonisolated private static func recognitionView(of image: CGImage) -> CGImage? {
        let scale = min(1, 320 / Double(max(image.width, image.height)))
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
        guard let scaledImage = context.makeImage() else { return nil }
        // Rows 10% to 88% from the top, as in addPoints.
        let keptRect = CGRect(x: 0, y: Int(Double(height) * 0.1), width: width, height: Int(Double(height) * 0.78))
        return scaledImage.cropping(to: keptRect)
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
