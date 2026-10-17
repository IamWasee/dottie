//
//  DottieSettingsViews.swift
//  leanring-buddy
//
//  Settings sections for permissions and updates, and the panel's
//  "Allow everything at once" button.
//

import SwiftUI

// MARK: - Permissions

/// Settings → Permissions: everything macOS can ask about, with one button
/// that asks for all of it in a row.
struct HomePermissionsSettings: View {
    @ObservedObject private var permissions = DottiePermissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(permissions.allowedCount) of \(DottiePermissions.Kind.allCases.count) allowed")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                    if let asking = permissions.currentlyAsking {
                        Text("Asking for \(asking.title)…")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                Spacer()
                Button(permissions.isAskingForAll ? "Asking…" : "Allow everything") {
                    Task { await permissions.askForAll() }
                }
                .disabled(permissions.isAskingForAll)
                .pointerCursor()
            }
            ForEach(DottiePermissions.Kind.allCases) { kind in
                permissionRow(kind)
            }
            Text("macOS asks for each one in turn. For Accessibility, Screen Recording and Input Monitoring it opens System Settings: switch Dottie on there and the next one follows. Anything you said no to before opens its page in System Settings.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
    }

    private func permissionRow(_ kind: DottiePermissions.Kind) -> some View {
        let status = permissions.statuses[kind] ?? .unknown
        return HStack(spacing: 8) {
            Image(systemName: status == .allowed ? "checkmark.circle.fill" : (status == .denied ? "xmark.circle" : "circle"))
                .font(.system(size: 12))
                .foregroundColor(status == .allowed ? DS.Colors.textPrimary : (status == .denied ? DS.Colors.warningText : DS.Colors.textTertiary))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(kind.reason)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            if status != .allowed {
                Button(status == .denied ? "Open Settings" : "Allow") {
                    Task {
                        await permissions.ask(for: kind)
                        await permissions.refresh()
                    }
                }
                .font(.system(size: 11))
                .disabled(permissions.isAskingForAll)
                .pointerCursor()
            }
        }
    }
}

// MARK: - Updates

/// Settings → Updates: check for a new version and install it in place.
struct HomeUpdateSettings: View {
    @ObservedObject private var updater = DottieUpdater.shared
    @AppStorage(DottieUpdater.autoCheckDefaultsKey) private var checksAutomatically = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dottie \(DottieUpdater.currentVersion)")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                actionButton
            }
            if let statusText {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(isProblem ? DS.Colors.warningText : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Check for updates automatically", isOn: $checksAutomatically)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            Text(DottieUpdater.keepsPermissionsAcrossUpdates
                 ? "Updates keep everything you've allowed, your settings and your chats."
                 : "Updates keep your settings and chats. This copy isn't signed with a certificate, so macOS may ask for some permissions again after an update.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch updater.state {
        case .available(let version):
            Button("Update to \(version)") { updater.installAvailableUpdate() }
                .pointerCursor()
        case .checking:
            ProgressView().controlSize(.small)
        case .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            Button("Check now") { Task { await updater.checkForUpdates() } }
                .pointerCursor()
        }
    }

    private var statusText: String? {
        switch updater.state {
        case .idle: return nil
        case .checking: return "Checking…"
        case .upToDate: return "You have the newest version."
        case .available(let version): return "Dottie \(version) is out. Updating takes a few seconds; Dottie closes and opens again."
        case .downloading(let version): return "Downloading \(version)…"
        case .installing(let version): return "Installing \(version). Dottie will reopen in a moment."
        case .failed(let message): return message
        }
    }

    private var isProblem: Bool {
        if case .failed = updater.state { return true }
        return false
    }
}

// MARK: - Panel

/// Asks for every permission Dottie can use in one go (the same as
/// Settings → Permissions → Allow everything).
struct AllowEverythingButton: View {
    @ObservedObject private var permissions = DottiePermissions.shared

    var body: some View {
        Button(action: { Task { await permissions.askForAll() } }) {
            Text(permissions.currentlyAsking.map { "Asking for \($0.title)…" } ?? "Allow everything at once")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(permissions.isAskingForAll)
        .pointerCursor()
    }
}
