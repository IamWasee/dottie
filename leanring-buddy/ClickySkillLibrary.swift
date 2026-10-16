//
//  ClickySkillLibrary.swift
//  leanring-buddy
//
//  Skills: reusable instructions a Clicky pulls in when a task calls for
//  them (how to make a report in the user's style, how to use some CLI,
//  a checklist for a recurring chore). Shipped Clicky keeps a skills
//  library and turns skills on per Clicky (ClickySkillLibraryBackend,
//  HermesSkillCatalog).
//
//  The clone uses Gemini CLI's own skills support. A skill is a folder with
//  a SKILL.md (YAML front matter with `name` and `description`, then the
//  instructions). The library lives in
//  ~/Library/Application Support/ClickyClone/Skills/<name>/SKILL.md, and a
//  skill reaches an agent as a symlink in its workspace's .gemini/skills/
//  folder. Gemini CLI lists every linked skill's name and description to the
//  model and loads the full instructions only when it calls activate_skill.
//

import AppKit
import Foundation

struct ClickySkill: Identifiable, Equatable {
    /// The folder name, which is also the skill's name.
    let name: String
    let description: String
    let folderURL: URL

    var id: String { name }
    var skillFileURL: URL { folderURL.appendingPathComponent("SKILL.md") }
}

enum ClickySkillLibraryError: LocalizedError {
    case invalidName
    case nameTaken(String)
    case missingSkillFile

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Give the skill a name with at least one letter or number."
        case .nameTaken(let skillName):
            return "There's already a skill called \(skillName)."
        case .missingSkillFile:
            return "That folder has no SKILL.md file in it."
        }
    }
}

@MainActor
final class ClickySkillLibrary: ObservableObject {
    @Published private(set) var skills: [ClickySkill] = []

    let libraryURL: URL

    /// Gemini CLI built-in skills the clone hides from agents.
    nonisolated static let hiddenBuiltInSkillNames = ["antigravity-support"]

