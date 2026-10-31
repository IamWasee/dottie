//
//  DottieCodeWorkspace.swift
//  leanring-buddy
//
//  The state behind Home → Code, Dottie's small code editor: every folder
//  of code Dottie and her helpers make (Projects, each Dot's workspace)
//  plus folders the user opens, the file being edited, saving, running a
//  command in the file's folder, and handing a change to a helper ("add a
//  dark mode to this page"). A file a helper changes on disk while it's
//  open and unedited reloads by itself, so the user watches the work land.
//
//  Voice Dottie opens files here with the code_editor tool, and helpers are
//  told the Code tab shows their work.
//

import AppKit
import Combine
import Foundation

@MainActor
final class DottieCodeWorkspace: ObservableObject {
    static let shared = DottieCodeWorkspace()

    struct Root: Identifiable, Equatable {
        let url: URL
        let title: String
        var id: String { url.path }
    }

    @Published private(set) var openedFolderURLs: [URL] = []
    @Published private(set) var selectedFileURL: URL?
    @Published var editorText = "" {
        didSet { if editorText != savedText { hasUnsavedChanges = true } }
    }
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var commandOutput = ""
    @Published private(set) var isRunningCommand = false
    @Published private(set) var statusLine = ""
    /// Bumped when the file tree should be read again.
    @Published private(set) var treeRevision = 0

    private var savedText = ""
    private var savedModificationDate: Date?
    private var reloadTimer: Timer?

    private static let openedFoldersDefaultsKey = "dottieCodeOpenedFolders"
    /// Bigger files open read-only in Finder's default app instead.
    private static let largestEditableFileBytes = 2_000_000
    static let coderHelperName = "Coder"

