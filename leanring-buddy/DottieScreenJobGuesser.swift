//
//  DottieScreenJobGuesser.swift
//  leanring-buddy
//
//  Guess first, look second. Most apps barely change between versions and
//  their layouts are well known (menus, shortcuts, where things live), so
//  before a screen job sends its first screenshot to a model, Groq (then
//  Gemini, then Claude with a short wait) is asked, in words only, for the steps
//  it would take in that app: open an app or a link, pick a menu item by
//  its path, press a shortcut, type, click a control by its name. The Mac
//  then does them itself:
//
//    - menus through Accessibility (Format → Table → Insert Row), which
//      never misses when the path is right,
//    - clicks by finding the control's own name in the window's
//      Accessibility tree (no screenshot, no model),
//    - "done when" checked with on-Mac text recognition.
//
//  When every step lands and the done text shows, the job is finished with
//  no screenshot sent anywhere. When a guess misses (the menu item isn't
//  there, no control has that name), the job carries on with screenshots
//  from where the guesses got to, told what was done and what missed.
//
//  How-tos learned by watching the user (DottieWatchAndLearn), app lessons
//  and screen-job tips for the app go into the question, so guesses get
//  better on the user's own apps.
//

import AppKit
import ApplicationServices
import Foundation
import Vision

@MainActor
final class DottieScreenJobGuesser {
    static let shared = DottieScreenJobGuesser()

