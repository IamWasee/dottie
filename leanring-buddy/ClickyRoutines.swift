//
//  ClickyRoutines.swift
//  leanring-buddy
//
//  Routines: a Clicky re-runs a task on a schedule ("every morning, check
//  my repos for new issues") and posts each answer in its chat and the
//  notch. Shipped Clicky does this in CompanionManager+ClickyRoutines:
//  agents have no scheduling tool; when the user asks for something on a
//  cadence, the agent does it once and appends a block like
//
//    <ROUTINE>{"action":"create","every_minutes":60,"title":"Repo Issues",
//              "task":"Check my repos for new issues and summarize them"}</ROUTINE>
//
//  and the app keeps the schedule. The clone uses the same block, actions
//  (create, update, delete, pause, resume) and run prompts. Routines only
//  run while the Mac is awake and the app is open.
//
//  24/7 jobs ("keep working on this all night") are routines too, with a
//  `keepWorking` part: they can run nonstop (the next run starts a short
//  break after the last one ends), stop at a set time, or stop themselves
//  when the helper says the whole job is done. DottieKeepWorking starts
//  them from voice and keeps the Mac awake while any is on.
//
//  Saved in ~/Library/Application Support/Dottie/Dots/routines.json.
//

import Combine
import CryptoKit
import Foundation

struct ClickyRoutine: Codable, Identifiable, Equatable {
    let id: UUID
    let agentID: UUID
    var title: String
    var task: String
    var everyMinutes: Int
    var isPaused: Bool
    let createdAt: Date
    /// When the latest run started. A new routine counts its first run as
    /// the turn that created it.
    var lastRunStartedAt: Date
    var runCount: Int
    var failedRunsInARow: Int
    /// Set for a 24/7 job (see DottieKeepWorking). Optional so routines
    /// saved before 24/7 jobs existed still load.
    var keepWorking: ClickyKeepWorking?
    /// When the latest run ended, for nonstop jobs.
    var lastRunFinishedAt: Date?

    // Saving tokens. All optional so routines saved before these existed
    // still load.

    /// Runs in a row that found nothing new. Frequent routines wait longer
    /// between runs while this grows (see nextRunAt), and go back to their
    /// own pace on the next real change.
    var unchangedRunsInARow: Int?
    /// The user turned off waiting longer: always run at the set pace.
    var alwaysRunsAtSetPace: Bool?
    /// A page whose text decides whether a run is needed at all. When its
    /// text hasn't changed since the last run, the run is skipped without
    /// asking any model.
    var watchURL: String?
    var lastWatchedTextHash: String?
    /// The routine's own conversation, so runs don't replay (or bloat) the
    /// helper's chat with the user. Started again every few runs, carrying
    /// over only the last report.
    var geminiSessionID: UUID?
    var hasStartedGeminiSession: Bool?
    var claudeThreadID: String?
    var runsInCurrentSession: Int?
    /// The previous run's answer, trimmed, handed to a fresh session.
    var lastRunReport: String?

    /// Waiting longer applies to routines that run more often than this.
    static let slowestBackedOffMinutes = 60

    /// The pace the routine was set up with: its interval, or a nonstop
    /// job's break.
    var setPaceMinutes: Int {
        if let keepWorking, keepWorking.isNonstop {
            return keepWorking.restMinutes
        }
        return everyMinutes
    }

    /// Quiet runs have stretched the wait past the set pace.
    var isWaitingLonger: Bool {
        currentPaceMinutes > setPaceMinutes
    }

    /// How long to wait between runs right now: the set pace, doubled for
    /// each run in a row that found nothing new, up to an hour.
    var currentPaceMinutes: Int {
        let unchangedRuns = min(unchangedRunsInARow ?? 0, 6)
        guard alwaysRunsAtSetPace != true, unchangedRuns > 0,
              setPaceMinutes < Self.slowestBackedOffMinutes else { return setPaceMinutes }
        return min(setPaceMinutes * (1 << unchangedRuns), Self.slowestBackedOffMinutes)
    }

    var nextRunAt: Date {
        if let keepWorking, keepWorking.isNonstop {
            // The next run starts a short break after the last one ended
            // (the roster skips it while the helper is still busy).
            let lastActivityAt = max(lastRunStartedAt, lastRunFinishedAt ?? .distantPast)
            return lastActivityAt.addingTimeInterval(TimeInterval(currentPaceMinutes * 60))
        }
        return lastRunStartedAt.addingTimeInterval(TimeInterval(currentPaceMinutes * 60))
    }

