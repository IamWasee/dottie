//
//  DottieAppTasks.swift
//  leanring-buddy
//
//  Named app tasks: the jobs Dottie knows how to do in each app or site,
//  named the way the app's own users would ("Rename a column", "Create a
//  query", "Export as PDF"). Wasee (27 Nov) wanted Dottie to understand the
//  specific tasks inside an app and make them herself, so she knows what
//  she's doing and can troubleshoot. Every screen job Jev finishes becomes
//  one: its steps (what was clicked, typed into and pressed, where it sat
//  and on which page; typed words that came from the request are marked so
//  the next request's own words go there), what it's for and when it's
//  done, how often it worked, and the problems it hit with what fixed them.
//  One cheap text call names it in the background. The next request for the
//  same task replays the steps one at a time, checking each against the
//  screen (DottieLooseLabels), and Jev takes over with a note where a step
//  isn't there; the task's notes go to Jev, its advisor and the step model.
//  This is also the app memory review's "goal paths" (27 Nov): a finished
//  job's path, replayed next time without asking a model per step.
//  Each app or site also gets a short card on how it works, written once
//  from what app memory saw and the tasks Dottie knows there, for the
//  advisor and the step model. Stored in Application Support/Dottie/AppTasks/.
//

import Combine
import Foundation

/// One step of a named task, kept so it can be done again.
struct DottieAppTaskStep: Codable, Equatable {
    enum Kind: String, Codable {
        case click, doubleClick, rightClick, typeIntoField, typeText, pressReturn, pressKeys
        /// The mouse pointed at it without a click (a menu that opens on hover).
        case hover
        case scrollDown, scrollUp, scrollLeft, scrollRight, goBack
        case openSite, searchWeb, openApp, quickMacAction
        /// A step only Jev can pick again (an icon with no words, a drag).
        case jevPicks
    }

    let kind: Kind
    /// What was clicked or typed into as it read on screen, or the keys,
    /// the site or the app.
    let label: String
    /// "button", "link", "text box"… when Accessibility named it.
    let role: String?
    /// Where it was, 0-1000 across and down the screen.
    let centerX: Double?
    let centerY: Double?
    /// The typed or searched text, or what a key press does.
    let text: String?
    /// The typed text came from the user's request ("cats" in "search for
    /// cats"): the next request's own words go there.
    let textCameFromRequest: Bool
    let pressesReturn: Bool
    /// The window title it was done on.
    let pageTitle: String
}

/// Something that went wrong on a named task, and what worked instead.
struct DottieAppTaskProblem: Codable, Equatable {
    /// Counted from 1.
    let stepNumber: Int
    /// The step as Dottie expected to do it.
    let expected: String
    let whatHappened: String
    /// The moves that worked instead, when the job still finished.
    var fix: String?
    let seenAt: Date
}

/// One task Dottie knows how to do in one app or site.
struct DottieAppTask: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var purpose: String
    var doneWhen: String
    var tips: [String]
    /// The app or site, as people say it ("Notion", "youtube.com").
    var appName: String
    /// Bundle identifiers and site hosts the task worked in.
    var places: [String]
    /// The requests it was used for, newest last.
    var exampleRequests: [String]
    var steps: [DottieAppTaskStep]
    /// The request the steps were recorded for (for putting a new
    /// request's words where the old one's were typed).
    var stepsRecordedFor: String
    var finalPageTitle: String?
    var timesRun: Int
    var timesSucceeded: Int
    var problems: [DottieAppTaskProblem]
    let createdAt: Date
    var lastUsed: Date
    /// False until the naming call answered (the name is the request's start).
    var isNamed: Bool
    /// The user showed it while Dottie watched (watch me): worth one try
    /// from memory before it has worked in a job.
    var learnedByWatching: Bool? = nil
    /// The user explained it in words in Home → Admin (DottieAppNotes): its
    /// steps are tips until a job records real ones.
    var learnedFromNotes: Bool? = nil
}

/// A short card on how one app or site works.
struct DottieAppCard: Codable, Equatable {
    var appName: String
    var text: String
    var madeAt: Date
    /// How many named tasks the place had when the card was written.
    var taskCountWhenMade: Int
}

/// What one Jev job did, step by step, for saving as a task.
struct DottieAppTaskRecording: Equatable {
    private(set) var steps: [DottieAppTaskStep] = []
    /// Each step's place (site host, else bundle identifier), in order.
    private(set) var placeKeys: [String] = []
    private(set) var placeNames: [String: String] = [:]
    private(set) var bundleIdentifiersByPlace: [String: String] = [:]
    var finalPageTitle: String?

    mutating func note(_ step: DottieAppTaskStep, placeKey: String, placeName: String, bundleIdentifier: String) {
        steps.append(step)
        placeKeys.append(placeKey)
        placeNames[placeKey] = placeName
        bundleIdentifiersByPlace[placeKey] = bundleIdentifier
    }

    /// The last step changed nothing or Jev's check said it failed.
    mutating func dropLastStep() {
        guard !steps.isEmpty else { return }
        steps.removeLast()
        placeKeys.removeLast()
    }

    /// Where most of the steps happened.
    var mainPlaceKey: String? {
        var countsByPlace: [String: Int] = [:]
        for placeKey in placeKeys { countsByPlace[placeKey, default: 0] += 1 }
        return countsByPlace.max { first, second in
            first.value == second.value ? first.key > second.key : first.value < second.value
        }?.key
    }

    var mainPlaceName: String? { mainPlaceKey.flatMap { placeNames[$0] } }
    var places: [String] { Array(Set(placeKeys)).sorted() }
}

/// A saved task being done again inside a Jev job, step by step.
struct DottieAppTaskPathReplay: Equatable {
    let task: DottieAppTask
    private(set) var nextStepIndex = 0
    /// The step's target wasn't on the last look; one more look first.
    var missedOnce = false
    /// Jev is doing the current step; the saved steps go on when Jev's
    /// move is that step.
    var jevIsDoingStep = false

    init(task: DottieAppTask) {
        self.task = task
    }

    var isDone: Bool { nextStepIndex >= task.steps.count }
    var currentStep: DottieAppTaskStep? { isDone ? nil : task.steps[nextStepIndex] }

    mutating func advance() {
        nextStepIndex += 1
        missedOnce = false
        jevIsDoingStep = false
    }

