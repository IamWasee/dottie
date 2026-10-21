//
//  DottieGameNavigator.swift
//  leanring-buddy
//
//  Plans a walk across the 3D map and turns it into exact controls, so
//  Dottie can get somewhere she knows without asking a model on the way:
//
//  1. Floor plan: the map's voxels seen from above, half a unit per cell.
//     A cell is blocked when enough points sit at body height (a wall, a
//     tree, a crate); mapped floor is open; never-seen cells are allowed
//     but cost more, so routes prefer ground she has seen.
//  2. Path: A* from where she stands to the place, eight directions.
//  3. Legs: the path straightened into a few lines, each one "turn so
//     many degrees, then hold W (and shift) for so many seconds", using
//     the movement model's walking speed.
//
//  Jumps, ledges and moving things aren't planned; the reflexes' glances
//  catch those and hand back to the brain.
//

import Foundation

@MainActor
enum DottieGameNavigator {
    struct Leg {
        let turnDegrees: Double
        let distance: Double
        let holdSeconds: Double
        let isSprinting: Bool
    }

    fileprivate struct GridPoint: Hashable {
        let gridX: Int
        let gridY: Int
    }

    /// Body height above the floor, in voxel rows (0.5 units each): from
    /// knee height to just over head height.
    private static let bodyHeightGridRows = 1...4
    private static let blockingHitCount: UInt16 = 2
    private static let maximumSearchedCells = 60_000
    /// Long straight legs are split so the glances can correct drift.
    private static let maximumLegDistance = 12.0

    /// The legs from the current pose to (targetX, targetY), or nil when no
    /// path was found.
    static func legs(on worldMap: DottieGameWorldMap, toX targetX: Double, y targetY: Double, sprint: Bool) -> [Leg]? {
        let voxelSize = DottieGameWorldMap.voxelSize
        let startPoint = GridPoint(gridX: Int(floor(worldMap.pose.x / voxelSize)), gridY: Int(floor(worldMap.pose.y / voxelSize)))
        let goalPoint = GridPoint(gridX: Int(floor(targetX / voxelSize)), gridY: Int(floor(targetY / voxelSize)))
        let (blockedCells, floorCells) = floorPlan(of: worldMap)
        guard let gridPath = aStarPath(from: startPoint, to: goalPoint, blockedCells: blockedCells, floorCells: floorCells) else {
            return nil
        }
        let waypoints = straightened(gridPath).map { gridPoint in
            (x: (Double(gridPoint.gridX) + 0.5) * voxelSize, y: (Double(gridPoint.gridY) + 0.5) * voxelSize)
        }

        var legs: [Leg] = []
        var currentX = worldMap.pose.x
        var currentY = worldMap.pose.y
        var currentHeading = worldMap.pose.headingDegrees
        for waypoint in waypoints.dropFirst() {
            let deltaX = waypoint.x - currentX
            let deltaY = waypoint.y - currentY
            let legDistance = hypot(deltaX, deltaY)
            guard legDistance > 0.3 else { continue }
            let bearingDegrees = atan2(deltaX, deltaY) * 180 / .pi
            var turnDegrees = DottieGameWorldMap.normalizedAngle(bearingDegrees - currentHeading)
            var distanceLeft = legDistance
            while distanceLeft > 0.3 {
                let pieceDistance = min(distanceLeft, maximumLegDistance)
                // Sprinting only pays off on longer stretches.
                let isSprinting = sprint && pieceDistance > 4
                legs.append(Leg(
                    turnDegrees: turnDegrees,
                    distance: pieceDistance,
                    holdSeconds: worldMap.movement.secondsToWalk(distance: pieceDistance, isSprinting: isSprinting),
                    isSprinting: isSprinting
                ))
                turnDegrees = 0
                distanceLeft -= pieceDistance
            }
            currentHeading = bearingDegrees
            currentX = waypoint.x
            currentY = waypoint.y
        }
        return legs
    }

    // MARK: - Floor plan

    private static func floorPlan(of worldMap: DottieGameWorldMap) -> (blocked: Set<GridPoint>, floor: Set<GridPoint>) {
        var bodyHeightHits: [GridPoint: Int] = [:]
        var floorCells: Set<GridPoint> = []
        // The camera sits 1.6 units up, so the floor is at grid row 0
        // (z 0…0.5) or just below it.
        for (voxelKey, hits) in worldMap.voxelHits {
            let gridPosition = DottieGameWorldMap.gridPosition(ofVoxelKey: voxelKey)
            let cell = GridPoint(gridX: gridPosition.gridX, gridY: gridPosition.gridY)
            if bodyHeightGridRows.contains(gridPosition.gridZ) {
                bodyHeightHits[cell, default: 0] += Int(hits)
            } else if gridPosition.gridZ <= 0 && gridPosition.gridZ >= -1 {
                floorCells.insert(cell)
            }
        }
        let blockedCells = Set(bodyHeightHits.filter { $0.value >= Int(blockingHitCount) }.keys)
        return (blockedCells, floorCells)
    }

    // MARK: - A*