    init(libraryURL: URL) {
        self.libraryURL = libraryURL
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Reading

    func reload() {
        let folderURLs = (try? FileManager.default.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        skills = folderURLs
            .compactMap(Self.readSkill(inFolder:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func skill(named skillName: String) -> ClickySkill? {
        skills.first { $0.name == skillName }
    }

    /// Names of the skill folders on disk right now, without parsing them.
    /// Used to spot skills an agent saved during a turn.
    func skillFolderNamesOnDisk() -> Set<String> {
        let folderNames = (try? FileManager.default.contentsOfDirectory(atPath: libraryURL.path)) ?? []
        return Set(folderNames.filter { !$0.hasPrefix(".") })
    }

    nonisolated private static func readSkill(inFolder folderURL: URL) -> ClickySkill? {
        let skillFileURL = folderURL.appendingPathComponent("SKILL.md")
        guard let skillFileText = try? String(contentsOf: skillFileURL, encoding: .utf8) else { return nil }
        let frontMatter = parseFrontMatter(skillFileText)
        return ClickySkill(
            name: folderURL.lastPathComponent,
            description: frontMatter["description"] ?? "",
            folderURL: folderURL
        )
    }

    /// Reads simple `key: value` lines between the opening and closing `---`.
    /// Enough for name and description; nested YAML is ignored.
    nonisolated static func parseFrontMatter(_ skillFileText: String) -> [String: String] {
        let lines = skillFileText.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var frontMatter: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard !line.hasPrefix(" "), let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let firstCharacter = value.first, firstCharacter == "\"" || firstCharacter == "'",
               value.last == firstCharacter {
                value = String(value.dropFirst().dropLast())
            }
            frontMatter[key] = value
        }
        return frontMatter
    }

    // MARK: - Changing

    /// Turns "Weekly Report!" into "weekly-report", the form Gemini CLI
    /// expects for skill names.
    nonisolated static func skillName(from displayName: String) -> String {
        let slugCharacters = displayName.lowercased().map { character -> Character in
            (character.isASCII && (character.isLetter || character.isNumber)) ? character : "-"
        }
        let skillName = String(slugCharacters)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(skillName.prefix(60))
    }

    @discardableResult
    func createSkill(displayName: String, description: String, instructions: String) throws -> ClickySkill {
        let skillName = Self.skillName(from: displayName)
        guard !skillName.isEmpty else { throw ClickySkillLibraryError.invalidName }
        let folderURL = libraryURL.appendingPathComponent(skillName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folderURL.path) else {
            throw ClickySkillLibraryError.nameTaken(skillName)
        }

        let oneLineDescription = description
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
        let skillFileText = """
        ---
        name: \(skillName)
        description: "\(oneLineDescription)"
        ---

        # \(displayName.trimmingCharacters(in: .whitespacesAndNewlines))

        \(instructions.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try skillFileText.write(to: folderURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        reload()
        return skill(named: skillName) ?? ClickySkill(name: skillName, description: oneLineDescription, folderURL: folderURL)
    }

    /// Copies a skill folder (one with a SKILL.md) into the library, for
    /// example one downloaded from GitHub.
    @discardableResult
    func importSkill(fromFolder sourceFolderURL: URL) throws -> ClickySkill {
        guard FileManager.default.fileExists(atPath: sourceFolderURL.appendingPathComponent("SKILL.md").path) else {
            throw ClickySkillLibraryError.missingSkillFile
        }
        let skillName = Self.skillName(from: sourceFolderURL.lastPathComponent)
        guard !skillName.isEmpty else { throw ClickySkillLibraryError.invalidName }
        let destinationFolderURL = libraryURL.appendingPathComponent(skillName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destinationFolderURL.path) else {
            throw ClickySkillLibraryError.nameTaken(skillName)
        }
        try FileManager.default.copyItem(at: sourceFolderURL, to: destinationFolderURL)
        reload()
        guard let importedSkill = skill(named: skillName) else { throw ClickySkillLibraryError.missingSkillFile }
        return importedSkill
    }

    /// Moves the skill's folder to the Trash.
    func deleteSkill(_ skill: ClickySkill) {
        try? FileManager.default.trashItem(at: skill.folderURL, resultingItemURL: nil)
        reload()
    }

    func revealInFinder(_ skill: ClickySkill) {
        NSWorkspace.shared.activateFileViewerSelecting([skill.skillFileURL])
    }

    func revealLibraryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([libraryURL])
    }

    // MARK: - Linking into agent workspaces

    /// Makes the workspace's .gemini/skills folder hold exactly one symlink
    /// per enabled skill. Real folders there (skills an agent made for
    /// itself) are left alone.
    func linkSkills(named enabledSkillNames: Set<String>, intoWorkspace workspaceURL: URL) {
        let fileManager = FileManager.default
        let workspaceSkillsURL = workspaceURL.appendingPathComponent(".gemini/skills", isDirectory: true)
        try? fileManager.createDirectory(at: workspaceSkillsURL, withIntermediateDirectories: true)

        let librarySkillNames = Set(skills.map(\.name))
        let wantedSkillNames = enabledSkillNames.intersection(librarySkillNames)

        let existingEntryNames = (try? fileManager.contentsOfDirectory(atPath: workspaceSkillsURL.path)) ?? []
        for existingEntryName in existingEntryNames {
            let entryURL = workspaceSkillsURL.appendingPathComponent(existingEntryName)
            let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: entryURL.path)) != nil
            if isSymlink && !wantedSkillNames.contains(existingEntryName) {
                try? fileManager.removeItem(at: entryURL)
            }
        }

        for skillName in wantedSkillNames {
            let linkURL = workspaceSkillsURL.appendingPathComponent(skillName)
            let linkTargetURL = libraryURL.appendingPathComponent(skillName, isDirectory: true)
            if let currentTarget = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) {
                if currentTarget == linkTargetURL.path { continue }
                try? fileManager.removeItem(at: linkURL)
            } else if fileManager.fileExists(atPath: linkURL.path) {
                // The agent has its own folder with this name; keep it.
                continue
            }
            try? fileManager.createSymbolicLink(at: linkURL, withDestinationURL: linkTargetURL)
        }
    }

    // MARK: - Agent instructions

    /// The part of every agent's global AGENTS.md about skills.
    nonisolated static func globalAgentInstructions(libraryURL: URL) -> String {
        """
        # Skills

        Skills are saved instructions for a kind of task. The ones turned on for you are listed to you with a name and a description; when a task matches one, activate it and follow it.

        When the user asks you to remember how to do something so you can do it the same way again (a report format, the steps of a chore, how to use a tool they rely on), save it as a skill in the shared library at `\(libraryURL.path)`: a folder named with lowercase words and hyphens, holding a `SKILL.md` that starts with front matter giving `name` (the folder name) and a one-sentence `description` of when to use it, followed by the instructions. Clicky turns a skill you save on for you, and the user can turn it on for other Clickys. Tell the user in one sentence that you saved it. Don't save skills the user didn't ask for, and don't edit skills in the library unless the user asks you to change one.

        """
    }
}
