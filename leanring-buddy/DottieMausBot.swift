//
//  DottieMausBot.swift
//  leanring-buddy
//
//  Helpers on the user's Claude plan. OpenMausBot ("MausBot") is a free,
//  open-source app that runs bots on the Claude Code CLI the user is already
//  signed in to, so helper work uses their Claude subscription instead of
//  Gemini's free tier. This file finds MausBot (its Mac app, or the
//  `openmausbot` npm package), installs it when it's missing, keeps a MausBot
//  workspace running, checks Claude Code is installed and signed in, and
//  decides which engine a helper turn runs on. DottieMausBotRuntime runs the
//  turns themselves.
//
//  Everything goes through MausBot's headless CLI (`openmausbot … --json`),
//  which talks to the workspace on 127.0.0.1:8799 (or 18799, 28799):
//    doctor, bots, models       is it up, which bots, which engines
//    team apply FILE            make or update a helper's bot
//    run / wait / interrupt     a helper turn
//    events                     live messages for the transcript
//  Exit codes: 0 done, 1 failed, 2 bad arguments, 3 needs the user,
//  4 timed out (the work keeps going), 5 can't reach the workspace.
//
//  On disk, under ~/Library/Application Support/Dottie/MausBot/:
//    npm/                       openmausbot and Claude Code, when Dottie installed them
//    teams/, messages/          files handed to the CLI, removed after use
//    claude-sign-in.command     opens Terminal on `claude auth login`
//    workspace.log              output of the workspace Dottie started, if any
//

import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - Engine choice

/// Which engine helper turns run on.
enum DottieHelperEngine: String, CaseIterable, Identifiable {
    /// Claude through MausBot, with Gemini CLI as the automatic backup.
    case claudeWithBackup = "claude"
    /// Gemini CLI only (the free tier), as before MausBot.
    case geminiOnly = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeWithBackup: return "Claude (MausBot), backup: Gemini"
        case .geminiOnly: return "Gemini only"
        }
    }

    static let preferenceDefaultsKey = "dottieHelperEngine"
    private static let claudePausedUntilDefaultsKey = "dottieClaudePausedUntil"
    private static let claudePauseReasonDefaultsKey = "dottieClaudePauseReason"

    static var preference: DottieHelperEngine {
        get {
            UserDefaults.standard.string(forKey: preferenceDefaultsKey).flatMap(DottieHelperEngine.init(rawValue:)) ?? .claudeWithBackup
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceDefaultsKey) }
    }

    /// Set after Claude hit a limit or an outage: until then helpers go
    /// straight to the backup, then Claude gets another try.
    static var claudePausedUntil: Date? {
        let pausedUntil = UserDefaults.standard.object(forKey: claudePausedUntilDefaultsKey) as? Date
        guard let pausedUntil, pausedUntil > Date() else { return nil }
        return pausedUntil
    }

    /// Why Claude is paused, in a few plain words.
    static var claudePauseReason: String? {
        guard claudePausedUntil != nil else { return nil }
        return UserDefaults.standard.string(forKey: claudePauseReasonDefaultsKey)
    }

    static func pauseClaude(for reason: DottieClaudeFallbackReason) {
        UserDefaults.standard.set(Date().addingTimeInterval(reason.pauseDuration), forKey: claudePausedUntilDefaultsKey)
        UserDefaults.standard.set(reason.pauseStatusText, forKey: claudePauseReasonDefaultsKey)
    }

    static func resumeClaude() {
        UserDefaults.standard.removeObject(forKey: claudePausedUntilDefaultsKey)
        UserDefaults.standard.removeObject(forKey: claudePauseReasonDefaultsKey)
    }
}

/// Why a helper turn moved from Claude to the Gemini backup.
enum DottieClaudeFallbackReason: Error, Equatable {
    /// The Claude plan's usage limit ran out.
    case usageLimit
    /// Claude is rate limited or overloaded for a moment.
    case busy
    /// Claude Code isn't signed in.
    case notSignedIn
    /// MausBot's workspace didn't answer or couldn't be started.
    case notReachable
    /// Anything else the engine reported, kept for the logs.
    case engineProblem(String)

    /// The small note in the helper's chat.
    var noteForTranscript: String {
        switch self {
        case .usageLimit: return "Claude limit reached, using the free backup"
        case .busy: return "Claude is busy right now, using the free backup"
        case .notSignedIn: return "Claude isn't signed in, using the free backup"
        case .notReachable: return "MausBot isn't answering, using the free backup"
        case .engineProblem: return "Claude couldn't take this one, using the free backup"
        }
    }

    /// Shown in Settings while Claude is paused.
    var pauseStatusText: String {
        switch self {
        case .usageLimit: return "Your Claude limit was reached"
        case .busy: return "Claude was busy"
        case .notSignedIn: return "Claude isn't signed in"
        case .notReachable: return "MausBot wasn't answering"
        case .engineProblem: return "Claude had a problem"
        }
    }

    /// How long helpers skip Claude before trying it again.
    var pauseDuration: TimeInterval {
        switch self {
        case .usageLimit: return 30 * 60
        case .notSignedIn: return 10 * 60
        case .busy, .notReachable, .engineProblem: return 5 * 60
        }
    }

