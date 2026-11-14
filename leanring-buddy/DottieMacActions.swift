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
            DottieFileSaver.save(text: input, to: inputFileURL)
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
    /// Besides "do shell script" that covers the other ways a script reaches
    /// a shell or another program's own scripting: Terminal's "do script",
    /// "run script" on text, JavaScript in a browser tab, typing keys into
    /// whatever app is in front, raw event codes written with « », and
    /// writing files.
    private static let riskyScriptPatterns = [
        "delete", "remove", "erase", "empty trash", "move to trash", "to trash", "do shell script",
        "send", "reply", "forward", "purchase", "buy", "shut down", "restart", "log out", "sudo",
        "password", "keychain", "format ", "overwrite",
        "do script", "run script", "load script", "osascript", "terminal", "iterm",
        "do javascript", "execute javascript", "keystroke", "key code", "«",
        "open for access", "to file"
    ]

    static func isRisky(_ text: String) -> Bool {
        // AppleScript reads "do   shell script" and a command broken over
        // two lines with ¬ the same as the plain spelling, so the check
        // looks at the words with single spaces between them.
        let wordsWithSingleSpaces = text.lowercased()
            .replacingOccurrences(of: "¬", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return riskyScriptPatterns.contains { wordsWithSingleSpaces.contains($0) }
    }

    /// UserDefaults key of "Run scripts without asking" in Settings →
    /// Working on its own. Also turned on by "Always allow" in the dialog.
    static let alwaysAllowsScriptsDefaultsKey = "dottieAlwaysAllowsScripts"

    /// Off until the user taps "Always allow" or turns the setting on.
    static var alwaysAllowsScripts: Bool {
        UserDefaults.standard.bool(forKey: alwaysAllowsScriptsDefaultsKey)
    }

    /// Who is asked before a script runs.
    enum ScriptPermissionRoute: Equatable {
        /// Nobody: the script runs straight away.
        case runWithoutAsking
        /// A dialog on the Mac with Do it, Always allow and Don't.
        case askOnMac
        /// Allow / Deny on the phone, because the user is away.
        case askOnPhone
    }

    /// Dottie works for the user, so a script only waits for a yes when it
    /// looks risky and the user hasn't said "always allow" yet. While the
    /// user is away the question goes to their phone, since nobody is at
    /// the Mac to see a dialog.
    static func scriptPermissionRoute(isScriptRisky: Bool, alwaysAllowsScripts: Bool, questionsGoToPhone: Bool) -> ScriptPermissionRoute {
        guard isScriptRisky, !alwaysAllowsScripts else { return .runWithoutAsking }
        return questionsGoToPhone ? .askOnPhone : .askOnMac
    }

    /// Runs AppleScript. Scripts that look like they send, delete, buy or
    /// run shell commands ask the user first (on the Mac, or on the phone
    /// in away mode) until the user picks "Always allow".
    @MainActor
    static func runAppleScript(_ script: String, purpose: String) async -> String {
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedScript.isEmpty else { return "the script was empty." }
        let permissionRoute = scriptPermissionRoute(
            isScriptRisky: isRisky(trimmedScript),
            alwaysAllowsScripts: alwaysAllowsScripts,
            questionsGoToPhone: DottieAwayMode.shared.questionsGoToPhone
        )
        let questionDetail = (purpose.isEmpty ? "" : purpose + "\n\n") + shortened(trimmedScript, to: 900)
        switch permissionRoute {
        case .runWithoutAsking:
            break
        case .askOnPhone:
            let isAllowed = await DottieAwayMode.shared.confirmOnPhone("Let Dottie run this script?\n\n" + questionDetail, screenshotJPEG: nil)
            guard isAllowed else { return "the user didn't allow it from their phone, so it wasn't run. carry on with what doesn't need it." }
        case .askOnMac:
            let answer = DottieConfirmation.askWithAlwaysAllow(
                title: "Let Dottie do this?",
                detail: questionDetail + "\n\nAlways allow: Dottie stops asking before scripts. You can change it in Settings → Working on its own.",
                confirmButtonTitle: "Do it"
            )
            switch answer {
            case .declined:
                return "the user said no, so it wasn't run. say okay, you won't."
            case .allowedAlways:
                UserDefaults.standard.set(true, forKey: alwaysAllowsScriptsDefaultsKey)
                DottieLog.notice("The user chose Always allow for scripts")
            case .allowedOnce:
                break
            }
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
            return "the script failed: \(shortened(errorText, to: 400)). fix the script and try once more; if it fails again, don't keep scripting: call do_task_on_screen with the user's whole goal so it's done on screen."
        }
        var resultText = result.output.isEmpty ? "done." : "done. it returned: \(shortened(result.output, to: 2000))"
        // "Play Louise" used to end here as "done." while Spotify only
        // showed a search, and Dottie said it was playing. What's actually
        // playing now goes back with the result, so a miss is seen.
        if let musicAppName = musicAppNamed(inScript: trimmedScript) {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            resultText += " " + (await nowPlayingLine(inAppNamed: musicAppName))
        }
        return resultText
    }

    /// Spotify or Music when the script talks to one of them.
    private static func musicAppNamed(inScript script: String) -> String? {
        let lowercasedScript = script.lowercased()
        if lowercasedScript.contains("application \"spotify\"") { return "Spotify" }
        if lowercasedScript.contains("application \"music\"") { return "Music" }
        return nil
    }

    /// What the music app says is playing, as a line for the model, with
    /// what to do when it isn't what the user asked for.
    static func nowPlayingLine(inAppNamed musicAppName: String) async -> String {
        let checkScript = """
        tell application "\(musicAppName)"
            if player state is playing then
                return "playing: " & (name of current track) & " by " & (artist of current track)
            else
                return "not playing (" & (player state as text) & ")"
            end if
        end tell
        """
        let checkResult = await runProcess("/usr/bin/osascript", arguments: ["-e", checkScript], timeout: 8)
        let checkOutput = checkResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let stateText = checkResult.exitCode == 0 && !checkOutput.isEmpty ? checkOutput : "couldn't tell what's playing"
        return "check of \(musicAppName) now: \(stateText). if they asked for something to play, only say it's playing when this shows it. if it doesn't (a search page, the wrong song, paused), \(musicAppName)'s scripting can't pick that song: call do_task_on_screen to search for it in \(musicAppName) and press play on the top result."
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

    enum AnswerWithAlwaysAllow {
        case allowedOnce
        case allowedAlways
        case declined
    }

    /// The same dialog with a third button, "Always allow", for questions
    /// the user shouldn't have to answer every time.
    static func askWithAlwaysAllow(title: String, detail: String, confirmButtonTitle: String) -> AnswerWithAlwaysAllow {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Always allow")
        alert.addButton(withTitle: "Don't")
        alert.window.level = .floating
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allowedOnce
        case .alertSecondButtonReturn: return .allowedAlways
        default: return .declined
        }
    }
}
