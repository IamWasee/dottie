//
//  DottieTalker.swift
//  leanring-buddy
//
//  Who answers a spoken (or typed) turn now that Gemini is out. Groq talks:
//  it gets the words alone (no screenshot, a short prompt, the last few
//  exchanges) and either answers small talk itself or says the turn is a
//  request. Requests go to Claude Haiku with voice Dottie's everyday tools
//  (the rest through find_tool / use_tool) and a screenshot only when Groq
//  says the screen matters. Kokoro speaks the answer. Every part is kept to
//  as few tokens as it can be.
//

import Foundation

/// What Groq made of a turn.
enum DottieTalkDecision: Equatable {
    /// Small talk: say this.
    case say(String)
    /// A request for Claude; `needsScreen` when it's about what's on screen.
    case request(needsScreen: Bool)
}

/// One answer from the request brain: text, tool calls, or both.
struct DottieBrainAnswer {
    var text: String
    var functionCalls: [(name: String, arguments: [String: Any])]
    /// The model's turn as it came, sent back with the tool results.
    var modelContent: [String: Any]?
}

/// Building the talker's and the request brain's bodies and reading their
/// answers. Pure, so it's unit tested.
enum DottieTalkerProtocol {
    /// Groq hears this many recent exchanges; Claude a few more.
    static let talkerExchangeCount = 3
    static let requestExchangeCount = 4
    /// Each remembered line is cut to this many characters.
    static let rememberedLineCharacterLimit = 300
    static let talkerAnswerTokenLimit = 160
    /// Room for a drawing's or notes' tool call (often 1,000+ tokens); the
    /// spoken answer itself stays one sentence by the prompt, and only the
    /// tokens actually written are paid for.
    static let requestAnswerTokenLimit = 2400
    /// Tool rounds one request may take before Claude has to answer.
    static let maximumToolRounds = 6

    static let requestWord = "REQUEST"
    static let screenWord = "SCREEN"

    /// The talker's only rules. Short on purpose: it's read on every turn.
    static func talkerSystemPrompt(personalityLine: String) -> String {
        """
        \(personalityLine)
        you are dottie's voice on the user's mac. your words are spoken aloud: answer only what they asked, in one short, casual, lowercase sentence, no extra details or follow-up questions, no lists or symbols.
        if the user is only chatting (hello, how are you, jokes, opinions, a quick fact you know), answer them.
        if they want anything done or looked up, or ask about their screen, apps, files, helpers, reminders, calendar, the web, or anything you aren't sure of, reply with only \(requestWord). asking you to open, move, click, change, add, send, write or find something is always \(requestWord), even when you could explain how; never write steps or a plan. so is pointing at, drawing or explaining something on their screen, or teaching them. never say you can't do something: reply \(requestWord) instead. add \(screenWord) after it (\(requestWord) \(screenWord)) when it's about what is on their screen.
        """
    }

    static func requestSystemPrompt(personalityLine: String, profile: String) -> String {
        var prompt = """
        \(personalityLine)
        you are dottie, on the user's mac, doing what they asked. your final reply is spoken aloud: answer only what they asked, in one short, casual, lowercase sentence (two only if they asked for more). no extra details, no describing things they didn't ask about, no offers or follow-up questions, no lists, markdown or symbols.
        anything on the mac itself goes to a mac tool first, never a screen job: opening an app, folder or file, quitting, windows, music, volume or a named shortcut is quick_mac_action ("open my downloads folder", "open notes"); if it says it couldn't, use run_applescript (finder, apps' own scripting). a web page is open_url or browser, a key press press_keys, a connected app use_app_tool.
        use your tools to do things (screen jobs, helpers, the web, reminders, memory). click one thing on the screenshot with click_on_screen (0-1000 of that image); anything longer on their screen (move, drag, type, fill in), start right away with do_task_on_screen; never tell them to do it themselves or say you can't from here. find_tool finds more tools by what the user wants and use_tool runs one; check find_tool before saying you can't do something. don't repeat a tool call that worked.
        if a screenshot is attached and pointing at one thing on it helps, end your reply with [POINT:x,y:label] in that image's pixels (add :screenN for another screen); otherwise end with [POINT:none].
        to explain or mark something on their screen, draw over it with explain_on_screen (surface screen, anchors); for its own graph or diagram, or to help them understand an idea, draw on a board. worked math and notes go in write_notes.
        """
        if !profile.isEmpty {
            prompt += "\nwhat you know about the user:\n" + profile
        }
        return prompt
    }