    /// Reads an engine error the way MausBot's own retry rules do. Nil when
    /// the text doesn't look like a limit, a sign-in or an engine problem.
    static func classify(_ errorText: String) -> DottieClaudeFallbackReason? {
        let lowercasedText = errorText.lowercased()
        guard !lowercasedText.isEmpty else { return nil }
        func matches(_ pattern: String) -> Bool {
            lowercasedText.range(of: pattern, options: .regularExpression) != nil
        }
        // A plan running out, however Claude Code words it ("You've hit your
        // weekly limit · resets …", "5-hour limit reached", "out of usage credits").
        if matches("usage limit|hit your ([a-z'’-]+ ){0,3}(limit|budget)|(weekly|daily|monthly|subscription|usage|session|5-hour|opus) limit reached|out of (usage|extra usage|credits)|\\bquota\\b|billing") {
            return .usageLimit
        }
        if matches("not logged in|logged out|please run /login|\\bunauthorized\\b|authentication|invalid api key|\\b401\\b|sign in to claude|oauth token") {
            return .notSignedIn
        }
        if matches("rate.?limit|too many requests|\\b429\\b|overloaded|\\bcapacity\\b|\\b529\\b") {
            return .busy
        }
        if matches("cli not found|command not found|enoent|exited [0-9-]+ before result|provider_error|no engine is available|engine .*unavailable|cannot reach openmausbot") {
            return .engineProblem(String(errorText.prefix(300)))
        }
        return nil
    }
}

/// Whether the next helper turn can run on Claude.
enum DottieClaudeReadiness {
    /// MausBot is up; run the turn through this launcher.
    case ready(DottieMausBotLauncher)
    /// Use Gemini without a note: Gemini only is chosen, MausBot isn't set
    /// up, or Claude is paused after an earlier problem.
    case skip
    /// Claude was expected but isn't usable now: note it and use Gemini.
    case fallback(DottieClaudeFallbackReason)
}

// MARK: - Where things live

