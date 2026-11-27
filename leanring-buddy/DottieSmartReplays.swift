//
//  DottieSmartReplays.swift
//  leanring-buddy
//
//  Smart replays: the user shows Dottie a job once ("create a smart replay
//  of me doing this"), and she keeps it as steps by what they meant, not
//  where the mouse went: open a new tab, go to instagram.com, click Search,
//  search for "example", open the account "example". Running one hands the
//  steps to a screen job, which finds each thing by its name, so it still
//  works when the page moves around.
//
//  Two kinds:
//  - smart: gets it done, adapts when the screen looks different and skips
//    steps already done.
//  - commercial: for filming. Exactly these steps in this order at a calm,
//    visible pace, nothing extra, and it stops and asks instead of
//    improvising.
//
//  Each one can have a closing line the user types once (asked in a text
//  box after recording), spoken at the end of every run, and phrases that
//  start it by voice, matched by meaning in the voice prompt.
//
//  Saved in Application Support/Dottie/Replays/Smart/<id>.json, edited in
//  Home → Smart Replays or by voice. The older instant replays
//  (DottieReplays.swift) stay as they are.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

struct DottieSmartReplay: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case smart
        case commercial

        var title: String {
            switch self {
            case .smart: return "Smart"
            case .commercial: return "Commercial"
            }
        }
    }

    var id: UUID
    var name: String
    var kind: Kind
    /// In order, by what each one means ("Search for \"example\"").
    var steps: [String]
    /// Said out loud at the end of every run, word for word. Nil for none.
    var closingMessage: String?
    /// What the user says to start it ("find me a school fest").
    var voiceShortcuts: [String]
    var createdAt: Date
    var lastRunAt: Date?
    var runCount: Int
}

// MARK: - The store

@MainActor
final class DottieSmartReplayStore: ObservableObject {
    static let shared = DottieSmartReplayStore()

    @Published private(set) var replays: [DottieSmartReplay] = []
    let folderURL: URL

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folderURL = applicationSupportURL.appendingPathComponent("Dottie/Replays/Smart", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        load()
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func load() {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        replays = fileURLs.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(DottieSmartReplay.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func fileURL(for replayID: UUID) -> URL {
        folderURL.appendingPathComponent("\(replayID.uuidString).json")
    }

    /// Adds a new replay or saves changes to one.
    func save(_ replay: DottieSmartReplay) {
        var cleanedReplay = replay
        cleanedReplay.steps = replay.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedClosingMessage = replay.closingMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cleanedReplay.closingMessage = trimmedClosingMessage.isEmpty ? nil : trimmedClosingMessage
        cleanedReplay.voiceShortcuts = replay.voiceShortcuts
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\"'")).lowercased() }
            .filter { !$0.isEmpty }
        if let existingIndex = replays.firstIndex(where: { $0.id == replay.id }) {
            replays[existingIndex] = cleanedReplay
        } else {
            replays.insert(cleanedReplay, at: 0)
        }
        guard let replayData = try? Self.encoder.encode(cleanedReplay) else { return }
        DottieFileSaver.save(replayData, to: fileURL(for: cleanedReplay.id))
    }

