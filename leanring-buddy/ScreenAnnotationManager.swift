//
//  ScreenAnnotationManager.swift
//  leanring-buddy
//
//  Circle to ask. While the talk shortcut is held, the cursor leaves a blue
//  trail on screen; circle something and Dottie sees exactly what you
//  marked. Shipped Clicky does this with ScreenAnnotationManager,
//  ScreenAnnotationOverlay and ScreenAnnotationCanvasView ("Hold the keys,
//  circle something on your screen with the cursor, and ask about it").
//
//  The trail is sampled from the mouse position, so no click or drag is
//  needed. When the shortcut is released, the trail is checked for a loop
//  (it comes back near where the loop started and encloses some area). A
//  loop becomes the turn's annotation: it stays on screen for a moment and
//  is drawn as a ring onto the screenshot the model sees. Anything else
//  fades away and the turn is a normal one.
//

import AppKit
import Combine
import SwiftUI

/// What the user circled, in AppKit global coordinates (bottom-left origin).
struct ScreenAnnotation {
    let loopPoints: [CGPoint]
    var boundingRect: CGRect { Self.boundingRect(of: loopPoints) }

    static func boundingRect(of points: [CGPoint]) -> CGRect {
        guard let firstPoint = points.first else { return .zero }
        var minX = firstPoint.x, maxX = firstPoint.x, minY = firstPoint.y, maxY = firstPoint.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Short note for the model about the ring in the screenshot.
    static let modelContextText = "while talking, the user circled part of the screen with the cursor. the screenshot shows it as a bright blue hand-drawn ring. they're asking about what's inside that ring, so focus on it."
}

@MainActor
final class ScreenAnnotationManager: ObservableObject {
    nonisolated static let enabledDefaultsKey = "clickyScreenAnnotationEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The trail drawn so far, in AppKit global coordinates.
    @Published private(set) var trailPoints: [CGPoint] = []
    /// Set once a loop is found on release; drawn as a closed ring.
    @Published private(set) var finishedLoopPoints: [CGPoint]?
    @Published private(set) var drawingOpacity: Double = 1

    private var samplingTimer: Timer?
    /// Every sample this hold, including the start before it shows.
    private var sampledPoints: [CGPoint] = []
    private var fadeTask: Task<Void, Never>?
    private var overlayWindows: [ScreenAnnotationOverlayWindow] = []
    private(set) var trackingStartedAt: Date?

    /// Samples finer than this are dropped.
    private static let minimumPointSpacing: CGFloat = 3
    /// The trail only appears once the cursor has really moved, so a still
    /// cursor while talking draws nothing.
    private static let minimumVisibleTrailLength: CGFloat = 40
    /// Enough for a long, slow hold; keeps loop detection quick.
    private static let maximumSampleCount = 1200

    // MARK: - Tracking

    func startTracking() {
        guard Self.isEnabled else { return }
        stopSampling()
        fadeTask?.cancel()
        trailPoints = []
        finishedLoopPoints = nil
        drawingOpacity = 1
        trackingStartedAt = Date()
        showOverlayWindows()

        sampledPoints = [NSEvent.mouseLocation]
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleMouseLocation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        samplingTimer = timer
    }

    private func sampleMouseLocation() {
        let mouseLocation = NSEvent.mouseLocation
        guard let lastPoint = sampledPoints.last,
              Self.distance(lastPoint, mouseLocation) >= Self.minimumPointSpacing,
              sampledPoints.count < Self.maximumSampleCount else { return }
        sampledPoints.append(mouseLocation)
        if !trailPoints.isEmpty || Self.pathLength(of: sampledPoints) >= Self.minimumVisibleTrailLength {
            trailPoints = sampledPoints
        }
    }

    /// Ends tracking. Returns the loop the user drew, if any; it stays on
    /// screen for a few seconds, and any other trail fades right away.
    @discardableResult
    func finishTracking() -> ScreenAnnotation? {
        guard samplingTimer != nil else { return nil }
        stopSampling()

        guard let loopPoints = Self.findLoop(in: sampledPoints) else {
            fadeOut(after: 0)
            return nil
        }
        finishedLoopPoints = loopPoints
        trailPoints = []
        fadeOut(after: 4)
        return ScreenAnnotation(loopPoints: loopPoints)
    }

