//
//  ClickyHotkeys.swift
//  leanring-buddy
//
//  Custom shortcuts for talking to Dottie and for dictation. Shipped Clicky
//  lets you record your own (ClickyHotkeyRecorder); v0 had the talk shortcut
//  hard-coded to ctrl + option.
//
//  A shortcut is either modifier keys held on their own (ctrl + option,
//  right option, fn) or modifiers plus one key (cmd + shift + space). Both
//  are matched in GlobalPushToTalkShortcutMonitor's listen-only event tap,
//  so they work in any app.
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

struct ClickyHotkey: Codable, Equatable {
    enum ModifierSide: String, Codable {
        case left
        case right
    }

    /// Device-independent modifiers (NSEvent.ModifierFlags raw value).
    var modifierFlagsRawValue: UInt
    /// The key held with the modifiers. Nil for a modifiers-only shortcut.
    var keyCode: UInt16?
    /// How the key is shown, e.g. "space" or "K".
    var keyDisplayName: String?
    /// For a single modifier held on its own: which side's key (right
    /// option, not either option).
    var modifierSide: ModifierSide?

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    var isModifierOnly: Bool { keyCode == nil }

    static let defaultTalk = ClickyHotkey(
        modifierFlagsRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue,
        keyCode: nil,
        keyDisplayName: nil,
        modifierSide: nil
    )

    static let defaultDictation = ClickyHotkey(
        modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue,
        keyCode: nil,
        keyDisplayName: nil,
        modifierSide: .right
    )

    /// Modifiers a shortcut can use. Caps lock and the numeric-pad flag are
    /// ignored.
    static let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]
    /// fn rides along on arrow and F-key presses, so key shortcuts ignore it.
    private static let keyShortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// Device-dependent bits CGEvent and NSEvent set for each side's key.
    private static let sideFlags: [(modifier: NSEvent.ModifierFlags, left: UInt64, right: UInt64)] = [
        (.control, 0x01, 0x2000),
        (.shift, 0x02, 0x04),
        (.command, 0x08, 0x10),
        (.option, 0x20, 0x40)
    ]

    // MARK: - Display

    /// "ctrl + option", "right option", "cmd + shift + space".
    var displayText: String {
        keyCapsuleLabels.joined(separator: " + ")
    }

    var keyCapsuleLabels: [String] {
        var labels: [String] = []
        let orderedModifiers: [(NSEvent.ModifierFlags, String)] = [
            (.function, "fn"), (.control, "ctrl"), (.option, "option"), (.shift, "shift"), (.command, "cmd")
        ]
        for (modifier, name) in orderedModifiers where modifierFlags.contains(modifier) {
            if let modifierSide, isModifierOnly {
                labels.append("\(modifierSide.rawValue) \(name)")
            } else {
                labels.append(name)
            }
        }
        if let keyDisplayName {
            labels.append(keyDisplayName)
        }
        return labels
    }

    // MARK: - Matching

    /// Whether this event presses or releases the shortcut, given whether it
    /// was already held.
    func transition(
        eventType: CGEventType,
        keyCode eventKeyCode: UInt16,
        flagsRawValue: UInt64,
        wasPressed: Bool
    ) -> BuddyPushToTalkShortcut.ShortcutTransition {
        let heldModifiers = NSEvent.ModifierFlags(rawValue: UInt(flagsRawValue))

        guard let keyCode else {
            guard eventType == .flagsChanged else { return .none }
            if !wasPressed {
                // Press on exactly these modifiers, so ctrl + option + cmd
                // shortcuts in other apps don't start it.
                let isExactlyHeld = heldModifiers.intersection(Self.shortcutModifiers) == modifierFlags
                    && isOnlyChosenSideHeld(flagsRawValue: flagsRawValue)
                return isExactlyHeld ? .pressed : .none
            }
            // Once pressed, stay pressed while its keys are down, even if
            // another modifier is bumped.
            let isStillHeld = heldModifiers.isSuperset(of: modifierFlags)
                && isChosenSideDown(flagsRawValue: flagsRawValue)
            return isStillHeld ? .none : .released
        }

        if eventType == .keyDown
            && eventKeyCode == keyCode
            && heldModifiers.intersection(Self.keyShortcutModifiers) == modifierFlags
            && !wasPressed {
            return .pressed
        }
        if eventType == .keyUp && eventKeyCode == keyCode && wasPressed {
            return .released
        }
        return .none
    }

    /// For a sided single modifier, checks that key (and not the other
    /// side's) is down. Always true for other shortcuts.
    private func isOnlyChosenSideHeld(flagsRawValue: UInt64) -> Bool {
        guard let sideBits = chosenSideBits else { return true }
        return flagsRawValue & sideBits.wanted != 0 && flagsRawValue & sideBits.other == 0
    }

    private func isChosenSideDown(flagsRawValue: UInt64) -> Bool {
        guard let sideBits = chosenSideBits else { return true }
        return flagsRawValue & sideBits.wanted != 0
    }

    private var chosenSideBits: (wanted: UInt64, other: UInt64)? {
        guard let modifierSide,
              let sideFlag = Self.sideFlags.first(where: { $0.modifier == modifierFlags }) else { return nil }
        return modifierSide == .left ? (sideFlag.left, sideFlag.right) : (sideFlag.right, sideFlag.left)
    }

    /// Which side's key is down when exactly one of a modifier's keys is.
    static func heldSide(of modifier: NSEvent.ModifierFlags, flagsRawValue: UInt64) -> ModifierSide? {
        guard let sideFlag = sideFlags.first(where: { $0.modifier == modifier }) else { return nil }
        let isLeftDown = flagsRawValue & sideFlag.left != 0
        let isRightDown = flagsRawValue & sideFlag.right != 0
        if isLeftDown && !isRightDown { return .left }
        if isRightDown && !isLeftDown { return .right }
        return nil
    }

    // MARK: - Saving

    static let talkDefaultsKey = "clickyTalkHotkey"
    static let dictationDefaultsKey = "clickyDictationHotkey"

    static func load(forKey defaultsKey: String, fallback: ClickyHotkey) -> ClickyHotkey {
        guard let savedData = UserDefaults.standard.data(forKey: defaultsKey),
              let savedHotkey = try? JSONDecoder().decode(ClickyHotkey.self, from: savedData) else {
            return fallback
        }
        return savedHotkey
    }

    func save(forKey defaultsKey: String) {
        guard let encodedData = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(encodedData, forKey: defaultsKey)
    }

    // MARK: - Key names

    /// Keys whose characters don't name them well.
    private static let namedKeyCodes: [UInt16: String] = [
        49: "space", 36: "return", 48: "tab", 51: "delete", 117: "forward delete",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "home", 119: "end", 116: "page up", 121: "page down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        namedKeyCodes[keyCode]?.hasPrefix("F") == true
    }

    static func displayName(forKeyCode keyCode: UInt16, characters: String?) -> String {
        if let namedKey = namedKeyCodes[keyCode] {
            return namedKey
        }
        let trimmedCharacters = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCharacters.isEmpty ? "key \(keyCode)" : trimmedCharacters.uppercased()
    }
}

