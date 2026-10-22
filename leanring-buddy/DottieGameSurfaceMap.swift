//
//  DottieGameSurfaceMap.swift
//  leanring-buddy
//
//  The game world as solid surfaces, so a shop on the map looks like a
//  shop from any side, the way 3D scanning apps build a model:
//
//  - Each depth sample is a ray from where Dottie stands to the surface it
//    hit. Small cells (`cellSize`) along the ray just before and after the
//    hit store how far they are from that surface (in front positive,
//    behind negative), averaged over every look, so every new view
//    sharpens the shape and one-off noise averages away. Cells near the
//    surface also keep the color they were seen with.
//  - Turning that into a model finds where the stored distance crosses
//    zero (surface nets): one point inside each cell the surface passes
//    through, joined into a mesh of four-sided faces, each point colored
//    like the game there.
//  - The model is written as map3d-surface.usdz (Preview and Quick Look
//    open it and let the user spin it) and map3d-surface.obj with vertex
//    colors (Blender, MeshLab).
//
//  Positions are on the same map as DottieGameWorldMap, measured from
//  spawn; heights from the floor. Kept in map/surface.bin.
//

import Foundation
import ModelIO

@MainActor
final class DottieGameSurfaceMap {
    /// One cell: its average distance to the nearest surface (as a share
    /// of `truncationDistance`, -1…1), how many looks that average is
    /// over, and its color (0xRRGGBB).
    struct Cell {
        var signedDistance: Float
        var weight: UInt8
        var color: UInt32
    }

    /// Depth rays from a few dozen frames are too far apart for smaller
    /// cells: 0.1 left most cells seen only once and the model full of holes.
    static let cellSize = 0.2
    /// How far before and behind a hit the surface is written.
    private static let truncationDistance = 0.5
    /// Fewer faces than this is scattered dots, not a model worth opening.
    private static let minimumFaceCount = 300
    /// Older looks stop counting more than this, so the surface can follow
    /// a game world that changes (a door opening).
    private static let maximumWeight: UInt8 = 40
    /// About 50 MB in memory at the most.
    private static let maximumCellCount = 2_500_000
    /// Rays longer than this are too rough for small cells.
    private static let maximumRayLength = 12.0

    static let modelFileName = "map3d-surface.usdz"
    /// Written instead when this Mac's Model I/O can't write USDZ (1.0.34
    /// left none on celly's Mac); Preview opens it the same way.
    static let fallbackModelFileName = "map3d-surface.usdc"
    static let plainModelFileName = "map3d-surface.obj"

    private(set) var cells: [Int64: Cell] = [:]
    private let fileURL: URL

    init(mapFolderURL: URL) {
        fileURL = mapFolderURL.appendingPathComponent("surface-v2.bin")
        // surface.bin held 0.1-unit cells, which don't fit the new size.
        try? FileManager.default.removeItem(at: mapFolderURL.appendingPathComponent("surface.bin"))
        cells = Self.loadCells(from: fileURL)
    }

    // MARK: - Adding a look

    /// Writes one frame's rays: from the camera at (cameraX, cameraY,
    /// cameraHeight) to each hit point, with the color seen there.
    func addRays(cameraX: Double, cameraY: Double, cameraHeight: Double, hits: [(x: Double, y: Double, z: Double, color: UInt32?)]) {
        let truncation = Self.truncationDistance
        let cellSize = Self.cellSize
        for hit in hits {
            let rayX = hit.x - cameraX
            let rayY = hit.y - cameraY
            let rayZ = hit.z - cameraHeight
            let rayLength = (rayX * rayX + rayY * rayY + rayZ * rayZ).squareRoot()
            guard rayLength > 0.3, rayLength < Self.maximumRayLength else { continue }
            let directionX = rayX / rayLength
            let directionY = rayY / rayLength
            let directionZ = rayZ / rayLength
            var distanceAlongRay = max(0, rayLength - truncation)
            while distanceAlongRay <= rayLength + truncation {
                let pointX = cameraX + directionX * distanceAlongRay
                let pointY = cameraY + directionY * distanceAlongRay
                let pointZ = cameraHeight + directionZ * distanceAlongRay
                let cellKey = DottieGameWorldMap.voxelKey(
                    gridX: Int((pointX / cellSize).rounded(.down)),
                    gridY: Int((pointY / cellSize).rounded(.down)),
                    gridZ: Int((pointZ / cellSize).rounded(.down))
                )
                // In front of the surface is positive, behind it negative.
                let signedDistance = Float((rayLength - distanceAlongRay) / truncation)
                let isAtSurface = abs(rayLength - distanceAlongRay) < cellSize
                if var cell = cells[cellKey] {
                    let earlierWeight = Float(cell.weight)
                    cell.signedDistance = (cell.signedDistance * earlierWeight + signedDistance) / (earlierWeight + 1)
                    if isAtSurface, let hitColor = hit.color {
                        cell.color = Self.blendedColor(cell.color, with: hitColor, earlierWeight: earlierWeight)
                    }
                    cell.weight = min(cell.weight + 1, Self.maximumWeight)
                    cells[cellKey] = cell
                } else if cells.count < Self.maximumCellCount {
                    cells[cellKey] = Cell(signedDistance: signedDistance, weight: 1, color: hit.color ?? 0x808080)
                }
                distanceAlongRay += cellSize
            }
        }
    }

