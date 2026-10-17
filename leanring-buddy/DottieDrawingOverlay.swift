//
//  DottieDrawingOverlay.swift
//  leanring-buddy
//
//  What Dottie draws on the screen ("circle the error", each step of a
//  guide): a click-through window over each display that draws each mark
//  the way a person would with a marker, in Dottie's gold-to-purple colors.
//
//  Marks hug the thing they mark: callers pass the element's real frame
//  (from Accessibility or a vision box), and a circle is a loose ellipse just
//  past its edges, not a ring around its corners. Strokes are made to look
//  hand-drawn (DottieSketchStroke): a circle starts up and to the right,
//  wobbles a little, and overshoots its start; lines bow slightly; the pen
//  speeds up and slows down as it draws.
//
//  Marks fade after a few seconds, unless the caller keeps them (a guide
//  keeps a step's marks until the user does the step).
//

import AppKit
import Combine
import SwiftUI

struct DottieDrawing: Identifiable, Equatable {
    let id = UUID()
    let shape: DottieScreenAction.DrawingShape
    /// What the drawing marks, in global AppKit coordinates.
    let targetRect: CGRect
    let note: String?
}

/// A pen color for teaching drawings. Gold is Dottie's gold-to-purple
/// marker; the rest are flat chalk colors for telling things apart.
enum DottieInk: String, CaseIterable {
    case gold, white, red, blue, green, yellow, pink, purple, orange

    var color: Color {
        switch self {
        case .gold: return Color(red: 1.0, green: 0.8, blue: 0.36)
        case .white: return Color(red: 0.97, green: 0.97, blue: 0.95)
        case .red: return Color(red: 1.0, green: 0.36, blue: 0.36)
        case .blue: return Color(red: 0.36, green: 0.66, blue: 1.0)
        case .green: return Color(red: 0.4, green: 0.88, blue: 0.5)
        case .yellow: return Color(red: 1.0, green: 0.92, blue: 0.3)
        case .pink: return Color(red: 1.0, green: 0.5, blue: 0.78)
        case .purple: return Color(red: 0.72, green: 0.52, blue: 1.0)
        case .orange: return Color(red: 1.0, green: 0.6, blue: 0.24)
        }
    }

    var strokeStyle: AnyShapeStyle {
        guard self == .gold else { return AnyShapeStyle(color) }
        return AnyShapeStyle(LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.84, blue: 0.38),
                Color(red: 0.95, green: 0.45, blue: 0.55),
                Color(red: 0.55, green: 0.3, blue: 0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }
}

/// One piece of a teaching drawing (explain_on_screen): a pen stroke, a
/// dot, a filled area, handwritten text, or the dark board it all sits on.
/// Points are global AppKit coordinates (bottom-left origin).
struct DottieFigure: Identifiable, Equatable {
    enum Shape: Equatable {
        /// smooth: a curve through the points instead of straight segments.
        case stroke(points: [CGPoint], closed: Bool, smooth: Bool, dashed: Bool, arrowAtStart: Bool, arrowAtEnd: Bool)
        case dot(center: CGPoint, radius: CGFloat)
        case fill(points: [CGPoint])
        /// Written left to right; `origin` is the middle of its left edge.
        case text(String, origin: CGPoint, fontSize: CGFloat)
        case board(rect: CGRect)
    }

    let id = UUID()
    let shape: Shape
    var ink: DottieInk = .gold
    var lineWidth: CGFloat = 3.5
    /// Seconds after it's added before the pen starts on it.
    var delay: Double = 0
    var drawDuration: Double = 0.6

    /// Roughly what it covers, to know which screen draws it.
    var bounds: CGRect {
        switch shape {
        case .stroke(let points, _, _, _, _, _), .fill(let points):
            return ScreenAnnotation.boundingRect(of: points).insetBy(dx: -20, dy: -20)
        case .dot(let center, let radius):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .text(let text, let origin, let fontSize):
            let width = DottieFigure.estimatedTextWidth(text, fontSize: fontSize)
            return CGRect(x: origin.x, y: origin.y - fontSize, width: width, height: fontSize * 2)
        case .board(let rect):
            return rect
        }
    }

