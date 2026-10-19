//
//  DottieBuiltInSkills.swift
//  leanring-buddy
//
//  Instructions only some helper tasks need (building a website, driving
//  Mac apps, operating apps with computer use) used to sit in every
//  helper's AGENTS.md, so every request of every turn re-sent them. They
//  are skills now: the helper sees one line per skill and reads the rest
//  only when a task needs it.
//
//  Gemini CLI picks them up from its user skills folder in Dottie's own CLI
//  home; Claude helpers get the same files through their bot's skills.
//

import Foundation

enum DottieBuiltInSkills {
    struct BuiltInSkill {
        let folderName: String
        let description: String
        let instructions: String
    }

    /// Skills every helper has. `includesComputerUse` adds the steps for
    /// operating apps with the computer-use tools (Gemini helpers only;
    /// Claude helpers hand on-screen steps back to Dottie).
    static func skills(includesComputerUse: Bool) -> [BuiltInSkill] {
        var builtInSkills = [
            BuiltInSkill(
                folderName: "dottie-building-things",
                description: "Use when asked to build or make something real: a website, web app, small tool, script, document or data file.",
                instructions: GeminiCLIAgentRuntime.buildingAgentInstructions
            ),
            BuiltInSkill(
                folderName: "dottie-mac-apps",
                description: "Use when a task involves Mac apps such as Calendar, Reminders, Notes, Mail, Music or Finder, or the user's Apple Shortcuts.",
                instructions: GeminiCLIAgentRuntime.macAppsAgentInstructions
            )
        ]
        if includesComputerUse {
            builtInSkills.append(BuiltInSkill(
                folderName: "dottie-operating-apps",
                description: "Use before operating an app or website on the Mac with the computer-use tools (clicking, typing, reading a window).",
                instructions: ClickyComputerUse.operatingAppsInstructions
            ))
        }
        return builtInSkills
    }

    /// Writes each skill's SKILL.md into `skillsFolderURL`, removing built-in
    /// skills that no longer apply, and returns the SKILL.md files written.
    /// Only rewrites a file whose text changed.
    @discardableResult
    static func write(_ builtInSkills: [BuiltInSkill], into skillsFolderURL: URL) -> [URL] {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: skillsFolderURL, withIntermediateDirectories: true)

        let currentFolderNames = Set(builtInSkills.map(\.folderName))
        let existingFolderNames = (try? fileManager.contentsOfDirectory(atPath: skillsFolderURL.path)) ?? []
        for staleFolderName in existingFolderNames where staleFolderName.hasPrefix("dottie-") && !currentFolderNames.contains(staleFolderName) {
            try? fileManager.removeItem(at: skillsFolderURL.appendingPathComponent(staleFolderName))
        }

        var skillFileURLs: [URL] = []
        for builtInSkill in builtInSkills {
            let skillFolderURL = skillsFolderURL.appendingPathComponent(builtInSkill.folderName, isDirectory: true)
            try? fileManager.createDirectory(at: skillFolderURL, withIntermediateDirectories: true)
            let skillFileURL = skillFolderURL.appendingPathComponent("SKILL.md")
            let skillFileText = """
            ---
            name: \(builtInSkill.folderName)
            description: \(builtInSkill.description)
            ---

            \(builtInSkill.instructions.trimmingCharacters(in: .whitespacesAndNewlines))

            """
            let existingText = try? String(contentsOf: skillFileURL, encoding: .utf8)
            if existingText != skillFileText {
                try? skillFileText.write(to: skillFileURL, atomically: true, encoding: .utf8)
            }
            skillFileURLs.append(skillFileURL)
        }
        return skillFileURLs
    }
}
