//
//  DottieMausBotIdlePause.swift
//  leanring-buddy
//
//  MausBot tidies every bot's memory once a night (its "memory upkeep",
//  from 3 AM), whether the bot did anything that day or not. Six of
//  Dottie's helpers cost about $0.11 a night that way, about $3.30 a month
//  with Dottie idle. MausBot skips bots that are paused, so Dottie pauses
//  each of her own bots that hasn't had a turn in the last 20 hours, and
//  resumes it right before its next turn. A bot that worked today stays
//  awake and keeps its nightly tidy. Only bots Dottie paused herself are
//  ever resumed, so a pause the user made in MausBot stays.
//

import Foundation

/// When a bot last had a turn and which ones Dottie paused. Foundation
/// only, so the choice can be unit tested.
nonisolated struct DottieMausBotIdleRecord: Codable, Equatable {
    var lastTurnByBotID: [String: Date] = [:]
    var botIDsPausedByDottie: Set<String> = []

    /// A bot is idle once this long has passed since its last turn.
    static let idleSeconds: TimeInterval = 20 * 60 * 60

    /// Bots Dottie has run that are idle now and not yet paused.
    func botIDsToPause(now: Date) -> [String] {
        lastTurnByBotID
            .filter { botID, lastTurnDate in
                !botIDsPausedByDottie.contains(botID) && now.timeIntervalSince(lastTurnDate) >= Self.idleSeconds
            }
            .map(\.key)
            .sorted()
    }

    /// Whether a bot has to be resumed before its turn.
    func needsResumeBeforeTurn(botID: String) -> Bool {
        botIDsPausedByDottie.contains(botID)
    }

    mutating func noteTurnStarted(botID: String, at date: Date) {
        lastTurnByBotID[botID] = date
        botIDsPausedByDottie.remove(botID)
    }

    mutating func notePaused(botID: String) {
        botIDsPausedByDottie.insert(botID)
    }
}

@MainActor
final class DottieMausBotIdlePause {
    static let shared = DottieMausBotIdlePause()

    private static let defaultsKey = "dottieMausBotIdleRecord"
    private var record: DottieMausBotIdleRecord
    private var lastIdleCheckDate: Date?
    /// How often idle bots are looked for (the roster's timer ticks every 30 s).
    private static let idleCheckIntervalSeconds: TimeInterval = 60 * 60

    private init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let savedRecord = try? JSONDecoder().decode(DottieMausBotIdleRecord.self, from: savedData) {
            record = savedRecord
        } else {
            record = DottieMausBotIdleRecord()
        }
    }

    /// Wakes a bot Dottie paused, then notes its turn. Called right before
    /// every MausBot turn.
    func prepareForTurn(botID: String, launcher: DottieMausBotLauncher) async {
        if record.needsResumeBeforeTurn(botID: botID) {
            let resumeResult = await DottieMausBotCLI.run(["bots", "resume", botID, "--json"], launcher: launcher, timeout: 20)
            if resumeResult.exitCode == DottieMausBotCLI.exitDone {
                DottieLog.notice("💤 Woke an idle helper bot for its turn")
            } else {
                DottieLog.warning("⚠️ Couldn't wake an idle helper bot (exit \(public: resumeResult.exitCode)); running the turn anyway")
            }
        }
        record.noteTurnStarted(botID: botID, at: Date())
        save()
    }

    /// Pauses Dottie's bots that have been idle 20 hours, at most once an
    /// hour, so MausBot's nightly memory tidy skips them.
    func pauseIdleBotsIfDue() async {
        let now = Date()
        if let lastIdleCheckDate, now.timeIntervalSince(lastIdleCheckDate) < Self.idleCheckIntervalSeconds { return }
        lastIdleCheckDate = now
        let idleBotIDs = record.botIDsToPause(now: now)
        guard !idleBotIDs.isEmpty, let launcher = await DottieMausBot.shared.currentLauncher() else { return }
        for botID in idleBotIDs {
            let pauseResult = await DottieMausBotCLI.run(["bots", "pause", botID, "--json"], launcher: launcher, timeout: 20)
            if pauseResult.exitCode == DottieMausBotCLI.exitDone {
                record.notePaused(botID: botID)
            } else if pauseResult.exitCode == DottieMausBotCLI.exitBadArguments {
                // The bot is gone from MausBot: stop tracking it.
                record.lastTurnByBotID.removeValue(forKey: botID)
            }
        }
        DottieLog.notice("💤 Paused \(public: record.botIDsPausedByDottie.count) idle helper bot(s) so their nightly memory run is skipped")
        save()
    }

    private func save() {
        guard let recordData = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(recordData, forKey: Self.defaultsKey)
    }
}