    static func estimatedTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        CGFloat(text.count) * fontSize * 0.56 + 6
    }
}

@MainActor
final class DottieDrawingOverlayManager: ObservableObject {
    @Published private(set) var drawings: [DottieDrawing] = []
    /// Teaching drawings. They stay until cleared, or a while after the
    /// explanation ends.
    @Published private(set) var figures: [DottieFigure] = []
    private var figureFadeOutTask: Task<Void, Never>?

    private static let drawingLifetimeSeconds: TimeInterval = 8
    private var overlayWindows: [NSWindow] = []
    private var fadeOutTask: Task<Void, Never>?

    /// Adds a mark. `fadesOut: false` keeps it until `clear()`.
    func add(_ drawing: DottieDrawing, fadesOut: Bool = true) {
        showWindowsIfNeeded()
        drawings.append(drawing)
        if fadesOut {
            scheduleFadeOut()
        } else {
            fadeOutTask?.cancel()
        }
    }

    func clear() {
        fadeOutTask?.cancel()
        drawings.removeAll()
        clearFigures()
    }

    func addFigures(_ newFigures: [DottieFigure]) {
        guard !newFigures.isEmpty else { return }
        showWindowsIfNeeded()
        figureFadeOutTask?.cancel()
        figures.append(contentsOf: newFigures)
    }

    func clearFigures() {
        figureFadeOutTask?.cancel()
        figures.removeAll()
    }

    /// Lets the user read the finished drawing, then fades it.
    func fadeFigures(after seconds: TimeInterval) {
        figureFadeOutTask?.cancel()
        figureFadeOutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.figures.removeAll()
        }
    }

    private func scheduleFadeOut() {
        fadeOutTask?.cancel()
        fadeOutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.drawingLifetimeSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.drawings.removeAll()
        }
    }

    /// One window per display, made on first use and rebuilt if the
    /// displays changed.
    private func showWindowsIfNeeded() {
        let screenFrames = NSScreen.screens.map(\.frame)
        guard overlayWindows.map(\.frame) != screenFrames else { return }
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            // Just under the cursor's overlay, so the pen stays on top of
            // the board and the drawing.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            let hostingView = NSHostingView(rootView: DottieDrawingCanvasView(overlayManager: self, screenFrame: screen.frame))
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear
            window.contentView = hostingView
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return window
        }
    }
}

private struct DottieDrawingCanvasView: View {
    @ObservedObject var overlayManager: DottieDrawingOverlayManager
    let screenFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(overlayManager.figures.filter { $0.bounds.intersects(screenFrame) }) { figure in
                DottieFigureView(figure: figure, screenFrame: screenFrame)
                    .transition(.opacity)
            }
            ForEach(overlayManager.drawings.filter { $0.targetRect.intersects(screenFrame) }) { drawing in
                DottieDrawingMarkView(drawing: drawing, localTargetRect: localRect(for: drawing.targetRect), canvasSize: screenFrame.size)
                    .transition(.opacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.4), value: overlayManager.drawings)
        .animation(.easeOut(duration: 0.5), value: overlayManager.figures)
    }

    /// Global AppKit (bottom-left origin) to this screen's SwiftUI space.
    private func localRect(for globalRect: CGRect) -> CGRect {
        CGRect(
            x: globalRect.minX - screenFrame.minX,
            y: screenFrame.maxY - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
    }
}

private struct DottieDrawingMarkView: View {
    let drawing: DottieDrawing
    let localTargetRect: CGRect
    let canvasSize: CGSize
    @State private var drawProgress: CGFloat = 0
    @State private var highlightOpacity: Double = 0

