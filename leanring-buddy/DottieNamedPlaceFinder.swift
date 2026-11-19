//
//  DottieNamedPlaceFinder.swift
//  leanring-buddy
//
//  Finds the folders and files a helper's task names ("in the 'bull and
//  shit' folder, open 'invoice cleanup.demo.xlsx'") before the helper
//  starts, so it gets the real paths and access to the folder instead of
//  searching the whole Mac step by step (each step is a full model round
//  trip) and being refused outside its own folders. Foundation only, so
//  the matching can be unit tested.
//

import Foundation

enum DottieNamedPlaceFinder {
    struct FoundFolder: Equatable {
        let spokenName: String
        let folderURL: URL
        /// Files in the folder, for the note; the closest match to a file
        /// the task named comes first.
        let fileNames: [String]
        /// The real name of a file the task named, when one is close enough.
        let matchedFileName: String?
    }

    static let maximumFilesListed = 25

    /// Names the task puts in quotes, and "the X folder" / "X folder" phrases.
    static func spokenNames(in taskText: String) -> [String] {
        var names: [String] = []
        let quotedPattern = "[\"'\u{2018}\u{2019}\u{201C}\u{201D}`]([^\"'\u{2018}\u{2019}\u{201C}\u{201D}`\\n]{2,80})[\"'\u{2018}\u{2019}\u{201C}\u{201D}`]"
        let folderPhrasePattern = "\\b(?:the|my|in|from|inside)\\s+([a-z0-9][a-z0-9 _.-]{1,60}?)\\s+folder\\b"
        for (pattern, options) in [(quotedPattern, NSRegularExpression.Options()), (folderPhrasePattern, .caseInsensitive)] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let range = NSRange(taskText.startIndex..., in: taskText)
            for match in expression.matches(in: taskText, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: taskText) else { continue }
                var name = String(taskText[nameRange]).trimmingCharacters(in: .whitespaces)
                // "the 'bull and shit' folder" was already caught in quotes.
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\u{2018}\u{2019}\u{201C}\u{201D}"))
                // "in the bull folder" catches "the bull".
                for leadingWord in ["the ", "my "] where name.lowercased().hasPrefix(leadingWord) {
                    name = String(name.dropFirst(leadingWord.count))
                }
                if !name.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    names.append(name)
                }
            }
        }
        return names
    }

    /// Letters and digits only, lowercased: "Invoice Cleanup (Dottie demo)"
    /// and "invoice cleanup.demo" compare by their words.
    static func comparableWords(_ name: String) -> [String] {
        let withoutExtension = isFileName(name) ? (name as NSString).deletingPathExtension : name
        return withoutExtension.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// How alike two names are, about 0 to 1: the share of the asked-for name's
    /// words that are in the real name. Same extension adds a little.
    static func similarity(askedName: String, realName: String) -> Double {
        let askedWords = comparableWords(askedName)
        guard !askedWords.isEmpty else { return 0 }
        let realWords = Set(comparableWords(realName))
        let sharedCount = askedWords.filter { realWords.contains($0) }.count
        // Extra words cost a little, so "Report.xlsx" beats "Report 2.xlsx".
        let extraWordCount = max(0, realWords.count - sharedCount)
        var score = Double(sharedCount) / Double(askedWords.count) - Double(extraWordCount) * 0.01
        let askedExtension = (askedName as NSString).pathExtension.lowercased()
        if !askedExtension.isEmpty, askedExtension == (realName as NSString).pathExtension.lowercased() {
            score += 0.1
        }
        return min(max(score, 0), 1.1)
    }

    /// The folders a task names, looked for one level inside each search
    /// folder (home, Desktop, Documents, Downloads), names matched without
    /// caring about case, spaces, dashes or underscores.
    static func findFolders(
        in taskText: String,
        searchFolderURLs: [URL],
        fileManager: FileManager = .default
    ) -> [FoundFolder] {
        let names = spokenNames(in: taskText)
        guard !names.isEmpty else { return [] }
        // A name with a file extension is a file, not a folder.
        let fileNames = names.filter { isFileName($0) }
        let folderNames = names.filter { !isFileName($0) }
        var foundFolders: [FoundFolder] = []
        for folderName in folderNames {
            guard let folderURL = folder(named: folderName, searchFolderURLs: searchFolderURLs, fileManager: fileManager),
                  !foundFolders.contains(where: { $0.folderURL == folderURL }) else { continue }
            let contents = (try? fileManager.contentsOfDirectory(atPath: folderURL.path))?
                .filter { !$0.hasPrefix(".") }
                .sorted() ?? []
            var matchedFileName: String?
            var bestScore = 0.5
            for askedFileName in fileNames {
                for realName in contents {
                    let score = similarity(askedName: askedFileName, realName: realName)
                    if score > bestScore {
                        bestScore = score
                        matchedFileName = realName
                    }
                }
            }
            var listedNames = contents
            if let matchedFileName {
                listedNames.removeAll { $0 == matchedFileName }
                listedNames.insert(matchedFileName, at: 0)
            }
            foundFolders.append(FoundFolder(
                spokenName: folderName,
                folderURL: folderURL,
                fileNames: Array(listedNames.prefix(maximumFilesListed)),
                matchedFileName: matchedFileName
            ))
        }
        return foundFolders
    }

    /// What the helper is told: the real paths, so it starts working
    /// instead of searching.
    static func noteText(for foundFolders: [FoundFolder]) -> String? {
        guard !foundFolders.isEmpty else { return nil }
        var lines = ["[where things are] Dottie already found what the task names; use these paths directly, no need to search:"]
        for foundFolder in foundFolders {
            lines.append("- \"\(foundFolder.spokenName)\" folder: \(foundFolder.folderURL.path)")
            if let matchedFileName = foundFolder.matchedFileName {
                lines.append("  the file meant is most likely: \(foundFolder.folderURL.appendingPathComponent(matchedFileName).path)")
            }
            if !foundFolder.fileNames.isEmpty {
                lines.append("  files there: \(foundFolder.fileNames.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func isFileName(_ name: String) -> Bool {
        let pathExtension = (name as NSString).pathExtension
        return (1...8).contains(pathExtension.count)
            && pathExtension.rangeOfCharacter(from: CharacterSet.letters) != nil
            && pathExtension.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil
    }

    private static func folder(named folderName: String, searchFolderURLs: [URL], fileManager: FileManager) -> URL? {
        let wantedKey = folderKey(folderName)
        guard !wantedKey.isEmpty else { return nil }
        for searchFolderURL in searchFolderURLs {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: searchFolderURL.path) else { continue }
            for entry in entries where folderKey(entry) == wantedKey {
                let candidateURL = searchFolderURL.appendingPathComponent(entry, isDirectory: true)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return candidateURL
                }
            }
        }
        return nil
    }

    /// A folder name with only its letters and digits, lowercased, so
    /// "Dottie test sandbox" said out loud finds "Dottie-test-sandbox".
    static func folderKey(_ name: String) -> String {
        name.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