enum DottieMausBotPaths {
    static var folderURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupportURL
            .appendingPathComponent("Dottie", isDirectory: true)
            .appendingPathComponent("MausBot", isDirectory: true)
    }

    /// npm prefix for the packages Dottie installs itself.
    static var npmPrefixURL: URL { folderURL.appendingPathComponent("npm", isDirectory: true) }
    static var npmBinFolderURL: URL { npmPrefixURL.appendingPathComponent("bin", isDirectory: true) }
    static var dottieInstalledCLIScriptURL: URL {
        npmPrefixURL.appendingPathComponent("lib/node_modules/openmausbot/cli.js", isDirectory: false)
    }
    static var dottieInstalledClaudeURL: URL { npmBinFolderURL.appendingPathComponent("claude", isDirectory: false) }
    static var teamFilesFolderURL: URL { folderURL.appendingPathComponent("teams", isDirectory: true) }
    static var messageFilesFolderURL: URL { folderURL.appendingPathComponent("messages", isDirectory: true) }
    static var claudeSignInScriptURL: URL { folderURL.appendingPathComponent("claude-sign-in.command", isDirectory: false) }
    static var workspaceLogURL: URL { folderURL.appendingPathComponent("workspace.log", isDirectory: false) }

    static func ensureFoldersExist() {
        for folderURL in [folderURL, teamFilesFolderURL, messageFilesFolderURL] {
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Finding MausBot and Claude Code

/// How to run the `openmausbot` CLI on this Mac.
struct DottieMausBotLauncher: Sendable {
    enum Source: Sendable, Equatable {
        /// /Applications/OpenMausBot.app, whose Electron binary runs the
        /// bundled CLI as plain Node (ELECTRON_RUN_AS_NODE).
        case desktopApp
        /// An `openmausbot` the user installed with npm.
        case userInstall
        /// The npm package Dottie installed with its own Node.js.
        case dottieInstall
    }

    let source: Source
    let executableURL: URL
    let leadingArguments: [String]
    let extraEnvironment: [String: String]

    var displayName: String {
        switch source {
        case .desktopApp: return "the MausBot app"
        case .userInstall: return "your MausBot install"
        case .dottieInstall: return "MausBot (set up by Dottie)"
        }
    }
}

/// Finds things on disk. Blocking: call from a background task.
enum DottieMausBotLocator {
    static let desktopAppBundleIdentifier = "com.openmausbot.app"

    static func desktopAppURL() -> URL? {
        if let registeredURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopAppBundleIdentifier) {
            return registeredURL
        }
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/OpenMausBot.app", "\(homeDirectoryPath)/Applications/OpenMausBot.app"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isDesktopAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: desktopAppBundleIdentifier).isEmpty
    }

    /// The MausBot app first (it matches the workspace it runs), then an
    /// install the user made, then Dottie's own copy.
    static func locateLauncher() -> DottieMausBotLauncher? {
        if let desktopAppURL = desktopAppURL() {
            let serverScriptURL = desktopAppURL.appendingPathComponent("Contents/Resources/server/openmausbot.js")
            let executableURL = Bundle(url: desktopAppURL)?.executableURL
                ?? desktopAppURL.appendingPathComponent("Contents/MacOS/OpenMausBot")
            if FileManager.default.fileExists(atPath: serverScriptURL.path),
               FileManager.default.isExecutableFile(atPath: executableURL.path) {
                return DottieMausBotLauncher(
                    source: .desktopApp,
                    executableURL: executableURL,
                    leadingArguments: [serverScriptURL.path],
                    extraEnvironment: ["ELECTRON_RUN_AS_NODE": "1"]
                )
            }
        }

        if let userInstalledPath = locateCommand(named: "openmausbot", skippingFolder: DottieMausBotPaths.npmBinFolderURL.path) {
            return DottieMausBotLauncher(
                source: .userInstall,
                executableURL: URL(fileURLWithPath: userInstalledPath),
                leadingArguments: [],
                extraEnvironment: [:]
            )
        }

        let dottieNodeURL = DotsRuntimeInstaller.nodeBinFolderURL.appendingPathComponent("node")
        if FileManager.default.fileExists(atPath: DottieMausBotPaths.dottieInstalledCLIScriptURL.path),
           FileManager.default.isExecutableFile(atPath: dottieNodeURL.path) {
            return DottieMausBotLauncher(
                source: .dottieInstall,
                executableURL: dottieNodeURL,
                leadingArguments: [DottieMausBotPaths.dottieInstalledCLIScriptURL.path],
                extraEnvironment: [:]
            )
        }
        return nil
    }

    /// The `claude` CLI MausBot's Claude engine runs: the places MausBot
    /// itself looks, Dottie's own copy, then the login shell.
    static func locateClaudeCLI() -> URL? {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(homeDirectoryPath)/.local/bin/claude",
            "\(homeDirectoryPath)/.claude/local/claude",
            DottieMausBotPaths.dottieInstalledClaudeURL.path,
            "\(homeDirectoryPath)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(homeDirectoryPath)/.volta/bin/claude",
            "\(homeDirectoryPath)/.bun/bin/claude"
        ]
        if let foundPath = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: foundPath)
        }
        return lookUpInLoginShell("claude").map { URL(fileURLWithPath: $0) }
    }

    /// Common install folders, then the login shell (GUI apps don't inherit
    /// the shell's PATH, so nvm and friends are only known there).
    private static func locateCommand(named commandName: String, skippingFolder skippedFolderPath: String) -> String? {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "/opt/homebrew/bin/\(commandName)",
            "/usr/local/bin/\(commandName)",
            "\(homeDirectoryPath)/.npm-global/bin/\(commandName)",
            "\(homeDirectoryPath)/.local/bin/\(commandName)",
            "\(homeDirectoryPath)/.volta/bin/\(commandName)",
            "\(homeDirectoryPath)/.bun/bin/\(commandName)"
        ]
        if let foundPath = commonPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return foundPath
        }
        guard let shellPath = lookUpInLoginShell(commandName),
              !shellPath.hasPrefix(skippedFolderPath) else { return nil }
        return shellPath
    }

    private static func lookUpInLoginShell(_ commandName: String) -> String? {
        let lookupOutput = runLoginShell("command -v \(commandName)")
        guard let lookupOutput, lookupOutput.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: lookupOutput) else { return nil }
        return lookupOutput
    }

    /// The login shell's PATH, so `#!/usr/bin/env node` scripts and the
    /// bots' shell commands find the user's tools.
    static let loginShellPATH: String? = runLoginShell("echo $PATH")

    private static func runLoginShell(_ command: String) -> String? {
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shellProcess.arguments = ["-lc", command]
        let outputPipe = Pipe()
        shellProcess.standardOutput = outputPipe
        shellProcess.standardError = FileHandle.nullDevice
        shellProcess.standardInput = FileHandle.nullDevice
        do {
            try shellProcess.run()
        } catch {
            return nil
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        shellProcess.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// Environment for every MausBot process: Dottie's Node.js first (MausBot
    /// needs Node 24), Dottie's npm folder (its `claude`), then the user's PATH.
    static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var pathFolders: [String] = []
        if DotsRuntimeInstaller.isInstalled {
            pathFolders.append(DotsRuntimeInstaller.nodeBinFolderURL.path)
        }
        pathFolders.append(DottieMausBotPaths.npmBinFolderURL.path)
        pathFolders.append(loginShellPATH ?? environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["PATH"] = pathFolders.joined(separator: ":")
        // MausBot adds this to the PATH its engines run with, so a workspace
        // finds the Claude Code Dottie installed.
        environment["OMB_EXTRA_PATH"] = DottieMausBotPaths.npmBinFolderURL.path
        environment["NO_COLOR"] = "1"
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        return environment
    }
}

// MARK: - Running commands

/// What one command printed and how it ended.
struct DottieMausBotCommandResult: @unchecked Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardErrorTail: String

    /// The one JSON document `--json` prints (failures included).
    var jsonObject: [String: Any]? {
        try? JSONSerialization.jsonObject(with: standardOutput) as? [String: Any]
    }

    /// The CLI's own words for a failure, else the end of stderr.
    var errorText: String {
        if let jsonObject, let errorMessage = jsonObject["error"] as? String, !errorMessage.isEmpty {
            return errorMessage
        }
        return standardErrorTail
    }
}

