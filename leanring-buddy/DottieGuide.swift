//
//  DottieGuide.swift
//  leanring-buddy
//
//  Teaching the app on screen, the thing Clicky was made for: "I'm in
//  Premiere, how do I add a sound effect?", "where do I go for effects?",
//  "give me a rundown of everything here". Voice Dottie hands the goal to
//  the guide (guide_user), and the user does the clicking while Dottie
//  shows the way. Off-target clicks end the guide without nagging.
//
//  Two modes:
//  - steps: one step at a time. A screenshot and the goal go to Gemini
//    Flash, which answers with the next single step: a click target (Dottie
//    points at it, circles it, says "click Window up in the menu bar") or a
//    manual step (drag this, type there; the user says "next" when done).
//    A click inside the target means the step is done: wait for the screen
//    to settle, look again, show the next step, until the goal is reached.
//  - tour: one look at the screen, then 4-7 beats, each marking one part of
//    the window while Dottie says what it's for.
//
//  CompanionManager draws the marks, moves the cursor and speaks each step
//  (presentStep), so this file only decides what to show and when.
//

import AppKit
import Foundation

@MainActor
final class DottieGuide {
    enum Mode: String {
        case steps, tour
    }

    struct Mark {
        let shape: DottieScreenAction.DrawingShape
        /// Global AppKit coordinates.
        let rect: CGRect
        let note: String?
    }

    struct Step {
        enum Kind: String {
            /// The user clicks the target; a click there moves on.
            case click
            /// Something to look at or do by hand; "next" moves on.
            case look
            /// The goal is reached.
            case done
        }

        let kind: Kind
        /// What Dottie says, one short instruction.
        let say: String
        let targetRect: CGRect?
        let targetLabel: String?
        let marks: [Mark]
        let displayFrame: CGRect
        /// Tours only: something Dottie does herself to bring the next part
        /// into view (scroll down to the templates, open a tab).
        var reveal: Reveal? = nil
        /// Walkthroughs only: go straight on once it's said, without
        /// waiting for a click or "next" (a tour of Dottie's own app).
        var movesOnWhenSaid = false
        /// The hand motion a person would make to show it: drag this to
        /// there, scroll here, these keys, type this.
        var gesture: Gesture? = nil
        /// 2-6 words shown right at the gesture or target ("drag this → here").
        var caption: String? = nil
    }

    /// What a person sitting next to you would do with their hand.
    struct Gesture {
        enum Kind: String { case drag, scroll, keys, type }
        let kind: Kind
        /// drag: what to grab. scroll, type: the area or field.
        let fromRect: CGRect?
        /// drag: where it goes.
        let toRect: CGRect?
        let direction: DottieScreenAction.ScrollDirection
        /// keys: the shortcut, like "cmd+shift+N".
        let keys: String?
        /// type: what to type.
        let text: String?
    }

    struct Reveal {
        enum Action: String { case scroll, click, keys }
        let action: Action
        /// Global AppKit point to scroll at or click.
        let point: CGPoint?
        let direction: DottieScreenAction.ScrollDirection
        let keys: String?
    }

    private enum StepWaitResult {
        case clickedTarget
        case clickedElsewhere(CGPoint)
        case userSaidNext
        case timedOut
    }

    private static let guideModel = "gemini-3.6-flash"
    private static let maximumRounds = 15
    private static let maximumTourRounds = 6
    private static let maximumTourBeats = 12
    private static let maximumScriptedSteps = 30
    private static let clickWaitTimeoutSeconds: TimeInterval = 120
    private static let lookWaitTimeoutSeconds: TimeInterval = 240
    /// Clicks this close to the target still count.
    private static let targetHitTolerance: CGFloat = 14

    /// Shows a step (marks, cursor, speech). Returns once it has been said.
    var presentStep: (@MainActor (Step) async -> Void)?
    /// The guide ended: clear marks and the notch. `spokenGoodbye` is set
    /// when there's a last thing to say that wasn't a step.
    var onEnd: (@MainActor (_ spokenGoodbye: String?) -> Void)?
    /// Short status for the notch.
    var onProgress: (@MainActor (_ text: String) -> Void)?
    /// The user clicked somewhere other than the step's target: take the
    /// old step's circle and pointer down at once, so the screen doesn't
    /// keep showing a step that's no longer true while the next look runs.
    var onStepTargetMissed: (@MainActor () -> Void)?

    private(set) var currentGoal: String?
    private var guideTask: Task<Void, Never>?
    private var clickMonitor: Any?
    /// Clicks in Dottie's own windows, for walkthroughs of her own app
    /// (global monitors only see clicks in other apps).
    private var ownWindowClickMonitor: Any?
    private var watchesOwnWindows = false
    private var stepWaitContinuation: CheckedContinuation<StepWaitResult, Never>?
    private var activeTargetRect: CGRect?
    /// A drag step's grab and drop places: a press near the first and a
    /// release near the second finishes the step by itself.
    private var activeDragRects: (from: CGRect, to: CGRect)?
    private var dragPressedNearSource = false
    private var dragMonitor: Any?

