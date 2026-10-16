//
//  DottieGuide.swift
//  leanring-buddy
//
//  Teaching the app on screen, the thing Clicky was made for: "I'm in
//  Premiere, how do I add a sound effect?", "where do I go for effects?",
//  "give me a rundown of everything here". Voice Dottie hands the goal to
//  the guide (guide_user), and the user does the clicking while Dottie
//  shows the way. Modeled on shipped Clicky's guided walkthrough
//  (CompanionManager+Annotation: [TARGET]/[HIGHLIGHT]/[SHAPE] beats, "Guided
//  target hit", "Guided follow-up: screen settled", off-target clicks end
//  the guide without nagging).
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
    }

    private enum StepWaitResult {
        case clickedTarget
        case clickedElsewhere(CGPoint)
        case userSaidNext
        case timedOut
    }

    private static let guideModel = "gemini-3.6-flash"
    private static let maximumRounds = 15
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

    private(set) var currentGoal: String?
    private var guideTask: Task<Void, Never>?
    private var clickMonitor: Any?
    private var stepWaitContinuation: CheckedContinuation<StepWaitResult, Never>?
    private var activeTargetRect: CGRect?

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
        resumeStepWait(with: .timedOut)
        finish(spokenGoodbye: nil)
        return true
    }

    private func finish(spokenGoodbye: String?) {
        removeClickMonitor()
        activeTargetRect = nil
        guideTask = nil
        currentGoal = nil
        onEnd?(spokenGoodbye)
    }

    // MARK: - Steps mode

    private func runSteps(goal: String) async -> String? {
        var history: [String] = []
        var consecutiveClicksElsewhere = 0

        for round in 1...Self.maximumRounds {
            if Task.isCancelled { return nil }
            onProgress?(round == 1 ? "looking at your screen" : "checking what changed")

            guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1440) else {
                return "I can't see your screen. I need Screen Recording permission for that."
            }
            let remainingRounds = Self.maximumRounds - round
            guard let step = await requestSteps(
                goal: goal,
                mode: .steps,
                history: history,
                remainingRounds: remainingRounds,
                screen: screen
            )?.first else {
                if Task.isCancelled { return nil }
                return "Gemini's too busy to guide right now. Try me again in a sec."
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
                    // Clicky ends the guide here so it never nags; give one
                    // more look in case they did it another way.
                    if consecutiveClicksElsewhere >= 2 { return nil }
                    history.append("Step \(round): \"\(step.say)\" (target: \(step.targetLabel ?? "it")). The user clicked somewhere else instead; they may have done it another way or gotten lost.")
                case .timedOut:
                    return nil
                }

            case .look:
                let waitResult = await waitForStepCompletion(targetRect: nil, timeout: Self.lookWaitTimeoutSeconds)
                switch waitResult {
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

    // MARK: - Tour mode

    private func runTour(goal: String) async -> String? {
        onProgress?("looking around")
        guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1440) else {
            return "I can't see your screen. I need Screen Recording permission for that."
        }
        guard let beats = await requestSteps(goal: goal, mode: .tour, history: [], remainingRounds: 0, screen: screen),
              !beats.isEmpty else {
            if Task.isCancelled { return nil }
            return "Gemini's too busy for a tour right now. Try me again in a sec."
        }
        for (beatIndex, beat) in beats.enumerated() {
            if Task.isCancelled { return nil }
            onProgress?("\(beatIndex + 1) of \(beats.count): \(beat.say)")
            await presentStep?(beat)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return nil
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
        let result = await withCheckedContinuation { continuation in
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
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleUserClick(at: clickLocation)
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
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
    """

    private static func instruction(goal: String, mode: Mode, history: [String], remainingRounds: Int, frontmostApp: String) -> String {
        switch mode {
        case .steps:
            let historyText = history.isEmpty ? "Nothing yet; this is the first step." : history.joined(separator: "\n")
            return """
            Frontmost app: \(frontmostApp).
            What the user wants: \(goal)

            What has happened in this guide so far, oldest first:
            \(historyText)

            Look at this new screenshot as the truth. Give exactly ONE next step toward the goal, as {"steps": [step]}.
            - kind "click": the next action is a single click on something visible now (a menu, menu item, tab, button, panel). Set target_box tightly on it and target_label to its visible text. "say" names only that one click.
            - kind "look": the next action is manual work you can't watch for (dragging a clip, typing a name, moving a slider, choosing by taste), or something to notice. Mark the place and say what to do, ending with "say next when you're done".
            - kind "done": the goal is reached or already visible; "say" is a short, warm wrap-up of how they got there.
            If what's needed isn't visible, guide them to reveal it (a menu in the menu bar, a Window menu item, a panel tab, a scroll). Treat steps in the history as done unless the screen clearly shows they failed; never repeat the same target. If a menu you pointed at is now open, the next target is inside it. If the screen shows a different app than the goal needs, guide them back to it.
            \(remainingRounds == 0 ? "This is the last step you can give: use kind 'done' and tell them what's left in one sentence." : "")
            """
        case .tour:
            return """
            Frontmost app: \(frontmostApp).
            What the user wants: \(goal)

            Give a short tour of what's on screen, as {"steps": [4 to 7 steps]}, each kind "look", in a natural order (top to bottom, left to right, or most important first). Each step marks ONE main part of the window (use highlight for big areas, circle for a single control) and says what it is and what they'd use it for, in one short sentence. If the user asked about something specific, focus the tour on that. The last step can be a short, friendly wrap-up with a tip.
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
                "marks": ["type": "ARRAY", "items": markSchema]
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
        screen: DottieDisplayCapture.Screenshot
    ) async -> [Step]? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let requestBody: [String: Any] = [
            "model": Self.guideModel,
            "systemInstruction": ["parts": [["text": Self.systemInstruction]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": screen.jpegData.base64EncodedString()]],
                    ["text": Self.instruction(goal: goal, mode: mode, history: history, remainingRounds: remainingRounds, frontmostApp: frontmostApp)]
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

        guard let (responseData, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            print("⚠️ Guide request failed: \(String(decoding: responseData.prefix(300), as: UTF8.self))")
            return nil
        }
        // /chat streams server-sent events.
        var answerText = ""
        for line in String(decoding: responseData, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
            guard let eventData = line.dropFirst(6).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let candidates = event["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            for part in parts where (part["thought"] as? Bool) != true {
                answerText += part["text"] as? String ?? ""
            }
        }
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
                      let rect = (rawMark["box_2d"] as? [Any]).flatMap({ globalRect(fromBox: $0, screen: screen) }) else { return nil }
                let note = (rawMark["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Mark(shape: shape, rect: rect, note: note?.isEmpty == false ? note : nil)
            }
            let targetLabel = (rawStep["target_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Step(
                kind: kind,
                say: say,
                targetRect: targetRect,
                targetLabel: targetLabel?.isEmpty == false ? targetLabel : nil,
                marks: marks,
                displayFrame: screen.displayFrame
            )
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
