//
//  DottieConnectedTools.swift
//  leanring-buddy
//
//  Lets Dottie (and helpers that take registry tools) use the apps
//  connected in Home → Tools: `apps_and_tools` says what's connected and
//  what each app can do, `use_app_tool` runs one of an app's tools.
//  Helpers also hear which command-line tools are on the Mac.
//

import Foundation

@MainActor
enum DottieConnectedTools: DottieToolModule {
    /// Longest answer handed back, so a big page can't swamp the reply.
    private static let maximumResultLength = 6000

    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "apps_and_tools",
                description: "Lists the apps the user connected (Notion, GitHub, Slack, a browser…) and the tools each one has. Give `app` to see that app's tools and their arguments.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "app": ["type": "STRING", "description": "An app's name from the list, to see its tools in detail. Leave out for the list."]
                    ]
                ],
                run: { arguments in
                    let store = DottieToolsStore.shared
                    if let app = arguments.dottieString("app") {
                        return await store.toolDetailsForAssistant(server: app)
                    }
                    return await store.summaryForAssistant()
                }
            ),
            DottieTool(
                name: "use_app_tool",
                description: "Runs one tool of a connected app. Check apps_and_tools first for the app's tool names and arguments. Try this before doing the same thing on the screen.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "app": ["type": "STRING", "description": "The app's name, as apps_and_tools lists it."],
                        "tool": ["type": "STRING", "description": "The tool's exact name."],
                        "arguments": ["type": "STRING", "description": "The tool's arguments as a JSON object, like {\"query\": \"budget\"}. Use {} for none."]
                    ],
                    "required": ["app", "tool"]
                ],
                run: { arguments in
                    await useAppTool(arguments)
                }
            )
        ]
    }

    static var voicePromptSection: String {
        let store = DottieToolsStore.shared
        let connectedNames = store.serverNames.filter { store.isEnabled($0) }
        guard !connectedNames.isEmpty else { return "" }
        // Each app's tool names from last time, so a clear ask goes
        // straight to use_app_tool instead of two apps_and_tools round trips.
        let appLines = connectedNames.map { serverName -> String in
            guard let tools = store.toolsByServer[serverName], !tools.isEmpty else { return "- \(serverName)" }
            let toolNames = tools.prefix(30).map(\.name).joined(separator: ", ")
            let more = tools.count > 30 ? " (+\(tools.count - 30) more)" : ""
            return "- \(serverName): \(toolNames)\(more)"
        }
        return """
        the user connected these apps (with their tools):
        \(appLines.joined(separator: "\n"))
        to use one, call use_app_tool right away when the tool and its arguments are obvious from its name; call apps_and_tools with the app first only when you need its arguments (never use find_tool or use_tool for these). say what you're doing in a few words while it runs.
        connected apps come first: before doing a task by hand (do_task_on_screen, clicking, the browser, a helper) or saying you can't, check whether one of these apps can do it, and if apps_and_tools shows a tool that fits, use it. only go to the screen when no connected app can, or its tool failed twice; then say so in a few words.
        """
    }

    static var helperPromptSection: String {
        DottieCLIToolsManager.helperInstructions
    }

    private static func useAppTool(_ arguments: [String: Any]) async -> String {
        let store = DottieToolsStore.shared
        guard let requestedApp = arguments.dottieString("app"),
              let toolName = arguments.dottieString("tool") else {
            return "say which app and which tool to use."
        }
        guard let serverName = store.matchServer(requestedApp) else {
            let summary = await store.summaryForAssistant()
            return "there's no connected app called \(requestedApp). " + summary
        }

        var toolArguments: [String: Any] = [:]
        if let argumentsObject = arguments["arguments"] as? [String: Any] {
            toolArguments = argumentsObject
        } else if let argumentsText = arguments.dottieString("arguments") {
            guard let argumentsData = argumentsText.data(using: .utf8),
                  let parsedArguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
                return "the arguments must be a JSON object, like {\"query\": \"budget\"}."
            }
            toolArguments = parsedArguments
        }

        // A close-but-wrong tool name gets the real list back.
        var resolvedToolName = toolName
        if let knownTools = store.toolsByServer[serverName], !knownTools.contains(where: { $0.name == toolName }) {
            if let match = knownTools.first(where: { $0.name.caseInsensitiveCompare(toolName) == .orderedSame }) {
                resolvedToolName = match.name
            } else {
                let details = await store.toolDetailsForAssistant(server: serverName)
                return "\(serverName) has no tool called \(toolName). " + details
            }
        }

        var result = await store.callTool(server: serverName, tool: resolvedToolName, arguments: toolArguments)
        if DottieGitHubLogin.isGitHubServer(store.config(for: serverName)),
           result.range(of: "404", options: .literal) != nil || result.localizedCaseInsensitiveContains("not found") {
            result += "\n" + DottieGitHubLogin.notFoundHint
            // Who the token belongs to, so the model stops guessing owners
            // (and a broken sign-in shows up as one).
            if resolvedToolName != "get_me" {
                let whoAmIResult = await store.callTool(server: serverName, tool: "get_me", arguments: [:])
                result += "\n" + DottieGitHubLogin.signedInAccountNote(fromGetMeResult: whoAmIResult)
            }
        }
        result = compactedJSONText(result)
        guard result.count > maximumResultLength else { return result }
        return String(result.prefix(maximumResultLength)) + "\n…(cut short; \(result.count) characters in all)"
    }

    /// Many apps answer with pretty-printed JSON; the indents and empty
    /// fields are often half of it, and every character slows the spoken
    /// answer. Same data, without the padding. Anything else stays as is.
    private static func compactedJSONText(_ resultText: String) -> String {
        let trimmedText = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = trimmedText.first, firstCharacter == "{" || firstCharacter == "[",
              let resultData = trimmedText.data(using: .utf8),
              let parsedObject = try? JSONSerialization.jsonObject(with: resultData),
              let compactData = try? JSONSerialization.data(withJSONObject: withoutEmptyValues(parsedObject), options: [.withoutEscapingSlashes]),
              let compactText = String(data: compactData, encoding: .utf8),
              compactText.count < trimmedText.count else { return resultText }
        return compactText
    }

    /// Drops nulls, empty strings, empty lists and empty objects.
    private static func withoutEmptyValues(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var keptValues: [String: Any] = [:]
            for (key, childValue) in dictionary {
                let cleanedValue = withoutEmptyValues(childValue)
                if cleanedValue is NSNull { continue }
                if let text = cleanedValue as? String, text.isEmpty { continue }
                if let list = cleanedValue as? [Any], list.isEmpty { continue }
                if let object = cleanedValue as? [String: Any], object.isEmpty { continue }
                keptValues[key] = cleanedValue
            }
            return keptValues
        }
        if let list = value as? [Any] {
            return list.map(withoutEmptyValues)
        }
        return value
    }
}