    func delete(_ replayID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: replayID))
        replays.removeAll { $0.id == replayID }
    }

    func noteRun(_ replayID: UUID) {
        guard var replay = replays.first(where: { $0.id == replayID }) else { return }
        replay.runCount += 1
        replay.lastRunAt = Date()
        save(replay)
    }

    func replay(withID replayID: UUID) -> DottieSmartReplay? {
        replays.first { $0.id == replayID }
    }

    /// The replay the user means: by a shortcut phrase, its number in the
    /// list ("the first one"), or its name.
    func replay(named spokenName: String) -> DottieSmartReplay? {
        let wanted = spokenName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let shortcutMatch = replays.first(where: { replay in
            replay.voiceShortcuts.contains { $0 == wanted || wanted.contains($0) || $0.contains(wanted) }
        }) {
            return shortcutMatch
        }
        let ordinalWords = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9]
        let ignoredWords: Set<String> = ["the", "one", "replay", "smart", "commercial", "number", "no"]
        let meaningfulWords = wanted.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !ignoredWords.contains($0) }
        if meaningfulWords.count == 1, let position = ordinalWords[meaningfulWords[0]] {
            return replays.indices.contains(position - 1) ? replays[position - 1] : nil
        }
        if meaningfulWords.count == 1, ["last", "latest", "newest"].contains(meaningfulWords[0]) {
            return replays.first
        }
        return replays.first { $0.name.lowercased() == wanted }
            ?? replays.first { $0.name.lowercased().contains(wanted) || wanted.contains($0.name.lowercased()) }
    }

    /// For the voice prompt: each replay's name and its shortcut phrases,
    /// so a request that means the same as a phrase starts it. Nil when
    /// there are no replays.
    var voicePromptLine: String? {
        guard !replays.isEmpty else { return nil }
        let replayLines = replays.prefix(20).map { replay -> String in
            let shortcutsText = replay.voiceShortcuts.isEmpty ? "" : " (started by: " + replay.voiceShortcuts.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
            return "\"\(replay.name)\" [\(replay.kind.rawValue)]\(shortcutsText)"
        }
        return "smart replays the user made: " + replayLines.joined(separator: "; ")
            + ". when the user asks for one of these, or says something that means the same as one of its phrases (reworded, words missing, a different detail like another search word), call use_tool smart_replays {\"action\": \"run\", \"name\": the replay's name, \"details\": what's different this time, if anything} right away. if two could fit, ask which one in a few words."
    }
}

// MARK: - Recording

/// Watches the user's clicks and typing while they show Dottie a job, and
/// turns them into steps by meaning when they're done. Watch me uses it
/// too, and gets each action with what's needed to save it as a task step
/// (DottieWatchedAction), hovers before a click elsewhere, and typed notes
/// told apart from form typing.
@MainActor
final class DottieSmartReplayRecorder {
    static let shared = DottieSmartReplayRecorder()

    /// What's under the pointer, read through Accessibility.
    struct PointedElement {
        let role: String
        let label: String?
        /// "the button \"Search\"", or where it was when it has no name.
        let description: String
    }

    private(set) var isRecording = false
    private(set) var recordingKind: DottieSmartReplay.Kind = .smart
    /// Watch me: every action with its place, spot and field, for tasks.
    private(set) var watchedActions: [DottieWatchedAction] = []
    /// Actions past the cap, not kept (said at the end so nothing is lost silently).
    private(set) var droppedActionCount = 0
    /// How many notes were typed so far; the watcher reads the screen after each.
    private(set) var narrationCount = 0
    /// A tour reads long sentences about the screen as notes too.
    private var isTour = false
    private var eventMonitors: [Any] = []
    private var appActivationObserver: NSObjectProtocol?
    private var pointerTimer: Timer?
    /// What the user did, one line per action, in order.
    private var actionLines: [String] = []
    private var typedTextBuffer = ""
    private var typedFieldLabel: String?
    private var didTypeIntoPasswordField = false
    private var lastPlaceLine: String?
    private var lastContext: DottieReplayContext?
    private var lastClickPosition: (centerX: Double, centerY: Double)?
    private var startedAt = Date()
    private var hoverTracker = DottieWatchHoverTracker()
    /// What the pointer rested on last, waiting for a click elsewhere.
    private var restedElement: (rest: DottieWatchHoverTracker.Rest, element: PointedElement, position: (centerX: Double, centerY: Double)?)?
    private static let describingModel = DottieModelPicker.normalModelName
    private static let maximumActionLines = DottieWatchPlan.maximumActions
    private static let pointerSampleSeconds = 0.3

