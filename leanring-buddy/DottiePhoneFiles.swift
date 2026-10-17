//
//  DottiePhoneFiles.swift
//  leanring-buddy
//
//  Files from the Mac, asked for by text: "find my howto presentation",
//  "send it to me", "put this_file on my Google Drive". A quick Gemini call
//  reads the text and uses three tools: Spotlight finds files anywhere on
//  the Mac in about a second, Telegram sends a file straight to the phone,
//  and Google Drive for desktop's folder uploads one to Drive. Without Drive
//  for desktop, CompanionManager has Dottie upload it at drive.google.com
//  on screen. Any other text goes to the Phone helper as before.
//

import Foundation

@MainActor
final class DottiePhoneFiles {
    /// The files the last search found, numbered from 1, so a later text
    /// can say "send the second one".
    private(set) var lastMatches: [URL] = []

    /// Sends a file to the paired phone. Returns nil when sent, else why not.
    var sendFileToPhone: ((URL, String) async -> String?)?
    /// Uploads a file at drive.google.com on screen (no Drive for desktop).
    /// Returns what to text back now; the result follows later.
    var uploadToDriveOnScreen: ((URL) -> String)?
    var sendText: ((String) async -> Void)?

    private static let model = "gemini-3.5-flash-lite"

    /// Handles a text if it's about files. Returns false when it isn't, so
    /// the Phone helper takes it.
    func handle(_ text: String) async -> Bool {
        let lowered = text.lowercased()
        // Only spend a Gemini call on texts that could be about files.
        let fileWords = ["file", "send", "find", "drive", "presentation", "document", "doc", "pdf", "photo", "picture",
                         "slides", "keynote", "spreadsheet", "folder", "upload", "share", "that one", "number", "first", "second"]
        let mentionsFiles = fileWords.contains { lowered.contains($0) }
        guard mentionsFiles || (!lastMatches.isEmpty && lowered.count < 40) else { return false }

        var contents: [[String: Any]] = [["role": "user", "parts": [["text": contextText() + "\nThe text: " + text]]]]
        for _ in 0..<6 {
            guard let modelParts = await requestNextStep(contents: contents) else { return false }
            contents.append(["role": "model", "parts": modelParts])
            let functionCalls = modelParts.compactMap { $0["functionCall"] as? [String: Any] }
            guard !functionCalls.isEmpty else { return false }
            var responses: [[String: Any]] = []
            for functionCall in functionCalls {
                let name = functionCall["name"] as? String ?? ""
                let arguments = functionCall["args"] as? [String: Any] ?? [:]
                switch name {
                case "hand_to_helper":
                    return false
                case "reply":
                    await sendText?((arguments["text"] as? String) ?? "Done.")
                    return true
                default:
                    let result = await perform(name: name, arguments: arguments)
                    var response: [String: Any] = ["name": name, "response": ["result": result]]
                    if let callID = functionCall["id"] as? String { response["id"] = callID }
                    responses.append(["functionResponse": response])
                }
            }
            contents.append(["role": "user", "parts": responses])
        }
        await sendText?("I got a bit lost there. Try again with the file's name?")
        return true
    }

    private func contextText() -> String {
        guard !lastMatches.isEmpty else { return "No files found yet in this chat." }
        return "Files found by the last search:\n" + Self.describe(lastMatches)
    }

