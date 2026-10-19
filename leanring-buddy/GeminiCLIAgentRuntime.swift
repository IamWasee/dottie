//
//  GeminiCLIAgentRuntime.swift
//  leanring-buddy
//
//  Runs one turn of a background Clicky agent with Google's open-source
//  Gemini CLI in headless mode. Shipped Clicky drives a bundled OpenAI Codex
//  CLI for this (CodexRuntimeBridge); Gemini's API doesn't speak the
//  Responses protocol current Codex needs, so the clone uses Gemini CLI,
//  which has the same kind of tools (shell, files, web, skills, MCP).
//
//  Each turn is one process:
//    gemini -m <model> -p <message> -o stream-json --approval-mode yolo
//           --skip-trust --include-directories <skills library>
//           (--session-id <uuid> | --resume <uuid>)
//  run inside the agent's workspace folder. The CLI's newline-delimited JSON
//  events (init, message, tool_use, tool_result, error, result) are parsed
//  into GeminiCLIAgentEvent values.
//
//  GEMINI_CLI_HOME points the CLI at a home folder the clone owns, so its
//  settings and saved sessions stay apart from any Gemini CLI setup the user
//  has in ~/.gemini (and Gemini CLI only reads the auth type from there).
//
//  The Gemini key never reaches the Mac: GOOGLE_GEMINI_BASE_URL points the
//  CLI at the Worker's /gemini passthrough, and the "API key" it sends is the
//  app's shared secret.
//

import Foundation

/// One parsed event from Gemini CLI's stream-json output.
enum GeminiCLIAgentEvent {
    case sessionStarted(sessionID: String, model: String)
    /// A chunk of the agent's reply (deltas accumulate into one message).
    case assistantTextDelta(String)
    case toolStarted(toolID: String, toolName: String, parametersSummary: String)
    case toolFinished(toolID: String, succeeded: Bool)
    case warning(String)
    case finished(succeeded: Bool, totalTokens: Int?, durationMilliseconds: Int?)
}

enum GeminiCLIAgentRuntimeError: LocalizedError {
    case geminiCLINotFound
    case workerNotConfigured
    case processFailed(exitCode: Int32, standardErrorTail: String)

    var errorDescription: String? {
        switch self {
        case .geminiCLINotFound:
            return "Dottie couldn't set up Gemini CLI, which Dots run on. Check your internet connection and try again."
        case .workerNotConfigured:
            return "Dottie isn't connected to its server yet. Add the server address in Settings → Connection."
        case .processFailed(let exitCode, let standardErrorTail):
            return "The agent stopped with exit code \(exitCode). \(standardErrorTail)"
        }
    }
}

final class GeminiCLIAgentRuntime {
    /// Model used for agents unless the agent overrides it. Agents make many
    /// calls per task, and gemini-3.8-flash's free daily limit runs out after
    /// a few tasks, so this is the next Flash model, which has more room.
    /// The Worker also moves to backup models when this one is busy.
    static let defaultAgentModel = "gemini-3.6-flash"

    /// Running processes by agent ID, so a turn can be stopped.
    private var runningProcessesByAgentID: [UUID: Process] = [:]
    private let runningProcessesLock = NSLock()

    // MARK: - Locating the CLI

