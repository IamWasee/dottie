//
//  DottieFolderCleanup.swift
//  leanring-buddy
//
//  "Clean up my Downloads." Builds a plan on the Mac, without any model
//  calls: sort files into folders by type (or by month), find exact
//  duplicates (same size, then same SHA-256), point out big files nobody
//  has opened in months, and give screenshots readable names from the
//  words on them (Apple's on-device text recognition). The plan shows in a
//  window with a checkbox per change; nothing happens until the user taps
//  Clean up. Removed files go to the Trash, never deleted, and the last
//  cleanup can be undone.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import Vision

@MainActor
final class DottieFolderCleanup {
    /// One proposed change, with its checkbox.
    struct Change: Identifiable {
        enum Kind {
            case move
            case rename
            case trash
        }

        let id = UUID()
        let kind: Kind
        let section: String
        let sourceURL: URL
        /// For move: the folder it goes into. For rename: the new name.
        let destinationFolderName: String?
        let newName: String?
        let detail: String
        let byteCount: Int64
        var isChecked: Bool
    }

    struct Plan {
        let folderURL: URL
        var changes: [Change]
    }

    /// One step of a cleanup, kept so it can be undone.
    private struct UndoStep: Codable {
        let from: String
        let to: String
    }

    private struct UndoLog: Codable {
        let folderPath: String
        let date: Date
        let steps: [UndoStep]
        let createdFolders: [String]
    }

    private var planWindow: NSWindow?

    private static var undoLogURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folderURL = applicationSupportURL.appendingPathComponent("Dottie", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL.appendingPathComponent("cleanup-undo.json")
    }

    var hasUndo: Bool {
        FileManager.default.fileExists(atPath: Self.undoLogURL.path)
    }

    // MARK: - Planning

    func planAndShow(folderName: String, groupsByMonth: Bool) async -> String {
        guard let folderURL = Self.resolveFolder(folderName) else {
            return "couldn't find a folder called \(folderName) in their home folder. ask them for its name or where it is."
        }
        guard Self.isSafeToClean(folderURL) else {
            return "that folder holds system or app files, so it's off limits. offer Downloads, Desktop or a folder of their own."
        }
        DottieEveryday.shared.notchPresenter?.showThinking(label: "looking through \(folderURL.lastPathComponent)")
        let changes = await Task.detached(priority: .userInitiated) {
            Self.buildChanges(in: folderURL, groupsByMonth: groupsByMonth)
        }.value
        if DottieEveryday.shared.notchPresenter?.surface == .thinking {
            DottieEveryday.shared.notchPresenter?.collapse()
        }
        guard !changes.isEmpty else {
            return "\(folderURL.lastPathComponent) already looks tidy; nothing to clean up. tell them."
        }
        showPlanWindow(Plan(folderURL: folderURL, changes: changes))

        let counts = Dictionary(grouping: changes, by: \.section).map { "\($0.value.count) \($0.key.lowercased())" }
        return "showing the cleanup plan for \(folderURL.lastPathComponent) in a window: \(counts.joined(separator: ", ")). nothing changes until they tap Clean up; removed files go to the Trash. tell them to look it over."
    }

