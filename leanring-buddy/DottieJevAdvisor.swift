//
//  DottieJevAdvisor.swift
//  leanring-buddy
//
//  Jev's advisor. Jev drives every screen-job step fast, but it picks from
//  a list and can't judge ("the newest email", "the most viewed video"),
//  reason or wait (Wasee's tests, 27 Nov). The advisor (Claude Haiku
//  through the Worker's "advisor" role, text only: the screen's words and
//  Jev's options, never a screenshot) reads the task once, at the same
//  moment Jev starts, and writes the steps plus the moments it will be
//  needed. Dottie watches for those moments on the Mac with no model call;
//  only then, or when Jev is unsure, a move failed, the user gave a hint or
//  a time shows on screen, the advisor is asked once: it picks one of Jev's
//  options, says how long to wait, or leaves a short note for the next
//  steps, and Jev carries on. Calls per job are capped so a long job stays
//  cheap. The plan part is Foundation only, so it can be unit tested.
//

import Foundation

enum DottieJevAdvisorPlan {
    enum NeedKind: String, Equatable, Sendable {
        case judge
        case wait
        case reason
    }

    /// A moment in the job the advisor said it will be needed for.
    struct Checkpoint: Equatable, Sendable {
        /// Words that will be on screen at that moment ("views", "Inbox").
        let watchWords: [String]
        let kind: NeedKind
        /// What to do then, in one line.
        let advice: String
    }

    struct Brief: Equatable, Sendable {
        let steps: [String]
        let checkpoints: [Checkpoint]

        static let empty = Brief(steps: [], checkpoints: [])
    }

    /// Why the advisor is being asked now.
    enum Trigger: Equatable, Sendable {
        case checkpoint(Checkpoint)
        case jevUnsure
        case moveFailed
        case userHint(String)
        case timeShown(seconds: Int)

        var reasonText: String {
            switch self {
            case .checkpoint(let checkpoint):
                switch checkpoint.kind {
                case .judge: return "this step needs judging or comparing: \(checkpoint.advice)"
                case .wait: return "this step may need waiting: \(checkpoint.advice)"
                case .reason: return "this step needs reasoning: \(checkpoint.advice)"
                }
            case .jevUnsure: return "Jev isn't sure what to do next."
            case .moveFailed: return "Jev's last move didn't work."
            case .userHint(let hintText): return "the user just said: \(hintText)"
            case .timeShown(let seconds): return "the screen shows about \(seconds) seconds left of something."
            }
        }
    }

    enum Advice: Equatable, Sendable {
        /// Do Jev's option with this number (1-based, as the advisor saw it).
        case pick(optionNumber: Int, note: String?)
        case wait(seconds: Int)
        /// A short instruction for Jev's next steps.
        case note(String)
        /// The whole job is already done: Jev couldn't tell, so the advisor
        /// says so (Wasee, 27 Nov: a YouTube job that had worked ended in
        /// "slow answer" instead of finishing).
        case done
        case none
    }

    static let maximumSteps = 8
    static let maximumCheckpoints = 6
    /// Advice calls a job may make: this many, plus one per round of a
    /// repeated job, so a 1,000-round job can't run up a bill.
    static let baseAdviceCallsPerJob = 10
    static let maximumAdviceCallsPerJob = 400
    static let maximumScreenLines = 60
    static let maximumOptionsShown = 80
    /// Advisor notes Jev reads at once: older ones are dropped, not piled up.
    static let maximumNotesKept = 2
    static let maximumNoteCharacters = 200
    static let defaultWaitSeconds = 60
    static let maximumSingleWaitSeconds = 600
    /// A round (or a job that doesn't repeat) never waits longer than this in total.
    static let maximumTotalWaitSeconds = 1_800

    static func adviceCallBudget(rounds: Int) -> Int {
        min(baseAdviceCallsPerJob + max(rounds, 1), maximumAdviceCallsPerJob)
    }

    // MARK: The brief, once per job

