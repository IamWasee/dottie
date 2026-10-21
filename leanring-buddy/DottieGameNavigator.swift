//
//  DottieGameNavigator.swift
//  leanring-buddy
//
//  Plans a walk across the 3D map and turns it into exact controls, so
//  Dottie can get somewhere she knows without asking a model on the way:
//
//  1. Floor plan: the map's voxels seen from above, half a unit per cell.
//     A cell is blocked when enough points sit at body height (a wall, a
//     tree, a crate), unless they all sit lower than this game's learned
//     jump height: then it's a low thing she jumps over. Cells where the
//     ground is only seen far below are drops (a ledge, a pit) and cost a
//     lot, so routes go around them when they can. Mapped floor is open;
//     never-seen cells are allowed but cost more, so routes prefer ground
//     she has seen. Blockers she walked into (DottieGameWorldMap) are
//     blocked too.
//  2. Path: A* from where she stands to the place, eight directions.
//  3. Legs: the path straightened into a few lines, each one "turn so
//     many degrees, then hold W (and shift) for so many seconds", using
//     the movement model's walking speed, with the spots along the leg
//     where she presses jump.
//

import Foundation

@MainActor
enum DottieGameNavigator {
    struct Leg {
        let turnDegrees: Double
        let distance: Double
        let holdSeconds: Double
        let isSprinting: Bool
        /// Where along this leg to jump, nearest first.
        let jumps: [Jump]
    }

    struct Jump {
        /// Units walked into the leg when jump is pressed (a little before
        /// the low thing, so she's in the air as she reaches it).
        let takeOffDistance: Double
        /// How high and how long the low thing is, for learning the jump.
        let obstacleHeight: Double
        let obstacleLength: Double
    }

    fileprivate typealias GridPoint = DottieGameWorldMap.FloorCell

    fileprivate struct FloorPlan {
        var blockedCells: Set<GridPoint> = []
        /// Low things she can jump over, with their height in units.
        var lowObstacleHeights: [GridPoint: Double] = [:]
        var floorCells: Set<GridPoint> = []
        var dropCells: Set<GridPoint> = []
    }

    /// Body height above the floor, in voxel rows (0.5 units each): from
    /// knee height to just over head height.
    private static let bodyHeightGridRows = 1...4
    private static let blockingHitCount: UInt16 = 2
    /// Ground seen this many rows (or more) below the floor is a drop.
    private static let dropGridRow = -3
    private static let unknownGroundCostFactor = 2.5
    private static let lowObstacleCostFactor = 3.0
    private static let dropCostFactor = 8.0
    /// Jump this far before the low thing.
    private static let takeOffLeadDistance = 0.6
    private static let maximumSearchedCells = 60_000
    /// Long straight legs are split so the glances can correct drift.
    private static let maximumLegDistance = 12.0

