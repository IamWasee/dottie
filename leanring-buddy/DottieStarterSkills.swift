//
//  DottieStarterSkills.swift
//  leanring-buddy
//
//  Fifty ready-made skills that ship with Dottie (documents, design,
//  coding, research, Mac automation, video, marketing), modeled on the
//  most used skills from Anthropic's skills repo, obra/superpowers and the
//  community. Their source is starter-skills/<name>/SKILL.md in the repo,
//  packed into DottieStarterSkills.json by scripts/build-starter-skills.py.
//
//  Each one is copied into the skills library once. A skill the user
//  edited is never overwritten, and one they deleted doesn't come back.
//  They're off for existing Dots (the user turns them on in Home → Skills);
//  a new Dot starts with the whole library, as before.
//

import Foundation

enum DottieStarterSkills {
    private struct StarterSkill: Decodable {
        let name: String
        let text: String
    }

    private static let installedNamesDefaultsKey = "dottieInstalledStarterSkillNames"

    /// Copies starter skills the library has never had into it.
    static func installMissingSkills(into libraryURL: URL) {
        guard let bundledFileURL = Bundle.main.url(forResource: "DottieStarterSkills", withExtension: "json"),
              let bundledData = try? Data(contentsOf: bundledFileURL),
              let starterSkills = try? JSONDecoder().decode([StarterSkill].self, from: bundledData) else {
            return
        }
        let fileManager = FileManager.default
        var installedNames = Set(UserDefaults.standard.stringArray(forKey: installedNamesDefaultsKey) ?? [])
        for starterSkill in starterSkills where !installedNames.contains(starterSkill.name) {
            let skillFolderURL = libraryURL.appendingPathComponent(starterSkill.name, isDirectory: true)
            // The user may already have a skill by this name; theirs stays.
            if !fileManager.fileExists(atPath: skillFolderURL.path) {
                try? fileManager.createDirectory(at: skillFolderURL, withIntermediateDirectories: true)
                try? starterSkill.text.write(to: skillFolderURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            }
            installedNames.insert(starterSkill.name)
        }
        UserDefaults.standard.set(Array(installedNames).sorted(), forKey: installedNamesDefaultsKey)
    }
}