enum DottieMausBotCLI {
    static let exitDone: Int32 = 0
    static let exitFailed: Int32 = 1
    static let exitBadArguments: Int32 = 2
    static let exitNeedsInput: Int32 = 3
    static let exitTimedOut: Int32 = 4
    static let exitUnreachable: Int32 = 5
    /// The process couldn't be started at all.
    static let exitCouldNotLaunch: Int32 = -1

    /// Runs `openmausbot <arguments>`. `onProgressLine` gets each JSON line
    /// the CLI writes to stderr (run's progress), `onLaunch` the process
    /// once it started (to stop it). `timeout` stops a command that hangs.
    static func run(
        _ arguments: [String],
        launcher: DottieMausBotLauncher,
        timeout: TimeInterval? = 60,
        onProgressLine: (@Sendable ([String: Any]) -> Void)? = nil,
        onLaunch: (@Sendable (Process) -> Void)? = nil
    ) async -> DottieMausBotCommandResult {
        var environment = DottieMausBotLocator.childEnvironment()
        environment.merge(launcher.extraEnvironment) { _, launcherValue in launcherValue }
        return await DottieMausBotProcessRunner.run(
            executableURL: launcher.executableURL,
            arguments: launcher.leadingArguments + arguments,
            environment: environment,
            timeout: timeout,
            onStandardErrorLine: onProgressLine.map { progressHandler in
                { lineData in
                    if let progressObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        progressHandler(progressObject)
                    }
                }
            },
            onLaunch: onLaunch
        )
    }
}

/// Runs a process to the end without blocking a thread, collecting stdout
/// and the tail of stderr. Output is read as it arrives, so a big JSON
/// document can't fill the pipe and stall the process.
enum DottieMausBotProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        onStandardErrorLine: (@Sendable (Data) -> Void)? = nil,
        onLaunch: (@Sendable (Process) -> Void)? = nil
    ) async -> DottieMausBotCommandResult {
        DottieMausBotPaths.ensureFoldersExist()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = DottieMausBotPaths.folderURL
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        let collector = DottieMausBotOutputCollector(onStandardErrorLine: onStandardErrorLine)
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let availableData = fileHandle.availableData
            guard !availableData.isEmpty else { return }
            collector.appendStandardOutput(availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let availableData = fileHandle.availableData
            guard !availableData.isEmpty else { return }
            collector.appendStandardError(availableData)
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
            do {
                try process.run()
                onLaunch?(process)
                if let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak process] in
                        if let process, process.isRunning {
                            process.terminate()
                        }
                    }
                }
            } catch {
                process.terminationHandler = nil
                collector.appendStandardError(Data(error.localizedDescription.utf8))
                continuation.resume(returning: DottieMausBotCLI.exitCouldNotLaunch)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if exitCode != DottieMausBotCLI.exitCouldNotLaunch {
            // Whatever arrived between the last read and the exit.
            collector.appendStandardOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
            collector.appendStandardError(errorPipe.fileHandleForReading.readDataToEndOfFile())
        }
        collector.flushStandardErrorLine()
        return DottieMausBotCommandResult(
            exitCode: exitCode,
            standardOutput: collector.standardOutput,
            standardErrorTail: collector.standardErrorTail
        )
    }
}

/// Collects a process's output from the pipes' background queues.
private final class DottieMausBotOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedOutput = Data()
    private var collectedErrorTail = Data()
    private var pendingErrorLine = Data()
    private let onStandardErrorLine: (@Sendable (Data) -> Void)?
    private let maximumErrorTailBytes = 1_500

    init(onStandardErrorLine: (@Sendable (Data) -> Void)?) {
        self.onStandardErrorLine = onStandardErrorLine
    }

    var standardOutput: Data {
        lock.lock()
        defer { lock.unlock() }
        return collectedOutput
    }

    var standardErrorTail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collectedErrorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func appendStandardOutput(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        collectedOutput.append(newData)
        lock.unlock()
    }

    func appendStandardError(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        collectedErrorTail.append(newData)
        if collectedErrorTail.count > maximumErrorTailBytes {
            collectedErrorTail = collectedErrorTail.suffix(maximumErrorTailBytes)
        }
        var completeLines: [Data] = []
        if onStandardErrorLine != nil {
            pendingErrorLine.append(newData)
            // Split on the newline byte, never on Characters ("\r\n" is one).
            while let newlineIndex = pendingErrorLine.firstIndex(of: UInt8(ascii: "\n")) {
                completeLines.append(Data(pendingErrorLine[pendingErrorLine.startIndex..<newlineIndex]))
                pendingErrorLine.removeSubrange(pendingErrorLine.startIndex...newlineIndex)
            }
        }
        lock.unlock()
        for completeLine in completeLines where !completeLine.isEmpty {
            onStandardErrorLine?(completeLine)
        }
    }

    func flushStandardErrorLine() {
        lock.lock()
        let remainingLine = pendingErrorLine
        pendingErrorLine = Data()
        lock.unlock()
        if !remainingLine.isEmpty {
            onStandardErrorLine?(remainingLine)
        }
    }
}