    /// A problem with the step about to be done.
    func problemWithCurrentStep(_ whatHappened: String, now: Date) -> DottieAppTaskProblem {
        DottieAppTaskProblem(stepNumber: nextStepIndex + 1, expected: currentStep.map(DottieAppTaskPlan.stepLine) ?? "the last step",
                             whatHappened: whatHappened, fix: nil, seenAt: now)
    }

    /// A problem with the step just done (it changed nothing).
    func problemWithStepJustDone(_ whatHappened: String, now: Date) -> DottieAppTaskProblem {
        let doneIndex = max(0, nextStepIndex - 1)
        let doneStep = doneIndex < task.steps.count ? task.steps[doneIndex] : nil
        return DottieAppTaskProblem(stepNumber: doneIndex + 1, expected: doneStep.map(DottieAppTaskPlan.stepLine) ?? "a step",
                                    whatHappened: whatHappened, fix: nil, seenAt: now)
    }

    /// The note Jev gets once the saved steps stop fitting the screen.
    func noteForJev(reason: String) -> String {
        let remainingSteps = task.steps.dropFirst(nextStepIndex).prefix(8).map(DottieAppTaskPlan.stepLine)
        return "Dottie was doing the saved task \"\(task.name)\" from memory and got to step \(nextStepIndex + 1) of \(task.steps.count), "
            + "but \(reason). Carry on from this screen yourself."
            + (remainingSteps.isEmpty ? "" : " The saved steps left were: " + remainingSteps.joined(separator: "; ") + ".")
    }

    /// Whether the move Jev picked is the saved step it was asked to take.
    static func jevMoveIsTheStep(_ move: DottieJevDriverPlan.Move, step: DottieAppTaskStep, requestText: String) -> Bool {
        guard let moveStep = DottieAppTaskPlan.step(from: move, pageTitle: step.pageTitle, requestText: requestText) else { return false }
        switch step.kind {
        case .typeIntoField, .typeText:
            return moveStep.kind == .typeIntoField || moveStep.kind == .typeText
        case .searchWeb, .jevPicks:
            return moveStep.kind == step.kind
        default:
            return moveStep.kind == step.kind
                && (step.label.isEmpty || DottieLooseLabels.similarity(moveStep.label, step.label) >= DottieLooseLabels.sameControlScore)
        }
    }
}

/// The pure parts: steps from moves and back, matching a request to a
/// task, updating counts and problems, and the texts for the models.
enum DottieAppTaskPlan {
    static let maximumTasks = 300
    static let maximumStepsPerTask = 80
    static let maximumExampleRequests = 5
    static let maximumProblemsKept = 6
    static let maximumKnowledgeCharacters = 1500
    /// A task fits a request in the place it was done in from this score.
    static let fitInSamePlace = 0.5
    /// Anywhere else, the request must name the task more clearly.
    static let fitElsewhere = 0.75
    /// A card is written again after this long, or after this many new tasks.
    static let cardRefreshInterval: TimeInterval = 30 * 24 * 60 * 60
    static let newTasksThatRefreshACard = 3

    // MARK: Steps from Jev's moves

    /// One of Jev's moves as a task step, or nil for moves that aren't
    /// steps (finished, looking up memory).
    static func step(from move: DottieJevDriverPlan.Move, pageTitle: String, requestText: String) -> DottieAppTaskStep? {
        func make(_ kind: DottieAppTaskStep.Kind, label: String, role: String? = nil, at point: (Double, Double)? = nil,
                  text: String? = nil, textMayComeFromRequest: Bool = true, pressesReturn: Bool = false) -> DottieAppTaskStep {
            DottieAppTaskStep(
                kind: kind, label: label, role: role, centerX: point?.0, centerY: point?.1, text: text,
                textCameFromRequest: textMayComeFromRequest && (text.map { textCameFromRequest($0, requestText: requestText) } ?? false),
                pressesReturn: pressesReturn, pageTitle: pageTitle
            )
        }
        switch move {
        case .click(let label, let centerX, let centerY):
            return make(.click, label: label, at: (centerX, centerY))
        case .clickControl(let label, let kind, let centerX, let centerY):
            return make(.click, label: label, role: kind, at: (centerX, centerY))
        case .doubleClick(let label, let centerX, let centerY):
            return make(.doubleClick, label: label, at: (centerX, centerY))
        case .rightClick(let label, let centerX, let centerY):
            return make(.rightClick, label: label, at: (centerX, centerY))
        case .hover(let label, let centerX, let centerY):
            return make(.hover, label: label, at: (centerX, centerY))
        case .typeIntoField(let fieldLabel, let centerX, let centerY, let text, let pressesReturn):
            return make(.typeIntoField, label: fieldLabel, role: "text box", at: (centerX, centerY), text: text, pressesReturn: pressesReturn)
        case .typeText(let text, let pressesReturn):
            return make(.typeText, label: "", text: text, pressesReturn: pressesReturn)
        case .pressKeys(let keys, let meaning):
            return make(.pressKeys, label: keys, text: meaning, textMayComeFromRequest: false)
        case .pressReturn, .scrollDown, .scrollUp, .scrollLeft, .scrollRight, .goBack:
            return plainKind(of: move).map { make($0, label: "") }
        case .openSite(let address):
            return make(.openSite, label: address)
        case .searchWeb(let text):
            return make(.searchWeb, label: text, text: text)
        case .openApp(let name):
            return make(.openApp, label: name)
        case .quickMacAction(let text):
            return make(.quickMacAction, label: text)
        case .clickUnlabeled, .drag, .holdMouseDown, .releaseMouseHere, .releaseMouseOn:
            return make(.jevPicks, label: move.summary)
        case .recallAppMemory, .finishedRound, .finished, .noneFits:
            return nil
        }
    }

    private static func plainKind(of move: DottieJevDriverPlan.Move) -> DottieAppTaskStep.Kind? {
        switch move {
        case .pressReturn: return .pressReturn
        case .scrollDown: return .scrollDown
        case .scrollUp: return .scrollUp
        case .scrollLeft: return .scrollLeft
        case .scrollRight: return .scrollRight
        case .goBack: return .goBack
        default: return nil
        }
    }

    // MARK: Steps from the step model's actions