    static func briefPrompt(taskText: String, appKnowledge: String = "") -> String {
        """
        You advise Jev, a fast model that does a job on a Mac screen one move at a time. Jev picks moves well but can't judge or compare, reason, or wait.
        The job: \(taskText)\(appKnowledgeLines(appKnowledge))
        Write:
        - steps: the steps in order, short, at most \(maximumSteps).
        - checkpoints: up to \(maximumCheckpoints) moments where Jev will need you: judging or comparing (newest, cheapest, most viewed, the right one), waiting (something loads, exports, uploads, a timer runs), or reasoning (check a total, read and decide). For each: "watch": 1 to 3 words that will be on the screen at that moment, "kind": judge, wait or reason, "advice": what to do then, one line. Only real ones; none is fine.
        Answer JSON only: {"steps":["..."],"checkpoints":[{"watch":["..."],"kind":"judge","advice":"..."}]}
        """
    }

    /// What Dottie knows about the app and the task, on its own lines
    /// after the job, or nothing when she knows nothing.
    static func appKnowledgeLines(_ appKnowledge: String) -> String {
        let trimmedKnowledge = appKnowledge.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKnowledge.isEmpty ? "" : "\nWhat Dottie knows about this app and task:\n" + String(trimmedKnowledge.prefix(2000))
    }

