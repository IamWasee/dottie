//
//  DottieToolInstaller.swift
//  leanring-buddy
//
//  Installs any command-line tool the user asks for: "install ffmpeg",
//  "get me something to download YouTube videos", "install the Vercel CLI".
//
//  DottieToolResolver finds the real package. Dottie says in one line what
//  she'll install and from where, and installs only after a yes (by voice),
//  a tap on Install (Home → Tools) or the Install button of a dialog (when a
//  helper asks with an <INSTALL_TOOL> block). Installs run in the
//  background with Homebrew, npm (Dottie's own Node.js when there's no
//  other), uv or pipx, cargo, or the tool's official installer; progress
//  shows in the notch and the Tools tab.
//
//  Tools installed this way are remembered: Home → Tools lists them with an
//  Uninstall button, and helpers' instructions name them so Gemini CLI and
//  MausBot helpers know they can use them.
//

import AppKit
import Combine
import Foundation

/// A tool Dottie installed because someone asked for it.
struct DottieInstalledTool: Codable, Equatable, Identifiable {
    let package: DottieToolPackage
    /// The programs it added, in a sensible order.
    var commands: [String]
    /// Program name → full path, found right after installing.
    var commandPaths: [String: String]
    /// "uv" or "pipx" for PyPI tools, so uninstalling uses the same one.
    var installer: String?
    let installedAt: Date

    var id: String { package.id }

    /// One line for helpers: "yt-dlp (/opt/homebrew/bin/yt-dlp): Downloads…"
    var helperLine: String {
        let programs = commands.map { command in
            commandPaths[command].map { "\(command) (\($0))" } ?? command
        }
        let programText = programs.isEmpty ? package.title : programs.joined(separator: ", ")
        return package.summary.isEmpty ? programText : "\(programText): \(package.summary)"
    }
}

/// A thread-safe "please stop" switch for a running install.
final class DottieStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

@MainActor
final class DottieToolInstaller: ObservableObject {
    static let shared = DottieToolInstaller()

    /// An install in progress.
    struct Job: Identifiable, Equatable {
        let package: DottieToolPackage
        /// The latest line the installer printed (Tools tab).
        var progressText: String
        /// A word or two for the notch: "downloading", "installing".
        var shortProgress: String
        var id: String { package.id }
    }

    enum Outcome: Equatable {
        case installed(DottieInstalledTool)
        case failed(String)
        case stopped
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var installedTools: [DottieInstalledTool]
    @Published private(set) var removingToolIDs: Set<String> = []
    /// The latest plain-English problem or result, for the Tools tab.
    @Published var lastMessage: String?

    nonisolated static let savedToolsDefaultsKey = "dottieToolsInstalledByAsking"
    /// npm tools go here, so no password is ever needed.
    nonisolated static var npmPrefixPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global").path
    }

    nonisolated static let helperRequestOpeningTag = "<INSTALL_TOOL>"
    nonisolated static let helperRequestClosingTag = "</INSTALL_TOOL>"

    private var stopFlags: [String: DottieStopFlag] = [:]
    /// What Dottie offered by voice, waiting for the user's yes. Keyed by
    /// every name the model might use for it.
    private var pendingVoicePlans: [String: (plan: DottieToolPlan, foundAt: Date)] = [:]
    private var lastNotchRefreshAt = Date.distantPast

    init() {
        installedTools = Self.savedTools()
    }

    func isInstalling(_ package: DottieToolPackage) -> Bool {
        jobs.contains { $0.id == package.id }
    }

    func job(for package: DottieToolPackage) -> Job? {
        jobs.first { $0.id == package.id }
    }

    // MARK: - Installing

    /// Installs in the background, then shows a card in the notch.
    func installAndAnnounce(_ plan: DottieToolPlan) async -> Outcome {
        let outcome = await install(plan)
        announce(outcome, package: plan.package)
        return outcome
    }

