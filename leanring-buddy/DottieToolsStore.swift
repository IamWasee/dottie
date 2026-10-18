//
//  DottieToolsStore.swift
//  leanring-buddy
//
//  The apps (MCP servers) connected in Home → Tools: adding and removing
//  them, their status, and using their tools. Servers start the first time
//  something needs them, stay running, and stop when Dottie quits.
//
//  Helpers get the same servers: Gemini CLI through the settings file
//  GeminiCLIAgentRuntime writes (geminiCLIServers), Claude Code and
//  OpenMausBot through their own config (DottieHelperMCPSync).
//

import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class DottieToolsStore: ObservableObject {
    enum Status: Equatable {
        case off
        case ready
        case starting
        case connected
        case needsKey([String])
        case needsProgram(String)
        case failed(String)
    }

    static let shared = DottieToolsStore()

    @Published private(set) var file: DottieToolsFile
    @Published private(set) var statuses: [String: Status] = [:]
    /// Each server's tools, remembered on disk so counts show before it starts.
    @Published private(set) var toolsByServer: [String: [DottieMCPToolInfo]]
    @Published var message: String?

    private var sessions: [String: DottieMCPServerSession] = [:]
    private var sessionFingerprints: [String: String] = [:]
    private var connectTasks: [String: Task<Void, Never>] = [:]
    private var helperSyncTask: Task<Void, Never>?

    init() {
        file = DottieToolsFile.load()
        toolsByServer = (try? JSONDecoder().decode([String: [DottieMCPToolInfo]].self, from: Data(contentsOf: DottieToolsFile.toolCacheFileURL))) ?? [:]
        refreshStatuses()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            DottieMCPStdioTransport.closeAll()
        }
        Task {
            await DottieCommandLocator.warmUp()
            self.refreshStatuses()
            self.scheduleHelperSync(delay: 5)
            // So helpers hear which command-line tools are on the Mac.
            await DottieCLIToolsManager.shared.refresh()
        }
    }

    // MARK: - Reading

    var serverNames: [String] { file.mcpServers.keys.sorted() }

    func config(for serverName: String) -> DottieMCPServerConfig? { file.mcpServers[serverName] }

    func isEnabled(_ serverName: String) -> Bool { file.isEnabled(serverName) }

    func preset(for serverName: String) -> DottieMCPPreset? {
        file.dottie.servers[serverName]?.preset.flatMap(DottieMCPPresets.preset(withID:))
    }

    func title(for serverName: String) -> String {
        file.dottie.servers[serverName]?.title ?? preset(for: serverName)?.title ?? serverName
    }

    func status(for serverName: String) -> Status { statuses[serverName] ?? .ready }

    /// Keys this server needs, by placeholder name, with labels from its
    /// preset when there is one.
    struct KeyName: Hashable {
        let name: String
        let label: String
    }

    func keyNames(for serverName: String) -> [KeyName] {
        guard let config = file.mcpServers[serverName] else { return [] }
        let presetFields = preset(for: serverName)?.fields ?? []
        return config.placeholderNames.map { name in
            KeyName(name: name, label: presetFields.first { $0.placeholder == name }?.label ?? name)
        }
    }

    func hasKey(_ name: String, for serverName: String) -> Bool {
        DottieToolsKeychain.value(server: serverName, name: name) != nil
    }

    func refreshStatuses() {
        var newStatuses: [String: Status] = [:]
        for serverName in serverNames {
            newStatuses[serverName] = computedStatus(for: serverName)
        }
        statuses = newStatuses
    }

    /// The status from the config alone, or what the running server said.
    private func computedStatus(for serverName: String) -> Status {
        guard let config = file.mcpServers[serverName] else { return .off }
        guard file.isEnabled(serverName) else { return .off }
        let missing = config.filledIn(serverName: serverName).missing
        if !missing.isEmpty { return .needsKey(missing) }
        if let command = config.command, DottieCommandLocator.locate(command) == nil,
           !(Self.nodeCommands.contains(command) && !DotsRuntimeInstaller.isInstalled) {
            return .needsProgram(command)
        }
        if let current = statuses[serverName] {
            switch current {
            case .failed:
                return current
            case .starting, .connected:
                if sessions[serverName] != nil { return current }
            default:
                break
            }
        }
        return .ready
    }

    /// Commands Dottie's own Node.js provides when the Mac has none.
    private static let nodeCommands: Set<String> = ["npx", "node", "npm"]

    // MARK: - Adding and changing

    /// Adds (or updates) a server from the catalog. `values` holds what the
    /// user typed by placeholder; `folders` holds picked folder lists.
    /// Returns a problem to show, or nil.
    @discardableResult
    func addPreset(_ preset: DottieMCPPreset, values: [String: String], folders: [String: [String]]) -> String? {
        for field in preset.fields where !field.isOptional {
            let typedValue = values[field.placeholder]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pickedFolders = folders[field.placeholder] ?? []
            let alreadyHasKey = field.kind == .secret && hasKey(field.placeholder, for: preset.id)
            switch field.kind {
            case .folders:
                if pickedFolders.isEmpty { return "Pick at least one folder for \(preset.title)." }
            default:
                if typedValue.isEmpty && !alreadyHasKey { return "\(preset.title) needs: \(field.label)." }
            }
        }

        var config = preset.config
        // A folder list fills a whole argument, one argument per folder.
        config.args = config.args.flatMap { argument -> [String] in
            for field in preset.fields where field.kind == .folders && argument == "${\(field.placeholder)}" {
                return folders[field.placeholder] ?? []
            }
            return [argument]
        }
        // Folders, files and addresses go straight into the config.
        let plainValues = preset.fields.filter { $0.kind != .secret && $0.kind != .folders }
        config = config.mapStrings { text in
            DottieToolsPlaceholders.fill(text) { name in
                guard let field = plainValues.first(where: { $0.placeholder == name }) else { return nil }
                var value = values[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if field.kind == .address {
                    while value.hasSuffix("/") { value.removeLast() }
                }
                return value
            }
        }
        // Keys and tokens go to the Keychain.
        for field in preset.fields where field.kind == .secret {
            let typedValue = values[field.placeholder]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !typedValue.isEmpty {
                DottieToolsKeychain.setValue(typedValue, server: preset.id, name: field.placeholder)
            }
        }

        file.mcpServers[preset.id] = config
        file.dottie.servers[preset.id] = DottieMCPServerSettings(enabled: true, preset: preset.id, title: preset.title)
        didChange(serverName: preset.id, connectNow: true)
        return nil
    }

    /// Adds a server the user describes: a command to run or a web address,
    /// plus KEY=value lines (env) or "Name: value" lines (headers). Every
    /// value typed there is kept in the Keychain.
    @discardableResult
    func addCustom(name rawName: String, commandOrAddress: String, settingLines: String) -> String? {
        let serverName = Self.cleanServerName(rawName)
        guard !serverName.isEmpty else { return "Give it a short name, like notes." }
        let trimmedTarget = commandOrAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return "Type the command to run or the web address." }

        var config = DottieMCPServerConfig()
        let isAddress = trimmedTarget.hasPrefix("http://") || trimmedTarget.hasPrefix("https://")
        if isAddress {
            guard URL(string: trimmedTarget) != nil else { return "That web address doesn't look right." }
            config.url = trimmedTarget
        } else {
            let words = Self.splitCommandLine(trimmedTarget)
            guard let command = words.first else { return "Type the command to run." }
            config.command = command
            config.args = Array(words.dropFirst())
        }

        for line in settingLines.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            if isAddress, let colonIndex = trimmedLine.firstIndex(of: ":") {
                let headerName = trimmedLine[..<colonIndex].trimmingCharacters(in: .whitespaces)
                let headerValue = trimmedLine[trimmedLine.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                guard !headerName.isEmpty else { continue }
                let placeholder = "HEADER_" + headerName.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
                config.headers[headerName] = storeSecret(headerValue, server: serverName, placeholder: placeholder)
            } else if let equalsIndex = trimmedLine.firstIndex(of: "=") {
                let variableName = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespaces)
                let variableValue = trimmedLine[trimmedLine.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
                guard DottieToolsPlaceholders.isValidName(variableName) else {
                    return "\(variableName) isn't a valid setting name. Use letters, numbers and _."
                }
                config.env[variableName] = storeSecret(variableValue, server: serverName, placeholder: variableName)
            } else {
                return isAddress ? "Write headers as Name: value." : "Write settings as NAME=value."
            }
        }

        file.mcpServers[serverName] = config
        file.dottie.servers[serverName] = DottieMCPServerSettings(enabled: true)
        didChange(serverName: serverName, connectNow: true)
        return nil
    }

    /// Adds every server in pasted JSON: {"mcpServers": {...}} or a
    /// name → server map, as Claude Desktop, Claude Code and Cursor write.
    @discardableResult
    func importJSON(_ text: String) -> String? {
        guard let jsonData = text.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return "That isn't valid JSON."
        }
        let serverObjects = (jsonObject["mcpServers"] as? [String: Any]) ?? (jsonObject["servers"] as? [String: Any]) ?? jsonObject
        var addedNames: [String] = []
        for (rawName, serverObject) in serverObjects {
            guard let serverDictionary = serverObject as? [String: Any],
                  let serverData = try? JSONSerialization.data(withJSONObject: serverDictionary),
                  var config = try? JSONDecoder().decode(DottieMCPServerConfig.self, from: serverData),
                  config.command != nil || config.url != nil else { continue }
            let serverName = Self.cleanServerName(rawName)
            guard !serverName.isEmpty else { continue }
            for (variableName, variableValue) in config.env {
                config.env[variableName] = storeSecret(variableValue, server: serverName, placeholder: variableName)
            }
            for (headerName, headerValue) in config.headers {
                let placeholder = "HEADER_" + headerName.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
                config.headers[headerName] = storeSecret(headerValue, server: serverName, placeholder: placeholder)
            }
            file.mcpServers[serverName] = config
            file.dottie.servers[serverName] = DottieMCPServerSettings(enabled: true)
            addedNames.append(serverName)
        }
        guard !addedNames.isEmpty else {
            return "Dottie didn't find any servers in that. It should look like {\"mcpServers\": {\"name\": {\"command\": \"…\"}}}."
        }
        for serverName in addedNames {
            didChange(serverName: serverName, connectNow: true)
        }
        message = "Added \(addedNames.sorted().joined(separator: ", "))."
        return nil
    }

    /// Keeps a typed value in the Keychain and returns the ${NAME} that
    /// stands in for it. Values that are already ${…} stay as they are.
    private func storeSecret(_ value: String, server: String, placeholder: String) -> String {
        if value.contains("${") || value.isEmpty { return value }
        DottieToolsKeychain.setValue(value, server: server, name: placeholder)
        return "${\(placeholder)}"
    }

    func setKey(_ value: String, name: String, for serverName: String) {
        DottieToolsKeychain.setValue(value, server: serverName, name: name)
        didChange(serverName: serverName, connectNow: true)
    }

    func setEnabled(_ isEnabled: Bool, for serverName: String) {
        var settings = file.dottie.servers[serverName] ?? DottieMCPServerSettings()
        settings.enabled = isEnabled
        file.dottie.servers[serverName] = settings
        didChange(serverName: serverName, connectNow: isEnabled)
    }

    func remove(_ serverName: String) {
        let placeholderNames = file.mcpServers[serverName]?.placeholderNames ?? []
        file.mcpServers[serverName] = nil
        file.dottie.servers[serverName] = nil
        DottieToolsKeychain.removeAll(server: serverName, names: placeholderNames)
        toolsByServer[serverName] = nil
        saveToolCache()
        didChange(serverName: serverName, connectNow: false)
    }

    private func didChange(serverName: String, connectNow: Bool) {
        file.save()
        stopSession(serverName)
        statuses[serverName] = nil
        refreshStatuses()
        scheduleHelperSync(delay: 1.5)
        if connectNow, case .ready = status(for: serverName) {
            connectInBackground(serverName)
        } else if connectNow, case .needsProgram = status(for: serverName) {
            // npx on a Mac without Node: Dottie's own Node is on its way.
            connectInBackground(serverName)
        }
    }

    // MARK: - Running servers

    func connectInBackground(_ serverName: String) {
        guard connectTasks[serverName] == nil else { return }
        connectTasks[serverName] = Task {
            await self.connect(serverName)
            self.connectTasks[serverName] = nil
        }
    }

    /// Starts the server if needed and reads its tools. Returns them, or nil
    /// when it couldn't (the status says why).
    @discardableResult
    func connect(_ serverName: String) async -> [DottieMCPToolInfo]? {
        guard file.isEnabled(serverName) else { return nil }
        do {
            let session = try await session(for: serverName)
            if case .connected = status(for: serverName) {} else {
                statuses[serverName] = .starting
            }
            let tools = try await session.listTools()
            statuses[serverName] = .connected
            if toolsByServer[serverName] != tools {
                toolsByServer[serverName] = tools
                saveToolCache()
            }
            return tools
        } catch let problem as SessionProblem {
            statuses[serverName] = problem.status
            return nil
        } catch {
            let detail = await sessions[serverName]?.errorOutputTail ?? ""
            let lastLine = DottieMCPStdioTransport.lastMeaningfulLine(of: detail)
            var reason = error.localizedDescription
            if !lastLine.isEmpty, !(error is DottieMCPError && reason.contains(lastLine)) {
                reason += " " + lastLine
            }
            stopSession(serverName)
            statuses[serverName] = .failed(String(reason.prefix(300)))
            return nil
        }
    }

    /// Runs one tool. Always returns text for the assistant.
    func callTool(server serverName: String, tool toolName: String, arguments: [String: Any], timeout: TimeInterval = 90) async -> String {
        do {
            let session = try await session(for: serverName)
            let text = try await session.callTool(toolName, arguments: arguments, timeout: timeout)
            statuses[serverName] = .connected
            return text.isEmpty ? "done (the tool returned nothing)." : text
        } catch let problem as SessionProblem {
            statuses[serverName] = problem.status
            return problem.explanation(title: title(for: serverName))
        } catch DottieMCPError.toolError(let message) {
            return "the tool reported a problem: \(message)"
        } catch {
            statuses[serverName] = .failed(error.localizedDescription)
            return "\(title(for: serverName)) couldn't do that: \(error.localizedDescription)"
        }
    }

    func stopAll() {
        for serverName in Array(sessions.keys) {
            stopSession(serverName)
        }
    }

    private struct SessionProblem: Error {
        let status: Status

        func explanation(title: String) -> String {
            switch status {
            case .needsKey(let names):
                return "\(title) needs a key first (\(names.joined(separator: ", "))). The user can add it in Home → Tools."
            case .needsProgram(let command):
                return "\(title) needs \(command), which isn't on this Mac. The user can install it in Home → Tools."
            case .off:
                return "\(title) is switched off in Home → Tools."
            case .failed(let reason):
                return "\(title) couldn't start: \(reason)"
            default:
                return "\(title) isn't ready."
            }
        }
    }

    /// The running session for a server, started fresh if its settings
    /// changed.
    private func session(for serverName: String) async throws -> DottieMCPServerSession {
        guard let config = file.mcpServers[serverName] else { throw SessionProblem(status: .off) }
        guard file.isEnabled(serverName) else { throw SessionProblem(status: .off) }
        let (filledConfig, missing) = config.filledIn(serverName: serverName)
        guard missing.isEmpty else { throw SessionProblem(status: .needsKey(missing)) }

        let fingerprint = filledConfig.fingerprint
        if let existing = sessions[serverName], sessionFingerprints[serverName] == fingerprint {
            return existing
        }
        stopSession(serverName)

        let endpoint = try await endpoint(for: filledConfig)
        let session = DottieMCPServerSession(serverName: serverName, endpoint: endpoint)
        sessions[serverName] = session
        sessionFingerprints[serverName] = fingerprint
        return session
    }

    private func endpoint(for config: DottieMCPServerConfig) async throws -> DottieMCPEndpoint {
        if let command = config.command {
            var executablePath = DottieCommandLocator.locate(command)
            if executablePath == nil && Self.nodeCommands.contains(command) {
                // No Node.js on this Mac: use Dottie's own.
                try? await DotsRuntimeInstaller.shared.installIfNeeded()
                executablePath = DottieCommandLocator.locate(command)
            }
            guard let executablePath else { throw SessionProblem(status: .needsProgram(command)) }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = DottieCommandLocator.searchPATH
            environment.merge(config.env) { _, configured in configured }
            return .program(executablePath: executablePath, arguments: config.args, environment: environment, workingDirectory: config.cwd)
        }
        guard let address = config.url, let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
            throw SessionProblem(status: .failed("its web address doesn't look right."))
        }
        return .web(url: url, headers: config.headers)
    }

    private func stopSession(_ serverName: String) {
        if let session = sessions.removeValue(forKey: serverName) {
            Task { await session.stop() }
        }
        sessionFingerprints[serverName] = nil
        connectTasks[serverName]?.cancel()
        connectTasks[serverName] = nil
    }

    private func saveToolCache() {
        if let cacheData = try? JSONEncoder().encode(toolsByServer) {
            try? FileManager.default.createDirectory(at: DottieToolsFile.folderURL, withIntermediateDirectories: true)
            try? cacheData.write(to: DottieToolsFile.toolCacheFileURL, options: .atomic)
        }
    }

    // MARK: - For voice and helpers

    /// Finds a server by name or title, loosely.
    func matchServer(_ requested: String) -> String? {
        let wanted = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let names = serverNames
        return names.first { $0.lowercased() == wanted }
            ?? names.first { title(for: $0).lowercased() == wanted }
            ?? names.first { $0.lowercased().contains(wanted) || title(for: $0).lowercased().contains(wanted) || wanted.contains($0.lowercased()) }
    }

    /// What's connected and what each can do, in a few lines. Servers never
    /// started yet get a few seconds to start.
    func summaryForAssistant() async -> String {
        let enabledNames = serverNames.filter { file.isEnabled($0) }
        guard !enabledNames.isEmpty else {
            return "no apps are connected yet. The user can connect apps like Notion, GitHub or Slack in Home → Tools."
        }
        let namesToStart = enabledNames.filter { toolsByServer[$0] == nil && status(for: $0) == .ready }
        for serverName in namesToStart { connectInBackground(serverName) }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, namesToStart.contains(where: { connectTasks[$0] != nil }) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        var lines = ["connected apps (use the name in use_app_tool):"]
        for serverName in enabledNames {
            let heading = "- \(serverName) (\(title(for: serverName)))"
            switch status(for: serverName) {
            case .needsKey:
                lines.append("\(heading): needs a key; the user can add it in Home → Tools.")
                continue
            case .needsProgram(let command):
                lines.append("\(heading): needs \(command) installed (Home → Tools).")
                continue
            case .failed(let reason):
                if toolsByServer[serverName] == nil {
                    lines.append("\(heading): not working right now (\(reason.prefix(120))).")
                    continue
                }
            default:
                break
            }
            guard let tools = toolsByServer[serverName] else {
                lines.append("\(heading): still starting; try again in a moment.")
                continue
            }
            let toolNames = tools.prefix(20).map(\.name).joined(separator: ", ")
            let more = tools.count > 20 ? " and \(tools.count - 20) more" : ""
            lines.append("\(heading): \(toolNames)\(more)")
        }
        return lines.joined(separator: "\n")
    }

    /// One app's tools with their arguments.
    func toolDetailsForAssistant(server requested: String) async -> String {
        guard let serverName = matchServer(requested) else {
            return "there's no connected app called \(requested). Connected: \(serverNames.joined(separator: ", "))."
        }
        guard let tools = await connect(serverName) ?? toolsByServer[serverName] else {
            return SessionProblem(status: status(for: serverName)).explanation(title: title(for: serverName))
        }
        var text = "\(serverName) tools (* = required argument):\n"
        for tool in tools {
            let line = "- \(tool.name)(\(tool.argumentSummary)): \(tool.description.prefix(180))\n"
            if text.count + line.count > 7000 {
                text += "…and more."
                break
            }
            text += line
        }
        return text
    }

    // MARK: - Helpers

    func scheduleHelperSync(delay: TimeInterval) {
        helperSyncTask?.cancel()
        helperSyncTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.syncHelpers()
        }
    }

    private func syncHelpers() async {
        // Only servers that are on and have all their keys.
        var readyServers: [String: DottieMCPServerConfig] = [:]
        for (serverName, config) in file.enabledServers {
            let (filledConfig, missing) = config.filledIn(serverName: serverName)
            if missing.isEmpty { readyServers[serverName] = filledConfig }
        }
        let previousClaudeCode = file.dottie.claudeCodeSynced
        let previousOpenMausBot = file.dottie.openMausBotSynced
        let result = await Task.detached(priority: .utility) {
            (
                claudeCode: DottieHelperMCPSync.syncClaudeCode(servers: readyServers, previouslySynced: previousClaudeCode),
                openMausBot: DottieHelperMCPSync.syncOpenMausBot(servers: readyServers, previouslySynced: previousOpenMausBot)
            )
        }.value
        if result.claudeCode != file.dottie.claudeCodeSynced || result.openMausBot != file.dottie.openMausBotSynced {
            file.dottie.claudeCodeSynced = result.claudeCode
            file.dottie.openMausBotSynced = result.openMausBot
            file.save()
        }
    }

    // MARK: - Names and command lines

    static func cleanServerName(_ rawName: String) -> String {
        let lowered = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var cleaned = ""
        for character in lowered {
            if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else if character == "-" || character == "_" || character == " " || character == "." {
                if !cleaned.isEmpty && cleaned.last != "-" { cleaned.append("-") }
            }
        }
        while cleaned.hasSuffix("-") { cleaned.removeLast() }
        return String(cleaned.prefix(40))
    }

    /// Splits a command line into words, keeping "quoted parts" together.
    static func splitCommandLine(_ commandLine: String) -> [String] {
        var words: [String] = []
        var currentWord = ""
        var quote: Character?
        var hasWord = false
        for character in commandLine {
            if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { currentWord.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character.isWhitespace {
                if hasWord || !currentWord.isEmpty { words.append(currentWord) }
                currentWord = ""
                hasWord = false
            } else {
                currentWord.append(character)
            }
        }
        if hasWord || !currentWord.isEmpty { words.append(currentWord) }
        return words
    }
}