    static func brief(fromAnswer answerText: String) -> Brief? {
        guard let object = jsonObject(in: answerText) else { return nil }
        let steps = (object["steps"] as? [Any] ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maximumSteps)
        let checkpoints = (object["checkpoints"] as? [Any] ?? []).compactMap { item -> Checkpoint? in
            guard let checkpointObject = item as? [String: Any],
                  let kindText = checkpointObject["kind"] as? String,
                  let kind = NeedKind(rawValue: kindText.lowercased()),
                  let advice = (checkpointObject["advice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !advice.isEmpty else { return nil }
            let watchWords = (checkpointObject["watch"] as? [Any] ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(3)
            return Checkpoint(watchWords: Array(watchWords), kind: kind, advice: String(advice.prefix(maximumNoteCharacters)))
        }
        return Brief(steps: Array(steps), checkpoints: Array(checkpoints.prefix(maximumCheckpoints)))
    }

    /// The first checkpoint not yet used whose watch words are all on the
    /// screen now. A checkpoint with no watch words never fires by itself.
    static func firedCheckpoint(in brief: Brief, screenTexts: [String], alreadyFired: Set<Int>) -> (index: Int, checkpoint: Checkpoint)? {
        let screenWords = " " + DottieJevDriverPlan.comparableWords(screenTexts.joined(separator: " ")) + " "
        for (index, checkpoint) in brief.checkpoints.enumerated() where !alreadyFired.contains(index) && !checkpoint.watchWords.isEmpty {
            let allShown = checkpoint.watchWords.allSatisfy { watchWord in
                let comparableWatchWord = DottieJevDriverPlan.comparableWords(watchWord)
                return !comparableWatchWord.isEmpty && screenWords.contains(" " + comparableWatchWord + " ")
            }
            if allShown { return (index, checkpoint) }
        }
        return nil
    }

    // MARK: Advice, only when needed

    static func advicePrompt(
        taskText: String,
        trigger: Trigger,
        screenLines: [(text: String, centerX: Double, centerY: Double)],
        optionDescriptions: [String],
        jobStateText: String,
        appKnowledge: String = ""
    ) -> String {
        let shownLines = screenLines
            .sorted { $0.centerY == $1.centerY ? $0.centerX < $1.centerX : $0.centerY < $1.centerY }
            .prefix(maximumScreenLines)
            .map { "(\(Int($0.centerX * 100)),\(Int($0.centerY * 100))) \($0.text)" }
        let shownOptions = optionDescriptions.prefix(maximumOptionsShown).enumerated().map { "\($0.offset + 1). \($0.element)" }
        return """
        You advise Jev on one step of a job on a Mac screen. Jev picks moves but can't judge, reason or wait.
        The job: \(taskText)\(appKnowledgeLines(appKnowledge))
        Why you're asked: \(trigger.reasonText)
        \(jobStateText)
        Text on the screen now, top to bottom, (x,y) from 0 to 100:
        \(shownLines.joined(separator: "\n"))
        Jev's options:
        \(shownOptions.joined(separator: "\n"))
        Answer JSON only, one of:
        {"do":"pick","option":N,"note":"why, short"} to do one of Jev's options now;
        {"do":"wait","seconds":N} when the screen is busy (loading, exporting, a timer);
        {"do":"note","note":"..."} a short instruction for Jev's next moves when no option fits yet;
        {"do":"done"} when the moves so far and the screen show every part of the job is already done;
        {"do":"none"} when you can't help.
        """
    }

    static func advice(fromAnswer answerText: String, optionCount: Int) -> Advice? {
        guard let object = jsonObject(in: answerText), let action = (object["do"] as? String)?.lowercased() else { return nil }
        let note = (object["note"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNoteCharacters)) }
        switch action {
        case "pick":
            guard let optionNumber = (object["option"] as? NSNumber)?.intValue,
                  optionNumber >= 1, optionNumber <= min(optionCount, maximumOptionsShown) else { return nil }
            return .pick(optionNumber: optionNumber, note: note?.isEmpty == true ? nil : note)
        case "wait":
            let seconds = (object["seconds"] as? NSNumber)?.intValue ?? defaultWaitSeconds
            return .wait(seconds: min(max(seconds, 1), maximumSingleWaitSeconds))
        case "note":
            guard let note, !note.isEmpty else { return nil }
            return .note(note)
        case "done":
            return .done
        case "none":
            return Advice.none
        default:
            return nil
        }
    }

    // MARK: Waiting

    /// "2 min left", "1:30 remaining", "about 45 seconds", "ETA 00:05:00":
    /// the longest time a screen text says is left, in seconds.
    static func secondsShown(in screenTexts: [String]) -> Int? {
        var longestSeconds: Int?
        func keep(_ seconds: Int) {
            guard seconds > 0 else { return }
            longestSeconds = max(longestSeconds ?? 0, seconds)
        }
        for text in screenTexts where text.contains(where: \.isNumber) {
            let lowercasedText = text.lowercased()
            let range = NSRange(lowercasedText.startIndex..., in: lowercasedText)
            func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
                guard index < match.numberOfRanges, let groupRange = Range(match.range(at: index), in: lowercasedText) else { return nil }
                return String(lowercasedText[groupRange])
            }
            if let expression = unitLeftExpression {
                for match in expression.matches(in: lowercasedText, range: range) {
                    if let amount = group(match, 1).flatMap(Int.init), let unit = group(match, 2) { keep(amount * secondsPerUnit(unit)) }
                }
            }
            if let expression = leadingUnitExpression {
                for match in expression.matches(in: lowercasedText, range: range) {
                    if let amount = group(match, 2).flatMap(Int.init), let unit = group(match, 3) { keep(amount * secondsPerUnit(unit)) }
                }
            }
            if let expression = clockExpression {
                for match in expression.matches(in: lowercasedText, range: range) {
                    let parts = group(match, 1) != nil ? [1, 2, 3] : [6, 7, 8]
                    let numbers = parts.compactMap { group(match, $0).flatMap(Int.init) }
                    if numbers.count == 3 {
                        keep(numbers[0] * 3_600 + numbers[1] * 60 + numbers[2])
                    } else if numbers.count == 2 {
                        keep(numbers[0] * 60 + numbers[1])
                    }
                }
            }
        }
        return longestSeconds
    }

    // Made once: this runs on every screen text of every step.
    private static let unitLeftExpression = try? NSRegularExpression(
        pattern: #"(\d{1,4})\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b[^\n]{0,20}?\b(left|remaining|to go)\b"#
    )
    private static let leadingUnitExpression = try? NSRegularExpression(
        pattern: #"\b(about|eta|in|wait|remaining:?|left:?)\s+(\d{1,4})\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#
    )
    private static let clockExpression = try? NSRegularExpression(
        pattern: #"(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(left|remaining|to go)\b|\b(eta|remaining:?|left:?)\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"#
    )

    private static func secondsPerUnit(_ unit: String) -> Int {
        if unit.hasPrefix("h") { return 3_600 }
        if unit.hasPrefix("m") { return 60 }
        return 1
    }

    /// How long to wait before looking again: what the screen says, or a
    /// minute when it says nothing, never more than ten minutes at once.
    static func waitSeconds(shownSeconds: Int?) -> Int {
        min(max(shownSeconds ?? defaultWaitSeconds, 5), maximumSingleWaitSeconds)
    }

    /// Why to ask the advisor before Jev this step, if at all. Being stuck
    /// comes first (the job would hand over otherwise), then what the user
    /// just said, then a time on screen (once until it's gone), then a
    /// checkpoint the brief named.
    static func triggerBeforeJev(
        isStuck: Bool,
        newHintTexts: [String],
        secondsShownOnScreen: Int?,
        timeTriggerArmed: Bool,
        firedCheckpoint: Checkpoint?
    ) -> Trigger? {
        if isStuck { return .moveFailed }
        if let newestHint = newHintTexts.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .userHint(newestHint)
        }
        if let secondsShownOnScreen, timeTriggerArmed { return .timeShown(seconds: secondsShownOnScreen) }
        if let firedCheckpoint { return .checkpoint(firedCheckpoint) }
        return nil
    }