    /// One of the step model's actions (as kept for instant replays) as a
    /// task step, or nil for actions that aren't steps (waits). Jobs Jev
    /// handed over and Claude finished used to be lost: only Jev's own
    /// finishes became tasks (Wasee, 27 Nov: patients added, no task kept).
    static func step(fromReplayStep replayStep: DottieReplay.Step, requestText: String) -> DottieAppTaskStep? {
        let arguments = replayStep.arguments
        let pageTitle = replayStep.target?.windowTitle ?? ""
        // The words on or beside the control read on screen match the
        // screen's texts next time better than the model's own name for it.
        let targetLabel = [replayStep.target?.title, replayStep.target?.nearbyText, replayStep.target?.descriptionText, replayStep.target?.label]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        func make(_ kind: DottieAppTaskStep.Kind, label: String, text: String? = nil,
                  textMayComeFromRequest: Bool = true, pressesReturn: Bool = false) -> DottieAppTaskStep {
            DottieAppTaskStep(
                kind: kind, label: label, role: nil, centerX: nil, centerY: nil, text: text,
                textCameFromRequest: textMayComeFromRequest && (text.map { textCameFromRequest($0, requestText: requestText) } ?? false),
                pressesReturn: pressesReturn, pageTitle: pageTitle
            )
        }
        switch replayStep.action {
        case "click":
            guard let targetLabel else { return make(.jevPicks, label: replayStep.summary) }
            if arguments["double_click"] == "true" { return make(.doubleClick, label: targetLabel) }
            if arguments["right_click"] == "true" { return make(.rightClick, label: targetLabel) }
            return make(.click, label: targetLabel)
        case "hover":
            guard let targetLabel else { return nil }
            return make(.hover, label: targetLabel)
        case "type_text":
            guard let typedText = arguments["text"], !typedText.isEmpty else { return nil }
            let pressesReturn = arguments["press_enter"] == "true"
            if let targetLabel {
                return make(.typeIntoField, label: targetLabel, text: typedText, pressesReturn: pressesReturn)
            }
            return make(.typeText, label: "", text: typedText, pressesReturn: pressesReturn)
        case "press_keys":
            guard let keys = arguments["keys"], !keys.isEmpty else { return nil }
            if keys.lowercased() == "return" || keys.lowercased() == "enter" { return make(.pressReturn, label: "") }
            return make(.pressKeys, label: keys, text: "a step that worked before", textMayComeFromRequest: false)
        case "scroll":
            switch arguments["direction"] ?? "down" {
            case "up": return make(.scrollUp, label: "")
            case "left": return make(.scrollLeft, label: "")
            case "right": return make(.scrollRight, label: "")
            default: return make(.scrollDown, label: "")
            }
        case "open_url":
            guard let address = arguments["url"], !address.isEmpty else { return nil }
            return make(.openSite, label: address)
        case "open_app":
            guard let appName = arguments["name"], !appName.isEmpty else { return nil }
            return make(.openApp, label: appName)
        default:
            return nil
        }
    }

    /// Whether typed text is the user's own words from the request.
    static func textCameFromRequest(_ text: String, requestText: String) -> Bool {
        let typedWords = DottieAppMemoryPlan.comparableWords(text)
        guard !typedWords.isEmpty else { return false }
        return (" " + DottieAppMemoryPlan.comparableWords(requestText) + " ").contains(" " + typedWords + " ")
    }

    // MARK: Doing a step again

    enum ReplayStep: Equatable {
        case move(DottieJevDriverPlan.Move)
        /// Already the way the step leaves it (the site or app is in front).
        case alreadyDone
        /// Jev takes this one: an icon with no words, or the new request's
        /// words that Dottie can't place.
        case jevTakesIt
        /// What the step needs isn't on the screen.
        case notOnScreen
    }

    /// The move that does a saved step on the screen as it is now.
    static func replayStep(
        _ step: DottieAppTaskStep, recordedForRequest oldRequest: String, newRequest: String,
        screenTexts: [DottieJevDriverPlan.ScreenText], screenControls: [DottieJevDriverPlan.ScreenControl],
        frontSiteHost: String?, frontAppName: String?
    ) -> ReplayStep {
        let candidates = screenControls.map { DottieLooseLabels.Candidate(label: $0.label, role: $0.kind, centerX: $0.centerX, centerY: $0.centerY) }
            + screenTexts.map { DottieLooseLabels.Candidate(label: $0.text, role: nil, centerX: $0.centerX, centerY: $0.centerY) }
        let typedText = textToType(for: step, recordedForRequest: oldRequest, newRequest: newRequest)
        switch step.kind {
        case .click, .doubleClick, .rightClick, .typeIntoField, .hover:
            if step.kind == .typeIntoField && typedText == nil { return .jevTakesIt }
            guard let target = DottieLooseLabels.bestMatch(forLabel: step.label, role: step.role,
                                                           centerX: step.centerX, centerY: step.centerY, among: candidates) else {
                return .notOnScreen
            }
            // A buy, delete or send button is pressed from memory only when
            // this request asks for it too; otherwise Jev decides (and isn't
            // offered it either).
            // Pointing at it presses nothing, so a hover is never risky.
            if step.kind != .hover, DottieJevDriverPlan.isRiskyLabel(target.label, forTask: newRequest) { return .jevTakesIt }
            return .move(targetedMove(step, target: target, typedText: typedText ?? ""))
        case .typeText:
            return typedText.map { ReplayStep.move(.typeText($0, pressesReturn: step.pressesReturn)) } ?? .jevTakesIt
        case .searchWeb:
            return typedText.map { ReplayStep.move(.searchWeb($0)) } ?? .jevTakesIt
        case .openSite:
            let stepHost = DottieJevDriverPlan.host(ofAddress: step.label).map(withoutWWW)
            if let stepHost, let frontSiteHost, stepHost == withoutWWW(frontSiteHost.lowercased()) { return .alreadyDone }
            return .move(.openSite(address: step.label))
        case .openApp:
            if let frontAppName, frontAppName.caseInsensitiveCompare(step.label) == .orderedSame { return .alreadyDone }
            return .move(.openApp(name: step.label))
        case .pressKeys:
            if DottieJevQuickCommands.isRisky(keys: step.label) { return .jevTakesIt }
            return .move(.pressKeys(keys: step.label, meaning: step.text ?? "a saved step"))
        case .quickMacAction:
            return .move(.quickMacAction(step.label))
        case .pressReturn: return .move(.pressReturn)
        case .scrollDown: return .move(.scrollDown)
        case .scrollUp: return .move(.scrollUp)
        case .scrollLeft: return .move(.scrollLeft)
        case .scrollRight: return .move(.scrollRight)
        case .goBack: return .move(.goBack)
        case .jevPicks: return .jevTakesIt
        }
    }