    /// The last `count` exchanges as Gemini contents, each line cut short.
    static func historyContents(_ exchanges: [(userTranscript: String, assistantResponse: String)], count: Int) -> [[String: Any]] {
        exchanges.suffix(count).flatMap { exchange -> [[String: Any]] in
            [
                ["role": "user", "parts": [["text": shortened(exchange.userTranscript)]]],
                ["role": "model", "parts": [["text": shortened(exchange.assistantResponse)]]]
            ]
        }
    }

    static func talkerRequestBody(
        transcript: String,
        exchanges: [(userTranscript: String, assistantResponse: String)],
        personalityLine: String
    ) -> [String: Any] {
        [
            "provider": "talk",
            "systemInstruction": ["parts": [["text": talkerSystemPrompt(personalityLine: personalityLine)]]],
            "contents": historyContents(exchanges, count: talkerExchangeCount)
                + [["role": "user", "parts": [["text": transcript]]]],
            "generationConfig": ["maxOutputTokens": talkerAnswerTokenLimit, "temperature": 0.6]
        ]
    }

    /// Reads the talker's answer. An empty answer counts as a request, so a
    /// turn is never dropped.
    static func decision(fromTalkerAnswer answerText: String) -> DottieTalkDecision {
        // Groq's gpt-oss sometimes wraps its answer in a made-up tool call
        // ({"name":"assistant","arguments":"REQUEST"}), and in round 1079 that
        // JSON was shown and read aloud as Dottie's reply on celly's Mac.
        let trimmedAnswer = unwrappedToolCallText(answerText.trimmingCharacters(in: .whitespacesAndNewlines))
        // Model markup that leaked through is never something to say.
        if looksLikeModelMarkup(trimmedAnswer) {
            return .request(needsScreen: trimmedAnswer.uppercased().contains(screenWord))
        }
        let firstWord = trimmedAnswer.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).first.map(String.init) ?? ""
        if trimmedAnswer.isEmpty || firstWord.uppercased() == requestWord {
            return .request(needsScreen: trimmedAnswer.uppercased().contains(screenWord))
        }
        // Small talk is a sentence or two. Steps, lists or markdown mean
        // the talker wrote a plan for something the user wants done, so
        // Claude does it instead, looking at the screen.
        if looksLikeAPlan(trimmedAnswer) || saysItCantDoSomething(trimmedAnswer) {
            return .request(needsScreen: true)
        }
        return .say(trimmedAnswer)
    }

    /// The words inside a made-up call like {"name":"assistant","arguments":"REQUEST"}
    /// (quoted or not); any other text comes back as it was.
    static func unwrappedToolCallText(_ answerText: String) -> String {
        guard answerText.hasPrefix("{"), answerText.contains("\"arguments\"") else { return answerText }
        let pattern = #""arguments"\s*:\s*("?)([\s\S]*?)\1\s*\}\s*$"#
        guard let regularExpression = try? NSRegularExpression(pattern: pattern),
              let match = regularExpression.firstMatch(in: answerText, range: NSRange(answerText.startIndex..., in: answerText)),
              let argumentsRange = Range(match.range(at: 2), in: answerText) else { return answerText }
        let argumentsText = answerText[argumentsRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return argumentsText.isEmpty ? answerText : argumentsText
    }

    /// JSON or chat-template tokens (<|channel|>) instead of words.
    static func looksLikeModelMarkup(_ answerText: String) -> Bool {
        answerText.contains("<|") || answerText.contains("|>")
            || (answerText.hasPrefix("{") && answerText.hasSuffix("}"))
            || (answerText.hasPrefix("[") && answerText.hasSuffix("]"))
    }

    /// The talker only knows how to chat, so "i can't draw on your screen"
    /// means it kept a request for itself; Claude has the tools for it.
    static func saysItCantDoSomething(_ answerText: String) -> Bool {
        let normalizedAnswer = answerText.lowercased().replacingOccurrences(of: "’", with: "'")
        let refusalPhrases = ["i can't", "i cannot", "i can not", "i'm not able", "i am not able", "i'm unable", "i am unable", "i don't have the ability"]
        return refusalPhrases.contains { normalizedAnswer.contains($0) }
    }

    static func looksLikeAPlan(_ answerText: String) -> Bool {
        if answerText.contains("**") || answerText.contains("\n- ") || answerText.hasPrefix("- ") { return true }
        let numberedLineCount = answerText.split(separator: "\n").filter { line in
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            return trimmedLine.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil
        }.count
        return numberedLineCount >= 2
    }

    /// Claude's body for one round of a request.
    static func requestBody(
        systemPrompt: String,
        conversation: [[String: Any]],
        toolDeclarations: [[String: Any]]
    ) -> [String: Any] {
        [
            "provider": "request",
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": conversation,
            "tools": [["functionDeclarations": toolDeclarations]],
            "generationConfig": ["maxOutputTokens": requestAnswerTokenLimit]
        ]
    }

    /// The user's turn for Claude: the screenshots (when sent) then the words.
    static func requestUserTurn(transcript: String, labeledImages: [(data: Data, label: String)]) -> [String: Any] {
        var parts: [[String: Any]] = []
        for labeledImage in labeledImages {
            parts.append(["text": labeledImage.label])
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": labeledImage.data.base64EncodedString()]])
        }
        parts.append(["text": transcript])
        return ["role": "user", "parts": parts]
    }

    /// The tool results as one user turn, in the order they were asked for.
    static func toolResultsTurn(_ results: [(name: String, response: [String: Any])]) -> [String: Any] {
        [
            "role": "user",
            "parts": results.map { result in
                ["functionResponse": ["name": result.name, "response": result.response]]
            }
        ]
    }

    /// Text and tool calls from the Worker's server-sent events (Gemini
    /// format; the paid models answer in one event).
    static func brainAnswer(fromServerSentEvents responseData: Data) -> DottieBrainAnswer {
        var answer = DottieBrainAnswer(text: "", functionCalls: [], modelContent: nil)
        var allParts: [[String: Any]] = []
        let responseText = String(decoding: responseData, as: UTF8.self)
        for line in responseText.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("data:") else { continue }
            let eventJSON = trimmedLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let eventData = eventJSON.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                  let candidates = event["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            allParts += parts
            for part in parts {
                if let text = part["text"] as? String, part["thought"] as? Bool != true {
                    answer.text += text
                }
                if let functionCall = part["functionCall"] as? [String: Any],
                   let functionName = functionCall["name"] as? String {
                    answer.functionCalls.append((functionName, functionCall["args"] as? [String: Any] ?? [:]))
                }
            }
        }
        if !allParts.isEmpty {
            answer.modelContent = ["role": "model", "parts": allParts]
        }
        return answer
    }

    /// Voice Dottie's tools the request brain gets declared. The rest stay
    /// behind find_tool, so each request carries a short tool list. Pointing
    /// is a [POINT:] tag here, and there's no higher model to hand to.
    static let requestToolNames: Set<String> = [
        "do_task_on_screen", "stop_screen_task", "answer_screen_job",
        "start_helper", "check_helper", "list_helpers",
        "search_web", "guide_user", "quick_mac_action",
        "remember", "recall_memory", "get_schedule", "add_reminder",
        "copy_to_clipboard", "explain_on_screen", "write_notes", "click_on_screen",
        // Direct Mac tools. Without them Claude only had quick_mac_action or
        // a screen job, and in round 2 of 1.0.80 "open my folder" and "open
        // Notes" became screen jobs that looked at screenshots for minutes.
        "run_applescript", "open_url", "browser", "press_keys", "type_text",
        "apps_and_tools", "use_app_tool", "control_device"
    ]

    /// Mac tools the request brain must try before a screen job for an
    /// everyday Mac action. The Pre-ship check holds asks to this.
    static let macToolNames: Set<String> = [
        "quick_mac_action", "run_applescript", "open_url", "browser", "press_keys", "control_device", "use_app_tool"
    ]

    static func requestToolDeclarations(from everyDeclaration: [[String: Any]], findAndUseDeclarations: [[String: Any]]) -> [[String: Any]] {
        everyDeclaration.filter { declaration in
            guard let toolName = declaration["name"] as? String else { return false }
            return requestToolNames.contains(toolName)
        } + findAndUseDeclarations
    }

    private static func shortened(_ line: String) -> String {
        line.count <= rememberedLineCharacterLimit ? line : String(line.prefix(rememberedLineCharacterLimit)) + "…"
    }
}

