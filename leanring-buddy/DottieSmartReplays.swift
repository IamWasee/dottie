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
        try? replayData.write(to: fileURL(for: cleanedReplay.id), options: .atomic)
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
/// turns them into steps by meaning when they're done.
@MainActor
final class DottieSmartReplayRecorder {
    static let shared = DottieSmartReplayRecorder()

    private(set) var isRecording = false
    private(set) var recordingKind: DottieSmartReplay.Kind = .smart
    private var eventMonitors: [Any] = []
    private var appActivationObserver: NSObjectProtocol?
    /// What the user did, one line per action, in order.
    private var actionLines: [String] = []
    private var typedTextBuffer = ""
    private var didTypeIntoPasswordField = false
    private var lastPlaceLine: String?
    private static let describingModel = "gemini-3.6-flash"
    private static let maximumActionLines = 200

    func start(kind: DottieSmartReplay.Kind) -> Bool {
        guard !isRecording else { return false }
        guard AXIsProcessTrusted() else { return false }
        recordingKind = kind
        actionLines = []
        typedTextBuffer = ""
        didTypeIntoPasswordField = false
        lastPlaceLine = nil
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
        notePlaceIfChanged()
        return true
    }

    /// Ends the recording. The raw actions, or nil when nothing was done.
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
        isRecording = false
        let recordedActionLines = actionLines
        actionLines = []
        let hasAnyAction = recordedActionLines.contains { !$0.hasPrefix("[in ") }
        return hasAnyAction ? recordedActionLines : nil
    }

    private var isDottieInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func append(_ actionLine: String) {
        guard actionLines.count < Self.maximumActionLines else { return }
        actionLines.append(actionLine)
    }

    /// "[in Safari: instagram.com]", added when the app or site changes.
    private func notePlaceIfChanged() {
        guard !isDottieInFront else { return }
        let context = DottieReplayContext.current()
        let placeText = [context.appName, context.siteHost ?? context.windowTitle.map { String($0.prefix(60)) }]
            .compactMap { $0 }
            .joined(separator: ": ")
        let placeLine = "[in \(placeText)]"
        guard placeLine != lastPlaceLine else { return }
        lastPlaceLine = placeLine
        append(placeLine)
    }

    private func flushTypedText() {
        if didTypeIntoPasswordField {
            append("typed a password (not saved)")
            didTypeIntoPasswordField = false
        }
        guard !typedTextBuffer.isEmpty else { return }
        append("typed \"\(typedTextBuffer)\"")
        typedTextBuffer = ""
    }

    private func noteClick(isRightClick: Bool) {
        guard !isDottieInFront else { return }
        flushTypedText()
        notePlaceIfChanged()
        append("\(isRightClick ? "right-clicked" : "clicked") \(Self.describeElementUnderPointer())")
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
            append("pressed \((modifierNames + [keyCharacters.uppercased()]).joined(separator: "+"))")
            notePlaceIfChanged()
            return
        }
        switch event.keyCode {
        case 36, 76:
            flushTypedText()
            append("pressed return")
        case 48:
            flushTypedText()
            append("pressed tab")
        case 53:
            flushTypedText()
            append("pressed escape")
        case 51:
            if typedTextBuffer.isEmpty {
                append("pressed delete")
            } else {
                typedTextBuffer.removeLast()
            }
        case 123, 124, 125, 126:
            flushTypedText()
            append("pressed the \(["left", "right", "down", "up"][Int(event.keyCode) - 123]) arrow")
        default:
            // Passwords are never written down, only that one was typed.
            if Self.isPasswordFieldFocused() {
                didTypeIntoPasswordField = true
            } else if let typedCharacters = event.characters, !typedCharacters.isEmpty {
                typedTextBuffer += typedCharacters
            }
        }
    }

    private static func isPasswordFieldFocused() -> Bool {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return false }
        let focusedElement = focusedValue as! AXUIElement
        return DottieAX.string(focusedElement, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
    }

    /// "the button \"Search\"", from Accessibility, or where in the window
    /// the click was when the thing has no name.
    private static func describeElementUnderPointer() -> String {
        let axPoint = DottieAX.axPoint(fromAppKit: NSEvent.mouseLocation)
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(axPoint.x), Float(axPoint.y), &hitElement) == .success,
              let hitElement else {
            return "somewhere Dottie couldn't read"
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
            return "the \(role) \"\(label.prefix(80))\""
        }
        if let window = DottieAX.enclosingWindow(of: hitElement), let windowFrame = DottieAX.axFrame(window), windowFrame.width > 0, windowFrame.height > 0 {
            let percentAcross = Int((axPoint.x - windowFrame.minX) / windowFrame.width * 100)
            let percentDown = Int((axPoint.y - windowFrame.minY) / windowFrame.height * 100)
            return "an unnamed \(role) about \(percentAcross)% across and \(percentDown)% down the window"
        }
        return "an unnamed \(role)"
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
}