    private static func targetedMove(_ step: DottieAppTaskStep, target: DottieLooseLabels.Candidate, typedText: String) -> DottieJevDriverPlan.Move {
        switch step.kind {
        case .doubleClick:
            return .doubleClick(label: target.label, centerX: target.centerX, centerY: target.centerY)
        case .rightClick:
            return .rightClick(label: target.label, centerX: target.centerX, centerY: target.centerY)
        case .hover:
            return .hover(label: target.label, centerX: target.centerX, centerY: target.centerY)
        case .typeIntoField:
            return .typeIntoField(fieldLabel: target.label, centerX: target.centerX, centerY: target.centerY,
                                  text: typedText, pressesReturn: step.pressesReturn)
        default:
            if let role = target.role {
                return .clickControl(label: target.label, kind: role, centerX: target.centerX, centerY: target.centerY)
            }
            return .click(label: target.label, centerX: target.centerX, centerY: target.centerY)
        }
    }

    private static func withoutWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The text a typing step types this time: its own text, or for the
    /// request's own words, the new request's words in the same place
    /// ("search for cats" then "search for dogs" types "dogs"); nil when
    /// they can't be placed.
    static func textToType(for step: DottieAppTaskStep, recordedForRequest oldRequest: String, newRequest: String) -> String? {
        guard let recordedText = step.text, !recordedText.isEmpty else { return step.text }
        guard step.textCameFromRequest else { return recordedText }
        if let slotText = slotValue(oldRequest: oldRequest, oldText: recordedText, newRequest: newRequest) { return slotText }
        if let sameSpotText = sameSpotWords(oldRequest: oldRequest, oldText: recordedText, newRequest: newRequest) { return sameSpotText }
        return textCameFromRequest(recordedText, requestText: newRequest) ? recordedText : nil
    }

    /// The new request's words in the same places as `oldText`'s words in
    /// the old one, when both have as many words and at least half of them
    /// match. A watched "add a patient named Jane Doe" typed "Jane" and
    /// "Doe" into two boxes; "add a patient named John Smith" types "John"
    /// and "Smith" there (slotValue only handles one gap).
    static func sameSpotWords(oldRequest: String, oldText: String, newRequest: String) -> String? {
        let oldWords = tidiedRequest(oldRequest).split(separator: " ").map { $0.lowercased() }
        let newWords = tidiedRequest(newRequest).split(separator: " ").map(String.init)
        let textWords = tidiedRequest(oldText).split(separator: " ").map { $0.lowercased() }
        guard !textWords.isEmpty, oldWords.count == newWords.count, oldWords.count >= textWords.count else { return nil }
        let matchingWordCount = zip(oldWords, newWords).filter { $0 == $1.lowercased() }.count
        guard matchingWordCount * 2 >= oldWords.count else { return nil }
        for start in 0...(oldWords.count - textWords.count) where Array(oldWords[start..<(start + textWords.count)]) == textWords {
            return newWords[start..<(start + textWords.count)].joined(separator: " ")
        }
        return nil
    }

    /// The part of the new request that sits where `oldText` sat in the old
    /// one, when both read the same around it.
    static func slotValue(oldRequest: String, oldText: String, newRequest: String) -> String? {
        let oldSentence = tidiedRequest(oldRequest).lowercased()
        let newSentenceAsSaid = tidiedRequest(newRequest)
        let newSentence = newSentenceAsSaid.lowercased()
        guard newSentence.count == newSentenceAsSaid.count,
              let oldTextRange = oldSentence.range(of: tidiedRequest(oldText).lowercased()) else { return nil }
        let textBefore = String(oldSentence[..<oldTextRange.lowerBound])
        let textAfter = String(oldSentence[oldTextRange.upperBound...])
        guard newSentence.hasPrefix(textBefore), newSentence.hasSuffix(textAfter),
              newSentence.count > textBefore.count + textAfter.count else { return nil }
        let slotStart = newSentenceAsSaid.index(newSentenceAsSaid.startIndex, offsetBy: textBefore.count)
        let slotEnd = newSentenceAsSaid.index(newSentenceAsSaid.endIndex, offsetBy: -textAfter.count)
        guard slotStart < slotEnd else { return nil }
        let slotText = newSentenceAsSaid[slotStart..<slotEnd].trimmingCharacters(in: .whitespaces)
        return slotText.isEmpty ? nil : slotText
    }

    /// Spaces squeezed and the closing punctuation left off.
    private static func tidiedRequest(_ text: String) -> String {
        let squeezed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return squeezed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?").union(.whitespaces))
    }

    // MARK: Matching a request to a task

    /// How well a task fits a request, 0 to 1: its name and purpose or one
    /// of the requests it was used for.
    static func fitScore(of task: DottieAppTask, forRequest request: String) -> Double {
        let exampleScores = task.exampleRequests.map { DottieTaskMatching.taskSimilarity(request, $0) }
        let nameScore = task.isNamed ? DottieTaskMatching.taskSimilarity(request, task.name + " " + task.purpose) : 0
        return (exampleScores + [nameScore]).max() ?? 0
    }

    /// The task this request is, if Dottie knows it: done in a place the
    /// job is in (or names) and fitting well, or fitting very well anywhere.
    static func bestTask(forRequest request: String, placeKeys: Set<String>, among tasks: [DottieAppTask]) -> DottieAppTask? {
        var best: (task: DottieAppTask, score: Double)?
        for task in tasks {
            let score = fitScore(of: task, forRequest: request)
            let isInTaskPlace = !placeKeys.isDisjoint(with: task.places)
            guard score >= (isInTaskPlace ? fitInSamePlace : fitElsewhere) else { continue }
            if let currentBest = best,
               (currentBest.score, currentBest.task.timesSucceeded) >= (score, task.timesSucceeded) { continue }
            best = (task, score)
        }
        return best?.task
    }

    /// Whether the task's steps are worth doing again: they worked at
    /// least once and haven't failed most of the time lately.
    static func isWorthReplaying(_ task: DottieAppTask) -> Bool {
        guard !task.steps.isEmpty else { return false }
        // Shown by the user while Dottie watched: tried once before it has worked.
        if task.learnedByWatching == true && task.timesRun == 0 { return true }
        guard task.timesSucceeded >= 1 else { return false }
        if task.timesRun >= 3 && Double(task.timesSucceeded) / Double(task.timesRun) < 0.5 { return false }
        return true
    }

