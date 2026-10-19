//
//  DottieSelfKnowledge.swift
//  leanring-buddy
//
//  Dottie knowing herself, and helping people use her: "what can you do?",
//  "what version are you?", "how do I turn on meeting mode?", "which
//  permissions are you missing?", "open your voice settings", "walk me
//  through setting up the phone".
//
//  One tool, about_me, answers all of it on the Mac with no model call:
//  - features: a plain-English map of what she can do and where each thing
//    lives (Home pages, Settings sections, the notch, shortcuts), plus every
//    tool other features add through DottieToolRegistry, so new features
//    show up without editing this file.
//  - status: live facts read from the app (version, update, permissions,
//    voice, helpers, phone, screen journal, …).
//  - troubleshoot: the same facts turned into likely problems and fixes.
//  - how_to: the feature entries that best match a question (keywords).
//  - open: opens a Home page or Settings section (DottieHomeNavigator).
//  - guide: a step-by-step walkthrough of her own app on the existing guide
//    (DottieGuide.startScripted). Each step opens the right page, finds
//    the control through the window's own accessibility tree (it's her own
//    app, so no screenshot or vision call), and points at it while she
//    says one short line.
//  - ask_permission: starts macOS's prompt through DottiePermissions.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Navigation

/// Lets Dottie open a Home page or Settings section herself. Home's views
/// watch these and clear them once handled. @Published hands the current
/// value to new subscribers, so a request made before the Home window
/// exists still lands when it appears.
@MainActor
final class DottieHomeNavigator: ObservableObject {
    static let shared = DottieHomeNavigator()

    @Published var requestedSection: HomeSpaceRootView.HomeSection?
    /// A Settings section's title, like "Voice" (the id HomeSettingsView
    /// gives each section).
    @Published var requestedSettingsGroup: String?
}

// MARK: - The tool

@MainActor
enum DottieSelfKnowledge: DottieToolModule {
    /// Set by CompanionManager.start(), for live state and the guide.
    static weak var companionManager: CompanionManager?

    private static let tourOfferedDefaultsKey = "dottieSelfTourOffered"

    static var appVersion: String { DottieUpdater.currentVersion }

    static var tools: [DottieTool] {
        [aboutMeTool(for: .voice), aboutMeTool(for: .helpers)]
    }

    static var voicePromptSection: String {
        let pageNames = HomeSpaceRootView.HomeSection.allCases.map { $0.rawValue.lowercased() }.joined(separator: ", ")
        var section = """
        about yourself: you're dottie \(appVersion), a mac companion who lives in the notch and the menu bar, with a home window (\(pageNames)). never guess about yourself, your settings or your state: call about_me. features is what you can do; how_to answers "how do i… in dottie"; status is live facts (version, update, permissions, voice, helpers, phone); troubleshoot when one of your own things fails or seems off (it reuses the self-check); open shows a home page or settings section; guide walks them through it on screen step by step (you point, they click; next and stop work like any guide); ask_permission and fix start the fix troubleshoot names. status names the claude account helpers use; switch_claude_account signs it out and starts a sign-in to pick another.
        helping with dottie: answer a "how do i…" in one sentence, then offer to show them (guide). when one of your own things fails (a missing permission, helpers not ready, phone not paired, an update waiting), say so plainly and offer the fix. asked what you can do: name three or four things in a sentence or two and offer a quick tour (guide with "tour").
        """
        if isNewUser {
            section += "\nthis user is new to you: after your first answer, offer a quick tour of what you can do in a few words."
        }
        return section
    }

    static var helperPromptSection: String {
        "about_me tells you what Dottie (the app you run in) can do, where each setting lives, and her live status."
    }

    /// Nobody has had the tour offered yet and there's barely any history.
    private static var isNewUser: Bool {
        if UserDefaults.standard.bool(forKey: tourOfferedDefaultsKey) { return false }
        return (companionManager?.conversationStore.entries.count ?? 0) < 3
    }

    private enum Action: String, CaseIterable {
        case features, status, troubleshoot, how_to, open, guide, ask_permission, fix, switch_claude_account
    }

    /// Helpers work in the background, so they don't get the on-screen
    /// actions.
    private static func actions(for audience: DottieTool.Audience) -> [Action] {
        audience == .voice ? Action.allCases : [.features, .status, .troubleshoot, .how_to]
    }

    private static func aboutMeTool(for audience: DottieTool.Audience) -> DottieTool {
        let actionNames = actions(for: audience).map(\.rawValue)
        let description = audience == .voice
            ? "Dottie's knowledge of herself: her features, where every setting lives in her app, and her live state. Call it instead of guessing whenever the user asks what you can do, how to do something in Dottie, where a setting is, what version you are, what's missing or not working, or wants to be shown around or walked through your app. features: everything you can do and where. how_to: the best matching features for a question. status: live facts. troubleshoot: likely problems with their fixes (uses the self-check). open: open a Home page or Settings section. guide: walk them through a topic in your app step by step on screen. ask_permission: start macOS's permission prompt. fix: run a fix troubleshoot named (its id). switch_claude_account: sign Claude out and start a new sign-in so they can pick which Claude account helpers use (status says which one is in use now)."
            : "What Dottie (the app you run in) can do and where each thing lives in her app (features, how_to), her live state (status), and likely problems with their fixes (troubleshoot)."
        return DottieTool(
            name: "about_me",
            description: description,
            parameters: [
                "type": "OBJECT",
                "properties": [
                    "action": [
                        "type": "STRING",
                        "enum": actionNames,
                        "description": "What to look up or do."
                    ],
                    "about": [
                        "type": "STRING",
                        "description": "open: the place, like 'voice settings', 'phone' or 'meetings'. guide: the topic, like 'phone', 'settings', 'meeting mode' or 'tour'. how_to and troubleshoot: the user's question. ask_permission: the permission, like 'screen recording', or 'all'. fix: the id troubleshoot gave, like 'runtime'."
                    ]
                ],
                "required": ["action"]
            ],
            audiences: [audience],
            run: { arguments in
                await DottieSelfKnowledge.run(arguments: arguments, audience: audience)
            }
        )
    }

    private static func run(arguments: [String: Any], audience: DottieTool.Audience) async -> String {
        guard let action = arguments.dottieString("action").flatMap({ Action(rawValue: $0.lowercased()) }),
              actions(for: audience).contains(action) else {
            return "say which action: " + actions(for: audience).map(\.rawValue).joined(separator: ", ") + "."
        }
        let about = arguments.dottieString("about") ?? ""
        if audience == .voice {
            // She's talked about herself now; no need to keep offering a tour.
            UserDefaults.standard.set(true, forKey: tourOfferedDefaultsKey)
        }
        switch action {
        case .features: return featuresText()
        case .status: return await statusText()
        case .troubleshoot: return await troubleshootText(question: about, mayRunSelfCheck: audience == .voice)
        case .how_to: return howToText(question: about)
        case .open: return openPlace(named: about)
        case .guide: return startWalkthrough(topic: about)
        case .ask_permission: return await askPermission(named: about)
        case .fix: return await applySelfCheckFix(named: about)
        case .switch_claude_account: return switchClaudeAccount()
        }
    }

    /// Signs Claude out, starts a new sign-in and shows its panel in
    /// Settings, where the user opens the link in a private window.
    private static func switchClaudeAccount() -> String {
        let mausBot = DottieMausBot.shared
        guard mausBot.isSetUp, mausBot.claudeState != .notInstalled else {
            return "Claude isn't set up for helpers yet, so there's no account to switch. offer to show Settings → Helpers: Claude via MausBot (Set up)."
        }
        let previousEmail = mausBot.claudeAccount?.email
        mausBot.switchClaudeAccount()
        show(.settings("Helpers: Claude via MausBot"))
        let previousAccountText = previousEmail.map { " (was \($0))" } ?? ""
        return "signing Claude out\(previousAccountText) and starting a new sign-in. Settings → Helpers is open: tell them in one line to click Open in a private window there and pick the account. helpers use the free Gemini backup until it's done."
    }
}

// MARK: - Places in the app

extension DottieSelfKnowledge {
    /// A Home page, or a section of Settings.
    struct Place {
        let section: HomeSpaceRootView.HomeSection
        var settingsGroup: String? = nil

        var name: String {
            settingsGroup.map { "Settings → \($0)" } ?? section.rawValue
        }

        static func settings(_ group: String) -> Place {
            Place(section: .settings, settingsGroup: group)
        }
    }

    /// A section of Settings: its title (HomeSettingsView's settingsGroup
    /// title, which is also its id), the control a walkthrough points at,
    /// what it's for, and other words for it.
    struct SettingsSection {
        let title: String
        let target: String
        let line: String
        let aliases: [String]

        init(_ title: String, _ target: String, _ line: String, _ aliases: [String]) {
            self.title = title
            self.target = target
            self.line = line
            self.aliases = aliases
        }
    }

    /// Settings' sections in order.
    fileprivate static let settingsSections: [SettingsSection] = [
        SettingsSection("Permissions", "Allow everything", "Permissions: what I'm allowed to use on your Mac. Allow everything asks for them all in a row.",
         ["permission", "access", "privacy", "allow"]),
        SettingsSection("Updates", "Check for updates automatically", "Updates: check for a new version and install it right here.",
         ["update", "version", "upgrade"]),
        SettingsSection("Helpers: Claude via MausBot", "Run helpers on", "Helpers: whether helpers run on your Claude plan through MausBot, with Gemini as the backup.",
         ["mausbot", "claude", "helper engine", "engine", "backup", "helpers settings"]),
        SettingsSection("Check everything", "Check everything", "Check everything: one button that tests every part I need and says what's wrong.",
         ["self check", "check", "test", "diagnose", "health"]),
        SettingsSection("Instant replays", "Instant replays", "Instant replays: screen jobs I remember and redo straight away.",
         ["replay", "replays", "remembered jobs"]),
        SettingsSection("Voice", "Dottie's voice", "Voice: how I sound and my personality, including one you make yourself.",
         ["voices", "personality", "sound", "accent", "make your own"]),
        SettingsSection("Shortcuts", "Talk to Dottie", "Shortcuts: the keys to talk, dictate, type to me and fix selected text.",
         ["shortcut", "hotkey", "hotkeys", "keys", "keyboard shortcut", "circle", "type to ask", "fix text"]),
        SettingsSection("Everyday", "Focus mode", "Everyday: focus mode, what it blocks, and undoing the last folder cleanup.",
         ["focus", "focus mode", "block", "blocked", "cleanup", "clean up"]),
        SettingsSection("Appearance", "Show Dottie in the notch", "Appearance: the notch, my blue cursor and its shape, and notifications.",
         ["notch", "cursor", "look", "notifications", "notification"]),
        SettingsSection("Dictation", "Words to spell your way", "Dictation: hold to type with your voice, languages, and words to spell your way.",
         ["dictate", "language", "languages", "words", "spelling"]),
        SettingsSection("Using your Mac", "Let Dots click and type without asking", "Using your Mac: whether Dots ask before they click and type, and the tips I learned.",
         ["computer use", "driver", "tips", "clicking", "use my mac"]),
        SettingsSection("Connection", "Server", "Connection: the server that talks to Gemini for me.",
         ["server", "worker", "secret", "internet"]),
        SettingsSection("History", "saved exchanges", "History: clear our saved conversation.",
         ["clear history", "clear conversation", "clear chat"])
    ]