    var isActive: Bool { guideTask != nil }

    func start(goal: String, mode: Mode) {
        stop()
        currentGoal = goal
        guideTask = Task { [weak self] in
            guard let self else { return }
            let goodbye: String?
            switch mode {
            case .steps: goodbye = await self.runSteps(goal: goal)
            case .tour: goodbye = await self.runTour(goal: goal)
            }
            guard !Task.isCancelled else { return }
            self.finish(spokenGoodbye: goodbye)
        }
    }

    /// A walkthrough of Dottie's own app (DottieSelfKnowledge). The steps
    /// are known ahead, so there's no screenshot and no model call:
    /// `nextStep` opens the right screen, finds the control and returns the
    /// step, or nil when the walkthrough is over.
    func startScripted(goal: String, nextStep: @escaping @MainActor (_ index: Int) async -> Step?) {
        stop()
        currentGoal = goal
        watchesOwnWindows = true
        guideTask = Task { [weak self] in
            guard let self else { return }
            let goodbye = await self.runScripted(nextStep: nextStep)
            guard !Task.isCancelled else { return }
            self.finish(spokenGoodbye: goodbye)
        }
    }

    /// The user said "next" or "done": the current step counts as done.
    @discardableResult
    func userSaidNext() -> Bool {
        guard isActive else { return false }
        resumeStepWait(with: .userSaidNext)
        return true
    }

    /// Ends the guide. Returns true if one was running.
    @discardableResult
    func stop() -> Bool {
        guard let guideTask else { return false }
        guideTask.cancel()
        DottieGuideBrain.shared.stop()
        resumeStepWait(with: .timedOut)
        finish(spokenGoodbye: nil)
        return true
    }

    private func finish(spokenGoodbye: String?) {
        removeClickMonitor()
        activeTargetRect = nil
        guideTask = nil
        currentGoal = nil
        watchesOwnWindows = false
        onEnd?(spokenGoodbye)
    }

    // MARK: - Steps mode

    private func runSteps(goal: String) async -> String? {
        var history: [String] = []
        var consecutiveClicksElsewhere = 0
        // "how do I add an event in Calendar" while System Settings covers
        // Calendar: guiding from that screenshot pointed at other apps'
        // buttons. Bring the app the goal names to the front first.
        if let namedAppName = await Self.bringAppNamedInGoalToFront(goal) {
            print("🧑‍🏫 Guide: brought \(namedAppName) to the front")
        }
        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // How this app really does it, from the web, looked up while the
        // first screenshot is taken. Guessing from one screenshot is how
        // Dottie sent the user to an audio button CapCut doesn't have.
        let howToLookup = Task { await Self.lookUpHowTo(goal: goal, appName: frontmostAppName) }

        for round in 1...Self.maximumRounds {
            if Task.isCancelled { return nil }
            onProgress?(round == 1 ? "looking at your screen" : "checking what changed")

            guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1440) else {
                return "I can't see your screen. I need Screen Recording permission for that."
            }
            let remainingRounds = Self.maximumRounds - round
            let howToText = await howToLookup.value
            guard let step = await requestVerifiedStep(
                goal: goal,
                history: history,
                remainingRounds: remainingRounds,
                screen: screen,
                howToText: howToText
            ) else {
                if Task.isCancelled { return nil }
                return "Claude and Gemini are both too busy to guide right now. Try me again in a sec."
            }
            if Task.isCancelled { return nil }

            onProgress?("step \(round): \(step.say)")
            await presentStep?(step)
            if Task.isCancelled { return nil }

            switch step.kind {
            case .done:
                return nil

            case .click:
                guard let targetRect = step.targetRect else {
                    history.append("Step \(round): \(step.say) (shown, no target)")
                    continue
                }
                let waitResult = await waitForStepCompletion(targetRect: targetRect, timeout: Self.clickWaitTimeoutSeconds)
                switch waitResult {
                case .clickedTarget, .userSaidNext:
                    consecutiveClicksElsewhere = 0
                    history.append("Step \(round): \"\(step.say)\" (target: \(step.targetLabel ?? "it")). The user clicked it.")
                case .clickedElsewhere:
                    consecutiveClicksElsewhere += 1
                    onStepTargetMissed?()
                    // Clicky ends the guide here so it never nags; give one
                    // more look in case they did it another way.
                    if consecutiveClicksElsewhere >= 2 { return nil }
                    onProgress?("you clicked something else, checking what changed")
                    history.append("Step \(round): \"\(step.say)\" (target: \(step.targetLabel ?? "it")). The user clicked somewhere else instead; they may have done it another way or gotten lost.")
                case .timedOut:
                    return nil
                }

            case .look:
                if let gesture = step.gesture, gesture.kind == .drag, let fromRect = gesture.fromRect, let toRect = gesture.toRect {
                    activeDragRects = (from: fromRect, to: toRect)
                }
                let waitResult = await waitForStepCompletion(targetRect: nil, timeout: Self.lookWaitTimeoutSeconds)
                activeDragRects = nil
                switch waitResult {
                case .clickedTarget where step.gesture?.kind == .drag:
                    history.append("Step \(round): \"\(step.say)\". The user dragged it there.")
                case .clickedTarget, .userSaidNext, .clickedElsewhere:
                    history.append("Step \(round): \"\(step.say)\". The user says they did it.")
                case .timedOut:
                    return nil
                }
            }

            if Task.isCancelled { return nil }
            // Let menus open and pages load before looking again.
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        return "That's as far as I can take you for now."
    }