    /// Finds the `gemini` executable: the copy Dottie set up itself (see
    /// DotsRuntimeInstaller), else one the user installed. GUI apps don't
    /// inherit the shell's PATH, so common install locations are checked
    /// first, then the user's login shell is asked.
    static func locateGeminiCLIExecutable() -> URL? {
        if let configuredPath = AppBundleConfiguration.stringValue(forKey: "GeminiCLIPath"),
           FileManager.default.isExecutableFile(atPath: configuredPath) {
            return URL(fileURLWithPath: configuredPath)
        }
        if DotsRuntimeInstaller.isInstalled {
            return DotsRuntimeInstaller.geminiLauncherURL
        }

        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let commonInstallPaths = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(homeDirectoryPath)/.npm-global/bin/gemini",
            "\(homeDirectoryPath)/.volta/bin/gemini",
            "\(homeDirectoryPath)/.bun/bin/gemini"
        ]
        if let foundPath = commonInstallPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: foundPath)
        }

        // nvm and friends put it somewhere only the login shell knows.
        let shellLookupProcess = Process()
        shellLookupProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shellLookupProcess.arguments = ["-lc", "command -v gemini"]
        let lookupOutputPipe = Pipe()
        shellLookupProcess.standardOutput = lookupOutputPipe
        shellLookupProcess.standardError = Pipe()
        do {
            try shellLookupProcess.run()
            shellLookupProcess.waitUntilExit()
        } catch {
            return nil
        }
        let lookupOutput = String(decoding: lookupOutputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lookupOutput.isEmpty, FileManager.default.isExecutableFile(atPath: lookupOutput) else { return nil }
        return URL(fileURLWithPath: lookupOutput)
    }

    /// The login shell's PATH, so the agent's shell commands find the same
    /// tools (node, python, git, brew) the user has in Terminal.
    private static let loginShellPATH: String? = {
        let pathLookupProcess = Process()
        pathLookupProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        pathLookupProcess.arguments = ["-lc", "echo $PATH"]
        let pathOutputPipe = Pipe()
        pathLookupProcess.standardOutput = pathOutputPipe
        pathLookupProcess.standardError = Pipe()
        guard (try? pathLookupProcess.run()) != nil else { return nil }
        pathLookupProcess.waitUntilExit()
        let pathOutput = String(decoding: pathOutputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pathOutput.isEmpty ? nil : pathOutput
    }()

    // MARK: - Running a turn

    /// Runs one agent turn and streams its events. Returns when the process
    /// exits. `isFirstTurn` starts a new CLI session with the agent's session
    /// ID; later turns resume it, so the agent remembers the conversation.
    func runTurn(
        agentID: UUID,
        sessionID: UUID,
        isFirstTurn: Bool,
        message: String,
        workspaceURL: URL,
        cliHomeURL: URL,
        model: String,
        isComputerUseApproved: Bool,
        additionalDirectoryURLs: [URL],
        onEvent: @escaping @Sendable (GeminiCLIAgentEvent) -> Void
    ) async throws {
        // The first Dot on a new Mac waits while Dottie downloads Gemini
        // CLI and Node.js (usually already done at launch).
        if Self.locateGeminiCLIExecutable() == nil {
            try? await DotsRuntimeInstaller.shared.installIfNeeded()
        }
        guard let geminiExecutableURL = Self.locateGeminiCLIExecutable() else {
            throw GeminiCLIAgentRuntimeError.geminiCLINotFound
        }
        guard ClickyWorkerConfiguration.isWorkerConfigured else {
            throw GeminiCLIAgentRuntimeError.workerNotConfigured
        }

        let agentProcess = Process()
        agentProcess.executableURL = geminiExecutableURL
        agentProcess.currentDirectoryURL = workspaceURL
        agentProcess.arguments = [
            "-m", model,
            "-p", message,
            "-o", "stream-json",
            "--approval-mode", "yolo",
            "--skip-trust"
        ] + additionalDirectoryURLs.flatMap { ["--include-directories", $0.path] }
          + (isFirstTurn
            ? ["--session-id", sessionID.uuidString.lowercased()]
            : ["--resume", sessionID.uuidString.lowercased()])

        var processEnvironment = ProcessInfo.processInfo.environment
        if let loginShellPATH = Self.loginShellPATH {
            processEnvironment["PATH"] = loginShellPATH
        }
        // Dottie's own Node.js, so node and npx work in the Dot's shell even
        // on a Mac without them.
        if DotsRuntimeInstaller.isInstalled {
            let existingPATH = processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            processEnvironment["PATH"] = existingPATH + ":" + DotsRuntimeInstaller.nodeBinFolderURL.path
        }
        processEnvironment["GOOGLE_GEMINI_BASE_URL"] = ClickyWorkerConfiguration.workerBaseURL + "/gemini"
        // The Worker swaps this for the real key. Without a shared secret
        // configured, any placeholder works.
        processEnvironment["GEMINI_API_KEY"] = ClickyWorkerConfiguration.appSharedSecret ?? "clicky-worker"
        processEnvironment["GEMINI_CLI_HOME"] = cliHomeURL.path
        // Keys for the apps connected in Home → Tools (see prepareCLIHome).
        processEnvironment.merge(DottieHelperMCPSync.helperSecretEnvironment()) { _, key in key }
        processEnvironment["DOTTIE_SEARCH_URL"] = ClickyWorkerConfiguration.workerBaseURL + "/search"
        // Picks the cua-driver policy for this turn (see ClickyComputerUse).
        processEnvironment["CLICKY_CUA_POLICY_FILE"] = (isComputerUseApproved
            ? ClickyComputerUse.actPolicyFileURL(inCLIHome: cliHomeURL)
            : ClickyComputerUse.observePolicyFileURL(inCLIHome: cliHomeURL)).path
        processEnvironment["NO_COLOR"] = "1"
        agentProcess.environment = processEnvironment

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        agentProcess.standardOutput = standardOutputPipe
        agentProcess.standardError = standardErrorPipe
        agentProcess.standardInput = FileHandle.nullDevice

        let streamJSONLineParser = GeminiCLIStreamJSONLineParser(onEvent: onEvent)
        standardOutputPipe.fileHandleForReading.readabilityHandler = { outputFileHandle in
            let availableData = outputFileHandle.availableData
            guard !availableData.isEmpty else { return }
            streamJSONLineParser.consume(availableData)
        }

        let standardErrorCollector = StandardErrorTailCollector()
        standardErrorPipe.fileHandleForReading.readabilityHandler = { errorFileHandle in
            let availableData = errorFileHandle.availableData
            guard !availableData.isEmpty else { return }
            standardErrorCollector.append(availableData)
        }

        let exitStatus: Int32 = try await withCheckedThrowingContinuation { continuation in
            agentProcess.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
            do {
                try agentProcess.run()
                setRunningProcess(agentProcess, forAgentID: agentID)
            } catch {
                agentProcess.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        // Pick up anything written between the last read and exit.
        streamJSONLineParser.consume(standardOutputPipe.fileHandleForReading.readDataToEndOfFile())
        streamJSONLineParser.flushRemainingLine()
        setRunningProcess(nil, forAgentID: agentID)

        // SIGTERM from stopTurn shows up as 15; that's a user stop, not a failure.
        if exitStatus != 0 && exitStatus != 15 && !streamJSONLineParser.sawFinishedEvent {
            throw GeminiCLIAgentRuntimeError.processFailed(
                exitCode: exitStatus,
                standardErrorTail: standardErrorCollector.tail
            )
        }
    }

    /// Writes the CLI's user settings into the clone's own CLI home: API-key
    /// auth (the worker supplies the real key), AGENTS.md as the context
    /// file, and cua-driver as the computer-use MCP server when it's
    /// installed. Gemini CLI ignores the auth type in workspace settings.
    /// Cheap enough to run before every turn, so installing cua-driver takes
    /// effect without a relaunch.
    static func prepareCLIHome(at cliHomeURL: URL, skillLibraryURL: URL) {
        let settingsFolderURL = cliHomeURL.appendingPathComponent(".gemini", isDirectory: true)
        try? FileManager.default.createDirectory(at: settingsFolderURL, withIntermediateDirectories: true)

        let cuaDriverURL = ClickyComputerUse.locateCuaDriverExecutable()
        var cliSettings: [String: Any] = [
            "security": ["auth": ["selectedType": "gemini-api-key"]],
            "context": ["fileName": "AGENTS.md"],
            "skills": ["disabled": ClickySkillLibrary.hiddenBuiltInSkillNames],
            // Google Search grounding answers "You exceeded your current
            // quota" on a free-tier key; Dots search through the Worker instead.
            "tools": [
                "exclude": ["google_web_search"],
                // A long command or page output is cut to this many
                // characters (the CLI keeps the full text in a file the
                // helper can read), so one big result isn't re-sent with
                // every later request of the turn.
                "truncateToolOutputThreshold": 20_000
            ]
        ]
        // MCP servers the user added in Home → Brain, for the Brain and
        // every Dot.
        var mcpServers = DottieBrain.userMCPServers()
        // Apps connected in Home → Tools. Their keys arrive as environment
        // variables (DottieHelperMCPSync.helperSecretEnvironment).
        for (serverName, serverSettings) in DottieHelperMCPSync.geminiCLIServers() where mcpServers[serverName] == nil {
            mcpServers[serverName] = serverSettings
        }
        if let cuaDriverURL {
            ClickyComputerUse.writePolicyFiles(inCLIHome: cliHomeURL)
            mcpServers[ClickyComputerUse.mcpServerName] = ClickyComputerUse.mcpServerSettings(cuaDriverURL: cuaDriverURL)
        }
        if !mcpServers.isEmpty {
            cliSettings["mcpServers"] = mcpServers
        }

        // Gemini CLI reads AGENTS.md from its home folder for every agent.
        let globalAgentInstructions = [
            ClickyComputerUse.globalAgentInstructions(isCuaDriverInstalled: cuaDriverURL != nil),
            ClickySkillLibrary.globalAgentInstructions(libraryURL: skillLibraryURL),
            ClickyRoutinePrompts.globalAgentInstructions,
            webSearchAgentInstructions,
            buildingAgentInstructions,
            macAppsAgentInstructions,
            DottieBrowser.agentInstructions,
            DottieCLIToolsManager.helperInstructions.isEmpty
                ? ""
                : "# Command-line tools\n\n" + DottieCLIToolsManager.helperInstructions + "\n"
        ].joined(separator: "\n")
        try? globalAgentInstructions
            .write(to: settingsFolderURL.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        if let settingsData = try? JSONSerialization.data(withJSONObject: cliSettings, options: [.prettyPrinted, .sortedKeys]) {
            try? settingsData.write(to: settingsFolderURL.appendingPathComponent("settings.json"), options: .atomic)
        }
    }

    /// How Dots search the web without Gemini's Google Search tool.
    static let webSearchAgentInstructions = """
    # Searching the web

    To search the web, run:

        curl -s -G -H "x-goog-api-key: $GEMINI_API_KEY" --data-urlencode "q=<your query>" "$DOTTIE_SEARCH_URL"

    It returns JSON: `results` (title, url, snippet) and `topPage` (the text of the first result). To read any other page, use `web_fetch` or `curl` on its URL. Cite the pages you used.

    """

    /// So Dots take on real builds (a website, an app, a script) instead of
    /// describing them, without hanging the turn on a server that never exits.
    static let buildingAgentInstructions = """
    # Building things

    You can build real, working things: websites, web apps, small tools, scripts, documents and data files. When asked to build something, build the whole thing, not a plan or a sketch.

    - Make each project its own folder in `output/` (for example `output/coffee-site/`).
    - For a website, plain `index.html` with CSS and JavaScript files is the default: it opens straight from disk in any browser. Make it look finished: real copy (no lorem ipsum), a clear layout, responsive on phones, and images as inline SVG or CSS rather than files you don't have.
    - Node.js, npm and npx are on your PATH. Use a framework (for example `npm create vite@latest`) only when the user asks for one or the job needs it, and then build it (`npm run build`) so there's a `dist/index.html` that opens from disk.
    - Never start a command that keeps running (a dev server, `npm run dev`, a watcher): your turn would never end. To check a page, read it back or run a quick script, then move on.
    - Before you reply, check your work: open the files you wrote, fix broken links and errors, and make sure everything the user asked for is there.
    - In your reply, say what you built and the path to open (for example `output/coffee-site/index.html`). Dottie can open it for the user.

    """

    /// Mac apps through their own scripting, which is quicker and surer
    /// than clicking on the screen.
    static let macAppsAgentInstructions = """
    # Mac apps, calendar and reminders

    You're on the user's Mac, so you can drive apps directly from the shell:

    - `osascript -e '<AppleScript>'` controls scriptable apps: Calendar (read and add events), Reminders (read, add, complete), Notes, Mail (read; make drafts), Music, Finder, Safari and Chrome tabs (only when that's the user's browser), system volume and dark mode. Prefer it to clicking on the screen.
    - `shortcuts list` and `shortcuts run "<name>" --input-path <file> --output-path <file>` run the user's Apple Shortcuts.
    - macOS may ask the user once to let Dottie control an app; if a script fails with "not authorized" (-1743), say so in your reply.
    - Never send an email or message, delete anything, or buy anything unless the user's task clearly asks for exactly that. Make a draft instead and say where it is.

    """

    func stopTurn(agentID: UUID) {
        runningProcessesLock.lock()
        let runningProcess = runningProcessesByAgentID[agentID]
        runningProcessesLock.unlock()
        runningProcess?.terminate()
    }

    func isTurnRunning(agentID: UUID) -> Bool {
        runningProcessesLock.lock()
        defer { runningProcessesLock.unlock() }
        return runningProcessesByAgentID[agentID] != nil
    }

    private func setRunningProcess(_ process: Process?, forAgentID agentID: UUID) {
        runningProcessesLock.lock()
        runningProcessesByAgentID[agentID] = process
        runningProcessesLock.unlock()
    }
}

// MARK: - stream-json parsing

/// Splits stdout into lines and turns each JSON line into an event. Lines
/// that aren't JSON (warnings the CLI prints) are ignored.
private final class GeminiCLIStreamJSONLineParser: @unchecked Sendable {
    private let onEvent: @Sendable (GeminiCLIAgentEvent) -> Void
    private let bufferLock = NSLock()
    private var pendingLineData = Data()
    private(set) var sawFinishedEvent = false

    init(onEvent: @escaping @Sendable (GeminiCLIAgentEvent) -> Void) {
        self.onEvent = onEvent
    }

    func consume(_ newData: Data) {
        guard !newData.isEmpty else { return }
        bufferLock.lock()
        pendingLineData.append(newData)
        var completeLines: [Data] = []
        while let newlineIndex = pendingLineData.firstIndex(of: UInt8(ascii: "\n")) {
            completeLines.append(pendingLineData[pendingLineData.startIndex..<newlineIndex])
            pendingLineData.removeSubrange(pendingLineData.startIndex...newlineIndex)
        }
        bufferLock.unlock()

        for completeLine in completeLines {
            parseLine(completeLine)
        }
    }

    func flushRemainingLine() {
        bufferLock.lock()
        let remainingLine = pendingLineData
        pendingLineData = Data()
        bufferLock.unlock()
        if !remainingLine.isEmpty {
            parseLine(remainingLine)
        }
    }

    private func parseLine(_ lineData: Data) {
        guard let eventObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let eventType = eventObject["type"] as? String else {
            return
        }

        switch eventType {
        case "init":
            onEvent(.sessionStarted(
                sessionID: eventObject["session_id"] as? String ?? "",
                model: eventObject["model"] as? String ?? ""
            ))
        case "message":
            // The CLI echoes the user's prompt as a message too; skip it.
            guard (eventObject["role"] as? String) == "assistant",
                  let contentText = eventObject["content"] as? String else { return }
            onEvent(.assistantTextDelta(contentText))
        case "tool_use":
            let parameters = eventObject["parameters"] as? [String: Any] ?? [:]
            onEvent(.toolStarted(
                toolID: eventObject["tool_id"] as? String ?? UUID().uuidString,
                // MCP tools arrive as mcp_<server>_<tool>; show just the tool.
                toolName: (eventObject["tool_name"] as? String ?? "tool")
                    .replacingOccurrences(of: "mcp_\(ClickyComputerUse.mcpServerName)_", with: ""),
                parametersSummary: Self.summarizeToolParameters(parameters)
            ))
        case "tool_result":
            onEvent(.toolFinished(
                toolID: eventObject["tool_id"] as? String ?? "",
                succeeded: (eventObject["status"] as? String) == "success"
            ))
        case "error":
            let warningMessage = (eventObject["message"] as? String)
                ?? (eventObject["error"] as? String)
                ?? "the agent reported an error"
            onEvent(.warning(warningMessage))
        case "result":
            sawFinishedEvent = true
            let stats = eventObject["stats"] as? [String: Any]
            onEvent(.finished(
                succeeded: (eventObject["status"] as? String) == "success",
                totalTokens: stats?["total_tokens"] as? Int,
                durationMilliseconds: stats?["duration_ms"] as? Int
            ))
        default:
            break
        }
    }

    /// One short line for the transcript, e.g. `file_path: output/report.md`.
    private static func summarizeToolParameters(_ parameters: [String: Any]) -> String {
        let preferredKeys = ["command", "file_path", "dir_path", "query", "pattern", "prompt", "name", "text", "value", "bundle_id", "key"]
        for preferredKey in preferredKeys {
            if let value = parameters[preferredKey] as? String, !value.isEmpty {
                let singleLineValue = value.replacingOccurrences(of: "\n", with: " ")
                return singleLineValue.count > 120 ? String(singleLineValue.prefix(117)) + "…" : singleLineValue
            }
        }
        return ""
    }
}

/// Keeps the last few hundred bytes of stderr for error messages.
private final class StandardErrorTailCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()
    private let maximumBytes = 600

    func append(_ newData: Data) {
        lock.lock()
        collectedData.append(newData)
        if collectedData.count > maximumBytes {
            collectedData = collectedData.suffix(maximumBytes)
        }
        lock.unlock()
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collectedData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
