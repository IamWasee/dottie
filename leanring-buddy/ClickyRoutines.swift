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
//  Saved in ~/Library/Application Support/ClickyClone/Clickys/routines.json.
//

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

    var nextRunAt: Date {
        lastRunStartedAt.addingTimeInterval(TimeInterval(everyMinutes * 60))
    }

    /// "every hour", "every 15 minutes", "every day".
    var cadenceDescription: String {
        ClickyRoutine.cadenceDescription(everyMinutes: everyMinutes)
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

    private enum CodingKeys: String, CodingKey {
        case action, title, task
        case everyMinutes = "every_minutes"
        case newTitle = "new_title"
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
            .filter { !$0.isPaused && $0.nextRunAt <= currentDate }
            .sorted { $0.nextRunAt < $1.nextRunAt }
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
                failedRunsInARow: 0
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

    Clicky can re-run a task in your chat on a schedule while the Mac is awake and Clicky is open; each run's answer lands in your chat and the user's notch. You have no scheduling tool: never say it can't be done, look for cron, or write looping scripts. When the user asks for something on a cadence ("every 30 minutes", "every morning", "keep checking"), do the task once now and answer as usual, then end the same reply with one block:

    <ROUTINE>{"action":"create","every_minutes":60,"title":"Repo Issues","task":"Check the user's GitHub repos for new issues and summarize who opened them and why they matter"}</ROUTINE>

    `every_minutes` is a whole number of at least \(ClickyRoutineStore.minimumEveryMinutes) (hourly = 60, daily = 1440). `title` is two to four words. `task` is the self-contained instruction for every later run and never repeats the cadence, since Clicky shows the schedule beside it. Confirm the cadence in one sentence of your answer ("I'll check this every hour."), never mention the block, and never promise runs while the Mac is asleep or off.

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

    /// The message for a scheduled run. Adapted from shipped Clicky's run
    /// prompts.
    static func runMessage(for routine: ClickyRoutine, runNumber: Int, previousRunStartedAt: Date, previousRunFailed: Bool) -> String {
        var briefLines = [
            "[Routine \"\(routine.title)\" · run \(runNumber)]",
            "",
            "This turn is run #\(runNumber) of the routine \"\(routine.title)\" (\(routine.cadenceDescription)) that the user set up, so Clicky is launching it automatically. The user isn't watching; don't ask them anything unless the routine can't do its job without an answer, and if so say plainly that it's stuck until they reply.",
            "Earlier runs of this routine are in this conversation above. The previous run started \(previousRunStartedAt.formatted(date: .abbreviated, time: .shortened)). Report what is NEW or changed since then, keep it short, and say so in one line if nothing changed.",
            "Post the answer as your reply. Don't create files unless the task itself asks for one. Don't emit a <ROUTINE> block to set up this repeat; it already exists."
        ]
        if previousRunFailed {
            briefLines.append("The previous attempt failed or was interrupted. Check the conversation first and finish only what is still missing. Don't repeat a message, post or other external action that already succeeded.")
        }
        briefLines.append("")
        briefLines.append("Task: \(routine.task)")
        return briefLines.joined(separator: "\n")
    }
}
