//
//  GeminiLiveToolCatalog.swift
//  leanring-buddy
//
//  Which tools Gemini Live gets declared up front and how it reaches the
//  rest: only the everyday tools are declared directly, the others are
//  found with find_tool and run with use_tool.
//

import AVFoundation
import Foundation

/// Which tools Live gets declared up front and how it reaches the rest.
/// Every declaration (name, description, schema) is read again at the start
/// of each voice session, so only the everyday tools are declared directly.
/// The others are found with find_tool, which returns their description and
/// schema as text, and run with use_tool, which goes through the same
/// dispatch as a direct call (GeminiLiveVoiceClient.dispatchFunctionCall).
@MainActor
enum GeminiLiveToolCatalog {
    static let findToolFunctionName = "find_tool"
    static let useToolFunctionName = "use_tool"

    /// Tools a user reaches for in a normal day, kept direct so they never
    /// cost an extra round trip through find_tool.
    static let directFunctionNames: Set<String> = [
        "point_at_element", "send_to_higher_model", "search_web",
        "do_task_on_screen", "stop_screen_task", "answer_screen_job",
        "guide_user", "guide_next", "stop_guide",
        "start_helper", "list_helpers", "check_helper",
        "recall_memory", "remember", "ask_brain",
        "control_device",
        "click_on_screen", "press_keys", "open_url", "type_text", "copy_to_clipboard",
        "run_applescript", "get_schedule", "add_reminder",
        // The user's connected apps (Home → Tools). Through use_tool, a
        // connected app's arguments were JSON inside JSON, and Live often
        // gave up or sent them wrong.
        "apps_and_tools", "use_app_tool",
        // Drawing. Through use_tool, a drawing's steps were JSON inside
        // JSON, and asks that didn't say "draw" never found the tool.
        "explain_on_screen", "draw_on_screen", "clear_drawings", "write_notes", "read_closely",
        // Opening apps, windows, music and volume done on the Mac by the
        // instant lane and Needle, mid-answer, with no screenshot.
        "quick_mac_action"
    ]

    /// One line for the voice prompt naming what the hidden tools cover, so
    /// the model knows to look for them. Keep it in step with what isn't in
    /// directFunctionNames.
    static let hiddenToolAreasSummary = "scrolling, your cursor's shape (change_cursor), the browser and its tabs, screenshots, apple shortcuts, adding calendar events, the reminders list and ticking one off, contacts, meeting notes, projects (list_projects) and helper teams, stopping helpers and opening what they made, saved pictures (find_pictures, save_picture), smart home device list (home_devices) and tv jobs, memories by time and forgetting (memories), games, recording gameplay (gameplay_recording), your level, 24/7 jobs, rewriting selected text, watching the screen for something, focus mode, folder cleanup, replays of past screen jobs, learned shortcuts (learned_shortcuts), the user's saved form details (form_details), smart replays (smart_replays: watch the user do a job once, then redo it by meaning; commercial ones for filming), self-check, about yourself and your settings (about_me), saving the user's corrections about how an app works (save_app_lesson), installing skills for the Dots from a folder (install_skills), installing command-line tools, the code editor (code_editor: open, show or change code in Home → Code), watch-and-learn how-tos (watch_and_learn), and away mode (away_mode)"

