//
//  DottieMCPClient.swift
//  leanring-buddy
//
//  A small Model Context Protocol client, so Dottie's voice can use the
//  apps the user connects in Home → Tools (Notion, GitHub, a browser…).
//
//  Two ways to reach a server:
//    - a program on the Mac (stdio): JSON-RPC 2.0, one message per line on
//      its stdin/stdout. Its stderr is kept for error messages.
//    - a web address (Streamable HTTP): each message is a POST; the answer
//      comes back as plain JSON or as server-sent events. The server's
//      Mcp-Session-Id is sent back on every later request.
//
//  Each server goes initialize → notifications/initialized → tools/list,
//  then tools/call as needed. DottieMCPServerSession starts it on first use,
//  keeps it running, and starts it again if the program crashed.
//

import Foundation

/// One tool a server offers.
struct DottieMCPToolInfo: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    /// The arguments in short, e.g. "query*, limit" (* = required).
    let argumentSummary: String
    /// The tool's input schema as JSON, trimmed.
    let inputSchemaJSON: String
}

enum DottieMCPError: LocalizedError {
    case couldNotStart(String)
    case timedOut(String)
    case stopped(String)
    case notAllowed(Int)
    case web(Int, String)
    case badReply(String)
    case toolError(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart(let reason):
            return "It couldn't start: \(reason)"
        case .timedOut(let what):
            return "It took too long to \(what)."
        case .stopped(let reason):
            return reason.isEmpty ? "It stopped unexpectedly." : "It stopped: \(reason)"
        case .notAllowed(let statusCode):
            return "It said no (\(statusCode)). Check the key or token."
        case .web(let statusCode, let body):
            return "Its server answered \(statusCode). \(body)"
        case .badReply(let detail):
            return "It sent an answer Dottie didn't understand. \(detail)"
        case .toolError(let message):
            return message
        }
    }
}

/// How to reach one server, with every ${…} already filled in.
enum DottieMCPEndpoint {
    case program(executablePath: String, arguments: [String], environment: [String: String], workingDirectory: String?)
    case web(url: URL, headers: [String: String])
}

// MARK: - Session