/// Asking the talker and the request brain through the Worker.
@MainActor
enum DottieTalker {
    enum TalkerError: Error {
        case workerAnswered(Int)
    }

    /// What Groq makes of the turn. A failure (no Groq key, Groq down) is a
    /// request, so Claude still answers.
    static func decide(
        transcript: String,
        exchanges: [(userTranscript: String, assistantResponse: String)],
        personalityLine: String
    ) async -> DottieTalkDecision {
        let requestBody = DottieTalkerProtocol.talkerRequestBody(transcript: transcript, exchanges: exchanges, personalityLine: personalityLine)
        // Every model call from here until the next turn counts toward this ask.
        let askNumber = DottieAskCounter.startNewAsk()
        DottieLog.notice("💬 Ask \(public: askNumber) started")
        do {
            let answer = try await post(requestBody, timeoutSeconds: 12)
            let decision = DottieTalkerProtocol.decision(fromTalkerAnswer: answer.text)
            if case .request(let needsScreen) = decision {
                DottieLog.notice("🗣️ Groq handed the turn to Claude\(needsScreen ? " with the screen" : "")")
            }
            return decision
        } catch {
            DottieLog.warning("⚠️ Groq couldn't talk, handing the turn to Claude: \(error.localizedDescription)")
            return .request(needsScreen: true)
        }
    }