    private static func resolveFolder(_ name: String) -> URL? {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lowered {
        case "", "downloads", "download", "my downloads":
            return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case "desktop", "my desktop":
            return fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        case "documents", "my documents":
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        default:
            break
        }
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let folderURL = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) && isDirectory.boolValue ? folderURL : nil
        }
        // A folder by name: in the home folder, then one level inside the
        // usual places.
        let searchRoots = [homeURL] + [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { fileManager.urls(for: $0, in: .userDomainMask).first }
        for rootURL in searchRoots {
            guard let childURLs = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            if let match = childURLs.first(where: { $0.lastPathComponent.lowercased() == lowered && $0.hasDirectoryPath }) {
                return match
            }
        }
        return nil
    }

    private static func isSafeToClean(_ folderURL: URL) -> Bool {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path
        guard folderPath.hasPrefix(homePath + "/") else { return false }
        let relativePath = String(folderPath.dropFirst(homePath.count + 1))
        let blockedTops = ["Library", "Applications", ".Trash"]
        return !blockedTops.contains { relativePath == $0 || relativePath.hasPrefix($0 + "/") }
            && !relativePath.hasPrefix(".")
    }

    // MARK: - Building the plan (off the main thread)

    private nonisolated static let categories: [(folder: String, extensions: Set<String>)] = [
        ("Images", ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2", "nef", "arw", "dng", "psd", "ai", "sketch", "fig"]),
        ("Videos", ["mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv"]),
        ("Music and Audio", ["mp3", "m4a", "wav", "aif", "aiff", "flac", "aac", "ogg", "opus"]),
        ("PDFs", ["pdf"]),
        ("Documents", ["doc", "docx", "pages", "txt", "rtf", "rtfd", "md", "odt", "epub"]),
        ("Spreadsheets", ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]),
        ("Presentations", ["ppt", "pptx", "key", "odp"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
        ("Installers", ["dmg", "pkg", "mpkg", "iso", "app"]),
        ("Code", ["swift", "py", "js", "ts", "json", "html", "css", "java", "c", "cpp", "h", "rb", "go", "rs", "sh", "ipynb", "yml", "yaml", "xml", "sql"])
    ]
    private nonisolated static let inProgressExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
    private nonisolated static let bigFileBytes: Int64 = 500 * 1024 * 1024
    private nonisolated static let oldFileDays: Double = 90
    private nonisolated static let maximumScreenshotsToRead = 40

    private struct ScannedFile {
        let url: URL
        let byteCount: Int64
        let isPackage: Bool
        let createdAt: Date
        let modifiedAt: Date
        let lastUsedAt: Date
    }

    nonisolated private static func buildChanges(in folderURL: URL, groupsByMonth: Bool) -> [Change] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileSizeKey, .creationDateKey, .contentModificationDateKey, .contentAccessDateKey]
        guard let childURLs = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [ScannedFile] = []
        for childURL in childURLs {
            guard let values = try? childURL.resourceValues(forKeys: Set(keys)) else { continue }
            let isPackage = values.isPackage ?? false
            // Folders that are already there are left alone; app bundles and
            // other packages count as files.
            if values.isDirectory == true && !isPackage { continue }
            if inProgressExtensions.contains(childURL.pathExtension.lowercased()) { continue }
            let modifiedAt = values.contentModificationDate ?? Date()
            files.append(ScannedFile(
                url: childURL,
                byteCount: Int64(values.totalFileSize ?? values.fileSize ?? 0),
                isPackage: isPackage,
                createdAt: values.creationDate ?? modifiedAt,
                modifiedAt: modifiedAt,
                lastUsedAt: max(values.contentAccessDate ?? modifiedAt, modifiedAt)
            ))
        }

        var changes: [Change] = []
        var handledPaths: Set<String> = []

        // Duplicates: same size, then same contents. The oldest copy stays.
        let sizeGroups = Dictionary(grouping: files.filter { !$0.isPackage && $0.byteCount > 0 }, by: \.byteCount).values.filter { $0.count > 1 }
        for sameSizeFiles in sizeGroups {
            let hashGroups = Dictionary(grouping: sameSizeFiles.compactMap { file in sha256(of: file.url).map { (file, $0) } }, by: { $0.1 }).values
            for duplicates in hashGroups where duplicates.count > 1 {
                let sortedCopies = duplicates.map(\.0).sorted { first, second in
                    if first.createdAt != second.createdAt { return first.createdAt < second.createdAt }
                    return first.url.lastPathComponent.count < second.url.lastPathComponent.count
                }
                guard let keptCopy = sortedCopies.first else { continue }
                for extraCopy in sortedCopies.dropFirst() {
                    handledPaths.insert(extraCopy.url.path)
                    changes.append(Change(
                        kind: .trash, section: "Duplicates", sourceURL: extraCopy.url,
                        destinationFolderName: nil, newName: nil,
                        detail: "Same as \(keptCopy.url.lastPathComponent) · \(byteText(extraCopy.byteCount))",
                        byteCount: extraCopy.byteCount, isChecked: true
                    ))
                }
            }
        }

        // Big files nobody has opened in months. Off by default: the user decides.
        let now = Date()
        for file in files where !handledPaths.contains(file.url.path) {
            let daysUnused = now.timeIntervalSince(file.lastUsedAt) / 86_400
            guard file.byteCount >= bigFileBytes, daysUnused >= oldFileDays else { continue }
            handledPaths.insert(file.url.path)
            changes.append(Change(
                kind: .trash, section: "Big and old", sourceURL: file.url,
                destinationFolderName: nil, newName: nil,
                detail: "\(byteText(file.byteCount)) · not opened in \(Int(daysUnused / 30)) months",
                byteCount: file.byteCount, isChecked: false
            ))
        }

        // Screenshots get a name from the words on them (newest first).
        let screenshots = files
            .filter { !handledPaths.contains($0.url.path) && isScreenshot($0.url) }
            .sorted { $0.createdAt > $1.createdAt }
        for screenshot in screenshots.prefix(maximumScreenshotsToRead) {
            guard let words = headline(ofImageAt: screenshot.url) else { continue }
            let dateText = screenshotDateFormatter.string(from: screenshot.createdAt)
            let newName = "\(words) \(dateText).\(screenshot.url.pathExtension.lowercased())"
            guard newName != screenshot.url.lastPathComponent else { continue }
            changes.append(Change(
                kind: .rename, section: "Rename screenshots", sourceURL: screenshot.url,
                destinationFolderName: nil, newName: newName,
                detail: "→ \(newName)", byteCount: 0, isChecked: true
            ))
        }

        // Everything else into folders.
        for file in files where !handledPaths.contains(file.url.path) {
            let folderName: String?
            if groupsByMonth {
                folderName = monthFolderFormatter.string(from: file.modifiedAt)
            } else if isScreenshot(file.url) {
                folderName = "Screenshots"
            } else {
                let fileExtension = file.url.pathExtension.lowercased()
                folderName = categories.first { $0.extensions.contains(fileExtension) }?.folder
            }
            guard let folderName else { continue }
            changes.append(Change(
                kind: .move, section: "Sort into folders", sourceURL: file.url,
                destinationFolderName: folderName, newName: nil,
                detail: "→ \(folderName)", byteCount: 0, isChecked: true
            ))
        }
        return changes
    }

    nonisolated private static func isScreenshot(_ fileURL: URL) -> Bool {
        let name = fileURL.lastPathComponent
        let isImage = ["png", "jpg", "jpeg", "heic"].contains(fileURL.pathExtension.lowercased())
        return isImage && (name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") || name.hasPrefix("CleanShot "))
    }

    /// The biggest line of text on the picture (usually a window or page
    /// title), cleaned up for a file name.
    nonisolated private static func headline(ofImageAt fileURL: URL) -> String? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { observation -> (String, CGFloat)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let letterCount = text.filter(\.isLetter).count
            guard letterCount >= 4, text.split(separator: " ").count <= 10 else { return nil }
            return (text, observation.boundingBox.height)
        }
        guard let tallest = lines.max(by: { $0.1 < $1.1 }) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -'&"))
        let cleanedWords = String(tallest.0.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
            .split(separator: " ")
            .joined(separator: " ")
        guard cleanedWords.count >= 4 else { return nil }
        return String(cleanedWords.prefix(50)).trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func sha256(of fileURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fileHandle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? fileHandle.read(upToCount: 1_048_576)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static let screenshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()

    nonisolated private static let monthFolderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM MMMM"
        return formatter
    }()

    nonisolated static func byteText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    // MARK: - Doing it

    /// Carries out the ticked changes and keeps an undo log. Returns a
    /// short summary.
    fileprivate func apply(_ plan: Plan) -> String {
        let fileManager = FileManager.default
        var steps: [UndoStep] = []
        var createdFolders: [String] = []
        var movedCount = 0
        var renamedCount = 0
        var trashedCount = 0
        var trashedBytes: Int64 = 0
        var failedCount = 0

        let checkedChanges = plan.changes.filter(\.isChecked)
        for change in checkedChanges where change.kind == .trash {
            var trashedURL: NSURL?
            do {
                try fileManager.trashItem(at: change.sourceURL, resultingItemURL: &trashedURL)
                if let trashedPath = trashedURL?.path {
                    steps.append(UndoStep(from: change.sourceURL.path, to: trashedPath))
                }
                trashedCount += 1
                trashedBytes += change.byteCount
            } catch {
                failedCount += 1
            }
        }

        // A screenshot can be both renamed and moved: one step for both.
        let renames = Dictionary(checkedChanges.filter { $0.kind == .rename }.map { ($0.sourceURL.path, $0.newName ?? "") }, uniquingKeysWith: { first, _ in first })
        let moves = Dictionary(checkedChanges.filter { $0.kind == .move }.map { ($0.sourceURL.path, $0.destinationFolderName ?? "") }, uniquingKeysWith: { first, _ in first })
        for sourcePath in Set(renames.keys).union(moves.keys) {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            guard fileManager.fileExists(atPath: sourcePath) else { continue }
            var targetFolderURL = sourceURL.deletingLastPathComponent()
            if let folderName = moves[sourcePath], !folderName.isEmpty {
                targetFolderURL = plan.folderURL.appendingPathComponent(folderName, isDirectory: true)
                if !fileManager.fileExists(atPath: targetFolderURL.path) {
                    do {
                        try fileManager.createDirectory(at: targetFolderURL, withIntermediateDirectories: true)
                        createdFolders.append(targetFolderURL.path)
                    } catch {
                        failedCount += 1
                        continue
                    }
                }
            }
            let targetName = renames[sourcePath].flatMap { $0.isEmpty ? nil : $0 } ?? sourceURL.lastPathComponent
            let targetURL = Self.uniqueURL(in: targetFolderURL, named: targetName)
            guard targetURL.path != sourcePath else { continue }
            do {
                try fileManager.moveItem(at: sourceURL, to: targetURL)
                steps.append(UndoStep(from: sourcePath, to: targetURL.path))
                if moves[sourcePath] != nil { movedCount += 1 }
                if renames[sourcePath] != nil { renamedCount += 1 }
            } catch {
                failedCount += 1
            }
        }

        if !steps.isEmpty {
            let undoLog = UndoLog(folderPath: plan.folderURL.path, date: Date(), steps: steps, createdFolders: createdFolders)
            if let logData = try? JSONEncoder().encode(undoLog) {
                try? logData.write(to: Self.undoLogURL, options: .atomic)
            }
        }

        var parts: [String] = []
        if movedCount > 0 { parts.append("sorted \(movedCount) file\(movedCount == 1 ? "" : "s") into folders") }
        if renamedCount > 0 { parts.append("renamed \(renamedCount) screenshot\(renamedCount == 1 ? "" : "s")") }
        if trashedCount > 0 { parts.append("moved \(trashedCount) to the Trash (\(Self.byteText(trashedBytes)))") }
        if failedCount > 0 { parts.append("\(failedCount) couldn't be moved") }
        guard !parts.isEmpty else { return "Nothing was changed." }
        let joinedParts = parts.joined(separator: ", ")
        return String(joinedParts.prefix(1)).uppercased() + String(joinedParts.dropFirst()) + "."
    }

    func undoLastCleanup() -> String {
        guard let logData = try? Data(contentsOf: Self.undoLogURL),
              let undoLog = try? JSONDecoder().decode(UndoLog.self, from: logData) else {
            return "there's no cleanup to undo."
        }
        let fileManager = FileManager.default
        var restoredCount = 0
        var missingCount = 0
        for step in undoLog.steps.reversed() {
            guard fileManager.fileExists(atPath: step.to), !fileManager.fileExists(atPath: step.from) else {
                missingCount += 1
                continue
            }
            do {
                try fileManager.moveItem(atPath: step.to, toPath: step.from)
                restoredCount += 1
            } catch {
                missingCount += 1
            }
        }
        // Folders the cleanup made go away again if they're empty now.
        for folderPath in undoLog.createdFolders {
            let remaining = (try? fileManager.contentsOfDirectory(atPath: folderPath))?.filter { $0 != ".DS_Store" } ?? ["?"]
            if remaining.isEmpty {
                try? fileManager.removeItem(atPath: folderPath)
            }
        }
        try? fileManager.removeItem(at: Self.undoLogURL)
        let folderName = (undoLog.folderPath as NSString).lastPathComponent
        let summary = "Put \(restoredCount) file\(restoredCount == 1 ? "" : "s") in \(folderName) back where they were."
            + (missingCount > 0 ? " \(missingCount) had moved since, so I left them." : "")
        DottieEveryday.shared.tell(title: "Cleanup undone", text: summary)
        return summary
    }

    private static func uniqueURL(in folderURL: URL, named fileName: String) -> URL {
        var candidateURL = folderURL.appendingPathComponent(fileName)
        let baseName = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        var number = 2
        while FileManager.default.fileExists(atPath: candidateURL.path) {
            let numberedName = fileExtension.isEmpty ? "\(baseName) \(number)" : "\(baseName) \(number).\(fileExtension)"
            candidateURL = folderURL.appendingPathComponent(numberedName)
            number += 1
        }
        return candidateURL
    }

    // MARK: - The plan window

    private func showPlanWindow(_ plan: Plan) {
        planWindow?.close()
        let model = CleanupPlanModel(plan: plan)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Clean up \(plan.folderURL.lastPathComponent)"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 460, height: 360)
        model.onFinish = { [weak self, weak window] approvedPlan in
            window?.close()
            guard let self, let approvedPlan else { return }
            let summary = self.apply(approvedPlan)
            DottieEveryday.shared.tell(
                title: "Cleaned up \(approvedPlan.folderURL.lastPathComponent)",
                text: summary + " Want it back? Tap Undo, or say \u{201C}undo the cleanup\u{201D}.",
                actionLabel: "Undo",
                action: { [weak self] in _ = self?.undoLastCleanup() }
            )
        }
        window.contentView = NSHostingView(rootView: CleanupPlanView(model: model))
        window.center()
        planWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Plan window UI

@MainActor
private final class CleanupPlanModel: ObservableObject {
    @Published var plan: DottieFolderCleanup.Plan
    var onFinish: ((DottieFolderCleanup.Plan?) -> Void)?

    static let sectionOrder = ["Duplicates", "Big and old", "Rename screenshots", "Sort into folders"]

    init(plan: DottieFolderCleanup.Plan) {
        self.plan = plan
    }

    var sections: [String] {
        Self.sectionOrder.filter { section in plan.changes.contains { $0.section == section } }
    }

    func indices(in section: String) -> [Int] {
        plan.changes.indices.filter { plan.changes[$0].section == section }
    }

    func setAll(in section: String, to isChecked: Bool) {
        for index in indices(in: section) {
            plan.changes[index].isChecked = isChecked
        }
    }

    var checkedCount: Int { plan.changes.filter(\.isChecked).count }

    var trashBytes: Int64 {
        plan.changes.filter { $0.isChecked && $0.kind == .trash }.reduce(0) { $0 + $1.byteCount }
    }
}

private struct CleanupPlanView: View {
    @ObservedObject var model: CleanupPlanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Here's my plan for \(model.plan.folderURL.lastPathComponent)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Untick anything you want left alone. Nothing changes until you tap Clean up, and removed files go to the Trash.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.sections, id: \.self) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            Divider().background(DS.Colors.borderSubtle)
            HStack(spacing: 12) {
                Text(footerText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button("Cancel") { model.onFinish?(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Clean up") { model.onFinish?(model.plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.checkedCount == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 360)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
    }

    private var footerText: String {
        let trashBytes = model.trashBytes
        let freedText = trashBytes > 0 ? " · frees \(DottieFolderCleanup.byteText(trashBytes))" : ""
        return "\(model.checkedCount) change\(model.checkedCount == 1 ? "" : "s")\(freedText)"
    }

    private func sectionView(_ section: String) -> some View {
        let sectionIndices = model.indices(in: section)
        let isAllChecked = sectionIndices.allSatisfy { model.plan.changes[$0].isChecked }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(section.uppercased()) · \(sectionIndices.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Button(isAllChecked ? "Untick all" : "Tick all") {
                    model.setAll(in: section, to: !isAllChecked)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.accentText)
                .pointerCursor()
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sectionIndices, id: \.self) { index in
                    Toggle(isOn: Binding(
                        get: { model.plan.changes[index].isChecked },
                        set: { model.plan.changes[index].isChecked = $0 }
                    )) {
                        HStack(spacing: 6) {
                            Text(model.plan.changes[index].sourceURL.lastPathComponent)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(model.plan.changes[index].detail)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
        }
    }
}