    /// One line per Home page for the tour. Keyed rather than switched on,
    /// so a page another feature adds still gets a line ("This is …").
    fileprivate static let pageLines: [HomeSpaceRootView.HomeSection: String] = [
        .conversation: "Conversation: everything we've said, and a box to type to me.",
        .clickys: "Dots: your background helpers and what they made.",
        .projects: "Projects: everything the Dots build, each in its own folder.",
        .pictures: "Pictures: things I remember by how they look.",
        .smartHome: "Smart Home: your TVs, lights and Home Assistant.",
        .skills: "Skills: instructions your Dots can use.",
        .tools: "Tools: connect your apps and install command-line tools for me and the helpers.",
        .brain: "Brain: what I remember about you, and the timeline of what we did.",
        .meetings: "Meetings: meeting mode and your saved notes.",
        .phone: "Phone: text me from Telegram.",
        .profile: "Profile: my level, streak, unlocks and 24/7 jobs.",
        .settings: "Settings: permissions, voice, shortcuts and more."
    ]

    fileprivate static let pageAliases: [HomeSpaceRootView.HomeSection: [String]] = [
        .conversation: ["chat", "chats", "messages", "home"],
        .clickys: ["dot", "helper", "helpers", "agents", "routines", "routine"],
        .projects: ["project"],
        .pictures: ["picture", "photos", "images", "image library"],
        .smartHome: ["lights", "tv", "tvs", "hue", "home assistant", "devices"],
        .skills: ["skill"],
        .tools: ["apps", "connected apps", "mcp", "integrations", "command line tools", "homebrew", "cli"],
        .brain: ["memory", "memories", "screen journal", "journal", "timeline", "second brain"],
        .meetings: ["meeting", "meeting mode", "notes", "meeting notes"],
        .phone: ["telegram", "phone bridge", "texting", "bot"],
        .profile: ["level", "levels", "xp", "streak", "unlocks", "24 7 jobs", "notch effect"],
        .settings: ["preferences", "options"]
    ]

    static var settingsGroupTitles: [String] { settingsSections.map(\.title) }

    /// Matches a spoken place ("voice settings", "the phone page") to a
    /// Home page or Settings section.
    static func place(named spokenName: String) -> Place? {
        let query = normalized(spokenName)
        guard !query.isEmpty else { return nil }

        var bestPage: (place: Place, score: Double)?
        for section in HomeSpaceRootView.HomeSection.allCases {
            let names = [section.rawValue] + (pageAliases[section] ?? [])
            let score = names.map { matchScore(query: query, name: $0) }.max() ?? 0
            if score > 0, score > (bestPage?.score ?? 0) {
                bestPage = (Place(section: section), score)
            }
        }
        var bestGroup: (place: Place, score: Double)?
        for settingsSection in settingsSections {
            let names = [settingsSection.title] + settingsSection.aliases
            let score = names.map { matchScore(query: query, name: $0) }.max() ?? 0
            if score > 0, score > (bestGroup?.score ?? 0) {
                bestGroup = (Place.settings(settingsSection.title), score)
            }
        }
        if let bestGroup, bestPage == nil || bestPage?.place.section == .settings || bestGroup.score >= (bestPage?.score ?? 0) {
            return bestGroup.place
        }
        return bestPage?.place
    }

    private static func matchScore(query: String, name: String) -> Double {
        let normalizedName = normalized(name)
        guard !normalizedName.isEmpty else { return 0 }
        if query == normalizedName { return 10 }
        if " \(query) ".contains(" \(normalizedName) ") {
            // "voice settings" names Voice more than Settings.
            return 5 + Double(normalizedName.count) / 100
        }
        if normalizedName.count >= 4, " \(normalizedName) ".contains(" \(query) ") { return 3 }
        return 0
    }

    static var placeNames: [String] {
        HomeSpaceRootView.HomeSection.allCases.map(\.rawValue) + settingsGroupTitles.map { "Settings → \($0)" }
    }

    private static func openPlace(named spokenName: String) -> String {
        guard let place = place(named: spokenName) else {
            return "no place called \"\(spokenName)\" in Dottie. places: " + placeNames.joined(separator: ", ") + "."
        }
        show(place)
        return "opened \(place.name) in Dottie's Home window. tell them in a few words what's there; point at something only if they ask."
    }

    /// Opens Home on this page (and scrolls Settings to the section).
    static func show(_ place: Place) {
        companionManager?.openHomeWindow()
        DottieHomeNavigator.shared.requestedSection = place.section
        if let settingsGroup = place.settingsGroup {
            DottieHomeNavigator.shared.requestedSettingsGroup = settingsGroup
        }
    }

    static var homeWindow: NSWindow? {
        NSApp.windows.first { $0.contentView is NSHostingView<HomeSpaceRootView> }
    }
}

// MARK: - The feature map

extension DottieSelfKnowledge {
    /// Something to point at in a walkthrough.
    enum Target {
        /// A control or text with this visible text; the first that's found.
        case text([String])
        /// A page's icon in Home's left rail.
        case page(HomeSpaceRootView.HomeSection)
    }

    /// One step of a walkthrough of Dottie's own app.
    struct WalkStep {
        enum Wait {
            /// Move on once it's said.
            case none
            /// The user clicks the target.
            case click
            /// The user says next.
            case next
        }

        /// The page to open first; the feature's place when nil.
        var place: Place? = nil
        var target: Target? = nil
        let say: String
        var wait: Wait = .next
        /// Skipped when this is false (already set up, already on).
        var isNeeded: (@MainActor () -> Bool)? = nil
        /// How long to wait for isNeeded to come true (a connection that
        /// takes a moment after the last click).
        var secondsToWaitForNeed: Double = 0
    }

    struct Feature {
        /// Short name for guide and how_to, like "phone".
        let id: String
        let title: String
        let keywords: [String]
        /// What it does, plain and short.
        let summary: String
        /// Where it lives in the app.
        let whereToFind: String
        var place: Place? = nil
        var steps: [WalkStep] = []
        var doneLine = "That's it! Ask me if you get stuck."
    }

