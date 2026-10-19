//
//  HomeProfileView.swift
//  leanring-buddy
//
//  Home → Profile: Dottie's level, XP bar and day streak, what she's
//  unlocked (and what's still locked), and any 24/7 jobs that are running.
//

import SwiftUI

struct HomeProfileView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var levels = DottieLevels.shared
    @ObservedObject private var keepWorking = DottieKeepWorking.shared
    @ObservedObject private var screenLock = DottieScreenLock.shared

    private let unlockColumns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                levelCard
                statsRow

                section(title: "Unlocks") {
                    LazyVGrid(columns: unlockColumns, alignment: .leading, spacing: 10) {
                        ForEach(DottieLevels.unlockables) { unlockable in
                            unlockTile(unlockable)
                        }
                    }
                    Text("Wear an unlocked one by clicking it, or tell Dottie \u{201C}wear the disco ball\u{201D}.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                section(title: "Notch effect") {
                    HStack(spacing: 8) {
                        ForEach(DottieNotchEffect.allCases, id: \.self) { effect in
                            notchEffectButton(effect)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("Shows around the notch when it opens.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                section(title: "24/7 jobs") {
                    if keepWorking.activeJobs.isEmpty {
                        Text("None running. Ask Dottie something like \u{201C}keep working on this all night until it's done\u{201D} and a helper keeps at it while your Mac stays awake.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(keepWorking.activeJobs) { job in
                            keepWorkingRow(job)
                        }
                        Text("Your Mac won't go to sleep on its own while these run. The screen can still turn off.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    if screenLock.isLocked {
                        Text("Your screen is locked: helpers keep going, and screen jobs wait until you unlock.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.warningText)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Level

    private var levelCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 1, green: 0.84, blue: 0.38), Color(red: 0.55, green: 0.3, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 64, height: 64)
                Text("\(levels.level)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(levels.levelName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                ProgressView(value: levels.progressToNextLevel)
                    .tint(DS.Colors.accent)
                Text("\(levels.totalXP) XP · \(levels.xpToNextLevel) to level \(levels.level + 1)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 20))
                    .foregroundColor(levels.streakDays > 0 ? .orange : DS.Colors.textTertiary)
                Text("\(levels.streakDays) day\(levels.streakDays == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("best \(levels.bestStreakDays)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .help("Days in a row Dottie did something for you")
        }
        .padding(16)
        .background(cardBackground)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat("Screen jobs", levels.counts[DottieLevels.Event.screenJob.rawValue] ?? 0)
            stat("Helper tasks", levels.counts[DottieLevels.Event.helperTask.rawValue] ?? 0)
            stat("Guides", levels.counts[DottieLevels.Event.guide.rawValue] ?? 0)
            stat("Games won", levels.counts[DottieLevels.Event.gameWon.rawValue] ?? 0)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    // MARK: - Unlocks

    private func unlockTile(_ unlockable: DottieLevels.Unlockable) -> some View {
        let isUnlocked = levels.isUnlocked(unlockable)
        return Button {
            guard isUnlocked else { return }
            _ = levels.wear(unlockable.name, cursorPet: companionManager.cursorPet)
        } label: {
            HStack(spacing: 8) {
                Image(unlockable.artworkName)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    // Locked ones are shown greyed out until their level.
                    .saturation(isUnlocked ? 1 : 0)
                    .opacity(isUnlocked ? 1 : 0.35)
                VStack(alignment: .leading, spacing: 1) {
                    Text(unlockable.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isUnlocked ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .lineLimit(1)
                    Text(isUnlocked ? unlockable.kindLabel : "Level \(unlockable.level)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer(minLength: 0)
                if !isUnlocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: isUnlocked)
        .help(isUnlocked ? "Wear \(unlockable.name)" : "Unlocks at level \(unlockable.level)")
    }

    private func notchEffectButton(_ effect: DottieNotchEffect) -> some View {
        let unlockable = DottieLevels.unlockables.first { $0.kind == .notchEffect(effect) }
        let isAvailable = unlockable.map(levels.isUnlocked) ?? true
        let isSelected = levels.notchEffect == effect
        return Button {
            levels.setNotchEffect(effect)
        } label: {
            HStack(spacing: 4) {
                Image(effect.artworkName)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .padding(.vertical, -4)
                    .saturation(isAvailable ? 1 : 0)
                    .opacity(isAvailable ? 1 : 0.5)
                Text(effect.displayName)
                    .font(.system(size: 12))
                if !isAvailable {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                }
            }
            .foregroundColor(isAvailable ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? DS.Colors.accentSubtle : DS.Colors.surface2)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(isAvailable ? effect.displayName : "Unlocks at level \(unlockable?.level ?? 1)")
    }

    // MARK: - 24/7

    private func keepWorkingRow(_ job: ClickyRoutine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.stars.fill")
                .foregroundColor(DS.Colors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(jobDetail(job))
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Stop") {
                keepWorking.stop(matching: job.title)
            }
            .font(.system(size: 12))
        }
        .padding(10)
        .background(cardBackground)
    }

    private func jobDetail(_ job: ClickyRoutine) -> String {
        let helperName = companionManager.clickyRoster.agent(withID: job.agentID)?.name ?? "A helper"
        var detail = "\(helperName) · \(job.cadenceDescription) · \(job.runCount) run\(job.runCount == 1 ? "" : "s")"
        if let endsAt = job.keepWorking?.endsAt {
            detail += " · until \(endsAt.formatted(date: .omitted, time: .shortened))"
        }
        if job.keepWorking?.untilDone == true {
            detail += " · stops when done"
        }
        return detail
    }

    // MARK: - Pieces

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