    /// Installs what the plan needs first, then the tool. The caller has
    /// the user's OK already.
    func install(_ plan: DottieToolPlan) async -> Outcome {
        let package = plan.package
        guard !isInstalling(package) else { return .failed("\(package.title) is already installing.") }
        let stopFlag = DottieStopFlag()
        stopFlags[package.id] = stopFlag
        jobs.append(Job(package: package, progressText: "Starting…", shortProgress: "starting"))
        lastMessage = nil
        refreshNotch(force: true)
        defer {
            jobs.removeAll { $0.id == package.id }
            stopFlags[package.id] = nil
            refreshNotch(force: true)
        }

        if let prerequisite = plan.prerequisite,
           let problem = await installPrerequisite(prerequisite, for: package, stopFlag: stopFlag) {
            return stopFlag.isStopped ? .stopped : .failed(problem)
        }
        if stopFlag.isStopped { return .stopped }

        let commandOrProblem = installCommand(for: package)
        guard case .command(let command) = commandOrProblem else {
            if case .problem(let problem) = commandOrProblem { return .failed(problem) }
            return .failed("\(package.title) didn't install.")
        }
        updateJob(package.id, progressText: "Installing with \(package.source.displayName)…", shortProgress: "installing")
        let result = await runTracked(command, jobID: package.id, stopFlag: stopFlag)
        if stopFlag.isStopped { return .stopped }
        guard result.exitCode == 0 else {
            return .failed(plainProblem(from: result, package: package))
        }

        await DottieCommandLocator.refresh()
        let commands = await discoverCommands(for: package, installer: command.installerName)
        var commandPaths: [String: String] = [:]
        for commandName in commands {
            if let path = DottieCommandLocator.locate(commandName) { commandPaths[commandName] = path }
        }
        let installedTool = DottieInstalledTool(
            package: package,
            commands: commands,
            commandPaths: commandPaths,
            installer: command.installerName,
            installedAt: Date()
        )
        installedTools.removeAll { $0.id == installedTool.id }
        installedTools.insert(installedTool, at: 0)
        saveTools()
        await DottieCLIToolsManager.shared.refresh()
        return .installed(installedTool)
    }

    func stop(jobID: String) {
        stopFlags[jobID]?.stop()
        updateJob(jobID, progressText: "Stopping…", shortProgress: "stopping")
    }

    private func announce(_ outcome: Outcome, package: DottieToolPackage) {
        switch outcome {
        case .installed(let tool):
            let programs = tool.commands.isEmpty ? "" : " Type \(tool.commands.prefix(2).joined(separator: " or ")) in Terminal."
            lastMessage = "Installed \(package.title)."
            DottieEveryday.shared.tell(title: "Installed \(package.title)", text: "It's ready, and helpers can use it too.\(programs)")
        case .failed(let problem):
            lastMessage = problem
            DottieEveryday.shared.tell(title: "Couldn't install \(package.title)", text: problem)
        case .stopped:
            lastMessage = "Stopped installing \(package.title)."
            DottieEveryday.shared.tell(title: "Stopped", text: "Stopped installing \(package.title).")
        }
    }