    /// A 24/7 job whose end time has passed.
    func hasEnded(at currentDate: Date) -> Bool {
        guard let endsAt = keepWorking?.endsAt else { return false }
        return endsAt <= currentDate
    }

    /// "every hour", "every 15 minutes", "every day", "nonstop".
    var cadenceDescription: String {
        if let keepWorking, keepWorking.isNonstop {
            return "nonstop, with \(keepWorking.restMinutes)-minute breaks"
        }
        return ClickyRoutine.cadenceDescription(everyMinutes: everyMinutes)
    }

    static func cadenceDescription(everyMinutes: Int) -> String {
        switch everyMinutes {
        case 60: return "every hour"
        case 1440: return "every day"
        case 10080: return "every week"
        case let minutes where minutes % 1440 == 0: return "every \(minutes / 1440) days"
        case let minutes where minutes % 60 == 0: return "every \(minutes / 60) hours"
        default: return "every \(everyMinutes) minutes"
        }
    }
}

/// The 24/7 part of a routine.
struct ClickyKeepWorking: Codable, Equatable {
    /// Nonstop: run again a short break after each run ends, instead of on
    /// a fixed interval.
    var isNonstop: Bool
    var restMinutes: Int
    /// Stops on its own at this time ("all night" ends in the morning).
    var endsAt: Date?
    /// Stops on its own when the helper says the whole job is done.
    var untilDone: Bool
    let startedAt: Date

    /// The shortest break between nonstop runs. Each helper run makes
    /// several requests, and the free tier allows about 15 a minute.
    static let minimumRestMinutes = 3

    /// The line a helper ends its reply with when the whole job is done.
    static let doneMarker = "ALL DONE"
    /// How a helper starts its reply when it found something the user
    /// should hear about right away.
    static let importantMarker = "IMPORTANT:"
}

/// One `<ROUTINE>` block from an agent's reply.
struct ClickyRoutineAction: Decodable {
    enum Kind: String, Decodable {
        case create, update, delete, pause, resume
    }

    let action: Kind
    let title: String
    let task: String?
    let everyMinutes: Int?
    let newTitle: String?
    let watchURL: String?

    private enum CodingKeys: String, CodingKey {
        case action, title, task
        case everyMinutes = "every_minutes"
        case newTitle = "new_title"
        case watchURL = "watch_url"
    }
}

@MainActor
final class ClickyRoutineStore: ObservableObject {
    @Published private(set) var routines: [ClickyRoutine] = []

    /// The free Gemini tier has a daily request cap, so routines can't run
    /// more often than this.
    nonisolated static let minimumEveryMinutes = 10
    /// After this many failed runs in a row a routine pauses itself.
    nonisolated static let maximumFailedRunsInARow = 3

    private let routinesFileURL: URL

    init(routinesFileURL: URL) {
        self.routinesFileURL = routinesFileURL
        load()
    }

    func routines(for agentID: UUID) -> [ClickyRoutine] {
        routines.filter { $0.agentID == agentID }
    }

    func routine(withID routineID: UUID) -> ClickyRoutine? {
        routines.first { $0.id == routineID }
    }

    /// Routines that are due now, oldest-due first.
    func dueRoutines(at currentDate: Date) -> [ClickyRoutine] {
        routines
            .filter { !$0.isPaused && !$0.hasEnded(at: currentDate) && $0.nextRunAt <= currentDate }
            .sorted { $0.nextRunAt < $1.nextRunAt }
    }

    // MARK: - 24/7 jobs

    /// 24/7 jobs that are on (not paused).
    var activeKeepWorkingRoutines: [ClickyRoutine] {
        routines.filter { $0.keepWorking != nil && !$0.isPaused }
    }

    /// Starts (or replaces) a 24/7 job for a helper. Its first run is the
    /// turn the caller starts now.
    @discardableResult
    func startKeepWorking(agentID: UUID, title: String, task: String, everyMinutes: Int, keepWorking: ClickyKeepWorking) -> ClickyRoutine {
        routines.removeAll { $0.agentID == agentID && $0.title.caseInsensitiveCompare(title) == .orderedSame }
        let newRoutine = ClickyRoutine(
            id: UUID(),
            agentID: agentID,
            title: title,
            task: task,
            everyMinutes: max(everyMinutes, Self.minimumEveryMinutes),
            isPaused: false,
            createdAt: Date(),
            lastRunStartedAt: Date(),
            runCount: 1,
            failedRunsInARow: 0,
            keepWorking: keepWorking,
            lastRunFinishedAt: nil
        )
        routines.append(newRoutine)
        ClickyAnalytics.trackRoutineChanged(action: "created")
        save()
        return newRoutine
    }

