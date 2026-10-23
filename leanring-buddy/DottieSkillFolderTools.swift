//
//  DottieSkillFolderTools.swift
//  leanring-buddy
//
//  "Install the skills in this folder": the install_skills voice tool adds
//  every skill in a folder the user points to (a SKILL.md folder, or a
//  folder of them like a downloaded set of 50) to the skills library and
//  turns each new one on for every Dot, the same as Home → Skills →
//  "Add a skill folder…". The folder can be a path, a folder name the user
//  says ("the dottie skills folder"), the folder open in the front Finder
//  window, or one picked in a folder picker. The user confirms on screen
//  before anything is copied.
//

import AppKit
import Foundation

@MainActor
enum DottieSkillFolderTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "install_skills",
                description: "Installs skills for the Dots from a folder the user points to: every folder inside it that has a SKILL.md (or the folder itself if it has one). Skills already installed are kept as they are. Pass path when the user said where the folder is (like ~/Dottie-claude-folder/dottie-skills) or named it ('the dottie skills folder' → dottie skills; 'my Downloads' → Downloads): a name is looked up in the home folder, Desktop, Downloads and Documents. Leave it out for 'install these skills' (the folder open in Finder is used) or when they didn't say; then a folder picker opens. The user confirms on screen before anything is copied. Then say in one sentence how many were installed.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "path": ["type": "STRING", "description": "The folder's path or name, only when the user said it. ~ is their home folder."]
                    ]
                ],
                audiences: [.voice]
            ) { arguments in
                await installSkills(folderPath: arguments.dottieString("path"))
            }
        ]
    }

    private static func installSkills(folderPath: String?) async -> String {
        guard let clickyRoster = DottieSelfKnowledge.companionManager?.clickyRoster else {
            return "skills can't be installed right now. say so in one line."
        }

        let chosenFolderURL: URL
        if let folderPath, !folderPath.isEmpty {
            guard let matchingFolderURL = folderURL(matchingSaidFolder: folderPath) else {
                return "there's no folder called \(folderPath) in the home folder, Desktop, Downloads or Documents. ask the user where it is, or call again without path so they can pick it."
            }
            chosenFolderURL = matchingFolderURL
        } else if let frontFinderFolderURL = frontFinderWindowFolderURL() {
            chosenFolderURL = frontFinderFolderURL
        } else {
            guard let pickedFolderURL = await askUserToPickSkillsFolder() else {
                return "the user closed the folder picker without choosing. say nothing was installed."
            }
            chosenFolderURL = pickedFolderURL
        }

        let isConfirmed = DottieConfirmation.ask(
            title: "Install the skills in \(chosenFolderURL.lastPathComponent)?",
            detail: "Every skill in this folder is copied into Dottie's skills library and turned on for every Dot. Skills you already have are kept as they are.\n\n\(chosenFolderURL.path)",
            confirmButtonTitle: "Install"
        )
        guard isConfirmed else { return "the user chose not to install them. say nothing was installed." }

        let folderInstallResult = clickyRoster.skillLibrary.installSkills(fromFolder: chosenFolderURL)
        for installedSkill in folderInstallResult.installedSkills {
            clickyRoster.enableSkillForAllAgents(installedSkill.name)
        }
        if !folderInstallResult.installedSkills.isEmpty {
            ClickyAnalytics.trackSkillChanged(action: "imported")
        }

        let installedCount = folderInstallResult.installedSkills.count
        let alreadyInstalledCount = folderInstallResult.alreadyInstalledSkillNames.count
        let failedCount = folderInstallResult.failedSkillMessages.count
        if installedCount == 0 && alreadyInstalledCount == 0 && failedCount == 0 {
            return "\(chosenFolderURL.lastPathComponent) has no skills in it (no folder with a SKILL.md). tell the user."
        }
        var resultLines = ["installed \(installedCount) skill\(installedCount == 1 ? "" : "s") from \(chosenFolderURL.lastPathComponent), each turned on for every dot."]
        if alreadyInstalledCount > 0 {
            resultLines.append("\(alreadyInstalledCount) were already installed and kept as they were.")
        }
        if failedCount > 0 {
            resultLines.append("\(failedCount) couldn't be copied: \(folderInstallResult.failedSkillMessages.prefix(5).joined(separator: "; ")).")
        }
        resultLines.append("tell the user in one sentence; they're in Home → Skills.")
        return resultLines.joined(separator: " ")
    }

    // MARK: - Finding the folder

    /// A path ("~/Downloads/skills", "/Users/…") or a folder name the user
    /// said ("dottie skills", "Downloads"), looked for in the home folder,
    /// Desktop, Downloads and Documents and up to two levels inside them.
    private static func folderURL(matchingSaidFolder saidFolder: String) -> URL? {
        let expandedPath = (saidFolder as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return isExistingFolder(atPath: expandedPath) ? URL(fileURLWithPath: expandedPath, isDirectory: true) : nil
        }

        let homeFolderURL = FileManager.default.homeDirectoryForCurrentUser
        let searchRootURLs = [
            homeFolderURL,
            homeFolderURL.appendingPathComponent("Desktop", isDirectory: true),
            homeFolderURL.appendingPathComponent("Downloads", isDirectory: true),
            homeFolderURL.appendingPathComponent("Documents", isDirectory: true),
        ]
        let wantedFolderName = normalizedFolderName(saidFolder)

        if let matchingRootURL = searchRootURLs.first(where: { normalizedFolderName($0.lastPathComponent) == wantedFolderName }) {
            return matchingRootURL
        }
        for searchRootURL in searchRootURLs {
            let childFolderURLs = (try? FileManager.default.contentsOfDirectory(
                at: searchRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            if let matchingChildFolderURL = childFolderURLs.first(where: {
                normalizedFolderName($0.lastPathComponent) == wantedFolderName && isExistingFolder(atPath: $0.path)
            }) {
                return matchingChildFolderURL
            }
        }
        // One level further down, for folders like ~/Dottie-claude-folder/dottie-skills.
        for searchRootURL in searchRootURLs {
            let childFolderURLs = (try? FileManager.default.contentsOfDirectory(
                at: searchRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for childFolderURL in childFolderURLs where isExistingFolder(atPath: childFolderURL.path) {
                let grandchildFolderURLs = (try? FileManager.default.contentsOfDirectory(
                    at: childFolderURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                if let matchingGrandchildFolderURL = grandchildFolderURLs.first(where: {
                    normalizedFolderName($0.lastPathComponent) == wantedFolderName && isExistingFolder(atPath: $0.path)
                }) {
                    return matchingGrandchildFolderURL
                }
            }
        }
        return nil
    }

    /// "Dottie Skills", "dottie-skills" and "my dottie_skills folder" all
    /// become "dottieskills", so a spoken name finds the folder on disk.
    private static func normalizedFolderName(_ folderName: String) -> String {
        var lowercasedFolderName = folderName.lowercased().trimmingCharacters(in: .whitespaces)
        if lowercasedFolderName.hasPrefix("the ") {
            lowercasedFolderName = String(lowercasedFolderName.dropFirst("the ".count))
        }
        if lowercasedFolderName.hasPrefix("my ") {
            lowercasedFolderName = String(lowercasedFolderName.dropFirst("my ".count))
        }
        if lowercasedFolderName.hasSuffix(" folder") {
            lowercasedFolderName = String(lowercasedFolderName.dropLast(" folder".count))
        }
        return lowercasedFolderName.filter { $0.isLetter || $0.isNumber }
    }

    private static func isExistingFolder(atPath folderPath: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The folder shown in the front Finder window when Finder is the app in
    /// front, so "install these skills" works on what the user is looking
    /// at. Asking Finder needs the user's Automation permission once.
    private static func frontFinderWindowFolderURL() -> URL? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return nil }
        let finderScriptSource = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return ""
            return POSIX path of (target of front Finder window as alias)
        end tell
        """
        var finderScriptError: NSDictionary?
        guard let finderScript = NSAppleScript(source: finderScriptSource),
              let frontWindowFolderPath = finderScript.executeAndReturnError(&finderScriptError).stringValue,
              !frontWindowFolderPath.isEmpty,
              isExistingFolder(atPath: frontWindowFolderPath) else { return nil }
        return URL(fileURLWithPath: frontWindowFolderPath, isDirectory: true)
    }

    /// Dottie is a menu bar app, so she comes to the front first or the
    /// picker would open behind the user's window.
    private static func askUserToPickSkillsFolder() async -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Install Skills"
        openPanel.message = "Choose the folder of skills to install (or one skill folder with a SKILL.md in it)."
        NSApp.activate(ignoringOtherApps: true)
        let pickerResponse = await withCheckedContinuation { continuation in
            openPanel.begin { modalResponse in
                continuation.resume(returning: modalResponse)
            }
        }
        guard pickerResponse == .OK else { return nil }
        return openPanel.url
    }
}
