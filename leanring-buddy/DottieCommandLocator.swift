//
//  DottieCommandLocator.swift
//  leanring-buddy
//
//  Finds command-line programs (npx, uvx, docker, jq, ffmpeg…) for the
//  Tools tab, MCP servers and helpers. Apps opened from the Dock don't get
//  the PATH Terminal has, so this looks in the usual install folders, then
//  in the folders the user's login shell knows about, and falls back to
//  Dottie's own Node.js (DotsRuntimeInstaller) for node, npm and npx.
//
//  The login shell is asked once, in the background (`warmUp()`); until it
//  answers, only the usual folders are searched, so nothing on the main
//  thread ever waits for a shell.
//

import Foundation

enum DottieCommandLocator {
    private static let lock = NSLock()
    private static var cachedLoginShellFolders: [String]?
    private static var isAskingLoginShell = false

    private static var homeFolder: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// Install folders worth checking even when the login shell doesn't
    /// list them.
    private static var commonFolders: [String] {
        [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(homeFolder)/.local/bin",
            "\(homeFolder)/.cargo/bin",
            "\(homeFolder)/.bun/bin",
            "\(homeFolder)/.deno/bin",
            "\(homeFolder)/.volta/bin",
            "\(homeFolder)/.npm-global/bin",
            "\(homeFolder)/.claude/local",
            "\(homeFolder)/.docker/bin",
            "\(homeFolder)/.orbstack/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    /// Programs in /usr/bin that are only stand-ins until Apple's Command
    /// Line Tools are installed: running one pops up an installer.
    private static let commandLineToolsStandIns: Set<String> = ["git", "python3", "pip3", "make", "clang"]

    static var areCommandLineToolsInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
    }

    /// Every folder searched, in order, with no duplicates.
    static var searchFolders: [String] {
        lock.lock()
        let loginFolders = cachedLoginShellFolders ?? []
        lock.unlock()
        var folders: [String] = []
        for folder in loginFolders + commonFolders + [DotsRuntimeInstaller.nodeBinFolderURL.path]
        where !folder.isEmpty && !folders.contains(folder) {
            folders.append(folder)
        }
        return folders
    }

    /// A PATH for programs Dottie starts, so they find the same tools.
    static var searchPATH: String {
        searchFolders.joined(separator: ":")
    }

    /// The full path of a program, or nil when it isn't installed.
    static func locate(_ commandName: String) -> String? {
        if commandName.contains("/") {
            let expandedPath = (commandName as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expandedPath) ? expandedPath : nil
        }
        let needsCommandLineTools = commandLineToolsStandIns.contains(commandName)
        let hasCommandLineTools = needsCommandLineTools ? areCommandLineToolsInstalled : true
        for folder in searchFolders {
            if folder == "/usr/bin" && needsCommandLineTools && !hasCommandLineTools { continue }
            let candidatePath = folder + "/" + commandName
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }
        return nil
    }

    static func isInstalled(_ commandName: String) -> Bool {
        locate(commandName) != nil
    }

    /// Asks the login shell for its PATH once, off the main thread.
    static func warmUp() async {
        lock.lock()
        let alreadyKnown = cachedLoginShellFolders != nil || isAskingLoginShell
        if !alreadyKnown { isAskingLoginShell = true }
        lock.unlock()
        guard !alreadyKnown else { return }

        let folders: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readLoginShellFolders())
            }
        }
        lock.lock()
        cachedLoginShellFolders = folders
        isAskingLoginShell = false
        lock.unlock()
    }

    /// Forgets the login shell's answer, e.g. after Homebrew is installed.
    static func refresh() async {
        lock.lock()
        cachedLoginShellFolders = nil
        lock.unlock()
        await warmUp()
    }

    private static func readLoginShellFolders() -> [String] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", "echo \"$PATH\""]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        // A shell profile that hangs must not hang Dottie.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return []
        }
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // Profiles sometimes print a banner first; the PATH is the last line.
        let lastLine = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return lastLine.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }
}