// MARK: - Recorder

/// Records a shortcut from the next keys pressed in the app's own windows.
/// Modifiers released without a key make a modifiers-only shortcut; a key
/// pressed with modifiers makes a key shortcut. Escape cancels.
@MainActor
final class ClickyHotkeyRecorder: ObservableObject {
    enum RecordingError: LocalizedError {
        case needsModifier
        case singleModifierTooCommon(String)

        var errorDescription: String? {
            switch self {
            case .needsModifier:
                return "Add ctrl, option, shift or cmd, or use an F key."
            case .singleModifierTooCommon(let keyName):
                return "\(keyName) on its own clashes with typing and app shortcuts. Use right option, right cmd, right ctrl, fn, or a combination."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var heldModifierLabels: [String] = []

    private var localEventMonitor: Any?
    private var peakModifiers: NSEvent.ModifierFlags = []
    private var peakSide: ClickyHotkey.ModifierSide?
    private var onFinish: ((Result<ClickyHotkey, RecordingError>?) -> Void)?

    /// `onFinish` gets the shortcut, an error, or nil when cancelled.
    func start(onFinish: @escaping (Result<ClickyHotkey, RecordingError>?) -> Void) {
        stop()
        self.onFinish = onFinish
        peakModifiers = []
        peakSide = nil
        heldModifierLabels = []
        isRecording = true

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.handle(event)
            }
            // Swallow keys while recording so they don't type or trigger.
            return nil
        }
    }

    func cancel() {
        finish(with: nil)
    }

