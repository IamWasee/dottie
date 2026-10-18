//
//  DottieEveryday.swift
//  leanring-buddy
//
//  The everyday pack: small things people do all day. The type-to-ask bar
//  (a shortcut that opens the notch's text box from any app), "fix this"
//  on any selected text, watches ("tell me when this download finishes"),
//  focus mode and folder cleanup. Each lives in its own file; this one
//  wires them to the rest of the app, shows their state in the notch and
//  gives Dottie's voice their tools (EverydayTools).
//

import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class DottieEveryday {
    static let shared = DottieEveryday()

    private(set) weak var companionManager: CompanionManager?
    let shortcuts = DottieGlobalShortcuts()
    let typeBar = DottieTypeBar()
    let watches = DottieWatches()
    let focus = DottieFocus()
    let cleanup = DottieFolderCleanup()

    /// At most this many watch / focus rows in the notch's hover peek.
    private static let maximumStatusLineCount = 3

    var notchPresenter: NotchPresenter? { companionManager?.notchPresenter }

    var personality: DottiePersonality {
        companionManager?.selectedPersonality ?? .saved
    }

    /// Called once from CompanionManager when the notch is set up.
    func attach(to companionManager: CompanionManager) {
        guard self.companionManager == nil else { return }
        self.companionManager = companionManager
        let notchPresenter = companionManager.notchPresenter

        notchPresenter.onStopStatusLine = { [weak self] statusLineID in
            self?.stopStatusLine(statusLineID)
        }
        typeBar.attach(to: notchPresenter)

        let shortcutMonitor = companionManager.globalPushToTalkShortcutMonitor
        shortcuts.clashCheck = { [weak shortcutMonitor] hotkey in
            guard let shortcutMonitor else { return nil }
            if hotkey == shortcutMonitor.talkHotkey { return "That's already the shortcut for talking to Dottie." }
            if hotkey == shortcutMonitor.dictationHotkey { return "That's already the dictation shortcut." }
            return nil
        }
        shortcuts.onAction = { [weak self] action in
            switch action {
            case .askBar:
                self?.toggleAskBar()
            case .fixText:
                Task { _ = await DottieFixText.run(style: .fixGrammar, fromShortcut: true) }
            }
        }
        shortcuts.start()

        watches.onChange = { [weak self] in self?.refreshStatusLines() }
        focus.onChange = { [weak self] in self?.refreshStatusLines() }
        focus.restoreSessionIfRunning()
        refreshStatusLines()
    }

    // MARK: - Type-to-ask bar

    /// Opens the notch's text box (or closes it if it's open). With the
    /// notch turned off, Home's composer takes its place.
    func toggleAskBar() {
        guard let companionManager else { return }
        let notchPresenter = companionManager.notchPresenter
        if notchPresenter.surface == .textInput {
            notchPresenter.cancelTextInput()
            return
        }
        guard companionManager.isNotchEnabled else {
            companionManager.openHomeWindow()
            return
        }
        typeBar.resetHistoryPosition()
        notchPresenter.openTextInput()
    }

    // MARK: - Notch state

    func refreshStatusLines() {
        guard let notchPresenter else { return }
        var lines: [NotchStatusLine] = []
        if let focusLine = focus.statusLine {
            lines.append(focusLine)
        }
        let watchLines = watches.statusLines
        let roomForWatches = Self.maximumStatusLineCount - lines.count
        if watchLines.count > roomForWatches {
            lines.append(contentsOf: watchLines.prefix(max(0, roomForWatches - 1)))
            let hiddenCount = watchLines.count - max(0, roomForWatches - 1)
            lines.append(NotchStatusLine(id: "watch:all", symbolName: "eye.fill", text: "\(hiddenCount) more things I'm watching"))
        } else {
            lines.append(contentsOf: watchLines)
        }
        if notchPresenter.statusLines != lines {
            notchPresenter.statusLines = lines
        }
        let badgeText = focus.compactBadgeText
        if notchPresenter.compactBadgeText != badgeText {
            notchPresenter.compactBadgeText = badgeText
        }
    }

    private func stopStatusLine(_ statusLineID: String) {
        if statusLineID == DottieFocus.statusLineID {
            focus.stop(reason: .stoppedByUser)
        } else if statusLineID == "watch:all" {
            _ = watches.stop(matching: "all")
        } else if statusLineID.hasPrefix("watch:"), let watchID = UUID(uuidString: String(statusLineID.dropFirst(6))) {
            watches.stop(id: watchID)
        }
        refreshStatusLines()
    }

    // MARK: - Telling the user

    /// A card in the notch, and optionally a sound, a macOS notification
    /// and a Telegram message to the paired phone.
    func tell(
        title: String,
        text: String,
        sound: NSSound.Name? = nil,
        notification: Bool = false,
        phone: Bool = false,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        notchPresenter?.showCard(title: title, text: text, actionLabel: actionLabel, action: action)
        if let sound {
            NSSound(named: sound)?.play()
        }
        if notification {
            postNotification(title: title, body: text)
        }
        if phone, let phoneBridge = companionManager?.phoneBridge, phoneBridge.pairedChatID != nil {
            Task { await phoneBridge.send("\(title): \(text)") }
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.count > 240 ? String(body.prefix(239)) + "…" : body
        content.sound = nil
        let request = UNNotificationRequest(identifier: "dottie-everyday-\(UUID().uuidString)", content: content, trigger: nil)
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { isGranted, _ in
            guard isGranted else { return }
            notificationCenter.add(request)
        }
    }
}

// MARK: - Type-to-ask bar

/// The notch's text box as a Spotlight-style bar: opened from any app by a
/// shortcut (DottieGlobalShortcuts), ↑ and ↓ step through what was asked
/// before, and the answer shows as text unless the user wants it read out.
@MainActor
final class DottieTypeBar {
    nonisolated static let speaksAnswersDefaultsKey = "dottieTypeBarSpeaksAnswers"
    private static let historyDefaultsKey = "dottieTypeBarHistory"
    private static let maximumHistoryCount = 50

    /// Off by default: typed questions get typed answers.
    static var speaksAnswers: Bool {
        UserDefaults.standard.bool(forKey: speaksAnswersDefaultsKey)
    }

    private(set) var history: [String] = UserDefaults.standard.stringArray(forKey: DottieTypeBar.historyDefaultsKey) ?? []
    /// Where ↑ has got to in the history; nil while typing something new.
    private var historyPosition: Int?
    /// What was in the box before ↑, so ↓ past the newest brings it back.
    private var unsentDraft = ""
    private weak var notchPresenter: NotchPresenter?
    private var keyMonitor: Any?

    func attach(to notchPresenter: NotchPresenter) {
        self.notchPresenter = notchPresenter
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.handleArrowKey(event) else { return event }
                return nil
            }
        }
    }

    func remember(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        history.removeAll { $0 == trimmedText }
        history.append(trimmedText)
        if history.count > Self.maximumHistoryCount {
            history.removeFirst(history.count - Self.maximumHistoryCount)
        }
        UserDefaults.standard.set(history, forKey: Self.historyDefaultsKey)
        resetHistoryPosition()
    }

    func resetHistoryPosition() {
        historyPosition = nil
        unsentDraft = ""
    }

    /// ↑ / ↓ in the notch's text box. Returns true when it used the key.
    private func handleArrowKey(_ event: NSEvent) -> Bool {
        guard let notchPresenter, notchPresenter.surface == .textInput,
              event.window?.styleMask.contains(.nonactivatingPanel) == true,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 126:
            guard !history.isEmpty else { return true }
            if historyPosition == nil {
                unsentDraft = notchPresenter.draftText
                historyPosition = history.count - 1
            } else if let position = historyPosition, position > 0 {
                historyPosition = position - 1
            }
            if let position = historyPosition {
                notchPresenter.draftText = history[position]
            }
            return true
        case 125:
            guard let position = historyPosition else { return true }
            if position + 1 < history.count {
                historyPosition = position + 1
                notchPresenter.draftText = history[position + 1]
            } else {
                historyPosition = nil
                notchPresenter.draftText = unsentDraft
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Voice tools

@MainActor
enum EverydayTools: DottieToolModule {
    static var tools: [DottieTool] {
        [fixTextTool, watchTool, focusTool, cleanFolderTool]
    }

    static var voicePromptSection: String {
        """
        everyday tools:
        - fix_text: "fix / shorten / translate / make this more formal…" about text the user selected. it rewrites the selection in place; afterwards just say a quick "done", don't read the text out.
        - watch: "tell me when…" something happens on screen (a download finishes, a page changes, it says Done, a game loads). it keeps watching after you stop talking and alerts them.
        - focus: focus sessions that block distracting apps and sites for some minutes.
        - clean_folder: tidy Downloads, Desktop or a folder they name. it shows a plan they approve; nothing happens until they tap Clean up. action undo puts the last cleanup back.
        """
    }

    private static var fixTextTool: DottieTool {
        DottieTool(
            name: "fix_text",
            description: "Rewrites the text the user has selected in the app in front, and puts the new text in its place (never in password fields). Use for fix spelling and grammar, shorter, longer, more formal, more casual, translate, or any custom rewrite of 'this'.",
            parameters: [
                "type": "OBJECT",
                "properties": [
                    "style": [
                        "type": "STRING",
                        "enum": DottieFixText.Style.allCases.map(\.rawValue),
                        "description": "What to do. fix_grammar fixes spelling and grammar only. custom uses instruction."
                    ],
                    "language": ["type": "STRING", "description": "For translate: the language to translate into."],
                    "instruction": ["type": "STRING", "description": "For custom: what to do, in the user's words."]
                ],
                "required": ["style"]
            ],
            audiences: [.voice]
        ) { arguments in
            let style = arguments.dottieString("style").flatMap(DottieFixText.Style.init(rawValue:)) ?? .fixGrammar
            return await DottieFixText.run(
                style: style,
                language: arguments.dottieString("language"),
                instruction: arguments.dottieString("instruction"),
                fromShortcut: false
            )
        }
    }

    private static var watchTool: DottieTool {
        DottieTool(
            name: "watch",
            description: "Watches the screen in the background and alerts the user (notch, sound, notification, phone) when something happens. Pick the cheapest kind: download_finishes for downloads, text_appears / text_disappears when they name words on screen, changes for 'when this page changes', stops_changing for 'when it's done loading', looks_like only for visual things words can't catch.",
            parameters: [
                "type": "OBJECT",
                "properties": [
                    "action": ["type": "STRING", "enum": ["start", "list", "stop"]],
                    "what": ["type": "STRING", "description": "For start: what they're waiting for, in their words (\"the download finishes\")."],
                    "kind": [
                        "type": "STRING",
                        "enum": DottieWatches.Kind.allCases.map(\.rawValue),
                        "description": "For start: how to tell it happened."
                    ],
                    "text": ["type": "STRING", "description": "For text_appears / text_disappears: the words to look for. For looks_like: what it should look like."],
                    "target": [
                        "type": "STRING",
                        "enum": ["front_window", "app", "screen"],
                        "description": "What to watch. Default front_window (the window they're looking at)."
                    ],
                    "app_name": ["type": "STRING", "description": "For target app: the app's name."],
                    "minutes": ["type": "NUMBER", "description": "Give up after this many minutes. Default 60, at most 480."],
                    "watch": ["type": "STRING", "description": "For stop: which watch (words from what it watches), or all."]
                ],
                "required": ["action"]
            ],
            audiences: [.voice]
        ) { arguments in
            let watches = DottieEveryday.shared.watches
            switch arguments.dottieString("action") ?? "list" {
            case "start":
                return await watches.start(
                    what: arguments.dottieString("what") ?? arguments.dottieString("text") ?? "something changes",
                    kind: arguments.dottieString("kind").flatMap(DottieWatches.Kind.init(rawValue:)) ?? .changes,
                    text: arguments.dottieString("text"),
                    target: arguments.dottieString("target") ?? "front_window",
                    appName: arguments.dottieString("app_name"),
                    minutes: arguments.dottieNumber("minutes") ?? 60
                )
            case "stop":
                return watches.stop(matching: arguments.dottieString("watch") ?? "all")
            default:
                return watches.listText()
            }
        }
    }

    private static var focusTool: DottieTool {
        DottieTool(
            name: "focus",
            description: "Focus mode: for some minutes, distracting apps get hidden and distracting sites get closed, with a cheeky line in the notch. Ends with a summary.",
            parameters: [
                "type": "OBJECT",
                "properties": [
                    "action": ["type": "STRING", "enum": ["start", "stop", "status"]],
                    "minutes": ["type": "NUMBER", "description": "For start: how long. Default from Settings (25)."],
                    "block": [
                        "type": "ARRAY",
                        "items": ["type": "STRING"],
                        "description": "For start: only these apps or sites (\"YouTube\", \"Steam\", \"reddit.com\"). Leave out to use their saved list."
                    ]
                ],
                "required": ["action"]
            ],
            audiences: [.voice]
        ) { arguments in
            let focus = DottieEveryday.shared.focus
            switch arguments.dottieString("action") ?? "status" {
            case "start":
                let blockList = (arguments["block"] as? [Any])?.compactMap { $0 as? String } ?? []
                return focus.start(minutes: arguments.dottieNumber("minutes"), block: blockList)
            case "stop":
                return focus.stop(reason: .stoppedByUser)
            default:
                return focus.statusText()
            }
        }
    }

    private static var cleanFolderTool: DottieTool {
        DottieTool(
            name: "clean_folder",
            description: "Tidies a folder: sorts files into folders by type (or month), finds duplicates and big old files, gives screenshots readable names. Shows the plan with checkboxes; nothing changes until the user taps Clean up. Removed files go to the Trash. action undo puts the last cleanup back.",
            parameters: [
                "type": "OBJECT",
                "properties": [
                    "action": ["type": "STRING", "enum": ["plan", "undo"], "description": "Default plan."],
                    "folder": ["type": "STRING", "description": "downloads (default), desktop, documents, or a folder's name or path."],
                    "group_by": ["type": "STRING", "enum": ["type", "month"], "description": "How to sort into folders. Default type."]
                ]
            ],
            audiences: [.voice]
        ) { arguments in
            let cleanup = DottieEveryday.shared.cleanup
            if arguments.dottieString("action") == "undo" {
                return cleanup.undoLastCleanup()
            }
            return await cleanup.planAndShow(
                folderName: arguments.dottieString("folder") ?? "downloads",
                groupsByMonth: arguments.dottieString("group_by") == "month"
            )
        }
    }
}