    /// The places a request is about: the front one and the sites it names.
    static func placeKeys(frontPlaceKey: String?, requestText: String) -> Set<String> {
        var keys = Set<String>()
        if let frontPlaceKey { keys.insert(frontPlaceKey.lowercased()) }
        for address in DottieJevDriverPlan.siteAddresses(from: requestText) {
            if let host = DottieJevDriverPlan.host(ofAddress: address) { keys.insert(withoutWWW(host)) }
        }
        return keys
    }

    /// A step's place: the site for a browser, else the app.
    static func placeKey(siteHost: String?, bundleIdentifier: String) -> String {
        if let siteHost, !siteHost.isEmpty { return withoutWWW(siteHost.lowercased()) }
        return bundleIdentifier.lowercased()
    }

    // MARK: Counting and problems

    /// The task after Jev finished the job: counts up, the steps that
    /// worked this time kept, and a problem the path hit closed with what
    /// worked instead.
    static func taskAfterSuccess(
        _ existingTask: DottieAppTask?, request: String, recording: DottieAppTaskRecording,
        pathProblem: DottieAppTaskProblem?, now: Date
    ) -> DottieAppTask? {
        let recordedSteps = recording.steps
        let stepsFit = !recordedSteps.isEmpty && recordedSteps.count <= maximumStepsPerTask
        guard var task = existingTask else {
            guard stepsFit else { return nil }
            return DottieAppTask(
                id: UUID(), name: placeholderName(forRequest: request), purpose: "", doneWhen: "", tips: [],
                appName: recording.mainPlaceName ?? "this app", places: recording.places, exampleRequests: [request],
                steps: recordedSteps, stepsRecordedFor: request, finalPageTitle: recording.finalPageTitle,
                timesRun: 1, timesSucceeded: 1, problems: [], createdAt: now, lastUsed: now, isNamed: false
            )
        }
        task.timesRun += 1
        task.timesSucceeded += 1
        task.lastUsed = now
        task.exampleRequests = keptExamples(task.exampleRequests, adding: request)
        task.places = Array(Set(task.places).union(recording.places)).sorted()
        if stepsFit {
            if var pathProblem {
                pathProblem.fix = fixText(recordedSteps: recordedSteps, fromStep: pathProblem.stepNumber)
                task.problems = keptProblems(task.problems, adding: pathProblem)
            }
            task.steps = recordedSteps
            task.stepsRecordedFor = request
            task.finalPageTitle = recording.finalPageTitle ?? task.finalPageTitle
        } else if let pathProblem {
            task.problems = keptProblems(task.problems, adding: pathProblem)
        }
        return task
    }

    /// The task after Jev couldn't finish the job.
    static func taskAfterFailure(_ existingTask: DottieAppTask, request: String, problem: DottieAppTaskProblem?, now: Date) -> DottieAppTask {
        var task = existingTask
        task.timesRun += 1
        task.lastUsed = now
        task.exampleRequests = keptExamples(task.exampleRequests, adding: request)
        if let problem { task.problems = keptProblems(task.problems, adding: problem) }
        return task
    }

    static func keptExamples(_ examples: [String], adding request: String) -> [String] {
        let withoutRequest = examples.filter { $0.caseInsensitiveCompare(request) != .orderedSame }
        return Array((withoutRequest + [request]).suffix(maximumExampleRequests))
    }

    static func keptProblems(_ problems: [DottieAppTaskProblem], adding problem: DottieAppTaskProblem) -> [DottieAppTaskProblem] {
        Array((problems + [problem]).suffix(maximumProblemsKept))
    }

    /// What worked from a problem's step on, for the task's notes.
    static func fixText(recordedSteps: [DottieAppTaskStep], fromStep stepNumber: Int) -> String {
        let firstIndex = max(0, min(stepNumber - 1, recordedSteps.count))
        let lines = recordedSteps[firstIndex...].prefix(4).map(stepLine)
        return lines.isEmpty ? "the job was already done" : lines.joined(separator: ", then ")
    }

    /// Fewer than this many tasks, and tasks this old, go first.
    static func trimmed(_ tasks: [DottieAppTask]) -> [DottieAppTask] {
        guard tasks.count > maximumTasks else { return tasks }
        return Array(tasks.sorted { $0.lastUsed > $1.lastUsed }.prefix(maximumTasks))
    }

    /// A first name from the request's start, until the naming call answers.
    static func placeholderName(forRequest request: String) -> String {
        let words = request.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        guard let firstLetter = words.first else { return "A task" }
        return firstLetter.uppercased() + words.dropFirst()
    }

    // MARK: Texts for the models and the user

    /// One step in words.
    static func stepLine(_ step: DottieAppTaskStep) -> String {
        let typedText = step.text.map { step.textCameFromRequest ? "the request's words (last time \"\($0)\")" : "\"\($0)\"" } ?? "text"
        let returnText = step.pressesReturn ? " and press Return" : ""
        switch step.kind {
        case .click: return "click " + (step.role.map { "the \($0) " } ?? "") + "\"\(step.label)\""
        case .doubleClick: return "double-click \"\(step.label)\""
        case .rightClick: return "right-click \"\(step.label)\""
        case .hover: return "point the mouse at \"\(step.label)\""
        case .typeIntoField: return "type \(typedText) into \"\(step.label)\"\(returnText)"
        case .typeText: return "type \(typedText)\(returnText)"
        case .pressReturn: return "press Return"
        case .pressKeys: return "press \(step.label)" + (step.text.map { " (\($0))" } ?? "")
        case .scrollDown: return "scroll down"
        case .scrollUp: return "scroll up"
        case .scrollLeft: return "scroll left"
        case .scrollRight: return "scroll right"
        case .goBack: return "go back"
        case .openSite: return "open \(step.label)"
        case .searchWeb: return "search the web for \(typedText)"
        case .openApp: return "open the app \(step.label)"
        case .quickMacAction: return "do \"\(step.label)\" on the Mac"
        case .jevPicks: return step.label
        }
    }

