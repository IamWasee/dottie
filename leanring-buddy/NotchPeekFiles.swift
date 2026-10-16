//
//  NotchPeekFiles.swift
//  leanring-buddy
//
//  The newest files your Dots made, as a row of thumbnails in the notch's
//  hover peek. Shipped Clicky has the same "file pile" (NotchAgentPeekFilePile,
//  NotchAgentPeekFileTile, NotchAgentPeekFileDragSource): click a file to
//  open it, or drag it straight into Mail, Slack, Finder or any other app.
//

import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Finding the files

enum NotchPeekFileIndex {
    /// Folders scanned in each Dot's workspace. `output/` is where Dots are
    /// told to put what they make; `tmp/` and `.gemini/` are scratch.
    private static let scannedFolderName = "output"
    /// How deep inside output/ to look (a Dot may group files in folders).
    private static let maximumDepth = 2

    /// The newest files across all Dots, newest first. Reads the disk, so
    /// call it off the main thread.
    static func newestFiles(
        inWorkspaces workspaces: [(agentID: UUID, agentName: String, workspaceURL: URL)],
        limit: Int
    ) -> [NotchPeekFile] {
        var foundFiles: [NotchPeekFile] = []
        for workspace in workspaces {
            let outputFolderURL = workspace.workspaceURL.appendingPathComponent(scannedFolderName, isDirectory: true)
            guard let fileEnumerator = FileManager.default.enumerator(
                at: outputFolderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in fileEnumerator {
                if fileEnumerator.level > maximumDepth {
                    fileEnumerator.skipDescendants()
                    continue
                }
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      resourceValues.isRegularFile == true else { continue }
                foundFiles.append(NotchPeekFile(
                    url: fileURL,
                    agentID: workspace.agentID,
                    agentName: workspace.agentName,
                    modifiedAt: resourceValues.contentModificationDate ?? .distantPast
                ))
            }
        }
        return Array(foundFiles.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit))
    }
}

// MARK: - Thumbnails

/// Quick Look thumbnails for the tiles, cached by path and modification
/// date so hovering again doesn't redraw them.
@MainActor
final class NotchPeekThumbnailCache: ObservableObject {
    static let shared = NotchPeekThumbnailCache()

    @Published private var thumbnailsByKey: [String: NSImage] = [:]
    private var keysBeingLoaded: Set<String> = []

    func thumbnail(for peekFile: NotchPeekFile) -> NSImage? {
        thumbnailsByKey[Self.cacheKey(for: peekFile)]
    }

    func loadThumbnailIfNeeded(for peekFile: NotchPeekFile, pointSize: CGSize) {
        let cacheKey = Self.cacheKey(for: peekFile)
        guard thumbnailsByKey[cacheKey] == nil, !keysBeingLoaded.contains(cacheKey) else { return }
        keysBeingLoaded.insert(cacheKey)

        let thumbnailRequest = QLThumbnailGenerator.Request(
            fileAt: peekFile.url,
            size: pointSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: thumbnailRequest) { thumbnailRepresentation, _ in
            let thumbnailImage = thumbnailRepresentation?.nsImage
            Task { @MainActor in
                let cache = NotchPeekThumbnailCache.shared
                cache.keysBeingLoaded.remove(cacheKey)
                // Fall back to the file's Finder icon.
                cache.thumbnailsByKey[cacheKey] = thumbnailImage ?? NSWorkspace.shared.icon(forFile: peekFile.url.path)
            }
        }
    }

    private static func cacheKey(for peekFile: NotchPeekFile) -> String {
        "\(peekFile.url.path)|\(peekFile.modifiedAt.timeIntervalSince1970)"
    }
}

// MARK: - Views

struct NotchPeekFilePile: View {
    @ObservedObject var notchPresenter: NotchPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Made by your Dots")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
            HStack(spacing: 8) {
                ForEach(notchPresenter.peekFiles) { peekFile in
                    NotchPeekFileTile(peekFile: peekFile, notchPresenter: notchPresenter)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct NotchPeekFileTile: View {
    let peekFile: NotchPeekFile
    @ObservedObject var notchPresenter: NotchPresenter
    @ObservedObject private var thumbnailCache = NotchPeekThumbnailCache.shared
    @State private var isHovered = false

    private static let thumbnailSize = CGSize(width: 48, height: 44)

    var body: some View {
        VStack(spacing: 3) {
            thumbnail
                .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
            Text(peekFile.url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 56)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.1 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { notchPresenter.onOpenPeekFile?(peekFile) }
        .onDrag {
            NSItemProvider(contentsOf: peekFile.url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open") { notchPresenter.onOpenPeekFile?(peekFile) }
            Button("Show in Finder") { notchPresenter.onRevealPeekFile?(peekFile) }
            Button("Open \(peekFile.agentName)'s chat") { notchPresenter.onOpenDot?(peekFile.agentID) }
        }
        .pointerCursor()
        .help("\(peekFile.url.lastPathComponent), made by \(peekFile.agentName) \(Self.relativeTime(peekFile.modifiedAt)). Click to open, or drag it into another app.")
        .onAppear {
            thumbnailCache.loadThumbnailIfNeeded(for: peekFile, pointSize: Self.thumbnailSize)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailImage = thumbnailCache.thumbnail(for: peekFile) {
            Image(nsImage: thumbnailImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.08))
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