    private static let markGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.84, blue: 0.38),
            Color(red: 0.95, green: 0.45, blue: 0.55),
            Color(red: 0.55, green: 0.3, blue: 0.85)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var sketch: DottieSketchStroke {
        DottieSketchStroke(shape: drawing.shape, targetRect: localTargetRect, seed: drawing.id.hashValue)
    }

    var body: some View {
        let sketch = self.sketch
        ZStack(alignment: .topLeading) {
            if drawing.shape == .highlight {
                // A soft wash over the area under the hand-drawn edge.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.86, blue: 0.4).opacity(0.13))
                    .frame(width: sketch.paddedRect.width, height: sketch.paddedRect.height)
                    .offset(x: sketch.paddedRect.minX, y: sketch.paddedRect.minY)
                    .opacity(highlightOpacity)
            }

            sketch.path
                .trim(from: 0, to: drawProgress)
                .stroke(Self.markGradient, style: StrokeStyle(lineWidth: drawing.shape == .highlight ? 2.5 : 3.5, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.3), radius: 1.5, x: 0, y: 1)

            if let note = drawing.note {
                Text(note)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 0.32, green: 0.15, blue: 0.45).opacity(0.92)))
                    .fixedSize()
                    .position(notePosition(for: sketch))
                    .opacity(Double(drawProgress))
            }
        }
        .onAppear {
            // A pen speeds into the stroke and eases out at the end.
            withAnimation(.timingCurve(0.45, 0.05, 0.25, 1, duration: sketch.drawDuration)) {
                drawProgress = 1
            }
            withAnimation(.easeOut(duration: 0.35)) {
                highlightOpacity = 1
            }
        }
    }

    /// Below the mark, or above it near the bottom of the screen; at the
    /// tail for an arrow.
    private func notePosition(for sketch: DottieSketchStroke) -> CGPoint {
        if drawing.shape == .arrow, let tail = sketch.arrowTail {
            return CGPoint(x: tail.x, y: tail.y - 16)
        }
        let markBounds = sketch.paddedRect
        let below = CGPoint(x: markBounds.midX, y: markBounds.maxY + 18)
        if below.y + 16 < canvasSize.height { return below }
        return CGPoint(x: markBounds.midX, y: markBounds.minY - 18)
    }
}

/// One teaching figure, drawn the way a pen would: strokes grow from their
/// start, text is written left to right, the board fades in.
private struct DottieFigureView: View {
    let figure: DottieFigure
    let screenFrame: CGRect
    @State private var progress: CGFloat = 0
    /// Arrowheads go on once the line reaches its end.
    @State private var arrowHeadOpacity: Double = 0

    /// A friendly handwriting face; macOS ships Noteworthy.
    private static func handwriting(size: CGFloat) -> Font {
        NSFont(name: "Noteworthy-Bold", size: size) != nil
            ? .custom("Noteworthy-Bold", size: size)
            : .system(size: size, weight: .semibold, design: .rounded)
    }