    /// What Dottie knows about a task, for Jev, its advisor and the step model.
    static func knowledgeText(for task: DottieAppTask) -> String {
        let purposeText = task.purpose.isEmpty ? "" : " (\(task.purpose))"
        var lines = [task.learnedFromNotes == true && task.timesRun == 0
            ? "The user explained how to do this task in \(task.appName): \"\(task.name)\"\(purposeText)."
            : "Dottie has done this task in \(task.appName) before: \"\(task.name)\"\(purposeText). It worked \(task.timesSucceeded) of \(task.timesRun) times."]
        if !task.steps.isEmpty {
            let shownSteps = task.steps.prefix(15).enumerated().map { "\($0.offset + 1). \(stepLine($0.element))" }
            lines.append("Her steps last time: " + shownSteps.joined(separator: "; "))
        }
        if !task.doneWhen.isEmpty { lines.append("Done when: \(task.doneWhen)") }
        if !task.tips.isEmpty { lines.append("Tips: " + task.tips.joined(separator: "; ")) }
        let recentProblems = task.problems.suffix(3)
        if !recentProblems.isEmpty {
            lines.append("Problems before: " + recentProblems.map { problem in
                "step \(problem.stepNumber) (\(problem.expected)): \(problem.whatHappened)" + (problem.fix.map { "; what worked instead: \($0)" } ?? "")
            }.joined(separator: " | "))
        }
        let text = lines.joined(separator: "\n")
        return text.count > maximumKnowledgeCharacters ? String(text.prefix(maximumKnowledgeCharacters)) + "…" : text
    }

    /// The naming call's prompt.
    static func namingPrompt(appName: String, request: String, steps: [DottieAppTaskStep], finalPageTitle: String?, knownNames: [String]) -> String {
        let stepLines = steps.prefix(20).enumerated().map { "\($0.offset + 1). \(stepLine($0.element))" }
        let knownNamesText = knownNames.isEmpty ? "none yet" : knownNames.prefix(30).joined(separator: "; ")
        return """
        Dottie, a Mac assistant, just finished a job in \(appName) by clicking and typing. Name it as one of the app's own tasks, \
        the way people who use \(appName) say it ("Rename a column", "Create a query", "Export as PDF"), not the user's exact words.
        The user asked: \(request)
        What she did:
        \(stepLines.joined(separator: "\n"))
        It ended on: \(finalPageTitle ?? "unknown")
        Tasks she already knows in \(appName): \(knownNamesText). Use one of those names if this is the same task.
        Answer JSON only: {"name":"3 to 6 words","purpose":"one line: what the task does","done_when":"what the screen shows when it's done",\
        "tips":["up to 2 short tips for doing it again or fixing it when a step isn't there"]}
        """
    }

    struct Naming: Equatable {
        let name: String
        let purpose: String
        let doneWhen: String
        let tips: [String]
    }