    /// A helper's turn ended (any turn), so a nonstop job's break starts now.
    func noteTurnFinished(agentID: UUID) {
        var changed = false
        for index in routines.indices where routines[index].agentID == agentID && routines[index].keepWorking != nil {
            routines[index].lastRunFinishedAt = Date()
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Agent actions

    /// Applies the blocks from one agent reply and returns a status line per
    /// change, for the agent's transcript.
    func apply(_ routineActions: [ClickyRoutineAction], forAgentID agentID: UUID) -> [String] {
        var statusLines: [String] = []
        for routineAction in routineActions {
            if let statusLine = apply(routineAction, forAgentID: agentID) {
                statusLines.append(statusLine)
            }
        }
        if !statusLines.isEmpty {
            save()
        }
        return statusLines
    }

    private func apply(_ routineAction: ClickyRoutineAction, forAgentID agentID: UUID) -> String? {
        let trimmedTitle = routineAction.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let existingRoutineIndex = routines.firstIndex {
            $0.agentID == agentID && $0.title.caseInsensitiveCompare(trimmedTitle) == .orderedSame
        }

        switch routineAction.action {
        case .create:
            guard let task = routineAction.task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty,
                  let requestedEveryMinutes = routineAction.everyMinutes else { return nil }
            let everyMinutes = max(requestedEveryMinutes, Self.minimumEveryMinutes)
            if let existingRoutineIndex {
                // A second "create" with the same title updates the first
                // rather than running two copies side by side.
                routines[existingRoutineIndex].task = task
                routines[existingRoutineIndex].everyMinutes = everyMinutes
                routines[existingRoutineIndex].watchURL = Self.validatedWatchURL(routineAction.watchURL)
                routines[existingRoutineIndex].lastWatchedTextHash = nil
                return "Updated routine “\(routines[existingRoutineIndex].title)”, \(routines[existingRoutineIndex].cadenceDescription)"
            }
            let newRoutine = ClickyRoutine(
                id: UUID(),
                agentID: agentID,
                title: trimmedTitle,
                task: task,
                everyMinutes: everyMinutes,
                isPaused: false,
                createdAt: Date(),
                lastRunStartedAt: Date(),
                runCount: 1,
                failedRunsInARow: 0,
                keepWorking: nil,
                lastRunFinishedAt: nil,
                watchURL: Self.validatedWatchURL(routineAction.watchURL)
            )
            routines.append(newRoutine)
            ClickyAnalytics.trackRoutineChanged(action: "created")
            return "Set up routine “\(newRoutine.title)”, \(newRoutine.cadenceDescription)"

        case .update:
            guard let existingRoutineIndex else { return nil }
            if let newTask = routineAction.task?.trimmingCharacters(in: .whitespacesAndNewlines), !newTask.isEmpty {
                routines[existingRoutineIndex].task = newTask
            }
            if let newEveryMinutes = routineAction.everyMinutes {
                routines[existingRoutineIndex].everyMinutes = max(newEveryMinutes, Self.minimumEveryMinutes)
            }
            if let newTitle = routineAction.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !newTitle.isEmpty {
                routines[existingRoutineIndex].title = newTitle
            }
            if let newWatchURL = routineAction.watchURL {
                routines[existingRoutineIndex].watchURL = Self.validatedWatchURL(newWatchURL)
                routines[existingRoutineIndex].lastWatchedTextHash = nil
            }
            ClickyAnalytics.trackRoutineChanged(action: "updated")
            return "Updated routine “\(routines[existingRoutineIndex].title)”, \(routines[existingRoutineIndex].cadenceDescription)"

        case .delete:
            guard let existingRoutineIndex else { return nil }
            let deletedRoutine = routines.remove(at: existingRoutineIndex)
            ClickyAnalytics.trackRoutineChanged(action: "deleted")
            return "Deleted routine “\(deletedRoutine.title)”"

        case .pause, .resume:
            guard let existingRoutineIndex else { return nil }
            let isPausing = routineAction.action == .pause
            setPaused(isPausing, routineIndex: existingRoutineIndex)
            return "\(isPausing ? "Paused" : "Resumed") routine “\(routines[existingRoutineIndex].title)”"
        }
    }

    /// An http(s) address, or nil.
    private static func validatedWatchURL(_ requestedWatchURL: String?) -> String? {
        guard let trimmedWatchURL = requestedWatchURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let watchURL = URL(string: trimmedWatchURL),
              let scheme = watchURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              watchURL.host != nil else { return nil }
        return trimmedWatchURL
    }

    // MARK: - Saving tokens

    /// A routine starts its own conversation again after this many runs,
    /// carrying over only the last report.
    static let runsPerRoutineSession = 8

    /// Whether this run should start a fresh conversation for the routine.
    func startsFreshSession(routineID: UUID) -> Bool {
        guard let routine = routine(withID: routineID) else { return true }
        let hasConversation = routine.hasStartedGeminiSession == true || routine.claudeThreadID != nil
        return !hasConversation || (routine.runsInCurrentSession ?? 0) >= Self.runsPerRoutineSession
    }

    /// Forgets the routine's conversation so the next run starts a new one,
    /// and returns the Gemini session id to use for it.
    func beginFreshSession(routineID: UUID) -> UUID {
        let freshSessionID = UUID()
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return freshSessionID }
        routines[routineIndex].geminiSessionID = freshSessionID
        routines[routineIndex].hasStartedGeminiSession = false
        routines[routineIndex].claudeThreadID = nil
        routines[routineIndex].runsInCurrentSession = 0
        save()
        return freshSessionID
    }

    func recordGeminiSessionStarted(routineID: UUID) {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[routineIndex].hasStartedGeminiSession = true
        save()
    }

    func recordClaudeThread(_ threadID: String, routineID: UUID) {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }),
              routines[routineIndex].claudeThreadID != threadID else { return }
        routines[routineIndex].claudeThreadID = threadID
        save()
    }

    /// After a run that answered: whether it found anything new, and what it
    /// reported, for the next fresh session.
    func recordRunReport(routineID: UUID, reportText: String, foundNothingNew: Bool) {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[routineIndex].runsInCurrentSession = (routines[routineIndex].runsInCurrentSession ?? 0) + 1
        routines[routineIndex].unchangedRunsInARow = foundNothingNew ? (routines[routineIndex].unchangedRunsInARow ?? 0) + 1 : 0
        // A "nothing new" line says nothing a fresh session needs; keep the
        // last real report.
        if !foundNothingNew {
            routines[routineIndex].lastRunReport = String(reportText.prefix(1200))
        }
        save()
    }

    /// A run skipped because its watched page hadn't changed, without
    /// asking any model. The page check is free, so it stays at the set
    /// pace and a change is caught as soon as it happens.
    func recordSkippedUnchangedRun(routineID: UUID) {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[routineIndex].lastRunStartedAt = Date()
        routines[routineIndex].lastRunFinishedAt = Date()
        save()
    }

    func recordWatchedTextHash(_ watchedTextHash: String, routineID: UUID) {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[routineIndex].lastWatchedTextHash = watchedTextHash
        save()
    }

    func setAlwaysRunsAtSetPace(_ alwaysRunsAtSetPace: Bool, routineID: UUID) {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[routineIndex].alwaysRunsAtSetPace = alwaysRunsAtSetPace
        if alwaysRunsAtSetPace {
            routines[routineIndex].unchangedRunsInARow = 0
        }
        save()
    }

    // MARK: - User actions

    func setPaused(_ isPaused: Bool, routineID: UUID) {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
        setPaused(isPaused, routineIndex: routineIndex)
        save()
    }

    private func setPaused(_ isPaused: Bool, routineIndex: Int) {
        routines[routineIndex].isPaused = isPaused
        if !isPaused {
            // Resuming starts a fresh count, and the next run is a full
            // interval away rather than immediately.
            routines[routineIndex].failedRunsInARow = 0
            routines[routineIndex].lastRunStartedAt = Date()
        }
        ClickyAnalytics.trackRoutineChanged(action: isPaused ? "paused" : "resumed")
    }

    func deleteRoutine(routineID: UUID) {
        routines.removeAll { $0.id == routineID }
        ClickyAnalytics.trackRoutineChanged(action: "deleted")
        save()
    }

    func deleteRoutines(forAgentID agentID: UUID) {
        routines.removeAll { $0.agentID == agentID }
        save()
    }

    // MARK: - Runs

    /// Records that a run is starting and returns its run number.
    func markRunStarted(routineID: UUID) -> Int? {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return nil }
        routines[routineIndex].lastRunStartedAt = Date()
        routines[routineIndex].runCount += 1
        save()
        return routines[routineIndex].runCount
    }

    /// Records how a run ended. Returns true when the routine just paused
    /// itself after too many failures in a row.
    func markRunFinished(routineID: UUID, succeeded: Bool) -> Bool {
        guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return false }
        routines[routineIndex].failedRunsInARow = succeeded ? 0 : routines[routineIndex].failedRunsInARow + 1
        var didPause = false
        if routines[routineIndex].failedRunsInARow >= Self.maximumFailedRunsInARow {
            routines[routineIndex].isPaused = true
            didPause = true
        }
        save()
        return didPause
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let routinesData = try? Data(contentsOf: routinesFileURL),
              let savedRoutines = try? decoder.decode([ClickyRoutine].self, from: routinesData) else { return }
        routines = savedRoutines
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let routinesData = try? encoder.encode(routines) else { return }
        try? routinesData.write(to: routinesFileURL, options: .atomic)
    }
}

