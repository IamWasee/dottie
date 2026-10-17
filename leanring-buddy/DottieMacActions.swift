//
//  DottieMacActions.swift
//  leanring-buddy
//
//  Dottie's direct hands on the Mac: the user's Apple Shortcuts and
//  AppleScript. Both talk to apps through their own scripting (Music,
//  Finder, Mail, Notes, System Settings…), which is faster and never misses
//  the way clicking on a screenshot can. Anything that sends, deletes, buys
//  or runs shell commands asks the user first in a dialog.
//

import AppKit
import Foundation

enum DottieMacActions {
    struct ProcessResult {
        let exitCode: Int32
        let output: String
        let errorOutput: String
        let timedOut: Bool
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a command off the main thread and gives up after `timeout`.
    nonisolated static func runProcess(_ executablePath: String, arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ProcessResult(exitCode: -1, output: "", errorOutput: error.localizedDescription, timedOut: false))
                    return
                }
                // Read while it runs so a big output can't fill the pipe and stall it.
                let outputBox = DataBox()
                let errorBox = DataBox()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global().async {
                    outputBox.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global().async {
                    errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }
                var didTimeOut = false
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    if Date() > deadline {
                        didTimeOut = true
                        process.terminate()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                process.waitUntilExit()
                _ = readGroup.wait(timeout: .now() + 2)
                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    output: String(decoding: outputBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    errorOutput: String(decoding: errorBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    timedOut: didTimeOut
                ))
            }
        }
    }

    // MARK: - Shortcuts

    static func shortcutNames() async -> [String] {
        let result = await runProcess("/usr/bin/shortcuts", arguments: ["list"], timeout: 20)
        return result.output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func listShortcuts() async -> String {
        let names = await shortcutNames()
        guard !names.isEmpty else { return "the user has no shortcuts in the Shortcuts app." }
        return "the user's shortcuts: " + names.prefix(200).joined(separator: ", ")
    }

    /// Runs one of the user's shortcuts by name, with optional text input,
    /// and returns what it outputs.
    static func runShortcut(named requestedName: String, input: String?) async -> String {
        let names = await shortcutNames()
        let shortcutName = names.first { $0.caseInsensitiveCompare(requestedName) == .orderedSame }
            ?? names.first { $0.localizedCaseInsensitiveContains(requestedName) || requestedName.localizedCaseInsensitiveContains($0) }
        guard let shortcutName else {
            return "there's no shortcut called \(requestedName). " + (names.isEmpty ? "the user has no shortcuts." : "their shortcuts: \(names.prefix(60).joined(separator: ", ")).")
        }

        let workFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("dottie-shortcut-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workFolderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolderURL) }

        var arguments = ["run", shortcutName]
        if let input, !input.isEmpty {
            let inputFileURL = workFolderURL.appendingPathComponent("input.txt")
            try? input.write(to: inputFileURL, atomically: true, encoding: .utf8)
            arguments += ["--input-path", inputFileURL.path]
        }
        let outputFileURL = workFolderURL.appendingPathComponent("output")
        arguments += ["--output-path", outputFileURL.path, "--output-type", "public.plain-text"]

        let result = await runProcess("/usr/bin/shortcuts", arguments: arguments, timeout: 120)
        if result.timedOut {
            return "the shortcut \(shortcutName) took too long and was stopped."
        }
        guard result.exitCode == 0 else {
            return "the shortcut \(shortcutName) failed: \(shortened(result.errorOutput.isEmpty ? result.output : result.errorOutput, to: 300))"
        }
        let outputText = (try? String(contentsOf: outputFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return outputText.isEmpty
            ? "ran the shortcut \(shortcutName)."
            : "ran the shortcut \(shortcutName). it returned: \(shortened(outputText, to: 2000))"
    }

    // MARK: - AppleScript

    /// Words that mean a script can send, delete, buy or run anything.
    private static let riskyScriptPatterns = [
        "delete", "remove", "erase", "empty trash", "move to trash", "to trash", "do shell script",
        "send", "reply", "forward", "purchase", "buy", "shut down", "restart", "log out", "sudo",
        "password", "keychain", "format ", "overwrite"
    ]

    static func isRisky(_ text: String) -> Bool {
        let lowercasedText = text.lowercased()
        return riskyScriptPatterns.contains { lowercasedText.contains($0) }
    }

    /// Runs AppleScript. Scripts that look like they send, delete, buy or
    /// run shell commands ask the user in a dialog first.
    @MainActor
    static func runAppleScript(_ script: String, purpose: String) async -> String {
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedScript.isEmpty else { return "the script was empty." }
        if isRisky(trimmedScript) {
            let isAllowed = DottieConfirmation.ask(
                title: "Let Dottie do this?",
                detail: (purpose.isEmpty ? "" : purpose + "\n\n") + shortened(trimmedScript, to: 900),
                confirmButtonTitle: "Do it"
            )
            guard isAllowed else { return "the user said no, so it wasn't run. say okay, you won't." }
        }
        let result = await runProcess("/usr/bin/osascript", arguments: ["-e", trimmedScript], timeout: 60)
        if result.timedOut {
            return "the script took too long and was stopped."
        }
        guard result.exitCode == 0 else {
            let errorText = result.errorOutput
            if errorText.contains("-1743") || errorText.localizedCaseInsensitiveContains("not authorized") {
                return "macOS blocked it: the user needs to allow Dottie to control that app (a macOS prompt, or System Settings → Privacy & Security → Automation → Dottie). tell them in one line."
            }
            return "the script failed: \(shortened(errorText, to: 400)). fix the script and try once more, or tell the user."
        }
        return result.output.isEmpty ? "done." : "done. it returned: \(shortened(result.output, to: 2000))"
    }

    static func shortened(_ text: String, to maximumLength: Int) -> String {
        text.count > maximumLength ? String(text.prefix(maximumLength - 1)) + "…" : text
    }
}

/// A plain macOS dialog for things only the user may approve.
@MainActor
enum DottieConfirmation {
    static func ask(title: String, detail: String, confirmButtonTitle: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Don't")
        alert.window.level = .floating
        return alert.runModal() == .alertFirstButtonReturn
    }
}