    /// Whether Jev waits for this advice. Only when the job would hand over
    /// otherwise (stuck, unsure, failed checks); everything else is thought
    /// over alongside Jev, which keeps moving (Wasee, 27 Nov).
    static func mustWaitForAdvice(_ trigger: Trigger) -> Bool {
        switch trigger {
        case .moveFailed, .jevUnsure: return true
        case .checkpoint, .userHint, .timeShown: return false
        }
    }

    /// What Jev's driver does with an option the advisor picked: the
    /// finishing options end the round or the job like Jev's own pick
    /// would; "none of these" is no help (nil).
    static func decision(forAdvisedMove move: DottieJevDriverPlan.Move, hasRoundsLeft: Bool, roundHasMoves: Bool) -> DottieJevDriverPlan.Decision? {
        switch move {
        case .noneFits:
            return nil
        case .finishedRound:
            return roundHasMoves ? .roundDone : nil
        case .finished:
            if hasRoundsLeft { return roundHasMoves ? .roundDone : nil }
            return .finished
        default:
            return .act(move)
        }
    }

    /// How much of a wait the round still allows (0 once it has waited its most).
    static func waitAllowance(requestedSeconds: Int, secondsWaitedThisRound: Int) -> Int {
        max(0, min(requestedSeconds, maximumTotalWaitSeconds - secondsWaitedThisRound))
    }