// MARK: - Prompts

enum ClickyRoutinePrompts {
    static let openingTag = "<ROUTINE>"
    static let closingTag = "</ROUTINE>"

    /// Pulls every `<ROUTINE>…</ROUTINE>` block out of a reply. Returns the
    /// reply without them and the blocks that parsed.
    static func extractRoutineActions(from replyText: String) -> (replyWithoutBlocks: String, routineActions: [ClickyRoutineAction]) {
        var remainingReply = replyText
        var routineActions: [ClickyRoutineAction] = []
        while let openingTagRange = remainingReply.range(of: openingTag),
              let closingTagRange = remainingReply.range(of: closingTag, range: openingTagRange.upperBound..<remainingReply.endIndex) {
            let blockJSON = String(remainingReply[openingTagRange.upperBound..<closingTagRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let blockData = blockJSON.data(using: .utf8),
               let routineAction = try? JSONDecoder().decode(ClickyRoutineAction.self, from: blockData) {
                routineActions.append(routineAction)
            }
            remainingReply.removeSubrange(openingTagRange.lowerBound..<closingTagRange.upperBound)
        }
        return (remainingReply.trimmingCharacters(in: .whitespacesAndNewlines), routineActions)
    }

    /// The part of every agent's global AGENTS.md about routines. Adapted
    /// from shipped Clicky's RECURRING REQUESTS instructions.
    static let globalAgentInstructions = """
    # Routines

    Dottie can re-run a task in your chat on a schedule while the Mac is awake and Dottie is open; each run's answer lands in your chat and the user's notch. You have no scheduling tool: never say it can't be done, look for cron, or write looping scripts. When the user asks for something on a cadence ("every 30 minutes", "every morning", "keep checking"), do the task once now and answer as usual, then end the same reply with one block:

    <ROUTINE>{"action":"create","every_minutes":60,"title":"Repo Issues","task":"Check the user's GitHub repos for new issues and summarize who opened them and why they matter"}</ROUTINE>

    When the task only matters if a web page changes (a price, a status page, a release list), add `"watch_url":"https://…"` to the block: Dottie reads that page first for free and skips the run while its text is unchanged. Leave it out otherwise.

    `every_minutes` is a whole number of at least \(ClickyRoutineStore.minimumEveryMinutes) (hourly = 60, daily = 1440). `title` is two to four words. `task` is the self-contained instruction for every later run and never repeats the cadence, since Dottie shows the schedule beside it. Confirm the cadence in one sentence of your answer ("I'll check this every hour."), never mention the block, and never promise runs while the Mac is asleep or off.

    To change one of your routines, emit `"action":"update"` with its exact `title` and only what changes: `every_minutes`, `new_title`, or the complete replacement `task`. A second `create` for a routine you already have replaces it. To stop, pause or resume one, emit `"action":"delete"`, `"pause"` or `"resume"` with its `title`. Say in your answer what you changed. Each message tells you which routines you have right now; that list is complete, whatever earlier messages say.

    """

    /// Prepended to every user turn so the agent knows its routines.
    static func currentRoutinesContext(for agentRoutines: [ClickyRoutine]) -> String {
        guard !agentRoutines.isEmpty else {
            return "[Your current routines: none.]"
        }
        let routineLines = agentRoutines.map { routine in
            "- \"\(routine.title)\": \(routine.cadenceDescription)\(routine.isPaused ? " (paused)" : ""). Task: \(routine.task)"
        }
        return "[Your current routines (the title is the handle you use to change one):\n" + routineLines.joined(separator: "\n") + "]"
    }

    /// A run's whole reply when it found nothing worth telling the user.
    /// Such runs stay quiet (no notch card or notification) and let the
    /// routine wait longer before the next one.
    static let nothingNewMarker = "NOTHING NEW"

    static func isNothingNewReply(_ replyText: String) -> Bool {
        let trimmedReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedReply.uppercased().hasPrefix(nothingNewMarker) && trimmedReply.count <= 200
    }

    /// For a run in a fresh conversation: what the last run reported.
    static func lastReportHandover(for routine: ClickyRoutine) -> String {
        guard let lastRunReport = routine.lastRunReport, !lastRunReport.isEmpty else {
            return "Earlier runs of this routine aren't in this conversation, and there's no earlier report."
        }
        return "Earlier runs of this routine aren't in this conversation. The last run that found something reported:\n\"\"\"\n\(lastRunReport)\n\"\"\""
    }

    /// The message for a scheduled run. Adapted from shipped Clicky's run
    /// prompts. Runs keep their own conversation, separate from the chat
    /// with the user; `isFreshSession` means this run starts a new one.
    static func runMessage(for routine: ClickyRoutine, runNumber: Int, previousRunStartedAt: Date, previousRunFailed: Bool, isFreshSession: Bool) -> String {
        let earlierRunsLine = isFreshSession
            ? lastReportHandover(for: routine)
            : "Earlier runs of this routine are in this conversation above."
        var briefLines = [
            "[Routine \"\(routine.title)\" · run \(runNumber)]",
            "",
            "This turn is run #\(runNumber) of the routine \"\(routine.title)\" (\(routine.cadenceDescription)) that the user set up, so Dottie is launching it automatically. The user isn't watching; don't ask them anything unless the routine can't do its job without an answer, and if so say plainly that it's stuck until they reply.",
            "\(earlierRunsLine) The previous run started \(previousRunStartedAt.formatted(date: .abbreviated, time: .shortened)). Report what is NEW or changed since then and keep it short. If nothing is new or changed, reply with exactly \"\(nothingNewMarker)\" and nothing else.",
            "Post the answer as your reply. Don't create files unless the task itself asks for one. Don't emit a <ROUTINE> block to set up this repeat; it already exists."
        ]
        if previousRunFailed {
            briefLines.append("The previous attempt failed or was interrupted. Check the conversation first and finish only what is still missing. Don't repeat a message, post or other external action that already succeeded.")
        }
        if let keepWorking = routine.keepWorking {
            briefLines.append(keepWorkingRules(keepWorking))
        }
        briefLines.append("")
        briefLines.append("Task: \(routine.task)")
        return briefLines.joined(separator: "\n")
    }

    /// What a 24/7 job's helper is told on every run, so Dottie can text
    /// the user about real news and stop when the job is done.
    static func keepWorkingRules(_ keepWorking: ClickyKeepWorking) -> String {
        var rules = "This is a 24/7 job the user asked you to keep working on while they're away. Keep each run focused and make real progress. "
            + "If you find something the user should hear about right away (a real result, a problem, a decision only they can make), start your reply with \"\(ClickyKeepWorking.importantMarker)\" and say it in one or two plain sentences; otherwise don't use that word."
        if keepWorking.untilDone {
            rules += " When the whole job is finished and nothing is left to do, end your reply with a line that says exactly \"\(ClickyKeepWorking.doneMarker)\"."
        }
        return rules
    }

    /// The first run of a 24/7 job, sent to the helper right away.
    static func keepWorkingFirstRunMessage(task: String, cadence: String, keepWorking: ClickyKeepWorking) -> String {
        """
        [24/7 job · run 1 · \(cadence)]

        \(keepWorkingRules(keepWorking)) Dottie will run this again (\(cadence)) on her own, so don't set up a <ROUTINE> block for it.

        Task: \(task)
        """
    }
}

// MARK: - Watched pages

/// Reads a routine's watch_url so a run can be skipped, without asking any
/// model, while the page's text hasn't changed.
enum ClickyRoutineWatchedPage {
    /// A fingerprint of the page's visible text, or nil when it can't be
    /// read (the run then goes ahead as usual).
    static func textHash(of watchURL: URL) async -> String? {
        var request = URLRequest(url: watchURL)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) Dottie", forHTTPHeaderField: "User-Agent")
        guard let (pageData, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else { return nil }
        // Scripts, styles and markup change on every load (nonces, build
        // ids) without anything the user would see changing.
        let visibleText = String(decoding: pageData, as: UTF8.self)
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return SHA256.hash(data: Data(visibleText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