/// One server: started on first use, kept warm, restarted after a crash.
actor DottieMCPServerSession {
    static let protocolVersion = "2025-06-18"

    let serverName: String
    private let endpoint: DottieMCPEndpoint
    private var programTransport: DottieMCPStdioTransport?
    private var webTransport: DottieMCPHTTPTransport?
    private var isInitialized = false
    private var startTask: Task<Void, Error>?
    private var cachedTools: [DottieMCPToolInfo]?
    private(set) var instructions: String?

    init(serverName: String, endpoint: DottieMCPEndpoint) {
        self.serverName = serverName
        self.endpoint = endpoint
    }

    private var isTransportAlive: Bool {
        if let programTransport { return programTransport.isRunning }
        return webTransport != nil
    }

    /// Starts the server and does the MCP handshake, once.
    func start() async throws {
        if isInitialized && isTransportAlive { return }
        if let startTask {
            try await startTask.value
            return
        }
        tearDown()
        let newStartTask = Task { try await self.performStart() }
        startTask = newStartTask
        do {
            try await newStartTask.value
            startTask = nil
        } catch {
            startTask = nil
            tearDown()
            throw error
        }
    }

    private func performStart() async throws {
        let handshakeTimeout: TimeInterval
        switch endpoint {
        case .program(let executablePath, let arguments, let environment, let workingDirectory):
            programTransport = try DottieMCPStdioTransport(
                serverName: serverName,
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory
            )
            // npx and uvx download the server the first time it runs.
            handshakeTimeout = 120
        case .web(let url, let headers):
            webTransport = DottieMCPHTTPTransport(url: url, headers: headers)
            handshakeTimeout = 25
        }

        let initializeResult = try await send("initialize", parameters: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "Dottie",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            ]
        ], timeout: handshakeTimeout, what: "start")
        if let agreedVersion = initializeResult["protocolVersion"] as? String {
            webTransport?.setProtocolVersion(agreedVersion)
        }
        instructions = initializeResult["instructions"] as? String
        try await notify("notifications/initialized")
        isInitialized = true
    }

    /// The server's tools (asked once, then remembered until it restarts).
    func listTools(refresh: Bool = false) async throws -> [DottieMCPToolInfo] {
        try await startOrRestart()
        if let cachedTools, !refresh { return cachedTools }
        var tools: [DottieMCPToolInfo] = []
        var cursor: String?
        for _ in 0..<20 {
            var parameters: [String: Any] = [:]
            if let cursor { parameters["cursor"] = cursor }
            let result = try await send("tools/list", parameters: parameters, timeout: 30, what: "list its tools")
            let toolObjects = result["tools"] as? [[String: Any]] ?? []
            tools += toolObjects.compactMap(Self.toolInfo(from:))
            cursor = result["nextCursor"] as? String
            if cursor?.isEmpty ?? true { break }
        }
        cachedTools = tools
        return tools
    }

    /// Runs a tool and returns its answer as text.
    func callTool(_ toolName: String, arguments: [String: Any], timeout: TimeInterval) async throws -> String {
        try await startOrRestart()
        let result = try await send("tools/call", parameters: [
            "name": toolName,
            "arguments": arguments
        ], timeout: timeout, what: "finish")
        let text = Self.text(fromToolResult: result)
        if (result["isError"] as? Bool) == true {
            throw DottieMCPError.toolError(text.isEmpty ? "The tool reported a problem." : text)
        }
        return text
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        tearDown()
    }

    /// The last thing the program wrote to stderr, for error messages.
    var errorOutputTail: String {
        programTransport?.errorOutputTail ?? ""
    }

    private func startOrRestart() async throws {
        if isInitialized && !isTransportAlive {
            // The program crashed or quit since last time.
            isInitialized = false
            cachedTools = nil
        }
        try await start()
    }

    private func tearDown() {
        programTransport?.close()
        programTransport = nil
        webTransport = nil
        isInitialized = false
        cachedTools = nil
    }

    // MARK: Messages

    private func send(_ method: String, parameters: [String: Any], timeout: TimeInterval, what: String) async throws -> [String: Any] {
        let reply: [String: Any]
        if let programTransport {
            reply = try await programTransport.request(method, parameters: parameters, timeout: timeout, what: what)
        } else if let webTransport {
            do {
                reply = try await webTransport.request(method, parameters: parameters, timeout: timeout, what: what)
            } catch DottieMCPHTTPTransport.SessionExpired.expired where method != "initialize" {
                // The server forgot this session; shake hands again once.
                isInitialized = false
                cachedTools = nil
                self.webTransport = nil
                try await start()
                guard let freshTransport = self.webTransport else { throw DottieMCPError.stopped("") }
                reply = try await freshTransport.request(method, parameters: parameters, timeout: timeout, what: what)
            }
        } else {
            throw DottieMCPError.stopped("")
        }

        if let errorObject = reply["error"] as? [String: Any] {
            let message = errorObject["message"] as? String ?? "unknown error"
            throw DottieMCPError.toolError(message)
        }
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func notify(_ method: String) async throws {
        if let programTransport {
            try programTransport.notify(method)
        } else if let webTransport {
            try await webTransport.notify(method)
        }
    }

    // MARK: Reading replies

    private static func toolInfo(from toolObject: [String: Any]) -> DottieMCPToolInfo? {
        guard let name = toolObject["name"] as? String, !name.isEmpty else { return nil }
        let description = ((toolObject["description"] as? String) ?? (toolObject["title"] as? String) ?? "")
            .replacingOccurrences(of: "\n", with: " ")
        let schema = toolObject["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        let argumentSummary = properties.keys.sorted { lhs, rhs in
            let lhsRequired = required.contains(lhs), rhsRequired = required.contains(rhs)
            return lhsRequired != rhsRequired ? lhsRequired : lhs < rhs
        }.map { key -> String in
            let type = ((properties[key] as? [String: Any])?["type"] as? String).map { " (\($0))" } ?? ""
            return key + (required.contains(key) ? "*" : "") + type
        }.joined(separator: ", ")
        let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return DottieMCPToolInfo(
            name: name,
            description: String(description.prefix(400)),
            argumentSummary: argumentSummary,
            inputSchemaJSON: String(schemaJSON.prefix(2000))
        )
    }

    private static func text(fromToolResult result: [String: Any]) -> String {
        var pieces: [String] = []
        for contentItem in result["content"] as? [[String: Any]] ?? [] {
            switch contentItem["type"] as? String {
            case "text":
                if let text = contentItem["text"] as? String { pieces.append(text) }
            case "image":
                pieces.append("[a picture (\(contentItem["mimeType"] as? String ?? "image"))]")
            case "audio":
                pieces.append("[a sound clip]")
            case "resource":
                let resource = contentItem["resource"] as? [String: Any] ?? [:]
                if let text = resource["text"] as? String {
                    pieces.append(text)
                } else {
                    pieces.append("[a file: \(resource["uri"] as? String ?? "")]")
                }
            case "resource_link":
                pieces.append("[link: \(contentItem["name"] as? String ?? "") \(contentItem["uri"] as? String ?? "")]")
            default:
                break
            }
        }
        if pieces.isEmpty, let structured = result["structuredContent"],
           let structuredData = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            pieces.append(String(decoding: structuredData, as: UTF8.self))
        }
        return pieces.joined(separator: "\n")
    }
}