// MARK: - Helper engines

/// Gives the connected apps to helpers. Everything here reads tools.json and
/// the Keychain directly, so it can run from any thread.
enum DottieHelperMCPSync {
    /// Servers for Gemini CLI's settings.json. Keys stay out of the file:
    /// it holds ${DOTTIE_…} and `helperSecretEnvironment()` supplies the
    /// values when a helper starts (Gemini CLI fills in ${…} itself).
    static func geminiCLIServers() -> [String: Any] {
        let file = DottieToolsFile.load()
        var servers: [String: Any] = [:]
        for (serverName, config) in file.enabledServers {
            var isMissingKey = false
            let environment = ProcessInfo.processInfo.environment
            let renamedConfig = config.mapStrings { text in
                DottieToolsPlaceholders.fill(text) { name in
                    if DottieToolsKeychain.value(server: serverName, name: name) != nil {
                        return "${\(DottieToolsPlaceholders.helperVariableName(server: serverName, name: name))}"
                    }
                    if environment[name] == nil { isMissingKey = true }
                    return nil
                }
            }
            guard !isMissingKey else { continue }
            if let command = renamedConfig.command {
                var serverSettings: [String: Any] = [
                    "command": DottieCommandLocator.locate(command) ?? command,
                    "args": renamedConfig.args,
                    "env": renamedConfig.env.merging(["PATH": DottieCommandLocator.searchPATH]) { configured, _ in configured }
                ]
                if let cwd = renamedConfig.cwd { serverSettings["cwd"] = cwd }
                servers[serverName] = serverSettings
            } else if let url = renamedConfig.url {
                // Gemini CLI: httpUrl is Streamable HTTP, url is the older SSE.
                let addressKey = renamedConfig.type == "sse" ? "url" : "httpUrl"
                var serverSettings: [String: Any] = [addressKey: url]
                if !renamedConfig.headers.isEmpty { serverSettings["headers"] = renamedConfig.headers }
                servers[serverName] = serverSettings
            }
        }
        return servers
    }

