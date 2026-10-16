//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Fires on every Escape key-down anywhere in the system. The companion
    /// uses it to cut off an answer mid-sentence, like shipped Clicky's
    /// escape-interrupt. The tap is listen-only, so Escape still reaches the
    /// frontmost app as usual.
    let escapeKeyPressedPublisher = PassthroughSubject<Void, Never>()
    private static let escapeKeyCode: UInt16 = 53

    /// Hold-to-dictate: right Option held on its own. Kept apart from the
    /// talk-to-Clicky shortcut (ctrl + option) so the two never overlap.
    let dictationShortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Any key pressed while the dictation key is held. Right Option also
    /// types special characters (option-e, option-2…), so a key press means
    /// the user wasn't dictating and the recording should be thrown away.
    let keyPressedDuringDictationPublisher = PassthroughSubject<Void, Never>()
    static let dictationShortcutDisplayText = "right option"
    /// Device-dependent bits CGEvent sets for each Option key.
    private static let rightOptionDeviceFlag: UInt64 = 0x40
    private static let leftOptionDeviceFlag: UInt64 = 0x20
    private var isDictationShortcutCurrentlyPressed = false

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if eventType == .keyDown && eventKeyCode == Self.escapeKeyCode {
            escapeKeyPressedPublisher.send(())
        }

        handleDictationShortcut(eventType: eventType, modifierFlagsRawValue: event.flags.rawValue)
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleDictationShortcut(eventType: CGEventType, modifierFlagsRawValue: UInt64) {
        if eventType == .keyDown && isDictationShortcutCurrentlyPressed {
            keyPressedDuringDictationPublisher.send(())
            return
        }
        guard eventType == .flagsChanged else { return }

        let deviceIndependentModifiers = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection([.shift, .control, .option, .command])
        let isOnlyRightOptionHeld = deviceIndependentModifiers == [.option]
            && modifierFlagsRawValue & Self.rightOptionDeviceFlag != 0
            && modifierFlagsRawValue & Self.leftOptionDeviceFlag == 0

        if isOnlyRightOptionHeld && !isDictationShortcutCurrentlyPressed {
            isDictationShortcutCurrentlyPressed = true
            dictationShortcutTransitionPublisher.send(.pressed)
        } else if !isOnlyRightOptionHeld && isDictationShortcutCurrentlyPressed {
            isDictationShortcutCurrentlyPressed = false
            dictationShortcutTransitionPublisher.send(.released)
        }
    }
}
