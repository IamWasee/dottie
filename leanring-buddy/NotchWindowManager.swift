//
//  NotchWindowManager.swift
//  leanring-buddy
//
//  Hosts NotchRootView in a borderless panel pinned over the MacBook notch
//  (or a small pill at the top-center of the screen on Macs without one).
//  The panel is resized to fit each surface so it never covers the menu bar
//  more than it needs to: while compact it is exactly the notch.
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

    private let notchPresenter: NotchPresenter
    private var panel: NotchPanel?
    private var presenterCancellables: Set<AnyCancellable> = []
    private var screenChangeObserver: NSObjectProtocol?
    private(set) var notchGeometry: NotchGeometry?

    init(notchPresenter: NotchPresenter) {
        self.notchPresenter = notchPresenter
    }

    func show() {
        guard panel == nil else { return }
        guard let geometry = Self.measureNotchGeometry() else { return }
        notchGeometry = geometry

        let notchPanel = NotchPanel(
            contentRect: frame(for: .compact, isHovering: false, geometry: geometry),
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
        notchPanel.orderFrontRegardless()

        bindPresenter()
        observeScreenChanges()
    }

    func hide() {
        presenterCancellables.removeAll()
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
            .combineLatest(notchPresenter.$isHovering)
            .removeDuplicates { previous, current in previous == current }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] surface, isHovering in
                self?.resizePanel(for: surface, isHovering: isHovering)
            }
            .store(in: &presenterCancellables)
    }

    private func resizePanel(for surface: NotchPresenter.Surface, isHovering: Bool) {
        guard let panel, let notchGeometry else { return }
        let targetFrame = frame(for: surface, isHovering: isHovering, geometry: notchGeometry)

        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.22
            animationContext.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }

        if surface == .textInput {
            // Take keyboard focus for typing without activating the app, so
            // whatever the user was working in stays frontmost.
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    /// Size of the black shape for each surface. Everything grows downward
    /// from the top-center of the screen.
    private func frame(for surface: NotchPresenter.Surface, isHovering: Bool, geometry: NotchGeometry) -> CGRect {
        let contentSize: CGSize
        switch surface {
        case .compact:
            contentSize = isHovering
                ? CGSize(width: geometry.notchWidth + 80, height: geometry.notchHeight + 28)
                : CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        case .listening, .thinking:
            contentSize = CGSize(width: max(geometry.notchWidth + 160, 360), height: geometry.notchHeight + 48)
        case .speaking:
            contentSize = CGSize(width: max(geometry.notchWidth + 220, 420), height: geometry.notchHeight + 76)
        case .textInput:
            contentSize = CGSize(width: max(geometry.notchWidth + 240, 440), height: geometry.notchHeight + 64)
        case .textResponse:
            contentSize = CGSize(width: max(geometry.notchWidth + 240, 440), height: geometry.notchHeight + 150)
        }

        return CGRect(
            x: geometry.topCenter.x - contentSize.width / 2,
            y: geometry.topCenter.y - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
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