    /// Everything Dottie can do, read from the real app (Home pages,
    /// Settings sections, the notch, CompanionManager's tools). Built on
    /// each call so shortcut names and state are current.
    static func features() -> [Feature] {
        let talkKeys = companionManager?.globalPushToTalkShortcutMonitor.talkHotkey.displayText ?? ClickyHotkey.defaultTalk.displayText
        let dictateKeys = companionManager?.globalPushToTalkShortcutMonitor.dictationHotkey.displayText ?? ClickyHotkey.defaultDictation.displayText
        let personalityNames = DottiePersonality.presets.map(\.displayName).joined(separator: ", ")
        let askBarKeys = DottieEveryday.shared.shortcuts.hotkey(for: .askBar)?.displayText
        let askBarText = askBarKeys.map { "Press \($0)" } ?? "Set a shortcut in Settings → Shortcuts, then press it"
        let fixTextKeys = DottieEveryday.shared.shortcuts.hotkey(for: .fixText)?.displayText
        let askBarKeyName: String = askBarKeys ?? "a shortcut you pick"
        let fixTextKeyName: String = fixTextKeys ?? "a shortcut you pick (off until you choose one)"
        let fixTextKeyNote: String = fixTextKeys.map { " (\($0))" } ?? " (set one in Settings → Shortcuts)"

        let allFeatures: [Feature] = [
            Feature(
                id: "tour",
                title: "A tour of Dottie",
                keywords: ["tour", "show me around", "what can you do", "everything", "overview", "rundown", "get started", "home window"],
                summary: "A quick look at each page of my Home window.",
                whereToFind: "Home window (click my menu bar icon, then Home, or hover the notch and click open).",
                place: Place(section: .conversation),
                steps: HomeSpaceRootView.HomeSection.allCases.map { section in
                    WalkStep(
                        place: Place(section: section),
                        target: .page(section),
                        say: pageLines[section] ?? "This is \(section.rawValue).",
                        wait: .none
                    )
                },
                doneLine: "That's the tour! Ask me how to do anything, or say walk me through it."
            ),
            Feature(
                id: "talk",
                title: "Talking to me",
                keywords: ["talk", "speak", "push to talk", "ask", "hold", "listen", "hear", "voice"],
                summary: "Hold \(talkKeys) and talk; let go and I answer out loud. I see your screen while you hold it, point at things with my blue cursor, and remember our conversation.",
                whereToFind: "Anywhere. Change the shortcut in Settings → Shortcuts.",
                place: .settings("Shortcuts"),
                steps: [
                    WalkStep(target: .text(["Talk to Dottie"]), say: "This is your talk shortcut: \(talkKeys). Click it and press new keys to change it.")
                ]
            ),
            Feature(
                id: "type",
                title: "Typing to me",
                keywords: ["type", "typing", "type to ask", "ask bar", "option space", "write", "keyboard", "message", "paste", "drop", "picture"],
                summary: "\(askBarText) in any app to type a question under the notch (Enter sends, Esc closes, ↑ brings back what you asked before). Or hover the notch and click \"type to dottie\", or use the box at the bottom of Home → Conversation, where you can also paste or drop pictures.",
                whereToFind: "Any app with the type-to-ask shortcut, the notch, or Home → Conversation.",
                place: Place(section: .conversation),
                steps: [
                    WalkStep(target: .text(["Type to Dottie", "Say what it is"]), say: "Type to me here and press return. You can paste or drop a picture in too.")
                ]
            ),
            Feature(
                id: "circle",
                title: "Circle to ask",
                keywords: ["circle", "mark", "annotate", "ring", "draw around", "highlight"],
                summary: "While you hold the talk shortcut, move the cursor around something to circle it; I see exactly what you marked.",
                whereToFind: "Settings → Shortcuts (switch it on or off).",
                place: .settings("Shortcuts"),
                steps: [
                    WalkStep(target: .text(["Circle things with the cursor while you talk"]), say: "This switch turns circling on or off.", wait: .click)
                ]
            ),
            Feature(
                id: "dictation",
                title: "Dictation",
                keywords: ["dictate", "dictation", "speech to text", "type for me", "spelling", "words", "language", "transcribe"],
                summary: "Hold \(dictateKeys), talk and let go: I type the cleaned-up text wherever your cursor is, or put it on the clipboard. Add words to spell your way, pick a language, and I learn words you correct.",
                whereToFind: "Anywhere. Settings → Dictation for the options.",
                place: .settings("Dictation"),
                steps: [
                    WalkStep(target: .text(["to dictate"]), say: "This switch turns dictation on. Hold \(dictateKeys) to use it.", wait: .none),
                    WalkStep(target: .text(["Words to spell your way"]), say: "Add names and jargon here so I spell them your way.", wait: .none),
                    WalkStep(target: .text(["Detect the language automatically"]), say: "I follow your language on my own, or you can pin one here.", wait: .none),
                    WalkStep(target: .text(["Learn words I correct"]), say: "And when you fix a word after dictating, I learn it.", wait: .none)
                ]
            ),
            Feature(
                id: "learn",
                title: "Learning any app",
                keywords: ["how do i", "learn", "teach", "show me", "walk me through", "where is", "point", "guide", "tutorial"],
                summary: "Ask how to do something in any app: I point at it, or walk you through it one click at a time, waiting for your click before the next step. Ask for a tour and I explain each part of the window. Say next to move on and stop to end.",
                whereToFind: "Any app, by voice."
            ),
            Feature(
                id: "do",
                title: "Doing things for you",
                keywords: ["click", "do it", "for me", "open", "job", "task", "automate", "game", "play", "stop", "escape", "browser", "tabs"],
                summary: "Ask me to do it (\"open youtube and search lofi\"): I click, type and scroll step by step and tell you how it went. Jobs line up in order, and wait while your screen is locked. I can play games too. Press Escape or the stop button in the notch to stop me. A job that worked is saved as an instant replay, so next time I redo it straight away.",
                whereToFind: "Any app, by voice. The tips I learn from jobs are in Settings → Using your Mac.",
                place: .settings("Using your Mac")
            ),
            Feature(
                id: "draw",
                title: "Explaining with drawings",
                keywords: ["draw", "drawing", "explain", "math", "diagram", "graph", "board", "whiteboard", "equation"],
                summary: "For math or anything visual I draw on your screen, or on a board beside it, while I explain step by step. Say clear to wipe it.",
                whereToFind: "Any app, by voice."
            ),
            Feature(
                id: "helpers",
                title: "Helpers (Dots)",
                keywords: ["helper", "helpers", "dot", "dots", "agent", "background", "research", "website", "build", "code", "routine", "routines", "delegate", "team"],
                summary: "Helpers (Dots) work on their own in a folder on your Mac with a shell, files and the web: research, documents, code, whole websites. Ask me out loud or give one a task in Home → Dots. They tell you in the notch when they're done. They run on your Claude plan through MausBot when it's set up, with Gemini as the backup. Routines run tasks on a schedule, and a team splits a big job between several helpers.",
                whereToFind: "Home → Dots. Which engine they run on: Settings → Helpers: Claude via MausBot.",
                place: Place(section: .clickys),
                steps: [
                    WalkStep(target: .page(.clickys), say: "This is Dots, your background helpers.", wait: .none),
                    WalkStep(target: .text(["New helper", "New Dot"]), say: "Click New helper to make one, or just ask me out loud to hand something off.")
                ]
            ),
            Feature(
                id: "projects",
                title: "Projects",
                keywords: ["project", "projects", "folder", "files", "website", "continue", "work on"],
                summary: "Everything Dots build lives in a project: its own folder with the files and notes on what's done and what's left. Say \"work on the coffee site again\" and the work goes back into it.",
                whereToFind: "Home → Projects.",
                place: Place(section: .projects),
                steps: [WalkStep(target: .page(.projects), say: "Your projects are here. Open one to see its folder and notes.", wait: .none)]
            ),
            Feature(
                id: "skills",
                title: "Skills",
                keywords: ["skill", "skills", "instructions", "teach dots"],
                summary: "Skills are instructions your Dots can use when a task calls for them. Make one, add a skill folder, and choose which Dots use it.",
                whereToFind: "Home → Skills.",
                place: Place(section: .skills),
                steps: [
                    WalkStep(target: .page(.skills), say: "This is Skills.", wait: .none),
                    WalkStep(target: .text(["New skill", "Add a skill folder"]), say: "Click New skill to write one. Each Dot can switch skills on or off.")
                ]
            ),
            Feature(
                id: "pictures",
                title: "Pictures I remember",
                keywords: ["picture", "pictures", "photo", "image", "remember how it looks", "save picture"],
                summary: "Pictures I know by name and description, so \"grab the golden sword\" finds it on screen. Add your own, and I save some myself.",
                whereToFind: "Home → Pictures.",
                place: Place(section: .pictures),
                steps: [
                    WalkStep(target: .page(.pictures), say: "This is Pictures.", wait: .none),
                    WalkStep(target: .text(["Add a picture", "Choose a picture"]), say: "Add a picture here with a name and where it's from.")
                ]
            ),
            Feature(
                id: "brain",
                title: "Memory and my second brain",
                keywords: ["memory", "remember", "forget", "brain", "journal", "screen journal", "know about me", "folders", "what i was doing"],
                summary: "I remember our chats and what the helpers did. Home → Brain shows what I know about you (you can edit it), the latest memories, the timeline of what happened, the \"Remember what's on my screen\" switch, the folders my brain can use, and Forget everything.",
                whereToFind: "Home → Brain.",
                place: Place(section: .brain),
                steps: [
                    WalkStep(target: .text(["What Dottie knows about you"]), say: "This is what I know about you. Click Edit to change it.", wait: .none),
                    WalkStep(target: .text(["Timeline"]), say: "This timeline is what we did, day by day. Tap a moment to see it all.", wait: .none),
                    WalkStep(target: .text(["Remember what's on my screen"]), say: "This switch lets me note what's on your screen every few minutes. It's off unless you turn it on.", wait: .none),
                    WalkStep(target: .text(["Folders the brain can use"]), say: "Add folders here so my brain can search your files.", wait: .none),
                    WalkStep(target: .text(["Forget everything"]), say: "And this wipes every memory.", wait: .none)
                ]
            ),
            Feature(
                id: "meetings",
                title: "Meeting mode",
                keywords: ["meeting", "meetings", "meeting mode", "notes", "take notes", "transcript", "record", "call", "zoom", "action items"],
                summary: "Off until you turn it on. Click Start taking notes in Home → Meetings, or tell me \"take notes\". I listen to your mic and your Mac's audio, and when you stop I save notes with the decisions and action items. The audio itself is never kept.",
                whereToFind: "Home → Meetings, or by voice.",
                place: Place(section: .meetings),
                steps: [
                    WalkStep(
                        target: .text(["Start taking notes"]),
                        say: "Click Start taking notes when your meeting begins, or just tell me to take notes.",
                        isNeeded: { companionManager?.meetingRecorder.isRecording != true }
                    ),
                    WalkStep(
                        target: .text(["Stop and write notes"]),
                        say: "When it's over, click Stop and write notes, or tell me to stop.",
                        wait: .none
                    ),
                    WalkStep(target: .text(["Saved meetings"]), say: "Your notes show up here.", wait: .none)
                ]
            ),
            Feature(
                id: "phone",
                title: "Texting me from your phone",
                keywords: ["phone", "telegram", "text", "texting", "phone bridge", "bot", "botfather", "pair", "mobile"],
                summary: "Text me from your phone with Telegram: a helper called Phone does the job on this Mac and texts you back. Set up your own bot (about two minutes) and pair your phone with a code. The Mac has to be awake with me running.",
                whereToFind: "Home → Phone.",
                place: Place(section: .phone),
                steps: [
                    WalkStep(
                        target: .text(["Open BotFather"]),
                        say: "On your phone, open Telegram and message BotFather. This button opens it too.",
                        isNeeded: { companionManager?.phoneBridge.isConnected != true }
                    ),
                    WalkStep(
                        target: .text(["Bot token"]),
                        say: "Send BotFather slash newbot, pick a name and a username ending in bot, then paste the token it gives you here.",
                        isNeeded: { companionManager?.phoneBridge.isConnected != true }
                    ),
                    WalkStep(
                        target: .text(["Connect"]),
                        say: "Now click Connect.",
                        wait: .click,
                        isNeeded: { companionManager?.phoneBridge.isConnected != true }
                    ),
                    WalkStep(
                        target: .text(["send it this code"]),
                        say: "Open your bot in Telegram and send it this code. That pairs your phone.",
                        isNeeded: {
                            companionManager?.phoneBridge.isConnected == true && companionManager?.phoneBridge.pairedChatID == nil
                        },
                        secondsToWaitForNeed: 10
                    ),
                    WalkStep(
                        target: .text(["Send a test message"]),
                        say: "You're paired. Click Send a test message to try it.",
                        wait: .click,
                        isNeeded: { companionManager?.phoneBridge.pairedChatID != nil },
                        secondsToWaitForNeed: 4
                    )
                ],
                doneLine: "That's it. Once you're paired, text your bot a job anytime and I'll do it here."
            ),
            Feature(
                id: "smarthome",
                title: "Smart home",
                keywords: ["smart home", "tv", "television", "lights", "light", "hue", "home assistant", "apple home", "roku", "android tv", "camera", "thermostat"],
                summary: "I run your house: TVs (Android TV, Google TV, Fire TV, Roku, or any TV through a capture card), Philips Hue lights, Home Assistant devices, and Apple Home through your shortcuts. Add them in Home → Smart Home, then just ask.",
                whereToFind: "Home → Smart Home.",
                place: Place(section: .smartHome),
                steps: [
                    WalkStep(target: .page(.smartHome), say: "This is Smart Home.", wait: .none),
                    WalkStep(target: .text(["Find on your Wi-Fi", "Add a TV", "TVs"]), say: "Add your TV here.", wait: .none),
                    WalkStep(target: .text(["Philips Hue"]), say: "Hue lights connect here.", wait: .none),
                    WalkStep(target: .text(["Home Assistant"]), say: "And Home Assistant for everything else.", wait: .none)
                ]
            ),
            Feature(
                id: "mac",
                title: "Mac powers",
                keywords: ["calendar", "schedule", "event", "reminder", "reminders", "contact", "contacts", "applescript", "apple shortcuts", "music", "spotify", "volume", "dark mode", "screenshot", "browser", "tabs", "finder", "mail"],
                summary: "Ask and I act on your Mac directly: your calendar and reminders, contacts, music, volume, dark mode, opening apps, your Apple Shortcuts, real screenshots, and your browser's tabs and pages. Anything that sends, deletes or buys asks you first.",
                whereToFind: "By voice. Each needs its permission in Settings → Permissions.",
                place: .settings("Permissions")
            ),
            Feature(
                id: "tools",
                title: "Connected apps and tools",
                keywords: ["tools", "apps", "connect", "connected apps", "mcp", "notion", "linear", "github", "integration", "command line", "cli", "homebrew", "install"],
                summary: "Connect your apps (MCP servers, like Notion or Linear) so I and the helpers can use them (\"add a page to my Notion\"), and install any command-line tool: type its name there, or just ask me (\"install ffmpeg\").",
                whereToFind: "Home → Tools.",
                place: Place(section: .tools),
                steps: [
                    WalkStep(target: .page(.tools), say: "This is Tools.", wait: .none),
                    WalkStep(target: .text(["Add an app"]), say: "Pick an app here to connect it. Some ask for a key.", wait: .none),
                    WalkStep(target: .text(["Your apps"]), say: "The ones you connected show up here.", wait: .none),
                    WalkStep(target: .text(["Command-line tools"]), say: "And these are tools I can install for the helpers.", wait: .none)
                ]
            ),
            Feature(
                id: "mausbot",
                title: "Helpers on your Claude plan",
                keywords: ["mausbot", "claude", "claude code", "engine", "backup", "gemini backup", "sign in", "limit", "paused", "account", "claude account", "switch account"],
                summary: "Helpers can run on your Claude plan through MausBot, a free app, at no extra cost. If Claude hits its limit or isn't signed in, they switch to the free Gemini backup by themselves and try Claude again later. Or pick Gemini only. It shows which Claude account they use, and Use a different account switches it.",
                whereToFind: "Settings → Helpers: Claude via MausBot.",
                place: .settings("Helpers: Claude via MausBot"),
                steps: [
                    WalkStep(target: .text(["Run helpers on"]), say: "Pick what helpers run on here.", wait: .none),
                    WalkStep(
                        target: .text(["Set up"]),
                        say: "Click Set up and I install MausBot and Claude Code for you.",
                        wait: .click,
                        isNeeded: { !DottieMausBot.shared.isSetUp || DottieMausBot.shared.claudeState == .notInstalled }
                    ),
                    WalkStep(
                        target: .text(["Sign in to Claude"]),
                        say: "Then click Sign in to Claude. Allow it once in your browser and I pick it up.",
                        wait: .click,
                        isNeeded: { DottieMausBot.shared.claudeState == .notSignedIn },
                        secondsToWaitForNeed: 6
                    ),
                    WalkStep(
                        target: .text(["Try Claude now"]),
                        say: "Claude is paused for now. Click Try Claude now to give it another go.",
                        wait: .click,
                        isNeeded: { DottieMausBot.shared.claudePausedUntil != nil }
                    )
                ],
                doneLine: "That's it. Helpers use Claude when they can and Gemini when they can't."
            ),
            Feature(
                id: "profile",
                title: "My levels",
                keywords: ["level", "levels", "xp", "streak", "unlock", "unlocks", "notch effect", "disco ball", "wear", "profile"],
                summary: "I level up: finished jobs, helper tasks, guides, games and days in a row earn XP. Levels unlock cursor shapes and notch effects (\"wear the disco ball\").",
                whereToFind: "Home → Profile.",
                place: Place(section: .profile),
                steps: [
                    WalkStep(target: .page(.profile), say: "This is my Profile: level, XP and streak.", wait: .none),
                    WalkStep(target: .text(["Unlocks"]), say: "Click an unlocked shape to dress me up.", wait: .none),
                    WalkStep(target: .text(["Notch effect"]), say: "This adds an effect around the notch.", wait: .none),
                    WalkStep(target: .text(["24/7 jobs"]), say: "And any 24/7 jobs show here, with a stop button.", wait: .none)
                ]
            ),
            Feature(
                id: "games",
                title: "Games",
                keywords: ["game", "games", "trivia", "quiz", "20 questions", "twenty questions", "guess my drawing", "doodle", "word chain", "bored"],
                summary: "Play with me: trivia on anything, 20 questions (either way round), guess my drawing, and word chain. Wins earn me XP.",
                whereToFind: "By voice: \"let's play trivia\"."
            ),
            Feature(
                id: "keepworking",
                title: "24/7 jobs",
                keywords: ["24 7", "all night", "keep working", "until it's done", "every 10 minutes", "overnight", "keep checking"],
                summary: "Ask a helper to keep working on something all night or check every few minutes. Your Mac stays awake (the screen can still turn off), a moon shows in the notch, and your phone gets a text when it finds something.",
                whereToFind: "By voice. Home → Profile lists and stops them.",
                place: Place(section: .profile)
            ),
            Feature(
                id: "focus",
                title: "Focus mode",
                keywords: ["focus", "focus mode", "distraction", "block", "blocked", "blocking", "youtube closes", "app keeps closing", "concentrate", "pomodoro"],
                summary: "For a set time I hide distracting apps and close distracting sites, with a cheeky line in the notch, and tell you how it went at the end. Say \"focus for 45 minutes\" or switch it on in Settings → Everyday, where you also choose what's blocked.",
                whereToFind: "Settings → Everyday, or by voice.",
                place: .settings("Everyday"),
                steps: [
                    WalkStep(target: .text(["Focus mode"]), say: "This switch starts focus mode.", wait: .none),
                    WalkStep(target: .text(["Focus for"]), say: "This sets how long.", wait: .none),
                    WalkStep(target: .text(["Apps to block"]), say: "And these are the apps and sites I block.", wait: .none)
                ]
            ),
            Feature(
                id: "watches",
                title: "Watching things for you",
                keywords: ["watch", "watches", "tell me when", "let me know when", "download finishes", "page changes", "notify me when", "loads"],
                summary: "\"Tell me when this download finishes\", \"when this page changes\", \"when it says Done\": I keep an eye on it on the Mac and tell you with a card in the notch, a sound, a notification and a text if your phone is paired.",
                whereToFind: "By voice. Running watches show when you hover the notch."
            ),
            Feature(
                id: "replays",
                title: "Instant replays",
                keywords: ["replay", "replays", "redo", "again", "faster", "remember how", "same thing again"],
                summary: "When a screen job works I remember its steps, so the next time you ask for the same thing in the same app or site I redo it straight away. Ask \"what replays do you have?\" or forget them.",
                whereToFind: "Settings → Instant replays, or by voice.",
                place: .settings("Instant replays"),
                steps: [WalkStep(target: .text(["Instant replays"]), say: "Your saved replays are listed here.", wait: .none)]
            ),
            Feature(
                id: "selfcheck",
                title: "Check everything",
                keywords: ["self check", "check everything", "check", "test", "broken", "not working", "diagnose", "slow", "no sound"],
                summary: "One button tests every part I need (permissions, the server, Gemini, my voice, the microphone, the screen, helpers, the phone) and says what's wrong, with a fix button where there is one. Or ask me to check myself.",
                whereToFind: "Settings → Check everything, or by voice.",
                place: .settings("Check everything"),
                steps: [WalkStep(target: .text(["Check everything"]), say: "Click Check everything. It takes a few seconds.", wait: .click)]
            ),
            Feature(
                id: "fixtext",
                title: "Fix selected text",
                keywords: ["fix text", "fix this", "rewrite", "shorter", "longer", "grammar", "spelling", "formal", "casual", "translate"],
                summary: "Select text in any app and say \"make this shorter\", \"fix the grammar\" or \"translate this to Spanish\", or press the fix-text shortcut\(fixTextKeyNote). I put the new text back in place.",
                whereToFind: "Any app. Shortcut in Settings → Shortcuts.",
                place: .settings("Shortcuts"),
                steps: [WalkStep(target: .text(["Fix selected text"]), say: "Pick a shortcut here to fix selected text in one press.", wait: .none)]
            ),
            Feature(
                id: "cleanup",
                title: "Folder cleanup",
                keywords: ["clean up", "cleanup", "tidy", "organize", "downloads", "desktop", "duplicates", "big files"],
                summary: "\"Clean up my Downloads\": I sort files into folders, find duplicates and big old files, and name screenshots, all on the Mac. You check the plan first, removed files go to the Trash, and you can undo the last cleanup in Settings → Everyday.",
                whereToFind: "By voice. Undo in Settings → Everyday.",
                place: .settings("Everyday"),
                steps: [WalkStep(target: .text(["Last folder cleanup"]), say: "Undo your last cleanup here.", wait: .none)]
            ),
            Feature(
                id: "timeline",
                title: "My memory timeline",
                keywords: ["timeline", "episodes", "what did we do", "what was i doing", "yesterday", "last week", "remember what's on my screen", "history of"],
                summary: "I keep short stories of what happened (\"checked the Kaggle rank in Opera\") from our chats, helper tasks and screen jobs, and, only if you turn it on, what's on your screen. Ask \"what was I working on yesterday?\" Home → Brain shows the timeline by day; delete any moment.",
                whereToFind: "Home → Brain → Timeline.",
                place: Place(section: .brain),
                steps: [
                    WalkStep(target: .text(["Timeline"]), say: "This is the timeline, day by day.", wait: .none),
                    WalkStep(target: .text(["Remember what's on my screen"]), say: "Switch this on if you want me to remember what's on your screen too.", wait: .none)
                ]
            ),
            Feature(
                id: "search",
                title: "Looking things up",
                keywords: ["search", "web", "news", "weather", "price", "look up", "google"],
                summary: "For fresh facts (news, prices, weather, scores) I search the web and answer in a sentence.",
                whereToFind: "By voice."
            ),
            Feature(
                id: "cursor",
                title: "My cursor",
                keywords: ["cursor", "blue cursor", "shape", "cat", "pet", "costume", "emoji", "roam", "walk around", "hide cursor"],
                summary: "My blue cursor points at things. Say \"turn into a cat\" (any emoji works) and it can roam your screen like a pet. Keep it always visible or only while we talk, and pick a shape, in Settings → Appearance.",
                whereToFind: "Settings → Appearance, or by voice.",
                place: .settings("Appearance"),
                steps: [
                    WalkStep(target: .text(["Keep the blue cursor visible"]), say: "This keeps my cursor on screen. Off, it only shows while we talk.", wait: .none),
                    WalkStep(target: .text(["Cursor shape"]), say: "Pick a shape here, or just tell me to turn into something.", wait: .none)
                ]
            ),
            Feature(
                id: "notch",
                title: "The notch",
                keywords: ["notch", "top of the screen", "peek", "hover", "captions", "answer card"],
                summary: "I live in the notch: listening waves, live captions and answer cards. Hover it to see your Dots and the files they made, or to type to me. Small icons show when meeting notes or the screen journal are on.",
                whereToFind: "Top of your screen. Turn it off in Settings → Appearance.",
                place: .settings("Appearance"),
                steps: [
                    WalkStep(target: .text(["Show Dottie in the notch"]), say: "This switch shows or hides me in the notch.", wait: .click)
                ]
            ),
            Feature(
                id: "notifications",
                title: "Notifications",
                keywords: ["notify", "notification", "notifications", "alert", "alerts"],
                summary: "I can notify you when a Dot finishes or needs you, while you're in another app.",
                whereToFind: "Settings → Appearance.",
                place: .settings("Appearance"),
                steps: [
                    WalkStep(target: .text(["Notify me when a Dot finishes or needs me"]), say: "This switch turns those notifications on or off.", wait: .click)
                ]
            ),
            Feature(
                id: "voice",
                title: "My voice and personality",
                keywords: ["voice", "sound", "accent", "personality", "tone", "sarcastic", "funny", "calm", "tutor", "hype"],
                summary: "Pick how I sound (tap play to hear each voice) and my personality: \(personalityNames), or make your own (\"a grumpy pirate who loves cats\").",
                whereToFind: "Settings → Voice.",
                place: .settings("Voice"),
                steps: [
                    WalkStep(target: .text(["Dottie's voice"]), say: "Pick my voice here. The play button lets you hear each one.", wait: .none),
                    WalkStep(target: .text(["Personality"]), say: "This picks my personality.", wait: .none),
                    WalkStep(target: .text(["Make your own"]), say: "And here you can make up your own.", wait: .none)
                ]
            ),
            Feature(
                id: "shortcuts",
                title: "Shortcuts",
                keywords: ["shortcut", "shortcuts", "hotkey", "keys", "change the key", "control option", "right option"],
                summary: "Hold \(talkKeys) to talk and \(dictateKeys) to dictate. Type to me with \(askBarKeyName) and fix selected text with \(fixTextKeyName). Click a shortcut in Settings → Shortcuts and press new keys to change it.",
                whereToFind: "Settings → Shortcuts.",
                place: .settings("Shortcuts"),
                steps: [
                    WalkStep(target: .text(["Talk to Dottie"]), say: "Click this, then press the keys you want to hold to talk.", wait: .none),
                    WalkStep(target: .text(["Dictate"]), say: "This one is for dictation.", wait: .none),
                    WalkStep(target: .text(["Type to Dottie"]), say: "This opens a box to type to me from any app.", wait: .none),
                    WalkStep(target: .text(["Fix selected text"]), say: "And this fixes the text you've selected.", wait: .none)
                ]
            ),
            Feature(
                id: "permissions",
                title: "Permissions",
                keywords: ["permission", "permissions", "allow", "access", "screen recording", "accessibility", "microphone", "privacy", "can't see", "can't hear"],
                summary: "Everything macOS can ask about, with what each is for. Allow everything asks for them all in a row; anything you said no to before opens its page in System Settings.",
                whereToFind: "Settings → Permissions.",
                place: .settings("Permissions"),
                steps: [
                    WalkStep(target: .text(["Allow everything"]), say: "Click Allow everything and macOS asks for each one in turn.", wait: .click)
                ]
            ),
            Feature(
                id: "updates",
                title: "Updates",
                keywords: ["update", "updates", "version", "new version", "upgrade", "latest"],
                summary: "I check for new versions every few hours and update in place in a few seconds. Check now or install from Settings → Updates.",
                whereToFind: "Settings → Updates.",
                place: .settings("Updates"),
                steps: [
                    WalkStep(target: .text(["Update to", "Check now"]), say: "Click here to check for a new version, or install one that's waiting.", wait: .click)
                ]
            ),
            Feature(
                id: "computeruse",
                title: "Letting Dots use your Mac",
                keywords: ["computer use", "without asking", "ask before", "click and type", "driver", "cua", "always allow"],
                summary: "Dots can always look at your apps. With the switch off they ask in the notch before they click or type.",
                whereToFind: "Settings → Using your Mac.",
                place: .settings("Using your Mac"),
                steps: [
                    WalkStep(target: .text(["Let Dots click and type without asking"]), say: "Switch this on to let Dots click and type without asking.", wait: .click)
                ]
            ),
            Feature(
                id: "connection",
                title: "My server",
                keywords: ["server", "connection", "worker", "secret", "not working", "offline"],
                summary: "The server that talks to Gemini for me (it holds the key, so the app never sees it).",
                whereToFind: "Settings → Connection.",
                place: .settings("Connection"),
                steps: [WalkStep(target: .text(["Server", "Server address"]), say: "This is my server.", wait: .none)]
            ),
            Feature(
                id: "history",
                title: "Our conversation",
                keywords: ["history", "conversation", "clear", "delete", "chats", "forget chat"],
                summary: "Home → Conversation shows everything we've said; delete one exchange from its row. Settings → History → Clear wipes them all.",
                whereToFind: "Home → Conversation, and Settings → History.",
                place: .settings("History"),
                steps: [WalkStep(target: .text(["Clear"]), say: "Click Clear to wipe our saved conversation.", wait: .none)]
            ),
            Feature(
                id: "menubar",
                title: "Menu bar icon",
                keywords: ["menu bar", "quit", "replay intro", "panel", "icon"],
                summary: "Click my icon in the menu bar for a quick panel: open Home, pick a voice, replay the intro, or quit.",
                whereToFind: "The menu bar."
            ),
            Feature(
                id: "settings",
                title: "A tour of Settings",
                keywords: ["settings", "preferences", "options", "configure"],
                summary: "Settings has: " + settingsSections.map(\.title).joined(separator: ", ") + ".",
                whereToFind: "Home → Settings.",
                place: Place(section: .settings),
                steps: settingsSections.map { settingsSection in
                    WalkStep(
                        place: .settings(settingsSection.title),
                        target: .text([settingsSection.title, settingsSection.target]),
                        say: settingsSection.line,
                        wait: .none
                    )
                },
                doneLine: "That's Settings! Ask me to open any of it."
            )
        ]
        return allFeatures
    }

