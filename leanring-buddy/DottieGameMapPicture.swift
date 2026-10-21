//
//  DottieGameMapPicture.swift
//  leanring-buddy
//
//  Makes each game's 3D map something the user can look at and manage:
//
//  - Every time a map is saved, it's drawn from above as overview.png in
//    its map folder: floor, walls, low things to jump, drops, blockers,
//    the spots Dottie photographed, named places, and where she stands.
//    report.txt next to it says in plain words what was mapped, whether
//    the depth model works and what the movement model has learned, so
//    it's easy to tell whether the map is working. map3d.obj (with
//    map3d.mtl for its colors) is the same map as blocks in 3D, which
//    Preview, Quick Look, Blender or MeshLab can open and turn around.
//  - Listing, opening and deleting maps (the menu bar panel's "Game maps"
//    button and the `game_maps` voice tool). Deleting removes only the map
//    and the movement model; the notebook and gameplay recordings stay.
//

import AppKit
import Foundation

@MainActor
enum DottieGameMapPicture {
    static let pictureFileName = "overview.png"
    static let reportFileName = "report.txt"
    static let modelFileName = "map3d.obj"
    private static let modelMaterialsFileName = "map3d.mtl"
    /// The most-seen blocks only, so the file stays small enough to open.
    private static let maximumModelBlockCount = 30_000

    struct SavedMap {
        let gameName: String
        let gameFolderURL: URL
        let spotCount: Int
        let lastSavedAt: Date?

        var mapFolderURL: URL { gameFolderURL.appendingPathComponent("map", isDirectory: true) }
    }

    // MARK: - Picture and report

    static func write(for worldMap: DottieGameWorldMap) {
        let floorPlan = DottieGameNavigator.floorPlan(of: worldMap)
        if let pictureData = picture(of: worldMap, floorPlan: floorPlan) {
            try? pictureData.write(to: worldMap.mapFolderURL.appendingPathComponent(pictureFileName), options: .atomic)
        }
        try? reportText(of: worldMap, floorPlan: floorPlan)
            .write(to: worldMap.mapFolderURL.appendingPathComponent(reportFileName), atomically: true, encoding: .utf8)
        write3DModel(of: worldMap)
    }

    // MARK: - 3D model