    private init() {
        openedFolderURLs = (UserDefaults.standard.stringArray(forKey: Self.openedFoldersDefaultsKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Catches helpers' edits to the open file every two seconds, only
    /// while the Code tab is on screen (it used to run for as long as
    /// Dottie did). Opening the tab checks right away.
    func startWatchingOpenFile() {
        reloadIfChangedOnDisk()
        guard reloadTimer == nil else { return }
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                DottieCodeWorkspace.shared.reloadIfChangedOnDisk()
            }
        }
    }

    func stopWatchingOpenFile() {
        reloadTimer?.invalidate()
        reloadTimer = nil
    }

    /// Projects, the Dots' folders, then folders the user opened.
    var roots: [Root] {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dottieFolderURL = applicationSupportURL.appendingPathComponent("Dottie", isDirectory: true)
        var roots = [
            Root(url: dottieFolderURL.appendingPathComponent("Projects", isDirectory: true), title: "Projects"),
            Root(url: dottieFolderURL.appendingPathComponent("Dots", isDirectory: true), title: "Dots")
        ]
        roots += openedFolderURLs.map { Root(url: $0, title: $0.lastPathComponent) }
        return roots.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// The folder a command runs in and a helper works in.
    var currentFolderURL: URL? {
        selectedFileURL?.deletingLastPathComponent()
    }

    // MARK: - Files

    /// Opens a file (or adds a folder to the tree). Returns a problem, or
    /// nil when it opened.
    @discardableResult
    func open(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return "there's no file at \(url.path)." }
        if isDirectory.boolValue {
            addFolder(url)
            return nil
        }
        if hasUnsavedChanges { save() }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileSize <= Self.largestEditableFileBytes,
              let fileData = try? Data(contentsOf: url),
              let fileText = String(data: fileData, encoding: .utf8) else {
            NSWorkspace.shared.open(url)
            return "that file isn't text (or is too big), so it opened in its own app."
        }
        selectedFileURL = url
        savedText = fileText
        editorText = fileText
        hasUnsavedChanges = false
        savedModificationDate = Self.modificationDate(of: url)
        statusLine = ""
        return nil
    }

    func save() {
        guard let selectedFileURL, hasUnsavedChanges else { return }
        do {
            try editorText.write(to: selectedFileURL, atomically: true, encoding: .utf8)
            savedText = editorText
            hasUnsavedChanges = false
            savedModificationDate = Self.modificationDate(of: selectedFileURL)
            statusLine = "Saved"
        } catch {
            statusLine = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func addFolder(_ folderURL: URL) {
        guard !openedFolderURLs.contains(folderURL) else { return }
        openedFolderURLs.append(folderURL)
        UserDefaults.standard.set(openedFolderURLs.map(\.path), forKey: Self.openedFoldersDefaultsKey)
        treeRevision += 1
    }

    func removeFolder(_ folderURL: URL) {
        openedFolderURLs.removeAll { $0 == folderURL }
        UserDefaults.standard.set(openedFolderURLs.map(\.path), forKey: Self.openedFoldersDefaultsKey)
        treeRevision += 1
    }

    func refreshTree() {
        treeRevision += 1
    }

    func chooseFolderToOpen() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Open"
        NSApp.activate(ignoringOtherApps: true)
        guard openPanel.runModal() == .OK, let chosenURL = openPanel.url else { return }
        open(chosenURL)
    }

    private func reloadIfChangedOnDisk() {
        guard let selectedFileURL, !hasUnsavedChanges,
              let diskModificationDate = Self.modificationDate(of: selectedFileURL),
              diskModificationDate != savedModificationDate,
              let fileText = try? String(contentsOf: selectedFileURL, encoding: .utf8) else { return }
        savedText = fileText
        editorText = fileText
        hasUnsavedChanges = false
        savedModificationDate = diskModificationDate
        statusLine = "Updated on disk"
        treeRevision += 1
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The entries of a folder for the tree: folders first, hidden files
    /// and build clutter left out.
    static func children(of folderURL: URL) -> [URL] {
        let skippedNames: Set<String> = ["node_modules", ".git", ".build", "DerivedData", "__pycache__", ".cli-home", ".venv", "dist"]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { !skippedNames.contains($0.lastPathComponent) }
            .sorted { firstURL, secondURL in
                let firstIsFolder = isFolder(firstURL), secondIsFolder = isFolder(secondURL)
                if firstIsFolder != secondIsFolder { return firstIsFolder }
                return firstURL.lastPathComponent.localizedStandardCompare(secondURL.lastPathComponent) == .orderedAscending
            }
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // MARK: - Running and asking

    /// Runs a shell command in the open file's folder (up to five minutes).
    func run(_ command: String) {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty, !isRunningCommand else { return }
        if hasUnsavedChanges { save() }
        let folderPath = currentFolderURL?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        isRunningCommand = true
        commandOutput = "$ \(trimmedCommand)\n"
        Task {
            let escapedFolderPath = folderPath.replacingOccurrences(of: "'", with: "'\\''")
            let result = await DottieMacActions.runProcess(
                "/bin/zsh",
                arguments: ["-lc", "cd '\(escapedFolderPath)' && \(trimmedCommand)"],
                timeout: 300
            )
            var outputText = result.output + (result.errorOutput.isEmpty ? "" : "\n" + result.errorOutput)
            if result.timedOut { outputText += "\n(stopped after 5 minutes)" }
            outputText += "\n(exit \(result.exitCode))"
            commandOutput += String(outputText.suffix(20_000))
            isRunningCommand = false
            treeRevision += 1
        }
    }

    /// Hands a change to the Coder helper, with the open file and folder.
    func askHelper(_ request: String) -> String {
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else { return "say what to change." }
        guard let clickyRoster = DottieSelfKnowledge.companionManager?.clickyRoster else { return "helpers aren't ready." }
        if hasUnsavedChanges { save() }
        let coderHelper = clickyRoster.agents.first { $0.name == Self.coderHelperName }
            ?? clickyRoster.createAgent(name: Self.coderHelperName, purpose: "Changes code the user has open in Dottie's Code tab.")
        var taskText = "The user is editing code in Dottie's Code tab and asks: \(trimmedRequest)"
        if let selectedFileURL {
            taskText += "\n\nThe open file is `\(selectedFileURL.path)`, in the folder `\(selectedFileURL.deletingLastPathComponent().path)`. Make the change in place there (not in your own folder), keep the code's style, check it works if you can, and reply with what you changed in two sentences."
        }
        let tasksAhead = clickyRoster.sendOrQueueMessage(taskText, to: coderHelper)
        statusLine = tasksAhead > 0 ? "Coder will do it after \(tasksAhead) other task\(tasksAhead == 1 ? "" : "s")" : "Coder is on it"
        return statusLine
    }
}

// MARK: - The voice tool

@MainActor
enum DottieCodeEditorTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "code_editor",
                description: "Dottie's own code editor (Home → Code), which shows every project and Dot folder. open shows a file or folder there (path, ~ for home; or a project's name); run runs a shell command in the open file's folder; change has the Coder helper change the open file (request); status says which file is open. Use it when the user wants to see, edit or run the code Dottie or a helper made.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["open", "run", "change", "status"]],
                        "path": ["type": "STRING", "description": "For open: the file or folder, or a project's name."],
                        "command": ["type": "STRING", "description": "For run: the shell command, like npm start."],
                        "request": ["type": "STRING", "description": "For change: what to change in the open file."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let workspace = DottieCodeWorkspace.shared
                switch arguments.dottieString("action") ?? "status" {
                case "open":
                    let spokenPath = arguments.dottieString("path") ?? ""
                    let fileURL = openableURL(forSaid: spokenPath)
                    DottieHomeNavigator.shared.requestedSection = .code
                    DottieSelfKnowledge.companionManager?.openHomeWindow()
                    guard let fileURL else { return "opened the Code tab; there was nothing called \(spokenPath)." }
                    return workspace.open(fileURL) ?? "opened \(fileURL.lastPathComponent) in the Code tab."
                case "run":
                    let command = arguments.dottieString("command") ?? ""
                    workspace.run(command)
                    DottieHomeNavigator.shared.requestedSection = .code
                    DottieSelfKnowledge.companionManager?.openHomeWindow()
                    return "running it in the Code tab; the output shows there."
                case "change":
                    return workspace.askHelper(arguments.dottieString("request") ?? "")
                default:
                    guard let selectedFileURL = workspace.selectedFileURL else { return "no file is open in the Code tab." }
                    return "\(selectedFileURL.path) is open\(workspace.hasUnsavedChanges ? ", with unsaved changes" : "")."
                }
            }
        ]
    }

    static var helperPromptSection: String {
        "The user reads, edits and runs code in Dottie's Code tab (Home → Code), which shows the Projects folder and every Dot's folder. When you make or change code, keep it in the project's folder and name the main file's path in your reply."
    }

    /// A path as said ("~/site/index.html"), or a project's name.
    private static func openableURL(forSaid spokenPath: String) -> URL? {
        let trimmedPath = spokenPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath) {
            return URL(fileURLWithPath: expandedPath)
        }
        let projectsRoot = DottieCodeWorkspace.shared.roots.first { $0.title == "Projects" }?.url
        guard let projectsRoot else { return nil }
        let wantedName = trimmedPath.lowercased()
        return DottieCodeWorkspace.children(of: projectsRoot).first {
            $0.lastPathComponent.lowercased().contains(wantedName) || wantedName.contains($0.lastPathComponent.lowercased())
        }
    }
}
