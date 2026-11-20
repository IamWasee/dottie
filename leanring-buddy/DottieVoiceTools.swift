//
//  DottieVoiceTools.swift
//  leanring-buddy
//
//  Voice Dottie's tools: their declarations and the one dispatch that runs
//  them. The talker's requests (Claude, see DottieTalker) call them through
//  runTool(functionName:arguments:) and get the answer back as a dictionary.
//  Only the everyday tools are declared up front (DottieVoiceToolCatalog);
//  the rest are found with find_tool and run with use_tool through the same
//  dispatch. Gemini Live, which these tools were first written for, is gone.
//

import Foundation

@MainActor
final class DottieVoiceTools {
    // MARK: - Callbacks (all delivered on the main actor)

    /// Hands a hard question to a stronger model; the answer is the tool result.
    var onHigherModelRequest: (@MainActor (_ question: String) async -> String)?
    /// Starts a background helper (Dot) on a task; returns a status line.
    var onStartClickyTask: (@MainActor (_ clickyName: String?, _ task: String, _ projectName: String?, _ restart: Bool) -> String)?
    /// list_helpers, check_helper, stop_helper and open_helper_result.
    var onHelperTool: (@MainActor (_ functionName: String, _ helperName: String?) -> String)?
    /// recall_memory, remember and ask_brain.
    var onBrainTool: (@MainActor (_ functionName: String, _ text: String) -> String)?
    /// One click, key press, scroll, page or drawing on the screen.
    var onScreenAction: (@MainActor (DottieScreenAction) async -> String)?
    /// Starts a multi-step screen job; returns a status line.
    var onStartScreenTask: (@MainActor (_ task: String, _ referenceImageNames: [String], _ restart: Bool) -> String)?
    /// Stops screen jobs, guides or helpers; returns a status line.
    var onStopScreenTask: (@MainActor (_ scope: String) -> String)?
    /// Starts a guide that teaches an app on screen.
    var onStartGuide: (@MainActor (_ goal: String, _ mode: String) -> String)?
    var onGuideNext: (@MainActor () -> String)?
    var onStopGuide: (@MainActor () -> String)?
    /// Shortcuts, AppleScript, Calendar, Reminders, Contacts, the browser,
    /// work tools, the cursor pet, smart home and teaching.
    var onMacTool: (@MainActor (_ functionName: String, _ arguments: [String: Any]) async -> String)?

    // MARK: - Running a tool

    /// Calls waiting for their tool's answer, by call id.
    private var waitingToolCalls: [String: CheckedContinuation<[String: Any], Never>] = [:]
    /// A screen job or helper can run for minutes; the caller is told it's
    /// still going rather than waiting that long.
    private static let toolWaitSeconds: UInt64 = 90