    /// "45 s", "2 min" for the notch while Dottie waits.
    static func waitText(seconds: Int) -> String {
        seconds < 90 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded())) min"
    }

    // MARK: Advice that came back while Jev went on

    enum BackgroundAdviceUse: Equatable {
        case decision(DottieJevDriverPlan.Decision)
        case wait(seconds: Int)
        case nothing
    }

    /// What a step does with advice that came back while Jev kept going:
    /// a picked move is made when that same move is still offered (with
    /// where it is now); "done" and waits only count on the screen they
    /// were asked about, since Jev may have moved on since.
    @MainActor
    static func use(of help: DottieJevAdvisorSession.Help, askedOnSameScreen: Bool, currentOptions: [DottieJevDriverPlan.Option]) -> BackgroundAdviceUse {
        switch help {
        case .decision(.act(let advisedMove)):
            guard let currentOption = currentOptions.first(where: { $0.move.signature == advisedMove.signature }) else { return .nothing }
            return .decision(.act(currentOption.move))
        case .decision(let otherDecision):
            return askedOnSameScreen && otherDecision != .unsure ? .decision(otherDecision) : .nothing
        case .wait(let seconds):
            return askedOnSameScreen ? .wait(seconds: seconds) : .nothing
        case .noted, .noHelp:
            return .nothing
        }
    }

    // MARK: What Jev reads from the advisor

    /// The notes with a new one added, only the newest few kept.
    static func keptNotes(_ notes: [String], adding newNote: String) -> [String] {
        let trimmedNote = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else { return notes }
        return Array((notes.filter { $0 != trimmedNote } + [trimmedNote]).suffix(maximumNotesKept))
    }

    /// The advisor's steps and current notes, as one block of Jev's how-to.
    static func howToText(brief: Brief?, notes: [String]) -> String {
        var lines: [String] = []
        if let brief, !brief.steps.isEmpty {
            lines.append("The advisor's plan: " + brief.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " "))
        }
        if !notes.isEmpty {
            lines.append("The advisor says now: " + notes.joined(separator: " Then: "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// The JSON object in a model's answer, even with words or a code fence around it.
    static func jsonObject(in answerText: String) -> [String: Any]? {
        guard let openingBrace = answerText.firstIndex(of: "{"), let closingBrace = answerText.lastIndex(of: "}"),
              openingBrace < closingBrace,
              let data = String(answerText[openingBrace...closingBrace]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Asks the Worker's advisor role. nil when it fails or is too slow; the
/// job then goes on as if there were no advisor.
enum DottieJevAdvisor {
    static func brief(forTask taskText: String, appKnowledge: String = "") async -> DottieJevAdvisorPlan.Brief? {
        let requestBody: [String: Any] = [
            "provider": "advisor",
            "contents": [["role": "user", "parts": [["text": DottieJevAdvisorPlan.briefPrompt(taskText: taskText, appKnowledge: appKnowledge)]]]],
            "generationConfig": ["maxOutputTokens": 500]
        ]
        guard let answerText = await DottieChat.send(requestBody, timeout: 12) else { return nil }
        let brief = DottieJevAdvisorPlan.brief(fromAnswer: answerText)
        DottieLog.notice("🧭 Advisor planned \(public: brief?.steps.count ?? 0) step(s) and \(public: brief?.checkpoints.count ?? 0) checkpoint(s)")
        return brief
    }

    static func advise(prompt: String, optionCount: Int) async -> DottieJevAdvisorPlan.Advice? {
        let requestBody: [String: Any] = [
            "provider": "advisor",
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["maxOutputTokens": 150]
        ]
        guard let answerText = await DottieChat.send(requestBody, timeout: 10) else { return nil }
        return DottieJevAdvisorPlan.advice(fromAnswer: answerText, optionCount: optionCount)
    }
}

/// One job's advisor: the brief (asked the moment the job starts, used as
/// soon as it's back, never waited for), the checkpoints already used this
/// round, the notes Jev reads, the advice calls left and the round's waits.
@MainActor
final class DottieJevAdvisorSession {
    enum Help: Equatable {
        case decision(DottieJevDriverPlan.Decision)
        case wait(seconds: Int)
        case noted
        case noHelp
    }

    let taskText: String
    private(set) var brief: DottieJevAdvisorPlan.Brief?
    private(set) var notes: [String] = []
    private(set) var adviceCallsLeft: Int
    private(set) var secondsWaitedThisRound = 0
    private var firedCheckpointIndexes = Set<Int>()
    private var timeTriggerArmed = true

    /// What Dottie knows about the app and this task (its card, a saved
    /// task's steps and problems), looked up once as the job started.
    let appKnowledge: String

    init(taskText: String, rounds: Int, asksForBrief: Bool = true, appKnowledge: String = "") {
        self.taskText = taskText
        self.appKnowledge = appKnowledge
        adviceCallsLeft = DottieJevAdvisorPlan.adviceCallBudget(rounds: rounds)
        guard asksForBrief else { return }
        Task { [weak self] in
            let askedBrief = await DottieJevAdvisor.brief(forTask: taskText, appKnowledge: appKnowledge)
            self?.brief = askedBrief
        }
    }

    /// The advisor's plan and notes, put first in Jev's how-to (the how-to
    /// is cut at its end when long).
    var howToText: String { DottieJevAdvisorPlan.howToText(brief: brief, notes: notes) }

    func triggerBeforeJev(screenTexts: [String], newHintTexts: [String], isStuck: Bool) -> DottieJevAdvisorPlan.Trigger? {
        let secondsShownOnScreen = DottieJevAdvisorPlan.secondsShown(in: screenTexts)
        let fired = brief.flatMap {
            DottieJevAdvisorPlan.firedCheckpoint(in: $0, screenTexts: screenTexts, alreadyFired: firedCheckpointIndexes)
        }
        let trigger = DottieJevAdvisorPlan.triggerBeforeJev(
            isStuck: isStuck, newHintTexts: newHintTexts, secondsShownOnScreen: secondsShownOnScreen,
            timeTriggerArmed: timeTriggerArmed, firedCheckpoint: fired?.checkpoint
        )
        // A time on screen asks once; it's asked again only after it was gone.
        if secondsShownOnScreen == nil { timeTriggerArmed = true }
        switch trigger {
        case .some(.timeShown): timeTriggerArmed = false
        case .some(.checkpoint): if let fired { firedCheckpointIndexes.insert(fired.index) }
        default: break
        }
        return trigger
    }

    func help(
        trigger: DottieJevAdvisorPlan.Trigger,
        screenTexts: [DottieJevDriverPlan.ScreenText],
        options: [DottieJevDriverPlan.Option],
        jobStateText: String,
        hasRoundsLeft: Bool,
        roundHasMoves: Bool
    ) async -> Help {
        guard adviceCallsLeft > 0 else {
            DottieLog.notice("🧭 The advisor has no advice calls left for this job")
            return .noHelp
        }
        adviceCallsLeft -= 1
        let prompt = DottieJevAdvisorPlan.advicePrompt(
            taskText: taskText, trigger: trigger,
            screenLines: screenTexts.map { (text: $0.text, centerX: $0.centerX / 1000, centerY: $0.centerY / 1000) },
            optionDescriptions: options.map(\.textForModels), jobStateText: jobStateText, appKnowledge: appKnowledge
        )
        guard let advice = await DottieJevAdvisor.advise(prompt: prompt, optionCount: options.count) else {
            DottieLog.notice("🧭 The advisor didn't answer")
            return .noHelp
        }
        switch advice {
        case .pick(let optionNumber, _):
            let pickedMove = options[optionNumber - 1].move
            guard let decision = DottieJevAdvisorPlan.decision(forAdvisedMove: pickedMove, hasRoundsLeft: hasRoundsLeft, roundHasMoves: roundHasMoves) else {
                return .noHelp
            }
            DottieLog.notice("🧭 The advisor picked a move: \(pickedMove.summary)")
            return .decision(decision)
        case .wait(let seconds):
            DottieLog.notice("🧭 The advisor said to wait \(public: seconds) s")
            return .wait(seconds: seconds)
        case .note(let noteText):
            notes = DottieJevAdvisorPlan.keptNotes(notes, adding: noteText)
            DottieLog.notice("🧭 The advisor left Jev a note: \(noteText)")
            return .noted
        case .done:
            guard let decision = DottieJevAdvisorPlan.decision(forAdvisedMove: .finished, hasRoundsLeft: hasRoundsLeft, roundHasMoves: roundHasMoves) else {
                return .noHelp
            }
            DottieLog.notice("🧭 The advisor said the job is done")
            return .decision(decision)
        case .none:
            return .noHelp
        }
    }

    // MARK: Thinking alongside Jev

    /// The advice asked in the background, and what came back. Jev never
    /// waits for it (Wasee, 27 Nov: "Claude isn't supposed to slow Dottie
    /// down"); the next step uses it if it still fits the screen.
    @MainActor
    final class AdviceInFlight {
        let askedOnScreen: [UInt8]
        let trigger: DottieJevAdvisorPlan.Trigger
        var help: Help?
        init(askedOnScreen: [UInt8], trigger: DottieJevAdvisorPlan.Trigger) {
            self.askedOnScreen = askedOnScreen
            self.trigger = trigger
        }
    }

    /// Asks for advice without waiting: the answer lands on the returned
    /// value when it comes.
    func helpInBackground(
        trigger: DottieJevAdvisorPlan.Trigger,
        askedOnScreen: [UInt8],
        screenTexts: [DottieJevDriverPlan.ScreenText],
        options: [DottieJevDriverPlan.Option],
        jobStateText: String,
        hasRoundsLeft: Bool,
        roundHasMoves: Bool
    ) -> AdviceInFlight {
        let inFlight = AdviceInFlight(askedOnScreen: askedOnScreen, trigger: trigger)
        DottieLog.notice("🧭 Asking the advisor alongside Jev (Jev doesn't wait)")
        Task { [weak self] in
            guard let self else { return }
            inFlight.help = await self.help(
                trigger: trigger, screenTexts: screenTexts, options: options, jobStateText: jobStateText,
                hasRoundsLeft: hasRoundsLeft, roundHasMoves: roundHasMoves
            )
        }
        return inFlight
    }

    /// Seconds this wait may take; 0 when the round has waited its most.
    func allowedWait(_ requestedSeconds: Int) -> Int {
        DottieJevAdvisorPlan.waitAllowance(requestedSeconds: requestedSeconds, secondsWaitedThisRound: secondsWaitedThisRound)
    }

    func noteWaited(_ seconds: Int) {
        secondsWaitedThisRound += max(seconds, 0)
    }

    /// A new round: checkpoints can fire again, old notes and waits go.
    func startRound() {
        firedCheckpointIndexes = []
        notes = []
        secondsWaitedThisRound = 0
        timeTriggerArmed = true
    }

    /// After a ledger page: only the notes the page kept.
    func restoreNotes(_ savedNotes: [String]) {
        notes = Array(savedNotes.suffix(DottieJevAdvisorPlan.maximumNotesKept))
    }
}