    /// The keys for `geminiCLIServers()`, as environment variables for the
    /// helper's process.
    static func helperSecretEnvironment() -> [String: String] {
        let file = DottieToolsFile.load()
        var environment: [String: String] = [:]
        for (serverName, config) in file.enabledServers {
            for name in config.placeholderNames {
                if let value = DottieToolsKeychain.value(server: serverName, name: name) {
                    environment[DottieToolsPlaceholders.helperVariableName(server: serverName, name: name)] = value
                }
            }
        }
        return environment
    }

    /// The name a Dottie server gets in other apps, so it never clashes
    /// with (or replaces) one the user added there themselves.
    static func externalName(for serverName: String) -> String {
        let cleaned = serverName.lowercased().map { character -> String in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? String(character) : "-"
        }.joined()
        return String("dottie-\(cleaned)".prefix(32))
    }

    /// The server in Claude Code's / OpenMausBot's shape, keys filled in.
    private static func externalEntry(for config: DottieMCPServerConfig, includeTypeForPrograms: Bool) -> [String: Any] {
        if let command = config.command {
            var entry: [String: Any] = [
                "command": DottieCommandLocator.locate(command) ?? command,
                "args": config.args,
                "env": config.env.merging(["PATH": DottieCommandLocator.searchPATH]) { configured, _ in configured }
            ]
            if includeTypeForPrograms { entry["type"] = "stdio" }
            return entry
        }
        var entry: [String: Any] = ["type": config.type == "sse" ? "sse" : "http", "url": config.url ?? ""]
        if !config.headers.isEmpty { entry["headers"] = config.headers }
        return entry
    }