    var body: some View {
        content
            .onAppear {
                let animation: Animation
                switch figure.shape {
                case .text: animation = .linear(duration: figure.drawDuration)
                case .board, .fill, .dot: animation = .easeOut(duration: figure.drawDuration)
                case .stroke: animation = .timingCurve(0.45, 0.05, 0.25, 1, duration: figure.drawDuration)
                }
                withAnimation(animation.delay(figure.delay)) {
                    progress = 1
                }
                withAnimation(.easeOut(duration: 0.15).delay(figure.delay + figure.drawDuration * 0.92)) {
                    arrowHeadOpacity = 1
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch figure.shape {
        case .board(let rect):
            let localBoard = localRect(rect)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.93))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
                .frame(width: localBoard.width, height: localBoard.height)
                .position(x: localBoard.midX, y: localBoard.midY)
                .opacity(Double(progress))

        case .fill(let points):
            Path { path in
                path.addLines(points.map(localPoint))
                path.closeSubpath()
            }
            .fill(figure.ink.color.opacity(0.2))
            .opacity(Double(progress))

        case .dot(let center, let radius):
            Circle()
                .fill(figure.ink.color)
                .frame(width: radius * 2, height: radius * 2)
                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
                .scaleEffect(progress)
                .position(localPoint(center))

        case .text(let text, let origin, let fontSize):
            let localOrigin = localPoint(origin)
            Text(text)
                .font(Self.handwriting(size: fontSize))
                .foregroundColor(figure.ink.color)
                .fixedSize()
                .shadow(color: .black.opacity(0.55), radius: 1.5, x: 0, y: 1)
                .mask(
                    GeometryReader { proxy in
                        Rectangle().frame(width: proxy.size.width * progress, height: proxy.size.height)
                    }
                )
                .frame(width: 2400, alignment: .leading)
                .position(x: localOrigin.x + 1200, y: localOrigin.y)

        case .stroke(let points, let closed, let smooth, let dashed, let arrowAtStart, let arrowAtEnd):
            let localPoints = points.map(localPoint)
            ZStack {
                Self.strokePath(through: localPoints, closed: closed, smooth: smooth)
                    .trim(from: 0, to: progress)
                    .stroke(figure.ink.strokeStyle, style: StrokeStyle(
                        lineWidth: figure.lineWidth,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: dashed ? [10, 8] : []
                    ))
                Self.arrowHeads(for: localPoints, atStart: arrowAtStart, atEnd: arrowAtEnd, size: 9 + figure.lineWidth * 1.6)
                    .stroke(figure.ink.strokeStyle, style: StrokeStyle(lineWidth: figure.lineWidth, lineCap: .round, lineJoin: .round))
                    .opacity(arrowHeadOpacity)
            }
            .shadow(color: .black.opacity(0.4), radius: 1.5, x: 0, y: 1)
        }
    }

    private func localPoint(_ globalPoint: CGPoint) -> CGPoint {
        CGPoint(x: globalPoint.x - screenFrame.minX, y: screenFrame.maxY - globalPoint.y)
    }

    private func localRect(_ globalRect: CGRect) -> CGRect {
        CGRect(x: globalRect.minX - screenFrame.minX, y: screenFrame.maxY - globalRect.maxY, width: globalRect.width, height: globalRect.height)
    }

    private static func strokePath(through points: [CGPoint], closed: Bool, smooth: Bool) -> Path {
        var path = Path()
        guard let firstPoint = points.first else { return path }
        guard smooth, points.count > 2 else {
            path.move(to: firstPoint)
            for point in points.dropFirst() { path.addLine(to: point) }
            if closed { path.closeSubpath() }
            return path
        }
        // Catmull-Rom, wrapping around for a closed curve.
        let loopPoints = closed ? points + [firstPoint] : points
        path.move(to: firstPoint)
        for index in 0..<(loopPoints.count - 1) {
            let previous = index > 0 ? loopPoints[index - 1] : (closed ? points[points.count - 1] : loopPoints[0])
            let current = loopPoints[index]
            let next = loopPoints[index + 1]
            let afterNext = index + 2 < loopPoints.count ? loopPoints[index + 2] : (closed ? loopPoints[1] : next)
            let control1 = CGPoint(x: current.x + (next.x - previous.x) / 6, y: current.y + (next.y - previous.y) / 6)
            let control2 = CGPoint(x: next.x - (afterNext.x - current.x) / 6, y: next.y - (afterNext.y - current.y) / 6)
            path.addCurve(to: next, control1: control1, control2: control2)
        }
        return path
    }

    private static func arrowHeads(for points: [CGPoint], atStart: Bool, atEnd: Bool, size: CGFloat) -> Path {
        var path = Path()
        func addHead(tip: CGPoint, from previous: CGPoint) {
            let direction = atan2(tip.y - previous.y, tip.x - previous.x)
            for wingAngle in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                path.move(to: CGPoint(x: tip.x + size * cos(direction + wingAngle), y: tip.y + size * sin(direction + wingAngle)))
                path.addLine(to: tip)
            }
        }
        if atEnd, points.count >= 2 {
            addHead(tip: points[points.count - 1], from: points[points.count - 2])
        }
        if atStart, points.count >= 2 {
            addHead(tip: points[0], from: points[1])
        }
        return path
    }
}