    /// Extra words find_tool matches on, for asks that don't share words
    /// with the tool's description ("turn into a cat" → change_cursor).
    private static let extraSearchWordsByToolName: [String: String] = [
        "stop_helper": "stop cancel helper dot",
        "gameplay_recording": "record recording gameplay game me playing capture keys keybinds clip replay play back do what i recorded routine",
        "open_helper_result": "open show result website file folder helper made",
        "type_text": "type write enter text field",
        "scroll_screen": "scroll page down up",
        "draw_on_screen": "draw circle mark highlight arrow box underline annotate",
        "clear_drawings": "clear erase drawings remove marks",
        "run_shortcut": "shortcut shortcuts apple homekit scene run",
        "list_shortcuts": "shortcuts list apple",
        "add_calendar_event": "calendar event meeting appointment add book schedule",
        "get_reminders": "reminders todo list tasks",
        "complete_reminder": "reminder done tick complete check off",
        "find_contact": "contact phone number email birthday address person",
        "browser": "browser tab tabs web page website form fill read safari chrome",
        "form_details": "form forms fill my details name email phone address postcode remember save forget autofill",
        "meeting_notes": "meeting notes call record transcribe minutes",
        "take_screenshot": "screenshot screen grab capture",
        "list_projects": "projects project folder list",
        "start_team": "team helpers parallel split big job",
        "save_picture": "save picture remember look image",
        "find_pictures": "pictures picture image saved find showed",
        "change_cursor": "cursor pet shape costume turn into cat dog animal emoji walk roam look",
        "explain_on_screen": "explain draw teach math geometry graph equation diagram board plot tutor sketch picture drawing animal horse",
        "code_on_screen": "code build website app project editor vscode cursor type typing human speed on screen commercial demo program write code",
        "read_closely": "read closely zoom close-up small text exponent power superscript math question exam homework formula equation misread",
        "write_notes": "notes note take write notebook study summary working solution steps equation formula chemistry physics science bullet heading",
        "home_devices": "smart home devices lights tv list connected",
        "tv_task": "tv television episode youtube netflix show",
        "memories": "memories episodes forget recent yesterday history past happened",
        "game": "game play trivia twenty questions drawing word chain fun",
        "dottie_level": "level xp streak unlock unlocks wear",
        "keep_working": "nonstop night keep working repeat every minutes background routine routines stop cancel schedule hourly",
        "apps_and_tools": "connected apps notion github slack tools integrations",
        "use_app_tool": "connected app run tool notion github slack",
        "fix_text": "fix rewrite selected text grammar spelling translate shorten formal",
        "watch": "watch alert notify tell when download finishes loads",
        "focus": "focus block distractions pomodoro concentrate",
        "clean_folder": "clean tidy organize folder downloads desktop duplicates",
        "replays": "replay replays redo again saved jobs shortcut when i say rename call it first second",
        "install_skills": "install add import skills skill folder set pack dots helpers skill.md",
        "save_app_lesson": "wrong correct correction actually no it is that is not where app lesson remember how app works",
        "smart_replays": "create smart replay commercial replay of me doing this watch me record steps show you how redo closing line say at the end edit filming",
        "self_check": "broken working diagnose check test sound microphone problem",
        "about_me": "dottie yourself settings version features permission help how tour update account",
        "install_tool": "install command line cli homebrew brew npm pip uninstall",
        "code_editor": "code editor file open edit change program script coder project source",
        "watch_and_learn": "watch me learn how to show you teach seconds",
        "away_mode": "away leaving heading out back home phone while gone"
    ]

    private static let maximumToolsPerSearch = 3
    /// Needle's centered similarity (DottieNeedleRouter) below which a
    /// tool isn't really related. Measured: right tools 0.13 to 0.34.
    private static let leastMeaningSimilarityForBonus: Float = 0.1

