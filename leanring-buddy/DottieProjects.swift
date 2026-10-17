//
//  DottieProjects.swift
//  leanring-buddy
//
//  Projects: one folder per thing the user is making ("coffee store
//  website", "golem guide"). When voice Dottie hands work to a Dot she names
//  the project, so a new thing gets its own folder and "let's work on the
//  coffee store site again" goes back to the same folder, the same notes
//  (PROJECT.md) and, when it's free, the same Dot. A team of Dots shares the
//  project folder, each doing its own part.
//
//  The folders live in Application Support/Dottie/Projects, which every Dot
//  can reach, so this doesn't widen what Dots can see of the user's Mac.
//  Home → Projects lists them with a button to open each folder.
//

import AppKit
import Combine
import Foundation

@MainActor
final class DottieProjects: ObservableObject {
    struct Project: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var summary: String
        let folderName: String
        let createdAt: Date
        var updatedAt: Date
        /// Dots that worked on it, most recent last.
        var helperNames: [String]
    }

    @Published private(set) var projects: [Project] = []

    let rootFolderURL: URL
    private var indexURL: URL { rootFolderURL.appendingPathComponent("projects.json") }

    /// The notes file every project keeps: what's in it and what's left.
    static let notesFileName = "PROJECT.md"

    init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        rootFolderURL = applicationSupportURL.appendingPathComponent("Dottie/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootFolderURL, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Finding and making

    /// The project the user means, by name: exact, then every word of the
    /// project's name in what they said, then the other way round.
    func project(matching spokenName: String) -> Project? {
        let wantedName = Self.normalized(spokenName)
        guard !wantedName.isEmpty else { return nil }
        if let exactMatch = projects.last(where: { Self.normalized($0.name) == wantedName }) {
            return exactMatch
        }
        let wantedWords = Set(wantedName.split(separator: " ").map(String.init)).subtracting(Self.fillerWords)
        // Most of the project's own words have to be there: "the coffee
        // site" finds "Coffee store website", "store" alone doesn't.
        let scoredProjects = projects.compactMap { project -> (project: Project, score: Int)? in
            let projectWords = Set(Self.normalized(project.name).split(separator: " ").map(String.init)).subtracting(Self.fillerWords)
            let matchedWordCount = projectWords.intersection(wantedWords).count
            guard matchedWordCount > 0, Double(matchedWordCount) >= Double(projectWords.count) / 2 else { return nil }
            return (project, matchedWordCount)
        }
        return scoredProjects
            .max { $0.score < $1.score || ($0.score == $1.score && $0.project.updatedAt < $1.project.updatedAt) }?
            .project
    }

    /// The existing project with this name, or a new one.
    func findOrCreate(named name: String, summary: String = "") -> (project: Project, isNew: Bool) {
        if let existingProject = project(matching: name) {
            return (existingProject, false)
        }
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let projectName = trimmedName.isEmpty ? "Project \(projects.count + 1)" : trimmedName
        let project = Project(
            id: UUID(),
            name: projectName,
            summary: summary,
            folderName: uniqueFolderName(for: projectName),
            createdAt: Date(),
            updatedAt: Date(),
            helperNames: []
        )
        try? FileManager.default.createDirectory(at: folderURL(for: project), withIntermediateDirectories: true)
        let notes = "# \(projectName)\n\n\(summary.isEmpty ? "" : summary + "\n\n")## What's here\n\n(nothing yet)\n\n## What's left\n\n"
        try? notes.write(to: folderURL(for: project).appendingPathComponent(Self.notesFileName), atomically: true, encoding: .utf8)
        projects.append(project)
        saveIndex()
        return (project, true)
    }

    /// A Dot started work on it.
    func noteWork(on projectID: UUID, by helperName: String) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[projectIndex].updatedAt = Date()
        projects[projectIndex].helperNames.removeAll { $0 == helperName }
        projects[projectIndex].helperNames.append(helperName)
        saveIndex()
    }

    func rename(_ project: Project, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let projectIndex = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[projectIndex].name = trimmedName
        saveIndex()
    }

    /// Moves the folder to the Trash, so nothing is lost by accident.
    func remove(_ project: Project) {
        try? FileManager.default.trashItem(at: folderURL(for: project), resultingItemURL: nil)
        projects.removeAll { $0.id == project.id }
        saveIndex()
    }

    func folderURL(for project: Project) -> URL {
        rootFolderURL.appendingPathComponent(project.folderName, isDirectory: true)
    }

    func revealInFinder(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([folderURL(for: project)])
    }

    /// Files in the project, not counting the notes and hidden files.
    func fileNames(in project: Project, limit: Int = 40) -> [String] {
        let folderURL = folderURL(for: project)
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var names: [String] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathComponents.contains("node_modules") {
                enumerator.skipDescendants()
                continue
            }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  fileURL.lastPathComponent != Self.notesFileName else { continue }
            names.append(String(fileURL.path.dropFirst(folderURL.path.count + 1)))
            if names.count >= limit { break }
        }
        return names.sorted()
    }

    /// The project's own notes (what's in it, what's left), shortened.
    func notes(for project: Project, maximumLength: Int = 1500) -> String {
        let notesText = (try? String(contentsOf: folderURL(for: project).appendingPathComponent(Self.notesFileName), encoding: .utf8)) ?? ""
        return String(notesText.prefix(maximumLength))
    }

    // MARK: - What Dots and voice Dottie are told

    /// Put in front of a Dot's task, so it works in the project folder and
    /// keeps the notes up to date.
    func taskPreamble(for project: Project, isNew: Bool, teamNote: String? = nil) -> String {
        let folderPath = folderURL(for: project).path
        var lines = [
            "This task is part of the user's project \"\(project.name)\"\(isNew ? " (new)" : ""). The project's folder is:",
            folderPath,
            "Keep every file for this project in that folder (cd there first; make subfolders as needed), not in your own workspace. When you build something openable (a website, an app), put it there too.",
            "First read \(Self.notesFileName) in that folder to see what's already been done. When you finish, update \(Self.notesFileName): what's in the project now, how to open or run it, and what's left to do."
        ]
        if !isNew {
            let existingFiles = fileNames(in: project, limit: 25)
            if !existingFiles.isEmpty {
                lines.append("Files already there: " + existingFiles.joined(separator: ", "))
            }
        }
        if let teamNote {
            lines.append(teamNote)
        }
        return lines.joined(separator: "\n") + "\n\nThe task:\n"
    }

    /// For voice Dottie's prompt: the projects she can go back to.
    var promptSummary: String {
        projects.sorted { $0.updatedAt > $1.updatedAt }.prefix(15).map { project in
            "- \(project.name)" + (project.summary.isEmpty ? "" : ": \(project.summary)")
                + (project.helperNames.last.map { " (last worked on by \($0))" } ?? "")
        }.joined(separator: "\n")
    }

    /// list_projects: every project with its files and notes.
    func listForVoice() -> String {
        guard !projects.isEmpty else { return "the user has no projects yet. one is made when a helper starts work with a project name." }
        return projects.sorted { $0.updatedAt > $1.updatedAt }.map { project in
            let files = fileNames(in: project, limit: 12)
            return "- \(project.name)\(project.summary.isEmpty ? "" : " (\(project.summary))"): "
                + (files.isEmpty ? "no files yet" : "\(files.count)\(files.count == 12 ? "+" : "") files, like \(files.prefix(5).joined(separator: ", "))")
                + (project.helperNames.isEmpty ? "" : ". worked on by \(project.helperNames.suffix(3).joined(separator: ", "))")
        }.joined(separator: "\n")
    }

    // MARK: - Private

    private static let fillerWords: Set<String> = ["the", "a", "an", "my", "project", "for", "of", "website", "site", "app"]

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func uniqueFolderName(for name: String) -> String {
        let baseName = Self.normalized(name).replacingOccurrences(of: " ", with: "-").prefix(40)
        let folderBase = baseName.isEmpty ? "project" : String(baseName)
        var folderName = folderBase
        var number = 2
        while FileManager.default.fileExists(atPath: rootFolderURL.appendingPathComponent(folderName).path) {
            folderName = "\(folderBase)-\(number)"
            number += 1
        }
        return folderName
    }

    private func loadIndex() {
        guard let indexData = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        projects = (try? decoder.decode([Project].self, from: indexData)) ?? []
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let indexData = try? encoder.encode(projects) else { return }
        try? indexData.write(to: indexURL, options: .atomic)
    }
}