/// Builds a hand-drawn-looking path for a mark. Deterministic per seed, so a
/// mark keeps its shape while it animates.
struct DottieSketchStroke {
    let shape: DottieScreenAction.DrawingShape
    let targetRect: CGRect
    private(set) var path = Path()
    /// The area the mark covers, a little larger than the target.
    private(set) var paddedRect: CGRect = .zero
    private(set) var arrowTail: CGPoint?
    private var random: SeededRandom

    /// Longer marks take a little longer to draw, like a real pen.
    var drawDuration: Double {
        switch shape {
        case .circle: return 0.55
        case .box, .highlight: return 0.6
        case .underline: return 0.35
        case .arrow: return 0.5
        }
    }

    init(shape: DottieScreenAction.DrawingShape, targetRect: CGRect, seed: Int) {
        self.shape = shape
        self.targetRect = targetRect.standardized
        self.random = SeededRandom(seed: UInt64(bitPattern: Int64(seed)))
        switch shape {
        case .circle: buildCircle()
        case .box, .highlight: buildBox()
        case .underline: buildUnderline()
        case .arrow: buildArrow()
        }
    }

    /// A loose ellipse just past the target's edges: starts up and to the
    /// right, goes around once with a slight wobble, and overshoots.
    private mutating func buildCircle() {
        let center = CGPoint(x: targetRect.midX, y: targetRect.midY)
        // An ellipse through the corners would be 1.41x the box; a person
        // circling a word cuts the corners, so stay close to the edges.
        let radiusX = targetRect.width / 2 * 1.08 + 9
        let radiusY = targetRect.height / 2 * 1.12 + 7
        paddedRect = CGRect(x: center.x - radiusX, y: center.y - radiusY, width: radiusX * 2, height: radiusY * 2)

        let tilt = CGFloat(random.next(in: -0.06...0.06))
        let startAngle = -CGFloat.pi * 0.32 + CGFloat(random.next(in: -0.15...0.15))
        let sweep = CGFloat.pi * 2 + CGFloat(random.next(in: 0.28...0.45))
        let wobblePhase = CGFloat(random.next(in: 0...(2 * Double.pi)))
        let wobbleAmount = CGFloat(random.next(in: 0.025...0.045))
        // The end comes back slightly inside the start, so the overlap
        // reads as one quick loop rather than a closed ring.
        let endShrink = CGFloat(random.next(in: 0.05...0.09))

        let pointCount = 72
        var points: [CGPoint] = []
        for index in 0...pointCount {
            let progress = CGFloat(index) / CGFloat(pointCount)
            let angle = startAngle + sweep * progress
            let wobble = 1 + wobbleAmount * sin(2 * angle + wobblePhase) + wobbleAmount * 0.5 * sin(3 * angle - wobblePhase)
            let shrink = 1 - endShrink * max(0, (progress - 0.82) / 0.18)
            let x = cos(angle) * radiusX * wobble * shrink
            let y = sin(angle) * radiusY * wobble * shrink
            points.append(CGPoint(
                x: center.x + x * cos(tilt) - y * sin(tilt),
                y: center.y + x * sin(tilt) + y * cos(tilt)
            ))
        }
        path = Self.smoothPath(through: points)
    }