    /// Finds an app named in the goal ("add an event in calendar", "where's
    /// the export button in final cut pro"), running first, then installed,
    /// and brings it to the front unless it already is. Returns its name, or
    /// nil when the goal names no app or it was already in front.
    private static func bringAppNamedInGoalToFront(_ goal: String) async -> String? {
        let goalWords = DottieInstalledApps.comparableName(goal).split(separator: " ").map(String.init)
        guard !goalWords.isEmpty else { return nil }
        // Longest names first, so "final cut pro" wins over "final".
        for wordCount in stride(from: min(4, goalWords.count), through: 1, by: -1) {
            for startIndex in 0...(goalWords.count - wordCount) {
                let candidateName = goalWords[startIndex..<(startIndex + wordCount)].joined(separator: " ")
                // Everyday words that are also app names would grab the
                // wrong app ("how do I add a note" isn't about Notes when
                // the user is in Bear).
                // "in notes" or "on photos" still names the app.
                let previousWord = startIndex > 0 ? goalWords[startIndex - 1] : ""
                let isIntroducedAsAnApp = ["in", "on", "inside", "using", "open", "with"].contains(previousWord)
                if wordCount == 1 && !isIntroducedAsAnApp && Self.wordsTooCommonToMeanAnApp.contains(candidateName) { continue }
                if candidateName == "dottie" || candidateName == "a" || candidateName == "i" { continue }
                if let runningApp = DottieInstalledApps.shared.runningApp(matchingSpokenName: candidateName) {
                    if runningApp.isActive { return nil }
                    runningApp.unhide()
                    runningApp.activate(options: [.activateAllWindows])
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    return runningApp.localizedName
                }
                if let installedApp = DottieInstalledApps.shared.installedApp(matchingSpokenName: candidateName),
                   await DottieScreenTaskRunner.openApplication(named: installedApp.name) {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    return installedApp.name
                }
            }
        }
        return nil
    }

    private static let wordsTooCommonToMeanAnApp: Set<String> = [
        "notes", "note", "music", "photos", "photo", "mail", "messages", "message", "maps", "map", "news",
        "books", "home", "clock", "weather", "calculator", "preview", "contacts", "reminders", "shortcuts",
        "code", "settings", "preferences", "word", "teams", "games", "stocks", "podcasts", "tv", "freeform",
        "chess", "keynote", "pages", "numbers", "dictionary", "font", "voice", "terminal", "console", "a", "i"
    ]

