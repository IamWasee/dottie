//
//  DottieKeepWorking.swift
//  leanring-buddy
//
//  24/7 mode, only when the user asks for it: "keep working on this all
//  night until it's done", "check every 10 minutes". A helper gets the task
//  now, and the job keeps re-running as a routine (ClickyRoutines), either
//  on an interval or nonstop with a short break between runs, until it's
//  done, its time is up or the user says stop.
//
//  While any 24/7 job is on, the Mac doesn't go to sleep on its own (the
//  display still can), the notch shows a small moon with a stop button,
//  and if the phone is paired (DottiePhoneBridge) the user gets a Telegram
//  text when a run finds something important, fails, or the job is done.
//

import Combine
import Foundation

@MainActor
final class DottieKeepWorking: ObservableObject {
    static let shared = DottieKeepWorking()

    /// The 24/7 jobs that are on.
    @Published private(set) var activeJobs: [ClickyRoutine] = []

    private weak var companion: CompanionManager?
    private var routinesCancellable: AnyCancellable?
    private var endCheckTimer: Timer?
    /// Helpers whose next finished turn is a 24/7 job's first run.
    private var firstRunAgentIDs: Set<UUID> = []

    static let defaultHelperName = "Night Shift"
    static let defaultRestMinutes = 5

    private init() {}

