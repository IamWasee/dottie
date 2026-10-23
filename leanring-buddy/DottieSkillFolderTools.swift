//
//  DottieSkillFolderTools.swift
//  leanring-buddy
//
//  "Install the skills in my dottie-skills folder": the install_skills voice
//  tool adds every skill in a folder the user points to (a SKILL.md folder,
//  a folder of them like a downloaded set of 50, or a downloaded repo with
//  a skills/ folder inside) to the skills library and turns each new one on
//  for every Dot, the same as Home → Skills → "Add a skill folder…". The
//  folder can be a path, a folder name the user says, the folder open in
//  the front Finder window, or one picked in a folder dialog. The user
//  confirms on screen before anything is copied.
//

import AppKit
import Foundation

@MainActor
enum DottieSkillFolderTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "install_skills",
                description: "Installs skills for the Dots from a folder the user points to: every folder inside it that has a SKILL.md (or the folder itself if it has one, or a downloaded repo with a skills folder inside). Use it for asks like 'install the skills in my dottie-skills folder', 'install the skills in Downloads', 'install these skills' (with a Finder window open) or 'install skills from a folder'. Skills already installed are kept as they are, and the user confirms on screen before anything is copied. Then say in one sentence how many were installed.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "folder": ["type": "STRING", "description": "The folder as the user said it: a path like ~/Downloads/skills, or a folder name like dottie-skills or Downloads. Leave out when they mean the folder open in Finder or didn't name one; a folder picker opens then."]
                    ]
                ],
                audiences: [.voice]
            ) { arguments in
                await installSkills(spokenFolder: arguments.dottieString("folder") ?? arguments.dottieString("path"))
            }
        ]
    }

    private static func installSkills(spokenFolder: String?) async -> String {
        guard let clickyRoster = DottieSelfKnowledge.companionManager?.clickyRoster else {
            return "skills can't be installed right now. say so in one line."
        }

        let chosenFolderURL: URL
        if let spokenFolder, !spokenFolder.isEmpty, let matchingFolderURL = folderURL(matchingSpokenFolder: spokenFolder) {
            chosenFolderURL = matchingFolderURL
        } else if spokenFolder == nil, let frontFinderFolderURL = frontFinderWindowFolderURL() {
            chosenFolderURL = frontFinderFolderURL
        } else if let pickedFolderURL = await askUserToPickSkillsFolder(couldNotFindSpokenFolder: spokenFolder) {
            chosenFolderURL = pickedFolderURL
        } else {
            return "the user closed the folder picker without choosing. say nothing was installed."
        }

        let skillFolderURLs = ClickySkillLibrary.skillFolders(inFolder: chosenFolderURL)
        guard !skillFolderURLs.isEmpty else {
            return "\(chosenFolderURL.lastPathComponent) has no skills in it (no folder with a SKILL.md). tell the user."
        }

        let isConfirmed = DottieConfirmation.ask(
            title: "Install \(skillFolderURLs.count) skill\(skillFolderURLs.count == 1 ? "" : "s") from \(chosenFolderURL.lastPathComponent)?",
            detail: "They're copied into Dottie's Skills library and turned on for every Dot. Skills you already have are left as they are.\n\n\(chosenFolderURL.path)",
            confirmButtonTitle: "Install"
        )
        guard isConfirmed else { return "the user chose not to install them. say okay in a few words." }

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

    /// A path ("~/Downloads/skills") or a folder name the user said
    /// ("dottie skills", "Downloads"), looked for in the home folder,
    /// Desktop, Downloads and Documents and one level inside them.
    private static func folderURL(matchingSpokenFolder spokenFolder: String) -> URL? {
        let expandedPath = (spokenFolder as NSString).expandingTildeInPath
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
        let wantedFolderName = normalizedFolderName(spokenFolder)
        guard !wantedFolderName.isEmpty else { return nil }

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
        var lowercasedName = folderName.lowercased().trimmingCharacters(in: .whitespaces)
        if lowercasedName.hasSuffix(" folder") {
            lowercasedName = String(lowercasedName.dropLast(" folder".count))
        }
        if lowercasedName.hasPrefix("my ") {
            lowercasedName = String(lowercasedName.dropFirst("my ".count))
        }
        if lowercasedName.hasPrefix("the ") {
            lowercasedName = String(lowercasedName.dropFirst("the ".count))
        }
        return lowercasedName.filter { $0.isLetter || $0.isNumber }
    }

    private static func isExistingFolder(atPath folderPath: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The folder in the front Finder window, when Finder is the app in
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
        var scriptError: NSDictionary?
        guard let finderScript = NSAppleScript(source: finderScriptSource),
              let frontWindowFolderPath = finderScript.executeAndReturnError(&scriptError).stringValue,
              !frontWindowFolderPath.isEmpty,
              isExistingFolder(atPath: frontWindowFolderPath) else { return nil }
        return URL(fileURLWithPath: frontWindowFolderPath, isDirectory: true)
    }

    /// Dottie is a menu bar app, so she comes to the front first or the
    /// picker would open behind the user's window.
    private static func askUserToPickSkillsFolder(couldNotFindSpokenFolder spokenFolder: String?) async -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Install Skills"
        if let spokenFolder, !spokenFolder.isEmpty {
            openPanel.message = "Couldn't find \u{201C}\(spokenFolder)\u{201D}. Choose the folder with the skills in it."
        } else {
            openPanel.message = "Choose the folder of skills to install (or one skill folder with a SKILL.md in it)."
        }
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