    private static func fingerprint(of entry: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Adds Dottie's servers to Claude Code (user scope) with `claude mcp
    /// add-json`, and removes ones Dottie added before that are gone. Never
    /// touches servers the user added to Claude Code. Returns the new record.
    static func syncClaudeCode(servers: [String: DottieMCPServerConfig], previouslySynced: [String: String]) -> [String: String] {
        guard let claudePath = DottieCommandLocator.locate("claude") else { return previouslySynced }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = DottieCommandLocator.searchPATH

        var desiredEntries: [String: [String: Any]] = [:]
        for (serverName, config) in servers {
            desiredEntries[externalName(for: serverName)] = externalEntry(for: config, includeTypeForPrograms: true)
        }

        var synced = previouslySynced
        for (externalName, _) in previouslySynced where desiredEntries[externalName] == nil {
            _ = runBlocking(claudePath, ["mcp", "remove", externalName, "--scope", "user"], environment)
            synced[externalName] = nil
        }
        for (externalName, entry) in desiredEntries {
            let entryFingerprint = fingerprint(of: entry)
            guard synced[externalName] != entryFingerprint,
                  let entryData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { continue }
            if synced[externalName] != nil {
                _ = runBlocking(claudePath, ["mcp", "remove", externalName, "--scope", "user"], environment)
                synced[externalName] = nil
            }
            let exitCode = runBlocking(claudePath, ["mcp", "add-json", externalName, String(decoding: entryData, as: UTF8.self), "--scope", "user"], environment)
            if exitCode == 0 {
                synced[externalName] = entryFingerprint
            }
        }
        return synced
    }

    /// Adds Dottie's servers to ~/.openmausbot/config.json when OpenMausBot
    /// is set up. Skipped when OpenMausBot already uses Claude Code's
    /// servers ("claudeUserMcp"), which get them from syncClaudeCode.
    static func syncOpenMausBot(servers: [String: DottieMCPServerConfig], previouslySynced: [String: String]) -> [String: String] {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openmausbot", isDirectory: true)
            .appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL),
              var configObject = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            return previouslySynced
        }
        let usesClaudeCodeServers = ((configObject["features"] as? [String: Any])?["claudeUserMcp"] as? Bool) == true
        var mcpServers = configObject["mcpServers"] as? [String: Any] ?? [:]
        let originalServers = mcpServers