    /// Clears everything at once (Escape, or a new turn).
    func clear() {
        stopSampling()
        fadeOut(after: 0)
    }

    private func stopSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    private func fadeOut(after delaySeconds: TimeInterval) {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                self.drawingOpacity = 0
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self.trailPoints = []
            self.finishedLoopPoints = nil
            self.hideOverlayWindows()
        }
    }

    // MARK: - Loop detection

    /// Finds the last closed loop in the trail: a stretch that ends close to
    /// where it began, is long enough to be deliberate, and encloses real
    /// area (so a line drawn back and forth doesn't count).
    nonisolated static func findLoop(in points: [CGPoint]) -> [CGPoint]? {
        guard points.count >= 8 else { return nil }

        var cumulativeLengths: [CGFloat] = [0]
        for index in 1..<points.count {
            cumulativeLengths.append(cumulativeLengths[index - 1] + distance(points[index - 1], points[index]))
        }

        for endIndex in stride(from: points.count - 1, through: 7, by: -1) {
            for startIndex in 0...(endIndex - 7) {
                let loopLength = cumulativeLengths[endIndex] - cumulativeLengths[startIndex]
                guard loopLength >= 120 else { break }
                // A closed loop's longest side is at most half its length,
                // so this rules out most stretches before the costlier checks.
                let closingGap = distance(points[startIndex], points[endIndex])
                guard closingGap <= max(24, 0.35 * loopLength / 2) else { continue }
                let loopPoints = Array(points[startIndex...endIndex])
                let loopBounds = ScreenAnnotation.boundingRect(of: loopPoints)
                guard loopBounds.width >= 24, loopBounds.height >= 24 else { continue }
                let allowedGap = max(24, 0.35 * max(loopBounds.width, loopBounds.height))
                guard closingGap <= allowedGap else { continue }
                let enclosedArea = abs(signedArea(of: loopPoints))
                guard enclosedArea >= 0.3 * loopBounds.width * loopBounds.height else { continue }
                return loopPoints
            }
        }
        return nil
    }

    nonisolated private static func signedArea(of points: [CGPoint]) -> CGFloat {
        var doubledArea: CGFloat = 0
        for index in points.indices {
            let currentPoint = points[index]
            let nextPoint = points[(index + 1) % points.count]
            doubledArea += currentPoint.x * nextPoint.y - nextPoint.x * currentPoint.y
        }
        return doubledArea / 2
    }

    nonisolated static func distance(_ firstPoint: CGPoint, _ secondPoint: CGPoint) -> CGFloat {
        hypot(firstPoint.x - secondPoint.x, firstPoint.y - secondPoint.y)
    }

    nonisolated private static func pathLength(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    // MARK: - Overlay windows

    private func showOverlayWindows() {
        guard overlayWindows.isEmpty else {
            overlayWindows.forEach { $0.orderFrontRegardless() }
            return
        }
        overlayWindows = NSScreen.screens.map { screen in
            let overlayWindow = ScreenAnnotationOverlayWindow(screen: screen)
            overlayWindow.contentView = NSHostingView(
                rootView: ScreenAnnotationCanvasView(annotationManager: self, screenFrame: screen.frame)
            )
            overlayWindow.orderFrontRegardless()
            return overlayWindow
        }
    }

    private func hideOverlayWindows() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = []
    }
}

// MARK: - Drawing onto screenshots