    private static func blendedColor(_ earlierColor: UInt32, with newColor: UInt32, earlierWeight: Float) -> UInt32 {
        func blendedChannel(_ shift: UInt32) -> UInt32 {
            let earlierChannel = Float((earlierColor >> shift) & 0xFF)
            let newChannel = Float((newColor >> shift) & 0xFF)
            return UInt32(((earlierChannel * earlierWeight + newChannel) / (earlierWeight + 1)).rounded()) << shift
        }
        return blendedChannel(16) | blendedChannel(8) | blendedChannel(0)
    }

    // MARK: - Making the model

    /// Builds the mesh off the main thread and writes the model files into
    /// `mapFolderURL`. Returns once they're written.
    @discardableResult
    func writeModel(into mapFolderURL: URL) -> Task<Void, Never> {
        let cellsSnapshot = cells
        let usdzURL = mapFolderURL.appendingPathComponent(Self.modelFileName)
        let usdcURL = mapFolderURL.appendingPathComponent(Self.fallbackModelFileName)
        let objURL = mapFolderURL.appendingPathComponent(Self.plainModelFileName)
        return Task.detached(priority: .utility) {
            let mesh = Self.surfaceMesh(from: cellsSnapshot)
            guard mesh.quads.count >= Self.minimumFaceCount else {
                // An older, better-looking model isn't there to replace, so
                // opening the map falls back to the colored blocks.
                try? FileManager.default.removeItem(at: usdzURL)
                try? FileManager.default.removeItem(at: usdcURL)
                try? FileManager.default.removeItem(at: objURL)
                return
            }
            Self.writeObj(mesh, to: objURL)
            try? FileManager.default.removeItem(at: usdzURL)
            try? FileManager.default.removeItem(at: usdcURL)
            if !Self.writeUSD(mesh, to: usdzURL) {
                Self.writeUSD(mesh, to: usdcURL)
            }
        }
    }

    private struct SurfaceMesh {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        var quads: [(Int32, Int32, Int32, Int32)] = []
    }