        var desiredEntries: [String: [String: Any]] = [:]
        if !usesClaudeCodeServers {
            for (serverName, config) in servers {
                desiredEntries[externalName(for: serverName)] = externalEntry(for: config, includeTypeForPrograms: false)
            }
        }

        var synced: [String: String] = [:]
        for externalName in previouslySynced.keys where desiredEntries[externalName] == nil {
            mcpServers[externalName] = nil
        }
        for (externalName, entry) in desiredEntries {
            // A server of the user's own under this name stays.
            if mcpServers[externalName] != nil && previouslySynced[externalName] == nil { continue }
            mcpServers[externalName] = entry
            synced[externalName] = fingerprint(of: entry)
        }

        guard let originalData = try? JSONSerialization.data(withJSONObject: originalServers, options: [.sortedKeys]),
              let newData = try? JSONSerialization.data(withJSONObject: mcpServers, options: [.sortedKeys]),
              originalData != newData else {
            return synced
        }
        configObject["mcpServers"] = mcpServers
        guard let outputData = try? JSONSerialization.data(withJSONObject: configObject, options: [.prettyPrinted, .sortedKeys]) else {
            return previouslySynced
        }
        do {
            try outputData.write(to: configURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            return synced
        } catch {
            return previouslySynced
        }
    }

    private static func runBlocking(_ executablePath: String, _ arguments: [String], _ environment: [String: String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return -1
        }
        return process.terminationStatus
    }
}
