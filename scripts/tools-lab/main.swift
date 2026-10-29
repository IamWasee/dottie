//
//  main.swift
//  tools-lab
//
//  Runs Dottie's own connector code (DottieToolsStore, DottieMCPClient,
//  DottieConnectedTools, DottieCLITools, DotsRuntimeInstaller) on a Mac
//  against the real servers from Home → Tools, the way the app does:
//
//    1. Dottie's own Node.js and Gemini CLI, and uv when it's missing.
//    2. Every key-free app from the catalog is added, started, and its
//       tools listed; most get one real tool call.
//    3. The voice path: apps_and_tools and use_app_tool, as Gemini Live
//       would call them through use_tool.
//    4. What helpers get: the Gemini CLI settings Dottie writes, and the
//       command-line tools they're told about.
//
//  Usage: tools-lab <folder for the files app> <git repo> <gemini cli home>
//

import Foundation

let labArguments = CommandLine.arguments
guard labArguments.count >= 4 else {
    print("usage: tools-lab <files folder> <git repo> <gemini cli home>")
    exit(2)
}
let filesFolderPath = labArguments[1]
let gitRepositoryPath = labArguments[2]
let geminiCLIHomePath = labArguments[3]

struct PlannedToolCall {
    let toolName: String
    let arguments: [String: Any]
}

/// One real call per app, with arguments from each server's own docs.
/// Apps not listed here are only started and asked for their tools.
let plannedCallsByPresetID: [String: PlannedToolCall] = [
    "filesystem": PlannedToolCall(toolName: "list_directory", arguments: ["path": filesFolderPath]),
    "fetch": PlannedToolCall(toolName: "fetch", arguments: ["url": "https://example.com", "max_length": 400]),
    "git": PlannedToolCall(toolName: "git_status", arguments: ["repo_path": gitRepositoryPath]),
    "time": PlannedToolCall(toolName: "get_current_time", arguments: ["timezone": "Asia/Tokyo"]),
    "memory": PlannedToolCall(toolName: "read_graph", arguments: [:]),
    "sequential-thinking": PlannedToolCall(toolName: "sequentialthinking", arguments: [
        "thought": "Checking that this server answers.", "nextThoughtNeeded": false, "thoughtNumber": 1, "totalThoughts": 1
    ]),
    "context7": PlannedToolCall(toolName: "resolve-library-id", arguments: ["libraryName": "react", "query": "react hooks"]),
    "exa": PlannedToolCall(toolName: "web_search_exa", arguments: ["query": "Roblox Studio MCP server", "numResults": 2]),
    "wikipedia": PlannedToolCall(toolName: "search_wikipedia", arguments: ["query": "Roblox", "limit": 2]),
    "arxiv": PlannedToolCall(toolName: "search_papers", arguments: ["query": "model context protocol", "max_results": 1]),
    "cloudflare-docs": PlannedToolCall(toolName: "search_cloudflare_documentation", arguments: ["query": "workers kv"])
]

/// Key-free apps that need nothing on the Mac but Node.js or uv.
let presetIDsToTry = [
    "filesystem", "fetch", "git", "time", "memory", "sequential-thinking",
    "context7", "exa", "wikipedia", "arxiv", "cloudflare-docs", "aws-docs",
    "youtube", "desktop-commander", "playwright", "chrome"
]

func oneLine(_ text: String, limit: Int = 160) -> String {
    let flattened = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
}

