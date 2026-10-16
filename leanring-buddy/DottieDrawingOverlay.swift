//
//  DottieDrawingOverlay.swift
//  leanring-buddy
//
//  What Dottie draws on the screen when asked ("circle the error", "draw an
//  arrow to the settings"): a click-through window over each display that
//  draws each mark as if by hand, in Dottie's gold-to-purple colors, then
//  fades it out after a few seconds.
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

@MainActor
final class DottieDrawingOverlayManager: ObservableObject {
    @Published private(set) var drawings: [DottieDrawing] = []

    private static let drawingLifetimeSeconds: TimeInterval = 8
    private var overlayWindows: [NSWindow] = []
    private var fadeOutTask: Task<Void, Never>?

    func add(_ drawing: DottieDrawing) {
        showWindowsIfNeeded()
        drawings.append(drawing)
        scheduleFadeOut()
    }

    func clear() {
        fadeOutTask?.cancel()
        drawings.removeAll()
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
            window.level = .screenSaver
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
            ForEach(overlayManager.drawings.filter { $0.targetRect.intersects(screenFrame) }) { drawing in
                DottieDrawingMarkView(drawing: drawing, localTargetRect: localRect(for: drawing.targetRect))
                    .transition(.opacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.5), value: overlayManager.drawings)
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
    @State private var drawProgress: CGFloat = 0

    private static let markGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.88, blue: 0.45),
            Color(red: 0.93, green: 0.45, blue: 0.55),
            Color(red: 0.45, green: 0.22, blue: 0.62)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack(alignment: .topLeading) {
            markPath
                .trim(from: 0, to: drawProgress)
                .stroke(Self.markGradient, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)

            if let note = drawing.note {
                Text(note)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(red: 0.32, green: 0.15, blue: 0.45).opacity(0.92)))
                    .fixedSize()
                    .position(notePosition)
                    .opacity(drawProgress)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6)) {
                drawProgress = 1
            }
        }
    }

    private var markPath: Path {
        let rect = localTargetRect
        var path = Path()
        switch drawing.shape {
        case .circle:
            path.addEllipse(in: rect.insetBy(dx: -max(12, rect.width * 0.12), dy: -max(10, rect.height * 0.25)))
        case .box:
            path.addRoundedRect(in: rect.insetBy(dx: -8, dy: -6), cornerSize: CGSize(width: 8, height: 8))
        case .underline:
            let underlineY = rect.maxY + 5
            path.move(to: CGPoint(x: rect.minX - 4, y: underlineY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX + 4, y: underlineY + 1),
                control: CGPoint(x: rect.midX, y: underlineY + 5)
            )
        case .arrow:
            // From up and to the left (or the right, near the left edge),
            // ending just short of the target with an arrowhead.
            let comesFromLeft = rect.minX > 160
            let tip = CGPoint(x: comesFromLeft ? rect.minX - 6 : rect.maxX + 6, y: rect.midY)
            let tail = CGPoint(x: tip.x + (comesFromLeft ? -120 : 120), y: tip.y - 80)
            path.move(to: tail)
            path.addQuadCurve(to: tip, control: CGPoint(x: (tail.x + tip.x) / 2, y: tip.y - 70))
            let headAngle = atan2(tip.y - (tip.y - 70), tip.x - (tail.x + tip.x) / 2)
            for wingOffset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                path.move(to: tip)
                path.addLine(to: CGPoint(
                    x: tip.x + 16 * cos(headAngle + wingOffset),
                    y: tip.y + 16 * sin(headAngle + wingOffset)
                ))
            }
        }
        return path
    }

    private var notePosition: CGPoint {
        let rect = localTargetRect
        switch drawing.shape {
        case .arrow:
            let comesFromLeft = rect.minX > 160
            return CGPoint(x: rect.midX + (comesFromLeft ? -150 : 150), y: rect.midY - 96)
        default:
            return CGPoint(x: rect.midX, y: rect.maxY + 30)
        }
    }
}