    func attach(to companion: CompanionManager) {
        self.companion = companion
        routinesCancellable = companion.clickyRoster.routineStore.$routines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] routines in
                self?.refresh(routines)
            }
        endCheckTimer?.invalidate()
        endCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopJobsWhoseTimeIsUp()
            }
        }
    }

    private func refresh(_ routines: [ClickyRoutine]) {
        let newActiveJobs = routines.filter { $0.keepWorking != nil && !$0.isPaused }
        if newActiveJobs != activeJobs { activeJobs = newActiveJobs }
        DottieKeepAwake.shared.setActive(!newActiveJobs.isEmpty)
        companion?.notchPresenter.isKeepWorkingOn = !newActiveJobs.isEmpty
    }

    private var routineStore: ClickyRoutineStore? { companion?.clickyRoster.routineStore }

    // MARK: - Starting and stopping

    func start(task: String, title: String?, helperName: String?, everyMinutes: Int?, untilDone: Bool, hours: Double?, untilMorning: Bool) -> String {
        guard let companion, let routineStore else { return "couldn't start that right now." }
        let name = helperName ?? Self.defaultHelperName
        let isNonstop = (everyMinutes ?? 0) <= 0
        let intervalMinutes = max(everyMinutes ?? 0, ClickyRoutineStore.minimumEveryMinutes)

        var endsAt: Date?
        if let hours, hours > 0 {
            endsAt = Date().addingTimeInterval(hours * 3600)
        } else if untilMorning {
            endsAt = Self.nextMorning()
        }
        let keepWorking = ClickyKeepWorking(
            isNonstop: isNonstop,
            restMinutes: max(Self.defaultRestMinutes, ClickyKeepWorking.minimumRestMinutes),
            endsAt: endsAt,
            untilDone: untilDone,
            startedAt: Date()
        )
        let cadence = isNonstop
            ? "nonstop, with \(keepWorking.restMinutes)-minute breaks"
            : ClickyRoutine.cadenceDescription(everyMinutes: intervalMinutes)

        let firstRunMessage = ClickyRoutinePrompts.keepWorkingFirstRunMessage(task: task, cadence: cadence, keepWorking: keepWorking)
        let helperStatus = companion.startClickyTask(clickyName: name, taskText: firstRunMessage, restart: true)
        guard let agent = companion.clickyRoster.agent(matchingName: name) else { return helperStatus }

        let jobTitle = title ?? Self.shortTitle(for: task)
        routineStore.startKeepWorking(agentID: agent.id, title: jobTitle, task: task, everyMinutes: intervalMinutes, keepWorking: keepWorking)
        firstRunAgentIDs.insert(agent.id)
        refresh(routineStore.routines)

        var parts = ["24/7 job \"\(jobTitle)\" is on: \(agent.name) works on it \(cadence)"]
        if let endsAt {
            parts.append("until \(endsAt.formatted(date: .omitted, time: .shortened))")
        }
        if untilDone {
            parts.append("and stops by itself when it's done")
        }
        var result = parts.joined(separator: " ") + ". the mac stays awake while it runs (the display can still sleep). "
        if companion.phoneBridge.pairedChatID != nil {
            result += "the user gets a telegram text if it finds something important or gets stuck. "
        }
        result += "say that in a few words. (helper: \(helperStatus))"
        return result
    }

    /// Stops the job with this title or helper name, or every job.
    @discardableResult
    func stop(matching name: String?) -> String {
        guard let routineStore else { return "nothing to stop." }
        let jobsToStop: [ClickyRoutine]
        if let name {
            let helperIDs = Set(companion?.clickyRoster.agents.filter { $0.name.localizedCaseInsensitiveContains(name) }.map(\.id) ?? [])
            jobsToStop = activeJobs.filter { $0.title.localizedCaseInsensitiveContains(name) || helperIDs.contains($0.agentID) }
        } else {
            jobsToStop = activeJobs
        }
        guard !jobsToStop.isEmpty else {
            return activeJobs.isEmpty ? "no 24/7 jobs are running." : "no 24/7 job matches that. running: " + activeJobs.map(\.title).joined(separator: ", ")
        }
        for job in jobsToStop {
            routineStore.deleteRoutine(routineID: job.id)
        }
        refresh(routineStore.routines)
        let names = jobsToStop.map { "\"\($0.title)\"" }.joined(separator: ", ")
        return "stopped \(names). \(activeJobs.isEmpty ? "the mac can sleep again." : "") a run already in progress finishes on its own."
    }

    func stopAll() {
        stop(matching: nil)
    }

    var statusForVoice: String {
        guard !activeJobs.isEmpty else { return "no 24/7 jobs are running." }
        return activeJobs.map { job in
            let helperName = companion?.clickyRoster.agent(withID: job.agentID)?.name ?? "a helper"
            var line = "\"\(job.title)\" by \(helperName): \(job.cadenceDescription), \(job.runCount) run\(job.runCount == 1 ? "" : "s") so far"
            if let endsAt = job.keepWorking?.endsAt {
                line += ", ends at \(endsAt.formatted(date: .omitted, time: .shortened))"
            }
            if job.keepWorking?.untilDone == true {
                line += ", stops when done"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Runs

    /// Every helper turn ends here (from CompanionManager). Texts the phone
    /// about real news, failures and finished jobs.
    func helperTurnFinished(agentID: UUID, reply: String, succeeded: Bool, routineTitle: String?) {
        guard let routineStore else { return }
        routineStore.noteTurnFinished(agentID: agentID)
        let wasFirstRun = firstRunAgentIDs.remove(agentID) != nil
        guard let job = routineStore.routines.first(where: { routine in
            routine.agentID == agentID && routine.keepWorking != nil
                && (routineTitle.map { $0 == routine.title } ?? wasFirstRun)
        }) else { return }

        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !succeeded {
            if job.isPaused {
                sendToPhone("Your 24/7 job \"\(job.title)\" stopped after \(ClickyRoutineStore.maximumFailedRunsInARow) runs in a row didn't work. Last thing it said: \(trimmedReply.prefix(400))")
            } else {
                sendToPhone("A run of your 24/7 job \"\(job.title)\" didn't work: \(trimmedReply.prefix(400))\nI'll try again on the next run.")
            }
            return
        }
        if trimmedReply.uppercased().contains(ClickyKeepWorking.doneMarker), job.keepWorking?.untilDone == true {
            routineStore.deleteRoutine(routineID: job.id)
            refresh(routineStore.routines)
            let summary = trimmedReply.replacingOccurrences(of: ClickyKeepWorking.doneMarker, with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sendToPhone("Done! Your 24/7 job \"\(job.title)\" is finished.\n\(summary.prefix(1500))")
            DottieLevels.shared.award(.helperTask, points: 2)
            return
        }
        if let importantNews = Self.importantNews(in: trimmedReply) {
            sendToPhone("News from your 24/7 job \"\(job.title)\": \(importantNews.prefix(1500))")
        }
    }

    private func stopJobsWhoseTimeIsUp() {
        guard let routineStore else { return }
        let now = Date()
        let endedJobs = routineStore.routines.filter { $0.keepWorking != nil && $0.hasEnded(at: now) }
        guard !endedJobs.isEmpty else { return }
        for job in endedJobs {
            routineStore.deleteRoutine(routineID: job.id)
            sendToPhone("Time's up: I stopped the 24/7 job \"\(job.title)\" after \(job.runCount) run\(job.runCount == 1 ? "" : "s").")
        }
        refresh(routineStore.routines)
    }

    private func sendToPhone(_ text: String) {
        guard let phoneBridge = companion?.phoneBridge, phoneBridge.pairedChatID != nil else { return }
        Task { await phoneBridge.send(text) }
    }

    // MARK: - Helpers

    /// The text after "IMPORTANT:" when the reply starts a line with it.
    static func importantNews(in reply: String) -> String? {
        for line in reply.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_#> "))
            guard trimmedLine.uppercased().hasPrefix(ClickyKeepWorking.importantMarker) else { continue }
            let afterMarker = reply.range(of: line).map { String(reply[$0.lowerBound...]) } ?? trimmedLine
            return afterMarker
                .replacingOccurrences(of: ClickyKeepWorking.importantMarker, with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// 8 in the morning, today if it's still early, else tomorrow.
    static func nextMorning() -> Date {
        let calendar = Calendar.current
        let todayAtEight = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        return todayAtEight > Date().addingTimeInterval(3600)
            ? todayAtEight
            : calendar.date(byAdding: .day, value: 1, to: todayAtEight) ?? todayAtEight
    }

    /// The first few words of the task, as a title.
    static func shortTitle(for task: String) -> String {
        let words = task.split(whereSeparator: { $0.isWhitespace }).prefix(4)
        let title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet.punctuationCharacters)
        return title.isEmpty ? "24/7 job" : title.prefix(1).uppercased() + title.dropFirst()
    }
}

// MARK: - The voice tool

@MainActor
enum DottieKeepWorkingTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "keep_working",
                description: "24/7 mode: a helper keeps working on a task in the background, re-running it on an interval or nonstop, while the Mac stays awake. Only when the user clearly asks for nonstop or repeated work (\"keep at it all night until it's done\", \"check every 10 minutes\"); never start one on your own. start needs the helper task; stop ends one (or all); status lists them. While one runs the Mac stays awake and the notch shows a moon.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "stop", "status"]],
                        "task": ["type": "STRING", "description": "For start: the full, self-contained task for the helper."],
                        "title": ["type": "STRING", "description": "For start: two to four words naming the job. For stop: which job (leave out to stop all)."],
                        "helper_name": ["type": "STRING", "description": "Which helper does it, if the user named one."],
                        "every_minutes": ["type": "NUMBER", "description": "Run again every this many minutes (at least 10). Leave out for nonstop (runs again a few minutes after each run ends)."],
                        "until_done": ["type": "BOOLEAN", "description": "true when it should stop by itself once the job is finished."],
                        "hours": ["type": "NUMBER", "description": "Stop after this many hours."],
                        "until_morning": ["type": "BOOLEAN", "description": "true for \"all night\": stops at 8 in the morning."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let keepWorking = DottieKeepWorking.shared
                switch arguments.dottieString("action") ?? "status" {
                case "start":
                    guard let task = arguments.dottieString("task") else { return "what should the helper keep working on?" }
                    return keepWorking.start(
                        task: task,
                        title: arguments.dottieString("title"),
                        helperName: arguments.dottieString("helper_name"),
                        everyMinutes: arguments.dottieNumber("every_minutes").map { Int($0.rounded()) },
                        untilDone: arguments.dottieBool("until_done") ?? false,
                        hours: arguments.dottieNumber("hours"),
                        untilMorning: arguments.dottieBool("until_morning") ?? false
                    )
                case "stop":
                    return keepWorking.stop(matching: arguments.dottieString("title") ?? arguments.dottieString("helper_name"))
                default:
                    return keepWorking.statusForVoice
                }
            }
        ]
    }

    static var voicePromptSection: String {
        """
        locked screen: helpers and non-screen tools work as usual, but screen jobs wait and start by themselves when the user unlocks. say so if asked from the phone.
        """
    }
}