    private static func aStarPath(from startPoint: GridPoint, to goalPoint: GridPoint, blockedCells: Set<GridPoint>, floorCells: Set<GridPoint>) -> [GridPoint]? {
        if startPoint == goalPoint { return [startPoint] }
        let neighborOffsets = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
        var openQueue = DottieGameNavigatorQueue()
        openQueue.insert(startPoint, priority: estimatedCost(from: startPoint, to: goalPoint))
        var costSoFar: [GridPoint: Double] = [startPoint: 0]
        var cameFrom: [GridPoint: GridPoint] = [:]
        var closedCells: Set<GridPoint> = []
        // The search stays in a box around the start and the goal.
        let searchMargin = 40
        let minimumGridX = min(startPoint.gridX, goalPoint.gridX) - searchMargin
        let maximumGridX = max(startPoint.gridX, goalPoint.gridX) + searchMargin
        let minimumGridY = min(startPoint.gridY, goalPoint.gridY) - searchMargin
        let maximumGridY = max(startPoint.gridY, goalPoint.gridY) + searchMargin

        while let currentPoint = openQueue.popLowest() {
            // A cell can be queued more than once with older, higher costs.
            if closedCells.contains(currentPoint) { continue }
            if currentPoint == goalPoint {
                var path = [currentPoint]
                var tracedPoint = currentPoint
                while let previousPoint = cameFrom[tracedPoint] {
                    path.append(previousPoint)
                    tracedPoint = previousPoint
                }
                return path.reversed()
            }
            closedCells.insert(currentPoint)
            guard closedCells.count < maximumSearchedCells else { return nil }

            for (offsetX, offsetY) in neighborOffsets {
                let neighborPoint = GridPoint(gridX: currentPoint.gridX + offsetX, gridY: currentPoint.gridY + offsetY)
                guard neighborPoint.gridX >= minimumGridX, neighborPoint.gridX <= maximumGridX,
                      neighborPoint.gridY >= minimumGridY, neighborPoint.gridY <= maximumGridY,
                      !closedCells.contains(neighborPoint) else { continue }
                // The goal itself may sit next to a wall (a door, a shop).
                if blockedCells.contains(neighborPoint) && neighborPoint != goalPoint { continue }
                let stepLength = offsetX != 0 && offsetY != 0 ? 1.414 : 1.0
                let unknownGroundPenalty = floorCells.contains(neighborPoint) ? 1.0 : 2.5
                let newCost = (costSoFar[currentPoint] ?? 0) + stepLength * unknownGroundPenalty
                if newCost < (costSoFar[neighborPoint] ?? .greatestFiniteMagnitude) {
                    costSoFar[neighborPoint] = newCost
                    cameFrom[neighborPoint] = currentPoint
                    openQueue.insert(neighborPoint, priority: newCost + estimatedCost(from: neighborPoint, to: goalPoint))
                }
            }
        }
        return nil
    }

    private static func estimatedCost(from point: GridPoint, to goalPoint: GridPoint) -> Double {
        hypot(Double(goalPoint.gridX - point.gridX), Double(goalPoint.gridY - point.gridY))
    }

    /// Keeps only the points where the path bends, so a staircase of grid
    /// steps becomes a few straight walks.
    private static func straightened(_ gridPath: [GridPoint]) -> [GridPoint] {
        guard gridPath.count > 2 else { return gridPath }
        var keptPoints = [gridPath[0]]
        var previousDirection: (Int, Int)?
        for pointIndex in 1..<gridPath.count {
            let direction = (gridPath[pointIndex].gridX - gridPath[pointIndex - 1].gridX, gridPath[pointIndex].gridY - gridPath[pointIndex - 1].gridY)
            if let previousDirection, previousDirection != direction {
                keptPoints.append(gridPath[pointIndex - 1])
            }
            previousDirection = direction
        }
        keptPoints.append(gridPath[gridPath.count - 1])
        return keptPoints
    }
}

/// The cells A* still has to look at, cheapest first (a binary heap).
private struct DottieGameNavigatorQueue {
    private var entries: [(point: DottieGameNavigator.GridPoint, priority: Double)] = []

    mutating func insert(_ point: DottieGameNavigator.GridPoint, priority: Double) {
        entries.append((point, priority))
        var childIndex = entries.count - 1
        while childIndex > 0 {
            let parentIndex = (childIndex - 1) / 2
            guard entries[childIndex].priority < entries[parentIndex].priority else { break }
            entries.swapAt(childIndex, parentIndex)
            childIndex = parentIndex
        }
    }

    mutating func popLowest() -> DottieGameNavigator.GridPoint? {
        guard !entries.isEmpty else { return nil }
        entries.swapAt(0, entries.count - 1)
        let lowestEntry = entries.removeLast()
        var parentIndex = 0
        while true {
            let leftChildIndex = parentIndex * 2 + 1
            let rightChildIndex = leftChildIndex + 1
            var smallestIndex = parentIndex
            if leftChildIndex < entries.count, entries[leftChildIndex].priority < entries[smallestIndex].priority {
                smallestIndex = leftChildIndex
            }
            if rightChildIndex < entries.count, entries[rightChildIndex].priority < entries[smallestIndex].priority {
                smallestIndex = rightChildIndex
            }
            guard smallestIndex != parentIndex else { break }
            entries.swapAt(parentIndex, smallestIndex)
            parentIndex = smallestIndex
        }
        return lowestEntry.point
    }
}
