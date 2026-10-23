//
//  DottieSkillFolderTools.swift
//  leanring-buddy
//
//  "Install the skills in this folder": the install_skills voice tool adds
//  every skill in a folder the user points to (a SKILL.md folder, or a
//  folder of them like a downloaded set of 50) to the skills library and
//  turns each new one on for every Dot, the same as Home → Skills →
//  "Add a skill folder…". Without a path, a folder picker opens so the user
//  can point to it.
//

import AppKit
import Foundation

@MainActor
enum DottieSkillFolderTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "install_skills",
                description: "Installs skills for the Dots from a folder the user points to: every folder inside it that has a SKILL.md (or the folder itself if it has one). Skills already installed are kept as they are. Pass path only when the user said where the folder is (like ~/Dottie-claude-folder/dottie-skills); otherwise leave it out and a folder picker opens for them to choose it. Then say in one sentence how many were installed.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "path": ["type": "STRING", "description": "The folder's path, only when the user said it. ~ is their home folder."]
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
            chosenFolderURL = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: chosenFolderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "there's no folder at \(chosenFolderURL.path). ask the user where it is, or call again without path so they can pick it."
            }
        } else {
            guard let pickedFolderURL = await askUserToPickSkillsFolder() else {
                return "the user closed the folder picker without choosing. say nothing was installed."
            }
            chosenFolderURL = pickedFolderURL
        }

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
