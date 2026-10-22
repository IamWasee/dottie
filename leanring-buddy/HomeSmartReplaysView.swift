//
//  HomeSmartReplaysView.swift
//  leanring-buddy
//
//  Home → Smart Replays: every replay the user showed Dottie, each one
//  editable in place (name, smart or commercial, steps, the line she says
//  at the end, the phrases that start it), with Run and Delete. Changes
//  are saved when the user presses Save, so half-typed steps never run.
//

import SwiftUI

struct HomeSmartReplaysView: View {
    @ObservedObject var smartReplayStore: DottieSmartReplayStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Replays")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Say \u{201C}create a smart replay of me doing this\u{201D} (or \u{201C}a commercial replay\u{201D}), do the job, then say \u{201C}done\u{201D}. Dottie keeps it as steps by what they mean, so it still works when the screen looks different. Commercial replays are for filming: exactly these steps, at a calm pace, nothing extra.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if smartReplayStore.replays.isEmpty {
                    HomeCard(title: "No smart replays yet") {
                        HomeHint("Show Dottie something once and it appears here, ready to edit.")
                    }
                } else {
                    ForEach(Array(smartReplayStore.replays.enumerated()), id: \.element.id) { listIndex, smartReplay in
                        HomeSmartReplayEditorCard(
                            listNumber: listIndex + 1,
                            savedSmartReplay: smartReplay,
                            smartReplayStore: smartReplayStore
                        )
                        // A fresh editor when the saved copy changes (by voice,
                        // or the closing-line box), so the fields show it.
                        .id("\(smartReplay.id)-\(smartReplay.hashValueForEditing)")
                    }
                }
            }
            .padding(24)
        }
    }
}

private extension DottieSmartReplay {
    /// Changes whenever anything the editor shows changes.
    var hashValueForEditing: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(kind)
        hasher.combine(steps)
        hasher.combine(closingMessage)
        hasher.combine(voiceShortcuts)
        return hasher.finalize()
    }
}

/// One replay, edited in place. Holds its own draft until Save.
private struct HomeSmartReplayEditorCard: View {
    let listNumber: Int
    let savedSmartReplay: DottieSmartReplay
    @ObservedObject var smartReplayStore: DottieSmartReplayStore

    @State private var draftSmartReplay: DottieSmartReplay
    @State private var draftShortcutsText: String
    @State private var draftClosingMessage: String
    @State private var statusMessage: String?

    init(listNumber: Int, savedSmartReplay: DottieSmartReplay, smartReplayStore: DottieSmartReplayStore) {
        self.listNumber = listNumber
        self.savedSmartReplay = savedSmartReplay
        self.smartReplayStore = smartReplayStore
        _draftSmartReplay = State(initialValue: savedSmartReplay)
        _draftShortcutsText = State(initialValue: savedSmartReplay.voiceShortcuts.joined(separator: "\n"))
        _draftClosingMessage = State(initialValue: savedSmartReplay.closingMessage ?? "")
    }

    private var draftWithTextFields: DottieSmartReplay {
        var replayToSave = draftSmartReplay
        replayToSave.voiceShortcuts = draftShortcutsText.components(separatedBy: .newlines)
        replayToSave.closingMessage = draftClosingMessage
        return replayToSave
    }

    private var hasUnsavedChanges: Bool {
        draftSmartReplay != savedSmartReplay
            || draftShortcutsText != savedSmartReplay.voiceShortcuts.joined(separator: "\n")
            || draftClosingMessage != (savedSmartReplay.closingMessage ?? "")
    }