    static func naming(fromAnswer answerText: String) -> Naming? {
        guard let object = jsonObject(in: answerText),
              let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let purpose = (object["purpose"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let doneWhen = (object["done_when"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tips = (object["tips"] as? [Any] ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .map { String($0.prefix(160)) }
        return Naming(name: String(name.prefix(60)), purpose: String(purpose.prefix(160)), doneWhen: String(doneWhen.prefix(160)), tips: Array(tips))
    }

    /// The task with the naming call's answer, or merged into a task of the
    /// same name in the same place (the steps that worked last are kept).
    static func tasksAfterNaming(_ tasks: [DottieAppTask], namedTaskID: UUID, naming: Naming) -> [DottieAppTask] {
        guard let namedIndex = tasks.firstIndex(where: { $0.id == namedTaskID }) else { return tasks }
        var namedTask = tasks[namedIndex]
        namedTask.name = naming.name
        namedTask.purpose = naming.purpose
        namedTask.doneWhen = naming.doneWhen
        namedTask.tips = naming.tips
        namedTask.isNamed = true
        var updatedTasks = tasks
        if let sameNameIndex = tasks.firstIndex(where: {
            $0.id != namedTaskID && $0.isNamed && $0.name.caseInsensitiveCompare(naming.name) == .orderedSame
                && !Set($0.places).isDisjoint(with: namedTask.places)
        }) {
            var olderTask = tasks[sameNameIndex]
            olderTask.timesRun += namedTask.timesRun
            olderTask.timesSucceeded += namedTask.timesSucceeded
            for request in namedTask.exampleRequests { olderTask.exampleRequests = keptExamples(olderTask.exampleRequests, adding: request) }
            olderTask.places = Array(Set(olderTask.places).union(namedTask.places)).sorted()
            olderTask.steps = namedTask.steps
            olderTask.stepsRecordedFor = namedTask.stepsRecordedFor
            olderTask.finalPageTitle = namedTask.finalPageTitle
            olderTask.purpose = naming.purpose.isEmpty ? olderTask.purpose : naming.purpose
            olderTask.doneWhen = naming.doneWhen.isEmpty ? olderTask.doneWhen : naming.doneWhen
            olderTask.tips = naming.tips.isEmpty ? olderTask.tips : naming.tips
            olderTask.lastUsed = max(olderTask.lastUsed, namedTask.lastUsed)
            updatedTasks[sameNameIndex] = olderTask
            updatedTasks.remove(at: namedIndex)
            return updatedTasks
        }
        updatedTasks[namedIndex] = namedTask
        return updatedTasks
    }

    /// Whether a place's card should be written (again).
    static func cardIsDue(_ card: DottieAppCard?, taskCountNow: Int, now: Date) -> Bool {
        guard let card else { return taskCountNow >= 1 }
        return now.timeIntervalSince(card.madeAt) > cardRefreshInterval
            || taskCountNow - card.taskCountWhenMade >= newTasksThatRefreshACard
    }

    /// The card call's prompt, from app memory's pages and the known tasks.
    static func cardPrompt(appName: String, memoryLines: [String], tasks: [DottieAppTask], userNotes: String = "") -> String {
        let taskLines = tasks.prefix(15).map { task in
            "- \(task.name)" + (task.purpose.isEmpty ? "" : ": \(task.purpose)") + " (steps: "
                + task.steps.prefix(6).map(stepLine).joined(separator: ", ") + ")"
        }
        return """
        Write a short card on how \(appName) works, for an assistant that uses it by clicking, typing and pressing keys: \
        what it's for, its main pages or areas and how to get to each, and how the tasks below are done. \
        At most 120 words, plain short lines, nothing else.
        What Dottie has seen in \(appName):
        \(memoryLines.prefix(25).joined(separator: "\n"))
        Tasks Dottie knows there:
        \(taskLines.joined(separator: "\n"))
        """ + (userNotes.isEmpty ? "" : "\n\(userNotes)\nKeep what the user said: it's the most reliable part.")
    }

    static func cardKnowledgeText(_ card: DottieAppCard) -> String {
        "How \(card.appName) works (Dottie's card): " + card.text
    }

    private static func jsonObject(in answerText: String) -> [String: Any]? {
        guard let openingBrace = answerText.firstIndex(of: "{"), let closingBrace = answerText.lastIndex(of: "}"),
              openingBrace < closingBrace else { return nil }
        let jsonText = String(answerText[openingBrace...closingBrace])
        return (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any]
    }
}

/// The store: tasks and cards on disk, naming and cards in the background.
@MainActor
final class DottieAppTasks: ObservableObject {
    static let shared = DottieAppTasks()

    /// What Dottie knows for one job, looked up once as it starts.
    struct JobStartKnowledge {
        /// The task this request is, when Dottie knows it.
        let task: DottieAppTask?
        /// The same task when its steps are worth doing again.
        let taskToReplay: DottieAppTask?
        /// The task's notes (steps, done check, problems), for Jev and its advisor.
        let taskText: String
        /// The app's card, for the advisor and the step model.
        let cardText: String

        static let nothing = JobStartKnowledge(task: nil, taskToReplay: nil, taskText: "", cardText: "")

        /// Everything, for the advisor and the step model.
        var fullText: String {
            [cardText, taskText].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// Where a card is written for: the place and how to read app memory about it.
    private struct CardPlace: Sendable {
        let placeKey: String
        let appName: String
        let bundleIdentifier: String?
        let siteHost: String?
    }

    @Published private(set) var tasks: [DottieAppTask] = []
    private var cardsByPlace: [String: DottieAppCard] = [:]
    private let folderURL: URL
    private var taskIDsBeingNamed = Set<UUID>()
    private var placesGettingACard = Set<String>()

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = applicationSupportURL.appendingPathComponent("Dottie/AppTasks", isDirectory: true)
        tasks = DottieFileLoader.load([DottieAppTask].self, from: folderURL.appendingPathComponent("tasks.json")) ?? []
        cardsByPlace = DottieFileLoader.load([String: DottieAppCard].self, from: folderURL.appendingPathComponent("cards.json")) ?? [:]
    }

    /// Named tasks follow app memory's own switch (on unless turned off);
    /// they come from Dottie's own finished jobs and from watch me.
    var isOn: Bool { DottieAppMemory.shared.isSwitchedOn }

    /// The task and card for a job, looked up once as it starts.
    func knowledgeAtJobStart(forTask taskText: String, context: DottieReplayContext) -> JobStartKnowledge {
        guard isOn else { return .nothing }
        // A job asked from Dottie's own window (Home's text box) isn't about
        // Dottie: the app it's for isn't in front yet, so every place Dottie
        // knows counts as this job's place (else a known task needed a
        // near-exact match and was missed).
        let startedFromDottie = context.appBundleIdentifier != nil && context.appBundleIdentifier == Bundle.main.bundleIdentifier
        let frontPlaceKey = startedFromDottie ? nil
            : context.appBundleIdentifier.map { DottieAppTaskPlan.placeKey(siteHost: context.siteHost, bundleIdentifier: $0) }
        var placeKeys = DottieAppTaskPlan.placeKeys(frontPlaceKey: frontPlaceKey, requestText: taskText)
        if startedFromDottie { placeKeys.formUnion(tasks.flatMap(\.places)) }
        let task = DottieAppTaskPlan.bestTask(forRequest: taskText, placeKeys: placeKeys, among: tasks)
        let cardPlaceKey = task?.places.first(where: { placeKeys.contains($0) }) ?? task?.places.first ?? frontPlaceKey
        let savedCardText = cardPlaceKey.flatMap { cardsByPlace[$0] }.map(DottieAppTaskPlan.cardKnowledgeText) ?? ""
        // What the user typed about the place in Home → Admin goes with the card.
        let userNotesText = cardPlaceKey.map { DottieAppNotes.shared.knowledgeText(forPlace: $0) } ?? ""
        let cardText = [savedCardText, userNotesText].filter { !$0.isEmpty }.joined(separator: "\n")
        if task != nil {
            DottieLog.notice("🗂️ This screen job is a task Dottie has done before")
        }
        return JobStartKnowledge(
            task: task,
            taskToReplay: task.flatMap { DottieAppTaskPlan.isWorthReplaying($0) ? $0 : nil },
            taskText: task.map(DottieAppTaskPlan.knowledgeText) ?? "",
            cardText: cardText
        )
    }

    /// A job finished (by Jev, or Claude after Jev handed over), or a
    /// repeated job finished its first round: its task is counted and its newest steps kept
    /// (or a new task made and named in the background), and the place's
    /// card is written when it's due.
    func noteJobFinished(request: String, matchedTaskID: UUID?, recording: DottieAppTaskRecording, pathProblem: DottieAppTaskProblem?) {
        guard isOn else { return }
        let existingTask = matchedTaskID.flatMap { taskID in tasks.first { $0.id == taskID } }
        guard let updatedTask = DottieAppTaskPlan.taskAfterSuccess(existingTask, request: request, recording: recording,
                                                                     pathProblem: pathProblem, now: Date()) else {
            DottieLog.notice("🗂️ A finished job wasn't kept as a task: \(public: recording.steps.count) steps (it keeps 1 to \(public: DottieAppTaskPlan.maximumStepsPerTask))")
            return
        }
        keep(updatedTask)
        DottieLog.notice("🗂️ Kept a finished job as a task (\(public: updatedTask.steps.count) steps, worked \(public: updatedTask.timesSucceeded) of \(public: updatedTask.timesRun) times)")
        let cardPlace = recording.mainPlaceKey.map { placeKey in
            CardPlace(placeKey: placeKey, appName: recording.mainPlaceName ?? updatedTask.appName,
                      bundleIdentifier: recording.bundleIdentifiersByPlace[placeKey],
                      siteHost: placeKey == recording.bundleIdentifiersByPlace[placeKey]?.lowercased() ? nil : placeKey)
        }
        if updatedTask.isNamed {
            if let cardPlace { writeCardIfDue(for: cardPlace) }
        } else {
            name(updatedTask, thenCardFor: cardPlace)
        }
    }

    /// Jev couldn't finish a job it was doing from a saved task.
    func noteJevHandedOver(request: String, replayedTaskID: UUID, problem: DottieAppTaskProblem?) {
        guard isOn, let task = tasks.first(where: { $0.id == replayedTaskID }) else { return }
        keep(DottieAppTaskPlan.taskAfterFailure(task, request: request, problem: problem, now: Date()))
    }

    /// Tasks the user showed while Dottie watched (watch me), already
    /// named by the watcher. Returns how many were kept.
    @discardableResult
    func noteWatchedTasks(_ watchedTasks: [DottieAppTask]) -> Int {
        guard isOn, !watchedTasks.isEmpty else { return 0 }
        tasks = DottieWatchPlan.tasksAfterWatching(tasks, adding: watchedTasks)
        saveTasks()
        DottieLog.notice("🗂️ Kept \(public: watchedTasks.count) task(s) the user showed Dottie")
        return watchedTasks.count
    }

    /// Forgets a place: its tasks (those done only there) and its card.
    func forget(placeKey: String) {
        tasks = DottieAppNotesPlan.tasksAfterForgetting(tasks, placeKey: placeKey)
        cardsByPlace.removeValue(forKey: placeKey.lowercased())
        saveTasks()
        saveCards()
    }

    func forget(taskID: UUID) {
        tasks.removeAll { $0.id == taskID }
        saveTasks()
    }

    private func keep(_ task: DottieAppTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        tasks = DottieAppTaskPlan.trimmed(tasks)
        saveTasks()
    }

    /// One cheap text call names the task the way the app's users would.
    private func name(_ task: DottieAppTask, thenCardFor cardPlace: CardPlace?) {
        guard !taskIDsBeingNamed.contains(task.id) else { return }
        taskIDsBeingNamed.insert(task.id)
        let knownNames = tasks.filter { $0.isNamed && !Set($0.places).isDisjoint(with: task.places) }.map(\.name)
        let prompt = DottieAppTaskPlan.namingPrompt(appName: task.appName, request: task.stepsRecordedFor, steps: task.steps,
                                                    finalPageTitle: task.finalPageTitle, knownNames: knownNames)
        let taskID = task.id
        Task { [weak self] in
            let answerText = await DottieChat.send(DottieAppTasks.textRequestBody(prompt: prompt, maximumOutputTokens: 220), timeout: 30)
            guard let self else { return }
            self.taskIDsBeingNamed.remove(taskID)
            if let answerText, let naming = DottieAppTaskPlan.naming(fromAnswer: answerText) {
                self.tasks = DottieAppTaskPlan.tasksAfterNaming(self.tasks, namedTaskID: taskID, naming: naming)
                self.saveTasks()
                DottieLog.notice("🗂️ Named a task Dottie can do now: \(naming.name)")
            } else {
                DottieLog.notice("🗂️ A finished job couldn't be named this time; it keeps its first name")
            }
            if let cardPlace { self.writeCardIfDue(for: cardPlace) }
        }
    }

    /// One cheap text call writes how the app works, from app memory's pages
    /// and the tasks Dottie knows there; again after 30 days or 3 new tasks.
    private func writeCardIfDue(for cardPlace: CardPlace) {
        let placeTasks = tasks.filter { $0.places.contains(cardPlace.placeKey) }
        guard !placesGettingACard.contains(cardPlace.placeKey),
              DottieAppTaskPlan.cardIsDue(cardsByPlace[cardPlace.placeKey], taskCountNow: placeTasks.count, now: Date()) else { return }
        placesGettingACard.insert(cardPlace.placeKey)
        let memoryLines = cardPlace.bundleIdentifier.map {
            DottieAppMemory.shared.cardMaterial(bundleIdentifier: $0, siteHost: cardPlace.siteHost)
        } ?? []
        let prompt = DottieAppTaskPlan.cardPrompt(appName: cardPlace.appName, memoryLines: memoryLines, tasks: placeTasks,
                                                  userNotes: DottieAppNotes.shared.knowledgeText(forPlace: cardPlace.placeKey))
        let taskCount = placeTasks.count
        Task { [weak self] in
            let answerText = await DottieChat.send(DottieAppTasks.textRequestBody(prompt: prompt, maximumOutputTokens: 260), timeout: 30)
            guard let self else { return }
            self.placesGettingACard.remove(cardPlace.placeKey)
            guard let answerText, !answerText.isEmpty else {
                DottieLog.notice("🗂️ An app's card couldn't be written this time")
                return
            }
            self.cardsByPlace[cardPlace.placeKey] = DottieAppCard(appName: cardPlace.appName, text: String(answerText.prefix(1200)),
                                                                  madeAt: Date(), taskCountWhenMade: taskCount)
            self.saveCards()
            DottieLog.notice("🗂️ Wrote a card on how an app works")
        }
    }

    /// The card for a place, for Home → Admin.
    func card(forPlace placeKey: String) -> DottieAppCard? {
        cardsByPlace[placeKey]
    }

    /// The places that have a card, for Home → Admin.
    var cardPlaceKeys: Set<String> { Set(cardsByPlace.keys) }

    /// The user taught Dottie about a place in Home → Admin: the model's card
    /// replaces the old one and the tasks it named are kept. Kept even with
    /// app memory off, since the user asked for it.
    func noteTaught(placeKey: String, appName: String, card cardText: String, tasks taughtTasks: [DottieAppTask]) {
        if !taughtTasks.isEmpty {
            tasks = DottieAppNotesPlan.tasksAfterTeaching(tasks, adding: taughtTasks)
            saveTasks()
        }
        if !cardText.isEmpty {
            cardsByPlace[placeKey] = DottieAppCard(appName: appName, text: cardText, madeAt: Date(),
                                                   taskCountWhenMade: tasks.filter { $0.places.contains(placeKey) }.count)
            saveCards()
        }
        objectWillChange.send()
    }

    /// A text-only ask; the Worker sends it to the cheap text model first.
    private static func textRequestBody(prompt: String, maximumOutputTokens: Int) -> [String: Any] {
        [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["maxOutputTokens": maximumOutputTokens]
        ]
    }

    private func saveTasks() {
        save(tasks, to: "tasks.json")
    }

    private func saveCards() {
        save(cardsByPlace, to: "cards.json")
    }

    private func save<Value: Encodable>(_ value: Value, to fileName: String) {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        guard let fileData = try? JSONEncoder().encode(value) else { return }
        _ = DottieFileSaver.save(fileData, to: folderURL.appendingPathComponent(fileName))
    }
}
