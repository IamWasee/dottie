//
//  DottieSpeedSettings.swift
//  leanring-buddy
//
//  Settings sections for the speed pack: "Check everything" (the
//  self-check) and the list of instant replays.
//

import SwiftUI

// MARK: - Check everything

/// Settings → Check everything: tries every part Dottie needs and lists
/// what works, with a fix button next to anything that doesn't.
struct HomeSelfCheckSettings: View {
    @ObservedObject private var selfCheck = DottieSelfCheck.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(headline)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if selfCheck.isRunning {
                    ProgressView().controlSize(.small)
                }
                Button(selfCheck.isRunning ? "Checking…" : "Check everything") {
                    Task { await selfCheck.run() }
                }
                .disabled(selfCheck.isRunning)
                .pointerCursor()
            }
            ForEach(selfCheck.items) { item in
                row(item)
            }
            Text("Takes a few seconds. It listens to your microphone for one second and sends Gemini one tiny message.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        if selfCheck.isRunning { return "Checking…" }
        guard selfCheck.lastRunAt != nil else { return "See if everything works" }
        let needsLook = selfCheck.items.filter { $0.level >= .warning }.count
        return needsLook == 0 ? "Everything works" : "\(needsLook) thing\(needsLook == 1 ? " needs" : "s need") a look"
    }

    private func row(_ item: DottieSelfCheck.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color(for: item.level))
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(item.detail)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
            if let fix = item.fix, let fixLabel = item.fixLabel {
                Button(fixLabel) { selfCheck.apply(fix) }
                    .font(.system(size: 11))
                    .disabled(selfCheck.isRunning)
                    .pointerCursor()
            }
        }
    }

    private func color(for level: DottieSelfCheck.Level) -> Color {
        switch level {
        case .good: return DS.Colors.success
        case .warning: return DS.Colors.warningText
        case .problem: return DS.Colors.destructive
        case .off: return DS.Colors.textTertiary
        }
    }
}

// MARK: - Instant replays

/// Settings → Instant replays: the screen jobs Dottie can redo from
/// memory, each with a delete button.
struct HomeReplaySettings: View {
    @ObservedObject private var store = DottieReplayStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.replays.isEmpty ? "No replays yet" : "\(store.replays.count) saved")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button("Forget all") { store.forgetAll() }
                    .disabled(store.replays.isEmpty)
                    .pointerCursor()
            }
            ForEach(store.replays) { replay in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(replay.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(2)
                        Text(details(for: replay))
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer()
                    Button(action: { store.forget(replay.id) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Forget this replay")
                    .pointerCursor()
                }
            }
            Text("When a screen job works, Dottie remembers its steps. Ask for the same thing again in the same app or site and she redoes it straight away, checking each step first. If the screen looks different, she works it out again.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func details(for replay: DottieReplay) -> String {
        var parts = ["\(replay.whereText)", "\(replay.steps.count) step\(replay.steps.count == 1 ? "" : "s")"]
        if replay.useCount > 0 { parts.append("replayed \(replay.useCount)×") }
        if let seconds = replay.lastReplaySeconds { parts.append(String(format: "last took %.1fs", seconds)) }
        return parts.joined(separator: " · ")
    }
}