extension ScreenAnnotation {
    /// Returns the JPEG with the loop drawn on it as a ring. `pixelPoint`
    /// maps a global point to the image's top-left pixel space, or nil for
    /// points that aren't on it. Returns nil if nothing could be drawn.
    func drawRing(onJPEG jpegData: Data, pixelPoint: (CGPoint) -> CGPoint?) -> Data? {
        let ringPixelPoints = loopPoints.compactMap(pixelPoint)
        guard ringPixelPoints.count >= 3,
              let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let screenshotImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let drawingContext = CGContext(
                data: nil,
                width: screenshotImage.width,
                height: screenshotImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }

        let imageHeight = CGFloat(screenshotImage.height)
        drawingContext.draw(screenshotImage, in: CGRect(x: 0, y: 0, width: screenshotImage.width, height: screenshotImage.height))

        // CGContext's origin is bottom-left; pixel points are top-left.
        let ringPath = CGMutablePath()
        ringPath.addLines(between: ringPixelPoints.map { CGPoint(x: $0.x, y: imageHeight - $0.y) })
        ringPath.closeSubpath()

        let ringLineWidth = max(3, CGFloat(screenshotImage.width) / 400)
        drawingContext.setLineJoin(.round)
        drawingContext.setLineCap(.round)
        drawingContext.addPath(ringPath)
        drawingContext.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.35))
        drawingContext.setLineWidth(ringLineWidth * 2.5)
        drawingContext.strokePath()
        drawingContext.addPath(ringPath)
        drawingContext.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
        drawingContext.setLineWidth(ringLineWidth)
        drawingContext.strokePath()

        guard let annotatedImage = drawingContext.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: annotatedImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// Draws the ring onto a single-display screenshot.
    func drawRing(on screenCapture: CompanionScreenCapture) -> Data? {
        let displayFrame = screenCapture.displayFrame
        guard displayFrame.intersects(boundingRect) else { return nil }
        return drawRing(onJPEG: screenCapture.imageData) { globalPoint in
            Self.pixelPoint(for: globalPoint, displayFrame: displayFrame, pixelSize: CGSize(
                width: screenCapture.screenshotWidthInPixels,
                height: screenCapture.screenshotHeightInPixels
            ))
        }
    }

    /// Draws the ring onto the Live composite frame.
    func drawRing(on compositeFrame: CompanionCompositeScreenFrame) -> Data? {
        drawRing(onJPEG: compositeFrame.jpegData) { globalPoint in
            guard let region = compositeFrame.regions.first(where: { $0.screenCapture.displayFrame.contains(globalPoint) }),
                  let pointInRegion = Self.pixelPoint(
                    for: globalPoint,
                    displayFrame: region.screenCapture.displayFrame,
                    pixelSize: region.rectInCompositePixels.size
                  ) else { return nil }
            return CGPoint(
                x: region.rectInCompositePixels.minX + pointInRegion.x,
                y: region.rectInCompositePixels.minY + pointInRegion.y
            )
        }
    }

    private static func pixelPoint(for globalPoint: CGPoint, displayFrame: CGRect, pixelSize: CGSize) -> CGPoint? {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return nil }
        let clampedX = min(max(globalPoint.x, displayFrame.minX), displayFrame.maxX)
        let clampedY = min(max(globalPoint.y, displayFrame.minY), displayFrame.maxY)
        return CGPoint(
            x: (clampedX - displayFrame.minX) / displayFrame.width * pixelSize.width,
            y: (displayFrame.maxY - clampedY) / displayFrame.height * pixelSize.height
        )
    }
}

// MARK: - Overlay

/// A click-through window over one screen that holds the trail.
final class ScreenAnnotationOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        // Drawn over any wallpaper in Dottie's dark colors.
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ScreenAnnotationCanvasView: View {
    @ObservedObject var annotationManager: ScreenAnnotationManager
    let screenFrame: CGRect

    var body: some View {
        ZStack {
            if let finishedLoopPoints = annotationManager.finishedLoopPoints {
                strokedPath(through: finishedLoopPoints, isClosed: true)
            } else {
                strokedPath(through: annotationManager.trailPoints, isClosed: false)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .opacity(annotationManager.drawingOpacity)
        .allowsHitTesting(false)
    }

    private func strokedPath(through globalPoints: [CGPoint], isClosed: Bool) -> some View {
        let path = Path { path in
            // Window-local SwiftUI coordinates have a top-left origin.
            let localPoints = globalPoints.map { CGPoint(x: $0.x - screenFrame.minX, y: screenFrame.maxY - $0.y) }
            guard let firstPoint = localPoints.first else { return }
            path.move(to: firstPoint)
            for point in localPoints.dropFirst() {
                path.addLine(to: point)
            }
            if isClosed { path.closeSubpath() }
        }
        return path
            .stroke(DS.Colors.overlayCursorBlue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6)
    }
}