// MARK: - Program on the Mac (stdio)

/// Talks to a server program over its stdin and stdout, one JSON message per
/// line.
final class DottieMCPStdioTransport: @unchecked Sendable {
    /// Every server program Dottie started, so quitting can stop them all.
    private static let runningTransportsLock = NSLock()
    private static var runningTransports: [ObjectIdentifier: DottieMCPStdioTransport] = [:]

    /// Stops every server program right away (Dottie is quitting).
    static func closeAll() {
        runningTransportsLock.lock()
        let transports = Array(runningTransports.values)
        runningTransports.removeAll()
        runningTransportsLock.unlock()
        for transport in transports {
            transport.close()
        }
    }

    private let serverName: String
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var pendingReplies: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextRequestID = 1
    private var bufferedOutput = Data()
    private var errorOutput = Data()
    private var running = false

    init(serverName: String, executablePath: String, arguments: [String], environment: [String: String], workingDirectory: String?) throws {
        self.serverName = serverName
        // A server that quits while Dottie writes to it must not take
        // Dottie down with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory, FileManager.default.fileExists(atPath: workingDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let newData = fileHandle.availableData
            if newData.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            self?.consumeOutput(newData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let newData = fileHandle.availableData
            if newData.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            self?.appendErrorOutput(newData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.handleExit()
        }

        do {
            try process.run()
        } catch {
            throw DottieMCPError.couldNotStart(error.localizedDescription)
        }
        lock.lock()
        running = true
        lock.unlock()
        Self.runningTransportsLock.lock()
        Self.runningTransports[ObjectIdentifier(self)] = self
        Self.runningTransportsLock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var errorOutputTail: String {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: errorOutput.suffix(600), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func request(_ method: String, parameters: [String: Any], timeout: TimeInterval, what: String) async throws -> [String: Any] {
        lock.lock()
        let requestID = nextRequestID
        nextRequestID += 1
        lock.unlock()

        let message: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": method, "params": parameters]
        let messageData = try JSONSerialization.data(withJSONObject: message)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard running else {
                lock.unlock()
                continuation.resume(throwing: DottieMCPError.stopped(errorOutputTailUnlocked))
                return
            }
            pendingReplies[requestID] = continuation
            lock.unlock()

            do {
                try write(messageData)
            } catch {
                finishReply(requestID, with: .failure(DottieMCPError.stopped(error.localizedDescription)))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finishReply(requestID, with: .failure(DottieMCPError.timedOut(what)))
            }
        }
    }

    func notify(_ method: String, parameters: [String: Any]? = nil) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let parameters { message["params"] = parameters }
        try write(JSONSerialization.data(withJSONObject: message))
    }

    func close() {
        lock.lock()
        let wasRunning = running
        lock.unlock()
        try? inputPipe.fileHandleForWriting.close()
        guard wasRunning else { return }
        process.terminate()
        let processToKill = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if processToKill.isRunning {
                kill(processToKill.processIdentifier, SIGKILL)
            }
        }
    }

