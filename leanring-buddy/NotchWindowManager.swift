//
//  NotchWindowManager.swift
//  leanring-buddy
//
//  Hosts NotchRootView in a borderless panel pinned over the MacBook notch
//  (or a small pill at the top-center of the screen on Macs without one).
//
//  The panel keeps one fixed size, big enough for the largest surface, and
//  the black shape grows and shrinks inside it as a SwiftUI animation.
//  Resizing the window itself animated out of step with its content (you
//  could see the shape's edge lag behind) and made SwiftUI's hover events
//  flicker while the frame moved under the mouse, which looped the hover
//  peek open and shut. Hover is now tracked here from the mouse position,
//  and the panel lets clicks through everywhere outside the shape.
//

import AppKit
import Combine
import SwiftUI

/// Borderless panels can't become key by default; the text input needs it.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchWindowManager {
    /// The notch's size and where it sits, in global AppKit coordinates.
    struct NotchGeometry {
        let screen: NSScreen
        let notchWidth: CGFloat
        let notchHeight: CGFloat
        let hasPhysicalNotch: Bool

        var topCenter: CGPoint {
            CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        }
    }

    /// Room on each side of the closed notch for the Dot indicators.
    static let compactIndicatorWidth: CGFloat = 30
    /// Height of the row of file tiles in the hover peek.
    static let peekFilePileHeight: CGFloat = 74

    private let notchPresenter: NotchPresenter
    private var panel: NotchPanel?
    private var presenterCancellables: Set<AnyCancellable> = []
    private var screenChangeObserver: NSObjectProtocol?
    private(set) var notchGeometry: NotchGeometry?
    private var mouseTrackingTimer: Timer?
    /// Whether the mouse is over the shape, as last decided by trackMouse.
    private var isMouseOverShape = false
    private var mouseLeftShapeAt: Date?
    /// Leaving the shape only counts after this long, so brushing past the
    /// edge doesn't snap the peek shut.
    private static let hoverExitDelaySeconds: TimeInterval = 0.12

    init(notchPresenter: NotchPresenter) {
        self.notchPresenter = notchPresenter
    }

    func show() {
        guard panel == nil else { return }
        guard let geometry = Self.measureNotchGeometry() else { return }
        notchGeometry = geometry

        let notchPanel = NotchPanel(
            contentRect: Self.canvasFrame(geometry: geometry),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar so the shape can merge with the physical notch.
        notchPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.isMovable = false
        notchPanel.acceptsMouseMovedEvents = true
        notchPanel.hidesOnDeactivate = false
        notchPanel.isReleasedWhenClosed = false
        // Clicks pass through until the mouse is over the shape.
        notchPanel.ignoresMouseEvents = true

        let rootView = NotchRootView(
            notchPresenter: notchPresenter,
            notchWidth: geometry.notchWidth,
            notchHeight: geometry.notchHeight
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        notchPanel.contentView = hostingView

        panel = notchPanel
        notchPresenter.shapeSize = shapeSize(for: notchPresenter.surface, isHovering: notchPresenter.isHovering, geometry: geometry)
        notchPanel.orderFrontRegardless()

        bindPresenter()
        observeScreenChanges()
        startTrackingMouse()
    }

    func hide() {
        presenterCancellables.removeAll()
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
        isMouseOverShape = false
        mouseLeftShapeAt = nil
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Sizing

    private func bindPresenter() {
        notchPresenter.$surface
            .combineLatest(notchPresenter.$isHovering, notchPresenter.$dotSummaries, notchPresenter.$peekFiles)
            .removeDuplicates { previous, current in previous == current }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] surface, isHovering, _, _ in
                self?.resizePanel(for: surface, isHovering: isHovering)
            }
            .store(in: &presenterCancellables)
        notchPresenter.$isScreenJournalOn
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.resizePanel(for: self.notchPresenter.surface, isHovering: self.notchPresenter.isHovering)
            }
            .store(in: &presenterCancellables)
    }

    private func resizePanel(for surface: NotchPresenter.Surface, isHovering: Bool) {
        guard let panel, let notchGeometry else { return }
        let targetShapeSize = shapeSize(for: surface, isHovering: isHovering, geometry: notchGeometry)
        if targetShapeSize != notchPresenter.shapeSize {
            // NotchRootView animates the shape to its new size.
            notchPresenter.shapeSize = targetShapeSize
        }

        if surface == .textInput {
            // Take keyboard focus for typing without activating the app, so
            // whatever the user was working in stays frontmost.
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    /// The panel's fixed frame: room for the largest surface, hanging from
    /// the top-center of the screen.
    private static func canvasFrame(geometry: NotchGeometry) -> CGRect {
        let canvasSize = CGSize(
            width: min(max(geometry.notchWidth + 280, 500), geometry.screen.frame.width),
            height: geometry.notchHeight + 260
        )
        return CGRect(
            x: geometry.topCenter.x - canvasSize.width / 2,
            y: geometry.topCenter.y - canvasSize.height,
            width: canvasSize.width,
            height: canvasSize.height
        )
    }

    /// Size of the black shape for each surface. Everything grows downward
    /// from the top-center of the screen.
    private func shapeSize(for surface: NotchPresenter.Surface, isHovering: Bool, geometry: NotchGeometry) -> CGSize {
        let contentSize: CGSize
        switch surface {
        case .compact:
            if isHovering {
                // One row for the eyes and buttons, a row per Dot, then the
                // newest files the Dots made.
                let peekRowCount = notchPresenter.peekDotSummaries.count
                let peekListHeight: CGFloat = peekRowCount == 0 ? 0 : CGFloat(peekRowCount) * 22 + 10
                let peekFilesHeight: CGFloat = notchPresenter.peekFiles.isEmpty ? 0 : Self.peekFilePileHeight + 8
                let isPeekEmpty = peekRowCount == 0 && notchPresenter.peekFiles.isEmpty
                contentSize = CGSize(
                    width: isPeekEmpty ? geometry.notchWidth + 80 : max(geometry.notchWidth + 160, notchPresenter.peekFiles.isEmpty ? 360 : 390),
                    height: geometry.notchHeight + 28 + peekListHeight + peekFilesHeight
                )
            } else if notchPresenter.showsCompactDotIndicators {
                contentSize = CGSize(width: geometry.notchWidth + 2 * Self.compactIndicatorWidth, height: geometry.notchHeight)
            } else {
                contentSize = CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
            }
        case .listening, .thinking:
            contentSize = CGSize(width: max(geometry.notchWidth + 160, 360), height: geometry.notchHeight + 48)
        case .speaking:
            contentSize = CGSize(width: max(geometry.notchWidth + 220, 420), height: geometry.notchHeight + 76)
        case .textInput:
            contentSize = CGSize(width: max(geometry.notchWidth + 240, 440), height: geometry.notchHeight + 64)
        case .textResponse:
            contentSize = CGSize(width: max(geometry.notchWidth + 240, 440), height: geometry.notchHeight + 150)
        case .screenTask:
            contentSize = CGSize(width: max(geometry.notchWidth + 240, 440), height: geometry.notchHeight + 70)
        }

        return contentSize
    }

    // MARK: - Hover

    /// Polls the mouse rather than relying on tracking areas: cheap, and it
    /// works while the panel ignores mouse events.
    private func startTrackingMouse() {
        mouseTrackingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trackMouse()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTrackingTimer = timer
    }

    private func trackMouse() {
        guard let panel, let notchGeometry else { return }
        let mouseLocation = NSEvent.mouseLocation
        let shapeSize = notchPresenter.shapeSize
        let shapeRect = CGRect(
            x: notchGeometry.topCenter.x - shapeSize.width / 2,
            y: notchGeometry.topCenter.y - shapeSize.height,
            width: shapeSize.width,
            height: shapeSize.height
        )
        // A little slack, and the top edge counts (the mouse can rest at the
        // very top of the screen).
        let isInsideShape = shapeRect.insetBy(dx: -4, dy: -4).contains(mouseLocation)

        let shouldIgnoreMouseEvents = !isInsideShape
        if panel.ignoresMouseEvents != shouldIgnoreMouseEvents {
            panel.ignoresMouseEvents = shouldIgnoreMouseEvents
        }

        if isInsideShape {
            mouseLeftShapeAt = nil
            if !isMouseOverShape {
                isMouseOverShape = true
                notchPresenter.isHovering = true
            }
        } else if isMouseOverShape {
            // Hysteresis: the shape just grew because of the hover, so it's
            // the grown shape the mouse has to leave, for a moment, before
            // the peek closes. It can't flicker open and shut.
            let leftAt = mouseLeftShapeAt ?? Date()
            mouseLeftShapeAt = leftAt
            if Date().timeIntervalSince(leftAt) >= Self.hoverExitDelaySeconds {
                isMouseOverShape = false
                mouseLeftShapeAt = nil
                notchPresenter.isHovering = false
            }
        }
    }

    // MARK: - Geometry

    /// Prefers the built-in display with a notch; otherwise uses the main
    /// screen and pretends there's a notch the height of the menu bar.
    static func measureNotchGeometry() -> NotchGeometry? {
        let screenWithNotch = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = screenWithNotch ?? NSScreen.main ?? NSScreen.screens.first else { return nil }

        if screen.safeAreaInsets.top > 0,
           let topLeftUnobscuredArea = screen.auxiliaryTopLeftArea,
           let topRightUnobscuredArea = screen.auxiliaryTopRightArea {
            let notchWidth = screen.frame.width - topLeftUnobscuredArea.width - topRightUnobscuredArea.width
            return NotchGeometry(
                screen: screen,
                notchWidth: notchWidth,
                notchHeight: screen.safeAreaInsets.top,
                hasPhysicalNotch: true
            )
        }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(
            screen: screen,
            notchWidth: 190,
            notchHeight: max(menuBarHeight, 24),
            hasPhysicalNotch: false
        )
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Rebuild so the SwiftUI view gets the new notch size.
                self.hide()
                self.show()
            }
        }
    }
}