    func start(kind: DottieSmartReplay.Kind, isTour: Bool = false) -> Bool {
        guard !isRecording else { return false }
        guard AXIsProcessTrusted() else { return false }
        recordingKind = kind
        self.isTour = isTour
        actionLines = []
        watchedActions = []
        droppedActionCount = 0
        narrationCount = 0
        typedTextBuffer = ""
        typedFieldLabel = nil
        didTypeIntoPasswordField = false
        lastPlaceLine = nil
        lastContext = nil
        lastClickPosition = nil
        hoverTracker = DottieWatchHoverTracker()
        restedElement = nil
        startedAt = Date()
        isRecording = true
        // Global monitors see input going to other apps, never Dottie's own.
        if let clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.noteClick(isRightClick: event.type == .rightMouseDown)
            }
        }) {
            eventMonitors.append(clickMonitor)
        }
        if let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.noteKey(event)
            }
        }) {
            eventMonitors.append(keyMonitor)
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushTypedText()
                self?.notePlaceIfChanged()
            }
        }
        // The pointer, a few times a second, only while recording: a rest on
        // something just before a click elsewhere is a hover (a menu).
        pointerTimer = Timer.scheduledTimer(withTimeInterval: Self.pointerSampleSeconds, repeats: true) { _ in
            Task { @MainActor in DottieSmartReplayRecorder.shared.samplePointer() }
        }
        notePlaceIfChanged()
        return true
    }

    /// Ends the recording. The raw actions, or nil when nothing was done.
    /// `watchedActions` keeps the same actions for watch me until the next start.
    func stop() -> [String]? {
        guard isRecording else { return nil }
        flushTypedText()
        for eventMonitor in eventMonitors {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitors = []
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        appActivationObserver = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        isRecording = false
        var recordedActionLines = actionLines
        actionLines = []
        let hasAnyAction = recordedActionLines.contains { !$0.hasPrefix("[in ") }
        if droppedActionCount > 0 {
            recordedActionLines.append("(\(droppedActionCount) more actions after these weren't kept)")
        }
        return hasAnyAction ? recordedActionLines : nil
    }

    private var isDottieInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private var secondsSinceStart: Double {
        Date().timeIntervalSince(startedAt)
    }

    private func append(_ actionLine: String, watched watchedAction: DottieWatchedAction) {
        guard actionLines.count < Self.maximumActionLines else {
            droppedActionCount += 1
            return
        }
        actionLines.append(actionLine)
        watchedActions.append(watchedAction)
    }

    /// An action with the place it happened in and when.
    private func makeAction(_ kind: DottieWatchedAction.Kind, label: String, role: String? = nil,
                            position: (centerX: Double, centerY: Double)? = nil, text: String? = nil,
                            fieldLabel: String? = nil, isHiddenBecausePrivate: Bool = false) -> DottieWatchedAction {
        let context = lastContext
        let placeKey = context?.appBundleIdentifier.map { DottieAppTaskPlan.placeKey(siteHost: context?.siteHost, bundleIdentifier: $0) } ?? ""
        return DottieWatchedAction(
            kind: kind, label: label, role: role, centerX: position?.centerX, centerY: position?.centerY, text: text,
            fieldLabel: fieldLabel, isHiddenBecausePrivate: isHiddenBecausePrivate, pageTitle: context?.windowTitle ?? "",
            placeKey: placeKey, placeName: context?.siteHost ?? context?.appName ?? "", secondsIntoWatch: secondsSinceStart
        )
    }

    /// Where a point is, 0-1000 across and down its screen.
    private static func screenPosition(of appKitPoint: CGPoint) -> (centerX: Double, centerY: Double)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }),
              screen.frame.width > 0, screen.frame.height > 0 else { return nil }
        let centerX = Double((appKitPoint.x - screen.frame.minX) / screen.frame.width * 1000)
        let centerY = Double((screen.frame.maxY - appKitPoint.y) / screen.frame.height * 1000)
        return (centerX, centerY)
    }

    /// "[in Safari: instagram.com]", added when the app or site changes.
    private func notePlaceIfChanged() {
        guard !isDottieInFront else { return }
        let context = DottieReplayContext.current()
        lastContext = context
        let placeText = [context.appName, context.siteHost ?? context.windowTitle.map { String($0.prefix(60)) }]
            .compactMap { $0 }
            .joined(separator: ": ")
        let placeLine = "[in \(placeText)]"
        guard placeLine != lastPlaceLine else { return }
        lastPlaceLine = placeLine
        append(placeLine, watched: makeAction(.place, label: placeText))
    }

    /// Writes down what was typed since the last key that ends typing.
    /// Returns true when it was a note about the screen, not form typing.
    @discardableResult
    private func flushTypedText() -> Bool {
        if didTypeIntoPasswordField {
            append("typed a password (not saved)", watched: makeAction(.password, label: ""))
            didTypeIntoPasswordField = false
        }
        guard !typedTextBuffer.isEmpty else { return false }
        let typedText = typedTextBuffer
        let fieldLabel = typedFieldLabel
        typedTextBuffer = ""
        typedFieldLabel = nil
        if DottieWatchPlan.isNarration(typedText, isTour: isTour) {
            let narrationText = DottieWatchPlan.narrationText(typedText)
            narrationCount += 1
            append("wrote a note: \"\(narrationText)\"", watched: makeAction(.narration, label: "", text: narrationText))
            return true
        }
        // Private-looking values (an SSN, a birth date, a phone number)
        // never reach watch me's model; smart replays keep the text to type.
        let isPrivate = DottieWatchPlan.looksPrivate(fieldLabel: fieldLabel, value: typedText)
        append("typed \"\(typedText)\"", watched: makeAction(
            .typed, label: fieldLabel ?? "", position: lastClickPosition, text: isPrivate ? nil : typedText,
            fieldLabel: fieldLabel, isHiddenBecausePrivate: isPrivate
        ))
        return false
    }

    private func noteClick(isRightClick: Bool) {
        guard !isDottieInFront else { return }
        flushTypedText()
        notePlaceIfChanged()
        let mouseLocation = NSEvent.mouseLocation
        let position = Self.screenPosition(of: mouseLocation)
        lastClickPosition = position
        let pointedElement = Self.readElementUnderPointer()
        // The pointer rested on a menu, then clicked one of its items.
        if let hoverRest = hoverTracker.restBeforeClick(pointX: Double(mouseLocation.x), pointY: Double(mouseLocation.y), at: secondsSinceStart),
           let restedElement, restedElement.rest == hoverRest,
           let restedLabel = restedElement.element.label, !restedLabel.isEmpty, restedLabel != pointedElement.label {
            append("pointed the mouse at \(restedElement.element.description) (a menu opened)", watched: makeAction(
                .hover, label: restedLabel, role: restedElement.element.role, position: restedElement.position
            ))
        }
        restedElement = nil
        append("\(isRightClick ? "right-clicked" : "clicked") \(pointedElement.description)", watched: makeAction(
            isRightClick ? .rightClick : .click, label: pointedElement.label ?? "", role: pointedElement.role, position: position
        ))
    }

    /// A pointer sample: when the pointer has just come to rest, what's
    /// under it is read once, for a hover if a click elsewhere follows.
    private func samplePointer() {
        guard isRecording, !isDottieInFront else { return }
        let mouseLocation = NSEvent.mouseLocation
        guard let rest = hoverTracker.notePointer(pointX: Double(mouseLocation.x), pointY: Double(mouseLocation.y), at: secondsSinceStart) else { return }
        restedElement = (rest, Self.readElementUnderPointer(), Self.screenPosition(of: mouseLocation))
    }

    private func noteKey(_ event: NSEvent) {
        guard !isDottieInFront else { return }
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCharacters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifierFlags.contains(.command) || modifierFlags.contains(.control) {
            flushTypedText()
            var modifierNames: [String] = []
            if modifierFlags.contains(.control) { modifierNames.append("control") }
            if modifierFlags.contains(.option) { modifierNames.append("option") }
            if modifierFlags.contains(.shift) { modifierNames.append("shift") }
            if modifierFlags.contains(.command) { modifierNames.append("cmd") }
            append("pressed \((modifierNames + [keyCharacters.uppercased()]).joined(separator: "+"))",
                   watched: makeAction(.pressed, label: (modifierNames + [keyCharacters]).joined(separator: "+")))
            notePlaceIfChanged()
            return
        }
        switch event.keyCode {
        case 36, 76:
            // Return that ends a typed note isn't a step.
            if !flushTypedText() {
                append("pressed return", watched: makeAction(.pressed, label: "return"))
            }
        case 48:
            flushTypedText()
            append("pressed tab", watched: makeAction(.pressed, label: "tab"))
        case 53:
            flushTypedText()
            append("pressed escape", watched: makeAction(.pressed, label: "escape"))
        case 51:
            if typedTextBuffer.isEmpty {
                append("pressed delete", watched: makeAction(.pressed, label: "delete"))
            } else {
                typedTextBuffer.removeLast()
            }
        case 123, 124, 125, 126:
            flushTypedText()
            let arrowName = ["left", "right", "down", "up"][Int(event.keyCode) - 123]
            append("pressed the \(arrowName) arrow", watched: makeAction(.pressed, label: arrowName))
        default:
            // Passwords are never written down, only that one was typed.
            if Self.isPasswordFieldFocused() {
                didTypeIntoPasswordField = true
            } else if let typedCharacters = event.characters, !typedCharacters.isEmpty {
                if typedTextBuffer.isEmpty { typedFieldLabel = Self.focusedFieldLabel() }
                typedTextBuffer += typedCharacters
            }
        }
    }

    private static func isPasswordFieldFocused() -> Bool {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedElement = DottieAccessibilityCast.element(focusedValue) else { return false }
        return DottieAX.string(focusedElement, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
    }

    /// The name of the text box being typed into ("First Name"), when
    /// Accessibility gives one.
    private static func focusedFieldLabel() -> String? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedElement = DottieAccessibilityCast.element(focusedValue) else { return nil }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", "AXPlaceholderValue", kAXHelpAttribute]
            .lazy
            .compactMap { DottieAX.string(focusedElement, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return label.map { String($0.prefix(80)) }
    }

    /// What's under the pointer, from Accessibility, or where in the window
    /// it was when the thing has no name.
    private static func readElementUnderPointer() -> PointedElement {
        let axPoint = DottieAX.axPoint(fromAppKit: NSEvent.mouseLocation)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &hitElement) == .success,
              let hitElement else {
            return PointedElement(role: "thing", label: nil, description: "somewhere Dottie couldn't read")
        }
        // A label inside a button or link: describe the button or link.
        var describedElement = hitElement
        var candidate: AXUIElement? = hitElement
        for _ in 0..<4 {
            guard let currentCandidate = candidate else { break }
            if let role = DottieAX.string(currentCandidate, kAXRoleAttribute), DottieAX.strongClickableRoles.contains(role) {
                describedElement = currentCandidate
                break
            }
            candidate = DottieAX.element(currentCandidate, kAXParentAttribute)
        }
        let role = DottieAX.string(describedElement, kAXRoleDescriptionAttribute)
            ?? DottieAX.string(describedElement, kAXRoleAttribute)?.replacingOccurrences(of: "AX", with: "").lowercased()
            ?? "thing"
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXValueAttribute, kAXHelpAttribute]
            .lazy
            .compactMap { DottieAX.string(describedElement, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? DottieAX.string(hitElement, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !label.isEmpty {
            let shortLabel = String(label.prefix(80))
            return PointedElement(role: role, label: shortLabel, description: "the \(role) \"\(shortLabel)\"")
        }
        if let window = DottieAX.enclosingWindow(of: hitElement), let windowFrame = DottieAX.axFrame(window), windowFrame.width > 0, windowFrame.height > 0 {
            let percentAcross = Int((axPoint.x - windowFrame.minX) / windowFrame.width * 100)
            let percentDown = Int((axPoint.y - windowFrame.minY) / windowFrame.height * 100)
            return PointedElement(role: role, label: nil, description: "an unnamed \(role) about \(percentAcross)% across and \(percentDown)% down the window")
        }
        return PointedElement(role: role, label: nil, description: "an unnamed \(role)")
    }

    /// Turns the raw actions into a name and steps by meaning, like a
    /// person describing what they did.
    static func describe(actionLines: [String], kind: DottieSmartReplay.Kind) async -> (name: String, steps: [String]) {
        let prompt = """
        Here is everything the user did on their Mac while showing an assistant how to do a job, in order. Lines in [brackets] say which app and site they were in.

        \(actionLines.joined(separator: "\n"))

        Write it as the steps a person would use to explain the job: what they meant, not raw clicks. For example: "Open a new browser tab", "Go to instagram.com", "Click Search", "Search for \\"example\\"", "Open the account \\"example\\"".
        - Merge clicking a box and typing into it into one step, and typing then pressing return into one step.
        - Name things by their visible names. Keep typed text exactly, in quotes.
        - Leave out mistakes the user undid and clicks that did nothing.
        - \(kind == .commercial ? "This is for filming, so keep every step the user did, in order." : "Keep it as short as the job allows.")
        Reply with only JSON: {"name": "a short name for the job, 2 to 5 words", "steps": ["...", "..."]}
        """
        if let answer = await DottieChat.ask(prompt, model: describingModel),
           let openingBraceIndex = answer.firstIndex(of: "{"),
           let closingBraceIndex = answer.lastIndex(of: "}"),
           let answerData = String(answer[openingBraceIndex...closingBraceIndex]).data(using: .utf8),
           let answerObject = try? JSONSerialization.jsonObject(with: answerData) as? [String: Any],
           let steps = answerObject["steps"] as? [String], !steps.isEmpty {
            let name = (answerObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (name.isEmpty ? "Smart replay" : String(name.prefix(60)), steps)
        }
        // Gemini didn't answer: the raw actions still make a replay the user
        // can tidy up in Home.
        return ("Smart replay", actionLines.filter { !$0.hasPrefix("[in ") })
    }
}

// MARK: - Asking in text

/// A text box for something only the user can write (the line a replay
/// says at the end). Returns nil when they skip it.
@MainActor
enum DottieTextPrompt {
    static func ask(title: String, detail: String, placeholder: String, initialText: String = "") -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Skip")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.placeholderString = placeholder
        textField.stringValue = initialText
        alert.accessoryView = textField
        alert.window.level = .floating
        alert.window.initialFirstResponder = textField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let typedText = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return typedText.isEmpty ? nil : typedText
    }
}

// MARK: - Running

extension DottieSmartReplay {
    /// The screen job's task. `details` is what the user wants different
    /// this time ("search for nasa instead").
    func screenJobTaskText(details: String?) -> String {
        let numberedSteps = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let detailsLine = details.map { "\nThis time the user wants: \($0). Change only what that asks (like the text to search for); keep every other step the same." } ?? ""
        switch kind {
        case .smart:
            return """
            Smart replay "\(name)", a job the user showed you once. Do it again by what each step means: the screen may look a bit different, so find each thing by its name, and skip a step that's already done.
            \(numberedSteps)\(detailsLine)
            """
        case .commercial:
            return """
            Commercial replay "\(name)": this run is being filmed. Do exactly these steps, in this order, one at a time, at a calm and steady pace, with nothing extra: no other clicks, no detours, no closing or reopening things. If a step can't be done exactly as written, stop and ask the user instead of doing something else.
            \(numberedSteps)\(detailsLine)
            """
        }
    }
}

// MARK: - Voice tool

@MainActor
enum DottieSmartReplayTools: DottieToolModule {
    /// Starts a smart replay as a screen job: the replay and what's
    /// different this time. Returns the status for the voice. Set by
    /// CompanionManager.
    static var startSmartReplayJob: ((DottieSmartReplay, String?) -> String)?

    static var voicePromptSection: String {
        "smart replays: \"create a smart replay of me doing this\" or \"create a commercial replay of me doing this\" → use_tool smart_replays {\"action\": \"start\", \"kind\": \"smart\" or \"commercial\"}, then say you're watching. while one is being recorded, \"done\" or \"stop\" → smart_replays stop. \"when I say X, run replay Y\" → smart_replays shortcut (or replays shortcut for an instant replay), never remember."
    }

    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "smart_replays",
                description: "Smart replays: jobs the user shows Dottie once and she redoes by meaning (open a new tab, go to instagram.com, click Search, search for \"example\"). Two kinds: smart (adapts, gets it done) and commercial (for filming: exactly these steps, calm visible pace, asks instead of improvising). start: begin watching the user ('create a smart replay of me doing this'). stop: they're done ('done'); Dottie writes the steps and asks in a text box what to say at the end. list. show: one replay's steps. run: by name, number ('the first one') or shortcut, with details for what's different this time ('search for nasa'). edit: change the name, kind, steps (the whole new list), or closing_message (what she says at the end; empty removes it). shortcut: a phrase that starts it. delete: only when the user asks; they confirm on screen. open: show the editor in Home.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "stop", "list", "show", "run", "edit", "shortcut", "delete", "open"], "description": "What to do."],
                        "kind": ["type": "STRING", "enum": ["smart", "commercial"], "description": "start and edit: which kind."],
                        "name": ["type": "STRING", "description": "Which replay: its name, number in the list, or a shortcut phrase."],
                        "details": ["type": "STRING", "description": "run: what's different this time, in the user's words."],
                        "new_name": ["type": "STRING", "description": "edit: a new name."],
                        "steps": ["type": "ARRAY", "items": ["type": "STRING"], "description": "edit: the full new list of steps, in order."],
                        "closing_message": ["type": "STRING", "description": "edit: what to say at the end of every run, word for word."],
                        "phrase": ["type": "STRING", "description": "shortcut: what the user will say to start it."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                await runTool(arguments)
            }
        ]
    }

    private static func runTool(_ arguments: [String: Any]) async -> String {
        let store = DottieSmartReplayStore.shared
        let recorder = DottieSmartReplayRecorder.shared
        switch arguments.dottieString("action") ?? "list" {
        case "start":
            let kind = DottieSmartReplay.Kind(rawValue: arguments.dottieString("kind") ?? "smart") ?? .smart
            guard !recorder.isRecording else { return "already watching; say done when finished." }
            guard recorder.start(kind: kind) else {
                return "can't watch yet: Dottie needs Accessibility access in System Settings → Privacy & Security."
            }
            return "watching now for a \(kind.rawValue) replay. tell the user to go ahead and say done when finished."
        case "stop":
            return await stopWatchingAndSaveReplay()
        case "list":
            guard !store.replays.isEmpty else { return "no smart replays yet. say \"create a smart replay of me doing this\" to make one." }
            return store.replays.enumerated().map { index, replay in
                "\(index + 1). \(replay.name) (\(replay.kind.rawValue), \(replay.steps.count) steps\(replay.voiceShortcuts.isEmpty ? "" : ", shortcuts: " + replay.voiceShortcuts.joined(separator: " / ")))"
            }.joined(separator: "\n")
        case "show":
            guard let replay = arguments.dottieString("name").flatMap(store.replay(named:)) else {
                return "no smart replay matches that. call smart_replays list."
            }
            let numberedSteps = replay.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            return "\(replay.name) (\(replay.kind.rawValue)):\n\(numberedSteps)\nsays at the end: \(replay.closingMessage ?? "nothing")"
        case "run":
            guard let replay = arguments.dottieString("name").flatMap(store.replay(named:)) else {
                return "no smart replay matches that. call smart_replays list."
            }
            guard let startSmartReplayJob else { return "replays can't run right now." }
            return "\(replay.kind.rawValue) replay \"\(replay.name)\": " + startSmartReplayJob(replay, arguments.dottieString("details"))
        case "edit":
            return editReplay(arguments)
        case "shortcut":
            guard var replay = arguments.dottieString("name").flatMap(store.replay(named:)) else {
                return "no smart replay matches that. call smart_replays list."
            }
            guard let phrase = arguments.dottieString("phrase") else { return "say which phrase should start it." }
            replay.voiceShortcuts.append(phrase)
            store.save(replay)
            return "saved: saying \"\(phrase)\", or anything that means the same, now runs \"\(replay.name)\". it works from the next conversation on."
        case "delete":
            guard let replay = arguments.dottieString("name").flatMap(store.replay(named:)) else {
                return "no smart replay matches that."
            }
            let isConfirmed = DottieConfirmation.ask(
                title: "Delete the smart replay \"\(replay.name)\"?",
                detail: "Its \(replay.steps.count) steps, closing line and shortcuts are removed.",
                confirmButtonTitle: "Delete"
            )
            guard isConfirmed else { return "the user chose to keep it." }
            store.delete(replay.id)
            return "deleted \"\(replay.name)\"."
        case "open":
            DottieSelfKnowledge.companionManager?.openHomeWindow()
            DottieHomeNavigator.shared.requestedSection = .smartReplays
            return "opened Smart Replays in Home."
        default:
            return "unknown action."
        }
    }

    /// Stops watching, has the actions turned into steps and saves them as a
    /// new replay, then opens the text box for its closing line.
    private static func stopWatchingAndSaveReplay() async -> String {
        let store = DottieSmartReplayStore.shared
        let recorder = DottieSmartReplayRecorder.shared
        let recordingKind = recorder.recordingKind
        guard recorder.isRecording else { return "wasn't watching anything." }
        guard let actionLines = recorder.stop() else {
            return "stopped, but nothing was done while watching, so nothing was saved."
        }
        let description = await DottieSmartReplayRecorder.describe(actionLines: actionLines, kind: recordingKind)
        let newReplay = DottieSmartReplay(
            id: UUID(),
            name: description.name,
            kind: recordingKind,
            steps: description.steps,
            closingMessage: nil,
            voiceShortcuts: [],
            createdAt: Date(),
            lastRunAt: nil,
            runCount: 0
        )
        store.save(newReplay)
        let savedReplayID = newReplay.id
        let savedReplayName = newReplay.name
        // The text box opens after this answer, so the voice isn't kept
        // waiting while the user types.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let closingMessage = DottieTextPrompt.ask(
                title: "Want Dottie to say something when \"\(savedReplayName)\" finishes?",
                detail: "She'll say it out loud at the end of every run. You can change it later in Home → Smart Replays.",
                placeholder: "Type it here, or skip"
            )
            guard let closingMessage, var savedReplay = store.replay(withID: savedReplayID) else { return }
            savedReplay.closingMessage = closingMessage
            store.save(savedReplay)
        }
        let numberedSteps = description.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
        return "saved the \(recordingKind.rawValue) replay \"\(description.name)\": \(numberedSteps). read the steps back in a few words, and say a text box is open for what she should say at the end (they can skip it)."
    }

    /// Changes a saved replay's name, kind, steps or closing line.
    private static func editReplay(_ arguments: [String: Any]) -> String {
        let store = DottieSmartReplayStore.shared
        guard var replay = arguments.dottieString("name").flatMap(store.replay(named:)) else {
            return "no smart replay matches that. call smart_replays list."
        }
        var changes: [String] = []
        if let newName = arguments.dottieString("new_name") {
            replay.name = newName
            changes.append("named it \"\(newName)\"")
        }
        if let kindName = arguments.dottieString("kind"), let newKind = DottieSmartReplay.Kind(rawValue: kindName) {
            replay.kind = newKind
            changes.append("made it a \(newKind.rawValue) replay")
        }
        if let newSteps = arguments["steps"] as? [String], !newSteps.isEmpty {
            replay.steps = newSteps
            changes.append("steps now: " + newSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " "))
        }
        if let closingMessage = arguments["closing_message"] as? String {
            replay.closingMessage = closingMessage
            changes.append(closingMessage.trimmingCharacters(in: .whitespaces).isEmpty ? "removed the closing line" : "closing line: \"\(closingMessage)\"")
        }
        guard !changes.isEmpty else { return "nothing to change was given." }
        store.save(replay)
        return "changed \"\(replay.name)\": " + changes.joined(separator: "; ") + ". read the change back in a few words."
    }
}