    private func stop() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        localEventMonitor = nil
        isRecording = false
        heldModifierLabels = []
    }

    private func finish(with result: Result<ClickyHotkey, RecordingError>?) {
        let finishHandler = onFinish
        onFinish = nil
        stop()
        finishHandler?(result)
    }

    private func handle(_ event: NSEvent) {
        let heldModifiers = event.modifierFlags.intersection(ClickyHotkey.shortcutModifiers)

        if event.type == .keyDown {
            if event.keyCode == 53 && heldModifiers.isEmpty {
                finish(with: nil)
                return
            }
            let keyModifiers = heldModifiers.subtracting(.function)
            guard !keyModifiers.isEmpty || ClickyHotkey.isFunctionKey(event.keyCode) else {
                finish(with: .failure(.needsModifier))
                return
            }
            finish(with: .success(ClickyHotkey(
                modifierFlagsRawValue: keyModifiers.rawValue,
                keyCode: event.keyCode,
                keyDisplayName: ClickyHotkey.displayName(forKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers),
                modifierSide: nil
            )))
            return
        }

        // flagsChanged: grow the combination while keys go down, and record
        // it once they're all up again.
        if !heldModifiers.isEmpty {
            peakModifiers.formUnion(heldModifiers)
            if heldModifiers == peakModifiers, peakModifiers != .function {
                peakSide = ClickyHotkey.heldSide(of: peakModifiers, flagsRawValue: UInt64(event.modifierFlags.rawValue))
            }
            heldModifierLabels = ClickyHotkey(
                modifierFlagsRawValue: peakModifiers.rawValue,
                keyCode: nil,
                keyDisplayName: nil,
                modifierSide: nil
            ).keyCapsuleLabels
            return
        }

        guard !peakModifiers.isEmpty else { return }
        let isSingleModifier = [NSEvent.ModifierFlags.shift, .control, .option, .command].contains(peakModifiers)
        if isSingleModifier {
            let sideName = peakSide?.rawValue ?? "either"
            let modifierName = ClickyHotkey(modifierFlagsRawValue: peakModifiers.rawValue, keyCode: nil, keyDisplayName: nil, modifierSide: nil).displayText
            // Shift alone fires on every capital letter, and left-side keys
            // start most app shortcuts.
            guard peakModifiers != .shift, peakSide == .right else {
                finish(with: .failure(.singleModifierTooCommon("\(sideName) \(modifierName)")))
                return
            }
        }
        finish(with: .success(ClickyHotkey(
            modifierFlagsRawValue: peakModifiers.rawValue,
            keyCode: nil,
            keyDisplayName: nil,
            modifierSide: isSingleModifier ? peakSide : nil
        )))
    }
}

/// A settings control that shows a shortcut as key caps and records a new
/// one when clicked.
struct ClickyHotkeyRecorderField: View {
    let hotkey: ClickyHotkey
    /// Called with the new shortcut; returns an error message to show, or
    /// nil if it was accepted.
    let onRecord: (ClickyHotkey) -> String?
    /// Lets the owner pause the global shortcuts while recording, so
    /// pressing the old shortcut doesn't start talking.
    let onRecordingChanged: (Bool) -> Void

    @StateObject private var recorder = ClickyHotkeyRecorder()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: toggleRecording) {
                HStack(spacing: 4) {
                    if recorder.isRecording {
                        if recorder.heldModifierLabels.isEmpty {
                            Text("Press keys…")
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.accentText)
                        } else {
                            keyCaps(recorder.heldModifierLabels)
                        }
                    } else {
                        keyCaps(hotkey.keyCapsuleLabels)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(recorder.isRecording ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(recorder.isRecording ? "Press the new shortcut, or Escape to cancel" : "Click to change")

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .onDisappear {
            if recorder.isRecording {
                recorder.cancel()
            }
        }
    }

    private func keyCaps(_ labels: [String]) -> some View {
        ForEach(labels, id: \.self) { label in
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(DS.Colors.surface3)
                )
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.cancel()
            return
        }
        errorMessage = nil
        onRecordingChanged(true)
        recorder.start { result in
            onRecordingChanged(false)
            switch result {
            case .none:
                break
            case .some(.failure(let recordingError)):
                errorMessage = recordingError.localizedDescription
            case .some(.success(let recordedHotkey)):
                errorMessage = onRecord(recordedHotkey)
            }
        }
    }
}
