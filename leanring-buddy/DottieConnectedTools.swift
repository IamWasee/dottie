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
                description: "Runs one tool of a connected app. Check apps_and_tools first for the app's tool names and arguments.",
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
        return """
        the user connected these apps: \(connectedNames.joined(separator: ", ")). to use one, use_tool apps_and_tools {"app": name} shows its tools, then use_tool use_app_tool runs one. say what you're doing in a few words while it runs.
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

        let result = await store.callTool(server: serverName, tool: resolvedToolName, arguments: toolArguments)
        guard result.count > maximumResultLength else { return result }
        return String(result.prefix(maximumResultLength)) + "\n…(cut short; \(result.count) characters in all)"
    }
}
