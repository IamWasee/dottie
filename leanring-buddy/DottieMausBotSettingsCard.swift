//
//  DottieMausBotSettingsCard.swift
//  leanring-buddy
//
//  Settings → Helpers: which engine helpers run on, and how Claude through
//  OpenMausBot is doing (MausBot found, workspace running, Claude signed
//  in, and as whom), with one button for whatever is missing, and "Use a
//  different account" to switch Claude accounts. Dottie installs the MausBot
//  app by itself; its progress shows here too. See DottieMausBot,
//  DottieMausBotAppInstaller and DottieClaudeAccount.
//

import SwiftUI

struct DottieMausBotSettingsCard: View {
    @ObservedObject private var mausBot = DottieMausBot.shared
    @ObservedObject private var claudeSignIn = DottieClaudeSignIn.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run helpers on")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Picker("", selection: Binding(
                    get: { mausBot.preference },
                    set: { mausBot.setPreference($0) }
                )) {
                    ForEach(DottieHelperEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .labelsHidden()
                .frame(width: 250)
            }

            if mausBot.preference == .claudeWithBackup {
                VStack(alignment: .leading, spacing: 6) {
                    statusRow(title: "MausBot", text: mausBot.mausBotStatusLine, isGood: mausBot.isSetUp)
                    statusRow(title: "Workspace", text: mausBot.workspaceStatusLine, isGood: mausBot.isWorkspaceReachable)
                    statusRow(title: "Claude", text: mausBot.claudeStatusLine, isGood: mausBot.claudeState == .ready)
                }

                if let pausedUntil = mausBot.claudePausedUntil {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(mausBot.claudePauseReason ?? "Claude is paused"). Helpers use the free Gemini backup until \(pausedUntil.formatted(date: .omitted, time: .shortened)).")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Try Claude now") { mausBot.resumeClaude() }
                            .controlSize(.small)
                            .pointerCursor()
                    }
                }

                if let busyText = mausBot.busyText {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busyText)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                } else if let problemText = mausBot.problemText {
                    Text(problemText)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DottieClaudeSignInPanel()

                actionButtons
            }

            Text(hintText)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if !mausBot.hasLookedForMausBot || mausBot.claudeState == .unknown {
                mausBot.refreshStatus(startWorkspace: false)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if mausBot.needsSetUp {
                Button("Set up") { mausBot.setUp() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(mausBot.isSettingUp || mausBot.isInstallingDesktopApp)
                    .pointerCursor()
            } else if claudeSignIn.isInProgress {
                // The sign-in panel above has the buttons.
                EmptyView()
            } else if mausBot.claudeState == .notSignedIn {
                Button("Sign in to Claude") { mausBot.openClaudeSignIn() }
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            } else if mausBot.claudeState == .ready {
                Button("Use a different account") { mausBot.switchClaudeAccount() }
                    .pointerCursor()
                    .help("Sign Claude out and pick another account for the helpers")
            }
            if mausBot.isSetUp {
                Button("Open MausBot") { mausBot.openMausBot() }
                    .pointerCursor()
            }
            Button("Check again") { mausBot.refreshStatus(startWorkspace: true) }
                .disabled(mausBot.isSettingUp)
                .pointerCursor()
        }
        .font(.system(size: 12))
    }

    private var hintText: String {
        if mausBot.preference == .geminiOnly {
            return "Helpers run on Gemini's free tier."
        }
        if mausBot.claudeState == .notSignedIn {
            return "Sign in opens your browser. Click Allow there once, and Dottie picks it up by itself. " + DottieClaudeSignInPanel.pickAccountTip
        }
        return "Helpers use your Claude plan through MausBot, a free app Dottie installs for you. Nothing extra to pay. If your Claude limit runs out, helpers switch to the free Gemini backup by themselves and try Claude again later."
    }

    private func statusRow(title: String, text: String, isGood: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11))
                .foregroundColor(isGood ? DS.Colors.success : DS.Colors.textTertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 78, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