// MARK: - Setup and status

/// Keeps MausBot ready for helpers and shows how it's doing in Settings.
@MainActor
final class DottieMausBot: ObservableObject {
    static let shared = DottieMausBot()

    /// The openmausbot npm version Dottie installs (the one its JSON was
    /// checked against). A MausBot app or the user's own install wins.
    static let pinnedMausBotVersion = "0.1.115"
    /// How long a successful workspace check is trusted before asking again.
    private static let workspaceCheckLifetime: TimeInterval = 120

    enum ClaudeState: Equatable {
        case unknown
        case notInstalled
        case notSignedIn
        case ready
    }

    @Published private(set) var launcherSource: DottieMausBotLauncher.Source?
    @Published private(set) var hasLookedForMausBot = false
    @Published private(set) var isWorkspaceReachable = false
    @Published private(set) var isWorkspaceStartedByDottie = false
    @Published private(set) var claudeState: ClaudeState = .unknown
    /// What a setup step is doing right now ("Installing MausBot…").
    @Published private(set) var busyText: String?
    @Published private(set) var problemText: String?
    @Published private(set) var preference: DottieHelperEngine = DottieHelperEngine.preference
    @Published private(set) var claudePausedUntil: Date? = DottieHelperEngine.claudePausedUntil
    @Published private(set) var claudePauseReason: String? = DottieHelperEngine.claudePauseReason
    /// Claude turns running now, so the workspace isn't swapped under them.
    @Published private(set) var activeClaudeTurnCount = 0