    nonisolated static let isEnabledDefaultsKey = "dottieScreenJobsGuessFirst"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledDefaultsKey) as? Bool ?? true
    }

    enum Outcome {
        /// Every step landed and the done text showed: nothing to look at.
        case finished(answer: String, steps: [String])
        /// Some steps were done blind; screenshots take it from here.
        case handedOver(note: String)
        /// No guess (unknown app, or the job needs looking from the start).
        case notTried
    }

    /// How long a step waits for its menu item or button to show up (apps
    /// and pages can take a moment), looking again every tenth of a second
    /// and going the moment it's there.
    private static let waitForControlSeconds: Double = 2
    /// How long an app or link gets to open before the next step.
    private static let waitAfterOpeningSeconds: Double = 1.5
    private static let geminiPlanModel = DottieModelPicker.normalModelName
    /// The Worker's route for a plan in words: GLM first, Claude as backup.
    static let planProviderName = "plan"

    /// Guesses the steps and does the ones it can without looking.
    func guessAndRun(taskText: String, knownHowTo: String, onProgress: @escaping @MainActor (String) -> Void) async -> Outcome {
        guard Self.isEnabled, DottieScreenActionPerformer.canPostEvents else { return .notTried }
        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let runningAppNames = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .prefix(20)
            .joined(separator: ", ")
        let question = """
        Task from the user: \(taskText)
        App in front: \(frontmostAppName). Apps open: \(runningAppNames).
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString).
        \(knownHowTo.isEmpty ? "" : "What Dottie already knows about doing this on this Mac:\n\(knownHowTo)\n")
        Reply with only the JSON object.
        """
        onProgress("working out the steps")
        guard let plan = await askForPlan(question) else { return .notTried }
        guard (plan["can_guess"] as? Bool) == true,
              let rawSteps = plan["steps"] as? [[String: Any]], !rawSteps.isEmpty else { return .notTried }

        var doneStepDescriptions: [String] = []
        for (stepIndex, rawStep) in rawSteps.prefix(25).enumerated() {
            if Task.isCancelled { return .notTried }
            let stepDescription = Self.describe(rawStep)
            onProgress("guessing step \(stepIndex + 1): \(stepDescription)")
            if let problem = await perform(rawStep) {
                DottieLog.notice("🔮 Guess missed at step \(stepIndex + 1) (\(stepDescription)): \(problem)")
                return .handedOver(note: Self.handOverNote(doneSteps: doneStepDescriptions, missedStep: stepDescription, problem: problem))
            }
            doneStepDescriptions.append(stepDescription)
            // Menus and windows take a moment to open.
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        let needsLook = (plan["needs_look"] as? Bool) ?? true
        let doneWhenText = (plan["done_when_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answer = (plan["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Done."
        if !needsLook, !doneWhenText.isEmpty {
            // The result can take a moment to show: look at 1.5 s, and once
            // more at 2 s.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var screenShowsDoneText = await Self.screenShows(doneWhenText)
            if !screenShowsDoneText {
                try? await Task.sleep(nanoseconds: 500_000_000)
                screenShowsDoneText = await Self.screenShows(doneWhenText)
            }
            if screenShowsDoneText {
                DottieLog.notice("🔮 Guessed the whole job without a screenshot: \(doneStepDescriptions.joined(separator: "; "))")
                return .finished(answer: answer, steps: doneStepDescriptions)
            }
        }
        return .handedOver(note: Self.handOverNote(doneSteps: doneStepDescriptions, missedStep: nil, problem: nil))
    }

    private static func handOverNote(doneSteps: [String], missedStep: String?, problem: String?) -> String {
        var note = doneSteps.isEmpty
            ? "Dottie tried to do this from memory of how the app is laid out, without looking."
            : "Dottie already did these steps from memory of how the app is laid out, without looking: \(doneSteps.joined(separator: "; "))."
        if let missedStep, let problem {
            note += " Then \"\(missedStep)\" didn't work (\(problem)), so carry on from what the screen shows now."
        } else {
            note += " Check the screen: if the task is done, call finish with the answer read from the screen; if not, carry on from here."
        }
        return note
    }

    // MARK: - Asking for the plan

    /// The plan comes from the Worker alone, GLM first (`"provider":
    /// "plan"`). A Claude planner bot used to be asked when that failed:
    /// another 8 s of "working out the steps" and a MausBot turn that loads
    /// about 55k cached tokens, for a guess the screenshot steps make anyway.
    private func askForPlan(_ question: String) async -> [String: Any]? {
        await askGeminiForPlan(question)
    }

    private func askGeminiForPlan(_ question: String) async -> [String: Any]? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let requestBody: [String: Any] = [
            // Words only: the Worker asks GLM first, then Claude.
            "provider": DottieScreenJobGuesser.planProviderName,
            "model": Self.geminiPlanModel,
            "systemInstruction": ["parts": [["text": Self.plannerInstructions]]],
            "contents": [["role": "user", "parts": [["text": question]]]],
            "generationConfig": ["responseMimeType": "application/json", "thinkingConfig": ["thinkingLevel": "low"]]
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        request.httpBody = requestData
        guard let (responseData, response) = try? await DottieModelPicker.shared.data(for: request, model: Self.geminiPlanModel, totalSeconds: 8),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let replyText = GeminiServerSentEvents.parts(from: responseData)
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        return DottieClaudeBot.jsonObject(in: replyText)
    }

    private static let plannerInstructions = """
    You plan jobs on the user's Mac without seeing the screen. You know macOS and common apps and websites well: their menus (by exact menu titles), keyboard shortcuts, and the names of their buttons. Dottie does your steps herself with Accessibility, so each step must name things exactly as the app does.

    Reply with only a JSON object:
    {"can_guess": true or false,
     "steps": [
       {"do": "open_app", "app": "Numbers"},
       {"do": "open_url", "url": "https://...", "app": "Safari"},
       {"do": "menu", "path": ["File", "New"]},
       {"do": "keys", "keys": "cmd+shift+n"},
       {"do": "type", "text": "..."},
       {"do": "click", "label": "exact name of the button, tab, link or field"},
       {"do": "wait", "seconds": 1.5}
     ],
     "done_when_text": "a short piece of text that will be visible on screen once it's done",
     "needs_look": true or false,
     "answer": "one short line to tell the user when it's done"}

    Rules:
    - can_guess is false when the steps depend on what's on screen (pick a result, read a value, find a specific message, a game, a site whose layout you don't know). Then leave steps empty.
    - Prefer, in order: a direct link (a site's search or page URL), a menu path, a keyboard shortcut, then clicking by name. Typing goes into whatever is focused, so focus the field first (a shortcut like cmd+l or a click on the field by name). To visit a site in a browser, use open_url (it opens a new tab) or press cmd+t first; never type an address over the tab the user already has open.
    - needs_look is true when the user wants something read off the screen or the result can't be checked by visible text.
    - Never plan a step that pays, sends, posts or deletes unless the task asks for exactly that, and never type a password.
    - Keep it short: at most 15 steps.
    """

    // MARK: - Doing a step without looking

    private static func describe(_ rawStep: [String: Any]) -> String {
        let action = rawStep["do"] as? String ?? "?"
        switch action {
        case "open_app": return "open \(rawStep["app"] as? String ?? "the app")"
        case "open_url": return "open \(rawStep["url"] as? String ?? "the link")"
        case "menu": return "menu " + ((rawStep["path"] as? [String]) ?? []).joined(separator: " → ")
        case "keys": return "press \(rawStep["keys"] as? String ?? "")"
        case "type": return "type \"\(String((rawStep["text"] as? String ?? "").prefix(40)))\""
        case "click": return "click \"\(rawStep["label"] as? String ?? "")\""
        case "wait": return "wait"
        default: return action
        }
    }

    /// Does one guessed step. nil when it worked, else what went wrong.
    private func perform(_ rawStep: [String: Any]) async -> String? {
        let action = rawStep["do"] as? String ?? ""
        switch action {
        case "open_app":
            guard let appName = rawStep["app"] as? String, await DottieScreenTaskRunner.openApplication(named: appName) else {
                return "couldn't open that app"
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.waitAfterOpeningSeconds * 1_000_000_000))
            return nil
        case "open_url":
            guard let address = rawStep["url"] as? String, let url = URL(string: address), url.scheme != nil else { return "not a link" }
            let opened: Bool
            if let appName = rawStep["app"] as? String, !appName.isEmpty {
                opened = await DottieScreenTaskRunner.open(url, inApplicationNamed: appName)
            } else {
                opened = NSWorkspace.shared.open(url)
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.waitAfterOpeningSeconds * 1_000_000_000))
            return opened ? nil : "couldn't open the link"
        case "menu":
            let path = (rawStep["path"] as? [String]) ?? []
            return await Self.retryingUntilItWorks { Self.selectMenu(path: path) }
        case "keys":
            guard let keys = rawStep["keys"] as? String, DottieScreenActionPerformer.press(keyCombination: keys) else { return "couldn't press those keys" }
            return nil
        case "type":
            guard let text = rawStep["text"] as? String, !text.isEmpty else { return "nothing to type" }
            if DottieAX.focusedElementIsSecure() { return "the focused field is a password box" }
            await DottieScreenActionPerformer.type(text)
            return nil
        case "click":
            guard let label = rawStep["label"] as? String, !label.isEmpty else { return "no name to click" }
            // Away, risky buttons need a yes, which needs a screenshot to
            // show: leave those to the screenshot loop.
            if DottieAwayMode.isRiskyLabel(label) { return "it's a button that pays, sends, posts or deletes, so it needs a look first" }
            return await Self.retryingUntilItWorks { await Self.clickControl(named: label) }
        case "wait":
            let seconds = min(max((rawStep["seconds"] as? NSNumber)?.doubleValue ?? 1, 0.2), 8)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        default:
            return "unknown step"
        }
    }

    /// Runs a step that finds something by name (a menu item, a button)
    /// again every tenth of a second until it works or waitForControlSeconds
    /// pass, so a slow app or page gets time to draw it. nil when it worked,
    /// else the last problem.
    private static func retryingUntilItWorks(_ step: () async -> String?) async -> String? {
        let deadline = Date().addingTimeInterval(waitForControlSeconds)
        var lastProblem = await step()
        while lastProblem != nil, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            lastProblem = await step()
        }
        return lastProblem
    }

    /// Picks a menu item by its titles, starting at the menu bar of the app
    /// in front. nil when it was picked.
    static func selectMenu(path: [String]) -> String? {
        guard !path.isEmpty, let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return "no menu path" }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        guard let menuBar = DottieAX.element(applicationElement, kAXMenuBarAttribute) else { return "no menu bar" }
        var currentContainer = menuBar
        for (index, title) in path.enumerated() {
            // A menu bar item or menu item holds its menu as its one child.
            let candidates = DottieAX.children(currentContainer).flatMap { child -> [AXUIElement] in
                DottieAX.string(child, kAXRoleAttribute) == (kAXMenuRole as String) ? DottieAX.children(child) : [child]
            }
            guard let item = candidates.first(where: { Self.namesMatch(DottieAX.string($0, kAXTitleAttribute), title) }) else {
                return "no \"\(title)\" in the \(index == 0 ? "menu bar" : path[index - 1]) menu"
            }
            if index == path.count - 1 {
                if let isEnabled = DottieAX.bool(item, kAXEnabledAttribute), !isEnabled { return "\"\(title)\" is greyed out" }
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? nil : "couldn't pick \"\(title)\""
            }
            currentContainer = item
        }
        return nil
    }

    /// Clicks the control with this name in the window in front, found in
    /// its Accessibility tree. nil when clicked.
    static func clickControl(named label: String) async -> String? {
        guard let window = DottieAX.focusedWindow() else { return "no window in front" }
        var bestMatch: (element: AXUIElement, score: Int)?
        var elementsToVisit = [window]
        var visitedCount = 0
        while !elementsToVisit.isEmpty, visitedCount < 2500 {
            let element = elementsToVisit.removeFirst()
            visitedCount += 1
            let role = DottieAX.string(element, kAXRoleAttribute) ?? ""
            let nameAttributes: [String] = [kAXTitleAttribute as String, kAXDescriptionAttribute as String, "AXLabel", kAXHelpAttribute as String, "AXPlaceholderValue"]
            var names: [String] = nameAttributes.compactMap { DottieAX.string(element, $0) }
            if role == "AXStaticText" || role == "AXButton" || role == "AXLink", let value = DottieAX.string(element, kAXValueAttribute as String) {
                names.append(value)
            }
            if names.contains(where: { namesMatch($0, label) }) {
                // A real control beats a label next to it.
                let score = DottieAX.strongClickableRoles.contains(role) ? 2 : (DottieAX.clickableRoles.contains(role) ? 1 : 0)
                if score > (bestMatch?.score ?? -1) {
                    bestMatch = (element, score)
                    if score == 2 { break }
                }
            }
            elementsToVisit.append(contentsOf: DottieAX.children(element))
        }
        guard let match = bestMatch?.element else { return "nothing named \"\(label)\" in the window" }
        let role = DottieAX.string(match, kAXRoleAttribute) ?? ""
        let isTextField = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role)
        if !isTextField, AXUIElementPerformAction(match, kAXPressAction as CFString) == .success {
            return nil
        }
        // Text fields get focus from a real click; so does anything that
        // doesn't take AXPress.
        guard let frame = DottieAX.axFrame(match), frame.width > 0, frame.height > 0 else { return "couldn't reach \"\(label)\"" }
        let clickPoint = DottieAX.appKitPoint(fromAX: CGPoint(x: frame.midX, y: frame.midY))
        DottieScreenActionPerformer.click(at: clickPoint, clickCount: 1, isRightClick: false)
        return nil
    }

    /// "Insert Row…" matches "insert row", and "Save As" matches "Save As…".
    static func namesMatch(_ candidate: String?, _ wanted: String) -> Bool {
        guard let candidate else { return false }
        func simplified(_ text: String) -> String {
            text.lowercased()
                .replacingOccurrences(of: "…", with: "")
                .replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        let simplifiedCandidate = simplified(candidate)
        let simplifiedWanted = simplified(wanted)
        return !simplifiedWanted.isEmpty && simplifiedCandidate == simplifiedWanted
    }

    /// Whether the screen in front shows this text, read on the Mac.
    static func screenShows(_ text: String) async -> Bool {
        guard let screen = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 1600) else { return false }
        let image = screen.image
        let lines = await Task.detached(priority: .userInitiated) {
            DottieScreenJobGuesser.readTextLines(in: image)
        }.value
        let wanted = text.lowercased()
        return lines.contains { $0.lowercased().contains(wanted) }
    }

    /// The lines of text on a screenshot, top to bottom, read with Apple's
    /// on-Mac text recognition (fast pass, confident lines only).
    nonisolated static func readTextLines(in image: CGImage) -> [String] {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        try? requestHandler.perform([textRequest])
        let observations = (textRequest.results ?? [])
            .filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.4 }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        return observations
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .prefix(40)
            .map { $0 }
    }
}

extension DottieAX {
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    /// True when the focused field is a password box, so nothing guessed
    /// is typed into it.
    static func focusedElementIsSecure() -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = element(systemWideElement, kAXFocusedUIElementAttribute) else { return false }
        return string(focusedElement, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
    }
}