    private static func featuresText() -> String {
        var lines = ["Dottie \(appVersion). What I can do and where it lives:"]
        for feature in features() where feature.id != "tour" && feature.id != "settings" {
            lines.append("- \(feature.title): \(feature.summary) Where: \(feature.whereToFind)")
        }
        lines.append("Home pages: " + HomeSpaceRootView.HomeSection.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        lines.append("Settings sections: " + settingsGroupTitles.joined(separator: ", ") + ".")

        // Tools other features added through the registry, so new features
        // show up here without anyone editing this file.
        var seenToolNames: Set<String> = ["about_me"]
        var registryLines: [String] = []
        for tool in DottieToolRegistry.tools(for: .voice) + DottieToolRegistry.tools(for: .helpers) where !seenToolNames.contains(tool.name) {
            seenToolNames.insert(tool.name)
            registryLines.append("- \(tool.name): \(firstSentence(of: tool.description))")
        }
        if !registryLines.isEmpty {
            lines.append("More things I can do (newer features):")
            lines += registryLines
        }
        lines.append("Walkthroughs I can give (about_me guide): " + features().filter { !$0.steps.isEmpty }.map(\.id).joined(separator: ", ") + ".")
        return lines.joined(separator: "\n")
    }

    private static func howToText(question: String) -> String {
        let matches = bestFeatures(for: question, limit: 3)
        guard !matches.isEmpty else {
            return "nothing in Dottie matches \"\(question)\". features gives the whole list. if it's about another app, use guide_user instead."
        }
        var lines: [String] = []
        for feature in matches {
            var line = "- \(feature.title): \(feature.summary) Where: \(feature.whereToFind)"
            if let place = feature.place { line += " (open: \(place.name))" }
            if !feature.steps.isEmpty { line += " (walkthrough: guide \"\(feature.id)\")" }
            lines.append(line)
        }
        lines.append("answer in one sentence, then offer to show them.")
        return lines.joined(separator: "\n")
    }

    /// Features ranked by simple keyword overlap with the question.
    static func bestFeatures(for question: String, limit: Int) -> [Feature] {
        let query = normalized(question)
        guard !query.isEmpty else { return [] }
        let queryWords = Set(query.split(separator: " ").map(String.init)).subtracting(stopWords)
        let scored = features().compactMap { feature -> (Feature, Double)? in
            var score = 0.0
            if query == feature.id { score += 10 }
            for keyword in feature.keywords {
                let normalizedKeyword = normalized(keyword)
                if " \(query) ".contains(" \(normalizedKeyword) ") {
                    score += normalizedKeyword.contains(" ") ? 3 : 2
                }
            }
            let titleWords = Set(normalized(feature.title).split(separator: " ").map(String.init)).subtracting(stopWords)
            score += Double(titleWords.intersection(queryWords).count)
            let summaryWords = Set(normalized(feature.summary).split(separator: " ").map(String.init)).subtracting(stopWords)
            score += 0.3 * Double(summaryWords.intersection(queryWords).count)
            return score >= 1 ? (feature, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "i", "me", "my", "you", "your", "do", "does", "how", "to", "in", "on", "of", "for", "is", "are",
        "can", "it", "and", "or", "what", "where", "which", "with", "this", "that", "turn", "get", "set", "up", "dottie",
        "please", "want", "would", "like", "be", "at", "from", "there", "here", "so", "if", "about"
    ]
}

// MARK: - Live state

extension DottieSelfKnowledge {
    /// The ones macOS switches on in System Settings rather than a dialog.
    private static let permissionsSwitchedOnInSettings: [DottiePermissions.Kind] = [.accessibility, .screenRecording, .inputMonitoring]

    private static func statusText() async -> String {
        let permissions = DottiePermissions.shared
        await permissions.refresh()
        var lines: [String] = []

        lines.append("Version: Dottie \(appVersion). " + updateDescription())
        lines.append(permissionsDescription())

        guard let companionManager = companionManager else {
            return lines.joined(separator: "\n")
        }

        let voiceModeName = companionManager.voiceMode == .live ? "Gemini Live" : "classic"
        lines.append("Voice: \(companionManager.selectedVoiceName), personality \(companionManager.selectedPersonality.displayName), \(voiceModeName) mode.")
        lines.append(shortcutsDescription())
        lines.append(await helpersDescription())
        lines.append(helperEngineDescription())
        lines.append("Phone: " + phoneDescription())
        lines.append(memoryAndModesDescription())
        lines.append(levelsDescription())
        lines.append("Notch: \(companionManager.isNotchEnabled ? "shown" : "hidden"). Blue cursor: \(companionManager.isClickyCursorEnabled ? "always visible" : "only while you talk").")
        lines.append(toolsDescription())
        lines.append("Smart home: \(companionManager.smartHome.promptSummary.isEmpty ? "nothing set up yet" : "set up").")
        lines.append("Server: \(serverDescription()).")
        if DottieScreenLock.shared.isLocked {
            lines.append("The screen is locked: helpers keep going, screen jobs wait until it's unlocked.")
        }
        if let lastCheck = DottieSelfCheck.shared.lastRunAt, !DottieSelfCheck.shared.items.isEmpty {
            let minutesAgo = max(0, Int(Date().timeIntervalSince(lastCheck) / 60))
            lines.append("Last self-check (\(minutesAgo) min ago): " + DottieSelfCheck.shared.summary)
        }
        return lines.joined(separator: "\n")
    }

    private static func permissionsDescription() -> String {
        let permissions = DottiePermissions.shared
        let allKinds = DottiePermissions.Kind.allCases
        let missingKinds = allKinds.filter { permissions.statuses[$0] == .notAsked || permissions.statuses[$0] == .denied }
        let unknownKinds = allKinds.filter { permissions.statuses[$0] == .unknown || permissions.statuses[$0] == nil }
        var description = "Permissions: \(permissions.allowedCount) of \(allKinds.count) allowed."
        if !missingKinds.isEmpty {
            let missingNames: [String] = missingKinds.map { kind in
                let turnedDownNote = permissions.statuses[kind] == .denied ? ", turned down before" : ""
                return "\(kind.title) (\(kind.reason.lowercased())\(turnedDownNote))"
            }
            description += " Missing: " + missingNames.joined(separator: "; ") + "."
        }
        if !unknownKinds.isEmpty {
            description += " macOS doesn't say for: " + unknownKinds.map(\.title).joined(separator: ", ") + "."
        }
        return description
    }

    private static func shortcutsDescription() -> String {
        guard let shortcutMonitor = companionManager?.globalPushToTalkShortcutMonitor else { return "Shortcuts: unknown." }
        let isDictationOn = UserDefaults.standard.object(forKey: "clickyDictationEnabled") as? Bool ?? true
        let globalShortcuts = DottieEveryday.shared.shortcuts
        let askBarKeys = globalShortcuts.hotkey(for: .askBar)?.displayText ?? "off"
        let fixTextKeys = globalShortcuts.hotkey(for: .fixText)?.displayText ?? "off"
        return "Shortcuts: hold \(shortcutMonitor.talkHotkey.displayText) to talk, \(shortcutMonitor.dictationHotkey.displayText) to dictate (dictation \(isDictationOn ? "on" : "off")). Type to Dottie: \(askBarKeys). Fix selected text: \(fixTextKeys)."
    }

    private static func helperEngineDescription() -> String {
        let mausBot = DottieMausBot.shared
        guard mausBot.preference == .claudeWithBackup else {
            return "Helper engine: Gemini only (free tier)."
        }
        var description = "Helper engine: Claude through MausBot, Gemini as backup. MausBot: \(mausBot.mausBotStatusLine). Claude: \(mausBot.claudeStatusLine)."
        if let pausedUntil = mausBot.claudePausedUntil {
            let reason = mausBot.claudePauseReason ?? "Claude is paused"
            description += " \(reason): helpers use Gemini until \(pausedUntil.formatted(date: .omitted, time: .shortened))."
        }
        return description
    }

    private static func memoryAndModesDescription() -> String {
        guard let companionManager = companionManager else { return "" }
        let everyday = DottieEveryday.shared
        let watchCount = everyday.watches.statusLines.count
        let keepWorkingCount = DottieKeepWorking.shared.activeJobs.count
        let screenNotes = companionManager.brain.isScreenJournalEnabled ? "on" : "off"
        let meetingNotes = companionManager.meetingRecorder.isRecording ? "taking notes now" : "off"
        let focusText = everyday.focus.isActive ? "on, \(everyday.focus.minutesLeft) min left" : "off"
        return "Remember what's on my screen: \(screenNotes). Meeting notes: \(meetingNotes). Focus mode: \(focusText). Watches running: \(watchCount). 24/7 jobs: \(keepWorkingCount). Instant replays saved: \(DottieReplayStore.shared.replays.count)."
    }

    private static func levelsDescription() -> String {
        let levels = DottieLevels.shared
        return "Level \(levels.level) (\(levels.levelName)), \(levels.totalXP) XP, \(levels.xpToNextLevel) to the next level, \(levels.streakDays)-day streak."
    }

    private static func toolsDescription() -> String {
        let toolsStore = DottieToolsStore.shared
        let appNames = toolsStore.serverNames.filter { toolsStore.isEnabled($0) }.map { toolsStore.title(for: $0) }
        let appsText = appNames.isEmpty ? "no apps connected" : "apps connected: " + appNames.joined(separator: ", ")
        let commandLineToolCount = DottieCLIToolsManager.shared.installedToolIDs.count
        return "Tools (Home → Tools): \(appsText); \(commandLineToolCount) command-line tools installed."
    }

    private static func updateDescription() -> String {
        switch DottieUpdater.shared.state {
        case .available(let version): return "Update waiting: Dottie \(version) (Settings → Updates → Update to \(version))."
        case .upToDate: return "Up to date."
        case .checking: return "Checking for updates now."
        case .downloading(let version): return "Downloading \(version) now."
        case .installing(let version): return "Installing \(version) now."
        case .failed(let message): return "The last update check failed: \(message)"
        case .idle: return "Hasn't checked for updates yet this run."
        }
    }

    /// Whether Dots can run: Dottie's own copy of their tools, or one the
    /// user installed (looked for off the main thread; it may ask the shell).
    private static func areHelpersReady() async -> Bool {
        if DotsRuntimeInstaller.isInstalled { return true }
        return await Task.detached(priority: .userInitiated) {
            GeminiCLIAgentRuntime.locateGeminiCLIExecutable() != nil
        }.value
    }

    private static func helpersDescription() async -> String {
        guard let roster = companionManager?.clickyRoster else { return "Helpers: unknown." }
        let helpers = roster.agents.filter { $0.isBrain != true }
        let workingCount = helpers.filter { roster.isRunning($0) }.count
        let waitingNames = helpers.filter { roster.pendingComputerUseRequest(for: $0) != nil }.map(\.name)
        var description = "Helpers (Dots): \(helpers.count), \(workingCount) working now."
        if !waitingNames.isEmpty {
            description += " Waiting for permission to use the Mac: " + waitingNames.joined(separator: ", ") + "."
        }
        let isReady = await areHelpersReady()
        description += isReady ? " Ready to run." : " Their Gemini tools are still downloading (one time, about 70 MB)."
        return description
    }

    private static func phoneDescription() -> String {
        guard let phoneBridge = companionManager?.phoneBridge else { return "unknown." }
        let botName = phoneBridge.botUsername.map { " @\($0)" } ?? ""
        if phoneBridge.pairedChatID != nil { return "paired through\(botName)." }
        if phoneBridge.isConnected { return "bot\(botName) connected, phone not paired yet (Home → Phone shows the code)." }
        return "not set up (Home → Phone)."
    }

    private static func serverDescription() -> String {
        guard ClickyWorkerConfiguration.isWorkerConfigured else { return "missing (Settings → Connection)" }
        let userServer = UserDefaults.standard.string(forKey: ClickyWorkerConfiguration.userWorkerBaseURLDefaultsKey) ?? ""
        return userServer.isEmpty ? "built in" : "your own"
    }

    // MARK: Troubleshooting

    private struct Problem {
        let text: String
        let fix: String
        let keywords: [String]
        /// Problems that break her core use come first.
        let isMajor: Bool
    }

    /// Self-check results younger than this are reused instead of testing
    /// again (a run takes a few seconds and one tiny Gemini call).
    private static let selfCheckReuseSeconds: TimeInterval = 10 * 60

    /// The speed pack's self-check does the real testing (permissions,
    /// server, Gemini, voice, microphone, screen, helpers' engine, MausBot,
    /// Claude, phone). This adds what it doesn't look at and puts what
    /// matches the question first.
    /// Helpers don't start a self-check (it listens to the microphone for a
    /// second); they get the last results.
    private static func troubleshootText(question: String, mayRunSelfCheck: Bool) async -> String {
        let selfCheck = DottieSelfCheck.shared
        var ranSelfCheckNow = false
        if selfCheck.isRunning {
            // Someone pressed Check everything a moment ago: wait for it.
            for _ in 0..<40 where selfCheck.isRunning {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        } else if mayRunSelfCheck && isSelfCheckStale(selfCheck) {
            await selfCheck.run()
            ranSelfCheckNow = true
        }

        var problems = selfCheck.items.filter { $0.level >= .warning }.map(problem(from:))
        problems += await stateProblems()

        let query = normalized(question)
        let queryWords = Set(query.split(separator: " ").map(String.init))
        func relevance(_ problem: Problem) -> Double {
            let matchedCount = Set(problem.keywords).intersection(queryWords).count
            return Double(matchedCount) * 2 + (problem.isMajor ? 1 : 0)
        }
        let sortedProblems = problems.sorted { relevance($0) > relevance($1) }
        // For a question about one thing, keep what matches it and what
        // breaks the most; leave out unrelated optional set-up.
        let shownProblems = query.isEmpty ? sortedProblems : sortedProblems.filter { relevance($0) > 0 }

        var lines: [String] = []
        if let lastRunAt = selfCheck.lastRunAt {
            let minutesAgo = max(0, Int(Date().timeIntervalSince(lastRunAt) / 60))
            lines.append(ranSelfCheckNow ? "Ran the self-check just now." : "Self-check from \(minutesAgo) min ago.")
        }
        if shownProblems.isEmpty {
            lines.append("Nothing in Dottie's own setup looks wrong" + (query.isEmpty ? "." : " for that."))
        } else {
            lines.append("Likely problems, most likely first:")
            lines += shownProblems.prefix(6).map { "- \($0.text) Fix: \($0.fix)" }
        }
        lines.append("If answers fail now and then, Gemini's free tier is probably busy for a moment: try again in a few seconds.")
        lines.append("say the most likely problem plainly in a sentence and offer the fix.")
        return lines.joined(separator: "\n")
    }

    private static func isSelfCheckStale(_ selfCheck: DottieSelfCheck) -> Bool {
        guard let lastRunAt = selfCheck.lastRunAt, !selfCheck.items.isEmpty else { return true }
        return Date().timeIntervalSince(lastRunAt) > selfCheckReuseSeconds
    }

    /// A self-check finding as a problem, with where to fix it.
    private static func problem(from item: DottieSelfCheck.Item) -> Problem {
        var fix: String
        if let fixLabel = item.fixLabel, item.fix != nil {
            fix = "about_me fix '\(item.id)' (the \(fixLabel) button in Settings → Check everything)."
        } else {
            fix = "Settings → Check everything has the details."
        }
        var keywords = normalized(item.title + " " + item.detail).split(separator: " ").map(String.init)
        if item.id.hasPrefix("permission") {
            keywords += ["permission", "permissions", "allow"]
        }
        switch item.id {
        case "worker", "gemini", "live":
            fix = "Settings → Connection for the server; if Gemini is busy, try again in a few seconds."
            keywords += ["voice", "talk", "answer", "answers", "slow", "server", "working", "respond"]
        case "mic":
            keywords += ["hear", "voice", "talk", "sound", "microphone"]
        case "screen", "ax-read":
            keywords += ["see", "screen", "point", "click", "pointing"]
        case "cua":
            fix = "Settings → Using your Mac explains how to get the driver."
            keywords += ["helper", "helpers", "dots", "click", "type"]
        case "runtime", "openmausbot", "claude":
            if item.fix == nil { fix = "Settings → Helpers: Claude via MausBot." }
            keywords += ["helper", "helpers", "dot", "dots", "mausbot", "claude", "task"]
        case "telegram":
            fix = "Home → Phone (about_me guide 'phone')."
            keywords += ["phone", "telegram", "text", "bot"]
        default:
            break
        }
        return Problem(text: "\(item.title): \(item.detail)", fix: fix, keywords: keywords, isMajor: item.level == .problem)
    }

    /// Things the self-check doesn't test: Dottie's own settings and modes.
    private static func stateProblems() async -> [Problem] {
        var problems: [Problem] = []
        if let companionManager = companionManager {
            let roster = companionManager.clickyRoster
            let waitingNames = roster.agents.filter { roster.pendingComputerUseRequest(for: $0) != nil }.map(\.name)
            if !waitingNames.isEmpty {
                problems.append(Problem(
                    text: "\(waitingNames.joined(separator: ", ")) is waiting for your OK to use the Mac.",
                    fix: "Answer Allow in the notch or in Home → Dots. To skip asking: Settings → Using your Mac.",
                    keywords: ["helper", "helpers", "dot", "dots", "stuck", "waiting"],
                    isMajor: true
                ))
            }
            let phoneBridge = companionManager.phoneBridge
            if !phoneBridge.isConnected {
                problems.append(Problem(
                    text: "Texting from the phone isn't set up.",
                    fix: "Home → Phone, about two minutes (about_me guide 'phone').",
                    keywords: ["phone", "telegram", "text", "bot"],
                    isMajor: false
                ))
            }
            if !companionManager.isNotchEnabled {
                problems.append(Problem(
                    text: "The notch is turned off, so captions, answers and helper updates don't show there.",
                    fix: "Settings → Appearance → Show Dottie in the notch.",
                    keywords: ["notch", "captions", "see", "show", "type"],
                    isMajor: false
                ))
            }
            if UserDefaults.standard.object(forKey: "clickyDictationEnabled") as? Bool == false {
                problems.append(Problem(
                    text: "Dictation is switched off.",
                    fix: "Settings → Dictation, first switch.",
                    keywords: ["dictate", "dictation", "type"],
                    isMajor: false
                ))
            }
        }

        let mausBot = DottieMausBot.shared
        if mausBot.preference == .claudeWithBackup {
            if let pausedUntil = mausBot.claudePausedUntil {
                problems.append(Problem(
                    text: "\(mausBot.claudePauseReason ?? "Claude is paused"), so helpers use the free Gemini backup until \(pausedUntil.formatted(date: .omitted, time: .shortened)).",
                    fix: "Settings → Helpers: Claude via MausBot → Try Claude now (about_me guide 'mausbot').",
                    keywords: ["helper", "helpers", "dots", "claude", "mausbot", "slow", "gemini", "limit"],
                    isMajor: false
                ))
            } else if mausBot.claudeState == .notSignedIn {
                problems.append(Problem(
                    text: "Claude isn't signed in, so helpers use the free Gemini backup.",
                    fix: "Settings → Helpers: Claude via MausBot → Sign in to Claude (about_me guide 'mausbot').",
                    keywords: ["helper", "helpers", "dots", "claude", "mausbot", "sign"],
                    isMajor: false
                ))
            } else if mausBot.hasLookedForMausBot && !mausBot.isSetUp {
                problems.append(Problem(
                    text: "MausBot isn't set up, so helpers run on Gemini's free tier instead of your Claude plan.",
                    fix: "Settings → Helpers: Claude via MausBot → Set up (about_me guide 'mausbot').",
                    keywords: ["helper", "helpers", "dots", "claude", "mausbot"],
                    isMajor: false
                ))
            }
        }

        for (action, problemText) in DottieEveryday.shared.shortcuts.problems {
            let shortcutName = action == .askBar ? "type-to-ask" : "fix-text"
            problems.append(Problem(
                text: "The \(shortcutName) shortcut doesn't work: \(problemText)",
                fix: "Settings → Shortcuts: pick another one.",
                keywords: ["shortcut", "type", "ask", "fix", "option", "space", "keys"],
                isMajor: false
            ))
        }

        let focus = DottieEveryday.shared.focus
        if focus.isActive {
            problems.append(Problem(
                text: "Focus mode is on (\(focus.minutesLeft) min left), so blocked apps hide and blocked sites close.",
                fix: "Say stop focus, or switch it off in Settings → Everyday.",
                keywords: ["focus", "closes", "closed", "closing", "hides", "hidden", "blocked", "youtube", "app", "site", "tab"],
                isMajor: true
            ))
        }

        if DottieScreenLock.shared.isLocked {
            problems.append(Problem(
                text: "The screen is locked, so screen jobs wait (helpers keep going).",
                fix: "Unlock the Mac; waiting jobs pick up by themselves.",
                keywords: ["screen", "job", "jobs", "waiting", "stuck", "locked"],
                isMajor: true
            ))
        }

        let toolsStore = DottieToolsStore.shared
        for serverName in toolsStore.serverNames where toolsStore.isEnabled(serverName) {
            let appTitle = toolsStore.title(for: serverName)
            let appProblem: String?
            switch toolsStore.status(for: serverName) {
            case .needsKey(let keyNames): appProblem = "needs a key (\(keyNames.joined(separator: ", ")))"
            case .needsProgram(let programName): appProblem = "needs \(programName) installed"
            case .failed(let message): appProblem = "couldn't start: \(message)"
            default: appProblem = nil
            }
            guard let appProblem else { continue }
            problems.append(Problem(
                text: "\(appTitle) in Home → Tools \(appProblem).",
                fix: "Home → Tools: open \(appTitle) and fix it there.",
                keywords: normalized(appTitle).split(separator: " ").map(String.init) + ["tools", "app", "apps", "connected", "mcp"],
                isMajor: false
            ))
        }

        if case .available(let version) = DottieUpdater.shared.state {
            problems.append(Problem(
                text: "An update is waiting: Dottie \(version).",
                fix: "Settings → Updates → Update to \(version). It takes a few seconds and I reopen.",
                keywords: ["update", "version", "bug", "broken", "fix"],
                isMajor: false
            ))
        } else if case .failed(let message) = DottieUpdater.shared.state {
            problems.append(Problem(
                text: "The last update check failed: \(message)",
                fix: "Settings → Updates → Check now.",
                keywords: ["update", "version"],
                isMajor: false
            ))
        }
        return problems
    }

    /// Runs a self-check item's own fix (Allow, Open Settings, install the
    /// helpers' engine, …), the same as its button in Settings.
    private static func applySelfCheckFix(named spokenName: String) async -> String {
        let selfCheck = DottieSelfCheck.shared
        if isSelfCheckStale(selfCheck) && !selfCheck.isRunning {
            await selfCheck.run()
        }
        let query = normalized(spokenName)
        let fixableItems = selfCheck.items.filter { $0.fix != nil && $0.level >= .warning }
        let matchedItem = fixableItems.first { $0.id == spokenName }
            ?? fixableItems.first { item in
                let title = normalized(item.title)
                return !query.isEmpty && (title.contains(query) || query.contains(title))
            }
        guard let item = matchedItem, let fix = item.fix else {
            if let place = place(named: spokenName) {
                show(place)
                return "nothing to fix by itself there, so I opened \(place.name)."
            }
            let names = fixableItems.map { "\($0.id) (\($0.title))" }
            return names.isEmpty
                ? "the self-check has nothing it can fix by itself right now."
                : "fixable now: " + names.joined(separator: ", ") + "."
        }
        selfCheck.apply(fix)
        return "doing \"\(item.fixLabel ?? "the fix")\" for \(item.title). tell them in a few words what to do next, if anything (allow it, or switch Dottie on in System Settings)."
    }

    // MARK: Permissions

    private static func askPermission(named spokenName: String) async -> String {
        let permissions = DottiePermissions.shared
        await permissions.refresh()
        let query = normalized(spokenName)
        if query.isEmpty || ["all", "everything", "all of them", "every permission"].contains(query) {
            let missingCount = DottiePermissions.Kind.allCases.filter { permissions.statuses[$0] != .allowed }.count
            Task { await permissions.askForAll() }
            return missingCount == 0
                ? "everything macOS can tell about is already allowed."
                : "macOS is asking for each missing permission in turn now. dialogs need Allow; for Accessibility, Screen Recording and Input Monitoring System Settings opens and they switch Dottie on there."
        }
        let matchedKind = DottiePermissions.Kind.allCases.first { kind in
            let names = [kind.title, kind.rawValue].map(normalized)
            return names.contains { name in
                query == name || " \(query) ".contains(" \(name) ") || " \(name) ".contains(" \(query) ")
                    || (query.count >= 3 && name.hasPrefix(query))
            }
        }
        guard let kind = matchedKind else {
            return "no permission called \"\(spokenName)\". permissions: " + DottiePermissions.Kind.allCases.map(\.title).joined(separator: ", ") + ", or all."
        }
        let status = permissions.statuses[kind]
        if status == .allowed { return "\(kind.title) is already allowed." }
        Task {
            await permissions.ask(for: kind)
            await permissions.refresh()
        }
        if status == .denied {
            return "they said no to \(kind.title) before, so macOS won't ask again: System Settings is opening on its page. they switch Dottie on there."
        }
        if permissionsSwitchedOnInSettings.contains(kind) {
            return "System Settings is opening on \(kind.title). they switch Dottie on there."
        }
        return "macOS is showing its \(kind.title) dialog now. they click Allow."
    }
}

// MARK: - Walkthroughs of her own app

extension DottieSelfKnowledge {
    /// Where a running walkthrough is up to.
    private final class WalkthroughProgress {
        var nextStepIndex = 0
        var hasAddedNextHint = false
        var hasEnded = false
    }

    private static func startWalkthrough(topic: String) -> String {
        guard let companionManager = companionManager else { return "the guide isn't ready yet. try again in a moment." }
        let walkthroughs = features().filter { !$0.steps.isEmpty }
        let topicName = normalized(topic)
        let chosenFeature = walkthroughs.first { $0.id == topicName }
            ?? bestFeatures(for: topic.isEmpty ? "tour" : topic, limit: 3).first { !$0.steps.isEmpty }
            ?? place(named: topic).map { placeWalkthrough(for: $0) }
        guard let feature = chosenFeature else {
            return "no walkthrough for \"\(topic)\". topics: " + walkthroughs.map(\.id).joined(separator: ", ") + ", or any Home page or Settings section."
        }

        let progress = WalkthroughProgress()
        let steps = feature.steps
        return companionManager.startSelfWalkthrough(goal: "using Dottie: \(feature.title)") { _ in
            await nextGuideStep(steps: steps, feature: feature, progress: progress)
        }
    }

    /// No written walkthrough: open the place and say what it is.
    private static func placeWalkthrough(for place: Place) -> Feature {
        let target: Target
        var line = pageLines[place.section] ?? "This is \(place.name)."
        if let settingsGroup = place.settingsGroup {
            target = .text([settingsGroup])
            if let settingsSection = settingsSections.first(where: { $0.title == settingsGroup }) {
                line = settingsSection.line
            }
        } else {
            target = .page(place.section)
        }
        return Feature(
            id: "place",
            title: place.name,
            keywords: [],
            summary: "",
            whereToFind: place.name,
            place: place,
            steps: [WalkStep(target: target, say: line, wait: .none)]
        )
    }

    private static func nextGuideStep(steps: [WalkStep], feature: Feature, progress: WalkthroughProgress) async -> DottieGuide.Step? {
        while progress.nextStepIndex < steps.count {
            let walkStep = steps[progress.nextStepIndex]
            progress.nextStepIndex += 1
            if let isNeeded = walkStep.isNeeded {
                var isStepNeeded = isNeeded()
                var secondsWaited = 0.0
                while !isStepNeeded && secondsWaited < walkStep.secondsToWaitForNeed {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return nil }
                    secondsWaited += 0.5
                    isStepNeeded = isNeeded()
                }
                if !isStepNeeded { continue }
            }
            return await guideStep(for: walkStep, defaultPlace: feature.place, progress: progress)
        }
        guard !progress.hasEnded else { return nil }
        progress.hasEnded = true
        return DottieGuide.Step(
            kind: .done,
            say: feature.doneLine,
            targetRect: nil,
            targetLabel: nil,
            marks: [],
            displayFrame: screenFrame(containing: homeWindow?.frame ?? .zero)
        )
    }

    /// Opens the step's page, finds its control and turns it into a guide
    /// step the existing guide shows (points, circles, says it).
    private static func guideStep(for walkStep: WalkStep, defaultPlace: Place?, progress: WalkthroughProgress) async -> DottieGuide.Step {
        let wasHomeVisible = homeWindow?.isVisible == true
        if let place = walkStep.place ?? defaultPlace {
            show(place)
            // Let the page appear (and Settings scroll) before looking.
            try? await Task.sleep(nanoseconds: wasHomeVisible ? 450_000_000 : 900_000_000)
        }

        var targetRect: CGRect?
        var targetLabel: String?
        if let target = walkStep.target, let window = homeWindow {
            let located = await locate(target, in: window, prefersControlOnRow: walkStep.wait == .click)
            targetRect = located.rect
            targetLabel = located.label
        }

        // A click step whose control wasn't found waits for "next" instead.
        var wait = walkStep.wait
        if wait == .click && targetRect == nil { wait = .next }
        var say = walkStep.say
        if wait == .next && !progress.hasAddedNextHint {
            say += " Say next when you're ready."
            progress.hasAddedNextHint = true
        }
        return DottieGuide.Step(
            kind: wait == .click ? .click : .look,
            say: say,
            targetRect: targetRect,
            targetLabel: targetLabel,
            marks: [],
            displayFrame: screenFrame(containing: targetRect ?? homeWindow?.frame ?? .zero),
            movesOnWhenSaid: wait == .none
        )
    }

    private static func screenFrame(containing rect: CGRect) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }?.frame
            ?? NSScreen.main?.frame
            ?? rect
    }
}

// MARK: - Finding controls in her own window

extension DottieSelfKnowledge {
    private struct AccessibleNode {
        let frame: CGRect
        let role: NSAccessibility.Role?
        let texts: [String]
    }

