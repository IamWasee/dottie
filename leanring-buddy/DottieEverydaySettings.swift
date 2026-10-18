//
//  DottieEverydaySettings.swift
//  leanring-buddy
//
//  Home → Settings rows for the everyday pack: the type-to-ask and
//  fix-text shortcuts, focus mode (a toggle and what it blocks), and
//  undoing the last folder cleanup.
//

import AppKit
import SwiftUI

/// Rows for the Shortcuts group.
struct DottieEverydayShortcutRows: View {
    @ObservedObject var shortcuts: DottieGlobalShortcuts
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor
    @AppStorage(DottieTypeBar.speaksAnswersDefaultsKey) private var speaksTypedAnswers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            shortcutRow(label: "Type to Dottie", action: .askBar)
            everydayRow(label: "Read typed answers out loud") {
                Toggle("", isOn: $speaksTypedAnswers)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            everydayHint("Press it in any app to type a question under the notch. Enter sends, Esc closes, ↑ brings back what you asked before. Answers show as text unless this is on.")
            shortcutRow(label: "Fix selected text", action: .fixText)
            everydayHint("Select text anywhere and press it to fix spelling and grammar in place. Or just ask Dottie: \u{201C}make this shorter\u{201D}, \u{201C}translate this to Spanish\u{201D}.")
        }
    }

    private func shortcutRow(label: String, action: DottieGlobalShortcuts.Action) -> some View {
        let currentHotkey = shortcuts.hotkey(for: action)
        return VStack(alignment: .trailing, spacing: 4) {
            everydayRow(label: label) {
                HStack(spacing: 8) {
                    if currentHotkey != nil {
                        Button("Turn off") { _ = shortcuts.setHotkey(nil, for: action) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .pointerCursor()
                    }
                    ClickyHotkeyRecorderField(
                        hotkey: currentHotkey ?? DottieGlobalShortcuts.offPlaceholder,
                        onRecord: { shortcuts.setHotkey($0, for: action) },
                        onRecordingChanged: { isRecording in
                            shortcuts.isSuspendedForRecording = isRecording
                            shortcutMonitor.isSuspendedForRecording = isRecording
                        }
                    )
                }
            }
            if let problem = shortcuts.problems[action] {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
            }
        }
    }
}

/// The Everyday group: focus mode and cleanup.
struct DottieEverydaySettings: View {
    @ObservedObject var focus: DottieFocus
    @AppStorage(DottieFocus.blockedAppsDefaultsKey) private var blockedApps = DottieFocus.defaultBlockedApps
    @AppStorage(DottieFocus.blockedSitesDefaultsKey) private var blockedSites = DottieFocus.defaultBlockedSites
    @AppStorage(DottieFocus.blocksGamesDefaultsKey) private var blocksGames = true
    @AppStorage(DottieFocus.defaultMinutesDefaultsKey) private var focusMinutes = 25
    @State private var cleanupMessage: String?
    @State private var hasCleanupToUndo = DottieEveryday.shared.cleanup.hasUndo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            everydayRow(label: focus.isActive ? "Focus mode · \(focus.minutesLeft) min left" : "Focus mode") {
                Toggle("", isOn: Binding(
                    get: { focus.isActive },
                    set: { isOn in
                        if isOn {
                            _ = focus.start(minutes: Double(focusMinutes), block: [])
                        } else {
                            focus.stop(reason: .stoppedByUser)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            everydayRow(label: "Focus for") {
                Stepper(value: $focusMinutes, in: 5...240, step: 5) {
                    Text("\(focusMinutes) min")
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps to block")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                TextField("App names, comma-separated", text: $blockedApps)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("Sites to block")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                TextField("youtube.com, reddit.com…", text: $blockedSites)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            everydayRow(label: "Block games too") {
                Toggle("", isOn: $blocksGames)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            everydayHint("While focus is on, Dottie hides blocked apps and closes blocked sites, with a cheeky word in the notch. Or say \u{201C}focus for 45 minutes\u{201D}.")

            everydayRow(label: "Last folder cleanup") {
                Button("Undo it") {
                    cleanupMessage = DottieEveryday.shared.cleanup.undoLastCleanup()
                    hasCleanupToUndo = DottieEveryday.shared.cleanup.hasUndo
                }
                .disabled(!hasCleanupToUndo)
            }
            everydayHint(cleanupMessage ?? "Ask Dottie to \u{201C}clean up my Downloads\u{201D}. She shows a plan first, and anything removed goes to the Trash.")
        }
        .onAppear {
            hasCleanupToUndo = DottieEveryday.shared.cleanup.hasUndo
        }
    }
}

// MARK: - Row styling (matches Home's settings rows)

private func everydayRow<Accessory: View>(label: String, @ViewBuilder accessory: () -> Accessory) -> some View {
    HStack {
        Text(label)
            .font(.system(size: 13))
            .foregroundColor(DS.Colors.textPrimary)
        Spacer()
        accessory()
            .font(.system(size: 12))
    }
}

private func everydayHint(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundColor(DS.Colors.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
}
