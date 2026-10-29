//
//  DottieAwayMode.swift
//  leanring-buddy
//
//  Away mode: the user has left the Mac and Dottie carries on alone. Turned
//  on from the menu bar panel, by voice ("I'm heading out") or by texting
//  the phone bot "away"; off by voice, the panel, texting "back", or
//  pressing the talk shortcut at the Mac.
//
//  While it's on, nobody is at the Mac to hear a question, so everything
//  that needs the user goes to their phone (DottiePhoneBridge) and waits:
//  a screen job's question, a helper asking to use the screen, and any
//  click on something that pays, sends, posts or deletes (checked here on
//  the Mac by the button's own words, not left to the model), which comes
//  with a screenshot and Allow / Deny buttons. Passwords are never asked
//  for over Telegram; a job that needs one waits for the user to be back.
//
//  Everything that happens is written to a log (Application Support/
//  Dottie/Away/log.json, failures with a screenshot), which becomes the
//  "while you were away" report: in the notch when the user comes back,
//  and on the phone when they text "report".
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class DottieAwayMode: ObservableObject {
    static let shared = DottieAwayMode()

    struct LogEntry: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case finished, failed, asked, approved, declined, helperReply, note
        }

        var id = UUID()
        let date: Date
        let kind: Kind
        let title: String
        let detail: String
        /// A screenshot saved next to the log, for failures.
        var screenshotFileName: String?
    }

    @Published private(set) var isAway: Bool
    @Published private(set) var awaySince: Date?
    @Published private(set) var log: [LogEntry] = []

    /// Set by CompanionManager when the phone bridge is made.
    weak var phoneBridge: DottiePhoneBridge?
    /// Called when away mode ends with the report, so the notch shows it.
    var onCameBack: ((_ reportText: String) -> Void)?

    private static let isAwayDefaultsKey = "dottieAwayModeOn"
    private static let awaySinceDefaultsKey = "dottieAwayModeSince"
    private static let maximumLogEntries = 300
    /// How long a question sent to the phone waits before the job gives up
    /// on it (the user may be on a train).
    static let phoneAnswerWaitSeconds: Double = 1800

    static var folderURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folderURL = applicationSupportURL.appendingPathComponent("Dottie/Away", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    private static var logFileURL: URL { folderURL.appendingPathComponent("log.json") }

    private init() {
        let defaults = UserDefaults.standard
        isAway = defaults.bool(forKey: Self.isAwayDefaultsKey)
        awaySince = defaults.object(forKey: Self.awaySinceDefaultsKey) as? Date
        loadLog()
    }

    /// True when a question should go to the phone instead of being said
    /// out loud: away mode is on and the phone is paired.
    var questionsGoToPhone: Bool {
        isAway && phoneBridge?.pairedChatID != nil && phoneBridge?.isConnected == true
    }

    // MARK: - On and off

    /// Turns away mode on or off and returns a line to say or text back.
    @discardableResult
    func setAway(_ newValue: Bool, from source: String) -> String {
        guard newValue != isAway else {
            return newValue ? "Away mode is already on." : "Away mode is already off."
        }
        let defaults = UserDefaults.standard
        if newValue {
            isAway = true
            awaySince = Date()
            defaults.set(true, forKey: Self.isAwayDefaultsKey)
            defaults.set(awaySince, forKey: Self.awaySinceDefaultsKey)
            record(.note, title: "Away mode on", detail: "turned on from \(source)")
            print("🚶 Away mode on (\(source))")
            let phoneIsPaired = phoneBridge?.pairedChatID != nil
            if phoneIsPaired, source != "phone" {
                Task { await phoneBridge?.send("Away mode is on. I'll keep working, text you before anything that pays, sends, posts or deletes, and text \"report\" any time to see what I've done.") }
            }
            return phoneIsPaired
                ? "Away mode is on. Questions and anything risky go to your phone, with Allow and Deny buttons. Text \"back\" or press the talk shortcut when you're back."
                : "Away mode is on, but no phone is paired (Home → Phone), so anything risky will wait for you at the Mac."
        }
        let reportText = report()
        isAway = false
        defaults.set(false, forKey: Self.isAwayDefaultsKey)
        record(.note, title: "Away mode off", detail: "turned off from \(source)")
        awaySince = nil
        defaults.removeObject(forKey: Self.awaySinceDefaultsKey)
        print("🏠 Away mode off (\(source))")
        // Questions still waiting on the phone are answered at the Mac now.
        phoneBridge?.resolvePendingQuestion(with: nil)
        onCameBack?(reportText)
        return "Welcome back. " + reportText
    }

    // MARK: - Asking on the phone

    /// Asks on the phone and waits. nil when there's no phone or no answer.
    func askOnPhone(_ question: String, choices: [String] = [], screenshotJPEG: Data? = nil) async -> String? {
        guard let phoneBridge, phoneBridge.pairedChatID != nil else { return nil }
        record(.asked, title: "Asked you", detail: question)
        let answer = await phoneBridge.ask(question, choices: choices, screenshotJPEG: screenshotJPEG, timeoutSeconds: Self.phoneAnswerWaitSeconds)
        if let answer {
            let isNo = answer.lowercased().hasPrefix("deny") || answer.lowercased().hasPrefix("no")
            record(isNo ? .declined : .approved, title: isNo ? "You said no" : "You answered", detail: "\(question) → \(answer)")
        }
        return answer
    }

    /// Asks Allow / Deny on the phone before a risky step. False on Deny or
    /// no answer, so nothing risky happens without a yes.
    func confirmOnPhone(_ question: String, screenshotJPEG: Data?) async -> Bool {
        let answer = await askOnPhone(question, choices: ["Allow", "Deny"], screenshotJPEG: screenshotJPEG)
        return answer == "Allow"
    }

    /// Words on a button or link that pay, send, post or delete. Checked on
    /// the Mac before every click while away, whatever the model thinks.
    static func isRiskyLabel(_ label: String) -> Bool {
        let words = label.lowercased()
        let riskyPhrases = [
            "pay", "buy", "purchase", "checkout", "check out", "place order", "order now", "subscribe", "donate", "transfer", "confirm payment",
            "send", "post", "publish", "tweet", "reply all", "share now", "submit",
            "delete", "remove", "erase", "empty trash", "discard", "unsubscribe", "cancel subscription", "close account", "deactivate"
        ]
        return riskyPhrases.contains { phrase in
            // Whole words only: "send" yes, "sender" or "repost settings" no.
            let pattern = "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: phrase) + "($|[^a-z])"
            return words.range(of: pattern, options: .regularExpression) != nil
        }
    }

    // MARK: - The log and the report

    func record(_ kind: LogEntry.Kind, title: String, detail: String, screenshotJPEG: Data? = nil) {
        var entry = LogEntry(date: Date(), kind: kind, title: title, detail: String(detail.prefix(1500)))
        if let screenshotJPEG {
            let fileName = "shot-\(entry.id.uuidString.prefix(8)).jpg"
            if (try? screenshotJPEG.write(to: Self.folderURL.appendingPathComponent(fileName), options: .atomic)) != nil {
                entry.screenshotFileName = fileName
            }
        }
        log.append(entry)
        if log.count > Self.maximumLogEntries {
            let removedEntries = log.prefix(log.count - Self.maximumLogEntries)
            for removedEntry in removedEntries {
                if let fileName = removedEntry.screenshotFileName {
                    try? FileManager.default.removeItem(at: Self.folderURL.appendingPathComponent(fileName))
                }
            }
            log.removeFirst(removedEntries.count)
        }
        saveLog()
    }

    /// Something finished while the user is away: logged, and texted when
    /// it wasn't already going to the phone.
    func noteResult(title: String, detail: String, succeeded: Bool, screenshotJPEG: Data? = nil, alreadyTextedToPhone: Bool) {
        record(succeeded ? .finished : .failed, title: title, detail: detail, screenshotJPEG: succeeded ? nil : screenshotJPEG)
        guard isAway, !alreadyTextedToPhone, let phoneBridge, phoneBridge.pairedChatID != nil else { return }
        Task {
            if !succeeded, let screenshotJPEG {
                await phoneBridge.sendPhoto(screenshotJPEG, caption: "\(title): \(detail)".prefix(900).description)
            } else {
                await phoneBridge.send("\(succeeded ? "✅" : "⚠️") \(title): \(detail)")
            }
        }
    }

    /// What happened since away mode went on (or the last 12 hours), in a
    /// few plain lines.
    func report() -> String {
        let since = awaySince ?? Date().addingTimeInterval(-12 * 3600)
        let entries = log.filter { $0.date >= since && $0.kind != .note }
        guard !entries.isEmpty else { return "Nothing happened while you were away." }
        let finishedCount = entries.filter { $0.kind == .finished || $0.kind == .helperReply }.count
        let failedEntries = entries.filter { $0.kind == .failed }
        let declinedCount = entries.filter { $0.kind == .declined }.count
        var lines = ["While you were away: \(finishedCount) done, \(failedEntries.count) didn't work\(declinedCount > 0 ? ", \(declinedCount) you said no to" : "")."]
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        for entry in entries.suffix(12) {
            let marker: String
            switch entry.kind {
            case .finished, .helperReply: marker = "✅"
            case .failed: marker = "⚠️"
            case .asked: marker = "❓"
            case .approved: marker = "👍"
            case .declined: marker = "✋"
            case .note: marker = "·"
            }
            lines.append("\(marker) \(timeFormatter.string(from: entry.date)) \(entry.title): \(entry.detail.prefix(160))")
        }
        if !failedEntries.isEmpty {
            lines.append("Screenshots of what went wrong are in \(Self.folderURL.path).")
        }
        return lines.joined(separator: "\n")
    }

    private func loadLog() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let logData = try? Data(contentsOf: Self.logFileURL),
              let savedLog = try? decoder.decode([LogEntry].self, from: logData) else { return }
        log = savedLog
    }

    private func saveLog() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let logData = try? encoder.encode(log) else { return }
        try? logData.write(to: Self.logFileURL, options: .atomic)
    }
}

