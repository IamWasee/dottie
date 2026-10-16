//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures the talk and dictation shortcuts while Dottie is running in the
//  background. Uses a CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool. Both
//  shortcuts can be changed in Settings (ClickyHotkeys.swift).
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

    /// Hold-to-dictate, right option by default. Settings keeps it different
    /// from the talk shortcut.
    let dictationShortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Any other key pressed while the dictation shortcut is held. Option
    /// also types special characters (option-e, option-2…), so a key press
    /// means the user wasn't dictating and the recording should be thrown
    /// away.
    let keyPressedDuringDictationPublisher = PassthroughSubject<Void, Never>()
    private var isDictationShortcutCurrentlyPressed = false

    /// The shortcuts, saved in UserDefaults. Changing one releases it if it
    /// was held, so nothing stays stuck on.
    @Published private(set) var talkHotkey = ClickyHotkey.load(forKey: ClickyHotkey.talkDefaultsKey, fallback: .defaultTalk)
    @Published private(set) var dictationHotkey = ClickyHotkey.load(forKey: ClickyHotkey.dictationDefaultsKey, fallback: .defaultDictation)

    /// True while Settings records a new shortcut, so pressing keys there
    /// doesn't start talking or dictating.
    var isSuspendedForRecording = false {
        didSet {
            if isSuspendedForRecording { releaseHeldShortcuts() }
        }
    }

    /// Whether the tap can swallow events. A shortcut with a letter or other
    /// key would otherwise also type that key into the front app. Needs
    /// Accessibility; without it the tap only listens.
    private var isEventTapActive = false

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

    // MARK: - Changing shortcuts

    /// Saves a new talk shortcut. Returns an error message instead if it
    /// clashes with dictation.
    func setTalkHotkey(_ newHotkey: ClickyHotkey) -> String? {
        guard newHotkey != dictationHotkey else {
            return "That's already the dictation shortcut."
        }
        releaseHeldShortcuts()
        talkHotkey = newHotkey
        newHotkey.save(forKey: ClickyHotkey.talkDefaultsKey)
        return nil
    }

    /// Saves a new dictation shortcut. Returns an error message instead if
    /// it clashes with talking to Dottie.
    func setDictationHotkey(_ newHotkey: ClickyHotkey) -> String? {
        guard newHotkey != talkHotkey else {
            return "That's already the shortcut for talking to Dottie."
        }
        releaseHeldShortcuts()
        dictationHotkey = newHotkey
        newHotkey.save(forKey: ClickyHotkey.dictationDefaultsKey)
        return nil
    }

    func resetHotkeysToDefaults() {
        releaseHeldShortcuts()
        talkHotkey = .defaultTalk
        dictationHotkey = .defaultDictation
        UserDefaults.standard.removeObject(forKey: ClickyHotkey.talkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: ClickyHotkey.dictationDefaultsKey)
    }

    private func releaseHeldShortcuts() {
        if isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }
        if isDictationShortcutCurrentlyPressed {
            isDictationShortcutCurrentlyPressed = false
            dictationShortcutTransitionPublisher.send(.released)
        }
    }

    // MARK: - Event tap

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

        // An active tap can swallow a key shortcut's key so it doesn't also
        // type. It needs Accessibility; fall back to listening without it.
        let createTap = { (tapOptions: CGEventTapOptions) in
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: tapOptions,
                eventsOfInterest: eventMask,
                callback: eventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }
        let activeEventTap = AXIsProcessTrusted() ? createTap(.defaultTap) : nil
        guard let globalEventTap = activeEventTap ?? createTap(.listenOnly) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }
        isEventTapActive = activeEventTap != nil

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

        guard !isSuspendedForRecording else {
            return Unmanaged.passUnretained(event)
        }

        let flagsRawValue = event.flags.rawValue
        let isDictationKeyEvent = handleDictationShortcut(
            eventType: eventType,
            keyCode: eventKeyCode,
            flagsRawValue: flagsRawValue
        )
        let isTalkKeyEvent = handleTalkShortcut(
            eventType: eventType,
            keyCode: eventKeyCode,
            flagsRawValue: flagsRawValue
        )

        // Swallow a key shortcut's own key (including key repeats) so it
        // doesn't also type into the front app.
        if isEventTapActive && (isTalkKeyEvent || isDictationKeyEvent) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// Returns true when the event is the shortcut's own key going down,
    /// repeating or coming up.
    private func handleTalkShortcut(eventType: CGEventType, keyCode: UInt16, flagsRawValue: UInt64) -> Bool {
        let wasPressed = isShortcutCurrentlyPressed
        let transition = talkHotkey.transition(
            eventType: eventType,
            keyCode: keyCode,
            flagsRawValue: flagsRawValue,
            wasPressed: wasPressed
        )

        switch transition {
        case .none:
            break
        case .pressed:
            // Adding keys to the dictation shortcut can make the talk one
            // (right option, then ctrl). Only one uses the mic at a time.
            if isDictationShortcutCurrentlyPressed {
                isDictationShortcutCurrentlyPressed = false
                dictationShortcutTransitionPublisher.send(.released)
            }
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Self.isOwnKeyEvent(of: talkHotkey, eventType: eventType, keyCode: keyCode, wasPressed: wasPressed, transition: transition)
    }

    private func handleDictationShortcut(eventType: CGEventType, keyCode: UInt16, flagsRawValue: UInt64) -> Bool {
        let wasPressed = isDictationShortcutCurrentlyPressed
        let transition = dictationHotkey.transition(
            eventType: eventType,
            keyCode: keyCode,
            flagsRawValue: flagsRawValue,
            wasPressed: wasPressed
        )

        switch transition {
        case .none:
            if eventType == .keyDown && wasPressed && keyCode != dictationHotkey.keyCode {
                keyPressedDuringDictationPublisher.send(())
            }
        case .pressed:
            guard !isShortcutCurrentlyPressed else { break }
            isDictationShortcutCurrentlyPressed = true
            dictationShortcutTransitionPublisher.send(.pressed)
        case .released:
            isDictationShortcutCurrentlyPressed = false
            dictationShortcutTransitionPublisher.send(.released)
        }

        return Self.isOwnKeyEvent(of: dictationHotkey, eventType: eventType, keyCode: keyCode, wasPressed: wasPressed, transition: transition)
    }

    private static func isOwnKeyEvent(
        of hotkey: ClickyHotkey,
        eventType: CGEventType,
        keyCode: UInt16,
        wasPressed: Bool,
        transition: BuddyPushToTalkShortcut.ShortcutTransition
    ) -> Bool {
        guard let hotkeyKeyCode = hotkey.keyCode, keyCode == hotkeyKeyCode,
              eventType == .keyDown || eventType == .keyUp else { return false }
        return transition != .none || wasPressed
    }
}