    /// Surface nets: a point in every cube of cells the surface crosses,
    /// placed at the average of where it crosses the cube's edges, and a
    /// face for every cell edge the surface crosses, joining the points of
    /// the four cubes around that edge. Cubes are named by their lowest
    /// corner cell. A cube with some corners never seen still gets a point
    /// from the edges between the corners that were.
    nonisolated private static func surfaceMesh(from cells: [Int64: Cell]) -> SurfaceMesh {
        let cellSize = Float(Self.cellSize)
        func cell(_ gridX: Int, _ gridY: Int, _ gridZ: Int) -> Cell? {
            cells[DottieGameWorldMap.voxelKey(gridX: gridX, gridY: gridY, gridZ: gridZ)]
        }
        let cornerOffsets: [(Int, Int, Int)] = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)]
        let cubeEdges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]

        // Every cube that has at least one seen cell as a corner, so a cube
        // whose lowest corner was never seen still gets its point.
        var candidateCubeKeys = Set<Int64>()
        candidateCubeKeys.reserveCapacity(cells.count * 2)
        for cellKey in cells.keys {
            let cellPosition = DottieGameWorldMap.gridPosition(ofVoxelKey: cellKey)
            for offset in cornerOffsets {
                candidateCubeKeys.insert(DottieGameWorldMap.voxelKey(
                    gridX: cellPosition.gridX - offset.0,
                    gridY: cellPosition.gridY - offset.1,
                    gridZ: cellPosition.gridZ - offset.2
                ))
            }
        }

        var mesh = SurfaceMesh()
        var pointIndexByCube: [Int64: Int32] = [:]
        for cellKey in candidateCubeKeys {
            let cubeCorner = DottieGameWorldMap.gridPosition(ofVoxelKey: cellKey)
            let cornerCells: [Cell?] = cornerOffsets.map { offset in
                cell(cubeCorner.gridX + offset.0, cubeCorner.gridY + offset.1, cubeCorner.gridZ + offset.2)
            }
            var crossingSum = SIMD3<Float>(0, 0, 0)
            var crossingCount: Float = 0
            for edge in cubeEdges {
                guard let firstCornerCell = cornerCells[edge.0], let secondCornerCell = cornerCells[edge.1] else { continue }
                let firstDistance = firstCornerCell.signedDistance
                let secondDistance = secondCornerCell.signedDistance
                guard (firstDistance < 0) != (secondDistance < 0) else { continue }
                let crossingFraction = firstDistance / (firstDistance - secondDistance)
                let firstCorner = SIMD3<Float>(Float(cornerOffsets[edge.0].0), Float(cornerOffsets[edge.0].1), Float(cornerOffsets[edge.0].2))
                let secondCorner = SIMD3<Float>(Float(cornerOffsets[edge.1].0), Float(cornerOffsets[edge.1].1), Float(cornerOffsets[edge.1].2))
                crossingSum += firstCorner + (secondCorner - firstCorner) * crossingFraction
                crossingCount += 1
            }
            guard crossingCount > 0 else { continue }
            let pointInCube = crossingSum / crossingCount
            // Cell centers sit half a cell in from the cell's lowest corner.
            let mapPoint = (SIMD3<Float>(Float(cubeCorner.gridX), Float(cubeCorner.gridY), Float(cubeCorner.gridZ)) + pointInCube + 0.5) * cellSize
            pointIndexByCube[cellKey] = Int32(mesh.positions.count)
            // OBJ and USD are y-up: the map's height becomes y and its
            // forward direction -z.
            mesh.positions.append(SIMD3<Float>(mapPoint.x, mapPoint.z, -mapPoint.y))
            let nearestColor = cornerCells.compactMap { $0 }.min { abs($0.signedDistance) < abs($1.signedDistance) }?.color ?? 0x808080
            mesh.colors.append(SIMD3<Float>(
                Float((nearestColor >> 16) & 0xFF) / 255,
                Float((nearestColor >> 8) & 0xFF) / 255,
                Float(nearestColor & 0xFF) / 255
            ))
        }

        // A face for each crossed edge from a cell to its +x, +y or +z
        // neighbor, joining the four cubes that share that edge.
        let edgeDirections: [(step: (Int, Int, Int), sideA: (Int, Int, Int), sideB: (Int, Int, Int))] = [
            ((1, 0, 0), (0, 1, 0), (0, 0, 1)),
            ((0, 1, 0), (0, 0, 1), (1, 0, 0)),
            ((0, 0, 1), (1, 0, 0), (0, 1, 0))
        ]
        for cellKey in cells.keys {
            let gridPosition = DottieGameWorldMap.gridPosition(ofVoxelKey: cellKey)
            guard let startCell = cell(gridPosition.gridX, gridPosition.gridY, gridPosition.gridZ) else { continue }
            for direction in edgeDirections {
                guard let endCell = cell(gridPosition.gridX + direction.step.0, gridPosition.gridY + direction.step.1, gridPosition.gridZ + direction.step.2),
                      (startCell.signedDistance < 0) != (endCell.signedDistance < 0) else { continue }
                func cubeKey(minusA: Int, minusB: Int) -> Int64 {
                    DottieGameWorldMap.voxelKey(
                        gridX: gridPosition.gridX - minusA * direction.sideA.0 - minusB * direction.sideB.0,
                        gridY: gridPosition.gridY - minusA * direction.sideA.1 - minusB * direction.sideB.1,
                        gridZ: gridPosition.gridZ - minusA * direction.sideA.2 - minusB * direction.sideB.2
                    )
                }
                guard let firstPoint = pointIndexByCube[cubeKey(minusA: 0, minusB: 0)],
                      let secondPoint = pointIndexByCube[cubeKey(minusA: 1, minusB: 0)],
                      let thirdPoint = pointIndexByCube[cubeKey(minusA: 1, minusB: 1)],
                      let fourthPoint = pointIndexByCube[cubeKey(minusA: 0, minusB: 1)] else { continue }
                // Face outward, toward the side in front of the surface.
                if startCell.signedDistance > 0 {
                    mesh.quads.append((firstPoint, fourthPoint, thirdPoint, secondPoint))
                } else {
                    mesh.quads.append((firstPoint, secondPoint, thirdPoint, fourthPoint))
                }
            }
        }
        return mesh
    }

    nonisolated private static func writeObj(_ mesh: SurfaceMesh, to fileURL: URL) {
        var lines = ["# Dottie's 3D map as surfaces, measured from spawn (0,0,0). Each point has its color after it (r g b)."]
        lines.reserveCapacity(mesh.positions.count + mesh.quads.count + 1)
        for (position, color) in zip(mesh.positions, mesh.colors) {
            lines.append("v \(position.x) \(position.y) \(position.z) \(color.x) \(color.y) \(color.z)")
        }
        for quad in mesh.quads {
            // OBJ counts points from 1.
            lines.append("f \(quad.0 + 1) \(quad.1 + 1) \(quad.2 + 1) \(quad.3 + 1)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// The same mesh as USD (the file's extension picks USDZ or USDC)
    /// through Model I/O, with the colors per point, in triangles. False
    /// when nothing was written.
    @discardableResult
    nonisolated private static func writeUSD(_ mesh: SurfaceMesh, to fileURL: URL) -> Bool {
        guard MDLAsset.canExportFileExtension(fileURL.pathExtension) else { return false }
        var triangleIndices: [UInt32] = []
        triangleIndices.reserveCapacity(mesh.quads.count * 6)
        for quad in mesh.quads {
            triangleIndices += [UInt32(quad.0), UInt32(quad.1), UInt32(quad.2), UInt32(quad.0), UInt32(quad.2), UInt32(quad.3)]
        }
        let positionData = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorData = mesh.colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let indexData = triangleIndices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeColor, format: .float3, offset: 0, bufferIndex: 1)
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
        vertexDescriptor.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
        let allocator = MDLMeshBufferDataAllocator()
        let submesh = MDLSubmesh(
            indexBuffer: allocator.newBuffer(with: indexData, type: .index),
            indexCount: triangleIndices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )
        let surfaceMesh = MDLMesh(
            vertexBuffers: [allocator.newBuffer(with: positionData, type: .vertex), allocator.newBuffer(with: colorData, type: .vertex)],
            vertexCount: mesh.positions.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )
        surfaceMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
        let asset = MDLAsset()
        asset.add(surfaceMesh)
        do {
            try asset.export(to: fileURL)
        } catch {
            print("⚠️ Couldn't write \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Saving

    /// 13 bytes a cell: the key, the distance (-127…127), the weight, the
    /// color.
    func save() {
        var cellData = Data(capacity: cells.count * 13)
        for (key, cell) in cells {
            withUnsafeBytes(of: key.littleEndian) { cellData.append(contentsOf: $0) }
            let storedDistance = Int8(clamping: Int((cell.signedDistance * 127).rounded()))
            cellData.append(UInt8(bitPattern: storedDistance))
            cellData.append(cell.weight)
            cellData.append(contentsOf: [UInt8((cell.color >> 16) & 0xFF), UInt8((cell.color >> 8) & 0xFF), UInt8(cell.color & 0xFF)])
        }
        try? cellData.write(to: fileURL, options: .atomic)
    }

    private static func loadCells(from fileURL: URL) -> [Int64: Cell] {
        guard let cellData = try? Data(contentsOf: fileURL) else { return [:] }
        let bytes = [UInt8](cellData)
        let cellCount = bytes.count / 13
        var loadedCells: [Int64: Cell] = [:]
        loadedCells.reserveCapacity(cellCount)
        for cellIndex in 0..<cellCount {
            let offset = cellIndex * 13
            var key: UInt64 = 0
            for byteIndex in 0..<8 {
                key |= UInt64(bytes[offset + byteIndex]) << (8 * UInt64(byteIndex))
            }
            loadedCells[Int64(bitPattern: key)] = Cell(
                signedDistance: Float(Int8(bitPattern: bytes[offset + 8])) / 127,
                weight: bytes[offset + 9],
                color: UInt32(bytes[offset + 10]) << 16 | UInt32(bytes[offset + 11]) << 8 | UInt32(bytes[offset + 12])
            )
        }
        return loadedCells
    }
}
