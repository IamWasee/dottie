//
//  DottieCLITools.swift
//  leanring-buddy
//
//  Command-line tools for Home → Tools: a catalog of handy ones, which are
//  already on this Mac, and one-tap installs with Homebrew in the
//  background. Helpers (Dots) are told which ones they can use.
//
//  Without Homebrew, Dottie offers to open Terminal with Homebrew's own
//  install command, since it needs the user's password.
//

import AppKit
import Combine
import Foundation

struct DottieCLITool: Identifiable, Equatable {
    let id: String
    /// What the user sees.
    let title: String
    let summary: String
    /// The program to look for.
    let command: String
    /// The Homebrew formula or cask.
    let brewName: String
    var isCask = false
}

enum DottieCLICatalog {
    static let all: [DottieCLITool] = [
        // Files and text
        DottieCLITool(id: "ripgrep", title: "ripgrep", summary: "Searches inside files very fast.", command: "rg", brewName: "ripgrep"),
        DottieCLITool(id: "fd", title: "fd", summary: "Finds files by name, fast.", command: "fd", brewName: "fd"),
        DottieCLITool(id: "fzf", title: "fzf", summary: "Picks from long lists by typing a few letters.", command: "fzf", brewName: "fzf"),
        DottieCLITool(id: "bat", title: "bat", summary: "Shows files with colors and line numbers.", command: "bat", brewName: "bat"),
        DottieCLITool(id: "tree", title: "tree", summary: "Shows a folder and everything in it as a tree.", command: "tree", brewName: "tree"),
        DottieCLITool(id: "jq", title: "jq", summary: "Reads and reshapes JSON data.", command: "jq", brewName: "jq"),
        DottieCLITool(id: "yq", title: "yq", summary: "Reads and reshapes YAML, XML and CSV.", command: "yq", brewName: "yq"),
        DottieCLITool(id: "trash", title: "trash", summary: "Moves files to the Trash instead of deleting them.", command: "trash", brewName: "trash"),
        DottieCLITool(id: "tag", title: "tag", summary: "Adds and reads Finder tags on files.", command: "tag", brewName: "tag"),
        DottieCLITool(id: "glow", title: "glow", summary: "Shows Markdown nicely in Terminal.", command: "glow", brewName: "glow"),
        DottieCLITool(id: "gum", title: "gum", summary: "Makes friendly prompts for shell scripts.", command: "gum", brewName: "gum"),
        DottieCLITool(id: "tldr", title: "tldr", summary: "Short, plain examples for any command.", command: "tldr", brewName: "tlrc"),

        // Web and downloads
        DottieCLITool(id: "curl", title: "curl", summary: "Downloads and talks to websites.", command: "curl", brewName: "curl"),
        DottieCLITool(id: "wget", title: "wget", summary: "Downloads files and whole sites.", command: "wget", brewName: "wget"),
        DottieCLITool(id: "httpie", title: "HTTPie", summary: "Friendly way to call web APIs.", command: "http", brewName: "httpie"),
        DottieCLITool(id: "yt-dlp", title: "yt-dlp", summary: "Downloads videos and audio from YouTube and more.", command: "yt-dlp", brewName: "yt-dlp"),
        DottieCLITool(id: "rclone", title: "rclone", summary: "Copies files to and from cloud storage.", command: "rclone", brewName: "rclone"),
        DottieCLITool(id: "speedtest-cli", title: "speedtest-cli", summary: "Tests your internet speed.", command: "speedtest-cli", brewName: "speedtest-cli"),

        // Pictures, sound, video and documents
        DottieCLITool(id: "ffmpeg", title: "FFmpeg", summary: "Converts, trims and joins video and audio.", command: "ffmpeg", brewName: "ffmpeg"),
        DottieCLITool(id: "imagemagick", title: "ImageMagick", summary: "Resizes, converts and edits pictures.", command: "magick", brewName: "imagemagick"),
        DottieCLITool(id: "sox", title: "SoX", summary: "Edits and converts sound files.", command: "sox", brewName: "sox"),
        DottieCLITool(id: "exiftool", title: "ExifTool", summary: "Reads and changes photo and file details.", command: "exiftool", brewName: "exiftool"),
        DottieCLITool(id: "tesseract", title: "Tesseract", summary: "Reads the text in pictures and scans.", command: "tesseract", brewName: "tesseract"),
        DottieCLITool(id: "pandoc", title: "Pandoc", summary: "Converts documents: Word, Markdown, PDF, web pages.", command: "pandoc", brewName: "pandoc"),
        DottieCLITool(id: "poppler", title: "Poppler", summary: "Pulls text and pictures out of PDFs (pdftotext).", command: "pdftotext", brewName: "poppler"),
        DottieCLITool(id: "qpdf", title: "qpdf", summary: "Merges, splits and unlocks PDFs.", command: "qpdf", brewName: "qpdf"),
        DottieCLITool(id: "ghostscript", title: "Ghostscript", summary: "Shrinks and converts PDFs.", command: "gs", brewName: "ghostscript"),

        // Data
        DottieCLITool(id: "sqlite", title: "SQLite", summary: "Opens and queries database files.", command: "sqlite3", brewName: "sqlite"),
        DottieCLITool(id: "duckdb", title: "DuckDB", summary: "Asks questions of spreadsheets and data files with SQL.", command: "duckdb", brewName: "duckdb"),

        // Code and AI
        DottieCLITool(id: "git", title: "Git", summary: "Keeps the history of code and documents.", command: "git", brewName: "git"),
        DottieCLITool(id: "gh", title: "GitHub CLI", summary: "Works with GitHub from Terminal.", command: "gh", brewName: "gh"),
        DottieCLITool(id: "node", title: "Node.js", summary: "Runs JavaScript programs and npx tools.", command: "node", brewName: "node"),
        DottieCLITool(id: "python", title: "Python 3", summary: "Runs Python programs.", command: "python3", brewName: "python"),
        DottieCLITool(id: "uv", title: "uv", summary: "Installs and runs Python tools fast (uvx).", command: "uv", brewName: "uv"),
        DottieCLITool(id: "deno", title: "Deno", summary: "Runs JavaScript and TypeScript safely.", command: "deno", brewName: "deno"),
        DottieCLITool(id: "bun", title: "Bun", summary: "Fast JavaScript runtime and package manager.", command: "bun", brewName: "bun"),
        DottieCLITool(id: "gemini-cli", title: "Gemini CLI", summary: "Google's AI helper for Terminal.", command: "gemini", brewName: "gemini-cli"),
        DottieCLITool(id: "claude-code", title: "Claude Code", summary: "Anthropic's AI coding helper for Terminal.", command: "claude", brewName: "claude-code", isCask: true),
        DottieCLITool(id: "codex", title: "Codex", summary: "OpenAI's AI coding helper for Terminal.", command: "codex", brewName: "codex", isCask: true),
        DottieCLITool(id: "ollama", title: "Ollama", summary: "Runs AI models on this Mac, offline.", command: "ollama", brewName: "ollama"),

        // The Mac itself
        DottieCLITool(id: "mas", title: "mas", summary: "Installs and updates Mac App Store apps.", command: "mas", brewName: "mas"),
        DottieCLITool(id: "blueutil", title: "blueutil", summary: "Turns Bluetooth on and off, connects devices.", command: "blueutil", brewName: "blueutil"),
        DottieCLITool(id: "switchaudio-osx", title: "SwitchAudioSource", summary: "Switches speakers, headphones and microphones.", command: "SwitchAudioSource", brewName: "switchaudio-osx"),
        DottieCLITool(id: "brightness", title: "brightness", summary: "Sets the screen brightness.", command: "brightness", brewName: "brightness"),
        DottieCLITool(id: "terminal-notifier", title: "terminal-notifier", summary: "Shows Mac notifications from scripts.", command: "terminal-notifier", brewName: "terminal-notifier"),
        DottieCLITool(id: "duti", title: "duti", summary: "Sets which app opens which kind of file.", command: "duti", brewName: "duti"),
        DottieCLITool(id: "htop", title: "htop", summary: "Shows what's using the Mac's power and memory.", command: "htop", brewName: "htop"),
        DottieCLITool(id: "btop", title: "btop", summary: "A colorful view of the Mac's CPU, memory and network.", command: "btop", brewName: "btop")
    ]