    /// Runs one of voice Dottie's tools by name and returns its response
    /// ("result" or "error").
    func runTool(functionName: String, arguments: [String: Any]) async -> [String: Any] {
        let functionCallID = UUID().uuidString
        let waitSeconds = Self.toolWaitSeconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: waitSeconds * 1_000_000_000)
            self?.waitingToolCalls.removeValue(forKey: functionCallID)?
                .resume(returning: ["result": "still working on it; it reports back by itself when done"])
        }
        return await withCheckedContinuation { continuation in
            waitingToolCalls[functionCallID] = continuation
            switch functionName {
            case DottieVoiceToolCatalog.findToolFunctionName:
                handleFindToolCall(functionCallID: functionCallID, functionArguments: arguments)
            case DottieVoiceToolCatalog.useToolFunctionName:
                handleUseToolCall(functionCallID: functionCallID, functionArguments: arguments)
            default:
                guard Self.everyFunctionName.contains(functionName) else {
                    waitingToolCalls.removeValue(forKey: functionCallID)?
                        .resume(returning: ["error": "there's no tool named \(functionName)"])
                    return
                }
                dispatchFunctionCall(functionName: functionName, functionCallID: functionCallID, functionArguments: arguments)
            }
        }
    }

    /// Hands a tool's answer back to the call waiting on it.
    private func finishToolCall(functionCallID: String, functionName: String, response: [String: Any]) {
        waitingToolCalls.removeValue(forKey: functionCallID)?.resume(returning: response)
    }

    // MARK: - Declarations

    /// Tool the model calls to make the blue cursor fly to a UI element.
    /// Coordinates are 0–1000 normalized on the frame, which is the space
    /// Gemini's vision models are trained to point in.
    private static let pointAtElementFunctionDeclaration: [String: Any] = [
        "name": "point_at_element",
        "description": "Fly the user's blue companion cursor to a specific UI element visible in the most recent screen frame. Use it whenever pointing at something on screen would help: a button, menu, field, icon, or area the user is asking about. Call it at most once per answer, before or while you speak.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "x": [
                    "type": "INTEGER",
                    "description": "Horizontal position of the element's center, normalized 0 (left edge of the frame) to 1000 (right edge)."
                ],
                "y": [
                    "type": "INTEGER",
                    "description": "Vertical position of the element's center, normalized 0 (top edge of the frame) to 1000 (bottom edge)."
                ],
                "label": [
                    "type": "STRING",
                    "description": "The element's visible text, exactly as it appears on screen when it has its own text (like 'Sign in' or 'Downloads'). For an icon, a 1-3 word name of what it is, like 'like button', 'comments icon' or 'download icon', never a number or count shown next to it. The app uses it to find the exact spot."
                ]
            ],
            "required": ["x", "y", "label"]
        ]
    ]

    /// send_to_higher_model: the fast voice model
    /// hands off questions that need careful reading or reasoning.
    private static let sendToHigherModelFunctionDeclaration: [String: Any] = [
        "name": "send_to_higher_model",
        "description": "Hand a question to a slower, smarter model that gets fresh full-resolution screenshots of every screen. Use it when the answer needs careful reading of small text, code, a long document or dense UI, multi-step reasoning, math, or precise step-by-step instructions. Don't use it for casual chat or quick answers you're confident about. Before calling, say a few words like \"let me take a closer look\". The result is the answer: say it to the user in your own voice, keeping its meaning.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "question": [
                    "type": "STRING",
                    "description": "The user's question, restated so it stands on its own, with any context from the conversation that the smarter model needs."
                ]
            ],
            "required": ["question"]
        ]
    ]

    /// Hands longer jobs to a background agent (see ClickyRoster).
    private static let startClickyTaskFunctionDeclaration: [String: Any] = [
        "name": "start_helper",
        "description": "Start a task with one of the user's background helpers (also called Dots). Helpers work on their own in the background on the user's Mac, like Claude: the user's connected apps and APIs (for example Roblox Studio, Notion, Gmail), command-line tools and scripts, the user's own signed-in browser, and Dottie's cursor for the on-screen parts; when one way fails they try the next. They can research, collect things from websites, make Word and Excel files, organize files, write code, build complete websites, small apps or a Roblox game, and they save what they figured out as skills for next time. Use it whenever the user asks for real work beyond answering, work that spans several apps or sources, or asks a helper to do something. After calling, say briefly that it's started.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "helper_name": [
                    "type": "STRING",
                    "description": "Name of the helper the user mentioned, if any. Leave empty to use an idle helper or make one."
                ],
                "task": [
                    "type": "STRING",
                    "description": "The task, written so it stands on its own: what to do, any details from the conversation or screen, and what the finished result should be."
                ],
                "project": [
                    "type": "STRING",
                    "description": "The project this belongs to, for anything being built or worked on over time: an existing project's name to continue it, or a short new name (2-4 words) for something new. Leave empty for one-off tasks like a quick lookup."
                ],
                "restart": [
                    "type": "BOOLEAN",
                    "description": "True only after the user said yes to starting over a task that matches one a helper is already doing or that was cut off when Dottie closed. Leave out otherwise."
                ]
            ],
            "required": ["task"]
        ]
    ]

    private static let listHelpersFunctionDeclaration: [String: Any] = [
        "name": "list_helpers",
        "description": "List the user's helpers as they are right now: which exist, which were deleted, and what each is doing (working, finished, stuck, waiting for permission). Always call this before talking about helpers; never rely on memory.",
        "parameters": ["type": "OBJECT", "properties": [String: Any]()]
    ]

    private static func helperFunctionDeclaration(name: String, description: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "helper_name": [
                        "type": "STRING",
                        "description": "The helper's name. Leave empty for the most recently active one."
                    ]
                ]
            ]
        ]
    }

    private static func brainFunctionDeclaration(name: String, description: String, argumentName: String, argumentDescription: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": [
                "type": "OBJECT",
                "properties": [argumentName: ["type": "STRING", "description": argumentDescription]],
                "required": [argumentName]
            ]
        ]
    }

    /// The second brain: memory search, saving a memory, and the Brain agent.
    private static let brainFunctionDeclarations: [[String: Any]] = [
        brainFunctionDeclaration(
            name: "recall_memory",
            description: "Search everything remembered about the user: past conversations, what helpers did, guides, screen jobs, things they asked you to remember, and what they were doing on screen. Use it whenever they ask about the past.",
            argumentName: "query",
            argumentDescription: "A few keywords for what to look for."
        ),
        brainFunctionDeclaration(
            name: "remember",
            description: "Save something the user asked you to remember.",
            argumentName: "fact",
            argumentDescription: "The thing to remember, written so it stands on its own."
        ),
        brainFunctionDeclaration(
            name: "ask_brain",
            description: "Hand a question or job to your second brain, which can search the user's shared folders and memory and use their command-line tools and connected apps. Use it for anything about their files, folders, repos or tools, or that needs real digging. Its answer comes back to you in a later message.",
            argumentName: "question",
            argumentDescription: "The question or job, written so it stands on its own."
        )
    ]

    private static let helperStatusFunctionDeclarations: [[String: Any]] = [
        listHelpersFunctionDeclaration,
        helperFunctionDeclaration(
            name: "check_helper",
            description: "Get one helper's current status, latest task, recent steps, latest reply and the files it made. Use it when the user asks how a helper is doing or what it said."
        ),
        helperFunctionDeclaration(
            name: "stop_helper",
            description: "Stop a helper that is working on something."
        ),
        helperFunctionDeclaration(
            name: "open_helper_result",
            description: "Open what a helper made for the user to see: a website in the browser, a single file in its app, or the helper's output folder."
        )
    ]

    /// Every tool voice Dottie can use: her own, screen actions, Mac tools,
    /// work tools, the cursor's shape, teaching, the smart home and the
    /// registry's voice tools. Only the everyday ones are declared up front
    /// (see directFunctionDeclarations); the rest are found with find_tool
    /// and run with use_tool, through the same dispatch.
    ///
    /// Made once: none of them change while Dottie runs, and every
    /// find_tool and use_tool call used to build the whole list again.
    static let everyFunctionDeclaration: [[String: Any]] = {
        var declarations: [[String: Any]] = coreFunctionDeclarations
        declarations += DottieScreenAction.functionDeclarations
        declarations += DottieMacTools.functionDeclarations
        declarations += DottieWorkTools.functionDeclarations
        declarations.append(DottieCursorPet.functionDeclaration)
        declarations.append(DottieTeaching.functionDeclaration)
        declarations += DottieSmartHome.functionDeclarations
        declarations += DottieToolRegistry.functionDeclarations(for: .voice)
        return declarations
    }()

    /// What the session's setup declares: the everyday tools, plus find_tool
    /// and use_tool for the rest. Every declaration is read again at the
    /// start of each session, so the rarely used ones stay out of it.
    static var directFunctionDeclarations: [[String: Any]] {
        let everydayDeclarations = everyFunctionDeclaration.filter { declaration in
            guard let toolName = declaration["name"] as? String else { return false }
            return DottieVoiceToolCatalog.directFunctionNames.contains(toolName)
        }
        return everydayDeclarations + [
            DottieVoiceToolCatalog.findToolFunctionDeclaration,
            DottieVoiceToolCatalog.useToolFunctionDeclaration
        ]
    }

    /// The tools not declared up front, which find_tool searches.
    private static let hiddenFunctionDeclarations: [[String: Any]] = everyFunctionDeclaration.filter { declaration in
        guard let toolName = declaration["name"] as? String else { return false }
        return !DottieVoiceToolCatalog.directFunctionNames.contains(toolName)
    }

    private static let everyFunctionName: Set<String> = Set(everyFunctionDeclaration.compactMap { $0["name"] as? String })

    private static var coreFunctionDeclarations: [[String: Any]] {
        [
            pointAtElementFunctionDeclaration,
            sendToHigherModelFunctionDeclaration,
            startClickyTaskFunctionDeclaration,
            searchWebFunctionDeclaration,
            doTaskOnScreenFunctionDeclaration,
            stopScreenTaskFunctionDeclaration,
            guideUserFunctionDeclaration,
            guideNextFunctionDeclaration,
            stopGuideFunctionDeclaration
        ] + helperStatusFunctionDeclarations + brainFunctionDeclarations
    }

    /// Teaching the app on screen, step by step or as a tour (DottieGuide).
    private static let guideUserFunctionDeclaration: [String: Any] = [
        "name": "guide_user",
        "description": "Teach the user the app on their screen. Use when they want to learn how to do something themselves ('how do I add a sound effect in premiere', 'where do I go to export', 'walk me through making a pivot table') or want a tour or rundown of the app ('show me around', 'give me a rundown of everything here'). steps mode walks them through it one click at a time: the app points and draws on screen, they click, and the next step appears. tour mode marks the main parts of the window one by one and explains each. The app shows every step on screen and you'll get each line to say. After calling, say only a few words like 'let me show you'.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "goal": [
                    "type": "STRING",
                    "description": "What the user wants to learn or do, in their words, with the app's name and any details they gave."
                ],
                "mode": [
                    "type": "STRING",
                    "enum": ["steps", "tour"],
                    "description": "steps to walk them through doing something; tour for a rundown of the app or screen."
                ]
            ],
            "required": ["goal", "mode"]
        ]
    ]

    private static let guideNextFunctionDeclaration: [String: Any] = [
        "name": "guide_next",
        "description": "During a guide, when the user says next, continue, done, got it, or that they did the step, so the guide moves on.",
        "parameters": ["type": "OBJECT", "properties": [String: Any]()]
    ]

    private static let stopGuideFunctionDeclaration: [String: Any] = [
        "name": "stop_guide",
        "description": "Stop the guide that's running, when the user says stop, that's enough, or never mind.",
        "parameters": ["type": "OBJECT", "properties": [String: Any]()]
    ]

    /// Multi-step jobs on the screen, done by DottieScreenTaskRunner.
    private static let doTaskOnScreenFunctionDeclaration: [String: Any] = [
        "name": "do_task_on_screen",
        "description": "Do a job on the user's screen that takes several steps, all in one go. If a job is already running, this one waits in line and starts when it finishes: opening apps, going to sites, searching, clicking through pages, typing, scrolling, and reading what's there. Example: 'open opera, search kaggle, go to my competitions, open the RSNA knee one and tell me my rank'. Also for a goal that sounds like one click but needs more to be done, like 'sign in with this account' (done when signed in, not when the account is clicked). Pass the whole goal, every step; it works out the steps itself and asks the user only if it must. Dottie's cursor does it step by step and you'll get the result in a later message to tell the user. Only when the user asks you to do it, and when no connected app (apps_and_tools) can do it instead: a connected GitHub, Notion, Gmail and the like answer far faster and more surely than clicking. After calling, just say you're on it in a few words.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "task": [
                    "type": "STRING",
                    "description": "The whole job in the user's words, every step in order, plus details from the conversation (names, apps, what to report back)."
                ],
                "reference_images": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"],
                    "description": "Names of saved pictures the user showed you that this job is about, exactly as find_pictures names them, like ['golden sword']. The job gets the pictures to match on screen."
                ],
                "restart": [
                    "type": "BOOLEAN",
                    "description": "True only after the user said yes to starting over a job that matches one already running, waiting, or cut off when Dottie closed. Leave out otherwise."
                ]
            ],
            "required": ["task"]
        ]
    ]

    private static let stopScreenTaskFunctionDeclaration: [String: Any] = [
        "name": "stop_screen_task",
        "description": "Manage on-screen jobs: stop everything and clear the waiting list (scope all: stop, cancel, never mind), skip only the running job so the next one starts (scope current: skip this one, next), or hear what's running and waiting (scope list).",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "scope": [
                    "type": "STRING",
                    "enum": ["all", "current", "list"],
                    "description": "all, current or list. Defaults to all."
                ]
            ]
        ]
    ]

    private static let searchWebFunctionDeclaration: [String: Any] = [
        "name": "search_web",
        "description": "Search the web for fresh or specific facts you don't know for sure: news, prices, scores, weather, opening hours, release dates, recent versions, or anything that may have changed. Say a few words first, like \"let me look that up\". The result has search results and the text of the top page; answer from it in a sentence or two.",
        "parameters": [
            "type": "OBJECT",
            "properties": [
                "query": [
                    "type": "STRING",
                    "description": "What to search for, written like a search engine query."
                ]
            ],
            "required": ["query"]
        ]
    ]

    // MARK: - Dispatch

    /// find_tool: the hidden tools that best match what the user wants,
    /// with their descriptions and argument schemas, for use_tool.
    private func handleFindToolCall(functionCallID: String, functionArguments: [String: Any]) {
        let whatTheUserWants = (functionArguments["what"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { [weak self] in
            // Needle's sense of meaning nudges the word match (a few ms;
            // nothing when Needle isn't there).
            let toolsRankedByMeaning = await DottieNeedleRouter.shared.hiddenToolsRankedByMeaning(
                for: whatTheUserWants,
                amongHiddenDeclarations: Self.hiddenFunctionDeclarations
            )
            let matchingToolsText = DottieVoiceToolCatalog.matchingToolsText(
                for: whatTheUserWants,
                amongHiddenDeclarations: Self.hiddenFunctionDeclarations,
                toolsRankedByMeaning: toolsRankedByMeaning
            )
            self?.finishToolCall(functionCallID: functionCallID, functionName: DottieVoiceToolCatalog.findToolFunctionName,
                                       response: ["result": matchingToolsText])
        }
    }

    /// use_tool: runs a hidden tool through exactly the dispatch it would
    /// get if it had been called by name.
    private func handleUseToolCall(functionCallID: String, functionArguments: [String: Any]) {
        let useToolFunctionName = DottieVoiceToolCatalog.useToolFunctionName
        let requestedToolName = (functionArguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requestedToolName.isEmpty else {
            finishToolCall(functionCallID: functionCallID, functionName: useToolFunctionName,
                                 response: ["error": "name was empty. call find_tool with what the user wants to get a tool's name."])
            return
        }
        guard requestedToolName != DottieVoiceToolCatalog.findToolFunctionName,
              requestedToolName != useToolFunctionName,
              Self.everyFunctionName.contains(requestedToolName) else {
            finishToolCall(functionCallID: functionCallID, functionName: useToolFunctionName,
                                 response: ["error": "there's no tool named \(requestedToolName). call find_tool with what the user wants to get the right name."])
            return
        }
        guard let requestedToolArguments = DottieVoiceToolCatalog.parsedToolArguments(from: functionArguments["arguments_json"]) else {
            finishToolCall(functionCallID: functionCallID, functionName: useToolFunctionName,
                                 response: ["error": "arguments_json must be a JSON object like {\"action\": \"start\"}, or {} for none. call use_tool again with valid JSON."])
            return
        }
        dispatchFunctionCall(functionName: requestedToolName, functionCallID: functionCallID, functionArguments: requestedToolArguments)
    }

    /// Runs one tool call by name. Direct calls and use_tool's both go
    /// through here, so a tool behaves the same whichever way it's called.
    private func dispatchFunctionCall(functionName: String, functionCallID: String, functionArguments: [String: Any]) {
        switch functionName {
        case "point_at_element":
            handlePointAtElementCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "send_to_higher_model":
            handleSendToHigherModelCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "start_helper":
            handleStartClickyTaskCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "recall_memory", "remember", "ask_brain":
            let argumentName = functionName == "recall_memory" ? "query" : (functionName == "remember" ? "fact" : "question")
            let argumentText = (functionArguments[argumentName] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let brainResult: String
            if argumentText.isEmpty && functionName != "recall_memory" {
                brainResult = "nothing to \(functionName == "remember" ? "remember" : "ask")."
            } else {
                brainResult = onBrainTool?(functionName, argumentText) ?? "the brain isn't available right now."
            }
            finishToolCall(functionCallID: functionCallID, functionName: functionName, response: ["result": brainResult])
        case "list_helpers", "check_helper", "stop_helper", "open_helper_result":
            let helperName = (functionArguments["helper_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let helperResult = onHelperTool?(functionName, helperName?.isEmpty == true ? nil : helperName)
                ?? "helpers aren't available right now."
            finishToolCall(functionCallID: functionCallID, functionName: functionName, response: ["result": helperResult])
        case "search_web":
            handleSearchWebCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "do_task_on_screen":
            handleDoTaskOnScreenCall(functionCallID: functionCallID, functionArguments: functionArguments)
        case "guide_user":
            let goal = (functionArguments["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mode = (functionArguments["mode"] as? String) ?? "steps"
            if !goal.isEmpty, let guideStatus = onStartGuide?(goal, mode) {
                finishToolCall(functionCallID: functionCallID, functionName: functionName, response: ["result": guideStatus])
            } else {
                finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                     response: ["error": "couldn't start a guide right now."])
            }
        case "guide_next":
            finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                 response: ["result": onGuideNext?() ?? "no guide is running."])
        case "stop_guide":
            finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                 response: ["result": onStopGuide?() ?? "no guide is running."])
        case "stop_screen_task":
            let scope = (functionArguments["scope"] as? String)?.lowercased() ?? "all"
            let stopStatus = onStopScreenTask?(scope) ?? "nothing is running."
            finishToolCall(functionCallID: functionCallID, functionName: functionName, response: ["result": stopStatus])
        case _ where DottieScreenAction.functionNames.contains(functionName):
            handleScreenActionCall(functionCallID: functionCallID, functionName: functionName, functionArguments: functionArguments)
        case _ where DottieMacTools.functionNames.contains(functionName) || DottieWorkTools.functionNames.contains(functionName)
            || functionName == DottieCursorPet.functionName || DottieSmartHome.functionNames.contains(functionName)
            || functionName == DottieTeaching.functionName:
            handleMacToolCall(functionCallID: functionCallID, functionName: functionName, functionArguments: functionArguments)
        case _ where DottieToolRegistry.handles(functionName, for: .voice):
            handleRegisteredToolCall(functionCallID: functionCallID, functionName: functionName, functionArguments: functionArguments)
        default:
            finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                 response: ["error": "unknown function"])
        }
    }

    /// The cursor flies from a [POINT:] tag in the spoken answer
    /// (CompanionManager+ClassicVoice), so the call only says how to point.
    private func handlePointAtElementCall(functionCallID: String, functionArguments: [String: Any]) {
        guard (functionArguments["x"] as? NSNumber) != nil, (functionArguments["y"] as? NSNumber) != nil else {
            finishToolCall(functionCallID: functionCallID, functionName: "point_at_element",
                           response: ["error": "x and y are required"])
            return
        }
        finishToolCall(functionCallID: functionCallID, functionName: "point_at_element",
                       response: ["result": "to point, end your answer with a [POINT:x,y:label] tag at the same spot. keep talking to the user."])
    }

    /// Hands the question to a stronger model with fresh screenshots; its
    /// answer is the tool result.
    private func handleSendToHigherModelCall(functionCallID: String, functionArguments: [String: Any]) {
        let question = (functionArguments["question"] as? String) ?? ""
        guard let onHigherModelRequest else {
            finishToolCall(functionCallID: functionCallID, functionName: "send_to_higher_model",
                                 response: ["error": "the deeper model isn't available. answer as best you can yourself."])
            return
        }

        Task { [weak self] in
            let higherModelAnswer = await onHigherModelRequest(question)
            guard let self else { return }
            self.finishToolCall(
                functionCallID: functionCallID,
                functionName: "send_to_higher_model",
                response: ["result": higherModelAnswer]
            )
        }
    }

    /// Web results for the caller to answer from.
    private func handleSearchWebCall(functionCallID: String, functionArguments: [String: Any]) {
        let query = ((functionArguments["query"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            finishToolCall(functionCallID: functionCallID, functionName: "search_web",
                                 response: ["error": "the query was empty."])
            return
        }

        Task { [weak self] in
            let searchResults = await DottieWebSearch.search(query)
            guard let self else { return }
            self.finishToolCall(
                functionCallID: functionCallID,
                functionName: "search_web",
                response: ["result": searchResults]
            )
        }
    }

    /// Clicks, typing, keys, scrolling, pages and drawing; the result says
    /// what happened.
    private func handleScreenActionCall(functionCallID: String, functionName: String, functionArguments: [String: Any]) {
        guard let onScreenAction,
              let screenAction = DottieScreenAction(functionName: functionName, arguments: functionArguments) else {
            finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                 response: ["error": "couldn't do that right now."])
            return
        }

        Task { [weak self] in
            let actionResult = await onScreenAction(screenAction)
            guard let self else { return }
            self.finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                      response: ["result": actionResult])
        }
    }

    private func handleMacToolCall(functionCallID: String, functionName: String, functionArguments: [String: Any]) {
        guard let onMacTool else {
            finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                 response: ["error": "couldn't do that right now."])
            return
        }
        Task { [weak self] in
            let toolResult = await onMacTool(functionName, functionArguments)
            guard let self else { return }
            self.finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                      response: ["result": toolResult])
        }
    }

    /// A tool a feature added through DottieToolRegistry.
    private func handleRegisteredToolCall(functionCallID: String, functionName: String, functionArguments: [String: Any]) {
        Task { [weak self] in
            let toolResult = await DottieToolRegistry.run(functionName, arguments: functionArguments, for: .voice)
                ?? "couldn't do that right now."
            guard let self else { return }
            self.finishToolCall(functionCallID: functionCallID, functionName: functionName,
                                      response: ["result": toolResult])
        }
    }

    private func handleDoTaskOnScreenCall(functionCallID: String, functionArguments: [String: Any]) {
        let taskText = (functionArguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !taskText.isEmpty, let onStartScreenTask else {
            finishToolCall(functionCallID: functionCallID, functionName: "do_task_on_screen",
                                 response: ["error": "couldn't start that right now."])
            return
        }
        let referenceImageNames = (functionArguments["reference_images"] as? [Any])?.compactMap { $0 as? String } ?? []
        let restart = (functionArguments["restart"] as? Bool) ?? ((functionArguments["restart"] as? NSNumber)?.boolValue ?? false)
        finishToolCall(functionCallID: functionCallID, functionName: "do_task_on_screen",
                             response: ["result": onStartScreenTask(taskText, referenceImageNames, restart)])
    }

    private func handleStartClickyTaskCall(functionCallID: String, functionArguments: [String: Any]) {
        let taskText = (functionArguments["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !taskText.isEmpty, let onStartClickyTask else {
            finishToolCall(functionCallID: functionCallID, functionName: "start_helper",
                                 response: ["error": "couldn't start a background task right now."])
            return
        }
        let requestedClickyName = (functionArguments["helper_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = (functionArguments["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let restart = (functionArguments["restart"] as? Bool) ?? ((functionArguments["restart"] as? NSNumber)?.boolValue ?? false)
        let startStatus = onStartClickyTask(
            requestedClickyName?.isEmpty == true ? nil : requestedClickyName,
            taskText,
            projectName?.isEmpty == true ? nil : projectName,
            restart
        )
        finishToolCall(functionCallID: functionCallID, functionName: "start_helper",
                             response: ["result": startStatus])
    }
}