    private func write(_ messageData: Data) throws {
        var line = messageData
        line.append(UInt8(ascii: "\n"))
        try inputPipe.fileHandleForWriting.write(contentsOf: line)
    }

    /// Splits stdout into lines (bytes, so CRLF can't confuse it) and
    /// handles each JSON message.
    private func consumeOutput(_ newData: Data) {
        lock.lock()
        bufferedOutput.append(newData)
        var completeLines: [Data] = []
        while let newlineIndex = bufferedOutput.firstIndex(of: UInt8(ascii: "\n")) {
            completeLines.append(Data(bufferedOutput[bufferedOutput.startIndex..<newlineIndex]))
            bufferedOutput.removeSubrange(bufferedOutput.startIndex...newlineIndex)
        }
        lock.unlock()

        for lineData in completeLines {
            handleLine(lineData)
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            // Some servers log plain text to stdout; ignore it.
            return
        }
        let messageID = Self.integerID(message["id"])
        if let method = message["method"] as? String {
            // The server is asking Dottie something (or just telling).
            guard let rawID = message["id"] else { return }
            respondToServerRequest(method: method, rawID: rawID)
            return
        }
        if let messageID {
            finishReply(messageID, with: .success(message))
        }
    }

    private func respondToServerRequest(method: String, rawID: Any) {
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": rawID]
        switch method {
        case "ping":
            reply["result"] = [String: Any]()
        default:
            reply["error"] = ["code": -32601, "message": "Dottie doesn't support \(method)."]
        }
        if let replyData = try? JSONSerialization.data(withJSONObject: reply) {
            try? write(replyData)
        }
    }

    private func finishReply(_ requestID: Int, with result: Result<[String: Any], Error>) {
        lock.lock()
        let continuation = pendingReplies.removeValue(forKey: requestID)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func appendErrorOutput(_ newData: Data) {
        lock.lock()
        errorOutput.append(newData)
        if errorOutput.count > 8000 {
            errorOutput = Data(errorOutput.suffix(4000))
        }
        lock.unlock()
    }

    private func handleExit() {
        Self.runningTransportsLock.lock()
        Self.runningTransports.removeValue(forKey: ObjectIdentifier(self))
        Self.runningTransportsLock.unlock()
        lock.lock()
        running = false
        let waitingReplies = pendingReplies
        pendingReplies.removeAll()
        let reason = errorOutputTailUnlocked
        lock.unlock()
        for continuation in waitingReplies.values {
            continuation.resume(throwing: DottieMCPError.stopped(Self.lastMeaningfulLine(of: reason)))
        }
    }

    /// Call with the lock held.
    private var errorOutputTailUnlocked: String {
        String(decoding: errorOutput.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lastMeaningfulLine(of text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String((lines.last ?? "").prefix(300))
    }

    static func integerID(_ rawID: Any?) -> Int? {
        if let number = rawID as? NSNumber { return number.intValue }
        if let text = rawID as? String { return Int(text) }
        return nil
    }
}

// MARK: - Web address (Streamable HTTP)

/// Talks to a server at a web address: each message is a POST, and the
/// answer is JSON or a short stream of server-sent events.
final class DottieMCPHTTPTransport: @unchecked Sendable {
    enum SessionExpired: Error { case expired }

    private let url: URL
    private let headers: [String: String]
    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextRequestID = 1
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration)
    }()

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    func setProtocolVersion(_ version: String) {
        lock.lock()
        protocolVersion = version
        lock.unlock()
    }

    func request(_ method: String, parameters: [String: Any], timeout: TimeInterval, what: String) async throws -> [String: Any] {
        lock.lock()
        let requestID = nextRequestID
        nextRequestID += 1
        lock.unlock()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": method, "params": parameters]
        let body = try JSONSerialization.data(withJSONObject: message)

        let session = self
        return try await withDottieTimeout(seconds: timeout, what: what) {
            guard let reply = try await session.post(body, waitingForReplyTo: requestID) else {
                throw DottieMCPError.badReply("No answer came back.")
            }
            return reply
        }
    }

    func notify(_ method: String) async throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        let body = try JSONSerialization.data(withJSONObject: message)
        _ = try await withDottieTimeout(seconds: 20, what: "start") {
            try await self.post(body, waitingForReplyTo: nil)
        }
    }

