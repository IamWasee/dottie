//
//  HomeAdminView.swift
//  leanring-buddy
//
//  Home → Admin, the secret tab (DottieAdminMode): admin unlocks (every
//  profile cosmetic, a free level) and beta features (the human auto
//  typer). Only in the sidebar once the secret phrase was said to Dottie.
//

import AppKit
import SwiftUI

struct HomeAdminView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var adminMode = DottieAdminMode.shared
    @ObservedObject private var levels = DottieLevels.shared
    @ObservedObject private var autoTyper = DottieAutoTyper.shared
    @AppStorage("dottieAutoTyperDraftText") private var draftText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                section(title: "Admin unlocks") {
                    VStack(alignment: .leading, spacing: 12) {
                        row(label: "Unlock every profile cosmetic") {
                            Toggle("", isOn: Binding(
                                get: { levels.isEveryUnlockOpenedByAdmin },
                                set: { levels.setEveryUnlockOpenedByAdmin($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                        hint("Every cursor shape and notch effect in Profile, whatever Dottie's level.")
                        row(label: "Level \(levels.level) · \(levels.levelName)") {
                            Button("Skip to level \(levels.level + 1)") { levels.adminGrantNextLevel() }
                                .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                        }
                    }
                    .padding(16)
                    .background(cardBackground)
                }

                section(title: "Beta · Human auto typer") {
                    autoTyperCard
                }

                section(title: "Hide this tab") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Lock the Admin tab") { adminMode.lock() }
                            .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                        hint("Takes the admin unlocks back and hides this tab until you say the phrase to Dottie again.")
                    }
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Admin")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("BETA")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(DS.Colors.accent))
            Spacer(minLength: 0)
            Text("You found the secret tab.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Auto typer

    private var autoTyperCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a paragraph or code. Dottie types it into the app you were using, one real key press at a time: uneven speed, pauses at punctuation and new lines, and typos she backspaces and fixes. Google Docs and similar apps build a normal version history. Press Esc to stop.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $draftText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 240)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                if autoTyper.isBusy {
                    Button("Stop") { autoTyper.stop() }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                } else {
                    Button("Start typing") {
                        autoTyper.start(text: draftText, handFocusBackToPreviousApp: true)
                    }
                    .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("Paste from clipboard") {
                    draftText = NSPasteboard.general.string(forType: .string) ?? draftText
                }
                .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                if !draftText.isEmpty && !autoTyper.isBusy {
                    Button("Clear") { draftText = "" }
                        .buttonStyle(DSTextButtonStyle(fontSize: 12))
                }
                Spacer(minLength: 0)
                Text("\(draftText.count) characters")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            autoTyperStatus

            Divider()

            sliderRow(
                label: "Speed",
                valueText: "\(Int(autoTyper.settings.wordsPerMinute)) words a minute",
                value: $autoTyper.settings.wordsPerMinute,
                range: 20...160,
                step: 5
            )
            sliderRow(
                label: "Typos",
                valueText: autoTyper.settings.typoChance == 0 ? "none" : "about \(Int((autoTyper.settings.typoChance * 100).rounded())) in 100 letters",
                value: $autoTyper.settings.typoChance,
                range: 0...0.12,
                step: 0.01
            )
            sliderRow(
                label: "Unevenness",
                valueText: unevennessText,
                value: $autoTyper.settings.speedVariation,
                range: 0...1,
                step: 0.1
            )
            sliderRow(
                label: "Wait before typing",
                valueText: "\(Int(autoTyper.settings.startDelaySeconds)) s",
                value: $autoTyper.settings.startDelaySeconds,
                range: 1...10,
                step: 1
            )
            row(label: "Stop to think now and then") {
                Toggle("", isOn: $autoTyper.settings.thinkingPauses)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            row(label: "Typing a new file in a code editor") {
                Toggle("", isOn: $autoTyper.settings.editorIndentsNewLines)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            hint("Turn this on for code editors like VS Code, IntelliJ or Xcode, in a new or empty file: the editor's own indentation and the brackets, quotes and tags it adds itself don't double up. Anything after the cursor is cleared at each new line. You can also say \u{201C}type what's on my clipboard like a human\u{201D} to Dottie.")
        }
        .padding(16)
        .background(cardBackground)
    }

    private var unevennessText: String {
        switch autoTyper.settings.speedVariation {
        case ..<0.25: return "steady"
        case ..<0.6: return "natural"
        default: return "very uneven"
        }
    }

    @ViewBuilder
    private var autoTyperStatus: some View {
        switch autoTyper.phase {
        case .idle:
            if let lastProblemText = autoTyper.lastProblemText {
                Text(lastProblemText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
            }
        case .countingDown(let secondsLeft):
            Text("Click where it should type. Starting in \(secondsLeft)…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
        case .typing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(autoTyper.typedCharacterCount), total: Double(max(autoTyper.totalCharacterCount, 1)))
                    .tint(DS.Colors.accent)
                Text("Typing at about \(Int(autoTyper.currentWordsPerMinute)) words a minute · \(autoTyper.fixedTypoCount) typos fixed · Esc stops")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        case .finished:
            Text("Done: \(autoTyper.totalCharacterCount) characters, \(autoTyper.fixedTypoCount) typos fixed along the way.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.success)
        case .stopped:
            Text("Stopped after \(autoTyper.typedCharacterCount) of \(autoTyper.totalCharacterCount) characters.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Pieces

    private func sliderRow(label: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Slider(value: value, in: range, step: step)
                .pointerCursor()
        }
    }

    private func row<Control: View>(label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 12)
            control()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
            .fill(DS.Colors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            content()
        }
    }
}