    /// Four slightly bowed strokes drawn in one go, closing a touch past the
    /// first corner like a quick marker box.
    private mutating func buildBox() {
        let padding: CGFloat = shape == .highlight ? 6 : 7
        let box = targetRect.insetBy(dx: -padding, dy: -padding)
        paddedRect = box
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY)
        ]
        var points: [CGPoint] = []
        for sideIndex in 0..<4 {
            let start = corners[sideIndex]
            let end = corners[(sideIndex + 1) % 4]
            let sideLength = max(hypot(end.x - start.x, end.y - start.y), 1)
            let bow = CGFloat(random.next(in: -1...1)) * min(4, sideLength * 0.02)
            let normal = CGPoint(x: -(end.y - start.y) / sideLength, y: (end.x - start.x) / sideLength)
            let stepCount = 12
            for step in 0...stepCount where !(sideIndex > 0 && step == 0) {
                let t = CGFloat(step) / CGFloat(stepCount)
                let bend = sin(t * .pi) * bow
                let jitterX = CGFloat(random.next(in: -0.6...0.6))
                let jitterY = CGFloat(random.next(in: -0.6...0.6))
                points.append(CGPoint(
                    x: start.x + (end.x - start.x) * t + normal.x * bend + jitterX,
                    y: start.y + (end.y - start.y) * t + normal.y * bend + jitterY
                ))
            }
        }
        if points.count > 1 {
            let first = points[0]
            let second = points[1]
            points.append(CGPoint(x: first.x + (second.x - first.x) * 0.9, y: first.y + (second.y - first.y) * 0.9 + 1.5))
        }
        path = Self.smoothPath(through: points)
    }

    /// A slightly rising, slightly curved line under the target.
    private mutating func buildUnderline() {
        let lineY = targetRect.maxY + 5
        let start = CGPoint(x: targetRect.minX - 3, y: lineY + CGFloat(random.next(in: 0...2)))
        let end = CGPoint(x: targetRect.maxX + 5, y: lineY - CGFloat(random.next(in: 1...3)))
        paddedRect = CGRect(x: start.x, y: targetRect.minY, width: end.x - start.x, height: targetRect.height + 9)
        var points: [CGPoint] = []
        let stepCount = 20
        for step in 0...stepCount {
            let t = CGFloat(step) / CGFloat(stepCount)
            points.append(CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t + sin(t * .pi) * 2.5
            ))
        }
        path = Self.smoothPath(through: points)
    }

    /// A curved arrow coming in from up and to the side, stopping just short
    /// of the target, with a two-stroke head.
    private mutating func buildArrow() {
        paddedRect = targetRect
        let comesFromLeft = targetRect.minX > 170
        let tip = CGPoint(
            x: comesFromLeft ? targetRect.minX - 6 : targetRect.maxX + 6,
            y: targetRect.midY - min(6, targetRect.height * 0.2)
        )
        let tail = CGPoint(x: tip.x + (comesFromLeft ? -110 : 110), y: tip.y - 70)
        arrowTail = tail
        let control = CGPoint(x: tail.x + (tip.x - tail.x) * 0.15, y: tip.y - 8)

        var arrowPath = Path()
        arrowPath.move(to: tail)
        arrowPath.addQuadCurve(to: tip, control: control)
        // The head follows the shaft's final direction.
        let direction = atan2(tip.y - control.y, tip.x - control.x)
        for wingAngle in [CGFloat.pi * 0.8, -CGFloat.pi * 0.78] {
            arrowPath.move(to: CGPoint(x: tip.x + 15 * cos(direction + wingAngle), y: tip.y + 15 * sin(direction + wingAngle)))
            arrowPath.addLine(to: tip)
        }
        path = arrowPath
    }

    /// Catmull-Rom through the points, so the stroke is smooth but keeps
    /// its wobble.
    private static func smoothPath(through points: [CGPoint]) -> Path {
        var smoothedPath = Path()
        guard points.count > 1 else { return smoothedPath }
        smoothedPath.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let previous = points[max(index - 1, 0)]
            let current = points[index]
            let next = points[index + 1]
            let afterNext = points[min(index + 2, points.count - 1)]
            let control1 = CGPoint(x: current.x + (next.x - previous.x) / 6, y: current.y + (next.y - previous.y) / 6)
            let control2 = CGPoint(x: next.x - (afterNext.x - current.x) / 6, y: next.y - (afterNext.y - current.y) / 6)
            smoothedPath.addCurve(to: next, control1: control1, control2: control2)
        }
        return smoothedPath
    }
}

/// Small deterministic random numbers (SplitMix64).
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        let unit = Double(mixed >> 11) / Double(UInt64(1) << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
