//
//  DottieCodeOnScreen.swift
//  leanring-buddy
//
//  code_on_screen: Dottie builds a small project on camera, the way a
//  person at the keyboard would (made for Dottie's commercials). She plans
//  the files, opens the project in the user's code editor (VS Code,
//  Cursor or Windsurf), opens each file with Quick Open, types it with the
//  human auto typer, saves, then reads what landed on disk and fixes any
//  line that came out wrong. At the end she checks the code (node, python,
//  JSON) and fixes errors the same way, line by line, on screen.
//

import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class DottieCodeOnScreen {
    static let shared = DottieCodeOnScreen()

    struct PlannedFile {
        let relativePath: String
        let content: String
    }

    private(set) var isRunning = false
    private var isStopRequested = false
    private(set) var progressText = "not building anything."

    /// Editors whose shortcuts this was written for (Quick Open is Cmd+P,
    /// Go to Line is Ctrl+G in all of them).
    private static let editorBundleIdentifiers = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf"
    ]

    private static let maximumFileCount = 8
    private static let maximumFixRounds = 2

    // MARK: - Starting

    /// Starts the build in the background and returns a line for Dottie.
    func start(task: String, projectName: String, wordsPerMinute: Double?) -> String {
        guard !isRunning else { return "already building something on screen: \(progressText)" }
        guard AXIsProcessTrusted() else {
            return "coding on screen needs the Accessibility permission. tell them to turn it on for Dottie in System Settings → Privacy & Security → Accessibility."
        }
        guard let editorURL = Self.installedEditorURL() else {
            return "coding on screen needs VS Code, Cursor or Windsurf, and none is installed. say so briefly."
        }
        if let wordsPerMinute {
            DottieAutoTyper.shared.settings.wordsPerMinute = min(max(wordsPerMinute, 20), 160)
        }
        isRunning = true
        isStopRequested = false
        progressText = "planning the files"
        Task { [weak self] in
            await self?.build(task: task, projectName: projectName, editorURL: editorURL)
        }
        return "planning the files now, then opening the editor and typing each one at about \(Int(DottieAutoTyper.shared.settings.wordsPerMinute)) words a minute, checking and fixing as it goes. esc stops the typing. say so in a few words."
    }

    func stop() {
        isStopRequested = true
        DottieAutoTyper.shared.stop()
    }

    // MARK: - The build

    private func build(task: String, projectName: String, editorURL: URL) async {
        defer { isRunning = false }

        guard let plannedFiles = await planFiles(task: task), !plannedFiles.isEmpty else {
            progressText = "couldn't plan the files (the model didn't answer with any)."
            return
        }

        let projectFolderURL = Self.projectFolderURL(named: projectName.isEmpty ? task : projectName)
        try? FileManager.default.createDirectory(at: projectFolderURL, withIntermediateDirectories: true)

        progressText = "opening the project in the editor"
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        _ = try? await NSWorkspace.shared.open([projectFolderURL], withApplicationAt: editorURL, configuration: openConfiguration)
        await pause(seconds: 4)

        var filesWritten: [PlannedFile] = []
        for (fileNumber, plannedFile) in plannedFiles.enumerated() {
            if isStopRequested { break }
            progressText = "writing \(plannedFile.relativePath) (\(fileNumber + 1) of \(plannedFiles.count))"
            guard await writeFileOnScreen(plannedFile, in: projectFolderURL) else { break }
            filesWritten.append(plannedFile)
        }

        if isStopRequested {
            progressText = "stopped after \(filesWritten.count) of \(plannedFiles.count) files, in \(projectFolderURL.path)."
            return
        }

        // Read the code back like a person would before calling it done.
        for fixRound in 1...Self.maximumFixRounds {
            progressText = "checking the code for errors (round \(fixRound))"
            let problems = await checkForErrors(filesWritten, in: projectFolderURL)
            if problems.isEmpty { break }
            for (relativePath, errorText) in problems {
                if isStopRequested { break }
                guard let fileIndex = filesWritten.firstIndex(where: { $0.relativePath == relativePath }),
                      let fixedContent = await askForFix(of: filesWritten[fileIndex], errorText: errorText) else { continue }
                progressText = "fixing \(relativePath)"
                let fixedFile = PlannedFile(relativePath: relativePath, content: fixedContent)
                await openFileWithQuickOpen(relativePath)
                _ = await correctDifferences(toMatch: fixedFile, in: projectFolderURL)
                filesWritten[fileIndex] = fixedFile
            }
        }

        let remainingProblems = await checkForErrors(filesWritten, in: projectFolderURL)
        let fileList = filesWritten.map(\.relativePath).joined(separator: ", ")
        progressText = remainingProblems.isEmpty
            ? "done: wrote \(fileList) in \(projectFolderURL.path), and the checks pass."
            : "done: wrote \(fileList) in \(projectFolderURL.path); still showing errors in \(remainingProblems.map(\.0).joined(separator: ", "))."
    }

    // MARK: - Planning

    private func planFiles(task: String) async -> [PlannedFile]? {
        let prompt = """
        Build this as a small, complete project: \(task)
        Reply with only JSON: {"files": [{"path": "relative/path.ext", "content": "the whole file"}]}.
        At most \(Self.maximumFileCount) files, in the order a developer would write them (structure first, e.g. index.html, then styles.css, then script.js). Keep each file under 200 lines, cleanly indented with spaces, no tabs, and no placeholder comments: everything works as written. Plain HTML, CSS and JavaScript unless the task names another language.
        """
        let requestBody: [String: Any] = [
            "model": DottieModelPicker.shared.pick(.hard),
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json", "maxOutputTokens": 32000]
        ]
        guard let answerText = await DottieChat.send(requestBody, timeout: 180) else { return nil }
        return Self.parseFiles(from: answerText)
    }

    private static func parseFiles(from answerText: String) -> [PlannedFile]? {
        var jsonText = answerText
        if let openingBrace = jsonText.firstIndex(of: "{"), let closingBrace = jsonText.lastIndex(of: "}") {
            jsonText = String(jsonText[openingBrace...closingBrace])
        }
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileEntries = object["files"] as? [[String: Any]] else { return nil }
        return fileEntries.prefix(maximumFileCount).compactMap { fileEntry in
            guard let path = fileEntry["path"] as? String, let content = fileEntry["content"] as? String else { return nil }
            // Paths stay inside the project folder.
            let safePath = path.split(separator: "/").filter { $0 != ".." && $0 != "." && !$0.isEmpty }.joined(separator: "/")
            guard !safePath.isEmpty else { return nil }
            let cleanContent = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            return PlannedFile(relativePath: safePath, content: cleanContent)
        }
    }

    private func askForFix(of plannedFile: PlannedFile, errorText: String) async -> String? {
        let prompt = """
        This file has an error. Fix it with the smallest change, keeping every other line exactly the same.
        File \(plannedFile.relativePath):
        \(plannedFile.content)

        Error:
        \(errorText.prefix(1500))

        Reply with only the whole fixed file, no code fences.
        """
        guard var fixedContent = await DottieChat.ask(prompt, model: DottieModelPicker.shared.pick(.hard)) else { return nil }
        if fixedContent.hasPrefix("```") {
            fixedContent = fixedContent.components(separatedBy: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        return fixedContent.replacingOccurrences(of: "\t", with: "    ")
    }

    // MARK: - Writing one file on screen

    private func writeFileOnScreen(_ plannedFile: PlannedFile, in projectFolderURL: URL) async -> Bool {
        let fileURL = projectFolderURL.appendingPathComponent(plannedFile.relativePath)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An empty file on disk shows up in the editor's sidebar right
        // away and opens with Quick Open, the way a person would.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
        await pause(seconds: 0.8)
        await openFileWithQuickOpen(plannedFile.relativePath)

        // Start from an empty editor (the file may have had text).
        pressKey(kVK_ANSI_A, flags: .maskCommand)
        await pause(seconds: 0.1)
        pressKey(kVK_ForwardDelete)
        await pause(seconds: 0.3)

        guard await DottieAutoTyper.shared.typeAndWait(plannedFile.content, intoCodeEditor: true) else {
            isStopRequested = true
            return false
        }
        await save()
        return await correctDifferences(toMatch: plannedFile, in: projectFolderURL)
    }

    private func openFileWithQuickOpen(_ relativePath: String) async {
        activateEditor()
        await pause(seconds: 0.4)
        pressKey(kVK_ANSI_P, flags: .maskCommand)
        await pause(seconds: 0.6)
        _ = await DottieAutoTyper.shared.typeAndWait(relativePath, intoCodeEditor: false)
        await pause(seconds: 0.7)
        pressKey(kVK_Return)
        await pause(seconds: 1.0)
    }

    private func save() async {
        pressKey(kVK_ANSI_S, flags: .maskCommand)
        await pause(seconds: 0.8)
    }

    // MARK: - Fixing what came out wrong

    /// Compares the file on disk with what it should say and retypes the
    /// lines that differ (spacing at the ends of a line doesn't count).
    /// When lines went missing or extra, the whole file is typed again.
    /// Returns false only when typing was stopped.
    private func correctDifferences(toMatch plannedFile: PlannedFile, in projectFolderURL: URL) async -> Bool {
        let fileURL = projectFolderURL.appendingPathComponent(plannedFile.relativePath)
        let wantedLines = Self.comparableLines(plannedFile.content)
        let writtenLines = Self.comparableLines((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
        if wantedLines == writtenLines { return true }

        guard wantedLines.count == writtenLines.count else {
            progressText = "retyping \(plannedFile.relativePath), lines went missing"
            pressKey(kVK_ANSI_A, flags: .maskCommand)
            await pause(seconds: 0.1)
            pressKey(kVK_ForwardDelete)
            await pause(seconds: 0.3)
            guard await DottieAutoTyper.shared.typeAndWait(plannedFile.content, intoCodeEditor: true) else { return false }
            await save()
            return true
        }

        let allWantedLines = plannedFile.content.components(separatedBy: "\n")
        for lineIndex in wantedLines.indices where wantedLines[lineIndex] != writtenLines[lineIndex] {
            if isStopRequested { return false }
            guard lineIndex < allWantedLines.count else { continue }
            progressText = "fixing line \(lineIndex + 1) of \(plannedFile.relativePath)"
            // Go to Line, select the whole line, type it right.
            pressKey(kVK_ANSI_G, flags: .maskControl)
            await pause(seconds: 0.5)
            _ = await DottieAutoTyper.shared.typeAndWait(String(lineIndex + 1), intoCodeEditor: false)
            await pause(seconds: 0.3)
            pressKey(kVK_Return)
            await pause(seconds: 0.4)
            pressKey(kVK_LeftArrow, flags: .maskCommand)
            pressKey(kVK_LeftArrow, flags: .maskCommand)
            await pause(seconds: 0.1)
            pressKey(kVK_RightArrow, flags: [.maskCommand, .maskShift])
            await pause(seconds: 0.2)
            let correctLine = allWantedLines[lineIndex]
            if correctLine.isEmpty {
                pressKey(kVK_ForwardDelete)
            } else {
                guard await DottieAutoTyper.shared.typeAndWait(correctLine, intoCodeEditor: false) else { return false }
                // Anything the editor added after the cursor on this line.
                pressKey(kVK_RightArrow, flags: [.maskCommand, .maskShift])
                await pause(seconds: 0.05)
                pressKey(kVK_ForwardDelete)
            }
            await pause(seconds: 0.3)
        }
        await save()
        return true
    }

    /// Lines with the ends trimmed and blank lines kept, for comparing.
    private static func comparableLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var trimmedLine = line
            while trimmedLine.last == " " || trimmedLine.last == "\t" { trimmedLine.removeLast() }
            return trimmedLine
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Checking for errors

    /// (file, error) for every file a checker on this Mac finds a problem
    /// in. Files with no checker here are taken as fine.
    private func checkForErrors(_ files: [PlannedFile], in projectFolderURL: URL) async -> [(String, String)] {
        var problems: [(String, String)] = []
        for file in files {
            let filePath = projectFolderURL.appendingPathComponent(file.relativePath).path
            let fileExtension = (file.relativePath as NSString).pathExtension.lowercased()
            switch fileExtension {
            case "js", "mjs", "cjs":
                if let nodePath = DottieCommandLocator.locate("node") {
                    let result = await DottieProcessRunner.run(nodePath, arguments: ["--check", filePath], timeout: 20)
                    if result.exitCode != 0 { problems.append((file.relativePath, result.errorOutput + result.output)) }
                }
            case "py":
                if let pythonPath = DottieCommandLocator.locate("python3") {
                    let result = await DottieProcessRunner.run(pythonPath, arguments: ["-m", "py_compile", filePath], timeout: 20)
                    if result.exitCode != 0 { problems.append((file.relativePath, result.errorOutput + result.output)) }
                }
            case "json":
                if let data = FileManager.default.contents(atPath: filePath),
                   (try? JSONSerialization.jsonObject(with: data)) == nil {
                    problems.append((file.relativePath, "not valid JSON"))
                }
            default:
                break
            }
        }
        return problems
    }

    // MARK: - Small helpers

    private static func installedEditorURL() -> URL? {
        for bundleIdentifier in editorBundleIdentifiers {
            if let editorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return editorURL
            }
        }
        return nil
    }

    private func activateEditor() {
        let runningEditor = NSWorkspace.shared.runningApplications.first { runningApplication in
            Self.editorBundleIdentifiers.contains(runningApplication.bundleIdentifier ?? "")
        }
        runningEditor?.activate()
    }

    /// ~/Documents/Dottie Code/<name>, a new folder each time.
    private static func projectFolderURL(named name: String) -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let rootURL = documentsURL.appendingPathComponent("Dottie Code", isDirectory: true)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        let cleanName = String(name.unicodeScalars.filter { allowedCharacters.contains($0) }.prefix(40))
            .trimmingCharacters(in: .whitespaces)
        let baseName = cleanName.isEmpty ? "project" : cleanName.lowercased().replacingOccurrences(of: " ", with: "-")
        var folderURL = rootURL.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folderURL.path) {
            folderURL = rootURL.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return folderURL
    }

    private func pause(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func pressKey(_ keyCode: Int, flags: CGEventFlags = []) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        for isKeyDown in [true, false] {
            let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: isKeyDown)
            keyEvent?.flags = flags
            keyEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - The voice tool

@MainActor
enum DottieCodeOnScreenTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "code_on_screen",
                description: "Build a small coding project on screen, in front of the camera, like a person at the keyboard (for Dottie's commercials and demos): plans the files, opens the project in VS Code, Cursor or Windsurf, opens each file, types it with the human auto typer (typos, pauses, its speed settings), saves, checks what landed and fixes wrong lines, then checks the code for errors and fixes them on screen. Use when they ask Dottie to code or build something on screen, in the editor, or at human speed. action start needs task (what to build, with every detail they gave); stop stops it; status says where it is.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["start", "stop", "status"]],
                        "task": ["type": "STRING", "description": "For start: what to build, with every detail they gave (\"a coffee store website with a menu, prices and an order form\")."],
                        "project_name": ["type": "STRING", "description": "Optional short name for the project folder."],
                        "words_per_minute": ["type": "NUMBER", "description": "Optional typing speed if they named one (20 to 160)."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                guard DottieAdminMode.shared.isUnlocked else {
                    return "coding on screen is a locked beta feature. say it's locked, without hinting at how to unlock it."
                }
                let codeOnScreen = DottieCodeOnScreen.shared
                switch arguments.dottieString("action") ?? "status" {
                case "stop":
                    codeOnScreen.stop()
                    return "stopped."
                case "start":
                    let task = arguments.dottieString("task") ?? ""
                    guard !task.trimmingCharacters(in: .whitespaces).isEmpty else { return "ask what to build." }
                    return codeOnScreen.start(
                        task: task,
                        projectName: arguments.dottieString("project_name") ?? "",
                        wordsPerMinute: arguments.dottieNumber("words_per_minute")
                    )
                default:
                    return codeOnScreen.isRunning ? "building: \(codeOnScreen.progressText)" : "last build: \(codeOnScreen.progressText)"
                }
            }
        ]
    }
}