// MARK: - The voice tool

@MainActor
enum DottieAwayModeTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "away_mode",
                description: "Away mode, for when the user leaves the Mac and wants Dottie to keep working without them ('I'm heading out, keep going', 'I'm back', 'what did you do while I was gone?'). on: questions and anything that pays, sends, posts or deletes go to their phone with Allow / Deny; off: back to normal, with the report; report: what ran, what worked, what failed while they were away.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["on", "off", "report", "status"]]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let awayMode = DottieAwayMode.shared
                switch arguments.dottieString("action") ?? "status" {
                case "on":
                    return awayMode.setAway(true, from: "voice")
                case "off":
                    return awayMode.setAway(false, from: "voice")
                case "report":
                    return awayMode.report()
                default:
                    return awayMode.isAway ? "away mode is on." : "away mode is off."
                }
            }
        ]
    }

    static var voicePromptSection: String {
        "when the user is leaving the mac and wants you to keep working, or says they're back, use away_mode."
    }
}

// MARK: - Settings → Working on its own

/// Away mode and the switches for how Dottie works without the user.
struct HomeWorkingAloneSettings: View {
    @ObservedObject private var awayMode = DottieAwayMode.shared
    @AppStorage(DottieScreenJobClaudeBrain.isEnabledDefaultsKey) private var screenJobsUseClaude = true
    @AppStorage(DottieScreenJobGuesser.isEnabledDefaultsKey) private var screenJobsGuessFirst = true
    @AppStorage(DottieWorkRoutes.helpersCanUseHomeFoldersDefaultsKey) private var helpersCanUseHomeFolders = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Away mode", isOn: Binding(
                get: { awayMode.isAway },
                set: { awayMode.setAway($0, from: "Settings") }
            ))
            .toggleStyle(.switch)
            .pointerCursor()
            hint("Dottie keeps working while you're gone. Questions, and anything that pays, sends, posts or deletes, go to your phone (Home → Phone) with Allow and Deny buttons. Text \u{201C}report\u{201D} to see what she's done.")
            Toggle("Screen jobs think with Claude Sonnet", isOn: $screenJobsUseClaude)
                .toggleStyle(.switch)
                .pointerCursor()
            hint("Uses your Claude plan through MausBot, with Gemini taking over when Claude is busy or slow.")
            Toggle("Guess the steps first, look only when a guess misses", isOn: $screenJobsGuessFirst)
                .toggleStyle(.switch)
                .pointerCursor()
            hint("Menus, shortcuts and buttons are tried by name before any screenshot is sent, since most apps are laid out the way everyone knows.")
            Toggle("Helpers can use my Documents, Desktop and Downloads", isOn: $helpersCanUseHomeFolders)
                .toggleStyle(.switch)
                .pointerCursor()
            hint("They still ask before deleting or overwriting your files. Takes effect the next time Dottie opens.")
            HStack {
                Text(awayMode.log.isEmpty ? "Nothing logged yet" : "\(awayMode.log.count) things logged")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Show the away log") { NSWorkspace.shared.open(DottieAwayMode.folderURL) }
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