    private func post(_ body: Data, waitingForReplyTo requestID: Int?) async throws -> [String: Any]? {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        for (headerName, headerValue) in headers {
            urlRequest.setValue(headerValue, forHTTPHeaderField: headerName)
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        lock.lock()
        let currentSessionID = sessionID
        let currentProtocolVersion = protocolVersion
        lock.unlock()
        if let currentSessionID { urlRequest.setValue(currentSessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let currentProtocolVersion { urlRequest.setValue(currentProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }

        let (bytes, response) = try await urlSession.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DottieMCPError.badReply("Not a web answer.")
        }
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id"), !newSessionID.isEmpty {
            lock.lock()
            sessionID = newSessionID
            lock.unlock()
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw DottieMCPError.notAllowed(httpResponse.statusCode)
        case 404 where currentSessionID != nil:
            lock.lock()
            sessionID = nil
            lock.unlock()
            throw SessionExpired.expired
        default:
            let errorBody = try await Self.readAll(bytes, limit: 400)
            throw DottieMCPError.web(httpResponse.statusCode, String(decoding: errorBody, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let requestID else { return nil }
        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            return try await Self.readEventStream(bytes, lookingFor: requestID)
        }
        let replyData = try await Self.readAll(bytes, limit: 32_000_000)
        guard !replyData.isEmpty else { return nil }
        let replyObject = try? JSONSerialization.jsonObject(with: replyData)
        if let reply = replyObject as? [String: Any] { return reply }
        // A batch: pick the answer to this request.
        if let replies = replyObject as? [[String: Any]] {
            return replies.first { DottieMCPStdioTransport.integerID($0["id"]) == requestID }
        }
        throw DottieMCPError.badReply(String(decoding: replyData.prefix(200), as: UTF8.self))
    }

    private static func readAll(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
            if collected.count >= limit { break }
        }
        return collected
    }

    /// Reads server-sent events until the answer to `requestID` arrives.
    /// Lines are split on raw bytes and a trailing CR is dropped, so CRLF
    /// and LF streams both work (see GeminiServerSentEvents for why Swift
    /// strings can't be split on "\n").
    private static func readEventStream(_ bytes: URLSession.AsyncBytes, lookingFor requestID: Int) async throws -> [String: Any]? {
        var currentLine = Data()
        var eventData: [String] = []

        func finishEvent() -> [String: Any]? {
            defer { eventData.removeAll() }
            guard !eventData.isEmpty,
                  let jsonData = eventData.joined(separator: "\n").data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  message["method"] == nil,
                  DottieMCPStdioTransport.integerID(message["id"]) == requestID else { return nil }
            return message
        }

        func handle(_ lineData: Data) -> [String: Any]? {
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                return finishEvent()
            }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                eventData.append(value)
            }
            // "event:", "id:", "retry:" and ":" comments need nothing.
            return nil
        }

        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if let reply = handle(currentLine) { return reply }
                currentLine.removeAll(keepingCapacity: true)
            } else {
                currentLine.append(byte)
            }
        }
        if !currentLine.isEmpty, let reply = handle(currentLine) { return reply }
        return finishEvent()
    }
}

/// Lets a value that isn't Sendable (JSON dictionaries) come back from a
/// child task. Each value is only ever touched by one task at a time.
struct DottieUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Runs `operation`, giving up after `seconds`.
func withDottieTimeout<Value>(seconds: TimeInterval, what: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let boxedResult = try await withThrowingTaskGroup(of: DottieUncheckedBox<Value>.self) { group -> DottieUncheckedBox<Value> in
        group.addTask { DottieUncheckedBox(value: try await operation()) }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DottieMCPError.timedOut(what)
        }
        guard let firstResult = try await group.next() else {
            throw DottieMCPError.timedOut(what)
        }
        group.cancelAll()
        return firstResult
    }
    return boxedResult.value
}