    var body: some View {
        HomeCard(title: "\(listNumber). \(savedSmartReplay.kind.title)") {
            HStack(spacing: 8) {
                TextField("Name", text: $draftSmartReplay.name)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $draftSmartReplay.kind) {
                    ForEach(DottieSmartReplay.Kind.allCases, id: \.self) { replayKind in
                        Text(replayKind.title).tag(replayKind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .pointerCursor()
            }

            Text("Steps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            ForEach(Array(draftSmartReplay.steps.indices), id: \.self) { stepIndex in
                HStack(spacing: 6) {
                    Text("\(stepIndex + 1).")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 22, alignment: .trailing)
                    TextField("What to do", text: stepBinding(at: stepIndex))
                        .textFieldStyle(.roundedBorder)
                    stepIconButton(systemName: "arrow.up", helpText: "Move up", isEnabled: stepIndex > 0) {
                        draftSmartReplay.steps.swapAt(stepIndex, stepIndex - 1)
                    }
                    stepIconButton(systemName: "arrow.down", helpText: "Move down", isEnabled: stepIndex < draftSmartReplay.steps.count - 1) {
                        draftSmartReplay.steps.swapAt(stepIndex, stepIndex + 1)
                    }
                    stepIconButton(systemName: "minus.circle", helpText: "Remove this step", isEnabled: true) {
                        draftSmartReplay.steps.remove(at: stepIndex)
                    }
                }
            }
            Button("Add a step") {
                draftSmartReplay.steps.append("")
            }
            .controlSize(.small)
            .pointerCursor()

            Text("Say at the end of every run")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            TextField("Nothing", text: $draftClosingMessage)
                .textFieldStyle(.roundedBorder)

            Text("Phrases that start it (one per line, anything that means the same works too)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            TextEditor(text: $draftShortcutsText)
                .font(.system(size: 12))
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                Button("Save") {
                    smartReplayStore.save(draftWithTextFields)
                    statusMessage = "Saved."
                }
                .disabled(!hasUnsavedChanges)
                .keyboardShortcut(.defaultAction)
                .pointerCursor(isEnabled: hasUnsavedChanges)

                Button("Run") {
                    if hasUnsavedChanges {
                        smartReplayStore.save(draftWithTextFields)
                    }
                    guard let startSmartReplayJob = DottieSmartReplayTools.startSmartReplayJob,
                          let replayToRun = smartReplayStore.replay(withID: savedSmartReplay.id) else {
                        statusMessage = "Replays can't run right now."
                        return
                    }
                    statusMessage = startSmartReplayJob(replayToRun, nil)
                }
                .pointerCursor()

                Spacer()

                Text(runSummary)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)

                Button("Delete", role: .destructive) {
                    let isConfirmed = DottieConfirmation.ask(
                        title: "Delete the smart replay \u{201C}\(savedSmartReplay.name)\u{201D}?",
                        detail: "Its \(savedSmartReplay.steps.count) steps, closing line and shortcuts are removed.",
                        confirmButtonTitle: "Delete"
                    )
                    if isConfirmed {
                        smartReplayStore.delete(savedSmartReplay.id)
                    }
                }
                .pointerCursor()
            }

            if let statusMessage {
                HomeHint(statusMessage)
            }
        }
    }

    private var runSummary: String {
        guard let lastRunAt = savedSmartReplay.lastRunAt else { return "Never run" }
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short
        let timesText = savedSmartReplay.runCount == 1 ? "1 run" : "\(savedSmartReplay.runCount) runs"
        return "\(timesText), last \(relativeFormatter.localizedString(for: lastRunAt, relativeTo: Date()))"
    }

    /// A binding that survives the step being removed while SwiftUI still
    /// draws the old row.
    private func stepBinding(at stepIndex: Int) -> Binding<String> {
        Binding(
            get: { draftSmartReplay.steps.indices.contains(stepIndex) ? draftSmartReplay.steps[stepIndex] : "" },
            set: { newStepText in
                guard draftSmartReplay.steps.indices.contains(stepIndex) else { return }
                draftSmartReplay.steps[stepIndex] = newStepText
            }
        )
    }

    private func stepIconButton(systemName: String, helpText: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(helpText)
        .pointerCursor(isEnabled: isEnabled)
    }
}