    private static let maximumScannedNodes = 6000
    private static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .popUpButton, .textField, .comboBox, .slider, .radioButton, .menuButton, .link
    ]

    /// Finds the target's frame (global AppKit points). Reads the window's
    /// own accessibility tree in-process (no permission, no screenshot),
    /// then on-screen text recognition on the Mac, then, for a page icon,
    /// where the rail draws it.
    private static func locate(_ target: Target, in window: NSWindow, prefersControlOnRow: Bool) async -> (rect: CGRect?, label: String?) {
        let nodes = accessibleNodes(in: window)
        switch target {
        case .page(let section):
            // The rail is the left edge of the window.
            let railNodes = nodes.filter { $0.frame.maxX <= window.frame.minX + 90 }
            if let rect = bestFrame(for: [section.rawValue], in: railNodes, visibleFrame: window.frame, prefersControlOnRow: false) {
                return (rect, section.rawValue)
            }
            return (railIconFrame(for: section, in: window), section.rawValue)

        case .text(let labels):
            if let rect = bestFrame(for: labels, in: nodes, visibleFrame: window.frame, prefersControlOnRow: prefersControlOnRow) {
                return (rect, labels.first)
            }
            // On-device text recognition, for a page that doesn't describe
            // itself to accessibility.
            if CGPreflightScreenCaptureAccess() {
                let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
                let displayFrame = screenFrame(containing: window.frame)
                for label in labels {
                    if let rect = await ScreenTextFinder.frameOfText(matching: label, near: windowCenter, displayFrame: displayFrame),
                       window.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                        return (rect, label)
                    }
                }
            }
            return (nil, labels.first)
        }
    }

    /// Every element in the window's accessibility tree with its frame,
    /// role and texts (label, title, value, placeholder, help).
    private static func accessibleNodes(in window: NSWindow) -> [AccessibleNode] {
        var nodes: [AccessibleNode] = []
        var pending: [Any] = window.accessibilityChildren() ?? []
        var nextIndex = 0
        while nextIndex < pending.count && nextIndex < maximumScannedNodes {
            let candidate = pending[nextIndex]
            nextIndex += 1
            guard let element = candidate as? NSAccessibilityProtocol else { continue }
            let texts = [
                element.accessibilityLabel(),
                element.accessibilityTitle(),
                element.accessibilityValue() as? String,
                element.accessibilityPlaceholderValue(),
                element.accessibilityHelp()
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            nodes.append(AccessibleNode(frame: element.accessibilityFrame(), role: element.accessibilityRole(), texts: texts))
            if let children = element.accessibilityChildren() {
                pending.append(contentsOf: children)
            }
        }
        return nodes
    }

    private static func bestFrame(for labels: [String], in nodes: [AccessibleNode], visibleFrame: CGRect, prefersControlOnRow: Bool) -> CGRect? {
        var best: (node: AccessibleNode, score: Double)?
        for (labelIndex, label) in labels.enumerated() {
            let wanted = normalized(label)
            guard !wanted.isEmpty else { continue }
            for node in nodes where node.frame.width > 1 && node.frame.height > 1 && visibleFrame.intersects(node.frame) {
                var textScore = 0.0
                for text in node.texts {
                    let candidate = normalized(text)
                    if candidate == wanted {
                        textScore = max(textScore, 3)
                    } else if wanted.count >= 3, candidate.hasPrefix(wanted) {
                        textScore = max(textScore, 2)
                    } else if wanted.count >= 4, candidate.contains(wanted) {
                        textScore = max(textScore, 1)
                    }
                }
                guard textScore > 0 else { continue }
                var score = textScore - 0.2 * Double(labelIndex)
                if let role = node.role, interactiveRoles.contains(role) { score += 0.5 }
                // Containers that merely include the text lose to the text.
                if node.frame.width * node.frame.height > 120_000 { score -= 1 }
                if score > (best?.score ?? 0) {
                    best = (node, score)
                }
            }
        }
        guard let best else { return nil }
        // A row's label: point at the switch or button on the same row.
        if prefersControlOnRow, best.node.role == .staticText,
           let rowControl = controlOnSameRow(as: best.node, in: nodes, visibleFrame: visibleFrame) {
            return rowControl.frame
        }
        return best.node.frame
    }

    private static func controlOnSameRow(as labelNode: AccessibleNode, in nodes: [AccessibleNode], visibleFrame: CGRect) -> AccessibleNode? {
        let rowTolerance = max(12, labelNode.frame.height)
        return nodes
            .filter { node in
                guard let role = node.role, interactiveRoles.contains(role), visibleFrame.intersects(node.frame) else { return false }
                return abs(node.frame.midY - labelNode.frame.midY) <= rowTolerance && node.frame.minX >= labelNode.frame.maxX - 4
            }
            .min { $0.frame.minX < $1.frame.minX }
    }

    /// Where Home's rail draws a page's icon (36pt buttons, 6pt apart, 14pt
    /// from the top of the content), for when accessibility doesn't say.
    private static func railIconFrame(for section: HomeSpaceRootView.HomeSection, in window: NSWindow) -> CGRect? {
        guard let index = HomeSpaceRootView.HomeSection.allCases.firstIndex(of: section) else { return nil }
        let contentTop = window.frame.minY + window.contentLayoutRect.maxY
        let iconSize: CGFloat = 36
        let iconTop = contentTop - 14 - CGFloat(index) * (iconSize + 6)
        return CGRect(
            x: window.frame.minX + window.contentLayoutRect.minX + 10,
            y: iconTop - iconSize,
            width: iconSize,
            height: iconSize
        )
    }
}

// MARK: - Text helpers

extension DottieSelfKnowledge {
    /// Lowercased words only: "Settings → Voice!" is "settings voice".
    static func normalized(_ text: String) -> String {
        let lowercased = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'", with: "")
        let words = lowercased.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    private static func firstSentence(of text: String) -> String {
        if let periodRange = text.range(of: ". ") {
            return String(text[..<periodRange.lowerBound]) + "."
        }
        return text
    }
}