    /// Gets Homebrew, Node.js, uv or Rust ready. Returns a problem or nil.
    private func installPrerequisite(_ prerequisite: DottieToolPrerequisite, for package: DottieToolPackage, stopFlag: DottieStopFlag) async -> String? {
        switch prerequisite {
        case .homebrew:
            guard !DottieCommandLocator.isInstalled("brew") else { return nil }
            updateJob(package.id, progressText: "Waiting for Homebrew. Type your Mac password in Terminal.", shortProgress: "waiting for Homebrew")
            DottieCLIToolsManager.shared.openHomebrewInstallerInTerminal()
            // Homebrew's installer runs in Terminal; carry on once it's there.
            let deadline = Date().addingTimeInterval(30 * 60)
            while !DottieCommandLocator.isInstalled("brew") {
                if stopFlag.isStopped { return "Stopped." }
                if Date() > deadline { return "Homebrew didn't finish installing, so \(package.title) wasn't installed. Ask again once it's done." }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            await DottieCommandLocator.refresh()
            await DottieCLIToolsManager.shared.refresh()
            return nil
        case .node:
            updateJob(package.id, progressText: "Getting Node.js ready (about 70 MB, once)…", shortProgress: "getting Node.js")
            do {
                try await DotsRuntimeInstaller.shared.installIfNeeded()
                return nil
            } catch {
                return "Dottie couldn't get Node.js ready, so \(package.title) wasn't installed. Check the internet connection and try again."
            }
        case .uv:
            updateJob(package.id, progressText: "Installing uv first…", shortProgress: "getting uv")
            if let problem = await DottieCLIToolsManager.shared.installUV() {
                return "\(problem) So \(package.title) wasn't installed."
            }
            return nil
        case .rust:
            guard !DottieCommandLocator.isInstalled("cargo"), let script = DottieToolResolver.rustupPackage.scriptInstallCommand else { return nil }
            updateJob(package.id, progressText: "Installing Rust first (a few minutes)…", shortProgress: "getting Rust")
            let command = InstallCommand(executablePath: "/bin/bash", arguments: ["-c", script], environment: Self.toolEnvironment, timeout: 1200, installerName: nil)
            let result = await runTracked(command, jobID: package.id, stopFlag: stopFlag)
            await DottieCommandLocator.refresh()
            guard result.exitCode == 0, DottieCommandLocator.isInstalled("cargo") else {
                return "Rust didn't install, so \(package.title) wasn't installed. " + DottieMCPStdioTransport.lastMeaningfulLine(of: result.errorOutput.isEmpty ? result.output : result.errorOutput)
            }
            return nil
        }
    }

    // MARK: - Commands

    private struct InstallCommand {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval
        let installerName: String?
    }

    private enum CommandOrProblem {
        case command(InstallCommand)
        case problem(String)
    }

    /// PATH with every install folder, for npm, uv, cargo and scripts.
    private static var toolEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = DottieCommandLocator.searchPATH
        environment["NO_COLOR"] = "1"
        environment["npm_config_fund"] = "false"
        environment["npm_config_audit"] = "false"
        environment["npm_config_update_notifier"] = "false"
        return environment
    }

    /// Dottie's own npm when there's no other.
    private static var npmPath: String? {
        if let npmPath = DottieCommandLocator.locate("npm") { return npmPath }
        let bundledNPMPath = DotsRuntimeInstaller.nodeBinFolderURL.appendingPathComponent("npm").path
        return FileManager.default.isExecutableFile(atPath: bundledNPMPath) ? bundledNPMPath : nil
    }

    private func installCommand(for package: DottieToolPackage) -> CommandOrProblem {
        switch package.source {
        case .homebrew, .homebrewCask:
            guard let brewPath = DottieCommandLocator.locate("brew") else {
                return .problem("Homebrew isn't installed yet, so \(package.title) wasn't installed.")
            }
            let arguments = ["install"] + (package.source == .homebrewCask ? ["--cask"] : []) + [package.packageName]
            return .command(InstallCommand(executablePath: brewPath, arguments: arguments, environment: DottieProcessRunner.homebrewEnvironment, timeout: 1800, installerName: nil))
        case .npm:
            guard let npmPath = Self.npmPath else {
                return .problem("Node.js isn't ready, so \(package.title) wasn't installed.")
            }
            let arguments = ["install", "-g", "--prefix", Self.npmPrefixPath, package.packageName]
            return .command(InstallCommand(executablePath: npmPath, arguments: arguments, environment: Self.toolEnvironment, timeout: 900, installerName: nil))
        case .pypi:
            if let uvPath = DottieCommandLocator.locate("uv") {
                return .command(InstallCommand(executablePath: uvPath, arguments: ["tool", "install", package.packageName], environment: Self.toolEnvironment, timeout: 1200, installerName: "uv"))
            }
            if let pipxPath = DottieCommandLocator.locate("pipx") {
                return .command(InstallCommand(executablePath: pipxPath, arguments: ["install", package.packageName], environment: Self.toolEnvironment, timeout: 1200, installerName: "pipx"))
            }
            return .problem("\(package.title) needs uv to install, and uv isn't on this Mac.")
        case .cargo:
            guard let cargoPath = DottieCommandLocator.locate("cargo") else {
                return .problem("\(package.title) needs Rust to install, and Rust isn't on this Mac.")
            }
            return .command(InstallCommand(executablePath: cargoPath, arguments: ["install", package.packageName], environment: Self.toolEnvironment, timeout: 3600, installerName: nil))
        case .script:
            guard let script = package.scriptInstallCommand else { return .problem("Dottie doesn't know how to install \(package.title).") }
            return .command(InstallCommand(executablePath: "/bin/bash", arguments: ["-c", script], environment: Self.toolEnvironment, timeout: 1200, installerName: nil))
        }
    }

