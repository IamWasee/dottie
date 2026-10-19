//
//  DottieClaudeSignInPanel.swift
//  leanring-buddy
//
//  The Claude sign-in in progress, shown in Settings → Helpers and on the
//  Helpers page: the sign-in link with "Open in a private window" and "Copy
//  link", a box for the code when the page shows one, and how it ended.
//  See DottieClaudeAccount for how the sign-in itself runs.
//

import SwiftUI

struct DottieClaudeSignInPanel: View {
    @ObservedObject private var signIn = DottieClaudeSignIn.shared
    @State private var pastedCode = ""

    static let pickAccountTip = "Sign out of claude.ai in your browser first, or use the private window, to pick another account."

    var body: some View {
        switch signIn.phase {
        case .idle:
            EmptyView()
        case .signingOut, .starting, .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(signIn.progressText ?? "Working…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer(minLength: 0)
                Button("Cancel") { signIn.cancel() }
                    .controlSize(.small)
                    .pointerCursor()
            }
        case .waitingForBrowser:
            waitingForBrowserView
        case .finished(let message):
            resultRow(message: message, color: DS.Colors.success, showsTryAgain: false)
        case .failed(let message):
            resultRow(message: message, color: DS.Colors.warningText, showsTryAgain: true)
        }
    }

    private var waitingForBrowserView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(signIn.isSwitchingAccount
                 ? "Open this link and pick the Claude account helpers should use."
                 : "Finish signing in in your browser. Wrong account? Open the link in a private window instead.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let signInLink = signIn.signInLink {
                Text(signInLink.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                privateWindowButton
                Button("Copy link") { signIn.copyLink() }
                    .pointerCursor()
                if !signIn.isSwitchingAccount {
                    Button("Open again") { signIn.openLinkInUsersBrowser() }
                        .pointerCursor()
                }
                Spacer(minLength: 0)
                Button("Cancel") { signIn.cancel() }
                    .pointerCursor()
            }
            .font(.system(size: 12))
            .controlSize(.small)

            if signIn.linkNeedsCode {
                HStack(spacing: 8) {
                    TextField("Paste the code the page shows at the end", text: $pastedCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { submitCode() }
                    Button("Done") { submitCode() }
                        .controlSize(.small)
                        .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointerCursor()
                }
            }

            if let noteText = signIn.noteText {
                Text(noteText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(Self.pickAccountTip)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One button for the user's browser, with the others in its menu.
    @ViewBuilder
    private var privateWindowButton: some View {
        let installedBrowsers = DottiePrivateBrowser.installed
        let preferredBrowser = DottiePrivateBrowser.preferred
        if installedBrowsers.count > 1 {
            Menu {
                ForEach(installedBrowsers) { browser in
                    Button("Private window in \(browser.name)") {
                        signIn.openLinkInPrivateWindow(browser: browser)
                    }
                }
            } label: {
                Text("Open in a private window")
            } primaryAction: {
                signIn.openLinkInPrivateWindow(browser: preferredBrowser)
            }
            .fixedSize()
            .pointerCursor()
        } else {
            Button("Open in a private window") {
                signIn.openLinkInPrivateWindow(browser: preferredBrowser)
            }
            .keyboardShortcut(.defaultAction)
            .pointerCursor()
        }
    }

    private func resultRow(message: String, color: Color, showsTryAgain: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if showsTryAgain {
                Button("Try again") { signIn.start(switchingAccount: signIn.isSwitchingAccount) }
                    .controlSize(.small)
                    .pointerCursor()
            }
            Button("OK") { signIn.dismissResult() }
                .controlSize(.small)
                .pointerCursor()
        }
    }

    private func submitCode() {
        signIn.submitCode(pastedCode)
        pastedCode = ""
    }
}