    private func perform(name: String, arguments: [String: Any]) async -> String {
        switch name {
        case "find_files":
            let query = ((arguments["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "error: no name to look for" }
            lastMatches = await Self.findFiles(named: query)
            return lastMatches.isEmpty
                ? "nothing on the Mac matches \(query)."
                : "found:\n" + Self.describe(lastMatches)
        case "send_files":
            let files = chosenFiles(arguments)
            guard !files.isEmpty else { return "error: pick files by their number from the search" }
            var results: [String] = []
            for file in files {
                let problem = await sendFileToPhone?(file, file.lastPathComponent) ?? "the phone isn't connected."
                results.append(problem.map { "\(file.lastPathComponent): \($0)" } ?? "\(file.lastPathComponent): sent")
            }
            return results.joined(separator: "\n")
        case "save_to_google_drive":
            let files = chosenFiles(arguments)
            guard !files.isEmpty else { return "error: pick files by their number from the search" }
            var results: [String] = []
            for file in files {
                if let driveFolder = Self.googleDriveFolder() {
                    do {
                        let copiedURL = try Self.copy(file, into: driveFolder)
                        results.append("\(file.lastPathComponent): copied into Google Drive (My Drive/\(copiedURL.deletingLastPathComponent().lastPathComponent)); Drive for desktop uploads it in a moment.")
                    } catch {
                        results.append("\(file.lastPathComponent): couldn't copy it (\(error.localizedDescription)).")
                    }
                } else {
                    results.append("\(file.lastPathComponent): " + (uploadToDriveOnScreen?(file) ?? "can't reach Google Drive."))
                }
            }
            return results.joined(separator: "\n")
        default:
            return "unknown tool"
        }
    }

    private func chosenFiles(_ arguments: [String: Any]) -> [URL] {
        let numbers = ((arguments["numbers"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        return numbers.compactMap { number in
            number >= 1 && number <= lastMatches.count ? lastMatches[number - 1] : nil
        }
    }

    // MARK: - Gemini

    private func requestNextStep(contents: [[String: Any]]) async -> [[String: Any]]? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let body: [String: Any] = [
            "model": Self.model,
            "systemInstruction": ["parts": [["text": Self.systemInstruction]]],
            "contents": contents,
            "tools": [["functionDeclarations": Self.functionDeclarations]],
            "toolConfig": ["functionCallingConfig": ["mode": "ANY"]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let parts = GeminiServerSentEvents.parts(from: data)
        return parts.isEmpty ? nil : parts
    }

    private static let systemInstruction = """
    You read texts the user sends from their phone to their Mac. If the text is about finding a file on the Mac, sending a file to their phone, or putting a file on Google Drive, use the tools; for anything else call hand_to_helper right away.
    - Search with find_files using the file's name or a distinctive part of it (without words like "presentation" or "file", which aren't in names). Try another spelling or a shorter part if nothing turns up.
    - If one file clearly matches, go ahead with what they asked. If several could be it, reply with the numbered list and ask which.
    - "send it to me", "text it to me", "send it here" means send_files. "put it on drive", "upload to google drive" means save_to_google_drive. If they only asked to find it, reply with what you found.
    - Finish with reply: a short text in plain words.
    """

    private static var functionDeclarations: [[String: Any]] {
        [
            [
                "name": "find_files",
                "description": "Search the whole Mac for files whose name contains these words (Spotlight).",
                "parameters": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]
            ],
            [
                "name": "send_files",
                "description": "Send files to the user's phone in this chat, by their numbers in the last search.",
                "parameters": ["type": "object", "properties": ["numbers": ["type": "array", "items": ["type": "integer"]]], "required": ["numbers"]]
            ],
            [
                "name": "save_to_google_drive",
                "description": "Put files on the user's Google Drive, by their numbers in the last search.",
                "parameters": ["type": "object", "properties": ["numbers": ["type": "array", "items": ["type": "integer"]]], "required": ["numbers"]]
            ],
            [
                "name": "reply",
                "description": "Text the user back and finish.",
                "parameters": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
            ],
            [
                "name": "hand_to_helper",
                "description": "The text isn't about files: a helper on the Mac takes it.",
                "parameters": ["type": "object", "properties": [:]]
            ]
        ]
    }

    // MARK: - Files on the Mac

    /// Files whose name contains the query, most recently used first.
    static func findFiles(named query: String, limit: Int = 8) async -> [URL] {
        let escapedQuery = query.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let spotlightQuery = "kMDItemFSName == \"*\(escapedQuery)*\"cd && kMDItemContentTypeTree != \"public.folder\""
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let result = await DottieMacActions.runProcess("/usr/bin/mdfind", arguments: ["-onlyin", homePath, spotlightQuery], timeout: 15)
        let skippedParts = ["/Library/", "/.Trash/", "/node_modules/", "/.git/", "/Caches/", ".app/"]
        let paths = result.output.split(separator: "\n").map(String.init).filter { path in
            !skippedParts.contains { path.contains($0) } && !(path as NSString).lastPathComponent.hasPrefix(".")
        }
        let urls = paths.prefix(200).map { URL(fileURLWithPath: $0) }
        let datedURLs = urls.map { url -> (URL, Date) in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
            return (url, values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast)
        }
        return datedURLs.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    private static func describe(_ urls: [URL]) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let formatter = ByteCountFormatter()
        return urls.enumerated().map { index, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize.map { formatter.string(fromByteCount: Int64($0)) } ?? "folder"
            let date = values?.contentModificationDate?.formatted(date: .abbreviated, time: .omitted) ?? ""
            let shortPath = url.path.replacingOccurrences(of: homePath, with: "~")
            return "\(index + 1). \(shortPath) (\(size), \(date))"
        }.joined(separator: "\n")
    }

    /// "My Drive" inside Google Drive for desktop, when it's installed.
    static func googleDriveFolder() -> URL? {
        let cloudStorageURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let accounts = try? FileManager.default.contentsOfDirectory(at: cloudStorageURL, includingPropertiesForKeys: nil),
              let driveAccount = accounts.first(where: { $0.lastPathComponent.hasPrefix("GoogleDrive") }),
              let driveFolders = try? FileManager.default.contentsOfDirectory(at: driveAccount, includingPropertiesForKeys: nil) else {
            return nil
        }
        // "My Drive" is named in the Mac's language; the others aren't it.
        let notMyDrive: Set<String> = ["Shared drives", "Other computers", ".shortcut-targets-by-id", ".Encrypted", "Computers"]
        return driveFolders.first { $0.lastPathComponent == "My Drive" }
            ?? driveFolders.first { !notMyDrive.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Copies a file into My Drive/From Dottie, keeping both if the name is taken.
    static func copy(_ fileURL: URL, into driveFolder: URL) throws -> URL {
        let destinationFolder = driveFolder.appendingPathComponent("From Dottie", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        var destination = destinationFolder.appendingPathComponent(fileURL.lastPathComponent)
        var copyNumber = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let fileExtension = fileURL.pathExtension
            destination = destinationFolder.appendingPathComponent("\(baseName) \(copyNumber)" + (fileExtension.isEmpty ? "" : ".\(fileExtension)"))
            copyNumber += 1
        }
        try FileManager.default.copyItem(at: fileURL, to: destination)
        return destination
    }
}