    /// Runs a command, showing its output on the job as it goes.
    private func runTracked(_ command: InstallCommand, jobID: String, stopFlag: DottieStopFlag) async -> DottieProcessRunner.Result {
        await DottieProcessRunner.run(
            command.executablePath,
            arguments: command.arguments,
            environment: command.environment,
            timeout: command.timeout,
            shouldStop: { stopFlag.isStopped }
        ) { [weak self] line in
            Task { @MainActor in
                self?.updateJob(jobID, progressText: String(line.prefix(90)), shortProgress: Self.shortProgress(for: line))
            }
        }
    }

    /// A friendly word for an installer's output line, or nil to keep the
    /// last one.
    private nonisolated static func shortProgress(for line: String) -> String? {
        let lowercasedLine = line.lowercased()
        if lowercasedLine.contains("download") || lowercasedLine.contains("fetching") { return "downloading" }
        if lowercasedLine.contains("compiling") { return "building" }
        if lowercasedLine.contains("pouring") || lowercasedLine.contains("installing") || lowercasedLine.contains("added ") || lowercasedLine.contains("linking") {
            return "installing"
        }
        return nil
    }

    private func updateJob(_ jobID: String, progressText: String, shortProgress: String?) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[jobIndex].progressText = progressText
        if let shortProgress, jobs[jobIndex].shortProgress != shortProgress {
            jobs[jobIndex].shortProgress = shortProgress
            refreshNotch(force: false)
        }
    }

    /// The programs a package added, asked of its installer where it knows.
    private func discoverCommands(for package: DottieToolPackage, installer: String?) async -> [String] {
        var discovered: [String] = []
        switch package.source {
        case .homebrew:
            if let brewPath = DottieCommandLocator.locate("brew") {
                let result = await DottieProcessRunner.run(brewPath, arguments: ["list", "--formula", package.packageName], environment: DottieProcessRunner.homebrewEnvironment, timeout: 30)
                for line in result.output.components(separatedBy: .newlines) where line.contains("/bin/") {
                    let name = (line.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
                    if !name.isEmpty && !discovered.contains(name) { discovered.append(name) }
                }
            }
        case .homebrewCask:
            if let brewPath = DottieCommandLocator.locate("brew") {
                let result = await DottieProcessRunner.run(brewPath, arguments: ["info", "--json=v2", "--cask", package.packageName], environment: DottieProcessRunner.homebrewEnvironment, timeout: 30)
                if let data = result.output.data(using: .utf8),
                   let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let cask = (info["casks"] as? [[String: Any]])?.first {
                    discovered = DottieToolResolver.caskBinaries(cask)
                }
            }
        case .pypi where installer == "uv":
            if let uvPath = DottieCommandLocator.locate("uv") {
                let result = await DottieProcessRunner.run(uvPath, arguments: ["tool", "list"], environment: Self.toolEnvironment, timeout: 30)
                discovered = Self.programs(inListing: result.output, forPackage: package.packageName, programPrefix: "- ")
            }
        case .cargo:
            if let cargoPath = DottieCommandLocator.locate("cargo") {
                let result = await DottieProcessRunner.run(cargoPath, arguments: ["install", "--list"], environment: Self.toolEnvironment, timeout: 30)
                discovered = Self.programs(inListing: result.output, forPackage: package.packageName, programPrefix: "")
            }
        default:
            break
        }
        // A program named like the package goes first.
        let shortName = (package.packageName as NSString).lastPathComponent
        discovered = discovered.filter { $0 == shortName } + discovered.filter { $0 != shortName }
        return discovered.isEmpty ? package.commands : discovered
    }

    /// Reads `uv tool list` / `cargo install --list`: a package line, then
    /// indented program lines.
    private nonisolated static func programs(inListing listing: String, forPackage packageName: String, programPrefix: String) -> [String] {
        let normalizedPackage = packageName.lowercased().replacingOccurrences(of: "_", with: "-")
        var programs: [String] = []
        var isInsidePackage = false
        for line in listing.components(separatedBy: .newlines) {
            let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t") || (!programPrefix.isEmpty && line.hasPrefix(programPrefix))
            if !isIndented {
                let firstWord = line.split(separator: " ").first.map(String.init)?.lowercased().replacingOccurrences(of: "_", with: "-") ?? ""
                isInsidePackage = firstWord == normalizedPackage
                continue
            }
            guard isInsidePackage else { continue }
            var program = line.trimmingCharacters(in: .whitespaces)
            if !programPrefix.isEmpty, program.hasPrefix(programPrefix) { program = String(program.dropFirst(programPrefix.count)) }
            program = program.split(separator: " ").first.map(String.init) ?? program
            if !program.isEmpty { programs.append(program) }
        }
        return programs
    }

    /// The installer's error in plain words.
    private func plainProblem(from result: DottieProcessRunner.Result, package: DottieToolPackage) -> String {
        let output = result.errorOutput.isEmpty ? result.output : result.errorOutput
        let lowercasedOutput = output.lowercased()
        let reason: String
        if result.exitCode == -1 {
            reason = "The installer couldn't start."
        } else if lowercasedOutput.contains("sudo") || lowercasedOutput.contains("password") {
            reason = "It needs your Mac password. To install it yourself, run this in Terminal: \(package.installCommandText)"
        } else if lowercasedOutput.contains("no available formula") || lowercasedOutput.contains("no cask with this name") || lowercasedOutput.contains("404") {
            reason = "\(package.source.displayName) doesn't have a package called \(package.packageName)."
        } else if lowercasedOutput.contains("could not resolve host") || lowercasedOutput.contains("network") || lowercasedOutput.contains("timed out") {
            reason = "The download failed. Check the internet connection and try again."
        } else if lowercasedOutput.contains("xcode") || lowercasedOutput.contains("command line tools") {
            reason = "It needs Apple's Command Line Tools. Run xcode-select --install in Terminal first."
        } else {
            let lastLine = DottieMCPStdioTransport.lastMeaningfulLine(of: output)
            reason = lastLine.isEmpty ? "The installer stopped with an error." : lastLine
        }
        return "\(package.title) didn't install. \(reason)"
    }

    // MARK: - Uninstalling

    /// Removes a tool Dottie installed. Returns a plain-English result.
    func uninstall(_ tool: DottieInstalledTool) async -> String {
        guard !removingToolIDs.contains(tool.id) else { return "Already removing \(tool.package.title)." }
        removingToolIDs.insert(tool.id)
        defer { removingToolIDs.remove(tool.id) }

        let package = tool.package
        var executablePath: String?
        var arguments: [String] = []
        var environment = Self.toolEnvironment
        switch package.source {
        case .homebrew, .homebrewCask:
            executablePath = DottieCommandLocator.locate("brew")
            arguments = ["uninstall"] + (package.source == .homebrewCask ? ["--cask"] : []) + [package.packageName]
            environment = DottieProcessRunner.homebrewEnvironment
        case .npm:
            executablePath = Self.npmPath
            arguments = ["uninstall", "-g", "--prefix", Self.npmPrefixPath, package.packageName]
        case .pypi:
            let installerName = tool.installer ?? "uv"
            executablePath = DottieCommandLocator.locate(installerName)
            arguments = installerName == "pipx" ? ["uninstall", package.packageName] : ["tool", "uninstall", package.packageName]
        case .cargo:
            executablePath = DottieCommandLocator.locate("cargo")
            arguments = ["uninstall", package.packageName]
        case .script:
            if let uninstallCommand = package.scriptUninstallCommand {
                executablePath = "/bin/bash"
                arguments = ["-c", uninstallCommand]
            }
        }

        var message: String
        if let executablePath {
            let result = await DottieProcessRunner.run(executablePath, arguments: arguments, environment: environment, timeout: 600)
            await DottieCommandLocator.refresh()
            let isGone = tool.commands.allSatisfy { !DottieCommandLocator.isInstalled($0) }
            if result.exitCode == 0 || isGone {
                message = "Removed \(package.title)."
                forget(tool)
            } else {
                let reason = DottieMCPStdioTransport.lastMeaningfulLine(of: result.errorOutput.isEmpty ? result.output : result.errorOutput)
                message = "\(package.title) didn't uninstall. \(reason)"
            }
        } else {
            message = "Dottie can't find what installed \(package.title), so she took it off the list. It may still be on the Mac."
            forget(tool)
        }
        lastMessage = message
        await DottieCLIToolsManager.shared.refresh()
        return message
    }

    private func forget(_ tool: DottieInstalledTool) {
        installedTools.removeAll { $0.id == tool.id }
        saveTools()
    }

    // MARK: - Saving

    private func saveTools() {
        guard let data = try? JSONEncoder().encode(installedTools) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedToolsDefaultsKey)
    }

    nonisolated static func savedTools() -> [DottieInstalledTool] {
        guard let data = UserDefaults.standard.data(forKey: savedToolsDefaultsKey),
              let tools = try? JSONDecoder().decode([DottieInstalledTool].self, from: data) else { return [] }
        return tools
    }

    // MARK: - Notch

    /// Installs in progress, for the notch's hover peek.
    var statusLines: [NotchStatusLine] {
        jobs.map { job in
            NotchStatusLine(id: "install:\(job.id)", symbolName: "arrow.down.circle.fill", text: "installing \(job.package.title): \(job.shortProgress)")
        }
    }

    private func refreshNotch(force: Bool) {
        guard force || Date().timeIntervalSince(lastNotchRefreshAt) > 1 else { return }
        lastNotchRefreshAt = Date()
        DottieEveryday.shared.refreshStatusLines()
    }

    // MARK: - Helpers' instructions

    /// What helpers are told: the tools Dottie installed for the user.
    nonisolated static var helperToolLines: String {
        savedTools().map { "- " + $0.helperLine }.joined(separator: "\n")
    }

    nonisolated static var helperInstallPolicy: String {
        """
        Don't install software yourself (no brew install, npm install -g, pip, pipx or uv tool install, cargo install, or curl | sh installers). Installing project dependencies inside your own folder is fine. If a task needs a command-line tool this Mac doesn't have, finish what you can, then end your reply with one block naming the tool and why, like this:

        \(helperRequestOpeningTag)ffmpeg: to turn the recording into an mp4\(helperRequestClosingTag)

        Dottie asks the user and installs it, then sends you a message so you can carry on.
        """
    }

    // MARK: - Helper requests

    /// Splits a helper's reply into the reply without its <INSTALL_TOOL>
    /// block and what the block asks for.
    nonisolated static func extractInstallRequest(from replyText: String) -> (reply: String, request: String?) {
        guard let openingRange = replyText.range(of: helperRequestOpeningTag),
              let closingRange = replyText.range(of: helperRequestClosingTag, range: openingRange.upperBound..<replyText.endIndex) else {
            return (replyText, nil)
        }
        let request = String(replyText[openingRange.upperBound..<closingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        var reply = replyText
        reply.removeSubrange(openingRange.lowerBound..<closingRange.upperBound)
        reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return (reply, request.isEmpty ? nil : request)
    }

    /// A helper asked for a tool. Finds it, asks the user in a dialog, and
    /// installs it on a yes. `reply` sends the helper the outcome.
    func handleHelperRequest(_ requestText: String, helperName: String, reply: @escaping @MainActor (String) -> Void) {
        let (toolName, reason) = Self.splitRequest(requestText)
        Task { @MainActor in
            let resolution = await DottieToolResolver.resolve(toolName)
            guard case .found(let plan) = resolution else {
                reply("Dottie couldn't find a command-line tool called \(toolName) on Homebrew, npm, PyPI or crates.io. Finish without it, or ask again with its exact package name.")
                return
            }
            let package = plan.package
            if let existingPath = plan.existingPath {
                reply("\(package.title) is already installed (\(existingPath)). Carry on with the task.")
                return
            }
            let reasonText = reason.isEmpty ? "" : ": \(reason)"
            let isAllowed = DottieConfirmation.ask(
                title: "Install \(package.title)?",
                detail: "Your helper \(helperName) asked for it\(reasonText).\n\n\(plan.oneLine)\n\nDottie will run: \(package.installCommandText)",
                confirmButtonTitle: "Install"
            )
            guard isAllowed else {
                reply("The user said no to installing \(package.title). Finish what you can without it.")
                return
            }
            switch await installAndAnnounce(plan) {
            case .installed(let tool):
                reply("\(package.title) is installed now: \(tool.helperLine). Carry on with the task.")
            case .failed(let problem):
                reply("\(problem) Finish what you can without it.")
            case .stopped:
                reply("The user stopped installing \(package.title). Finish what you can without it.")
            }
        }
    }

    /// "ffmpeg: to convert the video" → ("ffmpeg", "to convert the video").
    private nonisolated static func splitRequest(_ requestText: String) -> (name: String, reason: String) {
        for separator in [":", " — ", " - ", " (", " because "] {
            if let separatorRange = requestText.range(of: separator) {
                let name = requestText[..<separatorRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = requestText[separatorRange.upperBound...].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ")")))
                if !name.isEmpty { return (name, reason) }
            }
        }
        return (requestText.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    // MARK: - Voice

    /// Looks a tool up and tells the model what to ask the user.
    func voiceFind(name: String, source: DottieToolSource?) async -> String {
        let resolution = await DottieToolResolver.resolve(name, preferredSource: source)
        switch resolution {
        case .notFound(let request, let suggestions):
            var answer = "couldn't find a command-line tool called \(request)" + (source.map { " on \($0.displayName)" } ?? " on Homebrew, npm, PyPI or crates.io") + "."
            if !suggestions.isEmpty {
                answer += " close Homebrew names: \(suggestions.joined(separator: ", "))."
            }
            answer += " if that was a description, pick the well-known tool for it and call find again with its real name; otherwise ask the user for the exact name."
            return answer
        case .found(let plan):
            if let existingPath = plan.existingPath {
                return "\(plan.package.title) is already on this Mac (\(existingPath)). tell the user; nothing to install."
            }
            rememberVoicePlan(plan, request: name)
            return askLine(for: plan)
        }
    }

    /// Installs a tool the user said yes to. Without a recent find (or
    /// without `confirmed`), returns what to ask instead.
    func voiceInstall(name: String, source: DottieToolSource?, confirmed: Bool) async -> String {
        guard let pending = pendingVoicePlan(named: name),
              source == nil || pending.plan.package.source.argumentName == source?.argumentName else {
            return await voiceFind(name: name, source: source)
        }
        guard confirmed else { return askLine(for: pending.plan) }
        // A yes can't come back this fast; the model skipped asking.
        guard Date().timeIntervalSince(pending.foundAt) > 2 else {
            return "ask the user first, in one line, and wait for their yes. then call install again."
        }
        let plan = pending.plan
        pendingVoicePlans = [:]
        if isInstalling(plan.package) {
            return "\(plan.package.title) is already installing; the notch shows how it's going."
        }
        Task { @MainActor in
            _ = await self.installAndAnnounce(plan)
        }
        if plan.prerequisite == .homebrew {
            return "opened Terminal to install Homebrew first. tell the user to type their Mac password there (nothing shows while typing); \(plan.package.title) installs by itself once Homebrew is ready."
        }
        return "installing \(plan.package.title) from \(plan.package.source.displayName) in the background now. tell the user in a few words; the notch shows progress and a card when it's ready."
    }

    func voiceUninstall(name: String, confirmed: Bool) async -> String {
        let cleanedName = DottieToolResolver.cleaned(name)
        guard let tool = installedTools.first(where: { tool in
            tool.package.packageName.lowercased() == cleanedName
                || tool.package.title.lowercased() == cleanedName
                || tool.commands.contains(cleanedName)
        }) else {
            let names = installedTools.map(\.package.title)
            let installedText = names.isEmpty ? "she hasn't installed any yet" : "she installed: \(names.joined(separator: ", "))"
            return "Dottie only removes tools she installed; \(installedText). tell the user."
        }
        guard confirmed else {
            return "ask the user in one line if they want \(tool.package.title) removed, then call uninstall again with confirmed true."
        }
        return await uninstall(tool).lowercased()
    }

    func voiceList() -> String {
        let askedFor = installedTools.map { "\($0.package.title) (\($0.commands.joined(separator: ", ")))" }
        let catalogInstalled = DottieCLICatalog.all.filter { DottieCLIToolsManager.shared.isInstalled($0) }.map(\.title)
        var answer = askedFor.isEmpty ? "Dottie hasn't installed any tools by request yet." : "installed by asking: \(askedFor.joined(separator: ", "))."
        if !catalogInstalled.isEmpty {
            answer += " also on this Mac: \(catalogInstalled.joined(separator: ", "))."
        }
        if !jobs.isEmpty {
            answer += " installing now: \(jobs.map(\.package.title).joined(separator: ", "))."
        }
        return answer
    }

    private func askLine(for plan: DottieToolPlan) -> String {
        let package = plan.package
        let prerequisiteText = plan.prerequisite.map { " (it needs \($0.spokenDescription))" } ?? ""
        var answer = "found \(plan.oneLine). tell the user in one line what you'll install and from where, like \"I'll install \(package.title) from \(package.source.displayName)\(prerequisiteText), okay?\", and wait for a yes. on a yes, call install_tool with action install, name \"\(package.packageName)\" and confirmed true."
        if !plan.alsoFoundOn.isEmpty {
            let otherPlaces = plan.alsoFoundOn.map(\.argumentName).joined(separator: ", ")
            answer += " a package with that name is also on \(otherPlaces); if the user meant one of those, call find with that source."
        }
        return answer
    }

    private func rememberVoicePlan(_ plan: DottieToolPlan, request: String) {
        let entry = (plan: plan, foundAt: Date())
        for key in [DottieToolResolver.cleaned(request), plan.package.packageName.lowercased(), plan.package.title.lowercased()] + plan.package.commands {
            pendingVoicePlans[key] = entry
        }
    }

    private func pendingVoicePlan(named name: String) -> (plan: DottieToolPlan, foundAt: Date)? {
        guard let pending = pendingVoicePlans[DottieToolResolver.cleaned(name)] ?? pendingVoicePlans[name.lowercased()],
              Date().timeIntervalSince(pending.foundAt) < 15 * 60 else { return nil }
        return pending
    }
}

// MARK: - Tool

/// One voice tool for finding, installing, removing and listing
/// command-line tools.
@MainActor
enum DottieToolInstallTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "install_tool",
                description: "Finds, installs, removes or lists command-line tools on the Mac (from Homebrew, npm, PyPI or crates.io). Use it for asks like \"install ffmpeg\" or \"get me something to download youtube videos\". Always find first, tell the user in one line what you'll install and from where, and install only after they say yes. It installs in the background; the notch shows progress.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": [
                            "type": "STRING",
                            "enum": ["find", "install", "uninstall", "list"],
                            "description": "find looks it up; install runs after the user's yes; uninstall removes one Dottie installed; list says what's installed."
                        ],
                        "name": [
                            "type": "STRING",
                            "description": "The tool's real name, like ffmpeg, yt-dlp or vercel. For a vague ask (\"something to download YouTube videos\"), pick the well-known tool yourself (yt-dlp) and tell the user which."
                        ],
                        "source": [
                            "type": "STRING",
                            "enum": ["homebrew", "npm", "pypi", "cargo"],
                            "description": "Only when the user named where to get it, or find said it's also there."
                        ],
                        "confirmed": [
                            "type": "BOOLEAN",
                            "description": "install and uninstall: true only once the user said yes."
                        ]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice],
                run: { arguments in
                    await handle(arguments)
                }
            )
        ]
    }

    private static func handle(_ arguments: [String: Any]) async -> String {
        let installer = DottieToolInstaller.shared
        let action = arguments.dottieString("action")?.lowercased() ?? "find"
        let source = DottieToolSource.fromArgument(arguments.dottieString("source"))
        let confirmed = arguments.dottieBool("confirmed") ?? false
        if action == "list" {
            return installer.voiceList()
        }
        guard let name = arguments.dottieString("name") else {
            return "say which tool."
        }
        switch action {
        case "install":
            return await installer.voiceInstall(name: name, source: source, confirmed: confirmed)
        case "uninstall", "remove":
            return await installer.voiceUninstall(name: name, confirmed: confirmed)
        default:
            return await installer.voiceFind(name: name, source: source)
        }
    }
}