    /// Claude does the request, running tools through `runTool` for up to a
    /// few rounds, and returns what to say (with any [POINT:] tag).
    static func answerRequest(
        transcript: String,
        exchanges: [(userTranscript: String, assistantResponse: String)],
        labeledImages: [(data: Data, label: String)],
        systemPrompt: String,
        toolDeclarations: [[String: Any]],
        runTool: (String, [String: Any]) async -> [String: Any]
    ) async throws -> String {
        var conversation = DottieTalkerProtocol.historyContents(exchanges, count: DottieTalkerProtocol.requestExchangeCount)
        conversation.append(DottieTalkerProtocol.requestUserTurn(transcript: transcript, labeledImages: labeledImages))
        for toolRound in 0...DottieTalkerProtocol.maximumToolRounds {
            try Task.checkCancellation()
            // The last round gets no tools, so Claude has to say something.
            let isLastRound = toolRound == DottieTalkerProtocol.maximumToolRounds
            let requestBody = DottieTalkerProtocol.requestBody(
                systemPrompt: systemPrompt,
                conversation: conversation,
                toolDeclarations: isLastRound ? [] : toolDeclarations
            )
            let answer = try await post(requestBody, timeoutSeconds: 60)
            guard !answer.functionCalls.isEmpty, let modelContent = answer.modelContent, !isLastRound else {
                return answer.text
            }
            conversation.append(modelContent)
            var toolResults: [(name: String, response: [String: Any])] = []
            for functionCall in answer.functionCalls {
                DottieLog.notice("🛠️ Claude used \(public: functionCall.name)")
                toolResults.append((functionCall.name, await runTool(functionCall.name, functionCall.arguments)))
            }
            conversation.append(DottieTalkerProtocol.toolResultsTurn(toolResults))
        }
        return ""
    }

    private static func post(_ requestBody: [String: Any], timeoutSeconds: TimeInterval) async throws -> DottieBrainAnswer {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else { throw TalkerError.workerAnswered(statusCode) }
        if let answerUsage = DottieAskUsage.fromServerSentEvents(String(decoding: responseData, as: UTF8.self)) {
            DottieAskUsageLog.note(answerUsage, area: .voice, costCategory: "voice")
        }
        return DottieTalkerProtocol.brainAnswer(fromServerSentEvents: responseData)
    }
}