    static func tool(withID toolID: String) -> DottieCLITool? {
        all.first { $0.id == toolID }
    }
}

// MARK: - Installed tools and installing

@MainActor
final class DottieCLIToolsManager: ObservableObject {
    static let shared = DottieCLIToolsManager()

    /// IDs of catalog tools found on this Mac. Saved so helpers' instructions
    /// can list them right after launch.
    @Published private(set) var installedToolIDs: Set<String>
    /// Tool ID → the latest line of Homebrew's output while installing.
    @Published private(set) var installProgress: [String: String] = [:]
    @Published private(set) var lastProblem: String?
    @Published private(set) var isHomebrewInstalled = false
    @Published private(set) var isRefreshing = false

    nonisolated static let installedDefaultsKey = "dottieInstalledCLITools"

    init() {
        installedToolIDs = Set(UserDefaults.standard.stringArray(forKey: Self.installedDefaultsKey) ?? [])
        isHomebrewInstalled = DottieCommandLocator.locate("brew") != nil
    }

    /// Looks for every catalog tool (off the main thread).
    func refresh() async {
        isRefreshing = true
        await DottieCommandLocator.warmUp()
        let foundIDs: Set<String> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let found = DottieCLICatalog.all.filter { DottieCommandLocator.isInstalled($0.command) }.map(\.id)
                continuation.resume(returning: Set(found))
            }
        }
        installedToolIDs = foundIDs
        isHomebrewInstalled = DottieCommandLocator.locate("brew") != nil
        UserDefaults.standard.set(Array(foundIDs).sorted(), forKey: Self.installedDefaultsKey)
        isRefreshing = false
    }

    func isInstalled(_ tool: DottieCLITool) -> Bool {
        installedToolIDs.contains(tool.id)
    }

    /// Installs a tool with Homebrew in the background. Returns when done.
    func install(_ tool: DottieCLITool) async {
        guard installProgress[tool.id] == nil else { return }
        guard let brewPath = DottieCommandLocator.locate("brew") else {
            lastProblem = "Homebrew isn't installed yet."
            return
        }
        lastProblem = nil
        installProgress[tool.id] = "Starting…"
        let arguments = ["install"] + (tool.isCask ? ["--cask"] : []) + [tool.brewName]
        let result = await DottieProcessRunner.run(
            brewPath,
            arguments: arguments,
            environment: DottieProcessRunner.homebrewEnvironment,
            timeout: 1800
        ) { [weak self] line in
            Task { @MainActor in
                guard let self, self.installProgress[tool.id] != nil else { return }
                self.installProgress[tool.id] = String(line.prefix(80))
            }
        }
        installProgress[tool.id] = nil
        if result.exitCode != 0 {
            let reason = DottieMCPStdioTransport.lastMeaningfulLine(of: result.errorOutput.isEmpty ? result.output : result.errorOutput)
            lastProblem = "\(tool.title) didn't install. \(reason)"
        }
        await DottieCommandLocator.refresh()
        await refresh()
    }

    /// Installs uv (for uvx servers): with Homebrew when it's there,
    /// otherwise with uv's own installer, which needs no password.
    func installUV() async -> String? {
        if let uvTool = DottieCLICatalog.tool(withID: "uv"), DottieCommandLocator.locate("brew") != nil {
            await install(uvTool)
            return DottieCommandLocator.isInstalled("uvx") ? nil : (lastProblem ?? "uv didn't install.")
        }
        installProgress["uv"] = "Installing uv…"
        var environment = ProcessInfo.processInfo.environment
        environment["UV_NO_MODIFY_PATH"] = "1"
        let result = await DottieProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
            environment: environment,
            timeout: 600
        ) { _ in }
        installProgress["uv"] = nil
        await DottieCommandLocator.refresh()
        await refresh()
        if result.exitCode != 0 || !DottieCommandLocator.isInstalled("uvx") {
            return "uv didn't install. " + DottieMCPStdioTransport.lastMeaningfulLine(of: result.errorOutput)
        }
        return nil
    }

    /// Opens Terminal with Homebrew's official install command. Homebrew
    /// asks for the Mac's password there.
    func openHomebrewInstallerInTerminal() {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("Install Homebrew.command")
        let script = """
        #!/bin/bash
        echo "Installing Homebrew. Type your Mac password when asked (nothing shows as you type)."
        echo
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        echo
        echo "All done. You can close this window and go back to Dottie."

        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)
        } catch {
            lastProblem = "Dottie couldn't open Terminal. Visit brew.sh to install Homebrew."
        }
    }

    // MARK: For helpers

    /// The handy tools on this Mac, the ones Dottie installed on request,
    /// and how to ask for more, for helpers.
    nonisolated static var helperInstructions: String {
        let installedIDs = Set(UserDefaults.standard.stringArray(forKey: installedDefaultsKey) ?? [])
        let installedCommands = DottieCLICatalog.all.filter { installedIDs.contains($0.id) }.map(\.command)
        var paragraphs: [String] = []
        if !installedCommands.isEmpty {
            paragraphs.append("Command-line tools on this Mac you can use in the shell: \(installedCommands.joined(separator: ", ")). Prefer them to writing your own code (for example ffmpeg for video, pandoc for documents, jq for JSON).")
        }
        let requestedToolLines = DottieToolInstaller.helperToolLines
        if !requestedToolLines.isEmpty {
            paragraphs.append("Tools Dottie installed for the user, ready to use (use the full path if the name isn't found):\n" + requestedToolLines)
        }
        paragraphs.append(DottieToolInstaller.helperInstallPolicy)
        return paragraphs.joined(separator: "\n\n")
    }
}

// MARK: - Running a program

enum DottieProcessRunner {
    struct Result {
        let exitCode: Int32
        let output: String
        let errorOutput: String
    }

    /// Environment for quiet, quick Homebrew runs.
    static var homebrewEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = DottieCommandLocator.searchPATH
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["NONINTERACTIVE"] = "1"
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// Runs a program, calling `onLine` with each line it prints.
    /// `shouldStop` is checked a few times a second; true stops the program.
    static func run(
        _ executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        shouldStop: (@Sendable () -> Bool)? = nil,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                if let environment { process.environment = environment }
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.standardInput = FileHandle.nullDevice

                let collector = DottieProcessOutputCollector(onLine: onLine)
                outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let newData = fileHandle.availableData
                    if newData.isEmpty { fileHandle.readabilityHandler = nil } else { collector.appendOutput(newData) }
                }
                errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let newData = fileHandle.availableData
                    if newData.isEmpty { fileHandle.readabilityHandler = nil } else { collector.appendError(newData) }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(exitCode: -1, output: "", errorOutput: error.localizedDescription))
                    return
                }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    if Date() > deadline || shouldStop?() == true {
                        process.terminate()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                process.waitUntilExit()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                collector.appendOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
                collector.appendError(errorPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    output: collector.outputText,
                    errorOutput: collector.errorText
                ))
            }
        }
    }
}

/// Collects a program's output and reports each new line.
private final class DottieProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errorOutput = Data()
    private var partialLine = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func appendOutput(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        output.append(newData)
        if output.count > 200_000 { output = Data(output.suffix(100_000)) }
        lock.unlock()
        reportLines(newData)
    }

    func appendError(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        errorOutput.append(newData)
        if errorOutput.count > 200_000 { errorOutput = Data(errorOutput.suffix(100_000)) }
        lock.unlock()
        reportLines(newData)
    }

    private func reportLines(_ newData: Data) {
        lock.lock()
        partialLine.append(newData)
        var lines: [String] = []
        while let newlineIndex = partialLine.firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) {
            let lineData = partialLine[partialLine.startIndex..<newlineIndex]
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
            partialLine.removeSubrange(partialLine.startIndex...newlineIndex)
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    var outputText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: output, as: UTF8.self)
    }

    var errorText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: errorOutput, as: UTF8.self)
    }
}
