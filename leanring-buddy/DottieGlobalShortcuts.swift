//
//  DottieGlobalShortcuts.swift
//  leanring-buddy
//
//  Press-once shortcuts that work in any app: open the type-to-ask bar
//  (option + space by default) and fix the selected text (off until the
//  user picks one). Unlike the hold-to-talk shortcuts, these are plain
//  system hot keys (Carbon's RegisterEventHotKey): the key press never
//  reaches the app in front, no Accessibility permission is needed, and
//  macOS refuses one another app already owns, so we can say so.
//

import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class DottieGlobalShortcuts: ObservableObject {
    enum Action: UInt32, CaseIterable {
        case askBar = 1
        case fixText = 2

        var defaultsKey: String {
            switch self {
            case .askBar: return "dottieAskBarHotkey"
            case .fixText: return "dottieFixTextHotkey"
            }
        }

        /// Set when the user turned the shortcut off.
        var offDefaultsKey: String { defaultsKey + "Off" }

        var defaultHotkey: ClickyHotkey? {
            switch self {
            case .askBar:
                return ClickyHotkey(
                    modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue,
                    keyCode: 49,
                    keyDisplayName: "space",
                    modifierSide: nil
                )
            case .fixText:
                return nil
            }
        }
    }

    /// Shown in the recorder field when a shortcut is off.
    static let offPlaceholder = ClickyHotkey(modifierFlagsRawValue: 0, keyCode: nil, keyDisplayName: "off", modifierSide: nil)

    nonisolated static let hotKeySignature: OSType = 0x444F_5445 // "DOTE"
    private static weak var current: DottieGlobalShortcuts?

    @Published private(set) var hotkeys: [Action: ClickyHotkey] = [:]
    /// Why a shortcut couldn't be turned on (another app owns it).
    @Published private(set) var problems: [Action: String] = [:]

    var onAction: ((Action) -> Void)?
    /// Says whether a shortcut clashes with talk or dictation.
    var clashCheck: ((ClickyHotkey) -> String?)?

    /// While Settings records a shortcut, ours are off so pressing the old
    /// one doesn't fire.
    var isSuspendedForRecording = false {
        didSet {
            guard isSuspendedForRecording != oldValue else { return }
            if isSuspendedForRecording { unregisterAll() } else { registerAll() }
        }
    }

    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    init() {
        for action in Action.allCases {
            if let hotkey = Self.load(action) {
                hotkeys[action] = hotkey
            }
        }
    }

    func start() {
        Self.current = self
        installEventHandlerIfNeeded()
        registerAll()
    }

    func hotkey(for action: Action) -> ClickyHotkey? {
        hotkeys[action]
    }

    /// Saves a shortcut, or turns it off with nil. Returns an error to show
    /// instead when it can't be used.
    func setHotkey(_ newHotkey: ClickyHotkey?, for action: Action) -> String? {
        if let newHotkey {
            guard !newHotkey.isModifierOnly else {
                return "Use modifier keys with a key here, like option + space."
            }
            if let clashMessage = clashCheck?(newHotkey) {
                return clashMessage
            }
            if let otherAction = Action.allCases.first(where: { $0 != action && hotkeys[$0] == newHotkey }) {
                return otherAction == .askBar ? "That's already the shortcut for typing to Dottie." : "That's already the fix-text shortcut."
            }
        }
        unregister(action)
        hotkeys[action] = newHotkey
        Self.save(newHotkey, for: action)
        if !isSuspendedForRecording {
            register(action)
        }
        return problems[action]
    }

    // MARK: - Saving

    private static func load(_ action: Action) -> ClickyHotkey? {
        let defaults = UserDefaults.standard
        if let savedData = defaults.data(forKey: action.defaultsKey),
           let savedHotkey = try? JSONDecoder().decode(ClickyHotkey.self, from: savedData) {
            return savedHotkey
        }
        if defaults.bool(forKey: action.offDefaultsKey) { return nil }
        return action.defaultHotkey
    }

    private static func save(_ hotkey: ClickyHotkey?, for action: Action) {
        let defaults = UserDefaults.standard
        if let hotkey, let encodedData = try? JSONEncoder().encode(hotkey) {
            defaults.set(encodedData, forKey: action.defaultsKey)
            defaults.removeObject(forKey: action.offDefaultsKey)
        } else {
            defaults.removeObject(forKey: action.defaultsKey)
            defaults.set(true, forKey: action.offDefaultsKey)
        }
    }

    // MARK: - Registering

    private func registerAll() {
        for action in Action.allCases {
            register(action)
        }
    }

    private func unregisterAll() {
        for action in Action.allCases {
            unregister(action)
        }
    }

    private func register(_ action: Action) {
        unregister(action)
        problems[action] = nil
        guard let hotkey = hotkeys[action], let keyCode = hotkey.keyCode else { return }
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(hotkey.modifierFlags),
            EventHotKeyID(signature: Self.hotKeySignature, id: action.rawValue),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            hotKeyRefs[action] = hotKeyRef
        } else {
            problems[action] = "Another app already uses \(hotkey.displayText). Pick a different shortcut."
            print("⚠️ Dottie: couldn't register \(hotkey.displayText) (\(status))")
        }
    }

    private func unregister(_ action: Action) {
        if let hotKeyRef = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ -> OSStatus in
                guard let eventRef else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr, hotKeyID.signature == DottieGlobalShortcuts.hotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                let actionRawValue = hotKeyID.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        DottieGlobalShortcuts.fire(actionRawValue)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            print("⚠️ Dottie: couldn't listen for shortcuts (\(status))")
        }
    }

    private static func fire(_ actionRawValue: UInt32) {
        guard let current, !current.isSuspendedForRecording,
              let action = Action(rawValue: actionRawValue) else { return }
        current.onAction?(action)
    }

    private static func carbonModifiers(_ modifierFlags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0
        if modifierFlags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        return carbonFlags
    }
}