@MainActor
func runLab() async {
    print("== Environment Dottie sees (an app opened from the Dock) ==")
    print("PATH: \(ProcessInfo.processInfo.environment["PATH"] ?? "(none)")")
    await DottieCommandLocator.warmUp()
    for commandName in ["node", "npx", "uvx", "brew", "git", "python3", "claude", "gemini"] {
        print("  \(commandName): \(DottieCommandLocator.locate(commandName) ?? "not found")")
    }

    print("\n== 1. Dottie's own Node.js and Gemini CLI ==")
    let runtimeStart = Date()
    do {
        try await DotsRuntimeInstaller.shared.installIfNeeded()
        print("installed: \(DotsRuntimeInstaller.isInstalled) in \(Int(Date().timeIntervalSince(runtimeStart))) s, Node \(DotsRuntimeInstaller.nodeVersion), Gemini CLI \(DotsRuntimeInstaller.geminiCLIVersion)")
    } catch {
        print("FAILED: \(error.localizedDescription)")
    }
    if !DottieCommandLocator.isInstalled("uvx") {
        print("uvx missing: installing uv the way the Tools tab does…")
        let problem = await DottieCLIToolsManager.shared.installUV()
        print(problem.map { "FAILED: \($0)" } ?? "uv installed: \(DottieCommandLocator.locate("uvx") ?? "?")")
    }

    print("\n== 2. Apps from Home → Tools ==")
    let store = DottieToolsStore.shared
    var connectedPresetIDs: [String] = []
    for presetID in presetIDsToTry {
        guard let preset = DottieMCPPresets.preset(withID: presetID) else {
            print("[\(presetID)] not in this version's catalog")
            continue
        }
        let folders = presetID == "filesystem" ? ["FOLDERS": [filesFolderPath]] : [:]
        if let problem = store.addPreset(preset, values: [:], folders: folders) {
            print("[\(presetID)] couldn't add: \(problem)")
            continue
        }
        let connectStart = Date()
        let tools = await store.connect(presetID)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(connectStart))
        guard let tools else {
            print("[\(presetID)] ✗ didn't connect after \(seconds) s: \(store.status(for: presetID))")
            continue
        }
        connectedPresetIDs.append(presetID)
        print("[\(presetID)] ✓ connected in \(seconds) s, \(tools.count) tools: \(oneLine(tools.map(\.name).joined(separator: ", "), limit: 200))")
        if let plannedCall = plannedCallsByPresetID[presetID] {
            let callStart = Date()
            let result = await store.callTool(server: presetID, tool: plannedCall.toolName, arguments: plannedCall.arguments)
            print("    call \(plannedCall.toolName) (\(String(format: "%.1f", Date().timeIntervalSince(callStart))) s): \(oneLine(result))")
        }
    }
    print("connected \(connectedPresetIDs.count) of \(presetIDsToTry.count)")

    print("\n== 3. Voice Dottie's path (use_tool → apps_and_tools / use_app_tool) ==")
    print("voice prompt line: \(oneLine(DottieToolRegistry.voicePromptSections, limit: 400))")
    let summary = await DottieToolRegistry.run("apps_and_tools", arguments: [:], for: .voice) ?? "(no such tool)"
    print("apps_and_tools {}: \(oneLine(summary, limit: 400))")
    let timeDetails = await DottieToolRegistry.run("apps_and_tools", arguments: ["app": "Time zones"], for: .voice) ?? "(no such tool)"
    print("apps_and_tools {app: Time zones}: \(oneLine(timeDetails, limit: 300))")
    let spokenCalls: [[String: Any]] = [
        ["app": "Time zones", "tool": "get_current_time", "arguments": "{\"timezone\": \"Europe/London\"}"],
        ["app": "time", "tool": "GET_CURRENT_TIME", "arguments": "{\"timezone\": \"America/New_York\"}"],
        ["app": "Wikipedia", "tool": "search_wikipedia", "arguments": "{\"query\": \"Cloudflare\", \"limit\": 1}"],
        ["app": "Files and folders", "tool": "list_directory", "arguments": "{\"path\": \"\(filesFolderPath)\"}"],
        ["app": "notion", "tool": "search", "arguments": "{}"]
    ]
    for spokenCall in spokenCalls {
        let result = await DottieToolRegistry.run("use_app_tool", arguments: spokenCall, for: .voice) ?? "(no such tool)"
        print("use_app_tool \(spokenCall["app"] ?? "")/\(spokenCall["tool"] ?? ""): \(oneLine(result))")
    }

    print("\n== 4. What helpers get ==")
    let geminiServers = DottieHelperMCPSync.geminiCLIServers()
    print("Gemini CLI servers: \(geminiServers.keys.sorted().joined(separator: ", "))")
    let settingsFolderURL = URL(fileURLWithPath: geminiCLIHomePath).appendingPathComponent(".gemini", isDirectory: true)
    try? FileManager.default.createDirectory(at: settingsFolderURL, withIntermediateDirectories: true)
    // The same keys GeminiCLIAgentRuntime.prepareCLIHome writes, minus
    // computer use and skills, which the lab doesn't have.
    let cliSettings: [String: Any] = [
        "security": ["auth": ["selectedType": "gemini-api-key"]],
        "context": ["fileName": "AGENTS.md"],
        "tools": ["exclude": ["google_web_search"], "truncateToolOutputThreshold": 20_000],
        "mcpServers": geminiServers
    ]
    if let settingsData = try? JSONSerialization.data(withJSONObject: cliSettings, options: [.prettyPrinted, .sortedKeys]) {
        try? settingsData.write(to: settingsFolderURL.appendingPathComponent("settings.json"))
    }
    await DottieCLIToolsManager.shared.refresh()
    let helperInstructions = DottieCLIToolsManager.helperInstructions
    try? ("# Command-line tools\n\n" + helperInstructions + "\n").write(
        to: settingsFolderURL.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    print("CLI tools found (\(DottieCLIToolsManager.shared.installedToolIDs.count) of \(DottieCLICatalog.all.count)): \(DottieCLIToolsManager.shared.installedToolIDs.sorted().joined(separator: ", "))")
    print("helpers are told: \(oneLine(helperInstructions, limit: 500))")

    // The store syncs Claude Code a moment after each change.
    try? await Task.sleep(nanoseconds: 12_000_000_000)
    print("Claude Code entries Dottie added: \(DottieToolsFile.load().dottie.claudeCodeSynced.keys.sorted().joined(separator: ", "))")
    store.stopAll()
}

await runLab()
DottieMCPStdioTransport.closeAll()
exit(0)