    private(set) var launcher: DottieMausBotLauncher?
    private var ownedWorkspaceProcess: Process?
    private var workspaceConfirmedAt: Date?
    private var workspaceStartTask: Task<Bool, Never>?
    private var claudeCheckedAt: Date?
    private var setUpTask: Task<Void, Never>?
    private var signInWatchTask: Task<Void, Never>?
    private var cachedHelperModelSelection: String?
    private var hasScheduledWarmUp = false
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopOwnedWorkspace()
            }
        }
    }

    var isSetUp: Bool { launcher != nil }

    var isSettingUp: Bool { setUpTask != nil }

    // MARK: Engine choice

    func setPreference(_ newPreference: DottieHelperEngine) {
        DottieHelperEngine.preference = newPreference
        preference = newPreference
        if newPreference == .claudeWithBackup {
            refreshStatus(startWorkspace: true)
        }
    }

    func pauseClaude(for reason: DottieClaudeFallbackReason) {
        DottieHelperEngine.pauseClaude(for: reason)
        claudePausedUntil = DottieHelperEngine.claudePausedUntil
        claudePauseReason = DottieHelperEngine.claudePauseReason
        if reason == .notReachable {
            workspaceConfirmedAt = nil
            isWorkspaceReachable = false
        }
        if reason == .notSignedIn {
            claudeState = .notSignedIn
            claudeCheckedAt = Date()
        }
    }

    /// "Try Claude now" in Settings.
    func resumeClaude() {
        DottieHelperEngine.resumeClaude()
        claudePausedUntil = nil
        claudePauseReason = nil
        refreshStatus(startWorkspace: true)
    }

    func claudeTurnStarted() { activeClaudeTurnCount += 1 }
    func claudeTurnEnded() { activeClaudeTurnCount = max(0, activeClaudeTurnCount - 1) }

    /// Decides where the next helper turn runs, starting MausBot's
    /// workspace first if it's set up but not running.
    func readinessForHelperTurn() async -> DottieClaudeReadiness {
        guard preference == .claudeWithBackup else { return .skip }
        if DottieHelperEngine.claudePausedUntil != nil {
            return .skip
        }
        guard let launcher = await currentLauncher() else { return .skip }
        if let claudeCheckedAt, Date().timeIntervalSince(claudeCheckedAt) < Self.workspaceCheckLifetime {
            if claudeState == .notSignedIn { return .fallback(.notSignedIn) }
            if claudeState == .notInstalled { return .fallback(.engineProblem("Claude Code isn't installed")) }
        }
        guard await ensureWorkspaceReady(launcher: launcher) else {
            return .fallback(.notReachable)
        }
        return .ready(launcher)
    }

    /// The launcher, looked up once (the login shell lookup is slow).
    func currentLauncher() async -> DottieMausBotLauncher? {
        if let launcher, FileManager.default.fileExists(atPath: launcher.executableURL.path) {
            return launcher
        }
        let foundLauncher = await Task.detached(priority: .userInitiated) {
            DottieMausBotLocator.locateLauncher()
        }.value
        launcher = foundLauncher
        launcherSource = foundLauncher?.source
        hasLookedForMausBot = true
        return foundLauncher
    }

    /// "claude/<model>" for new helper bots: Claude's default in this
    /// workspace, unless Info.plist's MausBotHelperModel says otherwise.
    func helperModelSelection(launcher: DottieMausBotLauncher) async -> String? {
        if let configuredSelection = AppBundleConfiguration.stringValue(forKey: "MausBotHelperModel") {
            return configuredSelection
        }
        if let cachedHelperModelSelection { return cachedHelperModelSelection }
        let modelsResult = await DottieMausBotCLI.run(["models", "--json"], launcher: launcher, timeout: 30)
        let instances = modelsResult.jsonObject?["instances"] as? [[String: Any]] ?? []
        guard let claudeInstance = instances.first(where: { ($0["instanceId"] as? String) == "claude" }),
              let models = claudeInstance["models"] as? [String: Any],
              let defaultModel = models["default"] as? String, !defaultModel.isEmpty else { return nil }
        cachedHelperModelSelection = "claude/\(defaultModel)"
        return cachedHelperModelSelection
    }

    // MARK: Workspace

    /// Makes sure a MausBot workspace answers: the MausBot app (opened in the
    /// background if it's installed), else `openmausbot serve` as a child of
    /// Dottie that stops when Dottie quits.
    func ensureWorkspaceReady(launcher: DottieMausBotLauncher) async -> Bool {
        if let workspaceConfirmedAt, Date().timeIntervalSince(workspaceConfirmedAt) < Self.workspaceCheckLifetime {
            return true
        }
        if let workspaceStartTask {
            return await workspaceStartTask.value
        }
        let startTask = Task { await self.startWorkspaceIfNeeded(launcher: launcher) }
        workspaceStartTask = startTask
        let isReady = await startTask.value
        workspaceStartTask = nil
        return isReady
    }

    private func startWorkspaceIfNeeded(launcher: DottieMausBotLauncher) async -> Bool {
        if await checkWorkspace(launcher: launcher) {
            return true
        }
        if let desktopAppURL = DottieMausBotLocator.desktopAppURL() {
            // Two workspaces can't share MausBot's data folder, so with the
            // app installed the app runs it.
            if !DottieMausBotLocator.isDesktopAppRunning {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                _ = try? await NSWorkspace.shared.openApplication(at: desktopAppURL, configuration: configuration)
            }
        } else if ownedWorkspaceProcess?.isRunning != true {
            startOwnedWorkspace(launcher: launcher)
        }
        // A fresh workspace takes a few seconds to come up.
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 750_000_000)
            if await checkWorkspace(launcher: launcher) {
                return true
            }
            if DottieMausBotLocator.desktopAppURL() == nil && ownedWorkspaceProcess == nil {
                break
            }
        }
        return false
    }

    /// One `doctor`: is a workspace answering, and does it see Claude Code?
    private func checkWorkspace(launcher: DottieMausBotLauncher) async -> Bool {
        let doctorResult = await DottieMausBotCLI.run(["doctor", "--json"], launcher: launcher, timeout: 25)
        // 1 means the workspace answered but no engine is ready yet.
        let isReachable = doctorResult.exitCode == DottieMausBotCLI.exitDone
            || (doctorResult.exitCode == DottieMausBotCLI.exitFailed && (doctorResult.jsonObject?["health"] as? [String: Any]) != nil)
        isWorkspaceReachable = isReachable
        if isReachable {
            workspaceConfirmedAt = Date()
            let availableEngines = doctorResult.jsonObject?["availableEngines"] as? [String] ?? []
            if !availableEngines.contains("claude") {
                claudeState = .notInstalled
                claudeCheckedAt = Date()
            }
        } else {
            workspaceConfirmedAt = nil
        }
        return isReachable
    }

    private func startOwnedWorkspace(launcher: DottieMausBotLauncher) {
        DottieMausBotPaths.ensureFoldersExist()
        let workspaceProcess = Process()
        workspaceProcess.executableURL = launcher.executableURL
        workspaceProcess.arguments = launcher.leadingArguments + ["serve", "--no-pair"]
        var environment = DottieMausBotLocator.childEnvironment()
        environment.merge(launcher.extraEnvironment) { _, launcherValue in launcherValue }
        workspaceProcess.environment = environment
        workspaceProcess.currentDirectoryURL = DottieMausBotPaths.folderURL
        workspaceProcess.standardInput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: DottieMausBotPaths.workspaceLogURL.path, contents: nil)
        if let logFileHandle = try? FileHandle(forWritingTo: DottieMausBotPaths.workspaceLogURL) {
            workspaceProcess.standardOutput = logFileHandle
            workspaceProcess.standardError = logFileHandle
        } else {
            workspaceProcess.standardOutput = FileHandle.nullDevice
            workspaceProcess.standardError = FileHandle.nullDevice
        }
        workspaceProcess.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.ownedWorkspaceProcess === workspaceProcess else { return }
                    self.ownedWorkspaceProcess = nil
                    self.isWorkspaceStartedByDottie = false
                    self.workspaceConfirmedAt = nil
                }
            }
        }
        do {
            try workspaceProcess.run()
            ownedWorkspaceProcess = workspaceProcess
            isWorkspaceStartedByDottie = true
        } catch {
            problemText = "MausBot didn't start: \(error.localizedDescription)"
        }
    }

    /// Stops the workspace Dottie started (on quit, or before the MausBot
    /// app takes over). A workspace the MausBot app runs is left alone.
    func stopOwnedWorkspace() {
        guard let ownedWorkspaceProcess else { return }
        ownedWorkspaceProcess.terminationHandler = nil
        if ownedWorkspaceProcess.isRunning {
            ownedWorkspaceProcess.terminate()
        }
        self.ownedWorkspaceProcess = nil
        isWorkspaceStartedByDottie = false
        workspaceConfirmedAt = nil
    }

    // MARK: Status

    /// Looks for MausBot when Dottie starts and, when helpers run on Claude
    /// and it's set up, starts its workspace so the first task is quick.
    /// Installs nothing.
    func warmUpAfterLaunch() {
        guard !hasScheduledWarmUp else { return }
        hasScheduledWarmUp = true
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await self.performStatusRefresh(startWorkspace: self.preference == .claudeWithBackup)
        }
    }

    /// "Check again" in Settings.
    func refreshStatus(startWorkspace: Bool) {
        Task { await self.performStatusRefresh(startWorkspace: startWorkspace) }
    }

    private func performStatusRefresh(startWorkspace: Bool) async {
        launcher = nil
        guard let launcher = await currentLauncher() else {
            isWorkspaceReachable = false
            await refreshClaudeState()
            return
        }
        workspaceConfirmedAt = nil
        if startWorkspace {
            _ = await ensureWorkspaceReady(launcher: launcher)
        } else {
            _ = await checkWorkspace(launcher: launcher)
        }
        await refreshClaudeState()
        claudePausedUntil = DottieHelperEngine.claudePausedUntil
        claudePauseReason = DottieHelperEngine.claudePauseReason
    }

    /// Asks Claude Code itself whether it's signed in (`claude auth status`),
    /// as MausBot does.
    func refreshClaudeState() async {
        let claudeURL = await Task.detached(priority: .userInitiated) {
            DottieMausBotLocator.locateClaudeCLI()
        }.value
        claudeCheckedAt = Date()
        guard let claudeURL else {
            claudeState = .notInstalled
            return
        }
        let statusResult = await DottieMausBotProcessRunner.run(
            executableURL: claudeURL,
            arguments: ["auth", "status", "--json"],
            environment: DottieMausBotLocator.childEnvironment(),
            timeout: 15
        )
        let statusObject = try? JSONSerialization.jsonObject(with: statusResult.standardOutput) as? [String: Any]
        if let isLoggedIn = statusObject?["loggedIn"] as? Bool {
            claudeState = isLoggedIn ? .ready : .notSignedIn
        } else if statusResult.exitCode == DottieMausBotCLI.exitCouldNotLaunch {
            claudeState = .notInstalled
        } else {
            // A check that timed out (a Keychain prompt left open) says nothing.
            claudeState = claudeState == .notInstalled ? .unknown : claudeState
        }
    }

    // MARK: One-tap setup

    /// Installs what's missing (MausBot, Claude Code) into Dottie's own
    /// folder with Dottie's own Node.js (no admin password), starts the
    /// workspace and opens the Claude sign-in if it's needed.
    func setUp() {
        guard setUpTask == nil else { return }
        setUpTask = Task {
            await self.performSetUp()
            self.busyText = nil
            self.setUpTask = nil
        }
    }

    private func performSetUp() async {
        problemText = nil
        launcher = nil
        var foundLauncher = await currentLauncher()

        if foundLauncher == nil {
            busyText = "Getting Node.js ready…"
            do {
                try await DotsRuntimeInstaller.shared.installIfNeeded()
            } catch {
                problemText = error.localizedDescription
                return
            }
            busyText = "Installing MausBot (a one-time download)…"
            let installResult = await installNpmPackage("openmausbot@\(Self.pinnedMausBotVersion)")
            launcher = nil
            foundLauncher = await currentLauncher()
            if foundLauncher == nil {
                problemText = "Couldn't install MausBot. Check your internet connection and try again."
                print("⚠️ MausBot install failed: \(installResult.standardErrorTail)")
                return
            }
        }
        guard let foundLauncher else { return }

        let existingClaudeURL = await Task.detached(priority: .userInitiated) {
            DottieMausBotLocator.locateClaudeCLI()
        }.value
        if existingClaudeURL == nil {
            busyText = "Getting Node.js ready…"
            do {
                try await DotsRuntimeInstaller.shared.installIfNeeded()
            } catch {
                problemText = error.localizedDescription
                return
            }
            busyText = "Installing Claude Code…"
            let installResult = await installNpmPackage("@anthropic-ai/claude-code")
            guard FileManager.default.isExecutableFile(atPath: DottieMausBotPaths.dottieInstalledClaudeURL.path) else {
                problemText = "Couldn't install Claude Code. Check your internet connection and try again."
                print("⚠️ Claude Code install failed: \(installResult.standardErrorTail)")
                return
            }
            linkClaudeIntoLocalBin()
        }

        busyText = "Starting MausBot…"
        workspaceConfirmedAt = nil
        guard await ensureWorkspaceReady(launcher: foundLauncher) else {
            problemText = DottieMausBotLocator.desktopAppURL() != nil
                ? "MausBot didn't start. Open the MausBot app once, then tap Check again."
                : "MausBot didn't start. Try again in a minute."
            return
        }

        busyText = "Checking your Claude sign-in…"
        await refreshClaudeState()
        DottieHelperEngine.resumeClaude()
        claudePausedUntil = nil
        claudePauseReason = nil
        if claudeState == .notSignedIn {
            openClaudeSignIn()
        }
    }

    /// `npm install --global --prefix <Dottie's folder> <package>` with
    /// Dottie's own Node.js, so nothing needs an admin password.
    private func installNpmPackage(_ packageSpecifier: String) async -> DottieMausBotCommandResult {
        DottieMausBotPaths.ensureFoldersExist()
        let nodeBinFolderPath = DotsRuntimeInstaller.nodeBinFolderURL.path
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(nodeBinFolderPath):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["NO_COLOR"] = "1"
        return await DottieMausBotProcessRunner.run(
            executableURL: DotsRuntimeInstaller.nodeBinFolderURL.appendingPathComponent("npm"),
            arguments: [
                "install", "--global",
                "--prefix", DottieMausBotPaths.npmPrefixURL.path,
                "--no-audit", "--no-fund", "--loglevel", "error",
                packageSpecifier
            ],
            environment: environment,
            timeout: 15 * 60
        )
    }

    /// Claude Code's own installer puts `claude` in ~/.local/bin, where the
    /// MausBot app looks. Links Dottie's copy there when nothing else is.
    private func linkClaudeIntoLocalBin() {
        let localBinFolderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let linkURL = localBinFolderURL.appendingPathComponent("claude")
        guard (try? FileManager.default.attributesOfItem(atPath: linkURL.path)) == nil else { return }
        try? FileManager.default.createDirectory(at: localBinFolderURL, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: DottieMausBotPaths.dottieInstalledClaudeURL)
    }

    // MARK: Claude sign-in

    /// Opens Terminal on `claude auth login`. The user finishes in their
    /// browser once; Dottie notices by itself when it's done.
    func openClaudeSignIn() {
        Task {
            let claudeURL = await Task.detached(priority: .userInitiated) {
                DottieMausBotLocator.locateClaudeCLI()
            }.value
            guard let claudeURL else {
                self.problemText = "Claude Code isn't installed yet. Tap Set up first."
                return
            }
            DottieMausBotPaths.ensureFoldersExist()
            let escapedClaudePath = claudeURL.path.replacingOccurrences(of: "'", with: "'\\''")
            let signInScript = """
            #!/bin/zsh
            # Written by Dottie: signs Claude Code in so Dottie's helpers can use your Claude plan.
            unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR
            clear
            echo "Signing in to Claude for Dottie's helpers."
            echo "Finish in your browser, then come back to Dottie."
            echo
            '\(escapedClaudePath)' auth login --claudeai
            echo
            echo "All set. You can close this window."

            """
            let scriptURL = DottieMausBotPaths.claudeSignInScriptURL
            do {
                try signInScript.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            } catch {
                self.problemText = "Couldn't open the Claude sign-in: \(error.localizedDescription)"
                return
            }
            NSWorkspace.shared.open(scriptURL)
            self.watchForClaudeSignIn()
        }
    }

    /// Checks every few seconds (a local command, no model calls) until
    /// Claude is signed in, for up to five minutes.
    private func watchForClaudeSignIn() {
        signInWatchTask?.cancel()
        signInWatchTask = Task {
            for _ in 0..<75 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { return }
                await self.refreshClaudeState()
                if self.claudeState == .ready {
                    if DottieHelperEngine.claudePauseReason == DottieClaudeFallbackReason.notSignedIn.pauseStatusText {
                        self.resumeClaude()
                    }
                    return
                }
            }
        }
    }

    // MARK: Opening MausBot

    /// The MausBot app when it's installed, else the workspace's own page in
    /// the user's browser.
    func openMausBot() {
        if let desktopAppURL = DottieMausBotLocator.desktopAppURL() {
            if ownedWorkspaceProcess != nil && activeClaudeTurnCount == 0 {
                // The app runs its own workspace on the same data.
                stopOwnedWorkspace()
            }
            if ownedWorkspaceProcess == nil {
                NSWorkspace.shared.openApplication(at: desktopAppURL, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        guard let workspacePageURL = URL(string: "http://127.0.0.1:8799") else { return }
        Task { _ = await DottieBrowser.openInUsersBrowser(workspacePageURL) }
    }

    // MARK: Status lines for Settings

    var mausBotStatusLine: String {
        guard hasLookedForMausBot else { return "Looking for MausBot…" }
        guard let launcher else { return "Not set up yet" }
        return "Ready, using \(launcher.displayName)"
    }

    var workspaceStatusLine: String {
        guard isSetUp else { return "Starts once MausBot is set up" }
        if isWorkspaceReachable {
            return isWorkspaceStartedByDottie ? "Running (Dottie started it)" : "Running"
        }
        return "Not running. It starts by itself when a helper needs it."
    }

    var claudeStatusLine: String {
        switch claudeState {
        case .unknown: return "Not checked yet"
        case .notInstalled: return "Claude Code isn't installed"
        case .notSignedIn: return "Not signed in"
        case .ready: return "Signed in, using your Claude plan"
        }
    }
}