    /// The legs from the current pose to (targetX, targetY), or nil when no
    /// path was found.
    static func legs(on worldMap: DottieGameWorldMap, toX targetX: Double, y targetY: Double, sprint: Bool) -> [Leg]? {
        let voxelSize = DottieGameWorldMap.voxelSize
        let startPoint = GridPoint(gridX: Int(floor(worldMap.pose.x / voxelSize)), gridY: Int(floor(worldMap.pose.y / voxelSize)))
        let goalPoint = GridPoint(gridX: Int(floor(targetX / voxelSize)), gridY: Int(floor(targetY / voxelSize)))
        let plan = floorPlan(of: worldMap)
        guard let gridPath = aStarPath(from: startPoint, to: goalPoint, plan: plan) else {
            return nil
        }
        let jumpsAlongPath = jumps(along: gridPath, plan: plan)
        let waypoints = straightened(gridPath).map { gridPoint in
            (x: (Double(gridPoint.gridX) + 0.5) * voxelSize, y: (Double(gridPoint.gridY) + 0.5) * voxelSize)
        }

        var legs: [Leg] = []
        var currentX = worldMap.pose.x
        var currentY = worldMap.pose.y
        var currentHeading = worldMap.pose.headingDegrees
        // How far along the whole path each leg starts, to place the jumps.
        var distanceAlongPath = 0.0
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
                let pieceStartDistance = distanceAlongPath
                let jumpsInPiece = jumpsAlongPath
                    .filter { $0.takeOffDistance >= pieceStartDistance && $0.takeOffDistance < pieceStartDistance + pieceDistance }
                    .map { Jump(takeOffDistance: $0.takeOffDistance - pieceStartDistance, obstacleHeight: $0.obstacleHeight, obstacleLength: $0.obstacleLength) }
                legs.append(Leg(
                    turnDegrees: turnDegrees,
                    distance: pieceDistance,
                    holdSeconds: worldMap.movement.secondsToWalk(distance: pieceDistance, isSprinting: isSprinting),
                    isSprinting: isSprinting,
                    jumps: jumpsInPiece
                ))
                turnDegrees = 0
                distanceLeft -= pieceDistance
                distanceAlongPath += pieceDistance
            }
            currentHeading = bearingDegrees
            currentX = waypoint.x
            currentY = waypoint.y
        }
        return legs
    }

    // MARK: - Floor plan

    private static func floorPlan(of worldMap: DottieGameWorldMap) -> FloorPlan {
        let voxelSize = DottieGameWorldMap.voxelSize
        var bodyHeightHits: [GridPoint: Int] = [:]
        var highestHitRow: [GridPoint: Int] = [:]
        var lowestSeenRow: [GridPoint: Int] = [:]
        var plan = FloorPlan()
        // The camera sits 1.6 units up, so the floor is at grid row 0
        // (z 0…0.5) or just below it.
        for (voxelKey, hits) in worldMap.voxelHits {
            let gridPosition = DottieGameWorldMap.gridPosition(ofVoxelKey: voxelKey)
            let cell = GridPoint(gridX: gridPosition.gridX, gridY: gridPosition.gridY)
            if bodyHeightGridRows.contains(gridPosition.gridZ) {
                bodyHeightHits[cell, default: 0] += Int(hits)
                highestHitRow[cell] = max(highestHitRow[cell] ?? gridPosition.gridZ, gridPosition.gridZ)
            } else if gridPosition.gridZ <= 0 && gridPosition.gridZ >= -1 {
                plan.floorCells.insert(cell)
            } else if gridPosition.gridZ < 0 {
                lowestSeenRow[cell] = min(lowestSeenRow[cell] ?? gridPosition.gridZ, gridPosition.gridZ)
            }
        }
        let jumpHeight = worldMap.movement.jumpHeightUnits
        for (cell, hitCount) in bodyHeightHits where hitCount >= Int(blockingHitCount) {
            // The top of the highest row with something in it.
            let obstacleHeight = Double((highestHitRow[cell] ?? bodyHeightGridRows.upperBound) + 1) * voxelSize
            if obstacleHeight <= jumpHeight {
                plan.lowObstacleHeights[cell] = obstacleHeight
            } else {
                plan.blockedCells.insert(cell)
            }
        }
        for (cell, lowestRow) in lowestSeenRow where lowestRow <= dropGridRow && !plan.floorCells.contains(cell) {
            plan.dropCells.insert(cell)
        }
        plan.blockedCells.formUnion(worldMap.currentBlockedCells())
        return plan
    }

    /// The jumps a path needs: one per run of low cells, pressed a little
    /// before the run. A run longer than a jump carries her (steps, a
    /// slope) still gets one; the glances catch it if she sticks.
    private static func jumps(along gridPath: [GridPoint], plan: FloorPlan) -> [Jump] {
        let voxelSize = DottieGameWorldMap.voxelSize
        var foundJumps: [Jump] = []
        var distanceAlongPath = 0.0
        var runStartDistance: Double?
        var runHeight = 0.0
        for pointIndex in gridPath.indices {
            if pointIndex > 0 {
                let previousPoint = gridPath[pointIndex - 1]
                let isDiagonalStep = previousPoint.gridX != gridPath[pointIndex].gridX && previousPoint.gridY != gridPath[pointIndex].gridY
                distanceAlongPath += (isDiagonalStep ? 1.414 : 1.0) * voxelSize
            }
            if let obstacleHeight = plan.lowObstacleHeights[gridPath[pointIndex]] {
                if runStartDistance == nil {
                    runStartDistance = distanceAlongPath
                    runHeight = 0
                }
                runHeight = max(runHeight, obstacleHeight)
            } else if let startDistance = runStartDistance {
                foundJumps.append(Jump(
                    takeOffDistance: max(0, startDistance - takeOffLeadDistance),
                    obstacleHeight: runHeight,
                    obstacleLength: distanceAlongPath - startDistance
                ))
                runStartDistance = nil
            }
        }
        return foundJumps
    }

    // MARK: - A*

    private static func aStarPath(from startPoint: GridPoint, to goalPoint: GridPoint, plan: FloorPlan) -> [GridPoint]? {
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
                if plan.blockedCells.contains(neighborPoint) && neighborPoint != goalPoint { continue }
                let stepLength = offsetX != 0 && offsetY != 0 ? 1.414 : 1.0
                let groundCostFactor: Double
                if plan.lowObstacleHeights[neighborPoint] != nil {
                    groundCostFactor = lowObstacleCostFactor
                } else if plan.dropCells.contains(neighborPoint) {
                    groundCostFactor = dropCostFactor
                } else if plan.floorCells.contains(neighborPoint) {
                    groundCostFactor = 1.0
                } else {
                    groundCostFactor = unknownGroundCostFactor
                }
                let newCost = (costSoFar[currentPoint] ?? 0) + stepLength * groundCostFactor
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