    /// Words too common to tell tools apart.
    private static let ignoredSearchWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "what", "want", "wants", "user", "can", "you", "your",
        "my", "me", "to", "a", "an", "of", "in", "on", "it", "is", "do", "be", "at", "or", "some", "something", "please"
    ]

    static let findToolFunctionDeclaration: [String: Any] = [
        "name": findToolFunctionName,
        "description": "Find one of your other tools (listed by area in your instructions) for what the user wants. Returns the best matches with their description and arguments; then run one with use_tool. Skip it when you already know the tool's name and arguments.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "what": [
                    "type": "STRING",
                    "description": "What the user wants, in a few words, like 'take a screenshot' or 'turn into a cat'."
                ]
            ],
            "required": ["what"]
        ]
    ]

    static let useToolFunctionDeclaration: [String: Any] = [
        "name": useToolFunctionName,
        "description": "Run one of your other tools by name (from find_tool or your instructions). Its result comes back like any tool's.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "name": [
                    "type": "STRING",
                    "description": "The tool's exact name, like take_screenshot."
                ],
                "arguments_json": [
                    "type": "STRING",
                    "description": "The tool's arguments as a JSON object, like {\"what\": \"window\"}. {} for none."
                ]
            ],
            "required": ["name", "arguments_json"]
        ]
    ]

    /// use_tool's arguments_json as a dictionary. Empty or missing means no
    /// arguments; nil means it wasn't a JSON object, so use_tool reports it.
    static func parsedToolArguments(from argumentsJSONValue: Any?) -> [String: Any]? {
        // The schema says string, but take an object too if the model sent one.
        if let argumentsDictionary = argumentsJSONValue as? [String: Any] {
            return argumentsDictionary
        }
        let argumentsJSONText = (argumentsJSONValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if argumentsJSONText.isEmpty {
            return [:]
        }
        guard let parsedArguments = try? JSONSerialization.jsonObject(with: Data(argumentsJSONText.utf8)) as? [String: Any] else {
            return nil
        }
        return parsedArguments
    }

    /// find_tool's answer: the best few hidden tools for the ask, each with
    /// its name, description and argument schema. When nothing matches, the
    /// names of every hidden tool, so the model can try again.
    static func matchingToolsText(
        for whatTheUserWants: String,
        amongHiddenDeclarations hiddenDeclarations: [[String: Any]],
        toolsRankedByMeaning: [(name: String, similarity: Float)] = []
    ) -> String {
        let queryWords = searchWords(in: whatTheUserWants)
        let normalizedQuery = whatTheUserWants.lowercased().replacingOccurrences(of: " ", with: "_")
        // Needle's closest three by meaning get a nudge (3, 2, 1), but only
        // when they're a real match: unrelated tools score near 0.
        var meaningBonusByToolName: [String: Int] = [:]
        for (rankIndex, rankedTool) in toolsRankedByMeaning.prefix(3).enumerated() where rankedTool.similarity >= Self.leastMeaningSimilarityForBonus {
            meaningBonusByToolName[rankedTool.name] = 3 - rankIndex
        }

        var scoredDeclarations: [(declaration: [String: Any], score: Int)] = []
        for declaration in hiddenDeclarations {
            guard let toolName = declaration["name"] as? String else { continue }
            let toolDescription = declaration["description"] as? String ?? ""
            let nameAndExtraWords = searchWords(in: toolName.replacingOccurrences(of: "_", with: " ") + " " + (extraSearchWordsByToolName[toolName] ?? ""))
            let descriptionWords = searchWords(in: toolDescription)

            var score = 0
            // The model often already knows the name it wants.
            if normalizedQuery.contains(toolName) {
                score += 100
            }
            for queryWord in queryWords {
                if nameAndExtraWords.contains(queryWord) {
                    score += 3
                } else if descriptionWords.contains(queryWord) {
                    score += 1
                }
            }
            score += meaningBonusByToolName[toolName] ?? 0
            if score > 0 {
                scoredDeclarations.append((declaration: declaration, score: score))
            }
        }

        let bestDeclarations = scoredDeclarations
            .sorted { $0.score > $1.score }
            .prefix(maximumToolsPerSearch)
            .map { scoredDeclaration in scoredDeclaration.declaration }

        guard !bestDeclarations.isEmpty else {
            let hiddenToolNames = hiddenDeclarations.compactMap { $0["name"] as? String }.sorted()
            return "no tool matched \"\(whatTheUserWants)\". the tools you can find are: \(hiddenToolNames.joined(separator: ", ")). call find_tool again with other words or one of these names."
        }

        let toolTexts = bestDeclarations.map { declaration -> String in
            let toolName = declaration["name"] as? String ?? ""
            let toolDescription = declaration["description"] as? String ?? ""
            var toolText = "name: \(toolName)\ndescription: \(toolDescription)"
            if let parameters = declaration["parameters"],
               JSONSerialization.isValidJSONObject(parameters),
               let parametersData = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys, .withoutEscapingSlashes]) {
                toolText += "\narguments schema: " + String(decoding: parametersData, as: UTF8.self)
            }
            return toolText
        }
        return toolTexts.joined(separator: "\n\n")
            + "\n\nrun one with use_tool: name, and arguments_json as a JSON object string ({} for none). don't tell the user about this lookup."
    }

    /// Lowercased words of two or more letters (so "tv" counts), without a
    /// plural s, so "reminders" finds "reminder".
    private static func searchWords(in text: String) -> Set<String> {
        let rawWords = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        var words: Set<String> = []
        for rawWord in rawWords where rawWord.count >= 2 && !ignoredSearchWords.contains(rawWord) {
            if rawWord.count > 3 && rawWord.hasSuffix("s") && !rawWord.hasSuffix("ss") {
                words.insert(String(rawWord.dropLast()))
            } else {
                words.insert(rawWord)
            }
        }
        return words
    }
}