    /// The web's how-to for this app (its own help pages first), as text
    /// for the step prompt, or nil when the search fails or takes too long.
    private static let howToLookupTimeoutSeconds: UInt64 = 8
    private static func lookUpHowTo(goal: String, appName: String) async -> String? {
        let query = appName.isEmpty ? "how to \(goal)" : "\(appName) how to \(goal) help"
        let searchTask = Task { await DottieWebSearch.search(query) }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: howToLookupTimeoutSeconds * 1_000_000_000)
            searchTask.cancel()
        }
        let searchText = await searchTask.value
        timeoutTask.cancel()
        // Failures come back as an instruction for the voice, not results.
        guard searchText.hasPrefix("web results") else { return nil }
        return String(searchText.prefix(3500))
    }

    /// The next step, with its click target checked against the screen
    /// (Accessibility, then on-screen text, then a sharper look) and moved
    /// onto the real control. A target that can't be found anywhere gets
    /// one more ask, telling Gemini it pointed at something that isn't
    /// there, so a made-up button is never shown.
    private func requestVerifiedStep(
        goal: String,
        history: [String],
        remainingRounds: Int,
        screen: DottieDisplayCapture.Screenshot,
        howToText: String?
    ) async -> Step? {
        var historyForThisStep = history
        for attempt in 1...2 {
            guard var step = await requestSteps(
                goal: goal,
                mode: .steps,
                history: historyForThisStep,
                remainingRounds: remainingRounds,
                screen: screen,
                howToText: howToText
            )?.first else { return nil }
            guard step.kind == .click, let targetRect = step.targetRect, let targetLabel = step.targetLabel else {
                return step
            }
            let foundFrame = await PointingRefiner.refineFrame(
                elementLabel: targetLabel,
                userQuestion: goal,
                roughPoint: CGPoint(x: targetRect.midX, y: targetRect.midY),
                displayFrame: screen.displayFrame
            )
            if let foundFrame, screen.displayFrame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: foundFrame.midX, y: foundFrame.midY)) {
                // How far the model's own box was from the real control, so
                // drift can be read in the log.
                print("🧑‍🏫 Guide target \"\(targetLabel)\": model \(Int(targetRect.midX)),\(Int(targetRect.midY)) → found \(Int(foundFrame.midX)),\(Int(foundFrame.midY)) (\(Int(hypot(foundFrame.midX - targetRect.midX, foundFrame.midY - targetRect.midY))) points)")
                step = Step(
                    kind: step.kind,
                    say: step.say,
                    targetRect: foundFrame,
                    targetLabel: step.targetLabel,
                    marks: step.marks,
                    displayFrame: step.displayFrame,
                    reveal: step.reveal
                )
                return step
            }
            print("🧑‍🏫 Guide target \"\(targetLabel)\" isn't on screen (attempt \(attempt))")
            if attempt == 2 {
                // Still nothing there: say it without pointing at a spot
                // that may be wrong.
                return Step(kind: .look, say: step.say, targetRect: nil, targetLabel: nil, marks: [], displayFrame: step.displayFrame)
            }
            historyForThisStep.append("Your last answer pointed at \"\(targetLabel)\", but nothing with that name is on this screen. Don't point at it again unless you can read it on the screenshot. Point at what's really there that leads to it (per the how-to), or say honestly that you're not sure where it is in their version.")
        }
        return nil
    }

    // MARK: - Scripted walkthroughs

    private func runScripted(nextStep: @MainActor (_ index: Int) async -> Step?) async -> String? {
        var consecutiveClicksElsewhere = 0
        for index in 0..<Self.maximumScriptedSteps {
            if Task.isCancelled { return nil }
            guard let step = await nextStep(index) else { return nil }
            if Task.isCancelled { return nil }
            onProgress?("step \(index + 1): \(step.say)")
            await presentStep?(step)
            if Task.isCancelled { return nil }
            if step.kind == .done { return nil }
            if step.movesOnWhenSaid {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let targetRect = step.kind == .click ? step.targetRect : nil
            let waitResult = await waitForStepCompletion(
                targetRect: targetRect,
                timeout: targetRect == nil ? Self.lookWaitTimeoutSeconds : Self.clickWaitTimeoutSeconds
            )
            switch waitResult {
            case .clickedTarget, .userSaidNext:
                consecutiveClicksElsewhere = 0
            case .clickedElsewhere:
                // Same as steps mode: never nag; two misses in a row end it.
                consecutiveClicksElsewhere += 1
                if consecutiveClicksElsewhere >= 2 { return nil }
            case .timedOut:
                return nil
            }
            // Let the screen change (a page opens, a field appears).
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    // MARK: - Tour mode

    /// Looks, shows a few parts, and when the next part is off screen or
    /// behind a tab, scrolls or clicks to it herself and looks again.
    private func runTour(goal: String) async -> String? {
        var history: [String] = []
        var shownBeatCount = 0
        for round in 1...Self.maximumTourRounds {
            if Task.isCancelled { return nil }
            onProgress?(round == 1 ? "looking around" : "looking again")
            guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1440) else {
                return "I can't see your screen. I need Screen Recording permission for that."
            }
            let beatsLeft = Self.maximumTourBeats - shownBeatCount
            guard let beats = await requestSteps(goal: goal, mode: .tour, history: history, remainingRounds: beatsLeft, screen: screen),
                  !beats.isEmpty else {
                if Task.isCancelled { return nil }
                return round == 1 ? "Claude and Gemini are both too busy for a tour right now. Try me again in a sec." : nil
            }
            var didReveal = false
            for beat in beats {
                if Task.isCancelled { return nil }
                shownBeatCount += 1
                onProgress?("\(shownBeatCount): \(beat.say)")
                await presentStep?(beat)
                if Task.isCancelled { return nil }
                if let reveal = beat.reveal {
                    await perform(reveal)
                    history.append("\(beat.say) (you \(reveal.action == .scroll ? "scrolled \(reveal.direction.rawValue)" : reveal.action == .click ? "clicked to open it" : "pressed \(reveal.keys ?? "keys")"), so the screen changed)")
                    didReveal = true
                    // Everything after a reveal was planned on the old screen.
                    break
                }
                history.append(beat.say)
                if beat.kind == .done || shownBeatCount >= Self.maximumTourBeats { return nil }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if !didReveal { return nil }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        return nil
    }

    private func perform(_ reveal: Reveal) async {
        switch reveal.action {
        case .scroll:
            DottieScreenActionPerformer.scroll(direction: reveal.direction, amount: 5, at: reveal.point)
        case .click:
            guard let point = reveal.point else { return }
            DottieScreenActionPerformer.click(at: point, clickCount: 1, isRightClick: false)
        case .keys:
            if let keys = reveal.keys { _ = DottieScreenActionPerformer.press(keyCombination: keys) }
        }
    }

    // MARK: - Waiting for the user

    private func waitForStepCompletion(targetRect: CGRect?, timeout: TimeInterval) async -> StepWaitResult {
        activeTargetRect = targetRect
        installClickMonitor()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resumeStepWait(with: .timedOut)
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<StepWaitResult, Never>) in
            if Task.isCancelled {
                continuation.resume(returning: .timedOut)
            } else {
                stepWaitContinuation = continuation
            }
        }
        timeoutTask.cancel()
        removeClickMonitor()
        activeTargetRect = nil
        return result
    }

    private func resumeStepWait(with result: StepWaitResult) {
        guard let continuation = stepWaitContinuation else { return }
        stepWaitContinuation = nil
        continuation.resume(returning: result)
    }

    /// Watches the user's clicks in other apps (no special permission
    /// needed for mouse clicks).
    private func installClickMonitor() {
        removeClickMonitor()
        if activeDragRects != nil {
            dragPressedNearSource = false
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                let mouseLocation = NSEvent.mouseLocation
                let isPress = event.type == .leftMouseDown
                Task { @MainActor [weak self] in
                    self?.handleDragEvent(isPress: isPress, at: mouseLocation)
                }
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleUserClick(at: clickLocation)
            }
        }
        if watchesOwnWindows {
            ownWindowClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // The notch and other panels aren't part of the walkthrough.
                if !(event.window is NSPanel) {
                    let clickLocation = NSEvent.mouseLocation
                    Task { @MainActor [weak self] in
                        self?.handleUserClick(at: clickLocation)
                    }
                }
                return event
            }
        }
    }

    private func handleDragEvent(isPress: Bool, at mouseLocation: CGPoint) {
        guard stepWaitContinuation != nil, let activeDragRects else { return }
        let tolerance: CGFloat = 40
        if isPress {
            dragPressedNearSource = activeDragRects.from.insetBy(dx: -tolerance, dy: -tolerance).contains(mouseLocation)
        } else if dragPressedNearSource {
            dragPressedNearSource = false
            if activeDragRects.to.insetBy(dx: -tolerance * 2, dy: -tolerance * 2).contains(mouseLocation) {
                resumeStepWait(with: .clickedTarget)
            }
        }
    }

    private func removeClickMonitor() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
        }
        dragMonitor = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        if let ownWindowClickMonitor {
            NSEvent.removeMonitor(ownWindowClickMonitor)
        }
        ownWindowClickMonitor = nil
    }

    private func handleUserClick(at clickLocation: CGPoint) {
        guard stepWaitContinuation != nil else { return }
        guard let activeTargetRect else {
            // A "look" step: clicking around is part of doing it.
            return
        }
        let hitRect = activeTargetRect.insetBy(dx: -Self.targetHitTolerance, dy: -Self.targetHitTolerance)
        resumeStepWait(with: hitRect.contains(clickLocation) ? .clickedTarget : .clickedElsewhere(clickLocation))
    }

    // MARK: - Gemini

    private static let systemInstruction = """
    You are Dottie, a friendly guide sitting next to the user, teaching them the app on their screen. You see a screenshot of their screen. The user does the clicking; you show the way. Reply only with JSON.

    Coordinates: every box is box_2d = [ymin, xmin, ymax, xmax] on the screenshot, each 0-1000, drawn tightly around the thing itself (not its whole row or panel unless that's what you mean).

    "say" is spoken out loud: one short, plain sentence (at most about 15 words), friendly, no coordinates, no lists. Name things by their visible text and where they are ("Click Window, up in the menu bar.").

    Marks are drawn on the screen: circle (a small control or word), box (a group of controls), underline (text), arrow (point toward something), highlight (a whole area or panel). Use one or two marks per step, never more than three.

    Show it the way a person next to them would with their hand. Whenever the step is more than one click, add a gesture: drag (from_box on the thing to grab, to_box exactly where to drop it: Dottie's hand moves it there over and over), scroll (box_2d on the area to scroll, direction), keys (the shortcut, like cmd+shift+N: the keys are drawn on screen), type (box_2d on the field, text to type: shown beside it). Give every step a caption: 2-6 words shown right at the hand, like "drag this → here", "click File", "scroll down", "press ⌘S", "type your name".
    """

    private static func instruction(goal: String, mode: Mode, history: [String], remainingRounds: Int, frontmostApp: String, howToText: String?) -> String {
        let appLessons = DottieAppLessons.shared.lessons(forApp: frontmostApp)
        let appLessonsText = appLessons.isEmpty ? "" : "\nThe user has corrected you about \(frontmostApp) before; these are right, follow them over anything else:\n" + appLessons.map { "- \($0)" }.joined(separator: "\n") + "\n"
        switch mode {
        case .steps:
            let historyText = history.isEmpty ? "Nothing yet; this is the first step." : history.joined(separator: "\n")
            let howToSection = howToText.map { "\nHow this is done, from the web (may be for another version; the screenshot wins where they differ):\n\($0)\n" } ?? ""
            return """
            Frontmost app: \(frontmostApp).
            What the user wants: \(goal)
            \(appLessonsText)\(howToSection)

            What has happened in this guide so far, oldest first:
            \(historyText)

            Look at this new screenshot as the truth. Give exactly ONE next step toward the goal, as {"steps": [step]}.
            - kind "click": the next action is a single click on something visible now (a menu, menu item, tab, button, panel). Set target_box tightly on it and target_label to its visible text. "say" names only that one click.
            - kind "look": the next action is manual work (dragging a clip, typing a name, moving a slider, scrolling, a keyboard shortcut, choosing by taste), or something to notice. Show it with a gesture (a drag gets from_box and to_box; Dottie notices when they've dragged it there) and say what to do; for anything but a drag, end with "say next when you're done".
            - kind "done": the goal is reached or already visible; "say" is a short, warm wrap-up of how they got there.
            Never make up a control. Only target something you can actually read or clearly recognize on this screenshot, and set target_label to its exact visible text (or its tooltip name for an icon). Follow the app's real way of doing it, from the corrections and how-to above, not a guess about what apps usually have. If what's needed isn't visible, guide them to reveal it the way this app does it (select the clip first, a panel tab, a menu in the menu bar, a right-click menu, a scroll). If you don't know where it is in their version, say so honestly in a "look" step and suggest where to look, instead of pointing somewhere. Treat steps in the history as done unless the screen clearly shows they failed; never repeat the same target. If a menu you pointed at is now open, the next target is inside it. If the screen shows a different app than the goal needs, guide them back to it.
            \(remainingRounds == 0 ? "This is the last step you can give: use kind 'done' and tell them what's left in one sentence." : "")
            """
        case .tour:
            let historyText = history.isEmpty ? "Nothing yet; this is the start." : history.joined(separator: "\n")
            return """
            Frontmost app: \(frontmostApp).
            What the user wants: \(goal)
            \(appLessonsText)
            Already shown in this tour, oldest first:
            \(historyText)

            Continue the tour from this screenshot, as {"steps": [1 to 6 steps]}, in a natural order (top to bottom, left to right, or most important first). Don't repeat anything already shown. Each "look" step marks ONE main part of the window (highlight for big areas, circle for a single control) and says what it is and what they'd use it for, in one short sentence. If the user asked about something specific, focus on that.
            You can operate the app to show things: when the next part worth showing is cut off or not visible (more content below, like a list of templates; inside another tab, section or menu), give a step with a reveal instead of marks: reveal.action "scroll" with direction and box_2d on the area to scroll, "click" with box_2d on the tab, section, menu or disclosure arrow to open, or "keys". Its "say" tells them what you're doing ("let's scroll down to the templates"). A reveal step must be the LAST step you give: you'll get a fresh screenshot after it. Only click things that show or navigate (tabs, menus, sections, expand arrows), never ones that create, change, buy, send or delete.
            You have \(remainingRounds) steps left. When everything worth seeing is covered, end with a short, friendly wrap-up step of kind "done".
            """
        }
    }

    private static var responseSchema: [String: Any] {
        let boxSchema: [String: Any] = ["type": "ARRAY", "items": ["type": "INTEGER"]]
        let markSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "shape": ["type": "STRING", "enum": DottieScreenAction.DrawingShape.allCases.map(\.rawValue)],
                "box_2d": boxSchema,
                "note": ["type": "STRING", "description": "Optional 1-3 word label written by the mark."]
            ],
            "required": ["shape", "box_2d"]
        ]
        let stepSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "kind": ["type": "STRING", "enum": ["click", "look", "done"]],
                "say": ["type": "STRING"],
                "target_box": boxSchema,
                "target_label": ["type": "STRING"],
                "marks": ["type": "ARRAY", "items": markSchema],
                "caption": ["type": "STRING", "description": "2-6 words shown at the hand, like \"drag this → here\"."],
                "gesture": [
                    "type": "OBJECT",
                    "properties": [
                        "kind": ["type": "STRING", "enum": ["drag", "scroll", "keys", "type"]],
                        "from_box": boxSchema,
                        "to_box": boxSchema,
                        "box_2d": boxSchema,
                        "direction": ["type": "STRING", "enum": ["up", "down", "left", "right"]],
                        "keys": ["type": "STRING"],
                        "text": ["type": "STRING"]
                    ],
                    "required": ["kind"]
                ],
                "reveal": [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["scroll", "click", "keys"]],
                        "box_2d": boxSchema,
                        "direction": ["type": "STRING", "enum": ["up", "down", "left", "right"]],
                        "keys": ["type": "STRING"]
                    ],
                    "required": ["action"]
                ]
            ],
            "required": ["kind", "say"]
        ]
        return [
            "type": "OBJECT",
            "properties": ["steps": ["type": "ARRAY", "items": stepSchema]],
            "required": ["steps"]
        ]
    }

    private func requestSteps(
        goal: String,
        mode: Mode,
        history: [String],
        remainingRounds: Int,
        screen: DottieDisplayCapture.Screenshot,
        howToText: String? = nil
    ) async -> [Step]? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let stepInstruction = Self.instruction(goal: goal, mode: mode, history: history, remainingRounds: remainingRounds, frontmostApp: frontmostApp, howToText: howToText)
        // Claude Sonnet first (the user's Claude plan); Gemini when it
        // isn't there or is too slow.
        if let claudeAnswer = await DottieGuideBrain.shared.askClaude(
            systemInstruction: Self.systemInstruction,
            stepInstruction: stepInstruction,
            screenshotJPEG: screen.jpegData,
            screenshotPixelSize: CGSize(width: screen.image.width, height: screen.image.height)
        ), let steps = Self.parseSteps(from: claudeAnswer, screen: screen), !steps.isEmpty {
            return steps
        }
        if Task.isCancelled { return nil }
        let requestBody: [String: Any] = [
            // Groq first when Claude isn't there (the Worker asks it for
            // pixels and hands back box_2d); Gemini when Groq can't answer.
            "provider": "groq",
            "model": DottieModelPicker.shared.pick(.normal),
            "systemInstruction": ["parts": [["text": Self.systemInstruction]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": screen.jpegData.base64EncodedString()]],
                    ["text": stepInstruction]
                ]
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": Self.responseSchema
            ]
        ]

        // One retry: the free tier is sometimes busy for a moment.
        for attempt in 1...2 {
            if Task.isCancelled { return nil }
            if let answerText = await Self.postToChat(requestBody),
               let steps = Self.parseSteps(from: answerText, screen: screen), !steps.isEmpty {
                return steps
            }
            if attempt == 1 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        return nil
    }

    private static func postToChat(_ requestBody: [String: Any]) async -> String? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        guard let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        request.httpBody = requestBodyData

        let model = requestBody["model"] as? String ?? Self.guideModel
        guard let (responseData, response) = try? await DottieModelPicker.shared.data(for: request, model: model) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            print("⚠️ Guide request failed: \(String(decoding: responseData.prefix(300), as: UTF8.self))")
            return nil
        }
        // /chat streams server-sent events.
        let answerText = GeminiServerSentEvents.text(from: responseData)
        return answerText
    }

    private static func parseSteps(from answerText: String, screen: DottieDisplayCapture.Screenshot) -> [Step]? {
        // Tolerate a code fence or stray text around the JSON.
        guard let jsonStart = answerText.firstIndex(of: "{"), let jsonEnd = answerText.lastIndex(of: "}"),
              let answerData = String(answerText[jsonStart...jsonEnd]).data(using: .utf8),
              let answer = try? JSONSerialization.jsonObject(with: answerData) as? [String: Any],
              let rawSteps = answer["steps"] as? [[String: Any]] else { return nil }

        return rawSteps.compactMap { (rawStep: [String: Any]) -> Step? in
            let say = (rawStep["say"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !say.isEmpty else { return nil }
            var kind = Step.Kind(rawValue: (rawStep["kind"] as? String) ?? "look") ?? .look
            let targetRect = (rawStep["target_box"] as? [Any]).flatMap { globalRect(fromBox: $0, screen: screen) }
            if kind == .click && targetRect == nil {
                kind = .look
            }
            let marks: [Mark] = ((rawStep["marks"] as? [[String: Any]]) ?? []).prefix(3).compactMap { (rawMark: [String: Any]) -> Mark? in
                guard let shape = (rawMark["shape"] as? String).flatMap({ DottieScreenAction.DrawingShape(rawValue: $0.lowercased()) }),
                      let modelRect = (rawMark["box_2d"] as? [Any]).flatMap({ globalRect(fromBox: $0, screen: screen) }) else { return nil }
                // A drawing around one control (a button, tab or menu item)
                // goes around that control's real outline, not the model's
                // estimate. Bigger boxes mean an area, so they stay as given.
                let isAboutOneControl = modelRect.width <= 320 && modelRect.height <= 120
                let rect = isAboutOneControl ? AccessibilitySnap.refinedFrame(modelRect) : modelRect
                let note = (rawMark["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Mark(shape: shape, rect: rect, note: note?.isEmpty == false ? note : nil)
            }
            let targetLabel = (rawStep["target_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawReveal = rawStep["reveal"] as? [String: Any]
            let reveal = rawReveal.flatMap { parseReveal($0, screen: screen) }
            // A click reveal: point and circle where Dottie is about to click.
            var revealRect: CGRect?
            if reveal?.action == .click, let revealBox = rawReveal?["box_2d"] as? [Any] {
                revealRect = globalRect(fromBox: revealBox, screen: screen)
            }
            let gesture = (rawStep["gesture"] as? [String: Any]).flatMap { parseGesture($0, screen: screen) }
            if gesture?.kind == .drag && kind == .click {
                // A drag is never a single click.
                kind = .look
            }
            let caption = (rawStep["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Step(
                kind: reveal == nil ? kind : .look,
                say: say,
                targetRect: targetRect ?? revealRect,
                targetLabel: targetLabel?.isEmpty == false ? targetLabel : nil,
                marks: reveal == nil ? marks : [],
                displayFrame: screen.displayFrame,
                reveal: reveal,
                gesture: reveal == nil ? gesture : nil,
                caption: caption?.isEmpty == false ? String(caption!.prefix(48)) : nil
            )
        }
    }

    private static func parseGesture(_ rawGesture: [String: Any], screen: DottieDisplayCapture.Screenshot) -> Gesture? {
        guard let kind = (rawGesture["kind"] as? String).flatMap({ Gesture.Kind(rawValue: $0.lowercased()) }) else { return nil }
        func rect(_ key: String) -> CGRect? {
            guard let modelRect = (rawGesture[key] as? [Any]).flatMap({ globalRect(fromBox: $0, screen: screen) }) else { return nil }
            let isAboutOneControl = modelRect.width <= 320 && modelRect.height <= 120
            return isAboutOneControl ? AccessibilitySnap.refinedFrame(modelRect) : modelRect
        }
        let fromRect = rect("from_box") ?? rect("box_2d")
        let toRect = rect("to_box")
        let direction = (rawGesture["direction"] as? String).flatMap { DottieScreenAction.ScrollDirection(rawValue: $0.lowercased()) } ?? .down
        let keys = (rawGesture["keys"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (rawGesture["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .drag where fromRect == nil || toRect == nil: return nil
        case .scroll where fromRect == nil: return nil
        case .keys where keys?.isEmpty != false: return nil
        case .type where text?.isEmpty != false: return nil
        default: return Gesture(kind: kind, fromRect: fromRect, toRect: toRect, direction: direction, keys: keys, text: text)
        }
    }

    private static func parseReveal(_ rawReveal: [String: Any], screen: DottieDisplayCapture.Screenshot) -> Reveal? {
        guard let action = (rawReveal["action"] as? String).flatMap({ Reveal.Action(rawValue: $0.lowercased()) }) else { return nil }
        let rect = (rawReveal["box_2d"] as? [Any]).flatMap { globalRect(fromBox: $0, screen: screen) }
        let point = rect.map { CGPoint(x: $0.midX, y: $0.midY) }
        let direction = (rawReveal["direction"] as? String).flatMap { DottieScreenAction.ScrollDirection(rawValue: $0.lowercased()) } ?? .down
        let keys = (rawReveal["keys"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .click where point == nil: return nil
        case .keys where keys?.isEmpty != false: return nil
        default: return Reveal(action: action, point: point, direction: direction, keys: keys)
        }
    }

    /// [ymin, xmin, ymax, xmax] in 0-1000 on the screenshot, to a global
    /// AppKit rect.
    private static func globalRect(fromBox box: [Any], screen: DottieDisplayCapture.Screenshot) -> CGRect? {
        let numbers = box.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard numbers.count == 4 else { return nil }
        let (ymin, xmin, ymax, xmax) = (numbers[0], numbers[1], numbers[2], numbers[3])
        guard ymax >= ymin, xmax >= xmin else { return nil }
        let topLeft = screen.globalPoint(normalizedX: xmin, normalizedY: ymin)
        let bottomRight = screen.globalPoint(normalizedX: xmax, normalizedY: ymax)
        return CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
    }
}