    /// Writes the map as colored blocks in a Wavefront OBJ file: grey
    /// floor, white walls (amber when low enough to jump), blue below the
    /// floor, a cyan post at each photographed spot and a pink one where
    /// Dottie stands. Built off the main thread, since a big map is a few
    /// megabytes of text.
    @discardableResult
    private static func write3DModel(of worldMap: DottieGameWorldMap) -> Task<Void, Never> {
        let jumpHeightGridRows = Int(ceil(worldMap.movement.jumpHeightUnits / DottieGameWorldMap.voxelSize))
        let strongestVoxels = worldMap.voxelHits
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(maximumModelBlockCount)
            .map { DottieGameWorldMap.gridPosition(ofVoxelKey: $0.key) }
        let spotPositions = worldMap.keyframes.map { (x: $0.x, y: $0.y) }
        let dottiePosition = (x: worldMap.pose.x, y: worldMap.pose.y)
        let modelURL = worldMap.mapFolderURL.appendingPathComponent(modelFileName)
        let materialsURL = worldMap.mapFolderURL.appendingPathComponent(modelMaterialsFileName)
        let voxelSize = DottieGameWorldMap.voxelSize
        let materialsFileName = modelMaterialsFileName
        return Task.detached(priority: .utility) {
            let materialsText = """
            newmtl floor
            Kd 0.55 0.55 0.58
            newmtl wall
            Kd 0.95 0.95 0.95
            newmtl low
            Kd 0.98 0.68 0.15
            newmtl below
            Kd 0.25 0.5 0.95
            newmtl spot
            Kd 0.2 0.85 0.95
            newmtl dottie
            Kd 0.98 0.35 0.7

            """
            var modelLines = ["# Dottie's 3D map. Up is the height; one block is half a step.", "mtllib \(materialsFileName)"]
            var vertexCount = 0
            // One box: 8 corners, 6 square faces. OBJ is y-up, so the map's
            // height becomes y and its forward direction becomes -z.
            func addBox(minX: Double, minY: Double, minHeight: Double, width: Double, depth: Double, height: Double) {
                for corner in 0..<8 {
                    let cornerX = minX + (corner & 1 == 0 ? 0 : width)
                    let cornerY = minY + (corner & 2 == 0 ? 0 : depth)
                    let cornerHeight = minHeight + (corner & 4 == 0 ? 0 : height)
                    modelLines.append("v \(cornerX) \(cornerHeight) \(-cornerY)")
                }
                let first = vertexCount + 1
                for face in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]] {
                    modelLines.append("f " + face.map { String(first + $0) }.joined(separator: " "))
                }
                vertexCount += 8
            }
            var voxelsByMaterial: [String: [(gridX: Int, gridY: Int, gridZ: Int)]] = [:]
            for voxel in strongestVoxels {
                let material: String
                if voxel.gridZ < -1 {
                    material = "below"
                } else if voxel.gridZ <= 0 {
                    material = "floor"
                } else if voxel.gridZ <= jumpHeightGridRows {
                    material = "low"
                } else {
                    material = "wall"
                }
                voxelsByMaterial[material, default: []].append(voxel)
            }
            for (material, voxels) in voxelsByMaterial {
                modelLines.append("usemtl \(material)")
                for voxel in voxels {
                    addBox(minX: Double(voxel.gridX) * voxelSize, minY: Double(voxel.gridY) * voxelSize, minHeight: Double(voxel.gridZ) * voxelSize, width: voxelSize, depth: voxelSize, height: voxelSize)
                }
            }
            modelLines.append("usemtl spot")
            for spotPosition in spotPositions {
                addBox(minX: spotPosition.x - 0.1, minY: spotPosition.y - 0.1, minHeight: 0, width: 0.2, depth: 0.2, height: 2)
            }
            modelLines.append("usemtl dottie")
            addBox(minX: dottiePosition.x - 0.25, minY: dottiePosition.y - 0.25, minHeight: 0, width: 0.5, depth: 0.5, height: 3)
            try? materialsText.write(to: materialsURL, atomically: true, encoding: .utf8)
            try? (modelLines.joined(separator: "\n") + "\n").write(to: modelURL, atomically: true, encoding: .utf8)
        }
    }

    private static func picture(of worldMap: DottieGameWorldMap, floorPlan: DottieGameNavigator.FloorPlan) -> Data? {
        let voxelSize = DottieGameWorldMap.voxelSize
        // Everything to fit in the picture, in grid cells.
        var gridXValues: [Int] = []
        var gridYValues: [Int] = []
        func includeGridPoint(gridX: Int, gridY: Int) {
            gridXValues.append(gridX)
            gridYValues.append(gridY)
        }
        func includeMapPoint(x: Double, y: Double) {
            includeGridPoint(gridX: Int(floor(x / voxelSize)), gridY: Int(floor(y / voxelSize)))
        }
        for cell in floorPlan.floorCells.union(floorPlan.blockedCells).union(floorPlan.dropCells).union(floorPlan.lowObstacleHeights.keys) {
            includeGridPoint(gridX: cell.gridX, gridY: cell.gridY)
        }
        for keyframe in worldMap.keyframes {
            includeMapPoint(x: keyframe.x, y: keyframe.y)
        }
        for place in worldMap.places {
            includeMapPoint(x: place.x, y: place.y)
        }
        includeMapPoint(x: worldMap.pose.x, y: worldMap.pose.y)

        let paddingCells = 6
        let minimumGridX = (gridXValues.min() ?? 0) - paddingCells
        let maximumGridX = (gridXValues.max() ?? 0) + paddingCells
        let minimumGridY = (gridYValues.min() ?? 0) - paddingCells
        let maximumGridY = (gridYValues.max() ?? 0) + paddingCells
        let widthInCells = maximumGridX - minimumGridX + 1
        let heightInCells = maximumGridY - minimumGridY + 1
        let pixelsPerCell = min(8.0, 1000.0 / Double(max(widthInCells, heightInCells)))
        let titleHeight = 44.0
        let legendHeight = 34.0
        let pictureWidth = max(Int(Double(widthInCells) * pixelsPerCell), 640)
        let pictureHeight = Int(Double(heightInCells) * pixelsPerCell + titleHeight + legendHeight)

        guard let context = CGContext(
            data: nil,
            width: pictureWidth,
            height: pictureHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // The map's +y (Dottie's first starting direction) points up.
        let mapOriginX = (Double(pictureWidth) - Double(widthInCells) * pixelsPerCell) / 2
        func pixelPoint(x: Double, y: Double) -> CGPoint {
            CGPoint(
                x: mapOriginX + (x / voxelSize - Double(minimumGridX)) * pixelsPerCell,
                y: legendHeight + (y / voxelSize - Double(minimumGridY)) * pixelsPerCell
            )
        }
        func fillCell(_ cell: DottieGameNavigator.GridPoint, color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(
                x: mapOriginX + Double(cell.gridX - minimumGridX) * pixelsPerCell,
                y: legendHeight + Double(cell.gridY - minimumGridY) * pixelsPerCell,
                width: max(pixelsPerCell, 1),
                height: max(pixelsPerCell, 1)
            ))
        }

        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pictureWidth, height: pictureHeight))

        let floorColor = CGColor(red: 0.32, green: 0.33, blue: 0.36, alpha: 1)
        let wallColor = CGColor(red: 0.88, green: 0.88, blue: 0.9, alpha: 1)
        let lowObstacleColor = CGColor(red: 0.95, green: 0.7, blue: 0.2, alpha: 1)
        let dropColor = CGColor(red: 0.15, green: 0.3, blue: 0.75, alpha: 1)
        let blockerColor = CGColor(red: 0.9, green: 0.25, blue: 0.25, alpha: 1)
        let spotColor = CGColor(red: 0.3, green: 0.85, blue: 0.95, alpha: 1)
        let placeColor = CGColor(red: 0.35, green: 0.9, blue: 0.45, alpha: 1)
        let dottieColor = CGColor(red: 1, green: 0.4, blue: 0.8, alpha: 1)

        for cell in floorPlan.floorCells { fillCell(cell, color: floorColor) }
        for cell in floorPlan.dropCells { fillCell(cell, color: dropColor) }
        for cell in floorPlan.lowObstacleHeights.keys { fillCell(cell, color: lowObstacleColor) }
        for cell in floorPlan.blockedCells { fillCell(cell, color: wallColor) }
        for cell in worldMap.learnedBlockedCells { fillCell(cell, color: blockerColor) }

        // Each photographed spot, with a short line the way it faced.
        let spotRadius = max(1.5, min(3, pixelsPerCell / 2))
        context.setStrokeColor(spotColor)
        context.setLineWidth(1)
        for keyframe in worldMap.keyframes {
            let spotPoint = pixelPoint(x: keyframe.x, y: keyframe.y)
            let headingRadians = keyframe.headingDegrees * .pi / 180
            let tickLength = max(5, pixelsPerCell * 2)
            context.move(to: spotPoint)
            context.addLine(to: CGPoint(x: spotPoint.x + sin(headingRadians) * tickLength, y: spotPoint.y + cos(headingRadians) * tickLength))
            context.strokePath()
            context.setFillColor(spotColor)
            context.fillEllipse(in: CGRect(x: spotPoint.x - spotRadius, y: spotPoint.y - spotRadius, width: spotRadius * 2, height: spotRadius * 2))
        }

        // Dottie: an arrow the way the camera faces.
        let dottiePoint = pixelPoint(x: worldMap.pose.x, y: worldMap.pose.y)
        let dottieHeadingRadians = worldMap.pose.headingDegrees * .pi / 180
        let arrowLength = 12.0
        let arrowTip = CGPoint(x: dottiePoint.x + sin(dottieHeadingRadians) * arrowLength, y: dottiePoint.y + cos(dottieHeadingRadians) * arrowLength)
        let arrowLeft = CGPoint(x: dottiePoint.x + sin(dottieHeadingRadians - 2.5) * arrowLength * 0.6, y: dottiePoint.y + cos(dottieHeadingRadians - 2.5) * arrowLength * 0.6)
        let arrowRight = CGPoint(x: dottiePoint.x + sin(dottieHeadingRadians + 2.5) * arrowLength * 0.6, y: dottiePoint.y + cos(dottieHeadingRadians + 2.5) * arrowLength * 0.6)
        context.setFillColor(dottieColor)
        context.move(to: arrowTip)
        context.addLine(to: arrowLeft)
        context.addLine(to: arrowRight)
        context.closePath()
        context.fillPath()

        // Labels need an AppKit drawing context on top of the bitmap.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(cgColor: placeColor) ?? NSColor.green
        ]
        for place in worldMap.places {
            let placePoint = pixelPoint(x: place.x, y: place.y)
            context.setFillColor(placeColor)
            context.fillEllipse(in: CGRect(x: placePoint.x - 4, y: placePoint.y - 4, width: 8, height: 8))
            NSString(string: place.name).draw(at: CGPoint(x: placePoint.x + 6, y: placePoint.y - 6), withAttributes: labelAttributes)
        }
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(white: 0.75, alpha: 1)
        ]
        NSString(string: "\(worldMap.gameName): \(worldMap.keyframes.count) spots, \(worldMap.places.count) places, \(worldMap.voxelHits.count.formatted()) 3D points")
            .draw(at: CGPoint(x: 12, y: Double(pictureHeight) - 24), withAttributes: titleAttributes)
        NSString(string: "Seen from above. Up is the way Dottie faced when she first started. One square is half a step.")
            .draw(at: CGPoint(x: 12, y: Double(pictureHeight) - 40), withAttributes: subtitleAttributes)
        NSString(string: "grey floor · white wall · amber low thing (jump) · blue drop · red blocker · cyan photographed spot · green named place · pink arrow Dottie")
            .draw(at: CGPoint(x: 12, y: 11), withAttributes: subtitleAttributes)
        NSGraphicsContext.restoreGraphicsState()

        guard let pictureImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: pictureImage).representation(using: .png, properties: [:])
    }

    private static func reportText(of worldMap: DottieGameWorldMap, floorPlan: DottieGameNavigator.FloorPlan) -> String {
        let movementContents = worldMap.movement.contents
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        var lines = [
            "Dottie's map of \(worldMap.gameName)",
            "Saved \(dateFormatter.string(from: Date()))",
            "",
            "Sessions played with this map: \(worldMap.sessionCount)",
            "This session: \(worldMap.keyframesAddedThisSession) new spots photographed, \(worldMap.recognitionsThisSession) times she recognized a spot she knew, \(worldMap.framesWithDepthThisSession) frames turned into 3D.",
            "Spots photographed in total: \(worldMap.keyframes.count) (a spot is never photographed twice)",
            "3D points: \(worldMap.voxelHits.count.formatted())",
            "From above: \(floorPlan.floorCells.count) floor squares, \(floorPlan.blockedCells.count) wall squares, \(floorPlan.lowObstacleHeights.count) low squares to jump, \(floorPlan.dropCells.count) drop squares, \(worldMap.learnedBlockedCells.count) blocker squares she walked into",
            "Knows where she is right now: \(worldMap.isLocalized ? "yes" : "no, still looking for a spot she knows")",
            "Depth model: \(DottieGameDepth.shared.statusText)",
            "",
            "Movement she has learned for this game:",
            "- Camera: \(String(format: "%.2f", movementContents.degreesPerMousePoint))° per mouse point (measured \(movementContents.cameraTurnMeasurementCount) times)",
            "- Walking: \(String(format: "%.2f", movementContents.walkUnitsPerSecond)) units a second (corrected \(movementContents.walkSpeedCorrectionCount) times), sprinting \(String(format: "%.1f", movementContents.sprintSpeedFactor))x",
            "- Jumping: \(String(format: "%.1f", movementContents.jumpHeightUnits)) units high, \(String(format: "%.1f", movementContents.jumpDistanceUnits)) far (from \(movementContents.jumpAttemptCount) jumps)",
            ""
        ]
        if worldMap.places.isEmpty {
            lines.append("Named places: none yet.")
        } else {
            lines.append("Named places:")
            for place in worldMap.places {
                lines.append("- \(place.name) at (\(String(format: "%.1f", place.x)), \(String(format: "%.1f", place.y)))")
            }
        }
        // Checks worked out from this map, not fixed text.
        lines += ["", "Is it working?"]
        lines.append(worldMap.voxelHits.isEmpty
            ? "- No 3D points: the depth model isn't working, so the map only has photographed spots (see Depth model above)."
            : "- 3D: yes, the depth model has turned frames into \(worldMap.voxelHits.count.formatted()) points.")
        let facingDirections = Set(worldMap.keyframes.map { Int((($0.headingDegrees + 360).truncatingRemainder(dividingBy: 360)) / 45) })
        lines.append(facingDirections.count < 4
            ? "- Directions: her spots face only \(facingDirections.count) of 8 directions, so the map covers little more than the way she walked. Turning around fills it in."
            : "- Directions: her spots face \(facingDirections.count) of 8 directions.")
        let mappedSquareCount = floorPlan.floorCells.count + floorPlan.blockedCells.count
        if mappedSquareCount > 20, floorPlan.blockedCells.count > floorPlan.floorCells.count * 3 {
            lines.append("- Floor: most squares read as wall, which is unusual for an open area. The floor finding may be off for this game's camera.")
        }
        if worldMap.sessionCount > 1 {
            lines.append(worldMap.recognitionsThisSession == 0
                ? "- Recognizing: she hasn't recognized a spot she knew this session yet, so she may map places again."
                : "- Recognizing: yes, \(worldMap.recognitionsThisSession) times this session.")
        }
        if movementContents.walkSpeedCorrectionCount == 0 {
            lines.append("- Distances: walking speed hasn't been corrected yet (she corrects it on coming back to a known spot), so distances are guesses.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Managing maps

    /// Every game with a saved map, newest first.
    static func savedMaps() -> [SavedMap] {
        struct SavedName: Decodable {
            let gameName: String
        }
        let gameFolderURLs = (try? FileManager.default.contentsOfDirectory(at: DottieGameNotebook.gamesFolderURL, includingPropertiesForKeys: nil)) ?? []
        let maps = gameFolderURLs.compactMap { gameFolderURL -> SavedMap? in
            let mapSummaryURL = gameFolderURL.appendingPathComponent("map/map.json")
            guard let mapSummaryData = try? Data(contentsOf: mapSummaryURL) else { return nil }
            let mapSummary = (try? JSONSerialization.jsonObject(with: mapSummaryData)) as? [String: Any]
            let spotCount = (mapSummary?["keyframes"] as? [Any])?.count ?? 0
            let notebookData = try? Data(contentsOf: gameFolderURL.appendingPathComponent("notebook.json"))
            let gameName = notebookData.flatMap { try? JSONDecoder().decode(SavedName.self, from: $0) }?.gameName ?? gameFolderURL.lastPathComponent
            let lastSavedAt = (try? FileManager.default.attributesOfItem(atPath: mapSummaryURL.path))?[.modificationDate] as? Date
            return SavedMap(gameName: gameName, gameFolderURL: gameFolderURL, spotCount: spotCount, lastSavedAt: lastSavedAt)
        }
        return maps.sorted { ($0.lastSavedAt ?? .distantPast) > ($1.lastSavedAt ?? .distantPast) }
    }

    /// The saved map whose game name best matches what the user said.
    static func savedMap(named spokenName: String) -> SavedMap? {
        let lowercasedSpokenName = spokenName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowercasedSpokenName.isEmpty else { return nil }
        let maps = savedMaps()
        return maps.first { $0.gameName.lowercased() == lowercasedSpokenName }
            ?? maps.first { $0.gameName.lowercased().contains(lowercasedSpokenName) || lowercasedSpokenName.contains($0.gameName.lowercased()) }
            ?? maps.first { $0.gameFolderURL.lastPathComponent == DottieGameNotebook.folderName(for: spokenName) }
    }

    /// Opens a game's map folder (its picture and report) in Finder, or
    /// the folder with every game when none is given.
    static func openInFinder(_ savedMap: SavedMap?) {
        if let savedMap {
            let pictureURL = savedMap.mapFolderURL.appendingPathComponent(pictureFileName)
            if FileManager.default.fileExists(atPath: pictureURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([pictureURL])
            } else {
                NSWorkspace.shared.open(savedMap.mapFolderURL)
            }
            return
        }
        try? FileManager.default.createDirectory(at: DottieGameNotebook.gamesFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(DottieGameNotebook.gamesFolderURL)
    }

    /// Removes a game's map and movement model so the game is mapped from
    /// scratch next time. The notebook and gameplay recordings stay.
    /// Opens map3d.obj in the Mac's app for 3D models (Preview unless the
    /// user picked another), writing it first for a map saved before 3D
    /// models were. False when it couldn't be made.
    static func open3DModel(_ savedMap: SavedMap) async -> Bool {
        let modelURL = savedMap.mapFolderURL.appendingPathComponent(modelFileName)
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            let worldMap = DottieGameWorldMap(gameName: savedMap.gameName, gameFolderURL: savedMap.gameFolderURL)
            await write3DModel(of: worldMap).value
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }
        return NSWorkspace.shared.open(modelURL)
    }

    static func deleteMap(_ savedMap: SavedMap) -> Bool {
        do {
            try FileManager.default.removeItem(at: savedMap.mapFolderURL)
        } catch {
            print("⚠️ Couldn't delete the map of \(savedMap.gameName): \(error.localizedDescription)")
            return false
        }
        try? FileManager.default.removeItem(at: savedMap.gameFolderURL.appendingPathComponent("movement.json"))
        return true
    }
}
